# VERIFICATION_MATRIX — operation-router v3.0.8

<!-- verification-summary sourceTreePassed=560 sourceTreeFailed=0 installedFixturePassed=560 installedFixtureFailed=0 -->

현재 실행 계약은 `run -Detach` → `watch -Follow` → `operation_terminal` → `nextAction` → final review → `finalize` 순서다. recover는 watch가 없는 새 세션 재진입에만 사용한다.

## 검증 원칙

- source tree의 정식 `tests/run-tests.ps1`을 Windows PowerShell 5.1과 Pester 3.4 strict mode로 실행한다.
- fake Git repository와 bare remote, 주입 worker, mock PR probe, 격리 process와 고유 임시 USERPROFILE만 사용한다.
- 원격 Actions는 Pester 3.4.0과 임시 doctor CLI·합성 model cache를 고정해 runner 설치 상태에 의존하지 않는다.
- 실제 사용자 홈의 설치 Skill이나 runtime state를 읽거나 수정하지 않는다.
- 실제 Grok, GPT, Claude 유료 호출과 실제 GitHub PR 생성·수정·병합은 수행하지 않는다.
- 테스트 실패 catch 무시, skip, 기준 완화, 자동 merge는 허용하지 않는다.

## v3 필수 회귀 매핑

| 번호 | 영역 | 검증 내용 |
|---:|---|---|
| 1–5 | 설정 | 누락 legacy direct-main, 명시 mode, PR 계약, 잘못된 mode와 위험 ref 거부 |
| 6–13 | branch preflight | synced base 생성, dirty/ahead/behind/fetch/임의 branch 차단, 완전한 receipt+Draft PR 재개, 무소유 remote branch 차단 |
| 14–19 | worker/postflight | 실제 expected branch·issue·remote·엄격 완료 보고 계약, main 금지, branch 변경·base 직접 push 차단, work branch push 확인 |
| 20–24 | clone mutation lock | 다른 이슈·Operation 동시 mutation 차단, watch 읽기 허용, 안전한 해제, clone namespace 격리 |
| F4 abandon-claude | 방치 claude 지시 | 유효 해제, 잘못된 이슈/repo 거부, 활성 execution 거부, pending 누락·비Claude purpose·dirty/HEAD 변경 수동 해결 요구, 다른 clone 격리, idempotent |
| 25–34 | Draft PR | push 뒤 생성, 정확한 OPEN Draft 재사용, base/head/repository/state/Draft 불일치 차단, 생성 실패, body 마스킹·임시 파일 정리 |
| 35–42 | PR CI | 모든 success, failure 우선, pending, neutral/skipped/unknown, no-check 정책, API 오류, 전체 check 집계 |
| 43–50 | receipt/review/repair/recover | workflow round-trip, v1 legacy, mode pin, branch/PR SHA review gate, 같은 PR repair, 새 PR 금지, unverified recover |
| 51–57 | finalize | PASS+CI success만 Draft 유지 merge_ready, pending/failed/unavailable·repair 미검토·boundary/artifact/local verification 차단, Ready/merge 호출 0회 |
| 58–68b | direct-main와 안전 회귀 | 정상 run, fallback, review, repair, recover, watch-first, sanitization, retention, clone 격리, UTF-8 stdin, 기존 mock 유지, installed fixture 실제 홈 cache 비참조 |
| PR #2 외부 검토 회귀 | 완료 보고·workflow·CI·Draft·review coverage·원격 CI | Claude 보고 6경로, base/head workflow 4경로, PR 연관 check 6경로, finalize 재시도, 대형 diff/실패·`INCOMPLETE` coverage, Actions 정적 계약 |
| v3.0.2 모델 계약 | config 단일 원본·고정 ID·생성물 drift | source tree 정합성, Skill drift 복구, latest/family alias 쓰기 전 차단, Operation 2·3 공유 Skill 충돌 차단, modelPolicy 고정, doctor config 파생 보고 |
| v3.0.3 모델 수명주기 | 미래 고정 ID 전파·provider 진단 | 가상 Grok/GPT/Claude ID를 config에서 Skill·README 두 표·CI cache·manifest로 생성, Codex 역할별 available/missing, Grok 성공 목록 exact-ID 판정, malformed/error fail-closed, 쓰기 선검증·rollback, source/installed fixture 격리 |
| v3.0.3 detach 오류 정책 | F1-F3 envelope fidelity | direct-main/PR detached weekly/transient/provider/quota_unknown, clean Plan B, 2차 worker 오류 분류 보존, partial 반환·receipt 일치, usage-state 정직성, watch follow E2E, 유료 호출 0 |
| v3.0.5 live canary 정본 | 단계·provenance·외부 final review | run/watch terminal 고정, Operation 1 review·repair, Operation 2·1 구조화 evidence gate, actual result envelope·worker report·Draft PR head·PR-linked CI, merge·provider 호출 unknown 정직성, 재진입 중복 구현 0 |
| v3.0.5 visible verification | 사람이 읽는 수치와 버전 | summary 생성 block, README·REENTRY·VERIFICATION_MATRIX·CHANGELOG 버전, 실행 결과·parser·manifest·evidence·refactor metrics drift, Write rollback |
| v3.0.6 canary identity | checkpoint·nextAction·repair·invocation·merge 증거 | execution ID/generation/repo root 고정, Operation별 nextAction fail-closed, implementation/repair envelope 분리, 현재 execution invocation만 count, 직접 probe 없는 merge 호출 여부 unknown |
| v3.0.7 canary 마감 | 손상 checkpoint·호출 수·성공 envelope | 손상 JSON bytes 보존과 router 0회, 전체 canary/provider 현재 invocation 분리, success=true와 exitCode=0이 아닌 authoritative evidence의 finalize·merge_ready 차단 |
| v3.0.8 canary schema v4 | checkpoint 객체·worker identity·Operation 3 | null/scalar/array/빈 파일 불변 거부, 누락 reentry 별도 상태, 전체/현재 invocation 호출 증거 분리, case-sensitive worker 일치, authoritative evidence·OPEN Draft·미병합 PR context·CI success gate, direct-main 회귀, result schema 4/checkpoint schema 3 분리 |

## 상태별 기대 판정

| 기능 | 허용 결과 | fail-closed 결과 |
|---|---|---|
| PR preflight | receipt 소유 신규/기존 issue branch | `dirty_worktree`, `base_*`, `work_branch_*`, `remote_sync_unavailable` |
| PR postflight | `pr_opened`, `pr_ci_pending`, `pr_ci_unavailable` | worker/commit/branch/upstream/push/base/artifact/boundary/PR/CI failure, `required_workflow_removed` |
| review | OPEN Draft PR와 current branch/HEAD/head SHA 일치, 모든 파일·diff 청크 coverage | `pr_ci_failed`, unverified recover, dirty/mismatched context, `review_coverage_incomplete` |
| repair | verified run+REPAIR_REQUIRED review, 같은 branch·Draft PR | 다른 mode/branch/HEAD/PR, 새 PR 필요, lock 충돌 |
| recover | receipt에 고정된 mode로 result 또는 Git/PR/CI 확인 | result 부재 시 계속 `recovered_*_unverified` |
| finalize | 최종 PASS, current CI success, 모든 gate 정상 | pending/failed/unavailable, 미검토 repair, unverified/artifact/boundary/context 문제 |

## 하위 호환과 비목표

`direct-main`은 설정 누락 legacy 또는 명시적 rollback mode에서 v2 상태와 계약을 유지한다. 독립 review 전에 main에 들어갈 위험이 있으므로 기본값이 아니다.

`merge_ready`에서도 Draft를 유지하며 병합 완료가 아니다. Ready 전환, 자동 merge, merge queue, branch 삭제, local main fast-forward, rebase, conflict 해결, 여러 이슈의 한 checkout 병렬 mutation은 라우터가 수행하지 않는다.

PR CI 기대 여부는 receipt에 고정된 base/head commit workflow 스냅샷을 사용한다. check는 실제 PR 번호와 head SHA에 연결된 `pull_request` 실행만 인정하고 context별 최신 rerun을 사용한다. push-only 성공, workflow 삭제, PR event 연관성을 증명할 수 없는 legacy status는 fail-closed 한다.

모델 지정은 `config/config.json`을 단일 원본으로 사용한다. `scripts/sync-model-contract.ps1 -Write`는 모든 대상 구조를 먼저 검증한 뒤 6개 Skill frontmatter, README의 Claude·Grok·GPT 생성 표, CI용 합성 Codex model cache, manifest를 갱신하고 일반적인 중간 실패 시 원복한다. `-Check`는 생성물·manifest 정합성, 공유 Skill의 model·effort 충돌, `latest`/family alias를 검사한다. provider의 신규 출시·폐기 발견은 자동 업그레이드가 아닌 `notify-only` 운영 절차다. doctor는 성공한 Grok 목록과 명시한 Codex cache에서 config ID를 진단하지만 실행 게이트가 아니며 Claude 계정 가용성이나 실제 유료 실행 성공도 증명하지 않는다.

## 실행 결과

<!-- verification-visible:start -->
- source-tree 560 passed, 0 failed
- installed fixture 560 passed, 0 failed
- installed integration failures 0
- PowerShell parser files 23, manifest entries 46
- paid model calls 0
<!-- verification-visible:end -->

- 전체 검증 명령은 `tests/run-tests.ps1`과 `tests/run-installed-fixture.ps1`이다.
- 최종 집중 검증은 model contract, visible verification metadata, config·evidence JSON, manifest SHA-256, `git diff --check`를 포함한다.
- 신규 테스트는 fake Git/bare remote, 주입 worker, mock PR/check probe, 합성 model cache와 고유 임시 USERPROFILE만 사용했다.
- 실제 GitHub PR/check 변경은 수행하지 않았다.

상세 수치는 `evidence/source-tree-test-result.txt`에 보존한다.

## 외부 검토 상태

PR #2 외부 비판적 검토에서 추가된 결함 회귀는 전체 suite에 그대로 포함된다. v3.0.3 모델 수명주기 검증에서도 외부 worker나 유료 모델을 호출하지 않는다.
