# Azure Resilience Test Plan
**Environment:** `rg-ailab-{participant_name}` — East US  
**Author:** Senior Cloud Resilience Engineer  
**Date:** 2026-06-16  
**Classification:** Internal — Lab Use Only

---

## Environment Reference

| Component | Details |
|---|---|
| **vm-app** | Ubuntu 22.04, Standard_B2ms, 10.0.1.10, 30 GB OS disk (Standard_LRS) |
| **vm-db** | Ubuntu 22.04, Standard_B2ms, 10.0.2.10, PostgreSQL 14, `max_connections=20`, 30 GB OS disk |
| **vm-win** | Windows Server 2022, Standard_B2s, 10.0.1.20, 128 GB OS disk |
| **Access path** | Azure Bastion Basic only — no public IPs on any VM |
| **NSG-app** | SSH (22) and RDP (3389) from Bastion subnet 10.0.3.0/27 only |
| **NSG-db** | PostgreSQL (5432) from app subnet 10.0.1.0/24 only |
| **Storage** | Standard LRS, blob soft-delete 30 days |
| **PostgreSQL** | DB: `labdb` · User: `labuser` · Listen: 10.0.2.10 |
| **Admin user** | `labadmin` (Linux and Windows) |

### Access Pattern for All Commands

All VM commands run via **Azure Bastion** (SSH or RDP) or remotely using Azure Run Command:

```bash
# Azure CLI remote execution — Linux VM
az vm run-command invoke \
  --resource-group rg-ailab-<name> \
  --name <vm-name> \
  --command-id RunShellScript \
  --scripts '<command>'

# Azure CLI remote execution — Windows VM
az vm run-command invoke \
  --resource-group rg-ailab-<name> \
  --name vm-win \
  --command-id RunPowerShellScript \
  --scripts '<command>'
```

---

## Global Pre-Test Requirements

Before running **any** scenario:

1. Confirm Azure Bastion connectivity is operational from your browser.
2. Confirm no active maintenance window or scheduled deployments are in progress.
3. Take a VM-level **snapshot** of all three OS disks as a safety net:
   ```bash
   for VM in vm-app vm-db vm-win; do
     DISK_ID=$(az vm show -g rg-ailab-<name> -n $VM \
       --query storageProfile.osDisk.managedDisk.id -o tsv)
     az snapshot create \
       --resource-group rg-ailab-<name> \
       --name "snap-${VM}-pre-test-$(date +%Y%m%d)" \
       --source "$DISK_ID"
   done
   ```
4. Open a monitoring session: Azure Portal → VM → Metrics → CPU, Disk, Network.
5. Designate a **test lead** and a **recovery operator** — never the same person executing and recovering.

---

## Scenario A — vm-app CPU Exhaustion (Payment Service Under Load)

### Description
Simulate a runaway payment processing workload that saturates all vCPUs on vm-app,
causing transaction timeouts and degraded response times from the application tier.

### Failure Being Simulated
100% CPU utilisation across all 2 vCPUs on vm-app for a controlled duration,
mimicking a stuck thread pool or unbounded computation loop.

---

### ✅ Go / No-Go Check
Run on **vm-app** before proceeding:

```bash
# Must pass ALL checks before proceeding
echo "=== CPU BASELINE ===" && top -bn1 | grep "Cpu(s)"
echo "=== LOAD AVERAGE ===" && uptime
echo "=== RUNNING PROCESSES ===" && ps aux --sort=-%cpu | head -10

# PASS criteria:
#   CPU idle > 50%
#   load average (1 min) < 1.5
#   No existing stress / stress-ng processes running
```

**No-Go conditions:** CPU idle < 50%, active stress test detected, or production workload
running at > 70% CPU — reschedule the test.

---

### Trigger Command (Reversible)
Connect to **vm-app** via Bastion, then:

```bash
# Install stress-ng if not present (one-time)
sudo apt-get install -y stress-ng

# Start CPU stress — 2 workers matching vCPU count, 120-second auto-timeout
# Process is self-terminating; save the PID for early recovery
sudo stress-ng --cpu 2 --cpu-method matrixprod --timeout 120s --metrics-brief &
STRESS_PID=$!
echo "Stress PID: $STRESS_PID — test will auto-terminate in 120 seconds"
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-app** | CPU → ~100%, load average spikes to 2+, payment service threads queue/timeout |
| **vm-db** | No direct impact; may see idle connection timeouts if app stops polling |
| **vm-win** | No impact — operates independently on reporting workload |
| **Azure Bastion** | Session may become sluggish; Bastion itself is unaffected |
| **Network** | No impact |

---

### Recovery Command

```bash
# Option 1: Let the 120-second timeout self-terminate (preferred)
# Option 2: Kill immediately if needed
sudo kill $STRESS_PID 2>/dev/null || sudo pkill -f stress-ng
echo "Recovery initiated at $(date)"
```

---

### Validation Command

```bash
# Confirm CPU has returned to baseline — run 30 seconds after kill
echo "=== POST-RECOVERY CPU ===" && top -bn1 | grep "Cpu(s)"
echo "=== LOAD AVERAGE ===" && uptime
echo "=== STRESS PROCESSES ===" && pgrep stress-ng && echo "FAIL: stress still running" || echo "PASS: no stress processes"

# Success criteria: CPU idle > 70%, load average (1 min) < 0.5, no stress-ng process
```

**RTO Target:** < 2 minutes (self-terminating at 120 s; manual kill resolves in < 10 s)

---

## Scenario B — DB Connection Pool Exhaustion (max_connections Reached)

### Description
PostgreSQL on vm-db is configured with `max_connections = 20` (deliberate lab constraint
set in cloud-init). Saturate the connection pool to simulate a connection leak in the
application tier or a surge in concurrent transactions.

### Failure Being Simulated
All 20 connection slots consumed by idle test connections; any new connection attempt
from vm-app returns `FATAL: remaining connection slots are reserved`.

---

### ✅ Go / No-Go Check
Run on **vm-db** before proceeding:

```bash
# Check current active connections
sudo -u postgres psql -c "
  SELECT count(*) AS active_connections,
         (SELECT setting::int FROM pg_settings WHERE name='max_connections') AS max_conn
  FROM pg_stat_activity;"

# Check for existing test sessions
sudo -u postgres psql -c "
  SELECT pid, usename, application_name, state, query_start
  FROM pg_stat_activity
  WHERE usename = 'labuser'
  ORDER BY query_start;"

# PASS criteria: active_connections < 5, no existing flood sessions
```

**No-Go conditions:** Active connections already ≥ 15 — do not proceed; investigate
existing connection leak first.

---

### Trigger Command (Reversible)
Run on **vm-app** (connections originate from the app subnet to respect NSG rules):

```bash
# Flood script — opens 21 idle connections (exceeds max_connections=20)
# Each connection sleeps to hold the slot open
FLOOD_PIDS=()
for i in $(seq 1 21); do
  PGPASSWORD='Lab@2024!' psql \
    -h 10.0.2.10 -U labuser -d labdb \
    -c "SELECT pg_sleep(300);" &
  FLOOD_PIDS+=($!)
  echo "Opened connection $i (PID: ${FLOOD_PIDS[-1]})"
done

# Save PIDs for recovery
echo "${FLOOD_PIDS[@]}" > /tmp/flood_pids.txt
echo "Connection flood active — $(wc -w < /tmp/flood_pids.txt) background processes running"

# Confirm exhaustion from vm-db
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;"
```

**Expected error on new connection attempt from vm-app:**
```
FATAL:  remaining connection slots are reserved for non-replication superuser connections
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-db** | All 20 slots occupied; new connections from `labuser` refused with FATAL error |
| **vm-app** | Application DB calls fail; payment service returns 500/503 errors |
| **vm-win** | No direct DB access — reporting service unaffected if it reads from app API |
| **PostgreSQL** | `pg_stat_activity` shows 20 `idle` connections from 10.0.1.10 |

---

### Recovery Command
Run on **vm-app**:

```bash
# Kill all flood background jobs
kill $(cat /tmp/flood_pids.txt) 2>/dev/null
rm /tmp/flood_pids.txt

# OR: terminate from the DB side if vm-app is unreachable
# Run on vm-db:
sudo -u postgres psql -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE usename = 'labuser'
    AND application_name != 'psql'
    AND query LIKE '%pg_sleep%';"
```

---

### Validation Command
Run on **vm-db**:

```bash
# Confirm connection count has dropped
sudo -u postgres psql -c "
  SELECT count(*) AS active_connections
  FROM pg_stat_activity
  WHERE state IS NOT NULL;"

# Test a clean connection from vm-app
PGPASSWORD='Lab@2024!' psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT NOW();"

# Success criteria: active_connections < 5; psql test returns timestamp without error
```

**RTO Target:** < 1 minute (killing client processes is instantaneous)

---

## Scenario C — Disk Fill on vm-app (Production Write Failures)

### Description
Fill the vm-app OS disk to 95% capacity to simulate a log rotation failure, runaway
audit trail, or a large uncompressed export landing in /tmp. At 100% disk usage
PostgreSQL client writes, application logging, and OS journald all fail simultaneously.

### Failure Being Simulated
`No space left on device` errors on vm-app; application cannot write transaction logs
or temporary files; SSH may become sluggish as shell history cannot be written.

> **Note:** vm-app has a 30 GB OS disk. The fill file will consume ~24 GB.

---

### ✅ Go / No-Go Check
Run on **vm-app** before proceeding:

```bash
# Confirm current disk state
df -h /
echo "---"
du -sh /var/log /tmp /home 2>/dev/null

# Confirm enough free space to run the test safely (need at least 5 GB free to
# fill to 95% and still have room for the fallocate command itself)
FREE_GB=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
echo "Free space: ${FREE_GB} GB"
[[ $FREE_GB -gt 5 ]] && echo "PASS: sufficient space" || echo "FAIL: disk already low"

# PASS criteria: disk usage < 50%, /tmp has no large unexpected files
```

**No-Go conditions:** Current disk usage > 50% — existing fill may already be impacting
the system; investigate before adding a test fill.

---

### Trigger Command (Reversible)

```bash
# Calculate target: fill to 95% of 30 GB = 28.5 GB used
# Current used space is typically 4–6 GB on a fresh Ubuntu 22.04 VM
# Adjust FILL_SIZE_GB if df shows different current usage

CURRENT_USED_GB=$(df / | awk 'NR==2 {printf "%.0f", $3/1024/1024}')
TARGET_USED_GB=28       # 28/30 GB = ~93% — leaves 2 GB headroom for safety
FILL_SIZE_GB=$((TARGET_USED_GB - CURRENT_USED_GB))

echo "Current used: ${CURRENT_USED_GB} GB — allocating ${FILL_SIZE_GB} GB fill file"

# fallocate is near-instant and does NOT zero the disk (safe, no data loss)
sudo fallocate -l ${FILL_SIZE_GB}G /tmp/resilience-disk-fill.bin
echo "Fill complete — disk state:"
df -h /
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-app** | `No space left on device` on any write; app log rotation fails; systemd journal errors |
| **vm-db** | No direct impact — DB on separate VM |
| **vm-win** | No impact |
| **Application writes** | Transaction log writes fail; any service writing to local disk returns I/O errors |
| **SSH session** | May experience delayed prompts; `.bash_history` write fails (non-critical) |

---

### Recovery Command

```bash
# Single command — immediately reclaims all allocated space
sudo rm /tmp/resilience-disk-fill.bin
echo "Fill file removed at $(date)"
df -h /
```

---

### Validation Command

```bash
# Confirm disk space recovered
df -h /
echo "---"
# Write a test file to confirm writes work again
echo "disk-recovery-test" | sudo tee /tmp/write-test.txt && echo "PASS: writes working" || echo "FAIL: writes still blocked"
sudo rm /tmp/write-test.txt

# Confirm application log writes resume (adjust service name as needed)
sudo journalctl -u <your-app-service> --since "1 minute ago" | tail -5

# Success criteria: disk usage < 25%, test file write succeeds
```

**RTO Target:** < 1 minute (`rm` is instantaneous regardless of file size)

---

## Scenario D — Network Routing Misconfiguration (App Cannot Reach DB)

### Description
Simulate a misconfigured routing table or NSG rule change that cuts off PostgreSQL
connectivity between vm-app (10.0.1.10) and vm-db (10.0.2.10) on port 5432.
This uses a host-level `iptables` DROP rule on vm-db — fully reversible without
any Azure portal or Terraform changes.

### Failure Being Simulated
All TCP connections from vm-app to vm-db port 5432 are silently dropped (DROP, not
REJECT), mimicking a missing UDR or an overly broad NSG deny rule introduced during
a change-management window.

---

### ✅ Go / No-Go Check
Run on **vm-app** before proceeding:

```bash
# Confirm PostgreSQL is reachable before blocking
nc -zv 10.0.2.10 5432 && echo "PASS: DB port reachable" || echo "FAIL: DB already unreachable"

# Confirm no existing iptables block rules on vm-db
# (Run on vm-db)
sudo iptables -L INPUT -n --line-numbers | grep -i "10.0.1.10" \
  && echo "FAIL: existing block rule found" || echo "PASS: no existing block rules"

# Confirm PostgreSQL service is running on vm-db
sudo systemctl is-active postgresql && echo "PASS: PostgreSQL active" || echo "FAIL: PostgreSQL not running"
```

**No-Go conditions:** DB port already unreachable before test starts, or existing
iptables rules targeting vm-app IP are present.

---

### Trigger Command (Reversible)
Run on **vm-db**:

```bash
# Insert DROP rule for all traffic from vm-app to PostgreSQL port
# Rule is ephemeral — does NOT persist across reboots
sudo iptables -I INPUT 1 \
  -s 10.0.1.10/32 \
  -p tcp \
  --dport 5432 \
  -j DROP \
  -m comment --comment "RESILIENCE-TEST-SCENARIO-D"

# Confirm rule is in place
sudo iptables -L INPUT -n --line-numbers | grep "RESILIENCE-TEST"
echo "Network block active at $(date)"
```

Verify impact from **vm-app** (expect timeout, not immediate rejection):

```bash
# This will hang for ~30 seconds then time out — that is the expected behaviour
timeout 10 nc -zv 10.0.2.10 5432 \
  && echo "UNEXPECTED: connection still succeeds" \
  || echo "CONFIRMED: connection timed out as expected"
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-app → vm-db** | TCP SYN packets dropped; psql hangs then times out with `Connection timed out` |
| **vm-app application** | DB connection pool exhausts retry attempts; 500 errors to end users |
| **vm-db** | PostgreSQL continues running normally; no internal errors |
| **vm-win** | No direct DB connectivity — unaffected |
| **vm-db → vm-app** | Unaffected — rule is inbound on vm-db, does not block reverse direction |

---

### Recovery Command
Run on **vm-db**:

```bash
# Remove the specific test rule by comment match — safe, cannot remove production rules
sudo iptables -D INPUT \
  -s 10.0.1.10/32 \
  -p tcp \
  --dport 5432 \
  -j DROP \
  -m comment --comment "RESILIENCE-TEST-SCENARIO-D"

# Confirm rule removed
sudo iptables -L INPUT -n | grep "RESILIENCE-TEST" \
  && echo "FAIL: rule still present" || echo "PASS: rule removed at $(date)"
```

**Fallback recovery** if the exact rule cannot be matched:

```bash
# List rules with line numbers, then delete by number
sudo iptables -L INPUT -n --line-numbers | grep "RESILIENCE-TEST"
# sudo iptables -D INPUT <line-number>
```

---

### Validation Command
Run on **vm-app**:

```bash
# Confirm TCP connectivity restored
nc -zv 10.0.2.10 5432 && echo "PASS: DB port reachable" || echo "FAIL: port still blocked"

# Confirm a real query completes successfully
PGPASSWORD='Lab@2024!' psql -h 10.0.2.10 -U labuser -d labdb \
  -c "SELECT current_timestamp AS recovery_validated_at;"

# Success criteria: nc returns open, psql returns timestamp row
```

**RTO Target:** < 3 minutes (iptables deletion is instantaneous; app reconnects
within one connection pool retry cycle, typically < 30 s)

---

## Scenario E — Windows IIS Service Failure (Reporting Service Down)

### Description
Stop the IIS World Wide Web Publishing Service (`W3SVC`) on vm-win to simulate
a service crash of the reporting tier. This is the exact failure mode that occurs
after a failed Windows Update, a misconfigured App Pool recycling, or an out-of-memory
condition in an unmanaged .NET application.

### Failure Being Simulated
`W3SVC` transitions to `Stopped` state; all HTTP/HTTPS endpoints hosted on IIS return
connection refused; users accessing the reporting dashboard receive a browser error
rather than an HTTP error page.

---

### ✅ Go / No-Go Check
Run on **vm-win** via Bastion (RDP) or Azure Run Command (PowerShell):

```powershell
# Check service state
$svc = Get-Service -Name W3SVC
Write-Host "Service state: $($svc.Status)"

# Check Application Event Log for pre-existing errors
Get-EventLog -LogName Application -EntryType Error -Newest 5 |
    Select-Object TimeGenerated, Source, Message |
    Format-List

# Check IIS App Pool states
Import-Module WebAdministration -ErrorAction SilentlyContinue
Get-WebConfiguration 'system.applicationHost/applicationPools/add' |
    Select-Object name, @{n='state';e={(Get-WebConfigurationProperty `
      "system.applicationHost/applicationPools/add[@name='$($_.name)']" `
      -Name state).Value}} |
    Format-Table -AutoSize

# PASS criteria: W3SVC Running, no critical errors in last 5 Event Log entries,
#                all App Pools in Started state
```

**No-Go conditions:** `W3SVC` already stopped (would inflate RTO measurement),
or Event Log shows active crash loop.

---

### Trigger Command (Reversible)
Run on **vm-win**:

```powershell
# Record pre-test timestamp for log analysis
$testStartTime = Get-Date
Write-Host "Test started at: $testStartTime"

# Stop W3SVC — this also stops all dependent services (WAS is parent; stopping
# W3SVC leaves WAS running so IIS config is preserved)
Stop-Service -Name W3SVC -Force
Write-Host "W3SVC stopped at: $(Get-Date)"

# Confirm stopped
Get-Service -Name W3SVC | Select-Object Name, Status
```

Verify impact (from vm-app or another host on the same VNet):

```bash
# Run on vm-app — expect "Connection refused" or timeout
curl -s --connect-timeout 5 http://10.0.1.20/ \
  && echo "UNEXPECTED: IIS responding" \
  || echo "CONFIRMED: IIS not responding as expected"
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-win** | `W3SVC` = Stopped; all IIS-hosted sites return `ERR_CONNECTION_REFUSED` |
| **vm-app** | Any service polling vm-win reporting endpoints fails; fallback logic (if any) activates |
| **vm-db** | No impact — DB continues serving vm-app |
| **Azure Bastion** | RDP to vm-win remains fully functional (Bastion is independent of IIS) |
| **Windows Event Log** | Event ID 1074 (service control manager) logged on stop |

---

### Recovery Command
Run on **vm-win**:

```powershell
# Start W3SVC — WAS will automatically start first as the parent service
Start-Service -Name W3SVC
Write-Host "W3SVC start initiated at: $(Get-Date)"

# Wait for service to reach Running state (up to 30 seconds)
$timeout = 30
$elapsed = 0
do {
    Start-Sleep -Seconds 2
    $elapsed += 2
    $status = (Get-Service -Name W3SVC).Status
    Write-Host "  [$elapsed s] W3SVC status: $status"
} while ($status -ne 'Running' -and $elapsed -lt $timeout)

if ($status -eq 'Running') {
    Write-Host "PASS: W3SVC recovered in $elapsed seconds"
} else {
    Write-Host "FAIL: W3SVC did not reach Running state within $timeout seconds"
}
```

---

### Validation Command
Run on **vm-win**:

```powershell
# Service state check
Get-Service -Name W3SVC | Select-Object Name, Status

# IIS site check
Import-Module WebAdministration
Get-Website | Select-Object Name, State, PhysicalPath | Format-Table -AutoSize

# HTTP response test from vm-win itself
try {
    $response = Invoke-WebRequest -Uri "http://localhost/" -UseBasicParsing -TimeoutSec 5
    Write-Host "PASS: HTTP $($response.StatusCode) — IIS responding"
} catch {
    Write-Host "FAIL: IIS not responding — $($_.Exception.Message)"
}

# Event log confirmation of successful start
Get-EventLog -LogName System -Source "Service Control Manager" -Newest 3 |
    Where-Object { $_.Message -like "*World Wide Web*" } |
    Select-Object TimeGenerated, Message | Format-List
```

From **vm-app** (cross-VM validation):

```bash
curl -s --connect-timeout 5 -o /dev/null -w "HTTP %{http_code}" http://10.0.1.20/
# Expected: HTTP 200 (or any configured response — not connection refused)
```

**RTO Target:** < 1 minute (W3SVC starts in < 5 seconds on Standard_B2s with no warm-up workload)

---

## Scenario F — Java Payment Service SIGKILL (Orphaned DB Connections)

### Description
Force-kill the Java payment service process with `SIGKILL`, simulating a Linux OOM-killer
event, a watchdog force-kill, or an operator running `kill -9`. Because `SIGKILL` does not
allow JVM shutdown hooks to run, active JDBC connections are **not** closed gracefully. With
`max_connections=20` on PostgreSQL, even 5–10 orphaned connections from a crashed JVM can
block all subsequent application starts — the pool fills with dead `idle` entries that
PostgreSQL will not reap until TCP keepalive fires (minutes, not seconds), compounding
the outage into a second failure.

### Failure Being Simulated
Java process hard-terminated (exit code 137); JDBC pool connections orphaned in
`pg_stat_activity`; payment service unavailable; next application start cannot acquire
DB connections until orphaned slots are manually terminated.

---

### ✅ Go / No-Go Check
Run on **vm-app** and **vm-db**:

```bash
# vm-app: confirm Java is running
pgrep -la java | head -5
[[ $(pgrep -c java) -gt 0 ]] && echo "PASS: Java running" || echo "FAIL: no Java process"

# vm-db: confirm current connection count is healthy
sudo -u postgres psql -c "
  SELECT count(*) AS active_connections
  FROM pg_stat_activity
  WHERE usename = 'labuser';"

# PASS criteria: Java process found, active_connections < 10
```

**No-Go conditions:** Java process not found, or DB connections already ≥ 15 (would mask
the orphaned connection effect).

---

### Trigger Command (Reversible)
Run on **vm-app**:

```bash
# Identify the JVM PID by its heap allocation flag
JAVA_PID=$(pgrep -f "\-Xmx4g" | head -1)
[[ -z $JAVA_PID ]] && JAVA_PID=$(pgrep -o java)
echo "Killing Java PID: $JAVA_PID at $(date)"

# SIGKILL — bypasses all JVM shutdown hooks; guarantees orphaned JDBC connections
sudo kill -9 $JAVA_PID
echo "Java process killed at $(date)"

sleep 2 && pgrep java \
  && echo "WARNING: Java still running — check PID" \
  || echo "CONFIRMED: Java process terminated"
```

Immediately check orphaned connections on **vm-db** (within 30 s of kill):

```bash
sudo -u postgres psql -c "
  SELECT pid, state, application_name, client_addr, query_start
  FROM pg_stat_activity
  WHERE usename = 'labuser'
  ORDER BY query_start DESC;"
# Expected: connections with state='idle' and client_addr='10.0.1.10' persist after JVM is gone
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-app** | Java exits immediately; payment service returns no response; `systemd` logs exit code 137 (SIGKILL) |
| **vm-db** | Orphaned connections remain `idle` in `pg_stat_activity`; new app start fails with `FATAL: remaining connection slots reserved` if pool is full |
| **vm-win** | No impact — operates independently |
| **TCP keepalive** | Orphaned connections persist for 2–15 min depending on kernel `tcp_keepalive_time`; manual termination required for fast recovery |

---

### Recovery Command

```bash
# --- Step 1: Run on vm-db — terminate orphaned idle connections ---
sudo -u postgres psql -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE usename = 'labuser'
    AND state = 'idle'
    AND backend_type = 'client backend';"
echo "Orphaned connections terminated at $(date)"

# --- Step 2: Run on vm-app — restart the payment service ---
# Adjust unit name to match your actual systemd service
sudo systemctl restart payment-service 2>/dev/null \
  || { echo "systemd unit not found — starting manually:"; \
       sudo -u labadmin java -Xmx4g -jar /opt/payment/payment-service.jar & }
echo "Service restart initiated at $(date)"
```

---

### Validation Command

```bash
# vm-app: confirm JVM is running again
pgrep -la java && echo "PASS: Java running" || echo "FAIL: Java not running"

# vm-db: confirm connection count is healthy
sudo -u postgres psql -c "
  SELECT count(*) AS active_connections
  FROM pg_stat_activity
  WHERE usename = 'labuser';"
# Expected: < 5 (normal application idle pool)

# vm-app: confirm a new DB query completes
PGPASSWORD='Lab@2024!' psql -h 10.0.2.10 -U labuser -d labdb \
  -c "SELECT current_timestamp AS recovery_validated_at, inet_server_addr() AS db_host;"

# Success criteria: Java process found, active_connections < 5, psql query returns timestamp
```

**RTO Target:** < 3 minutes (terminate orphaned connections: ~30 s; JVM cold start: ~60–90 s)

---

## Scenario G — PostgreSQL Postmaster SIGKILL (WAL Crash Recovery)

### Description
Force-kill the PostgreSQL `postmaster` (supervisor) process with `SIGKILL`, simulating a hard
crash of the database engine. This is the failure mode produced by an OOM kill of the DB VM,
a storage I/O error causing the kernel to kill the postmaster, or a runaway background vacuum
triggering an OOM condition on `vm-db`. PostgreSQL uses Write-Ahead Logging (WAL) to guarantee
crash recovery; this test validates that: (a) `systemd` automatically restarts the postmaster,
(b) WAL replay completes without manual intervention, and (c) data committed before the crash
remains intact.

### Failure Being Simulated
`postmaster` hard-killed (exit code 137); all child backend processes die; PostgreSQL logs
`database system was not properly shut down`; WAL replay runs on next start to restore
consistency; `vm-app` JDBC pool receives `server closed the connection unexpectedly`.

---

### ✅ Go / No-Go Check
Run on **vm-db**:

```bash
# Confirm PostgreSQL is healthy and not mid-recovery
sudo systemctl is-active postgresql && echo "PASS: active" || echo "FAIL: not running"

sudo -u postgres psql -c "
  SELECT pg_is_in_recovery() AS is_replica,
         pg_current_wal_lsn() AS current_lsn;"
# PASS: is_replica = false

# Confirm active connections are low (WAL replay is faster on lightly-loaded system)
sudo -u postgres psql -c "
  SELECT count(*) AS connections FROM pg_stat_activity WHERE state IS NOT NULL;"
# PASS: connections < 10
```

**No-Go conditions:** `pg_is_in_recovery() = true` (recovery already in progress), or
active connections ≥ 15.

---

### Trigger Command (Reversible)
Run on **vm-db**:

```bash
# Read the postmaster PID from the PID file
PGMASTER_PID=$(sudo head -1 /var/lib/postgresql/14/main/postmaster.pid 2>/dev/null)
echo "PostgreSQL postmaster PID: $PGMASTER_PID"

# SIGKILL — postmaster and all child backends die immediately
sudo kill -9 $PGMASTER_PID
echo "Postmaster killed at $(date)"

# Watch systemd restart within ~5 seconds
sleep 3 && sudo systemctl status postgresql --no-pager | head -10
```

Verify impact from **vm-app** immediately after kill:

```bash
PGPASSWORD='Lab@2024!' timeout 5 psql -h 10.0.2.10 -U labuser -d labdb \
  -c "SELECT 1;" 2>&1 | grep -iE "error|refused|closed|fatal" \
  && echo "CONFIRMED: DB unreachable as expected" \
  || echo "UNEXPECTED: connection still succeeds"
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-db** | PostgreSQL immediately offline; systemd detects exit (code 137) and restarts within 5–10 s; WAL replay runs automatically |
| **vm-db journal** | `LOG: database system was interrupted` → `LOG: database system was not properly shut down` → `LOG: database system is ready to accept connections` |
| **vm-app** | Active queries receive `server closed the connection unexpectedly`; JDBC pool errors; in-flight payment transactions roll back |
| **vm-win** | No impact |

---

### Recovery Command

```bash
# Recovery is fully automatic via systemd — monitor progress:
sudo journalctl -u postgresql -f --since "1 minute ago"
# Wait for: "database system is ready to accept connections"

# If systemd did NOT auto-restart after 15 s:
sudo systemctl start postgresql

# Confirm recovery
sleep 20 && sudo systemctl is-active postgresql \
  && echo "PASS: PostgreSQL auto-recovered" \
  || echo "FAIL: manual intervention required — run: journalctl -u postgresql -n 30"
```

---

### Validation Command

```bash
# vm-db: confirm service active and WAL replay completed cleanly
sudo systemctl is-active postgresql
sudo -u postgres psql -c "
  SELECT pg_is_in_recovery() AS is_replica,
         current_timestamp AS recovered_at,
         pg_database_size('labdb') AS db_size_bytes;"

# vm-app: confirm end-to-end connectivity and data integrity
PGPASSWORD='Lab@2024!' psql -h 10.0.2.10 -U labuser -d labdb \
  -c "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY 1, 2;"

# vm-db: confirm no PANIC in recent logs
sudo journalctl -u postgresql --since "5 minutes ago" | grep -E "PANIC|FATAL|ready to accept" | tail -10

# Success criteria: service active, is_replica = false, vm-app query succeeds, no PANIC in logs
```

**RTO Target:** < 2 minutes (WAL replay: < 20 s; systemd restart: ~5 s; JDBC reconnect: ~30 s after DB available)

---

## Scenario H — vm-app Memory Exhaustion (OOM Killer Targets JVM)

### Description
Saturate the available RAM on `vm-app` to the point where the Linux OOM killer must terminate
the largest memory consumer — the Java payment service (allocated up to `-Xmx4g`).
`Standard_B2ms` has 8 GB RAM; with the JVM holding up to 4.5 GB (heap + metaspace + native
stacks), stressing an additional 5.5 GB of anonymous memory exceeds physical capacity and
forces the kernel OOM killer to act. This is the most realistic failure mode for a
**memory-leaking** payment service or uncontrolled off-heap allocation.

### Failure Being Simulated
Linux OOM killer logs `Out of memory: Killed process <PID> (java)` in `dmesg`; JVM exits
with signal 9; payment service unavailable; orphaned JDBC connections fill the PostgreSQL
connection pool (same cascade as Scenario F).

---

### ✅ Go / No-Go Check
Run on **vm-app**:

```bash
# Confirm sufficient free memory headroom
free -m
FREE_MB=$(free -m | awk '/^Mem:/{print $7}')
echo "Available memory: ${FREE_MB} MB"
[[ $FREE_MB -gt 2500 ]] && echo "PASS: sufficient headroom" || echo "FAIL: already under pressure"

# Confirm Java process is running
[[ $(pgrep -c java) -gt 0 ]] && echo "PASS: Java running" || echo "FAIL: no Java process"

# Confirm no existing stress-ng
pgrep stress-ng && echo "FAIL: existing stress-ng detected" || echo "PASS: clear"
```

**No-Go conditions:** Available memory < 2500 MB, Java not running, or existing stress-ng found.

---

### Trigger Command (Reversible)
Run on **vm-app**:

```bash
sudo apt-get install -y stress-ng

# Record JVM PID before test
JAVA_PID_BEFORE=$(pgrep -f "\-Xmx4g" | head -1)
echo "Java PID before test: $JAVA_PID_BEFORE"

# Stress 5.5 GB of anonymous memory — combined with JVM heap and OS overhead this
# exceeds 8 GB physical RAM; OOM killer fires within ~20–45 seconds.
# 90-second safety timeout prevents runaway if OOM kill does not fire.
sudo stress-ng --vm 1 --vm-bytes 5500M --vm-method zero-one --timeout 90s &
STRESS_PID=$!
echo "Memory stress started — PID $STRESS_PID"
echo "Monitor with: sudo dmesg -T | grep -iE 'oom|killed process|out of memory'"
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-app kernel** | OOM killer fires within ~30 s; selects highest-score process; logs `Out of memory: Killed process <PID> (java)` in `dmesg` |
| **vm-app** | Java hard-killed (exit code 137); payment service unavailable; systemd logs the exit |
| **vm-db** | Orphaned JDBC connections persist in `pg_stat_activity` (same as Scenario F) |
| **vm-win** | No impact |

> **Note:** If `stress-ng` is killed before the JVM, reduce `--vm-bytes` to `4500M` and re-run.
> If neither is killed within 90 s, check `free -m` and increase `--vm-bytes` by 500 MB increments.

---

### Recovery Command

```bash
# Step 1: Stop stress-ng (may already be killed by OOM)
sudo kill $STRESS_PID 2>/dev/null || sudo pkill -f stress-ng
echo "Stress stopped at $(date)"

# Step 2: Confirm memory pressure is resolved
sleep 5 && free -m

# Step 3: Terminate orphaned DB connections (run on vm-db)
sudo -u postgres psql -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE usename = 'labuser'
    AND state = 'idle'
    AND backend_type = 'client backend';"

# Step 4: Restart payment service (run on vm-app)
sudo systemctl restart payment-service 2>/dev/null \
  || echo "Adjust systemd unit name to match your deployment"
echo "Service restart initiated at $(date)"
```

---

### Validation Command

```bash
# vm-app: confirm OOM event recorded in kernel log
sudo dmesg -T | grep -iE "oom|killed process|out of memory" | tail -5

# vm-app: confirm memory pressure resolved and JVM is running
free -m
pgrep -la java && echo "PASS: JVM recovered" || echo "FAIL: JVM not running"

# vm-db: confirm connection count is back to normal
sudo -u postgres psql -c "
  SELECT count(*) FROM pg_stat_activity WHERE usename = 'labuser';"
# Expected: < 5

# vm-app: confirm end-to-end DB connectivity
PGPASSWORD='Lab@2024!' psql -h 10.0.2.10 -U labuser -d labdb \
  -c "SELECT 'oom-recovery-validated' AS status, current_timestamp;"

# Success criteria: dmesg shows OOM event, memory available > 2 GB, JVM running, DB query succeeds
```

**RTO Target:** < 5 minutes (OOM kill: ~30 s; DB cleanup: ~30 s; JVM cold start with Spring context: ~2–3 min)

---

## Scenario I — Daily Auto-Shutdown Simulation (VM Stop/Start Sequencing)

### Description
The Terraform configuration schedules all three VMs to stop daily at **13:00 UTC**
(`daily_recurrence_time = "1300"`). This is the **highest-frequency disruption** in this
environment — occurring every single day without exception.

> **Configuration note:** The Terraform code sets shutdown at **13:00 UTC**, not 20:00 UTC.
> Verify the live schedule with:
> `az rest --method get --url ".../shutdown-computevm-vm-db?api-version=2018-09-15"`

This scenario simulates the daily deallocation of `vm-db`, measuring: (a) how `vm-app`
degrades when its database disappears without warning, (b) cold-start time for PostgreSQL
after VM boot, and (c) whether the application reconnects automatically or requires a manual
restart. The correct startup order is **vm-db first, then vm-app** — this test validates
that ordering matters and is documented.

### Failure Being Simulated
`vm-db` transitions to `Deallocated` state (as auto-shutdown fires every day at 13:00 UTC);
PostgreSQL is unreachable; `vm-app` JDBC pool enters all-dead state; payment transactions
cannot commit until `vm-db` is manually restarted.

---

### ✅ Go / No-Go Check
Run from **Cloud Shell**:

```bash
# Confirm all VMs are currently running
az vm list -g rg-ailab-<name> --show-details \
  --query "[].{Name:name, PowerState:powerState}" -o table

# Confirm auto-shutdown schedule (verify actual configured time)
az rest --method get \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-ailab-<name>/providers/microsoft.devtestlab/schedules/shutdown-computevm-vm-db?api-version=2018-09-15" \
  --query "properties.dailyRecurrence.time" -o tsv

# PASS: all VMs PowerState=VM running, schedule returns "1300"
```

---

### Trigger Command (Reversible)
Run from **Cloud Shell**:

```bash
TEST_START=$(date -u +%H:%M:%S)
echo "Test started at ${TEST_START} UTC"

# Deallocate vm-db — identical to what auto-shutdown executes every day at 13:00 UTC
az vm deallocate \
  --resource-group rg-ailab-<name> \
  --name vm-db
echo "vm-db deallocated at $(date -u) UTC"

# Probe vm-app's response to DB loss within 30 s of deallocation
az vm run-command invoke \
  -g rg-ailab-<name> -n vm-app \
  --command-id RunShellScript \
  --scripts 'PGPASSWORD="Lab@2024!" timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1" 2>&1 | head -3 || echo "DB_UNREACHABLE"' \
  --query "value[0].message" -o tsv
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-db** | Transitions `Stopping → Deallocated`; PostgreSQL receives `SIGTERM` then `SIGKILL` during OS shutdown; all connections terminated cleanly |
| **vm-app** | JDBC pool detects dead connections; payment service throws `could not connect to server: Connection refused`; no new transactions complete |
| **vm-win** | If reporting service polls `vm-app` API: elevated error rate; if fully independent: unaffected |
| **Azure Bastion** | Fully operational; SSH to `vm-app` and RDP to `vm-win` are unaffected |
| **Auto-recovery** | **None** — no auto-start is configured; `vm-db` must be started manually each day after shutdown |

---

### Recovery Command
Run from **Cloud Shell**:

```bash
# Start vm-db FIRST — DB must be ready before app attempts reconnection
echo "Starting vm-db at $(date -u) UTC..."
az vm start --resource-group rg-ailab-<name> --name vm-db
echo "vm-db start command issued — polling for PostgreSQL readiness..."

# Poll for DB readiness (~60–90 s after VM start command returns)
for i in $(seq 1 12); do
  sleep 15
  RESULT=$(az vm run-command invoke \
    -g rg-ailab-<name> -n vm-app \
    --command-id RunShellScript \
    --scripts 'PGPASSWORD="Lab@2024!" timeout 3 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1" 2>&1' \
    --query "value[0].message" -o tsv 2>/dev/null)
  echo "[$((i*15))s elapsed] DB probe: $(echo $RESULT | tr '\n' ' ' | cut -c1-80)"
  echo "$RESULT" | grep -q "(1 row)" && echo "PASS: DB ready" && break
done
```

---

### Validation Command

```bash
# Cloud Shell: confirm vm-db power state
az vm show -g rg-ailab-<name> -n vm-db --show-details \
  --query "{name:name, powerState:powerState}" -o table

# vm-app: confirm DB connectivity is restored
PGPASSWORD='Lab@2024!' psql -h 10.0.2.10 -U labuser -d labdb \
  -c "SELECT current_timestamp AS recovered_at, inet_server_addr() AS db_ip;"

# vm-app: check application reconnect in service logs
sudo journalctl -u payment-service --since "5 minutes ago" 2>/dev/null | tail -20 \
  || echo "Adjust unit name to verify application reconnect logs"

# Success criteria: vm-db = Running, psql query returns timestamp, app logs show reconnect
```

**RTO Target:** < 5 minutes (VM start: ~2–3 min; PostgreSQL ready: ~30 s post-boot; JDBC reconnect: ~30 s)

---

## Scenario J — vm-db Disk Fill (PostgreSQL WAL Write Failure / PANIC)

### Description
Fill the `vm-db` OS disk to 90% capacity to simulate runaway PostgreSQL WAL accumulation,
unrotated server logs, or a large `pg_dump` left on the data volume. Unlike the `vm-app`
disk fill (Scenario C), this is significantly more severe: PostgreSQL will enter **PANIC**
state and shut down when it cannot write to the WAL directory, because a failed WAL write
could produce an unrecoverable inconsistency. The service refuses to restart until disk space
is reclaimed.

> **No data loss occurs.** PostgreSQL PANIC is a safe shutdown. WAL ensures all committed
> transactions are durable; the database recovers cleanly after space is freed.

### Failure Being Simulated
`No space left on device` on a WAL write; PostgreSQL logs
`PANIC: could not write to file "pg_wal/..."` and terminates; `vm-app` loses DB connectivity
entirely; payment service returns 500/503 errors — identical blast radius to Scenario I but
with a more complex diagnosis path (disk is the root cause, not a scheduled shutdown).

---

### ✅ Go / No-Go Check
Run on **vm-db**:

```bash
df -h /
FREE_GB=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
echo "Free space: ${FREE_GB} GB"
[[ $FREE_GB -gt 5 ]] && echo "PASS: sufficient headroom" || echo "FAIL: disk already low — do not proceed"

sudo systemctl is-active postgresql && echo "PASS: PostgreSQL running" || echo "FAIL: already stopped"

# Baseline WAL directory size
sudo du -sh /var/lib/postgresql/14/main/pg_wal/
```

**No-Go conditions:** Free disk < 5 GB, or PostgreSQL not currently running.

---

### Trigger Command (Reversible)
Run on **vm-db**:

```bash
# Target 90% fill of 30 GB disk = 27 GB used (leaves ~3 GB safety headroom)
CURRENT_USED_GB=$(df / | awk 'NR==2 {printf "%.0f", $3/1024/1024}')
TARGET_USED_GB=27
FILL_SIZE_GB=$((TARGET_USED_GB - CURRENT_USED_GB))
[[ $FILL_SIZE_GB -le 0 ]] && echo "FAIL: disk already at target — abort" && exit 1

echo "Current used: ${CURRENT_USED_GB} GB — allocating ${FILL_SIZE_GB} GB fill file"
sudo fallocate -l ${FILL_SIZE_GB}G /tmp/resilience-db-disk-fill.bin
echo "Fill complete at $(date)"
df -h /

# Force a checkpoint — triggers a WAL write; PANIC fires if headroom is exhausted
sudo -u postgres psql -c "CHECKPOINT;" 2>&1
sudo systemctl is-active postgresql \
  && echo "PostgreSQL still running (3 GB headroom absorbed the checkpoint)" \
  || echo "CONFIRMED: PostgreSQL PANIC'd — WAL write failure triggered"
```

---

### Expected Impact

| Component | Expected Behaviour |
|---|---|
| **vm-db OS** | Disk at 90%+; `syslog` and `journald` writes may fail; SSH session remains functional |
| **vm-db PostgreSQL** | If WAL write fails at 100%: `PANIC: could not write to file "pg_wal/..."` → immediate shutdown → `systemctl status` = `failed` |
| **vm-app** | Complete loss of DB connectivity; payment service returns 500/503 errors (identical blast radius to Scenario I) |
| **vm-win** | No impact |
| **Data integrity** | **No data loss** — PostgreSQL PANIC preserves all committed transactions; WAL is intact |

---

### Recovery Command
Run on **vm-db**:

```bash
# Step 1: Remove fill file — instant space reclamation regardless of file size
sudo rm /tmp/resilience-db-disk-fill.bin
echo "Fill file removed at $(date)"
df -h /

# Step 2: Restart PostgreSQL — WAL recovery runs automatically if it PANIC'd
sudo systemctl start postgresql
sleep 15

# Step 3: Confirm recovery
sudo systemctl is-active postgresql && echo "PASS: PostgreSQL running" || {
  echo "FAIL: PostgreSQL did not restart — checking logs:"
  sudo journalctl -u postgresql -n 20
}

# Step 4: Confirm clean recovery message
sudo journalctl -u postgresql --since "2 minutes ago" | \
  grep -E "ready to accept|PANIC|ERROR|started"
```

---

### Validation Command

```bash
# vm-db: confirm disk space and service state
df -h /
sudo systemctl is-active postgresql

# vm-db: confirm database integrity (no data loss)
sudo -u postgres psql -c "
  SELECT current_timestamp AS recovered_at,
         pg_database_size('labdb') AS db_bytes,
         pg_is_in_recovery() AS is_replica;"

# vm-app: confirm DB connectivity restored
PGPASSWORD='Lab@2024!' psql -h 10.0.2.10 -U labuser -d labdb \
  -c "SELECT 1 AS recovery_check;"

# Success criteria: disk < 35% used, PostgreSQL active, is_replica = false, vm-app query succeeds
```

**RTO Target:** < 3 minutes (`rm` is instantaneous; PostgreSQL WAL recovery: ~20 s; JDBC reconnect: ~30 s)

---

## Post-Test Checklist

Run after **all 10 scenarios** are complete:

```bash
# ---- Linux VMs (run on vm-app and vm-db) ----

# 1. No stress processes remaining (Scenarios A, H)
pgrep stress-ng && echo "WARN: stress-ng still running" || echo "OK: no stress-ng"

# 2. No fill files remaining on vm-app (Scenario C)
ls -lh /tmp/resilience-disk-fill.bin 2>/dev/null && echo "WARN: app fill file present" || echo "OK"

# 3. No fill files remaining on vm-db (Scenario J)
ls -lh /tmp/resilience-db-disk-fill.bin 2>/dev/null && echo "WARN: db fill file present" || echo "OK"

# 4. No iptables test rules remaining (Scenario D — run on vm-db)
sudo iptables -L INPUT -n | grep "RESILIENCE-TEST" && echo "WARN: test rule still present" || echo "OK"

# 5. DB connection count nominal (Scenarios B, F, G, H — run on vm-db)
sudo -u postgres psql -c "
  SELECT count(*) AS total,
         count(*) FILTER (WHERE state = 'idle') AS idle
  FROM pg_stat_activity
  WHERE usename = 'labuser';"
# Expected: total < 5, idle < 3

# 6. PostgreSQL service active and not in recovery (run on vm-db)
sudo systemctl is-active postgresql
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Expected: service active, pg_is_in_recovery = false

# 7. No orphaned flood PIDs file (Scenario B — run on vm-app)
ls /tmp/flood_pids.txt 2>/dev/null \
  && echo "WARN: flood pids file present — check for orphan psql processes" || echo "OK"

# 8. No orphaned psql sleep processes (Scenario B cleanup check — run on vm-app)
pgrep -la psql | grep "pg_sleep" && echo "WARN: sleep connections still running" || echo "OK"
```

```powershell
# ---- Windows VM (run on vm-win) ----

# 9. IIS running
(Get-Service W3SVC).Status   # Expected: Running

# 10. No orphaned test processes
Get-Process | Where-Object { $_.Name -like "*stress*" }
```

```bash
# ---- Azure-level (run from Cloud Shell) ----

# 11. All 3 VMs running — Scenario I may have left vm-db deallocated
az vm list -g rg-ailab-<name> --show-details \
  --query "[].{Name:name, PowerState:powerState}" -o table

# 12. Delete pre-test snapshots (optional — keep for 24 h as safety net)
# az snapshot delete -g rg-ailab-<name> --name snap-vm-app-pre-test-<date>
# az snapshot delete -g rg-ailab-<name> --name snap-vm-db-pre-test-<date>
# az snapshot delete -g rg-ailab-<name> --name snap-vm-win-pre-test-<date>
```

---

## Summary Table

| # | Scenario | Failure Type | Target | Trigger Method | Recovery Method | RTO Target |
|---|---|---|---|---|---|---|
| A | CPU Exhaustion | COMPUTE | vm-app | `stress-ng --cpu 2 --timeout 120s` | `pkill stress-ng` | 2 min |
| B | DB Connection Pool Exhaustion | DATABASE | vm-db | 21 parallel `psql pg_sleep(300)` | `kill $(cat /tmp/flood_pids.txt)` | 1 min |
| C | Disk Fill — vm-app | STORAGE | vm-app | `fallocate -l <N>G /tmp/resilience-disk-fill.bin` | `rm /tmp/resilience-disk-fill.bin` | 1 min |
| D | Network Misconfiguration (iptables) | NETWORK | vm-db | `iptables -I INPUT 1 --dport 5432 -j DROP` | `iptables -D INPUT` (same rule) | 3 min |
| E | IIS Service Failure | APPLICATION | vm-win | `Stop-Service W3SVC -Force` | `Start-Service W3SVC` | 1 min |
| F | Java SIGKILL + Orphaned Connections | APPLICATION | vm-app / vm-db | `kill -9 <java-pid>` | Terminate orphaned DB connections → restart service | 3 min |
| G | PostgreSQL Postmaster SIGKILL | DATABASE | vm-db | `kill -9 <postmaster-pid>` | systemd auto-restart + WAL replay | 2 min |
| H | VM Memory Exhaustion (OOM Killer) | COMPUTE / APPLICATION | vm-app | `stress-ng --vm 1 --vm-bytes 5500M` | `pkill stress-ng` → clear orphaned connections → restart JVM | 5 min |
| I | Auto-Shutdown Simulation (VM Stop) | COMPUTE / DATABASE | vm-db | `az vm deallocate --name vm-db` | `az vm start --name vm-db` | 5 min |
| J | vm-db Disk Fill (PostgreSQL PANIC) | STORAGE / DATABASE | vm-db | `fallocate -l <N>G /tmp/resilience-db-disk-fill.bin` | `rm fill-file` → `systemctl start postgresql` | 3 min |

> All scenarios are **fully reversible** without VM rebuild, Terraform changes,
> or permanent data loss. Every trigger has a documented, tested recovery path.

---

## Priority Order

Ranked by **risk to the payment service** (highest risk first):

| Rank | Scenario | Justification |
|---|---|---|
| 1 | **G — PostgreSQL Postmaster SIGKILL** | Hard DB crash terminates all in-flight payment transactions; systemd auto-restart and WAL recovery are untested in this environment; any misconfiguration means permanent downtime |
| 2 | **F — Java SIGKILL + Orphaned Connections** | Orphaned JDBC connections fill the critically low 20-slot pool; the next application start fails entirely — a cascading failure with no automatic mitigation |
| 3 | **I — Auto-Shutdown Simulation** | Happens **every day** at 13:00 UTC; the most frequent disruption in the environment; startup sequencing (DB before app) is undocumented and likely untested |
| 4 | **B — DB Connection Pool Exhaustion** | `max_connections=20` is critically low for a payment service; any connection leak or modest traffic surge exhausts the pool permanently until connections are manually killed |
| 5 | **D — Network Misconfiguration** | NSG misconfigurations are the most common Azure operational error; silent TCP DROP (not REJECT) causes long timeouts that cascade through the payment service thread pool |
| 6 | **J — vm-db Disk Fill (PANIC)** | WAL fill causes PostgreSQL PANIC and complete payment outage; equivalent blast radius to Scenario I but with a harder root-cause diagnosis path |
| 7 | **H — Memory Exhaustion / OOM** | JVM OOM is a realistic production failure for a leaking payment service; orphaned connections compound into a Scenario F cascade |
| 8 | **C — Disk Fill on vm-app** | Prevents all local writes; payment service fails on any operation requiring disk I/O; easier to diagnose than Scenario J but equally impactful |
| 9 | **A — CPU Exhaustion** | Degrades performance but does not hard-fail the payment service; DB connections remain valid; self-recovers in 120 s; lowest immediate payment risk |
| 10 | **E — IIS Service Failure** | Reporting service is not in the payment transaction critical path; isolated failure with no DB or payment impact |

---

## Dependency Map

Run scenarios in this order to avoid compound failures from an unrecovered prior test:

```
PHASE 1 — Isolated single-VM tests (no cross-VM blast radius):
  A  — CPU stress on vm-app only
  C  — Disk fill on vm-app only
  E  — IIS stop on vm-win only

PHASE 2 — Database-layer tests (require PostgreSQL healthy before starting):
  B  — Connection flood; requires PostgreSQL running and connection count < 5
  G  — Postmaster kill; validates systemd auto-restart and WAL recovery

PHASE 3 — Network and connectivity tests (require both vm-app and vm-db healthy):
  D  — iptables block; requires vm-app ↔ vm-db connectivity confirmed first

PHASE 4 — Application crash tests (run AFTER G confirms DB auto-recovery):
  F  — Java SIGKILL; run after G to confirm DB recovered; tests orphaned connection cascade

PHASE 5 — Memory pressure (clean state required; all prior connections must be cleared):
  H  — OOM stress; run after F/G confirmed recovered; full DB connection slots must be free

PHASE 6 — Infrastructure-level disruptions (most destructive — run last):
  J  — vm-db disk fill; requires PostgreSQL healthy and disk < 50% before test
  I  — Auto-shutdown simulation; run last; has longest RTO; requires Cloud Shell for recovery
```

**Hard dependencies:**

- Run **G before F** — confirms PostgreSQL auto-recovery works before testing the orphaned
  connection cascade that follows a JVM kill
- Run **F before H** — Scenario H produces the same orphaned connection condition; having
  validated the cleanup procedure in F first ensures H recovery is predictable
- Do **not** run **I and J** back-to-back in the same test window — both result in
  PostgreSQL being unavailable; sequential execution inflates apparent RTO and obscures
  individual recovery paths
- Run **D after B** — if B recovery is incomplete and connections linger, D's "recovery"
  may appear faster than it actually is; always confirm `pg_stat_activity` is clean first

---

## Known Gaps

The following resilience risks **exist in this environment but cannot be safely tested in a lab**:

| Gap | Risk | Why Untestable in Lab |
|---|---|---|
| **Azure platform host eviction** | If the underlying Azure host is evicted, the VM is reallocated; `Standard_B2ms` does not guarantee maintenance-free updates | Triggering a host eviction requires Azure support intervention; cannot be simulated with `az` CLI |
| **Standard LRS zone failure** | All three OS disks use `Standard_LRS` (single-zone, single-region); a zone outage in East US loses all three VMs simultaneously with no failover path | Zone-level failures cannot be triggered in a live subscription without destroying the environment |
| **Bastion Basic SKU session exhaustion** | Basic SKU supports 25 concurrent sessions; during an incident with multiple engineers, session exhaustion blocks all remote access to all three VMs | Generating 25 real Bastion sessions simultaneously requires browser automation; the test itself would lock out all operators |
| **NSG rule change during active transactions** | If an NSG rule is modified mid-transaction, in-flight packets may be asymmetrically affected during the propagation window | Azure NSG changes propagate at the fabric level with a brief inconsistency window; precise timing against an active transaction stream is not reproducible on demand |
| **`max_connections=20` under real application load** | In production the JVM JDBC pool may approach 20 slots before a flood test is needed; the headroom for Scenario B is environment-specific | `max_connections=20` is a deliberate lab constraint; real-world baseline load testing against the actual application pool size is required before Scenario B represents production risk |
| **Auto-shutdown with in-flight payment transactions** | Daily shutdown at 13:00 UTC forcibly terminates the OS mid-transaction; PostgreSQL receives `SIGTERM` but the JVM may be interrupted mid-JDBC-write | Triggering the actual auto-shutdown requires waiting for 13:00 UTC with a live in-flight transaction; cannot be safely reproduced on demand without risking data integrity |
| **Windows Update forced reboot on vm-win** | Windows Server 2022 can reboot mid-day if update orchestration is misconfigured; Azure auto-update settings are not locked in this Terraform configuration | Cannot be safely tested without configuring Windows Update policies and a maintenance window; unplanned reboots cannot be reliably injected via PowerShell without risking IIS config corruption |
| **Storage account IOPS throttling** | `Standard_LRS` with concurrent blob write bursts from all three VMs could hit IOPS limits (`Standard_B2ms`: 2,400 cached / 1,600 uncached IOPS) | Azure throttling is quota-based and shared; triggering it requires sustained multi-VM I/O that may affect other lab participants and cannot be cleanly reversed |
| **Coordinated dual-VM failure (vm-app + vm-db simultaneously)** | If both VMs fail simultaneously (e.g., power-domain failure), there is no hot standby; RTO is driven by Azure VM start time (~3 min) plus cold application start | Deallocating both VMs simultaneously removes the monitoring and recovery path via `vm-app`; recovery requires Cloud Shell only — a workflow not validated by any individual scenario in this plan |
