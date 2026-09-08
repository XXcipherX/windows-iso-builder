<#
.SYNOPSIS
Imports a raw GitHub Actions ISO artifact into private Yandex Disk app storage.

.DESCRIPTION
Yandex Disk downloads the ISO from a short-lived GitHub artifact URL, so the
runner never downloads or re-uploads the large file. After the asynchronous
import, the script verifies the remote size and SHA256 and uploads the small
sha256sum sidecar directly.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [long] $ArtifactId,

    [Parameter(Mandatory)]
    [ValidateScript({ $_ -notmatch '[\\/\r\n]' -and $_ -match '(?i)\.iso$' })]
    [string] $ISOName,

    [Parameter(Mandatory)]
    [long] $ExpectedSize,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedSHA256,

    [ValidateRange(1, 180)]
    [int] $OperationTimeoutMinutes = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($ArtifactId -le 0 -or $ExpectedSize -le 0) {
    throw 'ArtifactId and ExpectedSize must be positive integers.'
}

$yandexToken = $env:YANDEX_DISK_TOKEN
$githubToken = $env:GITHUB_TOKEN
$repository = $env:GITHUB_REPOSITORY
if ([string]::IsNullOrWhiteSpace($yandexToken)) {
    throw 'YANDEX_DISK_TOKEN is empty. Add the repository secret before enabling Yandex Disk upload.'
}
if ([string]::IsNullOrWhiteSpace($githubToken)) {
    throw 'GITHUB_TOKEN is empty. The import job requires Actions artifact read access.'
}
if ([string]::IsNullOrWhiteSpace($repository) -or $repository -notmatch '^[^/]+/[^/]+$') {
    throw 'GITHUB_REPOSITORY must have the owner/repository form.'
}

$githubApiUrl = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL.TrimEnd('/') } else { 'https://api.github.com' }
$yandexApiUrl = 'https://cloud-api.yandex.net/v1/disk'
$expectedHash = $ExpectedSHA256.ToLowerInvariant()
$remoteISOPath = "app:/$ISOName"
$remoteChecksumPath = "app:/$ISOName.sha256"
$yandexHeaders = @{ Authorization = "OAuth $yandexToken"; Accept = 'application/json' }

function Protect-LogValue {
    param([Parameter(Mandatory)][string] $Value)

    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::add-mask::$Value"
    }
}

function Get-YandexMetadata {
    param([Parameter(Mandatory)][string] $RemotePath)

    $path = [Uri]::EscapeDataString($RemotePath)
    $fields = [Uri]::EscapeDataString('name,path,size,sha256,modified')
    Invoke-RestMethod `
        -Method Get `
        -Uri "$yandexApiUrl/resources?path=$path&fields=$fields" `
        -Headers $yandexHeaders `
        -MaximumRetryCount 3 `
        -RetryIntervalSec 5
}

function Confirm-YandexFile {
    param(
        [Parameter(Mandatory)][string] $RemotePath,
        [Parameter(Mandatory)][long] $Size,
        [string] $SHA256
    )

    $metadata = $null
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            $candidate = Get-YandexMetadata -RemotePath $RemotePath
            if ($null -ne $candidate.size -and ([string]::IsNullOrWhiteSpace($SHA256) -or $candidate.sha256)) {
                $metadata = $candidate
                break
            }
        } catch {
            if ($attempt -eq 12) { throw }
        }

        Start-Sleep -Seconds 5
    }

    if ($null -eq $metadata) {
        throw "Yandex Disk did not expose complete metadata for $RemotePath."
    }
    if ([long] $metadata.size -ne $Size) {
        throw "Yandex Disk size verification failed for ${RemotePath}: expected=$Size, remote=$($metadata.size)."
    }
    if ($SHA256 -and ([string] $metadata.sha256).ToLowerInvariant() -ne $SHA256.ToLowerInvariant()) {
        throw "Yandex Disk SHA256 verification failed for ${RemotePath}: expected=$SHA256, remote=$($metadata.sha256)."
    }

    Write-Host "Verified $RemotePath ($Size bytes)."
}

$sizeGiB = $ExpectedSize / 1GB
Write-Host 'Import source:'
Write-Host "  Artifact ID: $ArtifactId"
Write-Host "  ISO: $ISOName"
Write-Host ('  Size: {0:N2} GiB ({1} bytes)' -f $sizeGiB, $ExpectedSize)
Write-Host "  SHA256: $expectedHash"
Write-Host "Requesting a temporary URL for raw GitHub artifact $ArtifactId..."
$artifactApiUri = "$githubApiUrl/repos/$repository/actions/artifacts/$ArtifactId/zip"
$redirectHandler = [Net.Http.HttpClientHandler]::new()
$redirectHandler.AllowAutoRedirect = $false
$redirectClient = [Net.Http.HttpClient]::new($redirectHandler)
$artifactResponse = $null
try {
    $redirectClient.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $githubToken)
    $redirectClient.DefaultRequestHeaders.Accept.Add([Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/vnd.github+json'))
    $redirectClient.DefaultRequestHeaders.UserAgent.ParseAdd('windows-iso-builder/1.0')
    $redirectClient.DefaultRequestHeaders.TryAddWithoutValidation('X-GitHub-Api-Version', '2026-03-10') | Out-Null
    $artifactResponse = $redirectClient.GetAsync(
        $artifactApiUri,
        [Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).GetAwaiter().GetResult()

    if ([int] $artifactResponse.StatusCode -ne 302 -or -not $artifactResponse.Headers.Location) {
        throw "GitHub artifact API did not return a download redirect (HTTP $([int] $artifactResponse.StatusCode) $($artifactResponse.ReasonPhrase))."
    }

    $sourceUri = $artifactResponse.Headers.Location
    if (-not $sourceUri.IsAbsoluteUri) {
        $sourceUri = [Uri]::new([Uri] $artifactApiUri, $sourceUri)
    }
    $sourceUrl = $sourceUri.AbsoluteUri
} finally {
    if ($null -ne $artifactResponse) { $artifactResponse.Dispose() }
    $redirectClient.Dispose()
}

$encodedSourceUrl = [Uri]::EscapeDataString($sourceUrl)
Protect-LogValue -Value $sourceUrl
Protect-LogValue -Value $encodedSourceUrl
Write-Host "GitHub returned a signed URL on host $($sourceUri.Host)."
$expiryMatch = [regex]::Match($sourceUri.Query, '(?:^\?|&)se=([^&]+)')
if ($expiryMatch.Success) {
    $signedExpiry = [Uri]::UnescapeDataString($expiryMatch.Groups[1].Value)
    Write-Host "Signed URL expiry reported by storage: $signedExpiry"
}

Write-Host "Starting server-side import of $ISOName to $remoteISOPath..."
$importStartedAt = [DateTimeOffset]::UtcNow
$encodedRemoteISOPath = [Uri]::EscapeDataString($remoteISOPath)
$importUri = "$yandexApiUrl/resources/upload?path=$encodedRemoteISOPath&url=$encodedSourceUrl&overwrite=true"
Protect-LogValue -Value $importUri
$import = Invoke-RestMethod `
    -Method Post `
    -Uri $importUri `
    -Headers $yandexHeaders `
    -MaximumRetryCount 3 `
    -RetryIntervalSec 5

if (-not $import.href) {
    throw 'Yandex Disk did not return an operation URL for the remote import.'
}

$operationUri = [string] $import.href
Protect-LogValue -Value $operationUri
Write-Host "Yandex Disk accepted the operation at $($importStartedAt.ToString('u'))."
Write-Host "Polling every 10 seconds; detailed heartbeat every 30 seconds; timeout is $OperationTimeoutMinutes minutes."
$deadline = [DateTimeOffset]::UtcNow.AddMinutes($OperationTimeoutMinutes)
$pollCount = 0
$nextDiagnosticAt = [DateTimeOffset]::MinValue
$completionEvidence = 'operation status'
while ($true) {
    $operation = Invoke-RestMethod `
        -Method Get `
        -Uri $operationUri `
        -Headers $yandexHeaders `
        -MaximumRetryCount 3 `
        -RetryIntervalSec 5

    $pollCount++
    $now = [DateTimeOffset]::UtcNow
    $status = ([string] $operation.status).ToLowerInvariant()
    if ($status -eq 'success') { break }
    if ($status -in @('failed', 'failure')) {
        $errorProperty = $operation.PSObject.Properties['error']
        $details = if ($errorProperty -and $errorProperty.Value) {
            $errorProperty.Value | ConvertTo-Json -Compress -Depth 5
        } else {
            'No details returned'
        }
        throw "Yandex Disk server-side import failed: $details"
    }
    if ($status -ne 'in-progress') {
        throw "Yandex Disk returned an unexpected operation status: '$status'."
    }
    if ($now -ge $deadline) {
        throw "Yandex Disk import did not finish within $OperationTimeoutMinutes minutes."
    }

    if ($now -ge $nextDiagnosticAt) {
        $elapsed = $now - $importStartedAt
        $operationJson = $operation | ConvertTo-Json -Compress -Depth 5
        Write-Host ('[{0}] Poll #{1}: status={2}, elapsed={3:N1} min, response={4}' -f $now.ToString('u'), $pollCount, $status, $elapsed.TotalMinutes, $operationJson)

        try {
            $visibleFile = Get-YandexMetadata -RemotePath $remoteISOPath
            $visibleSize = [long] $visibleFile.size
            $visibleHash = if ($visibleFile.PSObject.Properties['sha256']) {
                ([string] $visibleFile.sha256).ToLowerInvariant()
            } else {
                ''
            }
            $visibleHashMatches = $visibleHash -eq $expectedHash
            $visiblePercent = [math]::Min(100, ($visibleSize / $ExpectedSize) * 100)
            $visibleRate = if ($elapsed.TotalSeconds -gt 0) { $visibleSize / 1MB / $elapsed.TotalSeconds } else { 0 }
            $modified = if ($visibleFile.PSObject.Properties['modified']) { $visibleFile.modified } else { 'unknown' }
            Write-Host ('Destination resource is visible: {0} bytes ({1:N2}% of expected), apparent average {2:N2} MiB/s, modified={3}.' -f $visibleSize, $visiblePercent, $visibleRate, $modified)
            Write-Host "Destination SHA256 matches expected: $visibleHashMatches."
            Write-Host 'The destination metadata may describe a previously completed file; it is not a guaranteed live byte counter.'

            if ($visibleSize -eq $ExpectedSize -and $visibleHashMatches) {
                $completionEvidence = 'matching destination size and SHA256'
                Write-Host 'Destination size and SHA256 match the expected ISO; the import is complete even though the operation status has not changed yet.'
                break
            }
        } catch {
            $statusCode = $null
            $responseProperty = $_.Exception.PSObject.Properties['Response']
            if ($responseProperty -and $responseProperty.Value) {
                $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
                if ($statusProperty) { $statusCode = [int] $statusProperty.Value }
            }
            if ($statusCode -eq 404) {
                Write-Host 'Destination resource is not published yet (HTTP 404).'
            } else {
                Write-Warning "Destination metadata probe failed: $($_.Exception.Message)"
            }
        }

        $nextDiagnosticAt = $now.AddSeconds(30)
    }
    Start-Sleep -Seconds 10
}

$completedAt = [DateTimeOffset]::UtcNow
$totalElapsed = $completedAt - $importStartedAt
$effectiveRate = $ExpectedSize / 1MB / $totalElapsed.TotalSeconds
Write-Host ('Yandex Disk completion confirmed by {0} after {1:N1} minutes; effective end-to-end average: {2:N2} MiB/s.' -f $completionEvidence, $totalElapsed.TotalMinutes, $effectiveRate)
Confirm-YandexFile -RemotePath $remoteISOPath -Size $ExpectedSize -SHA256 $expectedHash

$checksumText = "$expectedHash *$ISOName`n"
$checksumBytes = [Text.Encoding]::ASCII.GetBytes($checksumText)
$encodedChecksumPath = [Uri]::EscapeDataString($remoteChecksumPath)
$checksumUpload = Invoke-RestMethod `
    -Method Get `
    -Uri "$yandexApiUrl/resources/upload?path=$encodedChecksumPath&overwrite=true" `
    -Headers $yandexHeaders `
    -MaximumRetryCount 3 `
    -RetryIntervalSec 5

if (-not $checksumUpload.href) {
    throw 'Yandex Disk did not return an upload URL for the checksum sidecar.'
}

$checksumUploadUrl = [string] $checksumUpload.href
Protect-LogValue -Value $checksumUploadUrl
Invoke-WebRequest `
    -Method Put `
    -Uri $checksumUploadUrl `
    -ContentType 'text/plain' `
    -Body $checksumBytes | Out-Null
Confirm-YandexFile -RemotePath $remoteChecksumPath -Size $checksumBytes.LongLength

if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8 -Value "remote_path=$remoteISOPath"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8 -Value "checksum_path=$remoteChecksumPath"
}
