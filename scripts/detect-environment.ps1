# 설치 환경 실측 (doctor). 비밀값 미기록. 유료 모델 호출 없이 --version/--help/login status만 사용.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    return $cmd.Source
}
function Invoke-Safe {
    param([Parameter(Mandatory)][scriptblock]$Block)
    try { $out = & $Block 2>&1; return @{ ok = $true; output = ($out -join "`n") } }
    catch { return @{ ok = $false; output = $_.Exception.Message } }
}
function Get-CodexModelIds {
    $result = @{ sol = 'unresolved'; terra = 'unresolved'; luna = 'unresolved'; source = 'not_found' }
    $cachePath = Join-Path $HOME '.codex\models_cache.json'
    if (-not (Test-Path -LiteralPath $cachePath)) { return $result }
    try {
        $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $result.source = $cachePath
        foreach ($m in $cache.models) {
            if ($m.slug -eq 'gpt-5.6-sol')   { $result.sol   = $m.slug }
            if ($m.slug -eq 'gpt-5.6-terra') { $result.terra = $m.slug }
            if ($m.slug -eq 'gpt-5.6-luna')  { $result.luna  = $m.slug }
        }
    } catch { $result.source = "read_error: $($_.Exception.Message)" }
    return $result
}

# v2.3.2 grok 헤드리스 권한 doctor 판정 (순수 함수, 테스트 가능).
# FAIL 조건: (1) 헤드리스 permission mode가 acceptEdits (2) allow/deny 구문 미검증 (3) JSON 출력인데 stopReason 파서 없음
function Get-GrokHeadlessDoctor {
    param(
        [AllowNull()][string]$ConfiguredMode,
        [bool]$AllowSupported, [bool]$DenySupported, [bool]$DontAskSupported,
        [bool]$JsonStopReasonParser, [bool]$HardcodedAcceptEdits,
        [bool]$AlwaysApproveSupported = $false
    )
    $fatal = @()
    if ($ConfiguredMode -eq 'acceptEdits' -or $HardcodedAcceptEdits) { $fatal += 'headless_permission_mode_acceptEdits' }
    if (-not ($AllowSupported -and $DenySupported)) { $fatal += 'allow_deny_syntax_unverified' }
    # v2.3.3: dontAsk는 grok 내장 ask 규칙(heredoc/명령 치환)에 답할 수 없어 PermissionCancelled로 세션이 죽는다.
    if ($ConfiguredMode -eq 'dontAsk') { $fatal += 'headless_mode_dontask_permission_cancelled_risk' }
    elseif ($ConfiguredMode -eq 'alwaysApprove') {
        if (-not $AlwaysApproveSupported) { $fatal += 'always_approve_flag_unverified' }
    }
    elseif (-not $DontAskSupported) { $fatal += 'permission_mode_syntax_unverified' }
    if (-not $JsonStopReasonParser) { $fatal += 'json_output_without_stopreason_parser' }
    return [pscustomobject]@{ pass = ($fatal.Count -eq 0); fatalIssues = @($fatal) }
}

function Invoke-EnvironmentDetection {
    $report = [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        modelDiscovered = $true
        executionVerified = $false
        claude = [ordered]@{}; grok = [ordered]@{}; codex = [ordered]@{}
        gh = [ordered]@{}; git = [ordered]@{}; powershell = [ordered]@{}
        skillFrontmatter = [ordered]@{}; grokHeadless = [ordered]@{}
    }

    $claudePath = Test-CommandAvailable -Name 'claude'
    $report.claude.found = [bool]$claudePath; $report.claude.path = $claudePath
    if ($claudePath) { $report.claude.version = (Invoke-Safe { & claude --version }).output.Trim() }

    $grokPath = Test-CommandAvailable -Name 'grok'
    $report.grok.found = [bool]$grokPath; $report.grok.path = $grokPath
    if ($grokPath) {
        $report.grok.version = (Invoke-Safe { & grok --version }).output.Trim()
        $m = Invoke-Safe { & grok models }
        $report.grok.modelsOutput = $m.output.Trim()
        if ($m.output -match 'grok-4\.5') { $report.grok.defaultModel = 'grok-4.5' } else { $report.grok.defaultModel = 'unresolved' }
    }

    # v2.3.2: grok 헤드리스 권한 실측 (grok --help 문자열 확인, 유료 호출 없음).
    $helpText = ''
    if ($grokPath) { $helpText = (Invoke-Safe { & grok --help }).output }
    $dontAskSupported = ($helpText -match 'dontAsk')
    $alwaysApproveSupported = ($helpText -match '--always-approve')
    $allowSupported   = ($helpText -match '(?m)--allow\b')
    $denySupported    = ($helpText -match '(?m)--deny\b')
    $noAutoUpdateFlag = ($helpText -match '--no-auto-update')
    # config의 헤드리스 권한 정책
    $configuredMode = $null; $allowRules = @(); $denyRules = @()
    try {
        $cfg = Get-Config
        if ($cfg.grok.PSObject.Properties.Name -contains 'headlessPermissions') {
            $hp = $cfg.grok.headlessPermissions
            if ($hp.PSObject.Properties.Name -contains 'mode') { $configuredMode = [string]$hp.mode }
            if ($hp.PSObject.Properties.Name -contains 'allow' -and $null -ne $hp.allow) { $allowRules = @($hp.allow) }
            if ($hp.PSObject.Properties.Name -contains 'deny'  -and $null -ne $hp.deny)  { $denyRules  = @($hp.deny) }
        }
    } catch { $configuredMode = "config_read_error: $($_.Exception.Message)" }
    # invoke-grok.ps1 소스 실측: stopReason 파서 존재 여부, acceptEdits 하드코딩 여부
    $grokScriptPath = Join-Path $PSScriptRoot 'invoke-grok.ps1'
    $grokScriptText = ''
    if (Test-Path -LiteralPath $grokScriptPath) { $grokScriptText = Get-Content -LiteralPath $grokScriptPath -Raw -Encoding UTF8 }
    $stopReasonParser = ($grokScriptText -match 'stopReason')
    $hardcodedAcceptEdits = ($grokScriptText -match "'acceptEdits'" -or $grokScriptText -match '"acceptEdits"' -or $grokScriptText -match '=\s*''acceptEdits''')

    $report.grokHeadless.permissionModeDontAskSupported = [bool]$dontAskSupported
    $report.grokHeadless.alwaysApproveFlagSupported = [bool]$alwaysApproveSupported
    $report.grokHeadless.allowRuleSupported = [bool]$allowSupported
    $report.grokHeadless.denyRuleSupported = [bool]$denySupported
    $report.grokHeadless.noAutoUpdateFlagSupported = [bool]$noAutoUpdateFlag
    $report.grokHeadless.noAutoUpdateNote = 'grok 0.2.102에는 --no-auto-update 플래그·환경변수·config 키가 없다. 추측 구문을 넣지 않으며(없는 플래그는 grok 실행을 깨뜨림), 헤드리스 --output-format json 실행은 대화형 자동 업데이트를 유발하지 않는다.'
    $report.grokHeadless.configuredMode = $configuredMode
    $report.grokHeadless.usesAcceptEdits = ($configuredMode -eq 'acceptEdits' -or $hardcodedAcceptEdits)
    $report.grokHeadless.allowRules = $allowRules
    $report.grokHeadless.denyRules = $denyRules
    $report.grokHeadless.jsonStopReasonParserPresent = [bool]$stopReasonParser
    $doctor = Get-GrokHeadlessDoctor -ConfiguredMode $configuredMode -AllowSupported $allowSupported -DenySupported $denySupported `
        -DontAskSupported $dontAskSupported -JsonStopReasonParser $stopReasonParser -HardcodedAcceptEdits $hardcodedAcceptEdits `
        -AlwaysApproveSupported $alwaysApproveSupported
    $report.grokHeadless.pass = $doctor.pass
    $report.grokHeadless.fatalIssues = $doctor.fatalIssues

    $codexPath = Test-CommandAvailable -Name 'codex'
    $report.codex.found = [bool]$codexPath; $report.codex.path = $codexPath
    if ($codexPath) {
        $report.codex.version = (Invoke-Safe { & codex --version }).output.Trim()
        $report.codex.loginStatus = (Invoke-Safe { & codex login status }).output.Trim()
        $report.codex.models = Get-CodexModelIds
    }

    $ghPath = Test-CommandAvailable -Name 'gh'
    $report.gh.found = [bool]$ghPath; $report.gh.path = $ghPath
    if ($ghPath) {
        $report.gh.version = ((Invoke-Safe { & gh --version }).output -split "`n" | Select-Object -First 1)
        $authText = (Invoke-Safe { & gh auth status }).output
        $report.gh.authenticated = ($authText -match 'Logged in to')
        if ($authText -match 'Logged in to') { $report.gh.authNote = 'logged_in' } else { $report.gh.authNote = 'not_logged_in_or_error' }
    }

    $gitPath = Test-CommandAvailable -Name 'git'
    $report.git.found = [bool]$gitPath; $report.git.path = $gitPath
    if ($gitPath) { $report.git.version = (Invoke-Safe { & git --version }).output.Trim() }

    $pwshPath = Test-CommandAvailable -Name 'pwsh'
    $powershellExePath = Test-CommandAvailable -Name 'powershell.exe'
    $report.powershell.pwshFound = [bool]$pwshPath; $report.powershell.pwshPath = $pwshPath
    $report.powershell.windowsPowerShellFound = [bool]$powershellExePath
    $report.powershell.windowsPowerShellPath = $powershellExePath
    if ($pwshPath) { $report.powershell.selected = $pwshPath } elseif ($powershellExePath) { $report.powershell.selected = $powershellExePath } else { $report.powershell.selected = $null }
    $report.powershell.selectedVersion = $PSVersionTable.PSVersion.ToString()

    # Skill frontmatter 지원 (claude.exe 문자열 실측으로 확인된 사실. executionVerified=false).
    $report.skillFrontmatter.supportedKeysConfirmed = @('name','description','model','allowed-tools','argument-hint','disable-model-invocation','user-invocable','effort','when_to_use')
    $report.skillFrontmatter.modelIdsRecognized = @('claude-opus-4-8','claude-sonnet-5','claude-haiku-4-5-20251001')
    $report.skillFrontmatter.dynamicModelSwitchConfirmed = $false
    $report.skillFrontmatter.note = 'Confirmed by inspecting claude.exe frontmatter key allowlist; not runtime-executed.'

    return $report
}

if ($MyInvocation.InvocationName -ne '.') {
    $report = Invoke-EnvironmentDetection
    Write-JsonFile -Path $Script:DoctorReportPath -Object $report
    $report | ConvertTo-Json -Depth 10
}
