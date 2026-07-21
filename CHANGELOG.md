# CHANGELOG — operation-router

버전별 실제 변경 사항만 기록한다. 라우팅·모델·effort·권한·fallback의 기본 뼈대는 v2.3에서 확립됐고 이후는 결함 수리와 보안·정책 보강이다.

## v2.4.1 (2026-07-21)

외부 정적 검토(v2.4.0 대상)에서 지적된 정합성·보안 결함을 좁게 수리. v2.4.0 태그는 이동하지 않고 이전 릴리스로 보존한다.

- **경계 finalizer를 모든 종료 경로로 통합**: `Complete-BoundaryFinalizer` 공통 함수를 `New-FinalOutput`과 review/repair 진입점에 적용했다. 이전에는 worker 실패·부분 변경·fallback·transient/weekly·review/repair 실패 같은 조기 반환이 postflight 경계 검사에 도달하지 않아, 감시 파일을 변경한 뒤 실패하면 `worker_failed` 등이 `repo_boundary_violation`보다 먼저 반환될 수 있었다. 이제 위반 시 최종 status를 `repo_boundary_violation`으로 승격하고 원래 상태를 `underlyingStatus`에 보존하며 CI를 조회하지 않는다. 위반 없으면 스키마 불변. 조기 반환 경로별 회귀 테스트 추가.
- **VERIFICATION_MATRIX 판정 분리**: Terra가 Sol 역할을 임시 수행한 V11·V12·V13·V15를 최종 PASS가 아닌 `PASS_PENDING_SOL_RETEST`로 표시. V10·V14는 PASS. Terra 실행은 라우터·검수 파서·수리 역학을 확인한 유효한 선행 검증이며 Sol canon은 불변이다.
- **Sol 차단 원인 정정**: "Sol이 (전역) 제거됐다"는 단정을 계정별 사실로 교체했다 — 주 사용 계정은 Codex 한도 소진으로 Sol 실행 불가, 별도 E2E 테스트 계정에서는 Sol이 models_cache에 노출되지 않아 doctor unresolved. 테스트 환경에서만 Sol→Terra 임시 매핑. README·CHANGELOG·VERIFICATION_MATRIX·REENTRY·config `_comment`/`_sol_note` 통일.
- **manifest tracked-file 완전성**: `.gitattributes`를 manifest에 포함하고, 파일시스템 배포 대상 집합과 manifest 경로 집합의 완전 일치·중복 금지·manifest 자체 제외를 테스트로 강제. 누락된 tracked file을 잡는다.
- **soft confirmation policy 표현 정정**: 자연어 자동 호출 전 확인을 "실행 전 확인 게이트"에서 "soft confirmation policy"로 낮춰, 코드가 강제하는 보안 토큰 게이트가 아니라 모델이 따르는 사용성·오작동 방지 정책임을 명시. SECURITY의 강제 방어층 목록에서 분리. 새 `-Confirmed`/확인 토큰 시스템은 만들지 않았다.
- **백업·롤백 문서 정정**: "버전 교체 전 전체 백업이 자동으로 쌓인다"는 표현을 제거하고, 자동 설치·백업·롤백 스크립트가 없으며 수동 생성 백업이 있는 경우에만 복원 가능함을 README·SECURITY에 통일.

## v2.4.0 (2026-07-21)

작전 1(V11~V15) 실전 검증 중 발굴한 결함 수리 + 보안 경계 + 사용성 정책 변경. 외부 정적 검토에서 6개 정합·보안 지적을 받아 v2.4.1로 수리했다.

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
- 작전 1의 sol 역할은 **테스트 환경에서만** 사용자 지시로 `gpt-5.6-terra`에 임시 매핑돼 있다(config `gpt.workers.sol`, `_sol_note`). 원인: 주 사용 Codex 계정은 한도 소진으로 Sol 실행 불가, 별도 E2E 테스트 계정에서는 Sol이 models_cache에 노출되지 않아 doctor가 unresolved로 판정. 이는 Sol의 전역 제거·폐기가 아니고 Terra가 공식 대체자도 아니다. Sol canon은 유지하며, 한도 복구·Sol 노출 계정에서 V11~V13·V15를 재검증한다.

## v2.3.5 (2026-07-21)
- 최종 작업자 ASCII 마커 `[OPERATION_ROUTER_FINAL_WORKER]`와 전역 규칙 예외. UTF-8 stdin 보존을 `System.Diagnostics.Process` 직접 실행으로 재구현(콘솔 CP 65001의 BOM 삽입 결함 차단). 168개 테스트.

## v2.3.4 (2026-07-21)
- runtime/test 로그 네임스페이스 격리, 삭제 경로 검증, 독립 source-tree 테스트, 자체 완결 검토본(manifest-sha256).

## v2.3.3 이하 (2026-07-20)
- Grok 헤드리스 Cancelled 근본 수리(alwaysApprove), stopReason JSON 분류, Claude-only 전용 Skill, 오류 3분류(weekly/transient/provider), 저장소 네임스페이스 영수증, review/repair 자격 강제. 상세는 REENTRY 및 메모리 이력 참조.
