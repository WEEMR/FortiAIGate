module "AWS_FortiAIGate" {
  source                        = "../AWS"
  providers                     = { aws = aws.FortiAIGate }
  AWS_GPU_Allow_Larger_Fallback = var.AWS_GPU_Allow_Larger_Fallback
  username                      = var.username
  create_FortiAIGate_CPU        = var.create_FortiAIGate_CPU
  create_FortiAIGate_GPU        = var.create_FortiAIGate_GPU
  create_AWS_Ollama             = var.create_AWS_Ollama
  virginia_region               = var.virginia_region
  AWS_Availability_Zone         = var.AWS_Availability_Zone
  FAIG_CPU_VM_Size              = var.FAIG_CPU_VM_Size
  FAIG_GPU_VM_Size              = var.FAIG_GPU_VM_Size
  Ollama_VM_Size                = var.Ollama_VM_Size
  Management_Source_CIDR        = local.Management_Source_CIDR
  Gateway_API_Port              = var.Gateway_API_Port
  Release_Bucket                = local.Release_Bucket
  CPU_Release_Prefix            = local.CPU_Release_Prefix
  GPU_Release_Prefix            = local.GPU_Release_Prefix
  CPU_User_Data                 = local.Gateway_User_Data.AWS_CPU
  GPU_User_Data                 = local.Gateway_User_Data.AWS_GPU
  Ollama_User_Data              = local.Ollama_User_Data.aws
  CPU_Readiness_Command         = local.CPU_Readiness_Command
  GPU_Readiness_Command         = local.GPU_Readiness_Command
  Ollama_Readiness_Command      = local.Ollama_Readiness_Command
}

module "Azure_FortiAIGate" {
  source                       = "../Azure"
  providers                    = { azapi = azapi.FortiAIGate }
  username                     = var.username
  create_Azure_FortiAIGate_CPU = var.create_Azure_FortiAIGate_CPU
  create_Azure_Ollama          = var.create_Azure_Ollama
  Azure_Region                 = var.Azure_Region
  Management_Source_CIDR       = local.Management_Source_CIDR
  SSH_Source_CIDR              = local.SSH_Source_CIDR
  ssh_public_key               = var.ssh_public_key
  AZ_FAIG_CPU_VM_Size          = var.AZ_FAIG_CPU_VM_Size
  AZ_Ollama_VM_Size            = var.AZ_Ollama_VM_Size
  Gateway_API_Port             = var.Gateway_API_Port
  CPU_User_Data                = local.Gateway_User_Data.Azure_CPU
  Ollama_User_Data             = local.Ollama_User_Data.azure
  CPU_Readiness_Command        = local.CPU_Readiness_Command
  Ollama_Readiness_Command     = local.Ollama_Readiness_Command
}
