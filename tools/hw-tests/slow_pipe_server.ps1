param([string]$Name = "xcom_slow", [int]$Seconds = 90)
﻿# PipeDirection::Out would mean the SERVER sends and the client must open with
# GENERIC_READ - the wrong shape for a log sink.  In means the server receives:
# the client's GENERIC_WRITE open succeeds, and because this server never reads,
# its 4 KiB buffer fills and the writer's synchronous write blocks.
$srv = New-Object System.IO.Pipes.NamedPipeServerStream(
    $Name, [System.IO.Pipes.PipeDirection]::In, 1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte,
    [System.IO.Pipes.PipeOptions]::None, 4096, 4096)
Write-Output "PIPE: listening on \\.\pipe\$Name"
$srv.WaitForConnection()
Write-Output "PIPE: client connected - deliberately NOT reading (stalled target)"
Start-Sleep -Seconds $Seconds
Write-Output "PIPE: done"
$srv.Dispose()
