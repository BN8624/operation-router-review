# SECURITY — operation-router v3.0.0

## Git workflow 방어

- 새 번들의 기본값은 `pull-request`이며 설정 누락은 기존 설치 호환을 위해 `direct-main`으로 해석한다.
- PR mode는 clean worktree, origin, base ref, fetch 결과, local/remote base 동일성, 허용된 시작 branch와 기존 branch 소유권을 fail-closed로 검사한다.
- `baseBranch`와 `branchPrefix`는 안전한 Git ref 구성요소만 허용한다. 공백, 제어 문자, `..`, `~`, `^`, `:`, `?`, `*`, `[`, 역슬래시, 선두·후행 slash, 연속 slash, `.lock` suffix와 shell meta 문자를 거부한다.
- 한 clone의 mutation lock은 run, repair, Claude 직접 실행과 branch 전환을 직렬화한다. watch, status, doctor, terminal receipt 조회는 읽기 전용이다.
- stale lock은 PID만 보고 제거하지 않는다. process 시작 시각, heartbeat, execution receipt와 terminal 여부를 함께 확인한다.
- worker 계약에는 실제 workflow mode, base branch/head, expected work/remote branch, issue number를 넣는다. PR mode worker는 branch·PR·이슈 관리, main push, force push, reset, clean, rebase를 하지 않는다.
- worker의 로컬 검증은 Grok JSON 또는 Codex JSONL의 최종 agent message 안에 있는 엄격한 `[ORH_WORKER_REPORT]`만 증거로 읽는다. 누락·잘못된 스키마·`false`·남은 문제는 최종 PASS나 CI success로 보충하지 않고 `merge_ready`를 차단한다.
- postflight는 current branch, base ref 불변, worker final HEAD의 base 포함 여부, upstream, local/remote work HEAD, worktree, commit, artifact와 watched boundary를 검사한다.

## Draft PR과 CI

- work branch push를 확인한 뒤에만 Draft PR을 생성한다. 같은 repository의 OPEN Draft PR 중 base/head/head SHA가 모두 일치할 때만 재사용한다.
- PR 본문은 마스킹·길이 제한된 요약만 담고 prompt, raw stdout/stderr, 환경 전체, 인증 header, secret, 이슈 원문 전체를 넣지 않는다.
- PR body는 임시 파일로 전달하고 finally에서 삭제한다.
- PR CI는 현재 PR head SHA의 모든 check run과 status context를 집계한다. 첫 check만 보고 성공 처리하지 않는다.
- CI pending, failed, unavailable에서는 `merge_ready`를 만들지 않는다. `not-requested`는 workflow 존재 여부와 `requireCiWhenWorkflowPresent` 정책에 따라 판정한다.
- `merge_ready`는 Draft 해제 상태일 뿐 병합 완료가 아니다. 자동 merge를 호출하지 않는다.

## receipt, progress, artifact

- workflow mode와 base/work/PR context는 pending, execution, run, review, repair receipt에 고정한다. v1 receipt 또는 workflow 누락 receipt는 direct-main legacy로만 읽으며 PR receipt로 추측 변환하지 않는다.
- progress summary는 `Protect-SecretText` 뒤 개행을 정규화하고 최대 500자로 제한한다. prompt·환경 전체·raw 출력·hidden reasoning은 progress journal에 기록하지 않는다.
- watch는 기존 execution과 generation을 읽고 postflight를 재개할 뿐 worker, fallback, review, repair, 새 generation을 시작하지 않는다.
- active 중 prompt와 raw stdout/stderr가 execution artifact root에 일시적으로 존재한다. terminal sanitization이 마스킹본을 만든 뒤 원본을 제거하며 retention은 active와 receipt 참조 generation을 보호한다.

## 정직한 한계

- branch와 PR은 OS sandbox가 아니다.
- worker deny 규칙과 자연어 계약은 우회될 가능성이 있다.
- postflight와 watched-file 검사는 사후 탐지이며 모든 파일 접근·읽기·생성·외부 전송을 막지 못한다.
- GitHub 계정과 token 권한 자체는 operation-router 밖의 별도 신뢰 경계다.
- Draft PR 생성·조회·Draft 해제 권한이 필요하다.
- repository mutation lock은 한 clone 내부 동시성만 제어하며 다른 clone에는 적용되지 않는다.
- base branch가 다른 정상 PR로 전진할 수 있다. 라우터는 worker final HEAD가 base에 포함됐는지를 따로 검사하고, 관련 없는 전진은 `baseAdvanced=true` 경고로 구분한다.
- 대상 프로젝트 workflow가 `pull_request`를 지원해야 하며 operation-router는 Actions, branch protection, ruleset을 자동 설정하지 않는다.
- active artifact에 대한 같은 OS 계정 또는 malware 접근을 별도 암호화나 ACL로 막지 않는다.
