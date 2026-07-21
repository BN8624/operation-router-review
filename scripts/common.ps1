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

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "JSON file not found: $Path" }
    # 실행 세대 write와의 순간적 파일 잠금 경합(IOException) 대비: 최대 5회, 100ms 간격 재시도.
    $raw = $null
    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            $lastError = $null
            break
        } catch [System.IO.IOException] {
            $lastError = $_
            if ($attempt -lt 5) { Start-Sleep -Milliseconds 100 }
        }
    }
    if ($null -ne $lastError) { throw $lastError }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "JSON file is empty: $Path" }
    return $raw | ConvertFrom-Json
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object, [int]$Depth = 12)
    $json = $Object | ConvertTo-Json -Depth $Depth
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Write-AtomicJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object, [int]$Depth = 20)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = Join-Path $parent ('.atomic-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = $Object | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
    $backup = Join-Path $parent ('.atomic-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temp, $Path, $backup, $true)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        } else { [System.IO.File]::Move($temp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Write-AtomicTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = Join-Path $parent ('.atomic-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temp, $Text, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        [System.IO.File]::Move($temp, $Path)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Get-Config { return Read-JsonFile -Path $Script:ConfigPath }
function Get-UsageState { return Read-JsonFile -Path $Script:UsageStatePath }

function Save-UsageState {
    param([Parameter(Mandatory)]$State)
    $State.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonFile -Path $Script:UsageStatePath -Object $State
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
function Assert-ValidGrokSetting {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -eq 'available' -or $Value -eq 'exhausted') { return $Value }
    if ($Value -match '^(100|[0-9]{1,2})$') { return [int]$Value }
    throw "Invalid grok setting '$Value'. Use 0-100, 'available', or 'exhausted'."
}
function Assert-ValidGptSetting {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -in @('available', 'reserved', 'exhausted')) { return $Value }
    if ($Value -match '^(100|[0-9]{1,2})$') { return [int]$Value }
    throw "Invalid gpt setting '$Value'. Use 0-100, 'available', 'reserved', or 'exhausted'."
}

# ---------- 사용량 상태 정규화 (숫자<->status 모순 방지) ----------
function Set-GrokState {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Validated, [Parameter(Mandatory)]$Config)
    $planB = [int]$Config.grok.thresholds.gptPlanBFromPercent
    if ($Validated -is [int]) {
        $State.grok.percent = [int]$Validated
        if ([int]$Validated -ge $planB) { $State.grok.status = 'exhausted' } else { $State.grok.status = 'available' }
    } elseif ($Validated -eq 'available') {
        $State.grok.status = 'available'; $State.grok.percent = 0
    } elseif ($Validated -eq 'exhausted') {
        $State.grok.status = 'exhausted'; $State.grok.percent = 100
    }
    return $State
}
function Set-GptState {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Validated)
    if ($Validated -is [int]) {
        $State.gpt.percent = [int]$Validated
        if ([int]$Validated -ge 100) { $State.gpt.status = 'exhausted' } else { $State.gpt.status = 'available' }
    } elseif ($Validated -eq 'available') {
        $State.gpt.status = 'available'; $State.gpt.percent = 0
    } elseif ($Validated -eq 'reserved') {
        $State.gpt.status = 'reserved'
    } elseif ($Validated -eq 'exhausted') {
        $State.gpt.status = 'exhausted'; $State.gpt.percent = 100
    }
    return $State
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

# ---------- 워커 오류 분류 및 공통 정책 (v2.3.1) ----------
# weekly_exhausted     : 명확한 주간 플랜 소진 → usage-state exhausted/100 + Plan B 허용
# transient_rate_limit : 일시적 429류 → usage-state 불변, 짧은 재시도 최대 1회 또는 transient_rate_limited 중단
# quota_unknown        : 주간 여부가 불명확한 quota 문구 → usage-state 불변, 중단
# provider_failure     : 인증·결제·권한·모델 오류 → 일반 실패로 중단 (Plan B 금지)
# none                 : 분류 불가 일반 오류
function Get-WorkerErrorClass {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $cfg = Get-Config
    foreach ($p in $cfg.weeklyExhaustedPatterns)    { if ($Text -match [regex]::Escape($p)) { return 'weekly_exhausted' } }
    foreach ($p in $cfg.transientRateLimitPatterns) { if ($Text -match [regex]::Escape($p)) { return 'transient_rate_limit' } }
    if ($cfg.PSObject.Properties.Name -contains 'quotaUnknownPatterns') {
        foreach ($p in $cfg.quotaUnknownPatterns)   { if ($Text -match [regex]::Escape($p)) { return 'quota_unknown' } }
    }
    foreach ($p in $cfg.providerFailurePatterns)    { if ($Text -match [regex]::Escape($p)) { return 'provider_failure' } }
    return 'none'
}
# 하위호환: quota(=Plan B 허용 소진)는 이제 주간 소진만 참이다. transient 429는 quota가 아니다.
function Test-QuotaExhaustedText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ((Get-WorkerErrorClass -Text $Text) -eq 'weekly_exhausted')
}
# WorkerResult에서 오류 분류를 얻는다 (ErrorClass 필드 우선, 없으면 Output 텍스트로 분류)
function Get-WorkerResultErrorClass {
    param([Parameter(Mandatory)]$Result)
    $props = $Result.PSObject.Properties.Name
    if ($props -contains 'ErrorClass' -and $null -ne $Result.ErrorClass -and $Result.ErrorClass -ne '') { return [string]$Result.ErrorClass }
    $t = ''
    if ($props -contains 'Output' -and $null -ne $Result.Output) { $t = [string]$Result.Output }
    return (Get-WorkerErrorClass -Text $t)
}

function Test-WorkerResultSuccess {
    param([Parameter(Mandatory)]$Result)
    if ($null -eq $Result) { return $false }
    $props = $Result.PSObject.Properties.Name
    if ($props -contains 'Success') { return [bool]$Result.Success }
    if ($props -contains 'ExitCode' -and $null -ne $Result.ExitCode) { return ([int]$Result.ExitCode -eq 0) }
    return $false
}

function Set-ProviderExhausted {
    param(
        [Parameter(Mandatory)][ValidateSet('grok','gpt')][string]$Provider,
        [Parameter(Mandatory)]$State
    )
    $State.$Provider.status = 'exhausted'
    $State.$Provider.percent = 100
    Save-UsageState -State $State
    return $State
}

# 최초·fallback·review·repair 작업자가 공통으로 사용하는 단일 오류 정책이다.
# 호출은 최초 1회이며 transient만 최대 1회 재시도한다. weekly만 usage-state를 변경한다.
function Invoke-WorkerWithErrorPolicy {
    param(
        [Parameter(Mandatory)][ValidateSet('grok','gpt')][string]$Provider,
        [Parameter(Mandatory)][scriptblock]$InvokeWorker,
        $State = $null,
        $Config = $null,
        [System.Collections.Generic.List[string]]$Log = $null
    )
    if ($null -eq $Config) { $Config = Get-Config }
    if ($null -eq $State) { $State = Get-UsageState }

    $maxRetries = 0
    $retryDelay = 0
    if ($Config.PSObject.Properties.Name -contains 'transientRetry') {
        if ($Config.transientRetry.PSObject.Properties.Name -contains 'maxRetries') {
            $maxRetries = [Math]::Min(1, [Math]::Max(0, [int]$Config.transientRetry.maxRetries))
        }
        if ($Config.transientRetry.PSObject.Properties.Name -contains 'delaySeconds') {
            $retryDelay = [Math]::Max(0, [int]$Config.transientRetry.delaySeconds)
        }
    }

    $attempts = 0
    $result = $null
    $errorClass = 'none'
    do {
        $attempts++
        $result = & $InvokeWorker
        if ($result.PSObject.Properties.Name -contains 'ExecutionPending' -and $result.ExecutionPending) {
            return [pscustomobject]@{
                Result = $result; Success = $false; ErrorClass = 'execution_pending'; Attempts = $attempts
                UsageStateChanged = $false; State = $State
            }
        }
        if (Test-WorkerResultSuccess -Result $result) {
            return [pscustomobject]@{
                Result = $result; Success = $true; ErrorClass = 'none'; Attempts = $attempts
                UsageStateChanged = $false; State = $State
            }
        }
        $errorClass = Get-WorkerResultErrorClass -Result $result
        if ($errorClass -ne 'transient_rate_limit' -or $attempts -gt $maxRetries) { break }
        if ($null -ne $Log) { $Log.Add("$Provider transient rate limit; retry $attempts/$maxRetries after ${retryDelay}s") }
        if ($retryDelay -gt 0) { Start-Sleep -Seconds $retryDelay }
    } while ($attempts -le $maxRetries)

    $usageChanged = $false
    if ($errorClass -eq 'weekly_exhausted') {
        Set-ProviderExhausted -Provider $Provider -State $State | Out-Null
        $usageChanged = $true
        if ($null -ne $Log) { $Log.Add("$Provider marked exhausted/100 after explicit weekly exhaustion") }
    }

    return [pscustomobject]@{
        Result = $result; Success = $false; ErrorClass = $errorClass; Attempts = $attempts
        UsageStateChanged = $usageChanged; State = $State
    }
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
# origin/main 대비 ahead/behind. origin 없으면 unavailable.
function Get-GitAheadBehind {
    param([string]$Path = (Get-Location).Path)
    $r = Invoke-GitRaw -Path $Path -GitArgs @('rev-list','--left-right','--count','origin/main...HEAD')
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

# ---------- 검수 JSON 엄격 파싱 (v2.2: valid 플래그 반환, 모든 위반은 fail-closed) ----------
# 규칙: verdict는 PASS|REPAIR_REQUIRED만. 모든 finding은 severity(blocker|high|medium)/file(string)/
# issue(비어있지 않음)/requiredFix(비어있지 않음) 필수. PASS+findings 존재, REPAIR_REQUIRED+findings 없음,
# 알 수 없는 severity는 전부 잘못된 응답(valid=false)이다. 호출자는 valid=false를 review_parse_failed로 처리한다.
function ConvertFrom-StrictReviewJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $fail = {
        param($reason)
        return [pscustomobject]@{ valid = $false; verdict = $null; parseError = $reason; findings = @() }
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return (& $fail 'empty_review_output') }
    # v2.3.5: codex --json은 단일 JSON이 아니라 JSONL 이벤트 스트림을 출력하고, verdict JSON은
    # item.completed 이벤트의 item(type=agent_message).text 안에 문자열로 들어 있다
    # (2026-07-21 op1-issue13 검수 실측). agent_message text가 있으면 마지막 것을 검수 본문으로 쓴다.
    # 평문 JSON 입력(mock·비스트리밍)은 agent_message가 없으므로 기존 동작 그대로다.
    $agentTexts = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $lt = $line.Trim()
        if ($lt.Length -lt 2 -or -not $lt.StartsWith('{')) { continue }
        $evt = $null
        try { $evt = $lt | ConvertFrom-Json } catch { continue }
        if ($null -eq $evt -or -not ($evt.PSObject.Properties.Name -contains 'item')) { continue }
        $it = $evt.item
        if ($null -ne $it -and ($it.PSObject.Properties.Name -contains 'type') -and $it.type -eq 'agent_message' -and
            ($it.PSObject.Properties.Name -contains 'text') -and -not [string]::IsNullOrWhiteSpace([string]$it.text)) {
            $agentTexts += [string]$it.text
        }
    }
    if ($agentTexts.Count -gt 0) { $Text = [string]$agentTexts[$agentTexts.Count - 1] }
    # 첫 '{' 부터 마지막 '}' 까지 추출 (Sol이 앞뒤 설명을 붙였을 수 있음)
    $start = $Text.IndexOf('{'); $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return (& $fail 'no_json_object_found') }
    $json = $Text.Substring($start, $end - $start + 1)
    try { $obj = $json | ConvertFrom-Json } catch { return (& $fail "json_parse_error: $($_.Exception.Message)") }
    if ($null -eq $obj -or -not ($obj.PSObject.Properties.Name -contains 'verdict')) { return (& $fail 'missing_verdict') }
    if ($obj.verdict -notin @('PASS','REPAIR_REQUIRED')) { return (& $fail "invalid_verdict:$($obj.verdict)") }
    $findings = @()
    if ($obj.PSObject.Properties.Name -contains 'findings' -and $null -ne $obj.findings) { $findings = @($obj.findings) }
    foreach ($f in $findings) {
        if ($null -eq $f) { return (& $fail 'null_finding') }
        $props = $f.PSObject.Properties.Name
        if (-not ($props -contains 'severity') -or $f.severity -notin @('blocker','high','medium')) {
            $sv = ''; if ($props -contains 'severity') { $sv = [string]$f.severity }
            return (& $fail "invalid_finding_severity:$sv")
        }
        if (-not ($props -contains 'file') -or $null -eq $f.file -or -not ($f.file -is [string])) { return (& $fail 'invalid_finding_file') }
        if (-not ($props -contains 'issue') -or [string]::IsNullOrWhiteSpace([string]$f.issue)) { return (& $fail 'empty_finding_issue') }
        if (-not ($props -contains 'requiredFix') -or [string]::IsNullOrWhiteSpace([string]$f.requiredFix)) { return (& $fail 'empty_finding_requiredFix') }
    }
    # PASS 인데 findings가 있으면 모순, REPAIR_REQUIRED 인데 findings가 없으면 모순 -> fail-closed
    if ($obj.verdict -eq 'PASS' -and $findings.Count -gt 0) { return (& $fail 'pass_verdict_with_findings') }
    if ($obj.verdict -eq 'REPAIR_REQUIRED' -and $findings.Count -eq 0) { return (& $fail 'repair_required_without_findings') }
    return [pscustomobject]@{ valid = $true; verdict = $obj.verdict; parseError = $null; findings = $findings }
}

# ---------- 저장소 식별 / 런타임 상태 네임스페이스 (v2.4.5) ----------
# owner/repo와 canonical root의 SHA-256 단축값을 함께 사용해 같은 origin의 복수 clone도 격리한다.
function Get-NormalizedCanonicalRepoRoot {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return $full.ToLowerInvariant() }
    return $full
}
function Get-RepoRootHash {
    param([Parameter(Mandatory)][string]$CanonicalRepoRoot)
    return (Get-Sha256Text -Text (Get-NormalizedCanonicalRepoRoot -Path $CanonicalRepoRoot)).Substring(0, 16)
}
function Get-RepoIdentity {
    param([Parameter(Mandatory)][string]$RepoPath)
    $root = $null
    $rootRes = Invoke-GitRaw -Path $RepoPath -GitArgs @('rev-parse','--show-toplevel')
    if ($rootRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($rootRes.Text)) {
        $root = [System.IO.Path]::GetFullPath($rootRes.Text).TrimEnd('\','/')
    }
    $ownerRepo = Get-GitOriginOwnerRepo -Path $RepoPath
    $rootHash = $null
    if ($root) { $rootHash = Get-RepoRootHash -CanonicalRepoRoot $root }
    $ns = 'unknown-repo'
    if ($ownerRepo) {
        $parts = $ownerRepo -split '/', 2
        $base = (($parts[0] -replace '[^a-zA-Z0-9_\.\-]', '_') + '__' + ($parts[1] -replace '[^a-zA-Z0-9_\.\-]', '_'))
        if ($rootHash) { $ns = $base + '__' + $rootHash }
    } elseif ($rootHash) {
        $ns = 'local__' + $rootHash
    }
    return [pscustomobject]@{
        ownerRepo = $ownerRepo; repoRoot = $root; canonicalRepoRoot = $root
        repoRootHash = $rootHash; namespaceVersion = 2; namespace = $ns
    }
}
function Get-LegacyPendingNamespacePath {
    param([Parameter(Mandatory)][string]$RepoPath)
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $legacy = 'unknown-repo'
    if ($id.ownerRepo) {
        $parts = $id.ownerRepo -split '/', 2
        $legacy = (($parts[0] -replace '[^a-zA-Z0-9_\.\-]', '_') + '__' + ($parts[1] -replace '[^a-zA-Z0-9_\.\-]', '_'))
    } elseif ($id.repoRoot) {
        # v2.4.4 local namespace를 찾기 위한 호환 계산에만 사용한다.
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try {
            $normalized = Get-NormalizedCanonicalRepoRoot -Path $id.repoRoot
            $hex = (($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized)) | ForEach-Object { $_.ToString('x2') }) -join '')
            $legacy = 'local-' + $hex.Substring(0, 12)
        } finally { $md5.Dispose() }
    }
    $dir = Join-Path $Script:PendingDir $legacy
    Assert-PathWithinRoot -Path $dir -Root $Script:PendingDir | Out-Null
    return $dir
}
function Get-PendingNamespacePath {
    param([Parameter(Mandatory)][string]$RepoPath)
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $dir = Join-Path $Script:PendingDir $id.namespace
    Assert-PathWithinRoot -Path $dir -Root $Script:PendingDir | Out-Null
    return $dir
}
function Initialize-PendingNamespace {
    param([Parameter(Mandatory)][string]$RepoPath)
    Initialize-RuntimeDirs
    $dir = Get-PendingNamespacePath -RepoPath $RepoPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$PromptContent, [string]$RunId
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
        schemaVersion = 1; executionId = $executionId; runId = $RunId; generation = $generation
        ownerRepo = $id.ownerRepo; repoRoot = $id.repoRoot; canonicalRepoRoot = $id.canonicalRepoRoot
        repoRootHash = $id.repoRootHash; namespaceVersion = $id.namespaceVersion
        operation = $Operation; issueNumber = $IssueNumber; kind = $Kind; purpose = 'implement'
        startHead = $Snapshot.startHead; startSnapshot = $Snapshot; worker = $Route.worker; model = $Route.model; effort = $Route.effort
        status = 'worker_starting'; startedAt = $now; updatedAt = $now
        promptHash = (Get-Sha256Text -Text $PromptContent); promptPath = $promptPath; logPath = $logPath
        promptPresent = $true; promptDeletedAt = $null; artifactRoot = $artifactRoot; artifactPath = $artifactDir
        resultPath = $resultPath; rawStdoutPath = $stdoutPath; rawStderrPath = $stderrPath
        stdoutPath = $null; stderrPath = $null; sanitizedStdoutPath = $sanitizedStdoutPath; sanitizedStderrPath = $sanitizedStderrPath
        artifactSanitizationStatus = 'pending'; artifactSanitizedAt = $null; invocationPath = $invocationPath
        processId = $null; processStartedAt = $null; finalHead = $null; workerExitCode = $null
        workerStopReason = $null; interruptedReason = $null; workerReportedVerification = $null
        localVerificationComplete = $false; interrupted = $false; recoveredByPostflight = $false
        resultEnvelopePresent = $false; verificationProvenance = 'worker_result_pending'
        postflight = $null; remainingProblems = @()
    }
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
    try { Invoke-ExecutionRetention -Receipt $Receipt | Out-Null } catch {
        $underlying = [string]$Receipt.status
        $Receipt.status = 'artifact_retention_failed'
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
function Save-PendingSnapshot {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)]$Snapshot,
          [Parameter(Mandatory)][string]$RepoPath, [string]$Kind = 'logic')
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $path = Get-PendingSnapshotPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    $payload = [pscustomobject]@{
        operation = $Operation; issueNumber = $IssueNumber; kind = $Kind
        ownerRepo = $id.ownerRepo; repoRoot = $id.repoRoot; canonicalRepoRoot = $id.canonicalRepoRoot
        repoRootHash = $id.repoRootHash; namespaceVersion = $id.namespaceVersion
        snapshot = $Snapshot; savedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
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
        [string]$VerificationProvenance = 'unknown'
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
    $payload = [pscustomobject]@{
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
        recoveredByPostflight = [bool]$RecoveredByPostflight
        verificationProvenance = $VerificationProvenance
        createdAt   = (Get-Date).ToUniversalTime().ToString('o')
    }
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
    if (-not [bool]$Receipt.resultEnvelopePresent -or [bool]$Receipt.interrupted -or
        [string]$Receipt.verificationProvenance -notin @('valid_worker_result_envelope','valid_worker_result_envelope_recovered_postflight')) {
        return (& $fail 'run_result_unverified' 'run_result_unverified' '정상 worker result envelope와 검증 provenance가 확인되지 않았다.')
    }
    if ([string]$Receipt.status -notin @('completed','completed_ci_pending','completed_ci_unavailable')) {
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
        [Parameter(Mandatory)][string]$PostReviewHead, [Parameter(Mandatory)][string]$OriginalWorker
    )
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $id = Get-RepoIdentity -RepoPath $RepoPath
    $path = Get-ReviewReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    $payload = [pscustomobject]@{
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
        createdAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
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

# ---------- 고정 실행 계약 ----------
function Get-FixedExecutionContract {
    return @'
[OPERATION_ROUTER_FINAL_WORKER]
You are the final worker already selected by operation-router.
Do not apply any global Operation 1/2/3 delegation rule in this marked session.
Do not invoke, inspect, preflight, or delegate to Grok, Codex, Claude, or any other worker CLI.
Implement the GitHub issue below directly. The issue body is the sole task canon.

[역할 지정 — 최우선으로 적용]
너는 operation-router가 호출한 "작업자(worker) CLI"이며, 이 주문은 지휘 세션이 너에게 이미 위임한 최종 실행 지시다.
전역 AGENTS.md/CLAUDE.md의 Operation Modes 규칙에서 "Grok CLI에 위임"하는 주체는 지휘자(Claude 세션)이고, 너는 그 위임을 받은 실행자다.
전역 규칙이 명시하듯 이 주문(이슈 원문)이 유일한 task canon이다. 따라서 너는 다른 CLI(grok, codex, claude 등)를 호출하거나 재위임하지 않고 아래 범위를 직접 구현한다.
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
- 커밋 메시지는 git commit -m "..." 한 줄 인라인으로만 작성한다. $(...) 명령 치환, heredoc(<<), 여러 줄 셸 명령을 쓰지 않는다 (헤드리스 권한 정책이 이런 명령을 차단한다).
- 완료 시 변경 파일, 테스트, 커밋, push, 남은 문제만 짧게 보고한다.

[아래는 GitHub 이슈 본문 원문 — 요약·재작성·삭제하지 않는다]
'@
}
# 계약 + 이슈원문(무손실). 이슈 본문은 변형하지 않는다.
function New-OrderContent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$IssueBody)
    $contract = Get-FixedExecutionContract
    return ($contract + "`n" + $IssueBody)
}

function New-TempOrderFile {
    param([Parameter(Mandatory)][string]$Content)
    Initialize-RuntimeDirs
    $name = 'order-' + [guid]::NewGuid().ToString('N') + '.txt'
    $path = Join-Path $Script:TempDir $name
    Assert-PathWithinRoot -Path $path -Root $Script:TempDir | Out-Null
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8 -NoNewline
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
