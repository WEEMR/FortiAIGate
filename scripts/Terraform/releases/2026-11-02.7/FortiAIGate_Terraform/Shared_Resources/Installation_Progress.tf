locals {
  Installation_Targets = merge(
    { for name, target in module.AWS_FortiAIGate.Installation_Targets : "AWS_${name}" => merge(target, { aws_profile = var.AWS_Profile == null ? "" : var.AWS_Profile }) },
    { for name, target in module.Azure_FortiAIGate.Installation_Targets : "Azure_${name}" => target }
  )
}

locals {
  Application_Installer_Hash = sha256(join("", [
    filesha256("${path.module}/Install_FortiAIGate.py"),
    filesha256("${path.module}/Install_FortiAIGate_Guest.py"),
    filesha256("${path.module}/Watch_Installation.py"),
  ]))
}

// Gateways continue from host preparation through the actual vendor installer.
// This post-provisioning step can also install onto an existing prepared VM;
// changing the application worker does not replace its VM or reset the GPU timer.
// Ollama retains its existing read-only readiness/configuration handoff.
resource "terraform_data" "Installation_Progress" {
  for_each = { for name, target in local.Installation_Targets : name => target
    if target.edition != "ollama" || var.Show_Installation_Progress == "yes"
  }
  input = merge(each.value, each.value.edition == "ollama" ? {} : {
    gateway_api_port = var.Gateway_API_Port
  })
  triggers_replace = [each.value, each.value.edition == "ollama" ? null : local.Application_Installer_Hash,
  each.value.edition == "ollama" ? null : var.Gateway_API_Port]
  provisioner "local-exec" {
    command = each.value.edition == "ollama" ? "python3 \"$FORTIAIGATE_WATCHER\" --target-json-env FORTIAIGATE_TARGET" : "python3 \"$FORTIAIGATE_WATCHER\" --target-json-env FORTIAIGATE_TARGET --show-progress ${var.Show_Installation_Progress}"
    environment = {
      FORTIAIGATE_WATCHER = abspath("${path.module}/${each.value.edition == "ollama" ? "Watch_Installation.py" : "Install_FortiAIGate.py"}")
      FORTIAIGATE_TARGET  = jsonencode(self.input)
    }
  }
}

locals {
  // This output contains configuration only, so the watcher can start before
  // CloudFormation returns a stack ID or finishes allocating GPU capacity.
  GPU_Capacity_Target = var.create_FortiAIGate_GPU == "yes" ? merge(
    module.AWS_FortiAIGate.Capacity_Target,
    { aws_profile = var.AWS_Profile == null ? "" : var.AWS_Profile }
  ) : null
}

// Read-only: first creation and configuration changes stream stack/capacity
// progress. Unchanged later applies do not create an artificial perpetual diff.
// After external expiry/recreation, Watch_Capacity.py can be run independently;
// the host watcher above also reruns when the resulting instance ID changes.
resource "terraform_data" "GPU_Capacity_Progress" {
  count            = var.create_FortiAIGate_GPU == "yes" && var.Show_Installation_Progress == "yes" ? 1 : 0
  input            = local.GPU_Capacity_Target
  triggers_replace = [local.GPU_Capacity_Target]
  provisioner "local-exec" {
    command = "python3 \"$FORTIAIGATE_CAPACITY_WATCHER\" --target-json-env FORTIAIGATE_CAPACITY_TARGET"
    environment = {
      FORTIAIGATE_CAPACITY_WATCHER = abspath("${path.module}/Watch_Capacity.py")
      FORTIAIGATE_CAPACITY_TARGET  = jsonencode(local.GPU_Capacity_Target)
    }
  }
}
