variable "username" { type = string }
variable "create_FortiAIGate_CPU" { type = string }
variable "create_FortiAIGate_GPU" { type = string }
variable "create_AWS_Ollama" { type = string }
variable "virginia_region" { type = string }
variable "AWS_Availability_Zone" { type = string }
variable "AWS_GPU_Allow_Larger_Fallback" {
  type    = string
  default = "no"
}
variable "FAIG_CPU_VM_Size" { type = string }
variable "FAIG_GPU_VM_Size" { type = string }
variable "Ollama_VM_Size" { type = string }
variable "Management_Source_CIDR" { type = string }
variable "Gateway_API_Port" { type = number }
variable "Release_Bucket" { type = string }
variable "CPU_Release_Prefix" { type = string }
variable "GPU_Release_Prefix" { type = string }
variable "CPU_User_Data" { type = string }
variable "GPU_User_Data" { type = string }
variable "Ollama_User_Data" { type = string }
variable "CPU_Readiness_Command" { type = string }
variable "GPU_Readiness_Command" { type = string }
variable "Ollama_Readiness_Command" { type = string }

locals {
  CPU    = var.create_FortiAIGate_CPU == "yes"
  GPU    = var.create_FortiAIGate_GPU == "yes"
  Ollama = local.CPU && var.create_AWS_Ollama == "yes"
  Prefix = "${var.username}_TF_FortiAIGate_CPU"
  Tags = {
    ManagedBy   = "Terraform"
    Application = "FortiAIGate"
    Owner       = var.username
  }
}
