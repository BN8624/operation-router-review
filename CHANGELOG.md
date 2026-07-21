# CHANGELOG — operation-router

버전별 실제 변경 사항만 기록한다. 라우팅·모델·effort·권한·fallback의 기본 뼈대는 v2.3에서 확립됐고 이후는 결함 수리와 보안·정책 보강이다.

## v2.4.5 (2026-07-22)

- 실행 namespace에 canonical repository root의 SHA-256 앞 16자를 추가했다. 새 receipt는 ownerRepo와 canonical root/hash를 모두 검증하며, 동일 origin의 복수 clone이 execution·lock·run/review receipt를 공유하지 않는다. exact root가 확인된 비활성 legacy receipt만 원자 이전한다.
- result envelope가 없는 recover를 `recovered_*_unverified`로 분리하고 provenance를 execution/run receipt에 저장한다. 이 진단 receipt는 작전 1 Sol review와 repair 자격이 없으며 GPT review 호출은 0회다.
- active 동안만 prompt와 raw stdout/stderr를 유지한다. terminal finalization은 마스킹 보존본을 만든 뒤 raw와 prompt를 삭제하며, 실패는 `artifact_sanitization_failed`로 보고한다. namespace별 terminal generation 보존 개수는 10이고 active·최신 참조 generation은 삭제하지 않는다.
- 선택 critical tree의 추가·수정·삭제를 사후 탐지하도록 확대했다. 호환 상태 `repo_boundary_violation`은 유지하지만 OS sandbox나 포괄적 경계 보호라는 주장을 제거했다.
- 라우팅, 모델·effort 배치, 사용량 임계값, fallback, Claude-only 정책은 변경하지 않았다. v2.4.5 검증은 mock/fake Git/격리 OS process와 installed fixture이며 유료 Grok·GPT live 호출은 실행하지 않았다.

## v2.4.4 (2026-07-22)

- 작전 1·2·3의 실제 Grok/GPT 구현 호출마다 `executionId`와 증가하는 `generation`을 가진 저장소별 실행 영수증을 worker 시작 전에 원자적으로 저장한다.
- 독립 `worker-host.ps1`이 raw stdout/stderr, 마스킹 runtime log, heartbeat, result를 실행 중부터 지속 저장하며 전경 대기는 480초로 제한한다. 전경 대기 종료는 worker 재호출 조건이 아니다.
- 활성 실행은 `execution_already_active`로 중복 worker 호출을 막고 `/operation recover <작전번호> <이슈번호>`를 반환한다. PID와 시작시각을 함께 비교해 PID 재사용을 방어한다.
- recover는 worker를 호출하지 않고 최신 세대 result 또는 Git·push·CI 상태로 postflight를 재개한다. 외부 중단 상태와 `interrupted`·`localVerificationComplete`·`recoveredByPostflight`를 일반 완료와 분리한다.
- CI 성공은 로컬 검증 완료나 worker 정상 JSON 반환으로 간주하지 않는다. 주문서 검증 계층 지침은 명시된 전체 로컬 검증을 임의로 삭제하지 않는다.
- 작전 1의 `sol` 역할을 임시 `gpt-5.6-terra` 매핑에서 설계 모델인 `gpt-5.6-sol`로 원복했다. `codex-cli 0.144.5` models_cache에서 Sol/Terra/Luna 노출을 확인했으며 `_sol_note`를 제거했다.
- 과거 Terra로 실행한 V11~V13·V15의 `PASS_PENDING_SOL_RETEST` 판정은 실제 Sol 재검증 전까지 유지한다.
- 검토 저장소 manifest에서 누락된 `evidence/` 파일 3개를 등록해 배포 대상 집합과 manifest 경로 집합을 일치시켰다.

## v2.4.3 (2026-07-21)

v2.4.2 외부 재검토에서 발견된 **영수증 세대(generation) 결함**을 수리(REPAIR_REQUIRED → 해소). 영수증 키가 (작전+이슈+저장소)로 고정이라, 실패·경계 위반으로 조기 반환된 재실행이 이전 세대의 성공/REPAIR_REQUIRED 영수증을 남겨 review·repair가 재사용할 수 있었다. v2.4.2 이하 태그는 이동하지 않는다.

- **HIGH — 이전 completed run 영수증 무효화**: 작전 1의 실제 worker 호출 직전에 같은 이슈의 기존 run·review 영수증을 삭제한다(`Remove-RunReceipt`/`Remove-ReviewReceipt`). 새 실행이 경계 위반·실패로 끝나면 새 영수증을 저장하지 않으므로, 과거 completed 영수증이 남아 review 자격을 통과하는 경로가 사라진다. 재실행 후 review는 영수증 없음으로 GPT를 호출하지 않는다.
- **HIGH — 이전 REPAIR_REQUIRED review 영수증 무효화**: 실제 GPT 검수 호출 직전에 기존 review 영수증을 삭제한다. 새 검수가 경계 위반·실패면 새 영수증을 저장하지 않아, 이전 세대의 REPAIR_REQUIRED 영수증으로 repair가 실행되는 경로가 사라진다.
- **원칙**: 새 실행·검수가 성공적으로 완료된 경우에만 새 영수증을 저장한다. 세대 식별자 같은 복잡한 시스템 없이, "worker/GPT 호출 직전 무효화 + 성공 시에만 저장"으로 해결.
- **LOW — 문서**: VERIFICATION_MATRIX 외부 검토 상태를 v2.4.3 재검토 예정으로 갱신.

## v2.4.2 (2026-07-21)

v2.4.1 외부 재검토에서 발견된 **영수증 저장 순서 결함**을 수리(REPAIR_REQUIRED → 해소). finalizer가 최종 출력만 고치고 영수증은 그 전에 저장돼, 보안 위반 run/review가 내부적으로 성공 영수증으로 남던 문제. v2.4.1 태그는 이동하지 않는다.

- **HIGH — run 영수증 경계 승격**: 작전 1 run 영수증을 저장하기 전에 경계 위반을 확정한다. 위반이면 `Save-RunReceipt`에 `-StatusOverride repo_boundary_violation`을 넘겨 영수증 status도 승격한다. 이전에는 `completed`로 저장돼 review 자격 검사를 통과했다. 이제 경계 위반 run은 `review_not_eligible`로 거부되고 GPT 검수가 호출되지 않는다.
- **HIGH — review 영수증 미저장**: 검수 실행 중 감시 파일이 변경되면 `REPAIR_REQUIRED` review 영수증을 저장하지 않는다(`Test-RepoBoundaryViolation`로 저장 직전 확인). 경계 위반 review 영수증으로 repair가 실행되는 경로를 원천 차단한다.
- **MEDIUM — Claude-only postflight 조기 반환**: `Invoke-PostflightCommand`의 `repository_receipt_mismatch` 반환도 pending 스냅샷의 boundaryWatch로 finalizer를 통과시킨다.
- **LOW — 문서 표현**: VERIFICATION_MATRIX 정책 행의 "실행 전 확인 게이트"를 "soft confirmation policy(코드 강제 게이트 아님)"로 정정. README 머리말의 v2.4.0 "진행 중"·"GPT Plan B 승인 전" 잔여 표현을 현재 상태로 갱신.

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
- **선택 파일 사후 탐지(당시 명칭 보정)**: v2.4.0은 일부 전역·라우터 파일의 실행 전후 SHA-256 변화를 `repo_boundary_violation`으로 보고하고 CI를 조회하지 않았다. 이 기능은 포괄적 저장소 경계나 sandbox가 아니며, v2.4.5에서 감시 tree와 한계를 정확히 문서화했다.
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
