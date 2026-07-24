# operation-router mock 테스트 (Pester 3.4 호환). 실제 프로젝트 미수정, 유료 호출 없음.
# tests/run-tests.ps1 실행기가 격리 경로를 주입하며, 이 파일은 source-tree 테스트 본문만 담는다.

param(
    [Parameter(Mandatory)][string]$RootPath,
    [Parameter(Mandatory)][string]$SkillsPath,
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$LogRoot,
    [Parameter(Mandatory)][string]$TestWorkRoot,
    [switch]$InstalledIntegration
)

Set-StrictMode -Version Latest

$RequestedRootPath = $RootPath
$RequestedSkillsPath = $SkillsPath
$RequestedStatePath = $StatePath
$RequestedLogRoot = $LogRoot
$RequestedTestWorkRoot = $TestWorkRoot

$RouterRoot = [System.IO.Path]::GetFullPath($RequestedRootPath).TrimEnd('\','/')
$ScriptsDir = Join-Path $RouterRoot 'scripts'
$LauncherPath = Join-Path $RouterRoot 'operation-router.cmd'
$GitRoot = Split-Path -Parent (Split-Path -Parent (Get-Command git -ErrorAction Stop).Source)
$GitBashPath = Join-Path $GitRoot 'bin\bash.exe'
$SkillsRoot = [System.IO.Path]::GetFullPath($RequestedSkillsPath).TrimEnd('\','/')
. (Join-Path $ScriptsDir 'common.ps1')
. (Join-Path $ScriptsDir 'resolve-route.ps1')
. (Join-Path $ScriptsDir 'prepare-operation.ps1')
. (Join-Path $ScriptsDir 'invoke-grok.ps1')
. (Join-Path $ScriptsDir 'invoke-gpt.ps1')
. (Join-Path $ScriptsDir 'postflight.ps1')
. (Join-Path $ScriptsDir 'run-operation.ps1')

$actualUsagePath = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude\operation-router\state\usage-state.json'))
$actualLogRoot = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude\operation-router\logs')).TrimEnd('\','/')
$actualSkillsRoot = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude\skills')).TrimEnd('\','/')
$resolvedStatePath = [System.IO.Path]::GetFullPath($RequestedStatePath)
$resolvedLogRoot = [System.IO.Path]::GetFullPath($RequestedLogRoot).TrimEnd('\','/')
if ($resolvedStatePath.Equals($actualUsagePath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source-tree tests refuse to read or write the real user usage-state.json.'
}
if ($resolvedLogRoot.Equals($actualLogRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source-tree tests refuse to use the real runtime log root.'
}
if (-not $InstalledIntegration -and $SkillsRoot.Equals($actualSkillsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installed Skill inspection requires -InstalledIntegration.'
}

$Script:RuntimeRoot = $RouterRoot
$Script:ConfigDir = Join-Path $RouterRoot 'config'
$Script:ConfigPath = Join-Path $TestWorkRoot 'config.direct-main.json'
$testConfig = Get-Content -LiteralPath (Join-Path $Script:ConfigDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$testConfig.gitWorkflow.mode = 'direct-main'
$testConfig.gitWorkflow.createDraftPullRequest = $false
$testConfig.gitWorkflow.fetchBeforeRun = $false
[System.IO.File]::WriteAllText($Script:ConfigPath,($testConfig|ConvertTo-Json -Depth 30),(New-Object System.Text.UTF8Encoding($false)))
$Script:StateDir = Split-Path -Parent $resolvedStatePath
$Script:UsageStatePath = $resolvedStatePath
$Script:PendingDir = Join-Path $Script:StateDir 'pending'
$Script:DoctorReportPath = Join-Path $Script:StateDir 'doctor-report.json'
$Script:LogRoot = $resolvedLogRoot
$Script:RuntimeLogDir = Join-Path $Script:LogRoot 'runtime'
$Script:TestLogRoot = Join-Path $Script:LogRoot 'tests'
$Script:TestLogDir = Join-Path $Script:TestLogRoot ('test-run-' + [guid]::NewGuid().ToString('N'))
$Script:RouterLogScope = 'test'
$TestWorkRoot = [System.IO.Path]::GetFullPath($RequestedTestWorkRoot).TrimEnd('\','/')
$Script:TempDir = Join-Path $TestWorkRoot 'temp'

$fixtureState = Join-Path $RouterRoot 'tests\fixtures\usage-state.initial.json'
if (-not (Test-Path -LiteralPath $fixtureState)) { throw "Missing state fixture: $fixtureState" }
New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
Copy-Item -LiteralPath $fixtureState -Destination $Script:UsageStatePath -Force
Initialize-RuntimeDirs
$cfg = Get-Config

function GS($s,$p){ [pscustomobject]@{ status=$s; percent=$p } }

function Get-TestFileSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -File | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name=$_.Name; Length=$_.Length; SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
}

function Convert-SnapshotToStableJson {
    param([Parameter(Mandatory)]$Snapshot)
    return (@($Snapshot) | ConvertTo-Json -Depth 4 -Compress)
}

function New-FakeRepo {
    param([switch]$WithRemote)
    $p = Join-Path $env:TEMP ("rr-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    Push-Location $p
    git init -q; git config user.email t@t.com; git config user.name t
    "x" | Out-File a.txt -Encoding utf8; git add .; git commit -q -m init | Out-Null; git branch -M main
    if ($WithRemote) {
        $rp = Join-Path $env:TEMP ("rrm-" + [guid]::NewGuid().ToString('N') + '.git')
        git init -q --bare $rp
        git remote add origin $rp
        git push -q origin main
        git branch --set-upstream-to=origin/main main *>$null
    }
    Pop-Location
    return $p
}
function Get-SkillFrontmatter {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($raw -notmatch '(?s)^﻿?---\r?\n(.*?)\r?\n---') { throw "no frontmatter: $Path" }
    $fm = $Matches[1]; $h = @{}
    foreach ($line in ($fm -split "`n")) {
        if ($line -match '^\s*([a-zA-Z0-9_\-]+):\s*(.*?)\s*$') { $h[$Matches[1]] = $Matches[2].Trim() }
    }
    return $h
}
$issue = { param($n,$p) "Do the thing verbatim body." }
$ciNone = { param($p) 'not-requested' }

function Set-TestGitWorkflow {
    param([Parameter(Mandatory)][ValidateSet('direct-main','pull-request')][string]$Mode)
    $source=Join-Path $Script:ConfigDir 'config.json'
    $config=Get-Content -LiteralPath $source -Raw -Encoding UTF8|ConvertFrom-Json
    $config.gitWorkflow.mode=$Mode
    if($Mode -eq 'direct-main'){
        $config.gitWorkflow.createDraftPullRequest=$false
        $config.gitWorkflow.fetchBeforeRun=$false
    } else {
        $config.gitWorkflow.createDraftPullRequest=$true
        $config.gitWorkflow.fetchBeforeRun=$true
    }
    [System.IO.File]::WriteAllText($Script:ConfigPath,($config|ConvertTo-Json -Depth 30),(New-Object System.Text.UTF8Encoding($false)))
}

function New-PrFakeRepo {
    param([switch]$WithWorkflow)
    $root=Join-Path $env:TEMP ('operation-router-pr-'+[guid]::NewGuid().ToString('N'))
    $repo=Join-Path $root 'work'
    $remote=Join-Path $root 'owner\repo.git'
    New-Item -ItemType Directory -Path $repo,(Split-Path -Parent $remote) -Force|Out-Null
    git init -q --bare $remote
    Push-Location $repo
    try {
        git init -q
        git config user.email t@t.com
        git config user.name t
        'base'|Set-Content -LiteralPath a.txt -Encoding UTF8
        if($WithWorkflow){
            New-Item -ItemType Directory -Path '.github\workflows' -Force|Out-Null
            "name: ci`non: [pull_request]`njobs: {}"|Set-Content -LiteralPath '.github\workflows\ci.yml' -Encoding UTF8
        }
        git add .
        git commit -q -m init
        git branch -M main
        $remoteUri=([System.Uri]::new($remote)).AbsoluteUri
        git remote add origin $remoteUri
        git push -q origin main
        git --git-dir=$remote symbolic-ref HEAD refs/heads/main
        git branch --set-upstream-to=origin/main main *>$null
    } finally {Pop-Location}
    return [pscustomobject]@{Root=$root;Repo=$repo;Remote=$remote}
}

function Remove-PrFakeRepo {
    param([Parameter(Mandatory)]$Fixture)
    $root=[System.IO.Path]::GetFullPath([string]$Fixture.Root)
    $temp=[System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/')+[System.IO.Path]::DirectorySeparatorChar
    if(-not $root.StartsWith($temp,[System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $root) -notmatch '^operation-router-pr-[a-f0-9]{32}$'){
        throw "unsafe PR fixture cleanup: $root"
    }
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}

function New-TestPullRequestProbe {
    param([bool]$AutoAdvanceHead=$true)
    $state=[pscustomobject]@{
        Items=@();CreateCalls=0;ReadyCalls=0;LookupCalls=0;Body=$null;BodyPath=$null
        BodyPathExistedDuringCreate=$false;Actions=@();AutoAdvanceHead=$AutoAdvanceHead
        CreateFailure=$false;ReadyFailure=$false
    }
    $probe={
        param($Action,$Context)
        $state.Actions=@($state.Actions)+@($Action)
        if($Action -eq 'lookup'){
            $state.LookupCalls++
            if($state.AutoAdvanceHead -and @($state.Items).Count -eq 1){
                $head=(& git -C ([string]$Context.repoPath) rev-parse "refs/remotes/origin/$([string]$Context.workBranch)" 2>$null|Out-String).Trim()
                if($head){$state.Items[0].headSha=$head}
            }
            return [pscustomobject]@{ok=$true;items=@($state.Items)}
        }
        if($Action -eq 'create'){
            $state.CreateCalls++
            $state.BodyPath=[string]$Context.bodyPath
            $state.BodyPathExistedDuringCreate=Test-Path -LiteralPath $state.BodyPath
            if($state.BodyPathExistedDuringCreate){$state.Body=Get-Content -LiteralPath $state.BodyPath -Raw -Encoding UTF8}
            if($state.CreateFailure){return [pscustomobject]@{ok=$false;error='pr_create_failed';items=@()}}
            $head=(& git -C ([string]$Context.repoPath) rev-parse HEAD|Out-String).Trim()
            $state.Items=@([pscustomobject]@{number=42;url='https://example.invalid/pr/42';state='OPEN';draft=$true
                baseBranch=[string]$Context.baseBranch;headBranch=[string]$Context.workBranch;headSha=$head
                headRepository=[string]$Context.ownerRepo;merged=$false})
            return [pscustomobject]@{ok=$true;url='https://example.invalid/pr/42';items=@()}
        }
        $state.ReadyCalls++
        if($state.ReadyFailure){return [pscustomobject]@{ok=$false;error='pr_ready_failed'}}
        if(@($state.Items).Count -eq 1){$state.Items[0].draft=$false}
        return [pscustomobject]@{ok=$true}
    }.GetNewClosure()
    return [pscustomobject]@{State=$state;Probe=$probe}
}

function New-PrCiCheck {
    param(
        [Parameter(Mandatory)][int]$PrNumber,
        [Parameter(Mandatory)][string]$HeadSha,
        [string]$Status='completed',
        [AllowNull()][string]$Conclusion='success',
        [string]$Context='windows/source-tree',
        [string]$Event='pull_request',
        [int64]$Id=1,
        [string]$UpdatedAt='2026-07-23T00:00:00Z'
    )
    return [pscustomobject]@{
        event=$Event;prNumber=$PrNumber;headSha=$HeadSha;context=$Context
        status=$Status;conclusion=$Conclusion;id=$Id;updatedAt=$UpdatedAt
    }
}

function New-PrWorker {
    param([ValidateSet('success','dirty','switch-main','main-push','no-commit','failed')][string]$Mode='success')
    $workerMode=$Mode
    return {
        param($Route,$Repo,$Prompt)
        if($workerMode -eq 'failed'){return [pscustomobject]@{ExitCode=1;Success=$false;QuotaExhausted=$false;Output='worker failed'}}
        Push-Location $Repo
        try {
            if($workerMode -eq 'no-commit'){return [pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;Output='no change'}}
            $assigned=(git branch --show-current).Trim()
            "change-$workerMode"|Set-Content -LiteralPath "change-$([guid]::NewGuid().ToString('N')).txt" -Encoding UTF8
            git add .
            git commit -q -m "fixture $workerMode"
            if($workerMode -eq 'switch-main'){
                git switch -q main
                'wrong branch'|Set-Content -LiteralPath wrong-branch.txt -Encoding UTF8
                git add wrong-branch.txt
                git commit -q -m 'wrong branch'
                git push -q -u origin "HEAD:$assigned"
            } else {
                git push -q -u origin HEAD
                if($workerMode -eq 'main-push'){git push -q origin HEAD:main}
            }
            if($workerMode -eq 'dirty'){'dirty'|Set-Content -LiteralPath dirty.txt -Encoding UTF8}
            return [pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;ErrorClass='none'
                Output='fixture tests passed';WorkerReportedVerification='fixture: 1 passed';LocalVerificationComplete=$true}
        } finally {Pop-Location}
    }.GetNewClosure()
}

function New-ClaudeImplPush {
    param([Parameter(Mandatory)][int]$Operation,[Parameter(Mandatory)][int]$IssueNumber)
    $op=$Operation;$issueNo=$IssueNumber
    return {
        param($repo,$order,$target)
        Push-Location $repo
        try {
            'y'|Out-File b.txt -Encoding utf8
            git add .
            git commit -q -m b
            git push -q origin main
            $head=(git rev-parse HEAD).Trim()
            $branch=(git branch --show-current).Trim()
        } finally {Pop-Location}
        [pscustomobject]@{
            Success=$true;ExitCode=0
            CompletionReport=[pscustomobject]@{
                schemaVersion=1;operation=$op;issueNumber=$issueNo;head=$head;workBranch=$branch
                localVerificationComplete=$true;verification='fixture tests passed: 1';remainingProblems=@()
            }
        }
    }.GetNewClosure()
}

function Write-TestClaudeCompletionReport {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Operation,
        [Parameter(Mandatory)][int]$IssueNumber,
        [string]$Head,
        [string]$WorkBranch,
        [bool]$LocalVerificationComplete=$true,
        $RemainingProblems=@(),
        [string]$Verification='fixture tests passed: 1'
    )
    if([string]::IsNullOrWhiteSpace($Head)){$Head=Get-GitHead -Path $Repo}
    if([string]::IsNullOrWhiteSpace($WorkBranch)){$WorkBranch=Get-GitCurrentBranch -Path $Repo}
    $report=[ordered]@{
        schemaVersion=1;operation=$Operation;issueNumber=$IssueNumber;head=$Head;workBranch=$WorkBranch
        localVerificationComplete=$LocalVerificationComplete;verification=$Verification
        remainingProblems=@($RemainingProblems)
    }
    $path=Get-ClaudeCompletionReportPath -Operation $Operation -IssueNumber $IssueNumber -RepoPath $Repo
    [System.IO.File]::WriteAllText($path,($report|ConvertTo-Json -Depth 10),(New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function New-ClaudePrPostflightFixture {
    param([Parameter(Mandatory)][int]$IssueNumber)
    Set-TestGitWorkflow -Mode pull-request
    $fixture=New-PrFakeRepo
    $probe=New-TestPullRequestProbe
    $pre=Initialize-GitWorkflowRun -RepoPath $fixture.Repo -IssueNumber $IssueNumber -Config (Get-Config) -PrProbe $probe.Probe
    if(-not $pre.ok){throw "Claude PR fixture preflight failed: $($pre.reason)"}
    Save-PendingSnapshot -Operation 2 -IssueNumber $IssueNumber -Snapshot $pre.snapshot -Kind logic -RepoPath $fixture.Repo -Workflow $pre.workflow|Out-Null
    Push-Location $fixture.Repo
    try {
        "claude-$IssueNumber"|Set-Content -LiteralPath "claude-$IssueNumber.txt" -Encoding UTF8
        git add .
        git commit -q -m "claude $IssueNumber"
        git push -q -u origin HEAD
    } finally {Pop-Location}
    return [pscustomobject]@{Fixture=$fixture;Probe=$probe;Preflight=$pre}
}

function New-PrMergeFixture {
    param([int]$IssueNumber=900,[int]$Operation=2)
    Set-TestGitWorkflow -Mode pull-request
    $fixture=New-PrFakeRepo
    $probe=New-TestPullRequestProbe
    $config=Get-Config
    $pre=Initialize-GitWorkflowRun -RepoPath $fixture.Repo -IssueNumber $IssueNumber -Config $config -PrProbe $probe.Probe
    if(-not $pre.ok){throw "merge fixture preflight failed: $($pre.reason)"}
    $workflow=Copy-WorkflowContext -Workflow $pre.workflow
    Add-Member -InputObject $workflow -NotePropertyName issueNumber -NotePropertyValue $IssueNumber -Force
    Push-Location $fixture.Repo
    try {
        'ready'|Set-Content -LiteralPath ready.txt -Encoding UTF8
        git add ready.txt
        git commit -q -m ready
        git push -q -u origin HEAD
    } finally {Pop-Location}
    $workflow.finalHead=Get-GitHead -Path $fixture.Repo
    $probe.State.Items=@([pscustomobject]@{number=42;url='https://example.invalid/pr/42';state='OPEN';draft=$true
        baseBranch=$workflow.baseBranch;headBranch=$workflow.workBranch;headSha=$workflow.finalHead
        headRepository='owner/repo';merged=$false})
    $workflow.pr=$probe.State.Items[0]
    $pf=[pscustomobject]@{status='pr_opened';branch=$workflow.workBranch;startHead=$pre.snapshot.startHead;finalHead=$workflow.finalHead
        headChanged=$true;commitCount=1;worktreeClean=$true;aheadBehindAvailable=$true;ahead=$null;behind=$null
        pushComplete=$true;ciStatus='success';workerExitCode=0;workflow=$workflow}
    $route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='medium'}
    $wr=[pscustomobject]@{Success=$true;ExitCode=0;Output='verified';WorkerReportedVerification='1 passed';LocalVerificationComplete=$true}
    Save-RunReceipt -Operation $Operation -IssueNumber $IssueNumber -RepoPath $fixture.Repo -Snapshot $pre.snapshot -Postflight $pf `
        -Route $route -WorkerResult $wr -StatusOverride 'pr_opened' -ResultEnvelopePresent $true -Interrupted $false `
        -LocalVerificationComplete $true -VerificationProvenance 'valid_worker_result_envelope' -Workflow $workflow `
        -ArtifactSanitizationStatus completed -ArtifactRetentionStatus completed|Out-Null
    Save-IssueWorkflowReceipt -IssueNumber $IssueNumber -RepoPath $fixture.Repo -Workflow $workflow|Out-Null
    return [pscustomobject]@{Fixture=$fixture;Probe=$probe;Workflow=$workflow;Postflight=$pf
        Receipt=(Get-RunReceipt -Operation $Operation -IssueNumber $IssueNumber -RepoPath $fixture.Repo)}
}

# v2.2+: 테스트용 verified run/review 영수증 생성
function Save-TestRunReceipt {
    param([Parameter(Mandatory)]$Repo, [Parameter(Mandatory)][int]$IssueNum,
          [string]$Worker = 'grok', [string]$FinalHeadOverride, [string]$Status = 'completed')
    Push-Location $Repo
    try {
        $heads = @(git rev-list --max-count=2 HEAD)
        $final = ([string]$heads[0]).Trim()
        $start = if ($heads.Count -gt 1) { ([string]$heads[1]).Trim() } else { $final }
    } finally { Pop-Location }
    if ($FinalHeadOverride) { $final = $FinalHeadOverride }
    $snap = [pscustomobject]@{ startHead = $start }
    $pf = [pscustomobject]@{ status=$Status; branch='main'; startHead=$start; finalHead=$final; headChanged=$true
        commitCount=1; worktreeClean=$true; aheadBehindAvailable=$true; ahead=0; behind=0; pushComplete=$true
        ciStatus='not-requested'; workerExitCode=0 }
    $route = [pscustomobject]@{ worker=$Worker; model='grok-4.5'; effort='high' }
    $wr = [pscustomobject]@{ Output = 'worker self-reported: tests passed (not re-run by router)' }
    Save-RunReceipt -Operation 1 -IssueNumber $IssueNum -RepoPath $Repo -Snapshot $snap -Postflight $pf -Route $route -WorkerResult $wr -RemainingProblems @() `
        -ResultEnvelopePresent $true -Interrupted $false -VerificationProvenance 'valid_worker_result_envelope' | Out-Null
}
function Save-TestRepairReceipts {
    param([Parameter(Mandatory)]$Repo, [Parameter(Mandatory)][int]$IssueNum, [Parameter(Mandatory)]$Findings)
    Save-TestRunReceipt -Repo $Repo -IssueNum $IssueNum -Worker 'grok'
    Save-ReviewReceipt -Operation 1 -IssueNumber $IssueNum -RepoPath $Repo -Verdict 'REPAIR_REQUIRED' -Findings $Findings `
        -PostReviewHead (Get-GitHead -Path $Repo) -OriginalWorker 'grok' | Out-Null
}


Describe '1. 네 개 Skill 등록 구조' {
    It '/operation, /operation-1, /operation-2, /operation-3 각각 SKILL.md 존재' {
        foreach ($n in @('operation','operation-1','operation-2','operation-3')) {
            (Test-Path (Join-Path $SkillsRoot "$n\SKILL.md")) | Should Be $true
        }
    }
    It 'frontmatter name이 폴더명과 일치' {
        foreach ($n in @('operation','operation-1','operation-2','operation-3')) {
            (Get-SkillFrontmatter -Path (Join-Path $SkillsRoot "$n\SKILL.md")).name | Should Be $n
        }
    }
    It '이전 단일 operation-router Skill은 제거됨' {
        (Test-Path (Join-Path $SkillsRoot 'operation-router')) | Should Be $false
    }
}

Describe '2. disable-model-invocation (v2.4.0 정책 A)' {
    It '디스패처 operation은 disable-model-invocation=true 유지' {
        (Get-SkillFrontmatter -Path (Join-Path $SkillsRoot "operation\SKILL.md"))['disable-model-invocation'] | Should Be 'true'
    }
    It '실행 Skill operation-1/2/3은 자연어 호출 허용(false)' {
        foreach ($n in @('operation-1','operation-2','operation-3')) {
            (Get-SkillFrontmatter -Path (Join-Path $SkillsRoot "$n\SKILL.md"))['disable-model-invocation'] | Should Be 'false'
        }
    }
    It '실행 Skill에 soft confirmation policy 문구가 있다(코드 강제 게이트 아님)' {
        foreach ($n in @('operation-1','operation-2','operation-3')) {
            $raw = Get-Content -LiteralPath (Join-Path $SkillsRoot "$n\SKILL.md") -Raw -Encoding UTF8
            $raw | Should Match 'soft confirmation policy'
            $raw | Should Match '실행할까요'
            $raw | Should Match '보안 토큰 게이트가 아니다'
        }
    }
    It 'Claude-only 전용 Skill은 disable-model-invocation=true 유지' {
        foreach ($n in @('operation-1-claude','operation-3-claude')) {
            (Get-SkillFrontmatter -Path (Join-Path $SkillsRoot "$n\SKILL.md"))['disable-model-invocation'] | Should Be 'true'
        }
    }
}

Describe 'v2.4.0 정책 B·C. 작전1 claude-only high + 고위험 경고' {
    It 'B: config claudeOnly.1.effort = high (유일 outlier 제거)' {
        (Get-Config).claudeOnly.'1'.effort | Should Be 'high'
    }
    It 'C: 작전1 claude_only_required는 고위험 경고를 포함한다' {
        $r = Resolve-OperationRoute -OperationNumber 1 -GrokState (GS 'exhausted' 100) -GptState (GS 'reserved' 20) -Config $cfg
        $r.status | Should Be 'claude_only_required'
        ($r.PSObject.Properties.Name -contains 'highRiskWarning') | Should Be $true
        $r.highRiskWarning | Should Match 'high-risk'
    }
    It 'C: 작전2 claude_only_required에는 고위험 경고가 없다' {
        $r = Resolve-OperationRoute -OperationNumber 2 -GrokState (GS 'exhausted' 100) -GptState (GS 'reserved' 20) -Config $cfg
        $r.status | Should Be 'claude_only_required'
        ($r.PSObject.Properties.Name -contains 'highRiskWarning') | Should Be $false
    }
}

Describe '3. 작전별 model/effort frontmatter' {
    It 'operation-1 = opus 4.8 / high' {
        $fm = Get-SkillFrontmatter -Path (Join-Path $SkillsRoot 'operation-1\SKILL.md')
        $fm.model | Should Be 'claude-opus-4-8'; $fm.effort | Should Be 'high'
    }
    It 'operation-2 = sonnet 5 / medium' {
        $fm = Get-SkillFrontmatter -Path (Join-Path $SkillsRoot 'operation-2\SKILL.md')
        $fm.model | Should Be 'claude-sonnet-5'; $fm.effort | Should Be 'medium'
    }
    It 'operation-3 = haiku 4.5 / low' {
        $fm = Get-SkillFrontmatter -Path (Join-Path $SkillsRoot 'operation-3\SKILL.md')
        $fm.model | Should Be 'claude-haiku-4-5-20251001'; $fm.effort | Should Be 'low'
    }
    It 'operation dispatcher = haiku / low' {
        $fm = Get-SkillFrontmatter -Path (Join-Path $SkillsRoot 'operation\SKILL.md')
        $fm.model | Should Be 'claude-haiku-4-5-20251001'; $fm.effort | Should Be 'low'
    }
    It '각 Skill에 argument-hint 존재' {
        foreach ($n in @('operation','operation-1','operation-2','operation-3')) {
            (Get-SkillFrontmatter -Path (Join-Path $SkillsRoot "$n\SKILL.md")).ContainsKey('argument-hint') | Should Be $true
        }
    }
}

Describe '4. 작전 1 단계 상태 전이' {
    It 'sol 역할은 임시 Terra가 아닌 gpt-5.6-sol에 매핑' {
        $cfg.gpt.workers.sol | Should Be 'gpt-5.6-sol'
    }
    It 'grok 가능 → 구현은 grok high' {
        $r = Resolve-OperationRoute -OperationNumber 1 -Purpose implement -GrokState (GS 'available' 0) -GptState (GS 'available' 0) -Config $cfg
        $r.worker | Should Be 'grok'; $r.effort | Should Be 'high'
    }
    It 'grok 소진 + gpt 여유 → 구현은 sol high' {
        $r = Resolve-OperationRoute -OperationNumber 1 -Purpose implement -GrokState (GS 'exhausted' 100) -GptState (GS 'available' 10) -Config $cfg
        $r.worker | Should Be 'gpt'; $r.workerAlias | Should Be 'sol'
    }
    It 'grok 소진 + gpt 차단 → claude_only_required sonnet' {
        $r = Resolve-OperationRoute -OperationNumber 1 -Purpose implement -GrokState (GS 'exhausted' 100) -GptState (GS 'available' 80) -Config $cfg
        $r.status | Should Be 'claude_only_required'; $r.requiredModel | Should Be 'claude-sonnet-5'
    }
    It '검수는 sol (gpt<80)' {
        $r = Resolve-OperationRoute -OperationNumber 1 -Purpose review -GrokState (GS 'available' 0) -GptState (GS 'available' 10) -Config $cfg
        $r.status | Should Be 'routed'; $r.workerAlias | Should Be 'sol'
    }
}

Describe '5-6. GPT 검수 예비분' {
    It '5. gpt>=80 검수 예비분 자동 사용 금지 → claude_review_fallback' {
        $r = Resolve-OperationRoute -OperationNumber 1 -Purpose review -GrokState (GS 'available' 0) -GptState (GS 'available' 85) -Config $cfg
        $r.status | Should Be 'claude_review_fallback'
    }
    It '6. 명시적 --use-gpt-review-reserve → sol 검수 허용' {
        $r = Resolve-OperationRoute -OperationNumber 1 -Purpose review -GrokState (GS 'available' 0) -GptState (GS 'available' 85) -Config $cfg -UseGptReviewReserve
        $r.status | Should Be 'routed'; $r.usedReviewReserve | Should Be $true
    }
    It 'reserved 상태 일반 구현 차단, 검수 예비분만 허용' {
        (Resolve-OperationRoute -OperationNumber 2 -GrokState (GS 'exhausted' 100) -GptState (GS 'reserved' 20) -Config $cfg).status | Should Be 'claude_only_required'
        (Resolve-OperationRoute -OperationNumber 1 -Purpose review -GrokState (GS 'available' 0) -GptState (GS 'reserved' 20) -Config $cfg -UseGptReviewReserve).status | Should Be 'routed'
    }
}

Describe '7. 작전 2 시작·종료 검토 상태 전이' {
    It '완료 경로: grok 커밋+push → completed' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciNone
            $res.status | Should Be 'completed'; $res.branch | Should Be 'main'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe '8. 작전 3 저장소 조사 금지 계약(문서)' {
    It 'operation-3 SKILL.md에 조사/검토 금지 문구가 있다' {
        $raw = Get-Content -LiteralPath (Join-Path $SkillsRoot 'operation-3\SKILL.md') -Raw -Encoding UTF8
        $raw | Should Match '조사하거나'
        $raw | Should Match '인수 검증'
    }
}

Describe '9-16. 사용량 라우팅' {
    It '9. Grok 84% 정상 (op1)' {
        (Resolve-OperationRoute -OperationNumber 1 -GrokState (GS 'available' 84) -GptState (GS 'available' 0) -Config $cfg).worker | Should Be 'grok'
    }
    It '10. Grok 85% 작전 1·2 신규 차단' {
        (Resolve-OperationRoute -OperationNumber 1 -GrokState (GS 'available' 85) -GptState (GS 'available' 0) -Config $cfg).status | Should Be 'blocked'
        (Resolve-OperationRoute -OperationNumber 2 -GrokState (GS 'available' 85) -GptState (GS 'available' 0) -Config $cfg).status | Should Be 'blocked'
    }
    It '10b. Grok 85% 작전 3 허용, --finish-current 로 op1/2 마감 허용' {
        (Resolve-OperationRoute -OperationNumber 3 -GrokState (GS 'available' 85) -GptState (GS 'available' 0) -Config $cfg).worker | Should Be 'grok'
        (Resolve-OperationRoute -OperationNumber 1 -GrokState (GS 'available' 85) -GptState (GS 'available' 0) -Config $cfg -FinishCurrent).worker | Should Be 'grok'
    }
    It '11. Grok 95% → GPT 전환' {
        (Resolve-OperationRoute -OperationNumber 2 -GrokState (GS 'available' 95) -GptState (GS 'available' 10) -Config $cfg).worker | Should Be 'gpt'
    }
    It '12. set grok 100 → 상태 exhausted 정규화 → GPT 경로' {
        $s = Get-UsageState; $s = Set-GrokState -State $s -Validated 100 -Config $cfg
        $s.grok.status | Should Be 'exhausted'
        (Resolve-OperationRoute -OperationNumber 2 -GrokState $s.grok -GptState (GS 'available' 10) -Config $cfg).worker | Should Be 'gpt'
    }
    It '13. GPT reserved 일반 구현 차단' {
        (Resolve-OperationRoute -OperationNumber 2 -GrokState (GS 'exhausted' 100) -GptState (GS 'reserved' 10) -Config $cfg).status | Should Be 'claude_only_required'
    }
    It '14. GPT 79% 작업 허용' {
        (Resolve-OperationRoute -OperationNumber 2 -GrokState (GS 'exhausted' 100) -GptState (GS 'available' 79) -Config $cfg).worker | Should Be 'gpt'
    }
    It '15. GPT 80% → Claude-only' {
        (Resolve-OperationRoute -OperationNumber 2 -GrokState (GS 'exhausted' 100) -GptState (GS 'available' 80) -Config $cfg).status | Should Be 'claude_only_required'
    }
    It '16. 숫자·상태 정규화 (grok available→percent 0, gpt 100→exhausted)' {
        $s = Get-UsageState
        $s = Set-GrokState -State $s -Validated 'available' -Config $cfg
        $s.grok.percent | Should Be 0
        $s = Set-GptState -State $s -Validated 100
        $s.gpt.status | Should Be 'exhausted'
    }
    It '16b. tier2(60-79): op3 logic terra 제한, mechanical luna 허용, op1 sol 검수전용' {
        (Resolve-OperationRoute -OperationNumber 3 -Kind logic -GrokState (GS 'exhausted' 100) -GptState (GS 'available' 60) -Config $cfg).status | Should Be 'claude_only_required'
        (Resolve-OperationRoute -OperationNumber 3 -Kind mechanical -GrokState (GS 'exhausted' 100) -GptState (GS 'available' 60) -Config $cfg).workerAlias | Should Be 'luna'
        (Resolve-OperationRoute -OperationNumber 1 -GrokState (GS 'exhausted' 100) -GptState (GS 'available' 60) -Config $cfg).status | Should Be 'claude_only_required'
    }
}

Describe '17-20. fallback 규칙 (run 수준)' {
    It '17. 한도 오류 전 변경 없음 → GPT fallback 허용' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $grQuota = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;Output='weekly limit reached' } }
            $gpOk = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 9 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grQuota -GptRunner $gpOk -CiProbe $ciNone
            $res.worker | Should Be 'gpt'; $res.status | Should Be 'completed'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '18. 한도 오류 전 파일 수정 → fallback 금지 (partial_worker_changes)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $grDirty = { param($r,$repo,$prompt) Push-Location $repo; "d" | Out-File c.txt -Encoding utf8; Pop-Location; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;Output='weekly limit reached' } }
            $gpNo = { param($r,$repo,$prompt) throw 'GPT must not run' }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 10 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grDirty -GptRunner $gpNo -CiProbe $ciNone
            $res.status | Should Be 'partial_worker_changes'; $res.fallbackAttempted | Should Be $false
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '19. 한도 오류 전 커밋 생성 → fallback 금지' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $grCommit = { param($r,$repo,$prompt) Push-Location $repo; "d" | Out-File c.txt -Encoding utf8; git add .; git commit -q -m c; Pop-Location; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;Output='weekly limit reached' } }
            $gpNo = { param($r,$repo,$prompt) throw 'GPT must not run' }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 11 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grCommit -GptRunner $gpNo -CiProbe $ciNone
            $res.status | Should Be 'partial_worker_changes'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '20. 일반 오류 → fallback 금지 (worker_failed)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $grFail = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='auth error 401' } }
            $gpNo = { param($r,$repo,$prompt) throw 'GPT must not run' }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 12 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grFail -GptRunner $gpNo -CiProbe $ciNone
            $res.status | Should Be 'worker_failed'; $res.worker | Should Be 'grok'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.4.0/v2.4.1 저장소 경계 탐지 + 공통 finalizer' {
    It 'Test-RepoBoundaryViolation: 스냅샷 없음/변화 없음은 위반 0' {
        @(Test-RepoBoundaryViolation -BeforeSnapshot $null).Count | Should Be 0
        $f = Join-Path $TestWorkRoot ("bw-" + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $f -Value 'original' -Encoding utf8
        $snap = @([pscustomobject]@{ path = $f; hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash })
        @(Test-RepoBoundaryViolation -BeforeSnapshot $snap).Count | Should Be 0
        Remove-Item -LiteralPath $f -Force
    }
    It 'Test-RepoBoundaryViolation: 내용 변경·삭제를 위반으로 탐지' {
        $f = Join-Path $TestWorkRoot ("bw-" + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $f -Value 'original' -Encoding utf8
        $snap = @([pscustomobject]@{ path = $f; hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash })
        Set-Content -LiteralPath $f -Value 'TAMPERED' -Encoding utf8
        @(Test-RepoBoundaryViolation -BeforeSnapshot $snap).Count | Should Be 1
        Remove-Item -LiteralPath $f -Force
        @(Test-RepoBoundaryViolation -BeforeSnapshot $snap).Count | Should Be 1  # 삭제도 변화
    }
    It 'Get-BoundarySnapshot: 없는 경로는 ABSENT, 실제 파일은 SHA-256' {
        $f = Join-Path $TestWorkRoot ("bw-" + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $f -Value 'x' -Encoding utf8
        $missing = Join-Path $TestWorkRoot ("nope-" + [guid]::NewGuid().ToString('N') + '.txt')
        $rec = @(Get-BoundarySnapshot -Paths @($f, $missing))
        ($rec | Where-Object { $_.path -eq $f }).hash | Should Match '^[A-Fa-f0-9]{64}$'
        ($rec | Where-Object { $_.path -eq $missing }).hash | Should Be 'ABSENT'
        Remove-Item -LiteralPath $f -Force
    }
    It 'Get-StartSnapshot이 boundaryWatch를 포함한다' {
        $repo = New-FakeRepo
        try {
            $snap = Get-StartSnapshot -RepoPath $repo
            ($snap.PSObject.Properties.Name -contains 'boundaryWatch') | Should Be $true
            @($snap.boundaryWatch).Count | Should BeGreaterThan 0
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'Complete-BoundaryFinalizer: null 결과/스냅샷은 그대로 반환' {
        (Complete-BoundaryFinalizer -Result $null -BoundarySnapshot $null) | Should Be $null
        $r = [pscustomobject]@{ status = 'completed' }
        (Complete-BoundaryFinalizer -Result $r -BoundarySnapshot $null).status | Should Be 'completed'
    }
    It 'Complete-BoundaryFinalizer: 위반 없으면 스키마 불변(필드 추가 없음)' {
        $f = Join-Path $TestWorkRoot ("bw-" + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $f -Value 'x' -Encoding utf8
        $bw = @([pscustomobject]@{ path = $f; hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash })
        $r = [pscustomobject]@{ status = 'completed'; ciStatus = 'success' }
        $out = Complete-BoundaryFinalizer -Result $r -BoundarySnapshot $bw
        $out.status | Should Be 'completed'
        ($out.PSObject.Properties.Name -contains 'underlyingStatus') | Should Be $false
        ($out.PSObject.Properties.Name -contains 'boundaryViolations') | Should Be $false
        Remove-Item -LiteralPath $f -Force
    }
    It 'Complete-BoundaryFinalizer: 위반 시 승격 + underlyingStatus 보존 + ciStatus not-checked + idempotent' {
        $f = Join-Path $TestWorkRoot ("bw-" + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $f -Value 'original' -Encoding utf8
        $bw = @([pscustomobject]@{ path = $f; hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash })
        Set-Content -LiteralPath $f -Value 'TAMPERED' -Encoding utf8
        $r = [pscustomobject]@{ status = 'worker_failed'; ciStatus = 'not-checked' }
        $out = Complete-BoundaryFinalizer -Result $r -BoundarySnapshot $bw
        $out.status | Should Be 'repo_boundary_violation'
        $out.underlyingStatus | Should Be 'worker_failed'
        @($out.boundaryViolations).Count | Should Be 1
        $out.ciStatus | Should Be 'not-checked'
        # idempotent: 다시 통과시켜도 underlyingStatus가 repo_boundary_violation으로 덮이지 않는다
        $again = Complete-BoundaryFinalizer -Result $out -BoundarySnapshot $bw
        $again.underlyingStatus | Should Be 'worker_failed'
        Remove-Item -LiteralPath $f -Force
    }

    # --- Invoke-RunOperation 조기 반환 경로별 경계 finalizer (env seam으로 감시 경로 대체) ---
    function New-BoundaryWatchSeam {
        $wf = Join-Path $TestWorkRoot ("watch-" + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $wf -Value 'original' -Encoding utf8
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $wf
        return $wf
    }
    It '감시 파일 변경 + worker 일반 실패 → repo_boundary_violation (underlying worker_failed)' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = New-BoundaryWatchSeam
        try {
            $gr = { param($r,$repo2,$prompt) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='auth error 401' } }
            $script:ciCalls = 0; $ciCount = { param($h) $script:ciCalls++; 'success' }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 40 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -GptRunner ({ param($r,$repo2,$prompt) throw 'no gpt' }) -CiProbe $ciCount
            $res.status | Should Be 'repo_boundary_violation'
            $res.underlyingStatus | Should Be 'worker_failed'
            @($res.boundaryViolations).Count | Should Be 1
            $script:ciCalls | Should Be 0
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }
    }
    It '감시 파일 변경 + transient 실패 → repo_boundary_violation (underlying transient_rate_limited)' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = New-BoundaryWatchSeam
        try {
            $gr = { param($r,$repo2,$prompt) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='rate limit exceeded' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 41 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -GptRunner ({ param($r,$repo2,$prompt) throw 'no gpt' }) -CiProbe $ciNone
            $res.status | Should Be 'repo_boundary_violation'
            $res.underlyingStatus | Should Be 'transient_rate_limited'
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }
    }
    It '감시 파일 변경 + weekly 소진 후 부분 변경 → repo_boundary_violation (underlying partial_worker_changes)' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = New-BoundaryWatchSeam
        try {
            $gr = { param($r,$repo2,$prompt) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; Push-Location $repo2; "d" | Out-File c.txt -Encoding utf8; git add .; git commit -q -m c; Pop-Location; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;Output='weekly limit reached' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 42 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -GptRunner ({ param($r,$repo2,$prompt) throw 'no gpt' }) -CiProbe $ciNone
            $res.status | Should Be 'repo_boundary_violation'
            $res.underlyingStatus | Should Be 'partial_worker_changes'
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }
    }
    It '감시 파일 변경 + GPT fallback 실패 → repo_boundary_violation' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = New-BoundaryWatchSeam
        try {
            $grWeekly = { param($r,$repo2,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;Output='weekly limit reached' } }
            $gpFail = { param($r,$repo2,$prompt) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='auth error 401' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 43 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grWeekly -GptRunner $gpFail -CiProbe $ciNone
            $res.status | Should Be 'repo_boundary_violation'
            $res.underlyingStatus | Should Be 'worker_failed'
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }
    }
    It '감시 파일 변경 + review 실패 → repo_boundary_violation' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = New-BoundaryWatchSeam
        try {
            # 유효한 grok completed run 영수증을 심어 검수 자격을 만든다
            $grOk = { param($r,$repo2,$prompt) Push-Location $repo2; "impl" | Out-File impl.txt -Encoding utf8; git add .; git commit -q -m impl; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            (Invoke-SetCommand -Target grok -Value '10') | Out-Null
            Invoke-RunOperation -OperationNumber 1 -IssueNumber 44 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grOk -CiProbe ({ param($h) 'success' }) | Out-Null
            $revFail = { param($repo2,$prompt,$r) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='auth error 401' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 44 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $revFail
            $rv.status | Should Be 'repo_boundary_violation'
            $rv.underlyingStatus | Should Be 'review_worker_failed'
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue; Invoke-ResetCommand | Out-Null }
    }
    It '감시 파일 변경 + repair 실패 → repo_boundary_violation' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = New-BoundaryWatchSeam
        try {
            $head = (Get-GitHead -Path $repo)
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            Save-TestRepairReceipts -Repo $repo -IssueNum 45 -Findings $findings
            $repairFail = { param($r,$repo2,$prompt) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='auth error 401' } }
            $rr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 45 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead $head -IssueFetcher $issue -RepairRunner $repairFail -CiProbe $ciNone
            $rr.status | Should Be 'repo_boundary_violation'
            $rr.underlyingStatus | Should Be 'repair_worker_failed'
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue; Invoke-ResetCommand | Out-Null }
    }
    It '위반 없으면 정상 상태와 스키마가 바뀌지 않는다' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = New-BoundaryWatchSeam
        try {
            $grOk = { param($r,$repo2,$prompt) Push-Location $repo2; "d" | Out-File c.txt -Encoding utf8; git add .; git commit -q -m c; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 46 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grOk -CiProbe ({ param($h) 'success' })
            $res.status | Should Be 'completed'
            ($res.PSObject.Properties.Name -contains 'underlyingStatus') | Should Be $false
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }
    }
    It 'v2.4.2 HIGH: 경계 위반 + 정상 커밋·push → run 영수증도 repo_boundary_violation, 후속 review not_eligible(GPT 0회)' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = New-BoundaryWatchSeam
        try {
            $gr = { param($r,$repo2,$prompt) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; Push-Location $repo2; "impl" | Out-File impl.txt -Encoding utf8; git add .; git commit -q -m impl; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 1 -IssueNumber 50 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe ({ param($h) 'success' })
            $res.status | Should Be 'repo_boundary_violation'
            # run 영수증 status도 승격돼야 한다 (completed로 남으면 review 자격을 통과함)
            (Get-RunReceipt -Operation 1 -IssueNumber 50 -RepoPath $repo).status | Should Be 'repo_boundary_violation'
            # 후속 review: 완료 영수증이 아니므로 자격 거부 + GPT 검수 미호출
            $script:revCalls50 = 0
            $revRunner = { param($repo2,$prompt,$r) $script:revCalls50++; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='{"verdict":"PASS","findings":[]}' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 50 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $revRunner
            $rv.status | Should Be 'review_not_eligible'
            $script:revCalls50 | Should Be 0
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue; Invoke-ResetCommand | Out-Null }
    }
    It 'v2.4.2 HIGH: 검수 중 경계 위반 → review 영수증 미저장(repair 자격 원천 차단)' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = $null
        try {
            # 1) 경계 seam 없이 정상 completed run 영수증 생성
            $grOk = { param($r,$repo2,$prompt) Push-Location $repo2; "impl" | Out-File impl.txt -Encoding utf8; git add .; git commit -q -m impl; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            Invoke-RunOperation -OperationNumber 1 -IssueNumber 51 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grOk -CiProbe ({ param($h) 'success' }) | Out-Null
            # 2) 검수 중 감시 파일 변경 + 유효한 REPAIR_REQUIRED JSON
            $wf = New-BoundaryWatchSeam
            $revRunner = { param($repo2,$prompt,$r) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"high","file":"a.txt","issue":"x","requiredFix":"y"}]}' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 51 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $revRunner
            $rv.status | Should Be 'repo_boundary_violation'
            $rv.underlyingStatus | Should Be 'reviewed'
            (Test-Path (Get-ReviewReceiptPath -Operation 1 -IssueNumber 51 -RepoPath $repo)) | Should Be $false
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; if($wf){ Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }; Invoke-ResetCommand | Out-Null }
    }
    It 'v2.4.3 HIGH: 이전 completed run 영수증이 재실행(경계위반+실패) 뒤 남지 않는다' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = $null
        try {
            # 1) seam 없이 정상 completed run 영수증 생성
            $grOk = { param($r,$repo2,$prompt) Push-Location $repo2; "impl" | Out-File impl.txt -Encoding utf8; git add .; git commit -q -m impl; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            Invoke-RunOperation -OperationNumber 1 -IssueNumber 60 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grOk -CiProbe ({ param($h) 'success' }) | Out-Null
            (Get-RunReceipt -Operation 1 -IssueNumber 60 -RepoPath $repo).status | Should Be 'completed'
            # 2) 같은 이슈 재실행: 감시 파일 변경 + worker 실패 (HEAD 불변)
            $wf = New-BoundaryWatchSeam
            $grFail = { param($r,$repo2,$prompt) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='auth error 401' } }
            $res = Invoke-RunOperation -OperationNumber 1 -IssueNumber 60 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grFail -GptRunner ({ param($r,$repo2,$prompt) throw 'no gpt' }) -CiProbe $ciNone
            $res.status | Should Be 'repo_boundary_violation'
            # 이전 completed 영수증이 무효화돼야 한다(과거 성공 상태 재사용 차단)
            (Get-RunReceipt -Operation 1 -IssueNumber 60 -RepoPath $repo) | Should Be $null
            # 후속 review는 영수증이 없어 GPT 미호출
            $script:rc60 = 0
            $revRunner = { param($repo2,$prompt,$r) $script:rc60++; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='{"verdict":"PASS","findings":[]}' } }
            Invoke-OperationReview -OperationNumber 1 -IssueNumber 60 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $revRunner | Out-Null
            $script:rc60 | Should Be 0
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; if($wf){ Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }; Invoke-ResetCommand | Out-Null }
    }
    It 'v2.4.3 HIGH: 이전 REPAIR_REQUIRED review 영수증이 경계위반 재검수 뒤 남지 않는다' {
        Invoke-ResetCommand | Out-Null; $repo = New-FakeRepo -WithRemote; $wf = $null
        try {
            $grOk = { param($r,$repo2,$prompt) Push-Location $repo2; "impl" | Out-File impl.txt -Encoding utf8; git add .; git commit -q -m impl; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            Invoke-RunOperation -OperationNumber 1 -IssueNumber 61 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grOk -CiProbe ({ param($h) 'success' }) | Out-Null
            # 1) 정상 REPAIR_REQUIRED review 영수증 생성 (seam 없음)
            $revRR = { param($repo2,$prompt,$r) [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"high","file":"a.txt","issue":"x","requiredFix":"y"}]}' } }
            Invoke-OperationReview -OperationNumber 1 -IssueNumber 61 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $revRR | Out-Null
            (Test-Path (Get-ReviewReceiptPath -Operation 1 -IssueNumber 61 -RepoPath $repo)) | Should Be $true
            # 2) 같은 이슈 재검수: 감시 파일 변경 + REPAIR_REQUIRED
            $wf = New-BoundaryWatchSeam
            $revTamper = { param($repo2,$prompt,$r) Set-Content -LiteralPath $wf -Value 'HACKED' -Encoding utf8; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"high","file":"a.txt","issue":"x","requiredFix":"y"}]}' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 61 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $revTamper
            $rv.status | Should Be 'repo_boundary_violation'
            # 이전 REPAIR_REQUIRED 영수증이 무효화돼야 한다(repair 재사용 차단)
            (Test-Path (Get-ReviewReceiptPath -Operation 1 -IssueNumber 61 -RepoPath $repo)) | Should Be $false
        } finally { $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE = $null; Remove-Item -Recurse -Force $repo; if($wf){ Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }; Invoke-ResetCommand | Out-Null }
    }
}

Describe '21-24. postflight 상태' {
    It '21. 종료코드 0 + 커밋 0 → no_commit' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 13 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciNone).status | Should Be 'no_commit'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '22. 커밋 있으나 push 미완 → push_incomplete' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 14 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciNone).status | Should Be 'push_incomplete'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '23. push 후 worktree dirty → dirty_worktree' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; "leftover" | Out-File d.txt -Encoding utf8; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 15 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciNone).status | Should Be 'dirty_worktree'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '24. CI API 오류(unavailable)를 success로 간주하지 않는다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $ciErr = { param($p) 'unavailable' }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 16 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciErr
            $res.ciStatus | Should Be 'unavailable'
            $res.ciStatus | Should Not Be 'success'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '24b. CI failure → ci_failed' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $ciFail = { param($p) 'failure' }
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 17 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciFail).status | Should Be 'ci_failed'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe '25-26. 고정 실행 계약 + 이슈 원문 보존' {
    It '25. 이슈 원문 앞에 고정 실행 계약이 붙는다' {
        $order = New-OrderContent -IssueBody 'ISSUE_BODY_MARKER'
        $order | Should Match '고정 실행 계약'
        $order | Should Match 'origin/main'
        $order.IndexOf('고정 실행 계약') -lt $order.IndexOf('ISSUE_BODY_MARKER') | Should Be $true
    }
    It '26. 이슈 원문 내용이 변형되지 않는다' {
        $body = "Line1 특수문자 <>&`n둘째 줄 with trailing spaces   "
        $order = New-OrderContent -IssueBody $body
        $order.Contains($body) | Should Be $true
    }
}

Describe '27-28. 상태 파일 위치 / reset 안전' {
    It '27. usage-state는 테스트 임시 루트에 있고 실제 사용자 상태가 아니다' {
        $Script:UsageStatePath | Should Not Be $actualUsagePath
        (Assert-PathWithinRoot -Path $Script:UsageStatePath -Root $TestWorkRoot) | Should Be $Script:UsageStatePath
    }
    It '28. reset은 config/스크립트를 삭제하지 않는다' {
        Invoke-ResetCommand | Out-Null
        (Test-Path $Script:ConfigPath) | Should Be $true
        (Test-Path (Join-Path $ScriptsDir 'run-operation.ps1')) | Should Be $true
        (Get-UsageState).grok.status | Should Be 'available'
    }
}

Describe '29-30. 보안/임시파일' {
    It '29. secret 형태 마스킹' {
        (Protect-SecretText -Text 'token=ghp_abcdefghijklmnopqrstuvwx1234') | Should Not Match 'ghp_abcdefghijklmnopqrstuvwx1234'
        (Protect-SecretText -Text 'api_key: sk-abcdefghijklmnopqrstuvwx') | Should Not Match 'sk-abcdefghijklmnopqrstuvwx'
        (Protect-SecretText -Text 'Authorization: Bearer abcdefghij1234567890') | Should Not Match 'abcdefghij1234567890'
    }
    It '29b. v2.4.0: Authorization 임의 스킴·AWS·고엔트로피 마스킹, git SHA/UUID는 보존' {
        # Authorization Basic (Bearer 아님) 값 제거
        (Protect-SecretText -Text 'Authorization: Basic dXNlcjpwYXNzd29yZDEyMzQ1Ng==') | Should Not Match 'dXNlcjpwYXNzd29yZA'
        # AWS 액세스 키
        (Protect-SecretText -Text 'AKIAIOSFODNN7EXAMPLE here') | Should Not Match 'AKIAIOSFODNN7EXAMPLE'
        # 알려진 접두 없는 고엔트로피 secret은 마스킹
        $secret = 'Xk9mQ2vLpZ7aB3nR8tYw1Cd5Ef0Gh6J'
        (Protect-SecretText -Text "value $secret end") | Should Not Match ([regex]::Escape($secret))
        # git SHA(40 hex)와 짧은 SHA는 보존 (오탐 금지)
        $sha = 'effe08c3bf15a067c186f68adaf346376ab61ce9'
        (Protect-SecretText -Text "startHead=$sha") | Should Match ([regex]::Escape($sha))
        # UUID 보존 (sessionId 등)
        $uuid = '019f8235-b50a-7121-81d0-d25acc4b8199'
        (Protect-SecretText -Text "sessionId $uuid") | Should Match ([regex]::Escape($uuid))
    }
    It '30. 작업자 실패 terminal 상태는 주문서 원문을 삭제하고 hash만 보존한다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:capPath = $null
            $gr = { param($r,$repo,$prompt) $script:capPath = $prompt; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='fail' } }
            Invoke-RunOperation -OperationNumber 2 -IssueNumber 18 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciNone | Out-Null
            (Test-Path -LiteralPath $script:capPath) | Should Be $false
            (Assert-PathWithinRoot -Path $script:capPath -Root $script:PendingDir) | Should Be $script:capPath
            $receipt = Get-ExecutionReceipt -Operation 2 -IssueNumber 18 -RepoPath $repo
            $receipt.promptPath | Should Be $null
            $receipt.promptPresent | Should Be $false
            ([string]$receipt.promptHash) | Should Match '^[A-Fa-f0-9]{64}$'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe '추가: 검증/주입/워커/doctor (기존 유지분)' {
    It '작전·이슈 번호 검증' {
        { Assert-ValidOperationNumber -Value '4' } | Should Throw
        (Assert-ValidOperationNumber -Value '2') | Should Be 2
        { Assert-ValidIssueNumber -Value '0' } | Should Throw
        (Assert-ValidIssueNumber -Value '42') | Should Be 42
    }
    It 'command injection 입력 거부' {
        { Assert-ValidIssueNumber -Value '8; rm -rf /' } | Should Throw
        { Assert-ValidIssueNumber -Value '$(echo x)' } | Should Throw
        { Assert-ValidOperationNumber -Value '1 && echo pwned' } | Should Throw
    }
    It '일반 오류는 quota로 판단하지 않고, 명시적 한도만 quota' {
        (Test-QuotaExhaustedText -Text 'build failed') | Should Be $false
        (Test-QuotaExhaustedText -Text 'weekly limit reached') | Should Be $true
    }
    It 'gpt unresolved 모델 fail-closed' {
        $tmp = New-TempOrderFile -Content 'x'
        try {
            $runner = { param($fp,$al) [pscustomobject]@{ ExitCode=0; Output='ok' } }
            { Invoke-GptWorker -Cwd $HOME -Model 'unresolved' -Effort 'low' -PromptFilePath $tmp -Runner $runner } | Should Throw
        } finally { Remove-TempOrderFile -Path $tmp }
    }
    It 'grok quota/일반 오류 플래그' {
        $tmp = New-TempOrderFile -Content 'x'
        try {
            $q = { param($fp,$al) [pscustomobject]@{ ExitCode=1; Output='weekly limit reached' } }
            $f = { param($fp,$al) [pscustomobject]@{ ExitCode=1; Output='build failed' } }
            (Invoke-GrokWorker -Cwd $HOME -Model 'grok-4.5' -Effort 'low' -MaxTurns 5 -PromptFilePath $tmp -Runner $q).QuotaExhausted | Should Be $true
            (Invoke-GrokWorker -Cwd $HOME -Model 'grok-4.5' -Effort 'low' -MaxTurns 5 -PromptFilePath $tmp -Runner $f).QuotaExhausted | Should Be $false
        } finally { Remove-TempOrderFile -Path $tmp }
    }
    It 'doctor 보고서 항목' {
        $r = Invoke-DoctorCommand
        $r.report.claude | Should Not Be $null
        # 2026-07-21 실측: codex models_cache.json에서 gpt-5.6-sol이 제거됨. doctor는 환경을 정직하게
        # 보고해야 하므로 sol은 정확 slug 또는 unresolved만 허용한다(unresolved는 invoke-gpt fail-closed로 차단).
        $r.report.codex.models.luna | Should Be 'gpt-5.6-luna'
        $r.report.codex.models.terra | Should Be 'gpt-5.6-terra'
        $r.report.codex.models.sol | Should Match '^(gpt-5\.6-sol|unresolved)$'
        $r.report.skillFrontmatter.dynamicModelSwitchConfirmed | Should Be $false
    }
    It 'dirty worktree 시작 전제 차단' {
        $repo = New-FakeRepo
        try {
            "changed" | Out-File (Join-Path $repo 'a.txt') -Encoding utf8
            (Test-StartPreconditions -RepoPath $repo).reason | Should Be 'dirty_worktree'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'op3 mechanical + gpt 80% → claude_direct(haiku)' {
        $r = Resolve-OperationRoute -OperationNumber 3 -Kind mechanical -GrokState (GS 'exhausted' 100) -GptState (GS 'available' 80) -Config $cfg
        $r.status | Should Be 'claude_direct'; $r.requiredModel | Should Be 'claude-haiku-4-5-20251001'
    }
    It 'claude_only_required 시 resumeCommand 포함' {
        Invoke-ResetCommand | Out-Null
        (Invoke-SetCommand -Target grok -Value 'exhausted') | Out-Null
        (Invoke-SetCommand -Target gpt -Value '90') | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 20 -RepoPath $repo -IssueFetcher $issue -CiProbe $ciNone
            $res.status | Should Be 'claude_only_required'
            $res.resumeCommand | Should Match '--claude-only'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

# ================= v2.1 핵심 실행 수리 테스트 =================
function Head-Of { param($repo) Push-Location $repo; $h = (git rev-parse HEAD).Trim(); Pop-Location; return $h }
function New-RepoAhead {
    $p = New-FakeRepo -WithRemote
    Push-Location $p; "ahead" | Out-File ahead.txt -Encoding utf8; git add .; git commit -q -m ahead; Pop-Location
    return $p
}
function New-RepoBehind {
    $p = New-FakeRepo -WithRemote
    Push-Location $p
    "c2" | Out-File c2.txt -Encoding utf8; git add .; git commit -q -m c2; git push -q origin main
    git reset --hard HEAD~1 *>$null    # 로컬만 뒤로 (테스트 셋업; 라우터 동작 아님)
    Pop-Location
    return $p
}
Describe 'v2.1-1. --claude-only 무한 루프 방지' {
    It '--claude-only 는 claude_only_required가 아니라 claude_execute를 반환하고 resumeCommand 재귀가 없다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 30 -RepoPath $repo -IssueFetcher $issue -ClaudeOnly -CiProbe $ciNone
            $res.status | Should Be 'claude_execute'
            $res.status | Should Not Be 'claude_only_required'
            ($res.PSObject.Properties.Name -contains 'resumeCommand') | Should Be $false
            $res.requiredModel | Should Be 'claude-sonnet-5'
        } finally {
            Remove-PendingSnapshot -Operation 2 -IssueNumber 30 -RepoPath $repo
            $op = Get-PendingOrderPath -Operation 2 -IssueNumber 30 -RepoPath $repo
            if (Test-Path $op) { Remove-Item $op -Force }
            Remove-Item -Recurse -Force $repo
        }
    }
}

Describe 'v2.1-2. claude-only 수행 후 postflight' {
    It 'implementer 주입 시 실제 수행 후 postflight completed' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 31 -RepoPath $repo -IssueFetcher $issue -ClaudeOnly -ClaudeImplementer (New-ClaudeImplPush -Operation 2 -IssueNumber 31) -CiProbe $ciNone
            $res.status | Should Be 'completed'
            $res.route | Should Be 'claude-only-executed'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '2단계: --claude-only 지시 후 세션이 구현하고 postflight 명령으로 completed' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $d = Invoke-RunOperation -OperationNumber 2 -IssueNumber 32 -RepoPath $repo -IssueFetcher $issue -ClaudeOnly -CiProbe $ciNone
            $d.status | Should Be 'claude_execute'
            # 세션이 직접 구현했다고 가정
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location
            $report=Write-TestClaudeCompletionReport -Repo $repo -Operation 2 -IssueNumber 32
            $pf = Invoke-PostflightCommand -Operation 2 -IssueNumber 32 -RepoPath $repo -CiProbe $ciNone -WorkerReportPath $report
            $pf.status | Should Be 'completed'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.1-3. operation-3 claude_direct 실제 흐름' {
    It 'grok 소진 + gpt80 + op3 mechanical + implementer → 실제 수행 completed' {
        Invoke-ResetCommand | Out-Null
        Invoke-SetCommand -Target grok -Value 'exhausted' | Out-Null
        Invoke-SetCommand -Target gpt -Value '80' | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $res = Invoke-RunOperation -OperationNumber 3 -Kind mechanical -IssueNumber 33 -RepoPath $repo -IssueFetcher $issue -ClaudeImplementer (New-ClaudeImplPush -Operation 3 -IssueNumber 33) -CiProbe $ciNone
            $res.status | Should Be 'completed'
            $res.route | Should Be 'claude-direct-executed'
            $res.model | Should Be 'claude-haiku-4-5-20251001'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

Describe 'v2.1-4. review 실제 mock GPT 호출 + 엄격 JSON (v2.2: 영수증 자동 복원)' {
    $repo = New-FakeRepo -WithRemote
    Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
    Save-TestRunReceipt -Repo $repo -IssueNum 5
    It 'review가 실제 mock GPT runner를 호출한다 (StartHead 인수 없음)' {
        Invoke-ResetCommand | Out-Null
        $script:reviewCalled = $false
        $runner = { param($repo,$prompt,$r) $script:reviewCalled = $true; [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[]}' } }
        Invoke-OperationReview -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner | Out-Null
        $script:reviewCalled | Should Be $true
    }
    It '검수 JSON PASS' {
        $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[]}' } }
        (Invoke-OperationReview -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner).verdict | Should Be 'PASS'
    }
    It '검수 JSON REPAIR_REQUIRED (findings는 review 영수증에 저장)' {
        $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=0; Output='{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"blocker","file":"b.txt","issue":"x","requiredFix":"y"}]}' } }
        $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
        $rv.verdict | Should Be 'REPAIR_REQUIRED'
        @($rv.findings).Count | Should Be 1
        (Test-Path (Get-ReviewReceiptPath -Operation 1 -IssueNumber 5 -RepoPath $repo)) | Should Be $true
    }
    It '잘못된 검수 JSON은 fail-closed (review_parse_failed, PASS 아님)' {
        $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=0; Output='looks good to me, ship it' } }
        $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
        $rv.status | Should Be 'review_parse_failed'
        $rv.verdict | Should Not Be 'PASS'
        $rv.parseError | Should Not Be $null
    }
    It 'PASS인데 findings 있으면 fail-closed (review_parse_failed)' {
        $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[{"severity":"blocker","file":"x","issue":"y","requiredFix":"z"}]}' } }
        $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
        $rv.status | Should Be 'review_parse_failed'
        $rv.verdict | Should Not Be 'PASS'
    }
    It 'GPT 검수 불가(gpt85 no reserve) → claude_review_fallback' {
        Invoke-SetCommand -Target gpt -Value '85' | Out-Null
        $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[]}' } }
        (Invoke-OperationReview -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner).status | Should Be 'claude_review_fallback'
        Invoke-ResetCommand | Out-Null
    }
    It 'cleanup' {
        Remove-RunReceipt -Operation 1 -IssueNumber 5 -RepoPath $repo
        Remove-ReviewReceipt -Operation 1 -IssueNumber 5 -RepoPath $repo
        Remove-Item -Recurse -Force $repo; $true | Should Be $true
    }
}

Describe 'v2.1-5. 수리 최대 1회 + 상태 가드' {
    It '수리 호출은 최대 1회, 후 postflight, 성공은 repair_completed_review_pending (재검수 없음)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $prh = Head-Of $repo
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            Save-TestRepairReceipts -Repo $repo -IssueNum 5 -Findings $findings
            $script:rc = 0
            $rep = { param($r,$repo,$prompt) $script:rc++; Push-Location $repo; "fix" | Out-File fix.txt -Encoding utf8; git add .; git commit -q -m fix; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead $prh -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
            $script:rc | Should Be 1
            $hr.status | Should Be 'repair_completed_review_pending'
            $hr.repairAttempted | Should Be $true
            $hr.finalReviewRequired | Should Be $true
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '명시 PostReviewHead가 receipt와 불일치하면 repair_argument_receipt_mismatch' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            Save-TestRepairReceipts -Repo $repo -IssueNum 5 -Findings $findings
            $script:rc2 = 0
            $rep = { param($r,$repo,$prompt) $script:rc2++; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead '0000000000000000000000000000000000000000' -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
            $hr.status | Should Be 'repair_argument_receipt_mismatch'
            $hr.reason | Should Be 'post_review_head_mismatch'
            $script:rc2 | Should Be 0
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.1-6. fallback resumeCommand 원래 이슈 유지' {
    It 'grok 한도(clean) + gpt90 → claude_only_required, resumeCommand에 원래 이슈번호 유지 (0/null 아님)' {
        Invoke-ResetCommand | Out-Null
        Invoke-SetCommand -Target gpt -Value '90' | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $grQuota = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;Output='weekly limit reached' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 42 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grQuota -CiProbe $ciNone
            $res.status | Should Be 'claude_only_required'
            $res.issueNumber | Should Be 42
            $res.resumeCommand | Should Be '/operation-2 42 --claude-only'
            $res.resumeCommand | Should Not Match ' 0 '
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

Describe 'v2.1-7. CI 상태 매핑 (main 직접 push)' {
    It 'CI success → completed' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 50 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe ({ param($h) 'success' })).status | Should Be 'completed'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'CI failure → ci_failed' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 51 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe ({ param($h) 'failure' })).status | Should Be 'ci_failed'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'CI pending → completed_ci_pending' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 52 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe ({ param($h) 'pending' })).status | Should Be 'completed_ci_pending'
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'CI unavailable → completed_ci_unavailable (completed 아님)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 53 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe ({ param($h) 'unavailable' })
            $res.status | Should Be 'completed_ci_unavailable'
            $res.status | Should Not Be 'completed'
            $res.ciStatus | Should Be 'unavailable'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.1-8. preflight 원격 동기화 게이트' {
    It '원격 확인 불가 → remote_sync_unavailable' {
        $repo = New-FakeRepo   # 원격 없음
        try { (Test-StartPreconditions -RepoPath $repo).reason | Should Be 'remote_sync_unavailable' } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'local ahead → local_ahead_of_remote' {
        $repo = New-RepoAhead
        try { (Test-StartPreconditions -RepoPath $repo).reason | Should Be 'local_ahead_of_remote' } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'behind → behind_remote' {
        $repo = New-RepoBehind
        try { (Test-StartPreconditions -RepoPath $repo).reason | Should Be 'behind_remote' } finally { Remove-Item -Recurse -Force $repo }
    }
    It '동기화됨 → ok' {
        $repo = New-FakeRepo -WithRemote
        try { (Test-StartPreconditions -RepoPath $repo).ok | Should Be $true } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'run 진입 시 미동기화면 해당 상태로 중단' {
        Invoke-ResetCommand | Out-Null
        $repo = New-RepoAhead
        try {
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 60 -RepoPath $repo -IssueFetcher $issue -CiProbe $ciNone
            $res.status | Should Be 'local_ahead_of_remote'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

# ================= v2.2 최종 실행 수리 테스트 =================

Describe 'v2.2-1. 작전 1 run 영수증 자동 저장' {
    It 'op1 run이 postflight까지 도달하면 영수증을 저장한다 (필수 필드 포함)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='implemented; tests: 12 passed (worker self-report)' } }
            $res = Invoke-RunOperation -OperationNumber 1 -IssueNumber 70 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciNone
            $res.status | Should Be 'completed'
            $rc = Get-RunReceipt -Operation 1 -IssueNumber 70 -RepoPath $repo
            $rc | Should Not Be $null
            $rc.operation | Should Be 1
            $rc.issueNumber | Should Be 70
            $rc.worker | Should Be 'grok'
            $rc.startHead | Should Be $res.startHead
            $rc.finalHead | Should Be $res.finalHead
            $rc.postflight.pushComplete | Should Be $true
            $rc.workerSummary | Should Match 'self-report'
            $rc.createdAt | Should Not Be $null
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 70 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.2-2/3/4. review 영수증 자동 복원' {
    It 'review가 StartHead 수동 인수 없이 영수증을 읽는다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 71
            $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[]}' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 71 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $rv.status | Should Be 'reviewed'
            $rv.verdict | Should Be 'PASS'
            Push-Location $repo; $expectedStart = (git rev-parse "HEAD~1").Trim(); Pop-Location
            $rv.startHead | Should Be $expectedStart
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 71 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
    It '영수증이 없으면 review를 중단한다 (review_receipt_missing)' {
        $repo = New-FakeRepo -WithRemote
        try {
            Remove-RunReceipt -Operation 1 -IssueNumber 72 -RepoPath $repo
            $runner = { param($repo,$prompt,$r) throw 'review runner must not run' }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 72 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $rv.status | Should Be 'review_receipt_missing'
            $rv.verdict | Should Be $null
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '현재 HEAD와 영수증 finalHead가 다르면 중단한다 (review_receipt_head_mismatch)' {
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 73 -FinalHeadOverride '0000000000000000000000000000000000000000'
            $runner = { param($repo,$prompt,$r) throw 'review runner must not run' }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 73 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $rv.status | Should Be 'review_receipt_head_mismatch'
            $rv.currentHead | Should Be (Head-Of $repo)
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 73 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.2-5. 검수 프롬프트에 실제 완료 자료(postflight) 포함' {
    It '프롬프트에 worker/종료코드/commitCount/branch/ahead-behind/worktree/push/ci/workerSummary가 들어간다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 74
            $script:pt = $null
            $runner = { param($repo,$prompt,$r) $script:pt = Get-Content -LiteralPath $prompt -Raw -Encoding UTF8; [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[]}' } }
            Invoke-OperationReview -OperationNumber 1 -IssueNumber 74 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner | Out-Null
            $script:pt | Should Match 'worker=grok model=grok-4\.5 effort=high'
            $script:pt | Should Match 'worker 종료코드'
            $script:pt | Should Match 'commitCount='
            $script:pt | Should Match 'branch=main'
            $script:pt | Should Match 'ahead=0 behind=0'
            $script:pt | Should Match 'worktreeClean='
            $script:pt | Should Match 'pushComplete='
            $script:pt | Should Match 'ciStatus='
            $script:pt | Should Match 'remainingProblems'
            $script:pt | Should Match 'workerSummary'
            $script:pt | Should Match '라우터가 재실행한 테스트 결과가 아니다'
            $script:pt | Should Match '변경 diff'
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 74 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.2-6/7. GPT 검수 호출 실패 처리 (JSON 파싱 전 확인)' {
    It '검수 quota 소진 → claude_review_fallback (결함 finding으로 위장하지 않음)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 75
            $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=1; Output='weekly usage limit reached' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 75 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $rv.status | Should Be 'claude_review_fallback'
            $rv.reason | Should Be 'gpt_review_weekly_exhausted'
            @($rv.findings).Count | Should Be 0
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 75 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
    It '일반 실행·인증 실패 → review_worker_failed (결함 finding으로 위장하지 않음)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 76
            $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=1; Output='auth error 401' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 76 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $rv.status | Should Be 'review_worker_failed'
            $rv.verdict | Should Be $null
            @($rv.findings).Count | Should Be 0
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 76 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.2-8/9/10. 검수 JSON 엄격 검증 fail-closed' {
    It '필수 필드 누락 finding (requiredFix 없음) → valid=false' {
        $p = ConvertFrom-StrictReviewJson -Text '{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"high","file":"a.ps1","issue":"x"}]}'
        $p.valid | Should Be $false
        $p.parseError | Should Match 'requiredFix'
    }
    It '알 수 없는 severity → valid=false' {
        $p = ConvertFrom-StrictReviewJson -Text '{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"critical","file":"a.ps1","issue":"x","requiredFix":"y"}]}'
        $p.valid | Should Be $false
        $p.parseError | Should Match 'severity'
    }
    It 'PASS + findings 존재 → valid=false' {
        $p = ConvertFrom-StrictReviewJson -Text '{"verdict":"PASS","findings":[{"severity":"medium","file":"a.ps1","issue":"x","requiredFix":"y"}]}'
        $p.valid | Should Be $false
        $p.parseError | Should Be 'pass_verdict_with_findings'
    }
    It 'REPAIR_REQUIRED + findings 없음 → valid=false' {
        $p = ConvertFrom-StrictReviewJson -Text '{"verdict":"REPAIR_REQUIRED","findings":[]}'
        $p.valid | Should Be $false
        $p.parseError | Should Be 'repair_required_without_findings'
    }
}

Describe 'v2.2-11/12. 수리 결과 정직 판정 + 영수증 자동 복원' {
    It '수리 성공 → repair_completed_review_pending (영수증에서 PostReviewHead/Target 자동 복원)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 77
            $findings = @([pscustomobject]@{ severity='high'; file='b.txt'; issue='x'; requiredFix='y' })
            Save-ReviewReceipt -Operation 1 -IssueNumber 77 -RepoPath $repo -Verdict 'REPAIR_REQUIRED' -Findings $findings -PostReviewHead (Head-Of $repo) -OriginalWorker 'grok' | Out-Null
            $rep = { param($r,$repo,$prompt) Push-Location $repo; "fix" | Out-File fix.txt -Encoding utf8; git add .; git commit -q -m fix; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $hr = Invoke-RepairCommand -OperationNumber 1 -IssueNumber 77 -RepoPath $repo -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
            $hr.status | Should Be 'repair_completed_review_pending'
            $hr.worker | Should Be 'grok'
            $hr.repairAttempted | Should Be $true
            $hr.finalReviewRequired | Should Be $true
            $hr.originalFindingCount | Should Be 1
            $hr.repairPostflight.pushComplete | Should Be $true
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 77 -RepoPath $repo; Remove-ReviewReceipt -Operation 1 -IssueNumber 77 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
    It '원래 blocker가 있어도 "남은 blocker"라고 단정하지 않는다 (재검수 없음)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $findings = @([pscustomobject]@{ severity='blocker'; file='a.txt'; issue='x'; requiredFix='y' })
            Save-TestRepairReceipts -Repo $repo -IssueNum 78 -Findings $findings
            $rep = { param($r,$repo,$prompt) Push-Location $repo; "fix" | Out-File fix.txt -Encoding utf8; git add .; git commit -q -m fix; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 78 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead (Head-Of $repo) -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
            $hr.status | Should Be 'repair_completed_review_pending'
            ($hr.PSObject.Properties.Name -contains 'remainingBlockingFindings') | Should Be $false
            ($hr.PSObject.Properties.Name -contains 'repairVerdict') | Should Be $false
            $hr.originalFindingCount | Should Be 1
            $hr.finalReviewRequired | Should Be $true
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '수리 영수증 없음 → repair_receipt_missing (인수 추측 금지)' {
        $repo = New-FakeRepo -WithRemote
        try {
            Remove-RunReceipt -Operation 1 -IssueNumber 79 -RepoPath $repo
            Remove-ReviewReceipt -Operation 1 -IssueNumber 79 -RepoPath $repo
            $hr = Invoke-RepairCommand -OperationNumber 1 -IssueNumber 79 -RepoPath $repo -IssueFetcher $issue -CiProbe $ciNone
            $hr.status | Should Be 'repair_receipt_missing'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.2-13. 수리 작업자 사용량 준수' {
    It 'Grok exhausted → grok 수리 금지 (repair_worker_unavailable, 워커 미호출, 교체 없음)' {
        Invoke-ResetCommand | Out-Null
        Invoke-SetCommand -Target grok -Value 'exhausted' | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            Save-TestRepairReceipts -Repo $repo -IssueNum 80 -Findings $findings
            $script:rc3 = 0
            $rep = { param($r,$repo,$prompt) $script:rc3++; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 80 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead (Head-Of $repo) -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
            $hr.status | Should Be 'repair_worker_unavailable'
            $hr.repairAttempted | Should Be $false
            $script:rc3 | Should Be 0
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
    It 'GPT 구현 run은 사용량 상태와 무관하게 repair 자격이 없다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            $script:rc4 = 0
            $rep = { param($r,$repo,$prompt) $script:rc4++; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            foreach ($v in @('80','reserved','exhausted')) {
                Invoke-SetCommand -Target gpt -Value $v | Out-Null
                Save-TestRunReceipt -Repo $repo -IssueNum 81 -Worker 'gpt'
                $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 81 -RepoPath $repo -Findings $findings -OriginalWorker 'gpt' -PostReviewHead (Head-Of $repo) -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
                $hr.status | Should Be 'repair_not_eligible'
                $hr.reason | Should Be 'run_unverified_or_ineligible'
            }
            $script:rc4 | Should Be 0
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

Describe 'v2.2-14. Skill의 claude_execute 수행 절차' {
    It 'operation-1/2/3 SKILL.md에 claude_only_required 중단 + claude_execute 수행 절차가 있다' {
        foreach ($n in @('operation-1','operation-2','operation-3')) {
            $raw = Get-Content -LiteralPath (Join-Path $SkillsRoot "$n\SKILL.md") -Raw -Encoding UTF8
            $raw | Should Match 'claude_only_required'
            $raw | Should Match 'resumeCommand'
            $raw | Should Match 'orderPath'
            $raw | Should Match 'postflightCommand'
            $raw | Should Match '표시만 하고 끝내지 않는다'
        }
    }
    It 'operation-1 SKILL.md가 실제 실행 순서(run→review→repair→종료검토)와 영수증 자동 복원을 명시한다' {
        $raw = Get-Content -LiteralPath (Join-Path $SkillsRoot 'operation-1\SKILL.md') -Raw -Encoding UTF8
        $raw | Should Match '실제 실행 순서'
        $raw | Should Match 'repair_completed_review_pending'
        $raw | Should Match '자동 복원'
        $raw | Should Not Match '\-StartHead <'
        $raw | Should Not Match '\-PostReviewHead <'
        $raw | Should Not Match '\-FindingsFile <'
    }
}

Describe 'v2.2-15/16/17. CI run 생성 지연 polling' {
    $lsEmpty = { param($p) @{ ok = $true; runs = @() } }
    It '워크플로 있음 + polling 종료까지 run 없음 → unavailable (not-requested/completed 금지)' {
        $ci = Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $lsEmpty -PollIntervalSeconds 0 -MaxAttempts 3
        $ci | Should Be 'unavailable'
        $ci | Should Not Be 'not-requested'
        $ci | Should Not Be 'success'
    }
    It '워크플로 없음 → not-requested (API 호출 없음)' {
        $script:lsCalled = $false
        $ls = { param($p) $script:lsCalled = $true; @{ ok = $true; runs = @() } }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $false -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 3) | Should Be 'not-requested'
        $script:lsCalled | Should Be $false
    }
    It 'Test-CiWorkflowPresent: 워크플로 파일 유무를 로컬로 판정한다' {
        $repo = New-FakeRepo
        try {
            (Test-CiWorkflowPresent -RepoPath $repo) | Should Be $false
            New-Item -ItemType Directory -Force (Join-Path $repo '.github\workflows') | Out-Null
            "name: ci" | Out-File (Join-Path $repo '.github\workflows\ci.yml') -Encoding utf8
            (Test-CiWorkflowPresent -RepoPath $repo) | Should Be $true
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'run 발견 + completed/success → success' {
        $ls = { param($p) @{ ok = $true; runs = @([pscustomobject]@{ headSha='abc123'; status='completed'; conclusion='success' }) } }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 3) | Should Be 'success'
    }
    It 'run 발견 + 실패 → failure' {
        $ls = { param($p) @{ ok = $true; runs = @([pscustomobject]@{ headSha='abc123'; status='completed'; conclusion='failure' }) } }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 3) | Should Be 'failure'
    }
    It 'run 발견 + 진행 중 → pending' {
        $ls = { param($p) @{ ok = $true; runs = @([pscustomobject]@{ headSha='abc123'; status='in_progress'; conclusion=$null }) } }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 3) | Should Be 'pending'
    }
    It 'run 생성 지연 후 발견 → polling으로 success (2번째 시도)' {
        $script:ciAttempt = 0
        $ls = {
            param($p)
            $script:ciAttempt++
            if ($script:ciAttempt -lt 2) { return @{ ok = $true; runs = @() } }
            return @{ ok = $true; runs = @([pscustomobject]@{ headSha='abc123'; status='completed'; conclusion='success' }) }
        }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 6) | Should Be 'success'
        $script:ciAttempt | Should Be 2
    }
    It 'API 오류 → unavailable' {
        $ls = { param($p) @{ ok = $false; runs = @() } }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 3) | Should Be 'unavailable'
    }
}

# ================= v2.3 실전 투입 전 구조 수리 테스트 =================

Describe 'v2.3-1. Claude-only 전용 Skill 라우팅' {
    It 'resumeCommand: 작전 1 → /operation-1-claude, 작전 3 logic → /operation-3-claude, 작전 2·3 mechanical 유지' {
        (Get-ResumeCommand -Operation 1 -IssueNumber 8) | Should Be '/operation-1-claude 8'
        (Get-ResumeCommand -Operation 3 -IssueNumber 9 -Kind logic) | Should Be '/operation-3-claude 9'
        (Get-ResumeCommand -Operation 2 -IssueNumber 8) | Should Be '/operation-2 8 --claude-only'
        (Get-ResumeCommand -Operation 3 -IssueNumber 9 -Kind mechanical) | Should Be '/operation-3 9 --kind mechanical --claude-only'
    }
    It 'run 수준: 작전 1 claude_only_required의 resume이 Sonnet 전용 Skill을 가리킨다' {
        Invoke-ResetCommand | Out-Null
        Invoke-SetCommand -Target grok -Value 'exhausted' | Out-Null
        Invoke-SetCommand -Target gpt -Value '90' | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $res = Invoke-RunOperation -OperationNumber 1 -IssueNumber 91 -RepoPath $repo -IssueFetcher $issue -CiProbe $ciNone
            $res.status | Should Be 'claude_only_required'
            $res.resumeCommand | Should Be '/operation-1-claude 91'
            $res.requiredModel | Should Be 'claude-sonnet-5'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
    It 'run 수준: 작전 3 logic claude_only_required의 resume이 /operation-3-claude' {
        Invoke-ResetCommand | Out-Null
        Invoke-SetCommand -Target grok -Value 'exhausted' | Out-Null
        Invoke-SetCommand -Target gpt -Value '90' | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $res = Invoke-RunOperation -OperationNumber 3 -Kind logic -IssueNumber 92 -RepoPath $repo -IssueFetcher $issue -CiProbe $ciNone
            $res.status | Should Be 'claude_only_required'
            $res.resumeCommand | Should Be '/operation-3-claude 92'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
    It '전용 Skill 존재 + frontmatter가 config claudeOnly 요구 모델/effort와 구조적으로 일치' {
        $fm1 = Get-SkillFrontmatter -Path (Join-Path $SkillsRoot 'operation-1-claude\SKILL.md')
        $fm1.name | Should Be 'operation-1-claude'
        $fm1.model | Should Be $cfg.claudeOnly.'1'.model
        $fm1.effort | Should Be $cfg.claudeOnly.'1'.effort
        $fm1['disable-model-invocation'] | Should Be 'true'
        $fm3 = Get-SkillFrontmatter -Path (Join-Path $SkillsRoot 'operation-3-claude\SKILL.md')
        $fm3.name | Should Be 'operation-3-claude'
        $fm3.model | Should Be $cfg.claudeOnly.'3'.logic.model
        $fm3.effort | Should Be $cfg.claudeOnly.'3'.logic.effort
        $fm3['disable-model-invocation'] | Should Be 'true'
    }
}

Describe 'v2.3-2. 워커 오류 3분류 (weekly/transient/provider)' {
    It '분류기: weekly/transient/provider/none을 구분한다' {
        (Get-WorkerErrorClass -Text 'weekly limit reached') | Should Be 'weekly_exhausted'
        (Get-WorkerErrorClass -Text 'usage limit reached for this plan') | Should Be 'quota_unknown'
        (Get-WorkerErrorClass -Text 'rate limit exceeded') | Should Be 'transient_rate_limit'
        (Get-WorkerErrorClass -Text 'HTTP 429: too many requests, retry after 20s') | Should Be 'transient_rate_limit'
        (Get-WorkerErrorClass -Text 'invalid api key') | Should Be 'provider_failure'
        (Get-WorkerErrorClass -Text 'model not found: grok-9') | Should Be 'provider_failure'
        (Get-WorkerErrorClass -Text 'build failed') | Should Be 'none'
    }
    It 'transient rate limit → usage-state 불변 + 재시도 최대 1회 + transient_rate_limited 중단' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:trc = 0
            $grTransient = { param($r,$repo,$prompt) $script:trc++; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='rate limit exceeded' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 94 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grTransient -CiProbe $ciNone
            $res.status | Should Be 'transient_rate_limited'
            $res.usageStateChanged | Should Be $false
            $script:trc | Should Be 2   # 최초 1회 + config 재시도 1회, 그 이상 없음
            $s = Get-UsageState
            $s.grok.status | Should Be 'available'
            $s.grok.percent | Should Be 0
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'transient 오류에서 자동 Plan B 금지 (GPT 미호출)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:gptCalled = $false
            $grTransient = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='too many requests' } }
            $gp = { param($r,$repo,$prompt) $script:gptCalled = $true; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 95 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grTransient -GptRunner $gp -CiProbe $ciNone
            $res.status | Should Be 'transient_rate_limited'
            $script:gptCalled | Should Be $false
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'weekly 소진에서만 usage-state exhausted/100 저장 + Plan B 전환' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $grWeekly = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;Output='weekly limit reached' } }
            $gpOk = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 96 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grWeekly -GptRunner $gpOk -CiProbe $ciNone
            $res.worker | Should Be 'gpt'
            $res.status | Should Be 'completed'
            $s = Get-UsageState
            $s.grok.status | Should Be 'exhausted'
            $s.grok.percent | Should Be 100
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

Describe 'v2.3-3. 동일 SHA 모든 workflow run 집계' {
    It '여러 workflow all-success → success' {
        $ls = { param($p) @{ ok = $true; runs = @(
            [pscustomobject]@{ headSha='abc123'; status='completed'; conclusion='success' },
            [pscustomobject]@{ headSha='abc123'; status='completed'; conclusion='success' },
            [pscustomobject]@{ headSha='other';  status='completed'; conclusion='failure' }
        ) } }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 3) | Should Be 'success'
    }
    It 'success+failure → failure (첫 run만 보지 않는다)' {
        $ls = { param($p) @{ ok = $true; runs = @(
            [pscustomobject]@{ headSha='abc123'; status='completed'; conclusion='success' },
            [pscustomobject]@{ headSha='abc123'; status='completed'; conclusion='failure' }
        ) } }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 3) | Should Be 'failure'
    }
    It 'success+pending(in_progress/queued) → pending' {
        $ls = { param($p) @{ ok = $true; runs = @(
            [pscustomobject]@{ headSha='abc123'; status='completed'; conclusion='success' },
            [pscustomobject]@{ headSha='abc123'; status='in_progress'; conclusion=$null },
            [pscustomobject]@{ headSha='abc123'; status='queued'; conclusion=$null }
        ) } }
        (Get-CiStatus -RepoPath $HOME -FinalHead 'abc123' -WorkflowPresent $true -RunLister $ls -PollIntervalSeconds 0 -MaxAttempts 3) | Should Be 'pending'
    }
}

Describe 'v2.3-4. 런타임 상태 저장소 네임스페이스' {
    It '저장소 A/B가 동일 이슈 번호를 써도 영수증이 서로 덮어쓰지 않는다' {
        $repoA = New-FakeRepo -WithRemote
        $repoB = New-FakeRepo -WithRemote
        try {
            Push-Location $repoA; "a2" | Out-File a2.txt -Encoding utf8; git add .; git commit -q -m a2; Pop-Location
            Push-Location $repoB; "b2" | Out-File b2.txt -Encoding utf8; git add .; git commit -q -m b2; Pop-Location
            Save-TestRunReceipt -Repo $repoA -IssueNum 90
            Save-TestRunReceipt -Repo $repoB -IssueNum 90
            $pA = Get-RunReceiptPath -Operation 1 -IssueNumber 90 -RepoPath $repoA
            $pB = Get-RunReceiptPath -Operation 1 -IssueNumber 90 -RepoPath $repoB
            $pA | Should Not Be $pB
            $rcA = Get-RunReceipt -Operation 1 -IssueNumber 90 -RepoPath $repoA
            $rcB = Get-RunReceipt -Operation 1 -IssueNumber 90 -RepoPath $repoB
            $rcA.finalHead | Should Be (Head-Of $repoA)
            $rcB.finalHead | Should Be (Head-Of $repoB)
            $rcA.finalHead | Should Not Be $rcB.finalHead
            $rcA.repoRoot | Should Not Be $rcB.repoRoot
        } finally {
            Remove-RunReceipt -Operation 1 -IssueNumber 90 -RepoPath $repoA
            Remove-RunReceipt -Operation 1 -IssueNumber 90 -RepoPath $repoB
            Remove-Item -Recurse -Force $repoA, $repoB
        }
    }
    It '다른 저장소의 영수증이면 review가 repository_receipt_mismatch로 중단한다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 93
            # 영수증의 저장소 정보를 다른 저장소로 조작 (이동/복사된 영수증 시뮬레이션)
            $rp = Get-RunReceiptPath -Operation 1 -IssueNumber 93 -RepoPath $repo
            $j = Get-Content -LiteralPath $rp -Raw -Encoding UTF8 | ConvertFrom-Json
            $j.ownerRepo = 'someone/other-repo'
            $j.repoRoot = 'C:\definitely\other\repo'
            $j | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $rp -Encoding UTF8
            $script:revCalled = $false
            $runner = { param($repo,$prompt,$r) $script:revCalled = $true; [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[]}' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 93 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $rv.status | Should Be 'repository_receipt_mismatch'
            $script:revCalled | Should Be $false
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 93 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.3-5. review/repair 실행 자격 코드 강제' {
    It 'worker=gpt 영수증 → review_not_eligible (Sol 자기검수 금지, GPT 미호출)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 97 -Worker 'gpt'
            $script:rev2 = $false
            $runner = { param($repo,$prompt,$r) $script:rev2 = $true; [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[]}' } }
            $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 97 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $rv.status | Should Be 'review_not_eligible'
            $rv.reason | Should Match 'worker_not_grok'
            $script:rev2 | Should Be $false
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 97 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
    It 'no_commit/worker_failed 영수증 → review_not_eligible' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            $runner = { param($repo,$prompt,$r) throw 'review runner must not run' }
            foreach ($st in @('no_commit','worker_failed')) {
                Save-TestRunReceipt -Repo $repo -IssueNum 98 -Status $st
                $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 98 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
                $rv.status | Should Be 'review_not_eligible'
                $rv.reason | Should Match 'run_not_completed'
            }
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 98 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
    It '유효한 grok completed 계열 영수증만 review를 허용한다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; Pop-Location
            $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=0; Output='{"verdict":"PASS","findings":[]}' } }
            foreach ($st in @('completed','completed_ci_pending','completed_ci_unavailable')) {
                Save-TestRunReceipt -Repo $repo -IssueNum 99 -Status $st
                $rv = Invoke-OperationReview -OperationNumber 1 -IssueNumber 99 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
                $rv.status | Should Be 'reviewed'
                $rv.verdict | Should Be 'PASS'
            }
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 99 -RepoPath $repo; Remove-Item -Recurse -Force $repo }
    }
    It '작전 2/3은 review·repair를 거부한다 (GPT 미호출)' {
        $repo = New-FakeRepo -WithRemote
        try {
            $runner = { param($repo,$prompt,$r) throw 'must not run' }
            (Invoke-OperationReview -OperationNumber 2 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner).status | Should Be 'review_not_eligible'
            (Invoke-OperationReview -OperationNumber 3 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner).status | Should Be 'review_not_eligible'
            (Invoke-RepairCommand -OperationNumber 2 -IssueNumber 5 -RepoPath $repo -IssueFetcher $issue).status | Should Be 'repair_not_eligible'
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            (Invoke-OperationRepair -OperationNumber 3 -IssueNumber 5 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead (Head-Of $repo) -IssueFetcher $issue).status | Should Be 'repair_not_eligible'
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

Describe 'v2.3-6. Skill 경로 이식성' {
    It '모든 operation Skill에 C:\Users\USER 하드코딩이 없고 $env:USERPROFILE을 쓴다' {
        foreach ($n in @('operation','operation-1','operation-2','operation-3','operation-1-claude','operation-3-claude')) {
            $raw = Get-Content -LiteralPath (Join-Path $SkillsRoot "$n\SKILL.md") -Raw -Encoding UTF8
            $raw | Should Not Match 'C:\\Users\\USER'
            $raw.Contains('$env:USERPROFILE\.claude\operation-router') | Should Be $true
        }
    }
}

Describe 'v2.3-7. 실패 확정 시 CI 미조회' {
    It 'worker 실패 시 CI polling을 하지 않는다 (ciStatus not-checked)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:ciCalls = 0
            $ciCount = { param($h) $script:ciCalls++; 'success' }
            $grFail = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='build failed' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 100 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grFail -CiProbe $ciCount
            $res.status | Should Be 'worker_failed'
            $res.ciStatus | Should Be 'not-checked'
            $script:ciCalls | Should Be 0
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It 'no_commit에서도 CI를 조회하지 않고, 게이트 통과 시에만 조회한다' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:ciCalls2 = 0
            $ciCount2 = { param($h) $script:ciCalls2++; 'success' }
            $grNoop = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 101 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grNoop -CiProbe $ciCount2
            $res.status | Should Be 'no_commit'
            $res.ciStatus | Should Be 'not-checked'
            $script:ciCalls2 | Should Be 0
            $grPush = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $res2 = Invoke-RunOperation -OperationNumber 2 -IssueNumber 102 -RepoPath $repo -IssueFetcher $issue -GrokRunner $grPush -CiProbe $ciCount2
            $res2.status | Should Be 'completed'
            $script:ciCalls2 | Should Be 1
        } finally { Remove-Item -Recurse -Force $repo }
    }
}

# ================= v2.3.1 실전 실행 수리 테스트 =================

Describe 'v2.3.1-1~4. shell 독립 실행기와 Skill 경로' {
    $allSkillNames = @('operation','operation-1','operation-2','operation-3','operation-1-claude','operation-3-claude')

    It '1. Skill 6종이 run-operation.ps1을 직접 호출하지 않는다' {
        foreach ($n in $allSkillNames) {
            $raw = Get-Content -LiteralPath (Join-Path $SkillsRoot "$n\SKILL.md") -Raw -Encoding UTF8
            $raw | Should Not Match 'run-operation\.ps1'
            $raw | Should Match 'operation-router\.cmd'
        }
    }

    It '2. operation-router.cmd가 존재하고 사용자 독립 경로만 사용한다' {
        (Test-Path -LiteralPath $LauncherPath) | Should Be $true
        $lines = @(Get-Content -LiteralPath $LauncherPath -Encoding Default)
        $lines[0] | Should Be '@echo off'
        $lines[1] | Should Be 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\operation-router\scripts\run-operation.ps1" %*'
        ($lines -join "`n") | Should Not Match 'C:\\Users\\USER'
    }

    It '3. Git Bash 방식으로 실행기 경로를 조립하고 Skill 실제 문자열과 일치한다' {
        (Test-Path -LiteralPath $GitBashPath) | Should Be $true
        $bashPath = (& $GitBashPath -lc 'USERPROFILE=/c/Users/Mock_User; printf %s "$USERPROFILE/.claude/operation-router/operation-router.cmd"')
        $bashPath | Should Be '/c/Users/Mock_User/.claude/operation-router/operation-router.cmd'
        foreach ($n in $allSkillNames) {
            $raw = Get-Content -LiteralPath (Join-Path $SkillsRoot "$n\SKILL.md") -Raw -Encoding UTF8
            $raw.Contains('$USERPROFILE/.claude/operation-router/operation-router.cmd') | Should Be $true
        }
    }

    It '4. PowerShell 방식으로 실행기 경로를 조립하고 Skill 실제 문자열과 일치한다' {
        $mockProfile = 'C:\Users\Mock User'
        (Join-Path $mockProfile '.claude\operation-router\operation-router.cmd') | Should Be 'C:\Users\Mock User\.claude\operation-router\operation-router.cmd'
        foreach ($n in $allSkillNames) {
            $raw = Get-Content -LiteralPath (Join-Path $SkillsRoot "$n\SKILL.md") -Raw -Encoding UTF8
            $raw.Contains('$env:USERPROFILE\.claude\operation-router\operation-router.cmd') | Should Be $true
        }
    }
}

Describe 'v2.3.1-5~8. Grok → GPT → Claude 연속 전환' {
    It '5. Grok weekly → GPT success' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;ErrorClass='weekly_exhausted';Output='weekly limit reached' } }
            $gp = { param($r,$repo,$prompt) Push-Location $repo; "ok" | Out-File done.txt -Encoding utf8; git add .; git commit -q -m done; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;ErrorClass='none';Output='ok' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 105 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -GptRunner $gp -CiProbe $ciNone
            $res.status | Should Be 'completed'
            $res.worker | Should Be 'gpt'
            (Get-UsageState).grok.status | Should Be 'exhausted'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }

    It '6. Grok weekly → GPT weekly → Claude-only' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:grok61 = 0; $script:gpt61 = 0
            $gr = { param($r,$repo,$prompt) $script:grok61++; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;ErrorClass='weekly_exhausted';Output='weekly limit reached' } }
            $gp = { param($r,$repo,$prompt) $script:gpt61++; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;ErrorClass='weekly_exhausted';Output='weekly usage limit reached' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 106 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -GptRunner $gp -CiProbe $ciNone
            $res.status | Should Be 'claude_only_required'
            $res.resumeCommand | Should Be '/operation-2 106 --claude-only'
            $script:grok61 | Should Be 1
            $script:gpt61 | Should Be 1
            $s = Get-UsageState
            $s.grok.status | Should Be 'exhausted'; $s.gpt.status | Should Be 'exhausted'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }

    It '7. Grok weekly → GPT transient → 재시도 1회 후 중단' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:gpt71 = 0
            $gr = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;ErrorClass='weekly_exhausted';Output='weekly limit reached' } }
            $gp = { param($r,$repo,$prompt) $script:gpt71++; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;ErrorClass='transient_rate_limit';Output='HTTP 429 too many requests' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 107 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -GptRunner $gp -CiProbe $ciNone
            $res.status | Should Be 'transient_rate_limited'
            $script:gpt71 | Should Be 2
            $s = Get-UsageState
            $s.grok.status | Should Be 'exhausted'; $s.gpt.status | Should Be 'available'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }

    It '8. Grok weekly → GPT 부분 변경+weekly → Claude fallback 차단' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $gr = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;ErrorClass='weekly_exhausted';Output='weekly limit reached' } }
            $gp = { param($r,$repo,$prompt) Push-Location $repo; "partial" | Out-File partial.txt -Encoding utf8; Pop-Location; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;ErrorClass='weekly_exhausted';Output='weekly limit reached' } }
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 108 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -GptRunner $gp -CiProbe $ciNone
            $res.status | Should Be 'partial_worker_changes'
            $res.worker | Should Be 'gpt'
            $res.fallbackAttempted | Should Be $true
            (Get-UsageState).gpt.status | Should Be 'exhausted'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

Describe 'v2.3.1-9~11. review·repair 공통 오류 정책' {
    It '9. GPT review weekly → GPT exhausted 저장 + claude_review_fallback' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File review.txt -Encoding utf8; git add .; git commit -q -m review; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 109
            $runner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=1;Success=$false;ErrorClass='weekly_exhausted';Output='weekly usage limit reached' } }
            $res = Invoke-OperationReview -OperationNumber 1 -IssueNumber 109 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $res.status | Should Be 'claude_review_fallback'
            $s = Get-UsageState
            $s.gpt.status | Should Be 'exhausted'; $s.gpt.percent | Should Be 100
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 109 -RepoPath $repo; Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }

    It '10. repair weekly → 해당 공급자 exhausted 저장 + repair_quota_exhausted' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            Save-TestRepairReceipts -Repo $repo -IssueNum 110 -Findings $findings
            $runner = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$true;ErrorClass='weekly_exhausted';Output='weekly limit reached' } }
            $res = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 110 -RepoPath $repo -Findings $findings -OriginalWorker grok -PostReviewHead (Head-Of $repo) -IssueFetcher $issue -RepairRunner $runner -CiProbe $ciNone
            $res.status | Should Be 'repair_quota_exhausted'
            $s = Get-UsageState
            $s.grok.status | Should Be 'exhausted'; $s.grok.percent | Should Be 100
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }

    It '11. review/repair transient는 별도 상태이고 usage-state 불변' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            Push-Location $repo; "y" | Out-File transient.txt -Encoding utf8; git add .; git commit -q -m transient; Pop-Location
            Save-TestRunReceipt -Repo $repo -IssueNum 111
            $reviewRunner = { param($repo,$prompt,$r) [pscustomobject]@{ ExitCode=1;Success=$false;ErrorClass='transient_rate_limit';Output='too many requests' } }
            $review = Invoke-OperationReview -OperationNumber 1 -IssueNumber 111 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $reviewRunner
            $review.status | Should Be 'review_transient_rate_limited'
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            Save-TestRepairReceipts -Repo $repo -IssueNum 112 -Findings $findings
            $repairRunner = { param($r,$repo,$prompt) [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;ErrorClass='transient_rate_limit';Output='HTTP 429' } }
            $repair = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 112 -RepoPath $repo -Findings $findings -OriginalWorker grok -PostReviewHead (Head-Of $repo) -IssueFetcher $issue -RepairRunner $repairRunner -CiProbe $ciNone
            $repair.status | Should Be 'repair_transient_rate_limited'
            $s = Get-UsageState
            $s.grok.status | Should Be 'available'; $s.gpt.status | Should Be 'available'
        } finally { Remove-RunReceipt -Operation 1 -IssueNumber 111 -RepoPath $repo; Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

Describe 'v2.3.1-12~15. quota 축소와 fallback 루프 가드' {
    It '12. 일반 quota exceeded는 weekly로 분류되지 않는다' {
        (Get-WorkerErrorClass -Text 'quota exceeded') | Should Be 'quota_unknown'
        (Get-WorkerErrorClass -Text 'you have exceeded your current quota') | Should Be 'quota_unknown'
    }

    It '13. HTTP 429 + quota exceeded는 weekly가 아니라 transient 또는 quota_unknown이다' {
        $class = Get-WorkerErrorClass -Text 'HTTP 429: quota exceeded, retry later'
        $class | Should Be 'transient_rate_limit'
        $class | Should Not Be 'weekly_exhausted'
    }

    It '14. 명시적 weekly limit만 exhausted/100으로 저장한다' {
        Invoke-ResetCommand | Out-Null
        $state = Get-UsageState
        $localConfig = Get-Config
        $localConfig.transientRetry.delaySeconds = 0
        $unknown = Invoke-WorkerWithErrorPolicy -Provider grok -State $state -Config $localConfig -InvokeWorker { [pscustomobject]@{ ExitCode=1;Success=$false;Output='quota exceeded' } }
        $unknown.ErrorClass | Should Be 'quota_unknown'
        (Get-UsageState).grok.status | Should Be 'available'
        $weekly = Invoke-WorkerWithErrorPolicy -Provider grok -State (Get-UsageState) -Config $localConfig -InvokeWorker { [pscustomobject]@{ ExitCode=1;Success=$false;Output='weekly limit reached' } }
        $weekly.ErrorClass | Should Be 'weekly_exhausted'
        $s = Get-UsageState
        $s.grok.status | Should Be 'exhausted'; $s.grok.percent | Should Be 100
        Invoke-ResetCommand | Out-Null
    }

    It '15. 동일 fallback 공급자의 두 번째 진입을 차단해 무한 루프를 막는다' {
        Invoke-ResetCommand | Out-Null
        $state = Get-UsageState
        $state.grok.status = 'exhausted'; $state.grok.percent = 100
        $config = Get-Config
        $repo = New-FakeRepo -WithRemote
        $prompt = New-TempOrderFile -Content 'mock'
        try {
            $snapshot = Get-StartSnapshot -RepoPath $repo
            $route = [pscustomobject]@{ status='routed'; worker='grok'; model='grok-4.5'; effort='medium' }
            $log = New-Object System.Collections.Generic.List[string]
            $script:loopGptCalled = 0
            $gp = { param($r,$repo,$prompt) $script:loopGptCalled++; [pscustomobject]@{ ExitCode=0;Success=$true;Output='must not run' } }
            $res = Invoke-QuotaFallback -Route $route -OperationNumber 2 -IssueNumber 115 -Kind logic -State $state -Config $config `
                -RepoPath $repo -PromptPath $prompt -Order 'mock' -Snapshot $snapshot -GptRunner $gp -Log $log -FallbackProviders @('grok','gpt')
            $res.TerminalOutput.status | Should Be 'fallback_loop_blocked'
            $script:loopGptCalled | Should Be 0
        } finally { Remove-TempOrderFile -Path $prompt; Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

# ================= v2.3.2 Grok headless Cancelled 수리 테스트 =================
Describe 'v2.3.2-1~7. grok 헤드리스 권한 인수 (acceptEdits 제거, v2.3.3: alwaysApprove + deny)' {
    It '1~7. 인수에 acceptEdits 없음, --always-approve 적용(--permission-mode 없음), allow/deny 규칙 적용, 추측 플래그 없음' {
        $tmp = New-TempOrderFile -Content 'x'
        try {
            $cap = { param($fp,$al) [pscustomobject]@{ ExitCode=0; Output='{"stopReason":"EndTurn"}' } }
            $r = Invoke-GrokWorker -Cwd $HOME -Model 'grok-4.5' -Effort 'low' -MaxTurns 40 -PromptFilePath $tmp -NoPlan $true -NoSubagents $true -Runner $cap
            $joined = ($r.ArgumentList -join ' ')
            $joined | Should Not Match 'acceptEdits'                              # 1
            ($r.ArgumentList -contains '--always-approve') | Should Be $true      # 2 (v2.3.3)
            $joined | Should Not Match '--permission-mode'
            $joined | Should Not Match 'dontAsk'
            ($r.ArgumentList -contains 'Read') | Should Be $true                  # 3
            ($r.ArgumentList -contains 'Grep') | Should Be $true
            ($r.ArgumentList -contains 'Edit') | Should Be $true
            ($r.ArgumentList -contains 'Bash(*)') | Should Be $true
            ($r.ArgumentList -contains 'Bash(git reset --hard*)') | Should Be $true   # 4
            ($r.ArgumentList -contains 'Bash(git clean*)') | Should Be $true          # 5
            ($r.ArgumentList -contains 'Bash(git push --force*)') | Should Be $true   # 6
            ($r.ArgumentList -contains 'Bash(rm -rf*)') | Should Be $true
            $joined | Should Not Match 'no-auto-update'                           # 7: 없는 플래그를 추측해 넣지 않음
            $r.PermissionMode | Should Be 'alwaysApprove'
        } finally { Remove-TempOrderFile -Path $tmp }
    }
    It '4~6b. deny가 allow보다 뒤가 아니라 둘 다 존재하며 위험 명령을 차단 목록에 포함' {
        $tmp = New-TempOrderFile -Content 'x'
        try {
            $cap = { param($fp,$al) [pscustomobject]@{ ExitCode=0; Output='{"stopReason":"EndTurn"}' } }
            $r = Invoke-GrokWorker -Cwd $HOME -Model 'grok-4.5' -Effort 'low' -MaxTurns 40 -PromptFilePath $tmp -Runner $cap
            $denyCount = @($r.ArgumentList | Where-Object { $_ -eq '--deny' }).Count
            $denyCount | Should Be 19
            $allowCount = @($r.ArgumentList | Where-Object { $_ -eq '--allow' }).Count
            $allowCount | Should Be 4
        } finally { Remove-TempOrderFile -Path $tmp }
    }
    It 'v2.4.0: deny 목록이 사양서 9-1 위험 명령을 1차 차단으로 포함한다' {
        $deny = @((Get-Config).grok.headlessPermissions.deny)
        foreach ($needle in @('git reset --merge','git reset --keep','git push*+*','rm -r -f','rmdir /s','rd /s','format ','diskpart','shutdown','reg delete')) {
            (@($deny | Where-Object { $_ -like "*$needle*" }).Count) | Should BeGreaterThan 0
        }
    }
}

Describe 'v2.3.2-8,9,14,15,16. stopReason JSON 분류 (exit 0을 성공으로 간주하지 않음)' {
    It '8~9. exit 0 + stopReason Cancelled → Success false + worker_cancelled' {
        $c = Get-GrokResultClassification -ExitCode 0 -Output '{"text":"...","stopReason":"Cancelled","sessionId":"s1"}'
        $c.Success | Should Be $false
        $c.ErrorClass | Should Be 'worker_cancelled'
        $c.StopReason | Should Be 'Cancelled'
        $c.SessionId | Should Be 's1'
        $c.QuotaExhausted | Should Be $false
    }
    It '9b. Aborted 계열도 worker_cancelled' {
        (Get-GrokResultClassification -ExitCode 0 -Output '{"stopReason":"Aborted"}').ErrorClass | Should Be 'worker_cancelled'
    }
    It '14. exit 0 + 잘못된 JSON → worker_protocol_error' {
        $c = Get-GrokResultClassification -ExitCode 0 -Output 'this is not json'
        $c.Success | Should Be $false
        $c.ErrorClass | Should Be 'worker_protocol_error'
    }
    It '15. stopReason MaxTurns → worker_turn_limit' {
        $c = Get-GrokResultClassification -ExitCode 0 -Output '{"stopReason":"MaxTurns"}'
        $c.ErrorClass | Should Be 'worker_turn_limit'
        $c.Success | Should Be $false
    }
    It '16. 정상 stopReason(EndTurn) → Success true, none' {
        $c = Get-GrokResultClassification -ExitCode 0 -Output '{"stopReason":"EndTurn","text":"done"}'
        $c.Success | Should Be $true
        $c.ErrorClass | Should Be 'none'
    }
    It '분류 우선순위 보존: weekly/transient/provider는 stopReason보다 우선' {
        (Get-GrokResultClassification -ExitCode 1 -Output 'weekly limit reached').ErrorClass | Should Be 'weekly_exhausted'
        (Get-GrokResultClassification -ExitCode 1 -Output 'weekly limit reached').QuotaExhausted | Should Be $true
        (Get-GrokResultClassification -ExitCode 1 -Output 'rate limit exceeded').ErrorClass | Should Be 'transient_rate_limit'
    }
}

Describe 'F1. 정상 종료 텍스트의 일반 오류 단어가 성공을 실패로 뒤집지 않는다' {
    # 회귀: 정상 종료(exit 0 + parsed JSON + 정상 stopReason)의 어시스턴트 완료 보고 텍스트에
    # provider/quota/transient 패턴 단어가 우연히 들어가도 성공은 성공이어야 한다.
    It 'exit 0 + EndTurn + 본문 permission → Success true, none' {
        $c = Get-GrokResultClassification -ExitCode 0 -Output '{"stopReason":"EndTurn","text":"updated permission checks in the auth module"}'
        $c.Success | Should Be $true
        $c.ErrorClass | Should Be 'none'
        $c.QuotaExhausted | Should Be $false
    }
    It 'exit 0 + EndTurn + 본문 billing/authentication → Success true' {
        (Get-GrokResultClassification -ExitCode 0 -Output '{"stopReason":"EndTurn","text":"added billing page and authentication flow"}').Success | Should Be $true
    }
    It 'exit 0 + EndTurn + 본문 429 → Success true (transient 오탐 방지)' {
        (Get-GrokResultClassification -ExitCode 0 -Output '{"stopReason":"EndTurn","text":"handle HTTP 429 too many requests retry"}').Success | Should Be $true
    }
    It '실패 경로에서는 텍스트 분류가 계속 동작한다: exit 0이라도 stopReason Error + permission → provider_failure' {
        $c = Get-GrokResultClassification -ExitCode 0 -Output '{"stopReason":"Error","text":"permission denied by the api"}'
        $c.Success | Should Be $false
        $c.ErrorClass | Should Be 'provider_failure'
    }
    It '진짜 provider 실패는 exit≠0에서 그대로 provider_failure' {
        (Get-GrokResultClassification -ExitCode 1 -Output 'invalid api key').ErrorClass | Should Be 'provider_failure'
    }
}

Describe 'v2.3.2-10~13,17. Cancelled run 정책 (usage 불변, fallback/재시도/CI 없음)' {
    It '10~13,17. worker_cancelled: usage 불변, GPT/Claude fallback 없음, 재시도 없음, CI polling 0회' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:v232GrokCalls = 0; $script:v232CiCalls = 0
            $lowCancel = { param($fp,$al) $script:v232GrokCalls++; [pscustomobject]@{ ExitCode=0; Output='{"text":"작업 범위를 확인한 뒤 한 줄만 수정하겠습니다.","stopReason":"Cancelled","sessionId":"c1"}' } }
            $grCancel = { param($r,$repo,$prompt) Invoke-GrokWorker -Cwd $repo -Model $r.model -Effort $r.effort -MaxTurns $r.maxTurns -PromptFilePath $prompt -NoPlan $r.noPlan -NoSubagents $r.noSubagents -Runner $lowCancel }
            $gpNo = { param($r,$repo,$prompt) throw 'GPT must not run on Cancelled' }
            $ciCount = { param($h) $script:v232CiCalls++; 'success' }
            $res = Invoke-RunOperation -OperationNumber 3 -IssueNumber 200 -Kind mechanical -RepoPath $repo -IssueFetcher $issue -GrokRunner $grCancel -GptRunner $gpNo -CiProbe $ciCount
            $res.status | Should Be 'worker_cancelled'
            $res.worker | Should Be 'grok'
            $res.workerExitCode | Should Be 0
            $res.workerStopReason | Should Be 'Cancelled'
            $res.fallbackAttempted | Should Be $false
            $res.commitCount | Should Be 0
            $res.status | Should Not Be 'claude_only_required'
            $script:v232GrokCalls | Should Be 1
            $script:v232CiCalls | Should Be 0
            (Get-UsageState).grok.status | Should Be 'available'
            (Get-UsageState).grok.percent | Should Be 0
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
    It '16b. 정상 stopReason run → postflight 진행 (completed)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $lowOk = { param($fp,$al) [pscustomobject]@{ ExitCode=0; Output='{"text":"done","stopReason":"EndTurn"}' } }
            $grOk = { param($r,$repo,$prompt) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; Invoke-GrokWorker -Cwd $repo -Model $r.model -Effort $r.effort -MaxTurns $r.maxTurns -PromptFilePath $prompt -NoPlan $r.noPlan -NoSubagents $r.noSubagents -Runner $lowOk }
            $res = Invoke-RunOperation -OperationNumber 3 -IssueNumber 201 -Kind mechanical -RepoPath $repo -IssueFetcher $issue -GrokRunner $grOk -CiProbe ({ param($h) 'success' })
            $res.status | Should Be 'completed'
            $res.worker | Should Be 'grok'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

Describe 'v2.3.2-18. doctor grok 헤드리스 권한 판정' {
    It '18. acceptEdits 거부, alwaysApprove+지원 확인 시 통과, dontAsk는 PermissionCancelled 위험으로 거부 (v2.3.3)' {
        (Get-GrokHeadlessDoctor -ConfiguredMode 'acceptEdits' -AllowSupported $true -DenySupported $true -DontAskSupported $true -JsonStopReasonParser $true -HardcodedAcceptEdits $false -AlwaysApproveSupported $true).pass | Should Be $false
        (Get-GrokHeadlessDoctor -ConfiguredMode 'alwaysApprove' -AllowSupported $true -DenySupported $true -DontAskSupported $true -JsonStopReasonParser $true -HardcodedAcceptEdits $false -AlwaysApproveSupported $true).pass | Should Be $true
        (Get-GrokHeadlessDoctor -ConfiguredMode 'alwaysApprove' -AllowSupported $true -DenySupported $true -DontAskSupported $true -JsonStopReasonParser $true -HardcodedAcceptEdits $false -AlwaysApproveSupported $false).pass | Should Be $false
        (Get-GrokHeadlessDoctor -ConfiguredMode 'dontAsk' -AllowSupported $true -DenySupported $true -DontAskSupported $true -JsonStopReasonParser $true -HardcodedAcceptEdits $false -AlwaysApproveSupported $true).pass | Should Be $false
        (Get-GrokHeadlessDoctor -ConfiguredMode 'alwaysApprove' -AllowSupported $false -DenySupported $true -DontAskSupported $true -JsonStopReasonParser $true -HardcodedAcceptEdits $false -AlwaysApproveSupported $true).pass | Should Be $false
        (Get-GrokHeadlessDoctor -ConfiguredMode 'alwaysApprove' -AllowSupported $true -DenySupported $true -DontAskSupported $true -JsonStopReasonParser $false -HardcodedAcceptEdits $false -AlwaysApproveSupported $true).pass | Should Be $false
        (Get-GrokHeadlessDoctor -ConfiguredMode 'alwaysApprove' -AllowSupported $true -DenySupported $true -DontAskSupported $true -JsonStopReasonParser $true -HardcodedAcceptEdits $true -AlwaysApproveSupported $true).pass | Should Be $false
    }
    It '18b. 실제 doctor 리포트 grokHeadless 통과 + 항목' {
        $r = Invoke-DoctorCommand
        $r.report.grokHeadless.usesAcceptEdits | Should Be $false
        $r.report.grokHeadless.pass | Should Be $true
        $r.report.grokHeadless.jsonStopReasonParserPresent | Should Be $true
        $r.report.grokHeadless.configuredMode | Should Be 'alwaysApprove'
        $r.report.grokHeadless.alwaysApproveFlagSupported | Should Be $true
        $r.report.grokHeadless.noAutoUpdateFlagSupported | Should Be $false
    }
}

Describe 'v2.3.2-19. 기존 작전 3 grok 실행 설정 불변' {
    It '19. grok-4.5 low / maxTurns 40 / noPlan / noSubagents 유지' {
        $cfg2 = Get-Config
        $cfg2.grok.operations.'3'.effort | Should Be 'low'
        $cfg2.grok.operations.'3'.maxTurns | Should Be 40
        $cfg2.grok.operations.'3'.noPlan | Should Be $true
        $cfg2.grok.operations.'3'.noSubagents | Should Be $true
        $r3 = Resolve-OperationRoute -OperationNumber 3 -Kind mechanical -GrokState (GS 'available' 0) -GptState (GS 'available' 0) -Config $cfg2
        $r3.worker | Should Be 'grok'; $r3.effort | Should Be 'low'; $r3.maxTurns | Should Be 40
        $r3.noPlan | Should Be $true; $r3.noSubagents | Should Be $true
    }
}

Describe 'v2.4.4. 실행 세대 영속화·중복 차단·recover' {
    It '1~4. 작전 1·2·3은 worker 호출 전 영수증·로그를 만들고 정상 완료 상태를 저장한다' {
        foreach($op in @(1,2,3)) {
            Invoke-ResetCommand | Out-Null
            $repo = New-FakeRepo -WithRemote
            try {
                $runner = {
                    param($route,$repo2,$prompt)
                    $rc = Get-ExecutionReceipt -Operation $op -IssueNumber (300+$op) -RepoPath $repo2
                    $rc.status | Should Be 'worker_running'
                    (Test-Path -LiteralPath $rc.logPath) | Should Be $true
                    Push-Location $repo2; "op$op" | Out-File "op$op.txt" -Encoding utf8; git add .; git commit -q -m "op$op"; git push -q origin main; Pop-Location
                    [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;ErrorClass='none';Output='ok' }
                }
                $res = Invoke-RunOperation -OperationNumber $op -IssueNumber (300+$op) -RepoPath $repo -IssueFetcher $issue -GrokRunner $runner -CiProbe $ciNone
                $res.status | Should Be 'completed'
                $rc = Get-ExecutionReceipt -Operation $op -IssueNumber (300+$op) -RepoPath $repo
                $rc.schemaVersion | Should Be 2; $rc.generation | Should Be 1; $rc.status | Should Be 'completed'
            } finally { Remove-Item -LiteralPath $repo -Recurse -Force }
        }
    }

    It '8~10. 살아 있는 동일 실행은 runner 0회와 recover 명령을 반환하고 다른 저장소는 격리된다' {
        Invoke-ResetCommand | Out-Null
        $repoA = New-FakeRepo -WithRemote; $repoB = New-FakeRepo -WithRemote
        try {
            $snap = Get-StartSnapshot -RepoPath $repoA
            $route = Resolve-OperationRoute -OperationNumber 2 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
            $rc = New-ExecutionGeneration -Operation 2 -IssueNumber 310 -RepoPath $repoA -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
            $rc.status='worker_running'; $rc.processId=$PID; $rc.processStartedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); Save-ExecutionReceipt -Receipt $rc -RepoPath $repoA | Out-Null
            $script:dupCalls=0
            $runner={param($r,$p,$o)$script:dupCalls++;[pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;Output='no'}}
            $a=Invoke-RunOperation -OperationNumber 2 -IssueNumber 310 -RepoPath $repoA -IssueFetcher $issue -GrokRunner $runner -CiProbe $ciNone
            $a.status | Should Be 'execution_already_active'; $a.resumeCommand | Should Be '/operation recover 2 310'; $script:dupCalls | Should Be 0
            $bRunner={param($r,$p,$o) Push-Location $p; 'b'|Out-File b.txt -Encoding utf8;git add .;git commit -q -m b;git push -q origin main;Pop-Location;[pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok'}}
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 310 -RepoPath $repoB -IssueFetcher $issue -GrokRunner $bRunner -CiProbe $ciNone).status | Should Be 'completed'
        } finally { Remove-Item -LiteralPath $repoA -Recurse -Force; Remove-Item -LiteralPath $repoB -Recurse -Force }
    }

    It '17,25. PID와 시작시각이 모두 일치할 때만 worker_running이며 recover는 postflight를 실행하지 않는다' {
        $repo=New-FakeRepo -WithRemote
        try {
            $snap=Get-StartSnapshot -RepoPath $repo; $route=Resolve-OperationRoute -OperationNumber 2 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
            $rc=New-ExecutionGeneration -Operation 2 -IssueNumber 311 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
            $rc.status='worker_running';$rc.processId=777;$rc.processStartedAt='2026-01-01T00:00:00Z';Save-ExecutionReceipt -Receipt $rc -RepoPath $repo|Out-Null
            $script:ciRecover=0;$ci={param($p)$script:ciRecover++;'success'}
            $alive={param($processIdValue)[pscustomobject]@{exists=$true;startedAt='2026-01-01T00:00:00Z'}}
            $res=Invoke-RecoverCommand -OperationNumber 2 -IssueNumber 311 -RepoPath $repo -ProcessProbe $alive -CiProbe $ci
            $res.status|Should Be 'worker_running';$res.workerCalls|Should Be 0;$script:ciRecover|Should Be 0
            $mismatch={param($processIdValue)[pscustomobject]@{exists=$true;startedAt='2026-01-02T00:00:00Z'}}
            $raw=Get-ExecutionReceipt -Operation 2 -IssueNumber 311 -RepoPath $repo;$raw.updatedAt='2020-01-01T00:00:00Z'
            Write-AtomicJsonFile -Path (Get-ExecutionReceiptPath -Operation 2 -IssueNumber 311 -RepoPath $repo) -Object $raw
            (Invoke-RecoverCommand -OperationNumber 2 -IssueNumber 311 -RepoPath $repo -ProcessProbe $mismatch -CiProbe $ci).status|Should Be 'interrupted_no_changes'
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It '11~16. result 없이 커밋·push된 중단은 worker 재호출 없이 unverified 상태로 복구된다' {
        $repo=New-FakeRepo -WithRemote
        try {
            $snap=Get-StartSnapshot -RepoPath $repo;$route=Resolve-OperationRoute -OperationNumber 2 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
            $rc=New-ExecutionGeneration -Operation 2 -IssueNumber 312 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
            $rc.status='worker_running';$rc.processId=999;$rc.processStartedAt='2026-01-01T00:00:00Z';$rc.updatedAt='2020-01-01T00:00:00Z'
            Write-AtomicJsonFile -Path (Get-ExecutionReceiptPath -Operation 2 -IssueNumber 312 -RepoPath $repo) -Object $rc
            Push-Location $repo;'done'|Out-File done.txt -Encoding utf8;git add .;git commit -q -m done;git push -q origin main;Pop-Location
            $dead={param($processIdValue)[pscustomobject]@{exists=$false;startedAt=$null}}
            $res=Invoke-RecoverCommand -OperationNumber 2 -IssueNumber 312 -RepoPath $repo -ProcessProbe $dead -CiProbe ({param($p)'success'})
            $res.status|Should Be 'recovered_commit_unverified';$res.workerCalls|Should Be 0
            $res.interrupted|Should Be $true;$res.localVerificationComplete|Should Be $false;$res.recoveredByPostflight|Should Be $true
            $saved=Get-ExecutionReceipt -Operation 2 -IssueNumber 312 -RepoPath $repo
            $saved.status|Should Be 'recovered_commit_unverified';$saved.resultEnvelopePresent|Should Be $false
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It '18~22. no-change·dirty·push·CI pending/failure/unavailable 상태를 구분한다' {
        foreach($case in @(
            @{n=313;mode='clean';ci='success';want='interrupted_no_changes'},
            @{n=314;mode='dirty';ci='success';want='interrupted_dirty_worktree'},
            @{n=315;mode='ahead';ci='success';want='interrupted_push_incomplete'},
            @{n=324;mode='behind';ci='success';want='interrupted_push_incomplete'},
            @{n=316;mode='push';ci='pending';want='recovered_ci_pending_unverified'},
            @{n=317;mode='push';ci='failure';want='recovered_ci_failed_unverified'},
            @{n=318;mode='push';ci='unavailable';want='recovered_ci_unavailable_unverified'})) {
            $repo=New-FakeRepo -WithRemote
            try {
                $snap=Get-StartSnapshot -RepoPath $repo;$route=Resolve-OperationRoute -OperationNumber 2 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
                $rc=New-ExecutionGeneration -Operation 2 -IssueNumber $case.n -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
                $rc.status='worker_running';$rc.processId=999;$rc.processStartedAt='2026-01-01T00:00:00Z';$rc.updatedAt='2020-01-01T00:00:00Z'
                Write-AtomicJsonFile -Path (Get-ExecutionReceiptPath -Operation 2 -IssueNumber $case.n -RepoPath $repo) -Object $rc
                if($case.mode -eq 'dirty'){'d'|Out-File (Join-Path $repo d.txt) -Encoding utf8}
                if($case.mode -in @('ahead','push')){Push-Location $repo;'c'|Out-File c.txt -Encoding utf8;git add .;git commit -q -m c;if($case.mode -eq 'push'){git push -q origin main};Pop-Location}
                if($case.mode -eq 'behind'){
                    Push-Location $repo;'local'|Out-File local.txt -Encoding utf8;git add .;git commit -q -m local;git push -q origin main;Pop-Location
                    $peer=Join-Path $env:TEMP ('rr-peer-'+[guid]::NewGuid().ToString('N'))
                    try {
                        $remote=(git -C $repo remote get-url origin);git clone -q -b main $remote $peer
                        git -C $peer config user.email t@t.com;git -C $peer config user.name t
                        'remote'|Out-File (Join-Path $peer remote.txt) -Encoding utf8;git -C $peer add .;git -C $peer commit -q -m remote;git -C $peer push -q origin main
                    } finally {if(Test-Path -LiteralPath $peer){Remove-Item -LiteralPath $peer -Recurse -Force}}
                    git -C $repo fetch -q origin
                }
                $res=Invoke-RecoverCommand -OperationNumber 2 -IssueNumber $case.n -RepoPath $repo -ProcessProbe ({param($processIdValue)[pscustomobject]@{exists=$false;startedAt=$null}}) -CiProbe ({param($p)$case.ci})
                $res.status|Should Be $case.want
            } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
        }
    }

    It '23. 다른 저장소의 실행 영수증으로 recover하면 fail-closed 한다' {
        $repoA=New-FakeRepo -WithRemote;$repoB=New-FakeRepo -WithRemote
        try {
            $snap=Get-StartSnapshot -RepoPath $repoA;$route=Resolve-OperationRoute -OperationNumber 2 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
            $rc=New-ExecutionGeneration -Operation 2 -IssueNumber 322 -RepoPath $repoA -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
            $foreignPath=Get-ExecutionReceiptPath -Operation 2 -IssueNumber 322 -RepoPath $repoB
            Write-AtomicJsonFile -Path $foreignPath -Object $rc
            (Invoke-RecoverCommand -OperationNumber 2 -IssueNumber 322 -RepoPath $repoB -CiProbe $ciNone).status | Should Be 'repository_receipt_mismatch'
        } finally {Remove-Item -LiteralPath $repoA -Recurse -Force;Remove-Item -LiteralPath $repoB -Recurse -Force}
    }

    It '22,24. 현재 generation과 일치하는 정상 result만 기존 postflight로 재개한다' {
        $repo=New-FakeRepo -WithRemote
        try {
            $snap=Get-StartSnapshot -RepoPath $repo;$route=Resolve-OperationRoute -OperationNumber 2 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
            $rc=New-ExecutionGeneration -Operation 2 -IssueNumber 319 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
            Push-Location $repo;'c'|Out-File c.txt -Encoding utf8;git add .;git commit -q -m c;git push -q origin main;Pop-Location
            Write-InjectedExecutionResult -Receipt $rc -WorkerResult ([pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;ErrorClass='none';Output='verified'}) -RepoPath $repo
            $res=Invoke-RecoverCommand -OperationNumber 2 -IssueNumber 319 -RepoPath $repo -CiProbe ({param($p)'success'})
            $res.status|Should Be 'completed';$res.interrupted|Should Be $false;$res.workerCalls|Should Be 0
            $rc2=New-ExecutionGeneration -Operation 2 -IssueNumber 320 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'x'
            $bad=[pscustomobject]@{schemaVersion=1;executionId='old';generation=0;worker='grok';exitCode=0;success=$true;quotaExhausted=$false;errorClass='none';workerStopReason=$null}
            Write-AtomicJsonFile -Path $rc2.resultPath -Object $bad;$rc2.status='worker_running';$rc2.updatedAt='2020-01-01T00:00:00Z';Write-AtomicJsonFile -Path (Get-ExecutionReceiptPath -Operation 2 -IssueNumber 320 -RepoPath $repo) -Object $rc2
            (Invoke-RecoverCommand -OperationNumber 2 -IssueNumber 320 -RepoPath $repo -ProcessProbe ({param($processIdValue)[pscustomobject]@{exists=$false;startedAt=$null}}) -CiProbe $ciNone).status|Should Be 'interrupted_no_changes'
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It '27~31. 실행 중 로그는 secret을 마스킹하고 artifact 경로는 runtime root 내부다' {
        Invoke-ResetCommand|Out-Null;$repo=New-FakeRepo -WithRemote
        try {
            $runner={param($r,$p,$o) Push-Location $p;'c'|Out-File c.txt -Encoding utf8;git add .;git commit -q -m c;git push -q origin main;Pop-Location;[pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;Output='Authorization: Basic abcdefghijklmnopqrstuvwxyz token=supersecretvalue'}}
            Invoke-RunOperation -OperationNumber 2 -IssueNumber 321 -RepoPath $repo -IssueFetcher $issue -GrokRunner $runner -CiProbe $ciNone|Out-Null
            $rc=Get-ExecutionReceipt -Operation 2 -IssueNumber 321 -RepoPath $repo;$text=Get-Content -LiteralPath $rc.logPath -Raw -Encoding utf8
            $text|Should Match 'MASKED';$text|Should Not Match 'supersecretvalue'
            (Assert-PathWithinRoot -Path $rc.resultPath -Root $Script:PendingDir)|Should Not Be $null
            (Assert-PathWithinRoot -Path $rc.logPath -Root $Script:LogRoot)|Should Not Be $null
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It '27~28. 독립 worker host가 종료 전 출력과 종료 후 result를 영속화한다' {
        $repo=New-FakeRepo -WithRemote
        $hostProcess=$null
        try {
            $snap=Get-StartSnapshot -RepoPath $repo
            $route=[pscustomobject]@{worker='gpt';model='fixture';effort='low'}
            $rc=New-ExecutionGeneration -Operation 2 -IssueNumber 323 -RepoPath $repo -Kind mechanical -Snapshot $snap -Route $route -PromptContent 'fixture'
            $inv=[pscustomobject]@{
                schemaVersion=1;executionId=$rc.executionId;generation=$rc.generation;filePath='powershell.exe'
                argumentList=@('-NoProfile','-Command',"Write-Output 'partial-before-exit'; Start-Sleep -Milliseconds 1800; Write-Output 'done'")
                stdinMode='nul';promptPath=$rc.promptPath
            }
            Write-AtomicJsonFile -Path $rc.invocationPath -Object $inv
            $receiptPath=Get-ExecutionReceiptPath -Operation 2 -IssueNumber 323 -RepoPath $repo
            $hostArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $ScriptsDir 'worker-host.ps1')+'"'),
                '-ExecutionReceiptPath',('"'+$receiptPath+'"'),'-InvocationPath',('"'+$rc.invocationPath+'"'),
                '-PendingDirOverride',('"'+$Script:PendingDir+'"'),'-LogRootOverride',('"'+$Script:LogRoot+'"'),
                '-ConfigPathOverride',('"'+$Script:ConfigPath+'"'))
            $hostProcess=Start-Process -FilePath 'powershell.exe' -ArgumentList $hostArgs -WorkingDirectory $repo -PassThru -WindowStyle Hidden
            $sawPartial=$false
            1..30 | ForEach-Object {
                if(-not $hostProcess.HasExited -and (Read-SharedTextFile -Path $rc.logPath) -match 'partial-before-exit'){$sawPartial=$true}
                if(-not $hostProcess.HasExited){Start-Sleep -Milliseconds 100;$hostProcess.Refresh()}
            }
            $hostProcess.WaitForExit();$hostProcess.ExitCode|Should Be 0;$sawPartial|Should Be $true
            (Test-Path -LiteralPath $rc.resultPath)|Should Be $true
            $hostReceipt=Get-ExecutionReceipt -Operation 2 -IssueNumber 323 -RepoPath $repo
            $hostReceipt.status|Should Be 'worker_exited_postflight_pending'
            (Test-Path -LiteralPath $rc.rawStdoutPath)|Should Be $false
            (Test-Path -LiteralPath $rc.promptPath)|Should Be $false
            (Test-Path -LiteralPath $hostReceipt.stdoutPath)|Should Be $true
        } finally {
            if ($null -ne $hostProcess -and -not $hostProcess.HasExited) { $hostProcess.WaitForExit(5000) | Out-Null }
            $removed=$false
            1..20 | ForEach-Object {
                if(-not $removed){
                    try {Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction Stop;$removed=$true}
                    catch {Start-Sleep -Milliseconds 100}
                }
            }
            if(-not $removed){throw "worker-host fixture remained locked: $repo"}
        }
    }
}

Describe 'v2.4.5-1. canonical root namespace와 legacy receipt 안전 처리' {
    It '같은 owner/repo의 복수 clone은 namespace·lock·receipt가 격리되고 owner만 같아도 mismatch다' {
        $repoA=New-FakeRepo;$repoB=New-FakeRepo
        try {
            git -C $repoA remote add origin 'https://github.com/BN8624/shared-fixture.git'
            git -C $repoB remote add origin 'https://github.com/BN8624/shared-fixture.git'
            $idA=Get-RepoIdentity -RepoPath $repoA;$idB=Get-RepoIdentity -RepoPath $repoB
            $idA.ownerRepo|Should Be $idB.ownerRepo
            $idA.namespace|Should Not Be $idB.namespace
            $idA.repoRootHash|Should Not Be $idB.repoRootHash
            $lockA=Open-ExecutionLock -Operation 2 -IssueNumber 401 -RepoPath $repoA
            $lockB=Open-ExecutionLock -Operation 2 -IssueNumber 401 -RepoPath $repoB
            try {$lockA|Should Not Be $null;$lockB|Should Not Be $null} finally {$lockA.Dispose();$lockB.Dispose()}
            Push-Location $repoA;'a2'|Out-File a2.txt -Encoding utf8;git add .;git commit -q -m a2;Pop-Location
            Save-TestRunReceipt -Repo $repoA -IssueNum 401
            (Get-RunReceipt -Operation 1 -IssueNumber 401 -RepoPath $repoB)|Should Be $null
            $foreign=Get-RunReceipt -Operation 1 -IssueNumber 401 -RepoPath $repoA
            Write-AtomicJsonFile -Path (Get-RunReceiptPath -Operation 1 -IssueNumber 402 -RepoPath $repoB) -Object $foreign
            $loaded=Get-RunReceipt -Operation 1 -IssueNumber 402 -RepoPath $repoB
            (Test-ReceiptRepoMatch -Receipt $loaded -RepoPath $repoB)|Should Be $false
        } finally {Remove-Item -LiteralPath $repoA -Recurse -Force;Remove-Item -LiteralPath $repoB -Recurse -Force}
    }

    It 'exact canonical root legacy receipt만 새 namespace로 원자 이전하고 ambiguous legacy는 남겨 둔다' {
        $repo=New-FakeRepo
        try {
            git -C $repo remote add origin 'https://github.com/BN8624/legacy-fixture.git'
            $id=Get-RepoIdentity -RepoPath $repo
            $legacyDir=Get-LegacyPendingNamespacePath -RepoPath $repo
            New-Item -ItemType Directory -Path $legacyDir -Force|Out-Null
            $legacyPath=Join-Path $legacyDir 'op1-issue403-run.json'
            $legacy=[pscustomobject]@{operation=1;issueNumber=403;ownerRepo=$id.ownerRepo;repoRoot=$id.repoRoot;status='completed'}
            Write-AtomicJsonFile -Path $legacyPath -Object $legacy
            $migrated=Get-RunReceipt -Operation 1 -IssueNumber 403 -RepoPath $repo
            $migrated.namespaceVersion|Should Be 2;$migrated.repoRootHash|Should Be $id.repoRootHash
            (Test-Path -LiteralPath $legacyPath)|Should Be $false
            (Test-Path -LiteralPath (Get-RunReceiptPath -Operation 1 -IssueNumber 403 -RepoPath $repo))|Should Be $true

            $ambiguousPath=Join-Path $legacyDir 'op1-issue404-run.json'
            Write-AtomicJsonFile -Path $ambiguousPath -Object ([pscustomobject]@{operation=1;issueNumber=404;ownerRepo=$id.ownerRepo;status='completed'})
            $ambiguous=Get-RunReceipt -Operation 1 -IssueNumber 404 -RepoPath $repo
            $ambiguous.legacyNamespaceBlocked|Should Be $true
            (Test-Path -LiteralPath $ambiguousPath)|Should Be $true
            (Test-Path -LiteralPath (Get-RunReceiptPath -Operation 1 -IssueNumber 404 -RepoPath $repo))|Should Be $false
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'legacy active execution은 자동 이전하지 않고 recover를 fail-closed 한다' {
        $repo=New-FakeRepo
        try {
            git -C $repo remote add origin 'https://github.com/BN8624/legacy-active.git'
            $snap=Get-StartSnapshot -RepoPath $repo;$route=Resolve-OperationRoute -OperationNumber 2 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
            $rc=New-ExecutionGeneration -Operation 2 -IssueNumber 405 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
            $rc.status='worker_running';$current=Get-ExecutionReceiptPath -Operation 2 -IssueNumber 405 -RepoPath $repo
            $legacyDir=Get-LegacyPendingNamespacePath -RepoPath $repo;New-Item -ItemType Directory -Path $legacyDir -Force|Out-Null
            $legacyPath=Join-Path $legacyDir 'op2-issue405-execution.json';Write-AtomicJsonFile -Path $legacyPath -Object $rc;Remove-Item -LiteralPath $current -Force
            $res=Invoke-RecoverCommand -OperationNumber 2 -IssueNumber 405 -RepoPath $repo
            $res.status|Should Be 'repository_receipt_mismatch';$res.reason|Should Be 'legacy_active_execution_migration_blocked'
            (Test-Path -LiteralPath $legacyPath)|Should Be $true;(Test-Path -LiteralPath $current)|Should Be $false
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }
}

Describe 'v2.4.5-2. result 유실 recover의 review 자격 차단' {
    It '정상 result envelope recover는 postflight와 적격 Grok 작전 1 review를 유지한다' {
        Invoke-ResetCommand|Out-Null;$repo=New-FakeRepo -WithRemote
        try {
            $snap=Get-StartSnapshot -RepoPath $repo;$route=Resolve-OperationRoute -OperationNumber 1 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
            $rc=New-ExecutionGeneration -Operation 1 -IssueNumber 410 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
            Push-Location $repo;'ok'|Out-File ok.txt -Encoding utf8;git add .;git commit -q -m ok;git push -q origin main;Pop-Location
            Write-InjectedExecutionResult -Receipt $rc -WorkerResult ([pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;ErrorClass='none';Output='verified';WorkerReportedVerification='targeted tests pass';LocalVerificationComplete=$true}) -RepoPath $repo
            $recover=Invoke-RecoverCommand -OperationNumber 1 -IssueNumber 410 -RepoPath $repo -CiProbe $ciNone
            $recover.status|Should Be 'completed';$recover.resultEnvelopePresent|Should Be $true
            $run=Get-RunReceipt -Operation 1 -IssueNumber 410 -RepoPath $repo
            $run.verificationProvenance|Should Be 'valid_worker_result_envelope_recovered_postflight'
            $script:v245ReviewCalls=0
            $review=Invoke-OperationReview -OperationNumber 1 -IssueNumber 410 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner ({param($p,$o,$r)$script:v245ReviewCalls++;[pscustomobject]@{ExitCode=0;Output='{"verdict":"PASS","findings":[]}'}})
            $review.verdict|Should Be 'PASS';$script:v245ReviewCalls|Should Be 1
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'result 없음 + commit/push 성공은 unverified 진단 receipt만 남기고 GPT review를 0회 호출한다' {
        Invoke-ResetCommand|Out-Null;$repo=New-FakeRepo -WithRemote;$manualFindings=$null
        try {
            $snap=Get-StartSnapshot -RepoPath $repo;$route=Resolve-OperationRoute -OperationNumber 1 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
            $rc=New-ExecutionGeneration -Operation 1 -IssueNumber 411 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
            $rc.status='worker_running';$rc.processId=999;$rc.processStartedAt='2026-01-01T00:00:00Z';$rc.updatedAt='2020-01-01T00:00:00Z'
            Write-AtomicJsonFile -Path (Get-ExecutionReceiptPath -Operation 1 -IssueNumber 411 -RepoPath $repo) -Object $rc
            Push-Location $repo;'lost'|Out-File lost.txt -Encoding utf8;git add .;git commit -q -m lost;git push -q origin main;Pop-Location
            $recover=Invoke-RecoverCommand -OperationNumber 1 -IssueNumber 411 -RepoPath $repo -ProcessProbe ({param($n)[pscustomobject]@{exists=$false;startedAt=$null}}) -CiProbe ({param($p)'success'})
            $recover.status|Should Be 'recovered_commit_unverified';$recover.resultEnvelopePresent|Should Be $false;$recover.localVerificationComplete|Should Be $false
            $run=Get-RunReceipt -Operation 1 -IssueNumber 411 -RepoPath $repo
            $run.status|Should Be 'recovered_commit_unverified';$run.interrupted|Should Be $true;$run.verificationProvenance|Should Be 'git_postflight_without_worker_result'
            $script:v245ReviewCalls=0
            $review=Invoke-OperationReview -OperationNumber 1 -IssueNumber 411 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner ({param($p,$o,$r)$script:v245ReviewCalls++;throw 'must not run'})
            $review.status|Should Be 'review_not_eligible';$review.reason|Should Be 'recovered_result_missing_or_unverified';$script:v245ReviewCalls|Should Be 0
            $manualFindings=Join-Path $TestWorkRoot 'unverified-repair-findings.json'
            Set-Content -LiteralPath $manualFindings -Value '[{"severity":"high","file":"lost.txt","issue":"x","requiredFix":"y"}]' -Encoding utf8
            $script:v246RepairCalls=0
            $repair=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 411 -RepoPath $repo -PostReviewHead (Head-Of $repo) -FindingsFile $manualFindings -Target grok `
                -RepairRunner ({param($r,$p,$o)$script:v246RepairCalls++;throw 'must not run'})
            $repair.status|Should Be 'repair_not_eligible';$repair.reason|Should Be 'run_unverified_or_ineligible';$repair.repairAttempted|Should Be $false;$script:v246RepairCalls|Should Be 0
        } finally {if($manualFindings){Remove-Item -LiteralPath $manualFindings -Force -ErrorAction SilentlyContinue};Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'result 없는 CI pending/failure/unavailable은 모두 unverified이며 review worker 호출은 0회다' {
        foreach($case in @(
            @{n=412;ci='pending';want='recovered_ci_pending_unverified'},
            @{n=413;ci='failure';want='recovered_ci_failed_unverified'},
            @{n=414;ci='unavailable';want='recovered_ci_unavailable_unverified'})) {
            Invoke-ResetCommand|Out-Null;$repo=New-FakeRepo -WithRemote
            try {
                $snap=Get-StartSnapshot -RepoPath $repo;$route=Resolve-OperationRoute -OperationNumber 1 -GrokState (GS available 0) -GptState (GS available 0) -Config $cfg
                $rc=New-ExecutionGeneration -Operation 1 -IssueNumber $case.n -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'x'
                $rc.status='worker_running';$rc.processId=999;$rc.processStartedAt='2026-01-01T00:00:00Z';$rc.updatedAt='2020-01-01T00:00:00Z';Write-AtomicJsonFile -Path (Get-ExecutionReceiptPath -Operation 1 -IssueNumber $case.n -RepoPath $repo) -Object $rc
                Push-Location $repo;'c'|Out-File c.txt -Encoding utf8;git add .;git commit -q -m c;git push -q origin main;Pop-Location
                (Invoke-RecoverCommand -OperationNumber 1 -IssueNumber $case.n -RepoPath $repo -ProcessProbe ({param($n)[pscustomobject]@{exists=$false;startedAt=$null}}) -CiProbe ({param($p)$case.ci})).status|Should Be $case.want
                $script:v245ReviewCalls=0
                $review=Invoke-OperationReview -OperationNumber 1 -IssueNumber $case.n -RepoPath $repo -IssueFetcher $issue -GptReviewRunner ({param($p,$o,$r)$script:v245ReviewCalls++;throw 'must not run'})
                $review.status|Should Be 'review_not_eligible';$review.reason|Should Be 'recovered_result_missing_or_unverified';$script:v245ReviewCalls|Should Be 0
            } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
        }
    }
}

Describe 'v2.4.6-1. 모든 repair 경로의 verified run/review receipt 자격 강제' {
    It '정상 run만 있고 review receipt가 없으면 수동 인수 3개로 우회할 수 없다' {
        $repo=New-FakeRepo -WithRemote;$findingsPath=Join-Path $TestWorkRoot 'missing-review-findings.json'
        try {
            $findings=@([pscustomobject]@{severity='high';file='a.txt';issue='x';requiredFix='y'})
            Save-TestRunReceipt -Repo $repo -IssueNum 430
            $findings|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $findingsPath -Encoding utf8
            $script:v246MissingReviewCalls=0
            $res=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 430 -RepoPath $repo -PostReviewHead (Head-Of $repo) -FindingsFile $findingsPath -Target grok `
                -RepairRunner ({param($r,$p,$o)$script:v246MissingReviewCalls++;throw 'must not run'})
            $res.status|Should Be 'repair_receipt_missing';$res.reason|Should Be 'review_receipt_missing';$res.repairAttempted|Should Be $false;$script:v246MissingReviewCalls|Should Be 0
        } finally {Remove-Item -LiteralPath $findingsPath -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'PostReviewHead Target FindingsFile 불일치는 각각 worker 호출 전에 차단한다' {
        $repo=New-FakeRepo -WithRemote;$goodPath=Join-Path $TestWorkRoot 'receipt-findings.json';$badPath=Join-Path $TestWorkRoot 'changed-findings.json';$malformedPath=Join-Path $TestWorkRoot 'malformed-findings.json'
        try {
            $findings=@([pscustomobject]@{severity='high';file='a.txt';issue='x';requiredFix='y'})
            Save-TestRepairReceipts -Repo $repo -IssueNum 431 -Findings $findings
            '[{"requiredFix":"y","issue":"x","file":"a.txt","severity":"high"}]'|Set-Content -LiteralPath $goodPath -Encoding utf8
            '[{"severity":"high","file":"a.txt","issue":"changed","requiredFix":"y"}]'|Set-Content -LiteralPath $badPath -Encoding utf8
            '{bad json'|Set-Content -LiteralPath $malformedPath -Encoding utf8
            $script:v246MismatchCalls=0;$runner={param($r,$p,$o)$script:v246MismatchCalls++;throw 'must not run'}
            $headMismatch=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 431 -RepoPath $repo -PostReviewHead ('0'*40) -RepairRunner $runner
            $targetMismatch=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 431 -RepoPath $repo -Target gpt -RepairRunner $runner
            $findingsMismatch=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 431 -RepoPath $repo -FindingsFile $badPath -RepairRunner $runner
            $malformed=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 431 -RepoPath $repo -FindingsFile $malformedPath -RepairRunner $runner
            foreach($case in @(@($headMismatch,'post_review_head_mismatch'),@($targetMismatch,'repair_target_mismatch'),@($findingsMismatch,'findings_mismatch'),@($malformed,'findings_mismatch'))){$case[0].status|Should Be 'repair_argument_receipt_mismatch';$case[0].reason|Should Be $case[1];$case[0].repairAttempted|Should Be $false}
            $script:v246MismatchCalls|Should Be 0
            (Compare-ReviewFindings -Expected $findings -Actual @((Get-Content $goodPath -Raw|ConvertFrom-Json)))|Should Be $true
        } finally {Remove-Item -LiteralPath $goodPath,$badPath,$malformedPath -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It '유효한 receipt와 의미상 같은 명시 인수는 core 재검증 후 repair runner를 1회 호출한다' {
        Invoke-ResetCommand|Out-Null;$repo=New-FakeRepo -WithRemote;$findingsPath=Join-Path $TestWorkRoot 'matching-findings.json'
        try {
            $findings=@([pscustomobject]@{severity='medium';file='a.txt';issue='x';requiredFix='y'})
            Save-TestRepairReceipts -Repo $repo -IssueNum 432 -Findings $findings
            '[{"requiredFix":"y","issue":"x","file":"a.txt","severity":"medium"}]'|Set-Content -LiteralPath $findingsPath -Encoding utf8
            $script:v246ValidRepairCalls=0
            $res=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 432 -RepoPath $repo -PostReviewHead (Head-Of $repo) -FindingsFile $findingsPath -Target grok `
                -IssueFetcher $issue -RepairRunner ({param($r,$p,$o)$script:v246ValidRepairCalls++;[pscustomobject]@{ExitCode=1;Success=$false;QuotaExhausted=$false;Output='fixture failure'}}) -CiProbe $ciNone
            $res.status|Should Be 'repair_worker_failed';$res.repairAttempted|Should Be $true;$script:v246ValidRepairCalls|Should Be 1
        } finally {Remove-Item -LiteralPath $findingsPath -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $repo -Recurse -Force;Invoke-ResetCommand|Out-Null}
    }

    It 'Save-RunReceipt 기본 provenance는 legacy 호출자를 review와 repair에 fail-closed 한다' {
        $repo=New-FakeRepo -WithRemote
        try {
            $final=Head-Of $repo;$snap=[pscustomobject]@{startHead=$final};$pf=[pscustomobject]@{status='completed';finalHead=$final};$route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high'}
            Save-RunReceipt -Operation 1 -IssueNumber 433 -RepoPath $repo -Snapshot $snap -Postflight $pf -Route $route|Out-Null
            $receipt=Get-RunReceipt -Operation 1 -IssueNumber 433 -RepoPath $repo
            $receipt.resultEnvelopePresent|Should Be $false;$receipt.interrupted|Should Be $true;$receipt.verificationProvenance|Should Be 'unknown'
            (Test-RunReceiptVerificationEligible -Receipt $receipt -RepoPath $repo).eligible|Should Be $false
            (Invoke-RepairCommand -OperationNumber 1 -IssueNumber 433 -RepoPath $repo).reason|Should Be 'run_unverified_or_ineligible'
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }
}

Describe 'v2.4.5-3. execution artifact sanitization과 retention' {
    It 'active raw partial은 관찰 가능하고 terminal 후 raw·prompt가 사라지며 보존본과 receipt만 마스킹된다' {
        $repo=New-FakeRepo
        try {
            git -C $repo remote add origin 'https://github.com/BN8624/artifact-fixture.git'
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='gpt';model='fixture';effort='low'}
            $promptSecret='PromptSecretAbC1234567890XyZ987654321'
            $ghSecret=('ghp_' + 'ABCDEFGHIJKLMNOPQRSTUVWXYZ123456')
            $authSecret='dXNlcjpwYXNzd29yZDEyMzQ1Njc4OTA='
            $awsSecret='AKIA1234567890ABCDEF'
            $entropySecret='AbCdEfGhIjKlMnOpQrStUvWxYz123456'
            $rc=New-ExecutionGeneration -Operation 2 -IssueNumber 420 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent ("order " + $promptSecret)
            $partial="token=$ghSecret`nAuthorization: Basic $authSecret`n$awsSecret`n$entropySecret"
            [System.IO.File]::WriteAllText([string]$rc.rawStdoutPath,$partial,(New-Object System.Text.UTF8Encoding($false)))
            (Read-SharedTextFile -Path $rc.rawStdoutPath)|Should Match ([regex]::Escape($ghSecret))
            (Test-Path -LiteralPath $rc.promptPath)|Should Be $true
            $rc.status='completed';$rc.workerReportedVerification=$partial;$rc.remainingProblems=@()
            $rc=Complete-ExecutionTerminalArtifacts -Receipt $rc -RepoPath $repo -IntendedStatus 'completed'
            $rc.status|Should Be 'completed';$rc.artifactSanitizationStatus|Should Be 'completed';$rc.promptPresent|Should Be $false
            (Test-Path -LiteralPath (Join-Path $rc.artifactPath 'stdout.raw'))|Should Be $false
            (Test-Path -LiteralPath (Join-Path $rc.artifactPath 'stderr.raw'))|Should Be $false
            (Test-Path -LiteralPath (Join-Path $rc.artifactPath 'prompt.txt'))|Should Be $false
            $saved=Read-SharedTextFile -Path $rc.stdoutPath;$saved|Should Match 'MASKED'
            foreach($secret in @($ghSecret,$authSecret,$awsSecret,$entropySecret,$promptSecret)) {
                $hits=@(Get-ChildItem -LiteralPath (Get-PendingNamespacePath -RepoPath $repo) -File -Recurse|Where-Object{(Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8) -match [regex]::Escape($secret)})
                $hits.Count|Should Be 0
            }
            $persisted=Get-ExecutionReceipt -Operation 2 -IssueNumber 420 -RepoPath $repo
            $persisted.promptHash|Should Not Be $null;$persisted.promptPath|Should Be $null;$persisted.rawStdoutPath|Should Be $null
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'retention은 namespace별 오래된 terminal generation만 지우고 active와 최신 receipt generation을 보존한다' {
        $repo=New-FakeRepo
        try {
            $route=[pscustomobject]@{worker='gpt';model='fixture';effort='low'};$terminalPaths=@()
            foreach($n in 1..3) {
                $rc=New-ExecutionGeneration -Operation 2 -IssueNumber 421 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent "p$n"
                $rc.remainingProblems=@();$rc=Complete-ExecutionTerminalArtifacts -Receipt $rc -RepoPath $repo -IntendedStatus 'completed';$terminalPaths+=$rc.artifactPath
                Start-Sleep -Milliseconds 25
            }
            $active=New-ExecutionGeneration -Operation 2 -IssueNumber 421 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'active'
            $active.status='worker_running';Save-ExecutionReceipt -Receipt $active -RepoPath $repo|Out-Null
            Invoke-ExecutionRetention -Receipt $active -RetentionCount 2|Out-Null
            (Test-Path -LiteralPath $active.artifactPath)|Should Be $true
            @($terminalPaths|Where-Object{Test-Path -LiteralPath $_}).Count|Should Be 2
            (Test-Path -LiteralPath $active.promptPath)|Should Be $true
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'execution root 밖 삭제를 거부하고 sanitization 실패를 성공 상태로 남기지 않는다' {
        $repo=New-FakeRepo;$lock=$null
        try {
            $route=[pscustomobject]@{worker='gpt';model='fixture';effort='low'};$rc=New-ExecutionGeneration -Operation 2 -IssueNumber 422 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'x'
            {Remove-ExecutionArtifactDirectory -Path (Join-Path $TestWorkRoot 'outside-artifact') -ArtifactRoot $rc.artifactRoot}|Should Throw
            $lock=[System.IO.File]::Open([string]$rc.rawStdoutPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
            $rc.remainingProblems=@();$failed=Complete-ExecutionTerminalArtifacts -Receipt $rc -RepoPath $repo -IntendedStatus 'completed'
            $failed.status|Should Be 'artifact_sanitization_failed';$failed.artifactSanitizationStatus|Should Be 'failed'
            @($failed.remainingProblems).Count|Should BeGreaterThan 0
        } finally {if($null -ne $lock){$lock.Dispose()};Remove-Item -LiteralPath $repo -Recurse -Force}
    }
}

Describe 'v2.4.7-0. v2.4.6 runtime hotfix 회귀 고정' {
    It 'atomic replace 중 receipt null은 result 변환에 전달하지 않고 다음 poll에서 정상 완료한다' {
        $repo=New-FakeRepo -WithRemote
        $prompt=Join-Path $TestWorkRoot 'hotfix-null-poll.txt'
        Set-Content -LiteralPath $prompt -Value 'fixture' -Encoding UTF8
        $snapshot=Get-StartSnapshot -RepoPath $repo
        $route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high';maxTurns=1;noPlan=$false;noSubagents=$false}
        $localConfig=Get-Config
        $localConfig.execution.foregroundWaitSeconds=2
        $localConfig.execution.pollIntervalMilliseconds=100
        $originalGet=${function:Get-ExecutionReceipt}
        $originalStart=${function:Start-ExecutionWorkerHost}
        $script:v247PollCalls=0
        $script:v247PollReceipt=$null
        try {
            Set-Item function:Get-ExecutionReceipt -Value {
                param([int]$Operation,[int]$IssueNumber,[string]$RepoPath)
                $script:v247PollCalls++
                if($script:v247PollCalls -eq 2){return $null}
                if($null -ne $script:v247PollReceipt){return $script:v247PollReceipt}
                return (& $originalGet -Operation $Operation -IssueNumber $IssueNumber -RepoPath $RepoPath)
            }
            Set-Item function:Start-ExecutionWorkerHost -Value {
                param($Receipt,$Route,$Config,[string]$RepoPath)
                $script:v247PollReceipt=$Receipt
                Write-AtomicJsonFile -Path ([string]$Receipt.resultPath) -Object ([pscustomobject]@{
                    schemaVersion=1;executionId=$Receipt.executionId;generation=$Receipt.generation;worker='grok'
                    exitCode=0;success=$true;quotaExhausted=$false;errorClass='none';workerStopReason='EndTurn'
                    localVerificationComplete=$false;stdoutPath=$Receipt.rawStdoutPath;stderrPath=$Receipt.rawStderrPath
                })
                return [pscustomobject]@{Id=1234}
            }
            $result=Invoke-PersistentRouteWorker -Route $route -RepoPath $repo -PromptPath $prompt -Config $localConfig `
                -OperationNumber 1 -IssueNumber 440 -Kind logic -Snapshot $snapshot -RunId 'hotfix-null-poll'
            $result.Success | Should Be $true
            $script:v247PollCalls | Should BeGreaterThan 2
        } finally {
            Set-Item function:Get-ExecutionReceipt -Value $originalGet
            Set-Item function:Start-ExecutionWorkerHost -Value $originalStart
            Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'repair CLI 선택 인수 생략은 receipt 복원을 유지하고 repair runner를 정확히 1회 호출한다' {
        $source=Get-Content -LiteralPath (Join-Path $ScriptsDir 'run-operation.ps1') -Raw -Encoding UTF8
        $source | Should Match 'if \(\$PSBoundParameters\.ContainsKey\(''PostReviewHead''\)\) \{ \$repairArgs\.PostReviewHead'
        $source | Should Match 'if \(\$PSBoundParameters\.ContainsKey\(''FindingsFile''\)\) \{ \$repairArgs\.FindingsFile'
        $source | Should Match 'if \(\$PSBoundParameters\.ContainsKey\(''Target''\)\) \{ \$repairArgs\.Target'
        $repo=New-FakeRepo -WithRemote
        $findings=@([pscustomobject]@{severity='high';file='a.txt';issue='fixture';requiredFix='fix it'})
        try {
            Save-TestRepairReceipts -Repo $repo -IssueNum 441 -Findings $findings
            $script:v247RepairCalls=0
            $runner={param($r,$path,$promptPath)$script:v247RepairCalls++;[pscustomobject]@{ExitCode=1;Success=$false;QuotaExhausted=$false;ErrorClass='provider_failure';Output='fixture provider failure'}}
            $result=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 441 -RepoPath $repo -IssueFetcher $issue -RepairRunner $runner -CiProbe $ciNone
            $result.status | Should Be 'repair_provider_failure'
            $result.status | Should Not Be 'repair_argument_receipt_mismatch'
            $result.repairAttempted | Should Be $true
            $script:v247RepairCalls | Should Be 1
        } finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'v2.4.7-1. sanitized progress journal과 GPT observable parser' {
    It 'execution generation은 worker 시작 전에 progress metadata와 execution_created를 남긴다' {
        $repo=New-FakeRepo
        try{
            $snap=Get-StartSnapshot -RepoPath $repo
            $route=[pscustomobject]@{worker='gpt';model='gpt-5.6-sol';effort='high'}
            $receipt=New-ExecutionGeneration -Operation 1 -IssueNumber 450 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'fixture' -RunId 'progress-created'
            $receipt.progressSchemaVersion | Should Be 1
            (Assert-PathWithinRoot -Path $receipt.progressPath -Root $receipt.artifactPath) | Out-Null
            $events=@(Read-ExecutionProgressEvents -Receipt $receipt)
            $events.Count | Should Be 1;$events[0].event | Should Be 'execution_created';$events[0].seq | Should Be 1
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'event schema는 단조 seq와 필수 필드를 유지하고 summary를 정규화·마스킹·500자로 제한한다' {
        $repo=New-FakeRepo
        try{
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high'}
            $receipt=New-ExecutionGeneration -Operation 1 -IssueNumber 451 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'fixture' -RunId 'progress-schema'
            $secret='ghp_abcdefghijklmnopqrstuvwx1234'
            Write-ExecutionProgressEvent -Receipt $receipt -Event heartbeat -Summary (($secret+"`n")+('x'*700)) | Out-Null
            $events=@(Read-ExecutionProgressEvents -Receipt $receipt);$event=$events[-1]
            foreach($field in @('schemaVersion','seq','at','operation','issueNumber','executionId','generation','worker','event','phase','level','summary')){($event.PSObject.Properties.Name -contains $field)|Should Be $true}
            [int]$event.seq | Should Be 2;([string]$event.summary).Length | Should Not BeGreaterThan 500
            [string]$event.summary | Should Not Match [regex]::Escape($secret);[string]$event.summary | Should Not Match "`n"
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'journal limit은 상세 이벤트를 progress_suppressed 1회로 줄이고 terminal 이벤트는 계속 기록한다' {
        $repo=New-FakeRepo;$original=${function:Get-ProgressConfig}
        try{
            Set-Item function:Get-ProgressConfig -Value {[pscustomobject]@{pollIntervalMilliseconds=10;heartbeatSeconds=1;maxSummaryCharacters=500;maxJournalBytes=1;followCheckpointSeconds=1}}
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high'}
            $receipt=New-ExecutionGeneration -Operation 2 -IssueNumber 452 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent 'fixture' -RunId 'progress-limit'
            Write-ExecutionProgressEvent -Receipt $receipt -Event file_changed -Summary 'a.txt' | Out-Null
            Write-ExecutionProgressEvent -Receipt $receipt -Event file_changed -Summary 'b.txt' | Out-Null
            Write-ExecutionProgressEvent -Receipt $receipt -Event operation_terminal -Summary 'completed' | Out-Null
            $events=@(Read-ExecutionProgressEvents -Receipt $receipt)
            @($events|Where-Object event -eq 'progress_suppressed').Count | Should Be 1
            @($events|Where-Object event -eq 'file_changed').Count | Should Be 0
            @($events|Where-Object event -eq 'operation_terminal').Count | Should Be 1
        }finally{Set-Item function:Get-ProgressConfig -Value $original;Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'GPT JSONL parser는 command와 file change만 구조화하고 reasoning·unknown·malformed를 무시한다' {
        $start=@(ConvertFrom-GptProgressLine -Line '{"type":"item.started","item":{"type":"command_execution","command":"powershell tests/run-tests.ps1"}}')
        $done=@(ConvertFrom-GptProgressLine -Line '{"type":"item.completed","item":{"type":"command_execution","exit_code":0}}')
        $file=@(ConvertFrom-GptProgressLine -Line '{"type":"item.completed","item":{"type":"file_change","path":"scripts/progress.ps1"}}')
        $start[0].event|Should Be 'command_started';$done[0].event|Should Be 'command_completed';$file[0].event|Should Be 'file_changed'
        @(ConvertFrom-GptProgressLine -Line '{"type":"reasoning","text":"hidden"}').Count|Should Be 0
        @(ConvertFrom-GptProgressLine -Line '{"type":"unknown"}').Count|Should Be 0
        @(ConvertFrom-GptProgressLine -Line '{bad').Count|Should Be 0
    }

    It 'observable Git state는 파일 변경과 commit/push 상태 비교에 필요한 값만 반환한다' {
        $repo=New-FakeRepo -WithRemote
        try{
            $before=Get-ExecutionObservableState -RepoPath $repo;$before.worktreeClean|Should Be $true;$before.ahead|Should Be 0
            Set-Content -LiteralPath (Join-Path $repo 'changed.txt') -Value 'x' -Encoding UTF8
            $after=Get-ExecutionObservableState -RepoPath $repo;$after.worktreeClean|Should Be $false
            @($after.files) -contains 'changed.txt' | Should Be $true
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'injected worker 경로도 process/output/exit/sanitized 이벤트를 순서대로 기록한다' {
        $repo=New-FakeRepo -WithRemote;$prompt=Join-Path $TestWorkRoot 'progress-injected.txt';Set-Content -LiteralPath $prompt -Value 'fixture' -Encoding UTF8
        try{
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high';maxTurns=1;noPlan=$false;noSubagents=$false}
            $runner={param($r,$path,$p)[pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;ErrorClass='none';Output='fixture output'}}
            $result=Invoke-PersistentRouteWorker -Route $route -RepoPath $repo -PromptPath $prompt -Config (Get-Config) -OperationNumber 3 -IssueNumber 453 -Kind logic -Snapshot $snap -RunId 'progress-injected' -InjectedRunner $runner
            $receipt=$result.ExecutionReceipt;$events=@(Read-ExecutionProgressEvents -Receipt $receipt);$names=@($events|ForEach-Object event)
            foreach($expected in @('execution_created','worker_process_started','worker_output_activity','worker_exited','artifact_sanitized')){($names -contains $expected)|Should Be $true}
            @($events|ForEach-Object {[int]$_.seq}) -join ',' | Should Be '1,2,3,4,5'
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

Describe 'v2.4.7-2. detach 실행과 generation 고정 watch terminal handoff' {
    It 'run detach는 host를 정확히 1회 시작하고 즉시 worker_starting과 watchCommand를 반환한다' {
        $repo=New-FakeRepo -WithRemote;$prompt=Join-Path $TestWorkRoot 'detach.txt';Set-Content -LiteralPath $prompt -Value fixture -Encoding UTF8
        $original=${function:Start-ExecutionWorkerHost};$script:v247HostCalls=0
        try{
            Set-Item function:Start-ExecutionWorkerHost -Value {param($Receipt,$Route,$Config,[string]$RepoPath)$script:v247HostCalls++;[pscustomobject]@{Id=999}}
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high';maxTurns=1;noPlan=$false;noSubagents=$false}
            $result=Invoke-PersistentRouteWorker -Route $route -RepoPath $repo -PromptPath $prompt -Config (Get-Config) -OperationNumber 1 -IssueNumber 460 -Kind logic -Snapshot $snap -RunId detach -Detach
            $result.ErrorClass|Should Be 'execution_pending';$result.WorkerCalls|Should Be 1;$result.ExecutionReceipt.status|Should Be 'worker_starting';$script:v247HostCalls|Should Be 1
        }finally{Set-Item function:Start-ExecutionWorkerHost -Value $original;Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'active execution에 detach를 재호출하면 workerCalls=0이고 generation을 재사용한다' {
        $repo=New-FakeRepo -WithRemote;$prompt=Join-Path $TestWorkRoot 'detach-active.txt';Set-Content -LiteralPath $prompt -Value fixture -Encoding UTF8
        try{
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='gpt';model='gpt-5.6-sol';effort='high'}
            $receipt=New-ExecutionGeneration -Operation 1 -IssueNumber 461 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent fixture -RunId active
            $result=Invoke-PersistentRouteWorker -Route $route -RepoPath $repo -PromptPath $prompt -Config (Get-Config) -OperationNumber 1 -IssueNumber 461 -Kind logic -Snapshot $snap -RunId second -Detach
            $result.AlreadyActive|Should Be $true;$result.WorkerCalls|Should Be 0;$result.ExecutionReceipt.generation|Should Be $receipt.generation
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'watch one-shot은 현재 progress를 출력하되 worker와 generation을 만들지 않는다' {
        $repo=New-FakeRepo
        try{
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high'}
            $receipt=New-ExecutionGeneration -Operation 2 -IssueNumber 462 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent fixture -RunId watch
            Write-ExecutionProgressEvent -Receipt $receipt -Event heartbeat -Summary 'running fixture'|Out-Null;Save-ExecutionReceipt -Receipt $receipt -RepoPath $repo|Out-Null
            $script:v247WatchLines=@();$emit={param($line)$script:v247WatchLines+=$line}
            $result=Invoke-WatchCommand -OperationNumber 2 -IssueNumber 462 -RepoPath $repo -Emitter $emit
            $result.status|Should Be 'worker_starting';$result.workerCalls|Should Be 0;$result.generation|Should Be 1
            @($script:v247WatchLines|Where-Object{$_ -match 'RUNNING'}).Count|Should Be 1
            (Get-ExecutionReceipt -Operation 2 -IssueNumber 462 -RepoPath $repo).generation|Should Be 1
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'watch follow는 worker result 후 recover를 1회 재개하고 terminal review handoff를 출력한다' {
        $repo=New-FakeRepo -WithRemote
        try{
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high'}
            $receipt=New-ExecutionGeneration -Operation 1 -IssueNumber 463 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent fixture -RunId follow
            Push-Location $repo;try{Set-Content a.txt 'changed';git add a.txt;git commit -q -m fixture;git push -q origin main}finally{Pop-Location}
            Write-AtomicJsonFile -Path $receipt.resultPath -Object ([pscustomobject]@{schemaVersion=1;executionId=$receipt.executionId;generation=$receipt.generation;worker='grok';exitCode=0;success=$true;quotaExhausted=$false;errorClass='none';workerStopReason='EndTurn';localVerificationComplete=$true;stdoutPath=$receipt.rawStdoutPath;stderrPath=$receipt.rawStderrPath})
            $receipt.status='worker_exited_postflight_pending';Save-ExecutionReceipt -Receipt $receipt -RepoPath $repo|Out-Null
            $script:v247WatchLines=@();$result=Invoke-WatchCommand -OperationNumber 1 -IssueNumber 463 -RepoPath $repo -Follow -Emitter {param($line)$script:v247WatchLines+=$line} -CiProbe $ciNone
            $result.terminal|Should Be $true;$result.status|Should Be 'completed';$result.nextAction|Should Be 'review';$result.workerCalls|Should Be 0
            @($script:v247WatchLines|Where-Object{$_ -match '^\[ORH_TERMINAL\]'}).Count|Should Be 1
            @((Read-ExecutionProgressEvents -Receipt (Get-ExecutionReceipt -Operation 1 -IssueNumber 463 -RepoPath $repo))|Where-Object event -eq 'operation_terminal').Count|Should Be 1
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'watch는 receipt generation 교체를 따라가지 않고 watch_generation_changed로 fail-closed 한다' {
        $repo=New-FakeRepo
        try{
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='gpt';model='gpt-5.6-terra';effort='medium'}
            $receipt=New-ExecutionGeneration -Operation 2 -IssueNumber 464 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent fixture -RunId generation
            $script:v247GenerationChanged=$false
            $sleep={param($ms)if(-not $script:v247GenerationChanged){$changed=Get-ExecutionReceipt -Operation 2 -IssueNumber 464 -RepoPath $repo;$changed.generation=2;$changed.executionId='replacement';Save-ExecutionReceipt -Receipt $changed -RepoPath $repo|Out-Null;$script:v247GenerationChanged=$true}}
            $result=Invoke-WatchCommand -OperationNumber 2 -IssueNumber 464 -RepoPath $repo -Follow -FollowSeconds 5 -SleepAction $sleep -Emitter {param($line)}
            $result.status|Should Be 'watch_generation_changed';$result.nextAction|Should Be 'stop';$result.workerCalls|Should Be 0
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'result 없는 interrupted recover는 성공을 합성하지 않고 manual_verification으로 끝난다' {
        $repo=New-FakeRepo -WithRemote
        try{
            $snap=Get-StartSnapshot -RepoPath $repo;$route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high'}
            $receipt=New-ExecutionGeneration -Operation 1 -IssueNumber 465 -RepoPath $repo -Kind logic -Snapshot $snap -Route $route -PromptContent fixture -RunId unverified
            Push-Location $repo;try{Set-Content a.txt 'changed';git add a.txt;git commit -q -m fixture;git push -q origin main}finally{Pop-Location}
            $receipt.status='interrupted_postflight_pending';$receipt.updatedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');Save-ExecutionReceipt -Receipt $receipt -RepoPath $repo|Out-Null
            $result=Invoke-WatchCommand -OperationNumber 1 -IssueNumber 465 -RepoPath $repo -Follow -Emitter {param($line)} -CiProbe $ciNone
            $result.terminal|Should Be $true;$result.nextAction|Should Be 'manual_verification';$result.status|Should Match 'unverified'
        }finally{Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue}
    }

    It 'nextAction은 operation/worker/verified status 정책을 구분한다' {
        (Get-WatchNextAction -Receipt ([pscustomobject]@{operation=1;worker='gpt'}) -Status completed)|Should Be 'opus_end_review'
        (Get-WatchNextAction -Receipt ([pscustomobject]@{operation=2;worker='grok'}) -Status completed_ci_pending)|Should Be 'sonnet_end_review'
        (Get-WatchNextAction -Receipt ([pscustomobject]@{operation=3;worker='grok'}) -Status completed)|Should Be 'report'
        (Get-WatchNextAction -Receipt ([pscustomobject]@{operation=1;worker='grok'}) -Status worker_failed)|Should Be 'stop'
    }

    It 'stable receipt read는 transient null을 bounded retry한 뒤 정상 receipt를 반환한다' {
        $original=${function:Get-ExecutionReceipt};$script:v247StableCalls=0
        try{
            Set-Item function:Get-ExecutionReceipt -Value {param($Operation,$IssueNumber,$RepoPath)$script:v247StableCalls++;if($script:v247StableCalls -lt 3){return $null};[pscustomobject]@{operation=$Operation;issueNumber=$IssueNumber;status='worker_running'}}
            $receipt=Get-ExecutionReceiptStable -Operation 1 -IssueNumber 466 -RepoPath $TestWorkRoot -MaxAttempts 4 -DelayMilliseconds 1
            $receipt.status|Should Be 'worker_running';$script:v247StableCalls|Should Be 3
        }finally{Set-Item function:Get-ExecutionReceipt -Value $original}
    }
}

Describe 'v2.4.7-3. Skill 자동 follow와 종료 검토 연결' {
    It 'operation-1은 run detach, watch follow, nextAction 순서와 허용 분기만 명시한다' {
        $raw=Get-Content -LiteralPath (Join-Path $SkillsRoot 'operation-1\SKILL.md') -Raw -Encoding UTF8
        $raw|Should Match '-Command run -Operation 1 -IssueNumber \$0 -Detach'
        $raw|Should Match '-Command watch -Operation 1 -IssueNumber \$0 -Follow'
        $raw|Should Match '(?s)run -Detach.*?-Command watch -Operation 1.*?-Follow.*?nextAction'
        $actions=@([regex]::Matches($raw,'nextAction=([a-z_]+)')|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique)
        ($actions -join ',')|Should Be 'manual_verification,opus_end_review,review,stop'
        $raw|Should Not Match 'recover만 안내|run을 다시 호출하지 않는다'
    }

    It 'operation-2는 run detach, watch follow, nextAction 순서와 허용 분기만 명시한다' {
        $raw=Get-Content -LiteralPath (Join-Path $SkillsRoot 'operation-2\SKILL.md') -Raw -Encoding UTF8
        $raw|Should Match '-Command run -Operation 2 -IssueNumber \$0 -Detach'
        $raw|Should Match '-Command watch -Operation 2 -IssueNumber \$0 -Follow'
        $raw|Should Match '(?s)run -Detach.*?-Command watch -Operation 2.*?-Follow.*?nextAction'
        $actions=@([regex]::Matches($raw,'nextAction=([a-z_]+)')|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique)
        ($actions -join ',')|Should Be 'sonnet_end_review,stop'
        $raw|Should Not Match 'recover만 안내|run을 다시 호출하지 않는다'
        $raw|Should Match '새 generation 생성의 근거가 아니다'
    }

    It 'operation-1과 operation-2의 recover는 새 세션 재진입 전용이다' {
        foreach($name in @('operation-1','operation-2')) {
            $raw=Get-Content -LiteralPath (Join-Path $SkillsRoot "$name\SKILL.md") -Raw -Encoding UTF8
            $raw|Should Match '새 세션.*재진입'
            $raw|Should Match 'watch가 살아 있는 동안 수동으로 호출하지 않는다'
        }
    }

    It 'operation 보조 Skill은 watch 명령을 제공하고 operation-3은 report 외 자동 검토를 추가하지 않는다' {
        $dispatcher=Get-Content -LiteralPath (Join-Path $SkillsRoot 'operation\SKILL.md') -Raw -Encoding UTF8
        $op3=Get-Content -LiteralPath (Join-Path $SkillsRoot 'operation-3\SKILL.md') -Raw -Encoding UTF8
        $dispatcher|Should Match '/operation watch';$dispatcher|Should Match '-Command watch -Operation <작전번호> -IssueNumber <이슈번호> -Follow'
        $op3|Should Match 'nextAction=report';$op3|Should Match '별도 review나 종료 검토를 자동 추가하지 않는다'
    }
}

Describe 'v2.4.7-4. 문서 watch-first 흐름 정합성' {
    It 'README, REENTRY, CHANGELOG, VERIFICATION_MATRIX는 run, watch, terminal, nextAction 순서를 사용한다' {
        foreach($relative in @('README.md','REENTRY.md','CHANGELOG.md','VERIFICATION_MATRIX.md')) {
            $raw=Get-Content -LiteralPath (Join-Path $RouterRoot $relative) -Raw -Encoding UTF8
            $raw|Should Match '(?s)run -Detach.*?watch -Follow.*?operation_terminal.*?nextAction'
            $raw|Should Not Match 'recover만 안내|recover 명령만 반환'
        }
        $readme=Get-Content -LiteralPath (Join-Path $RouterRoot 'README.md') -Raw -Encoding UTF8
        $reentry=Get-Content -LiteralPath (Join-Path $RouterRoot 'REENTRY.md') -Raw -Encoding UTF8
        $readme|Should Match 'watch가 살아 있는 동안 recover를 수동 호출하지 않는다'
        $reentry|Should Match 'watch가 살아 있는 동안 recover를 수동 호출하지 않는다'
    }
}

Describe 'v2.4.6-2. retention의 namespace 전체 최신 execution receipt 참조 보호' {
    It '여러 이슈의 latest와 active generation은 count를 초과해도 모두 보호한다' {
        $repo=New-FakeRepo
        try {
            $route=[pscustomobject]@{worker='gpt';model='fixture';effort='low'};$paths=@{}
            foreach($item in @(@('A1',1,440),@('A2',2,440),@('B1',1,441),@('B2',2,441))) {
                $rc=New-ExecutionGeneration -Operation 2 -IssueNumber $item[2] -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent $item[0]
                $rc.remainingProblems=@();$rc=Complete-ExecutionTerminalArtifacts -Receipt $rc -RepoPath $repo -IntendedStatus 'completed';$paths[$item[0]]=$rc.artifactPath
                Start-Sleep -Milliseconds 25
            }
            $active=New-ExecutionGeneration -Operation 3 -IssueNumber 442 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'C1'
            $active.status='worker_running';Save-ExecutionReceipt -Receipt $active -RepoPath $repo|Out-Null
            Invoke-ExecutionRetention -Receipt $active -RetentionCount 1|Out-Null
            foreach($name in @('A2','B2')){(Test-Path -LiteralPath $paths[$name])|Should Be $true}
            (Test-Path -LiteralPath $active.artifactPath)|Should Be $true;(Test-Path -LiteralPath $active.promptPath)|Should Be $true;(Test-Path -LiteralPath $active.rawStdoutPath)|Should Be $true
            @(@($paths['A1'],$paths['B1'])|Where-Object{Test-Path -LiteralPath $_}).Count|Should Be 1
            $namespace=Get-PendingNamespacePath -RepoPath $repo
            foreach($file in @(Get-ChildItem -LiteralPath $namespace -File -Filter '*-execution.json')){$latest=Read-JsonFile -Path $file.FullName;(Test-Path -LiteralPath $latest.artifactPath -PathType Container)|Should Be $true}
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'execution receipt JSON을 읽을 수 없으면 삭제 0개이고 terminal finalization은 artifact_retention_failed다' {
        $repo=New-FakeRepo
        try {
            $route=[pscustomobject]@{worker='gpt';model='fixture';effort='low'}
            $old=New-ExecutionGeneration -Operation 2 -IssueNumber 443 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'old'
            $old.remainingProblems=@();$old=Complete-ExecutionTerminalArtifacts -Receipt $old -RepoPath $repo -IntendedStatus 'completed'
            $latest=New-ExecutionGeneration -Operation 2 -IssueNumber 443 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'latest'
            $latest.remainingProblems=@();$latest=Complete-ExecutionTerminalArtifacts -Receipt $latest -RepoPath $repo -IntendedStatus 'completed'
            $namespace=Get-PendingNamespacePath -RepoPath $repo;$badReceipt=Join-Path $namespace 'op2-issue999-execution.json';'{broken'|Set-Content -LiteralPath $badReceipt -Encoding utf8
            {Invoke-ExecutionRetention -Receipt $latest -RetentionCount 0}|Should Throw
            (Test-Path -LiteralPath $old.artifactPath)|Should Be $true;(Test-Path -LiteralPath $latest.artifactPath)|Should Be $true
            $current=New-ExecutionGeneration -Operation 3 -IssueNumber 444 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'current'
            $current.remainingProblems=@();$failed=Complete-ExecutionTerminalArtifacts -Receipt $current -RepoPath $repo -IntendedStatus 'completed'
            $failed.status|Should Be 'artifact_retention_failed';(Test-Path -LiteralPath $old.artifactPath)|Should Be $true;(Test-Path -LiteralPath $latest.artifactPath)|Should Be $true
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'root 밖 receipt 참조는 삭제 전에 실패하고 marker 없는·malformed generation은 삭제하지 않는다' {
        $repo=New-FakeRepo
        try {
            $route=[pscustomobject]@{worker='gpt';model='fixture';effort='low'}
            $old=New-ExecutionGeneration -Operation 2 -IssueNumber 445 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'old'
            $old.remainingProblems=@();$old=Complete-ExecutionTerminalArtifacts -Receipt $old -RepoPath $repo -IntendedStatus 'completed'
            $latest=New-ExecutionGeneration -Operation 2 -IssueNumber 445 -RepoPath $repo -Kind logic -Snapshot (Get-StartSnapshot -RepoPath $repo) -Route $route -PromptContent 'latest'
            $latest.remainingProblems=@();$latest=Complete-ExecutionTerminalArtifacts -Receipt $latest -RepoPath $repo -IntendedStatus 'completed'
            $namespace=Get-PendingNamespacePath -RepoPath $repo;$outside=Join-Path $TestWorkRoot 'outside-generation';New-Item -ItemType Directory -Path $outside -Force|Out-Null
            $foreign=Read-JsonFile -Path (Get-ExecutionReceiptPath -Operation 2 -IssueNumber 445 -RepoPath $repo);$foreign.operation=3;$foreign.issueNumber=999;$foreign.artifactPath=$outside
            $foreignPath=Join-Path $namespace 'op3-issue999-execution.json';Write-AtomicJsonFile -Path $foreignPath -Object $foreign
            {Invoke-ExecutionRetention -Receipt $latest -RetentionCount 0}|Should Throw
            (Test-Path -LiteralPath $old.artifactPath)|Should Be $true
            Remove-Item -LiteralPath $foreignPath -Force
            $markerless=Join-Path $latest.artifactRoot 'markerless-generation';$malformed=Join-Path $latest.artifactRoot 'malformed-generation'
            New-Item -ItemType Directory -Path $markerless,$malformed -Force|Out-Null;'{bad'|Set-Content -LiteralPath (Join-Path $malformed 'generation.json') -Encoding utf8
            Invoke-ExecutionRetention -Receipt $latest -RetentionCount 0|Out-Null
            (Test-Path -LiteralPath $old.artifactPath)|Should Be $false;(Test-Path -LiteralPath $latest.artifactPath)|Should Be $true
            (Test-Path -LiteralPath $markerless)|Should Be $true;(Test-Path -LiteralPath $malformed)|Should Be $true
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }
}

Describe 'v2.4.5-4. watched critical tree 사후 무결성 검사' {
    It 'scripts tree의 수정·삭제·추가를 모두 결정론적으로 탐지한다' {
        $tree=Join-Path $TestWorkRoot ('critical-tree-'+[guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path (Join-Path $tree 'scripts') -Force|Out-Null
            Set-Content -LiteralPath (Join-Path $tree 'scripts\run-operation.ps1') -Value 'run' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $tree 'scripts\worker-host.ps1') -Value 'host' -Encoding utf8
            $spec=[pscustomobject]@{kind='tree';root=$tree;patterns=@('^scripts/.+\.ps1$')}
            $snap=Get-BoundarySnapshot -Specifications @($spec)
            Set-Content -LiteralPath (Join-Path $tree 'scripts\run-operation.ps1') -Value 'changed' -Encoding utf8
            Remove-Item -LiteralPath (Join-Path $tree 'scripts\worker-host.ps1') -Force
            Set-Content -LiteralPath (Join-Path $tree 'scripts\new-helper.ps1') -Value 'new' -Encoding utf8
            $viol=@(Test-RepoBoundaryViolation -BeforeSnapshot $snap)
            $viol.Count|Should Be 3
            $viol[0]|Should Match 'new-helper\.ps1$';$viol[1]|Should Match 'run-operation\.ps1$';$viol[2]|Should Match 'worker-host\.ps1$'
        } finally {if(Test-Path -LiteralPath $tree){Remove-Item -LiteralPath $tree -Recurse -Force}}
    }

    It 'config와 operation Skill 변경은 탐지하지만 state·logs·executions 변경은 false positive가 아니다' {
        $tree=Join-Path $TestWorkRoot ('critical-static-'+[guid]::NewGuid().ToString('N'))
        try {
            foreach($d in @('config','skills\operation-1','state','logs','executions')){New-Item -ItemType Directory -Path (Join-Path $tree $d) -Force|Out-Null}
            Set-Content -LiteralPath (Join-Path $tree 'config\config.json') -Value '{}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $tree 'skills\operation-1\SKILL.md') -Value 'skill' -Encoding utf8
            $spec=[pscustomobject]@{kind='tree';root=$tree;patterns=@('^config/.+\.json$','^skills/[^/]+/SKILL\.md$','^scripts/.+\.ps1$','^operation-router\.cmd$')}
            $snap=Get-BoundarySnapshot -Specifications @($spec)
            Set-Content -LiteralPath (Join-Path $tree 'config\config.json') -Value '{"x":1}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $tree 'skills\operation-1\SKILL.md') -Value 'changed' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $tree 'state\usage-state.json') -Value '{"ok":true}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $tree 'logs\runtime.log') -Value 'log' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $tree 'executions\result.json') -Value '{}' -Encoding utf8
            $viol=@(Test-RepoBoundaryViolation -BeforeSnapshot $snap)
            $viol.Count|Should Be 2
            ($viol -join "`n")|Should Match 'config\.json';($viol -join "`n")|Should Match 'SKILL\.md'
            ($viol -join "`n")|Should Not Match 'usage-state|runtime\.log|executions'
        } finally {if(Test-Path -LiteralPath $tree){Remove-Item -LiteralPath $tree -Recurse -Force}}
    }

    It 'critical tree violation은 CI를 조회하지 않고 성공 run/review/repair receipt를 만들지 않는다' {
        Invoke-ResetCommand|Out-Null;$repo=New-FakeRepo -WithRemote;$tree=Join-Path $TestWorkRoot ('critical-flow-'+[guid]::NewGuid().ToString('N'));$savedRuntime=$Script:RuntimeRoot
        try {
            New-Item -ItemType Directory -Path (Join-Path $tree 'scripts') -Force|Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tree 'config') -Force|Out-Null
            New-Item -ItemType Directory -Path (Join-Path $tree 'skills\operation-1') -Force|Out-Null
            Set-Content -LiteralPath (Join-Path $tree 'operation-router.cmd') -Value '@echo off' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $tree 'config\config.json') -Value '{}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $tree 'scripts\run-operation.ps1') -Value 'original' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $tree 'skills\operation-1\SKILL.md') -Value 'skill' -Encoding utf8
            $Script:RuntimeRoot=$tree;$script:v245CiCalls=0
            $runner={param($r,$p,$o)Set-Content -LiteralPath (Join-Path $tree 'scripts\run-operation.ps1') -Value 'tampered' -Encoding utf8;Push-Location $p;'x'|Out-File x.txt -Encoding utf8;git add .;git commit -q -m x;git push -q origin main;Pop-Location;[pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;ErrorClass='none';Output='ok'}}
            $res=Invoke-RunOperation -OperationNumber 1 -IssueNumber 423 -RepoPath $repo -IssueFetcher $issue -GrokRunner $runner -CiProbe ({param($p)$script:v245CiCalls++;'success'})
            $res.status|Should Be 'repo_boundary_violation';$script:v245CiCalls|Should Be 0
            (Get-RunReceipt -Operation 1 -IssueNumber 423 -RepoPath $repo).status|Should Be 'repo_boundary_violation'
            $script:v245ReviewCalls=0;$review=Invoke-OperationReview -OperationNumber 1 -IssueNumber 423 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner ({param($p,$o,$r)$script:v245ReviewCalls++;throw 'must not run'})
            $review.status|Should Be 'review_not_eligible';$script:v245ReviewCalls|Should Be 0
            (Test-Path -LiteralPath (Get-ReviewReceiptPath -Operation 1 -IssueNumber 423 -RepoPath $repo))|Should Be $false
            $repair=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 423 -RepoPath $repo
            $repair.status|Should Be 'repair_not_eligible';$repair.reason|Should Be 'run_unverified_or_ineligible';$repair.repairAttempted|Should Be $false
        } finally {$Script:RuntimeRoot=$savedRuntime;Remove-Item -LiteralPath $repo -Recurse -Force;if(Test-Path -LiteralPath $tree){Remove-Item -LiteralPath $tree -Recurse -Force};Invoke-ResetCommand|Out-Null}
    }
}

Describe 'v2.3.4-1~17. 로그·상태·Skill·검토본 재현성' {
    It '1. mock 로그는 현재 test-run 디렉터리에만 생성된다' {
        $path = Write-RouterLog -Name 'v234-mock-only' -Content 'mock'
        (Assert-PathWithinRoot -Path $path -Root $Script:TestLogDir) | Should Be $path
        @(Get-ChildItem -LiteralPath $Script:RuntimeLogDir -File -Filter '*.log').Count | Should Be 0
    }

    It '2. mock 로그 회전은 가짜 runtime 로그를 삭제하지 않는다' {
        $fixture = Join-Path $TestWorkRoot 'v234-preserve-count'
        $saved = [pscustomobject]@{ LogRoot=$Script:LogRoot; Runtime=$Script:RuntimeLogDir; TestRoot=$Script:TestLogRoot; TestDir=$Script:TestLogDir; Scope=$Script:RouterLogScope }
        try {
            $Script:LogRoot=$fixture; $Script:RuntimeLogDir=Join-Path $fixture 'runtime'; $Script:TestLogRoot=Join-Path $fixture 'tests'; $Script:TestLogDir=Join-Path $Script:TestLogRoot 'test-run-count'; $Script:RouterLogScope='test'
            Initialize-RuntimeDirs
            1..20 | ForEach-Object { Set-Content -LiteralPath (Join-Path $Script:RuntimeLogDir ('existing-e2e-{0:d2}.log' -f $_)) -Value "runtime-$_" -Encoding UTF8 }
            $before = @(Get-ChildItem -LiteralPath $Script:RuntimeLogDir -File).Name | Sort-Object
            1..25 | ForEach-Object { Write-RouterLog -Name "mock-$_" -Content "test-$_" | Out-Null }
            $after = @(Get-ChildItem -LiteralPath $Script:RuntimeLogDir -File).Name | Sort-Object
            ($after -join '|') | Should Be ($before -join '|')
        } finally {
            $Script:LogRoot=$saved.LogRoot; $Script:RuntimeLogDir=$saved.Runtime; $Script:TestLogRoot=$saved.TestRoot; $Script:TestLogDir=$saved.TestDir; $Script:RouterLogScope=$saved.Scope
            Assert-PathWithinRoot -Path $fixture -Root $TestWorkRoot | Out-Null
            if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
        }
    }

    It '3. mock 로그 회전은 가짜 runtime 로그의 내용과 SHA-256을 수정하지 않는다' {
        $fixture = Join-Path $TestWorkRoot 'v234-preserve-hash'
        $saved = [pscustomobject]@{ LogRoot=$Script:LogRoot; Runtime=$Script:RuntimeLogDir; TestRoot=$Script:TestLogRoot; TestDir=$Script:TestLogDir; Scope=$Script:RouterLogScope }
        try {
            $Script:LogRoot=$fixture; $Script:RuntimeLogDir=Join-Path $fixture 'runtime'; $Script:TestLogRoot=Join-Path $fixture 'tests'; $Script:TestLogDir=Join-Path $Script:TestLogRoot 'test-run-hash'; $Script:RouterLogScope='test'
            Initialize-RuntimeDirs
            1..20 | ForEach-Object { Set-Content -LiteralPath (Join-Path $Script:RuntimeLogDir ('existing-e2e-{0:d2}.log' -f $_)) -Value "runtime-$_" -Encoding UTF8 }
            $before = Convert-SnapshotToStableJson (Get-TestFileSnapshot $Script:RuntimeLogDir)
            1..25 | ForEach-Object { Write-RouterLog -Name "mock-$_" -Content "test-$_" | Out-Null }
            $after = Convert-SnapshotToStableJson (Get-TestFileSnapshot $Script:RuntimeLogDir)
            $after | Should Be $before
        } finally {
            $Script:LogRoot=$saved.LogRoot; $Script:RuntimeLogDir=$saved.Runtime; $Script:TestLogRoot=$saved.TestRoot; $Script:TestLogDir=$saved.TestDir; $Script:RouterLogScope=$saved.Scope
            Assert-PathWithinRoot -Path $fixture -Root $TestWorkRoot | Out-Null
            if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
        }
    }

    It '4. runtime 회전은 test-run 로그를 건드리지 않는다' {
        $fixture = Join-Path $TestWorkRoot 'v234-runtime-rotation'
        $saved = [pscustomobject]@{ LogRoot=$Script:LogRoot; Runtime=$Script:RuntimeLogDir; TestRoot=$Script:TestLogRoot; TestDir=$Script:TestLogDir; Scope=$Script:RouterLogScope }
        try {
            $Script:LogRoot=$fixture; $Script:RuntimeLogDir=Join-Path $fixture 'runtime'; $Script:TestLogRoot=Join-Path $fixture 'tests'; $Script:TestLogDir=Join-Path $Script:TestLogRoot 'test-run-rotation'; $Script:RouterLogScope='test'
            Initialize-RuntimeDirs
            1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $Script:TestLogDir "test-$_.log") -Value "test-$_" -Encoding UTF8 }
            1..21 | ForEach-Object { Set-Content -LiteralPath (Join-Path $Script:RuntimeLogDir "runtime-$_.log") -Value "runtime-$_" -Encoding UTF8; (Get-Item -LiteralPath (Join-Path $Script:RuntimeLogDir "runtime-$_.log")).LastWriteTimeUtc=(Get-Date).ToUniversalTime().AddSeconds($_) }
            $before = Convert-SnapshotToStableJson (Get-TestFileSnapshot $Script:TestLogDir)
            Invoke-LogRetention -Scope runtime
            (Convert-SnapshotToStableJson (Get-TestFileSnapshot $Script:TestLogDir)) | Should Be $before
            @(Get-ChildItem -LiteralPath $Script:RuntimeLogDir -File).Count | Should Be 20
        } finally {
            $Script:LogRoot=$saved.LogRoot; $Script:RuntimeLogDir=$saved.Runtime; $Script:TestLogRoot=$saved.TestRoot; $Script:TestLogDir=$saved.TestDir; $Script:RouterLogScope=$saved.Scope
            Assert-PathWithinRoot -Path $fixture -Root $TestWorkRoot | Out-Null
            if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
        }
    }

    It '5. test cleanup은 runtime 로그를 건드리지 않는다' {
        $fixture = Join-Path $TestWorkRoot 'v234-test-cleanup'
        $saved = [pscustomobject]@{ LogRoot=$Script:LogRoot; Runtime=$Script:RuntimeLogDir; TestRoot=$Script:TestLogRoot; TestDir=$Script:TestLogDir; Scope=$Script:RouterLogScope }
        try {
            $Script:LogRoot=$fixture; $Script:RuntimeLogDir=Join-Path $fixture 'runtime'; $Script:TestLogRoot=Join-Path $fixture 'tests'; $Script:TestLogDir=Join-Path $Script:TestLogRoot 'test-run-cleanup'; $Script:RouterLogScope='test'
            Initialize-RuntimeDirs
            1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $Script:RuntimeLogDir "runtime-$_.log") -Value "runtime-$_" -Encoding UTF8; Set-Content -LiteralPath (Join-Path $Script:TestLogDir "test-$_.log") -Value "test-$_" -Encoding UTF8 }
            $before = Convert-SnapshotToStableJson (Get-TestFileSnapshot $Script:RuntimeLogDir)
            Remove-TestLogDirectory -Path $Script:TestLogDir
            (Convert-SnapshotToStableJson (Get-TestFileSnapshot $Script:RuntimeLogDir)) | Should Be $before
            (Test-Path -LiteralPath $Script:TestLogDir) | Should Be $false
        } finally {
            $Script:LogRoot=$saved.LogRoot; $Script:RuntimeLogDir=$saved.Runtime; $Script:TestLogRoot=$saved.TestRoot; $Script:TestLogDir=$saved.TestDir; $Script:RouterLogScope=$saved.Scope
            Assert-PathWithinRoot -Path $fixture -Root $TestWorkRoot | Out-Null
            if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
        }
    }

    It '6. 회전·정리 대상이 지정 로그 루트 밖이면 실패한다' {
        $sibling = $Script:TestLogRoot + '-evil\outside.log'
        { Assert-PathWithinRoot -Path $sibling -Root $Script:TestLogRoot } | Should Throw
        { Remove-TestLogDirectory -Path (Split-Path -Parent $sibling) } | Should Throw
    }

    It '7. 임시 usage-state fixture가 자동 생성되고 초기 상태가 유효하다' {
        (Test-Path -LiteralPath $Script:UsageStatePath) | Should Be $true
        $state = Get-UsageState
        $state.grok.status | Should Be 'available'; $state.grok.percent | Should Be 0
        $state.gpt.status | Should Be 'available'; $state.gpt.percent | Should Be 0
    }

    It '8. 모든 상태 함수는 주입된 임시 usage-state만 사용한다' {
        $Script:UsageStatePath | Should Not Be $actualUsagePath
        Invoke-SetCommand -Target gpt -Value reserved | Out-Null
        (Read-JsonFile -Path $Script:UsageStatePath).gpt.status | Should Be 'reserved'
        Invoke-ResetCommand | Out-Null
    }

    It '9. 주입되지 않은 상태 파일은 reset으로 수정되지 않는다' {
        $sentinel = Join-Path $TestWorkRoot 'unrelated-state.json'
        Set-Content -LiteralPath $sentinel -Value '{"sentinel":true}' -Encoding UTF8
        $before = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
        Invoke-ResetCommand | Out-Null
        (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash | Should Be $before
    }

    It '10. Skill 검사는 source tree 내부 skills 경로를 사용한다' {
        (Assert-PathWithinRoot -Path $SkillsRoot -Root $RouterRoot) | Should Be $SkillsRoot
        foreach($name in @('operation','operation-1','operation-1-claude','operation-2','operation-3','operation-3-claude')) {
            (Test-Path -LiteralPath (Join-Path $SkillsRoot "$name\SKILL.md")) | Should Be $true
        }
    }

    It '11. 다른 설치 Skill 사본이 달라도 source tree Skill이 판정 기준이다' {
        $alternate = Join-Path $TestWorkRoot 'different-installed-skills\operation'
        New-Item -ItemType Directory -Path $alternate -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $alternate 'SKILL.md') -Value "---`nname: wrong-installed-copy`n---" -Encoding UTF8
        (Get-SkillFrontmatter -Path (Join-Path $SkillsRoot 'operation\SKILL.md')).name | Should Be 'operation'
        (Get-SkillFrontmatter -Path (Join-Path $alternate 'SKILL.md')).name | Should Be 'wrong-installed-copy'
    }

    It '12. README는 v3.0.0을 현재 버전으로 기록한다' {
        $readme = Get-Content -LiteralPath (Join-Path $RouterRoot 'README.md') -Raw -Encoding UTF8
        $readme | Should Match '^# operation-router \(v3\.0\.0\)'
    }

    It '13. README와 config는 alwaysApprove를 현재 권한 모드로 기록한다' {
        $readme = Get-Content -LiteralPath (Join-Path $RouterRoot 'README.md') -Raw -Encoding UTF8
        $readme | Should Match 'alwaysApprove'
        (Get-Config).grok.headlessPermissions.mode | Should Be 'alwaysApprove'
    }

    It '14. README는 dontAsk를 현재 사용 모드로 설명하지 않는다' {
        $readme = Get-Content -LiteralPath (Join-Path $RouterRoot 'README.md') -Raw -Encoding UTF8
        $readme | Should Not Match '--permission-mode dontAsk'
        $readme | Should Not Match 'mode `dontAsk` \+'
        $readme | Should Not Match '헤드리스는 `dontAsk`를 쓴다'
    }

    It '15. manifest의 모든 SHA-256이 일치하고 manifest 자신은 제외된다' {
        $manifest = Join-Path $RouterRoot 'manifest-sha256.txt'
        (Test-Path -LiteralPath $manifest) | Should Be $true
        $lines = @(Get-Content -LiteralPath $manifest -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should BeGreaterThan 0
        foreach($line in $lines) {
            $match=[regex]::Match($line, '^([A-Fa-f0-9]{64})  (.+)$')
            $match.Success | Should Be $true
            $expected=$match.Groups[1].Value.ToUpperInvariant(); $relative=$match.Groups[2].Value
            $relative | Should Not Match '(^|/)\.\.(/|$)'
            $relative | Should Not Be 'manifest-sha256.txt'
            $file=Join-Path $RouterRoot ($relative -replace '/', '\')
            (Assert-PathWithinRoot -Path $file -Root $RouterRoot) | Out-Null
            (Test-Path -LiteralPath $file) | Should Be $true
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash | Should Be $expected
        }
    }

    It '15b. v2.4.1: manifest가 모든 배포 대상 파일을 빠짐없이 포함한다(중복·누락 실패)' {
        $manifest = Join-Path $RouterRoot 'manifest-sha256.txt'
        $manifestPaths = @()
        foreach($line in (Get-Content -LiteralPath $manifest -Encoding UTF8 | Where-Object { $_ -match '^[A-Fa-f0-9]{64}  (.+)$' })) {
            $manifestPaths += (($line -split '  ',2)[1])
        }
        # 중복 경로 금지
        @($manifestPaths | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should Be 0
        # manifest 자신은 등록 대상에서 제외
        ($manifestPaths -contains 'manifest-sha256.txt') | Should Be $false
        # .gitattributes(EOL 변환 차단 → 바이트 재현성에 직접 영향)는 반드시 포함
        ($manifestPaths -contains '.gitattributes') | Should Be $true
        # 파일시스템 배포 대상 집합(런타임·백업 제외)과 manifest 경로 집합이 완전히 일치해야 한다.
        $runtimeDirs = @('state','logs','temp')
        $fsPaths = @()
        foreach($f in (Get-ChildItem -LiteralPath $RouterRoot -Recurse -File)) {
            $rel = $f.FullName.Substring($RouterRoot.Length).TrimStart('\','/') -replace '\\','/'
            $top = ($rel -split '/',2)[0]
            if ($runtimeDirs -contains $top) { continue }
            if ($rel -eq 'manifest-sha256.txt') { continue }
            if ($rel -like '*.bak' -or $rel -like '*.bak.*') { continue }
            $fsPaths += $rel
        }
        # manifest에 있으나 파일시스템에 없는 경로 (등록됐지만 Git/배포에 없음)
        @($manifestPaths | Where-Object { $fsPaths -notcontains $_ }).Count | Should Be 0
        # 파일시스템에 있으나 manifest에 없는 배포 대상 (누락된 tracked file)
        @($fsPaths | Where-Object { $manifestPaths -notcontains $_ }).Count | Should Be 0
    }

    It '16. manifest 검토 대상에 실제 secret 형태가 포함되지 않는다' {
        $manifest = Join-Path $RouterRoot 'manifest-sha256.txt'
        $patterns = @('gh[pousr]_[A-Za-z0-9]{20,}','sk-[A-Za-z0-9]{20,}','xai-[A-Za-z0-9]{20,}','Bearer\s+[A-Za-z0-9\.\-_]{10,}')
        $knownFixtures = @('ghp_abcdefghijklmnopqrstuvwx1234','sk-abcdefghijklmnopqrstuvwx','Bearer abcdefghij1234567890')
        $hits=@()
        foreach($line in (Get-Content -LiteralPath $manifest -Encoding UTF8)) {
            if($line -notmatch '^[A-Fa-f0-9]{64}  (.+)$'){continue}
            $relative=$Matches[1]; $file=Join-Path $RouterRoot ($relative -replace '/', '\')
            $text=Get-Content -LiteralPath $file -Raw -Encoding UTF8
            foreach($fixture in $knownFixtures){$text=$text.Replace($fixture,'KNOWN_TEST_FIXTURE')}
            foreach($pattern in $patterns){if($text -match $pattern){$hits += "$relative::$pattern"}}
        }
        $hits.Count | Should Be 0
    }

    It '17. 기존 149개와 v2.3.4 17개, v2.3.5 2개의 테스트 정의가 유지된다' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-tree.Tests.ps1') -Raw -Encoding UTF8
        ([regex]::Matches($source, '(?m)^\s*It\s+''').Count) | Should BeGreaterThan 167
    }

    It '18. 고정 계약은 ASCII 최종 작업자 마커와 재위임 금지를 먼저 전달한다' {
        $contract = Get-FixedExecutionContract
        $contract | Should Match '^\[OPERATION_ROUTER_FINAL_WORKER\]'
        $contract | Should Match 'Do not apply any global Operation 1/2/3 delegation rule'
        $contract | Should Match 'Do not invoke, inspect, preflight, or delegate to Grok, Codex, Claude'
        $issueBody = "# 한글 이슈`r`n원문 보존 ✓"
        (New-OrderContent -IssueBody $issueBody).EndsWith($issueBody) | Should Be $true
    }

    It '19. Windows PowerShell 전경 실행이 한글 stdin을 UTF-8 바이트로 보존한다' {
        # 비ASCII 디렉터리 경로에서도 stdin 파일이 전달되는지 함께 검증한다 (P2 지적 반영).
        $stdinDir = Join-Path $TestWorkRoot '한글 경로'
        New-Item -ItemType Directory -Path $stdinDir -Force | Out-Null
        $stdinPath = Join-Path $stdinDir 'utf8-stdin.txt'
        $payload = "[OPERATION_ROUTER_FINAL_WORKER]`n한글 계약 보존 ✓"
        Set-Content -LiteralPath $stdinPath -Value $payload -Encoding UTF8 -NoNewline
        $reader = '$s=[Console]::OpenStandardInput();$m=New-Object IO.MemoryStream;$b=New-Object byte[] 4096;while(($n=$s.Read($b,0,$b.Length))-gt 0){$m.Write($b,0,$n)};[Convert]::ToBase64String($m.ToArray())'
        $result = Invoke-ForegroundCommand -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-Command',$reader) -StdinFilePath $stdinPath
        $result.ExitCode | Should Be 0
        $received = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($result.Output.Trim()))
        # culture-sensitive StartsWith는 BOM(U+FEFF)을 무시하므로 ordinal로 비교해야 BOM 누출을 잡는다.
        $received.StartsWith($payload, [System.StringComparison]::Ordinal) | Should Be $true
        $received.Substring($payload.Length) | Should Match '^(\r?\n)?$'
    }

    It '21. codex JSONL 이벤트 스트림에서 agent_message의 verdict를 추출한다' {
        # 2026-07-21 op1-issue13 검수 실측 원문 형태 그대로.
        $jsonl = '{"type":"turn.started"}' + "`n" +
            '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"verdict\":\"PASS\",\"findings\":[]}"}}' + "`n" +
            '{"type":"turn.completed","usage":{"input_tokens":17645,"cached_input_tokens":10496,"output_tokens":223}}'
        $r = ConvertFrom-StrictReviewJson -Text $jsonl
        $r.valid | Should Be $true
        $r.verdict | Should Be 'PASS'
        $inner = '{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"high","file":"a.ps1","issue":"x","requiredFix":"y"}]}'
        $line = '{"type":"item.completed","item":{"type":"agent_message","text":' + (ConvertTo-Json $inner) + '}}'
        $r2 = ConvertFrom-StrictReviewJson -Text ('{"type":"turn.started"}' + "`n" + $line)
        $r2.valid | Should Be $true
        $r2.verdict | Should Be 'REPAIR_REQUIRED'
        @($r2.findings).Count | Should Be 1
        # 평문 JSON 입력은 기존 동작 유지
        (ConvertFrom-StrictReviewJson -Text '{"verdict":"PASS","findings":[]}').valid | Should Be $true
    }

    It '20. 비ASCII 인수 전경 실행도 NUL 고정 래퍼를 유지한다 (P1)' {
        # 명령줄에 한글이 있으면 env-var 래퍼 경로를 타며, stdin은 NUL(즉시 EOF)이어야 한다.
        $cmd = '$i=[Console]::In.ReadToEnd(); Write-Output (''STDINLEN='' + $i.Length); Write-Output ''한글인수확인'''
        $r = Invoke-ForegroundCommand -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-Command',$cmd)
        $r.ExitCode | Should Be 0
        $r.Output | Should Match 'STDINLEN=0'
        $r.Output | Should Match '한글인수확인'
        (Test-Path env:OR_FG_EXE) | Should Be $false
    }
}

Describe 'v3.0.0. issue branch와 Draft PR workflow' {
    BeforeEach {
        $script:v3SavedBoundary=$env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=Join-Path $TestWorkRoot 'v3-safe-boundary.txt'
        if(-not (Test-Path -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE)){
            'safe'|Set-Content -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE -Encoding UTF8
        }
        Set-TestGitWorkflow -Mode direct-main
        Invoke-ResetCommand|Out-Null
    }
    AfterEach {
        Set-TestGitWorkflow -Mode direct-main
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=$script:v3SavedBoundary
        Invoke-ResetCommand|Out-Null
    }

    It '1. gitWorkflow 누락 설정은 direct-main legacy로 해석한다' {
        $legacy=[pscustomobject]@{}
        $policy=Get-GitWorkflowPolicy -Config $legacy
        $policy.mode|Should Be 'direct-main'
        $policy.legacyDefault|Should Be $true
    }

    It '2. mode direct-main은 기존 main 직접 push 계약을 유지한다' {
        $config=Get-Content -LiteralPath (Join-Path $Script:ConfigDir 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $config.gitWorkflow.mode='direct-main';$config.gitWorkflow.createDraftPullRequest=$false;$config.gitWorkflow.fetchBeforeRun=$false
        (Get-GitWorkflowPolicy -Config $config).mode|Should Be 'direct-main'
        (Get-FixedExecutionContract -Workflow ([pscustomobject]@{mode='direct-main'}))|Should Match 'origin/main'
    }

    It '3. mode pull-request는 실제 branch 값이 들어간 PR worker 계약을 사용한다' {
        $w=[pscustomobject]@{mode='pull-request';baseBranch='main';baseHead=('a'*40);workBranch='operation-router/issue-3'
            remoteWorkBranch='origin/operation-router/issue-3';issueNumber=3}
        $order=New-OrderContent -IssueBody 'body' -Workflow $w
        $order|Should Match 'workflow mode: pull-request'
        $order|Should Match 'expected branch: operation-router/issue-3'
    }

    It '4. 알 수 없는 gitWorkflow mode는 fail-closed 한다' {
        $config=Get-Content -LiteralPath (Join-Path $Script:ConfigDir 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $config.gitWorkflow.mode='unsafe'
        {Get-GitWorkflowPolicy -Config $config}|Should Throw
        $config.gitWorkflow.mode='Pull-Request'
        {Get-GitWorkflowPolicy -Config $config}|Should Throw
        $config.gitWorkflow.mode='pull-request';$config.gitWorkflow.autoMerge='false'
        {Get-GitWorkflowPolicy -Config $config}|Should Throw
    }

    It '5. 위험한 baseBranch와 branchPrefix는 모두 거부한다' {
        $bad=@('bad branch','a..b','a~b','a^b','a:b','a?b','a*b','a[b','a\b','/main','main/','a//b','name.lock',"bad`nref",'main;whoami','a$(whoami)')
        foreach($value in $bad){(Test-SafeGitRefPolicyValue -Value $value)|Should Be $false}
        (Test-SafeGitRefPolicyValue -Value 'release/v3')|Should Be $true
    }

    It '6. clean synced main에서 issue 전용 branch를 origin main 기준으로 생성한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 6 -Config (Get-Config) -PrProbe (New-TestPullRequestProbe).Probe
            $pre.ok|Should Be $true
            (Get-GitCurrentBranch -Path $f.Repo)|Should Be 'operation-router/issue-6'
            $pre.workflow.workStartHead|Should Be $pre.workflow.baseRemoteHead
        } finally {Remove-PrFakeRepo $f}
    }

    It '7. dirty main은 worker 호출 전에 중단한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo
        try {
            'dirty'|Set-Content -LiteralPath (Join-Path $f.Repo 'dirty.txt') -Encoding UTF8
            (Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 7 -Config (Get-Config)).reason|Should Be 'dirty_worktree'
        } finally {Remove-PrFakeRepo $f}
    }

    It '8. local main behind remote는 자동 pull 없이 중단한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo;$peer=Join-Path $f.Root 'peer'
        try {
            git clone -q ([System.Uri]::new($f.Remote).AbsoluteUri) $peer
            Push-Location $peer
            try {git config user.email t@t.com;git config user.name t;'remote'|Set-Content remote.txt;git add .;git commit -q -m remote;git push -q origin main}finally{Pop-Location}
            (Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 8 -Config (Get-Config)).reason|Should Be 'base_behind_remote'
        } finally {Remove-PrFakeRepo $f}
    }

    It '9. local main ahead remote는 자동 push 없이 중단한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo
        try {
            Push-Location $f.Repo
            try {'local'|Set-Content local.txt;git add .;git commit -q -m local}finally{Pop-Location}
            (Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 9 -Config (Get-Config)).reason|Should Be 'base_ahead_remote'
        } finally {Remove-PrFakeRepo $f}
    }

    It '10. fetch 실패는 remote_sync_unavailable로 중단한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 10 -Config (Get-Config) -FetchProbe {param($p,$b)$false}
            $pre.reason|Should Be 'remote_sync_unavailable'
        } finally {Remove-PrFakeRepo $f}
    }

    It '11. base나 소유 work branch가 아닌 임의 branch에서 시작하면 중단한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo
        try {
            Push-Location $f.Repo;try{git switch -q -c arbitrary}finally{Pop-Location}
            (Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 11 -Config (Get-Config)).reason|Should Be 'not_on_base_or_work_branch'
        } finally {Remove-PrFakeRepo $f}
    }

    It '12. valid receipt가 소유한 기존 work branch는 재개할 수 있다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 12 -Config (Get-Config)
            Add-Member -InputObject $pre.workflow -NotePropertyName issueNumber -NotePropertyValue 12 -Force
            Push-Location $f.Repo
            try {
                'resume'|Set-Content -LiteralPath resume.txt -Encoding UTF8
                git add resume.txt
                git commit -q -m resume
                git push -q -u origin HEAD
            } finally {Pop-Location}
            $pre.workflow.finalHead=Get-GitHead -Path $f.Repo
            $pr.State.Items=@([pscustomobject]@{number=12;url='https://example.invalid/pr/12';state='OPEN';draft=$true
                baseBranch='main';headBranch='operation-router/issue-12';headSha=$pre.workflow.finalHead
                headRepository='owner/repo';merged=$false})
            $pre.workflow.pr=$pr.State.Items[0]
            Save-IssueWorkflowReceipt -IssueNumber 12 -RepoPath $f.Repo -Workflow $pre.workflow|Out-Null
            (Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 12 -Config (Get-Config) -PrProbe $pr.Probe).ok|Should Be $true
        } finally {Remove-PrFakeRepo $f}
    }

    It '12b. 라우터가 만든 미push 초기 branch는 Claude-only 재진입 전에 같은 receipt로 재개한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $first=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 120 -Config (Get-Config) -PrProbe $pr.Probe
            $first.ok|Should Be $true
            $workflow=Copy-WorkflowContext -Workflow $first.workflow
            Add-Member -InputObject $workflow -NotePropertyName issueNumber -NotePropertyValue 120 -Force
            Save-IssueWorkflowReceipt -IssueNumber 120 -RepoPath $f.Repo -Workflow $workflow|Out-Null
            $second=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 120 -Config (Get-Config) -PrProbe $pr.Probe
            $second.ok|Should Be $true
            $second.workflow.workBranch|Should Be 'operation-router/issue-120'
            $pr.State.LookupCalls|Should Be 0
        } finally {Remove-PrFakeRepo $f}
    }

    It '13. receipt 없는 기존 remote issue branch는 자동 채택하지 않는다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo
        try {
            Push-Location $f.Repo;try{git push -q origin 'main:refs/heads/operation-router/issue-13'}finally{Pop-Location}
            (Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 13 -Config (Get-Config)).reason|Should Be 'work_branch_unowned'
        } finally {Remove-PrFakeRepo $f}
    }

    It '14. PR mode 주문서에 expected branch와 실제 issue number가 포함된다' {
        $w=[pscustomobject]@{mode='pull-request';baseBranch='main';baseHead=('1'*40);workBranch='operation-router/issue-14'
            remoteWorkBranch='origin/operation-router/issue-14';issueNumber=14}
        $order=New-OrderContent -IssueBody 'x' -Workflow $w
        $order|Should Match 'expected branch: operation-router/issue-14'
        $order|Should Match 'issue number: 14'
        $order|Should Match '\[ORH_WORKER_REPORT\].*localVerificationComplete'
    }

    It '14b. 실제 worker 최종 메시지의 엄격 완료 보고만 로컬 검증 증거로 읽는다' {
        $marker='[ORH_WORKER_REPORT] {"localVerificationComplete":true,"verification":"12 tests passed","remainingProblems":[]}'
        $plain=ConvertFrom-WorkerCompletionReport -Text $marker
        $plain.valid|Should Be $true;$plain.localVerificationComplete|Should Be $true;$plain.verification|Should Be '12 tests passed'
        $grok=ConvertFrom-WorkerCompletionReport -Text (([pscustomobject]@{text="done`n$marker";stopReason='EndTurn'}|ConvertTo-Json -Compress))
        $grok.valid|Should Be $true
        $gptLine=([pscustomobject]@{type='item.completed';item=[pscustomobject]@{type='agent_message';text="done`n$marker"}}|ConvertTo-Json -Compress)
        (ConvertFrom-WorkerCompletionReport -Text $gptLine).valid|Should Be $true
        (ConvertFrom-WorkerCompletionReport -Text '[ORH_WORKER_REPORT] {"localVerificationComplete":"true","verification":"x","remainingProblems":[]}').valid|Should Be $false
        (ConvertFrom-WorkerCompletionReport -Text '[ORH_WORKER_REPORT] {"localVerificationComplete":true,"verification":"x","remainingProblems":"none"}').valid|Should Be $false
    }

    It 'F2. 마커와 JSON 사이의 CLI 장식이 있어도 완료 보고를 읽는다' {
        # 회귀: grok은 계약대로 보고하면서 마커 뒤에 ': #display-json' 렌더링 주석을 붙인다
        # (2026-07-24 op1-issue19 실측). 이전 정규식은 공백만 허용해 성공 실행의 보고를 버렸고,
        # localVerificationComplete=false가 되어 finalize가 merge_ready에 도달하지 못했다.
        $body='{"localVerificationComplete":true,"verification":"lint/typecheck/test(407) PASS","remainingProblems":[]}'
        $decorated="[ORH_WORKER_REPORT]: #display-json $body"
        $r=ConvertFrom-WorkerCompletionReport -Text $decorated
        $r.valid|Should Be $true
        $r.localVerificationComplete|Should Be $true
        $r.verification|Should Be 'lint/typecheck/test(407) PASS'

        # grok JSON 봉투 안에 장식된 마커가 들어 있어도 동일하게 복원한다
        $grokEnvelope=([pscustomobject]@{text="작업 완료`n$decorated";stopReason='EndTurn'}|ConvertTo-Json -Compress)
        (ConvertFrom-WorkerCompletionReport -Text $grokEnvelope).valid|Should Be $true

        # 장식이 없는 기존 형식도 계속 동작한다
        (ConvertFrom-WorkerCompletionReport -Text "[ORH_WORKER_REPORT] $body").valid|Should Be $true

        # 스키마 위반은 장식이 있어도 여전히 거부한다 (fail-closed 유지)
        (ConvertFrom-WorkerCompletionReport -Text '[ORH_WORKER_REPORT]: #display-json {"localVerificationComplete":"true","verification":"x","remainingProblems":[]}').valid|Should Be $false
    }

    It '15. PR mode 주문서는 main checkout과 main push를 명시적으로 금지한다' {
        $w=[pscustomobject]@{mode='pull-request';baseBranch='main';baseHead=('1'*40);workBranch='operation-router/issue-15'
            remoteWorkBranch='origin/operation-router/issue-15';issueNumber=15}
        $order=New-OrderContent -IssueBody 'x' -Workflow $w
        $order|Should Match 'main으로 checkout하거나 main에 push하지 않는다'
        $order|Should Match 'configured base branch\(main\)로 checkout하거나 그 branch에 push하지 않는다'
        $order|Should Match 'PR과 이슈를 생성·수정·댓글·종료·병합하지 않는다'
    }

    It '16. direct-main 주문서는 main commit과 origin main push 계약을 회귀 유지한다' {
        $order=New-OrderContent -IssueBody 'x' -Workflow ([pscustomobject]@{mode='direct-main'})
        $order|Should Match '현재 main 브랜치에서만'
        $order|Should Match 'origin/main에 push'
    }

    It '17. worker가 assigned branch를 바꾸면 postflight가 실패한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $res=Invoke-RunOperation -OperationNumber 2 -IssueNumber 17 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker switch-main) -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $res.status|Should Be 'work_branch_mismatch'
        } finally {Remove-PrFakeRepo $f}
    }

    It '18. worker final commit이 origin main에 들어가면 base_branch_touched로 실패한다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $res=Invoke-RunOperation -OperationNumber 2 -IssueNumber 18 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker main-push) -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $res.status|Should Be 'base_branch_touched'
        } finally {Remove-PrFakeRepo $f}
    }

    It '19. work branch local HEAD와 origin HEAD가 같으면 pushComplete다' {
        Set-TestGitWorkflow -Mode pull-request;$f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $res=Invoke-RunOperation -OperationNumber 2 -IssueNumber 19 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker success) -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $res.status|Should Be 'pr_opened'
            $res.pushComplete|Should Be $true
            $observable=Get-ExecutionObservableState -RepoPath $f.Repo -RemoteRef 'origin/operation-router/issue-19'
            $observable.ahead|Should Be 0;$observable.behind|Should Be 0
            (Get-Content -LiteralPath (Join-Path $RouterRoot 'scripts\worker-host.ps1') -Raw -Encoding UTF8)|Should Match 'ObservableRemoteRef'
            $saved=Get-RunReceipt -Operation 2 -IssueNumber 19 -RepoPath $f.Repo
            $remoteProbe={
                param($repo,$branch)
                if($branch -eq 'main'){return $null}
                $text=(& git -C $repo ls-remote --heads origin "refs/heads/$branch"|Out-String).Trim()
                if($text){return @($text -split '\s+')[0]}
                return $null
            }
            $remoteFailure=Resolve-PullRequestPostflight -RepoPath $f.Repo -StartSnapshot ([pscustomobject]@{startHead=$saved.startHead}) `
                -WorkerResult ([pscustomobject]@{Success=$true;ExitCode=0;WorkerReportedVerification='ok'}) -Workflow $saved.workflow `
                -Operation 2 -IssueNumber 19 -Route ([pscustomobject]@{worker='grok';model='grok-4.5';effort='medium'}) `
                -PrProbe $pr.Probe -RemoteHeadProbe $remoteProbe -ExistingPrOnly
            $remoteFailure.status|Should Be 'remote_sync_unavailable'
        } finally {Remove-PrFakeRepo $f}
    }

    It '20. 같은 clone에서 다른 issue mutation은 repository_execution_active로 차단한다' {
        $f=New-PrFakeRepo
        try {
            $first=Enter-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 20 -Purpose run
            $second=Enter-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 21 -Purpose run
            $second.status|Should Be 'repository_execution_active'
            $second.activeIssueNumber|Should Be 20
            Exit-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 20 -Token $first.token|Should Be $true
        } finally {Remove-PrFakeRepo $f}
    }

    It '21. 같은 issue의 다른 Operation mutation도 차단한다' {
        $f=New-PrFakeRepo
        try {
            $first=Enter-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 21 -Purpose run
            (Enter-RepositoryMutation -RepoPath $f.Repo -Operation 2 -IssueNumber 21 -Purpose run).status|Should Be 'repository_execution_active'
            (Enter-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 21 -Purpose repair).status|Should Be 'repository_execution_active'
            Exit-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 21 -Token $first.token|Out-Null
        } finally {Remove-PrFakeRepo $f}
    }

    It '22. watch와 terminal receipt 읽기는 mutation lock 중에도 차단되지 않는다' {
        $f=New-PrFakeRepo
        try {
            $first=Enter-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 22 -Purpose run
            (Get-RepositoryMutationReceipt -RepoPath $f.Repo).issueNumber|Should Be 22
            (Invoke-WatchCommand -OperationNumber 1 -IssueNumber 22 -RepoPath $f.Repo).status|Should Be 'receipt_unreadable'
            Exit-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 22 -Token $first.token|Out-Null
        } finally {Remove-PrFakeRepo $f}
    }

    It '23. terminal 또는 stale 판정 전에는 잘못된 token으로 lock을 해제할 수 없다' {
        $f=New-PrFakeRepo
        try {
            $first=Enter-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 23 -Purpose run
            (Exit-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 23 -Token 'wrong')|Should Be $false
            (Get-RepositoryMutationReceipt -RepoPath $f.Repo)|Should Not Be $null
            Exit-RepositoryMutation -RepoPath $f.Repo -Operation 1 -IssueNumber 23 -Token $first.token|Out-Null
        } finally {Remove-PrFakeRepo $f}
    }

    It '24. 다른 clone namespace의 mutation lock은 독립적이다' {
        $a=New-PrFakeRepo;$b=New-PrFakeRepo
        try {
            $la=Enter-RepositoryMutation -RepoPath $a.Repo -Operation 1 -IssueNumber 24 -Purpose run
            $lb=Enter-RepositoryMutation -RepoPath $b.Repo -Operation 2 -IssueNumber 24 -Purpose run
            $la.acquired|Should Be $true;$lb.acquired|Should Be $true
            Exit-RepositoryMutation -RepoPath $a.Repo -Operation 1 -IssueNumber 24 -Token $la.token|Out-Null
            Exit-RepositoryMutation -RepoPath $b.Repo -Operation 2 -IssueNumber 24 -Token $lb.token|Out-Null
        } finally {Remove-PrFakeRepo $a;Remove-PrFakeRepo $b}
    }
}

Describe 'v3.0.0. Draft PR와 PR CI workflow' {
    BeforeEach {
        $script:v3SavedBoundary=$env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=Join-Path $TestWorkRoot 'v3-safe-boundary.txt'
        if(-not (Test-Path -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE)){'safe'|Set-Content -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE -Encoding UTF8}
        Set-TestGitWorkflow -Mode pull-request
        Invoke-ResetCommand|Out-Null
    }
    AfterEach {
        Set-TestGitWorkflow -Mode direct-main
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=$script:v3SavedBoundary
        Invoke-ResetCommand|Out-Null
    }

    It '25. branch push 검증 뒤 Draft PR을 생성한다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $res=Invoke-RunOperation -OperationNumber 2 -IssueNumber 25 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker success) -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $res.status|Should Be 'pr_opened'
            $res.prNumber|Should Be 42
            $res.prDraft|Should Be $true
            $pr.State.CreateCalls|Should Be 1
            $pr.State.Items[0].draft|Should Be $true
            $pr.State.Items[0].baseBranch|Should Be 'main'
            $pr.State.Items[0].headBranch|Should Be 'operation-router/issue-25'
        } finally {Remove-PrFakeRepo $f}
    }

    It '26. 동일 base와 head의 기존 Draft PR은 재사용한다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $first=Invoke-RunOperation -OperationNumber 2 -IssueNumber 26 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker success) -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $first.status|Should Be 'pr_opened'
            $second=Invoke-RunOperation -OperationNumber 2 -IssueNumber 26 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker success) -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $second.status|Should Be 'pr_opened'
            $pr.State.CreateCalls|Should Be 1
        } finally {Remove-PrFakeRepo $f}
    }

    It '27. 다른 base의 PR은 fail-closed 한다' {
        $p=[pscustomobject]@{number=1;state='OPEN';draft=$true;baseBranch='develop';headBranch='operation-router/issue-27';headSha=('a'*40)}
        (Test-PullRequestContext -PullRequest $p -BaseBranch main -WorkBranch 'operation-router/issue-27' -HeadSha ('a'*40) -RequireDraft).status|Should Be 'pr_context_mismatch'
    }

    It '28. 다른 head의 PR은 fail-closed 한다' {
        $p=[pscustomobject]@{number=1;state='OPEN';draft=$true;baseBranch='main';headBranch='other';headSha=('a'*40)}
        (Test-PullRequestContext -PullRequest $p -BaseBranch main -WorkBranch 'operation-router/issue-28' -HeadSha ('a'*40) -RequireDraft).status|Should Be 'pr_context_mismatch'
        $wrongRepo=[pscustomobject]@{number=2;state='OPEN';draft=$true;baseBranch='main';headBranch='operation-router/issue-28'
            headSha=('a'*40);headRepository='other/fork'}
        (Test-PullRequestContext -PullRequest $wrongRepo -BaseBranch main -WorkBranch 'operation-router/issue-28' -HeadSha ('a'*40) `
            -OwnerRepo 'owner/repo' -RequireDraft).status|Should Be 'pr_context_mismatch'
    }

    It '29. closed PR은 재사용하지 않는다' {
        $p=[pscustomobject]@{number=1;state='CLOSED';draft=$true;baseBranch='main';headBranch='operation-router/issue-29';headSha=('a'*40)}
        (Test-PullRequestContext -PullRequest $p -BaseBranch main -WorkBranch 'operation-router/issue-29' -HeadSha ('a'*40) -RequireDraft).status|Should Be 'pr_already_closed'
    }

    It '30. merged PR은 재사용하지 않는다' {
        $p=[pscustomobject]@{number=1;state='MERGED';draft=$false;merged=$true;baseBranch='main';headBranch='operation-router/issue-30';headSha=('a'*40)}
        (Test-PullRequestContext -PullRequest $p -BaseBranch main -WorkBranch 'operation-router/issue-30' -HeadSha ('a'*40) -RequireDraft).status|Should Be 'pr_already_merged'
    }

    It '31. 예기치 않은 non-draft PR은 fail-closed 한다' {
        $p=[pscustomobject]@{number=1;state='OPEN';draft=$false;baseBranch='main';headBranch='operation-router/issue-31';headSha=('a'*40)}
        (Test-PullRequestContext -PullRequest $p -BaseBranch main -WorkBranch 'operation-router/issue-31' -HeadSha ('a'*40) -RequireDraft).status|Should Be 'pr_not_draft'
    }

    It '32. PR 생성 실패를 branch push 성공으로 위장하지 않는다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe;$pr.State.CreateFailure=$true
        try {
            $res=Invoke-RunOperation -OperationNumber 2 -IssueNumber 32 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker success) -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $res.status|Should Be 'pr_create_failed'
            $res.pushComplete|Should Be $true
        } finally {Remove-PrFakeRepo $f}
    }

    It '33. PR body는 secret을 마스킹하고 prompt와 raw output 원문을 포함하지 않는다' {
        $w=[pscustomobject]@{baseBranch='main';baseHead=('a'*40);workBranch='operation-router/issue-33';workStartHead=('a'*40);finalHead=('b'*40)}
        $route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='high'}
        $secret='Authorization: Bearer abcdefghij1234567890'
        $body=New-PullRequestBody -Operation 1 -IssueNumber 33 -Route $route -Workflow $w -VerificationSummary $secret
        $body|Should Not Match 'abcdefghij1234567890'
        $body|Should Match '\*\*\*MASKED\*\*\*'
        $body|Should Not Match 'GitHub 이슈 원문'
    }

    It '34. PR body 임시 파일은 create 호출 뒤 제거된다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $res=Invoke-RunOperation -OperationNumber 2 -IssueNumber 34 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker success) -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $res.status|Should Be 'pr_opened'
            $pr.State.BodyPathExistedDuringCreate|Should Be $true
            (Test-Path -LiteralPath $pr.State.BodyPath)|Should Be $false
        } finally {Remove-PrFakeRepo $f}
    }

    It '35. 동일 PR head의 모든 check가 success면 success다' {
        $f=New-PrFakeRepo
        try {
            $ci=Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@(
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context 'build' -Id 1),
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context 'test' -Id 2)
                )}}
            $ci|Should Be 'success'
        } finally {Remove-PrFakeRepo $f}
    }

    It '36. 하나라도 failure check가 있으면 failure다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@(
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context 'build' -Id 1),
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context 'test' -Conclusion failure -Id 2)
                )}})|Should Be 'failure'
        } finally {Remove-PrFakeRepo $f}
    }

    It '37. 실패가 없고 pending check가 있으면 pending이다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@(
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context 'build' -Id 1),
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context 'test' -Status in_progress -Conclusion $null -Id 2)
                )}})|Should Be 'pending'
        } finally {Remove-PrFakeRepo $f}
    }

    It '38. neutral skipped unknown conclusion은 unavailable이다' {
        $f=New-PrFakeRepo
        try {
            foreach($value in @('neutral','skipped','mystery')){
                $wanted=$value
                $lister={param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@(
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Conclusion $wanted)
                )}}.GetNewClosure()
                (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 -CheckLister $lister)|Should Be 'unavailable'
            }
        } finally {Remove-PrFakeRepo $f}
    }

    It '39. workflow가 있는데 polling 종료까지 check가 없으면 unavailable이다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}})|Should Be 'unavailable'
        } finally {Remove-PrFakeRepo $f}
    }

    It '40. workflow와 check가 모두 없으면 not-requested다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $false -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}})|Should Be 'not-requested'
        } finally {Remove-PrFakeRepo $f}
    }

    It '41. PR check API나 JSON probe 오류는 unavailable이다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$false;checks=@()}})|Should Be 'unavailable'
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)throw 'mock API failure'})|Should Be 'unavailable'
        } finally {Remove-PrFakeRepo $f}
    }

    It '42. 첫 check만 성공이어도 뒤 check 실패를 포함해 전체를 집계한다' {
        $f=New-PrFakeRepo
        try {
            $lister={param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@(
                (New-PrCiCheck -PrNumber $n -HeadSha $h -Context 'build' -Id 1),
                (New-PrCiCheck -PrNumber $n -HeadSha $h -Context 'test' -Conclusion cancelled -Id 2)
            )}}
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 1 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 -CheckLister $lister)|Should Be 'failure'
        } finally {Remove-PrFakeRepo $f}
    }
}

Describe 'v3.0.0. workflow receipt와 merge_ready' {
    BeforeEach {
        $script:v3SavedBoundary=$env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=Join-Path $TestWorkRoot 'v3-safe-boundary.txt'
        if(-not (Test-Path -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE)){'safe'|Set-Content -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE -Encoding UTF8}
        Set-TestGitWorkflow -Mode pull-request
        Invoke-ResetCommand|Out-Null
    }
    AfterEach {
        Set-TestGitWorkflow -Mode direct-main
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=$script:v3SavedBoundary
        Invoke-ResetCommand|Out-Null
    }

    It '43. workflow context는 JSON receipt에 round-trip 된다' {
        $f=New-PrFakeRepo
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 43 -Config (Get-Config)
            Add-Member -InputObject $pre.workflow -NotePropertyName issueNumber -NotePropertyValue 43 -Force
            Save-IssueWorkflowReceipt -IssueNumber 43 -RepoPath $f.Repo -Workflow $pre.workflow|Out-Null
            $saved=Get-IssueWorkflowReceipt -IssueNumber 43 -RepoPath $f.Repo
            $saved.schemaVersion|Should Be 2
            $saved.workflow.mode|Should Be 'pull-request'
            $saved.workflow.workBranch|Should Be 'operation-router/issue-43'
            $saved.workflow.baseHead|Should Be $pre.workflow.baseHead
        } finally {Remove-PrFakeRepo $f}
    }

    It '44. schemaVersion 1 receipt는 pull-request로 추측하지 않고 direct-main legacy다' {
        $legacy=[pscustomobject]@{schemaVersion=1;operation=1;status='completed'}
        $w=Get-ReceiptWorkflowContext -Receipt $legacy
        $w.mode|Should Be 'direct-main'
        $w.legacyReceipt|Should Be $true
    }

    It '45. active receipt mode는 이후 config mode 변경으로 바뀌지 않는다' {
        $f=New-PrFakeRepo
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 45 -Config (Get-Config)
            Save-IssueWorkflowReceipt -IssueNumber 45 -RepoPath $f.Repo -Workflow $pre.workflow|Out-Null
            Set-TestGitWorkflow -Mode direct-main
            (Get-ReceiptWorkflowContext -Receipt (Get-IssueWorkflowReceipt -IssueNumber 45 -RepoPath $f.Repo)).mode|Should Be 'pull-request'
        } finally {Remove-PrFakeRepo $f}
    }

    It '46. review는 current branch mismatch를 worker 호출 전에 차단한다' {
        $f=New-PrFakeRepo
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 46 -Config (Get-Config)
            $head=Get-GitHead -Path $f.Repo
            $receipt=[pscustomobject]@{finalHead=$head;workflow=$pre.workflow}
            Push-Location $f.Repo;try{git switch -q main}finally{Pop-Location}
            (Test-PullRequestReviewContext -RunReceipt $receipt -RepoPath $f.Repo).status|Should Be 'work_branch_mismatch'
        } finally {Remove-PrFakeRepo $f}
    }

    It '47. review는 PR head SHA mismatch를 차단한다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe -AutoAdvanceHead:$false
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 47 -Config (Get-Config)
            $head=Get-GitHead -Path $f.Repo
            $pr.State.Items=@([pscustomobject]@{number=47;url='x';state='OPEN';draft=$true;baseBranch='main'
                headBranch='operation-router/issue-47';headSha=('f'*40);headRepository='owner/repo';merged=$false})
            $receipt=[pscustomobject]@{finalHead=$head;workflow=$pre.workflow}
            (Test-PullRequestReviewContext -RunReceipt $receipt -RepoPath $f.Repo -PrProbe $pr.Probe).status|Should Be 'pr_context_mismatch'
            $pr.State.Items[0].headSha=$head
            $pre.workflow.pr=[pscustomobject]@{number=99;headSha=$head}
            (Test-PullRequestReviewContext -RunReceipt $receipt -RepoPath $f.Repo -PrProbe $pr.Probe).status|Should Be 'pr_context_mismatch'
        } finally {Remove-PrFakeRepo $f}
    }

    It '48. repair는 기존 work branch와 같은 Draft PR을 재사용한다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe;$checks={param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}
        }
        try {
            $run=Invoke-RunOperation -OperationNumber 1 -IssueNumber 48 -RepoPath $f.Repo -IssueFetcher $issue `
                -GrokRunner (New-PrWorker success) -PrProbe $pr.Probe -CheckLister $checks
            $run.status|Should Be 'pr_opened'
            $review=Invoke-OperationReview -OperationNumber 1 -IssueNumber 48 -RepoPath $f.Repo -IssueFetcher $issue -PrProbe $pr.Probe `
                -GptReviewRunner {param($p,$o,$r)[pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;Output='{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"high","file":"a.txt","issue":"x","requiredFix":"y"}]}'}}
            $review.verdict|Should Be 'REPAIR_REQUIRED'
            $repair=Invoke-RepairCommand -OperationNumber 1 -IssueNumber 48 -RepoPath $f.Repo -IssueFetcher $issue `
                -RepairRunner (New-PrWorker success) -PrProbe $pr.Probe -CheckLister $checks
            $repair.status|Should Be 'repair_completed_review_pending'
            $pr.State.CreateCalls|Should Be 1
            $repair.workflow.pr.number|Should Be 42
        } finally {Remove-PrFakeRepo $f}
    }

    It '49. repair postflight는 PR이 없을 때 새 PR을 생성하지 않는다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 49 -Config (Get-Config)
            Add-Member -InputObject $pre.workflow -NotePropertyName issueNumber -NotePropertyValue 49 -Force
            $pre.workflow.finalHead=Get-GitHead -Path $f.Repo
            $route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='medium'}
            $res=Ensure-DraftPullRequest -RepoPath $f.Repo -Operation 1 -IssueNumber 49 -Route $route -Workflow $pre.workflow -PrProbe $pr.Probe -ExistingOnly
            $res.status|Should Be 'pr_context_mismatch'
            $pr.State.CreateCalls|Should Be 0
        } finally {Remove-PrFakeRepo $f}
    }

    It '50. pull-request recover는 result가 없으면 unverified 자격을 유지한다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe;$issueNumber=50
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber $issueNumber -Config (Get-Config)
            Add-Member -InputObject $pre.workflow -NotePropertyName issueNumber -NotePropertyValue $issueNumber -Force
            Push-Location $f.Repo
            try {'recover'|Set-Content recover.txt;git add .;git commit -q -m recover;git push -q -u origin HEAD}finally{Pop-Location}
            $head=Get-GitHead -Path $f.Repo
            $pr.State.Items=@([pscustomobject]@{number=50;url='x';state='OPEN';draft=$true;baseBranch='main'
                headBranch='operation-router/issue-50';headSha=$head;headRepository='owner/repo';merged=$false})
            $pf=Resolve-PullRequestRecoveryPostflight -RepoPath $f.Repo -StartSnapshot $pre.snapshot -Workflow $pre.workflow `
                -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $pf.status|Should Be 'recovered_pr_commit_unverified'
        } finally {Remove-PrFakeRepo $f}
    }

    It '51. final PASS와 PR 연결 CI success가 모두 확인되면 Draft 유지 merge_ready다' {
        $m=New-PrMergeFixture -IssueNumber 51
        try {
            $res=Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 51 -ReviewVerdict PASS -RepoPath $m.Fixture.Repo -PrProbe $m.Probe.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h))}}
            $res.status|Should Be 'merge_ready'
            $res.prDraft|Should Be $true
            $res.merged|Should Be $false
            $m.Probe.State.ReadyCalls|Should Be 0
        } finally {Remove-PrFakeRepo $m.Fixture}
    }

    It '52. PASS여도 CI pending이면 merge_ready가 아니다' {
        $m=New-PrMergeFixture -IssueNumber 52
        try {
            $res=Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 52 -ReviewVerdict PASS -RepoPath $m.Fixture.Repo -PrProbe $m.Probe.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h -Status in_progress -Conclusion $null))}}
            $res.status|Should Be 'pr_ci_pending';$res.mergeReady|Should Be $false;$m.Probe.State.ReadyCalls|Should Be 0
        } finally {Remove-PrFakeRepo $m.Fixture}
    }

    It '53. PASS여도 CI failed면 merge_ready가 아니다' {
        $m=New-PrMergeFixture -IssueNumber 53
        try {
            $res=Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 53 -ReviewVerdict PASS -RepoPath $m.Fixture.Repo -PrProbe $m.Probe.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h -Conclusion failure))}}
            $res.status|Should Be 'pr_ci_failed';$res.mergeReady|Should Be $false;$m.Probe.State.ReadyCalls|Should Be 0
        } finally {Remove-PrFakeRepo $m.Fixture}
    }

    It '54. PASS여도 CI unavailable이면 merge_ready가 아니다' {
        $m=New-PrMergeFixture -IssueNumber 54
        try {
            $res=Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 54 -ReviewVerdict PASS -RepoPath $m.Fixture.Repo -PrProbe $m.Probe.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$false;checks=@()}}
            $res.status|Should Be 'pr_ci_unavailable';$res.mergeReady|Should Be $false;$m.Probe.State.ReadyCalls|Should Be 0
        } finally {Remove-PrFakeRepo $m.Fixture}
    }

    It '55. repair 뒤 종료 검토 verdict가 PASS가 아니면 merge_ready가 아니다' {
        $m=New-PrMergeFixture -IssueNumber 55
        try {
            Add-Member -InputObject $m.Receipt -NotePropertyName finalReviewRequired -NotePropertyValue $true -Force
            (Get-WorkflowMergeReadiness -RepoPath $m.Fixture.Repo -Receipt $m.Receipt -ReviewVerdict REPAIR_REQUIRED -PrProbe $m.Probe.Probe).status|Should Be 'review_required'
        } finally {Remove-PrFakeRepo $m.Fixture}
    }

    It '56. boundary violation receipt는 merge_ready 자격이 없다' {
        $m=New-PrMergeFixture -IssueNumber 56
        try {
            $m.Receipt.status='repo_boundary_violation'
            (Get-WorkflowMergeReadiness -RepoPath $m.Fixture.Repo -Receipt $m.Receipt -ReviewVerdict PASS -PrProbe $m.Probe.Probe).status|Should Be 'repo_boundary_violation'
            $m.Receipt.status='pr_opened';$m.Receipt.artifactSanitizationStatus='failed'
            (Get-WorkflowMergeReadiness -RepoPath $m.Fixture.Repo -Receipt $m.Receipt -ReviewVerdict PASS -PrProbe $m.Probe.Probe).status|Should Be 'artifact_sanitization_failed'
            $m.Receipt.artifactSanitizationStatus='completed';$m.Receipt.artifactRetentionStatus='failed'
            (Get-WorkflowMergeReadiness -RepoPath $m.Fixture.Repo -Receipt $m.Receipt -ReviewVerdict PASS -PrProbe $m.Probe.Probe).status|Should Be 'artifact_retention_failed'
            $m.Receipt.artifactRetentionStatus='completed';$m.Receipt.localVerificationComplete=$false
            (Get-WorkflowMergeReadiness -RepoPath $m.Fixture.Repo -Receipt $m.Receipt -ReviewVerdict PASS -PrProbe $m.Probe.Probe).status|Should Be 'worker_result_unverified'
            $m.Receipt.localVerificationComplete=$true
            Add-Member -InputObject $m.Receipt -NotePropertyName workerRemainingProblems -NotePropertyValue @('manual verification still needed') -Force
            (Get-WorkflowMergeReadiness -RepoPath $m.Fixture.Repo -Receipt $m.Receipt -ReviewVerdict PASS -PrProbe $m.Probe.Probe).status|Should Be 'worker_reported_remaining_problems'
        } finally {Remove-PrFakeRepo $m.Fixture}
    }

    It '57. finalize는 Draft 해제와 자동 merge를 모두 호출하지 않는다' {
        $m=New-PrMergeFixture -IssueNumber 57
        try {
            $res=Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 57 -ReviewVerdict PASS -RepoPath $m.Fixture.Repo -PrProbe $m.Probe.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h))}}
            $res.status|Should Be 'merge_ready'
            $m.Probe.State.ReadyCalls|Should Be 0
            @($m.Probe.State.Actions|Where-Object{$_ -eq 'ready'}).Count|Should Be 0
            @($m.Probe.State.Actions|Where-Object{$_ -eq 'merge'}).Count|Should Be 0
            (Get-Content -LiteralPath (Join-Path $ScriptsDir 'git-workflow.ps1') -Raw -Encoding UTF8)|Should Not Match 'gh\s+pr\s+merge'
        } finally {Remove-PrFakeRepo $m.Fixture}
    }
}

Describe 'v3.0.0 외부 비판적 검토 결함 회귀' {
    BeforeEach {
        $script:v3ReviewSavedBoundary=$env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=Join-Path $TestWorkRoot 'v3-review-safe-boundary.txt'
        if(-not (Test-Path -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE)){
            'safe'|Set-Content -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE -Encoding UTF8
        }
        Set-TestGitWorkflow -Mode pull-request
        $reviewConfig=Get-Content -LiteralPath $Script:ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json
        $script:v3ReviewPollingInterval=[int]$reviewConfig.ciPolling.intervalSeconds
        $script:v3ReviewPollingAttempts=[int]$reviewConfig.ciPolling.maxAttempts
        $reviewConfig.ciPolling.intervalSeconds=0
        $reviewConfig.ciPolling.maxAttempts=1
        [System.IO.File]::WriteAllText($Script:ConfigPath,($reviewConfig|ConvertTo-Json -Depth 30),(New-Object System.Text.UTF8Encoding($false)))
        Invoke-ResetCommand|Out-Null
    }
    AfterEach {
        $reviewConfig=Get-Content -LiteralPath $Script:ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json
        $reviewConfig.ciPolling.intervalSeconds=$script:v3ReviewPollingInterval
        $reviewConfig.ciPolling.maxAttempts=$script:v3ReviewPollingAttempts
        [System.IO.File]::WriteAllText($Script:ConfigPath,($reviewConfig|ConvertTo-Json -Depth 30),(New-Object System.Text.UTF8Encoding($false)))
        Set-TestGitWorkflow -Mode direct-main
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=$script:v3ReviewSavedBoundary
        Invoke-ResetCommand|Out-Null
    }

    It 'Claude 완료 보고가 없으면 valid provenance와 merge_ready를 차단한다' {
        $c=New-ClaudePrPostflightFixture -IssueNumber 601
        try {
            $pf=Invoke-PostflightCommand -Operation 2 -IssueNumber 601 -RepoPath $c.Fixture.Repo -PrProbe $c.Probe.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $pf.localVerificationComplete|Should Be $false
            $pf.verificationProvenance|Should Be 'claude_completion_report_missing'
            $receipt=Get-RunReceipt -Operation 2 -IssueNumber 601 -RepoPath $c.Fixture.Repo
            $receipt.resultEnvelopePresent|Should Be $false
            $receipt.verificationProvenance|Should Not Match '^valid_'
            (Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 601 -ReviewVerdict PASS -RepoPath $c.Fixture.Repo -PrProbe $c.Probe.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h))}}).status|Should Be 'worker_result_unverified'
        } finally {Remove-PrFakeRepo $c.Fixture}
    }

    It 'Claude 완료 보고 JSON이 잘못되면 merge_ready를 차단한다' {
        $c=New-ClaudePrPostflightFixture -IssueNumber 602
        try {
            $path=Get-ClaudeCompletionReportPath -Operation 2 -IssueNumber 602 -RepoPath $c.Fixture.Repo
            [System.IO.File]::WriteAllText($path,'{not-json',(New-Object System.Text.UTF8Encoding($false)))
            $pf=Invoke-PostflightCommand -Operation 2 -IssueNumber 602 -RepoPath $c.Fixture.Repo -PrProbe $c.Probe.Probe -WorkerReportPath $path `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $pf.completionReportReason|Should Be 'claude_completion_report_invalid_json'
            (Get-RunReceipt -Operation 2 -IssueNumber 602 -RepoPath $c.Fixture.Repo).localVerificationComplete|Should Be $false
            $fixed=[ordered]@{
                schemaVersion=1;operation=2;issueNumber=602;head=(Get-GitHead -Path $c.Fixture.Repo)
                workBranch='operation-router/issue-602';localVerificationComplete=$true
                verification='  CURRENT CLAUDE SESSION COMPLETED IMPLEMENTATION  ';remainingProblems=@()
            }|ConvertTo-Json -Compress
            (ConvertFrom-ClaudeCompletionReport -Json $fixed -ExpectedOperation 2 -ExpectedIssueNumber 602 `
                -ExpectedHead (Get-GitHead -Path $c.Fixture.Repo) -ExpectedWorkBranch 'operation-router/issue-602').valid|Should Be $false
        } finally {Remove-PrFakeRepo $c.Fixture}
    }

    It 'Claude 보고의 localVerificationComplete false는 merge_ready를 차단한다' {
        $c=New-ClaudePrPostflightFixture -IssueNumber 603
        try {
            $path=Write-TestClaudeCompletionReport -Repo $c.Fixture.Repo -Operation 2 -IssueNumber 603 -LocalVerificationComplete:$false
            Invoke-PostflightCommand -Operation 2 -IssueNumber 603 -RepoPath $c.Fixture.Repo -PrProbe $c.Probe.Probe -WorkerReportPath $path `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}|Out-Null
            $receipt=Get-RunReceipt -Operation 2 -IssueNumber 603 -RepoPath $c.Fixture.Repo
            $receipt.verificationProvenance|Should Be 'valid_claude_completion_report'
            $receipt.localVerificationComplete|Should Be $false
            (Get-WorkflowMergeReadiness -RepoPath $c.Fixture.Repo -Receipt $receipt -ReviewVerdict PASS -PrProbe $c.Probe.Probe).status|Should Be 'worker_result_unverified'
        } finally {Remove-PrFakeRepo $c.Fixture}
    }

    It 'Claude 보고에 remainingProblems가 있으면 merge_ready를 차단한다' {
        $c=New-ClaudePrPostflightFixture -IssueNumber 604
        try {
            $path=Write-TestClaudeCompletionReport -Repo $c.Fixture.Repo -Operation 2 -IssueNumber 604 -RemainingProblems @('manual check remains')
            Invoke-PostflightCommand -Operation 2 -IssueNumber 604 -RepoPath $c.Fixture.Repo -PrProbe $c.Probe.Probe -WorkerReportPath $path `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}|Out-Null
            $receipt=Get-RunReceipt -Operation 2 -IssueNumber 604 -RepoPath $c.Fixture.Repo
            (Get-WorkflowMergeReadiness -RepoPath $c.Fixture.Repo -Receipt $receipt -ReviewVerdict PASS -PrProbe $c.Probe.Probe).status|Should Be 'worker_reported_remaining_problems'
        } finally {Remove-PrFakeRepo $c.Fixture}
    }

    It '유효한 Claude 보고가 정확한 HEAD와 branch에 연결되면 Draft 유지 merge_ready가 가능하다' {
        $c=New-ClaudePrPostflightFixture -IssueNumber 605
        try {
            $path=Write-TestClaudeCompletionReport -Repo $c.Fixture.Repo -Operation 2 -IssueNumber 605
            $pf=Invoke-PostflightCommand -Operation 2 -IssueNumber 605 -RepoPath $c.Fixture.Repo -PrProbe $c.Probe.Probe -WorkerReportPath $path `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $pf.localVerificationComplete|Should Be $true
            $pf.verificationProvenance|Should Be 'valid_claude_completion_report'
            $final=Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 605 -ReviewVerdict PASS -RepoPath $c.Fixture.Repo -PrProbe $c.Probe.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h))}}
            $final.status|Should Be 'merge_ready'
            $final.prDraft|Should Be $true
            $c.Probe.State.ReadyCalls|Should Be 0
        } finally {Remove-PrFakeRepo $c.Fixture}
    }

    It '다른 HEAD에 연결된 Claude 보고는 검증 증거가 아니다' {
        $c=New-ClaudePrPostflightFixture -IssueNumber 606
        try {
            $path=Write-TestClaudeCompletionReport -Repo $c.Fixture.Repo -Operation 2 -IssueNumber 606 -Head ('f'*40)
            $pf=Invoke-PostflightCommand -Operation 2 -IssueNumber 606 -RepoPath $c.Fixture.Repo -PrProbe $c.Probe.Probe -WorkerReportPath $path `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $pf.completionReportReason|Should Be 'claude_completion_report_head_mismatch'
            (Get-RunReceipt -Operation 2 -IssueNumber 606 -RepoPath $c.Fixture.Repo).verificationProvenance|Should Not Match '^valid_'
        } finally {Remove-PrFakeRepo $c.Fixture}
    }

    It 'base workflow를 receipt에 고정하고 head에서 전부 삭제하면 required_workflow_removed다' {
        $f=New-PrFakeRepo -WithWorkflow;$pr=New-TestPullRequestProbe
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 610 -Config (Get-Config)
            $pre.workflow.baseWorkflow.exists|Should Be $true
            @($pre.workflow.baseWorkflow.files).Count|Should Be 1
            $pre.workflow.baseWorkflow.digest|Should Match '^[0-9a-f]{64}$'
            Push-Location $f.Repo
            try {
                Remove-Item -LiteralPath '.github\workflows\ci.yml' -Force
                git add -A
                git commit -q -m 'remove workflow'
                git push -q -u origin HEAD
            } finally {Pop-Location}
            $wr=[pscustomobject]@{Success=$true;ExitCode=0;WorkerReportedVerification='tests passed';WorkerRemainingProblems=@()}
            $route=[pscustomobject]@{worker='grok';model='grok-4.5';effort='medium'}
            $pf=Resolve-PullRequestPostflight -RepoPath $f.Repo -StartSnapshot $pre.snapshot -WorkerResult $wr -Workflow $pre.workflow `
                -Operation 2 -IssueNumber 610 -Route $route -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $pf.status|Should Be 'required_workflow_removed'
            $pf.workflow.headWorkflow.exists|Should Be $false
        } finally {Remove-PrFakeRepo $f}
    }

    It 'base에 workflow가 없고 head에서 추가했는데 check가 없으면 unavailable이다' {
        $f=New-PrFakeRepo;$pr=New-TestPullRequestProbe
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 611 -Config (Get-Config)
            Push-Location $f.Repo
            try {
                New-Item -ItemType Directory -Path '.github\workflows' -Force|Out-Null
                "name: added`non: [pull_request]`njobs: {}"|Set-Content -LiteralPath '.github\workflows\added.yml' -Encoding UTF8
                git add .
                git commit -q -m 'add workflow'
                git push -q -u origin HEAD
            } finally {Pop-Location}
            $pf=Resolve-PullRequestPostflight -RepoPath $f.Repo -StartSnapshot $pre.snapshot `
                -WorkerResult ([pscustomobject]@{Success=$true;ExitCode=0;WorkerReportedVerification='tests passed'}) -Workflow $pre.workflow `
                -Operation 2 -IssueNumber 611 -Route ([pscustomobject]@{worker='grok';model='grok-4.5';effort='medium'}) `
                -PrProbe $pr.Probe -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}}
            $pf.status|Should Be 'pr_ci_unavailable'
            $pf.workflow.baseWorkflow.exists|Should Be $false
            $pf.workflow.headWorkflow.exists|Should Be $true
        } finally {Remove-PrFakeRepo $f}
    }

    It 'base와 head 모두 workflow가 없을 때만 check 0개를 not-requested로 허용한다' {
        $f=New-PrFakeRepo
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 612 -Config (Get-Config)
            $headSnapshot=Get-GitWorkflowSnapshot -RepoPath $f.Repo -Ref (Get-GitHead -Path $f.Repo)
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 612 -HeadSha (Get-GitHead -Path $f.Repo) `
                -BaseWorkflow $pre.workflow.baseWorkflow -HeadWorkflow $headSnapshot -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@()}})|Should Be 'not-requested'
        } finally {Remove-PrFakeRepo $f}
    }

    It 'base workflow를 유지하고 연결된 PR check가 success면 success다' {
        $f=New-PrFakeRepo -WithWorkflow;$pr=New-TestPullRequestProbe
        try {
            $pre=Initialize-GitWorkflowRun -RepoPath $f.Repo -IssueNumber 613 -Config (Get-Config)
            Push-Location $f.Repo
            try {'change'|Set-Content change.txt;git add .;git commit -q -m change;git push -q -u origin HEAD}finally{Pop-Location}
            $pf=Resolve-PullRequestPostflight -RepoPath $f.Repo -StartSnapshot $pre.snapshot `
                -WorkerResult ([pscustomobject]@{Success=$true;ExitCode=0;WorkerReportedVerification='tests passed'}) -Workflow $pre.workflow `
                -Operation 2 -IssueNumber 613 -Route ([pscustomobject]@{worker='grok';model='grok-4.5';effort='medium'}) -PrProbe $pr.Probe `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h))}}
            $pf.status|Should Be 'pr_opened'
            $pf.ciStatus|Should Be 'success'
        } finally {Remove-PrFakeRepo $f}
    }

    It 'push 성공 check만 있으면 PR CI success로 인정하지 않는다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 620 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@(
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Event push)
                )}})|Should Be 'unavailable'
        } finally {Remove-PrFakeRepo $f}
    }

    It '정확한 pull_request check만 PR CI success로 인정한다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 621 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h))}})|Should Be 'success'
        } finally {Remove-PrFakeRepo $f}
    }

    It '기본 gh probe도 Actions push suite를 버리고 실제 pull_request run suite만 인정한다' {
        $f=New-PrFakeRepo
        $global:FakeGhMode='push'
        $global:FakeGhHead='a'*40
        $global:FakeGhPr=625
        function global:gh {
            $request=($args -join ' ')
            $global:LASTEXITCODE=0
            if($request -match '/actions/runs\?'){
                $runs=@()
                if($global:FakeGhMode -eq 'pull_request'){
                    $runs=@([pscustomobject]@{
                        event='pull_request';head_sha=$global:FakeGhHead;check_suite_id=7;run_attempt=2
                        updated_at='2026-07-23T00:00:00Z';pull_requests=@([pscustomobject]@{number=$global:FakeGhPr})
                        repository=[pscustomobject]@{full_name='owner/repo'}
                    })
                }
                ConvertTo-Json -InputObject @([pscustomobject]@{workflow_runs=$runs}) -Depth 12 -Compress
                return
            }
            if($request -match '/commits/.+/check-suites'){
                $linked=[pscustomobject]@{number=$global:FakeGhPr;head=[pscustomobject]@{sha=$global:FakeGhHead}}
                $suite=[pscustomobject]@{
                    id=7;head_sha=$global:FakeGhHead;pull_requests=@($linked)
                    app=[pscustomobject]@{slug='github-actions'}
                }
                ConvertTo-Json -InputObject @([pscustomobject]@{check_suites=@($suite)}) -Depth 12 -Compress
                return
            }
            if($request -match '/check-suites/7/check-runs'){
                $check=[pscustomobject]@{
                    id=8;head_sha=$global:FakeGhHead;name='verify';status='completed';conclusion='success'
                    completed_at='2026-07-23T00:00:00Z';app=[pscustomobject]@{slug='github-actions'}
                }
                ConvertTo-Json -InputObject @([pscustomobject]@{check_runs=@($check)}) -Depth 12 -Compress
                return
            }
            if($request -match '/commits/.+/status\?'){
                ConvertTo-Json -InputObject @([pscustomobject]@{statuses=@()}) -Depth 12 -Compress
                return
            }
            $global:LASTEXITCODE=1
        }
        try {
            $push=Get-DefaultPullRequestChecks -RepoPath $f.Repo -OwnerRepo 'owner/repo' -PrNumber $global:FakeGhPr -HeadSha $global:FakeGhHead
            $push.ok|Should Be $true
            @($push.checks).Count|Should Be 0
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber $global:FakeGhPr -HeadSha $global:FakeGhHead `
                -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 -CheckLister {param($p,$n,$h)$push})|Should Be 'unavailable'

            $global:FakeGhMode='pull_request'
            $pr=Get-DefaultPullRequestChecks -RepoPath $f.Repo -OwnerRepo 'owner/repo' -PrNumber $global:FakeGhPr -HeadSha $global:FakeGhHead
            $pr.ok|Should Be $true
            @($pr.checks).Count|Should Be 1
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber $global:FakeGhPr -HeadSha $global:FakeGhHead `
                -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 -CheckLister {param($p,$n,$h)$pr})|Should Be 'success'
        } finally {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            Remove-Variable FakeGhMode,FakeGhHead,FakeGhPr -Scope Global -ErrorAction SilentlyContinue
            Remove-PrFakeRepo $f
        }
    }

    It '같은 context의 과거 failure보다 최신 rerun success를 사용한다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 622 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@(
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context test -Conclusion failure -Id 1 -UpdatedAt '2026-07-22T00:00:00Z'),
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context test -Conclusion success -Id 2 -UpdatedAt '2026-07-23T00:00:00Z')
                )}})|Should Be 'success'
        } finally {Remove-PrFakeRepo $f}
    }

    It '현재 유효 context 하나라도 failure면 failure다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 623 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@(
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context build -Conclusion success -Id 1),
                    (New-PrCiCheck -PrNumber $n -HeadSha $h -Context test -Conclusion failure -Id 2)
                )}})|Should Be 'failure'
        } finally {Remove-PrFakeRepo $f}
    }

    It 'PR 번호나 head SHA가 다른 check만 있으면 unavailable이다' {
        $f=New-PrFakeRepo
        try {
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 624 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber 999 -HeadSha $h))}})|Should Be 'unavailable'
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 624 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister {param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha ('b'*40)))}})|Should Be 'unavailable'
            $unverified=New-PrCiCheck -PrNumber 624 -HeadSha ('a'*40)
            Add-Member -InputObject $unverified -NotePropertyName associationVerified -NotePropertyValue $false
            $unverifiedLister={param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@($unverified)}}.GetNewClosure()
            (Get-PullRequestCiStatus -RepoPath $f.Repo -PrNumber 624 -HeadSha ('a'*40) -WorkflowPresent $true -MaxAttempts 1 -PollIntervalSeconds 0 `
                -CheckLister $unverifiedLister)|Should Be 'unavailable'
        } finally {Remove-PrFakeRepo $f}
    }

    It 'finalize 재실행은 원격 Draft 상태를 바꾸지 않고 같은 merge_ready를 반환한다' {
        $m=New-PrMergeFixture -IssueNumber 630
        try {
            $checks={param($p,$n,$h)[pscustomobject]@{ok=$true;checks=@((New-PrCiCheck -PrNumber $n -HeadSha $h))}}
            $first=Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 630 -ReviewVerdict PASS -RepoPath $m.Fixture.Repo -PrProbe $m.Probe.Probe -CheckLister $checks
            $second=Invoke-FinalizeCommand -OperationNumber 2 -IssueNumber 630 -ReviewVerdict PASS -RepoPath $m.Fixture.Repo -PrProbe $m.Probe.Probe -CheckLister $checks
            $first.status|Should Be 'merge_ready';$second.status|Should Be 'merge_ready'
            $first.prDraft|Should Be $true;$second.prDraft|Should Be $true
            $m.Probe.State.ReadyCalls|Should Be 0
            (Get-Content -LiteralPath (Join-Path $ScriptsDir 'git-workflow.ps1') -Raw -Encoding UTF8)|Should Not Match 'gh\s+pr\s+ready'
        } finally {Remove-PrFakeRepo $m.Fixture}
    }

    It '40,000자 뒤 결함도 파일별 diff chunk 검토에서 발견한다' {
        Set-TestGitWorkflow -Mode direct-main
        $repo=New-FakeRepo -WithRemote
        try {
            $large=('A'*65000)+"`nCRITICAL_TAIL_DEFECT"
            [System.IO.File]::WriteAllText((Join-Path $repo 'large.txt'),$large,(New-Object System.Text.UTF8Encoding($false)))
            Push-Location $repo;try{git add large.txt;git commit -q -m large}finally{Pop-Location}
            Save-TestRunReceipt -Repo $repo -IssueNum 640
            $script:coverageCalls=0
            $runner={
                param($r,$prompt,$route)
                $script:coverageCalls++
                $text=Get-Content -LiteralPath $prompt -Raw -Encoding UTF8
                if($text -match 'CRITICAL_TAIL_DEFECT'){
                    return [pscustomobject]@{ExitCode=0;Success=$true;Output='{"verdict":"REPAIR_REQUIRED","findings":[{"severity":"high","file":"large.txt","issue":"tail defect","requiredFix":"repair tail"}]}'}
                }
                return [pscustomobject]@{ExitCode=0;Success=$true;Output='{"verdict":"PASS","findings":[]}'}
            }
            $review=Invoke-OperationReview -OperationNumber 1 -IssueNumber 640 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $review.verdict|Should Be 'REPAIR_REQUIRED'
            $script:coverageCalls|Should BeGreaterThan 1
            $review.coverageComplete|Should Be $true
            $receipt=Get-ReviewReceipt -Operation 1 -IssueNumber 640 -RepoPath $repo
            (@($receipt.changedFiles) -contains 'large.txt')|Should Be $true
            (@($receipt.reviewedFiles) -contains 'large.txt')|Should Be $true
            @($receipt.truncatedFiles).Count|Should Be 0
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It 'coverage receipt는 모든 changedFiles와 reviewedFiles 및 빈 truncatedFiles를 기록한다' {
        Set-TestGitWorkflow -Mode direct-main
        $repo=New-FakeRepo -WithRemote
        try {
            'one'|Set-Content -LiteralPath (Join-Path $repo 'one.txt') -Encoding UTF8
            'two'|Set-Content -LiteralPath (Join-Path $repo 'two.txt') -Encoding UTF8
            Push-Location $repo;try{git add .;git commit -q -m two-files}finally{Pop-Location}
            Save-TestRunReceipt -Repo $repo -IssueNum 642
            $runner={param($r,$prompt,$route)[pscustomobject]@{ExitCode=0;Success=$true;Output='{"verdict":"PASS","findings":[]}'}}
            $review=Invoke-OperationReview -OperationNumber 1 -IssueNumber 642 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $review.verdict|Should Be 'PASS'
            $receipt=Get-ReviewReceipt -Operation 1 -IssueNumber 642 -RepoPath $repo
            $receipt.coverageComplete|Should Be $true
            @($receipt.changedFiles).Count|Should Be 2
            @($receipt.reviewedFiles).Count|Should Be 2
            @($receipt.truncatedFiles).Count|Should Be 0
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It '원격 CI는 pull_request와 main push에서 Windows 정식 검증을 secret 없이 실행한다' {
        $workflowPath=Join-Path $RouterRoot '.github\workflows\operation-router-tests.yml'
        (Test-Path -LiteralPath $workflowPath)|Should Be $true
        $raw=Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
        $raw|Should Match '(?m)^\s{2}pull_request:'
        $raw|Should Match '(?m)^\s{2}push:'
        $raw|Should Match 'runs-on:\s*windows-latest'
        $raw|Should Match 'tests\\run-tests\.ps1'
        $raw|Should Match 'tests\\run-installed-fixture\.ps1'
        $raw|Should Match 'Language\.Parser'
        $raw|Should Match 'config\\config\.json'
        $raw|Should Match 'manifest-sha256\.txt'
        $raw|Should Match 'Create isolated doctor fixtures'
        $raw|Should Match 'tests\\fixtures\\ci-bin'
        $raw|Should Match 'tests\\fixtures\\models-cache\.ci\.json'
        $raw|Should Not Match 'pull_request_target'
        $raw|Should Not Match '\$\{\{\s*secrets\.'
        (Test-Path -LiteralPath (Join-Path $RouterRoot 'tests\fixtures\ci-bin\codex.ps1'))|Should Be $true
        (Test-Path -LiteralPath (Join-Path $RouterRoot 'tests\fixtures\ci-bin\grok.ps1'))|Should Be $true
        $models=Get-Content -LiteralPath (Join-Path $RouterRoot 'tests\fixtures\models-cache.ci.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $slugs=@($models.models|ForEach-Object{$_.slug})
        $slugs.Count|Should Be 3
        $slugs[0]|Should Be 'gpt-5.6-sol'
        $slugs[1]|Should Be 'gpt-5.6-terra'
        $slugs[2]|Should Be 'gpt-5.6-luna'
    }
}

Describe 'v3.0.0 review coverage fail-closed 회귀' {
    BeforeEach {
        $script:v3CoverageSavedBoundary=$env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=Join-Path $TestWorkRoot 'v3-coverage-safe-boundary.txt'
        if(-not (Test-Path -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE)){
            'safe'|Set-Content -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE -Encoding UTF8
        }
        Set-TestGitWorkflow -Mode direct-main
        Invoke-ResetCommand|Out-Null
    }
    AfterEach {
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=$script:v3CoverageSavedBoundary
        Invoke-ResetCommand|Out-Null
    }

    It 'diff chunk 검토 worker가 하나라도 실패하면 PASS를 금지하고 incomplete coverage receipt를 남긴다' {
        $repo=New-FakeRepo -WithRemote
        try {
            [System.IO.File]::WriteAllText((Join-Path $repo 'large-fail.txt'),('B'*65000),(New-Object System.Text.UTF8Encoding($false)))
            Push-Location $repo;try{git add large-fail.txt;git commit -q -m large}finally{Pop-Location}
            Save-TestRunReceipt -Repo $repo -IssueNum 641
            $script:coverageFailureCalls=0
            $runner={
                param($r,$prompt,$route)
                $script:coverageFailureCalls++
                if($script:coverageFailureCalls -gt 1){return [pscustomobject]@{ExitCode=1;Success=$false;Output='review failed'}}
                return [pscustomobject]@{ExitCode=0;Success=$true;Output='{"verdict":"PASS","findings":[]}'}
            }
            $review=Invoke-OperationReview -OperationNumber 1 -IssueNumber 641 -RepoPath $repo -IssueFetcher $issue -GptReviewRunner $runner
            $review.status|Should Be 'review_worker_failed'
            $review.verdict|Should Be $null
            @($review.reviewedFiles).Count|Should Be 0
            $review.coverageReceiptPath|Should Not BeNullOrEmpty
            (Test-Path -LiteralPath $review.coverageReceiptPath -PathType Leaf)|Should Be $true
            $rawCoverage=Get-Content -LiteralPath $review.coverageReceiptPath -Raw -Encoding UTF8|ConvertFrom-Json
            $rawCoverage.verdict|Should Be 'INCOMPLETE'
            $currentCoveragePath=Get-ReviewReceiptPath -Operation 1 -IssueNumber 641 -RepoPath $repo
            $currentCoveragePath|Should Be $review.coverageReceiptPath
            (Test-Path -LiteralPath $currentCoveragePath -PathType Leaf)|Should Be $true
            $coverageReceipt=Get-ReviewReceipt -Operation 1 -IssueNumber 641 -RepoPath $repo
            $coverageReceipt|Should Not BeNullOrEmpty
            @($coverageReceipt).Count|Should Be 1
            (@($coverageReceipt.PSObject.Properties.Name) -contains 'verdict')|Should Be $true
            $coverageReceipt.verdict|Should Be 'INCOMPLETE'
            $coverageReceipt.reviewStatus|Should Be 'review_worker_failed'
            $coverageReceipt.coverageComplete|Should Be $false
            @($coverageReceipt.changedFiles).Count|Should Be 1
            @($coverageReceipt.reviewedFiles).Count|Should Be 0
            @($coverageReceipt.truncatedFiles).Count|Should Be 0
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }
}

Describe 'v3.0.0. direct-main과 기존 안전 회귀 보존' {
    BeforeEach {
        $script:v3SavedBoundary=$env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=Join-Path $TestWorkRoot 'v3-safe-boundary.txt'
        if(-not (Test-Path -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE)){'safe'|Set-Content -LiteralPath $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE -Encoding UTF8}
        Set-TestGitWorkflow -Mode direct-main
        Invoke-ResetCommand|Out-Null
    }
    AfterEach {
        Set-TestGitWorkflow -Mode direct-main
        $env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE=$script:v3SavedBoundary
        Invoke-ResetCommand|Out-Null
    }

    It '58. direct-main 기존 정상 경로는 main push 뒤 completed다' {
        $repo=New-FakeRepo -WithRemote
        try {
            $runner={param($r,$p,$o)Push-Location $p;try{'v3'|Set-Content v3.txt;git add .;git commit -q -m v3;git push -q origin main;[pscustomobject]@{ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok'}}finally{Pop-Location}}
            (Invoke-RunOperation -OperationNumber 2 -IssueNumber 58 -RepoPath $repo -IssueFetcher $issue -GrokRunner $runner -CiProbe $ciNone).status|Should Be 'completed'
        } finally {Remove-Item -LiteralPath $repo -Recurse -Force}
    }

    It '59. direct-main weekly fallback routing은 GPT Plan B를 유지한다' {
        $route=Resolve-OperationRoute -OperationNumber 2 -GrokState (GS exhausted 100) -GptState (GS available 0) -Config (Get-Config)
        $route.status|Should Be 'routed'
        $route.worker|Should Be 'gpt'
    }

    It '60. direct-main 독립 review 회귀 테스트 정의를 삭제하거나 skip하지 않는다' {
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-tree.Tests.ps1') -Raw -Encoding UTF8
        $source|Should Match 'review 실제 mock GPT 호출'
        $source|Should Match 'review 영수증 자동 복원'
    }

    It '61. direct-main repair 회귀 테스트 정의를 유지한다' {
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-tree.Tests.ps1') -Raw -Encoding UTF8
        $source|Should Match '수리 결과 정직 판정'
        $source|Should Match '모든 repair 경로의 verified run/review receipt'
    }

    It '62. direct-main recover 회귀 테스트 정의를 유지한다' {
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-tree.Tests.ps1') -Raw -Encoding UTF8
        $source|Should Match '실행 세대 영속화·중복 차단·recover'
        $source|Should Match 'result 유실 recover의 review 자격 차단'
    }

    It '63. watch-first terminal nextAction 회귀를 유지한다' {
        $receipt=[pscustomobject]@{operation=2;worker='grok';status='completed'}
        (Get-WatchNextAction -Receipt $receipt -Status completed)|Should Be 'sonnet_end_review'
        (Get-WatchNextAction -Receipt $receipt -Status pr_opened)|Should Be 'sonnet_end_review'
    }

    It '64. artifact sanitization 회귀 테스트 정의를 유지한다' {
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-tree.Tests.ps1') -Raw -Encoding UTF8
        $source|Should Match 'execution artifact sanitization과 retention'
        $source|Should Match 'terminal 후 raw·prompt가 사라지며'
    }

    It '65. artifact retention의 namespace 전체 receipt 보호 회귀를 유지한다' {
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-tree.Tests.ps1') -Raw -Encoding UTF8
        $source|Should Match 'retention의 namespace 전체 최신 execution receipt 참조 보호'
    }

    It '66. clone namespace identity는 canonical root hash로 계속 격리된다' {
        $a=New-FakeRepo -WithRemote;$b=New-FakeRepo -WithRemote
        try {(Get-PendingNamespacePath -RepoPath $a)|Should Not Be (Get-PendingNamespacePath -RepoPath $b)}
        finally {Remove-Item -LiteralPath $a,$b -Recurse -Force}
    }

    It '67. UTF-8 stdin과 비ASCII 인수 회귀 테스트 정의를 유지한다' {
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-tree.Tests.ps1') -Raw -Encoding UTF8
        $source|Should Match 'Windows PowerShell 전경 실행이 한글 stdin'
        $source|Should Match '비ASCII 인수 전경 실행'
    }

    It '68. 기존 mock 전체는 skip이나 실패 무시 구문 없이 정식 runner에 남아 있다' {
        $runner=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'run-tests.ps1') -Raw -Encoding UTF8
        $runner|Should Match 'Strict=\$true'
        $runner|Should Match 'FailedCount -gt 0'
        $runner|Should Not Match 'SkippedCount\s*='
    }

    It '68b. installed fixture는 실제 사용자 홈 모델 cache를 읽지 않고 합성한다' {
        $fixture=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'run-installed-fixture.ps1') -Raw -Encoding UTF8
        $fixture|Should Match '\$fixtureModels\s*='
        $fixture|Should Match "'gpt-5\.6-sol'"
        $fixture|Should Not Match '\$sourceModels'
        $fixture|Should Not Match 'Copy-Item[^\r\n]+models_cache'
        $fixture|Should Not Match 'Join-Path\s+\$originalProfile\s+''\.codex'
    }
}

Write-Host "`nsourceTreeTests complete; isolated usage-state retained only for runner cleanup."
