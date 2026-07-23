---
name: operation-3
description: 작전 3 — 명확한 소규모 작업. 현재 Haiku 세션은 저장소를 조사하거나 검토하지 않고, 인수 검증 → 라우터 1회 실행 → postflight 결과 표시만 한다. GitHub 이슈 번호를 인수로 받는다.
argument-hint: <이슈번호> [--kind logic|mechanical] [--finish-current] [--claude-only]
disable-model-invocation: false
model: claude-haiku-4-5-20251001
effort: low
---

## v3 공통 watch

`run -Detach` 직후 다음 공통 watch를 실행해 terminal까지 같은 execution과 generation을 따른다. Operation 3은 terminal `nextAction=report`만 표시하며 별도 review나 종료 검토를 자동 추가하지 않는다.

```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command watch -Operation 3 -IssueNumber $0 -Follow
```

# 작전 3 (명확한 소규모 작업)

이 Skill은 Claude Haiku 4.5 / low 세션에서만 실행된다 (frontmatter 고정).

## 자연어 자동 호출 시 soft confirmation policy
`disable-model-invocation: false`라서 사용자가 자연어로 지시하면 모델이 이 Skill을 호출할 수 있다. `run`은 유료 worker 호출과 기본값인 issue branch·Draft PR 생성으로 이어지므로, 자연어 자동 호출일 때는 아래 soft confirmation policy를 따른다.
1. 먼저 `status`(읽기 전용, 무료)로 예상 워커를 파악한다.
2. "작전 3 <kind>, 이슈 #<번호>, 예상 워커 <grok/gpt/claude·비용 발생 여부>. 실행할까요?"를 제시하고 사용자 확인(예)을 받은 뒤에만 `run`을 실행한다.
사용자가 `/operation-3 ...` 슬래시 명령을 직접 입력한 경우는 명시적 실행이므로 이 확인을 생략한다. 이 확인은 모델이 따르는 사용성·오작동 방지용 soft policy이며, 라우터 코드가 강제하는 보안 토큰 게이트가 아니다(별도 확인 토큰 시스템을 두지 않는다).
이슈번호는 slash-command 첫 위치 인수 `$0`에서 읽는다. 실행기는 `operation-router.cmd`만 사용한다.
PowerShell은 `$env:USERPROFILE` 경로, Git Bash는 `$USERPROFILE` 경로를 사용한다.

현재 Haiku 세션은 저장소를 조사하거나 코드를 검토하지 않는다. 역할은 다음뿐이다.
```
인수 검증 → run -Detach → watch -Follow → operation_terminal → nextAction=report
```

## 실행
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command run -Operation 3 -IssueNumber $0 -Detach [-Kind logic|mechanical] [-FinishCurrent] [-ClaudeOnly]
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command run -Operation 3 -IssueNumber $0 -Detach [-Kind logic|mechanical] [-FinishCurrent] [-ClaudeOnly]
```

- 기본 kind는 `logic`. 기계적/로직 판단은 라우터가 LLM으로 추측하지 않고 인수로 받는다.
- Grok 사용 가능 → Grok 4.5 / low (no-plan, no-subagents)
- Grok 소진·GPT 작업 허용:
  - `--kind logic` → GPT-5.6 Terra / medium
  - `--kind mechanical` → GPT-5.6 Luna / low
- GPT 80% 이상:
  - `logic` → `status: claude_only_required`(claude-sonnet-5 / low). resumeCommand `/operation-3-claude <이슈번호>`(Sonnet 전용 Skill)를 안내한다.
  - `mechanical` → `status: claude_direct`(claude-haiku). 문서·버전 문자열·명백한 설정 치환처럼 기계적 작업만 현재 Haiku 세션이 직접 수행할 수 있다.
- `worker_starting`/`worker_running`/`execution_already_active`가 반환되면 즉시 같은 이슈의 `watch -Follow`를 실행한다.
- `watch_checkpoint`/`watch_recovery_locked`이면 같은 `executionId`와 `generation`의 watch만 다시 실행한다.
- terminal `nextAction=report`이면 결과를 표시하고 끝낸다. 별도 review나 종료 검토를 자동 추가하지 않는다.
- 기본 `pull-request` mode에서는 라우터가 issue branch와 Draft PR을 소유한다. worker는 branch·PR을 관리하거나 main에 push하지 않고 receipt의 work branch에만 push한다.
- recover는 Claude 세션이 이미 종료됐거나 사용자가 나중에 새 세션으로 재진입했고 watch가 없을 때만 사용한다. worker를 새로 호출하지 않는다.

## 주문서 검증 계층 지침

기본적으로 worker 로컬 필수 검증은 수정 관련 targeted test, 해당 파일 정적 검사나 lint, typecheck, 핵심 시뮬레이션, 커밋·push 전 최소 회귀다. 전체 테스트, 장시간 시뮬레이션, 멀티브라우저 E2E, dist 블랙박스, release asset·Pages 확인은 CI에서 확인할 수 있다. 다만 이 지침은 주문서의 명시적 로컬 검증을 삭제하거나 축소하는 규칙이 아니다.

## claude_only_required / claude_execute / claude-direct 분기

라우터 결과가 `claude_only_required`(logic)이면 반환된 `resumeCommand`(`/operation-3-claude <n>`)만 안내하고 중단한다.

라우터 결과가 `claude_execute` 또는 `claude-direct`이면 (요구 모델이 현재 세션과 일치할 때):
1. `orderPath`를 읽는다.
2. 고정 실행 계약과 이슈 주문서를 현재 세션이 수행한다.
3. 주문서에 고정된 expected branch에서 의미 단위 커밋을 만들고 expected remote branch에만 push한다.
4. 반환된 `postflightCommand`를 반드시 실행한다.
5. postflight 결과만 보고한다.

`claude_execute` JSON을 표시만 하고 끝내지 않는다.

## 출력
라우터 최종 JSON의 workflow mode, work branch, Draft PR, CI, push 상태를 짧게 요약해 표시한다. Operation 3은 `merge_ready`를 판정하거나 자동 병합하지 않는다. 전체 로그는 대화에 넣지 않는다.
