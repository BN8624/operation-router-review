# 작전 + Grok/GPT 사용량으로 실제 경로를 결정하는 순수 로직 (CLI 호출 없음, mock 불필요).
# 임계값은 config.json에서 온다. Grok 85/95, GPT 60/80 규칙을 구현한다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

function Get-IntPercent {
    param($State)
    if ($State.PSObject.Properties.Name -contains 'percent' -and $null -ne $State.percent) { return [int]$State.percent }
    return 0
}

# Grok 사용 가능성 판정.
# 반환: @{ decision = 'grok' | 'conserve_blocked' | 'plan_b'; reason }
function Resolve-GrokDecision {
    param([Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)]$GrokState,
          [Parameter(Mandatory)]$Config, [switch]$FinishCurrent)
    $conserve = [int]$Config.grok.thresholds.conserveOp12FromPercent   # 85
    $planB    = [int]$Config.grok.thresholds.gptPlanBFromPercent        # 95
    $p = Get-IntPercent -State $GrokState

    if ($GrokState.status -eq 'exhausted' -or $p -ge $planB) {
        return @{ decision = 'plan_b'; reason = 'grok_exhausted_or_over_95' }
    }
    if ($p -ge $conserve -and $OperationNumber -in @(1,2)) {
        if ($FinishCurrent) { return @{ decision = 'grok'; reason = 'grok_conserve_band_finish_current' } }
        return @{ decision = 'conserve_blocked'; reason = 'grok_conserve_new_run_blocked_85_94' }
    }
    return @{ decision = 'grok'; reason = 'grok_available' }
}

# GPT 워커가 현재 tier/status에서 허용되는지.
# 반환: @{ permitted = bool; reason }
function Test-GptWorkerPermitted {
    param([Parameter(Mandatory)][string]$Worker, [Parameter(Mandatory)][int]$OperationNumber,
          [Parameter(Mandatory)][string]$Purpose, [Parameter(Mandatory)]$GptState,
          [Parameter(Mandatory)]$Config, [switch]$UseReviewReserve)
    $tier1 = [int]$Config.gpt.thresholds.tier1MaxPercent   # 59
    $stop  = [int]$Config.gpt.thresholds.workerStopPercent  # 80
    $p = Get-IntPercent -State $GptState
    $status = $GptState.status

    if ($status -eq 'exhausted') { return @{ permitted = $false; reason = 'gpt_exhausted' } }

    if ($status -eq 'reserved') {
        if ($Purpose -eq 'review' -and $OperationNumber -eq 1 -and $UseReviewReserve) {
            return @{ permitted = $true; reason = 'gpt_reserved_review_reserve_override' }
        }
        return @{ permitted = $false; reason = 'gpt_reserved_general_work_blocked' }
    }

    if ($p -ge $stop) {   # tier3: 80-100
        if ($Purpose -eq 'review') {
            if ($UseReviewReserve) { return @{ permitted = $true; reason = 'gpt_tier3_review_reserve_override' } }
            return @{ permitted = $false; reason = 'gpt_tier3_review_reserve_not_used' }
        }
        return @{ permitted = $false; reason = 'gpt_tier3_general_work_blocked' }
    }

    if ($p -gt $tier1) {  # tier2: 60-79
        if ($Worker -eq 'luna') { return @{ permitted = $true; reason = 'gpt_tier2_luna_mechanical' } }
        if ($Worker -eq 'terra') {
            if ($OperationNumber -eq 2) { return @{ permitted = $true; reason = 'gpt_tier2_terra_op2' } }
            return @{ permitted = $false; reason = 'gpt_tier2_terra_restricted_to_op2' }
        }
        if ($Worker -eq 'sol') {
            if ($Purpose -eq 'review') { return @{ permitted = $true; reason = 'gpt_tier2_sol_review_only' } }
            return @{ permitted = $false; reason = 'gpt_tier2_sol_review_only_implement_blocked' }
        }
    }

    # tier1: 0-59 — 모든 워커 허용
    return @{ permitted = $true; reason = 'gpt_tier1_all_allowed' }
}

function Get-DesiredGptWorker {
    param([Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][string]$Kind,
          [Parameter(Mandatory)][string]$Purpose, [Parameter(Mandatory)]$Config)
    $opKey = [string]$OperationNumber
    if ($Purpose -eq 'review') { return $Config.gpt.desired.$opKey.review }
    if ($OperationNumber -eq 3) { return $Config.gpt.desired.'3'.$Kind }
    return $Config.gpt.desired.$opKey.implement
}

function New-ClaudeOnlyRoute {
    param([Parameter(Mandatory)][int]$OperationNumber, [Parameter(Mandatory)][string]$Kind,
          [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Reason)
    $opKey = [string]$OperationNumber
    if ($OperationNumber -eq 3) {
        $c = $Config.claudeOnly.'3'.$Kind
        $isDirect = ($c.PSObject.Properties.Name -contains 'direct' -and $c.direct)
        if ($isDirect) {
            return [pscustomobject]@{
                status = 'claude_direct'; operation = $OperationNumber; kind = $Kind; worker = 'claude'
                requiredModel = $c.model; requiredEffort = $null; reason = $Reason
            }
        }
        return [pscustomobject]@{
            status = 'claude_only_required'; operation = $OperationNumber; kind = $Kind; worker = 'claude'
            requiredModel = $c.model; requiredEffort = $c.effort; reason = $Reason
        }
    }
    $c = $Config.claudeOnly.$opKey
    $result = [pscustomobject]@{
        status = 'claude_only_required'; operation = $OperationNumber; kind = $Kind; worker = 'claude'
        requiredModel = $c.model; requiredEffort = $c.effort; reason = $Reason
    }
    # v2.4.0-C: 작전 1을 외부 구현·독립 검수 파이프라인 없이 Claude 단일 모델로 진행하는 고위험 상황을
    # 사용자에게 알린다. 차단하지 않고 판단 정보만 제공한다(effort는 이미 high).
    if ($OperationNumber -eq 1) {
        Add-Member -InputObject $result -NotePropertyName highRiskWarning -NotePropertyValue 'Operation 1 is high-risk and both Grok and GPT are unavailable, so there is no external implement + independent-review pipeline — only single-model Claude implementation with Opus end-review. For genuinely dangerous work (schema/save migration, core-engine surgery, data-loss risk), consider waiting for quota reset instead of proceeding via /operation-1-claude.'
    }
    return $result
}

function Resolve-OperationRoute {
    param(
        [Parameter(Mandatory)][int]$OperationNumber,
        [ValidateSet('logic','mechanical')][string]$Kind = 'logic',
        [ValidateSet('implement','review')][string]$Purpose = 'implement',
        [Parameter(Mandatory)]$GrokState,
        [Parameter(Mandatory)]$GptState,
        [switch]$UseGptReviewReserve,
        [switch]$FinishCurrent,
        [Parameter(Mandatory)]$Config
    )
    if ($OperationNumber -notin @(1,2,3)) { throw "Invalid operation number: $OperationNumber" }

    # 검수(review)는 GPT Sol 전용 경로: Grok 대상이 아니다.
    if ($Purpose -eq 'review') {
        $desired = Get-DesiredGptWorker -OperationNumber $OperationNumber -Kind $Kind -Purpose 'review' -Config $Config
        if ($null -eq $desired) {
            return [pscustomobject]@{ status = 'review_not_defined'; operation = $OperationNumber; worker = $null; reason = 'no_review_route' }
        }
        $perm = Test-GptWorkerPermitted -Worker $desired.worker -OperationNumber $OperationNumber -Purpose 'review' `
            -GptState $GptState -Config $Config -UseReviewReserve:$UseGptReviewReserve
        if ($perm.permitted) {
            return [pscustomobject]@{
                status = 'routed'; operation = $OperationNumber; kind = $Kind; purpose = 'review'
                worker = 'gpt'; model = $Config.gpt.workers.($desired.worker); workerAlias = $desired.worker
                effort = $desired.effort; usedReviewReserve = [bool]$UseGptReviewReserve; reason = $perm.reason
            }
        }
        # 검수 불가 -> Opus가 고위험 항목만 직접 종료 검토
        return [pscustomobject]@{
            status = 'claude_review_fallback'; operation = $OperationNumber; kind = $Kind; purpose = 'review'
            worker = 'claude'; reason = $perm.reason
        }
    }

    # 구현(implement)
    $grok = Resolve-GrokDecision -OperationNumber $OperationNumber -GrokState $GrokState -Config $Config -FinishCurrent:$FinishCurrent
    if ($grok.decision -eq 'grok') {
        $opKey = [string]$OperationNumber
        $g = $Config.grok.operations.$opKey
        return [pscustomobject]@{
            status = 'routed'; operation = $OperationNumber; kind = $Kind; purpose = 'implement'
            worker = 'grok'; model = $Config.grok.model; effort = $g.effort; maxTurns = $g.maxTurns
            noPlan = [bool]($g.PSObject.Properties.Name -contains 'noPlan' -and $g.noPlan)
            noSubagents = [bool]($g.PSObject.Properties.Name -contains 'noSubagents' -and $g.noSubagents)
            reason = $grok.reason
        }
    }
    if ($grok.decision -eq 'conserve_blocked') {
        return [pscustomobject]@{
            status = 'blocked'; operation = $OperationNumber; kind = $Kind; purpose = 'implement'
            worker = $null; reason = $grok.reason
            hint = 'Grok 85-94%: 작전 1/2 신규 실행 보호. --finish-current로 기존 작업 마감만 허용, 또는 /operation set grok <값> 조정.'
        }
    }

    # plan_b: Grok 소진/95%+ -> GPT 시도
    $desired = Get-DesiredGptWorker -OperationNumber $OperationNumber -Kind $Kind -Purpose 'implement' -Config $Config
    $perm = Test-GptWorkerPermitted -Worker $desired.worker -OperationNumber $OperationNumber -Purpose 'implement' `
        -GptState $GptState -Config $Config -UseReviewReserve:$UseGptReviewReserve
    if ($perm.permitted) {
        return [pscustomobject]@{
            status = 'routed'; operation = $OperationNumber; kind = $Kind; purpose = 'implement'
            worker = 'gpt'; model = $Config.gpt.workers.($desired.worker); workerAlias = $desired.worker
            effort = $desired.effort; reason = "grok_plan_b:$($perm.reason)"
        }
    }
    # GPT 불가 -> Claude-only (op3 mechanical은 claude_direct)
    return (New-ClaudeOnlyRoute -OperationNumber $OperationNumber -Kind $Kind -Config $Config -Reason "grok_plan_b_gpt_denied:$($perm.reason)")
}
