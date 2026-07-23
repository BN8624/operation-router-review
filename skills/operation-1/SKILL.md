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

## 자연어 자동 호출 시 soft confirmation policy
`disable-model-invocation: false`라서 사용자가 자연어로 지시하면 모델이 이 Skill을 호출할 수 있다. 작전 1은 고위험이고 `run`은 유료 worker 호출과 기본값인 issue branch·Draft PR 생성으로 이어지므로, 자연어 자동 호출일 때는 아래 soft confirmation policy를 따른다.
1. 먼저 `status`(읽기 전용, 무료)로 예상 워커를 파악한다.
2. "작전 1, 이슈 #<번호>, 예상 워커 <grok/gpt/claude·비용 발생 여부>. 실행할까요?"를 제시하고 사용자 확인(예)을 받은 뒤에만 `run`을 실행한다.
사용자가 `/operation-1 ...` 슬래시 명령을 직접 입력한 경우는 명시적 실행이므로 이 확인을 생략한다. 이 확인은 모델이 따르는 사용성·오작동 방지용 soft policy이며, 라우터 코드가 강제하는 보안 토큰 게이트가 아니다(별도 확인 토큰 시스템을 두지 않는다).

## 실제 실행 순서 (이 순서대로만 진행한다)

1. `run -Detach` 명령을 실행한다.
2. `worker_starting`/`worker_running`/`execution_already_active`가 반환되면 즉시 같은 실행에 `watch -Follow`를 실행하고 terminal까지 현재 작전 흐름을 유지한다.
3. `watch_checkpoint`/`watch_recovery_locked`이면 같은 `executionId`와 같은 `generation`에 watch만 다시 연결한다. 새 `run`은 금지한다.
4. terminal의 `nextAction`은 `review`/`opus_end_review`/`manual_verification`/`stop` 중 하나만 수행한다.
5. `nextAction=review`의 review가 PASS면 종료 검토(8단계)로 간다.
6. review가 REPAIR_REQUIRED면 findings는 라우터가 런타임 임시 파일(review 영수증 `state/pending/op1-issue<n>-review.json`)에 자동 저장하고, 원래 worker 정보를 유지해 `repair` 명령을 1회 실행한다 (worker/HEAD/findings는 영수증에서 자동 복원).
7. 수리 후 현재 Opus가 최종 diff를 확인한다 (`git diff <startHead>..HEAD`, 시작 HEAD는 run 영수증에 있음).
8. 최종 PASS 또는 REPAIR_REQUIRED를 판정한다. 최종 PASS일 때만 `finalize -ReviewVerdict PASS`를 호출한다.
9. `merge_ready`이면 병합 가능한 검토 상태라고 보고한다. 이는 병합 완료가 아니며 라우터와 worker 모두 자동 병합하지 않는다.

`-StartHead`, `-PostReviewHead`, `-Target`을 수동으로 추측해 넣지 않는다. run/review 영수증에서 자동 복원된다.

## 1. run — 작업자 구현 (라우터 1회 실행)
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command run -Operation 1 -IssueNumber $0 -Detach [-UseGptReviewReserve] [-FinishCurrent] [-ClaudeOnly]
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command run -Operation 1 -IssueNumber $0 -Detach [-UseGptReviewReserve] [-FinishCurrent] [-ClaudeOnly]
```

### v3 자동 follow와 Draft PR 종료 검토

`run -Detach`가 `worker_starting`/`worker_running`/`execution_already_active`를 반환하면 같은 작전·이슈로 즉시 다음 명령을 실행한다.

```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command watch -Operation 1 -IssueNumber $0 -Follow
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command watch -Operation 1 -IssueNumber $0 -Follow
```

- watch가 terminal을 반환할 때까지 현재 작전 흐름을 종료하지 않는다.
- `watch_checkpoint` 또는 `watch_recovery_locked`이고 같은 `executionId`/`generation`이 active이면 새 `run` 없이 같은 watch 명령만 다시 실행한다.
- `nextAction=review`이면 기존 Sol review를 실행한다.
- `nextAction=opus_end_review`이면 GPT 구현 결과이므로 현재 Opus 세션이 시작 HEAD 대비 diff·테스트·push 상태를 직접 종료 검토한다. Sol 자기검수는 금지한다.
- `nextAction=manual_verification`이면 review/repair를 호출하지 않고 수동 검증 필요를 보고한다.
- `nextAction=stop`이면 실패 상태를 보고하고 종료한다.
- watch를 중단하거나 다시 연결해도 worker를 종료하거나 새 generation을 만들지 않는다.
- 기본 `pull-request` mode에서는 라우터가 `operation-router/issue-<이슈번호>` branch를 선택하고 Draft PR을 생성·재사용한다. 구현, Sol review, repair, Opus 종료 검토는 receipt에 고정된 같은 branch와 같은 PR을 사용한다.
- worker는 branch나 PR을 만들거나 바꾸거나 병합하지 않는다. worker push 대상은 receipt에 적힌 원격 work branch뿐이다.
- 설정에 `gitWorkflow`가 없는 legacy 설치본 또는 명시적 `direct-main` mode에서는 v2 계약을 유지한다.
라우터가 사용량에 따라 작업자를 정한다.
- Grok 사용 가능 → Grok 4.5 / high
- Grok 소진·GPT 작업 허용 → GPT-5.6 Sol / high
- Grok 85~94%면 신규 실행이 보호 차단된다. 기존 작업 마감은 `--finish-current`일 때만.
- run이 worker postflight까지 도달하면 실행 영수증(`state/pending/op1-issue<n>-run.json`)이 자동 저장된다. receipt에는 시작·최종 HEAD, worker, 검증 결과뿐 아니라 실행 시작 때 고정한 workflow mode, base/work branch, PR 번호·URL·head SHA·CI 상태가 들어간다.
- recover는 Claude 세션이 이미 종료되었거나 사용자가 나중에 새 세션으로 재진입할 때만 `/operation recover 1 <이슈번호>`로 사용한다. watch가 살아 있는 동안 수동으로 호출하지 않는다. recover는 구현 worker를 0회 호출한다. 정상 result envelope가 없는 복구는 `recovered_*_unverified`이며 Sol review 불가이므로 검증 재실행 또는 수동 종료 검토가 필요하다.

## 주문서 검증 계층 지침

기본적으로 worker 로컬 필수 검증은 수정 관련 targeted test, 해당 파일 정적 검사나 lint, typecheck, 핵심 시뮬레이션, 커밋·push 전 최소 회귀다. 전체 테스트, 장시간 시뮬레이션, 멀티브라우저 E2E, dist 블랙박스, release asset·Pages 확인은 CI에서 확인할 수 있다. 다만 이 지침은 주문서의 명시적 로컬 검증을 삭제하거나 축소하는 규칙이 아니다.

## 2. review — GPT Sol 독립 검수 (영수증 자동, Grok 구현 결과 전용)
run 영수증을 자동으로 읽으므로 시작 HEAD를 다시 입력하지 않는다. 다음 명령만으로 검수가 실행된다.
검수 자격은 코드가 강제한다. 작전 1, worker=grok, 정상 result envelope, review 가능한 provenance, 같은 repository identity가 필수다. PR mode에서는 현재 branch/HEAD가 receipt의 workBranch/finalHead와 같고 PR이 OPEN·Draft이며 base/head/head SHA가 receipt 및 현재 HEAD와 일치해야 한다. `pr_opened`, `pr_ci_pending`, `pr_ci_unavailable`은 코드 review가 가능하지만 `pr_ci_failed`와 PR context 불일치는 review 불가다. result 유실 recover는 `reason: recovered_result_missing_or_unverified`이며 GPT 호출은 0회다. **GPT가 구현한 작전 1 결과는 Sol 자기검수를 하지 않고 현재 Opus가 직접 종료 검토한다.**
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command review -Operation 1 -IssueNumber $0 [-UseGptReviewReserve]
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command review -Operation 1 -IssueNumber $0 [-UseGptReviewReserve]
```
- 영수증이 없으면 `review_receipt_missing`, 현재 HEAD가 영수증 finalHead와 다르면 `review_receipt_head_mismatch`로 중단된다.
- 검수 프롬프트에는 workflow mode, base branch/head, work branch, PR 번호·URL·head SHA, PR CI, baseAdvanced, 시작 HEAD 대비 diff와 worker verification report가 포함된다. workerSummary는 작업자가 스스로 보고한 요약이며 라우터가 재실행한 테스트 결과가 아니다. review worker는 읽기 전용이며 PR이나 이슈를 수정하지 않는다.
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
- verified Grok run 영수증과 유효한 REPAIR_REQUIRED review 영수증이 모두 필수다. findings/postReviewHead/원래 worker는 영수증에서 자동 복원된다.
- `-PostReviewHead`/`-FindingsFile`/`-Target` 수동 인수는 영수증을 대체하지 않고 일치 assertion으로만 사용한다. 불일치는 `repair_argument_receipt_mismatch`, 영수증 부재·unverified provenance는 worker 호출 0회로 fail-closed 한다.
- 수리 작업자도 사용량 상태를 준수한다. Grok exhausted면 Grok 수리 금지, GPT 80%+/reserved/exhausted면 GPT 수리 금지, 검수 예비분은 수리에 쓰지 않는다. 사용할 작업자가 없으면 `repair_worker_unavailable`로 중단하고 다른 작업자로 교체하지 않는다.
- PR mode repair는 기존 work branch와 기존 OPEN Draft PR만 재사용하며 새 PR을 만들지 않는다. repair 뒤 PR head SHA와 CI를 다시 조회한다.
- 수리 성공 상태는 `repair_completed_review_pending`, `repair_pr_ci_pending`, `repair_pr_ci_unavailable` 중 하나다. `repair_pr_ci_failed`는 실패다. 수리 자체는 최종 PASS나 `merge_ready`가 아니며 Opus 종료 검토가 반드시 필요하다.

## 4. 종료 판정 (Opus 직접, 최종 PASS는 여기서만)
`git status --short`, run 영수증의 시작 HEAD 대비 diff, 테스트·커밋·push·worktree·workflow/PR/CI context만 확인한다. 전체 재전수조사 금지. REPAIR_REQUIRED이면 결함을 보고하고 finalize하지 않는다. PASS이면 다음 명령으로 최종 gate를 실행한다.

```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command finalize -Operation 1 -IssueNumber $0 -ReviewVerdict PASS
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command finalize -Operation 1 -IssueNumber $0 -ReviewVerdict PASS
```

CI pending/failed/unavailable, unresolved router state, dirty worktree, push 미완료, PR context 불일치, artifact 또는 boundary 실패에서는 `merge_ready`가 될 수 없다. 성공하면 Draft만 해제하며 merge는 호출하지 않는다.

## claude_only_required / claude_execute 분기

라우터 결과가 `claude_only_required`이면 반환된 `resumeCommand`(`/operation-1-claude <n>` — Sonnet 전용 Skill)만 안내하고 중단한다. Opus가 직접 구현하지 않는다.

라우터 결과가 `claude_execute`이면 (요구 모델 claude-sonnet-5와 현재 세션이 일치할 때, 즉 `/operation-1-claude` 세션에서):
1. `orderPath`를 읽는다.
2. 고정 실행 계약과 이슈 주문서를 현재 세션이 수행한다.
3. 주문서에 고정된 expected branch에서 의미 단위 커밋을 만들고 expected remote branch에만 push한다.
4. 반환된 `postflightCommand`를 반드시 실행한다.
5. postflight 결과만 보고한다.

`claude_execute` JSON을 표시만 하고 끝내지 않는다.

## 출력
라우터 최종 JSON의 workflowMode/baseBranch/workBranch/prNumber/prUrl/prDraft/ciStatus/status/pushComplete/reviewVerdict/remainingProblems을 짧게 요약한다. `merge_ready`를 completed나 merged라고 표현하지 않는다. 작업자 전체 출력·이슈 원문·장문 로그는 대화에 넣지 않는다.
