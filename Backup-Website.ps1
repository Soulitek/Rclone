<#
.SYNOPSIS
    Automated website backup script with SSH, rclone, and Google Drive integration.

.DESCRIPTION
    This script performs automated backups of a remote website by:
    1. Connecting to remote server via SSH (key authentication)
    2. Creating compressed tar.gz archive on remote server
    3. Downloading archive to local machine
    4. Uploading to Google Drive via rclone
    5. Rotating backups (keeping last 7)
    6. Cleaning up temporary files

.PARAMETER SSHUser
    Remote server username. If not provided, retrieves from Windows Credential Manager.

.PARAMETER SSHHost
    Remote server hostname or IP address. If not provided, retrieves from Windows Credential Manager.

.PARAMETER SSHPort
    SSH port number. Default is 22.

.PARAMETER RemotePath
    Path to website files on remote server (e.g., /var/www/html).

.PARAMETER GDriveRemote
    Google Drive destination path (e.g., gdrive:backups/website).

.PARAMETER DryRun
    If specified, simulates the backup process without making actual changes.

.PARAMETER SkipRotation
    If specified, skips the backup rotation (keeps all backups).

.EXAMPLE
    .\Backup-Website.ps1
    Runs backup with configuration from Windows Credential Manager.

.EXAMPLE
    .\Backup-Website.ps1 -DryRun
    Simulates the backup process without making changes.

.EXAMPLE
    .\Backup-Website.ps1 -SSHUser admin -SSHHost example.com -RemotePath /var/www/html -GDriveRemote "gdrive:backups/website"
    Runs backup with specified parameters.

.NOTES
    Requirements:
    - OpenSSH client installed and in PATH
    - SSH key configured for passwordless authentication
    - Rclone installed and configured with Google Drive remote
    - Run Setup-BackupCredentials.ps1 first for initial setup

    Script built with love by Soulitek
    Professional IT Business Solutions
    
    Contact: letstalk@soulitek.co.il
    Website: www.soulitek.co.il
    
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SSHUser,
    
    [Parameter(Mandatory=$false)]
    [string]$SSHHost,
    
    [Parameter(Mandatory=$false)]
    [int]$SSHPort = 22,
    
    [Parameter(Mandatory=$false)]
    [string]$RemotePath,
    
    [Parameter(Mandatory=$false)]
    [string]$GDriveRemote,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipRotation,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipConfirmation,
    
    [Parameter(Mandatory=$false)]
    [switch]$ForceSetup,
    
    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive
)

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

# Strict mode for better error detection
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Local backup directory (uses Windows temp folder)
$LOCAL_BACKUP_DIR = Join-Path $env:TEMP "website-backups"

# Log directory
$LOG_DIR = "C:\Logs\website-backup"

# Backup retention policy
$BACKUP_RETENTION_COUNT = 7

# Credential Manager target name
$CREDENTIAL_TARGET = "WebsiteBackup_SSH"

# Script start time
$SCRIPT_START_TIME = Get-Date

# Backup name with timestamp
$BACKUP_TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$BACKUP_NAME = "website-$BACKUP_TIMESTAMP.tar.gz"

# Log file path
$LOG_FILE = Join-Path $LOG_DIR "backup-$(Get-Date -Format 'yyyyMMdd').log"

# Note: Backup is streamed directly from remote server to local machine via SSH
# No archive is created on the remote server to save disk space

# =============================================================================
# INTERACTIVE SETUP HELPER FUNCTIONS
# =============================================================================

function Test-IsFirstRun {
    <#
    .SYNOPSIS
        Checks if this is the first run (no configuration exists).
    #>
    [CmdletBinding()]
    param()
    
    if (-not (Test-Path "HKCU:\Software\WebsiteBackup")) {
        return $true
    }
    
    $config = Get-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -ErrorAction SilentlyContinue
    if (-not $config -or -not $config.SSHUser -or -not $config.SSHHost -or -not $config.RemotePath -or -not $config.GDriveRemote) {
        return $true
    }
    
    return $false
}

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Checks if the current PowerShell session is running with administrator privileges.
    #>
    [CmdletBinding()]
    param()
    
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-ColorMessage {
    <#
    .SYNOPSIS
        Writes a colored message to the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Question', 'Header')]
        [string]$Type = 'Info'
    )
    
    $color = switch ($Type) {
        'Success'  { 'Green' }
        'Warning'  { 'Yellow' }
        'Error'    { 'Red' }
        'Question' { 'Cyan' }
        'Header'   { 'Cyan' }
        'Info'     { 'White' }
    }
    
    Write-Host $Message -ForegroundColor $color
}

function Show-ProgressStep {
    <#
    .SYNOPSIS
        Displays a progress step header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [int]$Step,
        
        [Parameter(Mandatory=$true)]
        [int]$TotalSteps,
        
        [Parameter(Mandatory=$true)]
        [string]$Description
    )
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "  STEP ${Step} of ${TotalSteps}: $Description" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""
}

function Read-UserChoice {
    <#
    .SYNOPSIS
        Prompts user for a choice with validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prompt,
        
        [Parameter(Mandatory=$false)]
        [string[]]$ValidChoices = @('Y', 'N'),
        
        [Parameter(Mandatory=$false)]
        [string]$DefaultChoice = ''
    )
    
    $promptText = $Prompt
    if ($DefaultChoice) {
        $promptText += " [$DefaultChoice]"
    }
    $promptText += ": "
    
    do {
        Write-Host $promptText -NoNewline -ForegroundColor Cyan
        $response = Read-Host
        
        if ([string]::IsNullOrEmpty($response) -and $DefaultChoice) {
            $response = $DefaultChoice
        }
        
        $response = $response.ToUpper()
        
        if ($ValidChoices -contains $response) {
            return $response
        }
        
        Write-ColorMessage "Invalid choice. Please enter one of: $($ValidChoices -join ', ')" -Type Warning
    } while ($true)
}

function Read-UserInput {
    <#
    .SYNOPSIS
        Prompts user for input with optional default value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prompt,
        
        [Parameter(Mandatory=$false)]
        [string]$DefaultValue = '',
        
        [Parameter(Mandatory=$false)]
        [switch]$Required
    )
    
    do {
        $promptText = $Prompt
        if ($DefaultValue) {
            $promptText += " [$DefaultValue]"
        }
        $promptText += ": "
        
        Write-Host $promptText -NoNewline -ForegroundColor Cyan
        $response = Read-Host
        
        if ([string]::IsNullOrEmpty($response) -and $DefaultValue) {
            return $DefaultValue
        }
        
        if (-not [string]::IsNullOrEmpty($response)) {
            return $response
        }
        
        if (-not $Required) {
            return ""
        }
        
        Write-ColorMessage "This field is required. Please enter a value." -Type Warning
    } while ($true)
}

function Show-WelcomeScreen {
    <#
    .SYNOPSIS
        Displays the welcome screen for first-time users.
    #>
    [CmdletBinding()]
    param()
    
    Clear-Host
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host "  WEBSITE BACKUP SYSTEM - FIRST TIME SETUP" -ForegroundColor Green
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host ""
    Write-ColorMessage "Welcome! It looks like this is your first time running this backup." -Type Info
    Write-Host ""
    Write-ColorMessage "I'll guide you through a quick setup process that will configure:" -Type Info
    Write-ColorMessage "  [OK] SSH connection to your server" -Type Info
    Write-ColorMessage "  [OK] Website files location" -Type Info
    Write-ColorMessage "  [OK] Google Drive backup storage" -Type Info
    Write-ColorMessage "  [OK] Automated backup schedule (optional)" -Type Info
    Write-Host ""
    Write-ColorMessage "Estimated time: 15-20 minutes" -Type Warning
    Write-Host ""
    Write-ColorMessage "Prerequisites that will be checked:" -Type Info
    Write-ColorMessage "  * OpenSSH Client" -Type Info
    Write-ColorMessage "  * Rclone (for Google Drive)" -Type Info
    Write-ColorMessage "  * SSH key pair" -Type Info
    Write-Host ""
    Write-Host ("-" * 80) -ForegroundColor DarkGray
    Write-Host "  Script built with love by Soulitek" -ForegroundColor DarkGray
    Write-Host "  Professional IT Business Solutions" -ForegroundColor DarkGray
    Write-Host "  Contact: letstalk@soulitek.co.il | www.soulitek.co.il" -ForegroundColor DarkGray
    Write-Host ("-" * 80) -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Configuration {
    <#
    .SYNOPSIS
        Displays the current configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config
    )
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "  CURRENT BACKUP CONFIGURATION" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  SSH Server:       " -NoNewline -ForegroundColor Gray
    Write-Host "$($Config.SSHUser)@$($Config.SSHHost):$($Config.SSHPort)" -ForegroundColor Yellow
    Write-Host "  Website Path:     " -NoNewline -ForegroundColor Gray
    Write-Host "$($Config.RemotePath)" -ForegroundColor Yellow
    Write-Host "  Google Drive:     " -NoNewline -ForegroundColor Gray
    Write-Host "$($Config.GDriveRemote)" -ForegroundColor Yellow
    Write-Host "  Backup Retention: " -NoNewline -ForegroundColor Gray
    Write-Host "Keep last $BACKUP_RETENTION_COUNT backups" -ForegroundColor Yellow
    if ($Config.ScheduleFrequency -and $Config.ScheduleTime) {
        Write-Host "  Schedule:         " -NoNewline -ForegroundColor Gray
        Write-Host "$($Config.ScheduleFrequency) at $($Config.ScheduleTime)" -ForegroundColor Yellow
    } else {
        Write-Host "  Schedule:         " -NoNewline -ForegroundColor Gray
        Write-Host "Not scheduled" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ("-" * 80) -ForegroundColor DarkGray
    Write-Host "  Script built with love by Soulitek - Professional IT Business Solutions" -ForegroundColor DarkGray
    Write-Host "  Contact: letstalk@soulitek.co.il | www.soulitek.co.il" -ForegroundColor DarkGray
    Write-Host ("-" * 80) -ForegroundColor DarkGray
    Write-Host ""
}

function Install-OpenSSHClient {
    <#
    .SYNOPSIS
        Automatically installs OpenSSH Client on Windows.
    #>
    [CmdletBinding()]
    param()
    
    Write-Host ""
    Write-ColorMessage "  Attempting to install OpenSSH Client..." -Type Info
    
    # Check if running as administrator
    if (-not (Test-IsAdministrator)) {
        Write-ColorMessage "  [!] Administrator privileges required to install OpenSSH Client." -Type Warning
        Write-ColorMessage "  Please run PowerShell as Administrator and try again." -Type Warning
        Write-ColorMessage "  Or install manually: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" -Type Info
        return $false
    }
    
    try {
        Write-ColorMessage "  Installing OpenSSH Client via Windows Features..." -Type Info
        
        # Check if already installed (capability might exist but not be detected by Get-Command)
        $capability = Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Client*" }
        
        if ($capability.State -eq "Installed") {
            Write-ColorMessage "  [OK] OpenSSH Client is already installed!" -Type Success
            Write-ColorMessage "  Note: You may need to restart your terminal for it to be detected." -Type Warning
            return $true
        }
        
        # Install OpenSSH Client
        $result = Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0" -ErrorAction Stop
        
        if ($result.RestartNeeded) {
            Write-ColorMessage "  [OK] OpenSSH Client installed! A restart may be required." -Type Success
        } else {
            Write-ColorMessage "  [OK] OpenSSH Client installed successfully!" -Type Success
        }
        
        # Refresh environment PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        
        return $true
    }
    catch {
        Write-ColorMessage "  [X] Failed to install OpenSSH Client: $_" -Type Error
        Write-ColorMessage "  Manual installation: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" -Type Info
        return $false
    }
}

function Install-Rclone {
    <#
    .SYNOPSIS
        Automatically downloads and installs Rclone.
    #>
    [CmdletBinding()]
    param()
    
    Write-Host ""
    Write-ColorMessage "  Attempting to install Rclone..." -Type Info
    
    $rcloneDir = Join-Path $env:LOCALAPPDATA "rclone"
    $rcloneExe = Join-Path $rcloneDir "rclone.exe"
    $downloadUrl = "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
    $tempZip = Join-Path $env:TEMP "rclone-install.zip"
    $tempExtract = Join-Path $env:TEMP "rclone-extract"
    
    try {
        # Create rclone directory
        if (-not (Test-Path $rcloneDir)) {
            New-Item -Path $rcloneDir -ItemType Directory -Force | Out-Null
            Write-ColorMessage "  Created directory: $rcloneDir" -Type Info
        }
        
        # Download rclone
        Write-ColorMessage "  Downloading Rclone from $downloadUrl..." -Type Info
        Write-ColorMessage "  This may take a moment..." -Type Info
        
        # Use TLS 1.2 for secure download
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        # Download with progress
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($downloadUrl, $tempZip)
        
        Write-ColorMessage "  Download complete. Extracting..." -Type Info
        
        # Clean up old extraction folder if exists
        if (Test-Path $tempExtract) {
            Remove-Item -Path $tempExtract -Recurse -Force
        }
        
        # Extract the zip
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
        
        # Find the rclone.exe in the extracted folder
        $extractedExe = Get-ChildItem -Path $tempExtract -Recurse -Filter "rclone.exe" | Select-Object -First 1
        
        if (-not $extractedExe) {
            throw "rclone.exe not found in downloaded archive"
        }
        
        # Copy rclone.exe to install directory
        Copy-Item -Path $extractedExe.FullName -Destination $rcloneExe -Force
        
        Write-ColorMessage "  Rclone installed to: $rcloneDir" -Type Success
        
        # Add to user PATH if not already there
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$rcloneDir*") {
            Write-ColorMessage "  Adding Rclone to user PATH..." -Type Info
            $newPath = "$userPath;$rcloneDir"
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
            
            # Update current session PATH
            $env:Path = "$env:Path;$rcloneDir"
            
            Write-ColorMessage "  [OK] Rclone added to PATH" -Type Success
        }
        
        # Clean up temp files
        Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        
        # Verify installation
        $version = & $rcloneExe version 2>&1 | Select-Object -First 1
        Write-ColorMessage "  [OK] Rclone installed successfully: $version" -Type Success
        
        return $true
    }
    catch {
        Write-ColorMessage "  [X] Failed to install Rclone: $_" -Type Error
        Write-ColorMessage "  Manual installation: Download from https://rclone.org/downloads/" -Type Info
        
        # Clean up on failure
        Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        
        return $false
    }
}

function Test-Prerequisite {
    <#
    .SYNOPSIS
        Checks if a required tool is installed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ToolName,
        
        [Parameter(Mandatory=$true)]
        [string]$Command,
        
        [Parameter(Mandatory=$false)]
        [string]$InstallGuide = ""
    )
    
    Write-Host "  Checking for $ToolName... " -NoNewline
    
    # Use Get-Command which is more reliable than trying to execute the command
    $cmdInfo = Get-Command $Command -ErrorAction SilentlyContinue
    
    if ($cmdInfo) {
        Write-ColorMessage "[OK] Found" -Type Success
        return $true
    }
    else {
        # Also check Windows Capability for OpenSSH
        if ($Command -eq "ssh") {
            $capability = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Client*" -and $_.State -eq "Installed" }
            if ($capability) {
                Write-ColorMessage "[OK] Found (may need terminal restart)" -Type Success
                return $true
            }
        }
        
        # Check common install locations for rclone
        if ($Command -eq "rclone") {
            $rclonePath = Join-Path $env:LOCALAPPDATA "rclone\rclone.exe"
            if (Test-Path $rclonePath) {
                Write-ColorMessage "[OK] Found" -Type Success
                return $true
            }
        }
        
        Write-ColorMessage "[X] Not Found" -Type Error
        
        if ($InstallGuide) {
            Write-Host ""
            Write-ColorMessage "  Installation Guide:" -Type Warning
            Write-Host "  $InstallGuide" -ForegroundColor Yellow
            Write-Host ""
        }
        
        return $false
    }
}

function Test-SSHKeyExists {
    <#
    .SYNOPSIS
        Checks if SSH key pair exists.
    #>
    [CmdletBinding()]
    param()
    
    $privateKeyPath = Join-Path $env:USERPROFILE ".ssh\id_rsa"
    $publicKeyPath = Join-Path $env:USERPROFILE ".ssh\id_rsa.pub"
    
    return (Test-Path $privateKeyPath) -and (Test-Path $publicKeyPath)
}

function New-SSHKeyPair {
    <#
    .SYNOPSIS
        Generates a new SSH key pair.
    #>
    [CmdletBinding()]
    param()
    
    Write-ColorMessage "Generating SSH key pair..." -Type Info
    Write-ColorMessage "Please press Enter when prompted (accept default location and empty passphrase for automation)." -Type Warning
    Write-Host ""
    
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    
    try {
        $process = Start-Process -FilePath "ssh-keygen" `
            -ArgumentList "-t", "rsa", "-b", "4096", "-f", "$sshDir\id_rsa" `
            -Wait -NoNewWindow -PassThru
        
        if ($process.ExitCode -eq 0) {
            Write-ColorMessage "[OK] SSH key pair generated successfully!" -Type Success
            return $true
        }
        else {
            Write-ColorMessage "[X] Failed to generate SSH key pair." -Type Error
            return $false
        }
    }
    catch {
        Write-ColorMessage "[X] Error generating SSH key: $_" -Type Error
        return $false
    }
}

function Get-SSHPublicKey {
    <#
    .SYNOPSIS
        Returns the content of the SSH public key.
    #>
    [CmdletBinding()]
    param()
    
    $publicKeyPath = Join-Path $env:USERPROFILE ".ssh\id_rsa.pub"
    
    if (Test-Path $publicKeyPath) {
        return Get-Content $publicKeyPath -Raw
    }
    
    return $null
}

function Test-SSHConnectionQuiet {
    <#
    .SYNOPSIS
        Tests SSH connection silently (without user prompts).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Hostname,
        
        [Parameter(Mandatory=$true)]
        [int]$Port
    )
    
    try {
        $process = Start-Process -FilePath "ssh" `
            -ArgumentList "-p", "$Port", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "${User}@${Hostname}", "exit" `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput "ssh_test.tmp" -RedirectStandardError "ssh_test_err.tmp"
        
        # Clean up temp files
        if (Test-Path "ssh_test.tmp") { Remove-Item "ssh_test.tmp" -ErrorAction SilentlyContinue }
        if (Test-Path "ssh_test_err.tmp") { Remove-Item "ssh_test_err.tmp" -ErrorAction SilentlyContinue }
        
        return $process.ExitCode -eq 0
    }
    catch {
        return $false
    }
}

function Test-RemotePathExists {
    <#
    .SYNOPSIS
        Tests if a remote path exists and is readable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Hostname,
        
        [Parameter(Mandatory=$true)]
        [int]$Port,
        
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    
    try {
        $command = "test -d '$Path' && test -r '$Path' && echo 'EXISTS'"
        $process = Start-Process -FilePath "ssh" `
            -ArgumentList "-p", "$Port", "${User}@${Hostname}", $command `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput "path_test.tmp" -RedirectStandardError "path_test_err.tmp"
        
        $output = ""
        if (Test-Path "path_test.tmp") {
            $output = (Get-Content "path_test.tmp" -Raw).Trim()
            Remove-Item "path_test.tmp" -ErrorAction SilentlyContinue
        }
        if (Test-Path "path_test_err.tmp") {
            Remove-Item "path_test_err.tmp" -ErrorAction SilentlyContinue
        }
        
        return $output -eq "EXISTS"
    }
    catch {
        return $false
    }
}

function Get-RemoteDirectories {
    <#
    .SYNOPSIS
        Discovers directories on the remote server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Hostname,
        
        [Parameter(Mandatory=$true)]
        [int]$Port,
        
        [Parameter(Mandatory=$true)]
        [string]$BasePath
    )
    
    try {
        # List directories in the base path
        $command = "ls -d $BasePath*/ 2>/dev/null | head -20"
        $process = Start-Process -FilePath "ssh" `
            -ArgumentList "-p", "$Port", "${User}@${Hostname}", $command `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput "dirs.tmp" -RedirectStandardError "dirs_err.tmp"
        
        $directories = @()
        if (Test-Path "dirs.tmp") {
            $output = Get-Content "dirs.tmp"
            if ($output) {
                $directories = $output | Where-Object { $_ -ne "" } | ForEach-Object { $_.TrimEnd('/') }
            }
            Remove-Item "dirs.tmp" -ErrorAction SilentlyContinue
        }
        if (Test-Path "dirs_err.tmp") {
            Remove-Item "dirs_err.tmp" -ErrorAction SilentlyContinue
        }
        
        return $directories
    }
    catch {
        return @()
    }
}

function New-BackupSchedule {
    <#
    .SYNOPSIS
        Creates a Windows Scheduled Task for automated backups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Daily', 'Weekly', 'Monthly', 'Quarterly')]
        [string]$Frequency,
        
        [Parameter(Mandatory=$false)]
        [string]$Time = "02:00"
    )
    
    $taskName = "Website Backup - Automated"
    $scriptPath = $PSCommandPath
    
    # Remove existing task if it exists
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-ColorMessage "  Removing existing scheduled task..." -Type Info
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    
    # Create action
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$scriptPath`" -NonInteractive"
    
    # Parse time
    $timeParts = $Time.Split(':')
    $hour = [int]$timeParts[0]
    $minute = [int]$timeParts[1]
    
    # Create trigger based on frequency
    $trigger = switch ($Frequency) {
        'Daily' {
            New-ScheduledTaskTrigger -Daily -At "$hour`:$minute"
        }
        'Weekly' {
            New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At "$hour`:$minute"
        }
        'Monthly' {
            # Daily trigger, but script will check if it's the 1st day
            New-ScheduledTaskTrigger -Daily -At "$hour`:$minute"
        }
        'Quarterly' {
            # Daily trigger, but script will check for quarterly months
            New-ScheduledTaskTrigger -Daily -At "$hour`:$minute"
        }
    }
    
    # Check if running as administrator
    $isAdmin = Test-IsAdministrator
    
    # Create principal (run as current user)
    # Use highest privileges only if running as administrator
    if ($isAdmin) {
        $principal = New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive `
            -RunLevel Highest
    } else {
        # Without admin rights, we can't use Highest run level
        # Use Limited run level instead (default)
        Write-ColorMessage "  Note: Not running as administrator. Task will be created with limited privileges." -Type Warning
        Write-ColorMessage "  For highest privileges, run PowerShell as Administrator and try again." -Type Info
        $principal = New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive
    }
    
    # Create settings
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
        -MultipleInstances IgnoreNew
    
    # Register the task
    try {
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Automated website backup - Runs $Frequency at $Time" `
            -ErrorAction Stop | Out-Null
        
        Write-ColorMessage "  [OK] Scheduled task created successfully!" -Type Success
        Write-ColorMessage "    Task Name: $taskName" -Type Info
        Write-ColorMessage "    Frequency: $Frequency" -Type Info
        Write-ColorMessage "    Time: $Time" -Type Info
        if (-not $isAdmin) {
            Write-ColorMessage "    Run Level: Limited (run as Administrator for highest privileges)" -Type Warning
        }
        
        # Save schedule to registry
        if (-not (Test-Path "HKCU:\Software\WebsiteBackup")) {
            New-Item -Path "HKCU:\Software\WebsiteBackup" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "ScheduleFrequency" -Value $Frequency
        Set-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "ScheduleTime" -Value $Time
        
        return $true
    }
    catch {
        Write-ColorMessage "  [X] Failed to create scheduled task: $_" -Type Error
        if ($_.Exception.Message -match "Access is denied" -or $_.Exception.Message -match "denied") {
            Write-ColorMessage "  This error usually means you need administrator privileges." -Type Warning
            Write-ColorMessage "  Solution: Right-click PowerShell and select 'Run as Administrator', then try again." -Type Info
        }
        return $false
    }
}

function Remove-BackupSchedule {
    <#
    .SYNOPSIS
        Removes the scheduled backup task.
    #>
    [CmdletBinding()]
    param()
    
    $taskName = "Website Backup - Automated"
    
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        Write-ColorMessage "[OK] Scheduled task removed successfully!" -Type Success
        
        # Remove from registry
        if (Test-Path "HKCU:\Software\WebsiteBackup") {
            Remove-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "ScheduleFrequency" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "ScheduleTime" -ErrorAction SilentlyContinue
        }
        
        return $true
    }
    catch {
        Write-ColorMessage "No scheduled task found to remove." -Type Warning
        return $false
    }
}

function Clear-BackupConfiguration {
    <#
    .SYNOPSIS
        Completely removes all backup configuration and starts fresh.
    #>
    [CmdletBinding()]
    param()
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Red
    Write-Host "  WARNING: DELETE ALL CONFIGURATION" -ForegroundColor Red
    Write-Host ("=" * 80) -ForegroundColor Red
    Write-Host ""
    Write-ColorMessage "This will permanently delete:" -Type Warning
    Write-Host "  * All backup configuration (SSH, paths, Google Drive settings)" -ForegroundColor Yellow
    Write-Host "  * Scheduled backup tasks" -ForegroundColor Yellow
    Write-Host "  * All stored credentials and settings" -ForegroundColor Yellow
    Write-Host ""
    Write-ColorMessage "This action CANNOT be undone!" -Type Error
    Write-Host ""
    Write-ColorMessage "After deletion, you'll need to run the setup wizard again." -Type Info
    Write-Host ""
    
    $confirm1 = Read-UserChoice -Prompt "Are you SURE you want to delete all configuration?" -ValidChoices @('Y', 'N') -DefaultChoice 'N'
    
    if ($confirm1 -ne 'Y') {
        Write-ColorMessage "Configuration deletion cancelled." -Type Info
        return $false
    }
    
    Write-Host ""
    Write-ColorMessage "Please type 'DELETE' to confirm:" -Type Warning
    $confirm2 = Read-Host
    
    if ($confirm2 -ne 'DELETE') {
        Write-ColorMessage "Confirmation text did not match. Deletion cancelled." -Type Warning
        return $false
    }
    
    Write-Host ""
    Write-ColorMessage "Deleting configuration..." -Type Info
    
    $deleted = @()
    $errors = @()
    
    # Remove scheduled task
    try {
        $taskName = "Website Backup - Automated"
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop | Out-Null
            $deleted += "Scheduled task"
        }
    }
    catch {
        $errors += "Scheduled task: $_"
    }
    
    # Remove registry configuration
    try {
        if (Test-Path "HKCU:\Software\WebsiteBackup") {
            Remove-Item -Path "HKCU:\Software\WebsiteBackup" -Recurse -Force -ErrorAction Stop
            $deleted += "Registry configuration"
        }
    }
    catch {
        $errors += "Registry: $_"
    }
    
    # Show results
    Write-Host ""
    if ($deleted.Count -gt 0) {
        Write-ColorMessage "[OK] Successfully deleted:" -Type Success
        foreach ($item in $deleted) {
            Write-Host "  * $item" -ForegroundColor Green
        }
    }
    
    if ($errors.Count -gt 0) {
        Write-ColorMessage "[!] Errors encountered:" -Type Warning
        foreach ($errMsg in $errors) {
            Write-Host "  * $errMsg" -ForegroundColor Yellow
        }
    }
    
    Write-Host ""
    Write-ColorMessage "[OK] All configuration has been cleared!" -Type Success
    Write-Host ""
    Write-ColorMessage "You can now run the setup wizard again by running:" -Type Info
    Write-Host "  .\Backup-Website.ps1" -ForegroundColor Yellow
    Write-Host ""
    
    return $true
}

function Get-BackupScheduleInfo {
    <#
    .SYNOPSIS
        Gets the current backup schedule information.
    #>
    [CmdletBinding()]
    param()
    
    $taskName = "Website Backup - Automated"
    
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        
        # Try to get frequency from registry first
        $frequency = "Unknown"
        $scheduleTime = "Unknown"
        
        if (Test-Path "HKCU:\Software\WebsiteBackup") {
            $regData = Get-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -ErrorAction SilentlyContinue
            if ($regData.ScheduleFrequency) {
                $frequency = $regData.ScheduleFrequency
            }
            if ($regData.ScheduleTime) {
                $scheduleTime = $regData.ScheduleTime
            }
        }
        
        $schedule = @{
            TaskName = $taskName
            Enabled = $task.State -eq 'Ready'
            NextRunTime = $taskInfo.NextRunTime
            LastRunTime = $taskInfo.LastRunTime
            LastResult = $taskInfo.LastTaskResult
            Frequency = $frequency
            Time = $scheduleTime
        }
        
        return $schedule
    }
    catch {
        return $null
    }
}

function Show-ScheduleMenu {
    <#
    .SYNOPSIS
        Shows schedule management menu.
    #>
    [CmdletBinding()]
    param()
    
    $currentSchedule = Get-BackupScheduleInfo
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "  BACKUP SCHEDULE MANAGEMENT" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""
    
    if ($currentSchedule) {
        Write-ColorMessage "Current Schedule:" -Type Info
        Write-Host "  Status:     " -NoNewline -ForegroundColor Gray
        $statusColor = if ($currentSchedule.Enabled) { 'Green' } else { 'Yellow' }
        $statusText = if ($currentSchedule.Enabled) { 'Enabled' } else { 'Disabled' }
        Write-Host $statusText -ForegroundColor $statusColor
        
        Write-Host "  Frequency:  " -NoNewline -ForegroundColor Gray
        Write-Host "$($currentSchedule.Frequency)" -ForegroundColor Yellow
        
        Write-Host "  Time:       " -NoNewline -ForegroundColor Gray
        Write-Host "$($currentSchedule.Time)" -ForegroundColor Yellow
        
        if ($currentSchedule.NextRunTime) {
            Write-Host "  Next Run:   " -NoNewline -ForegroundColor Gray
            Write-Host "$($currentSchedule.NextRunTime)" -ForegroundColor Yellow
        }
        
        if ($currentSchedule.LastRunTime) {
            Write-Host "  Last Run:   " -NoNewline -ForegroundColor Gray
            Write-Host "$($currentSchedule.LastRunTime)" -ForegroundColor Yellow
        }
    }
    else {
        Write-ColorMessage "No schedule configured." -Type Warning
    }
    
    Write-Host ""
    Write-Host "Options:" -ForegroundColor Cyan
    Write-Host "  [1] Create/Update schedule" -ForegroundColor White
    Write-Host "  [2] Remove schedule" -ForegroundColor White
    Write-Host "  [3] Test scheduled task" -ForegroundColor White
    Write-Host "  [B] Back to main menu" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-UserChoice -Prompt "Choice" -ValidChoices @('1', '2', '3', 'B') -DefaultChoice 'B'
    
    switch ($choice) {
        '1' {
            # Create/Update schedule
            Write-Host ""
            Write-ColorMessage "Schedule Options:" -Type Info
            Write-Host "  [1] Daily   - Every day at a specific time" -ForegroundColor White
            Write-Host "  [2] Weekly  - Every Monday" -ForegroundColor White
            Write-Host "  [3] Monthly - First day of each month" -ForegroundColor White
            Write-Host "  [4] Quarterly - First day of each quarter (Jan, Apr, Jul, Oct)" -ForegroundColor White
            Write-Host ""
            
            $scheduleChoice = Read-UserInput -Prompt "Select frequency (1-4)" -Required
            
            if ($scheduleChoice -match '^[1-4]$') {
                $scheduleTime = Read-UserInput -Prompt "What time? (HH:MM, e.g., 02:00)" -DefaultValue "02:00"
                
                # Validate time format
                if ($scheduleTime -notmatch '^\d{1,2}:\d{2}$') {
                    Write-ColorMessage "Invalid time format. Using default: 02:00" -Type Warning
                    $scheduleTime = "02:00"
                }
                
                $scheduleFrequency = switch ($scheduleChoice) {
                    '1' { 'Daily' }
                    '2' { 'Weekly' }
                    '3' { 'Monthly' }
                    '4' { 'Quarterly' }
                }
                
                Write-Host ""
                Write-ColorMessage "Creating scheduled task..." -Type Info
                
                if (New-BackupSchedule -Frequency $scheduleFrequency -Time $scheduleTime) {
                    Write-Host ""
                    Write-ColorMessage "[OK] Schedule updated successfully!" -Type Success
                }
            }
        }
        '2' {
            Write-Host ""
            $confirm = Read-UserChoice -Prompt "Remove scheduled backups?" -ValidChoices @('Y', 'N') -DefaultChoice 'N'
            if ($confirm -eq 'Y') {
                Remove-BackupSchedule
            }
        }
        '3' {
            Write-Host ""
            Write-ColorMessage "Testing scheduled task (running backup now)..." -Type Info
            try {
                Start-ScheduledTask -TaskName "Website Backup - Automated" -ErrorAction Stop
                Write-ColorMessage "[OK] Task started! Check Task Scheduler or logs for results." -Type Success
            }
            catch {
                Write-ColorMessage "[X] Failed to start task: $_" -Type Error
            }
        }
    }
    
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-InteractiveSetup {
    <#
    .SYNOPSIS
        Main interactive setup wizard for first-time users.
    #>
    [CmdletBinding()]
    param()
    
    # Show welcome screen
    Show-WelcomeScreen
    
    $proceed = Read-UserChoice -Prompt "Ready to begin?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
    if ($proceed -ne 'Y') {
        Write-ColorMessage "Setup cancelled by user." -Type Warning
        return $null
    }
    
    # STEP 1: Check Prerequisites
    Show-ProgressStep -Step 1 -TotalSteps 8 -Description "Checking Prerequisites"
    
    $sshInstalled = Test-Prerequisite -ToolName "OpenSSH Client" -Command "ssh" `
        -InstallGuide "Download from: https://docs.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse or use: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    
    $rcloneInstalled = Test-Prerequisite -ToolName "Rclone" -Command "rclone" `
        -InstallGuide "Download from: https://rclone.org/downloads/ and add to PATH"
    
    # Offer automatic installation for missing prerequisites
    if (-not $sshInstalled) {
        Write-Host ""
        $installSSH = Read-UserChoice -Prompt "Would you like to automatically install OpenSSH Client?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
        if ($installSSH -eq 'Y') {
            $sshInstalled = Install-OpenSSHClient
            if ($sshInstalled) {
                Write-Host ""
                Write-ColorMessage "  Verifying OpenSSH installation..." -Type Info
                Start-Sleep -Seconds 2
                # Re-test the command
                try {
                    $null = & ssh 2>&1
                    $sshInstalled = $true
                    Write-ColorMessage "  [OK] OpenSSH Client is now available!" -Type Success
                }
                catch {
                    Write-ColorMessage "  [!] OpenSSH installed but may require terminal restart to be detected." -Type Warning
                    $sshInstalled = $true  # Assume it's installed even if not detected yet
                }
            }
        }
    }
    
    if (-not $rcloneInstalled) {
        Write-Host ""
        $installRclone = Read-UserChoice -Prompt "Would you like to automatically install Rclone?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
        if ($installRclone -eq 'Y') {
            $rcloneInstalled = Install-Rclone
            if ($rcloneInstalled) {
                Write-Host ""
                Write-ColorMessage "  Verifying Rclone installation..." -Type Info
                Start-Sleep -Seconds 1
                # Re-test the command
                try {
                    $null = & rclone version 2>&1
                    $rcloneInstalled = $true
                    Write-ColorMessage "  [OK] Rclone is now available!" -Type Success
                }
                catch {
                    # Try with full path
                    $rcloneExe = Join-Path $env:LOCALAPPDATA "rclone\rclone.exe"
                    if (Test-Path $rcloneExe) {
                        Write-ColorMessage "  [OK] Rclone installed. You may need to restart terminal for PATH to update." -Type Success
                        $rcloneInstalled = $true
                    }
                }
            }
        }
    }
    
    if (-not $sshInstalled -or -not $rcloneInstalled) {
        Write-Host ""
        Write-ColorMessage "Missing prerequisites:" -Type Error
        if (-not $sshInstalled) { Write-ColorMessage "  - OpenSSH Client" -Type Error }
        if (-not $rcloneInstalled) { Write-ColorMessage "  - Rclone" -Type Error }
        Write-Host ""
        Write-ColorMessage "Please install the missing prerequisites and run this script again." -Type Error
        $retry = Read-UserChoice -Prompt "Would you like to retry the prerequisite check?" -ValidChoices @('Y', 'N') -DefaultChoice 'N'
        if ($retry -eq 'Y') {
            return Invoke-InteractiveSetup
        }
        return $null
    }
    
    Write-ColorMessage "`n[OK] All prerequisites are installed!" -Type Success
    Start-Sleep -Seconds 2
    
    # STEP 2: SSH Key Setup
    Show-ProgressStep -Step 2 -TotalSteps 8 -Description "SSH Key Setup"
    
    if (Test-SSHKeyExists) {
        Write-ColorMessage "[OK] SSH key pair already exists." -Type Success
    }
    else {
        Write-ColorMessage "No SSH key pair found. Let's create one." -Type Warning
        $createKey = Read-UserChoice -Prompt "Generate SSH key pair now?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
        
        if ($createKey -eq 'Y') {
            if (-not (New-SSHKeyPair)) {
                Write-ColorMessage "Failed to generate SSH key. Please create one manually and run setup again." -Type Error
                return $null
            }
        }
        else {
            Write-ColorMessage "Setup cannot continue without an SSH key. Exiting." -Type Error
            return $null
        }
    }
    
    # Display public key and instructions
    $publicKey = Get-SSHPublicKey
    Write-Host ""
    Write-ColorMessage "Your SSH Public Key:" -Type Info
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    Write-Host $publicKey -ForegroundColor Yellow
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    Write-Host ""
    Write-ColorMessage "IMPORTANT: You need to add this public key to your server's ~/.ssh/authorized_keys file." -Type Warning
    Write-Host ""
    Write-ColorMessage "Options:" -Type Info
    Write-ColorMessage "  1. Manual: Copy the key above and add it to ~/.ssh/authorized_keys on your server" -Type Info
    Write-ColorMessage "  2. Automatic: Use the Add-SSHKeyToServer.ps1 helper script (requires password)" -Type Info
    Write-Host ""
    
    $keyAdded = Read-UserChoice -Prompt "Have you added the public key to your server?" -ValidChoices @('Y', 'N') -DefaultChoice 'N'
    if ($keyAdded -ne 'Y') {
        Write-ColorMessage "Please add the public key to your server and run setup again." -Type Warning
        return $null
    }
    
    # STEP 3: Collect Server Information
    Show-ProgressStep -Step 3 -TotalSteps 8 -Description "Server Connection Information"
    
    $sshUser = Read-UserInput -Prompt "SSH Username" -Required
    $sshHost = Read-UserInput -Prompt "SSH Hostname or IP address" -Required
    $sshPort = [int](Read-UserInput -Prompt "SSH Port" -DefaultValue "22")
    
    Write-Host ""
    Write-ColorMessage "Testing SSH connection..." -Type Info
    
    if (Test-SSHConnectionQuiet -User $sshUser -Hostname $sshHost -Port $sshPort) {
        Write-ColorMessage "[OK] SSH connection successful!" -Type Success
    }
    else {
        Write-ColorMessage "[X] SSH connection failed!" -Type Error
        Write-ColorMessage "Please check your SSH key, server details, and network connection." -Type Warning
        
        $retry = Read-UserChoice -Prompt "Would you like to try different connection details?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
        if ($retry -eq 'Y') {
            return Invoke-InteractiveSetup
        }
        return $null
    }
    
    Start-Sleep -Seconds 1
    
    # STEP 4: Determine Backup Paths
    Show-ProgressStep -Step 4 -TotalSteps 8 -Description "Website Location"
    
    # Loop until user enters a valid path
    $pathValid = $false
    $remotePath = ""
    
    while (-not $pathValid) {
        Write-ColorMessage "Please enter the path to your website files on the server." -Type Info
        Write-Host ""
        Write-ColorMessage "Common examples:" -Type Info
        Write-Host "  - /home/username/public_html" -ForegroundColor Yellow
        Write-Host "  - /home/username/applications/myapp/public_html" -ForegroundColor Yellow
        Write-Host "  - /var/www/html" -ForegroundColor Yellow
        Write-Host ""
        Write-ColorMessage "TIP: You can use wildcards (*) to backup multiple folders at once!" -Type Info
        Write-ColorMessage "Example: /home/username/applications/*/local_backups" -Type Info
        Write-ColorMessage "         This will backup ALL local_backups folders from ALL applications." -Type Info
        Write-Host ""
        
        $remotePath = Read-UserInput -Prompt "Enter the full path to your website files" -Required
        
        # Check if path contains wildcard
        $hasWildcard = $remotePath -match '\*'
        
        # Verify the path exists
        Write-Host ""
        if ($hasWildcard) {
            Write-ColorMessage "Wildcard path detected: $remotePath" -Type Info
            Write-ColorMessage "Verifying wildcard pattern expands to valid directories..." -Type Info
            
            # Test if the wildcard pattern matches any directories
            $testWildcardCmd = "ssh -p $sshPort ${sshUser}@${sshHost} 'ls -d $remotePath 2>/dev/null | head -5'"
            $wildcardResult = Invoke-Expression $testWildcardCmd 2>&1
            
            if ($LASTEXITCODE -eq 0 -and $wildcardResult) {
                $matchCount = ($wildcardResult | Measure-Object -Line).Lines
                Write-ColorMessage "[OK] Pattern matches at least $matchCount directories!" -Type Success
                Write-ColorMessage "Sample matches:" -Type Info
                $wildcardResult | Select-Object -First 5 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
                $pathValid = $true
            }
            else {
                Write-ColorMessage "[X] Error: Wildcard pattern doesn't match any directories." -Type Error
                Write-ColorMessage "Please check your path and try again." -Type Warning
                Write-Host ""
                
                $retry = Read-UserChoice -Prompt "Try again?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
                if ($retry -ne 'Y') {
                    return $null
                }
                Write-Host ""
            }
        }
        else {
            Write-ColorMessage "Verifying path: $remotePath" -Type Info
            if (Test-RemotePathExists -User $sshUser -Hostname $sshHost -Port $sshPort -Path $remotePath) {
                Write-ColorMessage "[OK] Path exists and is accessible!" -Type Success
                $pathValid = $true
            }
            else {
                Write-ColorMessage "[X] Error: Path does not exist or is not accessible." -Type Error
                Write-ColorMessage "Please check your path and try again." -Type Warning
                Write-Host ""
                
                $retry = Read-UserChoice -Prompt "Try again?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
                if ($retry -ne 'Y') {
                    return $null
                }
                Write-Host ""
            }
        }
    }
    
    Start-Sleep -Seconds 1
    
    # STEP 5: Google Drive Setup
    Show-ProgressStep -Step 5 -TotalSteps 8 -Description "Google Drive Configuration"
    
    Write-ColorMessage "Checking rclone configuration..." -Type Info
    
    # Check if gdrive remote exists
    $process = Start-Process -FilePath "rclone" -ArgumentList "listremotes" `
        -Wait -NoNewWindow -PassThru -RedirectStandardOutput "remotes.tmp"
    
    $remotes = @()
    if (Test-Path "remotes.tmp") {
        $remotes = (Get-Content "remotes.tmp") | Where-Object { $_ -ne "" }
        Remove-Item "remotes.tmp" -ErrorAction SilentlyContinue
    }
    
    $gdriveExists = $remotes -contains "gdrive:"
    
    if ($gdriveExists) {
        Write-ColorMessage "[OK] Google Drive remote 'gdrive' already configured!" -Type Success
    }
    else {
        Write-Host ""
        Write-ColorMessage "Google Drive remote 'gdrive' not found." -Type Warning
        Write-ColorMessage "I'll launch rclone config to help you set it up." -Type Info
        Write-Host ""
        Write-ColorMessage "Follow these steps in rclone config:" -Type Info
        Write-ColorMessage "  1. Type 'n' for new remote" -Type Info
        Write-ColorMessage "  2. Enter name: gdrive" -Type Info
        Write-ColorMessage "  3. Select 'Google Drive' from the list" -Type Info
        Write-ColorMessage "  4. Leave client_id and client_secret blank (press Enter)" -Type Info
        Write-ColorMessage "  5. Choose scope: 1 (Full access)" -Type Info
        Write-ColorMessage "  6. Follow the browser authentication" -Type Info
        Write-ColorMessage "  7. Type 'q' to quit when done" -Type Info
        Write-Host ""
        
        $proceed = Read-UserChoice -Prompt "Ready to launch rclone config?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
        if ($proceed -ne 'Y') {
            Write-ColorMessage "Cannot continue without Google Drive configuration." -Type Error
            return $null
        }
        
        # Launch rclone config
        Start-Process -FilePath "rclone" -ArgumentList "config" -Wait -NoNewWindow
        
        # Verify gdrive was created
        $process = Start-Process -FilePath "rclone" -ArgumentList "listremotes" `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput "remotes.tmp"
        
        $remotes = @()
        if (Test-Path "remotes.tmp") {
            $remotes = (Get-Content "remotes.tmp") | Where-Object { $_ -ne "" }
            Remove-Item "remotes.tmp" -ErrorAction SilentlyContinue
        }
        
        $gdriveExists = $remotes -contains "gdrive:"
        
        if (-not $gdriveExists) {
            Write-ColorMessage "[X] Google Drive remote 'gdrive' was not found. Please run rclone config manually." -Type Error
            return $null
        }
        
        Write-ColorMessage "[OK] Google Drive configured successfully!" -Type Success
    }
    
    # Create backup directories
    Write-Host ""
    Write-ColorMessage "Creating backup directories on Google Drive..." -Type Info
    
    $null = Start-Process -FilePath "rclone" -ArgumentList "mkdir", "gdrive:backups" -Wait -NoNewWindow -PassThru
    $null = Start-Process -FilePath "rclone" -ArgumentList "mkdir", "gdrive:backups/website" -Wait -NoNewWindow -PassThru
    
    Write-ColorMessage "[OK] Backup directories created!" -Type Success
    
    $gdriveRemote = "gdrive:backups/website"
    
    Start-Sleep -Seconds 1
    
    # STEP 6: Schedule Automatic Backups
    Show-ProgressStep -Step 6 -TotalSteps 8 -Description "Automatic Backup Schedule (Optional)"
    
    Write-Host ""
    Write-ColorMessage "Would you like to schedule automatic backups?" -Type Question
    Write-Host ""
    Write-ColorMessage "Schedule Options:" -Type Info
    Write-Host "  [1] Daily     - Every day at a specific time" -ForegroundColor White
    Write-Host "  [2] Weekly    - Every Monday" -ForegroundColor White
    Write-Host "  [3] Monthly   - First day of each month" -ForegroundColor White
    Write-Host "  [4] Quarterly - First day of each quarter (Jan, Apr, Jul, Oct)" -ForegroundColor White
    Write-Host "  [5] Skip      - No automatic scheduling (run manually)" -ForegroundColor White
    Write-Host ""
    
    $scheduleChoice = Read-UserInput -Prompt "Select option (1-5)" -DefaultValue "5"
    
    if ($scheduleChoice -match '^[1-4]$') {
        Write-Host ""
        $scheduleTime = Read-UserInput -Prompt "What time should backups run? (HH:MM, e.g., 02:00)" -DefaultValue "02:00"
        
        # Validate time format
        if ($scheduleTime -notmatch '^\d{1,2}:\d{2}$') {
            Write-ColorMessage "Invalid time format. Using default: 02:00" -Type Warning
            $scheduleTime = "02:00"
        }
        
        $scheduleFrequency = switch ($scheduleChoice) {
            '1' { 'Daily' }
            '2' { 'Weekly' }
            '3' { 'Monthly' }
            '4' { 'Quarterly' }
        }
        
        Write-Host ""
        Write-ColorMessage "Creating scheduled task..." -Type Info
        
        if (New-BackupSchedule -Frequency $scheduleFrequency -Time $scheduleTime) {
            Write-Host ""
            Write-ColorMessage "*** Automatic backups scheduled!" -Type Success
            Write-ColorMessage "   Your backups will run $scheduleFrequency at $scheduleTime" -Type Info
            Write-Host ""
        }
        else {
            Write-ColorMessage "[!] Scheduling failed. You can schedule later or run backups manually." -Type Warning
        }
    }
    else {
        Write-ColorMessage "Skipping automatic scheduling." -Type Info
        Write-ColorMessage "You can schedule later from the main menu or run backups manually." -Type Info
    }
    
    Start-Sleep -Seconds 1
    
    # STEP 7: Save Configuration
    Show-ProgressStep -Step 7 -TotalSteps 8 -Description "Saving Configuration"
    
    $config = @{
        SSHUser = $sshUser
        SSHHost = $sshHost
        SSHPort = $sshPort
        RemotePath = $remotePath
        GDriveRemote = $gdriveRemote
    }
    
    Write-Host ""
    Write-ColorMessage "Configuration Summary:" -Type Info
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    Write-Host "  SSH Server:    " -NoNewline -ForegroundColor Gray
    Write-Host "${sshUser}@${sshHost}:${sshPort}" -ForegroundColor Yellow
    Write-Host "  Website Path:  " -NoNewline -ForegroundColor Gray
    Write-Host "$remotePath" -ForegroundColor Yellow
    Write-Host "  Backup Path:   " -NoNewline -ForegroundColor Gray
    Write-Host "$remotePath/local_backups/backup.tgz" -ForegroundColor Yellow
    Write-Host "  Google Drive:  " -NoNewline -ForegroundColor Gray
    Write-Host "$gdriveRemote" -ForegroundColor Yellow
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    Write-Host ""
    
    $confirm = Read-UserChoice -Prompt "Save this configuration?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
    if ($confirm -ne 'Y') {
        Write-ColorMessage "Configuration not saved. Exiting." -Type Warning
        return $null
    }
    
    # Save to registry
    try {
        if (-not (Test-Path "HKCU:\Software\WebsiteBackup")) {
            New-Item -Path "HKCU:\Software\WebsiteBackup" -Force | Out-Null
        }
        
        Set-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "SSHUser" -Value $sshUser
        Set-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "SSHHost" -Value $sshHost
        Set-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "SSHPort" -Value $sshPort
        Set-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "RemotePath" -Value $remotePath
        Set-ItemProperty -Path "HKCU:\Software\WebsiteBackup" -Name "GDriveRemote" -Value $gdriveRemote
        
        Write-ColorMessage "[OK] Configuration saved successfully!" -Type Success
    }
    catch {
        Write-ColorMessage "[X] Failed to save configuration: $_" -Type Error
        return $null
    }
    
    Start-Sleep -Seconds 1
    
    # STEP 8: Offer First Backup
    Show-ProgressStep -Step 8 -TotalSteps 8 -Description "Setup Complete!"
    
    Write-Host ""
    Write-ColorMessage "*** Setup completed successfully!" -Type Success
    Write-Host ""
    Write-ColorMessage "Your backup system is now configured and ready to use." -Type Info
    Write-Host ""
    Write-Host ("-" * 80) -ForegroundColor DarkGray
    Write-Host "  Script built with love by Soulitek - Professional IT Business Solutions" -ForegroundColor DarkGray
    Write-Host "  Contact: letstalk@soulitek.co.il | www.soulitek.co.il" -ForegroundColor DarkGray
    Write-Host ("-" * 80) -ForegroundColor DarkGray
    Write-Host ""
    
    $runNow = Read-UserChoice -Prompt "Would you like to run your first backup now?" -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
    
    if ($runNow -eq 'Y') {
        return $config
    }
    else {
        Write-Host ""
        Write-ColorMessage "You can run the backup anytime by executing:" -Type Info
        Write-Host "  .\Backup-Website.ps1" -ForegroundColor Yellow
        Write-Host ""
        return $null
    }
}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

function Write-Log {
    <#
    .SYNOPSIS
        Writes formatted log messages to console and log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to log file
    if (Test-Path $LOG_FILE) {
        Add-Content -Path $LOG_FILE -Value $logMessage -ErrorAction SilentlyContinue
    }
    
    # Write to console with color
    switch ($Level) {
        'Success' { Write-Host $logMessage -ForegroundColor Green }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
    }
}

function Write-StepHeader {
    <#
    .SYNOPSIS
        Writes a formatted step header to the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$StepName
    )
    
    $separator = "=" * 80
    Write-Log -Message $separator -Level Info
    Write-Log -Message "  $StepName" -Level Info
    Write-Log -Message $separator -Level Info
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

function Initialize-BackupEnvironment {
    <#
    .SYNOPSIS
        Initializes the backup environment (creates directories, log file, etc.).
    #>
    [CmdletBinding()]
    param()
    
    Write-StepHeader "Initializing Backup Environment"
    
    try {
        # Create log directory
        if (-not (Test-Path $LOG_DIR)) {
            New-Item -Path $LOG_DIR -ItemType Directory -Force | Out-Null
            Write-Log "Created log directory: $LOG_DIR" -Level Success
        }
        
        # Create/initialize log file
        if (-not (Test-Path $LOG_FILE)) {
            New-Item -Path $LOG_FILE -ItemType File -Force | Out-Null
        }
        
        # Create local backup directory
        if (-not (Test-Path $LOCAL_BACKUP_DIR)) {
            New-Item -Path $LOCAL_BACKUP_DIR -ItemType Directory -Force | Out-Null
            Write-Log "Created local backup directory: $LOCAL_BACKUP_DIR" -Level Success
        }
        
        Write-Log "Log file: $LOG_FILE" -Level Info
        Write-Log "Dry-run mode: $($DryRun.IsPresent)" -Level Info
        
        return $true
    }
    catch {
        Write-Log "Failed to initialize backup environment: $_" -Level Error
        return $false
    }
}

function Get-StoredCredentials {
    <#
    .SYNOPSIS
        Retrieves stored credentials from Windows Credential Manager.
    #>
    [CmdletBinding()]
    param()
    
    Write-StepHeader "Loading Configuration"
    
    try {
        # Try to retrieve credentials from Windows Credential Manager
        $credential = $null
        
        try {
            Add-Type -AssemblyName System.Security
            $credentialBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                [System.Text.Encoding]::UTF8.GetBytes($CREDENTIAL_TARGET),
                $null,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
        }
        catch {
            # Credential Manager not available or credential not found
        }
        
        # Build configuration object
        $config = @{
            SSHUser = $script:SSHUser
            SSHHost = $script:SSHHost
            SSHPort = $script:SSHPort
            RemotePath = $script:RemotePath
            GDriveRemote = $script:GDriveRemote
            ScheduleFrequency = $null
            ScheduleTime = $null
        }
        
        # If credentials not provided as parameters, try to load from registry (secure storage)
        if ([string]::IsNullOrEmpty($config.SSHUser) -or [string]::IsNullOrEmpty($config.SSHHost)) {
            $regPath = "HKCU:\Software\WebsiteBackup"
            if (Test-Path $regPath) {
                Write-Log "Loading configuration from registry..." -Level Info
                $regConfig = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                
                if ($regConfig) {
                    if ([string]::IsNullOrEmpty($config.SSHUser)) { $config.SSHUser = $regConfig.SSHUser }
                    if ([string]::IsNullOrEmpty($config.SSHHost)) { $config.SSHHost = $regConfig.SSHHost }
                    if ([string]::IsNullOrEmpty($config.RemotePath)) { $config.RemotePath = $regConfig.RemotePath }
                    if ([string]::IsNullOrEmpty($config.GDriveRemote)) { $config.GDriveRemote = $regConfig.GDriveRemote }
                    # Load schedule information if available
                    if ($regConfig.ScheduleFrequency) { $config.ScheduleFrequency = $regConfig.ScheduleFrequency }
                    if ($regConfig.ScheduleTime) { $config.ScheduleTime = $regConfig.ScheduleTime }
                }
            }
        } else {
            # Even if credentials are provided as parameters, still try to load schedule from registry
            $regPath = "HKCU:\Software\WebsiteBackup"
            if (Test-Path $regPath) {
                $regConfig = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                if ($regConfig) {
                    if ($regConfig.ScheduleFrequency) { $config.ScheduleFrequency = $regConfig.ScheduleFrequency }
                    if ($regConfig.ScheduleTime) { $config.ScheduleTime = $regConfig.ScheduleTime }
                }
            }
        }
        
        # Validate required configuration
        if ([string]::IsNullOrEmpty($config.SSHUser)) {
            throw "SSH User not configured. Run Setup-BackupCredentials.ps1 or provide -SSHUser parameter."
        }
        if ([string]::IsNullOrEmpty($config.SSHHost)) {
            throw "SSH Host not configured. Run Setup-BackupCredentials.ps1 or provide -SSHHost parameter."
        }
        if ([string]::IsNullOrEmpty($config.RemotePath)) {
            throw "Remote Path not configured. Run Setup-BackupCredentials.ps1 or provide -RemotePath parameter."
        }
        if ([string]::IsNullOrEmpty($config.GDriveRemote)) {
            throw "Google Drive Remote not configured. Run Setup-BackupCredentials.ps1 or provide -GDriveRemote parameter."
        }
        
        Write-Log "SSH User: $($config.SSHUser)" -Level Info
        Write-Log "SSH Host: $($config.SSHHost)" -Level Info
        Write-Log "SSH Port: $($config.SSHPort)" -Level Info
        Write-Log "Remote Path: $($config.RemotePath)" -Level Info
        Write-Log "Google Drive Remote: $($config.GDriveRemote)" -Level Info
        Write-Log "Configuration loaded successfully" -Level Success
        
        return $config
    }
    catch {
        Write-Log "Failed to load configuration: $_" -Level Error
        throw
    }
}

function Test-SSHConnection {
    <#
    .SYNOPSIS
        Tests SSH connectivity to the remote server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config
    )
    
    Write-StepHeader "Testing SSH Connection"
    
    $stepStart = Get-Date
    
    try {
        Write-Log "Testing connection to $($Config.SSHUser)@$($Config.SSHHost):$($Config.SSHPort)..." -Level Info
        
        if ($DryRun) {
            Write-Log "[DRY RUN] Would test SSH connection" -Level Warning
            return $true
        }
        
        # Test SSH connection with timeout using Start-Process
        $sshArgs = @("-p", "$($Config.SSHPort)", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes", "$($Config.SSHUser)@$($Config.SSHHost)", "echo CONNECTION_OK")
        Write-Log "Executing: ssh $($sshArgs -join ' ')" -Level Info
        
        $tempOutput = [System.IO.Path]::GetTempFileName()
        $tempError = [System.IO.Path]::GetTempFileName()
        
        try {
            $sshProcess = Start-Process -FilePath "ssh" -ArgumentList $sshArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $tempOutput -RedirectStandardError $tempError
            $result = if (Test-Path $tempOutput) { Get-Content $tempOutput -Raw } else { "" }
            $errorOutput = if (Test-Path $tempError) { Get-Content $tempError -Raw } else { "" }
            
            if ($sshProcess.ExitCode -eq 0 -and $result -match "CONNECTION_OK") {
                $duration = (Get-Date) - $stepStart
                Write-Log "SSH connection successful (Duration: $($duration.TotalSeconds.ToString('F2'))s)" -Level Success
                return $true
            }
            else {
                Write-Log "SSH connection failed. Exit code: $($sshProcess.ExitCode), Output: $result, Error: $errorOutput" -Level Error
                return $false
            }
        }
        finally {
            if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue }
            if (Test-Path $tempError) { Remove-Item $tempError -Force -ErrorAction SilentlyContinue }
        }
    }
    catch {
        $duration = (Get-Date) - $stepStart
        Write-Log "SSH connection test failed after $($duration.TotalSeconds.ToString('F2'))s: $_" -Level Error
        return $false
    }
}

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Checks if required tools are installed and available.
    #>
    [CmdletBinding()]
    param()
    
    Write-StepHeader "Checking Prerequisites"
    
    $allPrereqsMet = $true
    
    # Check SSH
    try {
        $sshCheck = Get-Command ssh -ErrorAction SilentlyContinue
        if (-not $sshCheck) {
            # Try common locations
            $commonPaths = @(
                "$env:SystemRoot\System32\OpenSSH\ssh.exe",
                "$env:ProgramFiles\OpenSSH\ssh.exe",
                "$env:ProgramFiles(x86)\OpenSSH\ssh.exe"
            )
            foreach ($path in $commonPaths) {
                if (Test-Path $path) {
                    $sshCheck = Get-Item $path
                    break
                }
            }
        }
        if ($sshCheck) {
            $sshPath = if ($sshCheck.Source) { $sshCheck.Source } else { $sshCheck.FullName }
            Write-Log "SSH client found: $sshPath" -Level Success
        }
        else {
            throw "SSH not found"
        }
    }
    catch {
        Write-Log "SSH client not found. Please install OpenSSH client." -Level Error
        $allPrereqsMet = $false
    }
    
    # Check SCP
    try {
        $scpCheck = Get-Command scp -ErrorAction Stop
        Write-Log "SCP utility found: $($scpCheck.Source)" -Level Success
    }
    catch {
        Write-Log "SCP utility not found. Please install OpenSSH client." -Level Error
        $allPrereqsMet = $false
    }
    
    # Check rclone (with timeout to prevent hanging)
    try {
        $rcloneJob = Start-Job -ScriptBlock { rclone version 2>&1 | Select-Object -First 1 }
        $jobResult = Wait-Job -Job $rcloneJob -Timeout 10
        if ($jobResult) {
            $rcloneVersion = Receive-Job -Job $rcloneJob
            Remove-Job -Job $rcloneJob -Force
            Write-Log "Rclone found: $rcloneVersion" -Level Success
        }
        else {
            Stop-Job -Job $rcloneJob -ErrorAction SilentlyContinue
            Remove-Job -Job $rcloneJob -Force -ErrorAction SilentlyContinue
            throw "Rclone check timed out"
        }
    }
    catch {
        Write-Log "Rclone not found or not responding. Please install rclone and configure Google Drive remote." -Level Error
        $allPrereqsMet = $false
    }
    
    return $allPrereqsMet
}

# =============================================================================
# BACKUP FUNCTIONS
# =============================================================================

function Get-BackupArchive {
    <#
    .SYNOPSIS
        Streams backup archive directly from remote server to local machine via SSH.
        No archive is created on the remote server - tar output streams directly through SSH.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config
    )
    
    Write-StepHeader "Streaming Backup from Remote Server"
    
    $stepStart = Get-Date
    
    try {
        $localPath = Join-Path $LOCAL_BACKUP_DIR $BACKUP_NAME
        
        # Check if path contains wildcard
        $hasWildcard = $Config.RemotePath -match '\*'
        
        Write-Log "Source: $($Config.SSHUser)@$($Config.SSHHost):$($Config.RemotePath)" -Level Info
        Write-Log "Destination: $localPath" -Level Info
        
        if ($hasWildcard) {
            Write-Log "Wildcard pattern detected - will backup all matching directories" -Level Info
        }
        
        if ($DryRun) {
            Write-Log "[DRY RUN] Would stream backup to $localPath" -Level Warning
            return $localPath
        }
        
        # Ensure local directory exists
        $localDir = Split-Path -Parent $localPath
        if (-not (Test-Path $localDir)) {
            New-Item -Path $localDir -ItemType Directory -Force | Out-Null
            Write-Log "Created local directory: $localDir" -Level Info
        }
        
        # Build tar command based on path type
        # Using -v for verbose output to show files being backed up
        if ($hasWildcard) {
            # For wildcard paths, tar the glob pattern directly (shell expands it)
            $tarCommand = "tar -cvzf - --ignore-failed-read $($Config.RemotePath) 2>&1"
        }
        else {
            # For single path, cd into directory and tar current dir
            $tarCommand = "cd '$($Config.RemotePath)' && tar -cvzf - . 2>&1"
        }
        
        Write-Log "Streaming backup via SSH (no server-side archive created)..." -Level Info
        Write-Log "Remote command: $tarCommand" -Level Info
        
        Write-Log "Starting backup stream with verbose output..." -Level Info
        Write-Host ""
        
        # Use .NET Process class for real-time stderr output while capturing stdout to file
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "ssh"
        $processInfo.Arguments = "-p $($Config.SSHPort) $($Config.SSHUser)@$($Config.SSHHost) `"$tarCommand`""
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        
        # Track progress
        $fileCount = 0
        $lastReportTime = Get-Date
        $startTime = Get-Date
        
        # Event handler for stderr (verbose output showing files)
        $stderrHandler = {
            if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
                $line = $EventArgs.Data
                # Skip tar info messages, show actual file paths
                if ($line -notmatch "^tar:" -and $line.Trim() -ne "") {
                    $script:fileCount++
                    # Show every file or periodically show progress
                    $elapsed = (Get-Date) - $script:startTime
                    $elapsedStr = "{0:mm\:ss}" -f $elapsed
                    
                    # Truncate long paths for display
                    $displayPath = if ($line.Length -gt 80) { "..." + $line.Substring($line.Length - 77) } else { $line }
                    Write-Host "`r  [$elapsedStr] Files: $($script:fileCount) | $displayPath".PadRight(120) -NoNewline -ForegroundColor Cyan
                }
                elseif ($line -match "^tar:") {
                    # Show tar warnings/info
                    Write-Host ""
                    Write-Host "  $line" -ForegroundColor Yellow
                }
            }
        }
        
        # Register event handlers
        $stdErrEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $stderrHandler
        
        try {
            # Start the process
            $process.Start() | Out-Null
            $process.BeginErrorReadLine()
            
            # Read stdout (tar data) and write to file
            $outputStream = [System.IO.File]::Create($localPath)
            try {
                $buffer = New-Object byte[] 65536
                $stdoutStream = $process.StandardOutput.BaseStream
                
                while ($true) {
                    $bytesRead = $stdoutStream.Read($buffer, 0, $buffer.Length)
                    if ($bytesRead -eq 0) { break }
                    $outputStream.Write($buffer, 0, $bytesRead)
                    
                    # Periodically show file size progress
                    $now = Get-Date
                    if (($now - $lastReportTime).TotalSeconds -ge 5) {
                        $currentSize = $outputStream.Length
                        $sizeMB = [math]::Round($currentSize / 1MB, 1)
                        $elapsed = $now - $startTime
                        $elapsedStr = "{0:mm\:ss}" -f $elapsed
                        Write-Host ""
                        Write-Host "  [$elapsedStr] Archive size: ${sizeMB} MB | Files processed: $fileCount" -ForegroundColor Green
                        $lastReportTime = $now
                    }
                }
            }
            finally {
                $outputStream.Close()
            }
            
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            
            Write-Host ""
            Write-Host ""
            
            if ($exitCode -ne 0) {
                # tar with --ignore-failed-read may return exit code 1 for minor issues
                if (-not (Test-Path $localPath) -or (Get-Item $localPath).Length -eq 0) {
                    throw "Failed to stream backup via SSH. Exit code: $exitCode"
                }
                else {
                    Write-Log "Tar completed with warnings (exit code $exitCode). Continuing..." -Level Warning
                }
            }
            
            Write-Log "Processed $fileCount files/directories" -Level Info
        }
        finally {
            Unregister-Event -SourceIdentifier $stdErrEvent.Name -ErrorAction SilentlyContinue
            Remove-Job -Id $stdErrEvent.Id -Force -ErrorAction SilentlyContinue
            if ($process -and -not $process.HasExited) {
                $process.Kill()
            }
            $process.Dispose()
        }
        
        # Verify the backup was created
        if (-not (Test-Path $localPath)) {
            throw "Backup file not found after streaming: $localPath"
        }
        
        $fileInfo = Get-Item $localPath
        $fileSizeBytes = $fileInfo.Length
        $fileSizeMB = [math]::Round($fileSizeBytes / 1MB, 2)
        $fileSizeGB = [math]::Round($fileSizeBytes / 1GB, 2)
        
        # Warn if suspiciously small
        if ($fileSizeBytes -lt 1048576) {  # Less than 1MB
            Write-Log "Warning: Backup size is very small ($fileSizeMB MB). Backup may be empty or incomplete." -Level Warning
        }
        
        $duration = (Get-Date) - $stepStart
        $sizeDisplay = if ($fileSizeGB -ge 1) { "$fileSizeGB GB" } else { "$fileSizeMB MB" }
        
        Write-Log "Backup stream completed successfully" -Level Success
        Write-Log "Local file: $localPath" -Level Info
        Write-Log "File size: $sizeDisplay" -Level Info
        Write-Log "Duration: $($duration.TotalSeconds.ToString('F2'))s ($([math]::Round($duration.TotalMinutes, 1)) minutes)" -Level Info
        
        return $localPath
    }
    catch {
        $duration = (Get-Date) - $stepStart
        Write-Log "Failed to stream backup after $($duration.TotalSeconds.ToString('F2'))s: $_" -Level Error
        return $null
    }
}

function Publish-ToGoogleDrive {
    <#
    .SYNOPSIS
        Uploads the backup archive to Google Drive using rclone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$LocalPath,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$Config
    )
    
    Write-StepHeader "Uploading to Google Drive"
    
    $stepStart = Get-Date
    
    try {
        Write-Log "Uploading: $LocalPath" -Level Info
        Write-Log "Destination: $($Config.GDriveRemote)/$BACKUP_NAME" -Level Info
        
        if ($DryRun) {
            Write-Log "[DRY RUN] Would upload to Google Drive" -Level Warning
            return $true
        }
        
        # Upload using rclone with progress
        $rcloneCommand = "rclone copy `"$LocalPath`" `"$($Config.GDriveRemote)`" --progress --stats 5s"
        Write-Log "Executing: $rcloneCommand" -Level Info
        
        $result = Invoke-Expression $rcloneCommand 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to upload to Google Drive. Exit code: $LASTEXITCODE, Output: $result"
        }
        
        # Verify upload
        $verifyCommand = "rclone ls `"$($Config.GDriveRemote)/$BACKUP_NAME`""
        $verifyResult = Invoke-Expression $verifyCommand 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Upload verification failed. File not found on Google Drive."
        }
        
        $duration = (Get-Date) - $stepStart
        Write-Log "Upload completed successfully" -Level Success
        Write-Log "Duration: $($duration.TotalSeconds.ToString('F2'))s" -Level Info
        
        return $true
    }
    catch {
        $duration = (Get-Date) - $stepStart
        Write-Log "Failed to upload to Google Drive after $($duration.TotalSeconds.ToString('F2'))s: $_" -Level Error
        return $false
    }
}

function Remove-OldBackups {
    <#
    .SYNOPSIS
        Removes old backups from Google Drive, keeping only the last N backups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory=$false)]
        [int]$KeepCount = $BACKUP_RETENTION_COUNT
    )
    
    Write-StepHeader "Rotating Old Backups"
    
    $stepStart = Get-Date
    
    try {
        Write-Log "Checking for old backups (keeping last $KeepCount)..." -Level Info
        
        if ($DryRun) {
            Write-Log "[DRY RUN] Would remove old backups" -Level Warning
            return $true
        }
        
        # List all backups
        $listCommand = "rclone lsf `"$($Config.GDriveRemote)`" --files-only"
        Write-Log "Executing: $listCommand" -Level Info
        
        $backups = Invoke-Expression $listCommand 2>&1 | Where-Object { $_ -match "^website-\d{8}-\d{6}\.tar\.gz$" }
        
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Warning: Failed to list backups. Skipping rotation." -Level Warning
            return $true
        }
        
        $backupCount = ($backups | Measure-Object).Count
        Write-Log "Found $backupCount backup(s)" -Level Info
        
        if ($backupCount -le $KeepCount) {
            Write-Log "No old backups to remove" -Level Info
            return $true
        }
        
        # Sort by name (timestamp is in filename) and get old backups
        $sortedBackups = $backups | Sort-Object
        $backupsToRemove = $sortedBackups | Select-Object -First ($backupCount - $KeepCount)
        
        Write-Log "Removing $($backupsToRemove.Count) old backup(s)..." -Level Info
        
        foreach ($backup in $backupsToRemove) {
            Write-Log "Deleting: $backup" -Level Info
            $deleteCommand = "rclone delete `"$($Config.GDriveRemote)/$backup`""
            $result = Invoke-Expression $deleteCommand 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Deleted: $backup" -Level Success
            }
            else {
                Write-Log "Warning: Failed to delete $backup - $result" -Level Warning
            }
        }
        
        $duration = (Get-Date) - $stepStart
        Write-Log "Backup rotation completed (Duration: $($duration.TotalSeconds.ToString('F2'))s)" -Level Success
        
        return $true
    }
    catch {
        $duration = (Get-Date) - $stepStart
        Write-Log "Backup rotation failed after $($duration.TotalSeconds.ToString('F2'))s: $_" -Level Warning
        return $true  # Non-critical failure
    }
}

function Remove-TempFiles {
    <#
    .SYNOPSIS
        Cleans up temporary local backup file after upload to Google Drive.
        Note: No remote cleanup needed since backup streams directly without creating server-side files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory=$false)]
        [string]$LocalPath
    )
    
    Write-StepHeader "Cleaning Up Temporary Files"
    
    $stepStart = Get-Date
    
    try {
        # Remove local backup file (after successful upload to Google Drive)
        if (-not [string]::IsNullOrEmpty($LocalPath) -and (Test-Path $LocalPath)) {
            Write-Log "Removing local temp file: $LocalPath" -Level Info
            
            if (-not $DryRun) {
                Remove-Item -Path $LocalPath -Force -ErrorAction Stop
                Write-Log "Local temp file removed successfully" -Level Success
            }
            else {
                Write-Log "[DRY RUN] Would remove local temp file" -Level Warning
            }
        }
        else {
            Write-Log "No local temp files to clean up" -Level Info
        }
        
        $duration = (Get-Date) - $stepStart
        Write-Log "Cleanup completed (Duration: $($duration.TotalSeconds.ToString('F2'))s)" -Level Success
        
        return $true
    }
    catch {
        $duration = (Get-Date) - $stepStart
        Write-Log "Cleanup failed after $($duration.TotalSeconds.ToString('F2'))s: $_" -Level Warning
        return $true  # Non-critical failure
    }
}

# =============================================================================
# NOTIFICATION FUNCTIONS
# =============================================================================

function Send-BackupNotification {
    <#
    .SYNOPSIS
        Sends email notification about backup status (optional, commented out by default).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Status,
        
        [Parameter(Mandatory=$true)]
        [string]$Details
    )
    
    # EMAIL NOTIFICATION - UNCOMMENT AND CONFIGURE TO ENABLE
    <#
    try {
        $emailParams = @{
            From = "backup@yourdomain.com"
            To = "admin@yourdomain.com"
            Subject = "Website Backup - $Status"
            Body = $Details
            SmtpServer = "smtp.yourdomain.com"
            Port = 587
            UseSsl = $true
            Credential = Get-Credential  # Or use stored credential
        }
        
        Send-MailMessage @emailParams
        Write-Log "Email notification sent" -Level Success
    }
    catch {
        Write-Log "Failed to send email notification: $_" -Level Warning
    }
    #>
    
    Write-Log "Email notifications are disabled. Enable in script if needed." -Level Info
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

function Invoke-Backup {
    <#
    .SYNOPSIS
        Main backup execution function.
    #>
    [CmdletBinding()]
    param()
    
    $backupSuccess = $false
    $localBackupPath = $null
    $config = $null
    
    try {
        Write-Log "========================================" -Level Info
        Write-Log "  WEBSITE BACKUP SCRIPT" -Level Info
        Write-Log "  Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Info
        Write-Log "========================================" -Level Info
        
        # Initialize environment
        if (-not (Initialize-BackupEnvironment)) {
            throw "Failed to initialize backup environment"
        }
        
        # Check prerequisites
        if (-not (Test-Prerequisites)) {
            throw "Prerequisites check failed. Please install required tools."
        }
        
        # Load configuration
        $config = Get-StoredCredentials
        
        # Log backup source info
        $hasWildcard = $config.RemotePath -match '\*'
        if ($hasWildcard) {
            Write-Log "Wildcard pattern detected: $($config.RemotePath)" -Level Info
            Write-Log "Backing up ALL matching directories" -Level Info
        }
        else {
            Write-Log "Backing up directory: $($config.RemotePath)" -Level Info
        }
        
        # Test SSH connection
        if (-not (Test-SSHConnection -Config $config)) {
            throw "SSH connection test failed"
        }
        
        # Stream backup directly from remote server to local machine
        # (No archive is created on the server - tar streams directly through SSH)
        $localBackupPath = Get-BackupArchive -Config $config
        if ([string]::IsNullOrEmpty($localBackupPath)) {
            throw "Failed to stream backup from remote server"
        }
        
        # Upload to Google Drive
        if (-not (Publish-ToGoogleDrive -LocalPath $localBackupPath -Config $config)) {
            throw "Failed to upload to Google Drive"
        }
        
        # Rotate old backups
        if (-not $SkipRotation) {
            Remove-OldBackups -Config $config
        }
        else {
            Write-Log "Skipping backup rotation (SkipRotation flag set)" -Level Warning
        }
        
        $backupSuccess = $true
    }
    catch {
        Write-Log "BACKUP FAILED: $_" -Level Error
        Write-Log $_.ScriptStackTrace -Level Error
        $backupSuccess = $false
    }
    finally {
        # Always cleanup temporary files
        if ($null -ne $config) {
            Remove-TempFiles -Config $config -LocalPath $localBackupPath
        }
        
        # Generate summary report
        Write-StepHeader "Backup Summary"
        
        $totalDuration = (Get-Date) - $SCRIPT_START_TIME
        
        Write-Log "Backup Name: $BACKUP_NAME" -Level Info
        Write-Log "Status: $(if ($backupSuccess) { 'SUCCESS' } else { 'FAILED' })" -Level $(if ($backupSuccess) { 'Success' } else { 'Error' })
        Write-Log "Total Duration: $($totalDuration.TotalSeconds.ToString('F2'))s ($($totalDuration.ToString('hh\:mm\:ss')))" -Level Info
        Write-Log "Ended: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Info
        
        if ($backupSuccess) {
            Write-Log "Backup completed successfully!" -Level Success
            
            # Send success notification
            $notificationDetails = @"
Backup completed successfully!

Backup Name: $BACKUP_NAME
Duration: $($totalDuration.ToString('hh\:mm\:ss'))
Log File: $LOG_FILE
"@
            Send-BackupNotification -Status "SUCCESS" -Details $notificationDetails
        }
        else {
            Write-Log "Backup failed. Check log file for details: $LOG_FILE" -Level Error
            
            # Send failure notification
            $notificationDetails = @"
Backup FAILED!

Backup Name: $BACKUP_NAME
Duration: $($totalDuration.ToString('hh\:mm\:ss'))
Log File: $LOG_FILE

Please check the log file for error details.
"@
            Send-BackupNotification -Status "FAILED" -Details $notificationDetails
        }
        
        Write-Log "========================================" -Level Info
        Write-Log "Log file saved to: $LOG_FILE" -Level Info
        Write-Log "========================================" -Level Info
        Write-Log "Script built with love by Soulitek - Professional IT Business Solutions" -Level Info
        Write-Log "Contact: letstalk@soulitek.co.il | www.soulitek.co.il" -Level Info
    }
    
    # Return exit code
    if ($backupSuccess) {
        exit 0
    }
    else {
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================

try {
    # For Monthly/Quarterly schedules, check if today is the right day to run
    if ($NonInteractive) {
        $scheduleInfo = Get-BackupScheduleInfo
        if ($scheduleInfo) {
            $today = Get-Date
            $shouldRun = $true
            
            if ($scheduleInfo.Frequency -eq 'Monthly') {
                # Only run on the 1st day of the month
                $shouldRun = ($today.Day -eq 1)
                if (-not $shouldRun) {
                    Write-Log "Monthly schedule: Today is not the 1st. Skipping backup." -Level Info
                    exit 0
                }
            }
            elseif ($scheduleInfo.Frequency -eq 'Quarterly') {
                # Only run on the 1st day of Jan, Apr, Jul, Oct
                $shouldRun = ($today.Day -eq 1 -and $today.Month -in @(1, 4, 7, 10))
                if (-not $shouldRun) {
                    Write-Log "Quarterly schedule: Today is not a quarterly start date. Skipping backup." -Level Info
                    exit 0
                }
            }
        }
    }
    
    # Check if this is first run or if ForceSetup is specified
    $isFirstRun = Test-IsFirstRun
    
    if ($ForceSetup -or $isFirstRun) {
        # Interactive setup mode
        if ($NonInteractive) {
            Write-ColorMessage "ERROR: Configuration required but running in non-interactive mode." -Type Error
            Write-ColorMessage "Please run the script interactively first to complete setup." -Type Error
            exit 1
        }
        
        $setupConfig = Invoke-InteractiveSetup
        
        if ($null -eq $setupConfig) {
            # Setup was cancelled or failed
            exit 0
        }
        
        # If setup returned a config, user wants to run backup now
        # Override parameters with setup values
        $SSHUser = $setupConfig.SSHUser
        $SSHHost = $setupConfig.SSHHost
        $SSHPort = $setupConfig.SSHPort
        $RemotePath = $setupConfig.RemotePath
        $GDriveRemote = $setupConfig.GDriveRemote
        
        # Proceed to backup
        Invoke-Backup
    }
    else {
        # Subsequent run - show configuration and get user choice
        if (-not $SkipConfirmation -and -not $NonInteractive) {
            # Load existing configuration
            $config = Get-StoredCredentials
            
            # Show configuration
            Show-Configuration -Config $config
            
            Write-Host "Options:" -ForegroundColor Cyan
            Write-Host "  [1] Run backup now (default)" -ForegroundColor White
            Write-Host "  [2] Reconfigure settings" -ForegroundColor White
            Write-Host "  [3] Run in dry-run mode" -ForegroundColor White
            Write-Host "  [4] Manage schedule" -ForegroundColor White
            Write-Host "  [5] Delete configuration (start fresh)" -ForegroundColor White
            Write-Host "  [Q] Quit" -ForegroundColor White
            Write-Host ""
            
            $choice = Read-UserChoice -Prompt "Choice" -ValidChoices @('1', '2', '3', '4', '5', 'Q', '') -DefaultChoice '1'
            
            switch ($choice) {
                '2' {
                    # Reconfigure
                    $setupConfig = Invoke-InteractiveSetup
                    
                    if ($null -eq $setupConfig) {
                        # Setup was cancelled
                        exit 0
                    }
                    
                    # Update parameters with new values
                    $SSHUser = $setupConfig.SSHUser
                    $SSHHost = $setupConfig.SSHHost
                    $SSHPort = $setupConfig.SSHPort
                    $RemotePath = $setupConfig.RemotePath
                    $GDriveRemote = $setupConfig.GDriveRemote
                    
                    # Proceed to backup
                    Invoke-Backup
                }
                '3' {
                    # Dry run mode
                    $DryRun = $true
                    Invoke-Backup
                }
                '4' {
                    # Manage schedule
                    Show-ScheduleMenu
                    # After managing schedule, show menu again
                    exit 0
                }
                '5' {
                    # Delete configuration and start fresh
                    if (Clear-BackupConfiguration) {
                        Write-Host ""
                        Write-ColorMessage "Configuration deleted. Restarting setup..." -Type Info
                        Start-Sleep -Seconds 2
                        # Restart the script to trigger first-run setup
                        & $PSCommandPath
                        exit 0
                    }
                    else {
                        Write-Host ""
                        Read-Host "Press Enter to continue"
                        exit 0
                    }
                }
                'Q' {
                    Write-ColorMessage "Backup cancelled by user." -Type Info
                    exit 0
                }
                default {
                    # Run backup (choice 1 or default)
                    Invoke-Backup
                }
            }
        }
        else {
            # Skip confirmation (either SkipConfirmation or NonInteractive mode)
            Invoke-Backup
        }
    }
}
catch {
    Write-ColorMessage "Fatal error: $_" -Type Error
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}


