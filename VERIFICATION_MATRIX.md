# VERIFICATION_MATRIX — operation-router v2.4.7

## 격리 검증 요약

| 구분 | 수량/결과 | 근거 |
|---|---:|---|
| source-tree Pester | 245/245 PASS | `tests/run-tests.ps1` |
| v2.4.6 hotfix 회귀 | 2/2 PASS | receipt null poll, repair optional CLI binding |
| v2.4.7 progress | 6/6 PASS | metadata/schema/masking/limit/GPT parser/Git/injected worker |
| v2.4.7 detach/watch | 8/8 PASS | single start, active reuse, one-shot, follow/recover, generation guard, unverified, nextAction, stable read |
| v2.4.7 Skill 통합 | 3/3 PASS | Operation 1/2 follow와 Operation 3 report-only |
| 기존 v2.4.4 execution/recover 회귀 | 9/9 PASS | persistent receipt, duplicate guard, recover, OS process fixture |
| installed fixture | 6/6 Skill byte-identical, failure 0 | `tests/run-installed-fixture.ps1` |
| paid AI live call | 0 | Grok/GPT/Claude 미호출 |

전체 suite는 mock runner, fake Git remote, 임시 repository, 일반 PowerShell child process, 격리 USERPROFILE을 사용한다. 실제 provider CLI 호출은 사용하지 않는다.

## 기능별 판정

| 기능 | 판정 | 핵심 확인 |
|---|---|---|
| `run -Detach` | PASS | receipt 선저장, host 1회, 즉시 pending, active 재호출 workerCalls=0 |
| progress journal | PASS | JSONL 필수 필드, lock 내 seq, BOM 없음, secret masking, 500자, size suppression |
| GPT progress parser | PASS | command/file/agent update 분리, reasoning·malformed·unknown 무시, worker result parser와 독립 |
| Grok progress fallback | PASS(격리) | raw output 크기, Git/worktree/file/commit/push, heartbeat 기반 |
| watch one-shot/follow | PASS | generation 고정, 재접속 무변경, recover/postflight 1회, terminal marker |
| nextAction | PASS | op1 Grok/GPT, op2, op3, unverified, failure 분기 |
| stable receipt read | PASS | not-found/empty/parse/IO transient bounded retry, 최종 fail-closed |
| secret 보호 | PASS | progress와 watch에 prompt/raw/env/reasoning 원문 없음 |
| 기존 routing/fallback | PASS | v2.4.6 정책 유지 회귀군 |
| manifest | PASS | 배포 대상 전부 포함, 중복·누락 없음, manifest 자신 제외 |

## 과거 live/E2E와 구분

v2.4.4 이전의 E2E·live probe 기록은 역사 자료일 뿐 v2.4.7 PASS 근거로 승격하지 않는다. v2.4.7은 유료 live 호출 없이 정적·격리 fixture로 검증했다.

## 외부 검토 상태

사용자 지시에 따라 다른 Grok·Claude·Codex worker를 호출하지 않았다. 별도 외부 AI review는 미실행이다.
