param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [int]$Count = 200,
    [string]$Tag = "repeat",
    [string]$LogDir = "D:\workspace\e2e-win\logs",
    [string]$Note = ""
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$log = Join-Path $LogDir "$Tag.log"
$start = Get-Date
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# repeat-run harness")
$lines.Add("# exe     : $Exe")
$lines.Add("# runs    : $Count")
$lines.Add("# note    : $Note")
$lines.Add("# start   : $($start.ToString('yyyy-MM-dd HH:mm:ss.fff'))")
$failures = 0
$failedRuns = @()
$hist = @{}
for ($i = 1; $i -le $Count; $i++) {
    $t0 = Get-Date
    $p = Start-Process -FilePath $Exe -NoNewWindow -Wait -PassThru
    $rc = $p.ExitCode
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    if ($hist.ContainsKey($rc)) { $hist[$rc]++ } else { $hist[$rc] = 1 }
    if ($rc -ne 0) { $failures++; $failedRuns += $i }
    $lines.Add(("run {0,4}  exit={1,-4} wall={2,6} ms  at={3}" -f $i, $rc, $ms, (Get-Date).ToString('HH:mm:ss.fff')))
}
$end = Get-Date
$lines.Add("# end     : $($end.ToString('yyyy-MM-dd HH:mm:ss.fff'))")
$lines.Add("# elapsed : $([int]($end - $start).TotalSeconds) s")
$lines.Add("# failures: $failures / $Count")
foreach ($k in ($hist.Keys | Sort-Object)) { $lines.Add("# exit-code histogram: rc=$k count=$($hist[$k])") }
if ($failedRuns.Count -gt 0) { $lines.Add("# failed run indices: $($failedRuns -join ', ')") }
$lines | Set-Content -LiteralPath $log
Get-Content -LiteralPath $log | Select-Object -First 6
Get-Content -LiteralPath $log | Select-Object -Last 5
"LOG=$log"
exit $failures
