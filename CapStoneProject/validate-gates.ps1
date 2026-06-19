param(
  [switch]$RunIdempotency
)

$ErrorActionPreference = "Stop"

Write-Host "Gate 1/4: Lint"
terraform fmt -check -recursive
terraform init -upgrade
terraform validate

Write-Host "Gate 2/4: Dry-Run"
terraform plan -out tfplan.dryrun

Write-Host "Gate 3/4: Bounded Scope"
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
) | Sort-Object

$planned = (terraform show -json tfplan.dryrun | ConvertFrom-Json).resource_changes.address | Sort-Object -Unique
$unexpected = Compare-Object -ReferenceObject $expected -DifferenceObject $planned -PassThru | Where-Object { $_ -notin $expected }

if ($unexpected) {
  Write-Error "Bounded scope failed. Unexpected resources in plan: $($unexpected -join ', ')"
}

Write-Host "Gate 4/4: Idempotency"
if ($RunIdempotency) {
  Write-Host "Applying dry-run plan to test idempotency..."
  terraform apply -auto-approve tfplan.dryrun

  terraform plan -detailed-exitcode
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Idempotency passed: second plan returned no changes."
  }
  elseif ($LASTEXITCODE -eq 2) {
    Write-Error "Idempotency failed: second plan still has changes."
  }
  else {
    Write-Error "Idempotency check failed due to terraform plan error."
  }
}
else {
  Write-Host "Skipped apply-based idempotency check. Re-run with -RunIdempotency for full gate."
}

Write-Host "All requested gates completed."
