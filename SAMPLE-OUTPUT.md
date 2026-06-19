# IIS Pool Monitor - Sample Output & Examples

## Console Output Example - Normal Operation

```
================================================================================
                   IIS Application Pool Monitor Started
================================================================================

2026-06-12 14:30:00.123 [INFO] ========================================
2026-06-12 14:30:00.234 [INFO] IIS Application Pool Monitor Started
2026-06-12 14:30:00.345 [INFO] DryRun Mode: False
2026-06-12 14:30:00.456 [INFO] Check Interval: 60 seconds
2026-06-12 14:30:00.567 [INFO] Log Path: C:\Logs\iis-monitor.log
2026-06-12 14:30:00.678 [INFO] ========================================
2026-06-12 14:30:01.123 [INFO] Saved initial state of 3 application pools
2026-06-12 14:30:01.234 [INFO] === Check #1 (2026-06-12 14:30:01) ===
2026-06-12 14:30:01.345 [INFO] All 3 pools are running normally
2026-06-12 14:30:01.456 [INFO] Next check in 60 seconds...
```

---

## Console Output Example - Pool Restart Scenario

```
2026-06-12 14:31:01.789 [INFO] === Check #2 (2026-06-12 14:31:01) ===
2026-06-12 14:31:01.890 [WARN] Found 1 stopped pool(s)
2026-06-12 14:31:01.901 [WARN] Stopped pool detected: 'DefaultAppPool'
2026-06-12 14:31:02.012 [INFO] Captured 3 error event(s) for pool 'DefaultAppPool'
2026-06-12 14:31:02.123 [INFO] Event ID: 5021 | Provider: IIS-W3SVC | Message: The application pool 'DefaultAppPool' has crashed...
2026-06-12 14:31:02.234 [INFO] Event ID: 2262 | Provider: WebHost | Message: Service critical error: Invalid pool configuration...
2026-06-12 14:31:02.345 [INFO] Event ID: 1000 | Provider: Application | Message: .NET Runtime version 4.0.30319 encountered an error...
2026-06-12 14:31:02.456 [INFO] Attempting to restart pool 'DefaultAppPool'...
2026-06-12 14:31:02.567 [SUCCESS] Successfully restarted pool 'DefaultAppPool'
2026-06-12 14:31:02.678 [INFO] Next check in 60 seconds...
```

---

## Console Output Example - Dry-Run Mode

```
2026-06-12 14:32:00.123 [INFO] ========================================
2026-06-12 14:32:00.234 [INFO] IIS Application Pool Monitor Started
2026-06-12 14:32:00.345 [INFO] DryRun Mode: True              ← DRY-RUN ACTIVE
2026-06-12 14:32:00.456 [INFO] Check Interval: 60 seconds
2026-06-12 14:32:00.567 [INFO] Log Path: C:\Logs\iis-monitor.log
2026-06-12 14:32:00.678 [INFO] ========================================

2026-06-12 14:32:01.123 [INFO] === Check #1 (2026-06-12 14:32:01) ===
2026-06-12 14:32:01.234 [INFO] All 3 pools are running normally
2026-06-12 14:32:01.345 [INFO] Next check in 60 seconds...

[Manually stop a pool for testing...]

2026-06-12 14:33:01.789 [INFO] === Check #2 (2026-06-12 14:33:01) ===
2026-06-12 14:33:01.890 [WARN] Found 1 stopped pool(s)
2026-06-12 14:33:01.901 [WARN] Stopped pool detected: 'TestPool'
2026-06-12 14:33:02.012 [INFO] Captured 1 error event(s) for pool 'TestPool'
2026-06-12 14:33:02.123 [INFO] Attempting to restart pool 'TestPool'...
2026-06-12 14:33:02.234 [INFO] [DRY-RUN] Would restart pool 'TestPool'  ← NOT ACTUALLY RESTARTED
2026-06-12 14:33:02.345 [INFO] Next check in 60 seconds...
```

---

## Log File Content - Full Session

```
2026-06-12 14:30:00.123 [INIT] IIS Pool Monitor started
2026-06-12 14:30:00.234 [INFO] ========================================
2026-06-12 14:30:00.345 [INFO] IIS Application Pool Monitor Started
2026-06-12 14:30:00.456 [INFO] DryRun Mode: False
2026-06-12 14:30:00.567 [INFO] Check Interval: 60 seconds
2026-06-12 14:30:00.678 [INFO] Log Path: C:\Logs\iis-monitor.log
2026-06-12 14:30:00.789 [INFO] ========================================
2026-06-12 14:30:01.001 [INFO] Saved initial state of 3 application pools
2026-06-12 14:30:01.112 [INFO] === Check #1 (2026-06-12 14:30:01) ===
2026-06-12 14:30:01.223 [INFO] All 3 pools are running normally
2026-06-12 14:30:01.334 [INFO] Next check in 60 seconds...
2026-06-12 14:31:01.445 [INFO] === Check #2 (2026-06-12 14:31:01) ===
2026-06-12 14:31:01.556 [INFO] All 3 pools are running normally
2026-06-12 14:31:01.667 [INFO] Next check in 60 seconds...
2026-06-12 14:32:01.778 [INFO] === Check #3 (2026-06-12 14:32:01) ===
2026-06-12 14:32:01.889 [WARN] Found 1 stopped pool(s)
2026-06-12 14:32:01.990 [WARN] Stopped pool detected: 'DefaultAppPool'
2026-06-12 14:32:02.101 [INFO] Captured 2 error event(s) for pool 'DefaultAppPool'
2026-06-12 14:32:02.212 [INFO] Event ID: 5021 | Provider: IIS-W3SVC | Message: The application pool 'DefaultAppPool' has encountered a cer...
2026-06-12 14:32:02.323 [INFO] Event ID: 1309 | Provider: Application Error | Message: Faulting application w3wp.exe, version 10.0.20348...
2026-06-12 14:32:02.434 [INFO] Attempting to restart pool 'DefaultAppPool'...
2026-06-12 14:32:04.545 [SUCCESS] Successfully restarted pool 'DefaultAppPool'
2026-06-12 14:32:04.656 [INFO] Next check in 60 seconds...
2026-06-12 14:33:04.767 [INFO] === Check #4 (2026-06-12 14:33:04) ===
2026-06-12 14:33:04.878 [INFO] All 3 pools are running normally
2026-06-12 14:33:04.989 [INFO] Next check in 60 seconds...
2026-06-12 14:33:15.090 [WARN] Received exit signal (Ctrl+C or script termination)
2026-06-12 14:33:15.201 [INFO] IIS Pool Monitor stopped
2026-06-12 14:33:15.312 [INFO] ========================================
```

---

## Real-World Scenarios

### Scenario 1: Pool Crash Due to Memory Leak
```
2026-06-12 09:15:03.456 [INFO] === Check #543 (2026-06-12 09:15:03) ===
2026-06-12 09:15:03.567 [WARN] Found 1 stopped pool(s)
2026-06-12 09:15:03.678 [WARN] Stopped pool detected: 'API_Production'
2026-06-12 09:15:03.789 [INFO] Captured 5 error event(s) for pool 'API_Production'
2026-06-12 09:15:03.890 [INFO] Event ID: 5021 | Provider: IIS-W3SVC | Message: Application pool 'API_Production' crashed due to memory...
2026-06-12 09:15:03.901 [INFO] Event ID: 2294 | Provider: IIS-W3SVC | Message: Process 'w3wp.exe' [PID: 4528] terminated unexpectedly...
2026-06-12 09:15:04.012 [SUCCESS] Successfully restarted pool 'API_Production'
2026-06-12 09:15:04.123 [INFO] Next check in 60 seconds...

[Later in log, pattern repeats...]

2026-06-12 12:45:01.234 [INFO] === Check #1080 (2026-06-12 12:45:01) ===
2026-06-12 12:45:01.345 [WARN] Found 1 stopped pool(s)
2026-06-12 12:45:01.456 [WARN] Stopped pool detected: 'API_Production'
2026-06-12 09:15:04.567 [SUCCESS] Successfully restarted pool 'API_Production'
→ Pool is crashing frequently - investigate root cause!
```

### Scenario 2: Configuration Issue on Multiple Pools
```
2026-06-12 08:00:01.123 [INFO] === Check #1 (2026-06-12 08:00:01) ===
2026-06-12 08:00:01.234 [WARN] Found 3 stopped pool(s)
2026-06-12 08:00:01.345 [WARN] Stopped pool detected: 'OldApplication'
2026-06-12 08:00:01.456 [INFO] Attempting to restart pool 'OldApplication'...
2026-06-12 08:00:02.567 [SUCCESS] Successfully restarted pool 'OldApplication'
2026-06-12 08:00:02.678 [WARN] Stopped pool detected: 'LegacyService'
2026-06-12 08:00:02.789 [INFO] Attempting to restart pool 'LegacyService'...
2026-06-12 08:00:03.890 [ERROR] Failed to restart pool 'LegacyService': The identity specified for this application pool cannot be used for v4.0...
2026-06-12 08:00:03.901 [WARN] Stopped pool detected: 'TestApp_v2'
2026-06-12 08:00:04.012 [INFO] Attempting to restart pool 'TestApp_v2'...
2026-06-12 08:00:05.123 [SUCCESS] Successfully restarted pool 'TestApp_v2'
→ LegacyService has a configuration problem - needs manual intervention
```

### Scenario 3: Idempotency Check - Pool Already Running
```
2026-06-12 14:30:01.123 [WARN] Found 1 stopped pool(s)
2026-06-12 14:30:01.234 [WARN] Stopped pool detected: 'AppPool_A'
2026-06-12 14:30:01.345 [INFO] Attempting to restart pool 'AppPool_A'...
2026-06-12 14:30:02.456 [SUCCESS] Successfully restarted pool 'AppPool_A'

[Same pool immediately detected as stopped again...]

2026-06-12 14:31:01.567 [WARN] Found 1 stopped pool(s)
2026-06-12 14:31:01.678 [WARN] Stopped pool detected: 'AppPool_A'
2026-06-12 14:31:01.789 [INFO] Pool 'AppPool_A' is already running. No restart needed.
→ Idempotency check prevented unnecessary restart - pool recovered on its own
```

---

## Performance Monitoring Logs

### 24-Hour Sample Statistics
```
Total checks performed: 1,440 (one per minute)
Pools monitored: 5
Total stopped events: 3
Total successful restarts: 3
Total restart failures: 0
Total events captured: 12
Log file size: 2.3 MB

Average operation time: 1.2 seconds
Peak CPU during restart: 3%
Average memory usage: 68 MB
Uptime: 24 hours 0 minutes
Restarts triggered by script: 3
Manual restarts: 0
```

---

## Error Scenarios & Logs

### WebAdministration Module Not Available
```
2026-06-12 14:30:00.123 [ERROR] WebAdministration module not available: The 'WebAdministration' module could not be loaded. For more information, run 'Import-Module WebAdministration'.
```
**Solution**: Install IIS Management Tools or run: `Enable-WindowsOptionalFeature -Online -FeatureName IIS-ManagementConsole`

### Administrator Privileges Required
```
Script terminated with error: This script must be run as Administrator
```
**Solution**: Right-click PowerShell and select "Run as Administrator"

### Log Directory Not Writable
```
2026-06-12 14:30:00.123 [ERROR] Log file 'C:\Logs\iis-monitor.log' is not writable: Access to the path 'C:\Logs' is denied.
```
**Solution**: Grant write permissions: `icacls "C:\Logs" /grant "$env:USERNAME:(OI)(CI)F"`

### Pool State Retrieval Error
```
2026-06-12 14:30:01.234 [ERROR] Failed to retrieve application pool states: The World Wide Web Publishing Service (W3SVC) or Internet Information Services (IIS) Master Service are not running.
```
**Solution**: Start IIS services: `Start-Service W3SVC, WAS`

---

## Scheduled Task Execution Logs

### Windows Task Scheduler History
```
Date: 2026-06-12
Time: 08:00:00 AM
Result: The task completed with an exit code of (0).
Duration: 1 second

---

Date: 2026-06-12
Time: 08:01:15 AM
Result: The task was terminated by the user.
Duration: 1 hour 15 minutes

---

Date: 2026-06-12
Time: 09:00:00 AM
Result: The task completed with an exit code of (0).
Duration: 45 minutes 32 seconds
(Script was monitoring entire time until restart occurred)
```

### PowerShell Execution Policy Check
```powershell
# Verify execution policy is set correctly
PS> Get-ExecutionPolicy
RemoteSigned

# If not set, enable script execution
PS> Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

---

## Deployment Verification Logs

### Successful Deployment
```
============================================================
                  DEPLOYMENT HELPER OUTPUT
============================================================

✓ Running as Administrator
✓ Windows Server 2022 (Build: 20348)
✓ IIS installed
✓ WebAdministration module available
✓ C:\Scripts - Script location (exists)
✓ C:\Logs - Log file location (created)
✓ Script copied to C:\Scripts\IIS-PoolMonitor.ps1
✓ Verification successful
✓ Dry-run completed
✓ Log file created successfully
✓ Scheduled task 'IIS-PoolMonitor' created
✓ Scheduled task started

============================================================
            DEPLOYMENT COMPLETE - NEXT STEPS
============================================================

1. VERIFY DEPLOYMENT
   • Check logs: Get-Content "C:\Logs\iis-monitor.log" -Wait
   • View current pools: Get-WebAppPool | Select Name, State

2. MONITOR SCRIPT EXECUTION
   • In Task Scheduler: Look for 'IIS-PoolMonitor' task
   • Check task history: Get-ScheduledTaskInfo -TaskName "IIS-PoolMonitor"

[Additional guidance...]
```

---

## Log Rotation Recommendation

### Weekly Log Archival Script
```powershell
# Archive logs older than 7 days
$logPath = "C:\Logs\iis-monitor.log"
$archivePath = "C:\Logs\Archive"

if (-not (Test-Path $archivePath)) {
    New-Item -ItemType Directory -Path $archivePath | Out-Null
}

$currentDate = Get-Date
$archiveFile = Join-Path $archivePath "iis-monitor_$($currentDate.ToString('yyyy-MM-dd_HHmm')).log.gz"

# Move current log to archive (implement compression)
Move-Item -Path $logPath -Destination $archiveFile -Force

# Create fresh log file
Write-Host "Log rotated to: $archiveFile"
```

---

## Expected Resource Usage

### Typical Daily Log Size
```
Check Interval: 60 seconds
Checks per day: 1,440
Average bytes per check: 200 bytes
Daily log size: ~300 KB

7-day log size: ~2.1 MB
30-day log size: ~9 MB
90-day log size: ~27 MB
```

### Memory & CPU Timeline
```
Startup:       15% CPU, 30 MB memory (initialization)
Idle (1-60s):  <1% CPU, 60 MB memory
Event capture:  8% CPU, 75 MB memory
Restart:       20% CPU, 80 MB memory (peak)
Back to idle:  <1% CPU, 65 MB memory
```

---

**Sample Output Version**: 1.0  
**Last Updated**: June 2026
