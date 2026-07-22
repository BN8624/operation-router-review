# operation-router 메인 진입점.
# 명령: run | review | repair | postflight | recover | status | doctor | set | reset
# run 역할: 시작검토 -> 계약+이슈원문 주문서 -> 라우팅 -> 작업자 1회 -> (한도오류 시 부분변경 가드) -> postflight -> 전체 JSON.

param(
    [ValidateSet('run','review','repair','postflight','recover','status','doctor','set','reset')][string]$Command = 'run',
    [int]$Operation,
    [int]$IssueNumber,
    [ValidateSet('logic','mechanical')][string]$Kind = 'logic',
    [switch]$UseGptReviewReserve,
    [switch]$FinishCurrent,
    [switch]$ClaudeOnly,
    [string]$StartHead,
    [string]$PostReviewHead,
    [string]$FindingsFile,
    [ValidateSet('grok','gpt')][string]$Target,
    [string]$Value
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'resolve-route.ps1')
. (Join-Path $PSScriptRoot 'prepare-operation.ps1')
. (Join-Path $PSScriptRoot 'invoke-grok.ps1')
. (Join-Path $PSScriptRoot 'invoke-gpt.ps1')
. (Join-Path $PSScriptRoot 'postflight.ps1')
. (Join-Path $PSScriptRoot 'detect-environment.ps1')

# ---------------- 보조 명령 ----------------
function Invoke-StatusCommand {
    $s = Get-UsageState
    [pscustomobject]@{ command = 'status'; grok = $s.grok; gpt = $s.gpt; updatedAt = $s.updatedAt }
}
function Invoke-DoctorCommand {
    $report = Invoke-EnvironmentDetection
    Write-JsonFile -Path $Script:DoctorReportPath -Object $report
    [pscustomobject]@{ command = 'doctor'; report = $report; reportPath = $Script:DoctorReportPath }
}
function Invoke-SetCommand {
    param([Parameter(Mandatory)][ValidateSet('grok','gpt')][string]$Target, [Parameter(Mandatory)][string]$Value)
    $cfg = Get-Config
    $state = Get-UsageState
    if ($Target -eq 'grok') {
        $v = Assert-ValidGrokSetting -Value $Value
        $state = Set-GrokState -State $state -Validated $v -Config $cfg
    } else {
        $v = Assert-ValidGptSetting -Value $Value
        $state = Set-GptState -State $state -Validated $v
    }
    Save-UsageState -State $state
    [pscustomobject]@{ command = 'set'; target = $Target; value = $Value; state = $state }
}
# reset은 런타임 상태만 초기화한다. Skill/스크립트/config는 건드리지 않는다.
function Invoke-ResetCommand {
    $default = [pscustomobject]@{
        grok = [pscustomobject]@{ status = 'available'; percent = 0 }
        gpt  = [pscustomobject]@{ status = 'available'; percent = 0 }
        updatedAt = $null
    }
    Save-UsageState -State $default
    [pscustomobject]@{ command = 'reset'; scope = 'runtime_state_only'; state = $default }
}

# ---------------- 출력 조립 ----------------
function New-RouteLabel {
    param([Parameter(Mandatory)]$Route)
    switch ($Route.status) {
        'routed' { if ($Route.worker -eq 'grok') { 'grok-primary' } elseif ($Route.reason -like 'grok_plan_b*') { 'gpt-plan-b' } else { 'gpt' } ; break }
        'claude_only_required' { 'claude-only'; break }
        'claude_direct' { 'claude-direct'; break }
        'claude_review_fallback' { 'claude-review'; break }
        'blocked' { 'blocked-conserve'; break }
        default { $Route.status }
    }
}

function New-FinalOutput {
    param(
        [Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][string]$RouteLabel,
        [Parameter(Mandatory)][string]$Status, $Worker, $Model, $Effort,
        $Snapshot, $Postflight, $IssueNumber, $LogPath, $RemainingProblems = @(), $Extra = $null
    )
    $o = [ordered]@{
        operation = $Operation
        route = $RouteLabel
        worker = $Worker
        model = $Model
        effort = $Effort
        startHead = if ($Snapshot) { $Snapshot.startHead } else { $null }
        finalHead = if ($Postflight) { $Postflight.finalHead } elseif ($Snapshot) { $Snapshot.startHead } else { $null }
        commitCount = if ($Postflight) { $Postflight.commitCount } else { 0 }
        workerExitCode = if ($Postflight) { $Postflight.workerExitCode } else { $null }
        branch = if ($Postflight) { $Postflight.branch } elseif ($Snapshot) { $Snapshot.branch } else { $null }
        ahead = if ($Postflight) { $Postflight.ahead } elseif ($Snapshot) { $Snapshot.ahead } else { $null }
        behind = if ($Postflight) { $Postflight.behind } elseif ($Snapshot) { $Snapshot.behind } else { $null }
        worktreeClean = if ($Postflight) { $Postflight.worktreeClean } elseif ($Snapshot) { $Snapshot.worktreeClean } else { $null }
        pushComplete = if ($Postflight) { $Postflight.pushComplete } else { $null }
        ciStatus = if ($Postflight) { $Postflight.ciStatus } else { 'not-requested' }
        status = $Status
        issueNumber = $IssueNumber
        remainingProblems = @($RemainingProblems)
        logPath = $LogPath
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }
    $obj = [pscustomobject]$o
    # 선택한 critical file의 사후 무결성 변화를 모든 종료 경로에서 확인한다. OS sandbox가 아니다.
    $bw = $null
    if ($Snapshot -and ($Snapshot.PSObject.Properties.Name -contains 'boundaryWatch')) { $bw = $Snapshot.boundaryWatch }
    return (Complete-BoundaryFinalizer -Result $obj -BoundarySnapshot $bw)
}

function Get-RemainingProblems {
    param([Parameter(Mandatory)][string]$Status, $Postflight)
    $probs = @()
    switch ($Status) {
        'no_commit'        { $probs += 'exit 0 but no commit created' }
        'push_incomplete'  { $probs += 'origin/main ahead/behind mismatch or unavailable' }
        'dirty_worktree'   { $probs += 'worktree dirty after worker' }
        'not_on_main'      { $probs += 'branch is not main after worker' }
        'ci_failed'        { $probs += 'CI reported failure' }
        'completed_ci_pending' { $probs += 'CI still pending' }
        'completed_ci_unavailable' { $probs += 'git/push OK but CI status could not be read (API error/none) — not counted as success' }
        'worker_failed'    { $probs += 'worker returned non-zero exit (not a quota error)' }
        'worker_cancelled' { $probs += 'worker stopReason was Cancelled/Aborted (headless run stopped before finishing); usage-state unchanged, no fallback, no retry' }
        'worker_turn_limit' { $probs += 'worker hit its turn limit (stopReason MaxTurns); usage-state unchanged, no fallback; do not raise turns to mask it' }
        'worker_protocol_error' { $probs += 'worker exited without parseable JSON (--output-format json); treated as failure even at exit 0, no fallback' }
        'provider_failure' { $probs += 'provider authentication, billing, permission, or model failure; usage-state unchanged' }
        'quota_unknown'    { $probs += 'ambiguous quota message; weekly exhaustion was not proven and usage-state is unchanged' }
        'fallback_loop_blocked' { $probs += 'fallback provider repetition was blocked' }
        'quota_exhausted'  { $probs += 'worker hit weekly plan exhaustion and no safe fallback' }
        'transient_rate_limited' { $probs += 'worker hit a transient rate limit (429); usage-state unchanged, no Plan B; retry later' }
        'partial_worker_changes' { $probs += 'worker made partial changes then hit quota; fallback withheld' }
        'repair_completed_review_pending' { $probs += 'repair applied but NOT re-reviewed; final PASS decided only by current-session end review' }
        'interrupted_no_changes' { $probs += 'worker result missing and no committed change recovered' }
        'interrupted_dirty_worktree' { $probs += 'worker result missing and worktree is dirty' }
        'interrupted_push_incomplete' { $probs += 'worker result missing and final HEAD is not confirmed on origin/main' }
        'recovered_commit_unverified' { $probs += 'commit/push recovered, but worker result and local verification are unverified; manual verification is required' }
        'recovered_ci_pending_unverified' { $probs += 'commit recovered but worker result is missing and CI is pending; review is not eligible' }
        'recovered_ci_failed_unverified' { $probs += 'commit recovered but worker result is missing and CI failed; review is not eligible' }
        'recovered_ci_unavailable_unverified' { $probs += 'commit recovered but worker result is missing and CI status is unavailable; review is not eligible' }
        'artifact_sanitization_failed' { $probs += 'execution artifacts could not be sanitized; completion is not trusted' }
        'artifact_retention_failed' { $probs += 'execution artifact retention failed; completion is not trusted' }
        'repair_worker_failed'    { $probs += 'repair worker returned non-zero exit (not a quota error)' }
        'repair_quota_exhausted'  { $probs += 'repair worker hit quota' }
        'repair_transient_rate_limited' { $probs += 'repair worker hit a transient rate limit; usage-state unchanged' }
        'repair_provider_failure' { $probs += 'repair provider failed; usage-state unchanged' }
        'repair_quota_unknown'    { $probs += 'repair returned an ambiguous quota message; usage-state unchanged' }
        'repair_postflight_failed' { $probs += 'repair worker exited 0 but postflight gates failed' }
        'repair_worker_unavailable' { $probs += 'no permitted repair worker under current usage state; no silent worker swap' }
    }
    return $probs
}

function Get-WorkerFailureStatus {
    param([Parameter(Mandatory)][string]$ErrorClass)
    switch ($ErrorClass) {
        'transient_rate_limit'  { return 'transient_rate_limited' }
        'provider_failure'      { return 'provider_failure' }
        'quota_unknown'         { return 'quota_unknown' }
        'worker_cancelled'      { return 'worker_cancelled' }
        'worker_turn_limit'     { return 'worker_turn_limit' }
        'worker_protocol_error' { return 'worker_protocol_error' }
        default                 { return 'worker_failed' }
    }
}

function New-WorkerPolicyFailureOutput {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)]$Route, [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Execution, [string]$LogPath,
        [bool]$FallbackAttempted = $false
    )
    $status = Get-WorkerFailureStatus -ErrorClass $Execution.ErrorClass
    # 워커 원시 결과에서 exit code와 stopReason을 보존한다 (exit code와 실제 성공 여부를 별도 필드로 유지).
    $workerExit = $null; $stopReason = $null
    if ($null -ne $Execution.Result) {
        $rp = $Execution.Result.PSObject.Properties.Name
        if ($rp -contains 'ExitCode') { $workerExit = $Execution.Result.ExitCode }
        if ($rp -contains 'WorkerStopReason') { $stopReason = $Execution.Result.WorkerStopReason }
    }
    return New-FinalOutput -Operation $OperationNumber -RouteLabel (New-RouteLabel -Route $Route) -Status $status `
        -Worker $Route.worker -Model $Route.model -Effort $Route.effort -Snapshot $Snapshot -Postflight $null `
        -IssueNumber $IssueNumber -LogPath $LogPath -RemainingProblems (Get-RemainingProblems -Status $status) `
        -Extra @{ errorClass = $Execution.ErrorClass; attempts = $Execution.Attempts; usageStateChanged = $Execution.UsageStateChanged
                  fallbackAttempted = $FallbackAttempted; ciStatus = 'not-checked'
                  workerExitCode = $workerExit; workerStopReason = $stopReason }
}

# v2.3: 작전 1과 작전 3 logic의 Claude-only 재개는 Sonnet 전용 Skill로 안내한다.
# (요구 모델 claude-sonnet-5와 Skill frontmatter 모델이 구조적으로 일치)
# 작전 2는 기존 /operation-2 --claude-only(Sonnet Skill) 유지, 작전 3 mechanical은 claude_direct(Haiku)라 resume 없음.
function Get-ResumeCommand {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [string]$Kind = 'logic')
    if ($IssueNumber -le 0) { throw "Get-ResumeCommand: issue number must be positive (got $IssueNumber). Refusing to emit a resume command with issue 0/null." }
    switch ($Operation) {
        1 { "/operation-1-claude $IssueNumber" ; break }
        2 { "/operation-2 $IssueNumber --claude-only" ; break }
        3 {
            if ($Kind -eq 'mechanical') { "/operation-3 $IssueNumber --kind mechanical --claude-only" }
            else { "/operation-3-claude $IssueNumber" }
            break
        }
    }
}

# --claude-only / claude_direct 실행 대상 (요구 모델·effort). config.claudeOnly 매핑을 따른다.
function Get-ClaudeTarget {
    param([Parameter(Mandatory)][int]$Operation, [string]$Kind = 'logic', [Parameter(Mandatory)]$Config)
    if ($Operation -eq 3) {
        $c = $Config.claudeOnly.'3'.$Kind
        $direct = ($c.PSObject.Properties.Name -contains 'direct' -and $c.direct)
        $eff = $null
        if ($c.PSObject.Properties.Name -contains 'effort') { $eff = $c.effort }
        return @{ model = $c.model; effort = $eff; direct = [bool]$direct }
    }
    $c = $Config.claudeOnly.([string]$Operation)
    return @{ model = $c.model; effort = $c.effort; direct = $false }
}

# --claude-only / claude_direct 실제 실행.
# ClaudeImplementer가 주입되면 현재 세션이 직접 구현한 것으로 보고 실행 후 postflight를 돌린다.
# 없으면 재라우팅/재귀 없이 'claude_execute' 지시(주문서·요구모델·postflight 명령)를 반환한다.
# 어느 경우에도 claude_only_required를 다시 반환하지 않는다 (무한 루프 제거).
function Invoke-ClaudeExecution {
    param(
        [Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber, [string]$Kind = 'logic',
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Order, [Parameter(Mandatory)]$Snapshot,
        [string]$Mode = 'claude-only', [scriptblock]$ClaudeImplementer, [scriptblock]$CiProbe,
        [Parameter(Mandatory)]$Log
    )
    if ($null -ne $ClaudeImplementer) {
        $Log.Add("claude execution ($Mode) model=$($Target.model) effort=$($Target.effort): running injected implementer")
        $impl = & $ClaudeImplementer $RepoPath $Order $Target
        # implementer 결과를 WorkerResult 형태로 정규화 (현재 세션이 수행 → 기본 성공)
        $success = $true; $exit = 0
        if ($null -ne $impl -and ($impl.PSObject.Properties.Name -contains 'Success')) { $success = [bool]$impl.Success }
        if ($null -ne $impl -and ($impl.PSObject.Properties.Name -contains 'ExitCode')) { $exit = [int]$impl.ExitCode }
        $wr = [pscustomobject]@{ Success = $success; ExitCode = $exit; QuotaExhausted = $false; Output = 'claude-executed' }
        $pf = Resolve-Postflight -RepoPath $RepoPath -StartSnapshot $Snapshot -WorkerResult $wr -DeclaredNoCodeChange:$false -CiProbe $CiProbe
        Remove-PendingSnapshot -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
        $lp = Write-RouterLog -Name "op$Operation-issue$IssueNumber-claude" -Content ($Log -join "`n")
        return New-FinalOutput -Operation $Operation -RouteLabel "$Mode-executed" -Status $pf.status `
            -Worker 'claude' -Model $Target.model -Effort $Target.effort -Snapshot $Snapshot -Postflight $pf `
            -IssueNumber $IssueNumber -LogPath $lp -RemainingProblems (Get-RemainingProblems -Status $pf.status -Postflight $pf) `
            -Extra @{ executedBy = 'claude'; mode = $Mode }
    }
    # 지시 모드: 주문서를 pending(저장소 네임스페이스)에 보존하고 postflight 명령을 안내 (재귀 resumeCommand 없음)
    Save-PendingSnapshot -Operation $Operation -IssueNumber $IssueNumber -Snapshot $Snapshot -Kind $Kind -RepoPath $RepoPath | Out-Null
    $orderPath = Get-PendingOrderPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $orderPath -Root $Script:PendingDir | Out-Null
    Set-Content -LiteralPath $orderPath -Value $Order -Encoding UTF8 -NoNewline
    $Log.Add("claude execution ($Mode) directive: order persisted, awaiting current-session implementation + postflight")
    $lp = Write-RouterLog -Name "op$Operation-issue$IssueNumber-claude" -Content ($Log -join "`n")
    return New-FinalOutput -Operation $Operation -RouteLabel $Mode -Status 'claude_execute' `
        -Worker 'claude' -Model $Target.model -Effort $Target.effort -Snapshot $Snapshot -Postflight $null `
        -IssueNumber $IssueNumber -LogPath $lp `
        -Extra @{
            requiredModel = $Target.model; requiredEffort = $Target.effort
            orderPath = $orderPath; startHead = $Snapshot.startHead
            postflightCommand = "-Command postflight -Operation $Operation -IssueNumber $IssueNumber"
            note = '현재 세션이 요구 모델이면 고정 실행 계약+이슈 원문(orderPath)을 직접 수행한 뒤 postflightCommand를 실행하라. 재라우팅/재귀 handoff 없음.'
        }
}

# claude-only 지시 후 현재 세션이 구현을 마친 뒤 호출: pending 스냅샷 기준 postflight.
function Invoke-PostflightCommand {
    param([Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber,
          [string]$RepoPath = (Get-Location).Path, [scriptblock]$CiProbe)
    $pend = Get-PendingSnapshot -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    if ($null -eq $pend) {
        return [pscustomobject]@{ operation = $Operation; issueNumber = $IssueNumber; status = 'no_pending_snapshot'
            note = 'pending 시작 스냅샷이 없다. 먼저 --claude-only 로 실행해 지시를 받아야 한다.' }
    }
    # v2.3: 현재 저장소와 스냅샷 저장소가 다르면 중단
    # v2.4.2: pending 스냅샷이 존재하므로 이 조기 반환도 경계 검사를 통과시킨다(감시 파일 변경 시 승격).
    $pendBoundary = $null
    if ($pend.PSObject.Properties.Name -contains 'snapshot' -and $null -ne $pend.snapshot -and ($pend.snapshot.PSObject.Properties.Name -contains 'boundaryWatch')) {
        $pendBoundary = $pend.snapshot.boundaryWatch
    }
    if (-not (Test-ReceiptRepoMatch -Receipt $pend -RepoPath $RepoPath)) {
        $mismatch = [pscustomobject]@{ operation = $Operation; issueNumber = $IssueNumber; status = 'repository_receipt_mismatch'
            note = '현재 저장소와 pending 스냅샷의 저장소가 다르다. postflight를 중단한다.' }
        return (Complete-BoundaryFinalizer -Result $mismatch -BoundarySnapshot $pendBoundary)
    }
    $wr = [pscustomobject]@{ Success = $true; ExitCode = 0; QuotaExhausted = $false; Output = 'claude-postflight' }
    $pf = Resolve-Postflight -RepoPath $RepoPath -StartSnapshot $pend.snapshot -WorkerResult $wr -DeclaredNoCodeChange:$false -CiProbe $CiProbe
    Remove-PendingSnapshot -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    $orderPath = Get-PendingOrderPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath
    if (Test-Path -LiteralPath $orderPath) { Remove-Item -LiteralPath $orderPath -Force }
    return New-FinalOutput -Operation $Operation -RouteLabel 'claude-postflight' -Status $pf.status `
        -Worker 'claude' -Model $null -Effort $null -Snapshot $pend.snapshot -Postflight $pf `
        -IssueNumber $IssueNumber -LogPath $null -RemainingProblems (Get-RemainingProblems -Status $pf.status -Postflight $pf)
}

# ---------------- run ----------------
function Invoke-RunOperation {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [ValidateSet('logic','mechanical')][string]$Kind = 'logic',
        [switch]$UseGptReviewReserve, [switch]$FinishCurrent, [switch]$ClaudeOnly,
        [string]$RepoPath = (Get-Location).Path,
        [scriptblock]$IssueFetcher, [scriptblock]$GrokRunner, [scriptblock]$GptRunner, [scriptblock]$CiProbe,
        [scriptblock]$ClaudeImplementer
    )
    $config = Get-Config

    $pre = Test-StartPreconditions -RepoPath $RepoPath
    if (-not $pre.ok) {
        $preSnap = $null
        if ($pre.PSObject.Properties.Name -contains 'snapshot') { $preSnap = $pre.snapshot }
        return New-FinalOutput -Operation $OperationNumber -RouteLabel 'blocked-preflight' -Status $pre.reason `
            -Worker $null -Model $null -Effort $null -Snapshot $preSnap `
            -Postflight $null -IssueNumber $IssueNumber -LogPath $null -RemainingProblems @($pre.reason)
    }
    $snapshot = $pre.snapshot

    if ($null -eq $IssueFetcher) {
        $IssueFetcher = {
            param($num, $path)
            $r = Invoke-GitRaw -Path $path -GitArgs @('rev-parse','--is-inside-work-tree')
            $out = & gh issue view $num --json body -q .body 2>&1
            if ($LASTEXITCODE -ne 0) { throw "gh issue view failed: $out" }
            return ($out | Out-String)
        }
    }
    $issueBody = & $IssueFetcher $IssueNumber $RepoPath
    $order = New-OrderContent -IssueBody $issueBody
    $tempOrderPath = New-TempOrderFile -Content $order

    $log = New-Object System.Collections.Generic.List[string]
    $log.Add("op=$OperationNumber issue=$IssueNumber kind=$Kind repo=$($pre.ownerRepo) startHead=$($snapshot.startHead)")

    try {
        # --claude-only 재개: 워커 라우팅을 다시 하지 않고 현재 세션이 직접 수행한다.
        # claude_only_required를 반복 반환하지 않는다 (무한 루프 제거).
        if ($ClaudeOnly) {
            $target = Get-ClaudeTarget -Operation $OperationNumber -Kind $Kind -Config $config
            return Invoke-ClaudeExecution -Operation $OperationNumber -IssueNumber $IssueNumber -Kind $Kind `
                -RepoPath $RepoPath -Target $target -Order $order -Snapshot $snapshot -Mode 'claude-only' `
                -ClaudeImplementer $ClaudeImplementer -CiProbe $CiProbe -Log $log
        }

        $state = Get-UsageState
        $route = Resolve-OperationRoute -OperationNumber $OperationNumber -Kind $Kind -Purpose implement `
            -GrokState $state.grok -GptState $state.gpt -Config $config `
            -UseGptReviewReserve:$UseGptReviewReserve -FinishCurrent:$FinishCurrent

        # claude_direct (작전 3 mechanical, GPT 차단): 현재 세션(Haiku)이 직접 수행하는 실제 흐름으로 연결.
        if ($route.status -eq 'claude_direct') {
            $target = Get-ClaudeTarget -Operation $OperationNumber -Kind $Kind -Config $config
            return Invoke-ClaudeExecution -Operation $OperationNumber -IssueNumber $IssueNumber -Kind $Kind `
                -RepoPath $RepoPath -Target $target -Order $order -Snapshot $snapshot -Mode 'claude-direct' `
                -ClaudeImplementer $ClaudeImplementer -CiProbe $CiProbe -Log $log
        }
        # claude_only_required (작전 1·2·3 logic, GPT 차단): 단일 handoff. resumeCommand로 --claude-only 안내 (원래 이슈번호 유지).
        if ($route.status -eq 'claude_only_required') {
            $extra = @{ requiredModel = $route.requiredModel; requiredEffort = $route.requiredEffort; reason = $route.reason
                       resumeCommand = (Get-ResumeCommand -Operation $OperationNumber -IssueNumber $IssueNumber -Kind $Kind) }
            $lp = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber" -Content ($log -join "`n")
            return New-FinalOutput -Operation $OperationNumber -RouteLabel (New-RouteLabel -Route $route) -Status $route.status `
                -Worker 'claude' -Model $route.requiredModel -Effort $route.requiredEffort -Snapshot $snapshot `
                -Postflight $null -IssueNumber $IssueNumber -LogPath $lp -Extra $extra
        }
        if ($route.status -eq 'blocked') {
            $lp = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber" -Content ($log -join "`n")
            return New-FinalOutput -Operation $OperationNumber -RouteLabel 'blocked-conserve' -Status 'blocked' `
                -Worker $null -Model $null -Effort $null -Snapshot $snapshot -Postflight $null `
                -IssueNumber $IssueNumber -LogPath $lp -RemainingProblems @($route.reason) -Extra @{ reason = $route.reason; hint = $route.hint }
        }

        # 워커 실행. 최초·fallback·review·repair가 같은 공통 오류 정책을 사용한다.
        $runId = [guid]::NewGuid().ToString('N')
        $invokePrimary = { Invoke-RouteWorker -Route $route -RepoPath $RepoPath -PromptPath $tempOrderPath -Config $config -GrokRunner $GrokRunner -GptRunner $GptRunner `
            -OperationNumber $OperationNumber -IssueNumber $IssueNumber -Kind $Kind -Snapshot $snapshot -RunId $runId }
        $execution = Invoke-WorkerWithErrorPolicy -Provider $route.worker -InvokeWorker $invokePrimary -State $state -Config $config -Log $log
        $result = $execution.Result
        if ($execution.ErrorClass -eq 'execution_pending') {
            $receipt = $result.ExecutionReceipt
            $pendingStatus = if ($result.AlreadyActive) { 'execution_already_active' } else { [string]$receipt.status }
            $extra = @{ executionId = $receipt.executionId; generation = $receipt.generation; startedAt = $receipt.startedAt
                logPath = $receipt.logPath; resumeCommand = "/operation recover $OperationNumber $IssueNumber" }
            return New-FinalOutput -Operation $OperationNumber -RouteLabel (New-RouteLabel -Route $route) -Status $pendingStatus `
                -Worker $route.worker -Model $route.model -Effort $route.effort -Snapshot $snapshot -Postflight $null `
                -IssueNumber $IssueNumber -LogPath $receipt.logPath -RemainingProblems @('worker execution has not reached postflight') -Extra $extra
        }
        $log.Add("worker=$($route.worker) model=$($route.model) effort=$($route.effort) exit=$($result.ExitCode) quota=$($result.QuotaExhausted)")
        $log.Add($result.Output)

        $effectiveRoute = $route

        # 주간 플랜 소진(weekly_exhausted) 시에만 fallback 검토 (transient·인증·결제·일반 오류는 절대 fallback 안 함)
        if (-not $execution.Success -and $execution.ErrorClass -eq 'weekly_exhausted') {
            $change = Test-WorkerChangedRepo -RepoPath $RepoPath -StartSnapshot $snapshot
            if ($change.changed) {
                # 부분 변경 발생 -> fallback 금지, reset/stash 금지
                $log.Add("partial changes detected (headChanged=$($change.headChanged) dirty=$($change.worktreeDirty) newCommits=$($change.newCommits)) -> fallback withheld")
                $lp = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber" -Content ($log -join "`n")
                $extra = @{ fallbackAttempted = $false; headChanged = $change.headChanged; worktreeDirty = $change.worktreeDirty; newCommits = $change.newCommits }
                return New-FinalOutput -Operation $OperationNumber -RouteLabel 'partial' -Status 'partial_worker_changes' `
                    -Worker $route.worker -Model $route.model -Effort $route.effort -Snapshot $snapshot -Postflight $null `
                    -IssueNumber $IssueNumber -LogPath $lp -RemainingProblems (Get-RemainingProblems -Status 'partial_worker_changes') -Extra $extra
            }
            # 변경 없음 -> 안전하게 fallback
            $rerouted = Invoke-QuotaFallback -Route $route -OperationNumber $OperationNumber -IssueNumber $IssueNumber -Kind $Kind -State $state `
                -Config $config -RepoPath $RepoPath -PromptPath $tempOrderPath -Order $order -Snapshot $snapshot `
                -GptRunner $GptRunner -ClaudeImplementer $ClaudeImplementer -CiProbe $CiProbe `
                -UseGptReviewReserve:$UseGptReviewReserve -FinishCurrent:$FinishCurrent -Log $log -FallbackProviders @($route.worker) -RunId $runId
            if ($null -ne $rerouted.TerminalOutput) {
                $rerouted.TerminalOutput.logPath = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber" -Content ($log -join "`n")
                return $rerouted.TerminalOutput
            }
            $result = $rerouted.Result
            $effectiveRoute = $rerouted.Route
        } elseif (-not $execution.Success) {
            $lp = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber" -Content ($log -join "`n")
            return New-WorkerPolicyFailureOutput -OperationNumber $OperationNumber -IssueNumber $IssueNumber -Route $route `
                -Snapshot $snapshot -Execution $execution -LogPath $lp -FallbackAttempted $false
        }

        # postflight
        $pf = Resolve-Postflight -RepoPath $RepoPath -StartSnapshot $snapshot -WorkerResult $result -DeclaredNoCodeChange:$false -CiProbe $CiProbe
        # 영수증을 저장하기 전에 watched critical-file 위반을 확정한다. 위반이면 영수증 status도
        # repo_boundary_violation으로 저장해, 보안 위반 run이 completed 영수증으로 남아 review 자격을
        #통과하는 결함을 막는다(finalizer는 출력만 고쳤음).
        $runBoundaryViol = @()
        if ($snapshot -and ($snapshot.PSObject.Properties.Name -contains 'boundaryWatch')) {
            $runBoundaryViol = @(Test-RepoBoundaryViolation -BeforeSnapshot $snapshot.boundaryWatch)
        }
        $receiptStatus = if ($runBoundaryViol.Count -gt 0) { 'repo_boundary_violation' } else { $pf.status }
        $executionRemaining = @(Get-RemainingProblems -Status $receiptStatus -Postflight $pf)
        if ($result.PSObject.Properties.Name -contains 'ExecutionReceipt' -and $null -ne $result.ExecutionReceipt) {
            $er = Get-ExecutionReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
            if ($null -ne $er -and [string]$er.executionId -eq [string]$result.ExecutionReceipt.executionId) {
                $er.status = $receiptStatus; $er.finalHead = $pf.finalHead; $er.workerExitCode = $result.ExitCode
                $er.workerStopReason = $result.WorkerStopReason; $er.postflight = $pf
                $er.interrupted = $false; $er.recoveredByPostflight = $false
                $er.workerReportedVerification = if ($result.PSObject.Properties.Name -contains 'WorkerReportedVerification' -and $null -ne $result.WorkerReportedVerification) { Protect-SecretText -Text ([string]$result.WorkerReportedVerification) } else { $null }
                $er.localVerificationComplete = if ($result.PSObject.Properties.Name -contains 'LocalVerificationComplete') { [bool]$result.LocalVerificationComplete } else { $false }
                $er.resultEnvelopePresent = $true; $er.verificationProvenance = 'valid_worker_result_envelope'
                $er.remainingProblems = @(Get-RemainingProblems -Status $receiptStatus -Postflight $pf)
                $er = Complete-ExecutionTerminalArtifacts -Receipt $er -RepoPath $RepoPath -IntendedStatus $receiptStatus
                $receiptStatus = [string]$er.status; $executionRemaining = @($er.remainingProblems)
            }
        }
        # 작전 1 실행 영수증은 artifact finalization까지 성공한 정상 결과에만 review 자격과 함께 저장한다.
        if ($OperationNumber -eq 1 -and $effectiveRoute.worker -in @('grok','gpt') -and $receiptStatus -notin @('artifact_sanitization_failed','artifact_retention_failed')) {
            $runLocalVerification = if($result.PSObject.Properties.Name -contains 'LocalVerificationComplete'){[bool]$result.LocalVerificationComplete}else{$false}
            $rcPath = Save-RunReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath -Snapshot $snapshot -Postflight $pf `
                -Route $effectiveRoute -WorkerResult $result -StatusOverride $receiptStatus -RemainingProblems $executionRemaining `
                -ResultEnvelopePresent $true -Interrupted $false -LocalVerificationComplete $runLocalVerification `
                -RecoveredByPostflight $false -VerificationProvenance 'valid_worker_result_envelope'
            $log.Add("op1 run receipt saved: $rcPath (status=$receiptStatus)")
        }
        $lp = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber" -Content ($log -join "`n")
        return New-FinalOutput -Operation $OperationNumber -RouteLabel (New-RouteLabel -Route $effectiveRoute) -Status $receiptStatus `
            -Worker $effectiveRoute.worker -Model $effectiveRoute.model -Effort $effectiveRoute.effort `
            -Snapshot $snapshot -Postflight $pf -IssueNumber $IssueNumber -LogPath $lp `
            -RemainingProblems $executionRemaining `
            -Extra @{ interrupted=$false; recoveredByPostflight=$false
                workerReportedVerification=if($result.PSObject.Properties.Name -contains 'WorkerReportedVerification' -and $null -ne $result.WorkerReportedVerification){Protect-SecretText -Text ([string]$result.WorkerReportedVerification)}else{$null}
                localVerificationComplete=if($result.PSObject.Properties.Name -contains 'LocalVerificationComplete'){[bool]$result.LocalVerificationComplete}else{$false}
                resultEnvelopePresent=$true; verificationProvenance='valid_worker_result_envelope' }
    }
    finally {
        Remove-TempOrderFile -Path $tempOrderPath
    }
}

# 실행 세대 result envelope를 기존 WorkerResult 형태로 복원한다.
function ConvertFrom-ExecutionResult {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$RepoPath)
    if (-not (Test-Path -LiteralPath ([string]$Receipt.resultPath))) { return $null }
    $envelope = Read-JsonFile -Path ([string]$Receipt.resultPath)
    if ([string]$envelope.executionId -ne [string]$Receipt.executionId -or [int]$envelope.generation -ne [int]$Receipt.generation) { return $null }
    $stdoutPath = if ($envelope.PSObject.Properties.Name -contains 'stdoutPath' -and $envelope.stdoutPath) { [string]$envelope.stdoutPath } elseif ($Receipt.PSObject.Properties.Name -contains 'stdoutPath' -and $Receipt.stdoutPath) { [string]$Receipt.stdoutPath } elseif ($Receipt.PSObject.Properties.Name -contains 'rawStdoutPath') { [string]$Receipt.rawStdoutPath } else { $null }
    $stderrPath = if ($envelope.PSObject.Properties.Name -contains 'stderrPath' -and $envelope.stderrPath) { [string]$envelope.stderrPath } elseif ($Receipt.PSObject.Properties.Name -contains 'stderrPath' -and $Receipt.stderrPath) { [string]$Receipt.stderrPath } elseif ($Receipt.PSObject.Properties.Name -contains 'rawStderrPath') { [string]$Receipt.rawStderrPath } else { $null }
    $output = ''
    if ($stdoutPath) { $output += Read-SharedTextFile -Path $stdoutPath }
    if ($stderrPath) { $output += Read-SharedTextFile -Path $stderrPath }
    $workerResult = [pscustomobject]@{
        Worker = $Receipt.worker; ExitCode = [int]$envelope.exitCode; Success = [bool]$envelope.success
        QuotaExhausted = [bool]$envelope.quotaExhausted; ErrorClass = [string]$envelope.errorClass
        WorkerStopReason = $envelope.workerStopReason; Output = $output; ExecutionReceipt = $Receipt
        WorkerReportedVerification = if ($envelope.PSObject.Properties.Name -contains 'workerReportedVerification') { $envelope.workerReportedVerification } else { $null }
        LocalVerificationComplete = if ($envelope.PSObject.Properties.Name -contains 'localVerificationComplete') { [bool]$envelope.localVerificationComplete } else { $false }
    }
    if (-not $workerResult.Success) {
        $Receipt.status = if ([string]::IsNullOrWhiteSpace($workerResult.ErrorClass)) { 'worker_failed' } else { [string]$workerResult.ErrorClass }
        $Receipt.workerExitCode = $workerResult.ExitCode; $Receipt.workerStopReason = $workerResult.WorkerStopReason
        $Receipt = Complete-ExecutionTerminalArtifacts -Receipt $Receipt -RepoPath $RepoPath -IntendedStatus ([string]$Receipt.status)
    }
    return $workerResult
}

function New-ExecutionPendingResult {
    param([Parameter(Mandatory)]$Receipt, [bool]$AlreadyActive = $false)
    return [pscustomobject]@{
        Worker = $Receipt.worker; ExitCode = $null; Success = $false; QuotaExhausted = $false
        ErrorClass = 'execution_pending'; WorkerStopReason = $null; Output = ''; ExecutionPending = $true
        AlreadyActive = $AlreadyActive; ExecutionReceipt = $Receipt
    }
}

function Write-InjectedExecutionResult {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)]$WorkerResult, [Parameter(Mandatory)][string]$RepoPath)
    $candidates = @(@($WorkerResult) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['ExitCode'] })
    if ($candidates.Count -eq 0) { throw 'Injected worker result is missing ExitCode.' }
    $WorkerResult = $candidates[-1]
    $output = ''; if ($WorkerResult.PSObject.Properties.Name -contains 'Output') { $output = [string]$WorkerResult.Output }
    [System.IO.File]::WriteAllText([string]$Receipt.rawStdoutPath, $output, (New-Object System.Text.UTF8Encoding($false)))
    $header = Read-SharedTextFile -Path ([string]$Receipt.logPath)
    [System.IO.File]::WriteAllText([string]$Receipt.logPath, ($header + "`ncliStarted=true`n`n" + (Protect-SecretText -Text $output)), (New-Object System.Text.UTF8Encoding($false)))
    $errorClass = Get-WorkerResultErrorClass -Result $WorkerResult
    $stopReason = $null; if ($WorkerResult.PSObject.Properties.Name -contains 'WorkerStopReason') { $stopReason = $WorkerResult.WorkerStopReason }
    $quota = ($errorClass -eq 'weekly_exhausted')
    if ($WorkerResult.PSObject.Properties.Name -contains 'QuotaExhausted') { $quota = [bool]$WorkerResult.QuotaExhausted }
    $verification = $null
    if ($WorkerResult.PSObject.Properties.Name -contains 'WorkerReportedVerification' -and $null -ne $WorkerResult.WorkerReportedVerification) {
        $verification = Protect-SecretText -Text ([string]$WorkerResult.WorkerReportedVerification)
    }
    $localVerificationComplete = $false
    if ($WorkerResult.PSObject.Properties.Name -contains 'LocalVerificationComplete') { $localVerificationComplete = [bool]$WorkerResult.LocalVerificationComplete }
    $sanitized = Complete-ExecutionArtifactSanitization -Receipt $Receipt
    $Receipt = $sanitized.receipt
    if (-not $sanitized.success) {
        $Receipt.status = 'artifact_sanitization_failed'
        $Receipt.remainingProblems = @('execution artifact sanitization failed: ' + [string]$sanitized.error)
        Save-ExecutionReceipt -Receipt $Receipt -RepoPath $RepoPath | Out-Null
        Write-ExecutionGenerationMarker -Receipt $Receipt -Status $Receipt.status
        try { Invoke-ExecutionRetention -Receipt $Receipt | Out-Null } catch {
            $Receipt.remainingProblems += ('execution retention failed: ' + (Protect-SecretText -Text ([string]$_.Exception.Message)))
            Save-ExecutionReceipt -Receipt $Receipt -RepoPath $RepoPath | Out-Null
        }
        throw 'Execution artifact sanitization failed.'
    }
    $envelope = [pscustomobject]@{
        schemaVersion = 1; executionId = $Receipt.executionId; generation = $Receipt.generation; worker = $Receipt.worker
        exitCode = $WorkerResult.ExitCode; success = [bool]$WorkerResult.Success; quotaExhausted = [bool]$quota
        errorClass = $errorClass; workerStopReason = $stopReason; workerReportedVerification = $verification
        localVerificationComplete = $localVerificationComplete; stdoutPath = $Receipt.stdoutPath; stderrPath = $Receipt.stderrPath
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-AtomicJsonFile -Path ([string]$Receipt.resultPath) -Object $envelope
    $Receipt.status = 'worker_exited_postflight_pending'; $Receipt.workerExitCode = $WorkerResult.ExitCode; $Receipt.workerStopReason = $stopReason
    Save-ExecutionReceipt -Receipt $Receipt -RepoPath $RepoPath | Out-Null
}

function Start-ExecutionWorkerHost {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)]$Route, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$RepoPath)
    if ($Route.worker -eq 'grok') {
        $inv = Get-GrokWorkerInvocation -Cwd $RepoPath -Model $Route.model -Effort $Route.effort -MaxTurns $Route.maxTurns `
            -PromptFilePath $Receipt.promptPath -NoPlan:$Route.noPlan -NoSubagents:$Route.noSubagents
    } else {
        $inv = Get-GptWorkerInvocation -Cwd $RepoPath -Model $Route.model -Effort $Route.effort -PromptFilePath $Receipt.promptPath `
            -Sandbox $Config.gpt.sandbox -ApprovalPolicy $Config.gpt.approvalPolicy
    }
    $payload = [pscustomobject]@{
        schemaVersion = 1; executionId = $Receipt.executionId; generation = $Receipt.generation
        filePath = $inv.filePath; argumentList = @($inv.argumentList); stdinMode = $inv.stdinMode; promptPath = $Receipt.promptPath
    }
    Write-AtomicJsonFile -Path ([string]$Receipt.invocationPath) -Object $payload
    $hostPath = Join-Path $PSScriptRoot 'worker-host.ps1'
    $receiptPath = Get-ExecutionReceiptPath -Operation $Receipt.operation -IssueNumber $Receipt.issueNumber -RepoPath $RepoPath
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $hostPath + '"'),
        '-ExecutionReceiptPath',('"' + $receiptPath + '"'),'-InvocationPath',('"' + $Receipt.invocationPath + '"'),
        '-PendingDirOverride',('"' + $Script:PendingDir + '"'),'-LogRootOverride',('"' + $Script:LogRoot + '"'),
        '-ConfigPathOverride',('"' + $Script:ConfigPath + '"'))
    return (Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $RepoPath -PassThru -WindowStyle Hidden)
}

function Invoke-PersistentRouteWorker {
    param(
        [Parameter(Mandatory)]$Route, [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$RunId,
        [scriptblock]$InjectedRunner
    )
    $lock = Open-ExecutionLock -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
    if ($null -eq $lock) {
        $existing = Get-ExecutionReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
        if ($null -eq $existing) { throw 'Execution lock is held but no receipt is readable.' }
        if ($existing.PSObject.Properties.Name -contains 'legacyNamespaceBlocked') {
            return [pscustomobject]@{ status='repository_receipt_mismatch'; workerCalls=0
                reason=[string]$existing.legacyNamespaceReason; operation=$OperationNumber; issueNumber=$IssueNumber }
        }
        return New-ExecutionPendingResult -Receipt $existing -AlreadyActive $true
    }
    try {
        $existing = Get-ExecutionReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
        if ($null -ne $existing -and ($existing.PSObject.Properties.Name -contains 'legacyNamespaceBlocked')) {
            return [pscustomobject]@{ status='repository_receipt_mismatch'; workerCalls=0
                reason=[string]$existing.legacyNamespaceReason; operation=$OperationNumber; issueNumber=$IssueNumber }
        }
        if ($null -ne $existing -and (Test-ExecutionStatusActive -Status ([string]$existing.status))) {
            return New-ExecutionPendingResult -Receipt $existing -AlreadyActive $true
        }
        # v2.4.3 세대 무효화는 실제 새 구현 worker 세대를 만들 때만 수행한다. 활성 실행 중복 호출은
        # 새 worker를 시작하지 않으므로 기존 run/review 영수증도 건드리지 않는다.
        if ($OperationNumber -eq 1) {
            Remove-RunReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
            Remove-ReviewReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
        }
        $prompt = Get-Content -LiteralPath $PromptPath -Raw -Encoding UTF8
        $receipt = New-ExecutionGeneration -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath -Kind $Kind `
            -Snapshot $Snapshot -Route $Route -PromptContent $prompt -RunId $RunId
        if ($null -ne $InjectedRunner) {
            $receipt.status = 'worker_running'; $receipt.processId = $PID
            $receipt.processStartedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
            Save-ExecutionReceipt -Receipt $receipt -RepoPath $RepoPath | Out-Null
            $workerResult = & $InjectedRunner $Route $RepoPath $receipt.promptPath
            Write-InjectedExecutionResult -Receipt $receipt -WorkerResult $workerResult -RepoPath $RepoPath
            $receipt = Get-ExecutionReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
            return ConvertFrom-ExecutionResult -Receipt $receipt -RepoPath $RepoPath
        }
        $null = Start-ExecutionWorkerHost -Receipt $receipt -Route $Route -Config $Config -RepoPath $RepoPath
    } finally { $lock.Dispose() }
    $waitSeconds = 480; $pollMs = 500
    if ($Config.PSObject.Properties.Name -contains 'execution') {
        if ($Config.execution.PSObject.Properties.Name -contains 'foregroundWaitSeconds') { $waitSeconds = [Math]::Max(0, [int]$Config.execution.foregroundWaitSeconds) }
        if ($Config.execution.PSObject.Properties.Name -contains 'pollIntervalMilliseconds') { $pollMs = [Math]::Max(100, [int]$Config.execution.pollIntervalMilliseconds) }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($waitSeconds)
    do {
        # worker-host가 Write-AtomicJsonFile의 File.Replace로 영수증을 교체하는 찰나에는
        # Test-Path가 false가 되어 Get-ExecutionReceipt가 null을 돌려줄 수 있다. 그 순간의 null은
        # "아직 준비 안 됨"이므로 에러 없이 다음 폴링으로 넘긴다 (필수 파라미터에 null 전달 금지).
        $current = Get-ExecutionReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
        if ($null -ne $current) {
            $ready = ConvertFrom-ExecutionResult -Receipt $current -RepoPath $RepoPath
            if ($null -ne $ready) { return $ready }
            if ([DateTime]::UtcNow -ge $deadline) { return New-ExecutionPendingResult -Receipt $current }
        } elseif ([DateTime]::UtcNow -ge $deadline) {
            # 마감 시각에도 영수증이 순간적으로 사라진 상태면 짧게 한 번 더 재시도한다.
            Start-Sleep -Milliseconds $pollMs
            $current = Get-ExecutionReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
            if ($null -ne $current) { return New-ExecutionPendingResult -Receipt $current }
            throw 'Execution receipt is not readable at deadline (transient atomic-replace window did not settle).'
        }
        Start-Sleep -Milliseconds $pollMs
    } while ($true)
}

# 워커 1회 실행 (mock 주입 가능)
function Invoke-RouteWorker {
    param([Parameter(Mandatory)]$Route, [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$PromptPath,
          [Parameter(Mandatory)]$Config, [scriptblock]$GrokRunner, [scriptblock]$GptRunner,
          [int]$OperationNumber = 0, [int]$IssueNumber = 0, [string]$Kind = 'logic', $Snapshot, [string]$RunId)
    if ($OperationNumber -gt 0 -and $IssueNumber -gt 0 -and $null -ne $Snapshot) {
        $injected = if ($Route.worker -eq 'grok') { $GrokRunner } else { $GptRunner }
        return Invoke-PersistentRouteWorker -Route $Route -RepoPath $RepoPath -PromptPath $PromptPath -Config $Config `
            -OperationNumber $OperationNumber -IssueNumber $IssueNumber -Kind $Kind -Snapshot $Snapshot -RunId $RunId -InjectedRunner $injected
    }
    if ($Route.worker -eq 'grok') {
        if ($null -eq $GrokRunner) {
            $GrokRunner = { param($r,$repo,$prompt) Invoke-GrokWorker -Cwd $repo -Model $r.model -Effort $r.effort -MaxTurns $r.maxTurns -PromptFilePath $prompt -NoPlan $r.noPlan -NoSubagents $r.noSubagents }
        }
        return (& $GrokRunner $Route $RepoPath $PromptPath)
    }
    if ($null -eq $GptRunner) {
        $GptRunner = { param($r,$repo,$prompt) Invoke-GptWorker -Cwd $repo -Model $r.model -Effort $r.effort -PromptFilePath $prompt -Sandbox $Config.gpt.sandbox -ApprovalPolicy $Config.gpt.approvalPolicy }
    }
    return (& $GptRunner $Route $RepoPath $PromptPath)
}

# 안전 fallback: 워커를 exhausted로 표시, 재라우팅. GPT로 넘어가거나 claude 실행/지시로 종료.
# 원래 operation/issueNumber/kind를 그대로 유지한다 (이슈 0/null 금지).
function Invoke-QuotaFallback {
    param([Parameter(Mandatory)]$Route, [Parameter(Mandatory)][int]$OperationNumber,
          [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$Kind,
          [Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$RepoPath,
          [Parameter(Mandatory)][string]$PromptPath, [Parameter(Mandatory)][string]$Order, [Parameter(Mandatory)]$Snapshot,
          [scriptblock]$GptRunner, [scriptblock]$ClaudeImplementer, [scriptblock]$CiProbe,
          [switch]$UseGptReviewReserve, [switch]$FinishCurrent, [Parameter(Mandatory)]$Log,
          [string[]]$FallbackProviders = @(), [string]$RunId)
    if ($IssueNumber -le 0) { throw "Invoke-QuotaFallback: issue number must be positive (got $IssueNumber)." }
    $Log.Add("$($Route.worker) weekly exhaustion handled; re-resolving route (issue=$IssueNumber)")

    $newRoute = Resolve-OperationRoute -OperationNumber $OperationNumber -Kind $Kind -Purpose implement `
        -GrokState $State.grok -GptState $State.gpt -Config $Config `
        -UseGptReviewReserve:$UseGptReviewReserve -FinishCurrent:$FinishCurrent

    if ($newRoute.status -eq 'claude_direct') {
        $target = Get-ClaudeTarget -Operation $OperationNumber -Kind $Kind -Config $Config
        $out = Invoke-ClaudeExecution -Operation $OperationNumber -IssueNumber $IssueNumber -Kind $Kind `
            -RepoPath $RepoPath -Target $target -Order $Order -Snapshot $Snapshot -Mode 'claude-direct' `
            -ClaudeImplementer $ClaudeImplementer -CiProbe $CiProbe -Log $Log
        return @{ TerminalOutput = $out; Result = $null; Route = $newRoute }
    }
    if ($newRoute.status -eq 'claude_only_required') {
        $extra = @{ requiredModel = $newRoute.requiredModel; requiredEffort = $newRoute.requiredEffort; rerouted = $true
                    resumeCommand = (Get-ResumeCommand -Operation $OperationNumber -IssueNumber $IssueNumber -Kind $Kind) }
        $out = New-FinalOutput -Operation $OperationNumber -RouteLabel (New-RouteLabel -Route $newRoute) -Status $newRoute.status `
            -Worker 'claude' -Model $newRoute.requiredModel -Effort $newRoute.requiredEffort -Snapshot $Snapshot -Postflight $null `
            -IssueNumber $IssueNumber -LogPath $null -Extra $extra
        return @{ TerminalOutput = $out; Result = $null; Route = $newRoute }
    }
    if ($newRoute.status -eq 'routed' -and $newRoute.worker -eq 'gpt') {
        if ($FallbackProviders -contains $newRoute.worker) {
            $out = New-FinalOutput -Operation $OperationNumber -RouteLabel 'fallback-loop-blocked' -Status 'fallback_loop_blocked' `
                -Worker $newRoute.worker -Model $newRoute.model -Effort $newRoute.effort -Snapshot $Snapshot -Postflight $null `
                -IssueNumber $IssueNumber -LogPath $null -RemainingProblems (Get-RemainingProblems -Status 'fallback_loop_blocked') `
                -Extra @{ fallbackProviders = @($FallbackProviders); ciStatus = 'not-checked' }
            return @{ TerminalOutput = $out; Result = $null; Route = $newRoute }
        }
        $nextHistory = @($FallbackProviders) + @($newRoute.worker)
        $invokeFallback = { Invoke-RouteWorker -Route $newRoute -RepoPath $RepoPath -PromptPath $PromptPath -Config $Config -GptRunner $GptRunner `
            -OperationNumber $OperationNumber -IssueNumber $IssueNumber -Kind $Kind -Snapshot $Snapshot -RunId $RunId }
        $execution = Invoke-WorkerWithErrorPolicy -Provider 'gpt' -InvokeWorker $invokeFallback -State $State -Config $Config -Log $Log
        $result = $execution.Result
        if ($execution.ErrorClass -eq 'execution_pending') {
            $receipt = $result.ExecutionReceipt
            $status = if ($result.AlreadyActive) { 'execution_already_active' } else { [string]$receipt.status }
            $out = New-FinalOutput -Operation $OperationNumber -RouteLabel (New-RouteLabel -Route $newRoute) -Status $status `
                -Worker $newRoute.worker -Model $newRoute.model -Effort $newRoute.effort -Snapshot $Snapshot -Postflight $null `
                -IssueNumber $IssueNumber -LogPath $receipt.logPath -RemainingProblems @('worker execution has not reached postflight') `
                -Extra @{ executionId=$receipt.executionId; generation=$receipt.generation; resumeCommand="/operation recover $OperationNumber $IssueNumber" }
            return @{ TerminalOutput = $out; Result = $null; Route = $newRoute }
        }
        $Log.Add("worker=gpt(rerouted) model=$($newRoute.model) exit=$($result.ExitCode)")
        $Log.Add($result.Output)
        if (-not $execution.Success -and $execution.ErrorClass -eq 'weekly_exhausted') {
            $change = Test-WorkerChangedRepo -RepoPath $RepoPath -StartSnapshot $Snapshot
            if ($change.changed) {
                $out = New-FinalOutput -Operation $OperationNumber -RouteLabel 'partial' -Status 'partial_worker_changes' `
                    -Worker $newRoute.worker -Model $newRoute.model -Effort $newRoute.effort -Snapshot $Snapshot -Postflight $null `
                    -IssueNumber $IssueNumber -LogPath $null -RemainingProblems (Get-RemainingProblems -Status 'partial_worker_changes') `
                    -Extra @{ fallbackAttempted = $true; fallbackProviders = $nextHistory; headChanged = $change.headChanged
                              worktreeDirty = $change.worktreeDirty; newCommits = $change.newCommits; ciStatus = 'not-checked' }
                return @{ TerminalOutput = $out; Result = $null; Route = $newRoute }
            }
            return Invoke-QuotaFallback -Route $newRoute -OperationNumber $OperationNumber -IssueNumber $IssueNumber -Kind $Kind `
                -State $State -Config $Config -RepoPath $RepoPath -PromptPath $PromptPath -Order $Order -Snapshot $Snapshot `
                -GptRunner $GptRunner -ClaudeImplementer $ClaudeImplementer -CiProbe $CiProbe `
                -UseGptReviewReserve:$UseGptReviewReserve -FinishCurrent:$FinishCurrent -Log $Log -FallbackProviders $nextHistory -RunId $RunId
        }
        if (-not $execution.Success) {
            $out = New-WorkerPolicyFailureOutput -OperationNumber $OperationNumber -IssueNumber $IssueNumber -Route $newRoute `
                -Snapshot $Snapshot -Execution $execution -LogPath $null -FallbackAttempted $true
            return @{ TerminalOutput = $out; Result = $null; Route = $newRoute }
        }
        return @{ TerminalOutput = $null; Result = $result; Route = $newRoute }
    }
    # 그 밖 (blocked 등)
    $out = New-FinalOutput -Operation $OperationNumber -RouteLabel (New-RouteLabel -Route $newRoute) -Status $newRoute.status `
        -Worker $null -Model $null -Effort $null -Snapshot $Snapshot -Postflight $null -IssueNumber $IssueNumber -LogPath $null
    return @{ TerminalOutput = $out; Result = $null; Route = $newRoute }
}

# ---------------- 작전 1: 실제 검수 (v2.2: run 영수증 자동 복원) ----------------
# run 영수증(state/pending/op<N>-issue<X>-run.json)을 자동으로 읽어 startHead/finalHead/작업자·모델·effort/
# postflight/workerSummary를 검수 프롬프트에 넣는다. -StartHead 수동 입력은 필요 없다.
# 영수증이 없거나 현재 HEAD가 영수증 finalHead와 다르면 검수를 중단한다.
# GPT 호출 실패 처리: quota → claude_review_fallback, 일반/인증/네트워크 실패 → review_worker_failed,
# 종료코드 0 + 잘못된 JSON → review_parse_failed (fail-closed). 실행 실패를 코드 결함 finding으로 위장하지 않는다.
function Invoke-OperationReview {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Kind = 'logic',
        [switch]$UseGptReviewReserve,
        [scriptblock]$IssueFetcher, [scriptblock]$GptReviewRunner
    )
    # 검수 워커 실행 후 watched critical-file 변화를 공통 finalizer로 판정한다. 진입 시 스냅샷을 캡처하고
    # 본문의 모든 반환을 하나의 결과로 모아 finalizer를 통과시킨다(자격 조기 반환 포함, 위반 없으면 무변경).
    $__reviewBoundary = Get-BoundarySnapshot
    $__reviewResult = & {
    $config = Get-Config

    # 0) v2.3 검수 실행 자격 강제: 작전 1이 아니면 GPT를 호출하지 않는다
    if ($OperationNumber -ne 1) {
        return [pscustomobject]@{ status = 'review_not_eligible'; verdict = $null; findings = @()
            reason = 'operation_not_1'; note = 'GPT Sol 독립 검수는 작전 1 전용이다. 작전 2/3은 review를 지원하지 않는다.' }
    }

    # 1) run 영수증 자동 복원 (StartHead 수동 인수 금지)
    $receipt = Get-RunReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
    $runEligibility = Test-RunReceiptVerificationEligible -Receipt $receipt -RepoPath $RepoPath
    if (-not $runEligibility.eligible) {
        if ($runEligibility.status -eq 'run_receipt_missing') {
            return [pscustomobject]@{ status = 'review_receipt_missing'; verdict = $null; findings = @()
                reason = $runEligibility.reason; note = $runEligibility.note
                expectedReceiptPath = (Get-RunReceiptPath -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath) }
        }
        if ($runEligibility.status -eq 'run_receipt_repository_mismatch') {
            return [pscustomobject]@{ status = 'repository_receipt_mismatch'; verdict = $null; findings = @()
                reason = $runEligibility.reason; note = $runEligibility.note }
        }
        $reviewReason = [string]$runEligibility.reason
        if ($runEligibility.status -eq 'run_result_unverified') { $reviewReason = 'recovered_result_missing_or_unverified' }
        return [pscustomobject]@{ status = 'review_not_eligible'; verdict = $null; findings = @()
            reason = $reviewReason; note = $runEligibility.note }
    }
    # 6) 현재 HEAD == 영수증 finalHead
    $currentHead = Get-GitHead -Path $RepoPath
    if ($currentHead -ne $receipt.finalHead) {
        return [pscustomobject]@{ status = 'review_receipt_head_mismatch'; verdict = $null; findings = @()
            note = '현재 HEAD가 run 영수증의 finalHead와 다르다. 검수를 중단한다.'
            receiptFinalHead = $receipt.finalHead; currentHead = $currentHead }
    }
    $startHead = $receipt.startHead
    $finalHead = $receipt.finalHead

    # 2) 검수 경로 (Sol 전용, 사용량 준수)
    $state = Get-UsageState
    $route = Resolve-OperationRoute -OperationNumber $OperationNumber -Kind $Kind -Purpose review `
        -GrokState $state.grok -GptState $state.gpt -Config $config -UseGptReviewReserve:$UseGptReviewReserve
    if ($route.status -ne 'routed' -or $route.worker -ne 'gpt') {
        # 검수 불가 -> 현재 세션이 고위험 항목만 직접 종료 검토
        return [pscustomobject]@{ status = 'claude_review_fallback'; verdict = $null; findings = @(); reason = $route.reason; reviewWorker = $null
            startHead = $startHead; finalHead = $finalHead }
    }

    if ($null -eq $IssueFetcher) {
        $IssueFetcher = { param($num, $path) $out = & gh issue view $num --json body -q .body 2>&1; if ($LASTEXITCODE -ne 0) { throw "gh issue view failed: $out" }; return ($out | Out-String) }
    }
    $issueBody = & $IssueFetcher $IssueNumber $RepoPath
    $changed = Get-GitChangedFiles -Path $RepoPath -SinceHead $startHead
    $diff = Get-GitDiff -Path $RepoPath -SinceHead $startHead

    # 3) 실제 완료 자료를 검수 프롬프트에 포함 (README가 주장하는 postflight 전체)
    $pfr = $receipt.postflight
    $workerSummary = ''
    if ($receipt.PSObject.Properties.Name -contains 'workerSummary' -and $null -ne $receipt.workerSummary) { $workerSummary = [string]$receipt.workerSummary }
    $remaining = @()
    if ($receipt.PSObject.Properties.Name -contains 'remainingProblems' -and $null -ne $receipt.remainingProblems) { $remaining = @($receipt.remainingProblems) }

    $reviewPrompt = @"
[독립 검수 요청 — 반드시 아래 JSON 스키마로만 응답한다]
{
  "verdict": "PASS|REPAIR_REQUIRED",
  "findings": [
    { "severity": "blocker|high|medium", "file": "path", "issue": "description", "requiredFix": "description" }
  ]
}
설명 문장 없이 JSON 객체 하나만 출력한다. 결함이 없으면 findings는 빈 배열이고 verdict는 PASS.
결함이 있으면 verdict는 REPAIR_REQUIRED이고 findings는 비어 있지 않아야 한다.
모든 finding은 severity(blocker|high|medium), file, 비어 있지 않은 issue, 비어 있지 않은 requiredFix를 가져야 한다.

[시작 HEAD] $startHead
[최종 HEAD] $finalHead
[작업자] worker=$($receipt.worker) model=$($receipt.model) effort=$($receipt.effort)
[worker 종료코드] $($pfr.workerExitCode)
[postflight]
commitCount=$($pfr.commitCount)
branch=$($pfr.branch)
ahead=$($pfr.ahead) behind=$($pfr.behind)
worktreeClean=$($pfr.worktreeClean)
pushComplete=$($pfr.pushComplete)
ciStatus=$($pfr.ciStatus)
runStatus=$($receipt.status)

[remainingProblems]
$($remaining -join "`n")

[변경 파일]
$($changed -join "`n")

[작업자 완료 보고 요약 — workerSummary. 작업자가 스스로 보고한 내용이며, 라우터가 재실행한 테스트 결과가 아니다]
$workerSummary

[GitHub 이슈 원문]
$issueBody

[변경 diff]
$diff
"@

    $promptPath = New-TempOrderFile -Content $reviewPrompt
    try {
        if ($null -eq $GptReviewRunner) {
            $GptReviewRunner = { param($repo, $prompt, $r) Invoke-GptWorker -Cwd $repo -Model $r.model -Effort $r.effort -PromptFilePath $prompt -Sandbox 'read-only' -ApprovalPolicy 'never' }
        }
        # v2.4.3: 실제 GPT 검수 호출 직전에 기존 review 영수증을 무효화한다. 새 검수가 경계 위반·실패로
        # 끝나면 이전 세대의 REPAIR_REQUIRED 영수증이 남아 repair가 그것을 재사용하는 것을 막는다.
        # 유효한 REPAIR_REQUIRED + 경계 위반 없음일 때만 아래 6)에서 새 영수증을 저장한다.
        Remove-ReviewReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
        $invokeReviewWorker = { & $GptReviewRunner $RepoPath $promptPath $route }
        $execution = Invoke-WorkerWithErrorPolicy -Provider 'gpt' -InvokeWorker $invokeReviewWorker -State $state -Config $config
        $res = $execution.Result

        # 4) JSON 파싱 전에 실행 결과부터 확인 (ExitCode/Success/QuotaExhausted/Output 존재)
        $resProps = @()
        if ($null -ne $res) { $resProps = $res.PSObject.Properties.Name }
        $exitCode = $null
        if ($resProps -contains 'ExitCode' -and $null -ne $res.ExitCode) { $exitCode = [int]$res.ExitCode }
        $outText = ''
        if ($resProps -contains 'Output' -and $null -ne $res.Output) { $outText = [string]$res.Output }
        if (-not $execution.Success -and $execution.ErrorClass -eq 'weekly_exhausted') {
            # GPT 검수 weekly 소진 -> 상태 저장 후 현재 세션 직접 검토로 전환한다.
            return [pscustomobject]@{ status = 'claude_review_fallback'; verdict = $null; findings = @()
                reason = 'gpt_review_weekly_exhausted'; reviewWorker = $route.model; exitCode = $exitCode
                startHead = $startHead; finalHead = $finalHead; errorClass = $execution.ErrorClass
                usageStateChanged = $true; attempts = $execution.Attempts }
        }
        if (-not $execution.Success) {
            $reviewStatus = switch ($execution.ErrorClass) {
                'transient_rate_limit' { 'review_transient_rate_limited'; break }
                'provider_failure'     { 'review_provider_failure'; break }
                'quota_unknown'        { 'review_quota_unknown'; break }
                default                { 'review_worker_failed' }
            }
            return [pscustomobject]@{ status = $reviewStatus; verdict = $null; findings = @()
                reviewWorker = $route.model; exitCode = $exitCode
                note = '검수 워커 오류를 별도 상태로 보고했다. 실행 실패를 코드 결함으로 위장하지 않는다.'
                startHead = $startHead; finalHead = $finalHead; errorClass = $execution.ErrorClass
                usageStateChanged = $false; attempts = $execution.Attempts }
        }

        # 5) 엄격 JSON 검증. 위반은 전부 review_parse_failed (fail-closed, PASS 아님)
        $parsed = ConvertFrom-StrictReviewJson -Text $outText
        if (-not $parsed.valid) {
            return [pscustomobject]@{ status = 'review_parse_failed'; verdict = $null; findings = @()
                parseError = $parsed.parseError; reviewWorker = $route.model; workerAlias = $route.workerAlias
                exitCode = $exitCode; startHead = $startHead; finalHead = $finalHead
                note = 'fail-closed: 검수 JSON이 스키마를 위반했다. PASS로 처리하지 않는다.' }
        }

        # 6) REPAIR_REQUIRED면 findings를 런타임 review 영수증에 저장 (repair가 자동 복원)
        # v2.4.2: 검수 실행 중 감시 파일이 변경됐다면 REPAIR_REQUIRED 영수증을 저장하지 않는다.
        # 저장 후 finalizer가 출력만 repo_boundary_violation으로 바꾸면 경계 위반 review 영수증이 남아
        # repair가 그것으로 실행될 수 있다. 영수증 자체를 만들지 않아 repair 자격을 원천 차단한다.
        $reviewReceiptPath = $null
        $reviewBoundaryViol = @(Test-RepoBoundaryViolation -BeforeSnapshot $__reviewBoundary)
        if ($parsed.verdict -eq 'REPAIR_REQUIRED' -and $reviewBoundaryViol.Count -eq 0) {
            $reviewReceiptPath = Save-ReviewReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath `
                -Verdict $parsed.verdict -Findings $parsed.findings -PostReviewHead $finalHead -OriginalWorker $receipt.worker
        }
        return [pscustomobject]@{
            status = 'reviewed'; verdict = $parsed.verdict; findings = @($parsed.findings)
            parseError = $null; reviewWorker = $route.model; workerAlias = $route.workerAlias
            startHead = $startHead; finalHead = $finalHead; exitCode = $exitCode
            reviewReceiptPath = $reviewReceiptPath
        }
    } finally {
        Remove-TempOrderFile -Path $promptPath
    }
    }
    return (Complete-BoundaryFinalizer -Result $__reviewResult -BoundarySnapshot $__reviewBoundary)
}

# ---------------- 작전 1: 단일 수리 (v2.2) ----------------
# 검수가 REPAIR_REQUIRED일 때, 원래 이슈 원문 + findings만 작업자에게 전달해 최대 1회 수리.
# - 수리 워커도 사용량 상태를 준수한다. 사용할 작업자가 없으면 repair_worker_unavailable로 중단하고
#   다른 작업자로 몰래 교체하지 않는다. 검수 예비분은 수리에 사용하지 않는다.
# - 수리 전 HEAD/worktree가 검수 직후 상태와 일치해야 한다. 재검수는 없다.
# - 수리 성공은 "남은 findings 없음"이 아니라 repair_completed_review_pending이다.
#   최종 PASS 판정은 현재 세션(Opus)의 종료 검토에서만 한다.
function Test-RepairFindingsSchema {
    param([AllowNull()]$Findings)
    $items = @($Findings)
    if ($items.Count -eq 0) { return [pscustomobject]@{ valid=$false; reason='findings_empty' } }
    foreach ($finding in $items) {
        if ($null -eq $finding) { return [pscustomobject]@{ valid=$false; reason='null_finding' } }
        $props = @($finding.PSObject.Properties.Name)
        if ($props -notcontains 'severity' -or [string]$finding.severity -notin @('blocker','high','medium')) { return [pscustomobject]@{ valid=$false; reason='invalid_finding_severity' } }
        if ($props -notcontains 'file' -or $null -eq $finding.file -or -not ($finding.file -is [string])) { return [pscustomobject]@{ valid=$false; reason='invalid_finding_file' } }
        if ($props -notcontains 'issue' -or [string]::IsNullOrWhiteSpace([string]$finding.issue)) { return [pscustomobject]@{ valid=$false; reason='invalid_finding_issue' } }
        if ($props -notcontains 'requiredFix' -or [string]::IsNullOrWhiteSpace([string]$finding.requiredFix)) { return [pscustomobject]@{ valid=$false; reason='invalid_finding_requiredFix' } }
    }
    return [pscustomobject]@{ valid=$true; reason=$null }
}

function Compare-ReviewFindings {
    param([AllowNull()]$Expected, [AllowNull()]$Actual)
    $expectedItems = @($Expected); $actualItems = @($Actual)
    $expectedSchema = Test-RepairFindingsSchema -Findings $expectedItems
    $actualSchema = Test-RepairFindingsSchema -Findings $actualItems
    if (-not $expectedSchema.valid -or -not $actualSchema.valid -or $expectedItems.Count -ne $actualItems.Count) { return $false }
    for ($i = 0; $i -lt $expectedItems.Count; $i++) {
        $actualProps = @($actualItems[$i].PSObject.Properties.Name)
        if ($actualProps.Count -ne 4 -or @($actualProps | Where-Object { $_ -notin @('severity','file','issue','requiredFix') }).Count -gt 0) { return $false }
        foreach ($field in @('severity','file','issue','requiredFix')) {
            if ([string]$expectedItems[$i].$field -cne [string]$actualItems[$i].$field) { return $false }
        }
    }
    return $true
}

function Get-EligibleRepairContext {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath,
        [bool]$HasFindingsAssertion=$false, [AllowNull()]$FindingsAssertion,
        [bool]$HasPostReviewHeadAssertion=$false, [string]$PostReviewHeadAssertion,
        [bool]$HasTargetAssertion=$false, [string]$TargetAssertion
    )
    $fail = {
        param([string]$Status, [string]$Reason, [string]$Note)
        return [pscustomobject]@{ eligible=$false; validated=$false; status=$Status; reason=$Reason; note=$Note; repairAttempted=$false }
    }
    if ($OperationNumber -ne 1) { return (& $fail 'repair_not_eligible' 'operation_not_1' '검수 기반 자동 수리는 작전 1 전용이다.') }
    $runReceipt = Get-RunReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
    $runEligibility = Test-RunReceiptVerificationEligible -Receipt $runReceipt -RepoPath $RepoPath
    if (-not $runEligibility.eligible) {
        if ($runEligibility.status -eq 'run_receipt_missing') { return (& $fail 'repair_receipt_missing' 'run_receipt_missing' $runEligibility.note) }
        if ($runEligibility.status -eq 'run_receipt_repository_mismatch') { return (& $fail 'repository_receipt_mismatch' 'run_receipt_repository_mismatch' $runEligibility.note) }
        return (& $fail 'repair_not_eligible' 'run_unverified_or_ineligible' $runEligibility.note)
    }
    $reviewReceipt = Get-ReviewReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
    if ($null -eq $reviewReceipt) { return (& $fail 'repair_receipt_missing' 'review_receipt_missing' '유효한 REPAIR_REQUIRED review 영수증이 필요하다.') }
    if (-not (Test-ReceiptRepoMatch -Receipt $reviewReceipt -RepoPath $RepoPath)) { return (& $fail 'repository_receipt_mismatch' 'review_receipt_repository_mismatch' '현재 저장소와 review 영수증의 저장소가 다르다.') }
    $reviewProps = @($reviewReceipt.PSObject.Properties.Name)
    foreach ($required in @('operation','verdict','findings','postReviewHead','originalWorker')) {
        if ($reviewProps -notcontains $required) { return (& $fail 'repair_not_eligible' 'review_receipt_incomplete' "review 영수증 필드가 없다: $required") }
    }
    if ([int]$reviewReceipt.operation -ne 1 -or [string]$reviewReceipt.verdict -ne 'REPAIR_REQUIRED') { return (& $fail 'repair_not_eligible' 'review_verdict_not_repair_required' 'REPAIR_REQUIRED review 영수증만 repair 자격이 있다.') }
    $schema = Test-RepairFindingsSchema -Findings @($reviewReceipt.findings)
    if (-not $schema.valid) { return (& $fail 'repair_not_eligible' 'review_findings_invalid' 'review 영수증 findings가 엄격 스키마를 만족하지 않는다.') }
    if ([string]$reviewReceipt.originalWorker -cne [string]$runReceipt.worker) { return (& $fail 'repair_not_eligible' 'review_original_worker_mismatch' 'review originalWorker와 run worker가 다르다.') }
    if ([string]$reviewReceipt.postReviewHead -cne [string]$runReceipt.finalHead) { return (& $fail 'repair_not_eligible' 'review_run_head_mismatch' 'review postReviewHead와 run finalHead가 다르다.') }
    $currentHead = Get-GitHead -Path $RepoPath
    if ($currentHead -cne [string]$reviewReceipt.postReviewHead) { return (& $fail 'repair_state_mismatch' 'current_head_mismatch' '현재 HEAD가 review postReviewHead와 다르다.') }
    if ($HasPostReviewHeadAssertion -and $PostReviewHeadAssertion -cne [string]$reviewReceipt.postReviewHead) { return (& $fail 'repair_argument_receipt_mismatch' 'post_review_head_mismatch' 'PostReviewHead 인수가 review 영수증과 다르다.') }
    if ($HasTargetAssertion -and ($TargetAssertion -cne [string]$reviewReceipt.originalWorker -or $TargetAssertion -cne [string]$runReceipt.worker)) { return (& $fail 'repair_argument_receipt_mismatch' 'repair_target_mismatch' 'Target 인수가 run/review 영수증의 worker와 다르다.') }
    if ($HasFindingsAssertion -and -not (Compare-ReviewFindings -Expected @($reviewReceipt.findings) -Actual @($FindingsAssertion))) { return (& $fail 'repair_argument_receipt_mismatch' 'findings_mismatch' 'FindingsFile 또는 findings 인수가 review 영수증과 다르다.') }
    return [pscustomobject]@{
        eligible=$true; validated=$true; status='eligible'; reason=$null; note='verified run and review receipts'
        runReceipt=$runReceipt; reviewReceipt=$reviewReceipt; findings=@($reviewReceipt.findings)
        postReviewHead=[string]$reviewReceipt.postReviewHead; originalWorker=[string]$reviewReceipt.originalWorker
        verificationProvenance=[string]$runReceipt.verificationProvenance; repairAttempted=$false
    }
}

function Invoke-OperationRepair {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath, $Findings,
        [ValidateSet('grok','gpt')][string]$OriginalWorker,
        [string]$PostReviewHead, [string]$Kind = 'logic',
        [scriptblock]$IssueFetcher, [scriptblock]$RepairRunner, [scriptblock]$CiProbe
    )
    $context = Get-EligibleRepairContext -OperationNumber $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath `
        -HasFindingsAssertion:$($PSBoundParameters.ContainsKey('Findings')) -FindingsAssertion $Findings `
        -HasPostReviewHeadAssertion:$($PSBoundParameters.ContainsKey('PostReviewHead')) -PostReviewHeadAssertion $PostReviewHead `
        -HasTargetAssertion:$($PSBoundParameters.ContainsKey('OriginalWorker')) -TargetAssertion $OriginalWorker
    if (-not $context.eligible) {
        Add-Member -InputObject $context -NotePropertyName operation -NotePropertyValue $OperationNumber -Force
        Add-Member -InputObject $context -NotePropertyName issueNumber -NotePropertyValue $IssueNumber -Force
        return $context
    }
    $Findings = @($context.findings); $OriginalWorker = [string]$context.originalWorker; $PostReviewHead = [string]$context.postReviewHead
    $config = Get-Config
    $originalFindingCount = @($Findings).Count

    # 0) 수리 워커 사용량 게이트 (usage-state를 지금 다시 읽는다)
    $state = Get-UsageState
    if ($OriginalWorker -eq 'grok') {
        $planB = [int]$config.grok.thresholds.gptPlanBFromPercent
        $gp = 0; if ($state.grok.PSObject.Properties.Name -contains 'percent' -and $null -ne $state.grok.percent) { $gp = [int]$state.grok.percent }
        if ($state.grok.status -eq 'exhausted' -or $gp -ge $planB) {
            return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repair_worker_unavailable'
                reason = 'grok_exhausted_repair_blocked'; repairAttempted = $false; originalFindingCount = $originalFindingCount
                note = 'Grok이 소진 상태다. 다른 작업자로 몰래 교체하지 않는다.' }
        }
    } else {
        $stop = [int]$config.gpt.thresholds.workerStopPercent
        $pp = 0; if ($state.gpt.PSObject.Properties.Name -contains 'percent' -and $null -ne $state.gpt.percent) { $pp = [int]$state.gpt.percent }
        $blockedReason = $null
        if ($state.gpt.status -eq 'exhausted') { $blockedReason = 'gpt_exhausted_repair_blocked' }
        elseif ($state.gpt.status -eq 'reserved') { $blockedReason = 'gpt_reserved_repair_blocked_review_reserve_not_for_repair' }
        elseif ($pp -ge $stop) { $blockedReason = 'gpt_tier3_repair_blocked_review_reserve_not_for_repair' }
        if ($null -ne $blockedReason) {
            return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repair_worker_unavailable'
                reason = $blockedReason; repairAttempted = $false; originalFindingCount = $originalFindingCount
                note = 'GPT가 80% 이상·reserved·exhausted다. 검수 예비분은 수리에 사용하지 않으며, 다른 작업자로 교체하지 않는다.' }
        }
    }

    # 1) 수리 전 상태 일치 확인 (검수 직후와 동일해야 함)
    $curHead = Get-GitHead -Path $RepoPath
    $wt = Get-GitWorktreeStatus -Path $RepoPath
    if ($curHead -ne $PostReviewHead -or -not $wt.Clean) {
        return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repair_state_mismatch'
            note = '검수 직후 HEAD/worktree와 현재 상태가 다르다. 자동 수리를 하지 않는다.'; expectedHead = $PostReviewHead; currentHead = $curHead; worktreeClean = [bool]$wt.Clean }
    }

    # 수리 시작 스냅샷 (postflight 기준)
    $snapshot = Get-StartSnapshot -RepoPath $RepoPath

    if ($null -eq $IssueFetcher) {
        $IssueFetcher = { param($num, $path) $out = & gh issue view $num --json body -q .body 2>&1; if ($LASTEXITCODE -ne 0) { throw "gh issue view failed: $out" }; return ($out | Out-String) }
    }
    $issueBody = & $IssueFetcher $IssueNumber $RepoPath
    $findingsJson = ($Findings | ConvertTo-Json -Depth 8)
    $repairOrder = (New-OrderContent -IssueBody $issueBody) + "`n`n[검수 결함 목록 — 아래 항목만 수리한다]`n$findingsJson"
    $promptPath = New-TempOrderFile -Content $repairOrder

    # 수리 워커: 원래 worker를 유지한다 (grok이면 Grok medium, gpt면 GPT Sol medium). 교체 없음.
    if ($OriginalWorker -eq 'grok') {
        $repairRoute = [pscustomobject]@{ worker = 'grok'; model = $config.grok.model; effort = 'medium'; maxTurns = $config.grok.operations.'2'.maxTurns; noPlan = $false; noSubagents = $true }
    } else {
        $repairRoute = [pscustomobject]@{ worker = 'gpt'; model = $config.gpt.workers.sol; effort = 'medium' }
    }

    $log = New-Object System.Collections.Generic.List[string]
    $log.Add("repair op=$OperationNumber issue=$IssueNumber originalWorker=$OriginalWorker repairWorker=$($repairRoute.worker)/$($repairRoute.effort) postReviewHead=$PostReviewHead")
    try {
        $invokeRepairWorker = { Invoke-RouteWorker -Route $repairRoute -RepoPath $RepoPath -PromptPath $promptPath -Config $config -GrokRunner $RepairRunner -GptRunner $RepairRunner }
        $execution = Invoke-WorkerWithErrorPolicy -Provider $repairRoute.worker -InvokeWorker $invokeRepairWorker -State $state -Config $config -Log $log
        $result = $execution.Result
        $log.Add("repair worker exit=$($result.ExitCode) quota=$($result.QuotaExhausted)")
        $log.Add($result.Output)
        if (-not $execution.Success) {
            $status = switch ($execution.ErrorClass) {
                'weekly_exhausted'     { 'repair_quota_exhausted'; break }
                'transient_rate_limit' { 'repair_transient_rate_limited'; break }
                'provider_failure'     { 'repair_provider_failure'; break }
                'quota_unknown'        { 'repair_quota_unknown'; break }
                default                { 'repair_worker_failed' }
            }
            $lp = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber-repair" -Content ($log -join "`n")
            return New-FinalOutput -Operation $OperationNumber -RouteLabel "repair-$($repairRoute.worker)" -Status $status `
                -Worker $repairRoute.worker -Model $repairRoute.model -Effort $repairRoute.effort -Snapshot $snapshot -Postflight $null `
                -IssueNumber $IssueNumber -LogPath $lp -RemainingProblems (Get-RemainingProblems -Status $status) `
                -Extra @{ repairAttempted = $true; originalFindingCount = $originalFindingCount; errorClass = $execution.ErrorClass
                          attempts = $execution.Attempts; usageStateChanged = $execution.UsageStateChanged; ciStatus = 'not-checked' }
        }
        $pf = Resolve-Postflight -RepoPath $RepoPath -StartSnapshot $snapshot -WorkerResult $result -DeclaredNoCodeChange:$false -CiProbe $CiProbe

        # 재검수를 하지 않으므로 수리 성공을 "남은 findings 없음"으로 단정하지 않는다.
        # 판정: worker 실패/quota는 구분해 보고, postflight 게이트 통과 시 repair_completed_review_pending.
        $status = $null
        switch ($pf.status) {
            'worker_failed'   { $status = 'repair_worker_failed' }
            'quota_exhausted' { $status = 'repair_quota_exhausted' }
            'completed'                { $status = 'repair_completed_review_pending' }
            'completed_ci_pending'     { $status = 'repair_completed_review_pending' }
            'completed_ci_unavailable' { $status = 'repair_completed_review_pending' }
            default { $status = 'repair_postflight_failed' }
        }
        $lp = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber-repair" -Content ($log -join "`n")

        $out = New-FinalOutput -Operation $OperationNumber -RouteLabel "repair-$($repairRoute.worker)" -Status $status `
            -Worker $repairRoute.worker -Model $repairRoute.model -Effort $repairRoute.effort -Snapshot $snapshot -Postflight $pf `
            -IssueNumber $IssueNumber -LogPath $lp -RemainingProblems (Get-RemainingProblems -Status $status -Postflight $pf) `
            -Extra @{
                repairAttempted = $true
                repairPostflight = $pf
                repairPostflightStatus = $pf.status
                originalFindingCount = $originalFindingCount
                finalReviewRequired = $true
                note = '재검수 없음: 원래 findings의 해소 여부는 판정하지 않았다. 최종 PASS는 현재 세션 종료 검토에서만 한다.'
            }
        return $out
    } finally {
        Remove-TempOrderFile -Path $promptPath
    }
}

# repair CLI 래퍼: 유효한 run/review 영수증은 필수이며 수동 인수는 receipt assertion으로만 사용한다.
function Invoke-RepairCommand {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [string]$RepoPath = (Get-Location).Path, [string]$Kind = 'logic',
        [string]$PostReviewHead, [string]$FindingsFile, [string]$Target,
        [scriptblock]$IssueFetcher, [scriptblock]$RepairRunner, [scriptblock]$CiProbe
    )
    $invoke = @{
        OperationNumber=$OperationNumber; IssueNumber=$IssueNumber; RepoPath=$RepoPath; Kind=$Kind
        IssueFetcher=$IssueFetcher; RepairRunner=$RepairRunner; CiProbe=$CiProbe
    }
    if ($PSBoundParameters.ContainsKey('PostReviewHead')) { $invoke.PostReviewHead = $PostReviewHead }
    if ($PSBoundParameters.ContainsKey('Target')) {
        if ($Target -notin @('grok','gpt')) {
            return [pscustomobject]@{ operation=$OperationNumber; issueNumber=$IssueNumber; status='repair_argument_receipt_mismatch'
                reason='repair_target_mismatch'; repairAttempted=$false; note='Target은 유효한 receipt worker와 일치해야 한다.' }
        }
        $invoke.OriginalWorker = $Target
    }
    if ($PSBoundParameters.ContainsKey('FindingsFile')) {
        try {
            $invoke.Findings = @((Get-Content -LiteralPath $FindingsFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop))
        } catch {
            return [pscustomobject]@{ operation=$OperationNumber; issueNumber=$IssueNumber; status='repair_argument_receipt_mismatch'
                reason='findings_mismatch'; repairAttempted=$false; note='FindingsFile을 읽거나 엄격 JSON findings로 검증할 수 없다.' }
        }
    }
    return Invoke-OperationRepair @invoke
}

# ---------------- v2.4.4 중단 복구 ----------------
function Invoke-RecoverCommand {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [string]$RepoPath = (Get-Location).Path, [scriptblock]$ProcessProbe, [scriptblock]$Clock, [scriptblock]$CiProbe
    )
    $receipt = Get-ExecutionReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
    if ($null -eq $receipt) {
        return [pscustomobject]@{ operation=$OperationNumber; issueNumber=$IssueNumber; status='execution_receipt_missing'; workerCalls=0 }
    }
    if ($receipt.PSObject.Properties.Name -contains 'legacyNamespaceBlocked') {
        return [pscustomobject]@{ operation=$OperationNumber; issueNumber=$IssueNumber; status='repository_receipt_mismatch'; workerCalls=0
            reason=[string]$receipt.legacyNamespaceReason }
    }
    if (-not (Test-ReceiptRepoMatch -Receipt $receipt -RepoPath $RepoPath)) {
        return [pscustomobject]@{ operation=$OperationNumber; issueNumber=$IssueNumber; status='repository_receipt_mismatch'; workerCalls=0 }
    }
    $result = ConvertFrom-ExecutionResult -Receipt $receipt -RepoPath $RepoPath
    if ($null -eq $result -and (Test-ExecutionStatusActive -Status ([string]$receipt.status))) {
        if (Test-ExecutionProcessAlive -Receipt $receipt -ProcessProbe $ProcessProbe) {
            return [pscustomobject]@{
                operation=$OperationNumber; issueNumber=$IssueNumber; status='worker_running'; workerCalls=0
                executionId=$receipt.executionId; generation=$receipt.generation; logPath=$receipt.logPath
                startedAt=$receipt.startedAt; resumeCommand="/operation recover $OperationNumber $IssueNumber"
            }
        }
        $now = if ($null -ne $Clock) { & $Clock } else { [DateTime]::UtcNow }
        $age = ([DateTime]$now).ToUniversalTime() - ([DateTime]::Parse([string]$receipt.updatedAt).ToUniversalTime())
        $staleSeconds = 15; $cfg = Get-Config
        if ($cfg.PSObject.Properties.Name -contains 'execution' -and $cfg.execution.PSObject.Properties.Name -contains 'staleHeartbeatSeconds') {
            $staleSeconds = [Math]::Max(1, [int]$cfg.execution.staleHeartbeatSeconds)
        }
        if ($age.TotalSeconds -lt $staleSeconds) {
            return [pscustomobject]@{
                operation=$OperationNumber; issueNumber=$IssueNumber; status='execution_state_unknown'; workerCalls=0
                executionId=$receipt.executionId; generation=$receipt.generation; logPath=$receipt.logPath
                resumeCommand="/operation recover $OperationNumber $IssueNumber"
            }
        }
    }
    $lock = Open-ExecutionLock -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
    if ($null -eq $lock) {
        return [pscustomobject]@{ operation=$OperationNumber; issueNumber=$IssueNumber; status='execution_recovery_locked'; workerCalls=0 }
    }
    try {
        $receipt = Get-ExecutionReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
        $result = ConvertFrom-ExecutionResult -Receipt $receipt -RepoPath $RepoPath
        $receipt.status = 'recovering_postflight'
        Save-ExecutionReceipt -Receipt $receipt -RepoPath $RepoPath | Out-Null
        $snapshot = $receipt.startSnapshot
        $route = [pscustomobject]@{ worker=$receipt.worker; model=$receipt.model; effort=$receipt.effort }
        if ($null -ne $result) {
            $pf = Resolve-Postflight -RepoPath $RepoPath -StartSnapshot $snapshot -WorkerResult $result -DeclaredNoCodeChange:$false -CiProbe $CiProbe
            $interrupted = $false; $recovered = $true
            $localVerificationComplete = if($result.PSObject.Properties.Name -contains 'LocalVerificationComplete'){[bool]$result.LocalVerificationComplete}else{$false}
            $resultEnvelopePresent = $true; $verificationProvenance = 'valid_worker_result_envelope_recovered_postflight'
            $workerStopReason = $result.WorkerStopReason; $interruptedReason = $null
        } else {
            $pf = Resolve-RecoveryPostflight -RepoPath $RepoPath -StartSnapshot $snapshot -CiProbe $CiProbe
            $interrupted = $true; $recovered = $true; $localVerificationComplete = $false
            $resultEnvelopePresent = $false; $verificationProvenance = 'git_postflight_without_worker_result'
            $workerStopReason = 'external_interruption'; $interruptedReason = 'result_missing_after_process_exit'
        }
        $boundary = @()
        if ($snapshot.PSObject.Properties.Name -contains 'boundaryWatch') { $boundary = @(Test-RepoBoundaryViolation -BeforeSnapshot $snapshot.boundaryWatch) }
        $finalStatus = if ($boundary.Count -gt 0) { 'repo_boundary_violation' } else { $pf.status }
        $receipt.status = $finalStatus; $receipt.finalHead = $pf.finalHead; $receipt.workerExitCode = if ($null -ne $result) { $result.ExitCode } else { $null }
        $receipt.workerStopReason = $workerStopReason; $receipt.interruptedReason = $interruptedReason; $receipt.postflight = $pf
        $receipt.workerReportedVerification = if($null -ne $result -and $result.PSObject.Properties.Name -contains 'WorkerReportedVerification' -and $null -ne $result.WorkerReportedVerification){Protect-SecretText -Text ([string]$result.WorkerReportedVerification)}else{$null}
        $receipt.remainingProblems = @(Get-RemainingProblems -Status $finalStatus -Postflight $pf)
        foreach ($item in @(@('interrupted',$interrupted),@('localVerificationComplete',$localVerificationComplete),@('recoveredByPostflight',$recovered),
                @('resultEnvelopePresent',$resultEnvelopePresent),@('verificationProvenance',$verificationProvenance))) {
            if ($receipt.PSObject.Properties.Name -contains $item[0]) { $receipt.($item[0]) = $item[1] }
            else { Add-Member -InputObject $receipt -NotePropertyName $item[0] -NotePropertyValue $item[1] }
        }
        $receipt = Complete-ExecutionTerminalArtifacts -Receipt $receipt -RepoPath $RepoPath -IntendedStatus $finalStatus
        $finalStatus = [string]$receipt.status
        if ($OperationNumber -eq 1 -and $receipt.worker -in @('grok','gpt') -and ($null -eq $result -or $result.Success) -and
            $finalStatus -notin @('artifact_sanitization_failed','artifact_retention_failed')) {
            if ($null -eq $result) { Remove-ReviewReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath }
            Save-RunReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath -Snapshot $snapshot -Postflight $pf `
                -Route $route -WorkerResult $result -StatusOverride $finalStatus -RemainingProblems $receipt.remainingProblems `
                -ResultEnvelopePresent $resultEnvelopePresent -Interrupted $interrupted -InterruptedReason $interruptedReason `
                -LocalVerificationComplete $localVerificationComplete -RecoveredByPostflight $recovered `
                -VerificationProvenance $verificationProvenance | Out-Null
        }
        $extra = @{
            executionId=$receipt.executionId; generation=$receipt.generation; interrupted=$interrupted
            workerExitCode=$receipt.workerExitCode; workerStopReason=$workerStopReason; interruptedReason=$interruptedReason
            workerReportedVerification=if($null -ne $result){Protect-SecretText -Text ([string]$result.Output)}else{$null}
            localVerificationComplete=$localVerificationComplete; recoveredByPostflight=$recovered; workerCalls=0
            resultEnvelopePresent=$resultEnvelopePresent; verificationProvenance=$verificationProvenance
        }
        return New-FinalOutput -Operation $OperationNumber -RouteLabel 'recover' -Status $finalStatus `
            -Worker $receipt.worker -Model $receipt.model -Effort $receipt.effort -Snapshot $snapshot -Postflight $pf `
            -IssueNumber $IssueNumber -LogPath $receipt.logPath -RemainingProblems $receipt.remainingProblems -Extra $extra
    } finally { $lock.Dispose() }
}

# ---------------- CLI 진입점 ----------------
if ($MyInvocation.InvocationName -ne '.') {
    switch ($Command) {
        'status' { Invoke-StatusCommand | ConvertTo-Json -Depth 12 }
        'doctor' { (Invoke-DoctorCommand) | ConvertTo-Json -Depth 12 }
        'set' {
            if (-not $Target -or -not $Value) { throw 'set requires -Target <grok|gpt> and -Value <...>' }
            Invoke-SetCommand -Target $Target -Value $Value | ConvertTo-Json -Depth 12
        }
        'reset' { Invoke-ResetCommand | ConvertTo-Json -Depth 12 }
        'run' {
            if (-not $Operation -or -not $IssueNumber) { throw 'run requires -Operation <1|2|3> and -IssueNumber <positive int>' }
            Assert-ValidOperationNumber -Value ([string]$Operation) | Out-Null
            Assert-ValidIssueNumber -Value ([string]$IssueNumber) | Out-Null
            Invoke-RunOperation -OperationNumber $Operation -IssueNumber $IssueNumber -Kind $Kind `
                -UseGptReviewReserve:$UseGptReviewReserve -FinishCurrent:$FinishCurrent -ClaudeOnly:$ClaudeOnly | ConvertTo-Json -Depth 12
        }
        'postflight' {
            if (-not $Operation -or -not $IssueNumber) { throw 'postflight requires -Operation and -IssueNumber' }
            Assert-ValidOperationNumber -Value ([string]$Operation) | Out-Null
            Assert-ValidIssueNumber -Value ([string]$IssueNumber) | Out-Null
            Invoke-PostflightCommand -Operation $Operation -IssueNumber $IssueNumber | ConvertTo-Json -Depth 12
        }
        'recover' {
            if (-not $Operation -or -not $IssueNumber) { throw 'recover requires -Operation and -IssueNumber' }
            Assert-ValidOperationNumber -Value ([string]$Operation) | Out-Null
            Assert-ValidIssueNumber -Value ([string]$IssueNumber) | Out-Null
            Invoke-RecoverCommand -OperationNumber $Operation -IssueNumber $IssueNumber -RepoPath (Get-Location).Path | ConvertTo-Json -Depth 20
        }
        'review' {
            # v2.2: -StartHead 수동 입력 불필요. run 영수증을 자동으로 읽는다.
            if (-not $Operation -or -not $IssueNumber) { throw 'review requires -Operation and -IssueNumber' }
            Assert-ValidOperationNumber -Value ([string]$Operation) | Out-Null
            Assert-ValidIssueNumber -Value ([string]$IssueNumber) | Out-Null
            Invoke-OperationReview -OperationNumber $Operation -IssueNumber $IssueNumber -RepoPath (Get-Location).Path `
                -Kind $Kind -UseGptReviewReserve:$UseGptReviewReserve | ConvertTo-Json -Depth 12
        }
        'repair' {
            # v2.2: -PostReviewHead/-FindingsFile/-Target은 선택 인수. 없으면 run/review 영수증에서 자동 복원한다.
            # v2.4.6 회귀: 이 세 값을 무조건 splat하면 Invoke-RepairCommand 내부의
            # $PSBoundParameters.ContainsKey(...)가 CLI에서 실제로 넘겼는지와 무관하게 항상 true가 되어,
            # 값을 안 넘겨도 빈 문자열/빈 Target이 assertion으로 강제되어 매번 repair_argument_receipt_mismatch로
            # 실패했다(이슈 #15 op1 repair에서 실측). 스크립트 자신의 $PSBoundParameters로 실제 CLI 바인딩 여부를
            # 가려 선택 인수일 때만 splat한다.
            if (-not $Operation -or -not $IssueNumber) { throw 'repair requires -Operation and -IssueNumber' }
            Assert-ValidOperationNumber -Value ([string]$Operation) | Out-Null
            Assert-ValidIssueNumber -Value ([string]$IssueNumber) | Out-Null
            $repairArgs = @{ OperationNumber = $Operation; IssueNumber = $IssueNumber; RepoPath = (Get-Location).Path; Kind = $Kind }
            if ($PSBoundParameters.ContainsKey('PostReviewHead')) { $repairArgs.PostReviewHead = $PostReviewHead }
            if ($PSBoundParameters.ContainsKey('FindingsFile')) { $repairArgs.FindingsFile = $FindingsFile }
            if ($PSBoundParameters.ContainsKey('Target')) { $repairArgs.Target = $Target }
            Invoke-RepairCommand @repairArgs | ConvertTo-Json -Depth 12
        }
    }
}
