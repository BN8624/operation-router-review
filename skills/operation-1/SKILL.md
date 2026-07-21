---
name: operation-1
description: 작전 1 — 고위험 전체 지휘·검수. 현재 Opus 세션이 시작 위험 검토 → 작업자 구현 → GPT Sol 독립 검수 → 수리 1회 → 종료 판정을 수행한다. GitHub 이슈 번호를 인수로 받는다.
argument-hint: <이슈번호> [--use-gpt-review-reserve] [--finish-current] [--claude-only]
disable-model-invocation: false
model: claude-opus-4-8
effort: high
---

# 작전 1 (고위험)

이 Skill은 Claude Opus 4.8 / high 세션에서만 실행된다 (frontmatter로 고정). 동적 모델 전환은 하지 않는다.
이슈번호는 slash-command 첫 위치 인수 `$0`에서 읽는다. 실행기는 `operation-router.cmd`만 사용한다.
PowerShell은 `$env:USERPROFILE` 경로, Git Bash는 `$USERPROFILE` 경로를 사용한다.

## 자연어 자동 호출 시 soft confirmation policy (v2.4.0)
`disable-model-invocation: false`라서 사용자가 자연어로 지시하면 모델이 이 Skill을 호출할 수 있다. 작전 1은 고위험이고 `run`은 유료 워커 호출과 origin/main 직접 push로 이어지므로, 자연어 자동 호출일 때는 아래 soft confirmation policy를 따른다.
1. 먼저 `status`(읽기 전용, 무료)로 예상 워커를 파악한다.
2. "작전 1, 이슈 #<번호>, 예상 워커 <grok/gpt/claude·비용 발생 여부>. 실행할까요?"를 제시하고 사용자 확인(예)을 받은 뒤에만 `run`을 실행한다.
사용자가 `/operation-1 ...` 슬래시 명령을 직접 입력한 경우는 명시적 실행이므로 이 확인을 생략한다. 이 확인은 모델이 따르는 사용성·오작동 방지용 soft policy이며, 라우터 코드가 강제하는 보안 토큰 게이트가 아니다(별도 확인 토큰 시스템을 두지 않는다).

## 실제 실행 순서 (이 순서대로만 진행한다)

1. `run` 명령 실행
2. run 결과가 완료 상태(`completed`/`completed_ci_pending`/`completed_ci_unavailable`)이고 worker=grok이면 `review` 실행
3. review PASS면 종료 검토(6단계)로 간다
4. review REPAIR_REQUIRED면 findings는 라우터가 런타임 임시 파일(review 영수증 `state/pending/op1-issue<n>-review.json`)에 자동 저장한다
5. 원래 worker 정보를 유지해 `repair` 명령을 1회 실행한다 (worker/HEAD/findings는 영수증에서 자동 복원)
6. 수리 후 현재 Opus가 최종 diff를 확인한다 (`git diff <startHead>..HEAD`, 시작 HEAD는 run 영수증에 있음)
7. 최종 PASS 또는 REPAIR_REQUIRED를 보고한다 — **최종 PASS 판정은 이 종료 검토에서만 한다**

`-StartHead`, `-PostReviewHead`, `-Target`을 수동으로 추측해 넣지 않는다. run/review 영수증에서 자동 복원된다.

## 1. run — 작업자 구현 (라우터 1회 실행)
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command run -Operation 1 -IssueNumber $0 [-UseGptReviewReserve] [-FinishCurrent] [-ClaudeOnly]
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command run -Operation 1 -IssueNumber $0 [-UseGptReviewReserve] [-FinishCurrent] [-ClaudeOnly]
```
라우터가 사용량에 따라 작업자를 정한다.
- Grok 사용 가능 → Grok 4.5 / high
- Grok 소진·GPT 작업 허용 → GPT-5.6 Sol / high
- Grok 85~94%면 신규 실행이 보호 차단된다. 기존 작업 마감은 `--finish-current`일 때만.
- run이 워커 postflight까지 도달하면 실행 영수증(`state/pending/op1-issue<n>-run.json`)이 자동 저장된다
  (startHead/finalHead/worker/model/effort/postflight/workerSummary/createdAt).

## 2. review — GPT Sol 독립 검수 (영수증 자동, Grok 구현 결과 전용)
run 영수증을 자동으로 읽으므로 시작 HEAD를 다시 입력하지 않는다. 다음 명령만으로 검수가 실행된다.
검수 자격은 코드가 강제한다 — 작전 1 + 영수증 worker=grok + run 상태 완료 계열 + 같은 저장소 + 현재 HEAD=영수증 finalHead가 아니면 GPT를 호출하지 않고 `review_not_eligible`(또는 `repository_receipt_mismatch`)로 중단된다. **GPT가 구현한 작전 1 결과는 Sol 자기검수를 하지 않고 현재 Opus가 직접 종료 검토한다.**
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command review -Operation 1 -IssueNumber $0 [-UseGptReviewReserve]
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command review -Operation 1 -IssueNumber $0 [-UseGptReviewReserve]
```
- 영수증이 없으면 `review_receipt_missing`, 현재 HEAD가 영수증 finalHead와 다르면 `review_receipt_head_mismatch`로 중단된다.
- 검수 프롬프트에는 이슈 원문·시작/최종 HEAD·변경 파일·diff·작업자(worker/model/effort)·worker 종료코드·commitCount·branch·ahead/behind·worktreeClean·pushComplete·ciStatus·remainingProblems·workerSummary가 포함된다. workerSummary는 작업자가 스스로 보고한 요약이며 라우터가 재실행한 테스트 결과가 아니다.
- GPT 80% 이상이면 예비분을 자동 사용하지 않는다. `--use-gpt-review-reserve`가 있을 때만 Sol 검수를 쓴다.
- 검수 결과 상태:
  - `reviewed` + verdict `PASS`|`REPAIR_REQUIRED` — 정상 JSON
  - `claude_review_fallback` — 검수 경로 차단 또는 GPT quota 소진. Opus가 주문서의 고위험 항목만 직접 종료 검토한다.
  - `review_worker_failed` — 일반 실행·인증·네트워크 실패. 실행 실패를 코드 결함 finding으로 위장하지 않는다.
  - `review_parse_failed` — 종료코드 0 + 잘못된 JSON. fail-closed이며 PASS가 아니다.

## 3. repair — 수리 (최대 1회, 영수증 자동)
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command repair -Operation 1 -IssueNumber $0
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command repair -Operation 1 -IssueNumber $0
```
- findings/postReviewHead/원래 worker는 review·run 영수증에서 자동 복원된다. 영수증이 없으면 `repair_receipt_missing`으로 중단된다.
- 수리 작업자도 사용량 상태를 준수한다. Grok exhausted면 Grok 수리 금지, GPT 80%+/reserved/exhausted면 GPT 수리 금지, 검수 예비분은 수리에 쓰지 않는다. 사용할 작업자가 없으면 `repair_worker_unavailable`로 중단하고 다른 작업자로 교체하지 않는다.
- 수리 성공 상태는 `repair_completed_review_pending`이다. 재검수를 하지 않으므로 원래 findings를 "남은 findings"라고 부르지 않는다. 워커 실패는 `repair_worker_failed`/`repair_quota_exhausted`/`repair_postflight_failed`로 구분된다.

## 4. 종료 판정 (Opus 직접, 최종 PASS는 여기서만)
`git status --short`, run 영수증의 시작 HEAD 대비 diff, 테스트·커밋·push·worktree·origin 동기화만 확인한다. 전체 재전수조사 금지. 확인 후 최종 PASS 또는 REPAIR_REQUIRED를 보고한다.

## claude_only_required / claude_execute 분기

라우터 결과가 `claude_only_required`이면 반환된 `resumeCommand`(`/operation-1-claude <n>` — Sonnet 전용 Skill)만 안내하고 중단한다. Opus가 직접 구현하지 않는다.

라우터 결과가 `claude_execute`이면 (요구 모델 claude-sonnet-5와 현재 세션이 일치할 때, 즉 `/operation-1-claude` 세션에서):
1. `orderPath`를 읽는다.
2. 고정 실행 계약과 이슈 주문서를 현재 세션이 수행한다.
3. 의미 단위 커밋·push를 완료한다.
4. 반환된 `postflightCommand`를 반드시 실행한다.
5. postflight 결과만 보고한다.

`claude_execute` JSON을 표시만 하고 끝내지 않는다.

## 출력
라우터 최종 JSON(operation/route/worker/model/startHead/finalHead/commitCount/ahead/behind/pushComplete/ciStatus/status/remainingProblems/logPath)을 짧게 요약해 표시한다. 작업자 전체 출력·이슈 원문·장문 로그는 대화에 넣지 않는다.
