# operation-router 메인 진입점.
# 명령: run | review | status | doctor | set | reset
# run 역할: 시작검토 -> 계약+이슈원문 주문서 -> 라우팅 -> 작업자 1회 -> (한도오류 시 부분변경 가드) -> postflight -> 전체 JSON.

param(
    [ValidateSet('run','review','repair','postflight','status','doctor','set','reset')][string]$Command = 'run',
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
    # v2.4.1: 모든 종료 출력이 이 공통 경로를 지난다. 시작 스냅샷의 boundaryWatch로 경계 위반을
    # 최종 판정한다(worker 실패·부분 변경·fallback·claude 실행 등 조기 반환 포함). 위반 없으면 무변경.
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

        # v2.4.3: 작전 1 실제 worker 호출 직전에 같은 이슈의 기존 run·review 영수증을 무효화한다.
        # 영수증 키는 (작전+이슈+저장소)로 고정이라 이전 세대가 남을 수 있다. 새 실행이 경계 위반·실패로
        # 조기 반환돼도 과거 completed run 영수증이나 REPAIR_REQUIRED review 영수증이 남아 review·repair가
        # 이전 세대를 재사용하는 것을 막는다. 새 영수증은 성공 postflight에서만 저장한다.
        if ($OperationNumber -eq 1) {
            Remove-RunReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
            Remove-ReviewReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
        }

        # 워커 실행. 최초·fallback·review·repair가 같은 공통 오류 정책을 사용한다.
        $invokePrimary = { Invoke-RouteWorker -Route $route -RepoPath $RepoPath -PromptPath $tempOrderPath -Config $config -GrokRunner $GrokRunner -GptRunner $GptRunner }
        $execution = Invoke-WorkerWithErrorPolicy -Provider $route.worker -InvokeWorker $invokePrimary -State $state -Config $config -Log $log
        $result = $execution.Result
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
                -UseGptReviewReserve:$UseGptReviewReserve -FinishCurrent:$FinishCurrent -Log $log -FallbackProviders @($route.worker)
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
        # v2.4.2: 영수증을 저장하기 전에 경계 위반을 먼저 확정한다. 위반이면 영수증 status도
        # repo_boundary_violation으로 저장해, 보안 위반 run이 completed 영수증으로 남아 review 자격을
        #통과하는 결함을 막는다(finalizer는 출력만 고쳤음).
        $runBoundaryViol = @()
        if ($snapshot -and ($snapshot.PSObject.Properties.Name -contains 'boundaryWatch')) {
            $runBoundaryViol = @(Test-RepoBoundaryViolation -BeforeSnapshot $snapshot.boundaryWatch)
        }
        $receiptStatus = if ($runBoundaryViol.Count -gt 0) { 'repo_boundary_violation' } else { $pf.status }
        # 작전 1 실행 영수증 자동 저장 (v2.2): review가 -StartHead 재입력 없이 자동으로 읽는다.
        if ($OperationNumber -eq 1 -and $effectiveRoute.worker -in @('grok','gpt')) {
            $rcPath = Save-RunReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath -Snapshot $snapshot -Postflight $pf `
                -Route $effectiveRoute -WorkerResult $result -StatusOverride $receiptStatus -RemainingProblems (Get-RemainingProblems -Status $receiptStatus -Postflight $pf)
            $log.Add("op1 run receipt saved: $rcPath (status=$receiptStatus)")
        }
        $lp = Write-RouterLog -Name "op$OperationNumber-issue$IssueNumber" -Content ($log -join "`n")
        return New-FinalOutput -Operation $OperationNumber -RouteLabel (New-RouteLabel -Route $effectiveRoute) -Status $pf.status `
            -Worker $effectiveRoute.worker -Model $effectiveRoute.model -Effort $effectiveRoute.effort `
            -Snapshot $snapshot -Postflight $pf -IssueNumber $IssueNumber -LogPath $lp `
            -RemainingProblems (Get-RemainingProblems -Status $pf.status -Postflight $pf)
    }
    finally {
        Remove-TempOrderFile -Path $tempOrderPath
    }
}

# 워커 1회 실행 (mock 주입 가능)
function Invoke-RouteWorker {
    param([Parameter(Mandatory)]$Route, [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$PromptPath,
          [Parameter(Mandatory)]$Config, [scriptblock]$GrokRunner, [scriptblock]$GptRunner)
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
          [string[]]$FallbackProviders = @())
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
        $invokeFallback = { Invoke-RouteWorker -Route $newRoute -RepoPath $RepoPath -PromptPath $PromptPath -Config $Config -GptRunner $GptRunner }
        $execution = Invoke-WorkerWithErrorPolicy -Provider 'gpt' -InvokeWorker $invokeFallback -State $State -Config $Config -Log $Log
        $result = $execution.Result
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
                -UseGptReviewReserve:$UseGptReviewReserve -FinishCurrent:$FinishCurrent -Log $Log -FallbackProviders $nextHistory
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
    # v2.4.1: 검수 워커 실행 후 경계 위반을 공통 finalizer로 판정한다. 진입 시 감시 스냅샷을 캡처하고
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
    if ($null -eq $receipt) {
        return [pscustomobject]@{ status = 'review_receipt_missing'; verdict = $null; findings = @()
            note = "run 영수증이 없다. 먼저 '-Command run -Operation $OperationNumber -IssueNumber $IssueNumber'를 완료해야 한다."
            expectedReceiptPath = (Get-RunReceiptPath -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath) }
    }
    # 2) 현재 저장소 == 영수증 저장소
    if (-not (Test-ReceiptRepoMatch -Receipt $receipt -RepoPath $RepoPath)) {
        return [pscustomobject]@{ status = 'repository_receipt_mismatch'; verdict = $null; findings = @()
            note = '현재 저장소와 run 영수증의 저장소가 다르다. 검수를 중단한다.' }
    }
    # 3) worker == grok (GPT가 구현한 작전 1은 Sol 자기검수 금지 — 현재 세션이 직접 종료 검토)
    if ($receipt.worker -ne 'grok') {
        return [pscustomobject]@{ status = 'review_not_eligible'; verdict = $null; findings = @()
            reason = "worker_not_grok:$($receipt.worker)"
            note = 'GPT가 구현한 결과는 Sol 자기검수를 하지 않는다. 현재 세션(Opus)이 직접 종료 검토한다.' }
    }
    # 4) run 상태가 완료 계열이어야 검수 자격이 있다
    if ($receipt.status -notin @('completed','completed_ci_pending','completed_ci_unavailable')) {
        return [pscustomobject]@{ status = 'review_not_eligible'; verdict = $null; findings = @()
            reason = "run_not_completed:$($receipt.status)"
            note = '완료되지 않은 run 결과는 검수하지 않는다. run을 먼저 정상 완료해야 한다.' }
    }
    # 5) 현재 HEAD == 영수증 finalHead
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
function Invoke-OperationRepair {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)]$Findings,
        [Parameter(Mandatory)][ValidateSet('grok','gpt')][string]$OriginalWorker,
        [Parameter(Mandatory)][string]$PostReviewHead, [string]$Kind = 'logic',
        [scriptblock]$IssueFetcher, [scriptblock]$RepairRunner, [scriptblock]$CiProbe
    )
    $config = Get-Config
    $originalFindingCount = @($Findings).Count

    # v2.3: 자동 수리는 작전 1 전용이다
    if ($OperationNumber -ne 1) {
        return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repair_not_eligible'
            reason = 'operation_not_1'; repairAttempted = $false
            note = '검수 기반 자동 수리는 작전 1 전용이다. 작전 2/3은 repair를 지원하지 않는다.' }
    }

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

# repair CLI 래퍼 (v2.2): -PostReviewHead/-FindingsFile/-Target을 수동으로 추측하지 않도록
# run/review 영수증에서 자동 복원한다. 명시 인수가 있으면 그것을 우선한다.
function Invoke-RepairCommand {
    param(
        [Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][int]$IssueNumber,
        [string]$RepoPath = (Get-Location).Path, [string]$Kind = 'logic',
        [string]$PostReviewHead, [string]$FindingsFile, [string]$Target,
        [scriptblock]$IssueFetcher, [scriptblock]$RepairRunner, [scriptblock]$CiProbe
    )
    # v2.3: 자동 수리는 작전 1 전용이다 (GPT 호출 전 차단)
    if ($OperationNumber -ne 1) {
        return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repair_not_eligible'
            reason = 'operation_not_1'; repairAttempted = $false
            note = '검수 기반 자동 수리는 작전 1 전용이다. 작전 2/3은 repair를 지원하지 않는다.' }
    }
    $reviewReceipt = Get-ReviewReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath
    $runReceipt = Get-RunReceipt -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath

    # v2.3: review 영수증 저장소가 현재 저장소와 다르면 중단
    if ($null -ne $reviewReceipt -and -not (Test-ReceiptRepoMatch -Receipt $reviewReceipt -RepoPath $RepoPath)) {
        return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repository_receipt_mismatch'
            note = '현재 저장소와 review 영수증의 저장소가 다르다. 수리를 중단한다.' }
    }
    # v2.3: 유효한 REPAIR_REQUIRED review 영수증만 수리 근거가 된다
    if ($null -ne $reviewReceipt -and $reviewReceipt.verdict -ne 'REPAIR_REQUIRED') {
        return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repair_not_eligible'
            reason = "review_verdict_not_repair_required:$($reviewReceipt.verdict)"; repairAttempted = $false
            note = 'REPAIR_REQUIRED가 아닌 review 영수증으로는 수리하지 않는다.' }
    }

    $findings = $null
    if ($FindingsFile) {
        $findings = @((Get-Content -LiteralPath $FindingsFile -Raw -Encoding UTF8 | ConvertFrom-Json))
    } elseif ($null -ne $reviewReceipt) {
        $findings = @($reviewReceipt.findings)
    }
    if (-not $PostReviewHead -and $null -ne $reviewReceipt) { $PostReviewHead = [string]$reviewReceipt.postReviewHead }
    if (-not $Target) {
        if ($null -ne $reviewReceipt -and $reviewReceipt.PSObject.Properties.Name -contains 'originalWorker' -and $reviewReceipt.originalWorker) {
            $Target = [string]$reviewReceipt.originalWorker
        } elseif ($null -ne $runReceipt) {
            $Target = [string]$runReceipt.worker
        }
    }
    if ($null -eq $findings -or @($findings).Count -eq 0 -or -not $PostReviewHead -or -not $Target) {
        return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repair_receipt_missing'
            note = 'review 영수증(REPAIR_REQUIRED findings)이 없다. 먼저 review를 실행해야 한다. 인수를 수동으로 추측해 넣지 않는다.'
            expectedReviewReceiptPath = (Get-ReviewReceiptPath -Operation $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath) }
    }
    if ($Target -notin @('grok','gpt')) {
        return [pscustomobject]@{ operation = $OperationNumber; issueNumber = $IssueNumber; status = 'repair_receipt_missing'
            note = "영수증의 원래 worker가 grok/gpt가 아니다: '$Target'. 자동 수리를 하지 않는다." }
    }
    return Invoke-OperationRepair -OperationNumber $OperationNumber -IssueNumber $IssueNumber -RepoPath $RepoPath `
        -Findings $findings -OriginalWorker $Target -PostReviewHead $PostReviewHead -Kind $Kind `
        -IssueFetcher $IssueFetcher -RepairRunner $RepairRunner -CiProbe $CiProbe
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
            if (-not $Operation -or -not $IssueNumber) { throw 'repair requires -Operation and -IssueNumber' }
            Assert-ValidOperationNumber -Value ([string]$Operation) | Out-Null
            Assert-ValidIssueNumber -Value ([string]$IssueNumber) | Out-Null
            Invoke-RepairCommand -OperationNumber $Operation -IssueNumber $IssueNumber -RepoPath (Get-Location).Path `
                -Kind $Kind -PostReviewHead $PostReviewHead -FindingsFile $FindingsFile -Target $Target | ConvertTo-Json -Depth 12
        }
    }
}
