#!/usr/bin/pwsh

param(
  [string]$windowsTargetName,
  [string]$destinationDirectory = 'output',
  [ValidateSet("x64", "arm64")] [string]$architecture = "x64",
  [ValidateSet("pro", "home")] [string]$edition = "pro",
  [ValidateSet("nb-no", "fr-ca", "fi-fi", "lv-lv", "es-es", "en-gb", "zh-tw", "th-th", "sv-se", "en-us", "es-mx", "bg-bg", "hr-hr", "pt-br", "el-gr", "cs-cz", "it-it", "sk-sk", "pl-pl", "sl-si", "neutral", "ja-jp", "et-ee", "ro-ro", "fr-fr", "pt-pt", "ar-sa", "lt-lt", "hu-hu", "da-dk", "zh-cn", "uk-ua", "tr-tr", "ru-ru", "nl-nl", "he-il", "ko-kr", "sr-latn-rs", "de-de")]
  [string]$lang = "en-us",
  [switch]$esd,
  [switch]$netfx3,
  [string]$revision,
  [switch]$SkipChecksum
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

$preview  = $false
$ringLower = $null

trap {
  Write-Host "ERROR: $_"
  @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
  @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
  Exit 1
}

# ------------------------------
# Log helpers + DISM bucketed progress (no aria2 parsing)
# ------------------------------
$script:reAnsi = [regex]'\x1B\[[0-9;]*[A-Za-z]'
$script:LastPrintedLine = $null
function Write-CleanLine([string]$text) {
  $clean = $script:reAnsi.Replace(($text ?? ''), '')
  if ($clean -eq $script:LastPrintedLine) { return }
  $script:LastPrintedLine = $clean
  Write-Host $clean
}

# DISM buckets (0/10/.../100)
$script:DismLastBucket = -1
$script:DismEveryPercent = if ($env:DISM_PROGRESS_STEP) { [int]$env:DISM_PROGRESS_STEP } else { 10 }
$script:DismNormalizeOutput = if ($env:DISM_PROGRESS_RAW -eq '1') { $false } else { $true }

$script:reArchiving = [regex]'Archiving file data:\s+.*?\((\d+)%\)\s+done'
$script:reBracket   = [regex]'\[\s*[= \-]*\s*(\d+(?:[.,]\d+)?)%\s*[= \-]*\s*\]'
$script:reLoosePct  = [regex]'(^|\s)(\d{1,3})(?:[.,]\d+)?%(\s|$)'

function Get-PercentFromText([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return $null }
  $t = $script:reAnsi.Replace($text, '')

  $m = $script:reArchiving.Match($t)
  if ($m.Success) { return [int]$m.Groups[1].Value }

  $m = $script:reBracket.Match($t)
  if ($m.Success) {
    $pct = $m.Groups[1].Value -replace ',', '.'
    return [int][math]::Floor([double]$pct)
  }

  $m = $script:reLoosePct.Match($t)
  if ($m.Success) {
    $n = [int]$m.Groups[2].Value
    if ($n -ge 0 -and $n -le 100) { return $n }
  }
  return $null
}

function Reset-ProgressSession { $script:DismLastBucket = -1 }

function Emit-ProgressBucket([int]$pct) {
  $bucket = [int]([math]::Floor($pct / $script:DismEveryPercent) * $script:DismEveryPercent)
  if ($bucket -le $script:DismLastBucket) { return $false }
  $script:DismLastBucket = $bucket

  if ($script:DismNormalizeOutput) { Write-CleanLine ("[DISM] Progress: {0}%" -f $bucket) }
  else { Write-CleanLine ("Progress: {0}%" -f $bucket) }

  if ($bucket -ge 100) {
    Write-CleanLine "[DISM] Progress: 100% (done)"
    Reset-ProgressSession
  }
  return $true
}

function Process-ProgressLine([string]$line) {
  $pct = Get-PercentFromText $line
  if ($pct -eq $null) { return $false }
  if ($script:DismLastBucket -ge 0 -and $pct -lt $script:DismLastBucket) { Reset-ProgressSession }
  [void](Emit-ProgressBucket $pct)
  return $true
}

# ------------------------------
# Basic metadata helpers
# ------------------------------
$arch = if ($architecture -eq "x64") { "amd64" } else { "arm64" }

function Get-EditionName($e) {
  switch ($e.ToLower()) {
    "home"  { "Core" }
    default { "Professional" }
  }
}

$dotSystemRevision = if ([string]::IsNullOrWhiteSpace($revision)) { '' } else { ".$revision" }
$systemRevision = if ([string]::IsNullOrWhiteSpace($revision)) { '' } else { " $revision" }

$TARGETS = @{
  "win11-25h2"      = @{ search="windows 11 26200$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "win11-25h2-beta" = @{ search="windows 11 26220$dotSystemRevision $arch"; edition=(Get-EditionName $edition); ring="Wif"; allowedRings=@("Wif","Wis","Beta"); displayVersion="25H2 BETA" }
  "win11-26h1"      = @{ search="windows 11 28000$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "win11-dev"       = @{ search="windows 11 26300$dotSystemRevision $arch"; edition=(Get-EditionName $edition); ring="Dev"; allowedRings=@("Dev","Wif","Wis"); displayVersion="25H2 DEV" }
  "win11-canary"    = @{ search="windows 11$systemRevision $arch"; edition=(Get-EditionName $edition); ring="Canary"; allowedRings=@("Canary"); displayVersion="CANARY" }
}

if (-not $TARGETS.ContainsKey($windowsTargetName)) {
  throw "Unsupported Windows target '$windowsTargetName'. Valid targets: $(@($TARGETS.Keys | Sort-Object) -join ', ')"
}

$currentTarget = $TARGETS[$windowsTargetName]
if ($currentTarget.ContainsKey('ring')) {
  $preview = $true
  $ringLower = "$($currentTarget.ring)".ToLowerInvariant()
}

function New-QueryString([hashtable]$parameters) {
  @($parameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$([System.Net.WebUtility]::UrlEncode([string]$_.Value))" }) -join '&'
}

function Get-ApiItemNames($value) {
  if ($null -eq $value) { return @() }

  if ($value -is [System.Collections.IDictionary]) {
    return @($value.Keys | ForEach-Object { [string]$_ })
  }

  if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
    return @($value | ForEach-Object {
      if ($null -ne $_) { [string]$_ }
    })
  }

  return @($value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
  for ($n = 0; $n -lt 15; ++$n) {
    if ($n) {
      Write-CleanLine "Waiting a bit before retrying the uup-dump api ${name} request #$n"
      Start-Sleep -Seconds 10
      Write-CleanLine "Retrying the uup-dump api ${name} request #$n"
    }
    try {
      $qs = if ($body) { '?' + (New-QueryString $body) } else { '' }
      return Invoke-RestMethod -Method Get -Uri ("https://api.uupdump.net/{0}.php{1}" -f $name, $qs)
    } catch {
      Write-CleanLine "WARN: failed the uup-dump api $name request: $_"
    }
  }
  throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso($name, $target) {
  Write-CleanLine "Getting the $name metadata"
  $result = Invoke-UupDumpApi listid @{ search = $target.search }

  $candidateBuilds = @($result.response.builds.PSObject.Properties)
  if ($candidateBuilds.Count -eq 0) {
    Write-CleanLine "No UUP candidates were returned for search '$($target.search)'."
    return $null
  }

  if ([string]::IsNullOrWhiteSpace($revision)) {
    Write-CleanLine "Revision not specified; selecting the latest matching UUP candidate from API order."
  }
  else {
    Write-CleanLine "Revision specified ($revision); selecting the first matching UUP candidate."
  }

  foreach ($candidate in $candidateBuilds) {
    $id = $candidate.Value.uuid
    $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{ id = $id })
    Write-CleanLine "Checking $name candidate $id ($uupDumpUrl)"

    if (-not $preview) {
      if ($candidate.Value.title -notmatch '(?i)\bversion\b') {
        Write-CleanLine "Skipping candidate ${id}: title does not contain 'version'."
        continue
      }

      $isAllowed = ($target.search -like '*preview*') -or ($candidate.Value.title -notlike '*preview*')
      if (-not $isAllowed) {
        Write-CleanLine "Skipping candidate ${id}: preview build does not match request."
        continue
      }
    }

    Write-CleanLine "Getting the $name $id langs metadata"
    $langResult = Invoke-UupDumpApi listlangs @{ id = $id }
    if ($langResult.response.updateInfo.build -ne $candidate.Value.build) {
      throw 'for some reason listlangs returned an unexpected build'
    }

    $candidate.Value | Add-Member -NotePropertyMembers @{
      langs = $langResult.response.langFancyNames
      info  = $langResult.response.updateInfo
    } -Force

    $langs = @(Get-ApiItemNames $candidate.Value.langs)
    if ($langs -notcontains $lang) {
      Write-CleanLine "Skipping candidate ${id}: expected lang=$lang, got langs=$($langs -join ',')."
      continue
    }

    Write-CleanLine "Getting the $name $id editions metadata"
    $editionsResult = Invoke-UupDumpApi listeditions @{ id = $id; lang = $lang }
    $candidate.Value | Add-Member -NotePropertyMembers @{ editions = $editionsResult.response.editionFancyNames } -Force

    $editions = @(Get-ApiItemNames $candidate.Value.editions)
    $expectedEdition = Get-EditionName $edition
    if ($editions -notcontains $expectedEdition) {
      Write-CleanLine "Skipping candidate ${id}: expected edition=$expectedEdition, got editions=$($editions -join ',')."
      continue
    }

    $selectedRing = if ($candidate.Value.info -and $candidate.Value.info.ring) {
      "$($candidate.Value.info.ring)"
    }
    else {
      'unknown'
    }

    $allowedRings = @()
    if ($target.ContainsKey('allowedRings')) {
      $allowedRings = @($target.allowedRings | ForEach-Object { "$_".ToUpperInvariant() })
    }
    elseif ($target.ContainsKey('ring')) {
      $allowedRings = @("$($target.ring)".ToUpperInvariant())
    }

    if ($allowedRings.Count -gt 0) {
      $actualRing = $selectedRing.ToUpper()
      if ($actualRing -notin $allowedRings) {
        Write-CleanLine "Skipping candidate ${id}: expected ring $($allowedRings -join '/'), got ring=$actualRing."
        continue
      }
    }

    return [PSCustomObject]@{
      name               = $name
      title              = $candidate.Value.title
      build              = $candidate.Value.build
      ring               = $selectedRing
      id                 = $id
      edition            = $target.edition
      virtualEdition     = $target['virtualEdition']
      apiUrl             = 'https://api.uupdump.net/get.php?' + (New-QueryString @{ id = $id; lang = $lang; edition = $target.edition })
      downloadUrl        = 'https://uupdump.net/download.php?' + (New-QueryString @{ id = $id; pack = $lang; edition = $target.edition })
      downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{ id = $id; pack = $lang; edition = $target.edition })
    }
  }

  Write-CleanLine "No UUP candidates matched filters for $name."
  return $null
}

# ------------------------------
# Patch uup_download_windows.cmd with sed - quiet aria2 flags
# ------------------------------
function Patch-Aria2-Flags {
  param([string]$CmdPath)
  if (-not (Test-Path $CmdPath)) { return }

  $sed = Get-Command sed -ErrorAction SilentlyContinue
  if ($sed) {
    Write-CleanLine "Patching aria2 flags in $CmdPath using sed."
    # Remove conflicting flags first
    & $sed.Path -ri 's/\s--console-log-level=\w+\b//g; s/\s--summary-interval=\d+\b//g; s/\s--download-result=\w+\b//g; s/\s--enable-color=\w+\b//g; s/\s-(q|quiet(=\w+)?)\b//g' $CmdPath
    # Inject quiet set right after "%aria2%"
    & $sed.Path -ri 's@("%aria2%"\s+)@\1--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false @g' $CmdPath
    return
  }

  # Fallback: PowerShell regex (preserves UTF-16LE)
  Write-CleanLine "sed not found. Patching aria2 flags in $CmdPath using PowerShell fallback."
  $bytes   = [System.IO.File]::ReadAllBytes($CmdPath)
  $content = [System.Text.Encoding]::Unicode.GetString($bytes)

  $patternsToRemove = @(
    '\s--console-log-level=\w+\b',
    '\s--summary-interval=\d+\b',
    '\s--download-result=\w+\b',
    '\s--enable-color=\w+\b',
    '\s-(?:q|quiet(?:=\w+)?)\b'
  )
  foreach ($re in $patternsToRemove) {
    $content = [regex]::Replace($content, $re, '', 'IgnoreCase, CultureInvariant')
  }
  $inject = '--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false '
  $content = [regex]::Replace($content, '("%aria2%"\s+)', ('$1' + $inject), 'IgnoreCase, CultureInvariant')

  $newBytes = [System.Text.Encoding]::Unicode.GetBytes($content)
  [System.IO.File]::WriteAllBytes($CmdPath, $newBytes)
}

function Get-WindowsIso($name, $destinationDirectory) {
  $target = $TARGETS[$name]
  $iso = Get-UupDumpIso $name $target
  if (-not $iso) { throw "Can't find UUP for $name ($($target.search)), lang=$lang." }

  $selectedRing = if ($iso.PSObject.Properties.Name -contains 'ring' -and $iso.ring) { "$($iso.ring)".ToUpper() } else { 'UNKNOWN' }
  $selectedInfo = "id=$($iso.id); build=$($iso.build); ring=$selectedRing; title=$($iso.title)"
  Write-CleanLine "Selected UUP candidate: $selectedInfo"

  $isoHasEdition    = $iso.PSObject.Properties.Name -contains 'edition' -and $iso.edition
  $hasVirtualMember = $iso.PSObject.Properties.Name -contains 'virtualEdition' -and $iso.virtualEdition
  $effectiveEdition = if ($isoHasEdition) { $iso.edition } else { $target.edition }

  if (!$preview) {
    if ($iso.title -match '(?i)version\s*([0-9A-Za-z\.\-]+)') {
      $verbuild = $matches[1]
    } else {
      $verbuild = "$($iso.build)"
      Write-CleanLine "WARN: Could not parse version from title. Falling back to build: $verbuild"
    }
  } else {
    $verbuild = if ($target.ContainsKey('displayVersion')) {
      "$($target.displayVersion)"
    } elseif ($target.ContainsKey('ring')) {
      "$($target.ring)".ToUpperInvariant()
    } else {
      $ringLower.ToUpperInvariant()
    }
  }

  $buildDirectory               = "$destinationDirectory/$name"
  $destinationIsoPath           = "$buildDirectory.iso"
  $destinationIsoMetadataPath   = "$destinationIsoPath.json"

  if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory | Out-Null }
  New-Item -ItemType Directory -Force $buildDirectory | Out-Null

  $edn = if ($hasVirtualMember) { $iso.virtualEdition } else { $effectiveEdition }
  Write-CleanLine $edn
  $title = "$name $edn $($iso.build)"

  Write-CleanLine "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
  $downloadPackageBody = if ($hasVirtualMember) { @{ autodl=3; updates=1; cleanup=1; 'virtualEditions[]'=$iso.virtualEdition } } else { @{ autodl=2; updates=1; cleanup=1 } }
  Invoke-WebRequest -Method Post -Uri $iso.downloadPackageUrl -Body $downloadPackageBody -OutFile "$buildDirectory.zip" | Out-Null
  Expand-Archive "$buildDirectory.zip" $buildDirectory

  $customAppsSource = ".\CustomAppsList.txt"
  $customAppsDest   = "$buildDirectory\CustomAppsList.txt"

  if (Test-Path $customAppsSource) { Write-CleanLine "Copying CustomAppsList.txt to build directory..."; Copy-Item -Path $customAppsSource -Destination $customAppsDest -Force } else { Write-CleanLine "WARNING: CustomAppsList.txt not found, skipping." }

  $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
    -replace '^(AutoExit\s*)=.*','$1=1' `
    -replace '^(ResetBase\s*)=.*','$1=1' `
    -replace '^(Cleanup\s*)=.*','$1=1' `
    -replace '^(CustomList\s*)=.*','$1=1' `
    -replace '^(SkipEdge\s*)=.*','$1=1'

  $tag = ""
  if ($esd) { $convertConfig = $convertConfig -replace '^(wim2esd\s*)=.*', '$1=1'; $tag += ".E" }
  if ($netfx3) { $convertConfig = $convertConfig -replace '^(NetFx3\s*)=.*', '$1=1'; $tag += ".N" }
  if ($hasVirtualMember) {
    $convertConfig = $convertConfig `
      -replace '^(StartVirtual\s*)=.*','$1=1' `
      -replace '^(vDeleteSource\s*)=.*','$1=1' `
      -replace '^(vAutoEditions\s*)=.*',"`$1=$($iso.virtualEdition)"
  }
  Set-Content -Encoding ascii -Path $buildDirectory/ConvertConfig.ini -Value $convertConfig

  Write-CleanLine "Creating the $title iso file inside the $buildDirectory directory"
  Push-Location $buildDirectory

  # Patch aria2 flags in the batch before running it
  Patch-Aria2-Flags -CmdPath (Join-Path $buildDirectory 'uup_download_windows.cmd')

  # Raw log path
  $rawLogDir = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
  $rawLog = Join-Path $rawLogDir "uup_dism_aria2_raw.log"

  & {
    powershell cmd /c uup_download_windows.cmd 2>&1 |
      Tee-Object -FilePath $rawLog |
      ForEach-Object {
        $raw = [string]$_
        if ([string]::IsNullOrEmpty($raw)) { return }
        foreach ($crChunk in ($raw -split "`r")) {
          foreach ($line in ($crChunk -split "`n")) {
            if ($line -eq $null) { continue }
            # DISM progress buckets; aria2 is not parsed here
            if (-not (Process-ProgressLine $line)) {
              if ($line -match '^\s*(Mounting image|Saving image|Applying image|Exporting image|Unmounting image|Deployment Image Servicing and Management tool|=== )') {
                Reset-ProgressSession
              }
              Write-CleanLine $line
            }
          }
        }
      }
  }

  if ($LASTEXITCODE) {
    Write-Host "::warning title=Build failed::Dumping last 1500 raw log lines"
    Get-Content $rawLog -Tail 1500 | Write-Host
    throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
  }

  Pop-Location

  $isoFiles = @(Resolve-Path "$buildDirectory/*.iso" -ErrorAction SilentlyContinue)
  if ($isoFiles.Count -eq 0) { throw "No ISO file found in $buildDirectory after build" }
  if ($isoFiles.Count -gt 1) { Write-CleanLine "WARN: Multiple ISO files found in ${buildDirectory}: $($isoFiles -join ', '). Using the first one." }
  $sourceIsoPath = $isoFiles[0]
  $IsoName = Split-Path $sourceIsoPath -leaf

  $isoChecksum = $null
  if ($SkipChecksum) {
    Write-CleanLine "Skipping checksum for intermediate ISO; the final ISO checksum will be calculated later."
  } else {
    Write-CleanLine "Getting the $sourceIsoPath checksum"
    $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
  }

  Set-Content -Path $destinationIsoMetadataPath -Value (
    ([PSCustomObject]@{
      name    = $name
      title   = $iso.title
      build   = $iso.build
      version = $verbuild
      tags    = $tag
      checksum = $isoChecksum
      uupDump = @{
        id                 = $iso.id
        apiUrl             = $iso.apiUrl
        downloadUrl        = $iso.downloadUrl
        downloadPackageUrl = $iso.downloadPackageUrl
      }
    } | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
  )

  Write-CleanLine "Moving the created $sourceIsoPath to $destinationDirectory/$IsoName"
  Move-Item -Force $sourceIsoPath "$destinationDirectory/$IsoName"

  $fullIsoPath = (Resolve-Path "$destinationDirectory/$IsoName").Path
  if ($SkipChecksum) {
    Remove-Item -LiteralPath "$fullIsoPath.sha256.txt" -Force -ErrorAction SilentlyContinue
  } else {
    Set-Content -Encoding ascii -NoNewline -LiteralPath "$fullIsoPath.sha256.txt" -Value $isoChecksum
  }

  Write-CleanLine "Cleaning up build directory to save space..."
  Remove-Item -Force -Recurse $buildDirectory -ErrorAction SilentlyContinue

  if ($env:GITHUB_ENV) {
    Write-Output "ISO_NAME=$IsoName" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    Write-Output "ISO_PATH=$fullIsoPath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
  }
  Write-CleanLine 'All Done.'
}

Get-WindowsIso $windowsTargetName $destinationDirectory
