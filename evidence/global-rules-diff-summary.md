# 전역 규칙 예외 diff 요약 (2026-07-21 검증)

## 대상 파일

- `~/.claude/CLAUDE.md`
- `~/.codex/AGENTS.md`

## 검증 결과

- 두 파일 SHA-256 동일 (byte-identical):
  `62D2DF237E43C0E605BEEAFE89F5D85B50D7903B919A46219F51383EEA40C1B9`
- 추가된 예외 섹션: `### operation-router final-worker exception`
  - `[OPERATION_ROUTER_FINAL_WORKER]` 마커로 시작하는 주문을 받은 세션은
    라우터가 이미 선택한 최종 작업자다.
  - 마커 세션에서는 Operation 1/2/3 재위임 규칙을 적용하지 않고, Grok·Codex·
    Claude 등 다른 워커 CLI를 점검·호출·재위임하지 않으며 이슈를 직접 구현한다.
  - 이 예외는 scope 확장을 허용하지 않고 task canon·Git·test·push·reporting
    규칙을 바꾸지 않는다. 마커가 없으면 기존 Operation Modes가 그대로 적용된다.
- 예외 범위: 마커가 있는 최종 작업자 세션으로만 한정된다 (일반 세션 무변화).
- 백업 존재:
  - `~/.claude/backups/operation-router.bak.v2.3.4.20260721-004357/global-rules/CLAUDE.md`
  - `~/.claude/backups/operation-router.bak.v2.3.4.20260721-004357/global-rules/AGENTS.md`
  - 교체 전 Codex 지침 원본: `~/.codex/AGENTS.md.bak.20260707-100332`
- Codex 가독성: Codex CLI의 전역 지침 경로인 `~/.codex/AGENTS.md`에 배치되어
  있다. 실전 독해 확인은 V03 재실행에서 Codex가 재위임 없이 직접 구현하는지로
  판정한다.
