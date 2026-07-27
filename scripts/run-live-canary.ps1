# 실제 receipt와 GitHub 상태를 따라 단계형 live canary를 실행하고 검증된 provenance만 기록한다.

[CmdletBinding()]
param(
    [switch]$ConfirmPaidProviderCall,
    [string]$RepoPath,
    [ValidateSet(1,2,3)][int]$Operation,
    [int]$IssueNumber,
    [ValidateSet('Start','Continue','Finalize')][string]$Phase = 'Start',
    [string]$FinalReviewEvidencePath,
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Script:CanaryCheckpointSchemaVersion = 3
$Script:CanaryResultSchemaVersion = 4

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

function New-CanaryUsageResult {
    param([string]$Reason = 'Explicit paid-provider confirmation and all target arguments are required.')
    return [pscustomobject][ordered]@{
        schemaVersion = $Script:CanaryResultSchemaVersion
        checkpointSchemaVersion = $Script:CanaryCheckpointSchemaVersion
        finalStatus = 'LIVE_CANARY_NOT_EXECUTED'
        usage = 'run-live-canary.ps1 -ConfirmPaidProviderCall -RepoPath <path> -Operation <1|2|3> -IssueNumber <number> [-Phase Start|Continue|Finalize] [-FinalReviewEvidencePath <path>] [-ResultPath <path>]'
        paidProviderCalls = 0
        paidProviderCallsVerified = $true
        paidProviderCallsReason = 'canary-not-executed'
        providerCallsThisInvocation = 0
        providerCallsThisInvocationVerified = $true
        notExecutedReason = $Reason
    }
}

function New-CanaryCheckpointFailure {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Reason,
        [AllowNull()]$Checkpoint,
        [AllowNull()]$CurrentExecution,
        [AllowNull()][string]$CheckpointPath
    )
    return [pscustomobject][ordered]@{
        schemaVersion = $Script:CanaryResultSchemaVersion
        checkpointSchemaVersion = $Script:CanaryCheckpointSchemaVersion
        finalStatus = $Status
        failureReason = $Reason
        checkpointPath = $CheckpointPath
        executionId = Get-CanaryProperty -Object $Checkpoint -Name 'executionId'
        generation = Get-CanaryProperty -Object $Checkpoint -Name 'generation'
        currentExecutionId = Get-CanaryProperty -Object $CurrentExecution -Name 'executionId'
        currentGeneration = Get-CanaryProperty -Object $CurrentExecution -Name 'generation'
        routerCommands = @()
        paidProviderCalls = $null
        paidProviderCallsVerified = $false
        paidProviderCallsReason = 'checkpoint-failure-before-provider-call-reconciliation'
        providerCallsThisInvocation = 0
        providerCallsThisInvocationVerified = $true
    }
}

function Test-CanaryResultEnvelope {
    param([AllowNull()]$ExecutionReceipt)
    $result = [pscustomobject][ordered]@{
        present = $false
        parsed = $false
        contextValid = $false
        workerValid = $false
        executionSuccessful = $false
        valid = $false
        path = $null
        envelope = $null
        reason = 'execution_receipt_missing'
    }
    if ($null -eq $ExecutionReceipt) { return $result }
    $executionProperties = @($ExecutionReceipt.PSObject.Properties.Name)
    if ($executionProperties -notcontains 'resultPath' -or
        [string]::IsNullOrWhiteSpace([string]$ExecutionReceipt.resultPath)) {
        $result.reason = 'result_path_missing'
        return $result
    }
    $result.path = [string]$ExecutionReceipt.resultPath
    if (-not (Test-Path -LiteralPath $result.path -PathType Leaf)) {
        $result.reason = 'result_file_missing'
        return $result
    }
    $result.present = $true
    try {
        $envelope = Get-Content -LiteralPath $result.path -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
        $result.parsed = $true
        $result.envelope = $envelope
    } catch {
        $result.reason = 'result_json_invalid'
        return $result
    }
    $properties = @($result.envelope.PSObject.Properties.Name)
    foreach ($required in @('schemaVersion','executionId','generation','worker','exitCode','success')) {
        if ($properties -notcontains $required) {
            $result.reason = "result_field_missing:$required"
            return $result
        }
    }
    if ($result.envelope.schemaVersion -isnot [int] -or [int]$result.envelope.schemaVersion -notin @(1)) {
        $result.reason = 'result_schema_unsupported'
        return $result
    }
    if ([string]$result.envelope.executionId -cne [string]$ExecutionReceipt.executionId -or
        [int]$result.envelope.generation -ne [int]$ExecutionReceipt.generation) {
        $result.reason = 'result_execution_mismatch'
        return $result
    }
    $result.contextValid = $true
    if ($result.envelope.worker -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$result.envelope.worker)) {
        $result.reason = 'result_field_type_invalid'
        return $result
    }
    if ([string]$result.envelope.worker -cne [string](Get-CanaryProperty -Object $ExecutionReceipt -Name 'worker')) {
        $result.reason = 'result_worker_mismatch'
        return $result
    }
    $result.workerValid = $true
    if ($result.envelope.exitCode -isnot [int] -or $result.envelope.success -isnot [bool]) {
        $result.reason = 'result_field_type_invalid'
        return $result
    }
    if (-not [bool]$result.envelope.success -and [int]$result.envelope.exitCode -eq 0) {
        $result.reason = 'result_success_exit_mismatch'
        return $result
    }
    if (-not [bool]$result.envelope.success) {
        $result.reason = 'result_execution_unsuccessful'
        return $result
    }
    if ([int]$result.envelope.exitCode -ne 0) {
        $result.reason = 'result_exit_code_nonzero'
        return $result
    }
    $result.executionSuccessful = $true
    $result.valid = $true
    $result.reason = $null
    return $result
}

function Get-CanaryWorkerReportEvidence {
    param(
        [AllowNull()]$ExecutionReceipt,
        [AllowNull()]$AuthoritativeReceipt,
        [Parameter(Mandatory)]$EnvelopeEvidence
    )
    $source = if ($null -ne $AuthoritativeReceipt) { $AuthoritativeReceipt } else { $ExecutionReceipt }
    $localComplete = $false
    $provenance = $null
    $reported = $null
    $remaining = @()
    if ($null -ne $source) {
        $localComplete = [bool](Get-CanaryProperty -Object $source -Name 'localVerificationComplete' -Default $false)
        $provenance = [string](Get-CanaryProperty -Object $source -Name 'verificationProvenance')
        $reported = Get-CanaryProperty -Object $source -Name 'workerReportedVerification'
        $remaining = @(@(
            @(Get-CanaryProperty -Object $source -Name 'workerRemainingProblems' -Default @()) +
            @(Get-CanaryProperty -Object $source -Name 'remainingProblems' -Default @())
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    $allowedProvenance = @(
        'valid_worker_result_envelope',
        'valid_worker_result_envelope_recovered_postflight',
        'valid_repair_worker_result',
        'valid_claude_completion_report'
    )
    $valid = (
        [bool]$EnvelopeEvidence.valid -and
        $localComplete -and
        $provenance -in $allowedProvenance -and
        -not [string]::IsNullOrWhiteSpace([string]$reported) -and
        $remaining.Count -eq 0
    )
    return [pscustomobject][ordered]@{
        valid = [bool]$valid
        localVerificationComplete = [bool]$localComplete
        verificationProvenance = $provenance
        workerReportedVerificationPresent = -not [string]::IsNullOrWhiteSpace([string]$reported)
        remainingProblems = @($remaining)
    }
}

function Get-CanaryPhaseEvidence {
    param(
        [Parameter(Mandatory)][ValidateSet('implementation','repair')][string]$Phase,
        [AllowNull()]$ExecutionReceipt,
        [AllowNull()]$WorkerReceipt,
        [Parameter(Mandatory)][int]$Operation,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [AllowNull()][string]$ExpectedHead
    )
    $envelope = Test-CanaryResultEnvelope -ExecutionReceipt $ExecutionReceipt
    $worker = Get-CanaryWorkerReportEvidence -ExecutionReceipt $ExecutionReceipt `
        -AuthoritativeReceipt $WorkerReceipt -EnvelopeEvidence $envelope
    $contextValid = $false
    $reason = $null
    if ($null -eq $ExecutionReceipt -or $null -eq $WorkerReceipt) {
        $reason = "$Phase`_receipt_missing"
    } else {
        $required = @(
            'executionId','generation','operation','issueNumber','ownerRepo','repoRootHash',
            'worker','finalHead'
        )
        foreach ($field in $required) {
            if ($ExecutionReceipt.PSObject.Properties.Name -notcontains $field) {
                $reason = "$Phase`_field_missing:$field"
                break
            }
        }
        if ($null -eq $reason -and $Phase -eq 'repair' -and
            ([string]$ExecutionReceipt.executionId -cne [string](Get-CanaryProperty -Object $WorkerReceipt -Name 'executionId') -or
             [int]$ExecutionReceipt.generation -ne [int](Get-CanaryProperty -Object $WorkerReceipt -Name 'generation' -Default 0))) {
            $reason = 'repair_receipt_execution_mismatch'
        }
        if ($null -eq $reason -and
            ([int]$ExecutionReceipt.operation -ne $Operation -or
             [int]$ExecutionReceipt.issueNumber -ne $IssueNumber -or
             [string]$ExecutionReceipt.ownerRepo -cne [string]$RepositoryIdentity.ownerRepo -or
             [string]$ExecutionReceipt.repoRootHash -cne [string]$RepositoryIdentity.repoRootHash)) {
            $reason = "$Phase`_repository_or_request_mismatch"
        }
        if ($null -eq $reason -and
            ([string]$ExecutionReceipt.worker -cne [string](Get-CanaryProperty -Object $WorkerReceipt -Name 'worker') -or
             [string]$ExecutionReceipt.finalHead -cne [string](Get-CanaryProperty -Object $WorkerReceipt -Name 'finalHead') -or
             (-not [string]::IsNullOrWhiteSpace($ExpectedHead) -and
              [string]$ExecutionReceipt.finalHead -cne $ExpectedHead))) {
            $reason = "$Phase`_worker_or_head_mismatch"
        }
        if ($null -eq $reason -and -not [bool]$envelope.valid) {
            $reason = [string]$envelope.reason
        }
        if ($null -eq $reason -and $Phase -eq 'repair') {
            $repairEnvelope = $envelope.envelope
            foreach ($field in @('operation','issueNumber','ownerRepo','repoRootHash','purpose','finalHead')) {
                if ($null -eq $repairEnvelope -or $repairEnvelope.PSObject.Properties.Name -notcontains $field) {
                    $reason = "repair_result_field_missing:$field"
                    break
                }
            }
            if ($null -eq $reason -and
                ([int]$repairEnvelope.operation -ne $Operation -or
                 [int]$repairEnvelope.issueNumber -ne $IssueNumber -or
                 [string]$repairEnvelope.ownerRepo -cne [string]$RepositoryIdentity.ownerRepo -or
                 [string]$repairEnvelope.repoRootHash -cne [string]$RepositoryIdentity.repoRootHash -or
                 [string]$repairEnvelope.purpose -cne 'repair' -or
                 [string]$repairEnvelope.worker -cne [string]$ExecutionReceipt.worker -or
                 [string]$repairEnvelope.finalHead -cne [string]$ExecutionReceipt.finalHead)) {
                $reason = 'repair_result_context_mismatch'
            }
        }
        if ($null -eq $reason) { $contextValid = $true }
    }
    $valid = ([bool]$contextValid -and [bool]$envelope.valid -and [bool]$worker.valid)
    if (-not $valid -and $null -eq $reason) {
        $reason = if (-not $envelope.valid) { [string]$envelope.reason } else { "$Phase`_worker_report_invalid" }
    }
    return [pscustomobject][ordered]@{
        performed = ($Phase -eq 'implementation' -or $null -ne $WorkerReceipt)
        valid = [bool]$valid
        executionId = Get-CanaryProperty -Object $ExecutionReceipt -Name 'executionId'
        generation = Get-CanaryProperty -Object $ExecutionReceipt -Name 'generation'
        resultEnvelope = $envelope.path
        resultEnvelopePresent = [bool]$envelope.present
        resultEnvelopeParsed = [bool]$envelope.parsed
        resultEnvelopeContextValid = [bool]$envelope.contextValid
        resultEnvelopeWorkerValid = [bool]$envelope.workerValid
        executionSuccessful = [bool]$envelope.executionSuccessful
        resultEnvelopeReason = $envelope.reason
        worker = Get-CanaryProperty -Object $ExecutionReceipt -Name 'worker'
        workerReportValid = [bool]$worker.valid
        localVerificationComplete = [bool]$worker.localVerificationComplete
        verificationProvenance = $worker.verificationProvenance
        remainingProblems = @($worker.remainingProblems)
        finalHead = Get-CanaryProperty -Object $ExecutionReceipt -Name 'finalHead'
        contextVerified = [bool]$contextValid
        reason = $reason
    }
}

function Test-CanaryFinalReviewEvidence {
    param(
        [string]$Path,
        [Parameter(Mandatory)][int]$Operation,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$ExpectedHead,
        [Parameter(Mandatory)][string]$ExpectedWorkBranch,
        [Parameter(Mandatory)][string]$ExpectedReviewer
    )
    $out = [pscustomobject][ordered]@{
        present = $false
        valid = $false
        verdict = $null
        reviewer = $null
        path = $null
        reason = 'final_review_evidence_missing'
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $out }
    $out.path = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $out.path -PathType Leaf)) {
        $out.reason = 'final_review_evidence_file_missing'
        return $out
    }
    $out.present = $true
    try {
        $evidence = Get-Content -LiteralPath $out.path -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        $out.reason = 'final_review_evidence_json_invalid'
        return $out
    }
    $properties = @($evidence.PSObject.Properties.Name)
    foreach ($required in @(
        'schemaVersion','operation','issueNumber','head','workBranch',
        'verdict','reviewer','reviewSummary','remainingProblems'
    )) {
        if ($properties -notcontains $required) {
            $out.reason = "final_review_evidence_field_missing:$required"
            return $out
        }
    }
    if ($evidence.schemaVersion -isnot [int] -or [int]$evidence.schemaVersion -ne 1 -or
        $evidence.operation -isnot [int] -or [int]$evidence.operation -ne $Operation -or
        $evidence.issueNumber -isnot [int] -or [int]$evidence.issueNumber -ne $IssueNumber) {
        $out.reason = 'final_review_evidence_context_mismatch'
        return $out
    }
    if ([string]$evidence.head -cne $ExpectedHead) {
        $out.reason = 'final_review_evidence_head_mismatch'
        return $out
    }
    if ([string]$evidence.workBranch -cne $ExpectedWorkBranch) {
        $out.reason = 'final_review_evidence_branch_mismatch'
        return $out
    }
    if ([string]$evidence.reviewer -cne $ExpectedReviewer) {
        $out.reason = 'final_review_evidence_reviewer_mismatch'
        return $out
    }
    $verdict = [string]$evidence.verdict
    if ($verdict -notin @('PASS','REPAIR_REQUIRED')) {
        $out.reason = 'final_review_evidence_verdict_invalid'
        return $out
    }
    $summary = ([string]$evidence.reviewSummary).Trim()
    if ($summary.Length -lt 40 -or $summary -match '^(done|pass|completed|review complete)[.! ]*$') {
        $out.reason = 'final_review_evidence_summary_insufficient'
        return $out
    }
    $remaining = @($evidence.remainingProblems | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($verdict -eq 'PASS' -and $remaining.Count -gt 0) {
        $out.reason = 'final_review_evidence_remaining_problems'
        return $out
    }
    $out.valid = $true
    $out.verdict = $verdict
    $out.reviewer = [string]$evidence.reviewer
    $out.reason = $null
    return $out
}

function Get-CanaryPrEvidence {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [AllowNull()]$Receipt,
        [scriptblock]$PrProbe,
        [scriptblock]$CheckLister,
        [scriptblock]$RemoteHeadProbe,
        [scriptblock]$MergeMutationProbe
    )
    $out = [pscustomobject][ordered]@{
        queried = $false
        status = 'not-available'
        baseBranch = $null
        workBranch = $null
        remoteWorkBranchHead = $null
        draftPrNumber = $null
        draftPrUrl = $null
        prHeadSha = $null
        prState = $null
        draftRetained = $null
        merged = $null
        prRemainsDraft = $null
        prMerged = $null
        prContextVerified = $false
        ciStatus = 'not-checked'
        automaticMergeCalled = $null
        automaticMergeVerification = 'unknown'
    }
    if ($null -eq $Receipt) { return $out }
    $workflow = Get-ReceiptWorkflowContext -Receipt $Receipt
    if ($null -eq $workflow -or [string]$workflow.mode -ne 'pull-request') {
        $out.status = 'workflow_not_pull_request'
        return $out
    }
    $out.baseBranch = [string]$workflow.baseBranch
    $out.workBranch = [string]$workflow.workBranch
    if ([string]::IsNullOrWhiteSpace($out.workBranch)) {
        $out.status = 'work_branch_missing'
        return $out
    }
    $ownerRepo = Get-GitOriginOwnerRepo -Path $RepoPath
    $lookup = Get-PullRequestForBranch -RepoPath $RepoPath -OwnerRepo $ownerRepo `
        -WorkBranch $out.workBranch -PrProbe $PrProbe
    $out.queried = $true
    if (-not $lookup.ok -or @($lookup.items).Count -ne 1) {
        $out.status = if ($lookup.ok) { 'pr_count_invalid' } else { [string]$lookup.status }
        return $out
    }
    $pr = $lookup.items[0]
    $out.draftPrNumber = [int]$pr.number
    $out.draftPrUrl = [string]$pr.url
    $out.prHeadSha = [string]$pr.headSha
    $out.prState = [string]$pr.state
    $out.draftRetained = [bool]$pr.draft
    $out.merged = [bool]$pr.merged
    $out.prRemainsDraft = [bool]$pr.draft
    $out.prMerged = [bool]$pr.merged
    $out.remoteWorkBranchHead = Get-GitRemoteBranchHead -RepoPath $RepoPath `
        -Branch $out.workBranch -RemoteHeadProbe $RemoteHeadProbe
    $receiptHead = [string](Get-CanaryProperty -Object $Receipt -Name 'finalHead')
    $out.prContextVerified = (
        -not [string]::IsNullOrWhiteSpace($receiptHead) -and
        $receiptHead -ceq [string]$out.remoteWorkBranchHead -and
        $receiptHead -ceq [string]$out.prHeadSha -and
        [string]$pr.baseBranch -ceq $out.baseBranch -and
        [string]$pr.headBranch -ceq $out.workBranch -and
        [string]$pr.headRepository -ieq $ownerRepo -and
        [string]$out.prState -ceq 'OPEN'
    )
    $headWorkflow = Get-GitWorkflowSnapshot -RepoPath $RepoPath -Ref $receiptHead
    $baseWorkflow = Get-CanaryProperty -Object $workflow -Name 'baseWorkflow'
    $out.ciStatus = Get-PullRequestCiStatus -RepoPath $RepoPath `
        -PrNumber ([int]$out.draftPrNumber) -HeadSha ([string]$out.prHeadSha) `
        -CheckLister $CheckLister -BaseWorkflow $baseWorkflow -HeadWorkflow $headWorkflow `
        -RequireCiWhenWorkflowPresent (Get-WorkflowRequireCi -Workflow $workflow)
    $out.automaticMergeVerification = 'not-directly-observable'
    if ($null -ne $MergeMutationProbe) {
        try {
            $mergeProbe = & $MergeMutationProbe $RepoPath ([int]$out.draftPrNumber) ([string]$out.prHeadSha)
            $mergeCalls = [int](Get-CanaryProperty -Object $mergeProbe -Name 'mergeCalls' -Default -1)
            if ($mergeCalls -ge 0) {
                $out.automaticMergeCalled = ($mergeCalls -gt 0)
                $out.automaticMergeVerification = 'router-mutation-probe'
            }
        } catch {
            $out.automaticMergeCalled = $null
            $out.automaticMergeVerification = 'mutation-probe-failed'
        }
    }
    $out.status = if ($out.prContextVerified) { 'verified' } else { 'pr_context_mismatch' }
    return $out
}

function Get-CanaryPaidCallEvidence {
    param(
        [AllowNull()]$ExecutionReceipt,
        [AllowNull()]$RepairReceipt,
        [Parameter(Mandatory)][int]$Operation,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RouterCommands
    )
    $byPhase = [ordered]@{ implementation=$null; review=0; repair=0; finalReview=0 }
    $failure = {
        param([string]$Reason)
        return [pscustomobject]@{
            count=$null;verified=$false;source=$Reason;reason=$Reason
            byPhase=[pscustomobject]$byPhase
        }
    }
    if ($null -eq $ExecutionReceipt -or
        $ExecutionReceipt.PSObject.Properties.Name -notcontains 'artifactPath' -or
        [string]::IsNullOrWhiteSpace([string]$ExecutionReceipt.artifactPath) -or
        -not (Test-Path -LiteralPath ([string]$ExecutionReceipt.artifactPath) -PathType Container)) {
        return (& $failure 'invocation-receipt-unavailable')
    }
    $invocationFiles = @(Get-ChildItem -LiteralPath ([string]$ExecutionReceipt.artifactPath) `
        -File -Filter 'invocation.json' -ErrorAction SilentlyContinue)
    if ($invocationFiles.Count -ne 1) {
        return (& $failure 'invocation-receipt-count-invalid')
    }
    try {
        $invocation = Get-Content -LiteralPath $invocationFiles[0].FullName -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        return (& $failure 'invocation-receipt-invalid')
    }
    $required = @(
        'schemaVersion','executionId','generation','operation','issueNumber',
        'provider','invocationKind','isPaidProviderInvocation','createdAt'
    )
    foreach ($name in $required) {
        if ($invocation.PSObject.Properties.Name -notcontains $name) {
            return (& $failure "invocation-field-missing:$name")
        }
    }
    $timestamp = [datetime]::MinValue
    $timestampValid = [datetime]::TryParse(
        [string]$invocation.createdAt,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$timestamp
    )
    if ($invocation.schemaVersion -isnot [int] -or [int]$invocation.schemaVersion -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$invocation.executionId) -or
        $invocation.generation -isnot [int] -or
        $invocation.operation -isnot [int] -or
        $invocation.issueNumber -isnot [int] -or
        [string]::IsNullOrWhiteSpace([string]$invocation.provider) -or
        [string]::IsNullOrWhiteSpace([string]$invocation.invocationKind) -or
        $invocation.isPaidProviderInvocation -isnot [bool] -or
        -not $timestampValid) {
        return (& $failure 'invocation-field-type-invalid')
    }
    if ([string]$invocation.executionId -cne [string]$ExecutionReceipt.executionId) {
        return (& $failure 'invocation-execution-mismatch')
    }
    if ([int]$invocation.generation -ne [int]$ExecutionReceipt.generation) {
        return (& $failure 'invocation-generation-mismatch')
    }
    if ([int]$invocation.operation -ne $Operation) {
        return (& $failure 'invocation-operation-mismatch')
    }
    if ([int]$invocation.issueNumber -ne $IssueNumber) {
        return (& $failure 'invocation-issue-mismatch')
    }
    if ([string]$invocation.provider -cne [string]$ExecutionReceipt.worker -or
        [string]$invocation.invocationKind -cne 'implementation') {
        return (& $failure 'invocation-provider-or-kind-mismatch')
    }
    $byPhase.implementation = if ([bool]$invocation.isPaidProviderInvocation) { 1 } else { 0 }
    $reviewUnreceipted = (@($RouterCommands | Where-Object { $_ -eq 'review' }).Count -gt 0)
    $repairUnreceipted = (@($RouterCommands | Where-Object { $_ -eq 'repair' }).Count -gt 0 -or $null -ne $RepairReceipt)
    if ($reviewUnreceipted) {
        $byPhase.review = $null
    }
    if ($repairUnreceipted) {
        $byPhase.repair = $null
    }
    if ($reviewUnreceipted -or $repairUnreceipted) {
        $reason = if ($reviewUnreceipted -and $repairUnreceipted) {
            'review-or-repair-invocation-not-receipted'
        } elseif ($reviewUnreceipted) {
            'review-invocation-not-receipted'
        } else {
            'repair-invocation-not-receipted'
        }
        return (& $failure $reason)
    }
    $count = [int]$byPhase.implementation
    return [pscustomobject]@{
        count=$count;verified=$true;source='execution-bound-invocation-receipt';reason=$null
        byPhase=[pscustomobject]$byPhase
    }
}

function Invoke-LiveCanary {
    param(
        [switch]$ConfirmPaidProviderCall,
        [string]$RepoPath,
        [int]$Operation,
        [int]$IssueNumber,
        [ValidateSet('Start','Continue','Finalize')][string]$Phase = 'Start',
        [string]$FinalReviewEvidencePath,
        [string]$ResultPath,
        [scriptblock]$RouterInvoker,
        [scriptblock]$ExecutionReader,
        [scriptblock]$RunReceiptReader,
        [scriptblock]$ReviewReceiptReader,
        [scriptblock]$RepairReceiptReader,
        [scriptblock]$PrProbe,
        [scriptblock]$CheckLister,
        [scriptblock]$RemoteHeadProbe,
        [scriptblock]$MergeMutationProbe
    )
    if (-not $ConfirmPaidProviderCall -or [string]::IsNullOrWhiteSpace($RepoPath) -or
        $Operation -notin @(1,2,3) -or $IssueNumber -lt 1) {
        return (New-CanaryUsageResult)
    }
    $resolvedRepo = [System.IO.Path]::GetFullPath($RepoPath).TrimEnd('\','/')
    if (-not (Test-GitRepository -Path $resolvedRepo)) {
        return (New-CanaryUsageResult -Reason "Canary target is not a Git repository: $resolvedRepo")
    }
    $resultPathWasExplicit = -not [string]::IsNullOrWhiteSpace($ResultPath)
    if (-not $resultPathWasExplicit) {
        if ($Phase -ne 'Start') {
            return (New-CanaryUsageResult -Reason 'Continue and Finalize require an existing -ResultPath checkpoint.')
        }
        $ResultPath = Join-Path ([System.IO.Path]::GetTempPath()) (
            'operation-router-live-canary-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '.json'
        )
    }
    $ResultPath = [System.IO.Path]::GetFullPath($ResultPath)
    if ($Phase -ne 'Start' -and -not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_REQUIRED' `
            -Reason 'checkpoint_file_missing' -Checkpoint $null -CurrentExecution $null `
            -CheckpointPath $ResultPath)
    }

    $routerRoot = Split-Path -Parent $PSScriptRoot
    $summary = Read-JsonFile -Path (Join-Path $routerRoot 'evidence\verification-summary.json')
    $routerHead = Get-CanaryGitValue -Path $routerRoot -Arguments @('rev-parse','HEAD')
    $repoIdentity = Get-RepoIdentity -RepoPath $resolvedRepo
    $currentHead = Get-CanaryGitValue -Path $resolvedRepo -Arguments @('rev-parse','HEAD')
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    $checkpoint = $null
    $checkpointExists = Test-Path -LiteralPath $ResultPath -PathType Leaf
    $checkpointJsonInvalid = $false
    if ($checkpointExists) {
        try {
            $checkpoint = Read-JsonFile -Path $ResultPath
        } catch {
            $checkpointJsonInvalid = $true
        }
    }
    if ($checkpointJsonInvalid) {
        return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_INVALID' `
            -Reason 'checkpoint_json_invalid' -Checkpoint $null -CurrentExecution $null `
            -CheckpointPath $ResultPath)
    }
    if ($checkpointExists -and $null -eq $checkpoint) {
        return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_INVALID' `
            -Reason 'checkpoint_json_null' -Checkpoint $null -CurrentExecution $null `
            -CheckpointPath $ResultPath)
    }
    if ($checkpointExists -and
        $checkpoint.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
        return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_INVALID' `
            -Reason 'checkpoint_json_root_not_object' -Checkpoint $null -CurrentExecution $null `
            -CheckpointPath $ResultPath)
    }
    if ($Phase -ne 'Start' -or $null -ne $checkpoint) {
        if ($null -eq $checkpoint) {
            return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_REQUIRED' `
                -Reason 'checkpoint_file_missing' -Checkpoint $null -CurrentExecution $null `
                -CheckpointPath $ResultPath)
        }
        $checkpointIdentity = Get-CanaryProperty -Object $checkpoint -Name 'targetRepositoryIdentity'
        $checkpointSchema = if ((Get-CanaryProperty -Object $checkpoint -Name 'checkpointSchemaVersion') -is [int]) {
            [int]$checkpoint.checkpointSchemaVersion
        } else {
            Get-CanaryProperty -Object $checkpoint -Name 'schemaVersion'
        }
        if ($checkpointSchema -isnot [int] -or
            [int]$checkpointSchema -ne $Script:CanaryCheckpointSchemaVersion -or
            [int](Get-CanaryProperty -Object $checkpoint -Name 'operation' -Default 0) -ne $Operation -or
            [int](Get-CanaryProperty -Object $checkpoint -Name 'issueNumber' -Default 0) -ne $IssueNumber -or
            [string](Get-CanaryProperty -Object $checkpointIdentity -Name 'ownerRepo') -cne [string]$repoIdentity.ownerRepo -or
            [string](Get-CanaryProperty -Object $checkpointIdentity -Name 'repoRootHash') -cne [string]$repoIdentity.repoRootHash) {
            return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_CONTEXT_MISMATCH' `
                -Reason 'checkpoint_schema_or_repository_context_mismatch' -Checkpoint $checkpoint `
                -CurrentExecution $null -CheckpointPath $ResultPath)
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-CanaryProperty -Object $checkpoint -Name 'executionId')) -or
            (Get-CanaryProperty -Object $checkpoint -Name 'generation') -isnot [int]) {
            return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_EXECUTION_MISMATCH' `
                -Reason 'checkpoint_execution_identity_missing' -Checkpoint $checkpoint `
                -CurrentExecution $null -CheckpointPath $ResultPath)
        }
        $startedAt = [string](Get-CanaryProperty -Object $checkpoint -Name 'startedAtUtc' -Default $startedAt)
    }
    $startHead = if ($null -ne $checkpoint) {
        [string](Get-CanaryProperty -Object $checkpoint -Name 'startHead' -Default $currentHead)
    } else { $currentHead }

    if ($null -eq $ExecutionReader) {
        $ExecutionReader = {
            param($repo,$op,$issue)
            try { return (Get-ExecutionReceiptStable -Operation $op -IssueNumber $issue -RepoPath $repo) }
            catch { return $null }
        }
    }
    if ($null -eq $RunReceiptReader) {
        $RunReceiptReader = { param($repo,$op,$issue) Get-RunReceipt -Operation $op -IssueNumber $issue -RepoPath $repo }
    }
    if ($null -eq $ReviewReceiptReader) {
        $ReviewReceiptReader = { param($repo,$op,$issue) Get-ReviewReceipt -Operation $op -IssueNumber $issue -RepoPath $repo }
    }
    if ($null -eq $RepairReceiptReader) {
        $RepairReceiptReader = { param($repo,$op,$issue) Get-RepairReceipt -Operation $op -IssueNumber $issue -RepoPath $repo }
    }
    if ($null -eq $RouterInvoker) {
        $RouterInvoker = {
            param($command,$context)
            switch ($command) {
                'run' {
                    return (Invoke-RunOperation -OperationNumber $context.operation -IssueNumber $context.issueNumber `
                        -RepoPath $context.repoPath -Detach)
                }
                'watch' {
                    return (Invoke-WatchCommand -OperationNumber $context.operation -IssueNumber $context.issueNumber `
                        -RepoPath $context.repoPath -Follow -Emitter { param($line) } `
                        -PrProbe $context.prProbe -CheckLister $context.checkLister -RemoteHeadProbe $context.remoteHeadProbe)
                }
                'review' {
                    return (Invoke-OperationReview -OperationNumber $context.operation -IssueNumber $context.issueNumber `
                        -RepoPath $context.repoPath -PrProbe $context.prProbe)
                }
                'repair' {
                    return (Invoke-RepairCommand -OperationNumber $context.operation -IssueNumber $context.issueNumber `
                        -RepoPath $context.repoPath -PrProbe $context.prProbe `
                        -CheckLister $context.checkLister -RemoteHeadProbe $context.remoteHeadProbe)
                }
                'finalize' {
                    return (Invoke-FinalizeCommand -OperationNumber $context.operation -IssueNumber $context.issueNumber `
                        -ReviewVerdict PASS -RepoPath $context.repoPath -PrProbe $context.prProbe `
                        -CheckLister $context.checkLister -RemoteHeadProbe $context.remoteHeadProbe)
                }
                default { throw "Unsupported canary router command: $command" }
            }
        }
    }

    $commands = New-Object System.Collections.ArrayList
    $routerOutputParsed = $false
    $routerOutput = $null
    $routerFailure = $null
    $context = [pscustomobject]@{
        repoPath=$resolvedRepo;operation=$Operation;issueNumber=$IssueNumber
        prProbe=$PrProbe;checkLister=$CheckLister;remoteHeadProbe=$RemoteHeadProbe
    }
    $invokeCommand = {
        param([string]$Name)
        [void]$commands.Add($Name)
        try {
            $value = & $RouterInvoker $Name $context
            if ($null -eq $value) { throw "Router command '$Name' returned no structured output." }
            $script:CanaryLastRouterOutput = $value
            $script:CanaryRouterOutputParsed = $true
            return $value
        } catch {
            $script:CanaryRouterFailure = $_.Exception.Message
            return $null
        }
    }
    $script:CanaryLastRouterOutput = $null
    $script:CanaryRouterOutputParsed = $false
    $script:CanaryRouterFailure = $null

    $execution = & $ExecutionReader $resolvedRepo $Operation $IssueNumber
    if ($Phase -eq 'Start' -and $null -eq $checkpoint -and $null -ne $execution -and -not $resultPathWasExplicit) {
        return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_REQUIRED' `
            -Reason 'existing_execution_requires_explicit_new_result_path' -Checkpoint $null `
            -CurrentExecution $execution -CheckpointPath $ResultPath)
    }
    if ($null -ne $checkpoint) {
        if ($null -eq $execution -or
            [int](Get-CanaryProperty -Object $execution -Name 'operation' -Default 0) -ne $Operation -or
            [int](Get-CanaryProperty -Object $execution -Name 'issueNumber' -Default 0) -ne $IssueNumber -or
            [string](Get-CanaryProperty -Object $execution -Name 'ownerRepo') -cne [string]$repoIdentity.ownerRepo -or
            [string](Get-CanaryProperty -Object $execution -Name 'repoRootHash') -cne [string]$repoIdentity.repoRootHash -or
            [string](Get-CanaryProperty -Object $execution -Name 'executionId') -cne [string]$checkpoint.executionId -or
            [int](Get-CanaryProperty -Object $execution -Name 'generation' -Default 0) -ne [int]$checkpoint.generation) {
            return (New-CanaryCheckpointFailure -Status 'LIVE_CANARY_CHECKPOINT_EXECUTION_MISMATCH' `
                -Reason 'checkpoint_does_not_match_current_execution_receipt' -Checkpoint $checkpoint `
                -CurrentExecution $execution -CheckpointPath $ResultPath)
        }
    }
    $anchorExecutionId = if ($null -ne $execution) { [string]$execution.executionId } else { $null }
    $anchorGeneration = if ($null -ne $execution) { [int]$execution.generation } else { $null }
    if ($Phase -eq 'Start' -and $null -eq $execution) {
        $routerOutput = & $invokeCommand 'run'
        if ($null -eq $routerOutput) { $routerFailure = $script:CanaryRouterFailure }
        $execution = & $ExecutionReader $resolvedRepo $Operation $IssueNumber
        if ($null -ne $execution) {
            $anchorExecutionId = [string]$execution.executionId
            $anchorGeneration = [int]$execution.generation
        }
    } elseif ($Phase -ne 'Start' -and $null -eq $execution) {
        $routerFailure = 'execution_receipt_missing'
    }

    $terminal = $null
    if ($null -ne $execution -and (Test-ExecutionStatusActive -Status ([string]$execution.status)) -and
        $Phase -ne 'Finalize') {
        $terminal = & $invokeCommand 'watch'
        if ($null -eq $terminal) { $routerFailure = $script:CanaryRouterFailure }
        $execution = & $ExecutionReader $resolvedRepo $Operation $IssueNumber
        if ($null -ne $execution -and
            ([string]$execution.executionId -cne $anchorExecutionId -or
             [int]$execution.generation -ne $anchorGeneration)) {
            $routerFailure = 'watch_execution_identity_changed'
        }
        if ($null -ne $terminal -and
            (-not [bool](Get-CanaryProperty -Object $terminal -Name 'terminal' -Default $false) -or
             [string](Get-CanaryProperty -Object $terminal -Name 'executionId') -cne $anchorExecutionId -or
             [int](Get-CanaryProperty -Object $terminal -Name 'generation' -Default 0) -ne $anchorGeneration)) {
            $routerFailure = 'watch_terminal_receipt_mismatch'
        }
    } elseif ($null -ne $execution -and -not (Test-ExecutionStatusActive -Status ([string]$execution.status))) {
        $terminal = [pscustomobject]@{
            status=[string]$execution.status;terminal=$true;executionId=[string]$execution.executionId
            generation=[int]$execution.generation
            nextAction=if($execution.PSObject.Properties.Name -contains 'nextAction' -and $execution.nextAction){
                [string]$execution.nextAction
            }else{Get-WatchNextAction -Receipt $execution -Status ([string]$execution.status)}
        }
    }

    $runReceipt = & $RunReceiptReader $resolvedRepo $Operation $IssueNumber
    $reviewReceipt = & $ReviewReceiptReader $resolvedRepo $Operation $IssueNumber
    $repairReceipt = & $RepairReceiptReader $resolvedRepo $Operation $IssueNumber
    $nextAction = if ($null -ne $terminal) { [string](Get-CanaryProperty -Object $terminal -Name 'nextAction') } else { $null }

    if ($null -eq $routerFailure -and $Operation -eq 1 -and $Phase -ne 'Finalize') {
        if ($nextAction -eq 'review') {
            if ($null -eq $reviewReceipt) {
                $routerOutput = & $invokeCommand 'review'
                if ($null -eq $routerOutput) { $routerFailure = $script:CanaryRouterFailure }
                $reviewReceipt = & $ReviewReceiptReader $resolvedRepo $Operation $IssueNumber
            }
            $reviewVerdict = [string](Get-CanaryProperty -Object $reviewReceipt -Name 'verdict')
            if ($reviewVerdict -eq 'REPAIR_REQUIRED') {
                if ($null -eq $repairReceipt) {
                    $routerOutput = & $invokeCommand 'repair'
                    if ($null -eq $routerOutput) { $routerFailure = $script:CanaryRouterFailure }
                    $repairReceipt = & $RepairReceiptReader $resolvedRepo $Operation $IssueNumber
                }
            } elseif ($reviewVerdict -ne 'PASS') {
                $routerFailure = 'operation1_review_not_terminal'
            }
        } elseif ($nextAction -ne 'opus_end_review') {
            $routerFailure = "operation1_next_action_invalid:$nextAction"
        }
    }

    $implementationEvidence = Get-CanaryPhaseEvidence -Phase implementation `
        -ExecutionReceipt $execution -WorkerReceipt $runReceipt -Operation $Operation `
        -IssueNumber $IssueNumber -RepositoryIdentity $repoIdentity `
        -ExpectedHead ([string](Get-CanaryProperty -Object $runReceipt -Name 'finalHead'))
    $repairEvidence = [pscustomobject][ordered]@{
        performed=$false;valid=$false;executionId=$null;generation=$null;resultEnvelope=$null
        resultEnvelopePresent=$false;resultEnvelopeParsed=$false;resultEnvelopeContextValid=$false
        resultEnvelopeWorkerValid=$false;executionSuccessful=$false
        resultEnvelopeReason='repair_not_performed';worker=$null
        workerReportValid=$false;localVerificationComplete=$false;verificationProvenance=$null
        remainingProblems=@();finalHead=$null;contextVerified=$false;reason='repair_not_performed'
    }
    if ($null -ne $repairReceipt) {
        $repairEvidence = Get-CanaryPhaseEvidence -Phase repair `
            -ExecutionReceipt $repairReceipt -WorkerReceipt $repairReceipt -Operation $Operation `
            -IssueNumber $IssueNumber -RepositoryIdentity $repoIdentity `
            -ExpectedHead (Get-CanaryGitValue -Path $resolvedRepo -Arguments @('rev-parse','HEAD'))
    }

    if ($null -eq $routerFailure) {
        switch ($Operation) {
            3 {
                if ($nextAction -cne 'report') {
                    $routerFailure = "operation3_next_action_invalid:$nextAction"
                }
            }
            2 {
                if ($nextAction -cne 'sonnet_end_review') {
                    $routerFailure = "operation2_next_action_invalid:$nextAction"
                }
            }
            1 {
                if ($nextAction -eq 'review') {
                    $reviewContextValid = (
                        $null -ne $reviewReceipt -and
                        [int](Get-CanaryProperty -Object $reviewReceipt -Name 'operation' -Default 0) -eq $Operation -and
                        [int](Get-CanaryProperty -Object $reviewReceipt -Name 'issueNumber' -Default 0) -eq $IssueNumber -and
                        [string](Get-CanaryProperty -Object $reviewReceipt -Name 'ownerRepo') -ceq [string]$repoIdentity.ownerRepo -and
                        [string](Get-CanaryProperty -Object $reviewReceipt -Name 'repoRootHash') -ceq [string]$repoIdentity.repoRootHash -and
                        [string](Get-CanaryProperty -Object $reviewReceipt -Name 'postReviewHead') -ceq
                            [string](Get-CanaryProperty -Object $runReceipt -Name 'finalHead')
                    )
                    $reviewVerdict = [string](Get-CanaryProperty -Object $reviewReceipt -Name 'verdict')
                    if (-not $reviewContextValid) {
                        $routerFailure = 'operation1_review_receipt_context_mismatch'
                    } elseif ($reviewVerdict -eq 'PASS') {
                        if ($null -ne $repairReceipt) {
                            $routerFailure = 'operation1_unexpected_repair_after_pass'
                        }
                    } elseif ($reviewVerdict -eq 'REPAIR_REQUIRED') {
                        if ($null -eq $repairReceipt) {
                            $routerFailure = 'operation1_repair_receipt_missing'
                        } elseif (-not [bool]$repairEvidence.valid) {
                            $routerFailure = 'repair_provenance_mismatch:' + [string]$repairEvidence.reason
                        }
                    } else {
                        $routerFailure = 'operation1_review_not_terminal'
                    }
                } elseif ($nextAction -ne 'opus_end_review') {
                    $routerFailure = "operation1_next_action_invalid:$nextAction"
                }
            }
        }
    }

    $authoritativeReceipt = if ($null -ne $repairReceipt) { $repairReceipt } else { $runReceipt }
    $authoritativeEvidence = if ($null -ne $repairReceipt) { $repairEvidence } else { $implementationEvidence }
    if ($null -eq $routerFailure -and $Operation -in @(1,2,3) -and -not [bool]$authoritativeEvidence.valid) {
        $routerFailure = 'authoritative_worker_evidence_invalid:' + [string]$authoritativeEvidence.reason
    }
    $workBranch = $null
    if ($null -ne $authoritativeReceipt) {
        $workflow = Get-ReceiptWorkflowContext -Receipt $authoritativeReceipt
        $workBranch = [string](Get-CanaryProperty -Object $workflow -Name 'workBranch')
    }
    $finalHead = Get-CanaryGitValue -Path $resolvedRepo -Arguments @('rev-parse','HEAD')
    $expectedReviewer = $null
    if ($Operation -in @(1,2)) {
        $config = Get-Config
        $expectedReviewer = [string]$config.claudeSession."$Operation".model
    }
    $finalReview = [pscustomobject]@{present=$false;valid=$false;verdict=$null;reviewer=$null;path=$null;reason='not-required'}
    if ($Operation -in @(1,2)) {
        $finalReview = Test-CanaryFinalReviewEvidence -Path $FinalReviewEvidencePath `
            -Operation $Operation -IssueNumber $IssueNumber -ExpectedHead $finalHead `
            -ExpectedWorkBranch $workBranch -ExpectedReviewer $expectedReviewer
    }

    $prEvidence = Get-CanaryPrEvidence -RepoPath $resolvedRepo -Receipt $authoritativeReceipt `
        -PrProbe $PrProbe -CheckLister $CheckLister -RemoteHeadProbe $RemoteHeadProbe `
        -MergeMutationProbe $MergeMutationProbe
    if ($null -eq $routerFailure -and $prEvidence.automaticMergeCalled -eq $true) {
        $routerFailure = 'automatic_merge_invocation_observed'
    }
    if ($null -eq $routerFailure -and $Operation -eq 3) {
        $workflowMode = [string](Get-CanaryProperty -Object $workflow -Name 'mode' -Default 'direct-main')
        if ($workflowMode -eq 'pull-request') {
            if (-not [bool]$prEvidence.prContextVerified) {
                $routerFailure = 'operation3_pr_context_invalid'
            } elseif ($prEvidence.prRemainsDraft -ne $true) {
                $routerFailure = 'operation3_pr_not_draft'
            } elseif ($prEvidence.prMerged -ne $false) {
                $routerFailure = 'operation3_pr_merged'
            } elseif ([string]$prEvidence.ciStatus -notin @('success','not-requested')) {
                $routerFailure = 'operation3_pr_ci_' + [string]$prEvidence.ciStatus
            }
        } elseif ([string]$authoritativeEvidence.finalHead -cne $finalHead) {
            $routerFailure = 'operation3_direct_main_head_mismatch'
        }
    }
    $finalizeOutput = $null
    if ($null -eq $routerFailure -and $Operation -in @(1,2) -and $finalReview.valid) {
        if ([string]$finalReview.verdict -ne 'PASS') {
            $routerFailure = 'final_review_requires_repair'
        } elseif (-not [bool]$prEvidence.prContextVerified) {
            $routerFailure = 'final_review_pr_context_unverified'
        } else {
            $finalizeOutput = & $invokeCommand 'finalize'
            if ($null -eq $finalizeOutput) { $routerFailure = $script:CanaryRouterFailure }
            $authoritativeReceipt = if ($null -ne $repairReceipt) {
                & $RepairReceiptReader $resolvedRepo $Operation $IssueNumber
            } else {
                & $RunReceiptReader $resolvedRepo $Operation $IssueNumber
            }
            $prEvidence = Get-CanaryPrEvidence -RepoPath $resolvedRepo -Receipt $authoritativeReceipt `
                -PrProbe $PrProbe -CheckLister $CheckLister -RemoteHeadProbe $RemoteHeadProbe `
                -MergeMutationProbe $MergeMutationProbe
            if ($prEvidence.automaticMergeCalled -eq $true) {
                $routerFailure = 'automatic_merge_invocation_observed'
            }
        }
    }

    $paidEvidence = Get-CanaryPaidCallEvidence -ExecutionReceipt $execution `
        -RepairReceipt $repairReceipt -Operation $Operation -IssueNumber $IssueNumber `
        -RouterCommands @($commands)
    $routerOutputParsed = [bool]$script:CanaryRouterOutputParsed
    $routerOutput = $script:CanaryLastRouterOutput
    if ($null -eq $routerFailure) { $routerFailure = $script:CanaryRouterFailure }

    $finalStatus = $null
    if ($null -ne $routerFailure) {
        if ($routerFailure -like 'operation3_next_action_invalid:*') {
            $finalStatus = 'LIVE_CANARY_OPERATION3_NEXT_ACTION_INVALID'
        } elseif ($routerFailure -like 'operation2_next_action_invalid:*') {
            $finalStatus = 'LIVE_CANARY_OPERATION2_NEXT_ACTION_INVALID'
        } elseif ($routerFailure -like 'operation1_next_action_invalid:*') {
            $finalStatus = 'LIVE_CANARY_OPERATION1_NEXT_ACTION_INVALID'
        } else {
            $finalStatus = 'LIVE_CANARY_FAILED'
        }
    } elseif ($Operation -eq 3) {
        if ($nextAction -eq 'report' -and [bool](Get-CanaryProperty -Object $terminal -Name 'terminal' -Default $false)) {
            $finalStatus = 'LIVE_CANARY_OPERATION3_COMPLETE'
        } else {
            $finalStatus = 'LIVE_CANARY_FAILED'
            $routerFailure = 'operation3_terminal_report_missing'
        }
    } elseif (-not $finalReview.present) {
        $finalStatus = 'LIVE_CANARY_FINAL_REVIEW_REQUIRED'
    } elseif (-not $finalReview.valid) {
        $finalStatus = 'LIVE_CANARY_FINAL_REVIEW_INVALID'
    } elseif ($null -ne $finalizeOutput) {
        $finalStatus = [string](Get-CanaryProperty -Object $finalizeOutput -Name 'status' -Default 'LIVE_CANARY_FAILED')
    } else {
        $finalStatus = 'LIVE_CANARY_FAILED'
    }

    $result = [pscustomobject][ordered]@{
        schemaVersion = $Script:CanaryResultSchemaVersion
        checkpointSchemaVersion = $Script:CanaryCheckpointSchemaVersion
        routerVersion = [string]$summary.version
        routerHead = $routerHead
        targetRepositoryIdentity = [pscustomobject][ordered]@{
            ownerRepo = $repoIdentity.ownerRepo
            repoRootHash = $repoIdentity.repoRootHash
        }
        phase = $Phase
        operation = $Operation
        issueNumber = $IssueNumber
        worker = Get-CanaryProperty -Object $execution -Name 'worker'
        model = Get-CanaryProperty -Object $execution -Name 'model'
        effort = Get-CanaryProperty -Object $execution -Name 'effort'
        startHead = $startHead
        finalHead = $finalHead
        executionId = Get-CanaryProperty -Object $execution -Name 'executionId'
        generation = Get-CanaryProperty -Object $execution -Name 'generation'
        authoritativeExecutionId = $authoritativeEvidence.executionId
        authoritativeGeneration = $authoritativeEvidence.generation
        routerCommands = @($commands)
        routerOutputParsed = $routerOutputParsed
        routerTerminalStatus = Get-CanaryProperty -Object $terminal -Name 'status'
        nextAction = $nextAction
        resultEnvelopePresent = [bool]$authoritativeEvidence.resultEnvelopePresent
        resultEnvelopeFilePresent = [bool]$authoritativeEvidence.resultEnvelopePresent
        resultEnvelopeParsed = [bool]$authoritativeEvidence.resultEnvelopeParsed
        resultEnvelopeContextValid = [bool]$authoritativeEvidence.resultEnvelopeContextValid
        resultEnvelopeWorkerValid = [bool]$authoritativeEvidence.resultEnvelopeWorkerValid
        resultExecutionSuccessful = [bool]$authoritativeEvidence.executionSuccessful
        resultEnvelopeValid = [bool]$authoritativeEvidence.valid
        resultEnvelopeReason = $authoritativeEvidence.resultEnvelopeReason
        workerReportValid = [bool]$authoritativeEvidence.workerReportValid
        localVerificationComplete = [bool]$authoritativeEvidence.localVerificationComplete
        verificationProvenance = $authoritativeEvidence.verificationProvenance
        remainingProblems = @($authoritativeEvidence.remainingProblems)
        implementationEvidence = $implementationEvidence
        repairEvidence = $repairEvidence
        branch = Get-CanaryGitValue -Path $resolvedRepo -Arguments @('branch','--show-current')
        baseBranch = $prEvidence.baseBranch
        workBranch = $prEvidence.workBranch
        remoteWorkBranchHead = $prEvidence.remoteWorkBranchHead
        draftPrNumber = $prEvidence.draftPrNumber
        draftPrUrl = $prEvidence.draftPrUrl
        prHeadSha = $prEvidence.prHeadSha
        prState = $prEvidence.prState
        prContextVerified = [bool]$prEvidence.prContextVerified
        ciStatus = $prEvidence.ciStatus
        finalReviewEvidenceValid = [bool]$finalReview.valid
        finalReviewVerdict = $finalReview.verdict
        finalStatus = $finalStatus
        failureReason = $routerFailure
        mergeReady = [bool](Get-CanaryProperty -Object $finalizeOutput -Name 'mergeReady' -Default $false)
        draftRetained = $prEvidence.draftRetained
        prRemainsDraft = $prEvidence.prRemainsDraft
        prMerged = $prEvidence.prMerged
        automaticMergeCalled = $prEvidence.automaticMergeCalled
        automaticMergeVerification = $prEvidence.automaticMergeVerification
        paidProviderCalls = $paidEvidence.count
        paidProviderCallsVerified = [bool]$paidEvidence.verified
        paidProviderCallsReason = $paidEvidence.reason
        paidProviderCallsByPhase = $paidEvidence.byPhase
        providerCallsThisInvocation = if ($commands.Count -eq 0) { 0 } else { $null }
        providerCallsThisInvocationVerified = ($commands.Count -eq 0)
        startedAtUtc = $startedAt
        finishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        evidenceSources = [pscustomobject][ordered]@{
            executionReceipt = if ($null -ne $execution) {
                Get-ExecutionReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $resolvedRepo
            } else { $null }
            resultEnvelope = $authoritativeEvidence.resultEnvelope
            implementationResultEnvelope = $implementationEvidence.resultEnvelope
            repairResultEnvelope = $repairEvidence.resultEnvelope
            runReceipt = if ($null -ne $runReceipt) {
                Get-RunReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $resolvedRepo
            } else { $null }
            reviewReceipt = if ($null -ne $reviewReceipt) {
                Get-ReviewReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $resolvedRepo
            } else { $null }
            repairReceipt = if ($null -ne $repairReceipt) {
                Get-RepairReceiptPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $resolvedRepo
            } else { $null }
            finalReviewEvidence = $finalReview.path
            finalizeResult = if ($null -ne $finalizeOutput) { 'router-function-output' } else { $null }
            pullRequest = if ($prEvidence.queried) { 'github-api' } else { $null }
            ci = if ($prEvidence.queried) { 'github-api-pr-linked-checks' } else { $null }
            paidProviderCalls = $paidEvidence.source
        }
    }
    Write-AtomicJsonFile -Path $ResultPath -Object $result -Depth 20
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ConfirmPaidProviderCall -or [string]::IsNullOrWhiteSpace($RepoPath) -or
        $Operation -notin @(1,2,3) -or $IssueNumber -lt 1) {
        New-CanaryUsageResult | ConvertTo-Json -Depth 6
        exit 2
    }
    . (Join-Path $PSScriptRoot 'run-operation.ps1')
    $invoke = @{
        ConfirmPaidProviderCall=$ConfirmPaidProviderCall
        RepoPath=$RepoPath
        Operation=$Operation
        IssueNumber=$IssueNumber
        Phase=$Phase
        FinalReviewEvidencePath=$FinalReviewEvidencePath
        ResultPath=$ResultPath
    }
    $result = Invoke-LiveCanary @invoke
    $result | ConvertTo-Json -Depth 20
    switch ([string]$result.finalStatus) {
        'LIVE_CANARY_NOT_EXECUTED' { exit 2 }
        'LIVE_CANARY_FINAL_REVIEW_REQUIRED' { exit 3 }
        'LIVE_CANARY_FINAL_REVIEW_INVALID' { exit 4 }
        'LIVE_CANARY_OPERATION3_COMPLETE' { exit 0 }
        'merge_ready' { exit 0 }
        default { exit 1 }
    }
}
