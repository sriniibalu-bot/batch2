# IIS Application Pool Monitor - Usage Guide

## Overview
This PowerShell script automates monitoring of IIS application pools on Windows Server 2022. It automatically detects stopped pools, captures relevant error logs, and optionally restarts them.

## Features
✅ Monitors all IIS application pools every 60 seconds (configurable)  
✅ Detects stopped pools and captures Windows Event Log errors (last 10 minutes)  
✅ Automatic pool restart with idempotency checks  
✅ Dry-run mode for testing before actual restarts  
✅ Complete logging with timestamps  
✅ Rollback functionality to restore original pool states  
✅ Clean exit handling on Ctrl+C  
✅ Comprehensive error handling with try/catch blocks  
✅ Administrator privilege verification  
✅ WebAdministration module validation  

## Requirements
- **OS**: Windows Server 2022
- **IIS**: Installed with WebAdministration PowerShell module
- **Privileges**: Must run as Administrator
- **Log Directory**: C:\Logs\ (auto-created if doesn't exist)

## Installation

1. **Copy the script** to a location like:
   ```
   C:\Scripts\IIS-PoolMonitor.ps1
   ```

2. **Ensure execution policy** allows running scripts:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
   ```

3. **Create log directory** (if not auto-created):
   ```powershell
   New-Item -ItemType Directory -Path C:\Logs -Force
   ```

## Usage Examples

### Basic Monitoring (Production Mode)
Monitors pools and restarts any that are stopped:
```powershell
.\IIS-PoolMonitor.ps1
```

### Dry-Run Mode (Testing/Preview)
Shows what actions would be taken WITHOUT restarting pools:
```powershell
.\IIS-PoolMonitor.ps1 -DryRun
```

### Custom Check Interval
Check pool states every 30 seconds instead of default 60:
```powershell
.\IIS-PoolMonitor.ps1 -CheckInterval 30
```

### Custom Log Path
Write logs to a different location:
```powershell
.\IIS-PoolMonitor.ps1 -LogPath "D:\CustomLogs\iis-monitor.log"
```

### Combine Parameters
```powershell
.\IIS-PoolMonitor.ps1 -DryRun -CheckInterval 30 -LogPath "C:\Logs\iis-test.log"
```

## Log Output

Logs are written to `C:\Logs\iis-monitor.log` with the following format:
```
2026-06-12 14:30:45.123 [INFO] === Check #1 (2026-06-12 14:30:45) ===
2026-06-12 14:30:45.456 [INFO] All 5 pools are running normally
2026-06-12 14:31:45.789 [WARN] Found 1 stopped pool(s)
2026-06-12 14:31:45.890 [WARN] Stopped pool detected: 'DefaultAppPool'
2026-06-12 14:31:46.012 [INFO] Captured 3 error event(s) for pool 'DefaultAppPool'
2026-06-12 14:31:46.123 [SUCCESS] Successfully restarted pool 'DefaultAppPool'
```

## Key Features Explained

### Idempotency
The script checks if a pool is already running before attempting restart:
- If pool is already Started: skips restart with INFO message
- If pool is Stopped: proceeds with restart
- Verifies restart success with follow-up check

### Dry-Run Mode
Use `-DryRun` parameter to:
- See which pools would be restarted
- Verify logging is working
- Test without affecting production
- Message format: `[DRY-RUN] Would restart pool 'PoolName'`

### Event Log Capture
When a stopped pool is detected, the script captures:
- **System Log**: IIS/W3SVC errors from last 10 minutes (up to 10 most recent)
- **Application Log**: ASP.NET/WebHost provider errors from last 10 minutes
- **Filters**: Pool name, IIS keywords, or specific error types
- **Output**: Event ID, Provider Name, and Message preview

### Rollback Function
Stop monitoring and restore pools to initial state:
- **On Ctrl+C**: Prompts user if they want to rollback
- **Manual**: Can be called via `Invoke-Rollback` (requires module reloading)
- **Initial State Saved**: At script startup for all existing pools

### Clean Exit Handling
The script handles termination gracefully:
- **Ctrl+C Trap**: Catches interrupt and prompts for rollback
- **PowerShell.Exiting Event**: Logs final status message
- **Exit Code**: Returns 0 on clean exit, 1 on error

### Error Handling
All IIS operations wrapped in try/catch:
- **Pool State Retrieval**: Logs and continues on failure
- **Event Log Queries**: Non-fatal failures logged as WARN
- **Pool Restart**: Full error logging with details
- **Monitoring Loop**: Catches loop errors and retries after interval

## Troubleshooting

### Script Won't Start - "This script must be run as Administrator"
**Solution**: Right-click PowerShell and select "Run as Administrator"

### WebAdministration Module Not Found
**Solution**: Install IIS with management tools:
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementConsole
```

### Permission Denied on Log File
**Solution**: Ensure C:\Logs\ is writable by your user:
```powershell
icacls "C:\Logs" /grant "$($env:USERNAME):(OI)(CI)F"
```

### Pool Restart Not Working
**Solution**: 
1. Check logs for specific error message
2. Verify IIS service is running: `Get-Service WAS, W3SVC | Select Name, Status`
3. Check pool configuration: `Get-WebAppPool -Name "PoolName" | Select State, AutoStart`

### No Event Log Errors Showing
**Solution**:
1. Verify event logs are enabled: `wevtutil gl System` / `wevtutil gl Application`
2. Check if errors exist in the timeframe
3. Try a larger time window by editing the script's `Get-EventLogErrors -MinutesBack` parameter

## Running as a Scheduled Task

### Create Scheduled Task via PowerShell
```powershell
# Create action
$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Scripts\IIS-PoolMonitor.ps1'

# Create trigger (runs at boot and every 1 hour)
$trigger = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 60) -RepetitionDuration (New-TimeSpan -Days 1000))
)

# Create settings
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable

# Register task
Register-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -TaskName "IIS-PoolMonitor" -Description "Monitors and restarts stopped IIS application pools" -RunLevel Highest -Force
```

### Verify Task
```powershell
Get-ScheduledTask -TaskName "IIS-PoolMonitor" | Get-ScheduledTaskInfo
```

### View Task Execution History
```powershell
Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational -FilterXPath "*[EventData[Data[@Name='TaskName']='/IIS-PoolMonitor']]" | Select-Object TimeCreated, Message | Format-Table
```

## Parameters Reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DryRun` | Switch | False | Shows actions without actually restarting pools |
| `-LogPath` | String | C:\Logs\iis-monitor.log | Path to the log file |
| `-CheckInterval` | Int | 60 | Seconds between pool state checks |

## Log Levels

| Level | Color | Usage |
|-------|-------|-------|
| INFO | White | General informational messages |
| WARN | Yellow | Warnings (stopped pools, rollback initiated) |
| ERROR | Red | Errors (failed operations, exceptions) |
| SUCCESS | Green | Successful operations (pool restarted successfully) |

## Security Considerations

1. **Administrator Requirement**: Script enforces administrator execution
2. **Log Location**: C:\Logs should be restricted to administrators
3. **Audit**: All actions logged with timestamps for compliance
4. **Error Details**: Captured for troubleshooting (no passwords/sensitive data)
5. **Event Log Access**: Only reads system/application event logs

## Performance Impact

- **CPU**: Minimal (monitoring only, no constant polling within intervals)
- **Memory**: ~50-100 MB for PowerShell process
- **Disk I/O**: One log write per check interval (configurable)
- **Network**: None

## Advanced Customization

### Add Email Notifications
Uncomment and customize in the script:
```powershell
function Send-AlertEmail {
    $emailParams = @{
        To = "admin@company.com"
        From = "iismonitor@company.com"
        Subject = "IIS Pool Stopped"
        Body = "Pool '$PoolName' was restarted due to stopped state"
        SmtpServer = "mail.company.com"
    }
    Send-MailMessage @emailParams
}
```

### Add Slack Notifications
Integrate with Slack webhook:
```powershell
function Send-SlackNotification {
    param([string]$Message)
    $uri = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
    Invoke-RestMethod -Uri $uri -Method Post -Body (@{ text = $Message } | ConvertTo-Json)
}
```

### Extend Event Log Capture
Modify `Get-EventLogErrors` function to include additional logs or providers

## Support and Logs Location
- **Log File**: C:\Logs\iis-monitor.log
- **Event Logs**: Event Viewer > Windows Logs > System, Application
- **IIS Logs**: %SystemRoot%\System32\LogFiles\HTTP
- **IIS Manager**: Server Manager > IIS Manager

---
**Last Updated**: June 12, 2026  
**Script Version**: 1.0  
**Target**: Windows Server 2022 with IIS
