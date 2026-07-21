# SECURITY — operation-router

라우터가 외부 워커 CLI(Grok/Codex)와 Claude 서브에이전트에게 GitHub 이슈를 위임해 코드를 구현·커밋·push하는 구조에서의 보안 경계와 방어층. 1인 사용 환경 기준.

## 위협 모델

- 워커 CLI가 주문서 범위를 벗어나 저장소 밖(전역 설정·홈·다른 저장소)을 수정.
- 워커가 위험 명령(force push, 히스토리 재작성, 대량 삭제, 시스템 명령)을 실행.
- 로그·검토 증거·workerSummary에 secret(토큰·키·Authorization) 노출.
- 워커가 전역 규칙을 읽고 다른 CLI로 재위임하거나 자기검수로 판정을 뒤집음.

## 방어층 (다중)

### 1. watched critical-file 사후 무결성 검사
`Get-StartSnapshot`이 선택한 critical file의 상대 경로·존재 여부·SHA-256을 기록하고, postflight `Test-RepoBoundaryViolation`이 추가·수정·삭제를 재검사한다. 대상은 전역 `.gitconfig`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, 라우터 `operation-router.cmd`, `config/**/*.json`, `scripts/**/*.ps1`, `skills/**/SKILL.md`, 설치된 `~/.claude/skills/operation*/SKILL.md`다. 변경 시 호환 상태 `repo_boundary_violation`으로 보고하고 CI를 조회하지 않는다. 이는 선택 파일의 **사후 탐지**이며 OS sandbox나 포괄적 저장소 경계가 아니다. (`scripts/prepare-operation.ps1`, `scripts/postflight.ps1`)

### 2. deny 블록리스트 — 1차 차단 (보조)
Grok 헤드리스 `--deny`가 명백한 위험 명령을 1차 차단한다(reset --hard/merge/keep, force push, `+main` refspec, rm 계열, rmdir/rd /s, format, diskpart, shutdown, reg delete). **한계**: 패턴 매칭이라 우회 가능하고 Grok 워커에만 적용된다. watched-file 검사도 이 우회를 사전에 차단하지 못한다. (`config/config.json` `grok.headlessPermissions.deny`, `_deny_note`)

### 3. 고정 실행 계약
모든 주문서 앞에 `[OPERATION_ROUTER_FINAL_WORKER]` 마커 + 계약이 붙는다: main에서만 작업, branch/PR 금지, force push·reset --hard·clean 금지, 시작 시 worktree clean, 커밋 메시지는 한 줄 인라인만(명령 치환·heredoc 금지 — 헤드리스 권한 정책이 차단), 이슈 비개입, secret·환경변수 출력 금지, 다른 CLI 재위임 금지. (`scripts/common.ps1` `Get-FixedExecutionContract`)

### 4. 전역 규칙
`~/.claude/CLAUDE.md`·`~/.codex/AGENTS.md`에서 수동 Operation Modes를 삭제해, 워커 CLI가 AGENTS.md에서 "grok에 위임" 지시 자체를 발견하지 못한다. 최종 작업자 예외는 마커 세션에만 적용되고 task canon·Git·보고 규칙은 유지한다.

### 5. GPT 샌드박스
Codex는 `-s workspace-write`(작업 디렉터리 밖 쓰기 차단) + `approval_policy=never`. origin push를 위해 `sandbox_workspace_write.network_access=true`만 허용. (`scripts/invoke-gpt.ps1`)

### 6. 검수 독립성
GPT가 구현한 작전 1 결과는 sol 자기검수를 하지 않는다(`review_not_eligible`). 유효한 Grok 완료 영수증, 정상 result envelope, review 가능한 provenance, 동일 owner/root 저장소, HEAD 일치가 모두 필요하다. result 유실 recover는 unverified 진단 receipt만 남고 GPT review를 호출하지 않는다. 검수 JSON은 fail-closed 엄격 검증한다.

### 7. repair receipt 불변식
review와 repair는 같은 verified run provenance helper를 사용한다. repair는 정상 Grok run receipt와 비어 있지 않은 엄격 findings를 가진 REPAIR_REQUIRED review receipt가 모두 있어야 하며, 두 receipt의 저장소·worker·HEAD 연결을 core 함수에서 다시 검증한다. 수동 `PostReviewHead`·`FindingsFile`·`Target`은 receipt assertion일 뿐 대체값이 아니며 불일치는 worker 호출 전에 차단한다. provenance 필드가 없는 legacy receipt도 추측하지 않는다.

## 강제 방어층이 아닌 것 — 자연어 호출 soft confirmation policy

operation-1/2/3의 `disable-model-invocation: false`로 모델이 자연어 지시로 Skill을 호출할 수 있다. 이때 실행 전에 예상 워커·비용을 한 줄로 확인받는 절차는 **모델이 따르는 사용성·오작동 방지 정책(soft policy)이며, 라우터 코드가 강제하는 보안 게이트가 아니다.** 별도 확인 토큰·`-Confirmed` 인수 시스템은 두지 않는다. 슬래시 명령 직접 입력은 명시적 실행으로 간주해 확인을 생략한다. 이 정책은 위 7개 강제 방어층에 포함되지 않는다.

## Secret 보호

- **마스킹**(`Protect-SecretText`): gh/sk/xai/AWS 키, `key=value` 형태, Bearer, Authorization 헤더(임의 스킴), 고엔트로피 토큰(Shannon 엔트로피). git SHA·UUID·순수 숫자는 오탐 제외.
- active execution 동안만 worker 입력용 `prompt.txt`와 raw stdout/stderr를 둔다. terminal finalization은 마스킹된 `stdout.log`·`stderr.log`를 만든 뒤 raw와 prompt 원문을 삭제하고 receipt에는 `promptHash`와 삭제 사실만 남긴다.
- 모든 runtime log, workerSummary, verification 문자열, recover 요약과 sanitization 오류에 마스킹을 적용한다. 변환·삭제 실패는 `artifact_sanitization_failed`, retention 실패는 `artifact_retention_failed`로 성공과 구분한다.
- 모든 최신 execution receipt가 참조하는 generation, active generation, marker가 없거나 terminal 여부가 불명확한 generation은 retention에서 보호한다. `executionRetentionCount=10`은 보호되지 않은 terminal generation의 추가 보존 수이며 보호 항목 때문에 실제 보존 수가 10을 초과할 수 있다. receipt 보호 집합을 완전히 계산·검증할 수 없으면 아무것도 삭제하지 않고 `artifact_retention_failed`로 보고한다.
- 환경변수 전체 덤프 코드 없음(개별 참조만).
- 검토 ZIP·저장소에 실제 usage-state·인증 정보·원본 모델 세션 JSONL 미포함. manifest 검토 대상에 secret 형태 없음(테스트로 강제).

## 알려진 한계

- deny 블록리스트는 우회 가능하며 watched-file 검사는 이를 사전에 차단하지 않는다.
- watched-file 검사는 감시 목록 밖 파일 접근·생성·수정·읽기·외부 전송, 다른 저장소 변경을 탐지하거나 차단하지 못한다. Grok 경로에는 OS-level workspace sandbox가 없다.
- 고엔트로피 마스킹은 대/소/숫자 혼합 24자+만 대상. 그 밖 형태의 secret은 놓칠 수 있다.
- active worker가 실행 중인 동안에는 CLI 입력에 필요한 prompt와 부분 출력용 raw 파일이 존재한다. 해당 기간의 로컬 계정·디스크 접근 위험까지 제거하는 암호화 저장소는 제공하지 않는다.
- Grok의 중간 와일드카드 deny 패턴(`git push*+*`) 실제 발동은 유료 live probe로 재검증하지 않았다.

## 롤백

이 저장소는 자동 설치·업그레이드·백업·롤백 스크립트를 제공하지 않는다. 기존 작업 과정에서 **수동으로 생성된** `~/.claude/backups/` 백업이 있는 경우에만 해당 사본을 `~/.claude/operation-router` 및 스킬 경로로 복원할 수 있다. 백업이 없는 설치본은 자동 복구되지 않는다. 과거에 수동 생성된 예시(`operation-router.bak.<timestamp>`, `global-rules.bak.<timestamp>`)는 역사적 참고일 뿐, 현재 버전이 이런 백업을 자동 생성한다는 의미가 아니다.
