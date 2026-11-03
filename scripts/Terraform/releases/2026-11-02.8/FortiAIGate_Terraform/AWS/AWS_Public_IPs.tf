resource "aws_eip" "FortiAIGate_CPU_PIP" {
  count      = local.CPU ? 1 : 0
  provider   = aws
  domain     = "vpc"
  tags       = merge(local.Tags, { Name = "${local.Prefix}_PIP" })
  depends_on = [aws_internet_gateway.FAIG_CPU_IGW]
}

resource "aws_eip_association" "FortiAIGate_CPU_PIP" {
  count                = local.CPU ? 1 : 0
  provider             = aws
  allocation_id        = aws_eip.FortiAIGate_CPU_PIP[0].id
  network_interface_id = aws_network_interface.FortiAIGate_CPU_NIC[0].id
}

resource "aws_eip" "Ollama_CPU_PIP" {
  count      = local.Ollama ? 1 : 0
  provider   = aws
  domain     = "vpc"
  tags       = merge(local.Tags, { Name = "${var.username}_TF_Ollama_CPU_PIP" })
  depends_on = [aws_internet_gateway.FAIG_CPU_IGW]
}

resource "aws_eip_association" "Ollama_CPU_PIP" {
  count                = local.Ollama ? 1 : 0
  provider             = aws
  allocation_id        = aws_eip.Ollama_CPU_PIP[0].id
  network_interface_id = aws_network_interface.Ollama_CPU_NIC[0].id
}
