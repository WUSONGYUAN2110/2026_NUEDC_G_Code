param(
    [string]$Port = "COM3",
    [int]$BaudRate = 115200,
    [int]$TimeoutSeconds = 8
)

$ErrorActionPreference = "Stop"

function Read-HmiPage {
    param(
        [System.IO.Ports.SerialPort]$Serial,
        [byte]$Request,
        [byte]$Page,
        [string]$CompletionCommand
    )

    $frame = [byte[]](0x55, 0xAA, $Request, $Page, 0x0D, 0x0A)
    $Serial.Write($frame, 0, $frame.Length)

    $commands = [System.Collections.Generic.List[string]]::new()
    $waveforms = [System.Collections.Generic.List[object]]::new()
    $commandBytes = [System.Collections.Generic.List[byte]]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $value = $Serial.ReadByte()
        }
        catch [System.TimeoutException] {
            continue
        }

        $commandBytes.Add([byte]$value)
        $count = $commandBytes.Count
        if ($count -lt 3 -or
            $commandBytes[$count - 1] -ne 0xFF -or
            $commandBytes[$count - 2] -ne 0xFF -or
            $commandBytes[$count - 3] -ne 0xFF) {
            continue
        }

        $payloadLength = $count - 3
        $payload = if ($payloadLength -gt 0) {
            $commandBytes.GetRange(0, $payloadLength).ToArray()
        } else {
            [byte[]]@()
        }
        $command = [Text.Encoding]::ASCII.GetString($payload)
        $commands.Add($command)
        $commandBytes.Clear()

        if ($command -match '^addt ([^.]+)\.id,0,464$') {
            $ready = [byte[]](0xFE, 0xFF, 0xFF, 0xFF)
            $Serial.Write($ready, 0, $ready.Length)
            $points = [byte[]]::new(464)
            $received = 0
            while ($received -lt $points.Length -and
                   [DateTime]::UtcNow -lt $deadline) {
                try {
                    $received += $Serial.Read(
                        $points, $received, $points.Length - $received)
                }
                catch [System.TimeoutException] {
                    continue
                }
            }
            if ($received -ne $points.Length) {
                throw "Waveform transfer timed out after $received bytes."
            }
            $done = [byte[]](0xFD, 0xFF, 0xFF, 0xFF)
            $Serial.Write($done, 0, $done.Length)
            $waveforms.Add([pscustomobject]@{
                Name = $Matches[1]
                Minimum = ($points | Measure-Object -Minimum).Minimum
                Maximum = ($points | Measure-Object -Maximum).Maximum
                Nonzero = ($points | Where-Object { $_ -ne 0 }).Count
            })
        }

        if ($command -eq $CompletionCommand) {
            return [pscustomobject]@{
                Commands = $commands.ToArray()
                Waveforms = $waveforms.ToArray()
            }
        }
    }

    throw "Timed out waiting for HMI command '$CompletionCommand'."
}

$serial = [System.IO.Ports.SerialPort]::new(
    $Port, $BaudRate, [System.IO.Ports.Parity]::None, 8,
    [System.IO.Ports.StopBits]::One)
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.ReadTimeout = 100
$serial.WriteTimeout = 500

try {
    $serial.Open()
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $timePage = Read-HmiPage -Serial $serial -Request 0x10 -Page 0x01 `
        -CompletionCommand "tsw btnFreq,1"
    $freqPage = Read-HmiPage -Serial $serial -Request 0x12 -Page 0x02 `
        -CompletionCommand "tsw btnTime,1"

    [pscustomobject]@{
        Port = $Port
        TimeCommands = $timePage.Commands
        TimeWaveforms = $timePage.Waveforms
        FrequencyCommands = $freqPage.Commands
        FrequencyWaveforms = $freqPage.Waveforms
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($serial.IsOpen) {
        $serial.Close()
    }
    $serial.Dispose()
}
