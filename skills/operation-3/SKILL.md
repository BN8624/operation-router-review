---
name: operation-3
description: 작전 3 — 명확한 소규모 작업. 현재 Haiku 세션은 저장소를 조사하거나 검토하지 않고, 인수 검증 → 라우터 1회 실행 → postflight 결과 표시만 한다. GitHub 이슈 번호를 인수로 받는다.
argument-hint: <이슈번호> [--kind logic|mechanical] [--finish-current] [--claude-only]
disable-model-invocation: true
model: claude-haiku-4-5-20251001
effort: low
---

# 작전 3 (명확한 소규모 작업)

이 Skill은 Claude Haiku 4.5 / low 세션에서만 실행된다 (frontmatter 고정).
이슈번호는 slash-command 첫 위치 인수 `$0`에서 읽는다. 실행기는 `operation-router.cmd`만 사용한다.
PowerShell은 `$env:USERPROFILE` 경로, Git Bash는 `$USERPROFILE` 경로를 사용한다.

현재 Haiku 세션은 저장소를 조사하거나 코드를 검토하지 않는다. 역할은 다음뿐이다.
```
인수 검증 → 라우터 1회 실행 → postflight 결과 표시
```

## 실행
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command run -Operation 3 -IssueNumber $0 [-Kind logic|mechanical] [-FinishCurrent] [-ClaudeOnly]
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command run -Operation 3 -IssueNumber $0 [-Kind logic|mechanical] [-FinishCurrent] [-ClaudeOnly]
```

- 기본 kind는 `logic`. 기계적/로직 판단은 라우터가 LLM으로 추측하지 않고 인수로 받는다.
- Grok 사용 가능 → Grok 4.5 / low (no-plan, no-subagents)
- Grok 소진·GPT 작업 허용:
  - `--kind logic` → GPT-5.6 Terra / medium
  - `--kind mechanical` → GPT-5.6 Luna / low
- GPT 80% 이상:
  - `logic` → `status: claude_only_required`(claude-sonnet-5 / low). resumeCommand `/operation-3-claude <이슈번호>`(Sonnet 전용 Skill)를 안내한다.
  - `mechanical` → `status: claude_direct`(claude-haiku). 문서·버전 문자열·명백한 설정 치환처럼 기계적 작업만 현재 Haiku 세션이 직접 수행할 수 있다.

## claude_only_required / claude_execute / claude-direct 분기

라우터 결과가 `claude_only_required`(logic)이면 반환된 `resumeCommand`(`/operation-3-claude <n>`)만 안내하고 중단한다.

라우터 결과가 `claude_execute` 또는 `claude-direct`이면 (요구 모델이 현재 세션과 일치할 때):
1. `orderPath`를 읽는다.
2. 고정 실행 계약과 이슈 주문서를 현재 세션이 수행한다.
3. 의미 단위 커밋·push를 완료한다.
4. 반환된 `postflightCommand`를 반드시 실행한다.
5. postflight 결과만 보고한다.

`claude_execute` JSON을 표시만 하고 끝내지 않는다.

## 출력
라우터 최종 JSON을 짧게 요약해 표시한다. 전체 로그는 대화에 넣지 않는다.
