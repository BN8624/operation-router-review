# Grok CLI 헤드리스 래퍼. 문서화된 옵션만 사용 (grok --help 2026-07-20). 전경 1회 실행.
# v2.3.2: acceptEdits 제거 → config.grok.headlessPermissions(dontAsk + allow/deny). exit 0만으로 성공 처리하지 않고
#         --output-format json 결과의 stopReason을 구조적으로 파싱해 Cancelled/turn limit/파싱실패를 실패로 판정한다.
# v2.3.3: mode=alwaysApprove 지원. grok 내장 정책은 heredoc(<<)·명령 치환이 든 명령을 ask 규칙으로 분류하는데,
#         dontAsk 헤드리스에서는 질문이 불가능해 세션 전체가 cancellationCategory=PermissionCancelled로 취소된다
#         (2026-07-20 op2-issue3 디버그 로그로 실측). --always-approve는 ask를 없애고, --deny는 여전히 우선 차단되며
#         deny 거부가 세션을 취소하지 않고 도구 오류로 전달됨을 프로브로 확인했다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

# grok 헤드리스 JSON(--output-format json) 결과를 구조적으로 파싱한다. 정규식만으로 판정하지 않는다.
# 앞뒤 부수 텍스트가 있어도 첫 '{'~마지막 '}'를 실제 JSON으로 파싱한다.
function ConvertFrom-GrokHeadlessJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $fail = { param($reason) [pscustomobject]@{ parsed = $false; stopReason = $null; sessionId = $null; text = $null; usage = $null; costUSD = $null; parseError = $reason } }
    if ([string]::IsNullOrWhiteSpace($Text)) { return (& $fail 'empty_output') }
    $start = $Text.IndexOf('{'); $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return (& $fail 'no_json_object_found') }
    $json = $Text.Substring($start, $end - $start + 1)
    try { $obj = $json | ConvertFrom-Json } catch { return (& $fail "json_parse_error: $($_.Exception.Message)") }
    if ($null -eq $obj) { return (& $fail 'null_json') }
    $props = $obj.PSObject.Properties.Name
    $get = { param($n) if ($props -contains $n -and $null -ne $obj.$n) { $obj.$n } else { $null } }
    $usd = $null
    if ($props -contains 'total_cost_usd' -and $null -ne $obj.total_cost_usd) { $usd = $obj.total_cost_usd }
    return [pscustomobject]@{
        parsed = $true
        stopReason = (& $get 'stopReason')
        sessionId  = (& $get 'sessionId')
        text       = (& $get 'text')
        usage      = (& $get 'usage')
        costUSD    = $usd
        parseError = $null
    }
}

# grok 워커 결과 분류 (순수 함수, 테스트 가능). exit code 0을 성공으로 간주하지 않는다.
# F1: 텍스트 오류 분류는 "실패 여부"가 아니라 "어떤 실패인가"만 답한다. 실패 여부는 JSON 파싱·
# stopReason·종료코드로 판정하고, 이 신호가 모두 정상이면 성공이다. 정상 종료의 어시스턴트 완료
# 보고 텍스트에 우연히 든 'permission'/'billing'/'429' 같은 단어로 성공을 실패로 뒤집지 않는다.
# 우선순위: (0) JSON 파싱 실패·stopReason 오류계열·exit≠0 중 하나라도 있으면 실패 경로, 아니면 성공.
#           (1) 실패 경로에서 텍스트가 명시적 weekly/transient/provider/quota_unknown이면 그대로 (v2.3 분류 보존)
#           (2) JSON 파싱 실패 → worker_protocol_error
#           (3) stopReason Cancelled/Aborted → worker_cancelled
#           (4) stopReason MaxTurns/turn limit → worker_turn_limit
#           (5) stopReason Error/Refusal → worker_error(일반 실패)
#           (6) 그 외 실패(exit≠0) → worker_failed
function Get-GrokResultClassification {
    param([Parameter(Mandatory)][int]$ExitCode, [Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    $textClass = Get-WorkerErrorClass -Text $Output
    $parsed = ConvertFrom-GrokHeadlessJson -Text $Output
    $stopReason = $null
    if ($parsed.parsed) { $stopReason = [string]$parsed.stopReason }

    # 실행이 실제로 실패를 가리키는 신호. 하나도 없으면 정상 종료이며 텍스트 오류 스캔을 적용하지 않는다.
    $stopReasonFailed = ($null -ne $stopReason -and $stopReason -match '(?i)cancel|abort|max.?turns|turn.?limit|error|refus')
    $runFailed = ((-not $parsed.parsed) -or $stopReasonFailed -or ($ExitCode -ne 0))

    $success = $false
    if (-not $runFailed) {
        $errClass = 'none'; $success = $true
    }
    elseif ($textClass -in @('weekly_exhausted','transient_rate_limit','provider_failure','quota_unknown')) {
        $errClass = $textClass
    }
    elseif (-not $parsed.parsed) {
        $errClass = 'worker_protocol_error'
    }
    elseif ($stopReason -match '(?i)cancel|abort') {
        $errClass = 'worker_cancelled'
    }
    elseif ($stopReason -match '(?i)max.?turns|turn.?limit') {
        $errClass = 'worker_turn_limit'
    }
    elseif ($stopReason -match '(?i)error|refus') {
        $errClass = 'worker_error'
    }
    else {
        $errClass = 'worker_failed'
    }

    return [pscustomobject]@{
        Success = $success
        ErrorClass = $errClass
        StopReason = $stopReason
        SessionId = $parsed.sessionId
        QuotaExhausted = ($errClass -eq 'weekly_exhausted')
        ParseError = $parsed.parseError
        CostUSD = $parsed.costUSD
    }
}

function Get-GrokWorkerInvocation {
    param(
        [Parameter(Mandatory)][string]$Cwd, [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Effort, [Parameter(Mandatory)][int]$MaxTurns,
        [Parameter(Mandatory)][string]$PromptFilePath, [bool]$NoPlan = $false,
        [bool]$NoSubagents = $false, $Permissions = $null
    )
    if ($null -eq $Permissions) { $Permissions = (Get-Config).grok.headlessPermissions }
    $mode = [string]$Permissions.mode
    if ([string]::IsNullOrWhiteSpace($mode)) { throw 'headless permission mode is empty; refusing to run (config.grok.headlessPermissions.mode)' }
    $argList = @('--cwd', $Cwd, '--model', $Model, '--reasoning-effort', $Effort,
        '--max-turns', [string]$MaxTurns, '--prompt-file', $PromptFilePath, '--output-format', 'json')
    if ($mode -eq 'alwaysApprove') { $argList += '--always-approve' } else { $argList += @('--permission-mode', $mode) }
    if ($null -ne $Permissions.allow) { foreach ($a in @($Permissions.allow)) { if (-not [string]::IsNullOrWhiteSpace([string]$a)) { $argList += @('--allow', [string]$a) } } }
    if ($null -ne $Permissions.deny) { foreach ($d in @($Permissions.deny)) { if (-not [string]::IsNullOrWhiteSpace([string]$d)) { $argList += @('--deny', [string]$d) } } }
    if ($NoPlan) { $argList += '--no-plan' }
    if ($NoSubagents) { $argList += '--no-subagents' }
    if (-not [string]::IsNullOrWhiteSpace($env:OPERATION_ROUTER_GROK_DEBUG)) { $argList += @('--debug-file', [string]$env:OPERATION_ROUTER_GROK_DEBUG) }
    return [pscustomobject]@{ filePath = 'grok'; argumentList = @($argList); stdinMode = 'nul'; permissionMode = $mode }
}

function Invoke-GrokWorker {
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Effort,
        [Parameter(Mandatory)][int]$MaxTurns,
        [Parameter(Mandatory)][string]$PromptFilePath,
        [bool]$NoPlan = $false,
        [bool]$NoSubagents = $false,
        $Permissions = $null,
        [scriptblock]$Runner
    )
    if (-not (Test-Path -LiteralPath $Cwd)) { throw "Working directory not found: $Cwd" }
    if (-not (Test-Path -LiteralPath $PromptFilePath)) { throw "Prompt file not found: $PromptFilePath" }

    $invocation = Get-GrokWorkerInvocation -Cwd $Cwd -Model $Model -Effort $Effort -MaxTurns $MaxTurns `
        -PromptFilePath $PromptFilePath -NoPlan:$NoPlan -NoSubagents:$NoSubagents -Permissions $Permissions
    $argList = @($invocation.argumentList)
    $mode = $invocation.permissionMode

    if ($null -eq $Runner) { $Runner = { param($fp, $al) Invoke-ForegroundCommand -FilePath $fp -ArgumentList $al } }
    $result = & $Runner 'grok' $argList

    $cls = Get-GrokResultClassification -ExitCode ([int]$result.ExitCode) -Output ([string]$result.Output)
    return [pscustomobject]@{
        Worker = 'grok'
        ExitCode = $result.ExitCode
        Success = $cls.Success
        QuotaExhausted = $cls.QuotaExhausted
        ErrorClass = $cls.ErrorClass
        WorkerStopReason = $cls.StopReason
        SessionId = $cls.SessionId
        Output = $result.Output
        ArgumentList = $argList
        PermissionMode = $mode
    }
}
