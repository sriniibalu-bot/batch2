#Requires -RunAsAdministrator
#Requires -Modules WebAdministration
<#
.SYNOPSIS
    Monitors IIS application pools and automatically restarts stopped pools.

.DESCRIPTION
    This script monitors all IIS application pools every 60 seconds. When a pool is detected
    as Stopped, it captures relevant Windows Event Log errors from the last 10 minutes,
    optionally restarts the pool (based on -DryRun switch), and logs all actions with timestamps.
    
    Supports rollback to restore original pool states and clean exit on Ctrl+C.

.PARAMETER DryRun
    If specified, shows what would be done without actually restarting pools.

.PARAMETER LogPath
    Path to the log file. Default: C:\Logs\iis-monitor.log

.PARAMETER CheckInterval
    Interval in seconds between pool state checks. Default: 60

.EXAMPLE
    # Run in monitoring mode (will restart stopped pools)
    .\IIS-PoolMonitor.ps1

.EXAMPLE
    # Run in dry-run mode (shows actions without restarting)
    .\IIS-PoolMonitor.ps1 -DryRun

.EXAMPLE
    # Run with custom log path and check interval
    .\IIS-PoolMonitor.ps1 -LogPath "C:\CustomLogs\iis.log" -CheckInterval 30

.NOTES
    Author: Windows Server Automation
    Requires: Administrator privileges, WebAdministration module, Windows Server 2022
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$LogPath = "C:\Logs\iis-monitor.log",
    [int]$CheckInterval = 60
)

#region Global Variables
$script:OriginalPoolStates = @{}
$script:MonitoringActive = $true
$script:ScriptStart = Get-Date
$script:PoolStateHistory = @{}
#endregion

#region Module Import
try {
    Import-Module WebAdministration -ErrorAction Stop | Out-Null
}
catch {
    Write-Error "WebAdministration module not available: $_"
    exit 1
}
#endregion

#region Helper Functions

function Initialize-Logging {
    <#
    .SYNOPSIS
        Initializes the logging system and verifies log directory exists.
    #>
    [CmdletBinding()]
    param()
    
    $logDir = Split-Path -Path $LogPath -Parent
    
    if (-not (Test-Path -Path $logDir)) {
        try {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            Write-Verbose "Created log directory: $logDir"
        }
        catch {
            Write-Error "Failed to create log directory '$logDir': $_"
            exit 1
        }
    }
    
    # Create or verify log file is writable
    try {
        Add-Content -Path $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [INIT] IIS Pool Monitor started" -ErrorAction Stop
    }
    catch {
        Write-Error "Log file '$LogPath' is not writable: $_"
        exit 1
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes timestamped log entries to the log file and console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logEntry = "$timestamp [$Level] $Message"
    
    try {
        Add-Content -Path $LogPath -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Information -MessageData "Failed to write to log: $_" -InformationAction Continue
    }
    
    # Console output with color coding
    switch ($Level) {
        'ERROR' { Write-Information -MessageData $logEntry -InformationAction Continue }
        'WARN' { Write-Information -MessageData $logEntry -InformationAction Continue }
        'SUCCESS' { Write-Information -MessageData $logEntry -InformationAction Continue }
        default { Write-Information -MessageData $logEntry -InformationAction Continue }
    }
}

function Get-AppPoolState {
    <#
    .SYNOPSIS
        Retrieves current state of all IIS application pools.
    #>
    [CmdletBinding()]
    param()
    
    try {
        $pools = @()
        Get-WebAppPool | ForEach-Object {
            $pools += @{
                Name = $_.Name
                State = $_.State
                AutoStart = $_.AutoStart
            }
        }
        return $pools
    }
    catch {
        Write-Log -Message "Failed to retrieve application pool states: $_" -Level ERROR
        return @()
    }
}

function Get-EventLogError {
    <#
    .SYNOPSIS
        Captures Windows Event Log errors related to IIS from the last N minutes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PoolName,
        
        [int]$MinutesBack = 10
    )
    
    try {
        $startTime = (Get-Date).AddMinutes(-$MinutesBack)
        $events = @()
        
        # Check System log for IIS-related errors
        $systemEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Level = 2  # Error level
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -match 'IIS|Application Pool|W3SVC' -or
            $_.Message -match [regex]::Escape($PoolName)
        }
        
        if ($systemEvents) {
            $events += $systemEvents
        }
        
        # Check Application log for IIS/ASP.NET errors
        $appEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            Level = 2  # Error level
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.ProviderName -match 'IIS|ASP.NET|WebHost' -or
            $_.Message -match [regex]::Escape($PoolName)
        }
        
        if ($appEvents) {
            $events += $appEvents
        }
        
        return $events | Sort-Object -Property TimeCreated -Descending | Select-Object -First 10
    }
    catch {
        Write-Log -Message "Failed to retrieve event log for pool '$PoolName': $_" -Level WARN
        return @()
    }
}

function Test-PoolIsRunning {
    <#
    .SYNOPSIS
        Idempotency check: verifies if a pool is actually running.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PoolName
    )
    
    try {
        $pool = Get-WebAppPool -Name $PoolName -ErrorAction Stop
        return $pool.State -eq 'Started'
    }
    catch {
        Write-Log -Message "Failed to check pool state for '$PoolName': $_" -Level ERROR
        return $false
    }
}

function Restart-AppPool {
    <#
    .SYNOPSIS
        Restarts a stopped IIS application pool with error handling.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PoolName
    )
    
    try {
        # Idempotency check
        if (Test-PoolIsRunning -PoolName $PoolName) {
            Write-Log -Message "Pool '$PoolName' is already running. No restart needed." -Level INFO
            return $true
        }
        
        # In DryRun mode, don't actually restart
        if ($DryRun) {
            Write-Log -Message "[DRY-RUN] Would restart pool '$PoolName'" -Level INFO
            return $true
        }
        
        # Check ShouldProcess before actually restarting
        if ($PSCmdlet.ShouldProcess($PoolName, 'Start application pool')) {
            # Perform restart
            Write-Log -Message "Attempting to restart pool '$PoolName'..." -Level INFO
            Start-WebAppPool -Name $PoolName -ErrorAction Stop
        }
        else {
            Write-Log -Message "Pool '$PoolName' restart skipped by user (WhatIf)" -Level INFO
            return $true
        }
        
        # Verify restart was successful
        Start-Sleep -Seconds 2
        
        if (Test-PoolIsRunning -PoolName $PoolName) {
            Write-Log -Message "Successfully restarted pool '$PoolName'" -Level SUCCESS
            return $true
        }
        else {
            Write-Log -Message "Pool '$PoolName' restart verification failed - pool still not running" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log -Message "Failed to restart pool '$PoolName': $_" -Level ERROR
        return $false
    }
}

function Save-InitialPoolState {
    <#
    .SYNOPSIS
        Saves the initial state of all pools for rollback capability.
    #>
    [CmdletBinding()]
    param()
    
    try {
        Get-WebAppPool | ForEach-Object {
            $script:OriginalPoolStates[$_.Name] = @{
                State = $_.State
                AutoStart = $_.AutoStart
            }
        }
        Write-Log -Message "Saved initial state of $($script:OriginalPoolStates.Count) application pools" -Level INFO
    }
    catch {
        Write-Log -Message "Failed to save initial pool states: $_" -Level ERROR
    }
}

function Invoke-Rollback {
    <#
    .SYNOPSIS
        Stops monitoring and restores application pools to their initial state.
    #>
    [CmdletBinding()]
    param()
    
    Write-Log -Message "===== ROLLBACK INITIATED =====" -Level WARN
    $script:MonitoringActive = $false
    
    if ($script:OriginalPoolStates.Count -eq 0) {
        Write-Log -Message "No saved pool states for rollback" -Level WARN
        return
    }
    
    foreach ($poolName in $script:OriginalPoolStates.Keys) {
        try {
            $originalState = $script:OriginalPoolStates[$poolName]
            $currentPool = Get-WebAppPool -Name $poolName -ErrorAction Stop
            
            if ($currentPool.State -ne $originalState.State -and $originalState.State -eq 'Started') {
                Write-Log -Message "Rolling back pool '$poolName' to Started state" -Level INFO
                Start-WebAppPool -Name $poolName -ErrorAction Stop
            }
            elseif ($currentPool.State -ne $originalState.State -and $originalState.State -eq 'Stopped') {
                Write-Log -Message "Rolling back pool '$poolName' to Stopped state" -Level INFO
                Stop-WebAppPool -Name $poolName -ErrorAction Stop
            }
        }
        catch {
            Write-Log -Message "Rollback failed for pool '$poolName': $_" -Level ERROR
        }
    }
    
    Write-Log -Message "===== ROLLBACK COMPLETED =====" -Level WARN
}

function Invoke-PoolStateMonitoring {
    <#
    .SYNOPSIS
        Main monitoring loop that checks pool states and handles restarts.
    #>
    [CmdletBinding()]
    param()
    
    $checkCount = 0
    
    while ($script:MonitoringActive) {
        try {
            $checkCount++
            $checkTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Write-Log -Message "=== Check #$checkCount ($checkTime) ===" -Level INFO
            
            $pools = Get-AppPoolState
            
            if ($pools.Count -eq 0) {
                Write-Log -Message "No application pools found or error retrieving pools" -Level WARN
                Start-Sleep -Seconds $CheckInterval
                continue
            }
            
            $stoppedPools = $pools | Where-Object { $_.State -eq 'Stopped' }
            
            if ($stoppedPools.Count -gt 0) {
                Write-Log -Message "Found $($stoppedPools.Count) stopped pool(s)" -Level WARN
                
                foreach ($pool in $stoppedPools) {
                    Write-Log -Message "Stopped pool detected: '$($pool.Name)'" -Level WARN
                    
                    # Capture event log errors
                    $events = Get-EventLogError -PoolName $pool.Name -MinutesBack 10
                    
                    if ($events.Count -gt 0) {
                        Write-Log -Message "Captured $($events.Count) error event(s) for pool '$($pool.Name)'" -Level INFO
                        
                        foreach ($logEvent in $events) {
                            $eventMsg = "Event ID: $($logEvent.Id) | Provider: $($logEvent.ProviderName) | Message: $($logEvent.Message -replace '\s+', ' ' | Limit-StringLength -MaxLength 100)"
                            Write-Log -Message $eventMsg -Level INFO
                        }
                    }
                    else {
                        Write-Log -Message "No recent error events found for pool '$($pool.Name)'" -Level INFO
                    }
                    
                    # Attempt restart
                    Restart-AppPool -PoolName $pool.Name
                }
            }
            else {
                Write-Log -Message "All $($pools.Count) pools are running normally" -Level INFO
            }
            
            # Wait for next check interval
            Write-Log -Message "Next check in $CheckInterval seconds..." -Level INFO
            Start-Sleep -Seconds $CheckInterval
        }
        catch {
            Write-Log -Message "Error in monitoring loop: $_" -Level ERROR
            Start-Sleep -Seconds $CheckInterval
        }
    }
}

function Limit-StringLength {
    <#
    .SYNOPSIS
        Limits a string to a maximum length.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [string]$InputString,
        
        [int]$MaxLength = 100
    )
    
    process {
        if ($InputString.Length -gt $MaxLength) {
            return "$($InputString.Substring(0, $MaxLength))..."
        }
        return $InputString
    }
}

#endregion

#region Script Initialization

# Verify running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Verify WebAdministration module
# (Module is already imported in the Module Import region above)

# Initialize logging
Initialize-Logging

# Display startup information
Write-Log -Message "========================================" -Level INFO
Write-Log -Message "IIS Application Pool Monitor Started" -Level INFO
Write-Log -Message "DryRun Mode: $DryRun" -Level INFO
Write-Log -Message "Check Interval: $CheckInterval seconds" -Level INFO
Write-Log -Message "Log Path: $LogPath" -Level INFO
Write-Log -Message "========================================" -Level INFO

# Save initial pool states for rollback
Save-InitialPoolState

#endregion

#region Cleanup and Exit Handlers

# Register cleanup on normal exit
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-Log -Message "Received exit signal (Ctrl+C or script termination)" -Level WARN
    
    # Optional: Perform rollback on exit
    # Uncomment the line below if you want automatic rollback on script exit
    # Invoke-Rollback
    
    Write-Log -Message "IIS Pool Monitor stopped" -Level INFO
    Write-Log -Message "========================================" -Level INFO
}

# Trap for Ctrl+C - allows clean exit with rollback option
trap {
    Write-Log -Message "Script interrupted by user" -Level WARN
    $script:MonitoringActive = $false
    
    # Prompt user for rollback
    Write-Information -MessageData "`n`nWould you like to rollback pool states to their initial state? (Y/N): " -InformationAction Continue -NoNewline
    $response = Read-Host
    
    if ($response -eq 'Y' -or $response -eq 'y') {
        Invoke-Rollback
    }
    else {
        Write-Log -Message "Rollback skipped by user. Pools remain in current state." -Level INFO
    }
    
    Write-Log -Message "IIS Pool Monitor stopped" -Level INFO
    Write-Log -Message "========================================" -Level INFO
    exit 0
}

#endregion

#region Main Execution

try {
    # Start monitoring
    Invoke-PoolStateMonitoring
}
catch {
    Write-Log -Message "Fatal error in main execution: $_" -Level ERROR
    exit 1
}

#endregion
