<#
.SYNOPSIS
    Installs an x64 Windows ISO in an ephemeral QEMU/KVM virtual machine and audits first boot.

.DESCRIPTION
    Intended only for Ubuntu GitHub-hosted runners. The script creates a sparse temporary disk,
    builds a CI-specific answer file without modifying the ISO, completes Windows Setup, waits
    for the first-logon audit marker, and retains only compact diagnostics.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ISOPath,

    [switch]$AuditTiny11,

    [ValidateRange(30, 180)]
    [int]$TimeoutMinutes = 75,

    [ValidateRange(64, 128)]
    [int]$VirtualDiskSizeGB = 64,

    [string]$WorkDirectory,

    [string]$ReportDirectory = (Join-Path $PWD 'install-results')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsLinux) {
    throw 'The full Windows installation test is supported only on an Ubuntu GitHub-hosted runner.'
}

$resolvedISO = (Resolve-Path -LiteralPath $ISOPath).Path
$auditScript = Join-Path $PSScriptRoot 'test-installed-windows.ps1'
if (-not (Test-Path -LiteralPath $auditScript -PathType Leaf)) {
    throw "Guest audit script is missing: $auditScript"
}

$ReportDirectory = [System.IO.Path]::GetFullPath($ReportDirectory)
New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$reportPath = Join-Path $ReportDirectory 'windows-install-test.log'

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
        $details = ($output | Out-String).Trim()
        if ($details) {
            throw "$Action failed with exit code ${exitCode}: $details"
        }
        throw "$Action failed with exit code $exitCode"
    }

    return $output
}

function Resolve-IsoEntry {
    param(
        [string]$Root,
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

function Get-FreeSpaceBytes {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $drive = [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $fullPath.StartsWith($_.RootDirectory.FullName, [System.StringComparison]::Ordinal) } |
        Sort-Object { $_.RootDirectory.FullName.Length } -Descending |
        Select-Object -First 1
    if (-not $drive) { throw "Could not determine free space for $fullPath" }
    return $drive.AvailableFreeSpace
}

function Select-WorkDirectory {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        New-Item -ItemType Directory -Path $RequestedPath -Force | Out-Null
        return [System.IO.Path]::GetFullPath($RequestedPath)
    }

    $candidates = @($env:RUNNER_TEMP, '/mnt', [System.IO.Path]::GetTempPath()) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Select-Object -Unique
    $usable = foreach ($candidate in $candidates) {
        try {
            $probe = Join-Path $candidate ".windows-install-probe-$PID"
            Set-Content -LiteralPath $probe -Value 'probe' -Encoding ascii
            Remove-Item -LiteralPath $probe -Force
            [pscustomobject]@{
                Path = [System.IO.Path]::GetFullPath($candidate)
                Free = (Get-FreeSpaceBytes -Path $candidate)
            }
        }
        catch {
            Write-Report "Work directory candidate is unavailable: $candidate"
        }
    }
    $selected = $usable | Sort-Object Free -Descending | Select-Object -First 1
    if (-not $selected) { throw 'No writable work directory is available.' }
    return $selected.Path
}

function Send-QemuQmpCommand {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Command,
        [hashtable]$CommandArguments
    )

    if ($Process.HasExited) { return $false }
    try {
        $request = [ordered]@{ execute = $Command }
        if ($CommandArguments) { $request.arguments = $CommandArguments }
        $Process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 5))
        $Process.StandardInput.Flush()
        return $true
    }
    catch {
        return $false
    }
}

function Test-TextFileContains {
    param(
        [string]$Path,
        [string]$Text
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        return [System.IO.File]::ReadAllText($Path).Contains($Text)
    }
    catch {
        return $false
    }
}

function Restore-GuestResultFromSerial {
    param(
        [string]$SerialPath,
        [string]$OutputPath
    )

    if (-not (Test-Path -LiteralPath $SerialPath -PathType Leaf)) { return $false }
    try {
        $lines = [System.IO.File]::ReadAllLines($SerialPath)
        $beginIndex = -1
        $endIndex = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -eq 'CI_WINDOWS_INSTALL_AUDIT_RESULT_BEGIN') {
                $beginIndex = $index
            }
            elseif ($beginIndex -ge 0 -and $lines[$index] -eq 'CI_WINDOWS_INSTALL_AUDIT_RESULT_END') {
                $endIndex = $index
                break
            }
        }
        if ($beginIndex -lt 0 -or $endIndex -le ($beginIndex + 1)) { return $false }

        $payload = ($lines[($beginIndex + 1)..($endIndex - 1)] -join '').Trim()
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'The decoded COM1 payload is empty.'
        }
        $parsedResult = $json | ConvertFrom-Json -ErrorAction Stop
        Assert-GuestResult -Result $parsedResult
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        return $true
    }
    catch {
        [void](Write-Report "Could not recover the guest audit result from COM1: $($_.Exception.Message)")
        return $false
    }
}

function Assert-GuestResult {
    param($Result)

    if ($null -eq $Result) { throw 'The audit result is JSON null.' }
    foreach ($propertyName in @('passed', 'totalChecks', 'failedChecks', 'checks')) {
        if ($null -eq $Result.PSObject.Properties[$propertyName]) {
            throw "The audit result is missing the '$propertyName' property."
        }
    }
    if ($Result.passed -isnot [bool]) { throw "The audit result 'passed' property is not Boolean." }

    $resultChecks = @($Result.checks)
    if ([int]$Result.totalChecks -lt 1 -or [int]$Result.totalChecks -ne $resultChecks.Count) {
        throw "The audit result check count is inconsistent: declared=$($Result.totalChecks); actual=$($resultChecks.Count)."
    }
    foreach ($check in $resultChecks) {
        foreach ($propertyName in @('name', 'passed', 'expected', 'actual')) {
            if ($null -eq $check.PSObject.Properties[$propertyName]) {
                throw "An audit check is missing the '$propertyName' property."
            }
        }
        if ($check.passed -isnot [bool]) { throw "Audit check '$($check.name)' has a non-Boolean result." }
    }

    $actualFailedChecks = @($resultChecks | Where-Object { -not $_.passed }).Count
    if ([int]$Result.failedChecks -ne $actualFailedChecks) {
        throw "The audit result failure count is inconsistent: declared=$($Result.failedChecks); actual=$actualFailedChecks."
    }
    if ($Result.passed -ne ($actualFailedChecks -eq 0)) {
        throw "The audit result 'passed' value is inconsistent with its failed checks."
    }
}

function Add-UnattendElement {
    param(
        [xml]$Document,
        [System.Xml.XmlElement]$Parent,
        [string]$Name,
        [AllowNull()][string]$Value,
        [switch]$ActionAdd
    )

    $element = $Document.CreateElement($Name, 'urn:schemas-microsoft-com:unattend')
    if ($ActionAdd) {
        $attribute = $Document.CreateAttribute('wcm', 'action', 'http://schemas.microsoft.com/WMIConfig/2002/State')
        $attribute.Value = 'add'
        [void]$element.Attributes.Append($attribute)
    }
    if ($null -ne $Value) { $element.InnerText = $Value }
    [void]$Parent.AppendChild($element)
    return $element
}

function Remove-UnattendChildren {
    param(
        [System.Xml.XmlElement]$Parent,
        [string[]]$Names
    )

    foreach ($child in @($Parent.ChildNodes)) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -in $Names) {
            [void]$Parent.RemoveChild($child)
        }
    }
}

function Get-OrCreateSettings {
    param([xml]$Document, [string]$Pass)

    $node = $Document.DocumentElement.SelectSingleNode("*[local-name()='settings' and @pass='$Pass']")
    if (-not $node) {
        $node = Add-UnattendElement -Document $Document -Parent $Document.DocumentElement -Name 'settings' -Value $null
        $node.SetAttribute('pass', $Pass)
    }
    return $node
}

function Get-OrCreateComponent {
    param(
        [xml]$Document,
        [System.Xml.XmlElement]$Settings,
        [string]$Name
    )

    $node = $Settings.SelectSingleNode("*[local-name()='component' and @name='$Name']")
    if (-not $node) {
        $node = Add-UnattendElement -Document $Document -Parent $Settings -Name 'component' -Value $null
        $node.SetAttribute('name', $Name)
        $node.SetAttribute('processorArchitecture', 'amd64')
        $node.SetAttribute('publicKeyToken', '31bf3856ad364e35')
        $node.SetAttribute('language', 'neutral')
        $node.SetAttribute('versionScope', 'nonSxS')
    }
    return $node
}

function New-MinimalAnswerFile {
    $document = [System.Xml.XmlDocument]::new()
    [void]$document.AppendChild($document.CreateXmlDeclaration('1.0', 'utf-8', $null))
    $root = $document.CreateElement('unattend', 'urn:schemas-microsoft-com:unattend')
    $wcm = $document.CreateAttribute('xmlns', 'wcm', 'http://www.w3.org/2000/xmlns/')
    $wcm.Value = 'http://schemas.microsoft.com/WMIConfig/2002/State'
    [void]$root.Attributes.Append($wcm)
    [void]$document.AppendChild($root)
    return $document
}

function Set-CiAnswerFile {
    param(
        [xml]$Document,
        [string]$Locale,
        [string]$EditionId,
        [string]$OutputPath
    )

    $windowsPe = Get-OrCreateSettings -Document $Document -Pass 'windowsPE'
    $setup = Get-OrCreateComponent -Document $Document -Settings $windowsPe -Name 'Microsoft-Windows-Setup'
    Remove-UnattendChildren -Parent $setup -Names @('DiskConfiguration', 'ImageInstall', 'UserData')

    $diskConfiguration = Add-UnattendElement -Document $Document -Parent $setup -Name 'DiskConfiguration' -Value $null
    $disk = Add-UnattendElement -Document $Document -Parent $diskConfiguration -Name 'Disk' -Value $null -ActionAdd
    [void](Add-UnattendElement -Document $Document -Parent $disk -Name 'DiskID' -Value '0')
    [void](Add-UnattendElement -Document $Document -Parent $disk -Name 'WillWipeDisk' -Value 'true')
    $createPartitions = Add-UnattendElement -Document $Document -Parent $disk -Name 'CreatePartitions' -Value $null

    $efi = Add-UnattendElement -Document $Document -Parent $createPartitions -Name 'CreatePartition' -Value $null -ActionAdd
    [void](Add-UnattendElement -Document $Document -Parent $efi -Name 'Order' -Value '1')
    [void](Add-UnattendElement -Document $Document -Parent $efi -Name 'Type' -Value 'EFI')
    [void](Add-UnattendElement -Document $Document -Parent $efi -Name 'Size' -Value '260')
    $msr = Add-UnattendElement -Document $Document -Parent $createPartitions -Name 'CreatePartition' -Value $null -ActionAdd
    [void](Add-UnattendElement -Document $Document -Parent $msr -Name 'Order' -Value '2')
    [void](Add-UnattendElement -Document $Document -Parent $msr -Name 'Type' -Value 'MSR')
    [void](Add-UnattendElement -Document $Document -Parent $msr -Name 'Size' -Value '16')
    $windows = Add-UnattendElement -Document $Document -Parent $createPartitions -Name 'CreatePartition' -Value $null -ActionAdd
    [void](Add-UnattendElement -Document $Document -Parent $windows -Name 'Order' -Value '3')
    [void](Add-UnattendElement -Document $Document -Parent $windows -Name 'Type' -Value 'Primary')
    [void](Add-UnattendElement -Document $Document -Parent $windows -Name 'Extend' -Value 'true')

    $modifyPartitions = Add-UnattendElement -Document $Document -Parent $disk -Name 'ModifyPartitions' -Value $null
    $modifyEfi = Add-UnattendElement -Document $Document -Parent $modifyPartitions -Name 'ModifyPartition' -Value $null -ActionAdd
    [void](Add-UnattendElement -Document $Document -Parent $modifyEfi -Name 'Order' -Value '1')
    [void](Add-UnattendElement -Document $Document -Parent $modifyEfi -Name 'PartitionID' -Value '1')
    [void](Add-UnattendElement -Document $Document -Parent $modifyEfi -Name 'Label' -Value 'System')
    [void](Add-UnattendElement -Document $Document -Parent $modifyEfi -Name 'Format' -Value 'FAT32')
    $modifyWindows = Add-UnattendElement -Document $Document -Parent $modifyPartitions -Name 'ModifyPartition' -Value $null -ActionAdd
    [void](Add-UnattendElement -Document $Document -Parent $modifyWindows -Name 'Order' -Value '2')
    [void](Add-UnattendElement -Document $Document -Parent $modifyWindows -Name 'PartitionID' -Value '3')
    [void](Add-UnattendElement -Document $Document -Parent $modifyWindows -Name 'Label' -Value 'Windows')
    [void](Add-UnattendElement -Document $Document -Parent $modifyWindows -Name 'Letter' -Value 'C')
    [void](Add-UnattendElement -Document $Document -Parent $modifyWindows -Name 'Format' -Value 'NTFS')
    [void](Add-UnattendElement -Document $Document -Parent $diskConfiguration -Name 'WillShowUI' -Value 'OnError')

    $imageInstall = Add-UnattendElement -Document $Document -Parent $setup -Name 'ImageInstall' -Value $null
    $osImage = Add-UnattendElement -Document $Document -Parent $imageInstall -Name 'OSImage' -Value $null
    $installFrom = Add-UnattendElement -Document $Document -Parent $osImage -Name 'InstallFrom' -Value $null
    $metadata = Add-UnattendElement -Document $Document -Parent $installFrom -Name 'MetaData' -Value $null -ActionAdd
    [void](Add-UnattendElement -Document $Document -Parent $metadata -Name 'Key' -Value '/IMAGE/INDEX')
    [void](Add-UnattendElement -Document $Document -Parent $metadata -Name 'Value' -Value '1')
    $installTo = Add-UnattendElement -Document $Document -Parent $osImage -Name 'InstallTo' -Value $null
    [void](Add-UnattendElement -Document $Document -Parent $installTo -Name 'DiskID' -Value '0')
    [void](Add-UnattendElement -Document $Document -Parent $installTo -Name 'PartitionID' -Value '3')
    [void](Add-UnattendElement -Document $Document -Parent $osImage -Name 'WillShowUI' -Value 'OnError')

    $userData = Add-UnattendElement -Document $Document -Parent $setup -Name 'UserData' -Value $null
    $productKey = Add-UnattendElement -Document $Document -Parent $userData -Name 'ProductKey' -Value $null
    $genericKey = switch -Regex ($EditionId) {
        '^Professional' { 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'; break }
        '^Core' { 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'; break }
        default { throw "Full installation test supports Professional and Core editions; found: $EditionId" }
    }
    [void](Add-UnattendElement -Document $Document -Parent $productKey -Name 'Key' -Value $genericKey)
    [void](Add-UnattendElement -Document $Document -Parent $productKey -Name 'WillShowUI' -Value 'OnError')
    [void](Add-UnattendElement -Document $Document -Parent $userData -Name 'AcceptEula' -Value 'true')

    $setupReference = @($setup.ChildNodes | Where-Object {
        $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and
        $_.LocalName -notin @('DiskConfiguration', 'ImageInstall', 'UserData')
    }) | Select-Object -First 1
    if ($setupReference) {
        [void]$setup.InsertBefore($diskConfiguration, $setupReference)
        [void]$setup.InsertBefore($imageInstall, $setupReference)
        [void]$setup.InsertBefore($userData, $setupReference)
    }

    $international = Get-OrCreateComponent -Document $Document -Settings $windowsPe -Name 'Microsoft-Windows-International-Core-WinPE'
    Remove-UnattendChildren -Parent $international -Names @('SetupUILanguage', 'InputLocale', 'SystemLocale', 'UILanguage', 'UserLocale')
    $setupUiLanguage = Add-UnattendElement -Document $Document -Parent $international -Name 'SetupUILanguage' -Value $null
    [void](Add-UnattendElement -Document $Document -Parent $setupUiLanguage -Name 'UILanguage' -Value $Locale)
    [void](Add-UnattendElement -Document $Document -Parent $international -Name 'InputLocale' -Value $Locale)
    [void](Add-UnattendElement -Document $Document -Parent $international -Name 'SystemLocale' -Value $Locale)
    [void](Add-UnattendElement -Document $Document -Parent $international -Name 'UILanguage' -Value $Locale)
    [void](Add-UnattendElement -Document $Document -Parent $international -Name 'UserLocale' -Value $Locale)

    $oobeSystem = Get-OrCreateSettings -Document $Document -Pass 'oobeSystem'
    $internationalCore = Get-OrCreateComponent -Document $Document -Settings $oobeSystem -Name 'Microsoft-Windows-International-Core'
    Remove-UnattendChildren -Parent $internationalCore -Names @('InputLocale', 'SystemLocale', 'UILanguage', 'UserLocale')
    [void](Add-UnattendElement -Document $Document -Parent $internationalCore -Name 'InputLocale' -Value $Locale)
    [void](Add-UnattendElement -Document $Document -Parent $internationalCore -Name 'SystemLocale' -Value $Locale)
    [void](Add-UnattendElement -Document $Document -Parent $internationalCore -Name 'UILanguage' -Value $Locale)
    [void](Add-UnattendElement -Document $Document -Parent $internationalCore -Name 'UserLocale' -Value $Locale)

    $shell = Get-OrCreateComponent -Document $Document -Settings $oobeSystem -Name 'Microsoft-Windows-Shell-Setup'
    Remove-UnattendChildren -Parent $shell -Names @('AutoLogon', 'UserAccounts', 'FirstLogonCommands')

    $autoLogon = Add-UnattendElement -Document $Document -Parent $shell -Name 'AutoLogon' -Value $null
    $autoPassword = Add-UnattendElement -Document $Document -Parent $autoLogon -Name 'Password' -Value $null
    [void](Add-UnattendElement -Document $Document -Parent $autoPassword -Name 'Value' -Value 'CiTest-2026!')
    [void](Add-UnattendElement -Document $Document -Parent $autoPassword -Name 'PlainText' -Value 'true')
    [void](Add-UnattendElement -Document $Document -Parent $autoLogon -Name 'Enabled' -Value 'true')
    [void](Add-UnattendElement -Document $Document -Parent $autoLogon -Name 'LogonCount' -Value '1')
    [void](Add-UnattendElement -Document $Document -Parent $autoLogon -Name 'Username' -Value 'ci-test')

    $userAccounts = Add-UnattendElement -Document $Document -Parent $shell -Name 'UserAccounts' -Value $null
    $localAccounts = Add-UnattendElement -Document $Document -Parent $userAccounts -Name 'LocalAccounts' -Value $null
    $localAccount = Add-UnattendElement -Document $Document -Parent $localAccounts -Name 'LocalAccount' -Value $null -ActionAdd
    $localPassword = Add-UnattendElement -Document $Document -Parent $localAccount -Name 'Password' -Value $null
    [void](Add-UnattendElement -Document $Document -Parent $localPassword -Name 'Value' -Value 'CiTest-2026!')
    [void](Add-UnattendElement -Document $Document -Parent $localPassword -Name 'PlainText' -Value 'true')
    [void](Add-UnattendElement -Document $Document -Parent $localAccount -Name 'Description' -Value 'Ephemeral CI installation test account')
    [void](Add-UnattendElement -Document $Document -Parent $localAccount -Name 'DisplayName' -Value 'CI Test')
    [void](Add-UnattendElement -Document $Document -Parent $localAccount -Name 'Group' -Value 'Administrators')
    [void](Add-UnattendElement -Document $Document -Parent $localAccount -Name 'Name' -Value 'ci-test')

    $oobe = $shell.SelectSingleNode("*[local-name()='OOBE']")
    if (-not $oobe) { $oobe = Add-UnattendElement -Document $Document -Parent $shell -Name 'OOBE' -Value $null }
    Remove-UnattendChildren -Parent $oobe -Names @('HideEULAPage', 'HideOnlineAccountScreens', 'HideWirelessSetupInOOBE', 'ProtectYourPC')
    [void](Add-UnattendElement -Document $Document -Parent $oobe -Name 'HideEULAPage' -Value 'true')
    [void](Add-UnattendElement -Document $Document -Parent $oobe -Name 'HideOnlineAccountScreens' -Value 'true')
    [void](Add-UnattendElement -Document $Document -Parent $oobe -Name 'HideWirelessSetupInOOBE' -Value 'true')
    [void](Add-UnattendElement -Document $Document -Parent $oobe -Name 'ProtectYourPC' -Value '3')

    $firstLogonCommands = Add-UnattendElement -Document $Document -Parent $shell -Name 'FirstLogonCommands' -Value $null
    $command = Add-UnattendElement -Document $Document -Parent $firstLogonCommands -Name 'SynchronousCommand' -Value $null -ActionAdd
    [void](Add-UnattendElement -Document $Document -Parent $command -Name 'Order' -Value '1')
    [void](Add-UnattendElement -Document $Document -Parent $command -Name 'Description' -Value 'Run CI installation audit')
    $commandLine = 'powershell.exe -WindowStyle Normal -ExecutionPolicy Bypass -NoProfile -Command "$drive = Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path -LiteralPath (Join-Path $_.Root ''CI_INSTALL_TEST.TAG'') } | Select-Object -First 1; if (-not $drive) { throw ''CI install test media not found.'' }; & (Join-Path $drive.Root ''test-installed-windows.ps1'') -ResultDirectory $drive.Root"'
    [void](Add-UnattendElement -Document $Document -Parent $command -Name 'CommandLine' -Value $commandLine)
    [void]$shell.InsertBefore($autoLogon, $oobe)

    $writerSettings = [System.Xml.XmlWriterSettings]::new()
    $writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $writerSettings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($OutputPath, $writerSettings)
    try { $Document.Save($writer) } finally { $writer.Dispose() }
    [void][xml](Get-Content -LiteralPath $OutputPath -Raw)
}

foreach ($command in @('sudo', 'mount', 'umount', 'wiminfo', 'qemu-img', 'qemu-system-x86_64', 'mkfs.vfat', 'id')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $command"
    }
}

$availableAccelerators = & qemu-system-x86_64 -accel help 2>&1
if (
    $LASTEXITCODE -ne 0 -or
    -not (Test-Path -LiteralPath '/dev/kvm') -or
    (($availableAccelerators -join "`n") -notmatch '(?im)^\s*kvm\s*$')
) {
    throw 'The full installation test requires KVM acceleration; /dev/kvm is unavailable.'
}
& sudo chmod a+rw -- /dev/kvm
if ($LASTEXITCODE -ne 0) { throw 'Could not grant the runner access to /dev/kvm.' }

$workBase = Select-WorkDirectory -RequestedPath $WorkDirectory
$freeBytes = Get-FreeSpaceBytes $workBase
Write-Report "Selected work directory: $workBase ($([math]::Round($freeBytes / 1GB, 2)) GiB free)."
if ($freeBytes -lt 25GB) {
    throw "At least 25 GiB of free work space is required; found $([math]::Round($freeBytes / 1GB, 2)) GiB."
}

$workRoot = Join-Path $workBase ("windows-install-test-{0}-{1}" -f $PID, [guid]::NewGuid().ToString('N'))
$ciMediaDirectory = Join-Path $workRoot 'ci-media-mount'
$ciMediaImage = Join-Path $workRoot 'ci-media.img'
$mountDirectory = Join-Path $workRoot 'iso-mount'
$diskPath = Join-Path $workRoot 'windows.qcow2'
$varsPath = Join-Path $workRoot 'OVMF_VARS.fd'
New-Item -ItemType Directory -Path $ciMediaDirectory, $mountDirectory -Force | Out-Null

$mounted = $false
$ciMediaMounted = $false
$process = $null
try {
    Invoke-NativeChecked -FilePath 'sudo' -Arguments @('mount', '-o', 'loop,ro', '--', $resolvedISO, $mountDirectory) -Action 'Mount ISO read-only' | Out-Null
    $mounted = $true

    $bootWim = Resolve-IsoEntry -Root $mountDirectory -RelativePath 'sources/boot.wim'
    $installImage = Resolve-IsoEntry -Root $mountDirectory -RelativePath 'sources/install.wim' -Optional
    if (-not $installImage) { $installImage = Resolve-IsoEntry -Root $mountDirectory -RelativePath 'sources/install.esd' }

    $bootInfo = Invoke-NativeChecked -FilePath 'wiminfo' -Arguments @($bootWim, '2') -Action 'Read Windows Setup image metadata'
    $bootInfoText = $bootInfo -join "`n"
    $locale = if ($bootInfoText -match '(?im)^\s*Default Language:\s*([^\s]+)\s*$') { $Matches[1] } else { 'en-US' }

    $installInfo = Invoke-NativeChecked -FilePath 'wiminfo' -Arguments @($installImage, '1') -Action 'Read install image metadata'
    $installInfoText = $installInfo -join "`n"
    if ($installInfoText -notmatch '(?im)^\s*Architecture:\s*x86_64\s*$') {
        throw 'The full installation test supports x64 Windows images only.'
    }
    if ($installInfoText -notmatch '(?im)^\s*Edition ID:\s*(\S+)\s*$') {
        throw 'Could not determine the Windows edition from install image index 1.'
    }
    $editionId = $Matches[1]
    Write-Report "Installation target: edition=$editionId; locale=$locale; image-index=1."

    $sourceAnswer = Resolve-IsoEntry -Root $mountDirectory -RelativePath 'autounattend.xml' -Optional
    if ($AuditTiny11 -and -not $sourceAnswer) {
        throw 'Tiny11 auditing requires the ISO root autounattend.xml.'
    }
    if ($sourceAnswer) {
        $answerDocument = [System.Xml.XmlDocument]::new()
        $answerDocument.PreserveWhitespace = $false
        $answerDocument.Load($sourceAnswer)
        Write-Report 'Using the ISO answer file as the base for the CI installation overlay.'
    }
    else {
        $answerDocument = New-MinimalAnswerFile
        Write-Report 'ISO answer file is absent; using a minimal CI installation answer file.'
    }

    Invoke-NativeChecked -FilePath 'sudo' -Arguments @('umount', '--lazy', '--', $mountDirectory) -Action 'Unmount ISO' | Out-Null
    $mounted = $false

    Invoke-NativeChecked -FilePath 'qemu-img' -Arguments @('create', '-f', 'raw', $ciMediaImage, '256M') -Action 'Create FAT test media image' | Out-Null
    Invoke-NativeChecked -FilePath 'mkfs.vfat' -Arguments @('-n', 'CI_INSTALL', $ciMediaImage) -Action 'Format FAT test media image' | Out-Null
    $runnerUid = ((& id -u) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not determine the runner user ID.' }
    $runnerGid = ((& id -g) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not determine the runner group ID.' }
    $mountOptions = "loop,rw,uid=$runnerUid,gid=$runnerGid,umask=022"
    Invoke-NativeChecked -FilePath 'sudo' -Arguments @('mount', '-o', $mountOptions, '--', $ciMediaImage, $ciMediaDirectory) -Action 'Mount FAT test media' | Out-Null
    $ciMediaMounted = $true

    $ciAnswerPath = Join-Path $ciMediaDirectory 'Autounattend.xml'
    Set-CiAnswerFile -Document $answerDocument -Locale $locale -EditionId $editionId -OutputPath $ciAnswerPath
    Copy-Item -LiteralPath $ciAnswerPath -Destination (Join-Path $ReportDirectory 'ci-autounattend.xml') -Force
    Copy-Item -LiteralPath $auditScript -Destination (Join-Path $ciMediaDirectory 'test-installed-windows.ps1') -Force
    Set-Content -LiteralPath (Join-Path $ciMediaDirectory 'CI_INSTALL_TEST.TAG') -Value 'QEMU Windows installation test media' -Encoding ascii
    if ($AuditTiny11) {
        Set-Content -LiteralPath (Join-Path $ciMediaDirectory 'AUDIT_TINY11.TAG') -Value 'Audit Tiny11 state' -Encoding ascii
    }
    Invoke-NativeChecked -FilePath 'sudo' -Arguments @('umount', '--', $ciMediaDirectory) -Action 'Flush FAT test media' | Out-Null
    $ciMediaMounted = $false

    Invoke-NativeChecked -FilePath 'qemu-img' -Arguments @('create', '-f', 'qcow2', '-o', 'preallocation=off', $diskPath, "${VirtualDiskSizeGB}G") -Action 'Create sparse Windows test disk' | Out-Null

    $firmwareCandidates = @(
        [pscustomobject]@{ Code = '/usr/share/OVMF/OVMF_CODE_4M.fd'; Vars = '/usr/share/OVMF/OVMF_VARS_4M.fd' }
        [pscustomobject]@{ Code = '/usr/share/OVMF/OVMF_CODE.fd'; Vars = '/usr/share/OVMF/OVMF_VARS.fd' }
    )
    $firmware = $firmwareCandidates | Where-Object {
        (Test-Path -LiteralPath $_.Code) -and (Test-Path -LiteralPath $_.Vars)
    } | Select-Object -First 1
    if (-not $firmware) { throw 'OVMF UEFI firmware was not found.' }
    Copy-Item -LiteralPath $firmware.Vars -Destination $varsPath

    $serialLog = Join-Path $ReportDirectory 'install-qemu-serial.log'
    $qemuLog = Join-Path $ReportDirectory 'install-qemu.log'
    $timeoutScreenshot = Join-Path $ReportDirectory 'install-timeout.png'
    $successScreenshot = Join-Path $ReportDirectory 'install-success.png'
    $arguments = @(
        '-machine', 'q35,accel=kvm',
        '-cpu', 'host',
        '-smp', '2',
        '-m', '6144',
        '-drive', "if=pflash,format=raw,readonly=on,file=$($firmware.Code)",
        '-drive', "if=pflash,format=raw,file=$varsPath",
        '-drive', "file=$diskPath,media=disk,format=qcow2,discard=unmap,detect-zeroes=unmap",
        '-drive', "file=$resolvedISO,media=cdrom,readonly=on,format=raw",
        '-drive', "file=$ciMediaImage,if=none,id=cimedia,format=raw,cache=writethrough",
        '-device', 'qemu-xhci,id=xhci',
        '-device', 'usb-storage,drive=cimedia,removable=on',
        '-boot', 'once=d,menu=off',
        '-display', 'none',
        '-serial', "file:$serialLog",
        '-qmp', 'stdio',
        '-nic', 'none',
        '-rtc', 'base=localtime'
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command 'qemu-system-x86_64').Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add($argument) }

    Write-Report "Starting unattended Windows installation (KVM; timeout: $TimeoutMinutes minutes)..."
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $qmpGreeting = $process.StandardOutput.ReadLine()
    try { $qmpGreetingMessage = $qmpGreeting | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "QEMU did not return a valid QMP greeting: $qmpGreeting" }
    if ($null -eq $qmpGreetingMessage.PSObject.Properties['QMP']) {
        throw "QEMU did not return the expected QMP greeting: $qmpGreeting"
    }
    [void](Send-QemuQmpCommand -Process $process -Command 'qmp_capabilities')
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $startedAt = Get-Date
    $timedOut = $false
    $completionSignal = 'CI_WINDOWS_INSTALL_AUDIT_COMPLETE'
    $completionObserved = $false
    $nextHeartbeatMinute = 1
    while (-not $process.HasExited) {
        $elapsed = (Get-Date) - $startedAt
        if (-not $completionObserved -and (Test-TextFileContains -Path $serialLog -Text $completionSignal)) {
            $completionObserved = $true
            Write-Report 'Installed Windows audit marker received; capturing screenshot and waiting for a clean guest shutdown.'
            [void](Send-QemuQmpCommand -Process $process -Command 'screendump' -CommandArguments @{
                filename = $successScreenshot
                format = 'png'
            })
        }
        if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
            $timedOut = $true
            [void](Send-QemuQmpCommand -Process $process -Command 'screendump' -CommandArguments @{
                filename = $timeoutScreenshot
                format = 'png'
            })
            Start-Sleep -Seconds 2
            [void](Send-QemuQmpCommand -Process $process -Command 'quit')
            if (-not $process.WaitForExit(10000)) { $process.Kill($true) }
            break
        }
        if ($elapsed.TotalSeconds -le 90) {
            [void](Send-QemuQmpCommand -Process $process -Command 'send-key' -CommandArguments @{
                keys = @(@{ type = 'qcode'; data = 'spc' })
            })
        }
        if ($elapsed.TotalMinutes -ge $nextHeartbeatMinute) {
            $diskBytes = if (Test-Path -LiteralPath $diskPath) { (Get-Item -LiteralPath $diskPath).Length } else { 0 }
            Write-Report "Installation test is still running ($nextHeartbeatMinute minute(s); qcow2=$([math]::Round($diskBytes / 1GB, 2)) GiB)..."
            $nextHeartbeatMinute++
        }
        Start-Sleep -Seconds 2
    }

    $process.WaitForExit()
    Set-Content -LiteralPath $qemuLog -Value @($qmpGreeting, $stdoutTask.Result, $stderrTask.Result)
    Write-Report "QEMU exited with code $($process.ExitCode)."

    Invoke-NativeChecked -FilePath 'sudo' -Arguments @('mount', '-o', 'loop,ro', '--', $ciMediaImage, $ciMediaDirectory) -Action 'Mount FAT test results' | Out-Null
    $ciMediaMounted = $true
    $completionMarker = Join-Path $ciMediaDirectory 'CI_INSTALL_COMPLETE.TAG'
    $completionReturned = Test-Path -LiteralPath $completionMarker -PathType Leaf
    foreach ($name in @(
        'CI_INSTALL_COMPLETE.TAG',
        'install-test-result.json',
        'serial-signal-error.txt',
        'guest-setupact.log',
        'guest-setuperr.log',
        'guest-Specialize.log',
        'guest-DefaultUser.log',
        'guest-FirstLogon.log',
        'guest-RemovePackages.log',
        'guest-RemoveCapabilities.log',
        'guest-RemoveFeatures.log'
    )) {
        $source = Join-Path $ciMediaDirectory $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $ReportDirectory $name) -Force
        }
    }
    Invoke-NativeChecked -FilePath 'sudo' -Arguments @('umount', '--', $ciMediaDirectory) -Action 'Unmount FAT test results' | Out-Null
    $ciMediaMounted = $false

    if ($timedOut) { throw "Windows installation did not complete within $TimeoutMinutes minutes." }
    if ($process.ExitCode -ne 0) {
        throw "QEMU exited with code $($process.ExitCode) before the full installation test completed."
    }
    if (-not $completionReturned) {
        throw 'QEMU exited before the installed Windows audit marker was written.'
    }

    $guestResultPath = Join-Path $ReportDirectory 'install-test-result.json'
    $guestResult = $null
    if (Test-Path -LiteralPath $guestResultPath -PathType Leaf) {
        try {
            $candidateResult = Get-Content -LiteralPath $guestResultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            Assert-GuestResult -Result $candidateResult
            $guestResult = $candidateResult
        }
        catch {
            [void](Write-Report "The FAT audit result is invalid; trying COM1: $($_.Exception.Message)")
        }
    }
    if ($null -eq $guestResult -and (Restore-GuestResultFromSerial -SerialPath $serialLog -OutputPath $guestResultPath)) {
        Write-Report 'Recovered install-test-result.json from the COM1 result channel.'
        $guestResult = Get-Content -LiteralPath $guestResultPath -Raw | ConvertFrom-Json -ErrorAction Stop
        Assert-GuestResult -Result $guestResult
    }
    if ($null -eq $guestResult) {
        throw 'The guest completed without returning install-test-result.json.'
    }
    Write-Report "Installed Windows audit completed: passed=$($guestResult.passed); checks=$($guestResult.totalChecks); failed=$($guestResult.failedChecks)."

    $summaryPath = Join-Path $ReportDirectory 'install-test-summary.md'
    Add-Content -LiteralPath $summaryPath -Value @(
        '### Full Windows installation test',
        '',
        '| Property | Value |',
        '| :--- | :--- |',
        "| Result | $(if ($guestResult.passed) { '✅ Passed' } else { '❌ Failed' }) |",
        "| Edition | $editionId |",
        "| Locale | $locale |",
        '| Architecture | x64 |',
        '| Acceleration | KVM |',
        "| Checks | $($guestResult.totalChecks) total; $($guestResult.failedChecks) failed |",
        "| Duration | $([math]::Round(((Get-Date) - $startedAt).TotalMinutes, 2)) minutes |",
        ''
    )
    $failedChecks = @($guestResult.checks | Where-Object { -not $_.passed })
    if ($failedChecks.Count) {
        Add-Content -LiteralPath $summaryPath -Value @('#### Failed checks', '')
        foreach ($check in $failedChecks) {
            Add-Content -LiteralPath $summaryPath -Value ('- **{0}** — expected `{1}`; actual `{2}`' -f $check.name, $check.expected, $check.actual)
        }
    }

    if (-not $guestResult.passed) {
        throw "Installed Windows audit failed $($guestResult.failedChecks) of $($guestResult.totalChecks) checks."
    }
    Write-Report 'Full Windows installation and first-boot audit passed.'
}
finally {
    if ($ciMediaMounted) {
        & sudo umount --lazy -- $ciMediaDirectory 2>&1 | Out-Null
    }
    if ($mounted) {
        & sudo umount --lazy -- $mountDirectory 2>&1 | Out-Null
    }
    if ($process -and -not $process.HasExited) {
        try {
            [void](Send-QemuQmpCommand -Process $process -Command 'quit')
            if (-not $process.WaitForExit(5000)) { $process.Kill($true) }
        }
        catch { }
    }
    if (Test-Path -LiteralPath $workRoot -PathType Container) {
        $resolvedWorkRoot = (Resolve-Path -LiteralPath $workRoot).Path
        $resolvedWorkBase = (Resolve-Path -LiteralPath $workBase).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ($resolvedWorkRoot.StartsWith($resolvedWorkBase + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $resolvedWorkRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Warning "Refusing to remove unexpected work path: $resolvedWorkRoot"
        }
    }
}
