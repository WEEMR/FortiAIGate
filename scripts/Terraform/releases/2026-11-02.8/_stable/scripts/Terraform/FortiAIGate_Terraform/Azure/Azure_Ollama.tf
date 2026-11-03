resource "azapi_resource" "Ollama_NIC" {
  count     = local.ollama ? 1 : 0
  type      = "Microsoft.Network/networkInterfaces@2024-05-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.ollama_prefix}_NIC"
  location  = var.Azure_Region
  tags      = local.ollama_tags
  body = {
    properties = {
      enableIPForwarding   = false
      networkSecurityGroup = { id = azapi_resource.Ollama_NSG[0].id }
      ipConfigurations = [{
        name = "${local.ollama_prefix}_NIC_IPConfig"
        properties = {
          primary                   = true
          privateIPAllocationMethod = "Static"
          privateIPAddress          = local.ollama_ip
          subnet                    = { id = azapi_resource.FAIG_subnet[0].id }
          publicIPAddress           = { id = azapi_resource.Ollama_PIP[0].id }
        }
      }]
    }
  }
}

resource "azapi_resource" "Ollama_VM" {
  count     = local.ollama ? 1 : 0
  type      = "Microsoft.Compute/virtualMachines@2024-07-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.ollama_prefix}_VM"
  location  = var.Azure_Region
  tags      = local.ollama_tags

  replace_triggers_external_values = [
    sha256(replace(var.Ollama_User_Data, "__FORTIAIGATE_OLLAMA_PUBLIC_IP__", azapi_resource.Ollama_PIP[0].output.properties.ipAddress)),
    sha256(var.ssh_public_key),
  ]

  body = {
    properties = {
      hardwareProfile = { vmSize = var.AZ_Ollama_VM_Size }
      securityProfile = {
        securityType = "TrustedLaunch"
        uefiSettings = { secureBootEnabled = true, vTpmEnabled = true }
      }
      storageProfile = {
        imageReference = {
          publisher = "Canonical"
          offer     = "0001-com-ubuntu-server-jammy"
          sku       = "22_04-lts-gen2"
          version   = "latest"
        }
        osDisk = {
          name         = "${local.ollama_prefix}_OS_Disk"
          createOption = "FromImage"
          caching      = "ReadWrite"
          diskSizeGB   = 64
          deleteOption = "Delete"
          managedDisk  = { storageAccountType = "StandardSSD_LRS" }
        }
      }
      osProfile = {
        computerName  = "${replace(var.username, "_", "-")}-TF-Ollama"
        adminUsername = local.admin
        customData    = base64gzip(replace(var.Ollama_User_Data, "__FORTIAIGATE_OLLAMA_PUBLIC_IP__", azapi_resource.Ollama_PIP[0].output.properties.ipAddress))
        linuxConfiguration = {
          disablePasswordAuthentication = true
          provisionVMAgent              = true
          ssh = { publicKeys = [{
            path    = "/home/${local.admin}/.ssh/authorized_keys"
            keyData = trimspace(var.ssh_public_key)
          }] }
        }
      }
      networkProfile = { networkInterfaces = [{
        id         = azapi_resource.Ollama_NIC[0].id
        properties = { primary = true }
      }] }
    }
  }
}

resource "azapi_resource" "Ollama_Ready" {
  count     = local.ollama ? 1 : 0
  type      = "Microsoft.Compute/virtualMachines/extensions@2024-07-01"
  parent_id = azapi_resource.Ollama_VM[0].id
  name      = "${local.ollama_prefix}_Ready"
  location  = var.Azure_Region

  replace_triggers_external_values = [sha256(var.Ollama_User_Data), sha256(var.Ollama_Readiness_Command)]

  body = {
    properties = {
      publisher               = "Microsoft.Azure.Extensions"
      type                    = "CustomScript"
      typeHandlerVersion      = "2.1"
      autoUpgradeMinorVersion = true
      settings                = { commandToExecute = var.Ollama_Readiness_Command }
    }
  }
  timeouts { create = "75m" }
}
