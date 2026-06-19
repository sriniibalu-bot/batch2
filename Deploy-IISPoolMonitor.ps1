#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deployment and setup helper for IIS Pool Monitor script.

.DESCRIPTION
    Automates deployment, testing, and scheduled task configuration for IIS-PoolMonitor.ps1

.EXAMPLE
    .\Deploy-IISPoolMonitor.ps1

.NOTES
    Run as Administrator
#>

[CmdletBinding()]
param()

function Write-Section {
    param([string]$Title)
    Write-Host "`n" -NoNewline
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Message, [ValidateSet('OK', 'WARN', 'ERROR')]$Status = 'OK')
    $colors = @{
        'OK' = 'Green'
        'WARN' = 'Yellow'
        'ERROR' = 'Red'
    }
    Write-Host "[✓] $Message" -ForegroundColor $colors[$Status]
}

function Test-Prerequisites {
    Write-Section "CHECKING PREREQUISITES"
    
    # Check Administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Status "Running as Administrator" 'OK'
    }
    else {
        Write-Status "NOT running as Administrator" 'ERROR'
        return $false
    }
    
    # Check Windows Server 2022
    $osVersion = [System.Environment]::OSVersion.Version
    if ($osVersion.Major -ge 10 -and $osVersion.Build -ge 20348) {
        Write-Status "Windows Server 2022 (Build: $($osVersion.Build))" 'OK'
    }
    else {
        Write-Status "Windows Server 2022 not detected (Current: $osVersion)" 'WARN'
    }
    
    # Check IIS
    try {
        $iisFeature = Get-WindowsFeature -Name Web-Server -ErrorAction Stop
        if ($iisFeature.Installed) {
            Write-Status "IIS installed" 'OK'
        }
        else {
            Write-Status "IIS not installed" 'ERROR'
            return $false
        }
    }
    catch {
        Write-Status "Could not verify IIS installation" 'WARN'
    }
    
    # Check WebAdministration module
    try {
        Import-Module WebAdministration -ErrorAction Stop
        Write-Status "WebAdministration module available" 'OK'
    }
    catch {
        Write-Status "WebAdministration module not available - attempting import" 'WARN'
        try {
            Add-WindowsFeature -Name Web-Mgmt-Tools | Out-Null
            Import-Module WebAdministration -ErrorAction Stop
            Write-Status "WebAdministration module installed and imported" 'OK'
        }
        catch {
            Write-Status "Failed to install WebAdministration module: $_" 'ERROR'
            return $false
        }
    }
    
    return $true
}

function Create-Directories {
    Write-Section "CREATING DIRECTORIES"
    
    $directories = @{
        "C:\Scripts" = "Script location"
        "C:\Logs" = "Log file location"
    }
    
    foreach ($dir in $directories.GetEnumerator()) {
        if (Test-Path -Path $dir.Key) {
            Write-Status "$($dir.Key) - $($dir.Value) (exists)" 'OK'
        }
        else {
            try {
                New-Item -ItemType Directory -Path $dir.Key -Force | Out-Null
                Write-Status "$($dir.Key) - $($dir.Value) (created)" 'OK'
            }
            catch {
                Write-Status "$($dir.Key) - Failed to create: $_" 'ERROR'
            }
        }
    }
}

function Copy-MonitorScript {
    Write-Section "COPYING MONITOR SCRIPT"
    
    $sourceScript = ".\IIS-PoolMonitor.ps1"
    $targetScript = "C:\Scripts\IIS-PoolMonitor.ps1"
    
    if (-not (Test-Path -Path $sourceScript)) {
        Write-Status "Source script not found: $sourceScript" 'ERROR'
        return $false
    }
    
    try {
        Copy-Item -Path $sourceScript -Destination $targetScript -Force
        Write-Status "Script copied to $targetScript" 'OK'
        
        # Verify
        if (Test-Path -Path $targetScript) {
            Write-Status "Verification successful" 'OK'
            return $true
        }
    }
    catch {
        Write-Status "Failed to copy script: $_" 'ERROR'
        return $false
    }
    
    return $false
}

function Test-DryRun {
    Write-Section "TESTING SCRIPT (DRY-RUN MODE)"
    
    Write-Host "Starting dry-run test (will run for 3 checks)..." -ForegroundColor Yellow
    Write-Host "This will show what the script would do without making changes.`n" -ForegroundColor Yellow
    
    try {
        & "C:\Scripts\IIS-PoolMonitor.ps1" -DryRun -CheckInterval 5 -LogPath "C:\Logs\iis-monitor-dryrun.log" &
        $pid = $global:LASTEXITCODE
        
        Start-Sleep -Seconds 18  # Wait for 3 checks (5s + 5s + 5s + overhead)
        
        Write-Status "Dry-run completed" 'OK'
        
        # Show logs
        if (Test-Path -Path "C:\Logs\iis-monitor-dryrun.log") {
            Write-Host "`nLog output preview:" -ForegroundColor Cyan
            Get-Content -Path "C:\Logs\iis-monitor-dryrun.log" -Tail 10
            Write-Status "Log file created successfully" 'OK'
        }
        
        return $true
    }
    catch {
        Write-Status "Dry-run test failed: $_" 'ERROR'
        return $false
    }
}

function Setup-ScheduledTask {
    Write-Section "SETTING UP SCHEDULED TASK"
    
    Write-Host "Would you like to create a scheduled task to run the monitor automatically? (Y/N): " -ForegroundColor Yellow -NoNewline
    $response = Read-Host
    
    if ($response -ne 'Y' -and $response -ne 'y') {
        Write-Host "Scheduled task setup skipped." -ForegroundColor Yellow
        return $true
    }
    
    Write-Host "`nScheduled Task Configuration:`n" -ForegroundColor Cyan
    
    # Remove existing task if present
    if (Get-ScheduledTask -TaskName "IIS-PoolMonitor" -ErrorAction SilentlyContinue) {
        try {
            Unregister-ScheduledTask -TaskName "IIS-PoolMonitor" -Confirm:$false
            Write-Status "Previous task 'IIS-PoolMonitor' removed" 'OK'
        }
        catch {
            Write-Status "Could not remove previous task: $_" 'WARN'
        }
    }
    
    try {
        # Create task action
        $action = New-ScheduledTaskAction `
            -Execute 'PowerShell.exe' `
            -Argument '-NoProfile -ExecutionPolicy Bypass -NoExit -File C:\Scripts\IIS-PoolMonitor.ps1'
        
        # Create trigger (at startup)
        $trigger = New-ScheduledTaskTrigger -AtStartup
        
        # Create settings
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 5)
        
        # Register task (runs as SYSTEM with highest privileges)
        $task = Register-ScheduledTask `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -TaskName "IIS-PoolMonitor" `
            -Description "Monitors and automatically restarts stopped IIS application pools" `
            -RunLevel Highest `
            -Force
        
        Write-Status "Scheduled task 'IIS-PoolMonitor' created" 'OK'
        
        # Show task info
        Write-Host "`nTask Details:" -ForegroundColor Cyan
        Get-ScheduledTask -TaskName "IIS-PoolMonitor" | Select-Object TaskName, State, @{Name='Triggers';Expression={$_.Triggers -join ', '}}
        
        Write-Host "`nStart task now? (Y/N): " -ForegroundColor Yellow -NoNewline
        $startNow = Read-Host
        
        if ($startNow -eq 'Y' -or $startNow -eq 'y') {
            Start-ScheduledTask -TaskName "IIS-PoolMonitor"
            Write-Status "Scheduled task started" 'OK'
            Start-Sleep -Seconds 2
            Get-ScheduledTaskInfo -TaskName "IIS-PoolMonitor" | Select-Object TaskName, LastRunTime, LastTaskResult
        }
        
        return $true
    }
    catch {
        Write-Status "Failed to create scheduled task: $_" 'ERROR'
        return $false
    }
}

function Show-NextSteps {
    Write-Section "DEPLOYMENT COMPLETE - NEXT STEPS"
    
    Write-Host @"
1. VERIFY DEPLOYMENT
   • Check logs: Get-Content "C:\Logs\iis-monitor.log" -Wait
   • View current pools: Get-WebAppPool | Select Name, State

2. MONITOR SCRIPT EXECUTION
   • In Task Scheduler: Look for 'IIS-PoolMonitor' task
   • Check task history: Get-ScheduledTaskInfo -TaskName "IIS-PoolMonitor"

3. REVIEW LOGS
   • Primary log: C:\Logs\iis-monitor.log
   • Archive logs daily to maintain size
   • Search for [WARN] and [ERROR] entries for issues

4. CONFIGURE ALERTS (Optional)
   • Add email/Slack notifications to script
   • Set up Event Log forwarding
   • Configure dashboard monitoring

5. TEST POOL RESTART (Optional - Sandbox Only)
   • Manually stop a pool: Stop-WebAppPool -Name "PoolName"
   • Monitor script will detect and restart within 60 seconds
   • Check logs for confirmation

SUPPORT & TROUBLESHOOTING
   • Documentation: IIS-PoolMonitor-README.md
   • Quick Reference: IIS-PoolMonitor-QuickRef.md
   • Script Location: C:\Scripts\IIS-PoolMonitor.ps1
   • Log Location: C:\Logs\iis-monitor.log

USEFUL COMMANDS
   # Check task status
   Get-ScheduledTask -TaskName "IIS-PoolMonitor" | Select TaskName, State

   # View task execution history
   Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational `
     -FilterXPath "*[EventData[Data[@Name='TaskName']='/IIS-PoolMonitor']]" `
     | Select-Object TimeCreated, Message

   # Watch logs in real-time
   Get-Content "C:\Logs\iis-monitor.log" -Wait

   # Check all pool states
   Get-WebAppPool | Select Name, State, AutoStart
"@

    Write-Host "=" * 60 -ForegroundColor Cyan
}

function Main {
    Write-Host "
    ╔════════════════════════════════════════════════════════════╗
    ║     IIS POOL MONITOR - DEPLOYMENT HELPER v1.0             ║
    ║     Windows Server 2022 Automation                        ║
    ╚════════════════════════════════════════════════════════════╝
    " -ForegroundColor Cyan
    
    # Run all setup steps
    if (-not (Test-Prerequisites)) {
        Write-Host "`nDeployment aborted due to missing prerequisites." -ForegroundColor Red
        exit 1
    }
    
    Create-Directories
    
    if (-not (Copy-MonitorScript)) {
        Write-Host "`nDeployment aborted - could not copy script." -ForegroundColor Red
        exit 1
    }
    
    # Optional: Run test
    Write-Host "`nRun dry-run test? (Y/N): " -ForegroundColor Yellow -NoNewline
    $runTest = Read-Host
    if ($runTest -eq 'Y' -or $runTest -eq 'y') {
        Test-DryRun
    }
    
    # Optional: Setup scheduled task
    Setup-ScheduledTask
    
    # Show completion info
    Show-NextSteps
    
    Write-Host "`n✓ Deployment helper script finished!" -ForegroundColor Green
}

# Execute
Main
