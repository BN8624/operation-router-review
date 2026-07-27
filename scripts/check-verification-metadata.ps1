# 공식 검증 메타데이터와 사람이 읽는 문서의 핵심 수치가 일치하는지 fail-closed로 검사한다.

[CmdletBinding()]
param(
    [string]$RootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredInteger {
    param(
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Summary.PSObject.Properties.Name -notcontains $Name) {
        throw "verification summary is missing '$Name'."
    }
    $value = $Summary.$Name
    if ($value -isnot [int] -and $value -isnot [long]) {
        throw "verification summary '$Name' must be an integer."
    }
    if ([long]$value -lt 0) {
        throw "verification summary '$Name' must not be negative."
    }
    return [long]$value
}

function Assert-DocumentCounts {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][long]$SourcePassed,
        [Parameter(Mandatory)][long]$SourceFailed,
        [Parameter(Mandatory)][long]$InstalledPassed,
        [Parameter(Mandatory)][long]$InstalledFailed
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "verification document is missing: $Path"
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $pattern = '<!-- verification-summary sourceTreePassed=(\d+) sourceTreeFailed=(\d+) installedFixturePassed=(\d+) installedFixtureFailed=(\d+) -->'
    $matches = @([regex]::Matches($text, $pattern))
    if ($matches.Count -ne 1) {
        throw "$Label must contain exactly one verification-summary marker."
    }
    $actual = @(
        [long]$matches[0].Groups[1].Value,
        [long]$matches[0].Groups[2].Value,
        [long]$matches[0].Groups[3].Value,
        [long]$matches[0].Groups[4].Value
    )
    $expected = @($SourcePassed, $SourceFailed, $InstalledPassed, $InstalledFailed)
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($actual[$index] -ne $expected[$index]) {
            throw "$Label verification counts differ from evidence/verification-summary.json."
        }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        $RootPath = Split-Path -Parent $PSScriptRoot
    }
    $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\','/')
    $summaryPath = Join-Path $resolvedRoot 'evidence\verification-summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        throw "verification summary is missing: $summaryPath"
    }
    try {
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 |
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

    $integerFields = @(
        'sourceTreePassed', 'sourceTreeFailed',
        'installedFixturePassed', 'installedFixtureFailed',
        'installedIntegrationFailures', 'powerShellParserFiles',
        'manifestEntries', 'paidModelCalls'
    )
    $numbers = @{}
    foreach ($field in $integerFields) {
        $numbers[$field] = Get-RequiredInteger -Summary $summary -Name $field
    }
    foreach ($field in @('modelContract','gitDiffCheck')) {
        if ($summary.PSObject.Properties.Name -notcontains $field -or
            $summary.$field -isnot [string] -or $summary.$field -cne 'passed') {
            throw "verification summary '$field' must be string 'passed'."
        }
    }
    if ($summary.PSObject.Properties.Name -notcontains 'verifiedHead' -or
        $summary.verifiedHead -isnot [string] -or $summary.verifiedHead -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'verification summary verifiedHead must be a 40-character Git SHA.'
    }
    if ($summary.PSObject.Properties.Name -notcontains 'verifiedAtUtc' -or
        $summary.verifiedAtUtc -isnot [string]) {
        throw 'verification summary verifiedAtUtc must be a string.'
    }
    $parsedTimestamp = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
        [string]$summary.verifiedAtUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsedTimestamp
    ) -or $parsedTimestamp.Offset -ne [timespan]::Zero) {
        throw 'verification summary verifiedAtUtc must be an ISO-8601 UTC timestamp.'
    }

    $readme = Get-Content -LiteralPath (Join-Path $resolvedRoot 'README.md') -Raw -Encoding UTF8
    if ($readme -notmatch '(?m)^# operation-router \(v([0-9]+\.[0-9]+\.[0-9]+)\)\s*$') {
        throw 'README version heading was not found.'
    }
    if ($Matches[1] -cne [string]$summary.version) {
        throw 'README version differs from verification summary.'
    }
    foreach ($doc in @(
        @{ path='README.md'; label='README' },
        @{ path='REENTRY.md'; label='REENTRY' },
        @{ path='VERIFICATION_MATRIX.md'; label='VERIFICATION_MATRIX' }
    )) {
        Assert-DocumentCounts -Path (Join-Path $resolvedRoot $doc.path) -Label $doc.label `
            -SourcePassed $numbers.sourceTreePassed -SourceFailed $numbers.sourceTreeFailed `
            -InstalledPassed $numbers.installedFixturePassed -InstalledFailed $numbers.installedFixtureFailed
    }

    $evidencePath = Join-Path $resolvedRoot 'evidence\source-tree-test-result.txt'
    $evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8
    if ($evidence -notmatch 'sourceTreeResult=(\d+) passed, (\d+) failed') {
        throw 'sourceTreeResult is missing from evidence text.'
    }
    $evidenceSourcePassed = [long]$Matches[1]
    $evidenceSourceFailed = [long]$Matches[2]
    if ($evidence -notmatch 'installedFixtureResult=(\d+) passed, (\d+) failed') {
        throw 'installedFixtureResult is missing from evidence text.'
    }
    $evidenceInstalledPassed = [long]$Matches[1]
    $evidenceInstalledFailed = [long]$Matches[2]
    if ($evidenceSourcePassed -ne $numbers.sourceTreePassed -or
        $evidenceSourceFailed -ne $numbers.sourceTreeFailed -or
        $evidenceInstalledPassed -ne $numbers.installedFixturePassed -or
        $evidenceInstalledFailed -ne $numbers.installedFixtureFailed) {
        throw 'evidence text test counts differ from verification summary.'
    }

    [pscustomobject]@{
        status = 'passed'
        version = [string]$summary.version
        sourceTreePassed = $numbers.sourceTreePassed
        installedFixturePassed = $numbers.installedFixturePassed
        verifiedHead = [string]$summary.verifiedHead
    } | ConvertTo-Json -Depth 4
    exit 0
} catch {
    Write-Error $_
    exit 1
}
