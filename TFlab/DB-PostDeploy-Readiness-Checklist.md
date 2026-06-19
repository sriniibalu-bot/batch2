# Post-Deployment Readiness Checklist — Database Engineer
**Environment:** rg-ailab-{participant_name} | eastus  
**Infrastructure:** Terraform (TFlab) | Validated:** 2026-06-15  
**Access path:** Azure Bastion Basic only — all checks via Bastion tunnel or az CLI

---

## Environment Summary (from Terraform)

| Resource | Detail |
|---|---|
| vm-app | Ubuntu 22.04, Standard_B2ms, 10.0.1.10, snet-app |
| vm-db | Ubuntu 22.04, Standard_B2ms, 10.0.2.10, snet-db, PostgreSQL 14 |
| vm-win | Windows Server 2022, Standard_B2s, 10.0.1.20, snet-app |
| Bastion | Basic SKU, AzureBastionSubnet 10.0.3.0/27 |
| NSG-db | Port 5432 from 10.0.1.0/24 only |
| NSG-app | SSH/RDP from 10.0.3.0/27 only |
| Storage | Standard LRS, soft-delete 30 days |
| Auto-shutdown | 13:00 UTC daily on all VMs |

---

## CHECK 01 — No Public IPs on VMs
**Category:** SECURITY  
**Check:** Confirm zero public IP addresses are attached to any VM NIC.

```bash
# az CLI
RG="rg-ailab-$(terraform output -raw resource_group | cut -d- -f3)"
az network public-ip list --resource-group $RG \
  --query "[?name!='pip-bastion'].{Name:name,IP:ipAddress,Attached:ipConfiguration.id}" \
  --output table
```

**Expected:** Only `pip-bastion` appears. No NIC-attached public IPs returned.  
**DB Note:** A public IP on vm-db would expose port 5432 to the internet — the single highest-risk misconfiguration for a database VM. Verify before any other check.

---

## CHECK 02 — NSG Denies Direct Internet to Port 5432
**Category:** SECURITY  
**Check:** Confirm nsg-db has no rule permitting inbound 5432 from source `*` or `Internet`.

```bash
az network nsg rule list \
  --resource-group $RG \
  --nsg-name nsg-db \
  --query "[?destinationPortRange=='5432' || contains(destinationPortRanges,'5432')].{Name:name,Source:sourceAddressPrefix,Access:access}" \
  --output table
```

**Expected:** Only one rule returned: `AllowPostgres`, source `10.0.1.0/24`, access `Allow`. No wildcard or Internet source present.  
**DB Note:** PostgreSQL must never be reachable from the public internet. This validates the Terraform `nsg-db` rule that restricts port 5432 to the app subnet only.

---

## CHECK 03 — SSH Password Authentication Disabled on vm-db
**Category:** SECURITY  
**Check:** Confirm the SSH daemon on vm-db rejects password logins (enforces key-only auth).

> Connect to vm-db via Azure Bastion SSH tunnel first.

```bash
# Run on vm-db (via Bastion)
sudo grep -E "^PasswordAuthentication|^ChallengeResponseAuthentication" /etc/ssh/sshd_config
```

**Expected:** `PasswordAuthentication no` and `ChallengeResponseAuthentication no`  
**DB Note:** The Terraform sets `disable_password_authentication = false` — password auth IS currently enabled, which is a **critical finding**. This must be remediated immediately on a database server. Credential-based brute-force attacks against SSH are the leading initial access vector for database breaches.

---

## CHECK 04 — PostgreSQL Not Listening on 0.0.0.0 (Wildcard)
**Category:** SECURITY  
**Check:** Confirm `listen_addresses` is bound only to the private IP, not the wildcard.

```bash
# Run on vm-db (via Bastion)
sudo -u postgres psql -c "SHOW listen_addresses;"
ss -tlnp | grep 5432
```

**Expected:** `listen_addresses = '10.0.2.10'` and `ss` shows `10.0.2.10:5432` — not `0.0.0.0:5432`.  
**DB Note:** The cloud-init correctly sets `listen_addresses = '10.0.2.10'`. This check validates the setting survived the PostgreSQL restart and was not overridden. A wildcard bind combined with a misconfigured NSG would expose the database directly.

---

## CHECK 05 — pg_hba.conf Restricts Client Access to App Subnet Only
**Category:** SECURITY  
**Check:** Confirm no permissive `trust` entries exist and that host access is scoped to 10.0.1.0/24.

```bash
# Run on vm-db (via Bastion)
sudo grep -v "^#\|^$" /etc/postgresql/14/main/pg_hba.conf
```

**Expected:**
```
local   all  postgres  peer
local   all  all       peer
host    labdb  labuser  10.0.1.0/24  md5
```
No `trust` entries. No `0.0.0.0/0` or `all` host entries.  
**DB Note:** `pg_hba.conf` is the last line of defence once the network layer is bypassed. A `trust` entry means any user from a matching IP authenticates without a password — catastrophic for a production database.

---

## CHECK 06 — PostgreSQL Service is Running and Enabled
**Category:** CONNECTIVITY  
**Check:** Confirm the PostgreSQL 14 service started successfully and is set to start on boot.

```bash
# Run on vm-db (via Bastion)
systemctl is-active postgresql
systemctl is-enabled postgresql
pg_lsclusters
```

**Expected:** `active`, `enabled`, and `pg_lsclusters` shows cluster `14 main` with status `online`.  
**DB Note:** cloud-init runs `systemctl enable postgresql && systemctl start postgresql`. Validate the service reached `active` state after cloud-init completion — cloud-init failures are silent at the VM level and easy to miss post-deployment.

---

## CHECK 07 — App VM Can Connect to PostgreSQL (Port 5432 Open)
**Category:** CONNECTIVITY  
**Check:** Confirm vm-app can reach vm-db:5432 and authenticate as labuser.

```bash
# Run on vm-app (via Bastion)
nc -zv 10.0.2.10 5432
psql "host=10.0.2.10 port=5432 dbname=labdb user=labuser" -c "SELECT version();"
```

**Expected:** `nc` returns `Connection to 10.0.2.10 5432 port [tcp/postgresql] succeeded!`  
`psql` returns PostgreSQL 14.x version string.  
**DB Note:** This is the critical application-to-database path. A failure here means the application tier cannot use the database regardless of how well PostgreSQL is configured internally.

---

## CHECK 08 — vm-db Cannot Be Reached from vm-win on Port 5432
**Category:** SECURITY  
**Check:** Confirm the Windows VM (10.0.1.20) cannot reach PostgreSQL — Windows clients should use the app VM as a proxy, not direct DB access.

```powershell
# Run on vm-win (via Bastion RDP)
Test-NetConnection -ComputerName 10.0.2.10 -Port 5432
```

**Expected:** `TcpTestSucceeded : False` — the connection times out.  
**DB Note:** While 10.0.1.20 is technically in snet-app (10.0.1.0/24) and the NSG-db rule would allow it, this check verifies the architectural intent — Windows admin VMs should not have a direct database connection path. If this returns True, an additional NSG rule scoping port 5432 to specific app server IPs is recommended.

---

## CHECK 09 — Bastion Is the Only Inbound Path (No Firewall Bypass)
**Category:** SECURITY  
**Check:** Confirm NSG-app permits SSH/RDP only from the Bastion subnet.

```bash
az network nsg rule list \
  --resource-group $RG \
  --nsg-name nsg-app \
  --query "[].{Name:name,Port:destinationPortRange,Source:sourceAddressPrefix,Access:access}" \
  --output table
```

**Expected:** `AllowSSH` source `10.0.3.0/27`, `AllowRDP` source `10.0.3.0/27`. No rules with source `*`, `Internet`, or `0.0.0.0/0` on ports 22 or 3389.  
**DB Note:** With no public IPs on VMs, Bastion is the sole administrative access path. Any NSG rule that opens SSH/RDP from a broader source would allow an attacker to bypass Bastion audit logging — which is the primary audit trail for database administrator activity.

---

## CHECK 10 — labdb Database and labuser Role Exist
**Category:** CONNECTIVITY  
**Check:** Confirm cloud-init successfully created the application database and its owner role.

```bash
# Run on vm-db (via Bastion)
sudo -u postgres psql -c "\l labdb"
sudo -u postgres psql -c "\du labuser"
sudo -u postgres psql -c "SELECT has_database_privilege('labuser','labdb','CONNECT');"
```

**Expected:** `labdb` listed with owner `labuser`. `\du` shows role `labuser`. `has_database_privilege` returns `t`.  
**DB Note:** Cloud-init runs psql commands as root against the postgres socket. If PostgreSQL was not yet fully initialised when cloud-init executed those commands, the database and role may be absent — a silent failure that will prevent all application connectivity.

---

## CHECK 11 — max_connections Is Appropriate for Workload
**Category:** PERFORMANCE  
**Check:** Confirm the PostgreSQL `max_connections` setting and current connection headroom.

```bash
# Run on vm-db (via Bastion)
sudo -u postgres psql -c "SHOW max_connections;"
sudo -u postgres psql -c "SELECT count(*) AS active_connections FROM pg_stat_activity;"
sudo -u postgres psql -c "SELECT setting::int - (SELECT count(*)::int FROM pg_stat_activity) AS free_connections FROM pg_settings WHERE name='max_connections';"
```

**Expected:** `max_connections = 20` per cloud-init. For a B2ms VM (2 vCPU, 8 GB RAM) this is **extremely low** — a **critical finding**. Recommended minimum is 100. Active connections should be below 15.  
**DB Note:** The cloud-init explicitly sets `max_connections = 20`. This will cause `FATAL: remaining connection slots are reserved for non-replication superuser connections` under any realistic application load. This must be raised (and `shared_buffers` recalculated accordingly) before the environment serves traffic.

---

## CHECK 12 — PostgreSQL Data Directory on Correct Disk
**Category:** PERFORMANCE  
**Check:** Confirm the PostgreSQL data directory is on a disk with adequate free space, and that the OS disk is not the bottleneck.

```bash
# Run on vm-db (via Bastion)
sudo -u postgres psql -c "SHOW data_directory;"
df -h $(sudo -u postgres psql -t -c "SHOW data_directory;" | tr -d ' ')
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

**Expected:** Data directory is `/var/lib/postgresql/14/main`. OS disk is 30 GB (per Terraform). Free space should be > 20% — flag if under 10 GB free.  
**DB Note:** The Terraform allocates only a 30 GB OS disk for vm-db with no separate data disk. For a production database this is insufficient and the data directory shares space with the OS — a data volume filling up will crash the OS. This is a **finding** to raise with the infrastructure team.

---

## CHECK 13 — Storage Account Soft-Delete Retention Verified
**Category:** BACKUP  
**Check:** Confirm blob soft-delete and container soft-delete are enabled on the lab storage account.

```bash
az storage account blob-service-properties show \
  --account-name "stailab${PARTICIPANT_NAME}" \
  --resource-group $RG \
  --query "{BlobSoftDelete:deleteRetentionPolicy, ContainerSoftDelete:containerDeleteRetentionPolicy}" \
  --output table
```

**Expected:** `deleteRetentionPolicy.enabled = true`, `days = 30`. `containerDeleteRetentionPolicy.enabled = true`, `days = 30`.  
**DB Note:** The Terraform configures 30-day retention (the spec stated 7 — verify the deployed value matches organisational policy). Soft-delete is the recovery path for accidental deletion of database export blobs or backup files stored in this account.

---

## CHECK 14 — No Azure Backup Vault Configured (Gap Finding)
**Category:** BACKUP  
**Check:** Confirm whether a Recovery Services Vault with VM backup policy exists for vm-db.

```bash
az backup vault list \
  --resource-group $RG \
  --query "[].{Vault:name,Location:location,Redundancy:properties.storageModelType}" \
  --output table

az backup item list \
  --resource-group $RG \
  --vault-name <vault-name-if-found> \
  --query "[?contains(name,'vm-db')].{Name:name,Policy:properties.policyName,LastBackup:properties.lastBackupTime}" \
  --output table 2>/dev/null || echo "NO BACKUP VAULT FOUND"
```

**Expected:** A vault exists with vm-db enrolled in a daily backup policy. LRS vault redundancy confirmed.  
**DB Note:** The Terraform code contains **no Recovery Services Vault resource** — this is a **critical gap**. VM-level snapshots via Azure Backup are the first line of database recovery for this architecture. Without it, a VM failure means data loss. This must be remediated before the environment is considered production-ready.

---

## CHECK 15 — Auto-Shutdown Schedule Does Not Conflict with DB Operations
**Category:** MONITORING  
**Check:** Confirm auto-shutdown time and verify no scheduled jobs or backup windows overlap.

```bash
az vm auto-shutdown show \
  --resource-group $RG \
  --name vm-db \
  --query "{Enabled:enabled,ShutdownTime:dailyRecurrenceTime,TimeZone:timeZone}" \
  --output table
```

```bash
# Also check cron on vm-db (via Bastion)
sudo crontab -l -u postgres 2>/dev/null || echo "no postgres crontab"
sudo crontab -l -u root | grep -i "pg\|backup\|dump" 2>/dev/null
```

**Expected:** Shutdown at `1300 UTC`. No pg_dump cron jobs scheduled within 30 minutes of shutdown. Stakeholders notified of the 13:00 UTC hard-stop.  
**DB Note:** The Terraform schedules **all three VMs to shut down at 13:00 UTC daily**. If a long-running backup, pg_dump, or VACUUM FULL is in-flight at that time, it will be killed mid-operation — potentially leaving a corrupt dump file or a table in an inconsistent state. For a database VM, auto-shutdown must be coordinated with all maintenance windows.

---

## CHECK 16 — Boot Diagnostics Enabled and Accessible
**Category:** MONITORING  
**Check:** Confirm boot diagnostics are enabled on vm-db and that the serial log shows a clean boot with PostgreSQL start.

```bash
az vm boot-diagnostics get-boot-log \
  --name vm-db \
  --resource-group $RG \
  | tail -50
```

**Expected:** Serial log shows `cloud-init` completed, `postgresql` service started, no kernel panics or OOM events.  
**DB Note:** Boot diagnostics is the only mechanism to diagnose vm-db startup failures when Bastion connectivity is unavailable (e.g., VM crashed before network stack came up). Validating it works post-deployment ensures it will be usable during an incident.

---

## CHECK 17 — PostgreSQL Log Destination and Log Level Configured
**Category:** MONITORING  
**Check:** Confirm PostgreSQL is logging connections, disconnections, and slow queries.

```bash
# Run on vm-db (via Bastion)
sudo -u postgres psql -c "SHOW log_connections;"
sudo -u postgres psql -c "SHOW log_disconnections;"
sudo -u postgres psql -c "SHOW log_min_duration_statement;"
sudo -u postgres psql -c "SHOW logging_collector;"
sudo ls -lh /var/log/postgresql/
```

**Expected:** `log_connections = on`, `log_disconnections = on`, `log_min_duration_statement` set to a value ≤ 1000ms. Logs present in `/var/log/postgresql/`.  
**DB Note:** The cloud-init does **not configure any logging parameters** — all values are PostgreSQL defaults (`log_connections = off`). Without connection logging, there is no audit trail of who connected to the database and when. This is a **security and compliance gap** that must be remediated before any production workload runs.

---

## CHECK 18 — Storage Account Not Publicly Accessible
**Category:** SECURITY  
**Check:** Confirm the storage account does not allow public blob access and that access is restricted.

```bash
az storage account show \
  --name "stailab${PARTICIPANT_NAME}" \
  --resource-group $RG \
  --query "{AllowBlobPublicAccess:allowBlobPublicAccess,PublicNetworkAccess:publicNetworkAccess,MinTLSVersion:minimumTlsVersion}" \
  --output table
```

**Expected:** `allowBlobPublicAccess = false` (or null/disabled), `minimumTlsVersion = TLS1_2`.  
**DB Note:** If database export files (pg_dump outputs) are written to this storage account, a publicly accessible blob container would expose the entire database contents anonymously. The Terraform does not explicitly set `allow_blob_public_access = false` — validate the Azure default has not been overridden.

---

## Findings Summary

| # | Category | Severity | Finding |
|---|---|---|---|
| 03 | SECURITY | **CRITICAL** | SSH password auth enabled on vm-db (`disable_password_authentication = false`) |
| 11 | PERFORMANCE | **CRITICAL** | `max_connections = 20` — will cause connection exhaustion under any load |
| 14 | BACKUP | **CRITICAL** | No Azure Recovery Services Vault — vm-db has zero backup coverage |
| 12 | PERFORMANCE | **HIGH** | No separate data disk on vm-db — 30 GB OS disk shared with PostgreSQL data |
| 17 | MONITORING | **HIGH** | PostgreSQL connection logging disabled by default — no audit trail |
| 15 | MONITORING | **MEDIUM** | Auto-shutdown at 13:00 UTC may kill in-flight DB operations |
| 18 | SECURITY | **MEDIUM** | Storage account public access not explicitly blocked in Terraform |

---

*Generated by: Senior Database Engineer review of TFlab Terraform deployment*  
*Terraform source: `TFlab/Main.tf`, `TFlab/cloud-init-db.yaml`*
