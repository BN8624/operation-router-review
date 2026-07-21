# CHANGELOG — operation-router

버전별 실제 변경 사항만 기록한다. 라우팅·모델·effort·권한·fallback의 기본 뼈대는 v2.3에서 확립됐고 이후는 결함 수리와 보안·정책 보강이다.

## v2.4.0 (2026-07-21)

작전 1(V11~V15) 실전 검증 중 발굴한 결함 수리 + 보안 경계 + 사용성 정책 변경. 테스트 184/184 PASS.

### 보안 (⑤)
- **저장소 경계 탐지 (실질 방어)**: `Get-StartSnapshot`이 저장소 밖 민감 경로(전역 `.gitconfig`, `CLAUDE.md`, `AGENTS.md`, 라우터 `config.json`·`common.ps1`)의 SHA-256을 워커 실행 전 스냅샷하고, postflight의 `Test-RepoBoundaryViolation`이 실행 후 재검사한다. 하나라도 바뀌면 `status: repo_boundary_violation`으로 최우선 보고하고 CI를 조회하지 않는다. 명령 패턴이 아니라 결과 변경을 잡으므로 플래그 재배열·래퍼·동의어 우회에 강하다.
- **deny 1차 차단 확장 (7→19)**: `git reset --merge/--keep`, `+main` 강제 push refspec, `rm` 플래그 분리형, `rmdir /s`·`rd /s`, `format`, `diskpart`, `shutdown`, `reg delete` 추가. 패턴 블록리스트는 취약하고 Grok 워커에만 적용되므로 1차 차단일 뿐이다(config `_deny_note` 명시).
- **secret 마스킹 강화**: Authorization 헤더 전체(Bearer 외 임의 스킴), AWS 액세스 키(`AKIA…`), 고엔트로피 토큰(Shannon 엔트로피 기반)을 추가로 마스킹한다. git SHA·UUID·순수 숫자는 명시적으로 제외해 로그 오탐을 막는다. 환경변수 전체 덤프 코드는 없음을 확인했다.

### 정책 (사용성)
- **A — 자연어 호출 + 실행 전 확인**: `operation-1/2/3`의 `disable-model-invocation`을 `false`로 바꿔 자연어 지시로도 호출할 수 있게 했다. 각 SKILL에 "실행 전 `status`로 예상 워커·비용을 파악해 한 줄 확인받고 진행, 슬래시 직접 입력은 생략" 계약을 추가했다. 디스패처(`/operation`)와 Claude 전용 변형은 `true` 유지.
- **B — 작전 1 Claude-only effort medium→high**: `claudeOnly.1`과 `operation-1-claude` frontmatter를 high로 올려 작전 1의 유일한 effort outlier를 제거했다(grok/sol/opus/claude 전부 high). 구현자↔검토자 분리(Opus 종료 검토)는 유지.
- **C — 작전 1 고위험 경고**: 작전 1이 `claude_only_required`로 떨어지면 반환에 `highRiskWarning` 필드를 붙인다(외부 구현·독립 검수 없이 단일 모델 진행 — 위험 작업이면 한도 리셋 대기 고려). 차단이 아닌 판단 정보. 작전 2에는 없음.

### 결함 수리 (작전 1 E2E 중 발굴)
- **검수 JSONL 파싱**: GPT 검수(codex `--json`)는 단일 JSON이 아니라 JSONL 이벤트 스트림이고 verdict가 `item.completed`/`agent_message`의 `text` 안에 있다. `ConvertFrom-StrictReviewJson`이 이를 추출하도록 수정. 이전에는 `review_parse_failed`로 fail-closed되어 정상 PASS를 못 받았다.
- **codex npm shim**: `Get-Command codex` 단건이 `codex.ps1`을 먼저 반환해 `Process.Start`가 실패했다. `-All`에서 Application(.exe/.cmd/.bat) 우선 선택으로 수리.

### 전역 규칙
- 전역 `CLAUDE.md`/`AGENTS.md`에서 수동 Operation Modes(§2·§3)를 전면 삭제했다. operation-router 스킬이 자동화하므로 수동 Grok 구동 규정이 스킬과 상충했다. 남긴 것은 Task Canon(§1), operation-router 최종 작업자 예외(§2), Common Git/보고(§3). 부수 효과로 워커 CLI가 AGENTS.md에서 "grok에 위임" 지시를 더는 발견하지 않는다.

### 범위 제외 (1인 사용 결정)
- install.ps1 / 업그레이드 / 롤백 스크립트와 INSTALL.md / ROLLBACK.md는 만들지 않는다. 롤백은 `~/.claude/backups/` 폴더 복원으로 충분하다.

### 임시 조건
- `gpt-5.6-sol`이 2026-07-21 models_cache에서 제거되어, 작전 1의 sol 역할은 사용자 지시로 `gpt-5.6-terra`에 임시 매핑돼 있다(config `gpt.workers.sol`, `_sol_note`). sol 복귀 시 매핑을 되돌리고 V11~V13·V15를 실제 sol로 재검증한다.

## v2.3.5 (2026-07-21)
- 최종 작업자 ASCII 마커 `[OPERATION_ROUTER_FINAL_WORKER]`와 전역 규칙 예외. UTF-8 stdin 보존을 `System.Diagnostics.Process` 직접 실행으로 재구현(콘솔 CP 65001의 BOM 삽입 결함 차단). 168개 테스트.

## v2.3.4 (2026-07-21)
- runtime/test 로그 네임스페이스 격리, 삭제 경로 검증, 독립 source-tree 테스트, 자체 완결 검토본(manifest-sha256).

## v2.3.3 이하 (2026-07-20)
- Grok 헤드리스 Cancelled 근본 수리(alwaysApprove), stopReason JSON 분류, Claude-only 전용 Skill, 오류 3분류(weekly/transient/provider), 저장소 네임스페이스 영수증, review/repair 자격 강제. 상세는 REENTRY 및 메모리 이력 참조.
