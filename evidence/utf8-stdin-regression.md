# UTF-8 stdin 회귀 증거 (v2.3.5 재수리, 2026-07-21)

V03 1차 실패의 직접 원인이던 작업자 stdin 인코딩 경로를 바이트 단위로 검증한 기록이다.

## 결함 실측 (수리 전)

Windows PowerShell 5.1, 콘솔 코드페이지 65001(UTF-8) 환경.

파일 바이트 (Set-Content -Encoding UTF8, 마커+한글 계약):

```text
EF BB BF 5B 4F 50 45 52 ... (BOM + payload)
```

기존 `$stdinContent | & exe` 파이프라인으로 자식이 받은 바이트:

```text
EF BB BF 5B 4F 50 45 52 ... E2 9C 93 0D 0A
```

- 선두에 BOM(EF BB BF) 3바이트가 삽입된다. `$OutputEncoding`을 BOM 없는
  UTF-8로 강제해도, 심지어 ASCII로 바꿔도 동일하게 삽입된다 (실측).
- 원인은 .NET Framework `Process`가 stdin 리다이렉트 시 `Console.InputEncoding`
  (CP 65001 → BOM 있는 UTF-8)으로 StreamWriter를 만들고 AutoFlush 설정 시점에
  프리앰블을 즉시 기록하기 때문이다. PS 5.1 파이프라인도 내부적으로 동일 경로다.
- 결과: 작업자 계약 첫 바이트가 `[OPERATION_ROUTER_FINAL_WORKER]` 마커가 아니게
  되어 마커 매칭(`^\[OPERATION_ROUTER_FINAL_WORKER\]`)이 실패할 수 있다.
- 테스트가 처음 이를 놓친 이유: culture-sensitive `String.StartsWith`가
  zero-width U+FEFF를 무시했다. 테스트를 ordinal 비교로 강화했다.

## 수리 (scripts/common.ps1 Invoke-ForegroundCommand stdin 분기)

1. `System.Diagnostics.Process` 직접 실행. 주문서 파일의 원시 바이트를
   `ReadAllBytes`로 읽고 파일 BOM(EF BB BF)이 있으면 제거 후
   `StandardInput.BaseStream`에 직접 기록한다.
2. `Process.Start` 전후로 `Console.InputEncoding`을 BOM 없는 UTF-8로 교체·원복해
   .NET이 만드는 stdin StreamWriter의 프리앰블 기록을 차단한다.
3. 기록 후 stdin을 `finally`에서 명시적으로 닫아 EOF를 보장한다.
4. stdout·stderr는 UTF-8로 각각 비동기 수집하고 exit code를 별도 필드로 반환한다
   (`ExitCode`/`Output`/`StdOut`/`StdErr`).

## 수리 후 실측 (한글 경로 포함)

임시 디렉터리 이름에 한글 포함(`utf8-한글경로-…`), payload =
마커 + `한글 계약 보존 ✓` + `다른 CLI에 위임하지 말고 직접 구현한다.`

```text
exit: 0
received len: 111  expected len: 111
byte-exact match (no BOM, no trailing): True
marker first: True          # ordinal StartsWith
phrase kept: True           # "다른 CLI에 위임하지 말고 직접 구현한다"
console encoding restored: utf-8
```

수신 바이트가 payload UTF-8 바이트와 완전 일치한다 (BOM 0, 꼬리 개행 0,
한글·✓ 무손실). 회귀 테스트 `19. Windows PowerShell 전경 실행이 한글 stdin을
UTF-8 바이트로 보존한다`가 이 경로를 상시 검증한다 (168/168 PASS에 포함).
