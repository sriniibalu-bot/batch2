variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group name for the capstone deployment."
  type        = string
  default     = "capstone_resource_group"
}

variable "vnet_cidr" {
  description = "Address space for the virtual network."
  type        = list(string)
  default     = ["10.60.0.0/16"]
}

variable "app_subnet_cidr" {
  description = "CIDR range for application subnet."
  type        = list(string)
  default     = ["10.60.1.0/24"]
}

variable "db_subnet_cidr" {
  description = "CIDR range for database subnet."
  type        = list(string)
  default     = ["10.60.2.0/24"]
}

variable "admin_username" {
  description = "Admin username for Linux VMs."
  type        = string
  default     = "labadmin"
}

variable "admin_password" {
  description = "Admin password for Linux VMs."
  type        = string
  sensitive   = true
  default     = "Training@123"
}

variable "db_app_username" {
  description = "Application database username to create inside PostgreSQL."
  type        = string
  default     = "labuser"
}

variable "db_app_password" {
  description = "Application database password for the db_app_username user."
  type        = string
  sensitive   = true
  default     = "Lab@2024!"
}

variable "app_vm_size" {
  description = "Azure VM size for the application server (2 vCPU class)."
  type        = string
  default     = "Standard_B2s"
}

variable "db_vm_size" {
  description = "Azure VM size for the database server (2 vCPU class)."
  type        = string
  default     = "Standard_B2ms"
}

variable "tags" {
  description = "Common tags for all resources."
  type        = map(string)
  default = {
    project = "capstone"
    owner   = "labuser"
  }
}
