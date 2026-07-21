# operation-router (v2.4.4)

Claude Code 전역 작전 라우터. GitHub 이슈를 작전 1/2/3으로 Grok CLI / Codex CLI(GPT) / Claude 중 하나에게 라우팅한다. 모델 ID·CLI 옵션·Skill frontmatter 지원은 설치본에서 실측했다. 작전 1/2/3의 실전 E2E와 실패·격리 경로의 mock 검증은 [VERIFICATION_MATRIX.md](VERIFICATION_MATRIX.md)에, 방어층은 [SECURITY.md](SECURITY.md)에, 변경 이력은 [CHANGELOG.md](CHANGELOG.md)에 있다.

## v2.4.x에서 실제 구현된 것 (요약)

- **장시간 실행 영속화·중단 복구**: 작전 1·2·3의 Grok/GPT 구현 호출 전에 저장소별 실행 세대 영수증과 runtime log를 만들고, 독립 `worker-host.ps1`이 stdout/stderr·heartbeat·result를 지속 저장한다. 같은 저장소·작전·이슈의 활성 세대는 새 worker를 호출하지 않는다. 세션이 끊기면 `/operation recover <작전번호> <이슈번호>`가 worker 재호출 없이 프로세스/result/Git/CI/postflight를 확인한다. 외부 중단 복구 상태와 `localVerificationComplete`는 일반 완료·CI 성공과 분리한다.
- **저장소 경계 탐지 (실질 방어)**: `Get-StartSnapshot`이 저장소 밖 민감 경로(전역 `.gitconfig`, `CLAUDE.md`, `AGENTS.md`, 라우터 `config.json`·`common.ps1`)의 SHA-256을 시작 시 스냅샷하고, `Test-RepoBoundaryViolation`이 실행 후 재검사한다. 변경 시 `status: repo_boundary_violation`으로 승격한다. v2.4.1에서 공통 `Complete-BoundaryFinalizer`를 모든 종료 경로(조기 반환 포함)에 적용하고, v2.4.2에서 run·review 영수증도 finalizer 확정 후 저장·차단해 보안 위반 run/review가 내부적으로 성공 영수증으로 남지 않게 했다. 명령 패턴이 아니라 결과 변경을 잡으므로 플래그 재배열·래퍼·동의어 우회에 강하다.
- **deny 1차 차단 확장**: Grok 헤드리스 `--deny` 목록을 위험 명령까지 확장했다(reset --merge/--keep, `+main` 강제 push refspec, `rm` 플래그 분리형, rmdir/rd /s, format, diskpart, shutdown, reg delete 등). 패턴 블록리스트는 취약하고 Grok 워커에만 적용되므로 1차 차단이며, 실질 방어는 위의 경계 탐지다(config `_deny_note`).
- **정책 A/B/C**: operation-1/2/3 자연어 호출 허용 + soft confirmation policy(코드 강제 게이트 아님), 작전 1 Claude-only effort high, 작전 1 고위험 경고. secret 마스킹 강화(Authorization/AWS/고엔트로피, SHA·UUID 오탐 제외).

## v2.3.5에서 실제 구현된 것 (v2.3.4 대비)

- **최종 작업자 식별**: 고정 실행 계약의 첫 줄을 ASCII 마커 `[OPERATION_ROUTER_FINAL_WORKER]`로 고정한다. 마커가 있는 세션은 라우터가 이미 선택한 최종 작업자이며 Grok·Codex·Claude 등 다른 CLI를 점검·호출·재위임하지 않는다.
- **전역 규칙 예외**: 설치 환경의 `CLAUDE.md`와 `AGENTS.md`에 동일한 마커 예외가 있어야 한다. 예외은 마커가 있는 최종 작업자 세션에서만 Operation 1/2/3 재위임 규칙을 비활성화하며 task canon·Git·test·push·reporting 규칙은 유지한다.
- **UTF-8 stdin 보존**: 작업자 stdin 전달을 PowerShell 파이프라인이 아닌 `System.Diagnostics.Process`로 수행한다. 주문서 파일의 원시 UTF-8 바이트(파일 BOM 제거)를 자식 stdin에 직접 기록하고 기록 후 stdin을 명시적으로 닫으며, stdout·stderr·exit code를 각각 수집한다. PS 5.1 파이프라인과 .NET Process 기본 stdin writer가 콘솔 CP 65001에서 BOM(EF BB BF)을 선두에 삽입하는 결함을 실측으로 확인했고, `Console.InputEncoding`을 Start 전후로 BOM 없는 UTF-8로 교체·원복해 차단한다. 한글 계약·한글 경로·마커 첫 바이트 보존을 바이트 단위로 회귀 테스트한다.
- **정책 불변**: 라우팅·모델·effort·권한·fallback과 v2.3.4의 runtime/test 로그 격리 정책은 변경하지 않았다.

## v2.3.4에서 실제 구현된 것 (v2.3.3 대비)

- **로그 네임스페이스 격리**: 새 실전 로그는 `logs/runtime/`, mock 로그는 실행별 `logs/tests/<test-run-id>/`에만 기록한다. 회전과 정리도 각 네임스페이스 안에서만 동작하며, v2.3.3의 기존 평면 `logs/*.log` 증거는 이동·수정·회전하지 않는다.
- **삭제 경로 검증**: 회전·test cleanup 직전에 정규화된 대상이 지정 로그 루트 자신 또는 디렉터리 구분자 경계 안의 자식인지 검사한다. 문자열 prefix만 같은 형제 경로는 거부한다.
- **독립 source-tree 테스트**: `tests/run-tests.ps1`은 `-RootPath`, `-SkillsPath`, `-StatePath`, `-LogRoot`를 지원한다. 기본 상태·로그·pending·temp는 고유한 시스템 임시 루트에 만들며 실제 사용자 usage-state와 실전 로그를 읽거나 수정하지 않는다. Skill 검사는 기본적으로 source tree의 `skills/`를 사용하고, 설치본 검사는 `-InstalledIntegration`을 명시한 경우에만 수행한다.
- **자체 완결 검토본**: 검토 ZIP은 README, config, scripts, 6개 Skill, tests/fixture, REENTRY, `manifest-sha256.txt`를 포함한다. manifest는 자기 자신을 제외한 검토 대상 파일의 SHA-256을 기록하고 ZIP 자체 SHA-256은 외부 완료 보고에 별도로 기록한다.
- **정책 정합성**: Grok 권한 모드는 `alwaysApprove`이며 deny 규칙이 자동 승인보다 우선한다. `dontAsk`는 PermissionCancelled를 일으킨 폐기된 과거 모드다. stdin NUL 고정, JSON stopReason 분류, Codex `approval_policy` 설정, 작업자의 다른 CLI 재위임 금지 계약을 현재 코드와 동일하게 문서화한다.

## v2.3.1에서 실제 구현된 것 (역사 기록)

- **shell 독립 실행기**: `%USERPROFILE%\.claude\operation-router\operation-router.cmd`가 Windows PowerShell 5.1로 `scripts\run-operation.ps1`을 호출한다. Skill 6종은 이 `.cmd`만 사용하며 PowerShell의 `$env:USERPROFILE`과 Git Bash의 `$USERPROFILE` 경로를 모두 명시한다. 이슈번호는 `$0`, 보조 명령은 `$ARGUMENTS`를 명시적으로 사용한다.
- **공통 워커 오류 정책**: 최초 작업자·fallback·review·repair가 모두 `Invoke-WorkerWithErrorPolicy`를 사용한다. `weekly_exhausted`만 해당 공급자를 exhausted/100으로 저장하고, `transient_rate_limit`은 상태 변경 없이 최대 1회 재시도하며, `provider_failure`·일반 실패는 fallback 없이 중단한다.
- **연속 fallback**: clean 저장소에서 Grok weekly → GPT Plan B를 수행하고, GPT도 weekly면 GPT exhausted/100 저장 후 Claude-only 또는 Claude direct로 이어진다. GPT가 부분 변경을 남기면 `partial_worker_changes`로 중단한다. 공급자별 fallback 1회 가드로 반복 진입을 차단한다.
- **review·repair 상태 반영**: GPT review weekly는 GPT 상태 저장 후 `claude_review_fallback`, repair weekly는 해당 공급자 상태 저장 후 `repair_quota_exhausted`다. transient/provider/general/quota_unknown은 각각 별도 상태이며 사용량 상태를 바꾸지 않는다.
- **주간 소진 패턴 축소**: `quota exceeded`, `you have exceeded your current quota`, `usage limit reached`는 `quota_unknown`이다. 분류 우선순위는 코드와 동일하게 weekly → transient → quota_unknown → provider다. 명시적 weekly 문구는 429가 함께 있어도 `weekly_exhausted`이며, weekly 문구 없이 일반 quota 문구와 429가 함께 있으면 `transient_rate_limit`이 quota_unknown보다 우선한다. 명시적인 weekly 문구만 exhausted/100을 만든다.
- **검증**: 기존 121개 mock 테스트에 필수 15개를 추가해 총 136개다. 실제 Grok·GPT·Claude 유료 호출 없이 fake Git 저장소와 주입 runner만 사용한다.

## v2.3에서 실제 구현된 것 (v2.2 대비)

- **Claude-only 전용 Skill 2종**: `/operation-1-claude <이슈번호>`(claude-sonnet-5 / medium), `/operation-3-claude <이슈번호>`(claude-sonnet-5 / low). 작전 1과 작전 3 logic의 `claude_only_required` resumeCommand가 이 전용 Skill을 가리킨다(요구 모델과 Skill frontmatter 모델이 구조적으로 일치). 작전 2는 기존 `/operation-2 <n> --claude-only`, 작전 3 mechanical은 기존 Haiku `claude_direct` 유지. 전용 Skill은 `-ClaudeOnly` run → `orderPath` 구현 → 커밋·push → `postflightCommand` 실행 → 결과 보고만 한다.
- **quota 오류 3분류**: `weeklyExhaustedPatterns`(주간 플랜 소진)만 usage-state를 exhausted/100으로 바꾸고 Plan B로 전환한다. `transientRateLimitPatterns`(429류)는 usage-state를 변경하지 않고 config(`transientRetry`, 기본 5초 후 최대 1회) 재시도 후에도 실패면 `transient_rate_limited`로 중단한다 — 다른 공급자로 넘기지 않는다. `providerFailurePatterns`(인증·결제·권한·모델)는 일반 실패로 중단한다. 기존 "rate limit exceeded → exhausted" 경로를 제거했다.
- **최종 HEAD의 모든 workflow run 집계**: 첫 run만 보던 `$match[0]` 코드를 제거했다. 하나라도 failure/cancelled/timed_out/startup_failure → `failure`, 실패 없고 하나라도 미완 → `pending`, 하나 이상 존재하고 전부 completed/success → `success`. run 없음 → 기존 polling, API 오류 → `unavailable`.
- **런타임 상태 네임스페이스**: pending·run/review 영수증·주문서를 `state/pending/<owner__repo>/`(origin 없으면 `local-<repoRoot 해시>/`)로 분리한다. 모든 영수증에 ownerRepo·canonical repoRoot·operation·issueNumber·startHead/finalHead를 저장하고, review/repair/postflight에서 현재 저장소와 다르면 `repository_receipt_mismatch`로 중단한다. 서로 다른 저장소가 같은 이슈 번호를 써도 덮어쓰지 않는다.
- **review 실행 자격 코드 강제**: 작전 1 + 영수증 worker=grok + run 상태 completed/completed_ci_pending/completed_ci_unavailable + 같은 저장소 + 현재 HEAD=영수증 finalHead가 아니면 GPT를 호출하지 않고 `review_not_eligible`로 중단한다. GPT가 구현한 작전 1 결과는 Sol 자기검수 없이 현재 Opus가 직접 종료 검토한다. repair도 작전 1 + 유효한 REPAIR_REQUIRED review 영수증을 강제한다(`repair_not_eligible`).
- **경로 이식성**: 모든 Skill에서 특정 사용자 폴더 하드코딩을 제거하고 `$env:USERPROFILE\.claude\operation-router\...`를 정본으로 쓴다. 설치본과 외부 검토본이 동일하다.
- **postflight 효율**: worker_failed/quota_exhausted/no_commit 등 Git·커밋·push 게이트에서 이미 실패가 확정되면 CI를 조회하지 않는다(최대 60초 polling 생략). 이때 ciStatus는 `not-checked`로 정직하게 남긴다.

## v2.2에서 실제 구현된 것 (v2.1 대비)

- **작전 1 실행 영수증 자동 저장**: 작전 1 `run`이 워커 postflight까지 도달하면 `state/pending/op1-issue<n>-run.json`에 operation/issueNumber/startHead/finalHead/worker/model/effort/postflight/workerSummary/createdAt을 저장한다.
- **review 영수증 자동 복원**: `-Command review -Operation 1 -IssueNumber <n>` 만으로 검수가 실행된다. `-StartHead` 수동 입력이 필요 없다. 영수증이 없으면 `review_receipt_missing`, 현재 HEAD ≠ 영수증 finalHead면 `review_receipt_head_mismatch`로 중단한다.
- **검수 프롬프트에 실제 완료 자료 포함**: 이슈 원문·시작/최종 HEAD·변경 파일·diff·작업자(worker/model/effort)·worker 종료코드·commitCount·branch·ahead/behind·worktreeClean·pushComplete·ciStatus·remainingProblems·workerSummary. 라우터는 테스트를 재실행하지 않으므로 테스트 관련 자료는 `workerSummary`(작업자 자기 보고)로 정직하게 표시한다.
- **GPT 검수 호출 실패 처리**: JSON 파싱 전에 ExitCode/Success/QuotaExhausted/Output을 확인한다. quota → `claude_review_fallback`, 일반 실행·인증·네트워크 실패 → `review_worker_failed`, 종료코드 0 + 잘못된 JSON → `review_parse_failed`(fail-closed). 실행 실패를 코드 결함 finding으로 위장하지 않는다.
- **검수 JSON 엄격 검증**: 모든 finding에 severity(blocker|high|medium)/file(string)/비어 있지 않은 issue/비어 있지 않은 requiredFix를 요구한다. `PASS + findings 존재`, `REPAIR_REQUIRED + findings 없음`, 알 수 없는 severity는 전부 잘못된 응답이며 fail-closed(`review_parse_failed`)다.
- **수리 판정 정직화**: 재검수를 하지 않으므로 수리 성공은 `repair_completed_review_pending`으로 반환한다(repairAttempted/repairPostflight/originalFindingCount/finalReviewRequired 포함). 원래 findings를 "남은 findings"라고 부르지 않는다. 실패는 `repair_worker_failed`/`repair_quota_exhausted`/`repair_postflight_failed`로 구분한다. 최종 PASS 판정은 현재 Opus의 종료 검토에서만 한다.
- **수리 작업자 사용량 준수**: 수리 시 usage-state를 다시 읽는다. Grok exhausted면 Grok 수리 금지, GPT 80%+/reserved/exhausted면 GPT 수리 금지, 검수 예비분은 수리에 사용하지 않는다. 사용할 작업자가 없으면 `repair_worker_unavailable`로 중단하고 다른 작업자로 몰래 교체하지 않는다.
- **repair 인수 자동 복원**: `-Command repair -Operation 1 -IssueNumber <n>` 만으로 실행된다. `-PostReviewHead`/`-FindingsFile`/`-Target`은 run/review 영수증에서 자동 복원된다(명시 인수가 있으면 우선). 영수증이 없으면 `repair_receipt_missing`.
- **CI run 생성 지연 처리**: 워크플로 파일(`.github/workflows/*.yml|yaml`)이 있는 저장소에서는 10초 간격 최대 6회(config.ciPolling) polling한다. 워크플로 없음 → `not-requested`(API 호출 없음). 워크플로 있음 + polling 종료까지 run 미발견 → `unavailable`(`not-requested`/`completed`로 위장하지 않음). API 오류 → `unavailable`.
- **Skill 실행 절차 명문화**: operation-1은 run→review→repair→종료검토 실제 순서로 다시 썼고, operation-1/2/3 모두에 `claude_only_required`(resumeCommand 안내 후 중단)와 `claude_execute`/`claude-direct`(orderPath 수행→커밋·push→postflightCommand 실행→postflight 결과 보고) 분기를 명시했다.

## v2.1에서 실제 구현된 것 (v2 대비)

- `--claude-only`가 실제 동작한다: 워커 재라우팅 없이 현재 세션이 고정 실행 계약+이슈 원문을 직접 수행하고, 같은 postflight를 돌린다. `claude_only_required`를 반복 반환하는 무한 루프를 제거했다.
- 작전 3 `mechanical`의 `claude_direct`도 실제 실행 흐름으로 연결된다.
- 작전 1 `review`가 실제 검수 입력(이슈 원문·startHead·finalHead·변경파일·diff·테스트·postflight)을 만들어 GPT Sol을 호출하고, 결과를 엄격 JSON(`verdict`/`findings`)으로 파싱한다. 파싱 실패를 PASS로 처리하지 않는다(fail-closed).
- 작전 1 `repair`가 검수 결함만으로 최대 1회 수리한다(상태 가드 + 수리 후 postflight).
- fallback `resumeCommand`가 원래 이슈 번호를 유지한다(이슈 0/null 금지).
- CI 상태를 `gh pr checks`가 아니라 최종 HEAD 기준 GitHub Actions run으로 조회한다. `unavailable`을 `completed`로 합치지 않는다(`completed_ci_unavailable`).
- 시작 전제에 원격 동기화 게이트(`origin/main` ahead=0 behind=0)를 추가했다(자동 fetch/pull/reset 없음).

## 실제 사용자 명령

작전 실행은 **작전별로 분리된 Skill**이다. 하나의 `/operation 1|2|3`로 모델을 동적 전환하지 않는다 (이유는 아래).

```
/operation-1 <이슈번호> [--use-gpt-review-reserve] [--finish-current] [--claude-only]
/operation-2 <이슈번호> [--finish-current] [--claude-only]
/operation-3 <이슈번호> [--kind logic|mechanical] [--finish-current] [--claude-only]

/operation-1-claude <이슈번호>    # 작전 1 Claude-only 재개 (Sonnet 전용, resumeCommand 대상)
/operation-3-claude <이슈번호>    # 작전 3 logic Claude-only 재개 (Sonnet 전용, resumeCommand 대상)

/operation status
/operation doctor
/operation recover <작전번호> <이슈번호>
/operation set grok <0-100|available|exhausted>
/operation set gpt  <0-100|available|reserved|exhausted>
/operation reset
```

Claude-only resumeCommand 라우팅: 작전 1 → `/operation-1-claude <n>`, 작전 2 → `/operation-2 <n> --claude-only`, 작전 3 logic → `/operation-3-claude <n>`, 작전 3 mechanical → `claude_direct`(Haiku 직접, resume 없음).

### 라우터 하위 명령 (Skill 세션이 오케스트레이션 중 호출)

작전 1/2/3 Skill의 Claude 세션이 단계 진행에 쓰는 `run-operation.ps1` 하위 명령이다. 사용자가 직접 칠 필요는 없다.

```
-Command run       -Operation N -IssueNumber X [-Kind ..] [-ClaudeOnly] [-FinishCurrent] [-UseGptReviewReserve]
-Command review    -Operation 1 -IssueNumber X    # run 영수증 자동 복원 (StartHead 수동 입력 없음), GPT Sol 실제 검수, 엄격 JSON
-Command repair    -Operation 1 -IssueNumber X    # review 영수증에서 findings/postReviewHead/원래 worker 자동 복원, 최대 1회
-Command postflight -Operation N -IssueNumber X    # --claude-only 지시 후 세션이 구현을 마치면 호출
-Command recover    -Operation N -IssueNumber X    # 중단된 최신 실행 세대 확인·postflight 재개, worker 재호출 없음
```

작전 1 `run` 완료 시 실행 영수증이 `state/pending/op1-issue<n>-run.json`에 자동 저장되고, review가 REPAIR_REQUIRED면 findings가 `state/pending/op1-issue<n>-review.json`에 자동 저장된다. `-StartHead`/`-PostReviewHead`/`-FindingsFile`/`-Target`을 수동으로 추측해 넣지 않는다 (명시하면 영수증보다 우선).

`--claude-only`로 `run`을 부르면 워커를 호출하지 않고 `claude_execute` 지시(요구 모델·orderPath·postflight 명령)를 반환한다. 현재 세션이 요구 모델이면 그 주문서를 직접 수행한 뒤 `postflight` 하위 명령으로 완료 검증을 받는다. 재귀 handoff는 없다.

### 장시간 실행과 recover

예를 들어 `/operation-2 9`로 이슈 9를 시작한 뒤 Claude 세션이나 전경 shell 호출이 끊겼다면 `/operation recover 2 9`를 실행한다. 활성 프로세스면 `worker_running`과 기존 `executionId`·`logPath`를 반환하고 postflight를 실행하지 않는다. result가 있으면 정상 postflight를 이어가며, result 없이 커밋·push만 남았으면 `recovered_*_after_interruption`으로 판정한다. recover는 Grok/GPT 구현 worker를 다시 호출하지 않으며, CI 성공만으로 `localVerificationComplete=true`를 만들지 않는다.

동일 저장소·작전·이슈의 활성 상태(`worker_starting`, `worker_running`, `worker_exited_postflight_pending`, `interrupted_postflight_pending`)에서 `run`을 다시 호출하면 `execution_already_active`와 recover 명령만 반환한다. PID와 프로세스 시작시각을 함께 비교하고 result 부재와 heartbeat 정체까지 확인하기 전에는 stale로 간주하지 않는다.

기본 검증 계층은 worker가 targeted test·관련 정적 검사/lint·typecheck·핵심 시뮬레이션·커밋 전 최소 회귀를 수행하고, 전체 장시간 suite·멀티브라우저 E2E·dist·release asset·Pages는 CI로 확인하는 방식이다. 주문서가 전체 로컬 검증을 명시하면 이를 임의로 삭제하지 않는다.

## 단일 `/operation 1` 대신 분리 Skill을 쓴 이유

Claude Code 2.1.212의 SKILL.md frontmatter는 `model`·`effort`를 **정적(로드시 고정)** 으로만 지원한다 (claude.exe의 frontmatter 키 허용목록 `d5h`에서 `model`,`effort`,`disable-model-invocation`,`argument-hint` 확인). 실행 중 하나의 명령으로 모델을 바꾸는 **동적 전환은 공식 확인되지 않았다**. 따라서 작전마다 모델이 다른 이 라우터는 작전별 Skill로 분리하고 각 frontmatter에 모델을 고정했다. 보조 디스패처와 Claude-only 변형은 `disable-model-invocation: true`, operation-1/2/3은 자연어 호출용 `false`와 soft confirmation policy를 사용한다.

## 작전별 Claude 모델·effort

| Skill | model (frontmatter) | effort | 역할 |
|---|---|---|---|
| operation-1 | claude-opus-4-8 | high | 시작 위험검토 → 작업자 → GPT Sol 검수 → 수리 1회 → 종료 판정 |
| operation-2 | claude-sonnet-5 | medium | 좁은 시작검토 → 작업자 → 종료검토 1회 |
| operation-3 | claude-haiku-4-5-20251001 | low | 인수검증 → 라우터 1회 → postflight 표시 (저장소 조사 안 함) |
| operation-1-claude | claude-sonnet-5 | medium | 작전 1 Claude-only 재개: claude_execute 주문서 직접 구현 + postflight |
| operation-3-claude | claude-sonnet-5 | low | 작전 3 logic Claude-only 재개: claude_execute 주문서 직접 구현 + postflight |
| operation | claude-haiku-4-5-20251001 | low | status/doctor/set/reset 디스패처 |

## 작업자(Grok/GPT) 경로

| 작전 | Grok 가능 | Grok 소진 + GPT 작업 허용 | GPT 차단(80%+/reserved/exhausted) |
|---|---|---|---|
| 1 구현 | grok-4.5 high | sol 역할 high† | claude_only_required (claude-sonnet-5) |
| 1 검수 | — | sol 역할 high† | claude_review_fallback (Opus 직접) / 예비분은 `--use-gpt-review-reserve`만 |

† sol 역할은 `gpt-5.6-sol`에 매핑된다. 2026-07-22 `codex-cli 0.144.5` models_cache에서 Sol 노출을 확인해, 테스트 환경의 임시 `gpt-5.6-terra` 매핑을 제거했다. 과거 Terra로 수행한 V11~V13·V15는 실제 Sol 재검증 전까지 `PASS_PENDING_SOL_RETEST`를 유지한다.
| 2 구현 | grok-4.5 medium | gpt-5.6-terra medium | claude_only_required (claude-sonnet-5) |
| 3 logic | grok-4.5 low | gpt-5.6-terra medium | claude_only_required (claude-sonnet-5 low) |
| 3 mechanical | grok-4.5 low | gpt-5.6-luna low | claude_direct (claude-haiku, 기계적 작업만) |

## 사용량 수동 관리

자동 사용량 조회는 공식 방법이 없어 전부 수동이다. `/operation set` 은 숫자와 상태를 자동 정규화한다.

- Grok: 숫자 0-94 → `available`, 95-100 → `exhausted`. `available` 설정 시 percent=0, `exhausted` 설정 시 percent=100.
- GPT: 숫자 0-99 → `available`, 100 → `exhausted`. `reserved`는 명시 설정만. `available` 설정 시 percent=0.

### Grok 85% / 95% 규칙
- 0-84%: 작전 1·2·3 정상.
- 85-94%: 작전 1·2 **신규 실행 보호 차단** (`status: blocked`). 작전 3은 허용. `--finish-current`가 있으면 기존 작업 마감만 Grok으로 허용.
- 95-100% 또는 exhausted: GPT Plan B로 전환.

### GPT 60% / 80% 규칙
- 0-59%: Terra/Luna 정상, Sol은 작전 1 검수 우선.
- 60-79%: Terra는 작전 2만, Luna는 기계적 작업만, Sol은 검수 전용(구현 불가). 나머지는 claude-only.
- 80-100%: 일반 작업자 호출 금지. 검수 예비분도 자동 사용 금지(`--use-gpt-review-reserve`만).
- `reserved`: 일반 구현 금지, `--use-gpt-review-reserve`가 있는 작전 1 검수만.
- `exhausted`: 모든 GPT 호출 금지.

## 부분 변경 후 fallback 금지 (partial_worker_changes)

Grok이 명시적 한도 오류를 반환해도, GPT로 넘기기 전에 **시작 HEAD == 현재 HEAD, worktree clean, 새 커밋 0** 을 확인한다. 셋 다 참일 때만 fallback한다. 파일 수정/새 파일/커밋/HEAD 변경/dirty 중 하나라도 있으면 `status: partial_worker_changes`, `fallbackAttempted: false`로 중단한다. 기존 변경을 reset/stash/삭제하지 않는다. 일반 오류(빌드·테스트·인증·CLI 없음·네트워크)는 어떤 경우에도 fallback하지 않는다.

## Claude-only 실행 (v2.1: 실제 동작)

중첩 `claude` 프로세스를 자동 실행하지 않는다 (공식 지원 미확인). 대신:

- 일반 `run`이 GPT까지 차단되면 `status: claude_only_required` + `resumeCommand`(예: `/operation-2 8 --claude-only`, 원래 이슈번호 유지)를 **한 번** 안내한다.
- 그 `--claude-only`를 실행하면 워커 라우팅을 다시 하지 않고 `status: claude_execute`를 반환한다(요구 모델·`orderPath`·`postflightCommand`). 현재 세션이 요구 모델이면 그 주문서(고정 실행 계약+이슈 원문)를 직접 수행한 뒤 `-Command postflight`로 완료 검증을 받는다.
- `claude_only_required`를 반복 반환하는 재귀 루프는 없다.
- 작전 3 `mechanical`의 `claude_direct`는 현재 Haiku 세션이 직접 수행하는 실제 흐름으로 연결된다(구현 콜백 실행 → postflight).
- 현재 세션 모델을 공식적으로 검증할 방법은 없으므로, 요구 모델과 주문서를 반환하되 몰래 다른 모델로 계속하지 않는다.

## postflight 완료 검증

종료코드 0만으로 완료 처리하지 않는다. 시작 HEAD 대비 HEAD 변화, 최소 1커밋, branch=main, origin/main ahead=0 behind=0, worktree clean, push 완료를 확인한다. 워커 단계에서도 종료코드 0을 성공으로 간주하지 않는다(아래 v2.3.2 참조).

완료 상태값: `completed`, `completed_ci_pending`, `completed_ci_unavailable`, `completed_no_change_declared`, `no_commit`, `push_incomplete`, `dirty_worktree`, `not_on_main`, `ci_failed`, `worker_failed`, `worker_cancelled`, `worker_turn_limit`, `worker_protocol_error`, `provider_failure`, `quota_unknown`, `quota_exhausted`, `transient_rate_limited`, `partial_worker_changes`, `fallback_loop_blocked`, `blocked`, `claude_only_required`, `claude_direct`, `claude_execute`, `claude_review_fallback`, `repair_state_mismatch`, `repository_receipt_mismatch`, `execution_already_active`, `worker_running`, `interrupted_no_changes`, `interrupted_dirty_worktree`, `interrupted_push_incomplete`, `recovered_completed_after_interruption`, `recovered_ci_pending_after_interruption`, `recovered_ci_failed_after_interruption`, `recovered_ci_unavailable_after_interruption`.

검수 상태값: `reviewed`(verdict PASS|REPAIR_REQUIRED), `review_not_eligible`(작전 1 아님·worker≠grok·run 미완료 — GPT 미호출), `repository_receipt_mismatch`(다른 저장소 영수증), `review_receipt_missing`, `review_receipt_head_mismatch`, `claude_review_fallback`(경로 차단 또는 명확한 weekly 소진), `review_transient_rate_limited`, `review_provider_failure`, `review_quota_unknown`, `review_worker_failed`, `review_parse_failed`(종료코드 0 + 잘못된 JSON, fail-closed).

수리 상태값: `repair_completed_review_pending`(수리 성공, 재검수 미실시 — 최종 PASS는 현재 세션 종료 검토에서만), `repair_not_eligible`(작전 1 아님·verdict≠REPAIR_REQUIRED), `repository_receipt_mismatch`, `repair_worker_failed`, `repair_quota_exhausted`, `repair_transient_rate_limited`, `repair_provider_failure`, `repair_quota_unknown`, `repair_postflight_failed`, `repair_worker_unavailable`, `repair_receipt_missing`, `repair_state_mismatch`.

### 워커 오류 분류 (v2.3.1)
- `weekly_exhausted` (weekly limit / weekly usage limit / weekly plan limit / weekly quota): usage-state를 exhausted/100으로 바꾸고 Plan B 전환을 검토한다.
- `transient_rate_limit` (rate limit exceeded / too many requests / requests per minute / retry after / 429): **usage-state 불변**, config `transientRetry`(기본 5초 후 최대 1회) 재시도 후에도 transient면 `transient_rate_limited`로 중단한다. 임의로 다른 공급자에게 넘기지 않는다.
- `quota_unknown` (`usage limit reached` / `quota exceeded` / `you have exceeded your current quota`): 주간 소진으로 확정하지 않고 **usage-state 불변**으로 중단한다. 429가 함께 있으면 transient 분류가 quota_unknown보다 우선한다 (단, 명시적 weekly 문구가 있으면 항상 `weekly_exhausted`가 우선).
- `provider_failure`와 일반 실패: usage-state를 바꾸거나 다른 공급자로 fallback하지 않는다.
- `provider_failure` (authentication / invalid api key / billing / permission / model not found): 일반 실패(`worker_failed`)로 중단한다.

### Grok 헤드리스 권한 정책 + stopReason 판정 (v2.3.2)
- **현재 권한**: `config.grok.headlessPermissions.mode=alwaysApprove`를 Grok의 `--always-approve`로 전달한다. `--deny` 위험 명령 규칙은 자동 승인보다 우선하며, 거부된 도구 호출은 세션 전체 취소가 아니라 작업자에게 전달되는 도구 오류가 된다. `acceptEdits`는 셸 승인을 해결하지 못해 쓰지 않는다. `dontAsk`도 heredoc·명령 치환에 대한 ask 규칙을 답할 수 없어 `PermissionCancelled`를 일으킨 과거 실패 모드이므로 현재 사용하지 않는다.
- **`--no-auto-update`**: grok 0.2.102에는 해당 플래그·환경변수·config 키가 존재하지 않는다. 없는 구문을 추측해 넣으면 grok 실행 자체가 깨지므로 넣지 않으며, 헤드리스 `--output-format json` 단발 실행은 대화형 자동 업데이트를 유발하지 않는다.
- **성공 판정**: `--output-format json` 결과를 실제 JSON으로 파싱해 `stopReason`/`sessionId`/text/usage를 구조적으로 추출한다. 성공은 `ExitCode==0` **그리고** JSON 파싱 성공 **그리고** stopReason이 Cancelled/Aborted/Error/MaxTurns 계열이 아님을 모두 충족해야 한다.
  - stopReason Cancelled/Aborted → `worker_cancelled`
  - stopReason MaxTurns/turn limit → `worker_turn_limit`
  - JSON 파싱 실패(종료코드 0이어도) → `worker_protocol_error`
  - 이 세 경우 모두 **usage-state 불변, GPT/Claude fallback 없음, 자동 재시도 없음, CI polling 없음**. 종료코드와 실제 성공 여부는 별도 필드(`workerExitCode`/`workerStopReason`)로 유지한다.
  - 텍스트가 명시적 weekly/transient/provider/quota_unknown이면 그 분류가 stopReason보다 우선한다(기존 v2.3 오류 정책 보존).

### postflight의 CI 조회 시점 (v2.3)
Git·커밋·push 게이트가 전부 통과한 뒤에만 CI를 조회한다. worker_failed/worker_cancelled/worker_turn_limit/worker_protocol_error/quota_exhausted/no_commit/dirty_worktree/not_on_main/push_incomplete로 이미 실패가 확정된 경우 CI polling을 생략하고 ciStatus를 `not-checked`로 남긴다.

시작 preflight 중단 상태값: `not_a_git_repository`, `not_on_main_branch`, `dirty_worktree`, `remote_sync_unavailable`, `local_ahead_of_remote`, `behind_remote`.

### CI 상태 의미 (v2.3)
`gh pr checks`(PR 기준)가 아니라 **최종 HEAD의 GitHub Actions run**(`gh run list --branch main --json headSha,status,conclusion`)으로 조회한다.
워크플로 존재 여부는 저장소의 `.github/workflows/*.yml|yaml` 로컬 확인으로 판정하고, 워크플로가 있으면 run 생성 지연을 고려해 **10초 간격 최대 6회 polling**한다(`config.ciPolling`).
**동일 최종 HEAD의 모든 run을 집계한다(첫 run만 보지 않음)** — 하나라도 failure/cancelled/timed_out/startup_failure → `failure`, 실패 없고 하나라도 미완(queued/in_progress) → `pending`, 하나 이상 존재하고 전부 completed/success → `success`.
`unavailable`(gh 없음·API 오류·JSON 파싱 실패·**워크플로 있음 + polling 종료까지 run 미발견**·completed인데 success/실패 어느 쪽도 아닌 conclusion) / `not-requested`(워크플로 파일 자체가 없음) / `not-checked`(Git 게이트 실패로 CI 미조회). **API 오류(`unavailable`)를 `completed`로 합치지 않고 `completed_ci_unavailable`로 남기며, 워크플로가 있는데 run이 아직 안 보이는 경우를 `not-requested`→`completed`로 처리하지 않는다.**

## 원격 동기화 게이트의 의미 (정직한 한계)

시작 전제의 ahead/behind 비교(`git rev-list --left-right --count origin/main...HEAD`)는 **마지막으로 알려진 origin/main 추적 ref 기준**이다. 라우터는 fetch/pull/reset을 자동 수행하지 않으므로, 로컬 추적 ref가 오래됐다면 실제 원격과 다를 수 있다. 실제 원격 HEAD를 확인하고 싶으면 저장소를 변경하지 않는 다음 방식 중 하나를 사용자가 직접 사용한다.

```
git ls-remote origin refs/heads/main
gh api repositories/<owner>/<repo>/commits/main
```

## 고정 실행 계약

작업자에게는 이슈 원문만 보내지 않는다. `[역할 지정]`에서 작업자가 지휘 세션으로부터 이미 위임받은 최종 실행자이며 Grok·Codex·Claude 등 다른 CLI에 재위임하지 않는다고 고정한다. 이어서 `[고정 실행 계약]`(main 전용, branch/PR 금지, 강제 push·reset --hard·clean -fd 금지, clean worktree 전제, 범위 밖 확장 금지, 의미단위 커밋+즉시 push, 이슈 CRUD 금지, secret 미출력, 테스트 실패 은폐 금지, 짧은 완료 보고) 다음에 **이슈 본문 원문을 무손실**로 붙인다. 이슈 본문은 요약·재작성·삭제하지 않는다.

## 파일 / 상태 위치

```
~/.claude/skills/operation, operation-1, operation-2, operation-3,
                 operation-1-claude, operation-3-claude              # 정적 Skill (SKILL.md만)
~/.claude/operation-router/
├─ operation-router.cmd        # Skill 6종이 공통으로 호출하는 shell 독립 실행기
├─ config/config.json          # 정적 설정 (오류 분류 패턴, ciPolling, transientRetry 포함)
├─ state/usage-state.json      # 가변 (reset 대상)
├─ state/doctor-report.json    # 가변 (doctor 산출)
├─ state/pending/<owner__repo>/   # 저장소별 네임스페이스 (origin 없으면 local-<해시>)
│   ├─ op<N>-issue<X>.json         # --claude-only 2단계용 시작 스냅샷
│   ├─ order-op<N>-issue<X>.txt    # claude-only 주문서
│   ├─ op<N>-issue<X>-run.json     # 작전 1 run 영수증 (ownerRepo/repoRoot 포함)
│   ├─ op<N>-issue<X>-review.json  # 작전 1 review 영수증 (ownerRepo/repoRoot 포함)
│   ├─ op<N>-issue<X>-execution.json # 최신 구현 실행 세대 영수증
│   └─ executions/                 # generation별 prompt/raw stdout·stderr/result
├─ scripts/*.ps1               # 라우터 스크립트 (worker-host 포함)
├─ skills/<6종>/SKILL.md       # source-tree/검토본 기준 Skill 사본
├─ tests/run-tests.ps1         # 격리 실행기, Pester 실패 시 exit 1
├─ tests/source-tree.Tests.ps1 # 기존 회귀 + v2.4.4 실행 영속화·recover 테스트
├─ tests/fixtures/usage-state.initial.json
├─ logs/runtime/               # 새 실전 로그, 이 디렉터리 안에서 최근 20개 회전
├─ logs/tests/<test-run-id>/   # mock 로그, 실행별 격리·정리
├─ logs/*.log                  # v2.3.3 이전 증거, 동결되어 새 회전 대상에서 제외
└─ temp/                       # 임시 주문서/검수 프롬프트 (작업 종료 시 finally 삭제)
```

가변 상태는 Skill 폴더 밖(runtime)에 둔다. `/operation reset`은 `state/usage-state.json`만 초기화하고 Skill·스크립트·config.json은 건드리지 않는다.

기본 검증은 source tree만 대상으로 하며 사용자 홈의 상태·로그·설치 Skill을 사용하지 않는다.

v2.4.4 최종 검증은 207개 Pester 전체 회귀와 별도 격리 Grok live probe 1회다. live probe는 생성한 로컬 저장소와 bare origin만 수정하며, worker 호출 전 영수증·종료 전 runtime log·정상 postflight를 확인한 뒤 fixture를 삭제한다.

## 롤백 (1인 사용)

이 저장소는 자동 설치·업그레이드·백업·롤백 스크립트를 제공하지 않는다. 기존 작업 과정에서 **수동으로 생성된** `~/.claude/backups/` 백업이 있는 경우에만 해당 사본을 `~/.claude/operation-router`와 `~/.claude/skills/operation*`로 복원할 수 있다. 백업이 없는 설치본은 자동 복구되지 않는다. (과거 수동 생성 예시: `operation-router.bak.<timestamp>`, `operation-router.bak.v2.1.<timestamp>`, `global-rules.bak.<timestamp>` — 현재 버전이 이 백업을 자동 생성한다는 뜻은 아니다.) 상세 문서: [CHANGELOG.md](CHANGELOG.md), [VERIFICATION_MATRIX.md](VERIFICATION_MATRIX.md), [SECURITY.md](SECURITY.md).

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 -RootPath <review-root> -SkillsPath <review-root>\skills -StatePath <temp>\state\usage-state.json -LogRoot <temp>\logs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 -InstalledIntegration
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-installed-fixture.ps1
```

첫 두 명령은 `sourceTreeTests=executed`, `installedIntegrationTests=not-requested`를 보고한다. `-InstalledIntegration`은 실제 설치된 `~/.claude/skills`를 검사한다. `run-installed-fixture.ps1`은 실제 전역 설치본을 수정하지 않고 격리 사용자 홈에 Skill 6종을 복사해 같은 설치 통합 검증을 수행한다. source-tree 검증과 설치 통합 검증을 같은 것으로 보고하지 않는다.

## 실행기

Windows PowerShell 5.1 (`powershell.exe`)만 있고 `pwsh`는 없다. 스크립트는 PS 5.1 문법(삼항연산자 미사용 등)으로 작성했다.

## 실제 확인된 CLI 모델 ID·옵션 (2026-07-20 실측)

- Skill frontmatter (claude.exe 실측): `model`,`effort`,`disable-model-invocation`,`argument-hint`,`user-invocable`,`when_to_use` 지원. 모델 ID `claude-opus-4-8`/`claude-sonnet-5`/`claude-haiku-4-5-20251001` 인식. effort low/medium/high/xhigh/max.
- Grok 0.2.102: 모델 grok-4.5(유일). `--cwd --model --reasoning-effort --max-turns --prompt-file --output-format json --always-approve --allow <RULE> --deny <RULE> --no-plan --no-subagents`. stdin은 임시 `.cmd` 래퍼의 `< NUL`로 고정한다. `--deny`가 자동 승인보다 우선하며 `--no-auto-update`는 존재하지 않는다.
- Codex 0.144.5: `codex exec --cd -m -c model_reasoning_effort=<e> -s workspace-write -c approval_policy=never -c sandbox_workspace_write.network_access=true --json -` (프롬프트 stdin). `-a`는 `codex exec`에 없는 옵션이므로 쓰지 않는다. 2026-07-22 `~/.codex/models_cache.json`에서 `gpt-5.6-sol`/`gpt-5.6-terra`/`gpt-5.6-luna`를 확인했다. doctor에서 `unresolved`로 판정된 모델 호출은 계속 fail-closed로 차단된다.

## 삭제·복구

- Skill 삭제: `~/.claude/skills/operation*` 폴더 삭제.
- 런타임 삭제: `~/.claude/operation-router/` 삭제 (프로젝트 무관).
- 복구: 이전 버전 백업은 `~/.claude/backups/operation-router.bak.<timestamp>/`(v1), `~/.claude/backups/operation-router.bak.v2.1.<timestamp>/`(v2.1, 런타임+Skill 포함).

## 알려진 제한 / 미확정

- **동적 모델 전환 미확인**: SKILL.md `model`은 정적. 하나의 명령으로 런타임 모델 전환이 되는지 공식 확인 못함 → 분리 Skill 채택.
- **중첩 claude 실행 미확인**: 자동 재귀 실행 안 함. claude-only는 수동 재개.
- **GPT/Grok 사용량 자동 조회 불가**: 전부 수동(`/operation set`).
- **작전 1 Sol 재검증 대기**: 임시 Terra 매핑은 제거했고 작전 1은 `gpt-5.6-sol`을 사용한다. 다만 Terra로 수행한 기존 V11~V13·V15는 Sol로 재실행해 통과하기 전까지 `PASS_PENDING_SOL_RETEST`를 유지한다. 상세는 [VERIFICATION_MATRIX.md](VERIFICATION_MATRIX.md).
- **grok models = grok-4.5 하나뿐**: 추가 모델 생기면 config.json 갱신 필요.
- **한글 별칭 `/작전` 미제공**: 별칭 필드 지원 미확인.
