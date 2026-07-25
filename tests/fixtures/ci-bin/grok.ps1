# CI doctor가 유료 호출 없이 Grok 기능 탐지를 재현한다.
if ($args.Count -gt 0 -and $args[0] -eq '--version') {
    'grok-ci-fixture 0.0.0'
} elseif ($args.Count -gt 0 -and $args[0] -eq 'models') {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    (Get-Content -LiteralPath (Join-Path $repoRoot 'config\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).grok.model
} elseif ($args.Count -gt 0 -and $args[0] -eq '--help') {
    '--always-approve --allow --deny dontAsk'
}
