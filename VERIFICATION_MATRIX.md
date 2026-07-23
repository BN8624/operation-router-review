# VERIFICATION_MATRIX — operation-router v3.0.0

현재 실행 계약은 `run -Detach` → `watch -Follow` → `operation_terminal` → `nextAction` → final review → `finalize` 순서다. recover는 watch가 없는 새 세션 재진입에만 사용한다.

## 검증 원칙

- source tree의 정식 `tests/run-tests.ps1`을 Windows PowerShell 5.1과 Pester 3.4 strict mode로 실행한다.
- fake Git repository와 bare remote, 주입 worker, mock PR probe, 격리 process와 고유 임시 USERPROFILE만 사용한다.
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
| 25–34 | Draft PR | push 뒤 생성, 정확한 OPEN Draft 재사용, base/head/repository/state/Draft 불일치 차단, 생성 실패, body 마스킹·임시 파일 정리 |
| 35–42 | PR CI | 모든 success, failure 우선, pending, neutral/skipped/unknown, no-check 정책, API 오류, 전체 check 집계 |
| 43–50 | receipt/review/repair/recover | workflow round-trip, v1 legacy, mode pin, branch/PR SHA review gate, 같은 PR repair, 새 PR 금지, unverified recover |
| 51–57 | finalize | PASS+CI success만 merge_ready, pending/failed/unavailable·repair 미검토·boundary/artifact/local verification 차단, ready만 호출 |
| 58–68b | direct-main와 안전 회귀 | 정상 run, fallback, review, repair, recover, watch-first, sanitization, retention, clone 격리, UTF-8 stdin, 기존 mock 유지, installed fixture 실제 홈 cache 비참조 |

## 상태별 기대 판정

| 기능 | 허용 결과 | fail-closed 결과 |
|---|---|---|
| PR preflight | receipt 소유 신규/기존 issue branch | `dirty_worktree`, `base_*`, `work_branch_*`, `remote_sync_unavailable` |
| PR postflight | `pr_opened`, `pr_ci_pending`, `pr_ci_unavailable` | worker/commit/branch/upstream/push/base/artifact/boundary/PR/CI failure |
| review | OPEN Draft PR와 current branch/HEAD/head SHA 일치 | `pr_ci_failed`, unverified recover, dirty/mismatched context |
| repair | verified run+REPAIR_REQUIRED review, 같은 branch·Draft PR | 다른 mode/branch/HEAD/PR, 새 PR 필요, lock 충돌 |
| recover | receipt에 고정된 mode로 result 또는 Git/PR/CI 확인 | result 부재 시 계속 `recovered_*_unverified` |
| finalize | 최종 PASS, current CI success, 모든 gate 정상 | pending/failed/unavailable, 미검토 repair, unverified/artifact/boundary/context 문제 |

## 하위 호환과 비목표

`direct-main`은 설정 누락 legacy 또는 명시적 rollback mode에서 v2 상태와 계약을 유지한다. 독립 review 전에 main에 들어갈 위험이 있으므로 기본값이 아니다.

`merge_ready`는 Draft 해제이며 병합 완료가 아니다. 자동 merge, merge queue, branch 삭제, local main fast-forward, rebase, conflict 해결, 여러 이슈의 한 checkout 병렬 mutation은 검증 대상도 구현 대상도 아니다.

## 실행 결과

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1`
  - 종료 코드 0, 912.15초
  - 318 passed, 0 failed, 0 skipped, 0 pending, 0 inconclusive
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-installed-fixture.ps1`
  - 종료 코드 0, 907.03초
  - source tree 318 passed, 0 failed, 0 skipped, 0 pending, 0 inconclusive
  - installed integration 실행, Skill 6종 byte-equivalence 실패 0
- 최종 집중 검증
  - 재현성·manifest 22 passed, Skill watch-first 4 passed, 문서 흐름 1 passed
  - PowerShell 15개 파일 구문 검사, config JSON 파싱, manifest 34개 SHA-256, `git diff --check` 통과
- 신규 테스트는 fake Git/bare remote, 주입 worker, mock PR/check probe, 합성 model cache와 고유 임시 USERPROFILE만 사용했다.
- 실제 GitHub PR/check 변경과 유료 Grok·GPT·Claude 호출은 0회다.

상세 수치는 `evidence/source-tree-test-result.txt`에 보존한다.

## 외부 검토 상태

사용자 지시에 따라 다른 Grok, Claude, Codex worker나 하위 agent를 호출하지 않았다. 별도 외부 AI review는 미실행이다.
