resource "azapi_resource" "FortiAIGate_CPU_PIP" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.Network/publicIPAddresses@2024-05-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.prefix}_PIP"
  location  = var.Azure_Region
  tags      = local.tags

  body = {
    sku = { name = "Standard" }
    properties = {
      publicIPAllocationMethod = "Static"
      publicIPAddressVersion   = "IPv4"
    }
  }
  response_export_values = ["properties.ipAddress"]
}

resource "azapi_resource" "Ollama_PIP" {
  count     = local.ollama ? 1 : 0
  type      = "Microsoft.Network/publicIPAddresses@2024-05-01"
  parent_id = azapi_resource.FAIG_RG[0].id
  name      = "${local.ollama_prefix}_PIP"
  location  = var.Azure_Region
  tags      = local.ollama_tags

  body = {
    sku = { name = "Standard" }
    properties = {
      publicIPAllocationMethod = "Static"
      publicIPAddressVersion   = "IPv4"
    }
  }
  response_export_values = ["properties.ipAddress"]
}
