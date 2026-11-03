// Available as soon as VM identifiers are known, while readiness extensions are running.
output "Installation_Targets" {
  value = merge(
    local.enabled ? {
      CPU = {
        cloud          = "azure"
        edition        = "cpu"
        resource_group = azapi_resource.FAIG_RG[0].name
        vm_name        = azapi_resource.FortiAIGate_CPU_VM[0].name
        region         = var.Azure_Region
      }
    } : {},
    local.ollama ? {
      Ollama = {
        cloud          = "azure"
        edition        = "ollama"
        resource_group = azapi_resource.FAIG_RG[0].name
        vm_name        = azapi_resource.Ollama_VM[0].name
        region         = var.Azure_Region
      }
    } : {}
  )
}

output "FortiAIGate_CPU" {
  value = local.enabled ? {
    Public_IP            = azapi_resource.FortiAIGate_CPU_PIP[0].output.properties.ipAddress
    Private_IP           = local.gateway_ip
    VM_ID                = azapi_resource.FortiAIGate_CPU_VM[0].id
    Connect_URL          = "https://portal.azure.com/#resource${azapi_resource.FortiAIGate_CPU_VM[0].id}"
    Connect_Instructions = "In the VM portal, choose Connect > Native SSH. Use fortiadmin and your matching private key from the allowed SSH source IP."
    Resource_Group       = azapi_resource.FAIG_RG[0].name
    VM_Name              = azapi_resource.FortiAIGate_CPU_VM[0].name
    URL                  = "https://${azapi_resource.FortiAIGate_CPU_PIP[0].output.properties.ipAddress}/ui"
    Connect              = "ssh fortiadmin@${azapi_resource.FortiAIGate_CPU_PIP[0].output.properties.ipAddress}"
    Install              = "Inside Ubuntu: sudo fortiaigate-prep-status, then fortiaigate-install."
    Status               = "Host preparation completed; vendor installation and licensing are interactive."
  } : null
  depends_on = [azapi_resource.FortiAIGate_CPU_Ready]
}

output "Ollama" {
  value = local.ollama ? {
    Public_IP            = azapi_resource.Ollama_PIP[0].output.properties.ipAddress
    Private_IP           = local.ollama_ip
    VM_ID                = azapi_resource.Ollama_VM[0].id
    Connect_URL          = "https://portal.azure.com/#resource${azapi_resource.Ollama_VM[0].id}"
    Connect_Instructions = "In the VM portal, choose Connect > Native SSH. Use fortiadmin and your matching private key from the allowed SSH source IP."
    Resource_Group       = azapi_resource.FAIG_RG[0].name
    VM_Name              = azapi_resource.Ollama_VM[0].name
    URL                  = "http://${azapi_resource.Ollama_PIP[0].output.properties.ipAddress}:3000"
    Browser_URL          = "http://${azapi_resource.Ollama_PIP[0].output.properties.ipAddress}:3000"
    Provider_URL         = "http://${local.ollama_ip}:11434/v1"
    Gateway_URL          = "https://${local.gateway_ip}${var.Gateway_API_Port == 443 ? "" : ":${var.Gateway_API_Port}"}/ai/openai/v1"
    Model                = "llama-lab"
    Connect              = "ssh fortiadmin@${azapi_resource.Ollama_PIP[0].output.properties.ipAddress}"
    Configure            = "sudo ollama-lab configure --manual"
    Status               = "Model backend ready; configure the provider, virtual key and trusted gateway certificate before WebUI setup."
  } : null
  depends_on = [azapi_resource.Ollama_Ready]
}
