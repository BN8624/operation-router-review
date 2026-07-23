# 작업자 실행 전 시작 상태를 기록한다 (startHead/branch/status/ahead-behind).
# 부분 변경 후 fallback 판정과 postflight 비교의 기준점이 된다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'git-workflow.ps1')

# v2.4.5 watched critical-file 사후 무결성 검사. 선택한 정적 파일의 실행 전후 변경만 탐지하며
# OS sandbox가 아니고 비감시 파일 접근·읽기·생성·전송을 차단하지 않는다.
function Get-BoundaryWatchSpecifications {
    if (-not [string]::IsNullOrWhiteSpace($env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE)) {
        return @($env:OPERATION_ROUTER_BOUNDARY_WATCH_OVERRIDE -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [pscustomobject]@{ kind='file'; path=[System.IO.Path]::GetFullPath($_) } })
    }
    $userHome = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $HOME }
    return @(
        [pscustomobject]@{ kind='file'; path=(Join-Path $userHome '.gitconfig') },
        [pscustomobject]@{ kind='file'; path=(Join-Path $userHome '.claude\CLAUDE.md') },
        [pscustomobject]@{ kind='file'; path=(Join-Path $userHome '.codex\AGENTS.md') },
        [pscustomobject]@{ kind='tree'; root=$Script:RuntimeRoot; patterns=@(
            '^operation-router\.cmd$','^config/.+\.json$','^scripts/.+\.ps1$','^skills/[^/]+/SKILL\.md$') },
        [pscustomobject]@{ kind='tree'; root=(Join-Path $userHome '.claude\skills'); patterns=@('^operation[^/]*/SKILL\.md$') }
    )
}

function Get-BoundaryWatchPaths {
    return @(Get-BoundaryWatchSpecifications | ForEach-Object { if ($_.kind -eq 'file') { $_.path } else { $_.root } })
}

function Get-CriticalTreeFiles {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Patterns)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { return @() }
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -File -Recurse)) {
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\','/') -replace '\\','/'
        $matched = $false
        foreach ($pattern in $Patterns) { if ($relative -match $pattern) { $matched=$true; break } }
        if (-not $matched) { continue }
        $hash = 'READ_ERROR'
        try { $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash } catch { }
        $records += [pscustomobject]@{ relativePath=$relative; exists=$true; hash=$hash }
    }
    return @($records | Sort-Object relativePath)
}

# 고정 파일과 critical tree의 상대 경로·존재 여부·SHA-256을 결정론적으로 기록한다.
function Get-BoundarySnapshot {
    param([string[]]$Paths, [object[]]$Specifications)
    $records = @()
    $specs = if ($PSBoundParameters.ContainsKey('Specifications')) {
        @($Specifications)
    } elseif ($PSBoundParameters.ContainsKey('Paths')) {
        @($Paths | ForEach-Object { [pscustomobject]@{ kind='file'; path=[System.IO.Path]::GetFullPath($_) } })
    } else { @(Get-BoundaryWatchSpecifications) }
    foreach ($spec in $specs) {
        if ($spec.kind -eq 'tree') {
            $root = [System.IO.Path]::GetFullPath([string]$spec.root).TrimEnd('\','/')
            $patterns = @($spec.patterns | ForEach-Object { [string]$_ })
            $records += [pscustomobject]@{ kind='tree'; root=$root; patterns=$patterns; files=@(Get-CriticalTreeFiles -Root $root -Patterns $patterns) }
        } else {
            $p = [System.IO.Path]::GetFullPath([string]$spec.path)
            $h = 'ABSENT'; $exists = Test-Path -LiteralPath $p -PathType Leaf
            if ($exists) {
                try { $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } catch { $h = 'READ_ERROR' }
            }
            $records += [pscustomobject]@{ kind='file'; path=$p; exists=[bool]$exists; hash=$h }
        }
    }
    return @($records)
}

# watched file의 추가·수정·삭제를 비교한다. 결과는 절대 경로 오름차순으로 고정한다.
function Test-RepoBoundaryViolation {
    param([Parameter(Mandatory)][AllowNull()]$BeforeSnapshot)
    if ($null -eq $BeforeSnapshot) { return @() }
    $violations = @()
    foreach ($rec in @($BeforeSnapshot)) {
        if ($null -eq $rec) { continue }
        if (($rec.PSObject.Properties.Name -contains 'kind') -and [string]$rec.kind -eq 'tree') {
            $root = [System.IO.Path]::GetFullPath([string]$rec.root).TrimEnd('\','/')
            $patterns = @($rec.patterns | ForEach-Object { [string]$_ })
            $current = @(Get-CriticalTreeFiles -Root $root -Patterns $patterns)
            $beforeMap=@{};$currentMap=@{}
            foreach($item in @($rec.files)){$beforeMap[[string]$item.relativePath]=[string]$item.hash}
            foreach($item in $current){$currentMap[[string]$item.relativePath]=[string]$item.hash}
            $all=@((@($beforeMap.Keys)+@($currentMap.Keys))|Sort-Object -Unique)
            foreach($relative in $all){
                if(-not $beforeMap.ContainsKey($relative) -or -not $currentMap.ContainsKey($relative) -or $beforeMap[$relative] -ne $currentMap[$relative]){
                    $violations += (Join-Path $root $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                }
            }
            continue
        }
        $p = [string]$rec.path
        $before = [string]$rec.hash
        $now = 'ABSENT'
        if (Test-Path -LiteralPath $p) {
            try { $now = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } catch { $now = 'READ_ERROR' }
        }
        if ($now -ne $before) { $violations += $p }
    }
    return @($violations | Sort-Object -Unique)
}

# v2.4.1 공통 종료 finalizer: 워커/구현자를 호출한 뒤 반환되는 모든 결과가 이 함수를 통과한다.
# 시작 시 캡처한 boundaryWatch 스냅샷과 현재 감시 파일을 비교해, 위반이 있으면 원래 status를
# underlyingStatus로 보존하고 최종 status를 repo_boundary_violation으로 승격한다. CI는 조회하지 않는다.
# 위반이 없으면 결과 스키마를 바꾸지 않고 그대로 반환한다(불필요한 필드 추가 없음).
function Complete-BoundaryFinalizer {
    param([Parameter(Mandatory)][AllowNull()]$Result, [AllowNull()]$BoundarySnapshot)
    if ($null -eq $Result) { return $Result }
    if ($null -eq $BoundarySnapshot) { return $Result }
    $violations = @(Test-RepoBoundaryViolation -BeforeSnapshot $BoundarySnapshot)
    if ($violations.Count -eq 0) { return $Result }
    $props = $Result.PSObject.Properties.Name
    $current = if ($props -contains 'status') { [string]$Result.status } else { $null }
    if ($current -eq 'repo_boundary_violation') { return $Result }  # idempotent
    Add-Member -InputObject $Result -NotePropertyName underlyingStatus -NotePropertyValue $current -Force
    if ($props -contains 'status') { $Result.status = 'repo_boundary_violation' }
    else { Add-Member -InputObject $Result -NotePropertyName status -NotePropertyValue 'repo_boundary_violation' -Force }
    Add-Member -InputObject $Result -NotePropertyName boundaryViolations -NotePropertyValue @($violations) -Force
    if ($props -contains 'ciStatus') { $Result.ciStatus = 'not-checked' }
    else { Add-Member -InputObject $Result -NotePropertyName ciStatus -NotePropertyValue 'not-checked' -Force }
    $rp = @('watched critical-file post-execution integrity violation detected')
    if ($props -contains 'remainingProblems' -and $null -ne $Result.remainingProblems) { $rp += @($Result.remainingProblems) }
    if ($props -contains 'remainingProblems') { $Result.remainingProblems = @($rp) }
    else { Add-Member -InputObject $Result -NotePropertyName remainingProblems -NotePropertyValue @($rp) -Force }
    return $Result
}

function Get-StartSnapshot {
    param([Parameter(Mandatory)][string]$RepoPath)
    $branch = Get-GitCurrentBranch -Path $RepoPath
    $head = Get-GitHead -Path $RepoPath
    $wt = Get-GitWorktreeStatus -Path $RepoPath
    $ab = Get-GitAheadBehind -Path $RepoPath
    return [pscustomobject]@{
        startHead     = $head
        branch        = $branch
        worktreeClean = [bool]$wt.Clean
        worktreeRaw   = $wt.Raw
        aheadBehindAvailable = [bool]$ab.Available
        ahead         = $ab.Ahead
        behind        = $ab.Behind
        boundaryWatch = Get-BoundarySnapshot
    }
}

# 시작 검토 전제조건. main + clean + origin/main 동기화(ahead=0 behind=0)를 요구한다.
# fetch/pull/reset을 자동 수행하지 않는다. 미동기화는 각각 명확한 상태로 중단한다.
function Test-StartPreconditions {
    param([Parameter(Mandatory)][string]$RepoPath)
    if (-not (Test-GitRepository -Path $RepoPath)) {
        return [pscustomobject]@{ ok = $false; reason = 'not_a_git_repository' }
    }
    $snap = Get-StartSnapshot -RepoPath $RepoPath
    if ($snap.branch -ne 'main') {
        return [pscustomobject]@{ ok = $false; reason = 'not_on_main_branch'; snapshot = $snap }
    }
    if (-not $snap.worktreeClean) {
        return [pscustomobject]@{ ok = $false; reason = 'dirty_worktree'; snapshot = $snap }
    }
    # 원격 동기화 게이트 (자동 fetch 없음: 마지막으로 알려진 origin/main 기준)
    if (-not $snap.aheadBehindAvailable) {
        return [pscustomobject]@{ ok = $false; reason = 'remote_sync_unavailable'; snapshot = $snap }
    }
    if ([int]$snap.behind -gt 0) {
        return [pscustomobject]@{ ok = $false; reason = 'behind_remote'; snapshot = $snap }
    }
    if ([int]$snap.ahead -gt 0) {
        return [pscustomobject]@{ ok = $false; reason = 'local_ahead_of_remote'; snapshot = $snap }
    }
    return [pscustomobject]@{ ok = $true; snapshot = $snap; ownerRepo = (Get-GitOriginOwnerRepo -Path $RepoPath) }
}

# 부분 변경 감지: 시작 이후 파일/커밋/HEAD 변화가 있으면 fallback 금지.
# 반환: @{ changed = bool; details }
function Test-WorkerChangedRepo {
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)]$StartSnapshot)
    $currentHead = Get-GitHead -Path $RepoPath
    $wt = Get-GitWorktreeStatus -Path $RepoPath
    $commits = 0
    if ($StartSnapshot.startHead) { $commits = Get-GitCommitCountSince -Path $RepoPath -SinceHead $StartSnapshot.startHead }
    $headChanged = ($currentHead -ne $StartSnapshot.startHead)
    $nowDirty = (-not $wt.Clean)
    $changed = ($headChanged -or $nowDirty -or ($commits -gt 0))
    return [pscustomobject]@{
        changed = [bool]$changed
        headChanged = [bool]$headChanged
        worktreeDirty = [bool]$nowDirty
        newCommits = [int]$commits
        currentHead = $currentHead
    }
}
