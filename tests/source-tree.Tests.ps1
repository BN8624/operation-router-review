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
$Script:ConfigPath = Join-Path $Script:ConfigDir 'config.json'
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
    It '30. 작업자 실패 시에도 임시 주문서 finally 삭제' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $script:capPath = $null
            $gr = { param($r,$repo,$prompt) $script:capPath = $prompt; [pscustomobject]@{ ExitCode=1;Success=$false;QuotaExhausted=$false;Output='fail' } }
            Invoke-RunOperation -OperationNumber 2 -IssueNumber 18 -RepoPath $repo -IssueFetcher $issue -GrokRunner $gr -CiProbe $ciNone | Out-Null
            (Test-Path $script:capPath) | Should Be $false
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
$implPush = { param($repo,$order,$target) Push-Location $repo; "y" | Out-File b.txt -Encoding utf8; git add .; git commit -q -m b; git push -q origin main; Pop-Location; [pscustomobject]@{ Success=$true; ExitCode=0 } }

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
            $res = Invoke-RunOperation -OperationNumber 2 -IssueNumber 31 -RepoPath $repo -IssueFetcher $issue -ClaudeOnly -ClaudeImplementer $implPush -CiProbe $ciNone
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
            $pf = Invoke-PostflightCommand -Operation 2 -IssueNumber 32 -RepoPath $repo -CiProbe $ciNone
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
            $res = Invoke-RunOperation -OperationNumber 3 -Kind mechanical -IssueNumber 33 -RepoPath $repo -IssueFetcher $issue -ClaudeImplementer $implPush -CiProbe $ciNone
            $res.status | Should Be 'completed'
            $res.route | Should Be 'claude-direct-executed'
            $res.model | Should Be 'claude-haiku-4-5-20251001'
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
}

# v2.2/v2.3: 테스트용 run 영수증 생성 (repo에 커밋 2개 필요: startHead=HEAD~1, finalHead=HEAD)
function Save-TestRunReceipt {
    param([Parameter(Mandatory)]$Repo, [Parameter(Mandatory)][int]$IssueNum,
          [string]$Worker = 'grok', [string]$FinalHeadOverride, [string]$Status = 'completed')
    Push-Location $Repo
    $final = (git rev-parse HEAD).Trim()
    $start = (git rev-parse "HEAD~1").Trim()
    Pop-Location
    if ($FinalHeadOverride) { $final = $FinalHeadOverride }
    $snap = [pscustomobject]@{ startHead = $start }
    $pf = [pscustomobject]@{ status=$Status; branch='main'; startHead=$start; finalHead=$final; headChanged=$true
        commitCount=1; worktreeClean=$true; aheadBehindAvailable=$true; ahead=0; behind=0; pushComplete=$true
        ciStatus='not-requested'; workerExitCode=0 }
    $route = [pscustomobject]@{ worker=$Worker; model='grok-4.5'; effort='high' }
    $wr = [pscustomobject]@{ Output = 'worker self-reported: tests passed (not re-run by router)' }
    Save-RunReceipt -Operation 1 -IssueNumber $IssueNum -RepoPath $Repo -Snapshot $snap -Postflight $pf -Route $route -WorkerResult $wr -RemainingProblems @() | Out-Null
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
            $script:rc = 0
            $rep = { param($r,$repo,$prompt) $script:rc++; Push-Location $repo; "fix" | Out-File fix.txt -Encoding utf8; git add .; git commit -q -m fix; git push -q origin main; Pop-Location; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead $prh -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
            $script:rc | Should Be 1
            $hr.status | Should Be 'repair_completed_review_pending'
            $hr.repairAttempted | Should Be $true
            $hr.finalReviewRequired | Should Be $true
        } finally { Remove-Item -Recurse -Force $repo }
    }
    It '수리 전 HEAD 불일치 → repair_state_mismatch (수리 실행 안 함)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            $script:rc2 = 0
            $rep = { param($r,$repo,$prompt) $script:rc2++; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 5 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead '0000000000000000000000000000000000000000' -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
            $hr.status | Should Be 'repair_state_mismatch'
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
            $script:rc3 = 0
            $rep = { param($r,$repo,$prompt) $script:rc3++; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 80 -RepoPath $repo -Findings $findings -OriginalWorker 'grok' -PostReviewHead (Head-Of $repo) -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
            $hr.status | Should Be 'repair_worker_unavailable'
            $hr.repairAttempted | Should Be $false
            $script:rc3 | Should Be 0
        } finally { Remove-Item -Recurse -Force $repo; Invoke-ResetCommand | Out-Null }
    }
    It 'GPT 80%+/reserved/exhausted → gpt 수리 금지 (검수 예비분 사용 안 함)' {
        Invoke-ResetCommand | Out-Null
        $repo = New-FakeRepo -WithRemote
        try {
            $findings = @([pscustomobject]@{ severity='high'; file='a.txt'; issue='x'; requiredFix='y' })
            $script:rc4 = 0
            $rep = { param($r,$repo,$prompt) $script:rc4++; [pscustomobject]@{ ExitCode=0;Success=$true;QuotaExhausted=$false;Output='ok' } }
            foreach ($v in @('80','reserved','exhausted')) {
                Invoke-SetCommand -Target gpt -Value $v | Out-Null
                $hr = Invoke-OperationRepair -OperationNumber 1 -IssueNumber 81 -RepoPath $repo -Findings $findings -OriginalWorker 'gpt' -PostReviewHead (Head-Of $repo) -IssueFetcher $issue -RepairRunner $rep -CiProbe $ciNone
                $hr.status | Should Be 'repair_worker_unavailable'
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

    It '12. README는 v2.4.3을 현재 버전으로 기록한다' {
        $readme = Get-Content -LiteralPath (Join-Path $RouterRoot 'README.md') -Raw -Encoding UTF8
        $readme | Should Match '^# operation-router \(v2\.4\.3\)'
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

Write-Host "`nsourceTreeTests complete; isolated usage-state retained only for runner cleanup."
