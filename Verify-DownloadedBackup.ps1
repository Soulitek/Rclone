<#
.SYNOPSIS
    Verifies the integrity of downloaded backup files using SHA256 checksums.

.DESCRIPTION
    This script verifies that downloaded backup files match their expected checksums
    from the manifest file. It helps detect corruption during download or storage.

.PARAMETER BackupFolder
    Path to the folder containing the downloaded backup files.

.PARAMETER ManifestFile
    Path to the checksum manifest file (.checksums.txt).

.EXAMPLE
    .\Verify-DownloadedBackup.ps1 -BackupFolder "C:\Downloads\website-20251130-161326" -ManifestFile "C:\Downloads\website-20251130-161326.checksums.txt"

.EXAMPLE
    .\Verify-DownloadedBackup.ps1 -BackupFolder "C:\Downloads\website-20251130-161326"
    # Will automatically look for .checksums.txt file in the same folder

.NOTES
    Requires PowerShell 5.1 or later.
    The manifest file format is: SHA256_HASH  filename.tar.gz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$BackupFolder,
    
    [Parameter(Mandatory=$false)]
    [string]$ManifestFile
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Function to calculate file checksum
function Get-FileChecksum {
    param([string]$FilePath)
    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
        return $hash.Hash
    }
    catch {
        Write-Error "Failed to calculate checksum for $FilePath : $_"
        return $null
    }
}

# Auto-detect manifest file if not provided
if (-not $ManifestFile) {
    $ManifestFile = Join-Path $BackupFolder "*.checksums.txt"
    $manifestFiles = Get-ChildItem -Path $ManifestFile -ErrorAction SilentlyContinue
    if ($manifestFiles.Count -eq 0) {
        Write-Error "No checksum manifest file found. Please specify -ManifestFile parameter."
        exit 1
    }
    if ($manifestFiles.Count -gt 1) {
        Write-Warning "Multiple manifest files found. Using: $($manifestFiles[0].FullName)"
        $ManifestFile = $manifestFiles[0].FullName
    } else {
        $ManifestFile = $manifestFiles[0].FullName
    }
}

# Verify manifest file exists
if (-not (Test-Path $ManifestFile)) {
    Write-Error "Manifest file not found: $ManifestFile"
    exit 1
}

# Verify backup folder exists
if (-not (Test-Path $BackupFolder)) {
    Write-Error "Backup folder not found: $BackupFolder"
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Backup Integrity Verification" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Backup Folder: $BackupFolder" -ForegroundColor Gray
Write-Host "Manifest File: $ManifestFile" -ForegroundColor Gray
Write-Host ""

# Read manifest file
$manifestLines = Get-Content $ManifestFile
$checksumMap = @{}
$totalFiles = 0
$verifiedFiles = 0
$corruptedFiles = 0
$missingFiles = 0

# Parse manifest file
foreach ($line in $manifestLines) {
    # Skip comments and empty lines
    if ($line -match '^\s*#' -or $line -match '^\s*$') {
        continue
    }
    
    # Parse checksum and filename: SHA256_HASH  filename.tar.gz
    if ($line -match '^([a-f0-9]{64})\s+(.+)$') {
        $expectedHash = $Matches[1].ToLower()
        $fileName = $Matches[2].Trim()
        $checksumMap[$fileName] = $expectedHash
        $totalFiles++
    }
}

if ($totalFiles -eq 0) {
    Write-Error "No valid checksum entries found in manifest file."
    exit 1
}

Write-Host "Found $totalFiles file(s) in manifest" -ForegroundColor Green
Write-Host ""

# Verify each file
foreach ($fileName in ($checksumMap.Keys | Sort-Object)) {
    $expectedHash = $checksumMap[$fileName]
    $filePath = Join-Path $BackupFolder $fileName
    
    Write-Host -NoNewline "Verifying: $fileName ... " -ForegroundColor Yellow
    
    if (-not (Test-Path $filePath)) {
        Write-Host "NOT FOUND" -ForegroundColor Red
        $missingFiles++
        continue
    }
    
    # Calculate actual checksum
    $actualHash = Get-FileChecksum -FilePath $filePath
    
    if (-not $actualHash) {
        Write-Host "ERROR (checksum calculation failed)" -ForegroundColor Red
        $corruptedFiles++
        continue
    }
    
    $actualHash = $actualHash.ToLower()
    
    # Compare checksums
    if ($actualHash -eq $expectedHash) {
        Write-Host "OK" -ForegroundColor Green
        $verifiedFiles++
    } else {
        Write-Host "CORRUPTED!" -ForegroundColor Red
        Write-Host "  Expected: $expectedHash" -ForegroundColor Gray
        Write-Host "  Actual:   $actualHash" -ForegroundColor Gray
        $corruptedFiles++
    }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Verification Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total files:     $totalFiles" -ForegroundColor White
Write-Host "Verified:        " -NoNewline -ForegroundColor White
Write-Host "$verifiedFiles" -ForegroundColor Green
Write-Host "Corrupted:       " -NoNewline -ForegroundColor White
if ($corruptedFiles -gt 0) {
    Write-Host "$corruptedFiles" -ForegroundColor Red
} else {
    Write-Host "$corruptedFiles" -ForegroundColor Green
}
Write-Host "Missing:         " -NoNewline -ForegroundColor White
if ($missingFiles -gt 0) {
    Write-Host "$missingFiles" -ForegroundColor Red
} else {
    Write-Host "$missingFiles" -ForegroundColor Green
}
Write-Host ""

# Exit with appropriate code
if ($corruptedFiles -gt 0 -or $missingFiles -gt 0) {
    Write-Host "VERIFICATION FAILED!" -ForegroundColor Red
    Write-Host "Some files are corrupted or missing. Please re-download the affected files." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "VERIFICATION SUCCESSFUL!" -ForegroundColor Green
    Write-Host "All files are intact and match their checksums." -ForegroundColor Green
    exit 0
}








