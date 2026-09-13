param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [int]$Count = 200,
    [int]$Burners = 0,
    [string]$Tag = "stress",
    [string]$LogDir = "D:\workspace\e2e-win\logs"
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$log = Join-Path $LogDir "$Tag.log"

$burnerProcs = @()
if ($Burners -gt 0) {
    for ($b = 0; $b -lt $Burners; $b++) {
        $burnerProcs += Start-Process -FilePath "pwsh" -ArgumentList @(
            "-NoProfile","-ExecutionPolicy","Bypass","-File",
            "D:\workspace\e2e2\hw\burn.ps1","-Seconds","900"
        ) -WindowStyle Hidden -PassThru
    }
    Start-Sleep -Seconds 8
}

$start = Get-Date
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# PAL startup-handshake stress")
$lines.Add("# exe      : $Exe")
$lines.Add("# runs     : $Count")
$lines.Add("# burners  : $Burners")
$lines.Add("# start    : $($start.ToString('yyyy-MM-dd HH:mm:ss.fff'))")
$failures = 0
$failedRuns = @()
for ($i = 1; $i -le $Count; $i++) {
    $t0 = Get-Date
    $p = Start-Process -FilePath $Exe -NoNewWindow -Wait -PassThru
    $rc = $p.ExitCode
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    if ($rc -ne 0) { $failures++; $failedRuns += $i }
    $lines.Add(("run {0,4}  exit={1,-4} wall={2,6} ms  at={3}" -f $i, $rc, $ms, (Get-Date).ToString('HH:mm:ss.fff')))
}
$end = Get-Date
$lines.Add("# end      : $($end.ToString('yyyy-MM-dd HH:mm:ss.fff'))")
$lines.Add("# elapsed  : $([int]($end - $start).TotalSeconds) s")
$lines.Add("# failures : $failures / $Count")
if ($failedRuns.Count -gt 0) { $lines.Add("# failed run indices: $($failedRuns -join ', ')") }
$lines | Set-Content -LiteralPath $log

foreach ($bp in $burnerProcs) { if (-not $bp.HasExited) { Stop-Process -Id $bp.Id -Force -ErrorAction SilentlyContinue } }

Get-Content -LiteralPath $log | Select-Object -First 6
"..."
Get-Content -LiteralPath $log | Select-Object -Last 4
"LOG=$log"
exit $failures
