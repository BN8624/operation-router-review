---
name: operation
description: operation-router 보조 명령. /operation status|doctor|set|reset과 중단 복구용 recover를 제공한다. 작전 실행은 /operation-1, /operation-2, /operation-3 를 쓴다.
argument-hint: status | doctor | recover <작전번호> <이슈번호> | set grok <0-100|available|exhausted> | set gpt <0-100|available|reserved|exhausted> | reset
disable-model-invocation: true
model: claude-haiku-4-5-20251001
effort: low
---

## v2.4.7 watch 명령

`/operation watch <작전번호> <이슈번호>`는 기존 worker를 새로 호출하지 않고 현재 execution의 progress journal과 완료 상태를 추적한다. `-Follow`를 사용하면 terminal 상태까지 기다리며, watch를 종료하거나 다시 연결해도 worker나 generation은 바뀌지 않는다.

```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command watch -Operation <작전번호> -IssueNumber <이슈번호> -Follow
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command watch -Operation <작전번호> -IssueNumber <이슈번호> -Follow
```

# operation (보조 명령 디스패처)

이 Skill은 가벼운 상태 관리 전용이다. 실제 작전 구현은 `/operation-1`, `/operation-2`, `/operation-3`가 담당한다 (각각 정적 모델·effort가 고정된 별도 Skill).

공통 실행기는 `operation-router.cmd` 하나뿐이다. `$ARGUMENTS`를 읽어 아래 명령 매핑 중 하나를 선택한다.
PowerShell 경로는 `$env:USERPROFILE\.claude\operation-router\operation-router.cmd`, Git Bash 경로는 `$USERPROFILE/.claude/operation-router/operation-router.cmd`를 사용한다.

## 명령 매핑

인수를 그대로 스크립트에 넘긴다. 스스로 해석해 다른 동작을 추가하지 않는다.

### `/operation status`
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command status
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command status
```

### `/operation doctor`
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command doctor
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command doctor
```

### `/operation set grok <0-100|available|exhausted>`
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command set -Target grok -Value <값>
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command set -Target grok -Value <값>
```

### `/operation set gpt <0-100|available|reserved|exhausted>`
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command set -Target gpt -Value <값>
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command set -Target gpt -Value <값>
```

### `/operation reset`
런타임 사용량 상태만 초기화한다. Skill·스크립트·config.json은 건드리지 않는다.
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command reset
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command reset
```

### `/operation recover <작전번호> <이슈번호>`
중단된 실행 세대의 프로세스·result·Git·CI·postflight만 확인한다. 외부 Grok/GPT worker를 새로 호출하거나 자동 재시도하지 않는다. 정상 result가 없으면 `recovered_*_unverified`로 반환하며 작전 1 review/repair 자격이 없고 검증 재실행 또는 수동 종료 검토가 필요하다.
```
& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command recover -Operation <작전번호> -IssueNumber <이슈번호>
# Git Bash: "$USERPROFILE/.claude/operation-router/operation-router.cmd" -Command recover -Operation <작전번호> -IssueNumber <이슈번호>
```

## 출력

스크립트가 반환한 JSON을 짧게 요약해 보여준다. 전체 원문 로그를 대화에 넣지 않는다.
`set grok`/`set gpt`는 숫자와 상태를 자동 정규화한다 (예: grok 95+ → exhausted, gpt 100 → exhausted).
