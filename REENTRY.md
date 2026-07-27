# REENTRY — operation-router v3.0.4 pull-request workflow

<!-- verification-summary sourceTreePassed=375 sourceTreeFailed=0 installedFixturePassed=375 installedFixtureFailed=0 -->

## Live E2E canary 정본 절차

`scripts/run-live-canary.ps1`는 `-ConfirmPaidProviderCall`, 별도 `-RepoPath`, `-Operation`, `-IssueNumber`를 모두 명시한 경우에만 router를 실행한다. 인수가 없으면 `LIVE_CANARY_NOT_EXECUTED`와 사용법을 반환한다. 결과 JSON에는 prompt, secret, raw stdout/stderr, 환경 전체를 넣지 않는다. 각 시나리오는 disposable canary 저장소와 전용 이슈에서 실행하고 Draft를 유지하며 자동 merge를 호출하지 않는다.

1. Operation 3 소규모 성공은 작은 기계적 변경 한 건을 커밋·push하고 result envelope, worker report, local verification, Draft PR head SHA와 CI를 대조한다.
2. Operation 2 성공은 구현 완료 뒤 Sonnet 종료 검토를 수행하고 `finalize`에서 PASS, CI success, Draft 유지, `merge_ready=true`를 확인한다.
3. Operation 1 성공은 Grok 구현, Sol review PASS, Opus 종료 검토, `finalize` 순서로 같은 branch와 Draft PR을 유지한다.
4. Operation 1 수리는 Sol review `REPAIR_REQUIRED`, 원 worker repair 1회, Opus 종료 검토, `finalize` 순서와 findings 소거를 확인한다.
5. worker 중단 복구는 실행 세대와 receipt를 보존한 채 새 세션 `recover`가 동일 execution을 이어받고 중복 worker를 시작하지 않는지 확인한다.
6. weekly exhaustion Plan B는 명시적 weekly 분류, usage exhausted/100, clean worktree에서만 다음 provider 전환, 실제 provider 호출 횟수를 확인한다.
7. partial changes 후 fallback 차단은 HEAD 또는 worktree 변경을 남긴 weekly 실패에서 `partial_worker_changes`와 fallback 미호출을 확인한다.
8. CI pending, failure, unavailable 각각에서 `merge_ready=false`, Draft 유지, 자동 merge 미호출을 확인한다.

현재 정본 결과는 `evidence/live-canary-result.json`이다. 별도 canary 저장소와 검증된 provider 인증이 제공되지 않아 이번 작업에서는 실제 유료 canary를 실행하지 않았으며 합성 테스트를 live E2E 통과로 간주하지 않는다.

## 최근 검증

Grok 전수검사와 수정 후 재검토 지적 사항까지 수리한 뒤 정식 source-tree 375개와 고유 임시 USERPROFILE installed fixture 375개가 모두 통과했다. installed integration failure는 0개이며, 저장소의 PowerShell 18개 구문 검사, config JSON 파싱, model contract, manifest 39개 SHA-256, `git diff --check`도 통과했다. 테스트 중 유료 모델 호출과 실제 사용자 홈 변경은 없었다.

## 현재 계약

- 새 번들의 기본 `gitWorkflow.mode`는 `pull-request`다.
- 설정에 `gitWorkflow`가 없는 기존 설치본은 `direct-main` legacy mode로 해석한다.
- 실행 시작 뒤에는 pending/execution/run/review/repair receipt에 저장한 workflow mode와 context를 사용하며 현재 config로 바꾸지 않는다.
- 이슈 하나는 `operation-router/issue-<issueNumber>` branch 하나와 Draft PR 하나를 사용한다. 구현, Operation 1 review, repair는 같은 branch와 PR에서 이어진다.
- 라우터가 base 동기화, branch 생성·선택·소유권, Draft PR, PR CI, receipt, `merge_ready`를 관리한다. worker는 지정 branch에서 수정·테스트·커밋하고 지정 원격 branch에만 push한다.
- 외부 worker의 마지막 `[ORH_WORKER_REPORT]` 또는 Claude-only/direct의 HEAD·operation·issue·work branch 고정 JSON 보고가 유효하고, 로컬 검증 완료가 `true`이며 남은 문제가 없어야 최종 `merge_ready` 자격을 얻는다.
- 한 clone에서는 run, repair, Claude 직접 구현, branch 전환 등 mutation 실행을 하나만 허용한다. watch, status, doctor, terminal receipt 읽기는 mutation lock 중에도 가능하다.
- 방치된 `claude_execute`/`claude-direct` 지시는 `abandon-claude`로만 안전하게 해제한다. PID 부재만으로 lock을 지우지 않으며, pending 누락·비Claude mutation purpose·dirty worktree·HEAD 변경·활성 worker·다른 이슈/clone은 거부한다.
- `run -Detach` → `watch -Follow`/recover 경로의 완료 result envelope는 동기 실행과 같은 구조화 실패 정책을 쓴다. weekly만 usage exhausted·Plan B, 부분 변경 시 반환과 receipt 모두 `partial_worker_changes`, Plan B 2차 실패 분류 보존, PR mode에서도 분류를 `worker_failed`로 붕괴하지 않는다.
- 자동 Draft 해제, 자동 merge, branch 삭제, main fast-forward, rebase, conflict 해결은 없다. `merge_ready`는 병합 완료가 아니며 Draft 상태로 남는다.
- 모델 배치는 `config/config.json`이 단일 원본이다. 새 고정 ID는 동기화 도구로 Skill 6종과 README 표에 반영하며 `latest` alias와 자동 업그레이드는 사용하지 않는다.

```text
run -Detach → watch -Follow → operation_terminal → nextAction → final review → finalize → merge_ready
```

`run -Detach`는 receipt와 progress journal을 만든 뒤 worker-host를 한 번 시작한다. `watch -Follow`는 repository identity, execution ID, generation에 고정되어 worker 종료 뒤 recover/postflight를 한 번 수행한다. checkpoint에서는 같은 execution과 generation의 watch만 반복한다.

Operation 1의 `nextAction`은 `review`, `opus_end_review`, `manual_verification`, `stop`만 허용한다. Operation 2는 `sonnet_end_review`, `stop`만 허용하며 Operation 3은 `report`다. 최종 검토 PASS 뒤 `finalize -ReviewVerdict PASS`가 PR·CI·push·artifact·boundary gate를 통과하면 Draft 유지 상태의 `merge_ready`가 된다.

## recover

v2.4.7부터 run은 watch와 함께 사용한다. recover는 Claude 세션이 이미 종료됐거나 사용자가 나중에 새 세션으로 재진입했고 watch가 없을 때만 사용한다. watch가 살아 있는 동안 recover를 수동 호출하지 않는다.

recover는 새 구현 worker를 임의로 재시작하지 않는다. 정상 실패 envelope가 있으면 동기 경로와 같은 오류 정책(weekly usage·clean Plan B, partial 거부, transient/provider/quota_unknown 구분)을 적용한다. result가 없으면 receipt에 고정된 mode로 Git·PR 사실만 복구한다. PR mode에서는 current branch/HEAD, remote work HEAD, OPEN Draft PR base/head/head SHA와 PR CI까지 확인한다. 정상 result envelope가 없으면 `recovered_pr_*_unverified` 또는 기존 direct-main unverified 상태를 유지하며 Operation 1 review·repair 자격을 만들지 않는다.

PR CI는 preflight에 고정된 base workflow와 final head workflow를 함께 사용한다. base workflow 전체 삭제, push-only check, PR 번호/head SHA 불일치, check 연관성 불명은 성공이 아니다. Operation 1 review는 모든 변경 파일의 모든 diff 청크가 검토된 경우에만 PASS receipt를 만든다.

## 주요 파일

- `scripts/git-workflow.ps1` — 설정 검증, branch preflight, clone mutation lock, Draft PR·PR CI, PR postflight/recover/finalize
- `scripts/run-operation.ps1` — run/watch/recover/review/repair/finalize 상태 전이
- `scripts/common.ps1` — workflow receipt와 실제 값이 포함된 worker 계약
- `scripts/sync-model-contract.ps1` — config 모델 배치와 Skill frontmatter·README 생성 표의 drift 검사·동기화
- `scripts/progress.ps1`, `scripts/worker-host.ps1` — generation 고정 progress와 detached worker
- `config/config.json` — 기본 PR 정책과 polling
- `tests/source-tree.Tests.ps1` — fake Git/bare remote/mock PR probe 기반 v3 회귀

## 모델 교체

공급자의 새 모델 출시·기존 모델 폐기는 자동 변경하지 않고 운영자가 확인한다. 공식 고정 ID를 확인한 뒤 `config/config.json`만 편집하고 아래 순서로 정합성을 만든다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\sync-model-contract.ps1 -Write
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\sync-model-contract.ps1 -Check
```

`-Write`는 쓰기 전에 model policy, effort, Skill frontmatter와 README marker 구조를 모두 검사한다. 유효하면 6개 Skill의 `model`·`effort`, README의 Claude·Grok·GPT 생성 표, CI용 합성 Codex model cache, `manifest-sha256.txt`를 함께 갱신하며 중간 실패 시 이미 쓴 파일을 원복한다. `-Check`는 고정 ID, 공유 Skill 제약, 모든 생성물과 manifest drift를 검사한다. `doctor`는 config에 지정된 Grok/GPT ID를 로컬 CLI 목록·cache와 비교하는 진단이며 실행 게이트가 아니다. 실행 중인 receipt의 model은 config 변경으로 바뀌지 않는다.

## 재검증

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\sync-model-contract.ps1 -Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-installed-fixture.ps1
git diff --check
git rev-list --left-right --count origin/main...HEAD
```

실제 사용자 홈의 설치본이나 runtime state를 쓰지 않고 고유 임시 USERPROFILE fixture를 사용한다. 유료 Grok, GPT, Claude live 호출은 검증에 사용하지 않는다.

## 알려진 한계

- branch와 Draft PR은 OS sandbox가 아니다.
- worker deny 계약은 우회될 수 있고 postflight는 일부 위반을 사후 탐지한다.
- GitHub 계정과 token 권한은 별도 신뢰 경계다.
- repository mutation lock은 한 clone 안에서만 동시 실행을 막는다.
- 공급자 모델 출시·폐기 발견은 `notify-only` 운영 절차다. doctor는 config의 Grok/GPT ID가 로컬 CLI 목록·cache에 있는지 비교하지만 Claude 계정 가용성이나 실제 유료 실행 성공을 증명하거나 모델을 자동 교체하지 않는다.
- 대상 저장소 CI가 `pull_request` event를 지원해야 한다. operation-router가 대상 Actions 설정을 자동 변경하지 않는다.
- active 실행 중 prompt/raw artifact가 일시적으로 존재하며 terminal sanitization 뒤 제거된다.
