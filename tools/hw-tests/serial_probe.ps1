param(
    [string]$WritePort = "COM37",
    [string]$ReadPort  = "COM36",
    [int]$Baud = 115200,
    [string]$Payload = "PING-0123456789",
    [int]$ReadMs = 700
)
function Open-Port([string]$name, [int]$baud) {
    $p = New-Object System.IO.Ports.SerialPort($name, $baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    $p.ReadTimeout = 500
    $p.WriteTimeout = 500
    $p.Handshake = [System.IO.Ports.Handshake]::None
    $p.DtrEnable = $false
    $p.RtsEnable = $false
    $p.Open()
    return $p
}
$w = $null; $r = $null
try {
    $w = Open-Port $WritePort $Baud
    $r = if ($ReadPort -eq $WritePort) { $w } else { Open-Port $ReadPort $Baud }
    "opened writer=$WritePort reader=$ReadPort baud=$Baud"
    $r.DiscardInBuffer()
    $w.DiscardInBuffer()
    $w.Write($Payload)
    $w.BaseStream.Flush()
    "wrote: $Payload"
    Start-Sleep -Milliseconds $ReadMs
    foreach ($pair in @(@($WritePort, $w), @($ReadPort, $r))) {
        $name = $pair[0]; $port = $pair[1]
        $n = $port.BytesToRead
        if ($n -gt 0) {
            $buf = New-Object byte[] $n
            $got = $port.Read($buf, 0, $n)
            $txt = [System.Text.Encoding]::ASCII.GetString($buf, 0, $got)
            "READ $name : $got bytes : '" + ($txt -replace "[\r\n]", ".") + "'"
        } else {
            "READ $name : 0 bytes"
        }
    }
} catch {
    "ERROR: " + $_.Exception.Message
} finally {
    if ($r -and $r -ne $w -and $r.IsOpen) { $r.Close() }
    if ($w -and $w.IsOpen) { $w.Close() }
}
