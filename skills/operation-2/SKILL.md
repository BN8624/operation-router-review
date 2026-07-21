---
name: operation-2
description: 작전 2 — 일반 복합 구현. 현재 Sonnet 세션이 좁은 시작 검토 → Grok 또는 GPT Terra 구현 → 종료 검토 1회를 수행한다. GitHub 이슈 번호를 인수로 받는다.
argument-hint: <이슈번호> [--finish-current] [--claude-only]
disable-model-invocation: false
model: claude-sonnet-5
effort: medium
---

# 작전 2 (일반 복합 구현)

이 Skill은 Claude Sonnet 5 / medium 세션에서만 실행된다 (frontmatter 고정).
이슈번호는 slash-command 첫 위치 인수 `$0`에서 읽는다. 실행기는 `operation-router.cmd`만 사용한다.
PowerShell은 `$env:USERPROFILE` 경로, Git Bash는 `$USERPROFILE` 경로를 사용한다.

## 자동 호출 시 실행 전 확인 (v2.4.0)
`disable-model-invocation: false`라서 사용자가 자연어로 지시하면 모델이 이 Skill을 호출할 수 있다. 단, `run`은 유료 워커 호출과 origin/main 직접 push로 이어지므로, 사용자가 `/operation-2 ...` 슬래시 명령을 직접 입력한 경우가 아니면 실행 전에 반드시 확인을 받는다.
1. 먼저 `status`(읽기 전용, 무료)로 예상 워커를 파악한다.
2. "작전 2, 이슈 #<번호>, 예상 워커 <grok/gpt/claude·비용 발생 여부>. 실행할까요?"를 제시하고 사용자 확인(예)을 받은 뒤에만 `run`을 실행한다.
슬래시 명령 직접 입력은 이미 명시적 실행이므로 이 확인을 생략한다.

## 1. 좁은 시작 검토 (최대 3개 명령)
- HEAD·branch·worktree, 주문서의 명백한 충돌만 확인
- 기술 조사·저장소 전수조사 금지. 3분 이내 작업자 실행을 목표로 한다.

## 2. 작업자 구현 — 라우터 1회 실행
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command run -Operation 2 -IssueNumber $0 [-FinishCurrent] [-ClaudeOnly]
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command run -Operation 2 -IssueNumber $0 [-FinishCurrent] [-ClaudeOnly]
```
- Grok 사용 가능 → Grok 4.5 / medium
- Grok 소진·GPT 작업 허용 → GPT-5.6 Terra / medium
- GPT 80% 이상 → `status: claude_only_required`(claude-sonnet-5) 반환. 이 Sonnet 세션이 반환된 `resumeCommand`(`/operation-2 <n> --claude-only`)로 직접 구현을 이어갈 수 있다.
- Grok 85~94%면 신규 실행이 보호 차단된다(기존 마감은 `--finish-current`).

## 3. 종료 검토 (최대 1회)
- 전체 저장소를 읽지 않는다. 시작 HEAD 대비 변경 diff, 주문서 핵심 완료 기준, 테스트·커밋·push·worktree 상태만 확인.
- 결함 발견 시 자동 재구현하지 않고 `REPAIR_REQUIRED`로 보고한다.

## claude_only_required / claude_execute 분기

라우터 결과가 `claude_only_required`이면 반환된 `resumeCommand`(`/operation-2 <n> --claude-only`)만 안내하고 중단한다.

라우터 결과가 `claude_execute`이면 (요구 모델이 현재 세션과 일치할 때):
1. `orderPath`를 읽는다.
2. 고정 실행 계약과 이슈 주문서를 현재 세션이 수행한다.
3. 의미 단위 커밋·push를 완료한다.
4. 반환된 `postflightCommand`를 반드시 실행한다.
5. postflight 결과만 보고한다.

`claude_execute` JSON을 표시만 하고 끝내지 않는다.

## 출력
라우터 최종 JSON을 짧게 요약해 표시한다. 작업자 전체 출력·이슈 원문·장문 로그는 대화에 넣지 않는다.
