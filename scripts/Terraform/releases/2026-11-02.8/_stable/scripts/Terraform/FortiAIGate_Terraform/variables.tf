variable "username" {
  description = "Resource name prefix, preserving the FortiAIOps <username>_TF_<product>_<resource> convention."
  type        = string
  default     = "fortilab"
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,19}$", var.username))
    error_message = "Use 1-20 letters, digits or underscores, starting with a letter."
  }
}

variable "create_FortiAIGate_CPU" {
  description = "Create FortiAIGate CPU on AWS."
  type        = string
  default     = "no"
  validation {
    condition     = contains(["yes", "no"], var.create_FortiAIGate_CPU)
    error_message = "create_FortiAIGate_CPU must be yes or no."
  }
}

variable "create_FortiAIGate_GPU" {
  description = "Create FortiAIGate GPU on AWS with its fixed eight-hour deletion deadline."
  type        = string
  default     = "no"
  validation {
    condition     = contains(["yes", "no"], var.create_FortiAIGate_GPU)
    error_message = "create_FortiAIGate_GPU must be yes or no."
  }
}

variable "create_Azure_FortiAIGate_CPU" {
  description = "Create FortiAIGate CPU on Azure. Azure GPU is not implemented."
  type        = string
  default     = "no"
  validation {
    condition     = contains(["yes", "no"], var.create_Azure_FortiAIGate_CPU)
    error_message = "create_Azure_FortiAIGate_CPU must be yes or no."
  }
}

variable "create_AWS_Ollama" {
  description = "Create one Ollama companion for each enabled AWS gateway."
  type        = string
  default     = "no"
  validation {
    condition     = contains(["yes", "no"], var.create_AWS_Ollama)
    error_message = "create_AWS_Ollama must be yes or no."
  }
  validation {
    condition     = var.create_AWS_Ollama != "yes" || var.create_FortiAIGate_CPU == "yes" || var.create_FortiAIGate_GPU == "yes"
    error_message = "AWS Ollama requires an enabled AWS CPU or GPU gateway."
  }
}

variable "create_Azure_Ollama" {
  description = "Create an Ollama companion for the Azure CPU gateway."
  type        = string
  default     = "no"
  validation {
    condition     = contains(["yes", "no"], var.create_Azure_Ollama)
    error_message = "create_Azure_Ollama must be yes or no."
  }
  validation {
    condition     = var.create_Azure_Ollama != "yes" || var.create_Azure_FortiAIGate_CPU == "yes"
    error_message = "Azure Ollama requires the Azure CPU gateway."
  }
}

variable "Management_Source_CIDR" {
  description = "Your computer browser public IPv4 /32 allowed to open HTTPS/WebUI. Null detects the Terraform runner; CloudShell users must supply the browser address."
  type        = string
  default     = null
  validation {
    condition     = var.Management_Source_CIDR == null ? true : can(cidrnetmask(var.Management_Source_CIDR)) && try(tonumber(split("/", var.Management_Source_CIDR)[1]) == 32, false) && !contains(["0.0.0.0/32", "255.255.255.255/32"], var.Management_Source_CIDR)
    error_message = "Use a trusted single IPv4 /32; broad CIDRs are not accepted."
  }
}

variable "virginia_region" {
  description = "AWS deployment region."
  type        = string
  default     = "us-east-1"
}

variable "AWS_Availability_Zone" {
  description = "AWS zone: auto tries supported GPU zones; an explicit zone limits placement to that zone."
  type        = string
  default     = "auto"
  validation {
    condition     = var.AWS_Availability_Zone == "auto" || (can(regex("^[a-z]{2}(?:-[a-z]+)+-[0-9][a-z]$", var.AWS_Availability_Zone)) && startswith(var.AWS_Availability_Zone, var.virginia_region))
    error_message = "Use auto or an Availability Zone in virginia_region."
  }
}

variable "Azure_Region" {
  description = "Azure deployment region."
  type        = string
  default     = "eastus"
}

variable "AWS_Profile" {
  description = "Optional AWS CLI profile; null uses the standard credential chain."
  type        = string
  default     = null
}

variable "AWS_Use_Credentials" {
  description = "Keep AWS authentication enabled when disabling existing AWS resources for refresh or destroy."
  type        = string
  default     = "no"
  validation {
    condition     = contains(["yes", "no"], var.AWS_Use_Credentials)
    error_message = "AWS_Use_Credentials must be yes or no."
  }
}

variable "ssh_public_key" {
  description = "Existing OpenSSH public key for Azure. Supply the .pub contents; AWS administration uses Session Manager."
  type        = string
  default     = ""
  validation {
    condition     = var.create_Azure_FortiAIGate_CPU != "yes" || can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+=*( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "Azure requires an existing OpenSSH public key, never its private key."
  }
}

variable "FAIG_CPU_VM_Size" {
  description = "AWS CPU instance size; matches the small CloudShell lab."
  type        = string
  default     = "t3a.large"
  validation {
    condition     = can(regex("^t3a?\\.(large|xlarge|2xlarge)$", var.FAIG_CPU_VM_Size))
    error_message = "Use t3.large/t3a.large or their xlarge/2xlarge sizes for the x86 CPU lab."
  }
}

variable "FAIG_GPU_VM_Size" {
  description = "AWS L40S GPU instance size, explicitly selected without automatic paid fallback."
  type        = string
  default     = "g6e.2xlarge"
  validation {
    condition     = contains(["g6e.2xlarge", "g6e.4xlarge"], var.FAIG_GPU_VM_Size)
    error_message = "Use g6e.2xlarge or an explicitly selected g6e.4xlarge; no automatic fallback is performed."
  }
}

variable "Ollama_VM_Size" {
  description = "AWS CPU Ollama companion size."
  type        = string
  default     = "t3a.large"
  validation {
    condition     = can(regex("^t3a?\\.(large|xlarge|2xlarge)$", var.Ollama_VM_Size))
    error_message = "Use an x86 t3/t3a.large, xlarge or 2xlarge Ollama host."
  }
}

variable "AZ_FAIG_CPU_VM_Size" {
  description = "Azure CPU lab size."
  type        = string
  default     = "Standard_B2as_v2"
}

variable "AZ_Ollama_VM_Size" {
  description = "Azure CPU Ollama companion size."
  type        = string
  default     = "Standard_B2as_v2"
}

variable "Gateway_API_Port" {
  description = "Private TLS API port allowed from Ollama; Terraform forwards a nondefault port to FortiAIGate HTTPS. Browser access stays on 443."
  type        = number
  default     = 443
  validation {
    condition     = var.Gateway_API_Port >= 1 && var.Gateway_API_Port <= 65535 && floor(var.Gateway_API_Port) == var.Gateway_API_Port && !contains([22, 3000, 11434], var.Gateway_API_Port)
    error_message = "Choose an integer TCP API port excluding SSH22, WebUI3000 and Ollama11434."
  }
}

variable "Show_Installation_Progress" {
  description = "Show preparation and application installation stages. Gateways are installed even when no; Python3 and the enabled-cloud CLI are always required."
  type        = string
  default     = "yes"
  validation {
    condition     = contains(["yes", "no"], var.Show_Installation_Progress)
    error_message = "Show_Installation_Progress must be yes or no."
  }
}

variable "subscription_id" {
  description = "Optional Azure subscription ID; otherwise use ARM_SUBSCRIPTION_ID or Azure CLI."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "Optional Azure tenant ID; otherwise use normal Azure authentication."
  type        = string
  default     = null
}

variable "client_id" {
  description = "Optional Azure service-principal client ID; otherwise use normal Azure authentication."
  type        = string
  default     = null
}

variable "client_secret" {
  description = "Optional Azure service-principal secret; prefer ARM_CLIENT_SECRET in the environment."
  type        = string
  default     = null
  sensitive   = true
}

variable "AWS_GPU_Allow_Larger_Fallback" {
  description = "Explicitly approve the higher-cost g6e.4xlarge only after all selected g6e.2xlarge zones return insufficient capacity. No means stop; never silently upsize."
  type        = string
  default     = "no"
  validation {
    condition     = contains(["yes", "no"], var.AWS_GPU_Allow_Larger_Fallback)
    error_message = "AWS_GPU_Allow_Larger_Fallback must be yes or no."
  }
  validation {
    condition     = var.AWS_GPU_Allow_Larger_Fallback != "yes" || var.FAIG_GPU_VM_Size == "g6e.2xlarge"
    error_message = "Larger fallback is available only from the preferred g6e.2xlarge size."
  }
}

variable "SSH_Source_CIDR" {
  description = "Optional Azure SSH client IPv4 /32. Null detects the Terraform runner (including CloudShell); browser HTTPS still uses Management_Source_CIDR."
  type        = string
  default     = null
  validation {
    condition     = var.SSH_Source_CIDR == null ? true : can(cidrnetmask(var.SSH_Source_CIDR)) && try(tonumber(split("/", var.SSH_Source_CIDR)[1]) == 32, false) && !contains(["0.0.0.0/32", "255.255.255.255/32"], var.SSH_Source_CIDR)
    error_message = "SSH_Source_CIDR must be null or one trusted IPv4 /32."
  }
}
