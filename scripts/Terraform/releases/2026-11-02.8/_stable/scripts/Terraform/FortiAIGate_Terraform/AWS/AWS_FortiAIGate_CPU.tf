data "aws_ami" "FortiAIGate_Ubuntu" {
  count       = local.CPU || local.GPU ? 1 : 0
  provider    = aws
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
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

resource "aws_network_interface" "FortiAIGate_CPU_NIC" {
  count           = local.CPU ? 1 : 0
  provider        = aws
  subnet_id       = aws_subnet.FAIG_CPU_Subnet[0].id
  private_ips     = ["10.250.20.10"]
  security_groups = [aws_security_group.FortiAIGate_CPU_NSG[0].id]
  tags            = merge(local.Tags, { Name = "${local.Prefix}_NIC" })
}

resource "aws_iam_role" "FortiAIGate_CPU_Role" {
  count    = local.CPU ? 1 : 0
  provider = aws
  name     = "${local.Prefix}_SSMRole"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" }
  }] })
  tags = local.Tags
}

resource "aws_iam_role_policy_attachment" "FortiAIGate_CPU_SSM" {
  count      = local.CPU ? 1 : 0
  provider   = aws
  role       = aws_iam_role.FortiAIGate_CPU_Role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "FortiAIGate_CPU_Release" {
  count    = local.CPU ? 1 : 0
  provider = aws
  role     = aws_iam_role.FortiAIGate_CPU_Role[0].id
  name     = "${local.Prefix}_S3Read"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::${var.Release_Bucket}",
    Condition = { StringLike = { "s3:prefix" = [var.CPU_Release_Prefix, "${var.CPU_Release_Prefix}/", "${var.CPU_Release_Prefix}/*"] } } },
    { Effect = "Allow", Action = "s3:GetObject", Resource = "arn:aws:s3:::${var.Release_Bucket}/${var.CPU_Release_Prefix}/*" }
  ] })
}

resource "aws_iam_instance_profile" "FortiAIGate_CPU_Profile" {
  count    = local.CPU ? 1 : 0
  provider = aws
  name     = "${local.Prefix}_SSMProfile"
  role     = aws_iam_role.FortiAIGate_CPU_Role[0].name
  tags     = local.Tags
}

resource "aws_instance" "FortiAIGate_CPU" {
  count                       = local.CPU ? 1 : 0
  provider                    = aws
  ami                         = data.aws_ami.FortiAIGate_Ubuntu[0].id
  instance_type               = var.FAIG_CPU_VM_Size
  iam_instance_profile        = aws_iam_instance_profile.FortiAIGate_CPU_Profile[0].name
  user_data_base64            = base64gzip(var.CPU_User_Data)
  user_data_replace_on_change = true
  primary_network_interface {
    network_interface_id = aws_network_interface.FortiAIGate_CPU_NIC[0].id
  }
  root_block_device {
    volume_size           = 128
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.Tags, { Name = "${local.Prefix}_OS_Disk" })
  }
  credit_specification { cpu_credits = "standard" }
  metadata_options { http_tokens = "required" }
  tags = merge(local.Tags, { Name = "${local.Prefix}_VM", Edition = "CPU" })
  depends_on = [
    aws_eip_association.FortiAIGate_CPU_PIP, aws_route_table_association.FAIG_CPU_RT,
    aws_iam_role_policy_attachment.FortiAIGate_CPU_SSM, aws_iam_role_policy.FortiAIGate_CPU_Release,
    aws_vpc_security_group_egress_rule.FAIG_CPU_Egress, aws_vpc_security_group_ingress_rule.FAIG_CPU_HTTPS,
  ]
}

resource "aws_ssm_association" "FortiAIGate_CPU_Ready" {
  count            = local.CPU ? 1 : 0
  provider         = aws
  name             = "AWS-RunShellScript"
  association_name = "${local.Prefix}_Ready"
  targets {
    key    = "InstanceIds"
    values = [aws_instance.FortiAIGate_CPU[0].id]
  }
  parameters                       = { commands = var.CPU_Readiness_Command, executionTimeout = "3600" }
  wait_for_success_timeout_seconds = 3600
}
