data "azapi_client_config" "FortiAIGate" {
  count = local.enabled ? 1 : 0
}

resource "azapi_resource" "FAIG_RG" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  parent_id = data.azapi_client_config.FortiAIGate[0].subscription_resource_id
  name      = "${local.prefix}_RG"
  location  = var.Azure_Region
  tags      = local.tags
  body      = { properties = {} }

  lifecycle {
    precondition {
      condition     = can(cidrnetmask(var.Management_Source_CIDR)) && try(tonumber(split("/", var.Management_Source_CIDR)[1]) > 0, false)
      error_message = "Management_Source_CIDR must be a restricted IPv4 CIDR; 0.0.0.0/0 is not allowed."
    }
    precondition {
      condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+=*( .*)?$", trimspace(var.ssh_public_key)))
      error_message = "Supply an existing SSH public key before enabling Azure CPU."
    }
  }
}

resource "azapi_resource" "FAIG_VNET" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.Network/virtualNetworks@2024-05-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.prefix}_VNET"
  location  = var.Azure_Region
  tags      = local.tags
  body = {
    properties = { addressSpace = { addressPrefixes = ["10.250.20.0/24"] } }
  }
}

resource "azapi_resource" "FAIG_subnet" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  parent_id = azapi_resource.FAIG_VNET[0].id
  name      = "${local.prefix}_Subnet"
  body = {
    properties = {
      addressPrefix         = "10.250.20.0/24"
      defaultOutboundAccess = false
    }
  }
}

resource "azapi_resource" "FortiAIGate_CPU_NSG" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.Network/networkSecurityGroups@2024-05-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.prefix}_NSG"
  location  = var.Azure_Region
  tags      = local.tags
  body = {
    properties = {
      securityRules = concat([
        {
          name = "${local.prefix}_NSG_SSH"
          properties = {
            priority            = 100, direction = "Inbound", access = "Allow", protocol = "Tcp"
            sourcePortRange     = "*", destinationPortRange = "22"
            sourceAddressPrefix = local.ssh_source, destinationAddressPrefix = "*"
          }
        },
        {
          name = "${local.prefix}_NSG_HTTPS"
          properties = {
            priority            = 110, direction = "Inbound", access = "Allow", protocol = "Tcp"
            sourcePortRange     = "*", destinationPortRange = "443"
            sourceAddressPrefix = var.Management_Source_CIDR, destinationAddressPrefix = "*"
          }
        }
        ], local.ollama ? [
        {
          name = "${local.prefix}_NSG_Ollama_API"
          properties = {
            priority            = 120, direction = "Inbound", access = "Allow", protocol = "Tcp"
            sourcePortRange     = "*", destinationPortRange = tostring(var.Gateway_API_Port)
            sourceAddressPrefix = "${local.ollama_ip}/32", destinationAddressPrefix = "*"
          }
        }
        ] : [], [
        {
          // Override Azure's default intra-VNET allow rule for management and gateway API.
          name = "${local.prefix}_NSG_Deny_Management"
          properties = {
            priority            = 130, direction = "Inbound", access = "Deny", protocol = "Tcp"
            sourcePortRange     = "*", destinationPortRanges = distinct(["22", "443", tostring(var.Gateway_API_Port)])
            sourceAddressPrefix = "*", destinationAddressPrefix = "*"
          }
        }
      ])
    }
  }
}

resource "azapi_resource" "Ollama_NSG" {
  count     = local.ollama ? 1 : 0
  type      = "Microsoft.Network/networkSecurityGroups@2024-05-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.ollama_prefix}_NSG"
  location  = var.Azure_Region
  tags      = local.ollama_tags
  body = {
    properties = {
      securityRules = [
        {
          name = "${local.ollama_prefix}_NSG_SSH"
          properties = {
            priority            = 100, direction = "Inbound", access = "Allow", protocol = "Tcp"
            sourcePortRange     = "*", destinationPortRange = "22"
            sourceAddressPrefix = local.ssh_source, destinationAddressPrefix = "*"
          }
        },
        {
          name = "${local.ollama_prefix}_NSG_WebUI"
          properties = {
            priority            = 110, direction = "Inbound", access = "Allow", protocol = "Tcp"
            sourcePortRange     = "*", destinationPortRange = "3000"
            sourceAddressPrefix = var.Management_Source_CIDR, destinationAddressPrefix = "*"
          }
        },
        {
          name = "${local.ollama_prefix}_NSG_Model"
          properties = {
            priority            = 120, direction = "Inbound", access = "Allow", protocol = "Tcp"
            sourcePortRange     = "*", destinationPortRange = "11434"
            sourceAddressPrefix = "${local.gateway_ip}/32", destinationAddressPrefix = "*"
          }
        },
        {
          name = "${local.ollama_prefix}_NSG_Deny_Other"
          properties = {
            priority            = 130, direction = "Inbound", access = "Deny", protocol = "Tcp"
            sourcePortRange     = "*", destinationPortRanges = ["22", "3000", "11434"]
            sourceAddressPrefix = "*", destinationAddressPrefix = "*"
          }
        }
      ]
    }
  }
}
