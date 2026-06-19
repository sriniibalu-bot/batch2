# IIS Pool Monitor - Quick Reference

## 🚀 Quick Start Commands

### Test Mode (No Changes)
```powershell
.\IIS-PoolMonitor.ps1 -DryRun
```

### Production Mode (Auto-Restart)
```powershell
.\IIS-PoolMonitor.ps1
```

### Watch Logs in Real-Time
```powershell
Get-Content "C:\Logs\iis-monitor.log" -Wait
```

### Check Current Pool States
```powershell
Get-WebAppPool | Select Name, State, AutoStart
```

## 🛠️ Common Parameter Combinations

| Task | Command |
|------|---------|
| Quick test (30s check interval) | `.\IIS-PoolMonitor.ps1 -DryRun -CheckInterval 30` |
| Slow monitoring (2 min interval) | `.\IIS-PoolMonitor.ps1 -CheckInterval 120` |
| Custom log location | `.\IIS-PoolMonitor.ps1 -LogPath "D:\Logs\iis.log"` |
| All options | `.\IIS-PoolMonitor.ps1 -DryRun -CheckInterval 30 -LogPath "C:\Logs\test.log"` |

## 📋 Log File Examples

### Pool Restart Success
```
2026-06-12 14:31:46.123 [WARN] Stopped pool detected: 'DefaultAppPool'
2026-06-12 14:31:46.234 [INFO] Captured 2 error event(s) for pool 'DefaultAppPool'
2026-06-12 14:31:46.345 [SUCCESS] Successfully restarted pool 'DefaultAppPool'
```

### Dry-Run Mode
```
2026-06-12 14:32:00.123 [INFO] DryRun Mode: True
2026-06-12 14:32:30.456 [WARN] Stopped pool detected: 'AppPool_API'
2026-06-12 14:32:30.567 [INFO] [DRY-RUN] Would restart pool 'AppPool_API'
```

### Idempotency Check (Pool Already Running)
```
2026-06-12 14:33:00.123 [INFO] Pool 'DefaultAppPool' is already running. No restart needed.
```

## ✅ Pre-Deployment Checklist

- [ ] Running as Administrator
- [ ] Windows Server 2022+
- [ ] IIS installed with WebAdministration module
- [ ] C:\Logs directory exists (or script creates it)
- [ ] Script location: C:\Scripts\IIS-PoolMonitor.ps1
- [ ] Tested in DryRun mode first
- [ ] Reviewed log output
- [ ] Scheduled task configured (if needed)

## 🔧 Troubleshooting Quick Fixes

### Script won't run
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

### Missing WebAdministration module
```powershell
Import-Module WebAdministration -ErrorAction Stop
```

### Check if IIS service is running
```powershell
Get-Service W3SVC, WAS | Select Name, Status
```

### View recent errors in logs
```powershell
Get-Content "C:\Logs\iis-monitor.log" | Where-Object { $_ -match "ERROR|WARN" }
```

### Clear old log file
```powershell
Remove-Item "C:\Logs\iis-monitor.log" -Force
```

## 📊 Log File Locations & Sizes

| File | Location | Typical Size |
|------|----------|--------------|
| Script Logs | C:\Logs\iis-monitor.log | 1-5 MB (7 days of monitoring) |
| System Events | Event Viewer > System | Auto-managed |
| Application Events | Event Viewer > Application | Auto-managed |
| IIS Access Logs | %SystemRoot%\System32\LogFiles\HTTP | Auto-managed |

## 🔄 Rollback Reference

### Manual Rollback (Advanced)
If script is running and you want to stop with rollback:
1. Press **Ctrl+C** in the PowerShell window
2. Answer **Y** at the prompt to restore pool states

### Manual Pool State Restore
```powershell
# Start all stopped pools
Get-WebAppPool | Where-Object { $_.State -eq 'Stopped' } | Start-WebAppPool

# Stop all running pools (if needed)
Get-WebAppPool | Where-Object { $_.State -eq 'Started' } | Stop-WebAppPool
```

## 📈 Monitoring Best Practices

1. **Test First**: Always run with `-DryRun` before production
2. **Check Logs**: Review log file before first production run
3. **Monitor Metrics**: Watch for restart frequency patterns
4. **Set Alerts**: Configure Task Scheduler to notify on high restart counts
5. **Review Events**: Regularly check Windows Event Log for root causes
6. **Adjust Intervals**: Tune CheckInterval based on your environment

## 🎯 Event Levels Explained

| Level | Meaning | Action |
|-------|---------|--------|
| INFO | Normal operation | Monitor for patterns |
| WARN | Stopped pool/rollback | Investigate root cause |
| ERROR | Operation failure | Check configuration |
| SUCCESS | Pool restarted | Log entry confirms success |

## 💾 Typical Log Output (1 Hour)

With 60-second check interval over 1 hour:
- 60 check headers (1 per minute)
- 0-5 pool status changes (depends on stability)
- 0-20 event log entries (only if pools stopped)
- ~2-5 KB log file size

## 🔐 Security Reminders

- Run as Administrator (enforced by script)
- Keep C:\Logs readable by admins only
- Store script in protected directory (C:\Scripts)
- Review logs regularly for unusual patterns
- Use scheduled task with specific service account for consistency

## 📞 Key Contacts & Resources

| Item | Location |
|------|----------|
| IIS Manager | `inetmgr` (command) or Server Manager |
| Event Viewer | `eventvwr.msc` (command) |
| Services | `services.msc` (command) |
| Task Scheduler | `taskschd.msc` (command) |
| PowerShell Help | `Get-Help Get-WebAppPool -Full` |

## ⏱️ Common Interval Settings

| Use Case | Interval | Reason |
|----------|----------|--------|
| Development | 30-60s | Quick detection |
| Production (Stable) | 5 minutes | Balance monitoring/overhead |
| Production (High-Traffic) | 2-3 minutes | Frequent restarts |
| Low-Resource Systems | 10-15 minutes | Reduce I/O |

---
**Version**: 1.0 | **Last Updated**: June 2026
