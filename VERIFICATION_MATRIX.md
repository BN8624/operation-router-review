# VERIFICATION_MATRIX — operation-router

검증 경로별 상태·증거. E2E는 공개 저장소 `BN8624/operation-router-e2e-20260720-175914`에서 실행했고, 실패·격리 경로는 mock/fake-git 테스트로 검증했다. 마지막 갱신 2026-07-21.

## 실전 E2E (유료 워커 호출)

| ID | 경로 | 모델/effort | 이슈 | 커밋 | 테스트 | CI | 판정 |
|----|------|------------|------|------|--------|----|----|
| V01 | 작전3 grok mechanical | grok-4.5 low | — | — | — | — | PASS |
| V02 | 작전3 grok logic | grok-4.5 low | — | — | — | success | PASS |
| V03 | 작전3 GPT Luna mechanical | gpt-5.6-luna low | #4 | 08ed0ee | — | success | PASS |
| V04 | 작전3 GPT Terra logic | gpt-5.6-terra medium | #5 | d3f2c6d | 8/8 | success | PASS |
| V05 | 작전3 Claude Haiku mechanical | claude-haiku-4-5 | #8 | 061aa85 | — | success | PASS |
| V06 | 작전3 Claude Sonnet logic | claude-sonnet-5 low | #9 | deba2a0 | 15/15 | success | PASS |
| V07 | 작전2 grok primary | grok-4.5 medium | — | — | — | — | CONDITIONAL_PASS¹ |
| V08 | 작전2 GPT Terra | gpt-5.6-terra medium | #6 | c0c9bc5 | 11/11 | success | CONDITIONAL_PASS¹ |
| V09 | 작전2 Claude-only | claude-sonnet-5 medium | #10 | c5bc458 | 17/17 | success | PASS |
| 4-1 | 작전2 Sonnet 검토자 재검증 | 검토 sonnet-5 ×2 / 구현 grok-4.5 medium | #7 | 5fa030b | 13/13 | success | PASS² |
| V11 | 작전1 grok 구현 + sol 검수 PASS | grok-4.5 high / 검수 terra³ high | #13 | 58f544e | — | success | PASS_PENDING_SOL_RETEST³ |
| V12 | 작전1 sol 검수 후 grok 수리 | repair grok-4.5 medium 1회 | #16 | (no_commit) | — | not-checked | PASS_PENDING_SOL_RETEST³⁴ |
| V13 | 작전1 GPT 구현 fallback | terra³ high, review_not_eligible | #14 | ad178c3 | — | success | PASS_PENDING_SOL_RETEST³ |
| V14 | 작전1 Claude-only | claude-sonnet-5 medium⁵ | #15 | b50e285 | 22/22 | success | PASS |
| V15 | 작전1 검수 예비분 off/on | off=claude_review_fallback / on=terra³ 검수 | #16 | 952d399 | — | success | PASS_PENDING_SOL_RETEST³ |

¹ V07·V08: 최초 실행 시 검토자가 설계상 Sonnet 5가 아닌 Fable 5였음. 4-1에서 Sonnet 5 서브에이전트 검토자로 재검증하여 편차 해소.
² 4-1: 시작·종료 검토를 Claude Sonnet 5 서브에이전트가 수행(자기 보고 claude-sonnet-5), 구현은 원설계 grok-primary. Fable은 지휘·전달만.
³ **PASS_PENDING_SOL_RETEST**: 작전 1의 sol 역할을 `gpt-5.6-terra`가 임시 수행한 상태로 검증했다. Terra 실행은 라우터·검수 파서·수리 역학을 확인한 **유효한 선행 검증**이며, 작전 1 canon의 Sol 역할 자체는 변경하지 않는다. 주 사용 계정은 Codex 한도 소진으로 Sol을 실행할 수 없었고, 별도 E2E 테스트 계정에서는 Sol이 models_cache에 노출되지 않아 doctor가 unresolved로 판정했다. 따라서 테스트 환경에서만 Sol을 Terra로 임시 매핑했다. 한도가 복구되고 Sol이 노출되는 계정에서 V11~V13·V15를 **동일 조건으로 재검증**하고, 그 통과 후에만 최종 PASS로 승격한다. V14는 Claude-only 경로라 Sol과 무관하므로 최종 PASS다.
⁴ V12: repair가 grok/medium 1회·finding만 전달·HEAD 가드 통과·2차 검수 없음·no_commit을 `repair_postflight_failed`로 정직 반환하는 역학을 검증. 원 finding은 자동 해소 처리하지 않음. 검수 영수증이 Terra 검수에서 나왔으므로 Sol 재검증 대기에 포함한다.
⁵ V14 실행 시점 effort는 medium. v2.4.0에서 정책 B로 high로 상향(정적 테스트로 검증, 유료 재검증은 후순위).

## 정적/격리 검증 (테스트 219/219 PASS, v2.4.5)

| 영역 | 검증 |
|------|------|
| 라우팅 | 작전×사용량×kind별 모델/effort/status 매핑, 임계값(grok 85/95, gpt 60/80), tier1/2/3 |
| fallback | weekly/transient/provider 3분류, 연속 전환(grok→gpt→claude), 부분 변경 guard, 루프 guard |
| postflight | no_commit/dirty/push_incomplete/not_on_main, CI 집계(success/failure/pending/unavailable), 실패 시 CI 미조회 |
| 워커 오류 | stopReason 분류(Cancelled/MaxTurns/protocol), exit 0≠성공, usage 불변 |
| 영수증 | owner/repo+canonical root SHA-256 namespace, clone 격리, owner/root 동시 검증, exact-root legacy migration, review/repair 자격 강제 |
| 실행 영속화 | worker 시작 전 generation receipt, active raw partial 관찰, terminal 마스킹 보존본·prompt/raw 삭제, terminal retention 10, active·최신 generation 보존 |
| recover | worker 호출 0회, 정상 result postflight 재개, result 유실 `*_unverified`, provenance 저장, unverified Sol review/repair 0회 |
| live probe | v2.4.5 유료 Grok·GPT live 호출 없음. v2.4.4의 과거 격리 Grok 1회는 역사 증거이며 이번 버전 PASS 근거로 승격하지 않음 |
| 보안 | secret 마스킹(+SHA/UUID 오탐 제외), critical tree 추가·수정·삭제 사후 탐지, state/log/execution 제외, 경로 이탈 삭제 거부 |
| 정책 A/B/C | disable-model-invocation, 자연어 호출 soft confirmation policy(코드 강제 게이트 아님), claudeOnly.1 high, highRiskWarning |
| 격리 | 로그 runtime/test 분리, usage-state 임시 격리, 삭제 경로 검증 |
| 재현성 | manifest-sha256 전수 일치, Skill 소스=설치본, secret 미포함 |

## Pending / 조건부

| 항목 | 상태 |
|------|------|
| sol 실제 모델 재검증 | 한도 복구 + Sol 노출 계정에서 config 매핑 원복 후 V11~V13·V15 재실행 → 통과 시 최종 PASS 승격 |
| 작전 1 Claude-only high 유료 재검증 | 정책 B는 정적 검증 완료. effort high 실전 재확인은 선택 |
| 외부 정적 검토 | v2.4.5는 사용자 지시에 따라 다른 Grok·Claude·Codex CLI 없이 직접 구현. 별도 외부 검토 미실행 |
