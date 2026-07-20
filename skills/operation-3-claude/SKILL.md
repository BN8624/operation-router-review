---
name: operation-3-claude
description: 작전 3 logic Claude-only 재개 — Grok·GPT가 모두 차단된 소규모 로직 작업을 현재 Sonnet 세션이 라우터의 claude_execute 지시(고정 실행 계약+이슈 원문)로 직접 구현한다. GitHub 이슈 번호를 인수로 받는다.
argument-hint: <이슈번호>
disable-model-invocation: true
model: claude-sonnet-5
effort: low
---

# 작전 3 logic Claude-only (Sonnet 직접 수행)

이 Skill은 Claude Sonnet 5 / low 세션에서만 실행된다 (frontmatter 고정). 라우터의 작전 3 logic Claude-only 요구 모델(config `claudeOnly.3.logic` = claude-sonnet-5 / low)과 구조적으로 일치한다.
이슈번호는 slash-command 첫 위치 인수 `$0`에서 읽는다. 실행기는 `operation-router.cmd`만 사용한다.
PowerShell은 `$env:USERPROFILE` 경로, Git Bash는 `$USERPROFILE` 경로를 사용한다.

`/operation-3 --kind logic`이 `claude_only_required`를 반환하면 이 Skill이 resumeCommand(`/operation-3-claude <이슈번호>`)로 안내된다.
작전 3 `mechanical`은 이 Skill 대상이 아니다 — 기존 Haiku `claude_direct` 흐름을 그대로 쓴다.

## 실행 절차 (이 순서대로만)

1. 라우터를 `-ClaudeOnly`로 1회 호출한다.
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command run -Operation 3 -IssueNumber $0 -Kind logic -ClaudeOnly
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command run -Operation 3 -IssueNumber $0 -Kind logic -ClaudeOnly
```
2. 반환 status가 `claude_execute`면 `orderPath`를 읽는다.
3. 고정 실행 계약과 이슈 주문서를 현재 Sonnet 세션이 직접 구현한다 (주문서 범위 밖 확장 금지).
4. 의미 단위 커밋·origin/main push를 완료한다.
5. 반환된 `postflightCommand`를 반드시 실행한다.
6. postflight 결과만 짧게 보고한다.

`claude_execute` JSON을 표시만 하고 끝내지 않는다. 재라우팅·재귀 handoff·다른 작업자 호출은 없다.

## 출력
postflight JSON(status/startHead/finalHead/commitCount/ahead/behind/pushComplete/ciStatus/remainingProblems)을 짧게 요약해 표시한다. 이슈 원문·장문 로그는 대화에 넣지 않는다.
