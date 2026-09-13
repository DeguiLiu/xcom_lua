param([int]$WatchdogSeconds = 30, [int]$PipeSeconds = 60)
$ErrorActionPreference = 'Continue'
$logDir = "D:\workspace\e2e2\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$out = Join-Path $logDir "slow_target.out"
$err = Join-Path $logDir "slow_target.err"

$srv = Start-Process pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
        "D:\workspace\e2e2\hw\slow_pipe_server.ps1",'-Name','xcom_slow','-Seconds',"$PipeSeconds") `
        -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
Write-Output "pipe server pid=$($srv.Id)"

Push-Location "D:\workspace\e2e2\xcom_lua\xcom_lua"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath ".\runtime\luajit.exe" `
        -ArgumentList @("D:\workspace\e2e2\hw\slow_target.lua", "\\\\.\\pipe\\xcom_slow", "10000") `
        -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
$exited = $proc.WaitForExit($WatchdogSeconds * 1000)
$wall = $sw.ElapsedMilliseconds
Pop-Location

if ($exited) {
    Write-Output "RESULT: process EXITED, rc=$($proc.ExitCode), wall=${wall} ms"
} else {
    Write-Output "RESULT: WATCHDOG TRIPPED - still running after ${WatchdogSeconds}s; killing (pid $($proc.Id))"
    $proc.Kill()
    $proc.WaitForExit(5000) | Out-Null
}
if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
Write-Output "--- stdout ($((Get-Item $out).Length) bytes) ---"
Get-Content $out
Write-Output "--- stderr ($((Get-Item $err).Length) bytes) ---"
Get-Content $err
