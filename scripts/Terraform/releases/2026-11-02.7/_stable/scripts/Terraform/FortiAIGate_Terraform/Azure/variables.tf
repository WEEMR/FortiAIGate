// Internal inputs supplied by Shared_Resources/main.tf.
variable "create_Azure_FortiAIGate_CPU" {
  type = string
  validation {
    condition     = contains(["yes", "no"], var.create_Azure_FortiAIGate_CPU)
    error_message = "create_Azure_FortiAIGate_CPU must be yes or no."
  }
}

variable "create_Azure_Ollama" {
  type = string
  validation {
    condition     = contains(["yes", "no"], var.create_Azure_Ollama)
    error_message = "create_Azure_Ollama must be yes or no."
  }
}

variable "username" {
  type = string
}

variable "Azure_Region" {
  type = string
}

variable "Management_Source_CIDR" {
  type = string
}

variable "SSH_Source_CIDR" {
  description = "Optional SSH client IPv4 /32; Shared_Resources detects the Terraform runner. Direct child-module callers default to Management_Source_CIDR."
  type        = string
  default     = null
  validation {
    condition     = var.SSH_Source_CIDR == null ? true : can(cidrnetmask(var.SSH_Source_CIDR)) && try(tonumber(split("/", var.SSH_Source_CIDR)[1]) == 32, false) && !contains(["0.0.0.0/32", "255.255.255.255/32"], var.SSH_Source_CIDR)
    error_message = "SSH_Source_CIDR must be null or one trusted IPv4 /32; broad CIDRs are not accepted."
  }
}

variable "ssh_public_key" {
  type = string
}

variable "AZ_FAIG_CPU_VM_Size" {
  type = string
}

variable "AZ_Ollama_VM_Size" {
  type = string
}

variable "Gateway_API_Port" {
  type = number
}

variable "CPU_User_Data" {
  description = "Shared, pinned CPU host-preparation cloud-init; the interactive vendor installation follows preparation."
  type        = string
}

variable "Ollama_User_Data" {
  description = "Shared, pinned Ollama preparation cloud-init."
  type        = string
}

variable "CPU_Readiness_Command" {
  description = "Guest command that waits for CPU preparation and fails on preparation errors."
  type        = string
}

variable "Ollama_Readiness_Command" {
  description = "Guest command that waits for the Ollama model backend and fails on installation errors."
  type        = string
}

locals {
  enabled       = var.create_Azure_FortiAIGate_CPU == "yes"
  ollama        = local.enabled && var.create_Azure_Ollama == "yes"
  prefix        = "${var.username}_TF_FortiAIGate_CPU"
  ollama_prefix = "${var.username}_TF_Ollama"
  gateway_ip    = "10.250.20.10"
  ollama_ip     = "10.250.20.20"
  admin         = "fortiadmin"
  ssh_source    = var.SSH_Source_CIDR != null ? var.SSH_Source_CIDR : var.Management_Source_CIDR
  tags = {
    ManagedBy   = "Terraform"
    Application = "FortiAIGate"
    Edition     = "CPU"
    Owner       = var.username
  }
  ollama_tags = merge(local.tags, {
    Application = "Ollama"
    Gateway     = local.prefix
  })
}
