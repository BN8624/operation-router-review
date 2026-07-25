# config 모델 지정을 단일 원본으로 삼아 Skill frontmatter와 README 모델표를 검사·동기화한다.

[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [string]$RootPath,
    [Parameter(ParameterSetName = 'Check')]
    [switch]$Check,
    [Parameter(ParameterSetName = 'Write')]
    [switch]$Write
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ModelConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing model config: $Path" }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw "Invalid model config JSON: $($_.Exception.Message)"
    }
}

function Get-ModelContracts {
    param([Parameter(Mandatory)]$Config)
    return @(
        [pscustomobject][ordered]@{ skill = 'operation-1'; model = [string]$Config.claudeSession.'1'.model; effort = [string]$Config.claudeSession.'1'.effort; role = '시작 위험검토 → 작업자 → GPT Sol 검수 → 수리 1회 → 종료 판정' }
        [pscustomobject][ordered]@{ skill = 'operation-2'; model = [string]$Config.claudeSession.'2'.model; effort = [string]$Config.claudeSession.'2'.effort; role = '좁은 시작검토 → 작업자 → 종료검토 1회' }
        [pscustomobject][ordered]@{ skill = 'operation-3'; model = [string]$Config.claudeSession.'3'.model; effort = [string]$Config.claudeSession.'3'.effort; role = '인수검증 → run/watch → Draft PR 결과 표시, 자동 review/finalize 없음' }
        [pscustomobject][ordered]@{ skill = 'operation-1-claude'; model = [string]$Config.claudeOnly.'1'.model; effort = [string]$Config.claudeOnly.'1'.effort; role = '작전 1 Claude-only 재개: claude_execute 주문서 직접 구현 + postflight' }
        [pscustomobject][ordered]@{ skill = 'operation-3-claude'; model = [string]$Config.claudeOnly.'3'.logic.model; effort = [string]$Config.claudeOnly.'3'.logic.effort; role = '작전 3 logic Claude-only 재개: claude_execute 주문서 직접 구현 + postflight' }
        [pscustomobject][ordered]@{ skill = 'operation'; model = [string]$Config.claudeSession.dispatcher.model; effort = [string]$Config.claudeSession.dispatcher.effort; role = 'status/doctor/watch/recover/finalize/set/reset 디스패처' }
    )
}

function Get-ConfiguredModelIds {
    param([Parameter(Mandatory)]$Config)
    $ordered = @(
        [string]$Config.grok.model
        [string]$Config.gpt.workers.sol
        [string]$Config.gpt.workers.terra
        [string]$Config.gpt.workers.luna
        [string]$Config.claudeSession.'1'.model
        [string]$Config.claudeSession.'2'.model
        [string]$Config.claudeSession.'3'.model
        [string]$Config.claudeSession.dispatcher.model
        [string]$Config.claudeOnly.'1'.model
        [string]$Config.claudeOnly.'2'.model
        [string]$Config.claudeOnly.'3'.logic.model
        [string]$Config.claudeOnly.'3'.mechanical.model
    )
    return @($ordered | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-ConfiguredGptModelIds {
    param([Parameter(Mandatory)]$Config)
    return @(
        [string]$Config.gpt.workers.sol
        [string]$Config.gpt.workers.terra
        [string]$Config.gpt.workers.luna
    ) | Select-Object -Unique
}

function Get-ReadmeModelBlock {
    param([Parameter(Mandatory)]$Contracts)
    $lines = @(
        '<!-- model-contract:start -->'
        '| Skill | model (frontmatter) | effort | 역할 |'
        '|---|---|---|---|'
    )
    foreach ($contract in $Contracts) {
        $lines += "| $($contract.skill) | $($contract.model) | $($contract.effort) | $($contract.role) |"
    }
    $lines += '<!-- model-contract:end -->'
    return ($lines -join "`n")
}

function Get-ReadmeWorkerBlock {
    param([Parameter(Mandatory)]$Config)
    $op1Implement = $Config.gpt.desired.'1'.implement
    $op1Review = $Config.gpt.desired.'1'.review
    $op2Implement = $Config.gpt.desired.'2'.implement
    $op3Logic = $Config.gpt.desired.'3'.logic
    $op3Mechanical = $Config.gpt.desired.'3'.mechanical
    return (@(
        '<!-- worker-model-contract:start -->'
        '| 작전 | Grok 가능 | Grok 소진 + GPT 작업 허용 | GPT 차단(80%+/reserved/exhausted) |'
        '|---|---|---|---|'
        "| 1 구현 | $($Config.grok.model) $($Config.grok.operations.'1'.effort) | $($Config.gpt.workers.([string]$op1Implement.worker)) $($op1Implement.effort) | claude_only_required (``claudeOnly.1``) |"
        "| 1 검수 | — | $($Config.gpt.workers.([string]$op1Review.worker)) $($op1Review.effort) | claude_review_fallback (Opus 직접) / 예비분은 ``--use-gpt-review-reserve``만 |"
        "| 2 구현 | $($Config.grok.model) $($Config.grok.operations.'2'.effort) | $($Config.gpt.workers.([string]$op2Implement.worker)) $($op2Implement.effort) | claude_only_required (``claudeOnly.2``) |"
        "| 3 logic | $($Config.grok.model) $($Config.grok.operations.'3'.effort) | $($Config.gpt.workers.([string]$op3Logic.worker)) $($op3Logic.effort) | claude_only_required (``claudeOnly.3.logic``) |"
        "| 3 mechanical | $($Config.grok.model) $($Config.grok.operations.'3'.effort) | $($Config.gpt.workers.([string]$op3Mechanical.worker)) $($op3Mechanical.effort) | claude_direct (``claudeOnly.3.mechanical``, 기계적 작업만) |"
        '<!-- worker-model-contract:end -->'
    ) -join "`n")
}

function Get-CodexModelCacheJson {
    param([Parameter(Mandatory)]$Config)
    $models = @(Get-ConfiguredGptModelIds -Config $Config | ForEach-Object {
        [ordered]@{ slug = [string]$_ }
    })
    return ([ordered]@{ models = $models } | ConvertTo-Json -Depth 4 -Compress)
}

function Get-FrontmatterValue {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key
    )
    $match = [regex]::Match($Text, "(?m)^$([regex]::Escape($Key)):\s*(\S+)\s*$")
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

function Set-FrontmatterValue {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $pattern = [regex]::new("(?m)^$([regex]::Escape($Key)):\s*.*$")
    if ($pattern.Matches($Text).Count -ne 1) { throw "Expected one '$Key' frontmatter entry." }
    return $pattern.Replace($Text, "$Key`: $Value", 1)
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Utf8TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-ManifestEntries {
    param([Parameter(Mandatory)][string]$ResolvedRoot)
    $manifestPath = Join-Path $ResolvedRoot 'manifest-sha256.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Missing manifest-sha256.txt.' }
    $rootPrefix = $ResolvedRoot.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    $seen = @{}
    $entries = @()
    foreach ($line in (Get-Content -LiteralPath $manifestPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($line -notmatch '^([A-Fa-f0-9]{64})  (.+)$') { throw "Invalid manifest line: $line" }
        $relative = [string]$Matches[2]
        if ($relative -eq 'manifest-sha256.txt' -or [System.IO.Path]::IsPathRooted($relative)) {
            throw "Unsafe manifest path: $relative"
        }
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ResolvedRoot $relative))
        if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Manifest path escapes root: $relative"
        }
        if ($seen.ContainsKey($relative)) { throw "Duplicate manifest path: $relative" }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Missing manifest target: $relative" }
        $seen[$relative] = $true
        $entries += [pscustomobject][ordered]@{
            expected = ([string]$Matches[1]).ToLowerInvariant()
            relative = $relative
            fullPath = $fullPath
        }
    }
    if ($entries.Count -eq 0) { throw 'Manifest has no entries.' }
    return @($entries)
}

function Get-ManifestErrors {
    param([Parameter(Mandatory)][string]$ResolvedRoot)
    $errors = @()
    try { $entries = @(Get-ManifestEntries -ResolvedRoot $ResolvedRoot) }
    catch { return @($_.Exception.Message) }
    foreach ($entry in $entries) {
        $actual = (Get-FileHash -LiteralPath $entry.fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $entry.expected) { $errors += "Manifest hash drift: $($entry.relative)" }
    }
    return @($errors)
}

function Get-ConfigurationErrors {
    param([Parameter(Mandatory)]$Config)
    $errors = @()
    $policyNames = @($Config.PSObject.Properties.Name)
    if ($policyNames -notcontains 'modelPolicy' -or $null -eq $Config.modelPolicy) {
        $errors += 'config.modelPolicy is required.'
    } else {
        $policy = $Config.modelPolicy
        if ([string]$policy.selection -cne 'pinned') { $errors += 'modelPolicy.selection must be pinned.' }
        if ($policy.allowLatestAliases -isnot [bool] -or [bool]$policy.allowLatestAliases) { $errors += 'modelPolicy.allowLatestAliases must be false.' }
        if ([string]$policy.discovery -cne 'notify-only') { $errors += 'modelPolicy.discovery must be notify-only.' }
    }

    foreach ($modelId in (Get-ConfiguredModelIds -Config $Config)) {
        if ($modelId -notmatch '^[a-z0-9][a-z0-9.-]*$' -or $modelId -notmatch '\d') {
            $errors += "Configured model ID is not a safe pinned identifier: $modelId"
        }
        if ($modelId -match '(^|[-.])(latest|opus|sonnet|haiku|fable)$' -and $modelId -notmatch '\d') {
            $errors += "Latest/family model alias is forbidden: $modelId"
        }
        if ($modelId -match '(^|[-.])latest($|[-.])') {
            $errors += "Latest model alias is forbidden: $modelId"
        }
    }

    if ([string]$Config.claudeSession.'2'.model -cne [string]$Config.claudeOnly.'2'.model -or
        [string]$Config.claudeSession.'2'.effort -cne [string]$Config.claudeOnly.'2'.effort) {
        $errors += 'Operation 2 session and Claude-only model/effort must match because they share one Skill.'
    }
    if ([string]$Config.claudeSession.'3'.model -cne [string]$Config.claudeOnly.'3'.mechanical.model) {
        $errors += 'Operation 3 session and mechanical Claude-direct model must match because they share one Skill.'
    }
    return @($errors)
}

function Get-ContractErrors {
    param(
        [Parameter(Mandatory)][string]$ResolvedRoot,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Contracts
    )
    $errors = @(Get-ConfigurationErrors -Config $Config)

    $allowedEfforts = @('low','medium','high','xhigh','max')
    foreach ($contract in $Contracts) {
        if ([string]::IsNullOrWhiteSpace([string]$contract.model)) { $errors += "Missing model for $($contract.skill)." }
        if ([string]$contract.effort -cnotin $allowedEfforts) { $errors += "Invalid effort for $($contract.skill): $($contract.effort)" }
        $skillPath = Join-Path $ResolvedRoot "skills\$($contract.skill)\SKILL.md"
        if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
            $errors += "Missing Skill file: skills/$($contract.skill)/SKILL.md"
            continue
        }
        $raw = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
        if ((Get-FrontmatterValue -Text $raw -Key 'model') -cne [string]$contract.model) {
            $errors += "Skill model drift: $($contract.skill)"
        }
        if ((Get-FrontmatterValue -Text $raw -Key 'effort') -cne [string]$contract.effort) {
            $errors += "Skill effort drift: $($contract.skill)"
        }
    }

    $readmePath = Join-Path $ResolvedRoot 'README.md'
    if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
        $errors += 'Missing README.md.'
    } else {
        $readme = (Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $expected = Get-ReadmeModelBlock -Contracts $Contracts
        $start = '<!-- model-contract:start -->'
        $end = '<!-- model-contract:end -->'
        $match = [regex]::Match($readme, "(?s)$([regex]::Escape($start)).*?$([regex]::Escape($end))")
        if (-not $match.Success) {
            $errors += 'README model contract markers are missing.'
        } elseif ($match.Value -cne $expected) {
            $errors += 'README model contract table drift.'
        }
        $workerStart = '<!-- worker-model-contract:start -->'
        $workerEnd = '<!-- worker-model-contract:end -->'
        $workerMatch = [regex]::Match($readme, "(?s)$([regex]::Escape($workerStart)).*?$([regex]::Escape($workerEnd))")
        if (-not $workerMatch.Success) {
            $errors += 'README worker model contract markers are missing.'
        } elseif ($workerMatch.Value -cne (Get-ReadmeWorkerBlock -Config $Config)) {
            $errors += 'README worker model contract table drift.'
        }
    }

    $cachePath = Join-Path $ResolvedRoot 'tests\fixtures\models-cache.ci.json'
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        $errors += 'Missing generated Codex model cache fixture.'
    } else {
        try {
            $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $actualIds = @($cache.models | ForEach-Object { [string]$_.slug })
            $expectedIds = @(Get-ConfiguredGptModelIds -Config $Config)
            if (($actualIds -join "`n") -cne ($expectedIds -join "`n")) {
                $errors += 'Codex model cache fixture drift.'
            }
        } catch {
            $errors += "Invalid generated Codex model cache fixture: $($_.Exception.Message)"
        }
    }
    $errors += @(Get-ManifestErrors -ResolvedRoot $ResolvedRoot)
    return @($errors)
}

if ([string]::IsNullOrWhiteSpace($RootPath)) { $RootPath = Split-Path -Parent $PSScriptRoot }
$resolvedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\','/')
$configPath = Join-Path $resolvedRoot 'config\config.json'
$config = Read-ModelConfig -Path $configPath
$contracts = Get-ModelContracts -Config $config

if ($Write) {
    try {
        $preparationErrors = @(Get-ConfigurationErrors -Config $config)
        $allowedEfforts = @('low','medium','high','xhigh','max')
        foreach ($contract in $contracts) {
            if ([string]::IsNullOrWhiteSpace([string]$contract.model)) { $preparationErrors += "Missing model for $($contract.skill)." }
            if ([string]$contract.effort -cnotin $allowedEfforts) { $preparationErrors += "Invalid effort for $($contract.skill): $($contract.effort)" }
        }
        if ($preparationErrors.Count -gt 0) { throw ($preparationErrors -join '; ') }

        $preparedWrites = @()
        foreach ($contract in $contracts) {
            $skillPath = Join-Path $resolvedRoot "skills\$($contract.skill)\SKILL.md"
            if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) { throw "Missing Skill file: $skillPath" }
            $raw = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
            $updated = Set-FrontmatterValue -Text $raw -Key 'model' -Value ([string]$contract.model)
            $updated = Set-FrontmatterValue -Text $updated -Key 'effort' -Value ([string]$contract.effort)
            $preparedWrites += [pscustomobject][ordered]@{ path = $skillPath; text = $updated }
        }

        $readmePath = Join-Path $resolvedRoot 'README.md'
        if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) { throw "Missing README: $readmePath" }
        $readmeRaw = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
        $lineEnding = if ($readmeRaw.Contains("`r`n")) { "`r`n" } else { "`n" }
        $normalized = $readmeRaw -replace "`r`n", "`n"
        $start = '<!-- model-contract:start -->'
        $end = '<!-- model-contract:end -->'
        $pattern = [regex]::new("(?s)$([regex]::Escape($start)).*?$([regex]::Escape($end))")
        if ($pattern.Matches($normalized).Count -ne 1) { throw 'README model contract markers must occur exactly once.' }
        $normalized = $pattern.Replace($normalized, (Get-ReadmeModelBlock -Contracts $contracts), 1)
        $workerStart = '<!-- worker-model-contract:start -->'
        $workerEnd = '<!-- worker-model-contract:end -->'
        $workerPattern = [regex]::new("(?s)$([regex]::Escape($workerStart)).*?$([regex]::Escape($workerEnd))")
        if ($workerPattern.Matches($normalized).Count -ne 1) { throw 'README worker model contract markers must occur exactly once.' }
        $normalized = $workerPattern.Replace($normalized, (Get-ReadmeWorkerBlock -Config $config), 1)
        $preparedWrites += [pscustomobject][ordered]@{ path = $readmePath; text = ($normalized -replace "`n", $lineEnding) }

        $cachePath = Join-Path $resolvedRoot 'tests\fixtures\models-cache.ci.json'
        if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { throw "Missing generated fixture: $cachePath" }
        $preparedWrites += [pscustomobject][ordered]@{ path = $cachePath; text = ((Get-CodexModelCacheJson -Config $config) + "`n") }

        $manifestEntries = @(Get-ManifestEntries -ResolvedRoot $resolvedRoot)
        $writeTextByPath = @{}
        foreach ($preparedWrite in $preparedWrites) {
            $writeTextByPath[[System.IO.Path]::GetFullPath([string]$preparedWrite.path)] = [string]$preparedWrite.text
        }
        $manifestPath = Join-Path $resolvedRoot 'manifest-sha256.txt'
        $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
        $manifestLineEnding = if ($manifestRaw.Contains("`r`n")) { "`r`n" } else { "`n" }
        $manifestHasTrailingLineEnding = $manifestRaw.EndsWith("`n")
        $manifestLines = @()
        foreach ($entry in $manifestEntries) {
            if ($writeTextByPath.ContainsKey($entry.fullPath)) {
                $hash = Get-Utf8TextSha256 -Text ([string]$writeTextByPath[$entry.fullPath])
            } else {
                $hash = (Get-FileHash -LiteralPath $entry.fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            $manifestLines += "$hash  $($entry.relative)"
        }
        $manifestText = $manifestLines -join $manifestLineEnding
        if ($manifestHasTrailingLineEnding) { $manifestText += $manifestLineEnding }
        $preparedWrites += [pscustomobject][ordered]@{ path = $manifestPath; text = $manifestText }

        $backups = @{}
        foreach ($preparedWrite in $preparedWrites) {
            $fullWritePath = [System.IO.Path]::GetFullPath([string]$preparedWrite.path)
            $backups[$fullWritePath] = [System.IO.File]::ReadAllBytes($fullWritePath)
        }
        $writtenPaths = @()
        try {
            foreach ($preparedWrite in $preparedWrites) {
                $fullWritePath = [System.IO.Path]::GetFullPath([string]$preparedWrite.path)
                Write-Utf8NoBom -Path $fullWritePath -Text ([string]$preparedWrite.text)
                $writtenPaths += $fullWritePath
            }
            $postWriteErrors = @(Get-ContractErrors -ResolvedRoot $resolvedRoot -Config $config -Contracts $contracts)
            if ($postWriteErrors.Count -gt 0) { throw ($postWriteErrors -join '; ') }
        }
        catch {
            $writeException = $_
            $restoreErrors = @()
            for ($index = $writtenPaths.Count - 1; $index -ge 0; $index--) {
                $writtenPath = $writtenPaths[$index]
                try { [System.IO.File]::WriteAllBytes($writtenPath, [byte[]]$backups[$writtenPath]) }
                catch { $restoreErrors += "$writtenPath`: $($_.Exception.Message)" }
            }
            if ($restoreErrors.Count -gt 0) {
                throw "$($writeException.Exception.Message); rollback failed: $($restoreErrors -join '; ')"
            }
            throw $writeException
        }
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

$contractErrors = @(Get-ContractErrors -ResolvedRoot $resolvedRoot -Config $config -Contracts $contracts)
if ($contractErrors.Count -gt 0) {
    foreach ($contractError in $contractErrors) { Write-Error $contractError }
    exit 1
}

[ordered]@{
    status = if ($Write) { 'model_contract_synchronized' } else { 'model_contract_valid' }
    selection = [string]$config.modelPolicy.selection
    discovery = [string]$config.modelPolicy.discovery
    skillCount = @($contracts).Count
    workerRoleCount = 4
    manifestUpdated = [bool]$Write
    configuredModelIds = @(Get-ConfiguredModelIds -Config $config)
} | ConvertTo-Json -Depth 5
