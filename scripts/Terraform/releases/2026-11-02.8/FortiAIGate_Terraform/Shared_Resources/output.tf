output "AWS_FortiAIGate_CPU" {
  value = module.AWS_FortiAIGate.FortiAIGate_CPU == null ? null : merge(module.AWS_FortiAIGate.FortiAIGate_CPU, {
    Install = "Completed by Terraform; open the WebUI for setup and licensing."
    Status  = "Application containers and WebUI ready; setup and licensing remain manual."
  })
  depends_on = [terraform_data.Installation_Progress]
}
output "AWS_FortiAIGate_GPU" {
  value = module.AWS_FortiAIGate.FortiAIGate_GPU == null ? null : merge(module.AWS_FortiAIGate.FortiAIGate_GPU, {
    Install = "Completed by Terraform; open the WebUI for setup and licensing."
    Status  = "Application containers and WebUI ready; setup and licensing remain manual. GPU model readiness and licensed inspection must be verified after licensing."
  })
  depends_on = [terraform_data.Installation_Progress]
}
output "AWS_Ollama" { value = module.AWS_FortiAIGate.Ollama }
output "Azure_FortiAIGate_CPU" {
  value = module.Azure_FortiAIGate.FortiAIGate_CPU == null ? null : merge(module.Azure_FortiAIGate.FortiAIGate_CPU, {
    Install = "Completed by Terraform; open the WebUI for setup and licensing."
    Status  = "Application containers and WebUI ready; setup and licensing remain manual."
  })
  depends_on = [terraform_data.Installation_Progress]
}
output "Azure_Ollama" { value = module.Azure_FortiAIGate.Ollama }
output "Management_Source_CIDR" { value = local.Management_Source_CIDR }
output "Installation_Targets" { value = local.Installation_Targets }

locals {
  // Keep each companion next to its gateway: both AWS editions may be selected.
  Deployment_Links = concat(
    var.create_FortiAIGate_CPU == "yes" ? [{
      label       = "AWS CPU"
      gateway     = module.AWS_FortiAIGate.FortiAIGate_CPU
      ollama      = try(module.AWS_FortiAIGate.Ollama.CPU, null)
      certificate = "python3 Shared_Resources/Prepare_Gateway_Certificate.py --cloud aws --edition cpu"
    }] : [],
    var.create_FortiAIGate_GPU == "yes" ? [{
      label       = "AWS GPU"
      gateway     = module.AWS_FortiAIGate.FortiAIGate_GPU
      ollama      = try(module.AWS_FortiAIGate.Ollama.GPU, null)
      certificate = "python3 Shared_Resources/Prepare_Gateway_Certificate.py --cloud aws --edition gpu"
    }] : [],
    var.create_Azure_FortiAIGate_CPU == "yes" ? [{
      label       = "Azure CPU"
      gateway     = module.Azure_FortiAIGate.FortiAIGate_CPU
      ollama      = module.Azure_FortiAIGate.Ollama
      certificate = "python3 Shared_Resources/Prepare_Gateway_Certificate.py --cloud azure"
    }] : [],
  )
}

output "Next_Steps" {
  value = local.Any_Cloud ? join("\n\n", concat(
    ["Terraform installed FortiAIGate and verified its application containers, database health and WebUI. Open the full URLs below using your terminal's link shortcut."],
    [for deployment in local.Deployment_Links : join("\n", concat(
      [
        "${deployment.label} — FortiAIGate",
        "1. Complete WebUI administrator setup and licensing:",
        "   ${deployment.gateway.URL}",
        "   The one-time API restart after WebUI setup runs automatically on the VM.",
        "2. Verify licensed inspection in the WebUI above; application readiness does not certify licensing or inference readiness.",
        "   FortiAIGate Connect (${startswith(deployment.label, "AWS") ? "AWS Session Manager" : "Azure portal: Connect > Native SSH"}):",
        "   ${deployment.gateway.Connect_URL}",
      ],
      deployment.ollama == null ? [] : [
        "3. In this gateway's WebUI, add the OpenAI-compatible provider ${deployment.ollama.Provider_URL}, map model llama-lab and create its virtual key:",
        "   ${deployment.gateway.URL}",
        "4. From this local Terraform directory, export and verify the gateway's public certificate:",
        "   ${deployment.certificate}",
        "5. Open this gateway's Ollama Connect link (${startswith(deployment.label, "AWS") ? "AWS Session Manager" : "Azure portal: Connect > Native SSH"}):",
        "   ${deployment.ollama.Connect_URL}",
        "   Run: ${deployment.ollama.Configure}",
        "   Gateway API: ${deployment.ollama.Gateway_URL}",
        "   Certificate: /opt/ollama-lab/imported-gateway-ca.crt; enter the virtual key at its hidden prompt.",
        "6. After configure verifies inference through FortiAIGate, open Ollama / Open WebUI:",
        "   ${deployment.ollama.URL}",
      ],
      deployment.label == "AWS GPU" ? ["   GPU lab deletion deadline (UTC), including linked Ollama: ${deployment.gateway.Delete_At_UTC}. The eight-hour clock includes setup time."] : [],
    ))],
    ["Keep this directory and Terraform state for cleanup. Review terraform plan -destroy, then use terraform destroy when finished."],
  )) : "No deployments selected. Edit User_Input.auto.tfvars to enable the desired cloud and companions."
  depends_on = [terraform_data.Installation_Progress]
}

output "SSH_Source_CIDR" { value = local.SSH_Source_CIDR }
