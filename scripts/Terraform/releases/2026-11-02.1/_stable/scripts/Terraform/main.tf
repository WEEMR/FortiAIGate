# FortiAIGate 8.0.2 CPU lab. Terraform >= 1.9; one file, one fresh lab/state.
# Select exactly one cloud below. Use a NEW folder/state for a second lab.
# AWS: clear AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN if set,
# then aws sso login --profile YOUR_PROFILE; export TF_VAR_aws_sso_profile=YOUR_PROFILE
# Azure: set ARM_SUBSCRIPTION_ID, ARM_TENANT_ID, ARM_CLIENT_ID and ARM_CLIENT_SECRET in your shell.
# Azure switches: deploy_aws="no", deploy_azure="yes". Supply an existing SSH .pub key.
# Before Azure runs: unset AWS_PROFILE AWS_DEFAULT_PROFILE (clear inherited SSO profile selection).
# Run: terraform init; terraform plan -out=lab.tfplan; terraform apply lab.tfplan
# Remove this lab: terraform destroy (keep the same variables and cloud login).

terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "= 6.71.0" }
    azapi = { source = "Azure/azapi", version = "= 2.13.0" }
  }
}

# ----- YOUR SETTINGS ----------------------------------------------------------
variable "deploy_aws" {
  description = "Deploy to AWS: yes or no."
  type        = string
  default     = "yes"
  validation {
    condition     = contains(["yes", "no"], lower(trimspace(var.deploy_aws)))
    error_message = "deploy_aws must be yes or no."
  }
}
variable "deploy_azure" {
  description = "Deploy to Azure: yes or no."
  type        = string
  default     = "no"
  validation {
    condition     = contains(["yes", "no"], lower(trimspace(var.deploy_azure)))
    error_message = "deploy_azure must be yes or no."
  }
  validation {
    condition     = (lower(trimspace(var.deploy_aws)) == "yes") != (lower(trimspace(var.deploy_azure)) == "yes")
    error_message = "Select exactly one cloud: AWS yes/Azure no, or AWS no/Azure yes."
  }
}
variable "username" {
  description = "New lab name prefix, 1-20 letters/digits/underscores; start with a letter."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,19}$", var.username))
    error_message = "Use 1-20 letters, digits or underscores, starting with a letter."
  }
}
variable "admin_public_ip" {
  description = "YOUR browser's public IPv4 for HTTPS, with or without /32."
  type        = string
  validation {
    condition     = can(cidrnetmask("${trimsuffix(trimspace(var.admin_public_ip), "/32")}/32")) && !strcontains(trimsuffix(trimspace(var.admin_public_ip), "/32"), "/") && !contains(["0.0.0.0", "255.255.255.255"], trimsuffix(trimspace(var.admin_public_ip), "/32"))
    error_message = "Supply one IPv4, e.g. 203.0.113.10 or 203.0.113.10/32; broad CIDRs are not accepted."
  }
}
variable "ssh_public_ip" {
  description = "SSH client IPv4, with/without /32. Blank uses admin_public_ip. For CloudShell SSH, supply CloudShell's egress IP."
  type        = string
  default     = ""
  validation {
    condition     = var.ssh_public_ip == "" || (can(cidrnetmask("${trimsuffix(trimspace(var.ssh_public_ip), "/32")}/32")) && !strcontains(trimsuffix(trimspace(var.ssh_public_ip), "/32"), "/"))
    error_message = "Use a single IPv4, optionally ending /32, or leave blank."
  }
}
variable "ssh_public_key" {
  description = "Azure requires an existing OpenSSH PUBLIC key. Paste the contents of ~/.ssh/id_ed25519.pub. Never paste the private key."
  type        = string
  default     = ""
  validation {
    condition     = lower(trimspace(var.deploy_azure)) != "yes" || can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+=*( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "Azure requires ssh_public_key; use the .pub file, not the private key. AWS uses Session Manager."
  }
}
variable "aws_sso_profile" {
  description = "AWS only: name of the AWS CLI SSO profile after aws sso login --profile NAME."
  type        = string
  default     = ""
  validation {
    condition     = lower(trimspace(var.deploy_aws)) != "yes" || length(trimspace(var.aws_sso_profile)) > 0
    error_message = "Set aws_sso_profile to your signed-in AWS CLI SSO profile name."
  }
}
variable "aws_instance_type" {
  type    = string
  default = "t3a.large" # 2 vCPU / 8 GiB, matching the small CPU lab.
  validation {
    condition     = can(regex("^t3a?\\.", var.aws_instance_type))
    error_message = "Use an x86_64 T3/T3a size; t3a.2xlarge provides the recommended 8 vCPU / 32 GiB."
  }
}
variable "azure_vm_size" {
  type    = string
  default = "Standard_B2as_v2" # 2 vCPU / 8 GiB, matching the small CPU lab.
}
variable "aws_prefix_list_id" {
  description = "Optional existing AWS prefix list for trusted internal traffic. Blank adds no prefix-list rule."
  type        = string
  default     = ""
}

variable "preparation_script_url" {
  description = "Reviewed shared host-preparation script. Keep its matching SHA-256."
  type        = string
  default     = "https://raw.githubusercontent.com/WEEMR/FortiAIGate/shared-2026-11-02.1/scripts/Home/releases/2026-11-02.1/prepare_fortiaigate_cpu.sh"
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+/[A-Za-z0-9_./%-]+[.]sh$", var.preparation_script_url))
    error_message = "Use a public HTTPS .sh URL without credentials, query parameters or shell characters."
  }
}
variable "preparation_script_sha256" {
  description = "SHA-256 of the reviewed preparation script; execution stops on a mismatch."
  type        = string
  default     = "db1cf5ca6d2a0519a2b633e6c3fd9991325d288bd064367891506d64c843ffb6"
  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.preparation_script_sha256))
    error_message = "Use the lowercase SHA-256 of the preparation script."
  }
}
variable "release_bucket" {
  description = "S3 bucket containing the matching CPU release; Azure uses public HTTPS objects."
  type        = string
  default     = "wrady-fortiaigate-lab"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.release_bucket))
    error_message = "Use a bucket name only, without s3:// or a folder."
  }
}
variable "release_prefix" {
  description = "Case-sensitive release folder, without leading/trailing slash."
  type        = string
  default     = "FortiAIGate_8.0.2_CPU"
  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]*$", var.release_prefix)) && !strcontains(var.release_prefix, "..")
    error_message = "Use one release folder containing letters, digits, dots, underscores or hyphens; parent paths are not allowed."
  }
}

# SSO is read from AWS_PROFILE/shared AWS config. Azure reads ARM_* credentials.
# Inactive providers are configured offline; dummy values below are not credentials.
provider "aws" {
  region                      = "us-east-1"
  profile                     = local.aws ? var.aws_sso_profile : ""
  access_key                  = local.aws ? null : "unused"
  secret_key                  = local.aws ? null : "unused"
  skip_credentials_validation = !local.aws
  skip_requesting_account_id  = !local.aws
  skip_metadata_api_check     = !local.aws
}
provider "azapi" {
  subscription_id            = local.azure ? null : "00000000-0000-0000-0000-000000000000"
  tenant_id                  = local.azure ? null : "00000000-0000-0000-0000-000000000000"
  client_id                  = local.azure ? null : "00000000-0000-0000-0000-000000000000"
  client_secret              = local.azure ? null : "unused-offline-provider"
  use_cli                    = false
  use_msi                    = false
  skip_provider_registration = !local.azure
}

locals {
  aws        = lower(trimspace(var.deploy_aws)) == "yes"
  azure      = lower(trimspace(var.deploy_azure)) == "yes"
  user       = lower(var.username)
  prefix     = "${local.user}_FortiAIGate"
  operator   = local.aws ? "ubuntu" : "fortiadmin"
  https_cidr = "${trimsuffix(trimspace(var.admin_public_ip), "/32")}/32"
  ssh_cidr   = var.ssh_public_ip == "" ? local.https_cidr : "${trimsuffix(trimspace(var.ssh_public_ip), "/32")}/32"
  tags       = { ManagedBy = "Terraform", Application = "FortiAIGate", Username = local.user }
  deployment = "/opt/fortiaigate/Installer/faig_deployment_assistant_data/deployment"
  prep_config = merge({ cloud = local.aws ? "aws" : "azure", region = "us-east-1" }, local.aws ? {
    release_s3_uri = "s3://${var.release_bucket}/${var.release_prefix}/"
    } : {
    release_https_base = "https://${var.release_bucket}.s3.us-east-1.amazonaws.com/${var.release_prefix}"
  })

  # Shared S3 host preparation, then full installation; no app passwords enter state.
  # The vendor wizard requires a terminal. Expect drives its real, pinned prompts.
  bootstrap = <<-BASH
    #!/bin/bash
    set -Eeuo pipefail
    umask 077
    exec > >(tee -a /var/log/fortiaigate-bootstrap.log) 2>&1
    trap 'rc=$?; printf "FAILED: line %s, exit %s\\n" "$LINENO" "$rc"; exit "$rc"' ERR
    rm -f /var/lib/fortiaigate/ready
    . /etc/os-release
    test "$ID" = ubuntu && test "$VERSION_ID" = 22.04
    test "$(dpkg --print-architecture)" = amd64
    operator=${local.operator}
    id "$operator"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$operator" > /etc/sudoers.d/90-fortiaigate
    chmod 0440 /etc/sudoers.d/90-fortiaigate
    visudo -cf /etc/sudoers.d/90-fortiaigate

    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
    apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y ca-certificates curl python3 expect
    cat > /etc/fortiaigate-prep.json <<'FORTI_PREP_CONFIG'
    ${jsonencode(local.prep_config)}
    FORTI_PREP_CONFIG
    chmod 0600 /etc/fortiaigate-prep.json
    prep_download=$(mktemp /tmp/fortiaigate-prep.XXXXXXXX.sh)
    curl --fail --location --show-error --retry 3 --proto '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 300 "${var.preparation_script_url}" --output "$prep_download"
    printf '%s  %s\n' "${var.preparation_script_sha256}" "$prep_download" | sha256sum --check
    bash -n "$prep_download"
    install -m 0700 "$prep_download" /usr/local/sbin/prepare_fortiaigate_cpu.sh
    rm -f "$prep_download"
    bash /usr/local/sbin/prepare_fortiaigate_cpu.sh
    test -f /var/lib/fortiaigate-prep/READY
    # Terraform keeps its fully automatic deployment after shared preparation.
    install -d -m 0700 -o "$operator" -g "$operator" /opt/fortiaigate/Installer/faig_deployment_assistant_data
    cd /opt/fortiaigate/Installer

    cat > /opt/fortiaigate/auto.exp <<'EXPECT'
    set timeout 1800
    proc answer {pattern value} {
      expect {
        -re $pattern {send -- "$value\r"}
        timeout {send_error "STOP: installer prompt timed out: $pattern\n"; exit 124}
        eof {send_error "STOP: installer ended before prompt: $pattern\n"; exit 1}
      }
    }
    spawn /bin/bash /opt/fortiaigate/Installer/deploy-docker-compose.sh
    if {![file exists /opt/fortiaigate/Installer/faig_deployment_assistant_data/deployment/.env]} {
    answer {Choice \[1\]: } 1
    answer {Absolute folder containing release image archives: } /opt/fortiaigate/Images
    answer {Choice \[1\]: } 1
    answer {HTTPS port \[443\]: } 443
    answer {HTTP redirect port \[8081\]: } 8081
    answer {Choice \[1\]: } 1
    answer {Choice \[2\]: } 2
    answer {LLM gateway memory in GB \(minimum 2\) \[8\]: } 4
    answer {Log retention storage budget in GB \(minimum 8\) \[16\]: } 8
    answer {Deployment namespace \[fortiaigate\]: } fortiaigate
    answer {Choice \[2\]: } 2
    }
    answer {Choice: } 3
    expect {
      -re {Choice \[1\]: } {send -- "1\r"; exp_continue}
      -re {Type exactly APPLY to continue: } {send -- "APPLY\r"}
      timeout {send_error "STOP: deployment confirmation timed out\n"; exit 124}
      eof {send_error "STOP: installer failed before deployment\n"; exit 1}
    }
    answer {Choice: } 6
    expect {
      eof {set result [wait]; exit [lindex $result 3]}
      timeout {send_error "STOP: installer did not exit\n"; exit 124}
    }
    EXPECT
    chown "$operator:$operator" /opt/fortiaigate/auto.exp
    chmod 0700 /opt/fortiaigate/auto.exp
    timeout 3600 runuser -u "$operator" -- expect /opt/fortiaigate/auto.exp
    ready=false
    stable=0
    for attempt in $(seq 1 120); do
      all_up=true
      # dlp-scanner belongs to the vendor's GPU profile and is absent in CPU mode.
      for container in faig-postgres faig-redis faig-api faig-webui faig-llm-gateway faig-guardrail faig-policy-guard faig-logd faig-license-manager faig-nginx; do
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)
        [ "$state" = running ] || all_up=false
      done
      for container in faig-postgres faig-redis; do
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)
        [ "$health" = healthy ] || all_up=false
      done
      code=$(curl -ksS --max-time 8 -o /dev/null -w '%%{http_code}' https://127.0.0.1/ui || true)
      if "$all_up" && [ "$code" = 200 ]; then stable=$((stable + 1)); else stable=0; fi
      if [ "$stable" -ge 3 ]; then ready=true; break; fi
      sleep 10
    done
    if [ "$ready" != true ]; then
      docker ps -a
      printf 'STOP: containers, database health or WebUI did not become ready.\n' >&2
      exit 1
    fi
    install -d -m 0700 /var/lib/fortiaigate
    touch /var/lib/fortiaigate/ready
    printf 'PASS: FortiAIGate is running. Complete WebUI setup and licensing.\n'
  BASH

  cloud_config = "#cloud-config\n${yamlencode({
    write_files = [{ path = "/usr/local/sbin/fortiaigate-bootstrap", permissions = "0700", content = local.bootstrap }]
    runcmd      = [["bash", "/usr/local/sbin/fortiaigate-bootstrap"]]
  })}"
  wait_command = "bash -c 'cloud-init status --wait >/dev/null 2>&1; test -f /var/lib/fortiaigate/ready'"
}

# ----- AWS: VPC, PUBLIC SUBNETS (1a/1f), IGW, SG, ROLE, UBUNTU -------------------
data "aws_ami" "ubuntu" {
  count       = local.aws ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical, not a personal AWS account.
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
resource "aws_vpc" "lab" {
  count                = local.aws ? 1 : 0
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.prefix}_VPC" })
}
resource "aws_subnet" "public" {
  count                   = local.aws ? 2 : 0
  vpc_id                  = aws_vpc.lab[0].id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = ["us-east-1a", "us-east-1f"][count.index]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.prefix}_Public_${count.index + 1}" })
}
resource "aws_internet_gateway" "lab" {
  count  = local.aws ? 1 : 0
  vpc_id = aws_vpc.lab[0].id
  tags   = merge(local.tags, { Name = "${local.prefix}_IGW" })
}
resource "aws_route_table" "public" {
  count  = local.aws ? 1 : 0
  vpc_id = aws_vpc.lab[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab[0].id
  }
  tags = merge(local.tags, { Name = "${local.prefix}_Public_Routes" })
}
resource "aws_route_table_association" "public" {
  count          = local.aws ? 2 : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}
resource "aws_security_group" "lab" {
  count       = local.aws ? 1 : 0
  name        = "${local.prefix}_NSG"
  description = "FortiAIGate HTTPS from the lab administrator"
  vpc_id      = aws_vpc.lab[0].id
  ingress {
    description = "HTTPS from administrator"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.https_cidr]
  }
  dynamic "ingress" {
    for_each = var.aws_prefix_list_id == "" ? [] : [var.aws_prefix_list_id]
    content {
      description     = "Optional trusted internal prefix list"
      from_port       = 0
      to_port         = 0
      protocol        = "-1"
      prefix_list_ids = [ingress.value]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}
resource "aws_iam_role" "ssm" {
  count = local.aws ? 1 : 0
  name  = "${local.prefix}_TF_SSMRole"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" }
  }] })
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "ssm" {
  count      = local.aws ? 1 : 0
  role       = aws_iam_role.ssm[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "release" {
  count = local.aws ? 1 : 0
  name  = "${local.prefix}_TF_S3Read"
  role  = aws_iam_role.ssm[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::${var.release_bucket}", Condition = { StringLike = { "s3:prefix" = [var.release_prefix, "${var.release_prefix}/", "${var.release_prefix}/*"] } } },
    { Effect = "Allow", Action = "s3:GetObject", Resource = "arn:aws:s3:::${var.release_bucket}/${var.release_prefix}/*" }
  ] })
}
resource "aws_iam_instance_profile" "ssm" {
  count = local.aws ? 1 : 0
  name  = "${local.prefix}_TF_SSMRole"
  role  = aws_iam_role.ssm[0].name
  tags  = local.tags
}
resource "aws_instance" "lab" {
  count                       = local.aws ? 1 : 0
  ami                         = data.aws_ami.ubuntu[0].id
  instance_type               = var.aws_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.lab[0].id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm[0].name
  user_data_base64            = base64gzip(local.cloud_config)
  user_data_replace_on_change = true
  root_block_device {
    volume_size           = 128
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }
  credit_specification { cpu_credits = "standard" }
  metadata_options { http_tokens = "required" }
  tags       = merge(local.tags, { Name = "${local.prefix}_Docker" })
  depends_on = [aws_route_table_association.public, aws_iam_role_policy_attachment.ssm, aws_iam_role_policy.release]
}
resource "aws_ssm_association" "ready" {
  count            = local.aws ? 1 : 0
  name             = "AWS-RunShellScript"
  association_name = "${local.prefix}_Ready"
  targets {
    key    = "InstanceIds"
    values = [aws_instance.lab[0].id]
  }
  parameters                       = { commands = local.wait_command, executionTimeout = "3600" }
  wait_for_success_timeout_seconds = 3600
}

# ----- AZURE: API-MANAGED RESOURCE GROUP, NETWORK AND UBUNTU --------------------
data "azapi_client_config" "current" {
  count = local.azure ? 1 : 0
}
resource "azapi_resource" "group" {
  count     = local.azure ? 1 : 0
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = "${local.prefix}_Docker"
  parent_id = "/subscriptions/${data.azapi_client_config.current[0].subscription_id}"
  location  = "eastus"
  tags      = local.tags
  body      = { properties = {} }
}
resource "azapi_resource" "vnet" {
  count     = local.azure ? 1 : 0
  type      = "Microsoft.Network/virtualNetworks@2024-05-01"
  name      = "${local.prefix}_VNet"
  parent_id = azapi_resource.group[0].id
  location  = "eastus"
  tags      = local.tags
  body      = { properties = { addressSpace = { addressPrefixes = ["10.0.0.0/16"] } } }
}
resource "azapi_resource" "subnet" {
  count     = local.azure ? 1 : 0
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  name      = "${local.prefix}_Subnet"
  parent_id = azapi_resource.vnet[0].id
  body      = { properties = { addressPrefix = "10.0.1.0/24", defaultOutboundAccess = false } }
}
resource "azapi_resource" "public_ip" {
  count     = local.azure ? 1 : 0
  type      = "Microsoft.Network/publicIPAddresses@2024-05-01"
  name      = "${local.prefix}_Public_IP"
  parent_id = azapi_resource.group[0].id
  location  = "eastus"
  tags      = local.tags
  body = {
    sku        = { name = "Standard" }
    properties = { publicIPAllocationMethod = "Static", publicIPAddressVersion = "IPv4" }
  }
  response_export_values = ["properties.ipAddress"]
}
resource "azapi_resource" "nsg" {
  count     = local.azure ? 1 : 0
  type      = "Microsoft.Network/networkSecurityGroups@2024-05-01"
  name      = "${local.prefix}_NSG"
  parent_id = azapi_resource.group[0].id
  location  = "eastus"
  tags      = local.tags
  body = { properties = { securityRules = [
    for name, rule in { HTTPS = { port = "443", priority = 100, cidr = local.https_cidr }, SSH = { port = "22", priority = 110, cidr = local.ssh_cidr } } : {
      name                    = name
      properties = {
        priority            = rule.priority, direction = "Inbound", access = "Allow", protocol = "Tcp"
        sourcePortRange     = "*", destinationPortRange = rule.port
        sourceAddressPrefix = rule.cidr, destinationAddressPrefix = "*"
      }
    }
  ] } }
}
resource "azapi_resource" "nic" {
  count     = local.azure ? 1 : 0
  type      = "Microsoft.Network/networkInterfaces@2024-05-01"
  name      = "${local.prefix}_NIC"
  parent_id = azapi_resource.group[0].id
  location  = "eastus"
  tags      = local.tags
  body = { properties = {
    networkSecurityGroup = { id = azapi_resource.nsg[0].id }
    ipConfigurations = [{ name = "Primary", properties = {
      privateIPAllocationMethod = "Dynamic"
      subnet                    = { id = azapi_resource.subnet[0].id }
      publicIPAddress           = { id = azapi_resource.public_ip[0].id }
    } }]
  } }
}
resource "azapi_resource" "vm" {
  replace_triggers_external_values = sha256(local.cloud_config) # First-boot changes require a fresh VM/check.
  count                            = local.azure ? 1 : 0
  type                             = "Microsoft.Compute/virtualMachines@2024-07-01"
  name                             = "${replace(local.user, "_", "-")}-fortiaigate"
  parent_id                        = azapi_resource.group[0].id
  location                         = "eastus"
  tags                             = local.tags
  body = { properties = {
    hardwareProfile = { vmSize = var.azure_vm_size }
    storageProfile = {
      imageReference = { publisher = "Canonical", offer = "ubuntu-22_04-lts", sku = "server", version = "latest" }
      osDisk = {
        name        = "${local.prefix}_OS_Disk", createOption = "FromImage", caching = "ReadWrite"
        managedDisk = { storageAccountType = "StandardSSD_LRS" }, diskSizeGB = 128, deleteOption = "Delete"
      }
    }
    osProfile = {
      computerName = "${replace(local.user, "_", "-")}-fortiaigate", adminUsername = local.operator
      customData   = base64gzip(local.cloud_config)
      linuxConfiguration = {
        disablePasswordAuthentication = true, provisionVMAgent = true
        ssh                           = { publicKeys = [{ path = "/home/${local.operator}/.ssh/authorized_keys", keyData = trimspace(var.ssh_public_key) }] }
      }
    }
    networkProfile = { networkInterfaces = [{ id = azapi_resource.nic[0].id, properties = { primary = true } }] }
  } }
}
resource "azapi_resource" "ready" {
  replace_triggers_external_values = sha256(local.cloud_config) # First-boot changes require a fresh VM/check.
  count                            = local.azure ? 1 : 0
  type                             = "Microsoft.Compute/virtualMachines/extensions@2024-07-01"
  name                             = "${local.prefix}_Ready"
  parent_id                        = azapi_resource.vm[0].id
  location                         = "eastus"
  body = { properties = {
    publisher               = "Microsoft.Azure.Extensions", type = "CustomScript", typeHandlerVersion = "2.1"
    autoUpgradeMinorVersion = true, settings = { commandToExecute = local.wait_command }
  } }
  timeouts { create = "75m" }
}

# ----- RESULT / ACCESS --------------------------------------------------------
output "webui" {
  value      = "https://${local.aws ? aws_instance.lab[0].public_ip : azapi_resource.public_ip[0].output.properties.ipAddress}/ui"
  depends_on = [aws_ssm_association.ready, azapi_resource.ready]
}
output "connect" {
  value = local.aws ? "AWS console: EC2 > ${aws_instance.lab[0].id} > Connect > Session Manager" : "ssh -i ~/.ssh/id_ed25519 fortiadmin@${azapi_resource.public_ip[0].output.properties.ipAddress} # adjust the key path if different"
}
output "finish" {
  value = "Open webui, create the administrator/organization, set the external URL without /ui, then upload your license. Afterwards, in the VM terminal: ${local.deployment}/compose.sh restart api"
}
output "troubleshooting" {
  value = "Inside the VM: sudo tail -f /var/log/fortiaigate-bootstrap.log (full deployment); /var/log/fortiaigate-prep.log covers shared preparation. Files and recovery archive: /opt/fortiaigate/Installer/faig_deployment_assistant_data/ . Terraform destroy deletes this lab's application data; save needed data first."
}
