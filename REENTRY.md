# REENTRY — operation-router v2.4.7-1 watch-first execution

## 현재 상태

- 기준 버전은 v2.4.7-1이다.
- 라우팅 모델, Grok 85/95 임계값, GPT 60/80 tier, weekly/transient/provider 분류, fallback, Claude-only 모델·effort 정책은 v2.4.6과 동일하다.
- `run -Detach`는 receipt와 progress journal을 만든 뒤 worker-host를 한 번 시작하고 즉시 반환한다.
- `watch -Follow`는 repository identity, execution ID, generation에 고정되어 진행 이벤트를 표시하고 worker 종료 뒤 기존 recover/postflight를 한 번 재개한다.
- Operation 1은 terminal `review`/`opus_end_review`/`manual_verification`/`stop`, Operation 2는 `sonnet_end_review`/`stop`, Operation 3은 `report`를 반환한다.
- v2.4.7부터 `run -Detach`는 `watch -Follow`와 함께 사용하며 `operation_terminal` 뒤 `nextAction`을 수행한다.
- recover는 Claude 세션이 이미 종료되었거나 사용자가 나중에 새 세션으로 재진입할 때만 사용한다. watch가 살아 있는 동안 수동 호출하지 않는다.
- result envelope가 유실된 recover는 계속 unverified이며 Operation 1 review/repair 자격이 없다.
- active prompt/raw artifact, terminal sanitization, execution retention, watched critical-file 검사 정책은 유지된다.

```text
run -Detach → watch -Follow → operation_terminal → nextAction
```

## 주요 파일

- `scripts/progress.ps1` — progress 초기화, lock 기반 JSONL append, GPT observable parser, formatting, nextAction
- `scripts/worker-host.ps1` — output/Git/heartbeat/worker lifecycle 관찰
- `scripts/run-operation.ps1` — detach, watch, recover/postflight terminal handoff
- `config/config.json` — progress polling, heartbeat, summary, journal, checkpoint 설정
- `skills/operation-1/SKILL.md`, `skills/operation-2/SKILL.md` — detach 후 자동 follow와 현재 Claude 세션 종료 검토

## 검증

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-installed-fixture.ps1
git diff --check
git rev-list --left-right --count origin/main...HEAD
```

예상·확정 기준은 source-tree 247/247, failed/skipped/pending/inconclusive 0, installed Skill 6/6 일치, installed integration failures 0이다. 유료 Grok/GPT/Claude live 호출은 0회다.

## 알려진 한계

- progress는 관찰 가능한 process/output/Git/test/terminal 사실이며 reasoning이나 모델 내부 사고를 보여주지 않는다.
- Grok incremental streaming이 확인되지 않은 환경에서는 command 단위가 아니라 output 크기와 Git 변화, heartbeat 중심이다.
- watch를 종료해도 worker는 계속 실행되며 동일 명령으로 재접속한다.
- active 실행 중 prompt/raw 파일은 일시적으로 존재한다. terminal sanitization 뒤 제거된다.
- watched critical-file 검사는 OS sandbox가 아니며 비감시 파일 접근·읽기·외부 전송을 막지 못한다.
- 유료 live E2E를 실행하지 않았으므로 실제 provider CLI 품질을 이번 릴리스 PASS 근거로 주장하지 않는다.
