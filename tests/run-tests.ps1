# operation-router source-tree 테스트를 사용자 상태·로그와 분리해 실행하고 실패 종료코드를 보장한다.

[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$SkillsPath,
    [string]$StatePath,
    [string]$LogRoot,
    [switch]$InstalledIntegration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = if ([string]::IsNullOrWhiteSpace($RootPath)) {
    Split-Path -Parent $PSScriptRoot
} else { $RootPath }
$root = [System.IO.Path]::GetFullPath($root).TrimEnd('\','/')
if (-not (Test-Path -LiteralPath (Join-Path $root 'scripts\common.ps1'))) { throw "Invalid review root: $root" }

$testWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('operation-router-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testWorkRoot -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($SkillsPath)) {
    $SkillsPath = Join-Path $root 'skills'
}
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $testWorkRoot 'state\usage-state.json' }
if ([string]::IsNullOrWhiteSpace($LogRoot)) { $LogRoot = Join-Path $testWorkRoot 'logs' }

$result = $null
$fatal = $null
try {
    Import-Module Pester -MinimumVersion 3.4 -ErrorAction Stop
    $spec = @{
        Path = Join-Path $PSScriptRoot 'source-tree.Tests.ps1'
        Parameters = @{
            RootPath = $root
            SkillsPath = [System.IO.Path]::GetFullPath($SkillsPath)
            StatePath = [System.IO.Path]::GetFullPath($StatePath)
            LogRoot = [System.IO.Path]::GetFullPath($LogRoot)
            TestWorkRoot = $testWorkRoot
            InstalledIntegration = $false
        }
    }
    $result = Invoke-Pester -Script $spec -PassThru -Strict
} catch {
    $fatal = $_
} finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    $fullWorkRoot = [System.IO.Path]::GetFullPath($testWorkRoot)
    if (-not $fullWorkRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $fullWorkRoot) -notmatch '^operation-router-tests-[a-f0-9]{32}$') {
        throw "Refusing unsafe test cleanup: $fullWorkRoot"
    }
    if (Test-Path -LiteralPath $fullWorkRoot) { Remove-Item -LiteralPath $fullWorkRoot -Recurse -Force }
}

$integrationFailed = 0
if ($null -eq $fatal -and $InstalledIntegration) {
    $installedRoot = Join-Path $env:USERPROFILE '.claude\skills'
    foreach($name in @('operation','operation-1','operation-1-claude','operation-2','operation-3','operation-3-claude')) {
        $source = Join-Path ([System.IO.Path]::GetFullPath($SkillsPath)) "$name\SKILL.md"
        $installed = Join-Path $installedRoot "$name\SKILL.md"
        if (-not (Test-Path -LiteralPath $installed) -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash) {
            $integrationFailed++
        }
    }
}

if ($null -ne $fatal) {
    Write-Error $fatal
    exit 1
}

$summary = [ordered]@{
    sourceTreeTests = 'executed'
    installedIntegrationTests = if ($InstalledIntegration) { 'executed' } else { 'not-requested' }
    installedIntegrationFailures = $integrationFailed
    total = [int]$result.TotalCount
    passed = [int]$result.PassedCount
    failed = [int]$result.FailedCount
    skipped = [int]$result.SkippedCount
    rootPath = $root
    skillsPath = [System.IO.Path]::GetFullPath($SkillsPath)
    statePath = 'isolated-temp-state'
    logRoot = 'isolated-temp-logs'
}
$summary | ConvertTo-Json
if ($result.FailedCount -gt 0 -or $integrationFailed -gt 0) { exit 1 }
exit 0
