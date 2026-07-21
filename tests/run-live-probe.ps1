# 실제 Grok 1회를 격리 저장소에서 실행해 영수증·실행 중 로그·postflight를 확인한다.

[CmdletBinding()]
param([switch]$KeepFixture)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$routerRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $routerRoot 'scripts\run-operation.ps1')

$probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('operation-router-live-v244-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $probeRoot 'work'
$remote = Join-Path $probeRoot 'origin.git'
$success = $false
$summary = $null

function Invoke-ProbeGit {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    & git -C $Path @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git failed in live probe: $($Arguments -join ' ')" }
}

try {
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
    & git init -q --bare $remote
    if ($LASTEXITCODE -ne 0) { throw 'bare origin init failed' }
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git init -q $repo
    if ($LASTEXITCODE -ne 0) { throw 'work repo init failed' }
    Invoke-ProbeGit -Path $repo -Arguments @('config','user.email','probe@example.invalid')
    Invoke-ProbeGit -Path $repo -Arguments @('config','user.name','operation-router-live-probe')
    [System.IO.File]::WriteAllText((Join-Path $repo 'README.md'), "# isolated live probe`n", (New-Object System.Text.UTF8Encoding($false)))
    Invoke-ProbeGit -Path $repo -Arguments @('add','README.md')
    Invoke-ProbeGit -Path $repo -Arguments @('commit','-q','-m','test: initialize live probe')
    Invoke-ProbeGit -Path $repo -Arguments @('branch','-M','main')
    Invoke-ProbeGit -Path $repo -Arguments @('remote','add','origin',$remote)
    Invoke-ProbeGit -Path $repo -Arguments @('push','-q','-u','origin','main')

    $Script:RuntimeRoot = Join-Path $probeRoot 'router-runtime'
    $Script:ConfigDir = Join-Path $routerRoot 'config'
    $Script:ConfigPath = Join-Path $Script:ConfigDir 'config.json'
    $Script:StateDir = Join-Path $Script:RuntimeRoot 'state'
    $Script:UsageStatePath = Join-Path $Script:StateDir 'usage-state.json'
    $Script:PendingDir = Join-Path $Script:StateDir 'pending'
    $Script:DoctorReportPath = Join-Path $Script:StateDir 'doctor-report.json'
    $Script:LogRoot = Join-Path $Script:RuntimeRoot 'logs'
    $Script:RuntimeLogDir = Join-Path $Script:LogRoot 'runtime'
    $Script:TestLogRoot = Join-Path $Script:LogRoot 'tests'
    $Script:TestLogDir = $null
    $Script:RouterLogScope = 'runtime'
    $Script:TempDir = Join-Path $Script:RuntimeRoot 'temp'
    Initialize-RuntimeDirs
    Copy-Item -LiteralPath (Join-Path $routerRoot 'tests\fixtures\usage-state.initial.json') -Destination $Script:UsageStatePath -Force

    $issue = {
        param($number,$path)
        @'
Create a file named probe.txt containing exactly this line:
operation-router v2.4.4 durable live probe
Commit it with message "test: verify durable worker execution" and push main to origin immediately.
Do not invoke or delegate to another AI CLI. Keep verification limited to git status and the exact file content.
'@
    }
    $result = Invoke-RunOperation -OperationNumber 2 -IssueNumber 244 -Kind mechanical -RepoPath $repo `
        -IssueFetcher $issue -CiProbe ({ param($path) 'not-requested' })
    $receipt = Get-ExecutionReceipt -Operation 2 -IssueNumber 244 -RepoPath $repo
    if ($result.status -ne 'completed') { throw "live probe did not complete: $($result.status)" }
    if ($result.worker -ne 'grok') { throw "live probe routed to unexpected worker: $($result.worker)" }
    if ($null -eq $receipt -or $receipt.status -ne 'completed') { throw 'live probe execution receipt is not completed' }
    if (-not (Test-Path -LiteralPath $receipt.logPath) -or -not (Test-Path -LiteralPath $receipt.resultPath)) { throw 'live probe durable artifact is missing' }
    $logText = Get-Content -LiteralPath $receipt.logPath -Raw -Encoding UTF8
    if ($logText -notmatch 'cliStarted=true') { throw 'live probe log did not record CLI start' }
    if ([DateTime]::Parse([string]$receipt.startedAt) -gt [DateTime]::Parse([string]$receipt.processStartedAt)) { throw 'execution receipt was not created before worker start' }
    $summary = [pscustomobject]@{
        status=$result.status; worker=$result.worker; workerCalls=1; executionId=$receipt.executionId; generation=$receipt.generation
        receiptBeforeWorker=$true; runtimeLogPresent=$true; postflightCompleted=$true
        preExitLogObservation='covered_by_deterministic_worker_host_process_test'
        startHead=$result.startHead; finalHead=$result.finalHead; receiptPath=(Get-ExecutionReceiptPath -Operation 2 -IssueNumber 244 -RepoPath $repo)
        logPath=$receipt.logPath; fixtureRetained=[bool]$KeepFixture
    }
    $success = $true
} finally {
    if (-not $KeepFixture -and $success) {
        $full = [System.IO.Path]::GetFullPath($probeRoot)
        $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $full) -notmatch '^operation-router-live-v244-[a-f0-9]{32}$') { throw "refusing unsafe live probe cleanup: $full" }
        Remove-Item -LiteralPath $full -Recurse -Force
    } elseif (-not $success) { Write-Warning "live probe fixture retained for diagnosis: $probeRoot" }
}

$summary | ConvertTo-Json -Depth 8
