terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "= 6.71.0" }
    azapi = { source = "Azure/azapi", version = "= 2.13.0" }
    http  = { source = "hashicorp/http", version = "= 3.5.0" }
  }
}

module "FortiAIGate" {
  source                        = "./Shared_Resources"
  AWS_GPU_Allow_Larger_Fallback = var.AWS_GPU_Allow_Larger_Fallback
  SSH_Source_CIDR               = var.SSH_Source_CIDR
  username                      = var.username
  create_FortiAIGate_CPU        = var.create_FortiAIGate_CPU
  create_FortiAIGate_GPU        = var.create_FortiAIGate_GPU
  create_Azure_FortiAIGate_CPU  = var.create_Azure_FortiAIGate_CPU
  create_AWS_Ollama             = var.create_AWS_Ollama
  create_Azure_Ollama           = var.create_Azure_Ollama
  Management_Source_CIDR        = var.Management_Source_CIDR
  virginia_region               = var.virginia_region
  AWS_Availability_Zone         = var.AWS_Availability_Zone
  Azure_Region                  = var.Azure_Region
  AWS_Profile                   = var.AWS_Profile
  AWS_Use_Credentials           = var.AWS_Use_Credentials
  ssh_public_key                = var.ssh_public_key
  FAIG_CPU_VM_Size              = var.FAIG_CPU_VM_Size
  FAIG_GPU_VM_Size              = var.FAIG_GPU_VM_Size
  Ollama_VM_Size                = var.Ollama_VM_Size
  AZ_FAIG_CPU_VM_Size           = var.AZ_FAIG_CPU_VM_Size
  AZ_Ollama_VM_Size             = var.AZ_Ollama_VM_Size
  Gateway_API_Port              = var.Gateway_API_Port
  Show_Installation_Progress    = var.Show_Installation_Progress
  subscription_id               = var.subscription_id
  tenant_id                     = var.tenant_id
  client_id                     = var.client_id
  client_secret                 = var.client_secret
}

output "AWS_FortiAIGate_CPU" {
  value = module.FortiAIGate.AWS_FortiAIGate_CPU
}

output "AWS_FortiAIGate_GPU" {
  value = module.FortiAIGate.AWS_FortiAIGate_GPU
}

output "AWS_Ollama" {
  value = module.FortiAIGate.AWS_Ollama
}

output "Azure_FortiAIGate_CPU" {
  value = module.FortiAIGate.Azure_FortiAIGate_CPU
}

output "Azure_Ollama" {
  value = module.FortiAIGate.Azure_Ollama
}

output "Management_Source_CIDR" {
  value = module.FortiAIGate.Management_Source_CIDR
}

output "Installation_Targets" {
  value = module.FortiAIGate.Installation_Targets
}

output "Next_Steps" {
  value = module.FortiAIGate.Next_Steps
}


output "SSH_Source_CIDR" { value = module.FortiAIGate.SSH_Source_CIDR }
