data "aws_ami" "Ollama_Ubuntu" {
  count       = var.create_AWS_Ollama == "yes" && (local.CPU || local.GPU) ? 1 : 0
  provider    = aws
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_security_group" "Ollama_CPU_NSG" {
  count       = local.Ollama ? 1 : 0
  provider    = aws
  name        = "${var.username}_TF_Ollama_CPU_NSG"
  description = "Private Ollama model and restricted operator browser"
  vpc_id      = aws_vpc.FortiAIGate_CPU_VPC[0].id
  tags        = merge(local.Tags, { Name = "${var.username}_TF_Ollama_CPU_NSG" })
}

resource "aws_vpc_security_group_ingress_rule" "Ollama_CPU_Model" {
  count                        = local.Ollama ? 1 : 0
  provider                     = aws
  security_group_id            = aws_security_group.Ollama_CPU_NSG[0].id
  referenced_security_group_id = aws_security_group.FortiAIGate_CPU_NSG[0].id
  ip_protocol                  = "tcp"
  from_port                    = 11434
  to_port                      = 11434
  description                  = "Model traffic from the linked FortiAIGate only"
}

resource "aws_vpc_security_group_ingress_rule" "Ollama_CPU_WebUI" {
  count             = local.Ollama ? 1 : 0
  provider          = aws
  security_group_id = aws_security_group.Ollama_CPU_NSG[0].id
  cidr_ipv4         = var.Management_Source_CIDR
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
  description       = "Open WebUI browser from the operator only"
}

resource "aws_vpc_security_group_egress_rule" "Ollama_CPU_Egress" {
  count             = local.Ollama ? 1 : 0
  provider          = aws
  security_group_id = aws_security_group.Ollama_CPU_NSG[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "Ollama_CPU_Gateway_API" {
  count                        = local.Ollama ? 1 : 0
  provider                     = aws
  security_group_id            = aws_security_group.FortiAIGate_CPU_NSG[0].id
  referenced_security_group_id = aws_security_group.Ollama_CPU_NSG[0].id
  ip_protocol                  = "tcp"
  from_port                    = var.Gateway_API_Port
  to_port                      = var.Gateway_API_Port
  description                  = "Ollama client access to the linked gateway API"
}

resource "aws_network_interface" "Ollama_CPU_NIC" {
  count           = local.Ollama ? 1 : 0
  provider        = aws
  subnet_id       = aws_subnet.FAIG_CPU_Subnet[0].id
  private_ips     = ["10.250.20.20"]
  security_groups = [aws_security_group.Ollama_CPU_NSG[0].id]
  tags            = merge(local.Tags, { Name = "${var.username}_TF_Ollama_CPU_NIC" })
}

resource "aws_iam_role" "Ollama_CPU_Role" {
  count    = local.Ollama ? 1 : 0
  provider = aws
  name     = "${var.username}_TF_Ollama_CPU_SSMRole"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" }
  }] })
  tags = local.Tags
}

resource "aws_iam_role_policy_attachment" "Ollama_CPU_SSM" {
  count      = local.Ollama ? 1 : 0
  provider   = aws
  role       = aws_iam_role.Ollama_CPU_Role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "Ollama_CPU_Profile" {
  count    = local.Ollama ? 1 : 0
  provider = aws
  name     = "${var.username}_TF_Ollama_CPU_SSMProfile"
  role     = aws_iam_role.Ollama_CPU_Role[0].name
  tags     = local.Tags
}

resource "aws_instance" "Ollama_CPU" {
  count                       = local.Ollama ? 1 : 0
  provider                    = aws
  ami                         = data.aws_ami.Ollama_Ubuntu[0].id
  instance_type               = var.Ollama_VM_Size
  iam_instance_profile        = aws_iam_instance_profile.Ollama_CPU_Profile[0].name
  user_data_base64            = base64gzip(var.Ollama_User_Data)
  user_data_replace_on_change = true
  primary_network_interface {
    network_interface_id = aws_network_interface.Ollama_CPU_NIC[0].id
  }
  root_block_device {
    volume_size           = 64
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.Tags, { Name = "${var.username}_TF_Ollama_CPU_OS_Disk" })
  }
  credit_specification { cpu_credits = "standard" }
  metadata_options { http_tokens = "required" }
  tags = merge(local.Tags, { Name = "${var.username}_TF_Ollama_CPU_VM", Parent_Edition = "CPU" })
  depends_on = [
    aws_eip_association.Ollama_CPU_PIP, aws_route_table_association.FAIG_CPU_RT,
    aws_iam_role_policy_attachment.Ollama_CPU_SSM,
    aws_vpc_security_group_egress_rule.Ollama_CPU_Egress,
    aws_vpc_security_group_ingress_rule.Ollama_CPU_Model,
    aws_vpc_security_group_ingress_rule.Ollama_CPU_Gateway_API,
    aws_vpc_security_group_ingress_rule.Ollama_CPU_WebUI,
  ]
}

resource "aws_ssm_association" "Ollama_CPU_Ready" {
  count            = local.Ollama ? 1 : 0
  provider         = aws
  name             = "AWS-RunShellScript"
  association_name = "${var.username}_TF_Ollama_CPU_Ready"
  targets {
    key    = "InstanceIds"
    values = [aws_instance.Ollama_CPU[0].id]
  }
  parameters                       = { commands = var.Ollama_Readiness_Command, executionTimeout = "3600" }
  wait_for_success_timeout_seconds = 3600
}
