# FinBridge Incident Network Analysis

Date: 2026-06-16
Incident reference: NSG and connectivity alerts around nsg-app / vm-app / DB flow on TCP 5432

## 1) Why widening source from /24 to /16 still caused blocked traffic

The source range widening by itself does not block traffic. In Azure NSG processing, traffic is allowed or denied by the first matching rule in ascending priority order. If the intended allow rule no longer matches in effective evaluation, traffic falls through to default deny.

For flow 10.0.1.10 -> 10.0.2.10:5432, evaluation works as follows:

1. Azure evaluates outbound rules on source side (NIC/subnet NSGs affecting vm-app path).
2. Azure evaluates inbound rules on destination side (NIC/subnet NSGs affecting DB target).
3. Inside each NSG, lower priority number is checked first (first match wins).
4. If no custom allow matches, default rules apply.
5. Flow logs show rule hit as DenyAllInbound, proving no earlier matching allow was found on effective destination-side inbound evaluation.

Given ALT-003 (VNet topology change on snet-app and snet-db at nearly the same time), the likely condition is that effective filtering path changed and the edited AllowPostgres rule did not match where traffic was actually evaluated, despite broader source CIDR.

## 2) Priority precedence and required rule context

- Azure NSG precedence: lower number = higher precedence.
- Therefore priority 50 is evaluated before 100.

Default rule clarification:
- AllowVnetInBound has priority 65000.
- DenyAllInbound has priority 65500.

To explain observed deny by DenyAllInbound:
- Traffic did not match AllowPostgres during effective evaluation.
- It also did not match any other earlier allow.
- It then hit default DenyAllInbound at 65500.

If a custom deny were matching earlier, flow logs would normally show that custom deny rule name instead of DenyAllInbound.

## 3) Exact Azure CLI commands

### 3a) Show all effective NSG rules on vm-app NIC now

```bash
RG=rg-finbridge
NIC_ID=$(az vm show -g $RG -n vm-app --query "networkProfile.networkInterfaces[0].id" -o tsv)
NIC_NAME=$(basename $NIC_ID)
az network nic list-effective-nsg -g $RG -n $NIC_NAME -o jsonc
```

### 3b) Fix AllowPostgres to restore connectivity

```bash
RG=rg-finbridge
az network nsg rule update \
  -g $RG \
  --nsg-name nsg-app \
  -n AllowPostgres \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes 10.0.1.0/24 \
  --source-port-ranges '*' \
  --destination-address-prefixes 10.0.2.10 \
  --destination-port-ranges 5432
```

### 3c) Verify fix is working within 30 seconds

```bash
RG=rg-finbridge
VM_ID=$(az vm show -g $RG -n vm-app --query id -o tsv)
az network watcher test-ip-flow \
  --resource-group $RG \
  --target-resource-id $VM_ID \
  --direction Outbound \
  --protocol TCP \
  --local 10.0.1.10:50000 \
  --remote 10.0.2.10:5432 \
  -o jsonc
```

Expected result: access = Allow and ruleName = AllowPostgres (or intended allow rule).

## 4) Why NSG flow logs appear later (1m32s gap)

NSG flow logs are near-real-time telemetry, not instantaneous packet-by-packet streaming. Delays commonly come from:

- Data-plane record batching and aggregation
- Log pipeline buffering
- Storage and ingestion latency in monitoring backends

A 1 minute 32 second gap is consistent with telemetry latency. It does not mean traffic remained healthy during that gap. For incident response:

- Use Activity Log timestamps as immediate control-plane truth
- Use flow logs as delayed confirmation
- Run active connectivity checks immediately after changes

## 5) Azure Monitor alert rule to detect change before impact

Required configuration:
- Signal: Activity Log
- Operation name: Microsoft.Network/networkSecurityGroups/securityRules/write
- Severity: Warning

Example CLI:

```bash
SUB_ID=$(az account show --query id -o tsv)
RG=rg-finbridge
AG_ID="/subscriptions/$SUB_ID/resourceGroups/$RG/providers/microsoft.insights/actionGroups/ag-finbridge-netops"

az monitor activity-log alert create \
  -g $RG \
  -n alert-nsg-securityrule-write \
  --scopes /subscriptions/$SUB_ID \
  --condition category=Administrative \
  --condition operationName=Microsoft.Network/networkSecurityGroups/securityRules/write \
  --condition status=Succeeded \
  --action-group $AG_ID \
  --description "Warning: NSG security rule modified in production"
```

Alert notification content should include before and after state:
- Caller identity (UPN or service principal)
- NSG name and security rule name
- Correlation ID and timestamp
- Previous and new values for: priority, source prefixes, destination prefixes, protocol, ports, direction, and access

Operationally, this is best done by forwarding alert payload to Logic App or Function for enrichment and explicit diff formatting.

## 6) Change management process gap from ALT-006

ALT-006 indicates a direct Bastion-admin production change in a short interactive session (2m14s) with immediate network impact.

Process gap:
- Missing enforced pre-change and post-change validation gates
- No mandatory peer approval for high-impact NSG edits
- No automatic rollback condition tied to failed connectivity checks

Is 2m14s enough to validate a network change?
- It is enough to execute a rule edit
- It is usually not enough for safe production validation unless scripted checks run immediately

Recommended minimum controls:
1. Approved change ticket with exact before/after values
2. Two-person review for NSG scope and priority edits
3. Baseline capture before change
4. Automated post-change checks (flow test, app health, dependency checks)
5. Time-bound rollback trigger if validation fails
