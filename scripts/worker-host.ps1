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
. (Join-Path $PSScriptRoot 'progress.ps1')
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

function Write-WorkerProgress {
    param([Parameter(Mandatory)]$Receipt,[Parameter(Mandatory)][string]$Event,[string]$Summary,[string]$Level='info')
    $written=Write-ExecutionProgressEvent -Receipt $Receipt -Event $Event -Summary $Summary -Level $Level
    if($null -ne $written){$script:LastWorkerProgressAt=[DateTime]::UtcNow}
}

function Update-WorkerObservableProgress {
    param([Parameter(Mandatory)]$Receipt,[Parameter(Mandatory)][string]$RepoPath,[switch]$Final)
    $stdout=Read-SharedTextFile -Path ([string]$Receipt.rawStdoutPath)
    $stderr=Read-SharedTextFile -Path ([string]$Receipt.rawStderrPath)
    $bytes=[Text.Encoding]::UTF8.GetByteCount($stdout)+[Text.Encoding]::UTF8.GetByteCount($stderr)
    if($bytes -ne $script:LastWorkerOutputBytes){
        Write-WorkerProgress -Receipt $Receipt -Event worker_output_activity -Summary "worker output changed: $bytes bytes"
        $script:LastWorkerOutputBytes=$bytes
    }
    if([string]$Receipt.worker -eq 'gpt'){
        $completeLines=@($stdout -split "`r?`n")
        if(-not $Final -and -not ($stdout.EndsWith("`n") -or $stdout.EndsWith("`r")) -and $completeLines.Count -gt 0){$completeLines=@($completeLines[0..($completeLines.Count-2)])}
        for($i=$script:ProcessedGptLines;$i -lt $completeLines.Count;$i++){
            foreach($event in @(ConvertFrom-GptProgressLine -Line ([string]$completeLines[$i]))){
                Write-WorkerProgress -Receipt $Receipt -Event ([string]$event.event) -Summary ([string]$event.summary) -Level ([string]$event.level)
            }
        }
        $script:ProcessedGptLines=$completeLines.Count
    }
    $current=Get-ExecutionObservableState -RepoPath $RepoPath
    if([string]$current.status -cne [string]$script:LastObservable.status){
        $state=if($current.worktreeClean){'clean'}else{'dirty'}
        Write-WorkerProgress -Receipt $Receipt -Event git_state_changed -Summary "worktree $state"
        foreach($file in @($current.files | Where-Object {$script:LastObservable.files -notcontains $_})){
            Write-WorkerProgress -Receipt $Receipt -Event file_changed -Summary ([string]$file)
        }
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$current.head) -and [string]$current.head -cne [string]$script:LastObservable.head){
        Write-WorkerProgress -Receipt $Receipt -Event commit_detected -Summary ([string]$current.head)
    }
    if($null -ne $current.ahead -and [int]$current.ahead -eq 0 -and $null -ne $script:LastObservable.ahead -and [int]$script:LastObservable.ahead -gt 0){
        Write-WorkerProgress -Receipt $Receipt -Event push_detected -Summary 'origin/main synchronized'
    }
    $script:LastObservable=$current
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
    $progressCfg=Get-ProgressConfig
    $script:LastWorkerOutputBytes=0
    $script:ProcessedGptLines=0
    $script:LastObservable=Get-ExecutionObservableState -RepoPath ([string]$receipt.repoRoot)
    $script:WorkerStartedAt=[DateTime]::UtcNow
    $script:LastWorkerProgressAt=$script:WorkerStartedAt
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/s','/c',('"' + $wrapper + '"')) `
        -WorkingDirectory ([string]$receipt.repoRoot) -RedirectStandardOutput ([string]$receipt.rawStdoutPath) `
        -RedirectStandardError ([string]$receipt.rawStderrPath) -PassThru -WindowStyle Hidden
    $receipt.status = 'worker_running'
    $receipt.processId = $proc.Id
    $receipt.processStartedAt = $proc.StartTime.ToUniversalTime().ToString('o')
    Write-WorkerProgress -Receipt $receipt -Event worker_process_started -Summary "$($receipt.model) / $($receipt.effort) process started"
    Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
    while (-not $proc.HasExited) {
        Update-ExecutionMaskedLog -Receipt $receipt -Header $header
        Update-WorkerObservableProgress -Receipt $receipt -RepoPath ([string]$receipt.repoRoot)
        if(([DateTime]::UtcNow-$script:LastWorkerProgressAt).TotalSeconds -ge [int]$progressCfg.heartbeatSeconds){
            $elapsed=[int]([DateTime]::UtcNow-$script:WorkerStartedAt).TotalSeconds
            $state=if($script:LastObservable.worktreeClean){'clean'}else{'dirty'}
            $headState=if([string]$script:LastObservable.head -ceq [string]$receipt.startHead){'HEAD unchanged'}else{'HEAD changed'}
            Write-WorkerProgress -Receipt $receipt -Event heartbeat -Summary "running ${elapsed}s, output $script:LastWorkerOutputBytes bytes, worktree $state, $headState"
        }
        $receipt = Get-ExecutionReceipt -Operation ([int]$receipt.operation) -IssueNumber ([int]$receipt.issueNumber) -RepoPath ([string]$receipt.repoRoot)
        if ([string]$receipt.executionId -ne [string]$invocation.executionId) { throw 'Execution generation changed while worker was running.' }
        Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
        Start-Sleep -Milliseconds 1000
        $proc.Refresh()
    }
    $proc.WaitForExit()
    Update-ExecutionMaskedLog -Receipt $receipt -Header $header
    Update-WorkerObservableProgress -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) -Final
    Write-WorkerProgress -Receipt $receipt -Event worker_exited -Summary "worker exited with code $($proc.ExitCode)"
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
    $sanitized = Complete-ExecutionArtifactSanitization -Receipt $receipt
    $receipt = $sanitized.receipt
    if (-not $sanitized.success) {
        $receipt.status = 'artifact_sanitization_failed'
        $receipt.remainingProblems = @('execution artifact sanitization failed: ' + [string]$sanitized.error)
        Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
        Write-ExecutionGenerationMarker -Receipt $receipt -Status $receipt.status
        try { Invoke-ExecutionRetention -Receipt $receipt | Out-Null } catch {
            $receipt.remainingProblems += ('execution retention failed: ' + (Protect-SecretText -Text ([string]$_.Exception.Message)))
            Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
        }
        throw 'Execution artifact sanitization failed.'
    }
    Write-WorkerProgress -Receipt $receipt -Event artifact_sanitized -Summary 'active prompt and raw output artifacts sanitized'
    $envelope = [pscustomobject]@{
        schemaVersion = 1; executionId = $receipt.executionId; generation = $receipt.generation
        worker = $receipt.worker; exitCode = $proc.ExitCode; success = [bool]$success
        quotaExhausted = [bool]$quota; errorClass = $errorClass; workerStopReason = $stopReason
        workerReportedVerification = $null; localVerificationComplete = $false
        stdoutPath = $receipt.stdoutPath; stderrPath = $receipt.stderrPath
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-AtomicJsonFile -Path ([string]$receipt.resultPath) -Object $envelope
    $receipt.status = 'worker_exited_postflight_pending'
    $receipt.workerExitCode = $proc.ExitCode
    $receipt.workerStopReason = $stopReason
    Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
} catch {
    $receipt = Get-ExecutionReceipt -Operation ([int]$receipt.operation) -IssueNumber ([int]$receipt.issueNumber) -RepoPath ([string]$receipt.repoRoot)
    if ($null -ne $receipt -and [string]$receipt.executionId -eq [string]$invocation.executionId -and [string]$receipt.status -ne 'artifact_sanitization_failed') {
        $receipt.status = 'interrupted_postflight_pending'
        $receipt.interruptedReason = 'worker_host_failure'
        $receipt.remainingProblems = @(Protect-SecretText -Text ([string]$_.Exception.Message))
        Save-ExecutionReceipt -Receipt $receipt -RepoPath ([string]$receipt.repoRoot) | Out-Null
    }
    throw
} finally {
    if (Test-Path -LiteralPath $wrapper) { Remove-Item -LiteralPath $wrapper -Force }
}
