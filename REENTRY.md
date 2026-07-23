# REENTRY — operation-router v3.0.0 pull-request workflow

## 현재 계약

- 새 번들의 기본 `gitWorkflow.mode`는 `pull-request`다.
- 설정에 `gitWorkflow`가 없는 기존 설치본은 `direct-main` legacy mode로 해석한다.
- 실행 시작 뒤에는 pending/execution/run/review/repair receipt에 저장한 workflow mode와 context를 사용하며 현재 config로 바꾸지 않는다.
- 이슈 하나는 `operation-router/issue-<issueNumber>` branch 하나와 Draft PR 하나를 사용한다. 구현, Operation 1 review, repair는 같은 branch와 PR에서 이어진다.
- 라우터가 base 동기화, branch 생성·선택·소유권, Draft PR, PR CI, receipt, `merge_ready`를 관리한다. worker는 지정 branch에서 수정·테스트·커밋하고 지정 원격 branch에만 push한다.
- 외부 worker의 마지막 `[ORH_WORKER_REPORT]` 또는 Claude-only/direct의 HEAD·operation·issue·work branch 고정 JSON 보고가 유효하고, 로컬 검증 완료가 `true`이며 남은 문제가 없어야 최종 `merge_ready` 자격을 얻는다.
- 한 clone에서는 run, repair, Claude 직접 구현, branch 전환 등 mutation 실행을 하나만 허용한다. watch, status, doctor, terminal receipt 읽기는 mutation lock 중에도 가능하다.
- 자동 Draft 해제, 자동 merge, branch 삭제, main fast-forward, rebase, conflict 해결은 없다. `merge_ready`는 병합 완료가 아니며 Draft 상태로 남는다.

```text
run -Detach → watch -Follow → operation_terminal → nextAction → final review → finalize → merge_ready
```

`run -Detach`는 receipt와 progress journal을 만든 뒤 worker-host를 한 번 시작한다. `watch -Follow`는 repository identity, execution ID, generation에 고정되어 worker 종료 뒤 recover/postflight를 한 번 수행한다. checkpoint에서는 같은 execution과 generation의 watch만 반복한다.

Operation 1의 `nextAction`은 `review`, `opus_end_review`, `manual_verification`, `stop`만 허용한다. Operation 2는 `sonnet_end_review`, `stop`만 허용하며 Operation 3은 `report`다. 최종 검토 PASS 뒤 `finalize -ReviewVerdict PASS`가 PR·CI·push·artifact·boundary gate를 통과하면 Draft 유지 상태의 `merge_ready`가 된다.

## recover

v2.4.7부터 run은 watch와 함께 사용한다. recover는 Claude 세션이 이미 종료됐거나 사용자가 나중에 새 세션으로 재진입했고 watch가 없을 때만 사용한다. watch가 살아 있는 동안 recover를 수동 호출하지 않는다.

recover는 새 worker를 호출하지 않고 receipt에 고정된 mode를 사용한다. PR mode에서는 current branch/HEAD, remote work HEAD, OPEN Draft PR base/head/head SHA와 PR CI까지 확인한다. 정상 result envelope가 없으면 `recovered_pr_*_unverified` 또는 기존 direct-main unverified 상태를 유지하며 Operation 1 review·repair 자격을 만들지 않는다.

PR CI는 preflight에 고정된 base workflow와 final head workflow를 함께 사용한다. base workflow 전체 삭제, push-only check, PR 번호/head SHA 불일치, check 연관성 불명은 성공이 아니다. Operation 1 review는 모든 변경 파일의 모든 diff 청크가 검토된 경우에만 PASS receipt를 만든다.

## 주요 파일

- `scripts/git-workflow.ps1` — 설정 검증, branch preflight, clone mutation lock, Draft PR·PR CI, PR postflight/recover/finalize
- `scripts/run-operation.ps1` — run/watch/recover/review/repair/finalize 상태 전이
- `scripts/common.ps1` — workflow receipt와 실제 값이 포함된 worker 계약
- `scripts/progress.ps1`, `scripts/worker-host.ps1` — generation 고정 progress와 detached worker
- `config/config.json` — 기본 PR 정책과 polling
- `tests/source-tree.Tests.ps1` — fake Git/bare remote/mock PR probe 기반 v3 회귀

## 재검증

```powershell
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
- 대상 저장소 CI가 `pull_request` event를 지원해야 한다. operation-router가 대상 Actions 설정을 자동 변경하지 않는다.
- active 실행 중 prompt/raw artifact가 일시적으로 존재하며 terminal sanitization 뒤 제거된다.
