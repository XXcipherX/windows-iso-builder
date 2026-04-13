<#
.SYNOPSIS
    Headless script to build a trimmed-down Windows 11 image for CI/CD automation.

.DESCRIPTION
    Automated build of a streamlined Windows 11 image (tiny11) without user interaction.
    Designed for GitHub Actions workflows and other CI/CD pipelines.
    Uses only Microsoft utilities like DISM, with oscdimg.exe from Windows ADK.

.PARAMETER ISO
    Drive letter of the mounted Windows 11 ISO (required, e.g., E)

.PARAMETER INDEX
    Windows image index to process (required, e.g., 1 for Home, 6 for Pro)

.PARAMETER SCRATCH
    Drive letter for scratch disk operations (optional, defaults to script root)

.PARAMETER SkipCleanup
    Skip cleanup of temporary files after ISO creation (optional, for debugging)

.EXAMPLE
    .\tiny11maker-headless.ps1 -ISO E -INDEX 1
    .\tiny11maker-headless.ps1 -ISO E -INDEX 6 -SCRATCH D

.NOTES
    Original Author: ntdevlabs
    Modified by: kelexine (https://github.com/kelexine)
    GitHub: https://github.com/kelexine/tiny11-automated
    Date: 2025-12-08
    
    License: MIT
    This is a headless automation-ready version designed for CI/CD pipelines.
#>

#---------[ Parameters ]---------#
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Drive letter of mounted Windows 11 ISO (e.g., E)")]
    [ValidatePattern('^[c-zC-Z]$')]
    [string]$ISO,
    
    [Parameter(Mandatory = $false, HelpMessage = "Path to Windows ISO file (will be mounted automatically)")]
    [string]$ISOPath,
    
    [Parameter(Mandatory = $true, HelpMessage = "Windows image index (1=Home, 6=Pro, etc.)")]
    [ValidateRange(1, 10)]
    [int]$INDEX,
    
    [Parameter(Mandatory = $false, HelpMessage = "Scratch disk drive letter (defaults to script directory)")]
    [ValidatePattern('^[c-zC-Z]$')]
    [string]$SCRATCH,
    
    [Parameter(Mandatory = $false, HelpMessage = "Output ISO file path (defaults to script directory)")]
    [string]$OutputPath,
    
    [Parameter(Mandatory = $false, HelpMessage = "Skip cleanup of temporary files")]
    [switch]$SkipCleanup,
    
    [Parameter(Mandatory = $false, HelpMessage = "Export as install.esd (maximum compression)")]
    [switch]$ESD
)

#---------[ Error Handling ]---------#
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

#---------[ Configuration ]---------#
if (-not $SCRATCH) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
}
else {
    $ScratchDisk = $SCRATCH + ":"
}

$script:AutoMountedISO = $null
$wimFilePath = "$ScratchDisk\tiny11\sources\install.wim"
$scratchDir = "$ScratchDisk\scratchdir"
$tiny11Dir = "$ScratchDisk\tiny11"
$outputISO = if ($OutputPath) { $OutputPath } else { "$PSScriptRoot\tiny11.iso" }
$logFile = "$PSScriptRoot\tiny11_$(Get-Date -Format yyyyMMdd_HHmmss).log"

#---------[ Functions ]---------#
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Output $logMessage
    Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [string]$Action = $FilePath,

        [switch]$IgnoreExitCode
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $details = ($output | Out-String).Trim()
        if ($details) {
            Write-Log "$Action failed (exit code $exitCode). Output: $details" "ERROR"
        }
        else {
            Write-Log "$Action failed (exit code $exitCode)." "ERROR"
        }
        throw "$Action failed (exit code $exitCode)"
    }

    return $output
}

function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )
    try {
        $commandOutput = (& 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-Log "Error setting registry $path\$name : $_" "ERROR"
        throw
    }

    if ($exitCode -eq 0) {
        Write-Log "Set registry: $path\$name = $value"
    }
    else {
        $details = if ($commandOutput) { " Output: $commandOutput" } else { "" }
        Write-Log "Failed to set registry $path\$name (exit code $exitCode).$details" "ERROR"
        throw "reg add failed with exit code $exitCode for $path\$name"
    }
}

function Convert-RegistryPathToProviderPath {
    param([string]$path)

    if ($path -match '^HKLM\\(.+)$') {
        return "Registry::HKEY_LOCAL_MACHINE\$($Matches[1])"
    }

    if ($path -match '^HKCU\\(.+)$') {
        return "Registry::HKEY_CURRENT_USER\$($Matches[1])"
    }

    return $null
}

function Remove-RegistryValue {
    param([string]$path)

    $providerPath = Convert-RegistryPathToProviderPath $path
    if ($providerPath) {
        try {
            if (-not (Test-Path -LiteralPath $providerPath)) {
                return
            }

            Remove-Item -LiteralPath $providerPath -Recurse -Force -ErrorAction Stop
            Write-Log "Removed registry: $path"
            return
        }
        catch {
            Write-Log "Registry not removed: $path. $_" "WARN"
            return
        }
    }

    try {
        $commandOutput = (& 'reg' 'delete' $path '/f' 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Log "Removed registry: $path"
        }
        else {
            $details = if ($commandOutput) { " Output: $commandOutput" } else { "" }
            if ($commandOutput -match 'unable to find the specified registry key or value') {
                return
            }
            else {
                Write-Log "Registry not removed: $path (exit code $exitCode).$details" "WARN"
            }
        }
    }
    catch {
        Write-Log "Error removing registry $path : $_" "WARN"
    }
}

function Remove-PathQuietly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Description = $Path,

        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    Remove-Item -LiteralPath $Path -Recurse:$Recurse.IsPresent -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    try {
        $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $adminAccount = $adminSID.Translate([System.Security.Principal.NTAccount]).Value
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue

        if ($item -and $item.PSIsContainer) {
            & takeown /F $Path /A /R /D Y *> $null
            & icacls $Path /grant "${adminAccount}:(F)" /T /C /Q *> $null
        }
        else {
            & takeown /F $Path /A *> $null
            & icacls $Path /grant "${adminAccount}:(F)" /C /Q *> $null
        }
    }
    catch {
        Write-Log "Could not reset permissions for $Description : $_" "WARN"
    }

    Remove-Item -LiteralPath $Path -Recurse:$Recurse.IsPresent -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) {
        Write-Log "Cleanup incomplete for $Description; some protected files remain." "WARN"
        return $false
    }

    return $true
}

function Test-Prerequisites {
    Write-Log "Checking prerequisites..."
    
    # Check admin rights
    $myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
    $adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator
    
    if (-not $myWindowsPrincipal.IsInRole($adminRole)) {
        Write-Log "Script must run as Administrator!" "ERROR"
        throw "Administrative privileges required"
    }
    
    # Check ISO mount
    if (-not (Test-Path "$DriveLetter\sources\boot.wim")) {
        Write-Log "boot.wim not found at $DriveLetter\sources\" "ERROR"
        throw "Invalid Windows 11 ISO mount point"
    }
    
    # Check for install.wim or install.esd
    if (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd")) {
        Write-Log "No install.wim or install.esd found" "ERROR"
        throw "Windows installation files not found"
    }
    
    # Check disk space (minimum 15GB recommended)
    $disk = Get-PSDrive -Name $ScratchDisk[0] -ErrorAction SilentlyContinue
    if ($disk) {
        $freeGB = [math]::Round($disk.Free / 1GB, 2)
        Write-Log "Available space on ${ScratchDisk}: ${freeGB}GB"
        if ($freeGB -lt 15) {
            Write-Log "Low disk space warning: ${freeGB}GB (15GB+ recommended)" "WARN"
        }
    }
    
    Write-Log "Prerequisites check passed"
}

function Initialize-Directories {
    Write-Log "Initializing directories..."
    New-Item -ItemType Directory -Force -Path "$tiny11Dir\sources" | Out-Null
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
    Write-Log "Directories created"
}

function Convert-ESDToWIM {
    Write-Log "Converting install.esd to install.wim..."
    
    $esdPath = "$DriveLetter\sources\install.esd"
    $tempWimPath = "$tiny11Dir\sources\install.wim"
    
    # Validate index exists in ESD
    $images = Get-WindowsImage -ImagePath $esdPath
    $validIndices = $images.ImageIndex
    
    if ($INDEX -notin $validIndices) {
        Write-Log "Invalid index $INDEX. Available: $($validIndices -join ', ')" "ERROR"
        throw "Image index $INDEX not found in install.esd"
    }
    
    Write-Log "Exporting image index $INDEX from ESD (this may take 10-20 minutes)..."
    Export-WindowsImage -SourceImagePath $esdPath -SourceIndex $INDEX `
        -DestinationImagePath $tempWimPath -CompressionType Maximum -CheckIntegrity
    
    Write-Log "ESD conversion complete"
}

function Copy-WindowsFiles {
    Write-Log "Copying Windows installation files from $DriveLetter..."
    Copy-Item -Path "$DriveLetter\*" -Destination $tiny11Dir -Recurse -Force
    
    # Remove read-only attribute and delete install.esd if present
    if (Test-Path "$tiny11Dir\sources\install.esd") {
        Set-ItemProperty -Path "$tiny11Dir\sources\install.esd" -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        Remove-Item "$tiny11Dir\sources\install.esd" -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path "$tiny11Dir\sources\boot.wim")) {
        throw "Copied source is invalid: missing $tiny11Dir\sources\boot.wim"
    }
    if (-not (Test-Path "$tiny11Dir\sources\install.wim")) {
        throw "Copied source is invalid: missing $tiny11Dir\sources\install.wim"
    }
    
    Write-Log "File copy complete"
}

function Test-ImageIndex {
    Write-Log "Validating image index $INDEX..."
    
    $images = Get-WindowsImage -ImagePath $wimFilePath
    $validIndices = $images.ImageIndex
    
    if ($INDEX -notin $validIndices) {
        Write-Log "Invalid index $INDEX. Available indices:" "ERROR"
        $images | ForEach-Object { Write-Log "  Index $($_.ImageIndex): $($_.ImageName)" }
        throw "Image index $INDEX not found"
    }
    
    $selectedImage = $images | Where-Object { $_.ImageIndex -eq $INDEX }
    Write-Log "Selected: Index $INDEX - $($selectedImage.ImageName)"
}

function Mount-WindowsImageFile {
    Write-Log "Mounting Windows image (Index: $INDEX)..."
    
    # Take ownership and set permissions
    & takeown /F $wimFilePath /A | Out-Null
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminAccount = $adminSID.Translate([System.Security.Principal.NTAccount]).Value
    & icacls $wimFilePath /grant "${adminAccount}:(F)" | Out-Null
    
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    
    Mount-WindowsImage -ImagePath $wimFilePath -Index $INDEX -Path $scratchDir
    Write-Log "Image mounted at $scratchDir"
}

function Get-ImageMetadata {
    Write-Log "Extracting image metadata..."
    
    # Get language
    $imageIntl = & dism /English /Get-Intl "/Image:$scratchDir"
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }
    
    if ($languageLine) {
        $script:languageCode = $Matches[1]
        Write-Log "Language: $script:languageCode"
    }
    
    # Get architecture
    $imageInfo = & dism /English /Get-WimInfo "/wimFile:$wimFilePath" "/index:$INDEX"
    $lines = $imageInfo -split '\r?\n'
    
    foreach ($line in $lines) {
        if ($line -like '*Architecture : *') {
            $script:architecture = $line -replace 'Architecture : ', ''
            if ($script:architecture -eq 'x64') {
                $script:architecture = 'amd64'
            }
            Write-Log "Architecture: $script:architecture"
            break
        }
    }
}

function Remove-BloatwareApps {
    Write-Log "Removing provisioned appx packages..."
    
    $packages = & dism /English "/image:$scratchDir" /Get-ProvisionedAppxPackages |
    ForEach-Object {
        if ($_ -match 'PackageName : (.*)') {
            $matches[1]
        }
    }
    
    $packagePrefixes = @(
        'AppUp.IntelManagementandSecurityStatus',
        'Clipchamp.Clipchamp',
        'DolbyLaboratories.DolbyAccess',
        'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.Copilot',
        'Microsoft.Windows.CrossDevice',
        'Microsoft.GamingApp',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.MixedReality.Portal',
        'Microsoft.MSPaint',
        'Microsoft.Office.OneNote',
        'Microsoft.OfficePushNotificationUtility',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.People',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.SkypeApp',
        'Microsoft.StartExperiencesApp',
        'Microsoft.Todos',
        'Microsoft.Wallet',
        'Microsoft.Windows.DevHome',
        'Microsoft.Windows.Copilot',
        'Microsoft.Windows.Teams',
        'Microsoft.WindowsAlarms',
        'Microsoft.WindowsCamera',
        'microsoft.windowscommunicationsapps',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'MicrosoftCorporationII.MicrosoftFamily',
        'MicrosoftCorporationII.QuickAssist',
        'MSTeams',
        'MicrosoftTeams',
        'Microsoft.549981C3F5F10',
        'Microsoft.Windows.AI',
        'Microsoft.Windows.AIFabric',
        'Microsoft.Windows.Recall',
        'Microsoft.Windows.CoreAI',
        'Microsoft.Recall'
    )
    
    $packagesToRemove = $packages | Where-Object {
        $packageName = $_
        $packagePrefixes | Where-Object { $packageName -like "*$_*" }
    }
    
    $removeCount = 0
    foreach ($package in $packagesToRemove) {
        Write-Log "Removing: $package"
        Invoke-NativeChecked -FilePath 'dism' -Arguments @(
            '/English',
            "/image:$scratchDir",
            '/Remove-ProvisionedAppxPackage',
            "/PackageName:$package"
        ) -Action "Remove provisioned appx package $package" | Out-Null
        $removeCount++
    }
    
    Write-Log "Removed $removeCount appx packages"
}

function Remove-EdgeAndOneDrive {
    Write-Log "Removing Microsoft Edge..."
    
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminAccount = $adminSID.Translate([System.Security.Principal.NTAccount]).Value
    
    $edgePaths = @(
        "$scratchDir\Program Files (x86)\Microsoft\Edge",
        "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate",
        "$scratchDir\Program Files (x86)\Microsoft\EdgeCore",
        "$scratchDir\Windows\System32\Microsoft-Edge-Webview"
    )
    
    foreach ($path in $edgePaths) {
        if (Test-Path $path) {
            & takeown /f $path /r /a | Out-Null
            & icacls $path /grant "${adminAccount}:(F)" /T /C | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Write-Log "Removing OneDrive..."
    $oneDrivePath = "$scratchDir\Windows\System32\OneDriveSetup.exe"
    if (Test-Path $oneDrivePath) {
        & takeown /f $oneDrivePath /a | Out-Null
        & icacls $oneDrivePath /grant "${adminAccount}:(F)" /T /C | Out-Null
        Remove-Item -Path $oneDrivePath -Force -ErrorAction SilentlyContinue
    }
    
    Write-Log "Edge and OneDrive removal complete"
}

function Set-RegistryTweaks {
    Write-Log "Loading registry hives..."
    
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zCOMPONENTS', "$scratchDir\Windows\System32\config\COMPONENTS") -Action 'Load COMPONENTS hive' | Out-Null
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zDEFAULT', "$scratchDir\Windows\System32\config\default") -Action 'Load DEFAULT hive' | Out-Null
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zNTUSER', "$scratchDir\Users\Default\ntuser.dat") -Action 'Load NTUSER hive' | Out-Null
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zSOFTWARE', "$scratchDir\Windows\System32\config\SOFTWARE") -Action 'Load SOFTWARE hive' | Out-Null
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zSYSTEM', "$scratchDir\Windows\System32\config\SYSTEM") -Action 'Load SYSTEM hive' | Out-Null
    
    Write-Log "Applying registry tweaks..."
    
    # Bypass system requirements
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'HideUnsupportedHardwareNotifications' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    
    # Disable sponsored apps and regional bloatware (Yandex, TikTok, etc.)
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\CloudContent' 'DisableThirdPartySuggestions' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
    
    Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
    
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
    
    # Enable local accounts on OOBE
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 'REG_DWORD' '1'
    
    # Copy autounattend.xml if exists
    if (Test-Path "$PSScriptRoot\autounattend.xml") {
        Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$scratchDir\Windows\System32\Sysprep\autounattend.xml" -Force
        Write-Log "Copied autounattend.xml"
    }
    
    # Disable reserved storage
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
    
    # Disable BitLocker
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    
    # Disable Chat icon
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

    # Disable News & Interests / Widgets
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 'REG_DWORD' '0'
    
    # Remove Edge registries
    Remove-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
    Remove-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
    Remove-RegistryValue "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
    Remove-RegistryValue "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
    
    # Disable OneDrive folder backup
    Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
    
    # Disable telemetry
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
    
    # Prevent DevHome and Outlook installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
    
    # Disable Copilot
    Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
    
    # Disable AI features (Recall, AI Fabric, Windows AI)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
    
    # Enhanced telemetry removal
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowDeviceNameInTelemetry' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack' 'ShowedToastAtLevel' 'REG_DWORD' '1'
    
    # Prevent Teams installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
    
    # Prevent new Outlook installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
    
    Write-Log "Registry tweaks applied"
}

function Remove-ScheduledTasks {
    Write-Log "Removing telemetry scheduled tasks..."
    
    $tasksPath = "$scratchDir\Windows\System32\Tasks"
    $tasksToRemove = @(
        "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program",
        "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "$tasksPath\Microsoft\Windows\Chkdsk\Proxy",
        "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"
    )
    
    foreach ($task in $tasksToRemove) {
        if (Test-Path $task) {
            Remove-Item -Path $task -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed task: $task"
        }
    }
    
    Write-Log "Scheduled tasks removed"
}

function Remove-NonEssentialServices {
    Write-Log "Disabling non-essential services (minimal for standard build)..."
    
    # Standard build: Only disable diagnostic and telemetry services
    # This preserves maximum compatibility while removing privacy/performance drains
    $servicesToDisable = @(
        'DiagTrack',           # Connected User Experiences and Telemetry
        'WerSvc',              # Windows Error Reporting
        'PcaSvc',              # Program Compatibility Assistant
        'SysMain'              # Superfetch (not needed on SSDs)
    )
    
    foreach ($service in $servicesToDisable) {
        Write-Log "Disabling service: $service"
        try {
            Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$service" 'Start' 'REG_DWORD' '4'
        }
        catch {
            Write-Log "Could not disable service $service : $_" "WARN"
        }
    }
    
    Write-Log "Non-essential services disabled"
}

function Dismount-RegistryHives {
    param(
        [switch]$BestEffort
    )

    Write-Log "Unloading registry hives..."

    $hives = @(
        'HKLM\zCOMPONENTS',
        'HKLM\zDEFAULT',
        'HKLM\zNTUSER',
        'HKLM\zSOFTWARE',
        'HKLM\zSYSTEM'
    )

    foreach ($hive in $hives) {
        if ($BestEffort) {
            Invoke-NativeChecked -FilePath 'reg' -Arguments @('unload', $hive) -Action "Unload $hive" -IgnoreExitCode | Out-Null
        }
        else {
            Invoke-NativeChecked -FilePath 'reg' -Arguments @('unload', $hive) -Action "Unload $hive" | Out-Null
        }
    }
    
    Write-Log "Registry hives unloaded"
}

function Optimize-WindowsImage {
    Write-Log "Cleaning up Windows image (this may take 10-15 minutes)..."
    Invoke-NativeChecked -FilePath 'dism.exe' -Arguments @(
        "/Image:$scratchDir", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase'
    ) -Action 'DISM image cleanup' | Out-Null
    Write-Log "Image cleanup complete"
}

function Dismount-AndExport {
    Write-Log "Dismounting install.wim..."
    Dismount-WindowsImage -Path $scratchDir -Save
    
    if ($ESD) {
        Write-Log "Exporting image as ESD with maximum compression (this may take 15-20 minutes)..."
        $tempImg = "$tiny11Dir\sources\install.esd"
        Invoke-NativeChecked -FilePath 'Dism.exe' -Arguments @(
            '/Export-Image', "/SourceImageFile:$wimFilePath", "/SourceIndex:$INDEX",
            "/DestinationImageFile:$tempImg", '/Compress:recovery'
        ) -Action 'DISM ESD export' | Out-Null
        
        Remove-Item -Path $wimFilePath -Force
        Write-Log "Install.esd export complete"
    }
    else {
        Write-Log "Exporting image as WIM with maximum compression (this may take 1-2 minutes)..."
        $tempImg = "$tiny11Dir\sources\install2.wim"
        Invoke-NativeChecked -FilePath 'Dism.exe' -Arguments @(
            '/Export-Image', "/SourceImageFile:$wimFilePath", "/SourceIndex:$INDEX",
            "/DestinationImageFile:$tempImg", '/Compress:max'
        ) -Action 'DISM WIM export' | Out-Null
        
        Remove-Item -Path $wimFilePath -Force
        Rename-Item -Path $tempImg -NewName "install.wim"
        Write-Log "Install.wim export complete"
    }
}

function Invoke-BootImageProcessing {
    Write-Log "Processing boot.wim..."
    
    $bootWimPath = "$tiny11Dir\sources\boot.wim"
    
    # Take ownership
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminAccount = $adminSID.Translate([System.Security.Principal.NTAccount]).Value
    & takeown /F $bootWimPath /A | Out-Null
    & icacls $bootWimPath /grant "${adminAccount}:(F)" | Out-Null
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    
    Write-Log "Mounting boot.wim (Index 2)..."
    Mount-WindowsImage -ImagePath $bootWimPath -Index 2 -Path $scratchDir
    
    Write-Log "Loading boot image registry..."
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zCOMPONENTS', "$scratchDir\Windows\System32\config\COMPONENTS") -Action 'Load boot COMPONENTS hive' | Out-Null
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zDEFAULT', "$scratchDir\Windows\System32\config\default") -Action 'Load boot DEFAULT hive' | Out-Null
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zNTUSER', "$scratchDir\Users\Default\ntuser.dat") -Action 'Load boot NTUSER hive' | Out-Null
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zSOFTWARE', "$scratchDir\Windows\System32\config\SOFTWARE") -Action 'Load boot SOFTWARE hive' | Out-Null
    Invoke-NativeChecked -FilePath 'reg' -Arguments @('load', 'HKLM\zSYSTEM', "$scratchDir\Windows\System32\config\SYSTEM") -Action 'Load boot SYSTEM hive' | Out-Null
    
    Write-Log "Applying system requirement bypasses to boot image..."
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'HideUnsupportedHardwareNotifications' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    
    Dismount-RegistryHives
    
    Write-Log "Dismounting boot.wim..."
    Dismount-WindowsImage -Path $scratchDir -Save
    
    Write-Log "Boot image processing complete"
}

function New-TinyISO {
    Write-Log "Creating ISO image..."
    
    # Copy autounattend.xml to ISO root for OOBE bypass
    if (Test-Path "$PSScriptRoot\autounattend.xml") {
        Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$tiny11Dir\autounattend.xml" -Force
        Write-Log "Copied autounattend.xml to ISO root"
    }
    
    # Determine oscdimg.exe location
    $hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
    $ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArchitecture\Oscdimg"
    $localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"
    
    if (Test-Path "$ADKDepTools\oscdimg.exe") {
        Write-Log "Using oscdimg.exe from Windows ADK"
        $OSCDIMG = "$ADKDepTools\oscdimg.exe"
    }
    else {
        Write-Log "ADK not found, downloading oscdimg.exe..."
        $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
        
        if (-not (Test-Path $localOSCDIMGPath)) {
            Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath -UseBasicParsing
            Write-Log "Downloaded oscdimg.exe"
        }
        
        $OSCDIMG = $localOSCDIMGPath
    }
    
    Write-Log "Building bootable ISO (this may take 5-10 minutes)..."
    Invoke-NativeChecked -FilePath $OSCDIMG -Arguments @(
        '-m',
        '-o',
        '-u2',
        '-udfver102',
        "-bootdata:2#p0,e,b$tiny11Dir\boot\etfsboot.com#pEF,e,b$tiny11Dir\efi\microsoft\boot\efisys.bin",
        $tiny11Dir,
        $outputISO
    ) -Action 'Build bootable ISO with oscdimg' | Out-Null
    
    if (Test-Path $outputISO) {
        $isoSize = [math]::Round((Get-Item $outputISO).Length / 1GB, 2)
        Write-Log "ISO created successfully: $outputISO (${isoSize}GB)"
    }
    else {
        throw "ISO creation failed"
    }
}

function Invoke-Cleanup {
    if ($SkipCleanup) {
        Write-Log "Skipping cleanup (SkipCleanup flag set)" "WARN"
        return
    }
    
    Write-Log "Performing cleanup..."
    
    # Remove temporary directories
    Remove-PathQuietly -Path $tiny11Dir -Description "tiny11 folder" -Recurse | Out-Null
    Remove-PathQuietly -Path $scratchDir -Description "scratchdir folder" -Recurse | Out-Null
    
    # Remove downloaded files
    Remove-PathQuietly -Path "$PSScriptRoot\oscdimg.exe" -Description "downloaded oscdimg.exe" | Out-Null
    # Note: autounattend.xml is a tracked repo file — do NOT delete from PSScriptRoot
    
    # Dismount auto-mounted ISO if applicable
    if ($script:AutoMountedISO) {
        Write-Log "Dismounting auto-mounted ISO: $($script:AutoMountedISO)"
        Dismount-DiskImage -ImagePath $script:AutoMountedISO -ErrorAction SilentlyContinue
    }
    
    # Verify cleanup
    $remainingItems = @()
    if (Test-Path $tiny11Dir) { $remainingItems += "tiny11 folder" }
    if (Test-Path $scratchDir) { $remainingItems += "scratchdir folder" }
    
    if ($remainingItems.Count -gt 0) {
        Write-Log "Cleanup incomplete: $($remainingItems -join ', ') still exist" "WARN"
    }
    else {
        Write-Log "Cleanup complete"
    }
}

#---------[ Main Execution ]---------#
try {
    Write-Log "=== Tiny11 Headless Builder Started ===" "INFO"
    Write-Log "Author: kelexine (https://github.com/kelexine)"
    
    # Auto-mount ISO if -ISOPath was provided
    if ($ISOPath) {
        if (-not (Test-Path $ISOPath)) { throw "ISO file not found: $ISOPath" }
        $resolvedPath = (Resolve-Path $ISOPath).Path
        Write-Log "Mounting ISO: $resolvedPath"
        $mountResult = Mount-DiskImage -ImagePath $resolvedPath -PassThru
        
        $foundISO = $null
        for ($attempt = 0; $attempt -lt 10 -and -not $foundISO; $attempt++) {
            $isoVolume = $mountResult | Get-Volume -ErrorAction SilentlyContinue
            if ($isoVolume) {
                $foundISO = $isoVolume |
                Where-Object { $_.PSObject.Properties.Name -contains 'DriveLetter' -and $_.DriveLetter } |
                Select-Object -First 1 -ExpandProperty DriveLetter
            }
            if (-not $foundISO) {
                Start-Sleep -Milliseconds 500
            }
        }
        
        if (-not $foundISO) { throw "Failed to get drive letter after mounting $resolvedPath" }
        $ISO = $foundISO
        Write-Log "ISO mounted at drive: ${ISO}:"
        $script:AutoMountedISO = $resolvedPath
    }
    elseif (-not $ISO) {
        throw "Either -ISO or -ISOPath must be specified"
    }
    $DriveLetter = $ISO + ":"
    
    Write-Log "Parameters: ISO=$ISO, INDEX=$INDEX, SCRATCH=$ScratchDisk, Output=$outputISO"
    
    Test-Prerequisites
    
    # Handle install.esd conversion if needed
    if (Test-Path "$DriveLetter\sources\install.esd") {
        Write-Log "Found install.esd, conversion required"
        Initialize-Directories
        Convert-ESDToWIM
        Copy-WindowsFiles
    }
    else {
        Write-Log "Found install.wim, no conversion needed"
        Initialize-Directories
        Copy-WindowsFiles
    }
    
    Test-ImageIndex
    Mount-WindowsImageFile
    Get-ImageMetadata
    
    # Customization phase
    Remove-BloatwareApps
    Remove-EdgeAndOneDrive
    Set-RegistryTweaks
    Remove-ScheduledTasks
    Remove-NonEssentialServices
    Dismount-RegistryHives
    
    # Finalization phase
    Optimize-WindowsImage
    Dismount-AndExport
    Invoke-BootImageProcessing
    New-TinyISO
    
    # Cleanup
    Invoke-Cleanup
    
    Write-Log "=== Tiny11 Build Completed Successfully ===" "INFO"
    Write-Log "Output: $outputISO"
    
    exit 0
    
}
catch {
    Write-Log "FATAL ERROR: $_" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    
    # Emergency cleanup
    try {
        $mountedHere = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and ($_.Path -ieq $scratchDir)
        }
        if ($mountedHere) {
            Write-Log "Emergency dismount (current scratch path): $scratchDir" "WARN"
            Dismount-WindowsImage -Path $scratchDir -Discard -ErrorAction SilentlyContinue
        }
        
        # Dismount auto-mounted ISO
        if ($script:AutoMountedISO) {
            Write-Log "Emergency dismount ISO: $($script:AutoMountedISO)" "WARN"
            Dismount-DiskImage -ImagePath $script:AutoMountedISO -ErrorAction SilentlyContinue
        }
        
        try { Dismount-RegistryHives -BestEffort } catch { }
    }
    catch {
        Write-Log "Emergency cleanup failed: $_" "ERROR"
    }
    
    exit 1
}
