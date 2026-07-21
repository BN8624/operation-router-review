# 장시간 외부 워커를 독립 실행하고 출력·종료 결과를 실행 세대 파일에 영속화한다.

param(
    [Parameter(Mandatory)][string]$ExecutionReceiptPath,
    [Parameter(Mandatory)][string]$InvocationPath,
    [string]$PendingDirOverride,
    [string]$LogRootOverride,
    [string]$ConfigPathOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'invoke-grok.ps1')
. (Join-Path $PSScriptRoot 'invoke-gpt.ps1')

if (-not [string]::IsNullOrWhiteSpace($PendingDirOverride)) { $Script:PendingDir = [System.IO.Path]::GetFullPath($PendingDirOverride) }
if (-not [string]::IsNullOrWhiteSpace($LogRootOverride)) { $Script:LogRoot = [System.IO.Path]::GetFullPath($LogRootOverride) }
if (-not [string]::IsNullOrWhiteSpace($ConfigPathOverride)) { $Script:ConfigPath = [System.IO.Path]::GetFullPath($ConfigPathOverride) }

function Update-ExecutionMaskedLog {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$Header)
    $stdout = Read-SharedTextFile -Path ([string]$Receipt.rawStdoutPath)
    $stderr = Read-SharedTextFile -Path ([string]$Receipt.rawStderrPath)
    $body = $stdout
    if (-not [string]::IsNullOrEmpty($stderr)) { $body += "`n[stderr]`n$stderr" }
    $text = $Header + "`ncliStarted=true`n`n" + (Protect-SecretText -Text $body)
    [System.IO.File]::WriteAllText([string]$Receipt.logPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-WorkerExecutable {
    param([Parameter(Mandatory)][string]$Name)
    $found = Get-Command $Name -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and $_.Source -match '\.(exe|cmd|bat)$' } | Select-Object -First 1
    if ($null -eq $found) { throw "Worker executable not found: $Name" }
    return $found.Source
}

$receipt = Read-JsonFile -Path $ExecutionReceiptPath
$invocation = Read-JsonFile -Path $InvocationPath
if ([string]$receipt.executionId -ne [string]$invocation.executionId -or [int]$receipt.generation -ne [int]$invocation.generation) {
    throw 'Invocation does not match execution receipt generation.'
}
if (-not (Test-ReceiptRepoMatch -Receipt $receipt -RepoPath ([string]$receipt.repoRoot))) { throw 'Execution receipt repository mismatch.' }
foreach ($path in @($ExecutionReceiptPath,$InvocationPath,$receipt.resultPath,$receipt.rawStdoutPath,$receipt.rawStderrPath)) {
    Assert-PathWithinRoot -Path ([string]$path) -Root $Script:PendingDir | Out-Null
}
Assert-PathWithinRoot -Path ([string]$receipt.logPath) -Root $Script:LogRoot | Out-Null

$header = Read-SharedTextFile -Path ([string]$receipt.logPath)
$wrapper = Join-Path (Split-Path -Parent $InvocationPath) 'worker-wrapper.cmd'
Assert-PathWithinRoot -Path $wrapper -Root $Script:PendingDir | Out-Null
$exe = Resolve-WorkerExecutable -Name ([string]$invocation.filePath)
$env:ORH_EXE = $exe
$argRefs = @()
$index = 0
foreach ($arg in @($invocation.argumentList)) {
    $name = "ORH_ARG_$index"
    [Environment]::SetEnvironmentVariable($name, [string]$arg, 'Process')
    $argRefs += ('"%' + $name + '%"')
    $index++
}
$stdin = '< NUL'
if ([string]$invocation.stdinMode -eq 'file') {
    $env:ORH_PROMPT = [string]$invocation.promptPath
    $stdin = '< "%ORH_PROMPT%"'
}
$wrapperContent = "@echo off`r`ncall `"%ORH_EXE%`" $($argRefs -join ' ') $stdin`r`nset `"ORH_RC=%ERRORLEVEL%`"`r`nexit /b %ORH_RC%`r`n"
[System.IO.File]::WriteAllText($wrapper, $wrapperContent, [System.Text.Encoding]::ASCII)

try {
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/s','/c',('"' + $wrapper + '"')) `
        -WorkingDirectory ([string]$receipt.repoRoot) -RedirectStandardOutput ([string]$receipt.rawStdoutPath) `
        -RedirectStandardError ([string]$receipt.rawStderrPath) -PassThru -WindowStyle Hidden
    $receipt.status = 'worker_running'
    $receipt.processId = $proc.Id
    $receipt.processStartedAt = $proc.StartTime.ToUniversalTime().ToString('o')
    Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
    while (-not $proc.HasExited) {
        Update-ExecutionMaskedLog -Receipt $receipt -Header $header
        $receipt = Get-ExecutionReceipt -Operation ([int]$receipt.operation) -IssueNumber ([int]$receipt.issueNumber) -RepoPath ([string]$receipt.repoRoot)
        if ([string]$receipt.executionId -ne [string]$invocation.executionId) { throw 'Execution generation changed while worker was running.' }
        Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
        Start-Sleep -Milliseconds 1000
        $proc.Refresh()
    }
    $proc.WaitForExit()
    Update-ExecutionMaskedLog -Receipt $receipt -Header $header
    $stdout = Read-SharedTextFile -Path ([string]$receipt.rawStdoutPath)
    $stderr = Read-SharedTextFile -Path ([string]$receipt.rawStderrPath)
    $output = $stdout + $stderr
    $success = ($proc.ExitCode -eq 0)
    $errorClass = Get-WorkerErrorClass -Text $output
    $stopReason = $null
    $quota = ($errorClass -eq 'weekly_exhausted')
    if ([string]$receipt.worker -eq 'grok') {
        $classification = Get-GrokResultClassification -ExitCode $proc.ExitCode -Output $output
        $success = $classification.Success; $errorClass = $classification.ErrorClass
        $stopReason = $classification.StopReason; $quota = $classification.QuotaExhausted
    }
    $envelope = [pscustomobject]@{
        schemaVersion = 1; executionId = $receipt.executionId; generation = $receipt.generation
        worker = $receipt.worker; exitCode = $proc.ExitCode; success = [bool]$success
        quotaExhausted = [bool]$quota; errorClass = $errorClass; workerStopReason = $stopReason
        workerReportedVerification = $null; localVerificationComplete = $false
        stdoutPath = $receipt.rawStdoutPath; stderrPath = $receipt.rawStderrPath
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-AtomicJsonFile -Path ([string]$receipt.resultPath) -Object $envelope
    $receipt.status = 'worker_exited_postflight_pending'
    $receipt.workerExitCode = $proc.ExitCode
    $receipt.workerStopReason = $stopReason
    Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
} catch {
    $receipt = Get-ExecutionReceipt -Operation ([int]$receipt.operation) -IssueNumber ([int]$receipt.issueNumber) -RepoPath ([string]$receipt.repoRoot)
    if ($null -ne $receipt -and [string]$receipt.executionId -eq [string]$invocation.executionId) {
        $receipt.status = 'interrupted_postflight_pending'
        $receipt.interruptedReason = 'worker_host_failure'
        $receipt.remainingProblems = @($_.Exception.Message)
        Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
    }
    throw
} finally {
    if (Test-Path -LiteralPath $wrapper) { Remove-Item -LiteralPath $wrapper -Force }
}
