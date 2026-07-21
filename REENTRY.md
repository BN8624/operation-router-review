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
  V41_sonnet_reverify: PASS  # 2026-07-21 이슈#7. 시작·종료 검토 모두 Sonnet 5 서브에이전트(agentId ab09331…/a8eae06…, 자기보고 claude-sonnet-5), Grok 4.5 medium 구현(grok-primary), 커밋 5fa030b, 테스트 13/13, CI success. Fable은 지휘·전달만. V07/V08의 검토 모델 편차 해소 — canon(Sonnet 검토자)은 유지
  V05: PASS                # 이슈#8. grok exhausted+gpt80, op3 mechanical → claude_execute(haiku). Haiku 4.5 직접 한 줄 수정, 커밋 061aa85, push·CI success, 외부 CLI 0
  V06: PASS                # 이슈#9. op3 logic → Haiku claude_only_required 비구현 정지(파일 0) → Sonnet 전용 흐름 -ClaudeOnly resume → claude_execute, 파일 2, 테스트 15/15, 커밋 deba2a0, CI success, 재귀 0
  V09: PASS                # 이슈#10. op2 → claude_only_required → 같은 Sonnet 세션 -ClaudeOnly 1회 → claude_execute, 파일 3, 테스트 17/17, 커밋 c5bc458, CI success, 외부 CLI 0, 재귀 0
  V10: PASS                # 이슈#12 단계형 fixture(테스트 저장소). 1단계 커밋 7cd33f4(의도적 테스트 미포함) → Sonnet 종료 검토 REPAIR_REQUIRED + 구조화 finding 2건, 자동 수리 0, 2차 작업자 0, 커밋 보존, 이슈 비개입. (2단계는 이슈#14=V13에서 완결)
  V11_terra: PASS          # 이슈#13. Opus 지휘(agentId a756342…) → Grok 4.5 high 구현(58f544e) → sol역할(terra) high 검수 verdict PASS 정상 파싱 → Opus 최종 PASS. ※실전 결함 발굴·수리: 검수가 codex JSONL(agent_message.text 내 verdict)이라 review_parse_failed → 파서 수리+회귀 테스트(21), 170/170 PASS
  V12_terra: PASS          # 이슈#16 영수증. repair grok/medium 1회, finding만 전달(로그 실증), postReviewHead 가드 통과, 2차 sol 검수 없음, no_commit→repair_postflight_failed 정직 반환, 자동 해소 간주 없음
  V13_terra: PASS          # 이슈#14. grok exhausted → terra high 직접 구현(ad178c3) → review_not_eligible(worker_not_grok)로 자기검수 차단(GPT 미호출) → Opus 직접 종료 검토 PASS
  V14: PASS                # 이슈#15. grok exhausted+gpt reserved → claude_only_required → /operation-1-claude Sonnet 구현(b50e285, 22/22) → Opus 종료 검토 PASS, 외부 CLI 0
  V15: PASS                # 이슈#16. off: claude_review_fallback(GPT 미호출) / on(-UseGptReviewReserve): terra 검수 실호출 verdict 정상 파싱(REPAIR_REQUIRED+finding 1)
solRetestPending:
  note: "2026-07-22 config gpt.workers.sol을 gpt-5.6-sol로 원복. V11~V13·V15는 실제 Sol 재검증 전까지 대기"
notApproved:
  operationRouter_v2_3_5_full: true
blocked:
  V11_V12_V13_V15_sol: "Sol 매핑은 복구됨 — 실제 Sol E2E 재검증 미실행"
usageState:
  note: "V03/V04/V08 성공 후 주문서에 따라 /operation reset 실행"
next:   # ①~④ 및 작전1(V11~V15, terra 대체) 완료. ⑤ 일부 착수:
  - security_repo_boundary_done              # ⑤-1 완료(2026-07-21): deny 확장(9-1 위험명령) + postflight 저장소 경계 탐지(Test-RepoBoundaryViolation, status repo_boundary_violation 최우선). 테스트 177/177
  - security_secret_done                     # ⑤-2 완료(2026-07-21): Authorization(임의 스킴)/AWS/고엔트로피 마스킹 추가, git SHA·UUID 오탐 제외, env 전체 덤프 없음 확인. 178/178
  - install_lifecycle_EXCLUDED               # 사용자 결정 2026-07-21: 1인 사용이라 install.ps1/업그레이드/롤백 및 INSTALL.md/ROLLBACK.md는 범위 제외. 롤백은 ~/.claude/backups 폴더 복원으로 충분. 다음 세션은 설치기를 만들지 말 것.
  - deny_pattern_grok_probe_optional         # ⑤-3 선택: deny 중간 와일드카드(git push*+*) 실제 발동은 grok 프로브 필요 — 경계 탐지가 실질 방어라 후순위
  - v2_4_0_policy_ABC_done                    # ⑤.5 완료(2026-07-21): A(operation-1/2/3 disable-model-invocation=false+실행 전 확인게이트, 디스패처·claude변형은 true 유지), B(claudeOnly.1.effort medium→high, operation-1-claude frontmatter도 high), C(작전1 claude_only_required에 highRiskWarning 필드). 184/184. 검토 저장소 6b48665. 주의: SKILL.md는 설치본(~/.claude/skills)과 소스(~/.claude/operation-router/skills) 양쪽 동기화 필수(테스트·manifest는 소스 사용)
  - reverify_policy_ABC_optional             # A/B/C는 정적 테스트로 검증됨. 실전 재검증은 선택: 자연어 호출은 이 세션에서 이미 operation-1/2/3 Skill 도구 노출 확인됨. 작전1 claude-only high는 유료라 후순위(V14는 medium으로 이미 PASS, effort만 상향)
  - v2_4_0_docs_done                         # ⑥ 완료: 버전 통일, CHANGELOG/VERIFICATION_MATRIX/SECURITY 작성
  - v2_4_1_review_followup_done              # 완료: 외부 검토 6개 지적 수리(finalizer 통합 등). 193/193
  - v2_4_2_receipt_ordering_done             # 완료: run/review 영수증을 finalizer 확정 후 저장. 195/195
  - v2_4_3_receipt_generation_done           # 완료(2026-07-21): v2.4.2 재검토 REPAIR_REQUIRED 수리 — 영수증 키가 (작전+이슈+저장소) 고정이라 이전 세대가 남던 문제. HIGH 작전1 worker 호출 직전 기존 run·review 영수증 삭제(Remove-RunReceipt/Remove-ReviewReceipt), GPT 검수 호출 직전 review 영수증 삭제, 성공 시에만 재저장. 실패·경계위반 재실행/재검수 후 과거 completed/REPAIR_REQUIRED 영수증 미잔존. 신규 테스트 2(재실행→run 영수증 null+review GPT 0회 / 재검수→review 영수증 삭제). 197/197. 검토저장소 태그 v2.4.3
  - external_review_v2_4_3                    # 남음: 검토 저장소 링크(태그 v2.4.3)로 외부 재검토 1회
  - sol_retest_pending                       # 2026-07-22 config 매핑 원복 완료. V11~V13·V15 실제 Sol E2E 재검증 → 최종 PASS 승격 남음
optional_considered_not_scheduled:          # 사용자 논의됨, 미확정 — 별도 지시 전까지 손대지 않음
  - provider_effort_consistency             # 3-logic effort가 grok=low/gpt=medium/sonnet=low로 공급자마다 다름(작업 난이도 무관). 통일 여부는 사용자 결정 대기
  - op2_vs_op3logic_gpt_collapse            # GPT 경로에서 작전2와 작전3-logic이 둘 다 terra/medium으로 구분 소실. 차등 여부 사용자 결정 대기
```

## 다음 세션 시작 절차 (2026-07-21 준비)

1. 상태 점검 (3분):
   - `& "$env:USERPROFILE\.claude\operation-router\operation-router.cmd" -Command status` → grok/gpt 모두 available/0이어야 함
   - `& "$env:USERPROFILE\.claude\operation-router\tests\run-tests.ps1" -InstalledIntegration` → 170/170, 불일치 0/6 기대
   - 검토 저장소 `C:\Users\USER\operation-router-build\review-repo` = github.com/BN8624/operation-router-review, HEAD 4d0f21a, clean/0-0 확인
2. ⑤ 보안·설치 검증 (사용자 승인된 범위, mock/임시 환경 우선):
   - deny 프로브: grok --deny 목록이 force-with-lease·+main push·reset --merge/--keep·rm -r -f·Remove-Item·cmd del/rd·rmdir /s·format·diskpart·shutdown·reg delete를 실제 패턴 매칭으로 막는지 (README 목록과 config 대조 후 무료 프로브)
   - 저장소 경계: postflight에 repo 밖 변경 탐지 여부 확인, 없으면 좁게 추가 검토
   - secret: 로그·evidence 마스킹 재확인 (기존 테스트 29·16 + 고엔트로피 스캔)
   - 설치 lifecycle: 임시 사용자 프로필/임시 HOME에서 신규 설치 → status/doctor/테스트, v2.3.3→최종 업그레이드(백업·usage-state 보존), 롤백(백업 복원) — 실제 사용자 환경을 건드리지 않는 격리 방식만
3. ⑤.5 v2.4.0 정책 변경 3건 (사용자 확정 2026-07-21 — 라우팅 구조는 유지, 아래만 변경):
   A. **자연어 호출 허용 + 실행 전 확인**: operation-1/2/3 SKILL.md의 `disable-model-invocation: true`를 해제(또는 false). 대신 각 실행 Skill 계약에 "실행 전 반드시 작전번호·이슈번호·예상 워커(비용 발생 여부)를 한 줄 요약하고 사용자 확인을 받은 뒤 실행"을 추가. 디스패처(/operation)는 판단 필요 없음. 영향: 테스트 '2. disable-model-invocation: true'(4 Skill 단언)와 doctor skillFrontmatter 기대를 새 정책에 맞게 수정, README 사용법 갱신. 목적: 슬래시 직접 입력과 "스킬 써" 명시 호출의 불일치 제거(현재 operation-3만 Skill 도구 로드되고 1·2는 disable-model-invocation로 거부됨).
   B. **작전1 Claude-only 구현 effort medium→high** (3번 처방 1): config `claudeOnly.1.effort`와 `/operation-1-claude` frontmatter effort를 high로. 작전1의 다른 슬롯(grok/sol/opus 전부 high)과 일치시켜 유일 outlier 제거. 구현자↔검토자 분리(Opus 검토)는 유지. Opus를 구현자로 만들지 말 것(자기검수 재발).
   C. **작전1 claude_only_required 고위험 경고** (3번 처방 2): 작전1의 claude_only_required 반환 메시지/resumeCommand 안내에 "고위험 작전을 외부 구현·독립 검수 파이프라인 없이 진행하는 상황 — 스키마 마이그레이션 등 진짜 위험 작업이면 한도 리셋 대기 고려" 문구 추가. 차단 로직 아님(메시지·문서만). effort로 못 닫는 잔여 격차를 사용자가 인지하고 대기/강행을 선택하게 함.
   ※ A·B·C는 effort/모델/Skill 정책 변경이므로 적용 후 작전1 Claude-only 경로(V14 계열)와 자연어 호출 경로를 재검증한다. 라우팅·권한·fallback·로그/상태 격리는 건드리지 않는다.
   ※ 보류했던 대안(3번의 전역 CLAUDE.md 우회안)은 채택 안 함 — 모델 고정 무력화 때문. A안(확인 게이트)으로 확정.
4-docs. ⑥ v2.4.0 문서: CHANGELOG.md, VERIFICATION_MATRIX.md(V01~V15 + 4-1, 증거 커밋·CI 포함), SECURITY.md, INSTALL.md, ROLLBACK.md 작성 → 버전 v2.4.0 통일 → manifest 갱신 → 전체 테스트 → 검토 저장소 push·태그 v2.4.0
4. 외부 검토 1회 (검토 저장소 링크) → PASS 시 완성 판정. 유료 워커 호출은 이 범위에 필요 없음.
5. Sol 매핑 원복은 2026-07-22 완료. V11~V13·V15를 실제 Sol로 재검증한 후 †조건을 해제한다.

주의: 서브에이전트에 실행기를 위임할 때는 반드시 `Set-Location "<repo>"; <명령>`로 한 명령에 묶는다. E2E 저장소 이슈 #12(2단계 완결)·#16(검수 finding 1건)은 열린 상태가 정상이다.

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
- (2026-07-21 갱신) 전역 규칙에서 수동 Operation Modes(§2·§3)를 전면 삭제했다. 이유: operation-router 스킬이 라우팅·구현을 자동화하므로 "Opus가 Bash로 grok 직접 호출" 등 수동 절차가 스킬과 상충했다. 남긴 것은 §1 Task Canon, §2 operation-router 최종 작업자 예외(수동 모드 참조 제거·재서술), §3 Common Git/보고다. 부수 효과로 워커 CLI가 AGENTS.md에서 "grok에 위임" 지시를 더는 발견하지 못해 V03 1차 실패(Luna가 전역 규칙 따라 grok 호출 시도)의 근본 원인이 규칙 차원에서 제거됐다. 두 파일 현재 SHA-256은 모두 `508EA6BEBF7959159CA73B0D5873761115256D3F82CECFDD28527D3ECB82D49B`. 삭제 전 백업은 `~/.claude/backups/global-rules.bak.20260721-162155/`.
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
