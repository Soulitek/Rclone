# Website Backup System

PowerShell-based automated website backups with Google Drive integration.

## Quick Start

Run the backup script:

```powershell
.\Backup-Website.ps1
```

The script will guide you through setup (SSH connection, Google Drive configuration, scheduling).

## Prerequisites

- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1+
- OpenSSH Client
- Rclone (with Google Drive configured)

## Usage

**First run:** Interactive setup wizard  
**Subsequent runs:** Press Enter to backup, or select options to reconfigure/manage schedule

**Non-interactive mode (for scheduled tasks):**
```powershell
.\Backup-Website.ps1 -NonInteractive
```

**Dry-run mode:**
```powershell
.\Backup-Website.ps1 -DryRun
```

## Features

- SSH key authentication
- Automated compression and upload to Google Drive
- Backup rotation (keeps last 7)
- Built-in scheduling (daily/weekly/monthly/quarterly)
- Comprehensive logging

## Documentation

For detailed documentation, see [docs/backup-system.md](docs/backup-system.md)
