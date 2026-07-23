# SECURITY — operation-router v2.4.7

## 방어 계층

- 고정 실행 계약은 main 전용, branch/PR·force push·reset hard·clean 금지, clean worktree, 논리 커밋·즉시 push, secret 미출력을 worker에게 전달한다.
- Grok deny 목록은 위험 명령의 1차 방어다. 완전한 sandbox가 아니며 패턴 우회 가능성이 있다.
- GPT worker는 `workspace-write`, `approval_policy=never`를 사용하며 push용 network access만 연다.
- watched critical-file 검사는 선택된 전역 설정과 operation-router의 config/scripts/skills 변경·삭제를 사후 탐지한다. OS sandbox가 아니다.
- review/repair는 verified Grok run, 정상 result envelope, repository identity, HEAD, REPAIR_REQUIRED receipt를 fail-closed로 검증한다.

## progress와 watch

- progress summary는 `Protect-SecretText` 적용 뒤 개행을 공백으로 정규화하고 최대 500자로 제한한다.
- prompt·이슈 원문·환경 전체·Authorization·API token·raw stdout 전체·hidden reasoning은 progress journal에 기록하지 않는다.
- generation별 lock 파일과 UTF-8 BOM 없는 한 줄 JSON append를 사용한다. lock 실패는 worker를 실패시키지 않고 마스킹된 runtime log에만 남긴다.
- `maxJournalBytes` 초과 시 상세 이벤트는 `progress_suppressed` 한 번으로 억제하지만 heartbeat, worker exit, sanitization, postflight, terminal은 계속 기록한다.
- watch는 읽기·표시와 기존 recover/postflight 재개만 수행한다. worker 호출, fallback 시작, 새 generation, review/repair, Git reset/stash/clean은 수행하지 않는다.
- owner/repository canonical root hash, execution ID, generation을 고정하고 중간 교체는 `watch_generation_changed`로 중단한다.
- watch를 종료해도 worker는 종료되지 않는다. 다시 실행하면 같은 receipt와 progress journal에 attach한다.

## artifact 수명

- active worker가 실행되는 동안 prompt와 raw stdout/stderr가 execution artifact root 안에 일시적으로 존재한다.
- terminal sanitization은 마스킹된 stdout/stderr를 만든 뒤 prompt/raw를 제거한다.
- terminal retention은 모든 최신 receipt가 참조하는 generation과 active/incomplete generation을 보호한다.

## 알려진 한계

- watched-file 검사는 비감시 파일 접근·읽기·생성·외부 전송을 차단하지 못한다.
- progress는 observable activity이지 worker reasoning, 의도, 품질 증명이 아니다.
- heartbeat는 process 생존과 마지막 관찰 상태를 말할 뿐 worker가 무엇을 생각하는지 보여주지 않는다.
- Grok streaming이 확인되지 않으면 command 단위 가시성이 제한된다.
- active artifact에 대한 로컬 계정·malware 접근을 별도 암호화나 OS ACL로 막지는 않는다.
