locals {
  app_vm_name = "capstone-app-vm"
  db_vm_name  = "capstone-db-vm"
}

resource "azurerm_resource_group" "capstone" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "capstone" {
  name                = "capstone-vnet"
  resource_group_name = azurerm_resource_group.capstone.name
  location            = azurerm_resource_group.capstone.location
  address_space       = var.vnet_cidr
  tags                = var.tags
}

resource "azurerm_subnet" "app" {
  name                 = "app-subnet"
  resource_group_name  = azurerm_resource_group.capstone.name
  virtual_network_name = azurerm_virtual_network.capstone.name
  address_prefixes     = var.app_subnet_cidr
}

resource "azurerm_subnet" "db" {
  name                 = "db-subnet"
  resource_group_name  = azurerm_resource_group.capstone.name
  virtual_network_name = azurerm_virtual_network.capstone.name
  address_prefixes     = var.db_subnet_cidr
}

resource "azurerm_network_security_group" "capstone" {
  name                = "capstone-shared-nsg"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh-to-app"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = var.app_subnet_cidr[0]
  }

  security_rule {
    name                       = "allow-postgres-from-app"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = var.app_subnet_cidr[0]
    destination_address_prefix = var.db_subnet_cidr[0]
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.capstone.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.capstone.id
}

resource "azurerm_public_ip" "app" {
  name                = "capstone-app-pip"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "app" {
  name                = "capstone-app-nic"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.app.id
  }
}

resource "azurerm_network_interface" "db" {
  name                = "capstone-db-nic"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.db.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                            = local.app_vm_name
  resource_group_name             = azurerm_resource_group.capstone.name
  location                        = azurerm_resource_group.capstone.location
  size                            = var.app_vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.app.id]
  tags                            = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_linux_virtual_machine" "db" {
  name                            = local.db_vm_name
  resource_group_name             = azurerm_resource_group.capstone.name
  location                        = azurerm_resource_group.capstone.location
  size                            = var.db_vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.db.id]
  custom_data = base64encode(templatefile("${path.module}/cloud-init-db.yaml", {
    db_app_username = var.db_app_username
    db_app_password = var.db_app_password
    app_subnet_cidr = var.app_subnet_cidr[0]
  }))
  tags = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
