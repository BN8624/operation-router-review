# Codex CLI(GPT) 헤드리스 래퍼. 문서화된 옵션만 사용 (codex exec --help 2026-07-20). 전경 1회 실행.
# 프롬프트는 stdin으로 전달 (codex exec는 --prompt-file 없음). unresolved 모델은 fail-closed.
# v2.3.3: codex exec에는 -a/--ask-for-approval 플래그가 없다 (2026-07-20 op3-issue4 E2E에서 exit 2 실측).
#         approval은 -c approval_policy=<값> config 오버라이드로 전달하고, workspace-write 샌드박스에서
#         origin push가 가능하도록 -c sandbox_workspace_write.network_access=true를 함께 준다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

function Invoke-GptWorker {
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Effort,
        [Parameter(Mandatory)][string]$PromptFilePath,
        [string]$Sandbox = 'workspace-write',
        [string]$ApprovalPolicy = 'never',
        [scriptblock]$Runner
    )
    if ($Model -eq 'unresolved' -or [string]::IsNullOrWhiteSpace($Model)) {
        throw 'GPT model id is unresolved. Refusing to invoke Codex CLI with a guessed model id.'
    }
    if (-not (Test-Path -LiteralPath $Cwd)) { throw "Working directory not found: $Cwd" }
    if (-not (Test-Path -LiteralPath $PromptFilePath)) { throw "Prompt file not found: $PromptFilePath" }

    $argList = @(
        'exec', '--cd', $Cwd, '-m', $Model, '-c', "model_reasoning_effort=$Effort",
        '-s', $Sandbox, '-c', "approval_policy=$ApprovalPolicy", '--json'
    )
    if ($Sandbox -eq 'workspace-write') { $argList += @('-c', 'sandbox_workspace_write.network_access=true') }
    $argList += '-'
    if ($null -eq $Runner) { $Runner = { param($fp, $al) Invoke-ForegroundCommand -FilePath $fp -ArgumentList $al -StdinFilePath $PromptFilePath } }
    $result = & $Runner 'codex' $argList

    $errClass = Get-WorkerErrorClass -Text $result.Output
    return [pscustomobject]@{
        Worker = 'gpt'; Model = $Model; ExitCode = $result.ExitCode; Success = ($result.ExitCode -eq 0)
        QuotaExhausted = ($errClass -eq 'weekly_exhausted'); ErrorClass = $errClass
        Output = $result.Output; ArgumentList = $argList
    }
}
