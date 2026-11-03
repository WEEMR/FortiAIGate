output "FortiAIGate_CPU" {
  value = local.CPU ? {
    Public_IP         = aws_eip.FortiAIGate_CPU_PIP[0].public_ip
    Private_IP        = "10.250.20.10"
    Instance_ID       = aws_instance.FortiAIGate_CPU[0].id
    Availability_Zone = aws_instance.FortiAIGate_CPU[0].availability_zone
    URL               = "https://${aws_eip.FortiAIGate_CPU_PIP[0].public_ip}/ui"
    Connect           = "aws ssm start-session --region ${var.virginia_region} --target ${aws_instance.FortiAIGate_CPU[0].id}"
    Connect_URL       = "https://${var.virginia_region}.console.aws.amazon.com/systems-manager/session-manager/${aws_instance.FortiAIGate_CPU[0].id}?region=${var.virginia_region}"
    Install           = "fortiaigate-install"
  } : null
  depends_on = [aws_ssm_association.FortiAIGate_CPU_Ready]
}

output "FortiAIGate_GPU" {
  value = local.GPU ? {
    Public_IP          = try(aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["PublicIPv4"], null)
    Private_IP         = "10.250.20.10"
    Instance_ID        = try(aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["InstanceId"], null)
    Instance_Type      = try(aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["InstanceType"], null)
    Availability_Zone  = try(aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["AvailabilityZone"], null)
    Capacity_Log_Group = try(aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["CapacityLogGroup"], null)
    URL                = try("https://${aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["PublicIPv4"]}/ui", null)
    Connect            = try("aws ssm start-session --region ${var.virginia_region} --target ${aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["InstanceId"]}", null)
    Connect_URL        = try("https://${var.virginia_region}.console.aws.amazon.com/systems-manager/session-manager/${aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["InstanceId"]}?region=${var.virginia_region}", null)
    Install            = "fortiaigate-install"
    Delete_At_UTC      = try(aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["BudgetDeleteAt"], null)
    Stack_Name         = local.GPU_Stack_Name
    Extend             = "python3 AWS/Extend_GPU.py --stack-name ${local.GPU_Stack_Name} --region ${var.virginia_region}"
    Resume             = "python3 AWS/Resume_GPU.py --stack-name ${local.GPU_Stack_Name} --region ${var.virginia_region}"
  } : null
}

// Independent of the CloudFormation resource: capacity messages can stream
// while that resource is still creating and before a GPU VM exists.
output "Capacity_Target" {
  value = local.GPU ? {
    cloud                = "aws"
    stack_name           = local.GPU_Stack_Name
    region               = var.virginia_region
    expected_name_prefix = "${var.username}_TF"
    configuration_hash   = local.GPU_Allocation_Hash
  } : null
}

output "Ollama" {
  value = merge(
    local.Ollama ? { CPU = {
      Public_IP    = aws_eip.Ollama_CPU_PIP[0].public_ip
      Private_IP   = "10.250.20.20"
      Instance_ID  = aws_instance.Ollama_CPU[0].id
      Browser_URL  = "http://${aws_eip.Ollama_CPU_PIP[0].public_ip}:3000"
      URL          = "http://${aws_eip.Ollama_CPU_PIP[0].public_ip}:3000"
      Provider_URL = "http://10.250.20.20:11434/v1"
      Gateway_URL  = "https://10.250.20.10:${var.Gateway_API_Port}/ai/openai/v1"
      Connect      = "aws ssm start-session --region ${var.virginia_region} --target ${aws_instance.Ollama_CPU[0].id}"
      Connect_URL  = "https://${var.virginia_region}.console.aws.amazon.com/systems-manager/session-manager/${aws_instance.Ollama_CPU[0].id}?region=${var.virginia_region}"
      Configure    = "sudo ollama-lab configure --manual"
    } } : {},
    local.GPU && var.create_AWS_Ollama == "yes" ? { GPU = {
      Public_IP    = try(aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["OllamaPublicIp"], null)
      Private_IP   = "10.250.20.20"
      Instance_ID  = try(aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["OllamaInstanceId"], null)
      Browser_URL  = try("http://${aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["OllamaPublicIp"]}:3000", null)
      URL          = try("http://${aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["OllamaPublicIp"]}:3000", null)
      Provider_URL = "http://10.250.20.20:11434/v1"
      Gateway_URL  = "https://10.250.20.10:${var.Gateway_API_Port}/ai/openai/v1"
      Connect      = try("aws ssm start-session --region ${var.virginia_region} --target ${aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["OllamaInstanceId"]}", null)
      Connect_URL  = try("https://${var.virginia_region}.console.aws.amazon.com/systems-manager/session-manager/${aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["OllamaInstanceId"]}?region=${var.virginia_region}", null)
      Configure    = "sudo ollama-lab configure --manual"
    } } : {},
  )
  depends_on = [aws_ssm_association.Ollama_CPU_Ready]
}

// Deliberately independent of readiness so the local watcher can stream stages.
output "Installation_Targets" {
  value = merge(
    local.CPU ? { CPU = {
      cloud = "aws", edition = "cpu", instance_id = aws_instance.FortiAIGate_CPU[0].id, region = var.virginia_region
    } } : {},
    local.GPU ? { GPU = {
      cloud = "aws", edition = "gpu", instance_id = aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["InstanceId"], region = var.virginia_region
    } } : {},
    local.Ollama ? { Ollama_CPU = {
      cloud = "aws", edition = "ollama", instance_id = aws_instance.Ollama_CPU[0].id, region = var.virginia_region
    } } : {},
    local.GPU && var.create_AWS_Ollama == "yes" ? { Ollama_GPU = {
      cloud = "aws", edition = "ollama", instance_id = aws_cloudformation_stack.FortiAIGate_GPU[0].outputs["OllamaInstanceId"], region = var.virginia_region
    } } : {},
  )
}
