resource "azapi_resource" "FortiAIGate_CPU_NIC" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.Network/networkInterfaces@2024-05-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.prefix}_NIC"
  location  = var.Azure_Region
  tags      = local.tags
  body = {
    properties = {
      enableIPForwarding   = false
      networkSecurityGroup = { id = azapi_resource.FortiAIGate_CPU_NSG[0].id }
      ipConfigurations = [{
        name = "${local.prefix}_NIC_IPConfig"
        properties = {
          primary                   = true
          privateIPAllocationMethod = "Static"
          privateIPAddress          = local.gateway_ip
          subnet                    = { id = azapi_resource.FAIG_subnet[0].id }
          publicIPAddress           = { id = azapi_resource.FortiAIGate_CPU_PIP[0].id }
        }
      }]
    }
  }
}

resource "azapi_resource" "FortiAIGate_CPU_VM" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.Compute/virtualMachines@2024-07-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.prefix}_VM"
  location  = var.Azure_Region
  tags      = local.tags

  // Custom-data/key changes need a fresh guest; they cannot be applied by updating Azure metadata.
  replace_triggers_external_values = [sha256(var.CPU_User_Data), sha256(var.ssh_public_key)]

  body = {
    properties = {
      hardwareProfile = { vmSize = var.AZ_FAIG_CPU_VM_Size }
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
          name         = "${local.prefix}_OS_Disk"
          createOption = "FromImage"
          caching      = "ReadWrite"
          diskSizeGB   = 128
          deleteOption = "Delete"
          managedDisk  = { storageAccountType = "StandardSSD_LRS" }
        }
      }
      osProfile = {
        computerName  = "${replace(var.username, "_", "-")}-TF-FAIG-CPU"
        adminUsername = local.admin
        customData    = base64gzip(var.CPU_User_Data)
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
        id         = azapi_resource.FortiAIGate_CPU_NIC[0].id
        properties = { primary = true }
      }] }
    }
  }
}

resource "azapi_resource" "FortiAIGate_CPU_Ready" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.Compute/virtualMachines/extensions@2024-07-01"
  parent_id = azapi_resource.FortiAIGate_CPU_VM[0].id
  name      = "${local.prefix}_Ready"
  location  = var.Azure_Region

  replace_triggers_external_values = [sha256(var.CPU_User_Data), sha256(var.CPU_Readiness_Command)]

  body = {
    properties = {
      publisher               = "Microsoft.Azure.Extensions"
      type                    = "CustomScript"
      typeHandlerVersion      = "2.1"
      autoUpgradeMinorVersion = true
      settings                = { commandToExecute = var.CPU_Readiness_Command }
    }
  }
  timeouts { create = "75m" }
}
