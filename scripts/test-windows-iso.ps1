<#
.SYNOPSIS
    Validates an x64 Windows ISO and optionally verifies that it reaches Windows PE in QEMU.

.DESCRIPTION
    Intended for Ubuntu GitHub-hosted runners. The script mounts the ISO read-only, verifies
    its boot files and WIM/ESD metadata, runs wimverify, and starts a QEMU VM with KVM when
    available or TCG otherwise.
    A temporary higher-priority Autounattend.xml writes a marker as soon as Windows PE starts.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ISOPath,

    [ValidateRange(5, 60)]
    [int]$BootTimeoutMinutes = 20,

    [switch]$SkipBoot,

    [string]$ReportDirectory = (Join-Path $PWD 'validation-results')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resolvedISO = (Resolve-Path -LiteralPath $ISOPath).Path
New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$reportPath = Join-Path $ReportDirectory 'iso-validation.log'

function Write-Report {
    param([string]$Message)

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Output $line
    Add-Content -LiteralPath $reportPath -Value $line
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory)]
        [string]$Action
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($output) {
        $output | ForEach-Object { Add-Content -LiteralPath $reportPath -Value $_ }
    }
    if ($exitCode -ne 0) {
        throw "$Action failed with exit code $exitCode"
    }

    return $output
}

function Resolve-IsoEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [switch]$Optional
    )

    $current = $Root
    foreach ($segment in ($RelativePath -split '[\\/]')) {
        $match = Get-ChildItem -LiteralPath $current -Force |
            Where-Object { $_.Name -ieq $segment } |
            Select-Object -First 1
        if (-not $match) {
            if ($Optional) { return $null }
            throw "Required ISO entry is missing: $RelativePath"
        }
        $current = $match.FullName
    }

    return $current
}

function Test-WimFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    Write-Report "Reading $Label metadata..."
    $info = Invoke-NativeChecked -FilePath 'wiminfo' -Arguments @($Path) -Action "Read $Label metadata"
    $infoText = $info -join "`n"
    Set-Content -LiteralPath (Join-Path $ReportDirectory "$Label-info.txt") -Value $infoText

    if ($infoText -notmatch '(?im)^\s*Architecture:\s*x86_64\s*$') {
        throw "$Label does not contain an x64 image"
    }

    Write-Report "Verifying $Label integrity..."
    Invoke-NativeChecked -FilePath 'wimverify' -Arguments @($Path) -Action "Verify $Label" | Out-Null
    Write-Report "$Label metadata and integrity are valid."
}

function Send-QemuMonitorCommand {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Command
    )

    if ($Process.HasExited) { return $false }
    try {
        $Process.StandardInput.WriteLine($Command)
        $Process.StandardInput.Flush()
        return $true
    }
    catch {
        return $false
    }
}

function Test-WindowsPeBoot {
    param([string]$Path)

    if (-not $IsLinux) {
        throw 'The QEMU boot test is supported only on an Ubuntu GitHub-hosted runner.'
    }

    if (-not (Get-Command 'qemu-system-x86_64' -ErrorAction SilentlyContinue)) {
        throw 'Required command is unavailable: qemu-system-x86_64'
    }

    $firmwareCandidates = @(
        [pscustomobject]@{ Code = '/usr/share/OVMF/OVMF_CODE_4M.fd'; Vars = '/usr/share/OVMF/OVMF_VARS_4M.fd' }
        [pscustomobject]@{ Code = '/usr/share/OVMF/OVMF_CODE.fd'; Vars = '/usr/share/OVMF/OVMF_VARS.fd' }
    )
    $firmware = $firmwareCandidates | Where-Object {
        (Test-Path -LiteralPath $_.Code) -and (Test-Path -LiteralPath $_.Vars)
    } | Select-Object -First 1
    if (-not $firmware) {
        throw 'OVMF UEFI firmware was not found.'
    }

    $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) "windows-iso-smoke-$PID"
    $markerDirectory = Join-Path $workRoot 'marker-media'
    New-Item -ItemType Directory -Path $markerDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $markerDirectory 'CI_MARKER.TAG') -Value 'QEMU Windows PE boot marker'

    $answerFile = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Signal successful Windows PE startup</Description>
          <Path>cmd.exe /c for %D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do @if exist %D:\CI_MARKER.TAG call %D:\BootMarker.cmd %D:</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
'@
    Set-Content -LiteralPath (Join-Path $markerDirectory 'Autounattend.xml') -Value $answerFile -Encoding utf8
    Set-Content -LiteralPath (Join-Path $markerDirectory 'BootMarker.cmd') -Encoding ascii -Value @(
        '@echo off',
        'echo Windows PE booted successfully>%1\WINPE_BOOTED.TXT',
        'wpeutil.exe shutdown'
    )

    $varsPath = Join-Path $workRoot 'OVMF_VARS.fd'
    Copy-Item -LiteralPath $firmware.Vars -Destination $varsPath
    $serialLog = Join-Path $ReportDirectory 'qemu-serial.log'
    $qemuLog = Join-Path $ReportDirectory 'qemu.log'
    $screenshotPath = Join-Path $ReportDirectory 'qemu-timeout.ppm'

    $acceleration = 'tcg'
    $cpuModel = 'max'
    $availableAccelerators = & qemu-system-x86_64 -accel help 2>&1
    if (
        $LASTEXITCODE -eq 0 -and
        (Test-Path -LiteralPath '/dev/kvm') -and
        (($availableAccelerators -join "`n") -match '(?im)^\s*kvm\s*$')
    ) {
        & sudo chmod a+rw -- /dev/kvm
        if ($LASTEXITCODE -eq 0) {
            $acceleration = 'kvm'
            $cpuModel = 'host'
        }
        else {
            Write-Report 'KVM is present but inaccessible; using TCG instead.'
        }
    }
    Write-Report "QEMU acceleration: $($acceleration.ToUpperInvariant())"

    $arguments = @(
        '-machine', "q35,accel=$acceleration",
        '-cpu', $cpuModel,
        '-smp', '2',
        '-m', '3072',
        '-drive', "if=pflash,format=raw,readonly=on,file=$($firmware.Code)",
        '-drive', "if=pflash,format=raw,file=$varsPath",
        '-drive', "file=$Path,media=cdrom,readonly=on,format=raw",
        '-drive', "file=fat:rw:$markerDirectory,if=none,id=marker,format=raw",
        '-device', 'qemu-xhci,id=xhci',
        '-device', 'usb-storage,drive=marker,removable=on',
        '-boot', 'order=d,menu=off',
        '-display', 'none',
        '-serial', "file:$serialLog",
        '-monitor', 'stdio',
        '-nic', 'none',
        '-no-reboot'
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command 'qemu-system-x86_64').Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add($argument) }

    Write-Report "Starting x64 UEFI Windows PE boot test (timeout: $BootTimeoutMinutes minutes)..."
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $startedAt = Get-Date
    $timedOut = $false
    $bootMarker = Join-Path $markerDirectory 'WINPE_BOOTED.TXT'
    $nextHeartbeatMinute = 1
    while (-not $process.HasExited) {
        $elapsed = (Get-Date) - $startedAt
        if (Test-Path -LiteralPath $bootMarker) {
            Write-Report 'Windows PE boot marker detected; stopping QEMU.'
            [void](Send-QemuMonitorCommand -Process $process -Command 'quit')
            if (-not $process.WaitForExit(5000)) { $process.Kill($true) }
            break
        }

        if ($elapsed.TotalMinutes -ge $BootTimeoutMinutes) {
            $timedOut = $true
            [void](Send-QemuMonitorCommand -Process $process -Command "screendump $screenshotPath")
            Start-Sleep -Seconds 2
            [void](Send-QemuMonitorCommand -Process $process -Command 'quit')
            if (-not $process.WaitForExit(5000)) { $process.Kill($true) }
            break
        }

        if ($elapsed.TotalSeconds -le 90) {
            [void](Send-QemuMonitorCommand -Process $process -Command 'sendkey spc')
        }
        if ($elapsed.TotalMinutes -ge $nextHeartbeatMinute) {
            Write-Report "Windows PE boot test is still running ($nextHeartbeatMinute minute(s) elapsed)..."
            $nextHeartbeatMinute++
        }
        Start-Sleep -Seconds 2
    }

    $process.WaitForExit()
    Set-Content -LiteralPath $qemuLog -Value @($stdoutTask.Result, $stderrTask.Result)
    Write-Report "QEMU exited with code $($process.ExitCode)."

    if ($timedOut) {
        throw "Windows PE did not report startup within $BootTimeoutMinutes minutes."
    }
    if (-not (Test-Path -LiteralPath $bootMarker)) {
        throw 'QEMU exited before Windows PE wrote the startup marker.'
    }

    Copy-Item -LiteralPath $bootMarker -Destination (Join-Path $ReportDirectory 'WINPE_BOOTED.TXT')
    Write-Report 'Windows PE boot marker received successfully.'
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($command in @('sudo', 'mount', 'umount', 'wiminfo', 'wimverify')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $command"
    }
}

$isoItem = Get-Item -LiteralPath $resolvedISO
if ($isoItem.Length -lt 1GB) {
    throw "ISO is unexpectedly small: $([math]::Round($isoItem.Length / 1MB)) MiB"
}
if ($isoItem.Length -gt 12GB) {
    throw "ISO exceeds the 12 GiB validation limit: $([math]::Round($isoItem.Length / 1GB, 2)) GiB"
}
Write-Report "Validating $($isoItem.Name) ($([math]::Round($isoItem.Length / 1GB, 2)) GiB)."
Write-Report "SHA256: $((Get-FileHash -LiteralPath $resolvedISO -Algorithm SHA256).Hash.ToLowerInvariant())"

$mountDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "windows-iso-mount-$PID"
New-Item -ItemType Directory -Path $mountDirectory -Force | Out-Null
$mounted = $false
try {
    Invoke-NativeChecked -FilePath 'sudo' -Arguments @('mount', '-o', 'loop,ro', '--', $resolvedISO, $mountDirectory) -Action 'Mount ISO read-only' | Out-Null
    $mounted = $true

    foreach ($entry in @(
        'bootmgr',
        'boot/bcd',
        'boot/boot.sdi',
        'boot/etfsboot.com',
        'efi/boot/bootx64.efi',
        'sources/boot.wim'
    )) {
        [void](Resolve-IsoEntry -Root $mountDirectory -RelativePath $entry)
        Write-Report "Found required ISO entry: $entry"
    }

    $bootWim = Resolve-IsoEntry -Root $mountDirectory -RelativePath 'sources/boot.wim'
    $installImage = Resolve-IsoEntry -Root $mountDirectory -RelativePath 'sources/install.wim' -Optional
    if (-not $installImage) {
        $installImage = Resolve-IsoEntry -Root $mountDirectory -RelativePath 'sources/install.esd'
    }

    Test-WimFile -Path $bootWim -Label 'boot-wim'
    Test-WimFile -Path $installImage -Label 'install-image'

    $answerFile = Resolve-IsoEntry -Root $mountDirectory -RelativePath 'autounattend.xml' -Optional
    if ($answerFile) {
        [void][xml](Get-Content -LiteralPath $answerFile -Raw)
        Write-Report 'Root autounattend.xml is well-formed XML.'
    }
    else {
        Write-Report 'Root autounattend.xml is absent (allowed for external Windows media).'
    }
}
finally {
    if ($mounted) {
        Invoke-NativeChecked -FilePath 'sudo' -Arguments @('umount', '--', $mountDirectory) -Action 'Unmount ISO' | Out-Null
    }
    Remove-Item -LiteralPath $mountDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Report 'ISO structural validation completed successfully.'
if (-not $SkipBoot) {
    Test-WindowsPeBoot -Path $resolvedISO
}
else {
    Write-Report 'QEMU boot test skipped.'
}

Write-Report 'All requested ISO tests passed.'
