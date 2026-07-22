<#
.SYNOPSIS
    Runs inside the temporary CI virtual machine after the first Windows logon.

.DESCRIPTION
    Executes the production FirstLogon.ps1 when present, validates the installed x64
    Windows system, optionally audits the expected Tiny11 state, and writes machine-readable
    results to the writable CI media attached by test-windows-install.ps1.
#>

[CmdletBinding()]
param(
    [string]$ResultDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

$checks = New-Object 'System.Collections.Generic.List[object]'
$auditTiny11 = Test-Path -LiteralPath (Join-Path $ResultDirectory 'AUDIT_TINY11.TAG')

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Expected,
        [AllowEmptyString()]
        [string]$Actual
    )

    $checks.Add([pscustomobject][ordered]@{
        name     = $Name
        passed   = $Passed
        expected = $Expected
        actual   = $Actual
    })
}

function Test-RegistryExpectation {
    param(
        [string]$Path,
        [string]$Name,
        $Expected
    )

    try {
        $actual = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
        Add-Check -Name "Registry: $Path\$Name" `
            -Passed ([string]$actual -eq [string]$Expected) `
            -Expected ([string]$Expected) `
            -Actual ([string]$actual)
    }
    catch {
        Add-Check -Name "Registry: $Path\$Name" -Passed $false -Expected ([string]$Expected) -Actual '<missing>'
    }
}

function Copy-GuestLog {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $destination = Join-Path $ResultDirectory ("guest-" + (Split-Path -Leaf $Path))
        Copy-Item -LiteralPath $Path -Destination $destination -Force -ErrorAction SilentlyContinue
    }
}

function Send-SerialCompletionSignal {
    param(
        [string]$Signal,
        [string]$ResultJson
    )

    $serialPort = $null
    try {
        $payload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ResultJson))
        $serialPort = [System.IO.Ports.SerialPort]::new()
        $serialPort.PortName = 'COM1'
        $serialPort.BaudRate = 115200
        $serialPort.Parity = [System.IO.Ports.Parity]::None
        $serialPort.DataBits = 8
        $serialPort.StopBits = [System.IO.Ports.StopBits]::One
        $serialPort.WriteTimeout = 15000
        $serialPort.Open()
        $serialPort.WriteLine('CI_WINDOWS_INSTALL_AUDIT_RESULT_BEGIN')
        $serialPort.WriteLine($payload)
        $serialPort.WriteLine('CI_WINDOWS_INSTALL_AUDIT_RESULT_END')
        $serialPort.WriteLine($Signal)
    }
    catch {
        Set-Content -LiteralPath (Join-Path $ResultDirectory 'serial-signal-error.txt') `
            -Value $_.Exception.ToString() -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    finally {
        if ($serialPort) {
            if ($serialPort.IsOpen) { $serialPort.Close() }
            $serialPort.Dispose()
        }
    }
}

$productionFirstLogon = 'C:\Windows\Setup\Scripts\FirstLogon.ps1'
if (Test-Path -LiteralPath $productionFirstLogon -PathType Leaf) {
    try {
        & $productionFirstLogon
        Add-Check -Name 'Production FirstLogon.ps1 execution' -Passed $true -Expected 'Completed' -Actual 'Completed'
    }
    catch {
        Add-Check -Name 'Production FirstLogon.ps1 execution' -Passed $false -Expected 'Completed' -Actual $_.Exception.Message
    }
}
elseif ($auditTiny11) {
    Add-Check -Name 'Production FirstLogon.ps1 presence' -Passed $false -Expected 'Present' -Actual 'Missing'
}

Start-Sleep -Seconds 5

try {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Add-Check -Name 'Operating system architecture' `
        -Passed ([Environment]::Is64BitOperatingSystem) `
        -Expected '64-bit' `
        -Actual $operatingSystem.OSArchitecture
    Add-Check -Name 'Windows client installation' `
        -Passed ([int]$operatingSystem.ProductType -eq 1) `
        -Expected 'ProductType 1 (client)' `
        -Actual ("ProductType {0}; {1}" -f $operatingSystem.ProductType, $operatingSystem.Caption)
    Add-Check -Name 'Windows system drive' `
        -Passed (Test-Path -LiteralPath 'C:\Windows\explorer.exe' -PathType Leaf) `
        -Expected 'C:\Windows\explorer.exe present' `
        -Actual $(if (Test-Path -LiteralPath 'C:\Windows\explorer.exe' -PathType Leaf) { 'Present' } else { 'Missing' })
}
catch {
    Add-Check -Name 'Installed Windows metadata' -Passed $false -Expected 'Readable' -Actual $_.Exception.Message
}

if ($auditTiny11) {
    foreach ($logName in @(
        'Specialize.log',
        'DefaultUser.log',
        'FirstLogon.log',
        'RemovePackages.log',
        'RemoveCapabilities.log',
        'RemoveFeatures.log'
    )) {
        $logPath = Join-Path 'C:\Windows\Setup\Scripts' $logName
        Add-Check -Name "Tiny11 setup log: $logName" `
            -Passed (Test-Path -LiteralPath $logPath -PathType Leaf) `
            -Expected 'Present' `
            -Actual $(if (Test-Path -LiteralPath $logPath -PathType Leaf) { 'Present' } else { 'Missing' })
    }

    $registryExpectations = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'HideUnsupportedHardwareNotifications'; Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSoftLanding'; Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'DoNotShowFeedbackNotifications'; Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowDeviceNameInTelemetry'; Value = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'; Name = 'DisablePCA'; Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat'; Name = 'ChatIcon'; Value = 3 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled'; Value = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement'; Value = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo'; Value = 1 },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'; Name = 'PreventDeviceEncryption'; Value = 1 },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn'; Value = 0 },
        @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 },
        @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 },
        @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 },
        @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo'; Value = 1 }
    )
    foreach ($expectation in $registryExpectations) {
        Test-RegistryExpectation -Path $expectation.Path -Name $expectation.Name -Expected $expectation.Value
    }

    foreach ($serviceName in @('DiagTrack', 'WerSvc', 'dmwappushservice')) {
        $servicePath = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
        if (Test-Path -LiteralPath $servicePath) {
            Test-RegistryExpectation -Path $servicePath -Name 'Start' -Expected 4
        }
        else {
            Add-Check -Name "Service disabled or absent: $serviceName" -Passed $true -Expected 'Disabled or absent' -Actual 'Absent'
        }
    }

    try {
        $sysMainStart = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain' -Name 'Start' -ErrorAction Stop).Start
        Add-Check -Name 'SysMain remains enabled' -Passed ([int]$sysMainStart -ne 4) -Expected 'Not disabled' -Actual ([string]$sysMainStart)
    }
    catch {
        Add-Check -Name 'SysMain remains enabled' -Passed $false -Expected 'Present and not disabled' -Actual '<missing>'
    }

    $scheduledTasks = @(
        @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
        @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
        @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
        @{ Path = '\Microsoft\Windows\Autochk\'; Name = 'Proxy' },
        @{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' },
        @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting' }
    )
    foreach ($task in $scheduledTasks) {
        $scheduledTask = Get-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction SilentlyContinue
        $actualState = if ($null -eq $scheduledTask) { 'Absent' } else { [string]$scheduledTask.State }
        Add-Check -Name ("Scheduled task disabled or absent: {0}{1}" -f $task.Path, $task.Name) `
            -Passed ($null -eq $scheduledTask -or $scheduledTask.State -eq 'Disabled') `
            -Expected 'Disabled or absent' `
            -Actual $actualState
    }

    $removedPackagePrefixes = @(
        'AppUp.IntelManagementandSecurityStatus', 'Clipchamp.Clipchamp',
        'DolbyLaboratories.DolbyAccess', 'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
        'Microsoft.BingNews', 'Microsoft.BingSearch', 'Microsoft.BingWeather', 'Microsoft.Copilot',
        'Microsoft.Windows.CrossDevice', 'MicrosoftWindows.CrossDevice', 'Microsoft.GamingApp',
        'Microsoft.GetHelp', 'Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes', 'Microsoft.MixedReality.Portal', 'Microsoft.MSPaint',
        'Microsoft.Office.OneNote', 'Microsoft.OfficePushNotificationUtility', 'Microsoft.OutlookForWindows',
        'Microsoft.Paint', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop', 'Microsoft.SkypeApp',
        'Microsoft.StartExperiencesApp', 'Microsoft.Todos', 'Microsoft.Wallet', 'Microsoft.Windows.DevHome',
        'Microsoft.Windows.Copilot', 'Microsoft.Windows.Teams', 'Microsoft.WindowsAlarms', 'Microsoft.WindowsCamera',
        'microsoft.windowscommunicationsapps', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps',
        'Microsoft.WindowsSoundRecorder', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxApp', 'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
        'MicrosoftCorporationII.MicrosoftFamily', 'MicrosoftCorporationII.QuickAssist', 'MSTeams',
        'MicrosoftTeams', 'Microsoft.549981C3F5F10', 'Microsoft.Windows.AI', 'Microsoft.Windows.AIFabric',
        'Microsoft.Windows.Recall', 'Microsoft.Windows.CoreAI', 'Microsoft.Recall'
    )
    $packageNames = @(
        @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue).DisplayName
        @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue).Name
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    $remainingPackages = @(
        foreach ($prefix in $removedPackagePrefixes) {
            if ($packageNames | Where-Object { $_ -like "*$prefix*" }) { $prefix }
        }
    )
    Add-Check -Name 'Removed Appx package families remain absent' `
        -Passed ($remainingPackages.Count -eq 0) `
        -Expected 'None present' `
        -Actual $(if ($remainingPackages.Count) { $remainingPackages -join '; ' } else { 'None present' })

    $removedCapabilities = @(
        'Print.Fax.Scan', 'Language.Handwriting', 'Browser.InternetExplorer', 'MathRecognizer',
        'OneCoreUAP.OneSync', 'Microsoft.Windows.MSPaint', 'Microsoft.Windows.PowerShell.ISE',
        'App.Support.QuickAssist', 'Language.Speech', 'Language.TextToSpeech', 'App.StepsRecorder',
        'Hello.Face.18967', 'Hello.Face.Migration.18967', 'Hello.Face.20134',
        'Media.WindowsMediaPlayer', 'Microsoft.Windows.WordPad'
    )
    $capabilityState = @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue)
    $remainingCapabilities = @(
        foreach ($selector in $removedCapabilities) {
            $matches = @($capabilityState | Where-Object { ($_.Name -split '~')[0] -eq $selector })
            if ($matches | Where-Object { $_.State -notin @('NotPresent', 'Removed') }) { $selector }
        }
    )
    Add-Check -Name 'Removed Windows capabilities remain absent' `
        -Passed ($remainingCapabilities.Count -eq 0) `
        -Expected 'None present' `
        -Actual $(if ($remainingCapabilities.Count) { $remainingCapabilities -join '; ' } else { 'None present' })

    $remainingFeatures = @()
    foreach ($featureName in @('MicrosoftWindowsPowerShellV2Root', 'Microsoft-RemoteDesktopConnection', 'Recall')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction SilentlyContinue
        if ($null -ne $feature -and $feature.State -notin @('Disabled', 'DisabledWithPayloadRemoved')) {
            $remainingFeatures += $featureName
        }
    }
    Add-Check -Name 'Removed Windows optional features remain disabled' `
        -Passed ($remainingFeatures.Count -eq 0) `
        -Expected 'None enabled' `
        -Actual $(if ($remainingFeatures.Count) { $remainingFeatures -join '; ' } else { 'None enabled' })

    $removedPaths = @(
        'C:\Program Files (x86)\Microsoft\Edge',
        'C:\Program Files (x86)\Microsoft\EdgeUpdate',
        'C:\Program Files (x86)\Microsoft\EdgeCore',
        'C:\Program Files (x86)\Microsoft\EdgeWebView',
        'C:\Windows\System32\OneDriveSetup.exe',
        'C:\Windows\SysWOW64\OneDriveSetup.exe'
    )
    $remainingPaths = @($removedPaths | Where-Object { Test-Path -LiteralPath $_ })
    Add-Check -Name 'Removed Edge and OneDrive paths remain absent' `
        -Passed ($remainingPaths.Count -eq 0) `
        -Expected 'None present' `
        -Actual $(if ($remainingPaths.Count) { $remainingPaths -join '; ' } else { 'None present' })
}

foreach ($logPath in @(
    'C:\Windows\Panther\setupact.log',
    'C:\Windows\Panther\setuperr.log',
    'C:\Windows\Setup\Scripts\Specialize.log',
    'C:\Windows\Setup\Scripts\DefaultUser.log',
    'C:\Windows\Setup\Scripts\FirstLogon.log',
    'C:\Windows\Setup\Scripts\RemovePackages.log',
    'C:\Windows\Setup\Scripts\RemoveCapabilities.log',
    'C:\Windows\Setup\Scripts\RemoveFeatures.log'
)) {
    Copy-GuestLog -Path $logPath
}

$failedChecks = @($checks | Where-Object { -not $_.passed })
$result = [ordered]@{
    completedAtUtc      = [datetime]::UtcNow.ToString('o')
    computerName        = $env:COMPUTERNAME
    tiny11AuditRequested = $auditTiny11
    passed              = ($failedChecks.Count -eq 0)
    totalChecks         = $checks.Count
    failedChecks        = $failedChecks.Count
    # Avoid the Windows PowerShell 5.1 generic List<T> array-subexpression binding bug.
    checks              = $checks.ToArray()
}

try {
    $resultJson = $result | ConvertTo-Json -Depth 6 -ErrorAction Stop
}
catch {
    $resultJson = [ordered]@{
        completedAtUtc       = [datetime]::UtcNow.ToString('o')
        computerName         = $env:COMPUTERNAME
        tiny11AuditRequested = $auditTiny11
        passed               = $false
        totalChecks          = 1
        failedChecks         = 1
        checks               = @([ordered]@{
            name = 'Serialize audit result'; passed = $false; expected = 'Valid JSON'; actual = $_.Exception.Message
        })
    } | ConvertTo-Json -Depth 4
}
if ([string]::IsNullOrWhiteSpace($resultJson)) {
    throw 'Audit result serialization produced an empty JSON payload.'
}
$resultPath = Join-Path $ResultDirectory 'install-test-result.json'
$resultJson | Set-Content -LiteralPath $resultPath -Encoding UTF8 -ErrorAction SilentlyContinue
Set-Content -LiteralPath (Join-Path $ResultDirectory 'CI_INSTALL_COMPLETE.TAG') -Value 'Installed Windows audit completed' -Encoding ASCII
Send-SerialCompletionSignal -Signal 'CI_WINDOWS_INSTALL_AUDIT_COMPLETE' -ResultJson $resultJson

# Give the host time to observe the serial signal and capture the success screenshot. A clean guest
# shutdown also flushes the writable FAT test media before the host reads the result files.
Start-Sleep -Seconds 20
shutdown.exe /s /t 0 /f
