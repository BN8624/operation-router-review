# 기존 검증 진입점을 visible metadata 동기화 검사의 호환 래퍼로 유지한다.

[CmdletBinding()]
param([string]$RootPath,[string]$GitRootPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) { $RootPath = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($GitRootPath)) { $GitRootPath = $RootPath }

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'sync-verification-metadata.ps1') `
    -RootPath $RootPath -GitRootPath $GitRootPath -Check
exit $LASTEXITCODE
