# run_debug.ps1 - launch XCOM with full diagnostics (XCOM_DEBUG=1).
#
# stderr is unbuffered in Lua, so every line (including LuaJIT's own panic
# text, e.g. "PANIC: unprotected error in call to Lua API (bad callback)")
# survives a hard process exit and lands in the log file.  The normal
# xcom.exe launcher hides the console, which throws stderr away; this script
# therefore starts luvjit.exe directly with stderr redirected to a file.
#
# Usage:
#   powershell -File run_debug.ps1                 # source checkout (runtime/ beside it)
#   powershell -File run_debug.ps1 -Root <dir>     # any release package root
#   powershell -File run_debug.ps1 -Open           # also auto-open the VIRTUAL port
#                                                  # (XCOM_SMOKE_OPEN=1, sim pump on)
param(
    [string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [switch]$Open
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Root).Path
$luvjit = Join-Path $root 'runtime\luvjit.exe'
if (-not (Test-Path -LiteralPath $luvjit)) { throw "not found: $luvjit" }

$entry = Join-Path $root 'main.ljbc'
if (-not (Test-Path -LiteralPath $entry)) { $entry = Join-Path $root 'main.lua' }
if (-not (Test-Path -LiteralPath $entry)) { throw "no main.ljbc/main.lua under $root" }

$log = Join-Path $root 'xcom_debug.log'
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
"==== XCOM debug run $stamp ====" | Set-Content -LiteralPath $log -Encoding UTF8
"entry: $entry" | Add-Content -LiteralPath $log

$env:XCOM_DEBUG = '1'
if ($Open) { $env:XCOM_SMOKE_OPEN = '1' }

# Start the app; block until it exits so the log stays complete.
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $luvjit
$psi.Arguments = '"' + $entry + '"'
$psi.WorkingDirectory = $root
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$reader = $proc.StandardError
while (-not $reader.EndOfStream) {
    $line = $reader.ReadLine()
    Add-Content -LiteralPath $log -Value $line
}
$proc.WaitForExit()
$code = $proc.ExitCode
"==== exited with code $code ====" | Add-Content -LiteralPath $log
Write-Host "XCOM exited with code $code"
Write-Host "log: $log"
