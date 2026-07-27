# usage-state 원자 저장·직렬화와 런타임 상태 경로를 제공하는 dot-source 모듈이다.

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

function Read-JsonFileStable {
    param([Parameter(Mandatory)][string]$Path,[int]$MaxAttempts=8,[int]$DelayMilliseconds=75)
    $last=$null
    for($attempt=1;$attempt -le [Math]::Max(1,$MaxAttempts);$attempt++){
        try{
            if(-not (Test-Path -LiteralPath $Path)){throw [System.IO.FileNotFoundException]::new("JSON file not found: $Path")}
            $raw=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
            if([string]::IsNullOrWhiteSpace($raw)){throw [System.IO.InvalidDataException]::new("JSON file is empty: $Path")}
            return ($raw|ConvertFrom-Json -ErrorAction Stop)
        }catch{
            $last=$_
            if($attempt -lt $MaxAttempts){Start-Sleep -Milliseconds ([Math]::Max(1,$DelayMilliseconds))}
        }
    }
    if($null -ne $last){throw $last}
    throw "JSON file is unreadable: $Path"
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
        $failureInjector = Get-Variable -Name AtomicWriteFailureInjector -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $failureInjector -and $null -ne $failureInjector.Value) {
            & $failureInjector.Value $temp $Path
        }
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

function Get-UsageStateLockPath {
    return (Join-Path (Split-Path -Parent $Script:UsageStatePath) 'usage-state.lock')
}

function Open-UsageStateLock {
    param([int]$MaxAttempts = 20, [int]$DelayMilliseconds = 50)
    $lockPath = Get-UsageStateLockPath
    $parent = Split-Path -Parent $lockPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le [Math]::Max(1, $MaxAttempts); $attempt++) {
        try {
            return [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            $lastError = $_
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds ([Math]::Max(1, $DelayMilliseconds))
            }
        }
    }
    $detail = if ($null -ne $lastError) { $lastError.Exception.Message } else { 'unknown lock error' }
    throw [System.TimeoutException]::new("Unable to acquire usage-state lock after $MaxAttempts attempts: $detail")
}

function Write-UsageStateUnlocked {
    param([Parameter(Mandatory)]$State)
    $State.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-AtomicJsonFile -Path $Script:UsageStatePath -Object $State
    return $State
}

function Invoke-UsageStateUpdate {
    param(
        [Parameter(Mandatory)][scriptblock]$Update,
        [int]$MaxLockAttempts = 20,
        [int]$LockDelayMilliseconds = 50
    )
    $lock = Open-UsageStateLock -MaxAttempts $MaxLockAttempts -DelayMilliseconds $LockDelayMilliseconds
    try {
        $state = Read-JsonFileStable -Path $Script:UsageStatePath
        $updated = & $Update $state
        if ($null -eq $updated) { throw 'Usage-state update returned null.' }
        return (Write-UsageStateUnlocked -State $updated)
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

function Save-UsageState {
    param(
        [Parameter(Mandatory)]$State,
        [int]$MaxLockAttempts = 20,
        [int]$LockDelayMilliseconds = 50
    )
    $lock = Open-UsageStateLock -MaxAttempts $MaxLockAttempts -DelayMilliseconds $LockDelayMilliseconds
    try {
        if (Test-Path -LiteralPath $Script:UsageStatePath) {
            $current = Read-JsonFileStable -Path $Script:UsageStatePath
            $incomingStamp = if ($State.PSObject.Properties.Name -contains 'updatedAt') { [string]$State.updatedAt } else { '' }
            $currentStamp = if ($current.PSObject.Properties.Name -contains 'updatedAt') { [string]$current.updatedAt } else { '' }
            if ($incomingStamp -cne $currentStamp) {
                throw 'Refusing to overwrite usage-state with a stale state object.'
            }
        }
        return (Write-UsageStateUnlocked -State $State)
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

# ---------- usage-state 입력 검증과 정규화 ----------
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

# ---------- usage-state 보조 명령 ----------
function Invoke-StatusCommand {
    $s = Get-UsageState
    [pscustomobject]@{ command = 'status'; grok = $s.grok; gpt = $s.gpt; updatedAt = $s.updatedAt }
}
function Invoke-SetCommand {
    param([Parameter(Mandatory)][ValidateSet('grok','gpt')][string]$Target, [Parameter(Mandatory)][string]$Value)
    $cfg = Get-Config
    if ($Target -eq 'grok') {
        $v = Assert-ValidGrokSetting -Value $Value
    } else {
        $v = Assert-ValidGptSetting -Value $Value
    }
    $state = Invoke-UsageStateUpdate -Update {
        param($current)
        if ($Target -eq 'grok') {
            return (Set-GrokState -State $current -Validated $v -Config $cfg)
        }
        return (Set-GptState -State $current -Validated $v)
    }
    [pscustomobject]@{ command = 'set'; target = $Target; value = $Value; state = $state }
}
# reset은 런타임 상태만 초기화한다. Skill/스크립트/config는 건드리지 않는다.
function Invoke-ResetCommand {
    $default = [pscustomobject]@{
        grok = [pscustomobject]@{ status = 'available'; percent = 0 }
        gpt  = [pscustomobject]@{ status = 'available'; percent = 0 }
        updatedAt = $null
    }
    $default = Invoke-UsageStateUpdate -Update { param($current) return $default }
    [pscustomobject]@{ command = 'reset'; scope = 'runtime_state_only'; state = $default }
}
