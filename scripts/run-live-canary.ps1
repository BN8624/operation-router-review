# 명시적 유료 호출 승인 뒤 별도 저장소에서 live canary를 실행하고 비밀값 없는 결과만 기록한다.

[CmdletBinding()]
param(
    [switch]$ConfirmPaidProviderCall,
    [string]$RepoPath,
    [int]$Operation,
    [int]$IssueNumber,
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanaryProperty {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Get-CanaryGitValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    Push-Location $Path
    try {
        $value = (& git @Arguments 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { return $null }
        return $value
    } finally {
        Pop-Location
    }
}

$usage = [pscustomobject][ordered]@{
    status = 'LIVE_CANARY_NOT_EXECUTED'
    usage = 'run-live-canary.ps1 -ConfirmPaidProviderCall -RepoPath <path> -Operation <1|2|3> -IssueNumber <number> [-ResultPath <path>]'
    reason = 'Explicit paid-provider confirmation and all target arguments are required.'
}
if (-not $ConfirmPaidProviderCall -or [string]::IsNullOrWhiteSpace($RepoPath) -or
    $Operation -notin @(1,2,3) -or $IssueNumber -lt 1) {
    $usage | ConvertTo-Json -Depth 4
    exit 2
}

$routerRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

$resolvedRepo = [System.IO.Path]::GetFullPath($RepoPath).TrimEnd('\','/')
if (-not (Test-GitRepository -Path $resolvedRepo)) {
    throw "Canary target is not a Git repository: $resolvedRepo"
}
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'operation-router-live-canary-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '.json'
    )
}
$ResultPath = [System.IO.Path]::GetFullPath($ResultPath)

$summary = Read-JsonFile -Path (Join-Path $routerRoot 'evidence\verification-summary.json')
$routerHead = Get-CanaryGitValue -Path $routerRoot -Arguments @('rev-parse','HEAD')
$startHead = Get-CanaryGitValue -Path $resolvedRepo -Arguments @('rev-parse','HEAD')
$repoIdentity = Get-RepoIdentity -RepoPath $resolvedRepo
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$parsed = $null
$runnerExitCode = $null
$rawResult = ''

Push-Location $resolvedRepo
try {
    $rawResult = (& powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot 'run-operation.ps1') `
        -Command run -Operation $Operation -IssueNumber $IssueNumber 2>&1 | Out-String).Trim()
    $runnerExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
try {
    if (-not [string]::IsNullOrWhiteSpace($rawResult)) {
        $parsed = $rawResult | ConvertFrom-Json -ErrorAction Stop
    }
} catch {
    $parsed = $null
}

$finalHead = Get-CanaryGitValue -Path $resolvedRepo -Arguments @('rev-parse','HEAD')
$branch = Get-CanaryGitValue -Path $resolvedRepo -Arguments @('branch','--show-current')
$worker = Get-CanaryProperty -Object $parsed -Name 'worker'
$attempts = Get-CanaryProperty -Object $parsed -Name 'attempts'
$paidCalls = 0
if ($worker -in @('grok','gpt')) {
    $paidCalls = if ($null -ne $attempts) { [Math]::Max(1,[int]$attempts) } else { 1 }
}
if ([bool](Get-CanaryProperty -Object $parsed -Name 'fallbackAttempted' -Default $false)) {
    $paidCalls++
}
$finalStatus = if ($null -ne $parsed) {
    [string](Get-CanaryProperty -Object $parsed -Name 'status' -Default 'router_status_missing')
} elseif ($runnerExitCode -ne 0) {
    'router_process_failed'
} else {
    'router_result_invalid'
}
$resultEnvelopePresent = ($null -ne $parsed)
$workerReportValid = $false
if ($resultEnvelopePresent -and $finalStatus -notin @('worker_protocol_error','router_status_missing')) {
    $workerReportValid = [bool](Get-CanaryProperty -Object $parsed -Name 'localVerificationComplete' -Default $false)
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    routerVersion = [string]$summary.version
    routerHead = $routerHead
    targetRepositoryIdentity = [pscustomobject][ordered]@{
        ownerRepo = $repoIdentity.ownerRepo
        repoRootHash = $repoIdentity.repoRootHash
    }
    operation = $Operation
    issueNumber = $IssueNumber
    worker = $worker
    model = Get-CanaryProperty -Object $parsed -Name 'model'
    effort = Get-CanaryProperty -Object $parsed -Name 'effort'
    startHead = $startHead
    finalHead = $finalHead
    executionId = Get-CanaryProperty -Object $parsed -Name 'executionId'
    generation = Get-CanaryProperty -Object $parsed -Name 'generation'
    resultEnvelopePresent = $resultEnvelopePresent
    workerReportValid = $workerReportValid
    localVerification = Get-CanaryProperty -Object $parsed -Name 'localVerificationComplete'
    branch = $branch
    draftPrNumber = Get-CanaryProperty -Object $parsed -Name 'prNumber'
    draftPrUrl = Get-CanaryProperty -Object $parsed -Name 'prUrl'
    prHeadSha = $finalHead
    ciStatus = Get-CanaryProperty -Object $parsed -Name 'ciStatus' -Default 'not-checked'
    finalStatus = $finalStatus
    mergeReady = [bool](Get-CanaryProperty -Object $parsed -Name 'mergeReady' -Default $false)
    draftRetained = Get-CanaryProperty -Object $parsed -Name 'prDraft'
    automaticMergeCalled = $false
    paidProviderCalls = $paidCalls
    runnerExitCode = $runnerExitCode
    startedAtUtc = $startedAt
    finishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
}
Write-AtomicJsonFile -Path $ResultPath -Object $result -Depth 12
$result | ConvertTo-Json -Depth 12
if ($runnerExitCode -ne 0 -or -not $resultEnvelopePresent) { exit 1 }
exit 0
