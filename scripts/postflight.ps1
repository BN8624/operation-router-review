# postflight 완료 검증. 종료코드 0만으로 완료 처리하지 않는다.
# HEAD 변화/커밋/branch/ahead-behind/clean/push + CI 상태를 검사해 최종 status를 확정한다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

# CI 상태 조회 (v2.2): main 직접 push 검증이므로 gh pr checks가 아니라 GitHub Actions run을
# 최종 HEAD(headSha)로 조회한다. 구분: success/failure/pending/unavailable/not-requested.
# - 워크플로 존재 여부는 저장소의 .github/workflows/*.yml|yaml 로컬 확인으로 판정한다.
# - 워크플로가 없으면 API 호출 없이 not-requested.
# - 워크플로가 있으면 run 생성 지연을 고려해 짧게 polling한다 (기본 10초 간격, 최대 6회, config.ciPolling).
# - polling 종료까지 run이 안 보이면 unavailable로 남긴다. not-requested나 completed로 위장하지 않는다.
# - API 오류는 unavailable. API 오류를 success로 간주하지 않는다.
function Test-CiWorkflowPresent {
    param([Parameter(Mandatory)][string]$RepoPath)
    $wfDir = Join-Path $RepoPath '.github\workflows'
    if (-not (Test-Path -LiteralPath $wfDir)) { return $false }
    $files = @(Get-ChildItem -LiteralPath $wfDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yml','.yaml') })
    return ($files.Count -gt 0)
}

# gh run list 1회 조회. 반환: @{ ok = bool; runs = @(...) }. ok=false는 API/파싱 오류.
function Get-CiRunList {
    param([Parameter(Mandatory)][string]$RepoPath)
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $gh) { return @{ ok = $false; runs = @() } }
    $ErrorActionPreference = 'Continue'
    Push-Location $RepoPath
    try {
        $out = & gh run list --branch main --limit 20 --json headSha,status,conclusion 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String)
        if ($code -ne 0) { return @{ ok = $false; runs = @() } }
        $runs = $null
        try { $runs = $text | ConvertFrom-Json } catch { return @{ ok = $false; runs = @() } }
        if ($null -eq $runs) { $runs = @() }
        return @{ ok = $true; runs = @($runs) }
    } finally { Pop-Location }
}

function Get-CiStatus {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][AllowNull()][string]$FinalHead,
        [scriptblock]$CiProbe,
        [scriptblock]$RunLister,
        $WorkflowPresent = $null,
        [int]$PollIntervalSeconds = -1,
        [int]$MaxAttempts = -1
    )
    if ($null -ne $CiProbe) { return (& $CiProbe $FinalHead) }
    if ([string]::IsNullOrWhiteSpace($FinalHead)) { return 'unavailable' }

    if ($PollIntervalSeconds -lt 0 -or $MaxAttempts -lt 1) {
        $cfg = Get-Config
        $interval = 10; $attempts = 6
        if ($cfg.PSObject.Properties.Name -contains 'ciPolling') {
            if ($cfg.ciPolling.PSObject.Properties.Name -contains 'intervalSeconds') { $interval = [int]$cfg.ciPolling.intervalSeconds }
            if ($cfg.ciPolling.PSObject.Properties.Name -contains 'maxAttempts') { $attempts = [int]$cfg.ciPolling.maxAttempts }
        }
        if ($PollIntervalSeconds -lt 0) { $PollIntervalSeconds = $interval }
        if ($MaxAttempts -lt 1) { $MaxAttempts = $attempts }
    }

    $wfPresent = $false
    if ($WorkflowPresent -is [bool]) { $wfPresent = $WorkflowPresent }
    else { $wfPresent = Test-CiWorkflowPresent -RepoPath $RepoPath }
    if (-not $wfPresent) { return 'not-requested' }

    if ($null -eq $RunLister) { $RunLister = { param($p) Get-CiRunList -RepoPath $p } }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $res = & $RunLister $RepoPath
        if (-not $res.ok) { return 'unavailable' }   # API 오류
        $match = @($res.runs | Where-Object { $_.headSha -eq $FinalHead })
        if ($match.Count -gt 0) {
            # v2.3: 동일 finalHead의 모든 run을 집계한다 (첫 run만 보지 않는다).
            # 하나라도 실패 → failure; 실패 없고 하나라도 미완 → pending; 전부 completed/success → success.
            $failureConclusions = @('failure','cancelled','timed_out','startup_failure')
            $anyFailure = $false; $anyPending = $false; $anyUnknown = $false
            foreach ($run in $match) {
                $rp = $run.PSObject.Properties.Name
                $st = ''; if ($rp -contains 'status' -and $null -ne $run.status) { $st = [string]$run.status }
                if ($st -ne 'completed') { $anyPending = $true; continue }
                $conc = ''; if ($rp -contains 'conclusion' -and $null -ne $run.conclusion) { $conc = [string]$run.conclusion }
                if ($conc -in $failureConclusions) { $anyFailure = $true }
                elseif ($conc -ne 'success') { $anyUnknown = $true }
            }
            if ($anyFailure) { return 'failure' }
            if ($anyPending) { return 'pending' }
            if ($anyUnknown) { return 'unavailable' }   # completed인데 success/실패 어느 쪽도 아님 (neutral/skipped 등) — success로 위장하지 않는다
            return 'success'
        }
        if ($attempt -lt $MaxAttempts -and $PollIntervalSeconds -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
    # 워크플로는 있는데 polling 종료까지 run 미발견: not-requested/completed로 처리하지 않는다.
    return 'unavailable'
}

# 최종 완료 상태 판정. WorkerResult는 Success/ExitCode/QuotaExhausted를 가진다.
# DeclaredNoCodeChange=true면 커밋 0을 허용한다 (주문서가 명시적 검증 작업일 때만).
function Resolve-Postflight {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)]$StartSnapshot,
        [Parameter(Mandatory)]$WorkerResult,
        [bool]$DeclaredNoCodeChange = $false,
        [scriptblock]$CiProbe
    )
    $branch = Get-GitCurrentBranch -Path $RepoPath
    $finalHead = Get-GitHead -Path $RepoPath
    $wt = Get-GitWorktreeStatus -Path $RepoPath
    $ab = Get-GitAheadBehind -Path $RepoPath
    $commitCount = 0
    if ($StartSnapshot.startHead) { $commitCount = Get-GitCommitCountSince -Path $RepoPath -SinceHead $StartSnapshot.startHead }
    $headChanged = ($finalHead -ne $StartSnapshot.startHead)

    $pushComplete = $false
    if ($ab.Available) { $pushComplete = ($ab.Ahead -eq 0 -and $ab.Behind -eq 0) }

    # 상태 우선순위: worker 실패 -> quota -> no_commit -> dirty -> push -> ci
    # v2.3: Git·커밋·push 게이트가 전부 통과한 뒤에만 CI를 조회한다.
    # worker_failed/quota_exhausted/no_commit 등 이미 실패가 확정된 경우 CI polling(최대 60초)을 하지 않고
    # ciStatus를 'not-checked'로 남긴다 (not-requested로 위장하지 않는다).
    # watched critical-file 위반의 최종 승격은 New-FinalOutput/review·repair의 공통
    #         Complete-BoundaryFinalizer가 모든 종료 경로에서 일괄 처리한다(조기 반환 포함).
    $status = $null
    if (-not $WorkerResult.Success) {
        if ($WorkerResult.QuotaExhausted) { $status = 'quota_exhausted' } else { $status = 'worker_failed' }
    }
    elseif ((-not $headChanged -or $commitCount -eq 0)) {
        if ($DeclaredNoCodeChange) { $status = 'completed_no_change_declared' } else { $status = 'no_commit' }
    }
    elseif (-not $wt.Clean) { $status = 'dirty_worktree' }
    elseif ($branch -ne 'main') { $status = 'not_on_main' }
    elseif (-not $ab.Available -or -not $pushComplete) { $status = 'push_incomplete' }

    $ci = 'not-checked'
    if ($null -eq $status) {
        # git 게이트가 통과해도 watched critical-file 위반이면 CI를 조회하지 않는다(호출 0회).
        # 최종 status를 repo_boundary_violation으로 승격하는 것은 공통 Complete-BoundaryFinalizer가 한다.
        # 여기서는 underlying status만 'completed'로 두고 CI probe를 건너뛴다.
        $boundaryViol = @()
        if ($null -ne $StartSnapshot -and ($StartSnapshot.PSObject.Properties.Name -contains 'boundaryWatch')) {
            $boundaryViol = @(Test-RepoBoundaryViolation -BeforeSnapshot $StartSnapshot.boundaryWatch)
        }
        if ($boundaryViol.Count -gt 0) {
            $status = 'completed'
        } else {
            $ci = Get-CiStatus -RepoPath $RepoPath -FinalHead $finalHead -CiProbe $CiProbe
            if ($ci -eq 'pending') { $status = 'completed_ci_pending' }
            elseif ($ci -eq 'failure') { $status = 'ci_failed' }
            elseif ($ci -eq 'unavailable') { $status = 'completed_ci_unavailable' }  # API 오류를 completed로 합치지 않는다
            else { $status = 'completed' }
        }
    }

    return [pscustomobject]@{
        status        = $status
        branch        = $branch
        startHead     = $StartSnapshot.startHead
        finalHead     = $finalHead
        headChanged   = [bool]$headChanged
        commitCount   = [int]$commitCount
        worktreeClean = [bool]$wt.Clean
        aheadBehindAvailable = [bool]$ab.Available
        ahead         = $ab.Ahead
        behind        = $ab.Behind
        pushComplete  = [bool]$pushComplete
        ciStatus      = $ci
        workerExitCode = $WorkerResult.ExitCode
    }
}

# 정상 worker result가 유실된 중단 복구용 판정. worker 성공을 합성하지 않고 Git·push·CI 사실만 기록한다.
function Resolve-RecoveryPostflight {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)]$StartSnapshot,
        [scriptblock]$CiProbe
    )
    $branch = Get-GitCurrentBranch -Path $RepoPath
    $finalHead = Get-GitHead -Path $RepoPath
    $wt = Get-GitWorktreeStatus -Path $RepoPath
    $ab = Get-GitAheadBehind -Path $RepoPath
    $commitCount = 0
    if ($StartSnapshot.startHead) { $commitCount = Get-GitCommitCountSince -Path $RepoPath -SinceHead $StartSnapshot.startHead }
    $headChanged = ($finalHead -ne $StartSnapshot.startHead)
    $pushComplete = ($ab.Available -and $ab.Ahead -eq 0 -and $ab.Behind -eq 0)
    $ci = 'not-checked'
    if ((-not $headChanged -or $commitCount -eq 0) -and $wt.Clean) { $status = 'interrupted_no_changes' }
    elseif (-not $wt.Clean) { $status = 'interrupted_dirty_worktree' }
    elseif ($branch -ne 'main' -or -not $pushComplete) { $status = 'interrupted_push_incomplete' }
    else {
        $boundaryViol = @()
        if ($StartSnapshot.PSObject.Properties.Name -contains 'boundaryWatch') { $boundaryViol = @(Test-RepoBoundaryViolation -BeforeSnapshot $StartSnapshot.boundaryWatch) }
        if ($boundaryViol.Count -gt 0) { $status = 'recovered_commit_unverified' }
        else {
            $ci = Get-CiStatus -RepoPath $RepoPath -FinalHead $finalHead -CiProbe $CiProbe
            if ($ci -eq 'pending') { $status = 'recovered_ci_pending_unverified' }
            elseif ($ci -eq 'failure') { $status = 'recovered_ci_failed_unverified' }
            elseif ($ci -eq 'unavailable') { $status = 'recovered_ci_unavailable_unverified' }
            else { $status = 'recovered_commit_unverified' }
        }
    }
    return [pscustomobject]@{
        status=$status; branch=$branch; startHead=$StartSnapshot.startHead; finalHead=$finalHead
        headChanged=[bool]$headChanged; commitCount=[int]$commitCount; worktreeClean=[bool]$wt.Clean
        aheadBehindAvailable=[bool]$ab.Available; ahead=$ab.Ahead; behind=$ab.Behind
        pushComplete=[bool]$pushComplete; ciStatus=$ci; workerExitCode=$null
    }
}
