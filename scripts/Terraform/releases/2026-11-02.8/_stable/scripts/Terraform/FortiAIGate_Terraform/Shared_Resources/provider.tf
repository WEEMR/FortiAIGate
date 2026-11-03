terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "= 6.71.0" }
    azapi = { source = "Azure/azapi", version = "= 2.13.0" }
    http  = { source = "hashicorp/http", version = "= 3.5.0" }
  }
}

locals {
  AWS_Authentication_Required = var.create_FortiAIGate_CPU == "yes" || var.create_FortiAIGate_GPU == "yes" || var.AWS_Use_Credentials == "yes"
  Any_Cloud                   = var.create_FortiAIGate_CPU == "yes" || var.create_FortiAIGate_GPU == "yes" || var.create_Azure_FortiAIGate_CPU == "yes"
}

provider "aws" {
  alias                       = "FortiAIGate"
  region                      = var.virginia_region
  profile                     = local.AWS_Authentication_Required ? var.AWS_Profile : null
  access_key                  = local.AWS_Authentication_Required ? null : "fortiaigate-inactive"
  secret_key                  = local.AWS_Authentication_Required ? null : "fortiaigate-inactive"
  skip_credentials_validation = !local.AWS_Authentication_Required
  skip_requesting_account_id  = !local.AWS_Authentication_Required
  skip_metadata_api_check     = !local.AWS_Authentication_Required
}

provider "azapi" {
  alias                      = "FortiAIGate"
  subscription_id            = var.subscription_id
  tenant_id                  = var.tenant_id
  client_id                  = var.client_id
  client_secret              = var.client_secret
  skip_provider_registration = true
  enable_preflight           = false
}
