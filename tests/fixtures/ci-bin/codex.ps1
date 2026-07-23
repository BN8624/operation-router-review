# CI doctor가 유료 호출 없이 Codex 설치 상태를 재현한다.
if ($args.Count -gt 0 -and $args[0] -eq '--version') {
    'codex-ci-fixture 0.0.0'
} elseif ($args.Count -gt 0 -and $args[0] -eq 'login') {
    'not logged in'
}
