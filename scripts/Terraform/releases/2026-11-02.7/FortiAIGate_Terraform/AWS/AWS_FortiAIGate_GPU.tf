locals {
  GPU_Template_SHA256 = filesha256("${path.module}/FortiAIGate_GPU_CloudFormation.json")
  // Exact compatibility mapping for the reviewed allocator-code / workload-IAM
  // dependency update from the retained 2026-11-02.4 template. All resource
  // Properties outside Lambda Code are byte-equivalent (offline regression).
  // Preserve existing VM identity/deadlines; unknown template bytes still
  // change the allocation fingerprint and require replacement as before.
  GPU_Allocation_Template_SHA256 = lookup({
    "f1e111ad33e47826d99d3d2b5d4a7a978a0305d1d3a8c93fb8e878f607e70e6d" = "42d01094c711a03cabc84ea602281bc0281ce69a95e3c3453bc2cc670edf61ff"
    "9d638c2f5654c0f6f8351cf6e5a4180e8367f26fe57360275a05c33e35c94048" = "42d01094c711a03cabc84ea602281bc0281ce69a95e3c3453bc2cc670edf61ff"
  }, local.GPU_Template_SHA256, local.GPU_Template_SHA256)
  GPU_Stack_Name = "FortiAIGate-GPU-${replace(lower(var.username), "_", "-")}-TF"
  GPU_Created_At = timestamp()
  GPU_Delete_At  = timeadd(local.GPU_Created_At, "8h")
  GPU_Allocation_Hash = sha256(jsonencode({
    template              = local.GPU_Allocation_Template_SHA256
    zone                  = var.AWS_Availability_Zone
    preferred_size        = var.FAIG_GPU_VM_Size
    allow_larger_fallback = var.AWS_GPU_Allow_Larger_Fallback
    gpu_user_data         = sha256(var.GPU_User_Data)
    ollama_user_data      = sha256(var.Ollama_User_Data)
    release_bucket        = var.Release_Bucket
    release_prefix        = var.GPU_Release_Prefix
    gpu_ami               = try(data.aws_ami.FortiAIGate_Ubuntu[0].id, "inactive")
  }))
}

// Placement-policy changes require a new lab; the capacity selector must never
// acquire another paid hold while an existing native GPU instance is retained.
resource "terraform_data" "GPU_Allocation_Configuration" {
  count            = local.GPU ? 1 : 0
  triggers_replace = local.GPU_Allocation_Hash
}

// The GPU lab keeps the reviewed CloudShell eight-hour deletion policy. Its
// complete optional Ollama host lives in this same stack and expires with it.
// The separate final cleanup service removes only this stack's retained role.
resource "aws_cloudformation_stack" "FortiAIGate_GPU_FinalCleanup" {
  count         = local.GPU ? 1 : 0
  provider      = aws
  name          = "${local.GPU_Stack_Name}-FinalCleanup"
  template_body = file("${path.module}/FortiAIGate_GPU_FinalCleanup.json")
  capabilities  = ["CAPABILITY_IAM"]
  parameters = {
    TargetStack = local.GPU_Stack_Name
    TargetRole  = "${var.username}_TF_FortiAIGate_GPU_CleanupRole"
  }
  tags = merge(local.Tags, { Name = "${var.username}_TF_FortiAIGate_GPU_FinalCleanup", AllocationConfigurationHash = local.GPU_Allocation_Hash })
  lifecycle {
    replace_triggered_by = [terraform_data.GPU_Allocation_Configuration[0]]
  }
}

resource "aws_cloudformation_stack" "FortiAIGate_GPU" {
  count         = local.GPU ? 1 : 0
  provider      = aws
  name          = local.GPU_Stack_Name
  template_body = file("${path.module}/FortiAIGate_GPU_CloudFormation.json")
  capabilities  = ["CAPABILITY_NAMED_IAM"]
  parameters = {
    NamePrefix          = "${var.username}_TF"
    ManagementCIDR      = var.Management_Source_CIDR
    AvailabilityZone    = var.AWS_Availability_Zone
    AllowLargerFallback = var.AWS_GPU_Allow_Larger_Fallback
    UbuntuAmi           = data.aws_ami.FortiAIGate_Ubuntu[0].id
    InstanceType        = var.FAIG_GPU_VM_Size
    GPUUserData         = base64gzip(var.GPU_User_Data)
    ReleaseBucket       = var.Release_Bucket
    ReleasePrefix       = var.GPU_Release_Prefix
    CreateOllama        = var.create_AWS_Ollama
    OllamaAmi           = var.create_AWS_Ollama == "yes" ? data.aws_ami.Ollama_Ubuntu[0].id : "unused"
    OllamaUserData      = base64gzip(var.Ollama_User_Data)
    OllamaInstanceType  = var.Ollama_VM_Size
    GatewayAPIPort      = tostring(var.Gateway_API_Port)
    BudgetCreatedAt     = local.GPU_Created_At
    BudgetDeleteAt      = local.GPU_Delete_At
    DeleteScheduleTime  = trimsuffix(local.GPU_Delete_At, "Z")
  }
  tags = merge(local.Tags, {
    Name                        = "${var.username}_TF_FortiAIGate_GPU_Stack"
    DeploymentGuide             = "FortiAIGate-GPU-AWS-v1"
    AllocationConfigurationHash = local.GPU_Allocation_Hash
  })
  lifecycle {
    // Updating another input or reconnecting never resets the original clock.
    ignore_changes       = [parameters["BudgetCreatedAt"], parameters["BudgetDeleteAt"], parameters["DeleteScheduleTime"]]
    replace_triggered_by = [terraform_data.GPU_Allocation_Configuration[0]]
  }
  depends_on = [aws_cloudformation_stack.FortiAIGate_GPU_FinalCleanup]
}
