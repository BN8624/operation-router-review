# 작업자 실행 전 시작 상태를 기록한다 (startHead/branch/status/ahead-behind).
# 부분 변경 후 fallback 판정과 postflight 비교의 기준점이 된다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

# v2.4.0 저장소 경계: 워커가 손대면 안 되는 저장소 밖 민감 경로. 명령 패턴이 아니라
# "실제로 바뀌었는가"를 SHA-256으로 잡으므로 플래그 재배열·래퍼·동의어 우회에 강하다.
function Get-BoundaryWatchPaths {
    # 테스트 seam: 격리 환경에서 감시 목록을 임시 경로로 대체한다(세미콜론 구분). 실전에는 미설정.
    if (-not [string]::IsNullOrWhiteSpace($env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE)) {
        return @($env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $userHome = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $HOME }
    return @(
        (Join-Path $userHome '.gitconfig'),
        (Join-Path $userHome '.claude\CLAUDE.md'),
        (Join-Path $userHome '.codex\AGENTS.md'),
        (Join-Path $userHome '.claude\operation-router\config\config.json'),
        (Join-Path $userHome '.claude\operation-router\scripts\common.ps1')
    )
}

# 경계 스냅샷: 감시 경로별 SHA-256(없으면 ABSENT)을 JSON 안전한 레코드 배열로 반환한다.
function Get-BoundarySnapshot {
    param([string[]]$Paths)
    if ($null -eq $Paths) { $Paths = Get-BoundaryWatchPaths }
    $records = @()
    foreach ($p in $Paths) {
        $h = 'ABSENT'
        if (Test-Path -LiteralPath $p) {
            try { $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } catch { $h = 'READ_ERROR' }
        }
        $records += [pscustomobject]@{ path = $p; hash = $h }
    }
    return @($records)
}

# 경계 위반 판정(순수 함수): 시작 스냅샷 대비 현재 해시가 달라진 경로 목록을 반환한다.
function Test-RepoBoundaryViolation {
    param([Parameter(Mandatory)][AllowNull()]$BeforeSnapshot)
    if ($null -eq $BeforeSnapshot) { return @() }
    $violations = @()
    foreach ($rec in @($BeforeSnapshot)) {
        if ($null -eq $rec) { continue }
        $p = [string]$rec.path
        $before = [string]$rec.hash
        $now = 'ABSENT'
        if (Test-Path -LiteralPath $p) {
            try { $now = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } catch { $now = 'READ_ERROR' }
        }
        if ($now -ne $before) { $violations += $p }
    }
    return @($violations)
}

# v2.4.1 공통 종료 finalizer: 워커/구현자를 호출한 뒤 반환되는 모든 결과가 이 함수를 통과한다.
# 시작 시 캡처한 boundaryWatch 스냅샷과 현재 감시 파일을 비교해, 위반이 있으면 원래 status를
# underlyingStatus로 보존하고 최종 status를 repo_boundary_violation으로 승격한다. CI는 조회하지 않는다.
# 위반이 없으면 결과 스키마를 바꾸지 않고 그대로 반환한다(불필요한 필드 추가 없음).
function Complete-BoundaryFinalizer {
    param([Parameter(Mandatory)][AllowNull()]$Result, [AllowNull()]$BoundarySnapshot)
    if ($null -eq $Result) { return $Result }
    if ($null -eq $BoundarySnapshot) { return $Result }
    $violations = @(Test-RepoBoundaryViolation -BeforeSnapshot $BoundarySnapshot)
    if ($violations.Count -eq 0) { return $Result }
    $props = $Result.PSObject.Properties.Name
    $current = if ($props -contains 'status') { [string]$Result.status } else { $null }
    if ($current -eq 'repo_boundary_violation') { return $Result }  # idempotent
    Add-Member -InputObject $Result -NotePropertyName underlyingStatus -NotePropertyValue $current -Force
    if ($props -contains 'status') { $Result.status = 'repo_boundary_violation' }
    else { Add-Member -InputObject $Result -NotePropertyName status -NotePropertyValue 'repo_boundary_violation' -Force }
    Add-Member -InputObject $Result -NotePropertyName boundaryViolations -NotePropertyValue @($violations) -Force
    if ($props -contains 'ciStatus') { $Result.ciStatus = 'not-checked' }
    else { Add-Member -InputObject $Result -NotePropertyName ciStatus -NotePropertyValue 'not-checked' -Force }
    $rp = @('repo boundary violation: watched out-of-repo files changed')
    if ($props -contains 'remainingProblems' -and $null -ne $Result.remainingProblems) { $rp += @($Result.remainingProblems) }
    if ($props -contains 'remainingProblems') { $Result.remainingProblems = @($rp) }
    else { Add-Member -InputObject $Result -NotePropertyName remainingProblems -NotePropertyValue @($rp) -Force }
    return $Result
}

function Get-StartSnapshot {
    param([Parameter(Mandatory)][string]$RepoPath)
    $branch = Get-GitCurrentBranch -Path $RepoPath
    $head = Get-GitHead -Path $RepoPath
    $wt = Get-GitWorktreeStatus -Path $RepoPath
    $ab = Get-GitAheadBehind -Path $RepoPath
    return [pscustomobject]@{
        startHead     = $head
        branch        = $branch
        worktreeClean = [bool]$wt.Clean
        worktreeRaw   = $wt.Raw
        aheadBehindAvailable = [bool]$ab.Available
        ahead         = $ab.Ahead
        behind        = $ab.Behind
        boundaryWatch = Get-BoundarySnapshot
    }
}

# 시작 검토 전제조건. main + clean + origin/main 동기화(ahead=0 behind=0)를 요구한다.
# fetch/pull/reset을 자동 수행하지 않는다. 미동기화는 각각 명확한 상태로 중단한다.
function Test-StartPreconditions {
    param([Parameter(Mandatory)][string]$RepoPath)
    if (-not (Test-GitRepository -Path $RepoPath)) {
        return [pscustomobject]@{ ok = $false; reason = 'not_a_git_repository' }
    }
    $snap = Get-StartSnapshot -RepoPath $RepoPath
    if ($snap.branch -ne 'main') {
        return [pscustomobject]@{ ok = $false; reason = 'not_on_main_branch'; snapshot = $snap }
    }
    if (-not $snap.worktreeClean) {
        return [pscustomobject]@{ ok = $false; reason = 'dirty_worktree'; snapshot = $snap }
    }
    # 원격 동기화 게이트 (자동 fetch 없음: 마지막으로 알려진 origin/main 기준)
    if (-not $snap.aheadBehindAvailable) {
        return [pscustomobject]@{ ok = $false; reason = 'remote_sync_unavailable'; snapshot = $snap }
    }
    if ([int]$snap.behind -gt 0) {
        return [pscustomobject]@{ ok = $false; reason = 'behind_remote'; snapshot = $snap }
    }
    if ([int]$snap.ahead -gt 0) {
        return [pscustomobject]@{ ok = $false; reason = 'local_ahead_of_remote'; snapshot = $snap }
    }
    return [pscustomobject]@{ ok = $true; snapshot = $snap; ownerRepo = (Get-GitOriginOwnerRepo -Path $RepoPath) }
}

# 부분 변경 감지: 시작 이후 파일/커밋/HEAD 변화가 있으면 fallback 금지.
# 반환: @{ changed = bool; details }
function Test-WorkerChangedRepo {
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)]$StartSnapshot)
    $currentHead = Get-GitHead -Path $RepoPath
    $wt = Get-GitWorktreeStatus -Path $RepoPath
    $commits = 0
    if ($StartSnapshot.startHead) { $commits = Get-GitCommitCountSince -Path $RepoPath -SinceHead $StartSnapshot.startHead }
    $headChanged = ($currentHead -ne $StartSnapshot.startHead)
    $nowDirty = (-not $wt.Clean)
    $changed = ($headChanged -or $nowDirty -or ($commits -gt 0))
    return [pscustomobject]@{
        changed = [bool]$changed
        headChanged = [bool]$headChanged
        worktreeDirty = [bool]$nowDirty
        newCommits = [int]$commits
        currentHead = $currentHead
    }
}
