# FinBridge Lab — Azure FinOps Cost Analysis & Reduction Report

**Period:** 2024-02-15 → 2024-03-15  
**Subscription:** AI-Lab-Participant-01  
**Analyst role:** Senior FinOps Engineer / Cloud Architect  
**Budget:** $100 / month | **Actual spend:** $346.00 / month | **Overage:** +246% over budget  
**Report generated:** 2024-03-15

---

## 1. Executive Summary

The FinBridge lab environment is running **246% over its $100/month budget** at $346/month, almost entirely driven by three resources:

| Driver | Monthly Cost | % of Total |
|---|---|---|
| Azure Bastion (Basic) | $136.80 | 39.5% |
| vm-win (Windows B2s) | $69.00 | 19.9% |
| vm-app (Linux B2ms) | $67.80 | 19.6% |
| vm-db (Linux B2ms) | $67.80 | 19.6% |
| pip-bastion + Storage | $4.60 | 1.4% |

All VMs show **chronically low average utilisation** (CPU avg < 4%). High peak values are lab stress exercises — not production workload — and do not justify current SKU sizing. The `day:3-10` tags confirm these are training-day resources, not always-on services.

**Applying all immediate optimisations (right-size + auto-schedule + Bastion) reduces monthly spend to approximately $19–$56/month — a saving of $290–$327/month and putting the environment firmly within its $100 budget.**

---

## 2. Optimisation Recommendations Table

> **Legend — Risk:** Low = no availability impact in lab context | Medium = brief access gap or degraded peak | High = availability/latency impact  
> **Action timing:** Immediate = apply this week | Next Sprint = plan & test first | Next Quarter = lower priority

| Resource | Current Monthly Cost | Optimisation Opportunity | Est. Monthly Saving | Optimised Cost | Risk | Action | Availability / Latency Flag |
|---|---|---|---|---|---|---|---|
| **vm-app** (Linux B2ms) | $67.80 | Right-size → Standard_B1ms (1 vCPU / 2 GB) + auto-shutdown outside lab hours (Mon–Fri 08:00–18:00 UTC) | **$64.44** | $3.36 | Low | **Immediate** | Peak CPU 97.4% during stress exercises — stress tests will be slower on 1 vCPU. Acceptable for lab. ⚠️ Flag: Memory peak 91.2% on B2ms → B1ms has 2 GB; verify no stress test requires >2 GB RAM. |
| **vm-db** (Linux B2ms) | $67.80 | Right-size → Standard_B1ms + auto-shutdown same schedule | **$64.44** | $3.36 | Low | **Immediate** | PG connections avg 3/20 — B1ms is adequate. Peak 19/20 during exercises still manageable. |
| **vm-win** (Windows B2s) | $69.00 | Right-size → Standard_B1s (1 vCPU / 1 GB) + auto-shutdown weekends & overnight. Currently running 24/7 including weekends — biggest scheduling win. | **$60.36** | $8.64 | Low | **Immediate** | Memory avg 31.4%, peak 96.1% — **B1s has only 1 GB RAM**. ⚠️ HIGH FLAG: If any Windows lab exercise needs >1 GB, B1s will cause OOM. Consider B2s with scheduling only ($27 saving) as a safer alternative while memory usage is confirmed. |
| **bastion-ailab** (Basic) | $136.80 | **Option A (preferred):** Replace Azure Bastion with Azure JIT VM Access (free) — no hourly charge. **Option B:** Schedule Bastion deployment via Terraform/Automation (destroy after 18:00, redeploy at 07:45 weekdays). | **$127–$137** | $0–$9.80 | Medium | **Next Sprint** | ⚠️ Flag: Between 18:00–08:00 UTC and weekends, direct VM access is blocked. Document emergency access runbook. JIT requires NSG rule automation. |
| **pip-bastion** (Static Standard) | $3.00 | If Bastion is removed (JIT route): delete static IP. If Bastion is kept/scheduled: retain. | **$0–$3.00** | $0–$3.00 | Low | With Bastion | No impact — static IPs still charge when unattached. |
| **stailab** (Storage — Hot LRS) | $1.60 | Tier-migrate inactive blobs: `container-hot` (24.6 GB, 38 days cold) → Cool tier; `container-archive` (8.3 GB, 6 months cold) → Archive tier. Keep `lab-data` on Hot. | **$0.34** | $1.26 | Low | **Next Sprint** | ⚠️ Flag: Archive tier has rehydration latency (hours). Ensure no lab exercise reads from `container-archive` directly. |
| **All VMs** (Reserved Instance) | — | RI pricing saves 40% on 1-yr commitment vs PAYG. **Not recommended for this lab** — scheduling reduces actual run hours to ~22% of month, making PAYG + schedule far cheaper than RI. See Section 4. | N/A | N/A | — | Next Quarter (review) | — |
| **All NICs** (Accelerated Networking) | $0.00 | Enable accelerated networking — free, reduces VM network latency ~25%. | $0 | $0 | Low | **Immediate** | Latency improvement, no negative impact. |
| **TOTAL** | **$346.00** | All immediate + next-sprint optimisations | **~$290–$316** | **~$30–$56** | | | |

---

## 3. Per-Resource Deep Dive

### 3.1 vm-app — Linux Standard_B2ms

| Metric | Value | Assessment |
|---|---|---|
| CPU avg | 3.2% | Severely over-provisioned |
| CPU p95 | 18.4% | Still fine on B1ms |
| CPU peak | 97.4% | Lab stress exercise only (4 occurrences) |
| Memory avg | 18.4% | Well within B1ms 2 GB |
| Memory peak | 91.2% | ~7.3 GB on B2ms — this is a stress exercise. B1ms peak ~1.84 GB. Verify actual peak RAM needed. |
| Disk avg | 12% | Minimal |
| Network | 1.2 MB/s in / 0.8 out | Well within B1ms NIC limits |

**Recommended SKU:** Standard_B1ms (1 vCPU, 2 GB RAM, 4 GB SSD) — $0.021/hr Linux  
**Scheduling:** Mon–Fri 08:00–18:00 UTC = 217 hrs/month  
**Optimised monthly cost:** $0.021 × 217 = **$4.56** (saving ~$63/month)

---

### 3.2 vm-db — Linux Standard_B2ms

| Metric | Value | Assessment |
|---|---|---|
| CPU avg | 1.8% | Lowest utilisation of all VMs |
| CPU p95 | 8.2% | B1ms headroom comfortable |
| Memory avg | 22.1% | ~1.77 GB on B2ms; ~0.44 GB on B1ms — watch PostgreSQL buffer cache |
| PG connections avg | 3/20 | Minimal |
| PG connections peak | 19/20 | During lab flood exercise only |

**Recommended SKU:** Standard_B1ms  
**Note:** PostgreSQL `shared_buffers` and `work_mem` settings should be reviewed if downgraded — the DB may need tuning to operate within 2 GB.  
**Scheduling:** Same as vm-app  
**Optimised monthly cost:** ~**$4.56** (saving ~$63/month)

---

### 3.3 vm-win — Windows Standard_B2s

| Metric | Value | Assessment |
|---|---|---|
| CPU avg | 2.1% | Over-provisioned |
| Memory avg | 31.4% | ~2.51 GB on B2s (8 GB SKU). **B1s has only 1 GB** — this is a concern |
| Memory peak | 96.1% | ~7.69 GB on B2s. Impossible on B1s (1 GB). |
| Uptime | 30 days including weekends | No scheduling currently applied |

**Memory concern is critical for B1s.** Average of 31.4% on a B2s (8 GB) = 2.51 GB used. B1s has 1 GB. This will cause OOM unless confirmed that the 31.4% figure includes page file usage.

**Safer immediate action:** Apply auto-shutdown (scheduling) only on current B2s SKU, targeting weekdays 08:00–18:00.  
**Optimised monthly cost (schedule only):** $2.30/day → $2.30 × (217/24) = **$20.82/month** (saving ~$48/month)  
**If B1s is confirmed safe after memory audit:** Further drop to ~$8.64/month

---

### 3.4 bastion-ailab — Azure Bastion Basic

| Factor | Detail |
|---|---|
| Current charge | $0.19/hr × 730 = $136.80/month |
| Actual usage window | Weekdays 08:00–17:00 UTC (~195 hrs/month, 26.7% of hours) |
| Waste | 73.3% of spend = ~$100/month |

**Option A — JIT VM Access (recommended for aggressive lab optimisation):**  
Cost: $0. Replace Bastion with Azure Security Center Just-in-Time VM access + NSG automation. Risk: Medium — requires Azure Defender for Cloud; less polished UX than Bastion. Saving: $136.80/month.

**Option B — Scheduled deployment via Terraform/Automation:**  
Deploy Bastion at 07:45 UTC weekdays, destroy at 17:15 UTC weekdays via Azure Automation runbook or GitHub Actions.  
Cost: $0.19 × 195 = **$37.05/month**. Saving: $99.75/month.

---

### 3.5 stailab — Storage Account (Standard LRS Hot)

| Container | Size | Last Accessed | Current Tier | Recommended Tier | Monthly Saving |
|---|---|---|---|---|---|
| container-hot | 24.6 GB | 38 days ago | Hot ($0.018/GB) | Cool ($0.010/GB) | $0.20 |
| container-archive | 8.3 GB | 6 months ago | Hot ($0.018/GB) | Archive ($0.001/GB) | $0.14 |
| lab-data | 0.4 GB | Yesterday | Hot | Hot (keep) | $0 |
| **Total saving** | | | | | **$0.34/month** |

⚠️ **Archive rehydration warning:** Archive tier data takes 1–15 hours to access. Confirm no lab exercise reads `container-archive` blobs at runtime before migrating.

---

## 4. Reserved Instance Breakeven Analysis

> Assuming 12-month commitment, 40% savings vs PAYG.

### Scenario A: No optimisation, RI only

| | Annual PAYG | Annual RI (40% off) | Annual Saving |
|---|---|---|---|
| All 3 VMs | $2,455.20 | $1,473.12 | **$982.08** |
| Breakeven | Month 1 (RI always cheaper at 24/7 use) | — | — |

**Verdict: RI is cheaper than PAYG if VMs run 24/7. But lab scheduling makes this irrelevant.**

### Scenario B: Right-sized + scheduled (recommended path)

After right-sizing (B1ms/B1s) and scheduling to ~217 hrs/month:

| VM | PAYG scheduled (annual) | RI equivalent (annual) | Verdict |
|---|---|---|---|
| vm-app B1ms | $3.36 × 12 = $40.32 | $9.20 × 12 = $110.40 | **PAYG+schedule wins** |
| vm-db B1ms | $3.36 × 12 = $40.32 | $9.20 × 12 = $110.40 | **PAYG+schedule wins** |
| vm-win B1s | $8.64 × 12 = $103.68 | $23.63 × 12 = $283.56 | **PAYG+schedule wins** |

**RI breakeven for lab environment:** VMs would need to run >60% of month (438+ hrs) for RI to pay off. Scheduled lab runs ~217 hrs/month (29.7%). **RI is not recommended for this environment.** Re-evaluate if environment moves to production-equivalent use.

---

## 5. Implementation Roadmap

### Immediate Actions (this week, zero-risk)

1. **Enable auto-shutdown on all 3 VMs** via Azure Portal → VM → Auto-shutdown → 18:00 UTC weekdays. Configure Azure Automation or a startup schedule for 08:00 UTC.
2. **Right-size vm-app and vm-db** to Standard_B1ms — deallocate VM, resize in portal, restart.
3. **Enable Accelerated Networking** on all VM NICs (zero cost, free latency improvement).
4. **Do not right-size vm-win yet** — audit actual memory consumption first (check Task Manager / Performance Monitor averages, not just stress peaks).

### Next Sprint (1–2 weeks)

5. **Schedule or replace Azure Bastion** — implement Option B (Terraform scheduled deployment) first; evaluate Option A (JIT) if Terraform automation is available.
6. **Storage tier migration** — use Azure Portal Lifecycle Management policy to auto-tier `container-hot` to Cool and `container-archive` to Archive.
7. **Audit vm-win memory** — if confirmed <900 MB normal use, right-size to B1s.

### Next Quarter

8. **Review RI** only if lab schedule changes to near-continuous use.
9. **Evaluate Azure Dev/Test pricing** — if subscription is Dev/Test eligible, Windows VMs qualify for Linux pricing (eliminates Windows license surcharge).
10. **Budget alert** — set Azure Cost Management alert at $80/month (80% of budget) to catch overruns before month-end.

---

## 6. Risk & Availability Summary

| Optimisation | Availability Impact | Latency Impact | Recommendation |
|---|---|---|---|
| VM right-size (app/db → B1ms) | None under normal load. Lab stress tests will be slower. | None | Proceed — lab context, acceptable |
| VM right-size (win → B1s) | **OOM risk** — 1 GB RAM vs 2.51 GB avg used. | None | **Do not apply until memory audit complete** |
| VM auto-shutdown | VMs unavailable outside lab hours. | N/A | Acceptable — lab use case. Document hours. |
| Bastion scheduling | No VM access 18:00–08:00 UTC weekdays or weekends. | N/A | Acceptable with emergency runbook in place. |
| Storage Cool/Archive tier | Archive rehydration: 1–15 hr delay. Cool: no delay. | Archive: high latency on reads | Verify no runtime dependency on cold containers. |
| Accelerated Networking | None | Improvement (~25% lower latency) | Apply immediately. |

---

## 7. Projected Budget After Optimisation

| Scenario | Monthly Cost | vs. Budget ($100) |
|---|---|---|
| Current (no changes) | $346.00 | +246% over |
| Immediate actions only (schedule + right-size app/db) | ~$120–$130 | +20–30% over |
| Immediate + Bastion scheduling | ~$30–$45 | **Under budget** |
| Full optimisation (JIT + all right-sizing) | ~$16–$20 | **84% under budget** |

---

*Report prepared for FinBridge Lab Environment | Subscription: AI-Lab-Participant-01 | Generated: 2024-03-15*  
*Prices based on Azure East US region PAYG rates as of 2024-03. Actual prices may vary by region.*
