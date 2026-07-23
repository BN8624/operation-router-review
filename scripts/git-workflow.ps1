# direct-main과 Draft PR Git 워크플로의 검증·상태 전이를 제공한다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-SafeGitRefPolicyValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '[\x00-\x20\x7f]') { return $false }
    if ($Value -match '\.\.|[~\^:\?\*\[\\]') { return $false }
    if ($Value -match '[;&|`$()<>{}!''"]') { return $false }
    if ($Value.StartsWith('/') -or $Value.EndsWith('/') -or $Value.Contains('//')) { return $false }
    if ($Value.EndsWith('.')) { return $false }
    if ($Value.EndsWith('.lock', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { return $false }
    foreach ($part in ($Value -split '/')) {
        if ($part -in @('.','..') -or [string]::IsNullOrWhiteSpace($part) -or $part.StartsWith('.') -or $part.EndsWith('.')) { return $false }
    }
    return $true
}

function Get-GitWorkflowPolicy {
    param([Parameter(Mandatory)]$Config)
    $configProperties=@($Config.PSObject.Properties|ForEach-Object{$_.Name})
    if ($configProperties -notcontains 'gitWorkflow' -or $null -eq $Config.gitWorkflow) {
        return [pscustomobject]@{
            mode='direct-main'; baseBranch='main'; branchPrefix='operation-router'
            createDraftPullRequest=$false; autoMerge=$false; requireCiWhenWorkflowPresent=$true
            fetchBeforeRun=$false; legacyDefault=$true
        }
    }
    $g = $Config.gitWorkflow
    $props = @($g.PSObject.Properties.Name)
    foreach ($required in @('mode','baseBranch','branchPrefix','createDraftPullRequest','autoMerge','requireCiWhenWorkflowPresent','fetchBeforeRun')) {
        if ($props -notcontains $required) { throw "gitWorkflow.$required is required." }
    }
    if ($g.mode -isnot [string] -or $g.baseBranch -isnot [string] -or $g.branchPrefix -isnot [string]) {
        throw 'gitWorkflow.mode, baseBranch, and branchPrefix must be strings.'
    }
    foreach ($booleanName in @('createDraftPullRequest','autoMerge','requireCiWhenWorkflowPresent','fetchBeforeRun')) {
        if ($g.$booleanName -isnot [bool]) { throw "gitWorkflow.$booleanName must be a boolean." }
    }
    $mode = [string]$g.mode
    if ($mode -cnotin @('direct-main','pull-request')) { throw "Invalid gitWorkflow.mode '$mode'." }
    $base = [string]$g.baseBranch; $prefix = [string]$g.branchPrefix
    if (-not (Test-SafeGitRefPolicyValue -Value $base)) { throw "Unsafe gitWorkflow.baseBranch '$base'." }
    if (-not (Test-SafeGitRefPolicyValue -Value $prefix)) { throw "Unsafe gitWorkflow.branchPrefix '$prefix'." }
    if ($mode -eq 'pull-request' -and -not [bool]$g.createDraftPullRequest) { throw 'pull-request mode requires createDraftPullRequest=true.' }
    if ($mode -eq 'pull-request' -and -not [bool]$g.fetchBeforeRun) { throw 'pull-request mode requires fetchBeforeRun=true.' }
    if ([bool]$g.autoMerge) { throw 'gitWorkflow.autoMerge must remain false.' }
    return [pscustomobject]@{
        mode=$mode; baseBranch=$base; branchPrefix=$prefix
        createDraftPullRequest=[bool]$g.createDraftPullRequest; autoMerge=[bool]$g.autoMerge
        requireCiWhenWorkflowPresent=[bool]$g.requireCiWhenWorkflowPresent
        fetchBeforeRun=[bool]$g.fetchBeforeRun; legacyDefault=$false
    }
}

function Get-IssueWorkBranch {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)]$Policy)
    Assert-ValidIssueNumber -Value ([string]$IssueNumber) | Out-Null
    $branch = "$($Policy.branchPrefix)/issue-$IssueNumber"
    if (-not (Test-SafeGitRefPolicyValue -Value $branch)) { throw "Unsafe generated work branch '$branch'." }
    return $branch
}

function Get-GitRefHead {
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Ref)
    $r = Invoke-GitRaw -Path $RepoPath -GitArgs @('rev-parse','--verify',$Ref)
    if ($r.ExitCode -ne 0 -or $r.Text -notmatch '^[0-9a-fA-F]{40,64}$') { return $null }
    return $r.Text.ToLowerInvariant()
}

function Get-GitUpstream {
    param([Parameter(Mandatory)][string]$RepoPath)
    $r = Invoke-GitRaw -Path $RepoPath -GitArgs @('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}')
    if ($r.ExitCode -ne 0) { return $null }
    return [string]$r.Text
}

function Get-GitRemoteBranchHead {
    param(
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Branch,
        [scriptblock]$RemoteHeadProbe
    )
    if ($null -ne $RemoteHeadProbe) { return (& $RemoteHeadProbe $RepoPath $Branch) }
    $r = Invoke-GitRaw -Path $RepoPath -GitArgs @('ls-remote','--heads','origin',"refs/heads/$Branch")
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return $null }
    $first = @($r.Text -split '\s+')[0]
    if ($first -notmatch '^[0-9a-fA-F]{40,64}$') { return $null }
    return $first.ToLowerInvariant()
}

function Get-GitWorkflowSnapshot {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Ref
    )
    $resolved=Get-GitRefHead -RepoPath $RepoPath -Ref $Ref
    if (-not $resolved) {
        return [pscustomobject]@{ok=$false;ref=$Ref;head=$null;exists=$false;files=@();digest=$null}
    }
    $tree=Invoke-GitRaw -Path $RepoPath -GitArgs @('ls-tree','-r','--full-tree',$resolved,'--','.github/workflows')
    if ($tree.ExitCode -ne 0) {
        return [pscustomobject]@{ok=$false;ref=$Ref;head=$resolved;exists=$false;files=@();digest=$null}
    }
    $entries=@()
    foreach ($line in @($tree.Text -split "`r?`n")) {
        if ($line -notmatch '^\d+\s+blob\s+([0-9a-fA-F]{40,64})\t(.+)$') { continue }
        $path=[string]$Matches[2]
        if ($path -notmatch '(?i)\.ya?ml$') { continue }
        $entries += [pscustomobject]@{path=$path;blobSha=([string]$Matches[1]).ToLowerInvariant()}
    }
    $entries=@($entries | Sort-Object path)
    $canonical=(@($entries | ForEach-Object { "$($_.path)`t$($_.blobSha)" }) -join "`n")
    return [pscustomobject]@{
        ok=$true;ref=$Ref;head=$resolved;exists=($entries.Count -gt 0)
        files=@($entries);digest=(Get-Sha256Text -Text $canonical)
    }
}

function Test-GitCommitAncestor {
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Ancestor, [Parameter(Mandatory)][string]$Descendant)
    if ([string]::IsNullOrWhiteSpace($Ancestor) -or [string]::IsNullOrWhiteSpace($Descendant)) { return $false }
    return ((Invoke-GitRaw -Path $RepoPath -GitArgs @('merge-base','--is-ancestor',$Ancestor,$Descendant)).ExitCode -eq 0)
}

function Copy-WorkflowContext {
    param([AllowNull()]$Workflow)
    if ($null -eq $Workflow) { return $null }
    return (($Workflow | ConvertTo-Json -Depth 30) | ConvertFrom-Json)
}

function Get-WorkflowRequireCi {
    param([Parameter(Mandatory)]$Workflow)
    if($Workflow.PSObject.Properties.Name -contains 'requireCiWhenWorkflowPresent'){
        return [bool]$Workflow.requireCiWhenWorkflowPresent
    }
    return $true
}

function Get-ReceiptWorkflowContext {
    param([AllowNull()]$Receipt)
    if ($null -eq $Receipt -or $Receipt.PSObject.Properties.Name -notcontains 'workflow' -or $null -eq $Receipt.workflow) {
        return [pscustomobject]@{ mode='direct-main'; baseBranch='main'; workBranch=$null; legacyReceipt=$true }
    }
    if ($Receipt.workflow.PSObject.Properties.Name -notcontains 'mode' -or [string]::IsNullOrWhiteSpace([string]$Receipt.workflow.mode)) {
        return [pscustomobject]@{ mode='direct-main'; baseBranch='main'; workBranch=$null; legacyReceipt=$true }
    }
    return (Copy-WorkflowContext -Workflow $Receipt.workflow)
}

function ConvertTo-NormalizedPullRequest {
    param([Parameter(Mandatory)]$PullRequest)
    $p = @($PullRequest.PSObject.Properties.Name)
    $state = if ($p -contains 'state') { ([string]$PullRequest.state).ToUpperInvariant() } else { '' }
    $draft = if ($p -contains 'draft') { [bool]$PullRequest.draft } elseif ($p -contains 'isDraft') { [bool]$PullRequest.isDraft } else { $false }
    $base = if ($p -contains 'baseBranch') { [string]$PullRequest.baseBranch } elseif ($p -contains 'baseRefName') { [string]$PullRequest.baseRefName } elseif ($p -contains 'base') { [string]$PullRequest.base.ref } else { '' }
    $head = if ($p -contains 'headBranch') { [string]$PullRequest.headBranch } elseif ($p -contains 'headRefName') { [string]$PullRequest.headRefName } elseif ($p -contains 'head') { [string]$PullRequest.head.ref } else { '' }
    $sha = if ($p -contains 'headSha') { [string]$PullRequest.headSha } elseif ($p -contains 'headRefOid') { [string]$PullRequest.headRefOid } elseif ($p -contains 'head') { [string]$PullRequest.head.sha } else { '' }
    $url = if ($p -contains 'url') { [string]$PullRequest.url } elseif ($p -contains 'html_url') { [string]$PullRequest.html_url } else { '' }
    $headRepository = ''
    if ($p -contains 'headRepository' -and $null -ne $PullRequest.headRepository) {
        if ($PullRequest.headRepository -is [string]) {
            $headRepository = [string]$PullRequest.headRepository
        } else {
            $repoProps = @($PullRequest.headRepository.PSObject.Properties.Name)
            if ($repoProps -contains 'nameWithOwner') { $headRepository = [string]$PullRequest.headRepository.nameWithOwner }
            elseif ($repoProps -contains 'full_name') { $headRepository = [string]$PullRequest.headRepository.full_name }
        }
    } elseif ($p -contains 'head' -and $null -ne $PullRequest.head) {
        $headProps = @($PullRequest.head.PSObject.Properties.Name)
        if ($headProps -contains 'repo' -and $null -ne $PullRequest.head.repo) {
            $repoProps = @($PullRequest.head.repo.PSObject.Properties.Name)
            if ($repoProps -contains 'full_name') { $headRepository = [string]$PullRequest.head.repo.full_name }
            elseif ($repoProps -contains 'nameWithOwner') { $headRepository = [string]$PullRequest.head.repo.nameWithOwner }
        }
    } elseif ($p -contains 'headRepo') {
        $headRepository = [string]$PullRequest.headRepo
    }
    $merged = if ($p -contains 'merged') { [bool]$PullRequest.merged } elseif ($p -contains 'merged_at') { -not [string]::IsNullOrWhiteSpace([string]$PullRequest.merged_at) } else { $state -eq 'MERGED' }
    return [pscustomobject]@{
        number=if($p -contains 'number'){[int]$PullRequest.number}else{0}; url=$url; state=$state; draft=$draft
        baseBranch=$base; headBranch=$head; headSha=$sha; headRepository=$headRepository; merged=[bool]$merged
    }
}

function Invoke-DefaultPullRequestProbe {
    param([Parameter(Mandatory)][ValidateSet('lookup','create')][string]$Action, [Parameter(Mandatory)]$Context)
    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ok=$false;error='pr_tool_unavailable';items=@()} }
    $ErrorActionPreference = 'Continue'
    Push-Location ([string]$Context.repoPath)
    try {
        if ($Action -eq 'lookup') {
            $owner = ([string]$Context.ownerRepo -split '/',2)[0]
            $endpoint = "repos/$($Context.ownerRepo)/pulls?state=all&head=$owner`:$($Context.workBranch)&per_page=100"
            $out = & gh api -X GET $endpoint 2>&1
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ok=$false;error='pr_lookup_failed';items=@()} }
            try { $items = @((($out | Out-String) | ConvertFrom-Json)) } catch { return [pscustomobject]@{ok=$false;error='pr_lookup_failed';items=@()} }
            return [pscustomobject]@{ok=$true;error=$null;items=@($items)}
        }
        if ($Action -eq 'create') {
            $out = & gh pr create --repo ([string]$Context.ownerRepo) --draft --base ([string]$Context.baseBranch) `
                --head ([string]$Context.workBranch) --title ([string]$Context.title) --body-file ([string]$Context.bodyPath) 2>&1
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ok=$false;error='pr_create_failed';items=@()} }
            return [pscustomobject]@{ok=$true;error=$null;url=(($out | Out-String).Trim());items=@()}
        }
    } finally { Pop-Location }
}

function Invoke-PullRequestProbe {
    param(
        [Parameter(Mandatory)][ValidateSet('lookup','create')][string]$Action,
        [Parameter(Mandatory)]$Context, [scriptblock]$PrProbe
    )
    try {
        if ($null -ne $PrProbe) { return (& $PrProbe $Action $Context) }
        return (Invoke-DefaultPullRequestProbe -Action $Action -Context $Context)
    } catch {
        $error = switch ($Action) {
            'lookup' { 'pr_lookup_failed' }
            'create' { 'pr_create_failed' }
            default  { 'pr_create_failed' }
        }
        return [pscustomobject]@{ok=$false;error=$error;items=@()}
    }
}

function Get-PullRequestForBranch {
    param(
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$OwnerRepo,
        [Parameter(Mandatory)][string]$WorkBranch, [scriptblock]$PrProbe
    )
    $ctx = [pscustomobject]@{repoPath=$RepoPath;ownerRepo=$OwnerRepo;workBranch=$WorkBranch}
    $res = Invoke-PullRequestProbe -Action lookup -Context $ctx -PrProbe $PrProbe
    if ($null -eq $res -or -not [bool]$res.ok) {
        $reason = 'pr_lookup_failed'
        if ($null -ne $res -and $res.PSObject.Properties.Name -contains 'error' -and [string]$res.error -eq 'pr_tool_unavailable') { $reason = 'pr_tool_unavailable' }
        return [pscustomobject]@{ok=$false;status=$reason;items=@()}
    }
    $items = @()
    foreach ($item in @($res.items)) { $items += ConvertTo-NormalizedPullRequest -PullRequest $item }
    return [pscustomobject]@{ok=$true;status='ok';items=@($items)}
}

function Test-PullRequestContext {
    param(
        [Parameter(Mandatory)]$PullRequest, [Parameter(Mandatory)][string]$BaseBranch,
        [Parameter(Mandatory)][string]$WorkBranch, [Parameter(Mandatory)][string]$HeadSha,
        [string]$OwnerRepo,
        [switch]$RequireDraft
    )
    $pr = ConvertTo-NormalizedPullRequest -PullRequest $PullRequest
    if ($pr.merged -or $pr.state -eq 'MERGED') { return [pscustomobject]@{ok=$false;status='pr_already_merged';pr=$pr} }
    if ($pr.state -ne 'OPEN') { return [pscustomobject]@{ok=$false;status='pr_already_closed';pr=$pr} }
    if ($RequireDraft -and -not $pr.draft) { return [pscustomobject]@{ok=$false;status='pr_not_draft';pr=$pr} }
    if (-not [string]::IsNullOrWhiteSpace($OwnerRepo) -and
        ([string]::IsNullOrWhiteSpace([string]$pr.headRepository) -or
         -not ([string]$pr.headRepository).Equals($OwnerRepo,[System.StringComparison]::OrdinalIgnoreCase))) {
        return [pscustomobject]@{ok=$false;status='pr_context_mismatch';pr=$pr}
    }
    if ($pr.baseBranch -cne $BaseBranch -or $pr.headBranch -cne $WorkBranch -or $pr.headSha -cne $HeadSha) {
        return [pscustomobject]@{ok=$false;status='pr_context_mismatch';pr=$pr}
    }
    return [pscustomobject]@{ok=$true;status='ok';pr=$pr}
}

function Get-IssueWorkflowReceiptPath {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) "issue-$IssueNumber-workflow.json")
}

function Save-IssueWorkflowReceipt {
    param(
        [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)]$Workflow
    )
    $identity=Get-RepoIdentity -RepoPath $RepoPath
    $now=(Get-Date).ToUniversalTime().ToString('o')
    $receipt=[pscustomobject]@{
        schemaVersion=2;issueNumber=$IssueNumber;ownerRepo=$identity.ownerRepo
        canonicalRepoRoot=$identity.canonicalRepoRoot;repoRootHash=$identity.repoRootHash
        workflow=(Copy-WorkflowContext -Workflow $Workflow);updatedAt=$now
    }
    $path=Get-IssueWorkflowReceiptPath -IssueNumber $IssueNumber -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    Write-AtomicJsonFile -Path $path -Object $receipt
    return $path
}

function Get-IssueWorkflowReceipt {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $path=Get-IssueWorkflowReceiptPath -IssueNumber $IssueNumber -RepoPath $RepoPath
    if(-not (Test-Path -LiteralPath $path)){return $null}
    try{return Read-JsonFileStable -Path $path -MaxAttempts 3 -DelayMilliseconds 25}catch{return $null}
}

function Find-IssueWorkflowReceipt {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$RepoPath)
    $candidates = @()
    $owner=Get-IssueWorkflowReceipt -IssueNumber $IssueNumber -RepoPath $RepoPath
    if($null -ne $owner){$candidates+=$owner}
    foreach ($operation in 1..3) {
        try {
            $execution = Get-ExecutionReceipt -Operation $operation -IssueNumber $IssueNumber -RepoPath $RepoPath
            if ($null -ne $execution) { $candidates += $execution }
        } catch {}
        try {
            $run = Get-RunReceipt -Operation $operation -IssueNumber $IssueNumber -RepoPath $RepoPath
            if ($null -ne $run) { $candidates += $run }
        } catch {}
    }
    $owned = @($candidates | Where-Object {
        (Test-ReceiptRepoMatch -Receipt $_ -RepoPath $RepoPath) -and
        (Get-ReceiptWorkflowContext -Receipt $_).mode -eq 'pull-request'
    } | Sort-Object -Property @{Expression={if($_.PSObject.Properties.Name -contains 'updatedAt'){[string]$_.updatedAt}elseif($_.PSObject.Properties.Name -contains 'createdAt'){[string]$_.createdAt}else{''}};Descending=$true})
    if ($owned.Count -eq 0) { return $null }
    return $owned[0]
}

function Initialize-GitWorkflowRun {
    param(
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)]$Config, [scriptblock]$FetchProbe, [scriptblock]$PrProbe
    )
    $policy = Get-GitWorkflowPolicy -Config $Config
    if ($policy.mode -eq 'direct-main') {
        $pre = Test-StartPreconditions -RepoPath $RepoPath
        if (-not $pre.ok) { return $pre }
        $workflow = [pscustomobject]@{mode='direct-main';baseBranch='main';workBranch=$null;legacyConfig=[bool]$policy.legacyDefault}
        Add-Member -InputObject $pre.snapshot -NotePropertyName workflow -NotePropertyValue $workflow -Force
        return [pscustomobject]@{ok=$true;snapshot=$pre.snapshot;ownerRepo=$pre.ownerRepo;workflow=$workflow;policy=$policy}
    }
    if (-not (Test-GitRepository -Path $RepoPath)) { return [pscustomobject]@{ok=$false;reason='not_a_git_repository'} }
    $wt = Get-GitWorktreeStatus -Path $RepoPath
    if (-not $wt.Clean) { return [pscustomobject]@{ok=$false;reason='dirty_worktree'} }
    $ownerRepo = Get-GitOriginOwnerRepo -Path $RepoPath
    if ([string]::IsNullOrWhiteSpace($ownerRepo)) { return [pscustomobject]@{ok=$false;reason='remote_sync_unavailable'} }
    $base = [string]$policy.baseBranch
    $work = Get-IssueWorkBranch -IssueNumber $IssueNumber -Policy $policy
    $current = Get-GitCurrentBranch -Path $RepoPath
    $ownerReceipt = Find-IssueWorkflowReceipt -IssueNumber $IssueNumber -RepoPath $RepoPath
    if ($current -notin @($base,$work)) { return [pscustomobject]@{ok=$false;reason='not_on_base_or_work_branch'} }
    if ($current -eq $work -and $null -eq $ownerReceipt) { return [pscustomobject]@{ok=$false;reason='work_branch_unowned'} }
    $localBase = Get-GitRefHead -RepoPath $RepoPath -Ref "refs/heads/$base"
    if(-not $localBase){return [pscustomobject]@{ok=$false;reason='base_branch_missing'}}
    $remoteBaseProbe=Invoke-GitRaw -Path $RepoPath -GitArgs @('ls-remote','--exit-code','--heads','origin',"refs/heads/$base")
    if($remoteBaseProbe.ExitCode -eq 2 -or ($remoteBaseProbe.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($remoteBaseProbe.Text))){
        return [pscustomobject]@{ok=$false;reason='base_branch_missing'}
    }
    if($remoteBaseProbe.ExitCode -ne 0){return [pscustomobject]@{ok=$false;reason='remote_sync_unavailable'}}

    $fetchOk = $true
    if ($null -ne $FetchProbe) {
        $fr = & $FetchProbe $RepoPath $base
        if ($fr -is [bool]) { $fetchOk = $fr } elseif ($null -eq $fr -or $fr.PSObject.Properties.Name -notcontains 'ok') { $fetchOk = $false } else { $fetchOk = [bool]$fr.ok }
    } else {
        $fetchOk = ((Invoke-GitRaw -Path $RepoPath -GitArgs @('fetch','origin',$base)).ExitCode -eq 0)
    }
    if (-not $fetchOk) { return [pscustomobject]@{ok=$false;reason='remote_sync_unavailable'} }
    $localBase = Get-GitRefHead -RepoPath $RepoPath -Ref "refs/heads/$base"
    $remoteBase = Get-GitRefHead -RepoPath $RepoPath -Ref "refs/remotes/origin/$base"
    if (-not $localBase -or -not $remoteBase) { return [pscustomobject]@{ok=$false;reason='base_branch_missing'} }
    $ab = Invoke-GitRaw -Path $RepoPath -GitArgs @('rev-list','--left-right','--count',"refs/remotes/origin/$base...refs/heads/$base")
    if ($ab.ExitCode -ne 0) { return [pscustomobject]@{ok=$false;reason='remote_sync_unavailable'} }
    $parts = @($ab.Text -split '\s+')
    if ($parts.Count -lt 2) { return [pscustomobject]@{ok=$false;reason='remote_sync_unavailable'} }
    if ([int]$parts[0] -gt 0) { return [pscustomobject]@{ok=$false;reason='base_behind_remote'} }
    if ([int]$parts[1] -gt 0) { return [pscustomobject]@{ok=$false;reason='base_ahead_remote'} }

    $localWork = Get-GitRefHead -RepoPath $RepoPath -Ref "refs/heads/$work"
    $remoteWork = Get-GitRemoteBranchHead -RepoPath $RepoPath -Branch $work
    if (($localWork -or $remoteWork) -and $null -eq $ownerReceipt) { return [pscustomobject]@{ok=$false;reason='work_branch_unowned'} }
    $priorPr = $null
    $provisionalLocalResume=$false
    if ($null -ne $ownerReceipt) {
        $ownedWorkflow = Get-ReceiptWorkflowContext -Receipt $ownerReceipt
        if ([string]$ownedWorkflow.workBranch -cne $work -or [string]$ownedWorkflow.baseBranch -cne $base) {
            return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'}
        }
        $hasRecordedFinal = ($ownedWorkflow.PSObject.Properties.Name -contains 'finalHead' -and
            -not [string]::IsNullOrWhiteSpace([string]$ownedWorkflow.finalHead))
        $hasRecordedPr = ($ownedWorkflow.PSObject.Properties.Name -contains 'pr' -and $null -ne $ownedWorkflow.pr)
        if ($remoteWork) {
            if (-not $localWork -or $localWork -cne $remoteWork) {
                return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'}
            }
            if (-not $hasRecordedFinal -or [string]$ownedWorkflow.finalHead -cne $remoteWork -or -not $hasRecordedPr) {
                return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'}
            }
            $lookup = Get-PullRequestForBranch -RepoPath $RepoPath -OwnerRepo $ownerRepo -WorkBranch $work -PrProbe $PrProbe
            if (-not $lookup.ok -or $lookup.items.Count -ne 1) { return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'} }
            $checked = Test-PullRequestContext -PullRequest $lookup.items[0] -BaseBranch $base -WorkBranch $work -HeadSha $remoteWork -OwnerRepo $ownerRepo -RequireDraft
            if (-not $checked.ok -or [int]$checked.pr.number -ne [int]$ownedWorkflow.pr.number) {
                return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch';prStatus=$checked.status}
            }
            $priorPr = $checked.pr
        } elseif ($localWork) {
            $expectedInitial = if ($ownedWorkflow.PSObject.Properties.Name -contains 'workStartHead') {
                [string]$ownedWorkflow.workStartHead
            } else { [string]$ownedWorkflow.baseHead }
            if ($hasRecordedFinal -or $hasRecordedPr -or [string]::IsNullOrWhiteSpace($expectedInitial) -or
                $localWork -cne $expectedInitial -or $localWork -cne $localBase) {
                return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'}
            }
            $provisionalLocalResume=$true
        } elseif ($hasRecordedFinal -or $hasRecordedPr) {
            return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'}
        }
    }

    if ($current -eq $base) {
        if (-not $localWork -and -not $remoteWork) {
            $sw = Invoke-GitRaw -Path $RepoPath -GitArgs @('switch','-c',$work,"origin/$base")
            if ($sw.ExitCode -ne 0) { return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'} }
        } elseif ($localWork -and $null -ne $ownerReceipt) {
            $sw = Invoke-GitRaw -Path $RepoPath -GitArgs @('switch',$work)
            if ($sw.ExitCode -ne 0) { return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'} }
        } else {
            return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'}
        }
    }
    if ((Get-GitCurrentBranch -Path $RepoPath) -cne $work) { return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'} }
    if ($localWork) {
        $currentUpstream=Get-GitUpstream -RepoPath $RepoPath
        if($provisionalLocalResume){
            if($currentUpstream -and $currentUpstream -cne "origin/$base"){
                return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'}
            }
        } elseif($currentUpstream -cne "origin/$work"){
            return [pscustomobject]@{ok=$false;reason='work_branch_context_mismatch'}
        }
    }
    $snap = Get-StartSnapshot -RepoPath $RepoPath
    $baseWorkflow=Get-GitWorkflowSnapshot -RepoPath $RepoPath -Ref $localBase
    if (-not $baseWorkflow.ok) { return [pscustomobject]@{ok=$false;reason='remote_sync_unavailable'} }
    $workflow = [pscustomobject]@{
        mode='pull-request';baseBranch=$base;baseHead=$localBase;baseLocalHead=$localBase;baseRemoteHead=$remoteBase
        workBranch=$work;remoteWorkBranch="origin/$work";workStartHead=$snap.startHead;workRemoteHeadAtStart=$remoteWork;finalHead=$null
        initialUpstream=(Get-GitUpstream -RepoPath $RepoPath);baseAdvanced=$false;pr=$priorPr
        createDraftPullRequest=[bool]$policy.createDraftPullRequest;autoMerge=$false
        requireCiWhenWorkflowPresent=[bool]$policy.requireCiWhenWorkflowPresent
        baseWorkflow=$baseWorkflow;headWorkflow=$null
    }
    Add-Member -InputObject $snap -NotePropertyName workflow -NotePropertyValue $workflow -Force
    return [pscustomobject]@{ok=$true;snapshot=$snap;ownerRepo=$ownerRepo;workflow=$workflow;policy=$policy}
}

function Get-RepositoryMutationLockPath {
    param([Parameter(Mandatory)][string]$RepoPath)
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) 'repository-execution.lock')
}

function Get-RepositoryMutationReceiptPath {
    param([Parameter(Mandatory)][string]$RepoPath)
    return (Join-Path (Get-PendingNamespacePath -RepoPath $RepoPath) 'repository-mutation.json')
}

function Open-RepositoryMutationLock {
    param([Parameter(Mandatory)][string]$RepoPath)
    Initialize-PendingNamespace -RepoPath $RepoPath | Out-Null
    $path = Get-RepositoryMutationLockPath -RepoPath $RepoPath
    Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
    try { return [System.IO.File]::Open($path,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
    catch [System.IO.IOException] { return $null }
}

function Get-RepositoryMutationReceipt {
    param([Parameter(Mandatory)][string]$RepoPath)
    $path = Get-RepositoryMutationReceiptPath -RepoPath $RepoPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Read-JsonFileStable -Path $path -MaxAttempts 3 -DelayMilliseconds 25 } catch { return $null }
}

function Test-RepositoryMutationActive {
    param([AllowNull()]$Receipt, [Parameter(Mandatory)][string]$RepoPath, [scriptblock]$ProcessProbe, [scriptblock]$Clock)
    if ($null -eq $Receipt) { return $false }
    try {
        $pending=Get-PendingSnapshot -Operation ([int]$Receipt.operation) -IssueNumber ([int]$Receipt.issueNumber) -RepoPath $RepoPath
        if($null -ne $pending -and (Test-ReceiptRepoMatch -Receipt $pending -RepoPath $RepoPath)){return $true}
    } catch {}
    if ($Receipt.PSObject.Properties.Name -contains 'executionId' -and -not [string]::IsNullOrWhiteSpace([string]$Receipt.executionId)) {
        try {
            $execution = Get-ExecutionReceipt -Operation ([int]$Receipt.operation) -IssueNumber ([int]$Receipt.issueNumber) -RepoPath $RepoPath
            if ($null -eq $execution -or [string]$execution.executionId -cne [string]$Receipt.executionId) { return $false }
            if (-not (Test-ExecutionStatusActive -Status ([string]$execution.status))) { return $false }
            if (Test-ExecutionProcessAlive -Receipt $execution -ProcessProbe $ProcessProbe) { return $true }
            if (Test-Path -LiteralPath ([string]$execution.resultPath)) { return $true }
            $now = if ($null -ne $Clock) { & $Clock } else { [DateTime]::UtcNow }
            $age = ([DateTime]$now).ToUniversalTime() - ([DateTime]::Parse([string]$execution.updatedAt).ToUniversalTime())
            $limit = 15; try { $limit=[Math]::Max(1,[int](Get-Config).execution.staleHeartbeatSeconds) } catch {}
            return ($age.TotalSeconds -lt $limit)
        } catch { return $true }
    }
    if ($Receipt.PSObject.Properties.Name -contains 'processId' -and $null -ne $Receipt.processId) {
        $probe = Get-ProcessIdentity -ProcessId ([int]$Receipt.processId) -ProcessProbe $ProcessProbe
        if ($probe.exists -and [string]$probe.startedAt -eq [string]$Receipt.processStartedAt) { return $true }
    }
    try {
        $now = if ($null -ne $Clock) { & $Clock } else { [DateTime]::UtcNow }
        return ((([DateTime]$now).ToUniversalTime() - ([DateTime]::Parse([string]$Receipt.updatedAt).ToUniversalTime())).TotalSeconds -lt 15)
    } catch { return $true }
}

function Enter-RepositoryMutation {
    param(
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][int]$Operation,
        [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$Purpose,
        [scriptblock]$ProcessProbe, [scriptblock]$Clock
    )
    $lock = Open-RepositoryMutationLock -RepoPath $RepoPath
    if ($null -eq $lock) { return [pscustomobject]@{acquired=$false;status='repository_execution_active'} }
    try {
        $existing = Get-RepositoryMutationReceipt -RepoPath $RepoPath
        if (Test-RepositoryMutationActive -Receipt $existing -RepoPath $RepoPath -ProcessProbe $ProcessProbe -Clock $Clock) {
            if ([int]$existing.operation -eq $Operation -and [int]$existing.issueNumber -eq $IssueNumber) {
                $continuationPurpose=$Purpose -in @('run','recover','claude-postflight')
                $hasExecution=($existing.PSObject.Properties.Name -contains 'executionId' -and -not [string]::IsNullOrWhiteSpace([string]$existing.executionId))
                if($continuationPurpose -and ($Purpose -ne 'run' -or $hasExecution)){
                    return [pscustomobject]@{acquired=$true;owned=$true;token=[string]$existing.token;receipt=$existing}
                }
            }
            return [pscustomobject]@{
                acquired=$false;status='repository_execution_active';activeOperation=[int]$existing.operation
                activeIssueNumber=[int]$existing.issueNumber;executionId=$existing.executionId
                watchCommand="-Command watch -Operation $($existing.operation) -IssueNumber $($existing.issueNumber) -Follow"
            }
        }
        $id = Get-RepoIdentity -RepoPath $RepoPath
        $token = [guid]::NewGuid().ToString('N')
        $pidInfo = Get-ProcessIdentity -ProcessId $PID
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $receipt = [pscustomobject]@{
            schemaVersion=1;token=$token;operation=$Operation;issueNumber=$IssueNumber;purpose=$Purpose
            executionId=$null;generation=$null;ownerRepo=$id.ownerRepo;canonicalRepoRoot=$id.canonicalRepoRoot
            repoRootHash=$id.repoRootHash;processId=$PID;processStartedAt=$pidInfo.startedAt
            status='starting';createdAt=$now;updatedAt=$now
        }
        Write-AtomicJsonFile -Path (Get-RepositoryMutationReceiptPath -RepoPath $RepoPath) -Object $receipt
        return [pscustomobject]@{acquired=$true;owned=$false;token=$token;receipt=$receipt}
    } finally { $lock.Dispose() }
}

function Set-RepositoryMutationExecution {
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$ExecutionReceipt)
    $lock = Open-RepositoryMutationLock -RepoPath $RepoPath
    if ($null -eq $lock) { throw 'repository mutation lock is busy' }
    try {
        $receipt = Get-RepositoryMutationReceipt -RepoPath $RepoPath
        if ($null -eq $receipt -or [string]$receipt.token -cne $Token) { throw 'repository mutation ownership changed' }
        $receipt.executionId=[string]$ExecutionReceipt.executionId;$receipt.generation=[int]$ExecutionReceipt.generation
        $receipt.status='worker_running';$receipt.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        Write-AtomicJsonFile -Path (Get-RepositoryMutationReceiptPath -RepoPath $RepoPath) -Object $receipt
    } finally { $lock.Dispose() }
}

function Exit-RepositoryMutation {
    param(
        [Parameter(Mandatory)][string]$RepoPath, [int]$Operation, [int]$IssueNumber,
        [string]$Token, [switch]$RequireTerminal
    )
    $lock = Open-RepositoryMutationLock -RepoPath $RepoPath
    if ($null -eq $lock) { return $false }
    try {
        $path = Get-RepositoryMutationReceiptPath -RepoPath $RepoPath
        $receipt = Get-RepositoryMutationReceipt -RepoPath $RepoPath
        if ($null -eq $receipt) { return $true }
        $owned = (-not [string]::IsNullOrWhiteSpace($Token) -and [string]$receipt.token -ceq $Token)
        if (-not $owned) { return $false }
        if ($RequireTerminal -and $receipt.executionId) {
            $execution = Get-ExecutionReceipt -Operation ([int]$receipt.operation) -IssueNumber ([int]$receipt.issueNumber) -RepoPath $RepoPath
            if ($null -ne $execution -and (Test-ExecutionStatusActive -Status ([string]$execution.status))) { return $false }
        }
        Assert-PathWithinRoot -Path $path -Root $Script:PendingDir | Out-Null
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        return $true
    } finally { $lock.Dispose() }
}

function New-PullRequestBody {
    param(
        [Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)]$Route, [Parameter(Mandatory)]$Workflow,
        [AllowEmptyString()][string]$VerificationSummary, $RemainingProblems=@()
    )
    $summary = Protect-SecretText -Text $VerificationSummary
    if ($summary.Length -gt 2000) { $summary=$summary.Substring(0,2000)+'...[truncated]' }
    $remaining = @($RemainingProblems | Select-Object -First 20 | ForEach-Object {
        $item=Protect-SecretText -Text ([string]$_)
        if($item.Length -gt 300){$item=$item.Substring(0,300)+'...[truncated]'}
        $item
    })
    if ($remaining.Count -eq 0) { $remaining=@('none reported') }
    return @"
Closes #$IssueNumber
Generated by operation-router.
- Operation: $Operation
- Worker: $($Route.worker)/$($Route.model)/$($Route.effort)
- Workflow mode: pull-request
- Base branch: $($Workflow.baseBranch)
- Base head: $($Workflow.baseHead)
- Work branch: $($Workflow.workBranch)
- Start head: $($Workflow.workStartHead)
- Final head: $($Workflow.finalHead)
- Verification: $summary
- Remaining problems: $($remaining -join '; ')
"@
}

function Ensure-DraftPullRequest {
    param(
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][int]$Operation,
        [Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)]$Route,
        [Parameter(Mandatory)]$Workflow, [string]$VerificationSummary='', $RemainingProblems=@(),
        [scriptblock]$PrProbe, [scriptblock]$IssueTitleFetcher, [switch]$ExistingOnly
    )
    $ownerRepo = Get-GitOriginOwnerRepo -Path $RepoPath
    if (-not $ownerRepo) { return [pscustomobject]@{ok=$false;status='pr_lookup_failed'} }
    $lookup = Get-PullRequestForBranch -RepoPath $RepoPath -OwnerRepo $ownerRepo -WorkBranch ([string]$Workflow.workBranch) -PrProbe $PrProbe
    if (-not $lookup.ok) { return [pscustomobject]@{ok=$false;status=$lookup.status} }
    if ($lookup.items.Count -gt 1) { return [pscustomobject]@{ok=$false;status='pr_context_mismatch'} }
    if ($lookup.items.Count -eq 1) {
        $check = Test-PullRequestContext -PullRequest $lookup.items[0] -BaseBranch ([string]$Workflow.baseBranch) `
            -WorkBranch ([string]$Workflow.workBranch) -HeadSha ([string]$Workflow.finalHead) -OwnerRepo $ownerRepo -RequireDraft
        if (-not $check.ok) { return [pscustomobject]@{ok=$false;status=$check.status;pr=$check.pr} }
        return [pscustomobject]@{ok=$true;status='pr_opened';created=$false;pr=$check.pr}
    }
    if($ExistingOnly){return [pscustomobject]@{ok=$false;status='pr_context_mismatch'}}
    $title = $null
    if ($null -ne $IssueTitleFetcher) {
        try { $title = & $IssueTitleFetcher $IssueNumber $RepoPath } catch {}
    } else {
        try {
            $out = & gh issue view $IssueNumber --repo $ownerRepo --json title -q .title 2>$null
            if ($LASTEXITCODE -eq 0) { $title=($out|Out-String).Trim() }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace([string]$title)) { $title="Issue #$IssueNumber`: operation-router change" }
    $body = New-PullRequestBody -Operation $Operation -IssueNumber $IssueNumber -Route $Route -Workflow $Workflow `
        -VerificationSummary $VerificationSummary -RemainingProblems $RemainingProblems
    $bodyPath = New-TempOrderFile -Content $body
    try {
        $ctx = [pscustomobject]@{
            repoPath=$RepoPath;ownerRepo=$ownerRepo;baseBranch=$Workflow.baseBranch;workBranch=$Workflow.workBranch
            title=(Protect-SecretText -Text ([string]$title));bodyPath=$bodyPath
        }
        $created = Invoke-PullRequestProbe -Action create -Context $ctx -PrProbe $PrProbe
        if ($null -eq $created -or -not [bool]$created.ok) {
            $status='pr_create_failed'
            if ($null -ne $created -and $created.PSObject.Properties.Name -contains 'error' -and [string]$created.error -eq 'pr_tool_unavailable'){$status='pr_tool_unavailable'}
            return [pscustomobject]@{ok=$false;status=$status}
        }
    } finally { Remove-TempOrderFile -Path $bodyPath }
    $lookup = Get-PullRequestForBranch -RepoPath $RepoPath -OwnerRepo $ownerRepo -WorkBranch ([string]$Workflow.workBranch) -PrProbe $PrProbe
    if (-not $lookup.ok) { return [pscustomobject]@{ok=$false;status=$lookup.status} }
    if ($lookup.items.Count -ne 1) { return [pscustomobject]@{ok=$false;status='pr_context_mismatch'} }
    $check = Test-PullRequestContext -PullRequest $lookup.items[0] -BaseBranch ([string]$Workflow.baseBranch) `
        -WorkBranch ([string]$Workflow.workBranch) -HeadSha ([string]$Workflow.finalHead) -OwnerRepo $ownerRepo -RequireDraft
    if (-not $check.ok) { return [pscustomobject]@{ok=$false;status=$check.status;pr=$check.pr} }
    return [pscustomobject]@{ok=$true;status='pr_opened';created=$true;pr=$check.pr}
}

function Get-DefaultPullRequestChecks {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$OwnerRepo,
        [Parameter(Mandatory)][int]$PrNumber,
        [Parameter(Mandatory)][string]$HeadSha
    )
    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ok=$false;checks=@()} }
    $ErrorActionPreference='Continue'
    Push-Location $RepoPath
    try {
        # GitHub Actions check suite의 pull_requests 목록만으로는 push 실행과 PR 실행을
        # 구분할 수 없다. 먼저 실제 pull_request workflow run을 조회해 허용 suite를 고정한다.
        $actionOut=& gh api --paginate --slurp -H 'Accept: application/vnd.github+json' `
            "repos/$OwnerRepo/actions/runs?head_sha=$HeadSha&event=pull_request&per_page=100" 2>&1
        if($LASTEXITCODE -ne 0){return [pscustomobject]@{ok=$false;checks=@()}}
        try{$actionPages=(($actionOut|Out-String)|ConvertFrom-Json)}catch{return [pscustomobject]@{ok=$false;checks=@()}}
        $pullRequestActionSuites=@{}
        foreach($page in @($actionPages)){
            if($null -eq $page -or $page.PSObject.Properties.Name -notcontains 'workflow_runs'){continue}
            foreach($run in @($page.workflow_runs)){
                $runProps=@($run.PSObject.Properties.Name)
                if(@('event','head_sha','pull_requests','check_suite_id')|Where-Object{$runProps -notcontains $_}){continue}
                if([string]$run.event -cne 'pull_request' -or [string]$run.head_sha -cne $HeadSha){continue}
                if($runProps -contains 'repository' -and $null -ne $run.repository -and
                    $run.repository.PSObject.Properties.Name -contains 'full_name' -and
                    [string]$run.repository.full_name -cne $OwnerRepo){continue}
                $linked=$false
                foreach($linkedPr in @($run.pull_requests)){
                    if($null -ne $linkedPr -and $linkedPr.PSObject.Properties.Name -contains 'number' -and
                        [int]$linkedPr.number -eq $PrNumber){$linked=$true;break}
                }
                if($linked){
                    $pullRequestActionSuites[[string][int64]$run.check_suite_id]=[pscustomobject]@{
                        runAttempt=if($runProps -contains 'run_attempt'){[int64]$run.run_attempt}else{0}
                        updatedAt=if($runProps -contains 'updated_at'){[string]$run.updated_at}else{''}
                    }
                }
            }
        }
        $suiteOut=& gh api --paginate --slurp -H 'Accept: application/vnd.github+json' "repos/$OwnerRepo/commits/$HeadSha/check-suites?per_page=100" 2>&1
        if($LASTEXITCODE -ne 0){return [pscustomobject]@{ok=$false;checks=@()}}
        try{$suitePages=(($suiteOut|Out-String)|ConvertFrom-Json)}catch{return [pscustomobject]@{ok=$false;checks=@()}}
        $suites=@()
        foreach($page in @($suitePages)){
            if($null -ne $page -and $page.PSObject.Properties.Name -contains 'check_suites'){
                $suites+=@($page.check_suites)
            }
        }
        $all=@()
        foreach($suite in $suites){
            $suiteProps=@($suite.PSObject.Properties.Name)
            if($suiteProps -notcontains 'id' -or $suiteProps -notcontains 'head_sha' -or
                [string]$suite.head_sha -cne $HeadSha -or $suiteProps -notcontains 'pull_requests'){
                continue
            }
            $linked=$false
            foreach($linkedPr in @($suite.pull_requests)){
                if($null -ne $linkedPr -and $linkedPr.PSObject.Properties.Name -contains 'number' -and
                    [int]$linkedPr.number -eq $PrNumber){
                    if($linkedPr.PSObject.Properties.Name -contains 'head' -and $null -ne $linkedPr.head -and
                        $linkedPr.head.PSObject.Properties.Name -contains 'sha' -and
                        [string]$linkedPr.head.sha -cne $HeadSha){continue}
                    $linked=$true
                    break
                }
            }
            if(-not $linked){continue}
            $suiteApp='unknown'
            if($suiteProps -contains 'app' -and $null -ne $suite.app -and
                $suite.app.PSObject.Properties.Name -contains 'slug'){$suiteApp=[string]$suite.app.slug}
            $actionRun=$null
            if($suiteApp -eq 'github-actions'){
                $suiteKey=[string][int64]$suite.id
                if(-not $pullRequestActionSuites.ContainsKey($suiteKey)){continue}
                $actionRun=$pullRequestActionSuites[$suiteKey]
            }
            $runOut=& gh api --paginate --slurp -H 'Accept: application/vnd.github+json' "repos/$OwnerRepo/check-suites/$([int64]$suite.id)/check-runs?per_page=100" 2>&1
            if($LASTEXITCODE -ne 0){return [pscustomobject]@{ok=$false;checks=@()}}
            try{$runPages=(($runOut|Out-String)|ConvertFrom-Json)}catch{return [pscustomobject]@{ok=$false;checks=@()}}
            foreach($page in @($runPages)){
                if($null -eq $page -or $page.PSObject.Properties.Name -notcontains 'check_runs'){continue}
                foreach($c in @($page.check_runs)){
                    if($c.PSObject.Properties.Name -notcontains 'head_sha' -or [string]$c.head_sha -cne $HeadSha){continue}
                    $app='unknown'
                    if($c.PSObject.Properties.Name -contains 'app' -and $null -ne $c.app -and
                        $c.app.PSObject.Properties.Name -contains 'slug'){$app=[string]$c.app.slug}
                    $updated=if($c.PSObject.Properties.Name -contains 'completed_at' -and $c.completed_at){[string]$c.completed_at}elseif(
                        $c.PSObject.Properties.Name -contains 'started_at' -and $c.started_at){[string]$c.started_at}else{''}
                    $all+=[pscustomobject]@{
                        context="$app/$([string]$c.name)";status=[string]$c.status;conclusion=[string]$c.conclusion
                        event='pull_request';prNumber=$PrNumber;headSha=$HeadSha;updatedAt=$updated
                        id=if($c.PSObject.Properties.Name -contains 'id'){[int64]$c.id}else{0}
                        runAttempt=if($null -ne $actionRun){[int64]$actionRun.runAttempt}else{0}
                        associationVerified=$true
                    }
                }
            }
        }
        # Legacy commit status는 API 응답만으로 push와 pull_request 연관성을 구분할 수 없다.
        # 존재 자체를 숨기지 않고 미확인 context로 전달해 상위 집계가 unavailable로 닫히게 한다.
        $statusOut=& gh api --paginate --slurp -H 'Accept: application/vnd.github+json' `
            "repos/$OwnerRepo/commits/$HeadSha/status?per_page=100" 2>&1
        if($LASTEXITCODE -ne 0){return [pscustomobject]@{ok=$false;checks=@()}}
        try{$statusPages=(($statusOut|Out-String)|ConvertFrom-Json)}catch{return [pscustomobject]@{ok=$false;checks=@()}}
        foreach($page in @($statusPages)){
            if($null -eq $page -or $page.PSObject.Properties.Name -notcontains 'statuses'){continue}
            foreach($statusContext in @($page.statuses)){
                $all+=[pscustomobject]@{
                    context=if($statusContext.PSObject.Properties.Name -contains 'context'){[string]$statusContext.context}else{'legacy-status'}
                    status=if($statusContext.PSObject.Properties.Name -contains 'state'){[string]$statusContext.state}else{'unknown'}
                    conclusion=$null;event='unknown';prNumber=$PrNumber;headSha=$HeadSha
                    updatedAt=if($statusContext.PSObject.Properties.Name -contains 'updated_at'){[string]$statusContext.updated_at}else{''}
                    id=if($statusContext.PSObject.Properties.Name -contains 'id'){[int64]$statusContext.id}else{0}
                    runAttempt=0;associationVerified=$false
                }
            }
        }
        return [pscustomobject]@{ok=$true;associationVerified=$true;checks=@($all)}
    } finally { Pop-Location }
}

function Get-PullRequestCiStatus {
    param(
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][int]$PrNumber,
        [Parameter(Mandatory)][string]$HeadSha, [scriptblock]$CheckLister,
        $BaseWorkflow=$null,$HeadWorkflow=$null,$WorkflowPresent=$null,
        [bool]$RequireCiWhenWorkflowPresent=$true,
        [int]$PollIntervalSeconds=-1, [int]$MaxAttempts=-1
    )
    $cfg=Get-Config
    if($PollIntervalSeconds -lt 0){$PollIntervalSeconds=[int]$cfg.ciPolling.intervalSeconds}
    if($MaxAttempts -lt 1){$MaxAttempts=[int]$cfg.ciPolling.maxAttempts}
    $basePresent=$false;$headPresent=$false;$workflowEvidence=$false
    if($null -ne $BaseWorkflow -or $null -ne $HeadWorkflow){
        if($null -eq $BaseWorkflow -or $null -eq $HeadWorkflow){return 'unavailable'}
        foreach($snapshot in @($BaseWorkflow,$HeadWorkflow)){
            if($snapshot.PSObject.Properties.Name -notcontains 'ok' -or -not [bool]$snapshot.ok -or
                $snapshot.PSObject.Properties.Name -notcontains 'exists'){return 'unavailable'}
        }
        $basePresent=[bool]$BaseWorkflow.exists;$headPresent=[bool]$HeadWorkflow.exists;$workflowEvidence=$true
        if($basePresent -and -not $headPresent){return 'required_workflow_removed'}
    } elseif($WorkflowPresent -is [bool]){
        $headPresent=[bool]$WorkflowPresent;$workflowEvidence=$true
    } else {
        return 'unavailable'
    }
    $wfPresent=($basePresent -or $headPresent)
    $owner=Get-GitOriginOwnerRepo -Path $RepoPath
    for($attempt=1;$attempt -le $MaxAttempts;$attempt++){
        try {
            $res=if($null -ne $CheckLister){& $CheckLister $RepoPath $PrNumber $HeadSha}else{
                Get-DefaultPullRequestChecks -RepoPath $RepoPath -OwnerRepo $owner -PrNumber $PrNumber -HeadSha $HeadSha
            }
        } catch { return 'unavailable' }
        if($null -eq $res -or -not [bool]$res.ok){return 'unavailable'}
        $checks=@($res.checks)
        if($checks.Count -gt 0){
            $associated=@();$associationUnknown=$false
            foreach($c in $checks){
                $props=@($c.PSObject.Properties.Name)
                if($props -contains 'associationVerified' -and -not [bool]$c.associationVerified){
                    $associationUnknown=$true
                    continue
                }
                if(@('event','prNumber','headSha','context')|Where-Object{$props -notcontains $_}){
                    $associationUnknown=$true
                    continue
                }
                if([string]$c.event -cne 'pull_request'){continue}
                if([int]$c.prNumber -ne $PrNumber -or [string]$c.headSha -cne $HeadSha){continue}
                if([string]::IsNullOrWhiteSpace([string]$c.context)){$associationUnknown=$true;continue}
                $associated+=$c
            }
            if($associationUnknown){return 'unavailable'}
            if($associated.Count -eq 0){
                if(-not $wfPresent -or -not $RequireCiWhenWorkflowPresent){return 'not-requested'}
                if($attempt -lt $MaxAttempts -and $PollIntervalSeconds -gt 0){Start-Sleep -Seconds $PollIntervalSeconds}
                continue
            }
            $latest=@()
            foreach($group in @($associated|Group-Object -Property context)){
                $current=@($group.Group|Sort-Object -Property `
                    @{Expression={
                        if($_.PSObject.Properties.Name -contains 'updatedAt' -and -not [string]::IsNullOrWhiteSpace([string]$_.updatedAt)){
                            try{return [DateTime]::Parse([string]$_.updatedAt).ToUniversalTime().Ticks}catch{}
                        }
                        return [int64]0
                    };Descending=$true},`
                    @{Expression={if($_.PSObject.Properties.Name -contains 'runAttempt'){[int64]$_.runAttempt}else{0}};Descending=$true},`
                    @{Expression={if($_.PSObject.Properties.Name -contains 'id'){[int64]$_.id}else{0}};Descending=$true})
                $latest+=$current[0]
            }
            $failure=$false;$pending=$false;$unknown=$false
            foreach($c in $latest){
                $status='';$conclusion=''
                if($c.PSObject.Properties.Name -contains 'status'){$status=([string]$c.status).ToLowerInvariant()}
                if($c.PSObject.Properties.Name -contains 'conclusion'){$conclusion=([string]$c.conclusion).ToLowerInvariant()}
                if($status -in @('queued','pending','in_progress','requested','waiting')){$pending=$true;continue}
                if($status -in @('failure','error')){$failure=$true;continue}
                if($conclusion -in @('failure','cancelled','timed_out','action_required','startup_failure','error')){$failure=$true}
                elseif($conclusion -in @('queued','pending','in_progress')){$pending=$true}
                elseif($conclusion -ne 'success'){$unknown=$true}
            }
            if($failure){return 'failure'};if($pending){return 'pending'};if($unknown){return 'unavailable'};return 'success'
        }
        if(-not $workflowEvidence){return 'unavailable'}
        if(-not $wfPresent -or -not $RequireCiWhenWorkflowPresent){return 'not-requested'}
        if($attempt -lt $MaxAttempts -and $PollIntervalSeconds -gt 0){Start-Sleep -Seconds $PollIntervalSeconds}
    }
    return 'unavailable'
}

function Resolve-PullRequestPostflight {
    param(
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)]$StartSnapshot,
        [Parameter(Mandatory)]$WorkerResult, [Parameter(Mandatory)]$Workflow,
        [Parameter(Mandatory)][int]$Operation, [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)]$Route, [scriptblock]$PrProbe, [scriptblock]$CheckLister,
        [scriptblock]$IssueTitleFetcher, [scriptblock]$RemoteHeadProbe, [switch]$ExistingPrOnly
    )
    $w=Copy-WorkflowContext -Workflow $Workflow
    $branch=Get-GitCurrentBranch -Path $RepoPath;$final=Get-GitHead -Path $RepoPath;$wt=Get-GitWorktreeStatus -Path $RepoPath
    $commits=Get-GitCommitCountSince -Path $RepoPath -SinceHead ([string]$StartSnapshot.startHead)
    $upstream=Get-GitUpstream -RepoPath $RepoPath;$remoteWork=Get-GitRemoteBranchHead -RepoPath $RepoPath -Branch ([string]$w.workBranch) -RemoteHeadProbe $RemoteHeadProbe
    $remoteBase=Get-GitRemoteBranchHead -RepoPath $RepoPath -Branch ([string]$w.baseBranch) -RemoteHeadProbe $RemoteHeadProbe
    $localBase=Get-GitRefHead -RepoPath $RepoPath -Ref "refs/heads/$($w.baseBranch)"
    $pushComplete=($remoteWork -and $final -ceq $remoteWork)
    $status=$null;$ci='not-checked';$pr=$null
    if(-not $WorkerResult.Success){$status='worker_failed'}
    elseif($commits -lt 1 -or $final -ceq [string]$StartSnapshot.startHead){$status='no_commit'}
    elseif(-not $wt.Clean){$status='dirty_worktree'}
    elseif($branch -cne [string]$w.workBranch){$status='work_branch_mismatch'}
    elseif($localBase -cne [string]$w.baseLocalHead){$status='local_base_ref_changed'}
    elseif($upstream -cne [string]$w.remoteWorkBranch){$status='work_branch_upstream_mismatch'}
    elseif(-not $pushComplete){$status='work_branch_push_incomplete'}
    elseif(-not $remoteBase){$status='remote_sync_unavailable'}
    elseif($remoteBase -and (Test-GitCommitAncestor -RepoPath $RepoPath -Ancestor $final -Descendant $remoteBase)){$status='base_branch_touched'}
    $w.finalHead=$final
    $w.headWorkflow=Get-GitWorkflowSnapshot -RepoPath $RepoPath -Ref $final
    $w.baseAdvanced=($remoteBase -and $remoteBase -cne [string]$w.baseRemoteHead -and -not (Test-GitCommitAncestor -RepoPath $RepoPath -Ancestor $final -Descendant $remoteBase))
    if($null -eq $status -and ($w.PSObject.Properties.Name -notcontains 'baseWorkflow' -or -not [bool]$w.baseWorkflow.ok -or
        -not [bool]$w.headWorkflow.ok)){$status='pr_ci_unavailable'}
    if($null -eq $status -and [bool]$w.baseWorkflow.exists -and -not [bool]$w.headWorkflow.exists){
        $status='required_workflow_removed';$ci='required_workflow_removed'
    }
    if($null -eq $status){
        $boundary=@();if($StartSnapshot.PSObject.Properties.Name -contains 'boundaryWatch'){$boundary=@(Test-RepoBoundaryViolation -BeforeSnapshot $StartSnapshot.boundaryWatch)}
        if($boundary.Count -gt 0){$status='repo_boundary_violation'}
    }
    if($null -eq $status){
        $summary='not reported'
        if($WorkerResult.PSObject.Properties.Name -contains 'WorkerReportedVerification' -and
            -not [string]::IsNullOrWhiteSpace([string]$WorkerResult.WorkerReportedVerification)){
            $summary=[string]$WorkerResult.WorkerReportedVerification
        }
        $workerProblems=@()
        if($WorkerResult.PSObject.Properties.Name -contains 'WorkerRemainingProblems'){
            $workerProblems=@($WorkerResult.WorkerRemainingProblems)
        }
        $ensured=Ensure-DraftPullRequest -RepoPath $RepoPath -Operation $Operation -IssueNumber $IssueNumber -Route $Route -Workflow $w `
            -VerificationSummary $summary -RemainingProblems $workerProblems -PrProbe $PrProbe -IssueTitleFetcher $IssueTitleFetcher -ExistingOnly:$ExistingPrOnly
        if(-not $ensured.ok){$status=[string]$ensured.status}else{
            $pr=$ensured.pr;$w.pr=$pr
            $ci=Get-PullRequestCiStatus -RepoPath $RepoPath -PrNumber ([int]$pr.number) -HeadSha $final -CheckLister $CheckLister `
                -BaseWorkflow $w.baseWorkflow -HeadWorkflow $w.headWorkflow `
                -RequireCiWhenWorkflowPresent (Get-WorkflowRequireCi -Workflow $w)
            if($ci -eq 'required_workflow_removed'){$status='required_workflow_removed'}elseif($ci -eq 'failure'){$status='pr_ci_failed'}elseif($ci -eq 'pending'){$status='pr_ci_pending'}elseif($ci -eq 'unavailable'){$status='pr_ci_unavailable'}else{$status='pr_opened'}
        }
    }
    return [pscustomobject]@{
        status=$status;branch=$branch;startHead=$StartSnapshot.startHead;finalHead=$final;headChanged=($final -cne [string]$StartSnapshot.startHead)
        commitCount=[int]$commits;worktreeClean=[bool]$wt.Clean;aheadBehindAvailable=$true;ahead=$null;behind=$null
        pushComplete=[bool]$pushComplete;ciStatus=$ci;workerExitCode=$WorkerResult.ExitCode;workflow=$w
        baseAdvanced=[bool]$w.baseAdvanced;pr=$pr
    }
}

function Resolve-WorkflowPostflight {
    param(
        [Parameter(Mandatory)][string]$RepoPath,[Parameter(Mandatory)]$StartSnapshot,[Parameter(Mandatory)]$WorkerResult,
        [Parameter(Mandatory)]$Workflow,[Parameter(Mandatory)][int]$Operation,[Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)]$Route,[scriptblock]$CiProbe,[scriptblock]$PrProbe,[scriptblock]$CheckLister,
        [scriptblock]$IssueTitleFetcher,[scriptblock]$RemoteHeadProbe,[switch]$ExistingPrOnly
    )
    if([string]$Workflow.mode -eq 'pull-request'){
        return Resolve-PullRequestPostflight -RepoPath $RepoPath -StartSnapshot $StartSnapshot -WorkerResult $WorkerResult -Workflow $Workflow `
            -Operation $Operation -IssueNumber $IssueNumber -Route $Route -PrProbe $PrProbe -CheckLister $CheckLister `
            -IssueTitleFetcher $IssueTitleFetcher -RemoteHeadProbe $RemoteHeadProbe -ExistingPrOnly:$ExistingPrOnly
    }
    $direct = Resolve-Postflight -RepoPath $RepoPath -StartSnapshot $StartSnapshot -WorkerResult $WorkerResult -DeclaredNoCodeChange:$false -CiProbe $CiProbe
    Add-Member -InputObject $direct -NotePropertyName workflow -NotePropertyValue (Copy-WorkflowContext -Workflow $Workflow) -Force
    return $direct
}

function Resolve-PullRequestRecoveryPostflight {
    param(
        [Parameter(Mandatory)][string]$RepoPath,[Parameter(Mandatory)]$StartSnapshot,[Parameter(Mandatory)]$Workflow,
        [scriptblock]$PrProbe,[scriptblock]$CheckLister,[scriptblock]$RemoteHeadProbe
    )
    $w=Copy-WorkflowContext -Workflow $Workflow;$branch=Get-GitCurrentBranch -Path $RepoPath;$head=Get-GitHead -Path $RepoPath;$wt=Get-GitWorktreeStatus -Path $RepoPath
    $commits=Get-GitCommitCountSince -Path $RepoPath -SinceHead ([string]$StartSnapshot.startHead)
    $remote=Get-GitRemoteBranchHead -RepoPath $RepoPath -Branch ([string]$w.workBranch) -RemoteHeadProbe $RemoteHeadProbe
    $remoteBase=Get-GitRemoteBranchHead -RepoPath $RepoPath -Branch ([string]$w.baseBranch) -RemoteHeadProbe $RemoteHeadProbe
    $localBase=Get-GitRefHead -RepoPath $RepoPath -Ref "refs/heads/$($w.baseBranch)"
    $upstream=Get-GitUpstream -RepoPath $RepoPath
    $baseUntouched=($remoteBase -and -not (Test-GitCommitAncestor -RepoPath $RepoPath -Ancestor $head -Descendant $remoteBase))
    $push=($remote -and $head -ceq $remote);$ci='not-checked';$status='recovered_pr_context_mismatch'
    if($commits -gt 0 -and $wt.Clean -and $branch -ceq [string]$w.workBranch -and $push -and
        $localBase -ceq [string]$w.baseLocalHead -and $upstream -ceq [string]$w.remoteWorkBranch -and $baseUntouched){
        $lookup=Get-PullRequestForBranch -RepoPath $RepoPath -OwnerRepo (Get-GitOriginOwnerRepo -Path $RepoPath) -WorkBranch ([string]$w.workBranch) -PrProbe $PrProbe
        if($lookup.ok -and $lookup.items.Count -eq 1){
            $checked=Test-PullRequestContext -PullRequest $lookup.items[0] -BaseBranch ([string]$w.baseBranch) -WorkBranch ([string]$w.workBranch) -HeadSha $head `
                -OwnerRepo (Get-GitOriginOwnerRepo -Path $RepoPath) -RequireDraft
            if($checked.ok){
                $w.pr=$checked.pr;$w.finalHead=$head;$w.headWorkflow=Get-GitWorkflowSnapshot -RepoPath $RepoPath -Ref $head
                $ci=Get-PullRequestCiStatus -RepoPath $RepoPath -PrNumber ([int]$checked.pr.number) -HeadSha $head -CheckLister $CheckLister `
                    -BaseWorkflow $(if($w.PSObject.Properties.Name -contains 'baseWorkflow'){$w.baseWorkflow}else{$null}) -HeadWorkflow $w.headWorkflow `
                    -RequireCiWhenWorkflowPresent (Get-WorkflowRequireCi -Workflow $w)
                if($ci -eq 'required_workflow_removed'){$status='recovered_pr_context_mismatch'}elseif($ci -eq 'pending'){$status='recovered_pr_ci_pending_unverified'}elseif($ci -eq 'failure'){$status='recovered_pr_ci_failed_unverified'}elseif($ci -eq 'unavailable'){$status='recovered_pr_ci_unavailable_unverified'}else{$status='recovered_pr_commit_unverified'}
            }
        }
    }
    return [pscustomobject]@{status=$status;branch=$branch;startHead=$StartSnapshot.startHead;finalHead=$head;headChanged=($head -cne [string]$StartSnapshot.startHead)
        commitCount=[int]$commits;worktreeClean=[bool]$wt.Clean;aheadBehindAvailable=$true;ahead=$null;behind=$null;pushComplete=[bool]$push
        ciStatus=$ci;workerExitCode=$null;workflow=$w}
}

function Test-PullRequestReviewContext {
    param([Parameter(Mandatory)]$RunReceipt,[Parameter(Mandatory)][string]$RepoPath,[scriptblock]$PrProbe)
    $w=Get-ReceiptWorkflowContext -Receipt $RunReceipt
    if([string]$w.mode -ne 'pull-request'){return [pscustomobject]@{ok=$true;status='ok';workflow=$w}}
    if((Get-GitCurrentBranch -Path $RepoPath) -cne [string]$w.workBranch){return [pscustomobject]@{ok=$false;status='work_branch_mismatch'}}
    if((Get-GitHead -Path $RepoPath) -cne [string]$RunReceipt.finalHead){return [pscustomobject]@{ok=$false;status='review_pr_head_mismatch'}}
    if(-not (Get-GitWorktreeStatus -Path $RepoPath).Clean){return [pscustomobject]@{ok=$false;status='dirty_worktree'}}
    $lookup=Get-PullRequestForBranch -RepoPath $RepoPath -OwnerRepo (Get-GitOriginOwnerRepo -Path $RepoPath) -WorkBranch ([string]$w.workBranch) -PrProbe $PrProbe
    if(-not $lookup.ok -or $lookup.items.Count -ne 1){return [pscustomobject]@{ok=$false;status='pr_context_mismatch'}}
    $check=Test-PullRequestContext -PullRequest $lookup.items[0] -BaseBranch ([string]$w.baseBranch) -WorkBranch ([string]$w.workBranch) -HeadSha ([string]$RunReceipt.finalHead) `
        -OwnerRepo (Get-GitOriginOwnerRepo -Path $RepoPath) -RequireDraft
    if(-not $check.ok){return [pscustomobject]@{ok=$false;status=$check.status}}
    if($w.PSObject.Properties.Name -notcontains 'pr' -or $null -eq $w.pr -or
        [int]$w.pr.number -ne [int]$check.pr.number){
        return [pscustomobject]@{ok=$false;status='pr_context_mismatch'}
    }
    $w.pr=$check.pr
    return [pscustomobject]@{ok=$true;status='ok';workflow=$w;pr=$check.pr}
}

function Get-WorkflowMergeReadiness {
    param(
        [Parameter(Mandatory)][string]$RepoPath,[Parameter(Mandatory)]$Receipt,[Parameter(Mandatory)][string]$ReviewVerdict,
        [scriptblock]$PrProbe,[scriptblock]$CheckLister,[scriptblock]$RemoteHeadProbe
    )
    $w=Get-ReceiptWorkflowContext -Receipt $Receipt
    if([string]$w.mode -ne 'pull-request'){return [pscustomobject]@{ready=$false;status='direct_main_no_merge_ready';workflow=$w}}
    if($ReviewVerdict -ne 'PASS'){return [pscustomobject]@{ready=$false;status='review_required';workflow=$w}}
    $eligibleStatuses=@('pr_opened','pr_ci_pending','pr_ci_unavailable','repair_completed_review_pending','repair_pr_ci_pending','repair_pr_ci_unavailable')
    if($Receipt.PSObject.Properties.Name -notcontains 'status' -or [string]$Receipt.status -notin $eligibleStatuses){
        return [pscustomobject]@{ready=$false;status=if($Receipt.PSObject.Properties.Name -contains 'status'){[string]$Receipt.status}else{'workflow_receipt_incomplete'};workflow=$w}
    }
    foreach($required in @('resultEnvelopePresent','interrupted','localVerificationComplete','verificationProvenance','artifactSanitizationStatus','artifactRetentionStatus')){
        if($Receipt.PSObject.Properties.Name -notcontains $required){return [pscustomobject]@{ready=$false;status='workflow_receipt_incomplete';workflow=$w}}
    }
    if(-not [bool]$Receipt.resultEnvelopePresent -or [bool]$Receipt.interrupted -or -not [bool]$Receipt.localVerificationComplete){
        return [pscustomobject]@{ready=$false;status='worker_result_unverified';workflow=$w}
    }
    if([string]$Receipt.verificationProvenance -notin @(
        'valid_worker_result_envelope','valid_worker_result_envelope_recovered_postflight',
        'valid_repair_worker_result','valid_claude_completion_report')){
        return [pscustomobject]@{ready=$false;status='worker_result_unverified';workflow=$w}
    }
    if($Receipt.PSObject.Properties.Name -contains 'workerRemainingProblems' -and
        @($Receipt.workerRemainingProblems|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)}).Count -gt 0){
        return [pscustomobject]@{ready=$false;status='worker_reported_remaining_problems';workflow=$w}
    }
    if([string]$Receipt.artifactSanitizationStatus -notin @('completed','not-applicable')){
        return [pscustomobject]@{ready=$false;status='artifact_sanitization_failed';workflow=$w}
    }
    if([string]$Receipt.artifactRetentionStatus -notin @('completed','not-applicable')){
        return [pscustomobject]@{ready=$false;status='artifact_retention_failed';workflow=$w}
    }
    if($Receipt.PSObject.Properties.Name -contains 'postflight' -and $null -ne $Receipt.postflight){
        if($Receipt.postflight.PSObject.Properties.Name -contains 'pushComplete' -and -not [bool]$Receipt.postflight.pushComplete){
            return [pscustomobject]@{ready=$false;status='work_branch_push_incomplete';workflow=$w}
        }
    }
    if(-not (Get-GitWorktreeStatus -Path $RepoPath).Clean){return [pscustomobject]@{ready=$false;status='dirty_worktree';workflow=$w}}
    $head=Get-GitHead -Path $RepoPath
    if((Get-GitCurrentBranch -Path $RepoPath) -cne [string]$w.workBranch -or $head -cne [string]$Receipt.finalHead){return [pscustomobject]@{ready=$false;status='work_branch_mismatch';workflow=$w}}
    if((Get-GitRefHead -RepoPath $RepoPath -Ref "refs/heads/$($w.baseBranch)") -cne [string]$w.baseLocalHead){
        return [pscustomobject]@{ready=$false;status='local_base_ref_changed';workflow=$w}
    }
    if((Get-GitUpstream -RepoPath $RepoPath) -cne [string]$w.remoteWorkBranch){
        return [pscustomobject]@{ready=$false;status='work_branch_upstream_mismatch';workflow=$w}
    }
    $remoteHead=Get-GitRemoteBranchHead -RepoPath $RepoPath -Branch ([string]$w.workBranch) -RemoteHeadProbe $RemoteHeadProbe
    if(-not $remoteHead -or $remoteHead -cne $head){return [pscustomobject]@{ready=$false;status='work_branch_push_incomplete';workflow=$w}}
    $remoteBase=Get-GitRemoteBranchHead -RepoPath $RepoPath -Branch ([string]$w.baseBranch) -RemoteHeadProbe $RemoteHeadProbe
    if(-not $remoteBase){return [pscustomobject]@{ready=$false;status='remote_sync_unavailable';workflow=$w}}
    if(Test-GitCommitAncestor -RepoPath $RepoPath -Ancestor $head -Descendant $remoteBase){
        return [pscustomobject]@{ready=$false;status='base_branch_touched';workflow=$w}
    }
    $w.baseAdvanced=($remoteBase -cne [string]$w.baseRemoteHead)
    $w.headWorkflow=Get-GitWorkflowSnapshot -RepoPath $RepoPath -Ref $head
    if($w.PSObject.Properties.Name -notcontains 'baseWorkflow' -or -not [bool]$w.baseWorkflow.ok -or -not [bool]$w.headWorkflow.ok){
        return [pscustomobject]@{ready=$false;status='pr_ci_unavailable';ciStatus='unavailable';workflow=$w}
    }
    if([bool]$w.baseWorkflow.exists -and -not [bool]$w.headWorkflow.exists){
        return [pscustomobject]@{ready=$false;status='required_workflow_removed';ciStatus='required_workflow_removed';workflow=$w}
    }
    $lookup=Get-PullRequestForBranch -RepoPath $RepoPath -OwnerRepo (Get-GitOriginOwnerRepo -Path $RepoPath) -WorkBranch ([string]$w.workBranch) -PrProbe $PrProbe
    if(-not $lookup.ok -or $lookup.items.Count -ne 1){return [pscustomobject]@{ready=$false;status='pr_context_mismatch';workflow=$w}}
    $check=Test-PullRequestContext -PullRequest $lookup.items[0] -BaseBranch ([string]$w.baseBranch) -WorkBranch ([string]$w.workBranch) -HeadSha $head `
        -OwnerRepo (Get-GitOriginOwnerRepo -Path $RepoPath) -RequireDraft
    if(-not $check.ok){return [pscustomobject]@{ready=$false;status=$check.status;workflow=$w}}
    $w.pr=$check.pr
    $ci=Get-PullRequestCiStatus -RepoPath $RepoPath -PrNumber ([int]$check.pr.number) -HeadSha $head -CheckLister $CheckLister `
        -BaseWorkflow $w.baseWorkflow -HeadWorkflow $w.headWorkflow `
        -RequireCiWhenWorkflowPresent (Get-WorkflowRequireCi -Workflow $w)
    if($ci -eq 'required_workflow_removed'){return [pscustomobject]@{ready=$false;status='required_workflow_removed';ciStatus=$ci;workflow=$w}}
    if($ci -eq 'pending'){return [pscustomobject]@{ready=$false;status='pr_ci_pending';ciStatus=$ci;workflow=$w}}
    if($ci -eq 'failure'){return [pscustomobject]@{ready=$false;status='pr_ci_failed';ciStatus=$ci;workflow=$w}}
    if($ci -eq 'unavailable'){return [pscustomobject]@{ready=$false;status='pr_ci_unavailable';ciStatus=$ci;workflow=$w}}
    return [pscustomobject]@{ready=$true;status='ready';ciStatus=$ci;workflow=$w}
}
