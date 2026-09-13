param([int]$Seconds = 600)
$end = (Get-Date).AddSeconds($Seconds)
$x = 0.0
while ((Get-Date) -lt $end) { for ($i = 0; $i -lt 2000000; $i++) { $x = [Math]::Sqrt($x + $i) }; $x = 0.0 }
