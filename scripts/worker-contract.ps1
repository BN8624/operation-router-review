# worker 결과 분류·완료 보고서 파싱·오류 정책을 제공하는 dot-source 모듈이다.

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

# errorClass → 최종 status 매핑. weekly는 Plan B 후보(quota_exhausted), 그 외는 분류별 고정 상태.
function Get-WorkerPolicyStatus {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ErrorClass)
    switch ($ErrorClass) {
        'weekly_exhausted'      { return 'quota_exhausted' }
        'transient_rate_limit'  { return 'transient_rate_limited' }
        'provider_failure'      { return 'provider_failure' }
        'quota_unknown'         { return 'quota_unknown' }
        'worker_cancelled'      { return 'worker_cancelled' }
        'worker_turn_limit'     { return 'worker_turn_limit' }
        'worker_protocol_error' { return 'worker_protocol_error' }
        default                 { return 'worker_failed' }
    }
}

function ConvertFrom-WorkerCompletionReport {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $invalid = {
        param([string]$Reason)
        [pscustomobject]@{
            valid=$false;reason=$Reason;localVerificationComplete=$false
            verification=$null;remainingProblems=@()
        }
    }
    if([string]::IsNullOrWhiteSpace($Text)){return (& $invalid 'worker_report_missing')}

    $structured=@()
    foreach($line in @($Text -split "`r?`n")){
        $trimmed=$line.Trim()
        if($trimmed.Length -lt 2 -or -not $trimmed.StartsWith('{')){continue}
        try{$event=$trimmed|ConvertFrom-Json -ErrorAction Stop}catch{continue}
        if($null -ne $event -and $event.PSObject.Properties.Name -contains 'item' -and $null -ne $event.item -and
            $event.item.PSObject.Properties.Name -contains 'type' -and [string]$event.item.type -eq 'agent_message' -and
            $event.item.PSObject.Properties.Name -contains 'text' -and -not [string]::IsNullOrWhiteSpace([string]$event.item.text)){
            $structured += [string]$event.item.text
        }
    }
    if($structured.Count -eq 0){
        $start=$Text.IndexOf('{');$end=$Text.LastIndexOf('}')
        if($start -ge 0 -and $end -gt $start){
            try{
                $grok=$Text.Substring($start,$end-$start+1)|ConvertFrom-Json -ErrorAction Stop
                if($null -ne $grok -and $grok.PSObject.Properties.Name -contains 'text' -and
                    -not [string]::IsNullOrWhiteSpace([string]$grok.text)){
                    $structured += [string]$grok.text
                }
            }catch{}
        }
    }
    $candidate=if($structured.Count -gt 0){[string]$structured[$structured.Count-1]}else{$Text}
    # F2: 마커와 JSON 사이의 CLI 장식을 허용한다. grok은 계약대로 보고하면서도 마커 뒤에
    # ': #display-json' 같은 렌더링 주석을 덧붙인다(2026-07-24 op1-issue19 실측). 이전 정규식은
    # 마커와 '{' 사이에 공백만 허용해, 계약을 지킨 성공 실행의 보고를 worker_report_missing으로
    # 버리고 localVerificationComplete=false로 만들어 finalize의 merge_ready 도달을 막았다.
    # '{'가 아닌 문자만 건너뛰므로 JSON 본문 자체는 그대로 첫 '{'부터 캡처된다.
    $matches=[regex]::Matches($candidate,'(?m)^\s*\[ORH_WORKER_REPORT\][^\{\r\n]*(\{[^\r\n]+\})\s*$')
    if($matches.Count -eq 0){return (& $invalid 'worker_report_missing')}
    try{$report=$matches[$matches.Count-1].Groups[1].Value|ConvertFrom-Json -ErrorAction Stop}catch{return (& $invalid 'worker_report_invalid_json')}
    if($null -eq $report){return (& $invalid 'worker_report_null')}
    $props=@($report.PSObject.Properties.Name)
    if($props.Count -ne 3 -or @($props|Where-Object{$_ -notin @('localVerificationComplete','verification','remainingProblems')}).Count -gt 0){
        return (& $invalid 'worker_report_schema_mismatch')
    }
    if($report.localVerificationComplete -isnot [bool] -or $report.verification -isnot [string] -or
        $report.remainingProblems -isnot [System.Array] -or
        [string]::IsNullOrWhiteSpace([string]$report.verification)){
        return (& $invalid 'worker_report_schema_mismatch')
    }
    $remaining=@()
    foreach($problem in @($report.remainingProblems)){
        if($problem -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$problem)){
            return (& $invalid 'worker_report_schema_mismatch')
        }
        $safe=Protect-SecretText -Text ([string]$problem)
        if($safe.Length -gt 300){$safe=$safe.Substring(0,300)+'...[truncated]'}
        $remaining+=$safe
        if($remaining.Count -gt 20){return (& $invalid 'worker_report_too_many_problems')}
    }
    $verification=Protect-SecretText -Text ([string]$report.verification)
    if($verification.Length -gt 2000){$verification=$verification.Substring(0,2000)+'...[truncated]'}
    return [pscustomobject]@{
        valid=$true;reason=$null;localVerificationComplete=[bool]$report.localVerificationComplete
        verification=$verification;remainingProblems=@($remaining)
    }
}

function ConvertFrom-ClaudeCompletionReport {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][int]$ExpectedOperation,
        [Parameter(Mandatory)][int]$ExpectedIssueNumber,
        [Parameter(Mandatory)][string]$ExpectedHead,
        [Parameter(Mandatory)][string]$ExpectedWorkBranch
    )
    $invalid = {
        param([string]$Reason)
        [pscustomobject]@{
            valid=$false;reason=$Reason;localVerificationComplete=$false
            verification=$null;remainingProblems=@();head=$null;workBranch=$null
        }
    }
    if ([string]::IsNullOrWhiteSpace($Json)) { return (& $invalid 'claude_completion_report_missing') }
    try { $report = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch { return (& $invalid 'claude_completion_report_invalid_json') }
    if ($null -eq $report) { return (& $invalid 'claude_completion_report_null') }
    $props=@($report.PSObject.Properties.Name)
    $allowed=@('schemaVersion','operation','issueNumber','head','workBranch','localVerificationComplete','verification','remainingProblems')
    if ($props.Count -ne $allowed.Count -or @($props | Where-Object { $_ -notin $allowed }).Count -gt 0) {
        return (& $invalid 'claude_completion_report_schema_mismatch')
    }
    if ($report.schemaVersion -isnot [int] -or [int]$report.schemaVersion -ne 1 -or
        $report.operation -isnot [int] -or [int]$report.operation -ne $ExpectedOperation -or
        $report.issueNumber -isnot [int] -or [int]$report.issueNumber -ne $ExpectedIssueNumber -or
        $report.head -isnot [string] -or $report.workBranch -isnot [string] -or
        $report.localVerificationComplete -isnot [bool] -or $report.verification -isnot [string] -or
        $report.remainingProblems -isnot [System.Array]) {
        return (& $invalid 'claude_completion_report_schema_mismatch')
    }
    if ([string]$report.head -cne $ExpectedHead) { return (& $invalid 'claude_completion_report_head_mismatch') }
    if ([string]$report.workBranch -cne $ExpectedWorkBranch) { return (& $invalid 'claude_completion_report_branch_mismatch') }
    if ([string]::IsNullOrWhiteSpace([string]$report.verification) -or
        ([string]$report.verification).Trim().Equals(
            'current Claude session completed implementation',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return (& $invalid 'claude_completion_report_verification_invalid')
    }
    $remaining=@()
    foreach ($problem in @($report.remainingProblems)) {
        if ($problem -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$problem)) {
            return (& $invalid 'claude_completion_report_schema_mismatch')
        }
        $safe=Protect-SecretText -Text ([string]$problem)
        if ($safe.Length -gt 300) { $safe=$safe.Substring(0,300)+'...[truncated]' }
        $remaining+=$safe
        if ($remaining.Count -gt 20) { return (& $invalid 'claude_completion_report_too_many_problems') }
    }
    $verification=Protect-SecretText -Text ([string]$report.verification)
    if ($verification.Length -gt 2000) { $verification=$verification.Substring(0,2000)+'...[truncated]' }
    return [pscustomobject]@{
        valid=$true;reason=$null;localVerificationComplete=[bool]$report.localVerificationComplete
        verification=$verification;remainingProblems=@($remaining)
        head=[string]$report.head;workBranch=[string]$report.workBranch
    }
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
    return (Invoke-UsageStateUpdate -Update {
        param($current)
        $current.$Provider.status = 'exhausted'
        $current.$Provider.percent = 100
        return $current
    })
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
        $State = Set-ProviderExhausted -Provider $Provider -State $State
        $usageChanged = $true
        if ($null -ne $Log) { $Log.Add("$Provider marked exhausted/100 after explicit weekly exhaustion") }
    }

    return [pscustomobject]@{
        Result = $result; Success = $false; ErrorClass = $errorClass; Attempts = $attempts
        UsageStateChanged = $usageChanged; State = $State
    }
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
