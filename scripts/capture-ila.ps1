<#
Attach to an already configured AX7020 ILA and export CSV/VCD, or summarize an
existing CSV. Hardware mode never programs or resets the FPGA.
#>
[CmdletBinding()]
param(
    [string]$IlaName,
    [string]$TriggerTcl,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30,
    [switch]$Vcd,
    [string]$AnalyzeOnly,
    [string]$VivadoPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $Root 'captures\latest'
$LogDir = Join-Path $Root 'logs'
$Action = if ($AnalyzeOnly) { 'ila-analyze' } else { 'ila-capture' }
$Utf8 = [Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Force $OutDir, $LogDir | Out-Null

function File([string]$what, [string]$path) {
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.PSIsContainer -or !$item.Length) { throw "$what must be a non-empty file: $path" }
    $item.FullName
}
function Manifest([string]$path) {
    $result = @{}
    foreach ($line in [IO.File]::ReadAllLines((File 'manifest' $path))) {
        $line = $line.Trim()
        if (!$line -or $line.StartsWith('#')) { continue }
        $at = $line.IndexOf('=')
        if ($at -lt 1) { throw "Invalid manifest line: $line" }
        $key = $line.Substring(0, $at).Trim()
        if ($result.ContainsKey($key)) { throw "Duplicate manifest key: $key" }
        $result[$key] = $line.Substring($at + 1).Trim()
    }
    $result
}
function Value([hashtable]$m, [string]$key) {
    if (!$m.ContainsKey($key) -or ![string]$m[$key]) { throw "Manifest is missing: $key" }
    [string]$m[$key]
}
function Artifact([hashtable]$m, [string]$prefix) {
    $relative = Value $m "$($prefix)_path"
    if ([IO.Path]::IsPathRooted($relative)) { throw "$prefix path must be repository-relative." }
    $path = [IO.Path]::GetFullPath((Join-Path $Root ($relative -replace '/', '\')))
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\'
    if (!$path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "$prefix path escapes the repository." }
    $path = File $prefix $path
    [UInt64]$size = 0
    if (![UInt64]::TryParse((Value $m "$($prefix)_size"), [ref]$size) -or
        (Get-Item $path).Length -ne $size -or
        !(Get-FileHash $path -Algorithm SHA256).Hash.Equals((Value $m "$($prefix)_sha256"), [StringComparison]::OrdinalIgnoreCase)) {
        throw "$prefix does not match the hardware manifest. Run Vivado build."
    }
    $path
}
function AtomicText([string]$path, [string]$text) {
    $temp = "$path.tmp.$PID"
    [IO.File]::WriteAllText($temp, $text, $Utf8)
    if ([IO.File]::Exists($path)) {
        $backup = "$path.bak.$PID"
        [IO.File]::Replace($temp, $path, $backup)
        Remove-Item $backup -Force
    }
    else { [IO.File]::Move($temp, $path) }
}
function AtomicMove([string]$source, [string]$target) {
    if ([IO.File]::Exists($target)) {
        $backup = "$target.bak.$PID"
        [IO.File]::Replace($source, $target, $backup)
        Remove-Item $backup -Force
    }
    else { [IO.File]::Move($source, $target) }
}
function Safe([string]$name) {
    $name = $name -replace '[^A-Za-z0-9_.-]', '_'
    if ($name) { $name } else { 'ila' }
}
function Analyze([string]$csv, [string]$summaryPath) {
    $lines = [IO.File]::ReadAllLines($csv)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^("?Sample in (Buffer|Window)"?),') { $start = $i; break }
    }
    if ($start -lt 0) { throw 'CSV has no Vivado ILA header.' }
    $dataStart = $start + 1
    if ($dataStart -lt $lines.Count -and $lines[$dataStart] -match '^"?Radix\s+-') {
        $dataStart++
    }
    if ($dataStart -ge $lines.Count) { throw 'CSV has no Vivado ILA sample rows.' }
    $data = @(@($lines[$start]) + @($lines[$dataStart..($lines.Count - 1)]) | ConvertFrom-Csv)
    if (!$data.Count) { throw 'CSV has no Vivado ILA sample rows.' }
    $names = @($data[0].PSObject.Properties.Name | Where-Object { $_ -notmatch '^(Sample in Buffer|Sample in Window|TRIGGER)$' })
    $stats = @($names | ForEach-Object { @{
        name = $_; first = $null; last = $null; transitions = 0L; unknown = 0L
        values = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); truncated = $false
    } })
    $trigger = $null
    for ($row = 0; $row -lt $data.Count; $row++) {
        $triggerProperty = $data[$row].PSObject.Properties['TRIGGER']
        $triggerValue = if ($null -eq $triggerProperty) { $null } else { $triggerProperty.Value }
        if ($null -eq $trigger -and $triggerValue -and $triggerValue -ne '0') { $trigger = $row }
        foreach ($s in $stats) {
            $v = [string]$data[$row].PSObject.Properties[$s.name].Value
            if ($null -eq $s.first) { $s.first = $v } elseif ($v -cne $s.last) { $s.transitions++ }
            $s.last = $v
            if ($v -match '[xXzZuUwW]') { $s.unknown++ }
            if ($s.values.Count -lt 16) { [void]$s.values.Add($v) } elseif (!$s.values.Contains($v)) { $s.truncated = $true }
        }
    }
    $rows = $data.Count
    $signals = @($stats | ForEach-Object {
        [ordered]@{
            name = $_.name; first_value = $_.first; last_value = $_.last
            transitions = $_.transitions; unknown_values = $_.unknown
            distinct_values = @($_.values); distinct_values_truncated = $_.truncated
        }
    })
    $summary = [ordered]@{
        schema_version = 1; source_csv = [IO.Path]::GetFullPath($csv)
        generated_utc = [DateTime]::UtcNow.ToString('o'); sample_rows = $rows
        trigger_position = $trigger; signals = $signals
    }
    AtomicText $summaryPath (($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
    $triggerText = if ($null -eq $trigger) { 'unknown' } else { $trigger }
    Write-Host "SUMMARY: rows=$rows trigger_position=$triggerText signals=$($stats.Count)"
    foreach ($s in @($stats | Sort-Object -Property @{Expression = { $_.transitions }; Descending = $true}, @{Expression = { $_.name }} | Select-Object -First 8)) {
        Write-Host "SIGNAL: name=$($s.name) transitions=$($s.transitions) unknown=$($s.unknown) first=$($s.first) last=$($s.last)"
    }
    $summary
}
function Vivado {
    if ($VivadoPath) { return File 'Vivado executable' $VivadoPath }
    if ($env:XILINX_VIVADO) { return File 'Vivado executable' (Join-Path $env:XILINX_VIVADO 'bin\vivado.bat') }
    $found = @(Get-Command vivado -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (!$found.Count) { throw 'Vivado was not found. Set XILINX_VIVADO or pass -VivadoPath.' }
    $found[0].Source
}
function Drive {
    foreach ($letter in @('T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
        if (Get-PSDrive $letter -ErrorAction SilentlyContinue) { continue }
        $name = $letter + ':'
        & "$env:SystemRoot\System32\subst.exe" $name $Root
        if (!$LASTEXITCODE) { return $name }
    }
    throw 'No temporary drive letter is available.'
}
function Short([string]$path, [string]$driveRoot) {
    $full = [IO.Path]::GetFullPath($path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\'
    if (!$full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside the repository: $path" }
    Join-Path $driveRoot $full.Substring($base.Length)
}
function MergeLog([string]$stdout, [string]$stderr, [string]$log) {
    Get-Content $stdout, $stderr -ErrorAction SilentlyContinue | Out-File $log -Encoding utf8
    Remove-Item $stdout, $stderr -Force -ErrorAction SilentlyContinue
}

try {
    if ($AnalyzeOnly) {
        if ($TriggerTcl -or $IlaName -or $Vcd) { throw '-AnalyzeOnly cannot use hardware capture options.' }
        $csv = File 'ILA CSV' $AnalyzeOnly
        $name = Safe ([IO.Path]::GetFileNameWithoutExtension($csv))
        $summaryPath = Join-Path $OutDir "$name.summary.json"
        $summary = Analyze $csv $summaryPath
        $captureManifest = Join-Path $OutDir "$name.capture.manifest"
        AtomicText $captureManifest (@(
            'manifest_version=1'; 'mode=analyze_only'; "csv_path=$csv"
            "csv_size=$((Get-Item $csv).Length)"
            "csv_sha256=$((Get-FileHash $csv -Algorithm SHA256).Hash.ToLowerInvariant())"
            "summary_path=$summaryPath"; "sample_rows=$($summary.sample_rows)"
        ) -join [Environment]::NewLine)
        Write-Host "CAPTURE: mode=analyze_only summary=$summaryPath manifest=$captureManifest"
        Write-Host 'RESULT: status=PASS action=ila-analyze'
        exit 0
    }

    $candidates = @(Get-ChildItem (Join-Path $Root 'prj') -Filter '*.hardware.manifest' -File)
    if ($candidates.Count -ne 1) { throw "Expected one hardware manifest; found $($candidates.Count). Run Vivado build." }
    $manifestPath = File 'hardware manifest' $candidates[0].FullName
    $m = Manifest $manifestPath
    if ((Value $m manifest_version) -ne '1' -or (Value $m part) -ne 'xc7z020clg400-2' -or (Value $m ila_enabled) -ne '1') {
        throw 'The hardware manifest is not an ILA-enabled AX7020 build.'
    }
    $bit = Artifact $m bit
    $ltx = Artifact $m debug_probes
    $trigger = if ($TriggerTcl) { File 'trigger Tcl' $TriggerTcl } else { $null }
    $vendor = Vivado
    $captureTcl = File 'capture Tcl' (Join-Path $PSScriptRoot 'capture-ila.tcl')
    $tempCsv = Join-Path $OutDir ".capture-$PID.csv"
    $tempVcd = if ($Vcd) { Join-Path $OutDir ".capture-$PID.vcd" } else { '' }
    $LogFile = Join-Path $LogDir ("ila-capture-{0}-p{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID)
    $drive = $null
    $previousLocalData = $env:XILINX_LOCAL_USER_DATA
    $env:XILINX_LOCAL_USER_DATA = 'no'
    try {
        $version = @(& $vendor -version 2>&1)
        if ($LASTEXITCODE -ne 0 -or ($version -join ' ') -notmatch '(?<!\d)2022\.2(?!\d)') { throw 'Vivado 2022.2 is required.' }
        $drive = Drive
        $driveRoot = "$drive\"
        $vendorArgs = @(
            '-mode', 'batch', '-nolog', '-nojournal', '-notrace'
            '-source', (Short $captureTcl $driveRoot), '-tclargs'
            (Short $ltx $driveRoot), $(if ($IlaName) { $IlaName } else { '-' })
            $(if ($trigger) { Short $trigger $driveRoot } else { '-' })
            (Short $tempCsv $driveRoot), $(if ($Vcd) { Short $tempVcd $driveRoot } else { '-' })
        )
        $stdout = "$LogFile.stdout"
        $stderr = "$LogFile.stderr"
        $process = Start-Process $vendor -ArgumentList $vendorArgs -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F | Out-File $stderr -Append
            [void]$process.WaitForExit(5000)
            $process.Dispose()
            MergeLog $stdout $stderr $LogFile
            throw "ILA capture timed out after $TimeoutSeconds seconds; the sample clock may be stopped. Log: $LogFile"
        }
        $process.WaitForExit()
        $process.Refresh()
        $exitCode = $process.ExitCode
        $process.Dispose()
        MergeLog $stdout $stderr $LogFile
        if (($null -ne $exitCode -and $exitCode -ne 0) -or
            !(Select-String -LiteralPath $LogFile -SimpleMatch -Pattern 'SUCCESS: ILA capture exported.' -Quiet) -or
            (Select-String -LiteralPath $LogFile -Pattern '(ERROR:|CRITICAL WARNING:|FATAL:|\[ERROR\])' -Quiet)) {
            throw "Vivado ILA capture failed (exit_code=$exitCode). Log: $LogFile"
        }
        $selected = @(Select-String -LiteralPath $LogFile -Pattern '^CAPTURE_ILA_NAME=(.+)$' | Select-Object -Last 1)
        if ($selected.Count -ne 1) { throw 'Vivado did not report the selected ILA name.' }
        $selected = $selected[0].Matches[0].Groups[1].Value
    }
    finally {
        if ($drive) { & "$env:SystemRoot\System32\subst.exe" $drive /D | Out-Null }
        if ($null -eq $previousLocalData) { Remove-Item Env:XILINX_LOCAL_USER_DATA -ErrorAction SilentlyContinue }
        else { $env:XILINX_LOCAL_USER_DATA = $previousLocalData }
    }

    $name = Safe $selected
    $csv = Join-Path $OutDir "$name.csv"
    AtomicMove (File 'captured CSV' $tempCsv) $csv
    $vcdPath = ''
    if ($Vcd) {
        $vcdPath = Join-Path $OutDir "$name.vcd"
        AtomicMove (File 'captured VCD' $tempVcd) $vcdPath
    }
    $summaryPath = Join-Path $OutDir "$name.summary.json"
    $summary = Analyze $csv $summaryPath
    $captureManifest = Join-Path $OutDir "$name.capture.manifest"
    AtomicText $captureManifest (@(
        'manifest_version=1'; 'mode=hardware'; "ila_name=$selected"
        "captured_utc=$([DateTime]::UtcNow.ToString('o'))"
        "hardware_manifest_sha256=$((Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant())"
        "bit_sha256=$((Get-FileHash $bit -Algorithm SHA256).Hash.ToLowerInvariant())"
        "ltx_sha256=$((Get-FileHash $ltx -Algorithm SHA256).Hash.ToLowerInvariant())"
        "csv_path=$csv"; "csv_size=$((Get-Item $csv).Length)"
        "csv_sha256=$((Get-FileHash $csv -Algorithm SHA256).Hash.ToLowerInvariant())"
        "vcd_path=$(if ($vcdPath) { $vcdPath } else { 'absent' })"
        "summary_path=$summaryPath"; "sample_rows=$($summary.sample_rows)"
    ) -join [Environment]::NewLine)
    Write-Host "CAPTURE: ila=$selected csv=$csv vcd=$(if ($vcdPath) { $vcdPath } else { 'absent' }) summary=$summaryPath"
    Write-Host "RESULT: status=PASS action=ila-capture log=$LogFile"
}
catch {
    Remove-Item (Join-Path $OutDir ".capture-$PID.csv"), (Join-Path $OutDir ".capture-$PID.vcd") -Force -ErrorAction SilentlyContinue
    Write-Host "RESULT: status=FAIL action=$Action"
    Write-Error $_
    exit 1
}
