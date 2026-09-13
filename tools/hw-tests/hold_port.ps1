param([string]$Port = "COM37", [int]$Seconds = 45)
$p = New-Object System.IO.Ports.SerialPort($Port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$p.ReadTimeout = 200
try {
    $p.Open()
    "HOLDER: opened $Port for $Seconds s (pid $PID)"
    Start-Sleep -Seconds $Seconds
    "HOLDER: releasing $Port"
} catch {
    "HOLDER: FAILED to open ${Port}: " + $_.Exception.Message
} finally {
    if ($p.IsOpen) { $p.Close() }
}
