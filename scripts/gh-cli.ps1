# gh CLI 호출 헬퍼 (dot-source 전용). stdout·stderr 분리, 재시도, 실패 진단을 제공한다.

# gh CLI 호출. stdout과 stderr를 분리해 gh나 내부 git의 경고 한 줄이 JSON·URL 출력을 오염시키지 않게 한다.
# 2>&1로 합치면 'warning: ...' 한 줄만 섞여도 ConvertFrom-Json이 깨지고 원인 없이 lookup 실패로만 보인다.
function Invoke-GhRaw {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$GhArgs)
    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ExitCode = $null; Text = ''; StdErr = ''; ToolAvailable = $false }
    }
    $ErrorActionPreference = 'Continue'
    Initialize-RuntimeDirs
    $errPath = Join-Path $Script:TempDir ('gh-' + [guid]::NewGuid().ToString('N') + '.err')
    Push-Location $Path
    try {
        $out = & gh @GhArgs 2>$errPath
        $exit = $LASTEXITCODE
        $stderrText = ''
        if (Test-Path -LiteralPath $errPath) {
            $raw = Get-Content -LiteralPath $errPath -Raw -ErrorAction SilentlyContinue
            if ($null -ne $raw) { $stderrText = [string]$raw }
        }
        return [pscustomobject]@{
            ExitCode = $exit; Text = ($out | Out-String)
            StdErr = (Protect-SecretText -Text $stderrText); ToolAvailable = $true
        }
    } finally {
        Pop-Location
        Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
    }
}
# gh stdout을 JSON으로 파싱한다. 성공 여부와 실패 사유를 함께 돌려준다.
function ConvertFrom-GhJsonText {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()]$Text)
    $t = if ($null -eq $Text) { '' } else { [string]$Text }
    if ([string]::IsNullOrWhiteSpace($t)) { return [pscustomobject]@{ ok = $false; value = $null; reason = 'empty_output' } }
    try { return [pscustomobject]@{ ok = $true; value = ($t | ConvertFrom-Json -ErrorAction Stop); reason = $null } }
    catch { return [pscustomobject]@{ ok = $false; value = $null; reason = 'invalid_json' } }
}
# 진단용 stderr 요약. 첫 비어있지 않은 줄만, 길이를 제한해 남긴다.
function Get-GhErrorDetail {
    param([AllowEmptyString()][AllowNull()]$StdErr, [AllowNull()]$ExitCode, [AllowEmptyString()][AllowNull()]$Reason, [int]$Attempts = 1)
    $line = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$StdErr)) {
        foreach ($candidate in ([string]$StdErr -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $line = $candidate.Trim(); break }
        }
    }
    if ($line.Length -gt 300) { $line = $line.Substring(0, 300) }
    return [pscustomobject]@{
        exitCode = $ExitCode; reason = if ($null -eq $Reason) { '' } else { [string]$Reason }
        stderrFirstLine = $line; attempts = [int]$Attempts
    }
}
# gh 호출을 실패 시 짧게 재시도한다. 일시적 API·네트워크 오류로 실행 전체가 죽지 않게 한다.
# JSON을 기대하는 호출은 -ExpectJson으로 파싱 실패도 재시도 대상이 된다.
function Invoke-GhWithRetry {
    param(
        [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$GhArgs,
        [switch]$ExpectJson, [int]$MaxAttempts = 3, [int]$InitialDelayMilliseconds = 400,
        [scriptblock]$GhRunner, [scriptblock]$Sleeper
    )
    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    $delay = [Math]::Max(0, $InitialDelayMilliseconds)
    $last = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $raw = if ($null -ne $GhRunner) { & $GhRunner $Path $GhArgs } else { Invoke-GhRaw -Path $Path -GhArgs $GhArgs }
        if ($null -ne $raw -and $raw.PSObject.Properties.Name -contains 'ToolAvailable' -and -not [bool]$raw.ToolAvailable) {
            return [pscustomobject]@{
                ok = $false; toolAvailable = $false; value = $null; text = ''
                detail = (Get-GhErrorDetail -StdErr '' -ExitCode $null -Reason 'tool_unavailable' -Attempts $attempt)
            }
        }
        $exitCode = if ($null -ne $raw -and $raw.PSObject.Properties.Name -contains 'ExitCode') { $raw.ExitCode } else { $null }
        $text = if ($null -ne $raw -and $raw.PSObject.Properties.Name -contains 'Text') { [string]$raw.Text } else { '' }
        $stderr = if ($null -ne $raw -and $raw.PSObject.Properties.Name -contains 'StdErr') { [string]$raw.StdErr } else { '' }
        if ($null -eq $exitCode -or [int]$exitCode -ne 0) {
            $last = [pscustomobject]@{
                ok = $false; toolAvailable = $true; value = $null; text = $text
                detail = (Get-GhErrorDetail -StdErr $stderr -ExitCode $exitCode -Reason 'nonzero_exit' -Attempts $attempt)
            }
        } elseif ($ExpectJson) {
            $parsed = ConvertFrom-GhJsonText -Text $text
            if ($parsed.ok) {
                return [pscustomobject]@{
                    ok = $true; toolAvailable = $true; value = $parsed.value; text = $text
                    detail = (Get-GhErrorDetail -StdErr $stderr -ExitCode $exitCode -Reason '' -Attempts $attempt)
                }
            }
            $last = [pscustomobject]@{
                ok = $false; toolAvailable = $true; value = $null; text = $text
                detail = (Get-GhErrorDetail -StdErr $stderr -ExitCode $exitCode -Reason $parsed.reason -Attempts $attempt)
            }
        } else {
            return [pscustomobject]@{
                ok = $true; toolAvailable = $true; value = $null; text = $text
                detail = (Get-GhErrorDetail -StdErr $stderr -ExitCode $exitCode -Reason '' -Attempts $attempt)
            }
        }
        if ($attempt -lt $MaxAttempts) {
            if ($null -ne $Sleeper) { & $Sleeper $delay } elseif ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
            $delay = $delay * 2
        }
    }
    return $last
}
