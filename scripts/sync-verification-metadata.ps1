# 검증 summary에서 사람이 보는 문서 블록을 생성하고 버전·수치·manifest·줄 수 drift를 검사한다.

[CmdletBinding(DefaultParameterSetName='Check')]
param(
    [Parameter(ParameterSetName='Write',Mandatory)][switch]$Write,
    [Parameter(ParameterSetName='Check')][switch]$Check,
    [string]$RootPath,
    [string]$GitRootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VerificationInteger {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name)
    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        throw "verification summary is missing '$Name'."
    }
    $value = $Object.$Name
    if ($value -isnot [int] -and $value -isnot [long]) {
        throw "verification summary '$Name' must be an integer."
    }
    if ([long]$value -lt 0) {
        throw "verification summary '$Name' must not be negative."
    }
    return [long]$value
}

function Get-VerificationSummaryData {
    param([Parameter(Mandatory)][string]$ResolvedRoot)
    $path = Join-Path $ResolvedRoot 'evidence\verification-summary.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "verification summary is missing: $path"
    }
    try {
        $summary = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "verification summary JSON is invalid: $($_.Exception.Message)"
    }
    if ($summary.PSObject.Properties.Name -notcontains 'schemaVersion' -or
        $summary.schemaVersion -isnot [int] -or [int]$summary.schemaVersion -ne 1) {
        throw 'verification summary schemaVersion must be integer 1.'
    }
    if ($summary.PSObject.Properties.Name -notcontains 'version' -or
        $summary.version -isnot [string] -or $summary.version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'verification summary version must be a semantic version string.'
    }
    foreach ($name in @(
        'sourceTreePassed','sourceTreeFailed','installedFixturePassed','installedFixtureFailed',
        'installedIntegrationFailures','powerShellParserFiles','manifestEntries','paidModelCalls'
    )) {
        [void](Get-VerificationInteger -Object $summary -Name $name)
    }
    foreach ($name in @('modelContract','gitDiffCheck')) {
        if ($summary.PSObject.Properties.Name -notcontains $name -or
            $summary.$name -isnot [string] -or [string]$summary.$name -cne 'passed') {
            throw "verification summary '$name' must be string 'passed'."
        }
    }
    if ($summary.PSObject.Properties.Name -notcontains 'verifiedHead' -or
        $summary.verifiedHead -isnot [string] -or [string]$summary.verifiedHead -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'verification summary verifiedHead must be a 40-character Git SHA.'
    }
    if ($summary.PSObject.Properties.Name -notcontains 'verifiedAtUtc' -or
        $summary.verifiedAtUtc -isnot [string]) {
        throw 'verification summary verifiedAtUtc must be a string.'
    }
    $timestamp = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
        [string]$summary.verifiedAtUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$timestamp
    ) -or $timestamp.Offset -ne [timespan]::Zero) {
        throw 'verification summary verifiedAtUtc must be an ISO-8601 UTC timestamp.'
    }
    if ($summary.PSObject.Properties.Name -notcontains 'refactorMetrics' -or
        $null -eq $summary.refactorMetrics) {
        throw 'verification summary refactorMetrics is required.'
    }
    $metrics = $summary.refactorMetrics
    if ($metrics.PSObject.Properties.Name -notcontains 'baselineHead' -or
        $metrics.baselineHead -isnot [string] -or
        [string]$metrics.baselineHead -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'refactorMetrics.baselineHead must be a 40-character Git SHA.'
    }
    foreach ($name in @(
        'commonBefore','commonAfter','runOperationBefore','runOperationAfter',
        'stateStoreLines','workerContractLines'
    )) {
        [void](Get-VerificationInteger -Object $metrics -Name $name)
    }
    return $summary
}

function Get-VerificationNewline {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Get-VerificationVisibleBlock {
    param(
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)][ValidateSet('README','REENTRY','VERIFICATION_MATRIX')][string]$Document,
        [Parameter(Mandatory)][string]$Newline
    )
    $sourcePassed = Get-VerificationInteger -Object $Summary -Name 'sourceTreePassed'
    $sourceFailed = Get-VerificationInteger -Object $Summary -Name 'sourceTreeFailed'
    $installedPassed = Get-VerificationInteger -Object $Summary -Name 'installedFixturePassed'
    $installedFailed = Get-VerificationInteger -Object $Summary -Name 'installedFixtureFailed'
    $parserFiles = Get-VerificationInteger -Object $Summary -Name 'powerShellParserFiles'
    $manifestEntries = Get-VerificationInteger -Object $Summary -Name 'manifestEntries'
    $integrationFailures = Get-VerificationInteger -Object $Summary -Name 'installedIntegrationFailures'
    $paidCalls = Get-VerificationInteger -Object $Summary -Name 'paidModelCalls'
    $lines = if ($Document -eq 'VERIFICATION_MATRIX') {
        @(
            '<!-- verification-visible:start -->'
            "- source-tree $sourcePassed passed, $sourceFailed failed"
            "- installed fixture $installedPassed passed, $installedFailed failed"
            "- installed integration failures $integrationFailures"
            "- PowerShell parser files $parserFiles, manifest entries $manifestEntries"
            "- paid model calls $paidCalls"
            '<!-- verification-visible:end -->'
        )
    } else {
        @(
            '<!-- verification-visible:start -->'
            "Official verification: source-tree $sourcePassed passed, $sourceFailed failed; installed fixture $installedPassed passed, $installedFailed failed."
            "Verified PowerShell files $parserFiles, manifest entries $manifestEntries, installed integration failures $integrationFailures, paid model calls $paidCalls."
            '<!-- verification-visible:end -->'
        )
    }
    return ($lines -join $Newline)
}

function Get-VerificationHiddenMarker {
    param([Parameter(Mandatory)]$Summary)
    return ('<!-- verification-summary sourceTreePassed={0} sourceTreeFailed={1} installedFixturePassed={2} installedFixtureFailed={3} -->' -f
        (Get-VerificationInteger -Object $Summary -Name 'sourceTreePassed'),
        (Get-VerificationInteger -Object $Summary -Name 'sourceTreeFailed'),
        (Get-VerificationInteger -Object $Summary -Name 'installedFixturePassed'),
        (Get-VerificationInteger -Object $Summary -Name 'installedFixtureFailed'))
}

function Assert-VerificationMarkerStructure {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Label)
    $startCount = @([regex]::Matches($Text,'<!-- verification-visible:start -->')).Count
    $endCount = @([regex]::Matches($Text,'<!-- verification-visible:end -->')).Count
    if ($startCount -ne 1 -or $endCount -ne 1) {
        throw "$Label must contain exactly one verification-visible marker pair."
    }
    $pattern = '(?s)<!-- verification-visible:start -->.*?<!-- verification-visible:end -->'
    if (@([regex]::Matches($Text,$pattern)).Count -ne 1) {
        throw "$Label verification-visible marker order is invalid."
    }
    if (@([regex]::Matches($Text,'<!-- verification-summary .*? -->')).Count -ne 1) {
        throw "$Label must contain exactly one verification-summary marker."
    }
}

function Set-VerificationVisibleBlock {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExpectedBlock,
        [Parameter(Mandatory)][string]$ExpectedHiddenMarker,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-VerificationMarkerStructure -Text $Text -Label $Label
    $updated = [regex]::Replace(
        $Text,
        '(?s)<!-- verification-visible:start -->.*?<!-- verification-visible:end -->',
        [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $ExpectedBlock }
    )
    $updated = [regex]::Replace(
        $updated,
        '<!-- verification-summary .*? -->',
        [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $ExpectedHiddenMarker }
    )
    return $updated
}

function Assert-VerificationVersionHeadings {
    param([Parameter(Mandatory)][string]$ResolvedRoot,[Parameter(Mandatory)][string]$Version)
    $checks = @(
        @{ path='README.md'; pattern='(?m)^# operation-router \(v([0-9]+\.[0-9]+\.[0-9]+)\)\s*$'; label='README' },
        @{ path='REENTRY.md'; pattern='(?m)^# REENTRY .*operation-router v([0-9]+\.[0-9]+\.[0-9]+).*$'; label='REENTRY' },
        @{ path='VERIFICATION_MATRIX.md'; pattern='(?m)^# VERIFICATION_MATRIX .*operation-router v([0-9]+\.[0-9]+\.[0-9]+)\s*$'; label='VERIFICATION_MATRIX' },
        @{ path='CHANGELOG.md'; pattern='(?m)^## v([0-9]+\.[0-9]+\.[0-9]+) \('; label='CHANGELOG' }
    )
    foreach ($versionCheck in $checks) {
        $text = Get-Content -LiteralPath (Join-Path $ResolvedRoot $versionCheck.path) -Raw -Encoding UTF8
        $headingMatch = [regex]::Match($text,$versionCheck.pattern)
        if (-not $headingMatch.Success) { throw "$($versionCheck.label) version heading was not found." }
        if ([string]$headingMatch.Groups[1].Value -cne $Version) {
            throw "$($versionCheck.label) version differs from verification summary."
        }
    }
}

function Get-GitBaselineLineCount {
    param(
        [Parameter(Mandatory)][string]$ResolvedGitRoot,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$RelativePath
    )
    & git -C $ResolvedGitRoot cat-file -e "$Head`:$RelativePath" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "baseline Git blob is unavailable: $Head`:$RelativePath" }
    $lines = @(& git -C $ResolvedGitRoot show "$Head`:$RelativePath")
    if ($LASTEXITCODE -ne 0) { throw "baseline Git line count failed: $Head`:$RelativePath" }
    return [long]$lines.Count
}

function Assert-VerificationRefactorMetrics {
    param(
        [Parameter(Mandatory)][string]$ResolvedRoot,
        [Parameter(Mandatory)][string]$ResolvedGitRoot,
        [Parameter(Mandatory)]$Summary
    )
    $m = $Summary.refactorMetrics
    $actual = [ordered]@{
        commonBefore = Get-GitBaselineLineCount -ResolvedGitRoot $ResolvedGitRoot -Head $m.baselineHead -RelativePath 'scripts/common.ps1'
        commonAfter = [long]@(Get-Content -LiteralPath (Join-Path $ResolvedRoot 'scripts\common.ps1') -Encoding UTF8).Count
        runOperationBefore = Get-GitBaselineLineCount -ResolvedGitRoot $ResolvedGitRoot -Head $m.baselineHead -RelativePath 'scripts/run-operation.ps1'
        runOperationAfter = [long]@(Get-Content -LiteralPath (Join-Path $ResolvedRoot 'scripts\run-operation.ps1') -Encoding UTF8).Count
        stateStoreLines = [long]@(Get-Content -LiteralPath (Join-Path $ResolvedRoot 'scripts\state-store.ps1') -Encoding UTF8).Count
        workerContractLines = [long]@(Get-Content -LiteralPath (Join-Path $ResolvedRoot 'scripts\worker-contract.ps1') -Encoding UTF8).Count
    }
    foreach ($name in $actual.Keys) {
        if ([long]$m.$name -ne [long]$actual[$name]) {
            throw "refactorMetrics.$name differs from the Git/filesystem line count."
        }
    }
    $changelog = Get-Content -LiteralPath (Join-Path $ResolvedRoot 'CHANGELOG.md') -Raw -Encoding UTF8
    $metricLine = ('- refactor metrics: baseline `{0}`, `common.ps1` {1}->{2}, `run-operation.ps1` {3}->{4}, `state-store.ps1` {5}, `worker-contract.ps1` {6} lines.' -f
        $m.baselineHead,$m.commonBefore,$m.commonAfter,$m.runOperationBefore,$m.runOperationAfter,
        $m.stateStoreLines,$m.workerContractLines)
    if (-not $changelog.Contains($metricLine)) {
        throw 'CHANGELOG refactor metrics differ from verification summary.'
    }
}

function Assert-VerificationEvidenceText {
    param([Parameter(Mandatory)][string]$ResolvedRoot,[Parameter(Mandatory)]$Summary)
    $text = Get-Content -LiteralPath (Join-Path $ResolvedRoot 'evidence\source-tree-test-result.txt') -Raw -Encoding UTF8
    $required = @(
        "sourceTreeResult=$($Summary.sourceTreePassed) passed, $($Summary.sourceTreeFailed) failed",
        "installedFixtureResult=$($Summary.installedFixturePassed) passed, $($Summary.installedFixtureFailed) failed",
        "installedIntegrationFailures=$($Summary.installedIntegrationFailures)",
        "powerShellParserResult=$($Summary.powerShellParserFiles) passed, 0 errors",
        "manifestScope=$($Summary.manifestEntries) deployment files; manifest-sha256.txt excludes itself",
        "paidModelCalls=$($Summary.paidModelCalls)"
    )
    foreach ($value in $required) {
        if (-not $text.Contains($value)) {
            throw "evidence text differs from verification summary: $value"
        }
    }
}

function Test-VerificationMetadata {
    param(
        [Parameter(Mandatory)][string]$ResolvedRoot,
        [Parameter(Mandatory)][string]$ResolvedGitRoot,
        [Parameter(Mandatory)]$Summary
    )
    Assert-VerificationVersionHeadings -ResolvedRoot $ResolvedRoot -Version ([string]$Summary.version)
    $hidden = Get-VerificationHiddenMarker -Summary $Summary
    foreach ($doc in @(
        @{ path='README.md'; label='README' },
        @{ path='REENTRY.md'; label='REENTRY' },
        @{ path='VERIFICATION_MATRIX.md'; label='VERIFICATION_MATRIX' }
    )) {
        $text = Get-Content -LiteralPath (Join-Path $ResolvedRoot $doc.path) -Raw -Encoding UTF8
        Assert-VerificationMarkerStructure -Text $text -Label $doc.label
        $newline = Get-VerificationNewline -Text $text
        $expected = Get-VerificationVisibleBlock -Summary $Summary -Document $doc.label -Newline $newline
        if (-not $text.Contains($expected)) {
            throw "$($doc.label) visible verification block differs from verification summary."
        }
        if (-not $text.Contains($hidden)) {
            throw "$($doc.label) hidden verification marker differs from verification summary."
        }
    }
    Assert-VerificationEvidenceText -ResolvedRoot $ResolvedRoot -Summary $Summary
    $parserFiles = @(Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }).Count
    if ([long]$parserFiles -ne [long]$Summary.powerShellParserFiles) {
        throw 'PowerShell parser file count differs from verification summary.'
    }
    $manifestLines = @(Get-Content -LiteralPath (Join-Path $ResolvedRoot 'manifest-sha256.txt') -Encoding UTF8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ([long]$manifestLines.Count -ne [long]$Summary.manifestEntries) {
        throw 'manifest entry count differs from verification summary.'
    }
    Assert-VerificationRefactorMetrics -ResolvedRoot $ResolvedRoot -ResolvedGitRoot $ResolvedGitRoot -Summary $Summary
    return [pscustomobject][ordered]@{
        status = 'passed'
        version = [string]$Summary.version
        sourceTreePassed = [long]$Summary.sourceTreePassed
        installedFixturePassed = [long]$Summary.installedFixturePassed
        powerShellParserFiles = [long]$Summary.powerShellParserFiles
        manifestEntries = [long]$Summary.manifestEntries
        verifiedHead = [string]$Summary.verifiedHead
    }
}

function Write-VerificationTextAtomic {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    $directory = Split-Path -Parent $Path
    $temp = Join-Path $directory ('.verification-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $directory ('.verification-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        [System.IO.File]::WriteAllText($temp,$Text,(New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Replace($temp,$Path,$backup)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Invoke-VerificationMetadataSync {
    param(
        [Parameter(Mandatory)][ValidateSet('Write','Check')][string]$Mode,
        [Parameter(Mandatory)][string]$ResolvedRoot,
        [Parameter(Mandatory)][string]$ResolvedGitRoot,
        [scriptblock]$ManifestSynchronizer
    )
    $summary = Get-VerificationSummaryData -ResolvedRoot $ResolvedRoot
    if ($Mode -eq 'Check') {
        return (Test-VerificationMetadata -ResolvedRoot $ResolvedRoot -ResolvedGitRoot $ResolvedGitRoot -Summary $summary)
    }
    $targets = @(
        Join-Path $ResolvedRoot 'README.md'
        Join-Path $ResolvedRoot 'REENTRY.md'
        Join-Path $ResolvedRoot 'VERIFICATION_MATRIX.md'
    )
    $manifestPath = Join-Path $ResolvedRoot 'manifest-sha256.txt'
    $snapshots = @{}
    foreach ($path in @($targets + $manifestPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "verification target is missing: $path" }
        $snapshots[$path] = [System.IO.File]::ReadAllBytes($path)
    }
    $updates = @{}
    $hidden = Get-VerificationHiddenMarker -Summary $summary
    foreach ($path in $targets) {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $label = switch (Split-Path -Leaf $path) {
            'README.md' { 'README' }
            'REENTRY.md' { 'REENTRY' }
            default { 'VERIFICATION_MATRIX' }
        }
        $expected = Get-VerificationVisibleBlock -Summary $summary -Document $label -Newline (Get-VerificationNewline -Text $text)
        $updates[$path] = Set-VerificationVisibleBlock -Text $text -ExpectedBlock $expected `
            -ExpectedHiddenMarker $hidden -Label $label
    }
    try {
        foreach ($path in $targets) { Write-VerificationTextAtomic -Path $path -Text $updates[$path] }
        if ($null -ne $ManifestSynchronizer) {
            & $ManifestSynchronizer $ResolvedRoot
        } else {
            $sync = Join-Path $ResolvedRoot 'scripts\sync-model-contract.ps1'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sync -RootPath $ResolvedRoot -Write | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "manifest synchronization failed with exit code $LASTEXITCODE." }
        }
        return (Test-VerificationMetadata -ResolvedRoot $ResolvedRoot -ResolvedGitRoot $ResolvedGitRoot -Summary $summary)
    } catch {
        foreach ($path in $snapshots.Keys) {
            [System.IO.File]::WriteAllBytes($path,[byte[]]$snapshots[$path])
        }
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ([string]::IsNullOrWhiteSpace($RootPath)) { $RootPath = Split-Path -Parent $PSScriptRoot }
        if ([string]::IsNullOrWhiteSpace($GitRootPath)) { $GitRootPath = $RootPath }
        $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\','/')
        $resolvedGitRoot = [System.IO.Path]::GetFullPath($GitRootPath).TrimEnd('\','/')
        $mode = if ($Write) { 'Write' } else { 'Check' }
        Invoke-VerificationMetadataSync -Mode $mode -ResolvedRoot $resolvedRoot -ResolvedGitRoot $resolvedGitRoot |
            ConvertTo-Json -Depth 6
        exit 0
    } catch {
        Write-Error $_
        exit 1
    }
}
