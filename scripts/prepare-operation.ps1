# 작업자 실행 전 시작 상태를 기록한다 (startHead/branch/status/ahead-behind).
# 부분 변경 후 fallback 판정과 postflight 비교의 기준점이 된다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

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
