FortiAIGate and Ollama multi-cloud Terraform

Download the approved FortiAIGate_MultiCloud_Terraform.zip from:
https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Terraform/FortiAIGate_MultiCloud_Terraform.zip

Extract the ZIP into a new directory/state and open FortiAIGate_Terraform/.
The project follows the FortiAIOps root/AWS/Azure/Shared_Resources layout.
Edit User_Input.auto.tfvars at that project root. All deployment switches
are disabled in the download. Detailed inputs, automatic installation, network,
Ollama setup and cleanup instructions are in Shared_Resources/README.md.

Supported:
  AWS FortiAIGate CPU and GPU; Azure FortiAIGate CPU.
  AWS/Azure Ollama companions behind each same-cloud selected gateway.
  Azure GPU is not included.

From FortiAIGate_Terraform/:
  terraform init
  terraform validate
  terraform plan -out=FortiAIGate.tfplan
  terraform apply FortiAIGate.tfplan
  terraform destroy

Use Terraform >=1.9,<2.0, Python3 and the enabled cloud CLI. The default progress
watcher shows the same pinned CloudShell preparation stages/messages. Terraform
then installs FortiAIGate on AWS CPU/GPU and Azure CPU and waits for its WebUI.
Complete WebUI setup and licensing; its one-time API restart is automatic.
Show_Installation_Progress="no" hides details but still installs the application.
Separate CloudShell deployments keep their existing interactive process.
Ollama model setup is automatic; gateway virtual key/certificate configuration
is interactive. Credentials, keys, state and plans never belong in Git.

For CloudShell, explicitly set Management_Source_CIDR to YOUR BROWSER IPv4 /32,
not the shell runner's detected egress address. AWS uses normal CLI credentials
or AWS_Profile; Azure uses normal Azure authentication plus a public SSH key.
The Azure progress watcher needs az logged into the same subscription. Azure
SSH_Source_CIDR defaults to the runner IP; browser access uses Management_Source_CIDR.

AWS GPU Auto tries supported zones and uses short-lived targeted capacity holds.
Set AWS_GPU_Allow_Larger_Fallback="yes" only to preapprove the higher-cost
g6e.4xlarge after all preferred-size zones fail for capacity. Otherwise it stops.
Other API/quota errors never authorize fallback. The actual size/zone is output.

GPU preserves its eight-hour complete-lab deletion deadline, including linked
Ollama. CPU has no automatic deletion. Keep state and credentials for cleanup.
Read the full project instructions before planning.

Existing stable main.tf and .terraform.lock.hcl routes retain the earlier
standalone CPU configuration for saved downloads. They are not the entry point
for this organized multi-cloud ZIP, and existing state is not migrated.

Release maintenance (repository root):
  python3 scripts/Terraform/release.py build
  python3 scripts/Terraform/release.py publish
  python3 scripts/Terraform/release.py check
  python3 scripts/Terraform/release.py promote --version VERSION

The builder runs formatting, cached-provider validation, mock/schema-only plans
and offline runtime/package checks. It creates no cloud resources. Initialize
provider plugins separately; set TERRAFORM_BIN if PATH has an older Terraform.
Only allowlisted runtime files and safe disabled input defaults enter the ZIP.
Tests, internal generators, local inputs, provider caches, plans and state are
excluded. Changed published bytes require a new version; existing immutable
releases are preserved. This source change does not publish a release or Site.
