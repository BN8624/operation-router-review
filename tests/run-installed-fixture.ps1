# 전역 설치본을 건드리지 않고 격리된 사용자 홈에 Skill 설치 사본을 만들어 통합 검증한다.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$routerRoot = Split-Path -Parent $PSScriptRoot
$fixtureHome = Join-Path ([System.IO.Path]::GetTempPath()) ('operation-router-installed-v247-' + [guid]::NewGuid().ToString('N'))
$installedRoot = Join-Path $fixtureHome '.claude\skills'
$originalProfile = $env:USERPROFILE
$originalModuleCache = [Environment]::GetEnvironmentVariable('PSModuleAnalysisCachePath','Process')

try {
    New-Item -ItemType Directory -Path $installedRoot -Force | Out-Null
    foreach($name in @('operation','operation-1','operation-1-claude','operation-2','operation-3','operation-3-claude')) {
        $target = Join-Path $installedRoot $name
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $routerRoot "skills\$name\SKILL.md") -Destination (Join-Path $target 'SKILL.md') -Force
    }
    $sourceModels = Join-Path $originalProfile '.codex\models_cache.json'
    if (Test-Path -LiteralPath $sourceModels) {
        $fixtureCodex = Join-Path $fixtureHome '.codex'
        New-Item -ItemType Directory -Path $fixtureCodex -Force | Out-Null
        Copy-Item -LiteralPath $sourceModels -Destination (Join-Path $fixtureCodex 'models_cache.json') -Force
    }
    $env:USERPROFILE = $fixtureHome
    $env:PSModuleAnalysisCachePath = Join-Path $fixtureHome '.cache\ModuleAnalysisCache'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-tests.ps1') `
        -RootPath $routerRoot -SkillsPath (Join-Path $routerRoot 'skills') -InstalledIntegration
    if ($LASTEXITCODE -ne 0) { throw "isolated installed integration failed with exit code $LASTEXITCODE" }
} finally {
    $env:USERPROFILE = $originalProfile
    [Environment]::SetEnvironmentVariable('PSModuleAnalysisCachePath',$originalModuleCache,'Process')
    $full = [System.IO.Path]::GetFullPath($fixtureHome)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $full) -notmatch '^operation-router-installed-v247-[a-f0-9]{32}$') { throw "refusing unsafe installed fixture cleanup: $full" }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
