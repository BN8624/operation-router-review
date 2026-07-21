---
name: operation-1-claude
description: 작전 1 Claude-only 재개 — Grok·GPT가 모두 차단됐을 때 현재 Sonnet 세션이 라우터의 claude_execute 지시(고정 실행 계약+이슈 원문)를 직접 구현한다. GitHub 이슈 번호를 인수로 받는다.
argument-hint: <이슈번호>
disable-model-invocation: true
model: claude-sonnet-5
effort: high
---

# 작전 1 Claude-only (Sonnet 직접 수행)

이 Skill은 Claude Sonnet 5 / high 세션에서만 실행된다 (frontmatter 고정). 라우터의 작전 1 Claude-only 요구 모델(config `claudeOnly.1` = claude-sonnet-5 / high)과 구조적으로 일치한다. 작전 1은 고위험이므로 v2.4.0에서 effort를 medium→high로 올렸다(작전 1의 다른 슬롯과 동일).
이슈번호는 slash-command 첫 위치 인수 `$0`에서 읽는다. 실행기는 `operation-router.cmd`만 사용한다.
PowerShell은 `$env:USERPROFILE` 경로, Git Bash는 `$USERPROFILE` 경로를 사용한다.

`/operation-1`이 `claude_only_required`를 반환하면 이 Skill이 resumeCommand(`/operation-1-claude <이슈번호>`)로 안내된다.

## 실행 절차 (이 순서대로만)

1. 라우터를 `-ClaudeOnly`로 1회 호출한다.
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command run -Operation 1 -IssueNumber $0 -ClaudeOnly
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command run -Operation 1 -IssueNumber $0 -ClaudeOnly
```
2. 반환 status가 `claude_execute`면 `orderPath`를 읽는다.
3. 고정 실행 계약과 이슈 주문서를 현재 Sonnet 세션이 직접 구현한다 (주문서 범위 밖 확장 금지).
4. 의미 단위 커밋·origin/main push를 완료한다.
5. 반환된 `postflightCommand`를 반드시 실행한다.
6. postflight 결과만 짧게 보고한다.

`claude_execute` JSON을 표시만 하고 끝내지 않는다. 재라우팅·재귀 handoff·다른 작업자 호출은 없다.
GPT Sol 독립 검수는 Grok 구현 결과에만 적용되므로, 이 경로의 결과는 검수 없이 사용자·외부 ChatGPT 검토로 넘어간다.

## 출력
postflight JSON(status/startHead/finalHead/commitCount/ahead/behind/pushComplete/ciStatus/remainingProblems)을 짧게 요약해 표시한다. 이슈 원문·장문 로그는 대화에 넣지 않는다.
