output "resource_group_name" {
  description = "Resource group created by this stack."
  value       = azurerm_resource_group.capstone.name
}

output "app_public_ip" {
  description = "Public IP address for the application VM."
  value       = azurerm_public_ip.app.ip_address
}

output "app_private_ip" {
  description = "Private IP address for the application VM."
  value       = azurerm_network_interface.app.private_ip_address
}

output "db_private_ip" {
  description = "Private IP address for the database VM."
  value       = azurerm_network_interface.db.private_ip_address
}

output "ssh_command" {
  description = "SSH command to connect to the app VM using password auth."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.app.ip_address}"
}
