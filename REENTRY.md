# REENTRY — operation-router v2.3.5 완성 검증

## 현재 버전과 승인 상태

- 설치 런타임은 `~/.claude/operation-router`의 v2.3.5 수리본이다.
- v2.3.3 전체 백업은 `~/.claude/backups/operation-router.bak.v2.3.3.20260721-000909/`에 있다.
- v2.3.4 전체 백업은 `~/.claude/backups/operation-router.bak.v2.3.4.20260721-004357/`에 있다.
- v2.3.4는 로그 격리와 검토본 재현성을 수리했고 166/166 source-tree 테스트를 통과했다.
- v2.3.5는 V03 1차 실행에서 확인된 최종 작업자 예외·UTF-8 stdin 결함만 좁게 수리한다.
- 라우팅·모델·effort·권한·fallback 정책은 바꾸지 않았다.

```yaml
verified:
  V01: PASS
  V02: PASS
  V03: PASS                # 2026-07-21 재실행. Luna low 직접 구현, 이슈#4, docs/plan-b.md, 커밋 08ed0ee, CI success, grok 0회
  V04: PASS                # 이슈#5, Terra medium, slug max_length + 테스트 3개, 커밋 d3f2c6d, 테스트 8/8, CI success
  V07: CONDITIONAL_PASS    # 종료 검토 모델이 설계상 Sonnet 5가 아닌 Fable 5였음
  V08: CONDITIONAL_PASS    # 이슈#6, 작전2 Terra medium, 파일 3개, 커밋 c0c9bc5, 테스트 11/11, CI success, branch/PR 없음 — 시작·종료 검토자가 Sonnet 5가 아닌 Fable 5 (V07과 동일 편차)
notApproved:
  operationRouter_v2_3_5_full: true
blocked:
  V11_V12_V13_V15_sol: "gpt-5.6-sol이 2026-07-21 models_cache에서 제거됨 — 사용자 결정 필요"
usageState:
  note: "V03/V04/V08 성공 후 주문서에 따라 /operation reset 실행"
next:   # 2026-07-21 사용자 확정 순서
  - static_defects_4_repair_and_full_tests   # 이번 사이클 범위는 여기까지
  - V07_V08_sonnet5_reverify                 # 4-1 결정: Fable 공식화 금지, Sonnet 5로 작은 작전 2 1회 재검증. Sonnet 실행 불가 시 BLOCKED_BY_REVIEWER_AVAILABILITY로 남기고 다음으로
  - V05_V06_V09_claude_only
  - V10_repair_required_fixture
  - security_and_install_verification
  - v2_4_0_final_docs
  - operation1_V11_V15_hold                  # sol 제거. 임의 모델 치환·canon 변경 금지
```

### 2026-07-21 정적 결함 4건 수리 (외부 검토 지적)

- P1: 비ASCII 명령줄 전경 실행이 상속 실행으로 폴백하며 `< NUL`을 잃던 경로를 제거했다. 비ASCII 문자열을 배치 본문에 쓰지 않고 유니코드 환경변수 참조("%VAR%")로 전달해 NUL 고정을 유지한다. 테스트 20 추가(STDINLEN=0 + 한글 인수 왕복).
- P2: UTF-8 stdin 테스트 19가 실제 한글 디렉터리(`한글 경로/`)에서 stdin 파일을 전송하도록 확장해 문서의 "한글 경로 검증" 주장과 테스트 범위를 일치시켰다.
- P2: config `_comment`의 codex 모델 목록을 현재 환경(terra/luna, sol 제거·fail-closed)에 맞게 갱신했다.
- P2: README 오류 분류 서술을 코드 정본(weekly → transient → quota_unknown → provider, 명시적 weekly는 429 동반에도 우선)에 맞췄다.

### 2026-07-21 V03 재실행 전 무료 probe 수리

- 외부 검토 지적대로 codex는 npm shim 3종(codex.ps1/.cmd/확장자 없음)이고 `Get-Command` 단건은 .ps1을 먼저 반환해 `Process.Start`가 실패했다.
- resolver를 `Get-Command -All`에서 Application(.exe/.cmd/.bat) 우선 선택으로 좁게 수리했다. 무료 probe 결과 exitCode 0, `codex-cli 0.144.5`.
- 수리 후 전체 168/168 PASS 유지, 검토 저장소 커밋 9564386에 반영.

Grok 기본 구현 경로는 사용할 수 있다. GPT Plan B와 전체 라우터는 아직 승인 전이다.

## v2.3.4 로그·검토본 격리

```text
logs/
  runtime/                 새 실전 로그, runtime 안에서만 최근 20개 회전
  tests/<test-run-id>/     mock 로그, 해당 실행 디렉터리만 정리
  *.log                    v2.3.3 이전 실전 증거, 동결
```

- source-tree 테스트의 상태·pending·temp·로그는 고유 시스템 임시 루트에서만 생성한다.
- 기본 Skill 검사 경로는 검토본 내부 `skills/`다.
- 설치 Skill 검사는 `-InstalledIntegration`을 명시한 경우에만 별도로 실행한다.
- 기존 v2.3.3 평면 실전 로그 `logs/*.log` 20개는 이동·수정·회전하지 않는다.
- 검토 ZIP은 실제 usage-state, 인증 정보, 전체 모델 원문 로그를 포함하지 않는다.

## v2.3.5 최종 작업자 계약 수리

- 고정 실행 계약은 ASCII 첫 줄 `[OPERATION_ROUTER_FINAL_WORKER]`로 시작한다.
- 전역 `~/.claude/CLAUDE.md`와 `~/.codex/AGENTS.md`에 마커 세션의 Operation 1/2/3 재위임 예외를 바이트 동일하게 추가했다.
- 전역 규칙 두 파일의 현재 SHA-256은 모두 `62D2DF237E43C0E605BEEAFE89F5D85B50D7903B919A46219F51383EEA40C1B9`다.
- (2026-07-21 재수리) `$OutputEncoding` 고정 방식은 BOM 누출을 막지 못하는 것이 바이트 실측으로 확인됐다. PS 5.1 파이프라인과 .NET Process 기본 stdin writer는 콘솔 CP 65001에서 자식 stdin 선두에 BOM(EF BB BF)을 삽입한다.
- 최종 구현은 `System.Diagnostics.Process` 직접 실행이다. 주문서 파일의 원시 UTF-8 바이트(파일 BOM 제거)를 stdin에 기록하고 명시적으로 닫으며, `Console.InputEncoding`을 Start 전후 BOM 없는 UTF-8로 교체·원복하고, stdout·stderr·exit code를 각각 수집한다.
- 한글 계약을 native 자식 프로세스에 보내 바이트를 역직렬화하는 회귀 테스트(ordinal 비교로 BOM 검출)와 마커 계약 테스트를 추가했다. 한글 경로·마커 첫 바이트·"다른 CLI에 위임하지 말고 직접 구현한다" 문구 보존을 바이트 단위로 확인했다.

## 검증 현황 (2026-07-21 확정)

- v2.3.5 source-tree 테스트: 168/168 PASS
- v2.3.5 설치 Skill 통합 검사: 불일치 0/6 (SHA-256 byte-identical)
- 격리 검증: 테스트 3회 실행 후 동결 로그 20개·runtime 로그 1개 수·이름·해시 불변, 실제 usage-state SHA-256 불변, `logs/tests/` 비어 있음, 시스템 임시 test workroot 잔존 0
- 전역 규칙: `~/.claude/CLAUDE.md`와 `~/.codex/AGENTS.md` SHA-256 동일(`62D2DF23...40C1B9`), 백업은 `backups/operation-router.bak.v2.3.4.../global-rules/`
- manifest-sha256: 전수 재계산·일치
- 외부 독립 검토: 미실행

### 2026-07-21 환경 변화 — gpt-5.6-sol 제거 (작전 1 차단 요인)

- `~/.codex/models_cache.json`이 2026-07-21 01:27 갱신되며 `gpt-5.6-sol`이 목록에서 사라졌다 (terra·luna·5.5·5.4-mini만 남음).
- doctor는 sol을 `unresolved`로 정직하게 보고하고, invoke-gpt는 unresolved 모델을 fail-closed로 거부한다 (기존 테스트로 보장).
- doctor 테스트는 luna·terra 정확 일치 + sol은 `정확 slug 또는 unresolved` 허용으로 좁게 수정했다. 라우팅·config·모델 정책은 변경하지 않았다.
- 영향: V03·V04·V08(luna/terra)은 진행 가능. V11~V13·V15의 Sol 검수·구현 경로는 sol 재등장 또는 설계 변경 결정 전까지 실행 불가 — 사용자 결정 필요.

## 현재 usage-state

- grok = exhausted/100
- gpt = available/0
- Plan B 검증용 상태이므로 V03·V04·V08 성공 전에는 reset하지 않는다.

## E2E 저장소와 이슈 #4

- 저장소는 `C:\Users\USER\scratchpad\operation-router-e2e-20260720-175914`다.
- 현재 기준 HEAD는 `effe08c3bf15a067c186f68adaf346376ab61ce9`이다.
- 브랜치는 main이고 origin/main 앞·뒤 0/0, worktree clean을 유지한다.
- 이슈 #4는 OPEN, 댓글 0개여야 한다.
- expected file은 `docs/plan-b.md`다.
- expected commit은 `docs: add plan b marker`다.

### V03 1차 실행 결과

- route=`gpt-plan-b`, worker=`gpt`, model=`gpt-5.6-luna`, effort=`low`까지는 일치했다.
- 결과는 `no_commit`이었고 start/final HEAD는 모두 `effe08c3bf15a067c186f68adaf346376ab61ce9`, commitCount=0이었다.
- Luna가 전역 Operation Modes를 자신에게 적용해 Grok 사전 점검과 호출을 시도했고, Grok은 미인증 상태로 실패했다.
- Luna 세션에서 한글 고정 계약이 mojibake로 전달된 것을 원문 JSONL로 확인했다.
- 실제 파일·커밋·push·이슈 변경은 0건이다.
- 실전 로그는 `~/.claude/operation-router/logs/runtime/20260720-153824-155-op3-issue4.log`다.

V03 성공 기준은 route=`gpt-plan-b`, worker=`gpt`, model=`gpt-5.6-luna`, effort=`low`, Grok 호출 0회, 변경 파일 1개, 커밋 1개, origin/main push 완료, CI success다. Codex가 다른 CLI에 재위임하지 않고 직접 구현해야 한다.

## 다음 실행 순서

1. v2.3.5 자체 검증과 검토 ZIP 재현성을 통과한다.
2. v2.3.5 외부 독립 검토 PASS를 확인한다.
3. 기존 이슈 #4에서 V03을 추가 승인된 1회로 재실행한다.
4. V03이 완전히 성공한 경우에만 V04 Terra logic을 실행한다.
5. V04가 성공한 경우에만 V08 Operation 2 Terra를 실행한다.
6. Claude-only와 나머지 6개 Skill 기능 검증 공백을 해소한다.
7. 모든 기능과 최종 통합 검토가 PASS한 뒤에만 `/operation reset`을 실행한다.

V03에서 GPT가 직접 구현하지 못하면 V04·V08로 넘어가지 않는다.

## 프로젝트 완성 조건

- 6개 Skill의 모든 사용자 명령과 Grok·GPT·Claude 라우팅이 정상 동작한다.
- 정상 구현 경로는 실제 E2E, 소진·취소·dirty·위험 삭제 같은 실패 경로는 격리 mock/integration으로 검증한다.
- V07 조건부 승인을 해소하거나 canon에서 편차를 명시적으로 수용한다.
- source-tree 테스트, 설치 통합 테스트, PowerShell 구문, config JSON, manifest, ZIP 재실행이 모두 PASS한다.
- 최종 증거 ZIP을 만든 뒤 외부 통합 검토가 PASS한다.
- 마지막에 usage-state를 reset하고 설치본·E2E 저장소의 clean/sync 상태를 확인한다.
- 그때만 `operationRouter_v2_3_5_full: approved`로 기록한다.
