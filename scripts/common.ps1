# operation-router 공용 헬퍼 (dot-source 전용). 런타임 경로/검증/Git/마스킹/계약을 제공한다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RuntimeRoot = Split-Path -Parent $PSScriptRoot
$Script:ConfigDir   = Join-Path $Script:RuntimeRoot 'config'
$Script:StateDir    = Join-Path $Script:RuntimeRoot 'state'
$Script:PendingDir  = Join-Path $Script:StateDir 'pending'
$Script:LogRoot     = Join-Path $Script:RuntimeRoot 'logs'
$Script:RuntimeLogDir = Join-Path $Script:LogRoot 'runtime'
$Script:TestLogRoot = Join-Path $Script:LogRoot 'tests'
$Script:RouterLogScope = 'runtime'
$Script:TestLogDir  = $null
$Script:TempDir     = Join-Path $Script:RuntimeRoot 'temp'
$Script:ConfigPath       = Join-Path $Script:ConfigDir 'config.json'
$Script:UsageStatePath   = Join-Path $Script:StateDir 'usage-state.json'
$Script:DoctorReportPath = Join-Path $Script:StateDir 'doctor-report.json'

. (Join-Path $PSScriptRoot 'state-store.ps1')
. (Join-Path $PSScriptRoot 'worker-contract.ps1')

function Initialize-RuntimeDirs {
    $dirs = @($Script:RuntimeRoot, $Script:ConfigDir, $Script:StateDir, $Script:PendingDir,
        $Script:LogRoot, $Script:RuntimeLogDir, $Script:TestLogRoot, $Script:TempDir)
    if ($Script:RouterLogScope -eq 'test' -and -not [string]::IsNullOrWhiteSpace([string]$Script:TestLogDir)) {
        $dirs += $Script:TestLogDir
    }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}


# ---------- 입력 검증 (command injection 방지) ----------
function Assert-ValidOperationNumber {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '^[123]$') { throw "Invalid operation number '$Value'. Only 1, 2, or 3 are allowed." }
    return [int]$Value
}
function Assert-ValidIssueNumber {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '^[1-9][0-9]{0,9}$') { throw "Invalid issue number '$Value'. Only a positive integer is allowed." }
    return [int]$Value
}
function Assert-ValidKind {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -ne 'mechanical' -and $Value -ne 'logic') { throw "Invalid --kind '$Value'. Only 'mechanical' or 'logic' are allowed." }
    return $Value
}

# ---------- 경로 안전 ----------
function Assert-PathWithinRoot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $rootPrefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    $inside = $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) {
        throw "Path '$fullPath' escapes required root '$fullRoot'."
    }
    return $fullPath
}

# ---------- 비밀값 마스킹 ----------
# v2.4.0: 문자열이 알려진 secret 형태(접두)가 아니어도 고엔트로피 토큰이면 마스킹한다.
# 단, git SHA(순수 16진)·UUID·순수 숫자는 로그에서 정상적으로 쓰이므로 제외해 오탐을 막는다.
function Test-HighEntropyToken {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Token)
    if ($Token.Length -lt 24) { return $false }
    if ($Token -match '^[0-9a-fA-F]+$') { return $false }                                   # git SHA/hex 다이제스트
    if ($Token -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $false }  # UUID
    if (-not ($Token -cmatch '[a-z]' -and $Token -cmatch '[A-Z]' -and $Token -match '[0-9]')) { return $false }  # 대/소/숫자 혼합만 후보
    $len = $Token.Length; $H = 0.0
    foreach ($g in ($Token.ToCharArray() | Group-Object)) { $p = $g.Count / $len; $H -= $p * [Math]::Log($p, 2) }
    return ($H -ge 3.5)
}
function Protect-SecretText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $m = $Text
    $m = [regex]::Replace($m, 'gh[pousr]_[A-Za-z0-9]{20,}', '***MASKED_GH_TOKEN***')
    $m = [regex]::Replace($m, 'sk-[A-Za-z0-9]{20,}', '***MASKED_API_KEY***')
    $m = [regex]::Replace($m, 'xai-[A-Za-z0-9]{20,}', '***MASKED_API_KEY***')
    $m = [regex]::Replace($m, 'AKIA[0-9A-Z]{16}', '***MASKED_AWS_KEY***')
    $m = [regex]::Replace($m, '(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*\S+', '$1=***MASKED***')
    $m = [regex]::Replace($m, 'Bearer\s+[A-Za-z0-9\.\-_]{10,}', 'Bearer ***MASKED***')
    # Authorization 헤더 전체(Bearer 외 Basic 등 임의 스킴 포함) 값 제거
    $m = [regex]::Replace($m, '(?im)(Authorization\s*:\s*)\S.*$', '$1***MASKED***')
    # 고엔트로피 토큰 마스킹 (알려진 접두가 없는 secret 대비). 토큰 경계로만 검사.
    $m = [regex]::Replace($m, '[A-Za-z0-9+/_\-]{24,}', {
        param($mm)
        if (Test-HighEntropyToken -Token $mm.Value) { return '***MASKED_HIGH_ENTROPY***' } else { return $mm.Value }
    })
    return $m
}

function Write-RouterLog {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Content)
    Initialize-RuntimeDirs
    $scope = [string]$Script:RouterLogScope
    if ($scope -eq 'runtime') { $dir = $Script:RuntimeLogDir; $root = $Script:RuntimeLogDir }
    elseif ($scope -eq 'test') {
        if ([string]::IsNullOrWhiteSpace([string]$Script:TestLogDir)) { throw 'Test log scope requires TestLogDir.' }
        $dir = $Script:TestLogDir; $root = $Script:TestLogRoot
    } else { throw "Unknown router log scope '$scope'." }
    Assert-PathWithinRoot -Path $dir -Root $root | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $safeName = ($Name -replace '[^a-zA-Z0-9_\-]', '_')
    $path = Join-Path $dir "$stamp-$safeName.log"
    if (Test-Path -LiteralPath $path) { $path = Join-Path $dir "$stamp-$safeName-$([guid]::NewGuid().ToString('N')).log" }
    Assert-PathWithinRoot -Path $path -Root $root | Out-Null
    Set-Content -LiteralPath $path -Value (Protect-SecretText -Text $Content) -Encoding UTF8
    Invoke-LogRetention -Scope $scope
    return $path
}
function Invoke-LogRetention {
    param([ValidateSet('runtime','test')][string]$Scope = 'runtime')
    $cfg = Get-Config
    $keep = 20
    if ($cfg.PSObject.Properties.Name -contains 'logRetentionCount') { $keep = [int]$cfg.logRetentionCount }
    if ($Scope -eq 'runtime') { $dir = $Script:RuntimeLogDir; $root = $Script:RuntimeLogDir }
    else {
        if ([string]::IsNullOrWhiteSpace([string]$Script:TestLogDir)) { throw 'Test log retention requires TestLogDir.' }
        $dir = $Script:TestLogDir; $root = $Script:TestLogRoot
    }
    Assert-PathWithinRoot -Path $dir -Root $root | Out-Null
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $files = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.log' | Sort-Object LastWriteTime -Descending)
    if ($files.Count -gt $keep) {
        foreach ($file in @($files | Select-Object -Skip $keep)) {
            Assert-PathWithinRoot -Path $file.FullName -Root $dir | Out-Null
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function Remove-TestLogDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $full = Assert-PathWithinRoot -Path $Path -Root $Script:TestLogRoot
    if ($full.Equals([System.IO.Path]::GetFullPath($Script:TestLogRoot).TrimEnd('\','/'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove the test log root itself.'
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}


# ---------- Git 헬퍼 ----------
function Invoke-GitRaw {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$GitArgs)
    $ErrorActionPreference = 'Continue'
    Push-Location $Path
    try {
        $out = & git @GitArgs 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($out | Out-String)).Trim() }
    } finally { Pop-Location }
}
function Test-GitRepository {
    param([string]$Path = (Get-Location).Path)
    return ((Invoke-GitRaw -Path $Path -GitArgs @('rev-parse','--is-inside-work-tree')).ExitCode -eq 0)
}
function Get-GitHead {
    param([string]$Path = (Get-Location).Path)
    $r = Invoke-GitRaw -Path $Path -GitArgs @('rev-parse','HEAD')
    if ($r.ExitCode -ne 0) { return $null }
    return $r.Text
}
function Get-GitCurrentBranch {
    param([string]$Path = (Get-Location).Path)
    return (Invoke-GitRaw -Path $Path -GitArgs @('rev-parse','--abbrev-ref','HEAD')).Text
}
function Get-GitWorktreeStatus {
    param([string]$Path = (Get-Location).Path)
    $r = Invoke-GitRaw -Path $Path -GitArgs @('status','--porcelain')
    return @{ Clean = ([string]::IsNullOrWhiteSpace($r.Text)); Raw = $r.Text }
}
function Get-GitOriginOwnerRepo {
    param([string]$Path = (Get-Location).Path)
    $r = Invoke-GitRaw -Path $Path -GitArgs @('remote','get-url','origin')
    if ($r.ExitCode -ne 0) { return $null }
    if ($r.Text -match '[:/]([^/:]+)/([^/]+?)(\.git)?$') { return "$($Matches[1])/$($Matches[2])" }
    return $null
}
# 지정 원격 ref 대비 ahead/behind. 생략하면 legacy origin/main을 사용한다.
function Get-GitAheadBehind {
    param([string]$Path = (Get-Location).Path, [string]$RemoteRef = 'origin/main')
    $r = Invoke-GitRaw -Path $Path -GitArgs @('rev-list','--left-right','--count',"$RemoteRef...HEAD")
    if ($r.ExitCode -ne 0) { return @{ Available = $false; Ahead = $null; Behind = $null } }
    $parts = $r.Text -split '\s+'
    if ($parts.Count -ge 2) { return @{ Available = $true; Behind = [int]$parts[0]; Ahead = [int]$parts[1] } }
    return @{ Available = $false; Ahead = $null; Behind = $null }
}
function Get-GitCommitCountSince {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SinceHead)
    $r = Invoke-GitRaw -Path $Path -GitArgs @('rev-list','--count',"$SinceHead..HEAD")
    if ($r.ExitCode -ne 0) { return 0 }
    if ($r.Text -match '^\d+$') { return [int]$r.Text }
    return 0
}
function Get-GitChangedFiles {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SinceHead)
    $r = Invoke-GitRaw -Path $Path -GitArgs @('diff','--name-only',"$SinceHead..HEAD")
    if ($r.ExitCode -ne 0) { return @() }
    if ([string]::IsNullOrWhiteSpace($r.Text)) { return @() }
    return ($r.Text -split "`r?`n" | Where-Object { $_ -ne '' })
}
# 검수 프롬프트용 diff. 과대 컨텍스트 방지를 위해 최대 문자수로 자른다.
function Get-GitDiff {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SinceHead, [int]$MaxChars = 40000)
    $r = Invoke-GitRaw -Path $Path -GitArgs @('diff',"$SinceHead..HEAD")
    if ($r.ExitCode -ne 0) { return '' }
    $t = $r.Text
    if ($t.Length -gt $MaxChars) { return $t.Substring(0, $MaxChars) + "`n...[diff truncated at $MaxChars chars]..." }
    return $t
}

function Get-GitReviewDiffChunks {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SinceHead,
        [int]$MaxChunkChars = 30000
    )
    if ($MaxChunkChars -lt 1000) { throw 'MaxChunkChars must be at least 1000.' }
    $changed=@(Get-GitChangedFiles -Path $Path -SinceHead $SinceHead)
    $chunks=@()
    $truncated=@()
    foreach ($file in $changed) {
        $r=Invoke-GitRaw -Path $Path -GitArgs @('diff','--binary','--full-index',"$SinceHead..HEAD",'--',[string]$file)
        if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$r.Text)) {
            $truncated+=[string]$file
            continue
        }
        $text=[string]$r.Text
        $count=[Math]::Max(1,[int][Math]::Ceiling($text.Length/[double]$MaxChunkChars))
        for ($index=0;$index -lt $count;$index++) {
            $offset=$index*$MaxChunkChars
            $length=[Math]::Min($MaxChunkChars,$text.Length-$offset)
            $chunks += [pscustomobject]@{
                file=[string]$file;chunkIndex=$index+1;chunkCount=$count
                text=$text.Substring($offset,$length)
            }
        }
    }
    return [pscustomobject]@{
        changedFiles=@($changed);chunks=@($chunks);truncatedFiles=@($truncated)
    }
}


# 영수증/스냅샷의 저장소가 현재 저장소와 같은지 검증 (fail-closed: 확인 불가면 불일치)
function Test-ReceiptRepoMatch {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$RepoPath)
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $props = $Receipt.PSObject.Properties.Name
    if (-not $id.repoRoot -or -not $id.repoRootHash) { return $false }
    $rOwner = $null; if ($props -contains 'ownerRepo') { $rOwner = [string]$Receipt.ownerRepo }
    if ($id.ownerRepo) {
        if ([string]::IsNullOrWhiteSpace($rOwner) -or -not $rOwner.Equals([string]$id.ownerRepo, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    } elseif (-not [string]::IsNullOrWhiteSpace($rOwner)) { return $false }
    $rRoot = $null
    if ($props -contains 'canonicalRepoRoot') { $rRoot = [string]$Receipt.canonicalRepoRoot }
    elseif ($props -contains 'repoRoot') { $rRoot = [string]$Receipt.repoRoot }
    if ([string]::IsNullOrWhiteSpace($rRoot)) { return $false }
    try {
        if ((Get-NormalizedCanonicalRepoRoot -Path $rRoot) -cne (Get-NormalizedCanonicalRepoRoot -Path $id.repoRoot)) { return $false }
    } catch { return $false }
    if ($props -contains 'repoRootHash') {
        if ([string]::IsNullOrWhiteSpace([string]$Receipt.repoRootHash) -or [string]$Receipt.repoRootHash -cne [string]$id.repoRootHash) { return $false }
    } elseif ($props -contains 'namespaceVersion' -and [int]$Receipt.namespaceVersion -ge 2) { return $false }
    return $true
}

function Get-ReceiptWithLegacyMigration {
    param(
        [Parameter(Mandatory)][string]$CurrentPath, [Parameter(Mandatory)][string]$LegacyPath,
        [Parameter(Mandatory)][string]$RepoPath, [switch]$BlockActiveExecution
    )
    if (Test-Path -LiteralPath $CurrentPath) { return (Read-JsonFile -Path $CurrentPath) }
    if ($LegacyPath -eq $CurrentPath -or -not (Test-Path -LiteralPath $LegacyPath)) { return $null }
    $legacy = Read-JsonFile -Path $LegacyPath
    $reason = $null
    if (-not (Test-ReceiptRepoMatch -Receipt $legacy -RepoPath $RepoPath)) { $reason = 'legacy_repository_identity_ambiguous' }
    elseif ($BlockActiveExecution -and (Test-ExecutionStatusActive -Status ([string]$legacy.status))) { $reason = 'legacy_active_execution_migration_blocked' }
    if ($reason) {
        Add-Member -InputObject $legacy -NotePropertyName legacyNamespaceBlocked -NotePropertyValue $true -Force
        Add-Member -InputObject $legacy -NotePropertyName legacyNamespaceReason -NotePropertyValue $reason -Force
        return $legacy
    }
    $parent = Split-Path -Parent $CurrentPath
    Assert-PathWithinRoot -Path $CurrentPath -Root $Script:PendingDir | Out-Null
    Assert-PathWithinRoot -Path $LegacyPath -Root $Script:PendingDir | Out-Null
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $id = Get-RepoIdentity -RepoPath $RepoPath
    foreach ($field in @{
        ownerRepo=$id.ownerRepo; repoRoot=$id.repoRoot; canonicalRepoRoot=$id.canonicalRepoRoot
        repoRootHash=$id.repoRootHash; namespaceVersion=$id.namespaceVersion
    }.GetEnumerator()) {
        Add-Member -InputObject $legacy -NotePropertyName $field.Key -NotePropertyValue $field.Value -Force
    }
    Write-AtomicJsonFile -Path $CurrentPath -Object $legacy
    $verified = Read-JsonFile -Path $CurrentPath
    if (-not (Test-ReceiptRepoMatch -Receipt $verified -RepoPath $RepoPath)) { throw 'Legacy receipt migration verification failed.' }
    Remove-Item -LiteralPath $LegacyPath -Force
    return $verified
}

# ---------- v2.4.4 외부 구현 워커 실행 세대 ----------
function Get-ExecutionKey {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber)
    return "op$Operation-issue$IssueNumber"
}
function Get-ExecutionReceiptPath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "$(Get-ExecutionKey -Operation $Operation -IssueNumber $IssueNumber)-execution.json")
}
function Get-ExecutionLockPath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "$(Get-ExecutionKey -Operation $Operation -IssueNumber $IssueNumber)-execution.lock")
}
function Open-ExecutionLock {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $path = Get-ExecutionLockPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    try { return [System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
    catch [System.IO.IOException] { return $null }
}
function Get-ExecutionReceipt {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $path = Get-ExecutionReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $legacyPath = Join-Path (Get-LegacyPendingNamespacePath -RepoPath $RepoPath) "$(Get-ExecutionKey -Operation $Operation -IssueNumber $IssueNumber)-execution.json"
    return (Get-ReceiptWithLegacyMigration -CurrentPath $path -LegacyPath $legacyPath -RepoPath $RepoPath -BlockActiveExecution)
}
function Get-ExecutionReceiptStable {
    param([Parameter(Mandatory)][int]$Operation,[Parameter(Mandatory)][int]$IssueNumber,[Parameter(Mandatory)][string]$RepoPath,[int]$MaxAttempts=8,[int]$DelayMilliseconds=75)
    $last=$null
    for($attempt=1;$attempt -le [Math]::Max(1,$MaxAttempts);$attempt++){
        try{
            $receipt=Get-ExecutionReceipt -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
            if($null -eq $receipt){throw [System.IO.InvalidDataException]::new('execution receipt temporarily unavailable')}
            return $receipt
        }catch{$last=$_;if($attempt -lt $MaxAttempts){Start-Sleep -Milliseconds ([Math]::Max(1,$DelayMilliseconds))}}
    }
    if($null -ne $last){throw $last}
    return $null
}
function Save-ExecutionReceipt {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$RepoPath)
    $path = Get-ExecutionReceiptPath -Operation ([int]$Receipt.operation) -IssueNumber ([int]$Receipt.issueNumber) -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    $Receipt.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-AtomicJsonFile -Path $path -Object $Receipt
    return $path
}
function Test-ExecutionStatusActive {
    param([AllowNull()][string]$Status)
    return ($Status -in @('worker_starting','worker_running','worker_exited_postflight_pending','interrupted_postflight_pending','recovering_postflight'))
}
function Get-RouterLogDirectory {
    if ([string]$Script:RouterLogScope -eq 'runtime') { return $Script:RuntimeLogDir }
    if ([string]$Script:RouterLogScope -eq 'test') { return $Script:TestLogDir }
    throw "Unknown router log scope '$($Script:RouterLogScope)'."
}
function Get-Sha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}
function New-ExecutionGeneration {
    param(
        [Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Route,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PromptContent, [string]$RunId,
        [AllowNull()]$Workflow
    )
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $previous = Get-ExecutionReceipt -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $generation = 1
    if ($null -ne $previous -and ($previous.PSObject.Properties.Name -contains 'generation')) { $generation = [int]$previous.generation + 1 }
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $executionId = [guid]::NewGuid().ToString('N')
    $namespace = Get-PendingNamespacePath -RepoPath $RepoPath
    $artifactRoot = Join-Path $namespace 'executions'
    $artifactDir = Join-Path $artifactRoot ("$(Get-ExecutionKey -Operation $Operation -IssueNumber $IssueNumber)-g$generation-$executionId")
    Assert-PathWithinRoot -Path $artifactDir -Root $Script:PendingDir | Out-Null
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    $promptPath = Join-Path $artifactDir 'prompt.txt'
    $resultPath = Join-Path $artifactDir 'result.json'
    $stdoutPath = Join-Path $artifactDir 'stdout.raw'
    $stderrPath = Join-Path $artifactDir 'stderr.raw'
    $sanitizedStdoutPath = Join-Path $artifactDir 'stdout.log'
    $sanitizedStderrPath = Join-Path $artifactDir 'stderr.log'
    $invocationPath = Join-Path $artifactDir 'invocation.json'
    foreach ($path in @($promptPath,$resultPath,$stdoutPath,$stderrPath,$sanitizedStdoutPath,$sanitizedStderrPath,$invocationPath)) { Assert-PathWithinRoot -Path $path -Root $artifactDir | Out-Null }
    [System.IO.File]::WriteAllText($promptPath, $PromptContent, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($stdoutPath, '', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($stderrPath, '', (New-Object System.Text.UTF8Encoding($false)))
    $logDir = Get-RouterLogDirectory
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logPath = Join-Path $logDir ("execution-$executionId.log")
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $header = "executionId=$executionId`noperation=$Operation`nissueNumber=$IssueNumber`nrepository=$($id.ownerRepo)`nstartHead=$($Snapshot.startHead)`nworker=$($Route.worker)`nmodel=$($Route.model)`neffort=$($Route.effort)`nstartedAt=$now`ncliStarted=false"
    [System.IO.File]::WriteAllText($logPath, (Protect-SecretText -Text $header), (New-Object System.Text.UTF8Encoding($false)))
    Invoke-LogRetention -Scope ([string]$Script:RouterLogScope)
    $receipt = [pscustomobject]@{
        schemaVersion = if($null -ne $Workflow){2}else{1}; executionId = $executionId; runId = $RunId; generation = $generation
        ownerRepo = $id.ownerRepo; repoRoot = $id.repoRoot; canonicalRepoRoot = $id.canonicalRepoRoot
        repoRootHash = $id.repoRootHash; namespaceVersion = $id.namespaceVersion
        operation = $Operation; issueNumber = $IssueNumber; kind = $Kind; purpose = 'implement'
        startHead = $Snapshot.startHead; startSnapshot = $Snapshot; worker = $Route.worker; model = $Route.model; effort = $Route.effort
        status = 'worker_starting'; startedAt = $now; updatedAt = $now
        promptHash = (Get-Sha256Text -Text $PromptContent); promptPath = $promptPath; logPath = $logPath
        promptPresent = $true; promptDeletedAt = $null; artifactRoot = $artifactRoot; artifactPath = $artifactDir
        resultPath = $resultPath; rawStdoutPath = $stdoutPath; rawStderrPath = $stderrPath
        stdoutPath = $null; stderrPath = $null; sanitizedStdoutPath = $sanitizedStdoutPath; sanitizedStderrPath = $sanitizedStderrPath
        artifactSanitizationStatus = 'pending'; artifactSanitizedAt = $null
        artifactRetentionStatus = 'pending'; artifactRetentionCompletedAt = $null; invocationPath = $invocationPath
        processId = $null; processStartedAt = $null; finalHead = $null; workerExitCode = $null
        workerStopReason = $null; interruptedReason = $null; workerReportedVerification = $null
        localVerificationComplete = $false; interrupted = $false; recoveredByPostflight = $false
        resultEnvelopePresent = $false; verificationProvenance = 'worker_result_pending'
        postflight = $null; remainingProblems = @()
    }
    if ($null -ne $Workflow) { Add-Member -InputObject $receipt -NotePropertyName workflow -NotePropertyValue (Copy-WorkflowContext -Workflow $Workflow) -Force }
    $receipt = Initialize-ExecutionProgress -Receipt $receipt
    Write-ExecutionProgressEvent -Receipt $receipt -Event execution_created -Summary "execution generation $generation created" | Out-Null
    Save-ExecutionReceipt -Receipt $receipt -RepoPath $RepoPath | Out-Null
    return $receipt
}
function Get-ProcessIdentity {
    param([Parameter(Mandatory)][int]$ProcessId, [scriptblock]$ProcessProbe)
    if ($null -ne $ProcessProbe) { return (& $ProcessProbe $ProcessId) }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return [pscustomobject]@{ exists = $true; startedAt = $p.StartTime.ToUniversalTime().ToString('o') }
    } catch { return [pscustomobject]@{ exists = $false; startedAt = $null } }
}
function Test-ExecutionProcessAlive {
    param([Parameter(Mandatory)]$Receipt, [scriptblock]$ProcessProbe)
    if ($null -eq $Receipt.processId -or $null -eq $Receipt.processStartedAt) { return $false }
    $identity = Get-ProcessIdentity -ProcessId ([int]$Receipt.processId) -ProcessProbe $ProcessProbe
    if (-not $identity.exists -or [string]::IsNullOrWhiteSpace([string]$identity.startedAt)) { return $false }
    try {
        $expected = [DateTime]::Parse([string]$Receipt.processStartedAt).ToUniversalTime()
        $actual = [DateTime]::Parse([string]$identity.startedAt).ToUniversalTime()
        return ([Math]::Abs(($actual - $expected).TotalSeconds) -lt 1.0)
    } catch { return $false }
}
function Read-SharedTextFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true); try { return $reader.ReadToEnd() } finally { $reader.Dispose() } }
    finally { $stream.Dispose() }
}

function Complete-ExecutionArtifactSanitization {
    param([Parameter(Mandatory)]$Receipt)
    $errors = @()
    try {
        $artifactPath = if ($Receipt.PSObject.Properties.Name -contains 'artifactPath' -and $Receipt.artifactPath) {
            [string]$Receipt.artifactPath
        } else { Split-Path -Parent ([string]$Receipt.resultPath) }
        Assert-PathWithinRoot -Path $artifactPath -Root $Script:PendingDir | Out-Null
        $stdoutRaw = if ($Receipt.PSObject.Properties.Name -contains 'rawStdoutPath') { [string]$Receipt.rawStdoutPath } else { $null }
        $stderrRaw = if ($Receipt.PSObject.Properties.Name -contains 'rawStderrPath') { [string]$Receipt.rawStderrPath } else { $null }
        $stdoutSaved = if ($Receipt.PSObject.Properties.Name -contains 'sanitizedStdoutPath' -and $Receipt.sanitizedStdoutPath) { [string]$Receipt.sanitizedStdoutPath } else { Join-Path $artifactPath 'stdout.log' }
        $stderrSaved = if ($Receipt.PSObject.Properties.Name -contains 'sanitizedStderrPath' -and $Receipt.sanitizedStderrPath) { [string]$Receipt.sanitizedStderrPath } else { Join-Path $artifactPath 'stderr.log' }
        foreach ($path in @($stdoutSaved,$stderrSaved)) { Assert-PathWithinRoot -Path $path -Root $artifactPath | Out-Null }
        if ($stdoutRaw) { Assert-PathWithinRoot -Path $stdoutRaw -Root $artifactPath | Out-Null }
        if ($stderrRaw) { Assert-PathWithinRoot -Path $stderrRaw -Root $artifactPath | Out-Null }
        $stdout = if ($stdoutRaw -and (Test-Path -LiteralPath $stdoutRaw)) { Read-SharedTextFile -Path $stdoutRaw } elseif (Test-Path -LiteralPath $stdoutSaved) { Read-SharedTextFile -Path $stdoutSaved } else { '' }
        $stderr = if ($stderrRaw -and (Test-Path -LiteralPath $stderrRaw)) { Read-SharedTextFile -Path $stderrRaw } elseif (Test-Path -LiteralPath $stderrSaved) { Read-SharedTextFile -Path $stderrSaved } else { '' }
        Write-AtomicTextFile -Path $stdoutSaved -Text (Protect-SecretText -Text $stdout)
        Write-AtomicTextFile -Path $stderrSaved -Text (Protect-SecretText -Text $stderr)
        foreach ($raw in @($stdoutRaw,$stderrRaw)) {
            if ($raw -and (Test-Path -LiteralPath $raw)) { Remove-Item -LiteralPath $raw -Force }
        }
        $promptPath = if ($Receipt.PSObject.Properties.Name -contains 'promptPath') { [string]$Receipt.promptPath } else { $null }
        if ($promptPath) {
            Assert-PathWithinRoot -Path $promptPath -Root $artifactPath | Out-Null
            if (Test-Path -LiteralPath $promptPath) { Remove-Item -LiteralPath $promptPath -Force }
        }
        $now = (Get-Date).ToUniversalTime().ToString('o')
        foreach ($item in @(
            @('rawStdoutPath',$null),@('rawStderrPath',$null),@('stdoutPath',$stdoutSaved),@('stderrPath',$stderrSaved),
            @('promptPath',$null),@('promptPresent',$false),@('promptDeletedAt',$now),
            @('artifactSanitizationStatus','completed'),@('artifactSanitizedAt',$now))) {
            Add-Member -InputObject $Receipt -NotePropertyName $item[0] -NotePropertyValue $item[1] -Force
        }
        if ($Receipt.PSObject.Properties.Name -contains 'workerReportedVerification' -and $null -ne $Receipt.workerReportedVerification) {
            $Receipt.workerReportedVerification = Protect-SecretText -Text ([string]$Receipt.workerReportedVerification)
        }
        if ($Receipt.PSObject.Properties.Name -contains 'remainingProblems' -and $null -ne $Receipt.remainingProblems) {
            $Receipt.remainingProblems = @($Receipt.remainingProblems | ForEach-Object { Protect-SecretText -Text ([string]$_) })
        }
        return [pscustomobject]@{ success=$true; receipt=$Receipt; error=$null }
    } catch {
        $safe = Protect-SecretText -Text ([string]$_.Exception.Message)
        Add-Member -InputObject $Receipt -NotePropertyName artifactSanitizationStatus -NotePropertyValue 'failed' -Force
        return [pscustomobject]@{ success=$false; receipt=$Receipt; error=$safe }
    }
}

function Write-ExecutionGenerationMarker {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$Status)
    $artifactPath = if ($Receipt.PSObject.Properties.Name -contains 'artifactPath' -and $Receipt.artifactPath) { [string]$Receipt.artifactPath } else { Split-Path -Parent ([string]$Receipt.resultPath) }
    Assert-PathWithinRoot -Path $artifactPath -Root $Script:PendingDir | Out-Null
    $markerPath = Join-Path $artifactPath 'generation.json'
    Assert-PathWithinRoot -Path $markerPath -Root $artifactPath | Out-Null
    Write-AtomicJsonFile -Path $markerPath -Object ([pscustomobject]@{
        executionId=[string]$Receipt.executionId; generation=[int]$Receipt.generation; status=$Status
        terminal=(-not (Test-ExecutionStatusActive -Status $Status)); updatedAt=(Get-Date).ToUniversalTime().ToString('o')
    })
}

function Remove-ExecutionArtifactDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ArtifactRoot)
    $safePath = Assert-PathWithinRoot -Path $Path -Root $ArtifactRoot
    if ($safePath.Equals([System.IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\','/'), [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove the execution artifact root itself.' }
    if (Test-Path -LiteralPath $safePath) {
        $item = Get-Item -LiteralPath $safePath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to remove reparse-point execution artifact: $safePath" }
        Remove-Item -LiteralPath $safePath -Recurse -Force
    }
}

function Test-ExecutionReceiptNamespaceIdentity {
    param([Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)]$Anchor)
    $candidateProps=@($Candidate.PSObject.Properties.Name);$anchorProps=@($Anchor.PSObject.Properties.Name)
    foreach($field in @('ownerRepo','canonicalRepoRoot','repoRootHash','namespaceVersion')) {
        if($candidateProps -notcontains $field -or $anchorProps -notcontains $field){return $false}
    }
    if(-not ([string]$Candidate.ownerRepo).Equals([string]$Anchor.ownerRepo,[System.StringComparison]::OrdinalIgnoreCase)){return $false}
    if([string]$Candidate.repoRootHash -cne [string]$Anchor.repoRootHash -or [int]$Candidate.namespaceVersion -ne [int]$Anchor.namespaceVersion){return $false}
    try {
        return ((Get-NormalizedCanonicalRepoRoot -Path ([string]$Candidate.canonicalRepoRoot)) -ceq
            (Get-NormalizedCanonicalRepoRoot -Path ([string]$Anchor.canonicalRepoRoot)))
    } catch { return $false }
}

function Invoke-ExecutionRetention {
    param([Parameter(Mandatory)]$Receipt, [int]$RetentionCount = -1)
    $artifactPath = if ($Receipt.PSObject.Properties.Name -contains 'artifactPath' -and $Receipt.artifactPath) { [string]$Receipt.artifactPath } else { Split-Path -Parent ([string]$Receipt.resultPath) }
    $artifactRoot = if ($Receipt.PSObject.Properties.Name -contains 'artifactRoot' -and $Receipt.artifactRoot) { [string]$Receipt.artifactRoot } else { Split-Path -Parent $artifactPath }
    $artifactRoot = Assert-PathWithinRoot -Path $artifactRoot -Root $Script:PendingDir
    $artifactPath = Assert-PathWithinRoot -Path $artifactPath -Root $artifactRoot
    if ($artifactPath.Equals($artifactRoot,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'Current execution receipt points to the artifact root itself.' }
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Container)) { throw 'Current execution receipt artifactPath is missing.' }
    $namespaceRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $artifactRoot)).TrimEnd('\','/')
    Assert-PathWithinRoot -Path $namespaceRoot -Root $Script:PendingDir | Out-Null
    if ((Split-Path -Leaf $artifactRoot) -ne 'executions') { throw "Unexpected execution artifact root: $artifactRoot" }
    if ($Receipt.PSObject.Properties.Name -notcontains 'canonicalRepoRoot' -or [string]::IsNullOrWhiteSpace([string]$Receipt.canonicalRepoRoot) -or
        -not (Test-ReceiptRepoMatch -Receipt $Receipt -RepoPath ([string]$Receipt.canonicalRepoRoot))) { throw 'Current execution receipt repository identity is invalid.' }
    $expectedNamespace = [System.IO.Path]::GetFullPath((Get-PendingNamespacePath -RepoPath ([string]$Receipt.canonicalRepoRoot))).TrimEnd('\','/')
    if (-not $namespaceRoot.Equals($expectedNamespace,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'Execution artifact namespace does not match the receipt repository identity.' }
    if ($RetentionCount -lt 0) {
        $RetentionCount = 10; $cfg = Get-Config
        if ($cfg.PSObject.Properties.Name -contains 'execution' -and $cfg.execution.PSObject.Properties.Name -contains 'executionRetentionCount') { $RetentionCount = [Math]::Max(0, [int]$cfg.execution.executionRetentionCount) }
    }
    if (-not (Test-Path -LiteralPath $artifactRoot)) { return @() }

    # 삭제 전에 namespace의 모든 최신 execution receipt를 완전히 읽고 보호 집합을 확정한다.
    $receiptFiles = @(Get-ChildItem -LiteralPath $namespaceRoot -File -Filter '*-execution.json' | Sort-Object Name)
    $protected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    [void]$protected.Add($artifactPath)
    foreach ($receiptFile in $receiptFiles) {
        $latest = Read-JsonFile -Path $receiptFile.FullName
        if (-not (Test-ExecutionReceiptNamespaceIdentity -Candidate $latest -Anchor $Receipt)) { throw "Execution receipt repository identity mismatch: $($receiptFile.Name)" }
        if ($latest.PSObject.Properties.Name -notcontains 'artifactPath' -or [string]::IsNullOrWhiteSpace([string]$latest.artifactPath)) { throw "Execution receipt artifactPath is missing: $($receiptFile.Name)" }
        $referenced = Assert-PathWithinRoot -Path ([string]$latest.artifactPath) -Root $artifactRoot
        if ($referenced.Equals($artifactRoot,[System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $referenced -PathType Container)) { throw "Execution receipt artifactPath is invalid or missing: $($receiptFile.Name)" }
        [void]$protected.Add($referenced)
    }

    # marker가 없거나 불완전하거나 active/reparse-point인 디렉터리는 삭제 후보가 아니다.
    $unreferencedTerminal = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath $artifactRoot -Directory)) {
        $dirPath = [System.IO.Path]::GetFullPath($dir.FullName).TrimEnd('\','/')
        if (-not ([System.IO.Path]::GetFullPath((Split-Path -Parent $dirPath)).TrimEnd('\','/')).Equals($artifactRoot,[System.StringComparison]::OrdinalIgnoreCase)) { throw "Execution artifact is not a direct child: $dirPath" }
        if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $protected.Contains($dirPath)) { continue }
        $markerPath = Join-Path $dir.FullName 'generation.json'
        if (-not (Test-Path -LiteralPath $markerPath)) { continue }
        try {
            $marker = Read-JsonFile -Path $markerPath
            $markerProps=@($marker.PSObject.Properties.Name)
            if ($markerProps -notcontains 'terminal' -or $markerProps -notcontains 'updatedAt' -or -not [bool]$marker.terminal) { continue }
            $updated=[DateTime]::Parse([string]$marker.updatedAt).ToUniversalTime()
            $unreferencedTerminal += [pscustomobject]@{ Directory=$dir; Path=$dirPath; UpdatedAt=$updated }
        } catch { continue }
    }

    # count는 보호되지 않은 terminal generation에만 적용한다. 모든 후보를 검증한 뒤 삭제를 시작한다.
    $ordered = @($unreferencedTerminal | Sort-Object -Property @{Expression='UpdatedAt';Descending=$true},@{Expression='Path';Descending=$false})
    $deletePlan = @($ordered | Select-Object -Skip $RetentionCount)
    foreach ($entry in $deletePlan) {
        Assert-PathWithinRoot -Path $entry.Path -Root $artifactRoot | Out-Null
        if ($protected.Contains($entry.Path) -or ($entry.Directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unsafe execution retention candidate: $($entry.Path)" }
        $marker = Read-JsonFile -Path (Join-Path $entry.Path 'generation.json')
        if ($marker.PSObject.Properties.Name -notcontains 'terminal' -or -not [bool]$marker.terminal) { throw "Execution retention candidate is not terminal: $($entry.Path)" }
    }
    $removed = @()
    foreach ($entry in $deletePlan) {
        Remove-ExecutionArtifactDirectory -Path $entry.Path -ArtifactRoot $artifactRoot
        $removed += $entry.Path
    }

    # 삭제 뒤에도 모든 최신 receipt가 가리키는 generation이 존재하는지 다시 읽어 검증한다.
    foreach ($receiptFile in @(Get-ChildItem -LiteralPath $namespaceRoot -File -Filter '*-execution.json' | Sort-Object Name)) {
        $latest = Read-JsonFile -Path $receiptFile.FullName
        if (-not (Test-ExecutionReceiptNamespaceIdentity -Candidate $latest -Anchor $Receipt) -or
            $latest.PSObject.Properties.Name -notcontains 'artifactPath' -or [string]::IsNullOrWhiteSpace([string]$latest.artifactPath)) { throw "Execution receipt post-retention validation failed: $($receiptFile.Name)" }
        $referenced = Assert-PathWithinRoot -Path ([string]$latest.artifactPath) -Root $artifactRoot
        if (-not (Test-Path -LiteralPath $referenced -PathType Container)) { throw "Execution receipt generation was lost during retention: $($receiptFile.Name)" }
    }
    return $removed
}

function Complete-ExecutionTerminalArtifacts {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$IntendedStatus)
    $Receipt.status = $IntendedStatus
    $sanitized = Complete-ExecutionArtifactSanitization -Receipt $Receipt
    $Receipt = $sanitized.receipt
    if (-not $sanitized.success) {
        $Receipt.status = 'artifact_sanitization_failed'
        $Receipt.remainingProblems = @($Receipt.remainingProblems) + @('execution artifact sanitization failed: ' + [string]$sanitized.error)
    }
    Write-ExecutionGenerationMarker -Receipt $Receipt -Status ([string]$Receipt.status)
    try {
        Invoke-ExecutionRetention -Receipt $Receipt | Out-Null
        Add-Member -InputObject $Receipt -NotePropertyName artifactRetentionStatus -NotePropertyValue 'completed' -Force
        Add-Member -InputObject $Receipt -NotePropertyName artifactRetentionCompletedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    } catch {
        $underlying = [string]$Receipt.status
        $Receipt.status = 'artifact_retention_failed'
        Add-Member -InputObject $Receipt -NotePropertyName artifactRetentionStatus -NotePropertyValue 'failed' -Force
        Add-Member -InputObject $Receipt -NotePropertyName artifactFinalizationUnderlyingStatus -NotePropertyValue $underlying -Force
        $Receipt.remainingProblems = @($Receipt.remainingProblems) + @('execution retention failed: ' + (Protect-SecretText -Text ([string]$_.Exception.Message)))
        Write-ExecutionGenerationMarker -Receipt $Receipt -Status ([string]$Receipt.status)
    }
    Save-ExecutionReceipt -Receipt $Receipt -RepoPath $RepoPath | Out-Null
    return $Receipt
}

# ---------- claude-only 2단계용 pending 상태 (state/pending/<namespace>) ----------
function Get-PendingKey {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber)
    return "op$Operation-issue$IssueNumber"
}
function Get-PendingSnapshotPath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $key = Get-PendingKey -Operation $Operation -IssueNumber $IssueNumber
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "$key.json")
}
function Get-PendingOrderPath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $key = Get-PendingKey -Operation $Operation -IssueNumber $IssueNumber
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "order-$key.txt")
}
function Get-ClaudeCompletionReportPath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $key = Get-PendingKey -Operation $Operation -IssueNumber $IssueNumber
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "claude-report-$key.json")
}
function Read-ClaudeCompletionReport {
    param(
        [Parameter(Mandatory)][int]$Operation,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$ExpectedHead,
        [Parameter(Mandatory)][string]$ExpectedWorkBranch,
        [string]$ReportPath
    )
    $expectedPath=Get-ClaudeCompletionReportPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $expectedFull=[System.IO.Path]::GetFullPath($expectedPath)
    $selected=if ([string]::IsNullOrWhiteSpace($ReportPath)) { $expectedFull } else { [System.IO.Path]::GetFullPath($ReportPath) }
    Assert-PathWithinRoot -Path $selected -Root $Script:PendingDir | Out-Null
    if (-not $selected.Equals($expectedFull,[System.StringComparison]::OrdinalIgnoreCase)) {
        return (ConvertFrom-ClaudeCompletionReport -Json '' -ExpectedOperation $Operation -ExpectedIssueNumber $IssueNumber `
            -ExpectedHead $ExpectedHead -ExpectedWorkBranch $ExpectedWorkBranch)
    }
    if (-not (Test-Path -LiteralPath $selected -PathType Leaf)) {
        return (ConvertFrom-ClaudeCompletionReport -Json '' -ExpectedOperation $Operation -ExpectedIssueNumber $IssueNumber `
            -ExpectedHead $ExpectedHead -ExpectedWorkBranch $ExpectedWorkBranch)
    }
    try { $json=Get-Content -LiteralPath $selected -Raw -Encoding UTF8 -ErrorAction Stop }
    catch { $json='' }
    return (ConvertFrom-ClaudeCompletionReport -Json $json -ExpectedOperation $Operation -ExpectedIssueNumber $IssueNumber `
        -ExpectedHead $ExpectedHead -ExpectedWorkBranch $ExpectedWorkBranch)
}
function Save-PendingSnapshot {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)]$Snapshot,
          [Parameter(Mandatory)][string]$RepoPath, [string]$Kind = 'logic', [AllowNull()]$Workflow)
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $path = Get-PendingSnapshotPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    $payload = [pscustomobject]@{
        schemaVersion = if($null -ne $Workflow){2}else{1}
        operation = $Operation; issueNumber = $IssueNumber; kind = $Kind
        ownerRepo = $id.ownerRepo; repoRoot = $id.repoRoot; canonicalRepoRoot = $id.canonicalRepoRoot
        repoRootHash = $id.repoRootHash; namespaceVersion = $id.namespaceVersion
        snapshot = $Snapshot; savedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($null -ne $Workflow) { Add-Member -InputObject $payload -NotePropertyName workflow -NotePropertyValue (Copy-WorkflowContext -Workflow $Workflow) -Force }
    Write-JsonFile -Path $path -Object $payload
    return $path
}
function Get-PendingSnapshot {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $path = Get-PendingSnapshotPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $legacyPath = Join-Path (Get-LegacyPendingNamespacePath -RepoPath $RepoPath) "$(Get-PendingKey -Operation $Operation -IssueNumber $IssueNumber).json"
    $receipt = Get-ReceiptWithLegacyMigration -CurrentPath $path -LegacyPath $legacyPath -RepoPath $RepoPath
    if ($null -ne $receipt -and -not ($receipt.PSObject.Properties.Name -contains 'legacyNamespaceBlocked')) {
        $legacyOrder = Join-Path (Get-LegacyPendingNamespacePath -RepoPath $RepoPath) "order-$(Get-PendingKey -Operation $Operation -IssueNumber $IssueNumber).txt"
        $currentOrder = Get-PendingOrderPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
        if (-not (Test-Path -LiteralPath $currentOrder) -and (Test-Path -LiteralPath $legacyOrder)) {
            Assert-PathWithinRoot -Path $legacyOrder -Root $Script:PendingDir | Out-Null
            Assert-PathWithinRoot -Path $currentOrder -Root $Script:PendingDir | Out-Null
            [System.IO.File]::WriteAllBytes($currentOrder, [System.IO.File]::ReadAllBytes($legacyOrder))
            if ((Get-FileHash -LiteralPath $currentOrder -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $legacyOrder -Algorithm SHA256).Hash) { throw 'Legacy pending order migration verification failed.' }
            Remove-Item -LiteralPath $legacyOrder -Force
        }
    }
    return $receipt
}
function Remove-PendingSnapshot {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $path = Get-PendingSnapshotPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

# ---------- 작전 1 실행 영수증 (v2.2: run/review 자동 저장, review/repair가 자동 복원) ----------
# run 영수증: 작전 1 run이 워커 postflight까지 도달하면 저장. review가 -StartHead 수동 입력 없이 읽는다.
# review 영수증: verdict=REPAIR_REQUIRED일 때 findings/postReviewHead/originalWorker를 저장. repair가 읽는다.
function Get-RunReceiptPath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "op$Operation-issue$IssueNumber-run.json")
}
function Save-RunReceipt {
    param(
        [Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Postflight,
        [Parameter(Mandatory)]$Route, $WorkerResult, $RemainingProblems = @(),
        [string]$StatusOverride, [bool]$ResultEnvelopePresent = $false,
        [bool]$Interrupted = $true, [string]$InterruptedReason,
        [bool]$LocalVerificationComplete = $false, [bool]$RecoveredByPostflight = $false,
        [string]$VerificationProvenance = 'unknown', [AllowNull()]$Workflow,
        [string]$ArtifactSanitizationStatus = 'unknown', [string]$ArtifactRetentionStatus = 'unknown'
    )
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $path = Get-RunReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    # workerSummary는 작업자 출력의 마스킹·절단본이다. 라우터가 재실행한 테스트 결과가 아니다.
    $summary = ''
    if ($null -ne $WorkerResult -and ($WorkerResult.PSObject.Properties.Name -contains 'Output') -and $null -ne $WorkerResult.Output) {
        $summary = Protect-SecretText -Text ([string]$WorkerResult.Output)
        if ($summary.Length -gt 4000) { $summary = $summary.Substring(0, 4000) + "`n...[workerSummary truncated at 4000 chars]..." }
    }
    $effort = $null
    if ($Route.PSObject.Properties.Name -contains 'effort') { $effort = $Route.effort }
    $reportedVerification = $null
    if ($null -ne $WorkerResult -and ($WorkerResult.PSObject.Properties.Name -contains 'WorkerReportedVerification') -and $null -ne $WorkerResult.WorkerReportedVerification) {
        $reportedVerification = Protect-SecretText -Text ([string]$WorkerResult.WorkerReportedVerification)
    }
    $workerRemaining=@()
    if($null -ne $WorkerResult -and $WorkerResult.PSObject.Properties.Name -contains 'WorkerRemainingProblems'){
        $workerRemaining=@($WorkerResult.WorkerRemainingProblems|ForEach-Object{Protect-SecretText -Text ([string]$_)})
    }
    $payload = [pscustomobject]@{
        schemaVersion = if($null -ne $Workflow){2}else{1}
        operation   = $Operation
        issueNumber = $IssueNumber
        ownerRepo   = $id.ownerRepo
        repoRoot    = $id.repoRoot
        canonicalRepoRoot = $id.canonicalRepoRoot
        repoRootHash = $id.repoRootHash
        namespaceVersion = $id.namespaceVersion
        startHead   = $Snapshot.startHead
        finalHead   = $Postflight.finalHead
        worker      = $Route.worker
        model       = $Route.model
        effort      = $effort
        status      = if (-not [string]::IsNullOrEmpty($StatusOverride)) { $StatusOverride } else { $Postflight.status }
        postflight  = $Postflight
        remainingProblems = @($RemainingProblems)
        workerSummary = $summary
        resultEnvelopePresent = [bool]$ResultEnvelopePresent
        interrupted = [bool]$Interrupted
        interruptedReason = $InterruptedReason
        localVerificationComplete = [bool]$LocalVerificationComplete
        workerReportedVerification = $reportedVerification
        workerRemainingProblems = @($workerRemaining)
        recoveredByPostflight = [bool]$RecoveredByPostflight
        verificationProvenance = $VerificationProvenance
        artifactSanitizationStatus = $ArtifactSanitizationStatus
        artifactRetentionStatus = $ArtifactRetentionStatus
        createdAt   = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($null -ne $Workflow) { Add-Member -InputObject $payload -NotePropertyName workflow -NotePropertyValue (Copy-WorkflowContext -Workflow $Workflow) -Force }
    Write-JsonFile -Path $path -Object $payload
    return $path
}
function Get-RunReceipt {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $path = Get-RunReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $legacyPath = Join-Path (Get-LegacyPendingNamespacePath -RepoPath $RepoPath) "op$Operation-issue$IssueNumber-run.json"
    return (Get-ReceiptWithLegacyMigration -CurrentPath $path -LegacyPath $legacyPath -RepoPath $RepoPath)
}
function Test-RunReceiptVerificationEligible {
    param([AllowNull()]$Receipt, [Parameter(Mandatory)][string]$RepoPath)
    $fail = {
        param([string]$Status, [string]$Reason, [string]$Note)
        return [pscustomobject]@{ eligible=$false; status=$Status; reason=$Reason; note=$Note }
    }
    if ($null -eq $Receipt) {
        return (& $fail 'run_receipt_missing' 'run_receipt_missing' 'run 영수증이 없어 검증 자격을 확인할 수 없다.')
    }
    if (-not (Test-ReceiptRepoMatch -Receipt $Receipt -RepoPath $RepoPath)) {
        return (& $fail 'run_receipt_repository_mismatch' 'run_receipt_repository_mismatch' '현재 저장소와 run 영수증의 저장소가 다르다.')
    }
    $props = @($Receipt.PSObject.Properties.Name)
    foreach ($required in @('operation','worker','status','finalHead','resultEnvelopePresent','interrupted','verificationProvenance')) {
        if ($props -notcontains $required) {
            return (& $fail 'run_result_unverified' 'run_result_unverified' "run 영수증에 필수 provenance 필드가 없다: $required")
        }
    }
    if ([int]$Receipt.operation -ne 1) {
        return (& $fail 'run_not_eligible' 'run_operation_not_1' '작전 1 run 영수증만 review와 repair 자격이 있다.')
    }
    if ([string]$Receipt.worker -ne 'grok') {
        return (& $fail 'run_not_eligible' ("worker_not_grok:" + [string]$Receipt.worker) 'Grok이 구현한 작전 1 run만 독립 review와 repair 자격이 있다.')
    }
    $resealed=([string]$Receipt.verificationProvenance -eq 'explicit_external_head_reseal')
    if($resealed -and (
        $props -notcontains 'externalCommitsIncluded' -or -not [bool]$Receipt.externalCommitsIncluded -or
        $props -notcontains 'resultEnvelopeCoversFinalHead' -or [bool]$Receipt.resultEnvelopeCoversFinalHead -or
        $props -notcontains 'resealHistory' -or @($Receipt.resealHistory).Count -eq 0)){
        return (& $fail 'run_result_unverified' 'reseal_evidence_incomplete' '외부 커밋 재봉인 증거가 불완전하다.')
    }
    if (-not [bool]$Receipt.resultEnvelopePresent -or [bool]$Receipt.interrupted -or
        [string]$Receipt.verificationProvenance -notin @(
            'valid_worker_result_envelope','valid_worker_result_envelope_recovered_postflight',
            'explicit_external_head_reseal')) {
        return (& $fail 'run_result_unverified' 'run_result_unverified' '정상 worker result envelope와 검증 provenance가 확인되지 않았다.')
    }
    $workflow = Get-ReceiptWorkflowContext -Receipt $Receipt
    $eligibleStatuses = if ([string]$workflow.mode -eq 'pull-request') {
        @('pr_opened','pr_ci_pending','pr_ci_unavailable')
    } else {
        @('completed','completed_ci_pending','completed_ci_unavailable')
    }
    if ([string]$Receipt.status -notin $eligibleStatuses) {
        return (& $fail 'run_status_not_completed' ("run_not_completed:" + [string]$Receipt.status) '정상 완료 상태가 아닌 run은 review와 repair 자격이 없다.')
    }
    return [pscustomobject]@{
        eligible=$true; status='eligible'; reason=$null; note='verified run receipt'
        receipt=$Receipt; verificationProvenance=[string]$Receipt.verificationProvenance
    }
}
function Remove-RunReceipt {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $path = Get-RunReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-ReviewReceiptPath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "op$Operation-issue$IssueNumber-review.json")
}
function Save-ReviewReceipt {
    param(
        [Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Verdict, [Parameter(Mandatory)]$Findings,
        [Parameter(Mandatory)][string]$PostReviewHead, [Parameter(Mandatory)][string]$OriginalWorker,
        [AllowNull()]$Workflow, $ChangedFiles=@(), $ReviewedFiles=@(), $TruncatedFiles=@(),
        [string]$ReviewStatus='reviewed', [System.Nullable[bool]]$CoverageCompleteOverride=$null
    )
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $path = Get-ReviewReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    $payload = [pscustomobject]@{
        schemaVersion  = if($null -ne $Workflow){2}else{1}
        operation      = $Operation
        issueNumber    = $IssueNumber
        ownerRepo      = $id.ownerRepo
        repoRoot       = $id.repoRoot
        canonicalRepoRoot = $id.canonicalRepoRoot
        repoRootHash   = $id.repoRootHash
        namespaceVersion = $id.namespaceVersion
        verdict        = $Verdict
        findings       = @($Findings)
        postReviewHead = $PostReviewHead
        originalWorker = $OriginalWorker
        changedFiles    = @($ChangedFiles)
        reviewedFiles   = @($ReviewedFiles)
        truncatedFiles  = @($TruncatedFiles)
        coverageComplete = if($null -ne $CoverageCompleteOverride){[bool]$CoverageCompleteOverride}else{
            (@($TruncatedFiles).Count -eq 0 -and
             @($ChangedFiles | Where-Object { @($ReviewedFiles) -notcontains $_ }).Count -eq 0)
        }
        reviewStatus    = $ReviewStatus
        createdAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($null -ne $Workflow) { Add-Member -InputObject $payload -NotePropertyName workflow -NotePropertyValue (Copy-WorkflowContext -Workflow $Workflow) -Force }
    Write-JsonFile -Path $path -Object $payload
    return $path
}
function Get-ReviewReceipt {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $path = Get-ReviewReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $legacyPath = Join-Path (Get-LegacyPendingNamespacePath -RepoPath $RepoPath) "op$Operation-issue$IssueNumber-review.json"
    return (Get-ReceiptWithLegacyMigration -CurrentPath $path -LegacyPath $legacyPath -RepoPath $RepoPath)
}
function Remove-ReviewReceipt {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $path = Get-ReviewReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-RepairReceiptPath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "op$Operation-issue$IssueNumber-repair.json")
}
function Get-RepairResultEnvelopePath {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "op$Operation-issue$IssueNumber-repair-result.json")
}
function Save-RepairReceipt {
    param(
        [Parameter(Mandatory)][int]$Operation,[Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath,[Parameter(Mandatory)]$RunReceipt,
        [Parameter(Mandatory)]$Postflight,[Parameter(Mandatory)]$Route,
        [Parameter(Mandatory)][string]$Status,[Parameter(Mandatory)]$Workflow,
        [AllowNull()]$WorkerResult
    )
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $id=Get-RepoIdentity -RepoPath $RepoPath
    $path=Get-RepairReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $resultPath=Get-RepairResultEnvelopePath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    Assert-PathWithinRoot -Path $resultPath -Root $Script:PendingDir | Out-Null
    $previous=Get-RepairReceipt -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $generation=1
    if($null -ne $previous -and $previous.PSObject.Properties.Name -contains 'generation'){
        $generation=[int]$previous.generation+1
    }
    $executionId=[guid]::NewGuid().ToString('N')
    $repairRemaining=@()
    if($null -ne $WorkerResult -and $WorkerResult.PSObject.Properties.Name -contains 'WorkerRemainingProblems'){
        $repairRemaining=@($WorkerResult.WorkerRemainingProblems)
    }
    $localVerificationComplete=($null -ne $WorkerResult -and $WorkerResult.PSObject.Properties.Name -contains 'LocalVerificationComplete' -and [bool]$WorkerResult.LocalVerificationComplete)
    $workerReportedVerification=if($null -ne $WorkerResult -and $WorkerResult.PSObject.Properties.Name -contains 'WorkerReportedVerification'){
        Protect-SecretText -Text ([string]$WorkerResult.WorkerReportedVerification)
    }else{$null}
    $exitCode=if($null -ne $WorkerResult -and $WorkerResult.PSObject.Properties.Name -contains 'ExitCode'){[int]$WorkerResult.ExitCode}else{0}
    $success=($status -in @('repair_completed_review_pending','repair_pr_ci_pending','repair_pr_ci_failed','repair_pr_ci_unavailable'))
    $workerReportValid=($localVerificationComplete -and -not [string]::IsNullOrWhiteSpace([string]$workerReportedVerification) -and $repairRemaining.Count -eq 0)
    $completedAt=(Get-Date).ToUniversalTime().ToString('o')
    $envelope=[pscustomobject]@{
        schemaVersion=1;executionId=$executionId;generation=$generation;operation=$Operation;issueNumber=$IssueNumber
        ownerRepo=$id.ownerRepo;repoRootHash=$id.repoRootHash;purpose='repair';worker=$Route.worker
        exitCode=$exitCode;success=[bool]$success;finalHead=$Postflight.finalHead
        workerReportedVerification=$workerReportedVerification;localVerificationComplete=[bool]$localVerificationComplete
        workerRemainingProblems=@($repairRemaining);workerReportValid=[bool]$workerReportValid;completedAt=$completedAt
    }
    Write-AtomicJsonFile -Path $resultPath -Object $envelope
    $payload=[pscustomobject]@{
        schemaVersion=2;operation=$Operation;issueNumber=$IssueNumber;ownerRepo=$id.ownerRepo
        repoRoot=$id.repoRoot;canonicalRepoRoot=$id.canonicalRepoRoot;repoRootHash=$id.repoRootHash
        namespaceVersion=$id.namespaceVersion;startHead=$RunReceipt.startHead;repairStartHead=$Postflight.startHead
        executionId=$executionId;generation=$generation;purpose='repair';resultPath=$resultPath;invocationReceiptPath=$null
        finalHead=$Postflight.finalHead;worker=$Route.worker;model=$Route.model;effort=$Route.effort
        status=$Status;postflight=$Postflight;workflow=(Copy-WorkflowContext -Workflow $Workflow)
        finalReviewRequired=$true;reviewVerdict=$null
        resultEnvelopePresent=$true;interrupted=$false
        localVerificationComplete=[bool]$localVerificationComplete
        workerReportedVerification=$workerReportedVerification;workerReportValid=[bool]$workerReportValid
        remainingProblems=@($repairRemaining);workerRemainingProblems=@($repairRemaining)
        verificationProvenance='valid_repair_worker_result'
        artifactSanitizationStatus='not-applicable';artifactRetentionStatus='not-applicable'
        createdAt=$completedAt
    }
    Write-JsonFile -Path $path -Object $payload
    return $path
}
function Get-RepairReceipt {
    param([Parameter(Mandatory)][int]$Operation,[Parameter(Mandatory)][int]$IssueNumber,[Parameter(Mandatory)][string]$RepoPath)
    $path=Get-RepairReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    if(-not (Test-Path -LiteralPath $path)){return $null}
    try{return Read-JsonFileStable -Path $path -MaxAttempts 3 -DelayMilliseconds 25}catch{return $null}
}
function Remove-RepairReceipt {
    param([Parameter(Mandatory)][int]$Operation,[Parameter(Mandatory)][int]$IssueNumber,[Parameter(Mandatory)][string]$RepoPath)
    $path=Get-RepairReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
}

# ---------- 고정 실행 계약 ----------
function Get-FixedExecutionContract {
    param([AllowNull()]$Workflow)
    $orderSourceKind='issue-body'
    if($null -ne $Workflow -and $Workflow.PSObject.Properties.Name -contains 'orderSource' -and
        $null -ne $Workflow.orderSource -and $Workflow.orderSource.PSObject.Properties.Name -contains 'kind'){
        $orderSourceKind=[string]$Workflow.orderSource.kind
    }
    if ($null -ne $Workflow -and [string]$Workflow.mode -eq 'pull-request') {
        return @"
[OPERATION_ROUTER_FINAL_WORKER]
You are the final worker already selected by operation-router.
Do not apply any global Operation 1/2/3 delegation rule in this marked session.
Do not invoke, inspect, preflight, or delegate to Grok, Codex, Claude, or any other worker CLI.
Implement the recorded order below directly. The recorded order is the sole task canon.

[역할 지정 — 최우선으로 적용]
너는 operation-router가 호출한 최종 작업자다. 다른 모델이나 CLI에 재위임하지 않는다.

[고정 실행 계약 — pull-request]
- workflow mode: pull-request
- base branch: $($Workflow.baseBranch)
- base head: $($Workflow.baseHead)
- expected branch: $($Workflow.workBranch)
- expected remote branch: $($Workflow.remoteWorkBranch)
- issue number: $($Workflow.issueNumber)
- 현재 expected branch에서만 작업한다.
- branch를 생성·변경·삭제하지 않는다.
- main으로 checkout하거나 main에 push하지 않는다.
- configured base branch($($Workflow.baseBranch))로 checkout하거나 그 branch에 push하지 않는다.
- $($Workflow.remoteWorkBranch)에만 push하고 upstream을 그 원격 브랜치로 설정한다.
- PR과 이슈를 생성·수정·댓글·종료·병합하지 않는다.
- force push, reset, clean, rebase를 하지 않는다.
- 작업 시작 전 worktree가 clean이어야 한다.
- 기록된 주문 원문 범위를 확장하지 않는다.
- 의미 단위별로 테스트하고 커밋한다.
- 테스트 실패를 숨기지 않는다.
- secret과 환경변수 값을 출력하거나 커밋하지 않는다.
- 완료 시 변경 파일, 테스트, 커밋, push, 남은 문제만 짧게 보고한다.
- 마지막 줄은 반드시 [ORH_WORKER_REPORT] {"localVerificationComplete":true,"verification":"실행한 검증 요약","remainingProblems":[]} 형식의 한 줄 JSON이다. 검증을 실제로 완료하지 못했으면 localVerificationComplete를 false로, 남은 문제가 있으면 문자열 배열로 보고한다.

[아래는 기록된 주문 원문 (source=$orderSourceKind) — 요약·재작성·삭제하지 않는다]
"@
    }
    return @"
[OPERATION_ROUTER_FINAL_WORKER]
You are the final worker already selected by operation-router.
Do not apply any global Operation 1/2/3 delegation rule in this marked session.
Do not invoke, inspect, preflight, or delegate to Grok, Codex, Claude, or any other worker CLI.
Implement the recorded order below directly. The recorded order is the sole task canon.

[역할 지정 — 최우선으로 적용]
너는 operation-router가 호출한 "작업자(worker) CLI"이며, 이 주문은 지휘 세션이 너에게 이미 위임한 최종 실행 지시다.
전역 AGENTS.md/CLAUDE.md의 Operation Modes 규칙에서 "Grok CLI에 위임"하는 주체는 지휘자(Claude 세션)이고, 너는 그 위임을 받은 실행자다.
전역 규칙이 명시하듯 아래 기록된 주문이 유일한 task canon이다. 따라서 너는 다른 CLI(grok, codex, claude 등)를 호출하거나 재위임하지 않고 아래 범위를 직접 구현한다.
다른 CLI에 위임하지 말고 직접 구현한다.

[고정 실행 계약 — 작업자는 이 규칙을 반드시 지킨다]
- 현재 main 브랜치에서만 작업한다.
- branch와 PR을 만들지 않는다.
- 강제 push, git reset --hard, git clean -fd를 금지한다.
- 작업 시작 전 worktree가 clean이어야 한다.
- 주문서 범위 밖으로 확장하지 않는다.
- 의미 단위별로 테스트를 포함해 커밋하고 즉시 origin/main에 push한다.
- 이슈 생성·수정·댓글·종료를 하지 않는다.
- secret과 환경변수 값을 출력하거나 커밋하지 않는다.
- 테스트 실패를 숨기지 않는다.
- 커밋 메시지는 git commit -m "..." 한 줄 인라인으로만 작성한다. `$(...) 명령 치환, heredoc(<<), 여러 줄 셸 명령을 쓰지 않는다 (헤드리스 권한 정책이 이런 명령을 차단한다).
- 완료 시 변경 파일, 테스트, 커밋, push, 남은 문제만 짧게 보고한다.

[아래는 기록된 주문 원문 (source=$orderSourceKind) — 요약·재작성·삭제하지 않는다]
"@
}
# 계약 + 기록된 주문 원문(무손실). 주문 내용은 변형하지 않는다.
function New-OrderContent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$IssueBody, [AllowNull()]$Workflow)
    $contract = Get-FixedExecutionContract -Workflow $Workflow
    return ($contract + "`n" + $IssueBody)
}

function New-TempOrderFile {
    param([Parameter(Mandatory)][string]$Content)
    Initialize-RuntimeDirs
    $name = 'order-' + [guid]::NewGuid().ToString('N') + '.txt'
    $path = Join-Path $Script:TempDir $name
    Assert-PathWithinRoot -Path $path -Root $Script:TempDir | Out-Null
    [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}
function Remove-TempOrderFile {
    param([Parameter(Mandatory)][string]$Path)
    Assert-PathWithinRoot -Path $Path -Root $Script:TempDir | Out-Null
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}

# 전경 자식 프로세스 1회 실행 (백그라운드/nohup 금지)
# v2.3.3: StdinFilePath가 없으면 stdin을 호출 환경에서 상속하지 않고 NUL 장치에 고정한다.
#         grok 0.2.102 헤드리스는 stdin이 파이프 EOF(예: Git Bash /dev/null 상속)면 실행 중이던 도구 호출을
#         "User cancelled"로 오인해 stopReason=Cancelled로 중단한다 (2026-07-20 op3-issue2 E2E에서 재현·확인).
#         NUL 고정은 임시 .cmd 래퍼(`< NUL`)로만 가능하다 — Start-Process -RedirectStandardInput은 장치 경로를 거부한다.
function Invoke-ForegroundCommand {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$ArgumentList, [string]$StdinFilePath)
    $ErrorActionPreference = 'Continue'
    if ($StdinFilePath) {
        # v2.3.5: PS 5.1 파이프라인(`$content | & exe`)은 콘솔 CP 65001에서 네이티브 stdin 선두에
        # UTF-8 BOM(EF BB BF)을 삽입한다 ($OutputEncoding과 무관, 2026-07-21 바이트 실측). BOM이 붙으면
        # 작업자 계약 첫 바이트가 [OPERATION_ROUTER_FINAL_WORKER] 마커가 아니게 된다.
        # System.Diagnostics.Process로 파일의 원시 UTF-8 바이트(파일 BOM은 제거)를 직접 기록하고,
        # 기록 후 stdin을 명시적으로 닫아 EOF를 보장한다. stdout/stderr/exit code는 각각 수집한다.
        $stdinBytes = [System.IO.File]::ReadAllBytes($StdinFilePath)
        $stdinOffset = 0
        if ($stdinBytes.Length -ge 3 -and $stdinBytes[0] -eq 0xEF -and $stdinBytes[1] -eq 0xBB -and $stdinBytes[2] -eq 0xBF) { $stdinOffset = 3 }
        $resolvedStdin = $FilePath
        # npm shim은 codex.ps1/codex.cmd/codex 3종을 만들고 Get-Command 단건은 .ps1을 먼저 반환한다.
        # Process.Start는 .ps1이나 확장자 없는 sh 스크립트를 실행하지 못하므로 Application(.exe/.cmd/.bat)을 우선 선택한다.
        $foundStdin = Get-Command $FilePath -All -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -and ($_.Source -match '\.(exe|cmd|bat)$') } |
            Select-Object -First 1
        if ($foundStdin) { $resolvedStdin = $foundStdin.Source }
        $escapedArgs = foreach ($a in $ArgumentList) {
            $s = [string]$a
            if ($s.Length -eq 0 -or $s -match '[\s"]') {
                '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
            } else { $s }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $resolvedStdin
        $psi.Arguments = ($escapedArgs -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.WorkingDirectory = (Get-Location).ProviderPath
        # .NET Framework Process.Start는 stdin StreamWriter를 Console.InputEncoding으로 만들고
        # AutoFlush 설정 시 프리앰블을 즉시 기록한다. 콘솔이 CP 65001이면 BOM 3바이트가 자식 stdin에
        # 먼저 들어가므로, Start 전후로 InputEncoding을 BOM 없는 UTF-8로 교체·원복한다.
        $prevInputEncoding = $null
        try { $prevInputEncoding = [Console]::InputEncoding } catch {}
        try {
            try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
            $proc = [System.Diagnostics.Process]::Start($psi)
        } finally {
            if ($null -ne $prevInputEncoding) { try { [Console]::InputEncoding = $prevInputEncoding } catch {} }
        }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        try {
            $proc.StandardInput.BaseStream.Write($stdinBytes, $stdinOffset, $stdinBytes.Length - $stdinOffset)
            $proc.StandardInput.BaseStream.Flush()
        } catch [System.IO.IOException] {
            # 자식이 stdin을 읽기 전에 종료한 경우 — 종료코드와 stderr로 실패가 드러난다.
        } finally {
            $proc.StandardInput.Close()
        }
        $proc.WaitForExit()
        $stdoutText = $outTask.Result
        $stderrText = $errTask.Result
        $combined = $stdoutText
        if (-not [string]::IsNullOrEmpty($stderrText)) { $combined = $combined + $stderrText }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $combined; StdOut = $stdoutText; StdErr = $stderrText }
    }
    $resolved = $FilePath
    $found = Get-Command $FilePath -ErrorAction SilentlyContinue
    if ($found -and $found.Source -and ($found.Source -match '\.(exe|cmd|bat)$')) { $resolved = $found.Source }
    $cmdLine = '@"' + $resolved + '" ' + (($ArgumentList | ForEach-Object { '"' + ([string]$_ -replace '%', '%%') + '"' }) -join ' ') + ' < NUL'
    $hasNonAscii = $false
    foreach ($ch in $cmdLine.ToCharArray()) { if ([int]$ch -gt 127) { $hasNonAscii = $true; break } }
    if ($hasNonAscii) {
        # v2.3.5-p1: 비ASCII 명령줄에서도 stdin NUL 고정을 유지한다. cmd 배치 본문은 OEM 코드페이지로
        # 읽혀 비ASCII가 깨지므로, 비ASCII 문자열은 배치에 직접 쓰지 않고 유니코드 환경변수 참조("%VAR%")로
        # 전달한다 (cmd 변수 확장은 유니코드를 보존한다). 이전의 상속 실행 폴백은 < NUL이 없어
        # grok 헤드리스가 파이프 EOF를 User cancelled로 오인하는 경로였다.
        Initialize-RuntimeDirs
        $wrapperPath = Join-Path $Script:TempDir ('fg-' + [guid]::NewGuid().ToString('N') + '.cmd')
        $envNames = @('OR_FG_EXE')
        $parts = @('@"%OR_FG_EXE%"')
        for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
            $envNames += ('OR_FG_ARG' + $i)
            $parts += ('"%OR_FG_ARG' + $i + '%"')
        }
        try {
            Set-Item -Path 'env:OR_FG_EXE' -Value $resolved
            for ($i = 0; $i -lt $ArgumentList.Count; $i++) { Set-Item -Path ('env:OR_FG_ARG' + $i) -Value ([string]$ArgumentList[$i]) }
            Set-Content -LiteralPath $wrapperPath -Value (($parts -join ' ') + ' < NUL') -Encoding Ascii
            $output = & cmd.exe /d /c $wrapperPath 2>&1
            $exit = $LASTEXITCODE
        } finally {
            Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
            foreach ($n in $envNames) { Remove-Item -Path ('env:' + $n) -ErrorAction SilentlyContinue }
        }
        return [pscustomobject]@{ ExitCode = $exit; Output = ($output | Out-String) }
    }
    Initialize-RuntimeDirs
    $wrapperPath = Join-Path $Script:TempDir ('fg-' + [guid]::NewGuid().ToString('N') + '.cmd')
    Set-Content -LiteralPath $wrapperPath -Value $cmdLine -Encoding Ascii
    try {
        $output = & cmd.exe /d /c $wrapperPath 2>&1
        $exit = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ ExitCode = $exit; Output = ($output | Out-String) }
}
