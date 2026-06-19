# Capstone Terraform Stack (Azure)

This Terraform code deploys:
- One Linux application VM with a public IP for SSH access.
- One Linux database VM on private subnet only (no public IP).
- PostgreSQL 13 installed on DB VM and user creation:
  - `CREATE USER labuser WITH PASSWORD 'Lab@2024!';`
- Admin account on both VMs:
  - Username: `labadmin`
  - Password: `Training@123`

## Deployed Infrastructure

- Resource group: `capstone_resource_group`
- One virtual network
- Two subnets:
  - `app-subnet`
  - `db-subnet`
- One network security group associated to both subnets

## VM Sizing Note

Azure VM SKUs do not provide exact 2 vCPU / 5 GB and 2 vCPU / 10 GB combinations in most regions.
Defaults used in this code are the closest common 2-vCPU options:
- App VM: `Standard_B2s` (2 vCPU, 4 GiB RAM)
- DB VM: `Standard_B2ms` (2 vCPU, 8 GiB RAM)

You can change `app_vm_size` and `db_vm_size` in `variables.tf` or `terraform.tfvars`.

## Usage

```powershell
cd C:\Users\labuser\Documents\training\CapStoneProject
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

## Gate Validation Commands (Before Apply)

### 1) Lint Gate

```powershell
terraform fmt -check -recursive
terraform init -upgrade
terraform validate
```

### 2) Dry-Run Gate

```powershell
terraform plan -out tfplan.dryrun
```

### 3) Bounded Scope Gate

```powershell
$expected = @(
  "azurerm_resource_group.capstone",
  "azurerm_virtual_network.capstone",
  "azurerm_subnet.app",
  "azurerm_subnet.db",
  "azurerm_network_security_group.capstone",
  "azurerm_subnet_network_security_group_association.app",
  "azurerm_subnet_network_security_group_association.db",
  "azurerm_public_ip.app",
  "azurerm_network_interface.app",
  "azurerm_network_interface.db",
  "azurerm_linux_virtual_machine.app",
  "azurerm_linux_virtual_machine.db"
)
$planned = (terraform show -json tfplan.dryrun | ConvertFrom-Json).resource_changes.address | Sort-Object -Unique
Compare-Object $expected $planned
```

### 4) Idempotency Gate

```powershell
# Full idempotency requires one apply in a disposable/subscription test environment.
terraform apply -auto-approve tfplan.dryrun
terraform plan -detailed-exitcode
# Exit code 0 = idempotent (no changes)
# Exit code 2 = changes still detected
```

## Optional One-Shot Gate Script

```powershell
.\validate-gates.ps1
# or full idempotency (runs apply)
.\validate-gates.ps1 -RunIdempotency
```

## Fault Injection Lab

For a safe PostgreSQL 13 connection pool exhaustion test that runs from the app VM, see `fault-injection_script/README.md` and `fault-injection_script/postgres-connection-pool-exhaustion.sh`.
