// Each edition owns an isolated network. These fixed addresses match CloudShell.
resource "aws_vpc" "FortiAIGate_CPU_VPC" {
  count                = local.CPU ? 1 : 0
  provider             = aws
  cidr_block           = "10.250.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.Tags, { Name = "${local.Prefix}_VPC" })
}

resource "aws_subnet" "FAIG_CPU_Subnet" {
  count             = local.CPU ? 2 : 0
  provider          = aws
  vpc_id            = aws_vpc.FortiAIGate_CPU_VPC[0].id
  cidr_block        = "10.250.${20 + count.index}.0/24"
  availability_zone = var.AWS_Availability_Zone == "auto" ? null : var.AWS_Availability_Zone
  tags = merge(local.Tags, {
    Name = count.index == 0 ? "${local.Prefix}_Subnet" : "${local.Prefix}_Subnet_2"
  })
}

resource "aws_internet_gateway" "FAIG_CPU_IGW" {
  count    = local.CPU ? 1 : 0
  provider = aws
  vpc_id   = aws_vpc.FortiAIGate_CPU_VPC[0].id
  tags     = merge(local.Tags, { Name = "${local.Prefix}_IGW" })
}

resource "aws_route_table" "FAIG_CPU_RT" {
  count    = local.CPU ? 1 : 0
  provider = aws
  vpc_id   = aws_vpc.FortiAIGate_CPU_VPC[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.FAIG_CPU_IGW[0].id
  }
  tags = merge(local.Tags, { Name = "${local.Prefix}_RT" })
}

resource "aws_route_table_association" "FAIG_CPU_RT" {
  count          = local.CPU ? 2 : 0
  provider       = aws
  subnet_id      = aws_subnet.FAIG_CPU_Subnet[count.index].id
  route_table_id = aws_route_table.FAIG_CPU_RT[0].id
}

resource "aws_default_security_group" "FAIG_CPU_Default_NSG" {
  count    = local.CPU ? 1 : 0
  provider = aws
  vpc_id   = aws_vpc.FortiAIGate_CPU_VPC[0].id
  ingress  = []
  egress   = []
  tags     = merge(local.Tags, { Name = "${local.Prefix}_Default_NSG" })
}

resource "aws_security_group" "FortiAIGate_CPU_NSG" {
  count       = local.CPU ? 1 : 0
  provider    = aws
  name        = "${local.Prefix}_NSG"
  description = "FortiAIGate CPU HTTPS; administration through Session Manager"
  vpc_id      = aws_vpc.FortiAIGate_CPU_VPC[0].id
  tags        = merge(local.Tags, { Name = "${local.Prefix}_NSG" })
}

resource "aws_vpc_security_group_ingress_rule" "FAIG_CPU_HTTPS" {
  count             = local.CPU ? 1 : 0
  provider          = aws
  security_group_id = aws_security_group.FortiAIGate_CPU_NSG[0].id
  description       = "HTTPS from the operator browser"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.Management_Source_CIDR
}

resource "aws_vpc_security_group_egress_rule" "FAIG_CPU_Egress" {
  count             = local.CPU ? 1 : 0
  provider          = aws
  security_group_id = aws_security_group.FortiAIGate_CPU_NSG[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
