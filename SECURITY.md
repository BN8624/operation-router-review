# SECURITY — operation-router

라우터가 외부 워커 CLI(Grok/Codex)와 Claude 서브에이전트에게 GitHub 이슈를 위임해 코드를 구현·커밋·push하는 구조에서의 보안 경계와 방어층. 1인 사용 환경 기준.

## 위협 모델

- 워커 CLI가 주문서 범위를 벗어나 저장소 밖(전역 설정·홈·다른 저장소)을 수정.
- 워커가 위험 명령(force push, 히스토리 재작성, 대량 삭제, 시스템 명령)을 실행.
- 로그·검토 증거·workerSummary에 secret(토큰·키·Authorization) 노출.
- 워커가 전역 규칙을 읽고 다른 CLI로 재위임하거나 자기검수로 판정을 뒤집음.

## 방어층 (다중)

### 1. 저장소 경계 탐지 — 실질 방어
`Get-StartSnapshot`이 워커 실행 전 감시 경로의 SHA-256을 스냅샷하고, postflight `Test-RepoBoundaryViolation`이 실행 후 재검사한다. 변경 시 `status: repo_boundary_violation`으로 최우선 보고, CI 미조회. 감시 경로: 전역 `.gitconfig`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, 라우터 `config.json`·`common.ps1`. **명령 문자열이 아니라 결과 변경을 잡으므로** 플래그 재배열·`cmd /c` 래퍼·동의어 명령 우회에 강하다. (`scripts/prepare-operation.ps1`, `scripts/postflight.ps1`)

### 2. deny 블록리스트 — 1차 차단 (보조)
Grok 헤드리스 `--deny`가 명백한 위험 명령을 1차 차단한다(reset --hard/merge/keep, force push, `+main` refspec, rm 계열, rmdir/rd /s, format, diskpart, shutdown, reg delete). **한계**: 패턴 매칭이라 우회 가능하고 Grok 워커에만 적용된다. 그래서 1차 차단이며 실질 방어는 층 1이다. (`config/config.json` `grok.headlessPermissions.deny`, `_deny_note`)

### 3. 고정 실행 계약
모든 주문서 앞에 `[OPERATION_ROUTER_FINAL_WORKER]` 마커 + 계약이 붙는다: main에서만 작업, branch/PR 금지, force push·reset --hard·clean 금지, 시작 시 worktree clean, 커밋 메시지는 한 줄 인라인만(명령 치환·heredoc 금지 — 헤드리스 권한 정책이 차단), 이슈 비개입, secret·환경변수 출력 금지, 다른 CLI 재위임 금지. (`scripts/common.ps1` `Get-FixedExecutionContract`)

### 4. 전역 규칙
`~/.claude/CLAUDE.md`·`~/.codex/AGENTS.md`에서 수동 Operation Modes를 삭제해, 워커 CLI가 AGENTS.md에서 "grok에 위임" 지시 자체를 발견하지 못한다. 최종 작업자 예외는 마커 세션에만 적용되고 task canon·Git·보고 규칙은 유지한다.

### 5. GPT 샌드박스
Codex는 `-s workspace-write`(작업 디렉터리 밖 쓰기 차단) + `approval_policy=never`. origin push를 위해 `sandbox_workspace_write.network_access=true`만 허용. (`scripts/invoke-gpt.ps1`)

### 6. 검수 독립성
GPT가 구현한 작전 1 결과는 sol 자기검수를 하지 않는다(`review_not_eligible`). 유효한 grok 완료 영수증 + 같은 저장소 + HEAD 일치만 검수 자격. 검수 JSON은 fail-closed 엄격 검증(스키마 위반·PASS+findings 모순은 `review_parse_failed`, PASS 위장 없음). Opus는 구현자가 되지 않는다(자기검수 방지).

## 강제 방어층이 아닌 것 — 자연어 호출 soft confirmation policy

operation-1/2/3의 `disable-model-invocation: false`로 모델이 자연어 지시로 Skill을 호출할 수 있다. 이때 실행 전에 예상 워커·비용을 한 줄로 확인받는 절차는 **모델이 따르는 사용성·오작동 방지 정책(soft policy)이며, 라우터 코드가 강제하는 보안 게이트가 아니다.** 별도 확인 토큰·`-Confirmed` 인수 시스템은 두지 않는다. 슬래시 명령 직접 입력은 명시적 실행으로 간주해 확인을 생략한다. 이 정책은 위 6개 강제 방어층에 포함되지 않는다.

## Secret 보호

- **마스킹**(`Protect-SecretText`): gh/sk/xai/AWS 키, `key=value` 형태, Bearer, Authorization 헤더(임의 스킴), 고엔트로피 토큰(Shannon 엔트로피). git SHA·UUID·순수 숫자는 오탐 제외.
- 모든 로그(`Write-RouterLog`)와 workerSummary에 마스킹 적용.
- 환경변수 전체 덤프 코드 없음(개별 참조만).
- 검토 ZIP·저장소에 실제 usage-state·인증 정보·원본 모델 세션 JSONL 미포함. manifest 검토 대상에 secret 형태 없음(테스트로 강제).

## 알려진 한계

- deny 블록리스트는 우회 가능(층 1이 보완).
- 저장소 경계 탐지는 정의된 감시 경로만 본다. 감시 목록 밖의 임의 파일 생성은 잡지 못한다(홈·전역 설정·라우터 자신 등 고가치 대상만 감시).
- 고엔트로피 마스킹은 대/소/숫자 혼합 24자+만 대상. 그 밖 형태의 secret은 놓칠 수 있다.
- Grok의 중간 와일드카드 deny 패턴(`git push*+*`) 실제 발동은 grok 프로브로 미확인(층 1이 실질 방어라 후순위).

## 롤백

이 저장소는 자동 설치·업그레이드·백업·롤백 스크립트를 제공하지 않는다. 기존 작업 과정에서 **수동으로 생성된** `~/.claude/backups/` 백업이 있는 경우에만 해당 사본을 `~/.claude/operation-router` 및 스킬 경로로 복원할 수 있다. 백업이 없는 설치본은 자동 복구되지 않는다. 과거에 수동 생성된 예시(`operation-router.bak.<timestamp>`, `global-rules.bak.<timestamp>`)는 역사적 참고일 뿐, 현재 버전이 이런 백업을 자동 생성한다는 의미가 아니다.
