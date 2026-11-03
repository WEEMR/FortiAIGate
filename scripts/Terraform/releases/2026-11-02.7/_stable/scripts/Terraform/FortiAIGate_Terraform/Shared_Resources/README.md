# FortiAIGate and Ollama Terraform

This project follows the FortiAIOps Terraform organization and resource naming. Run normal Terraform commands from `FortiAIGate_Terraform/` and edit only the top-level `User_Input.auto.tfvars` for deployment settings.

Terraform provisions the infrastructure, prepares the host, runs the FortiAIGate installer and verifies the application WebUI for AWS CPU, AWS GPU and Azure CPU. Complete organization/admin setup and licensing in the WebUI afterward. This application automation belongs only to Terraform; the separate CloudShell launchers retain their existing interactive installation process.

```text
FortiAIGate_Terraform/
  main.tf
  variables.tf
  User_Input.auto.tfvars
  .terraform.lock.hcl
  AWS/
    AWS_VPC.tf
    AWS_Public_IPs.tf
    AWS_FortiAIGate_CPU.tf
    AWS_FortiAIGate_GPU.tf
    AWS_Ollama.tf
    Extend_GPU.py
    Resume_GPU.py
    FortiAIGate_GPU_CloudFormation.json
    FortiAIGate_GPU_FinalCleanup.json
    variables.tf
    provider.tf
    output.tf
  Azure/
    Azure_Networking.tf
    Azure_Public_IPs.tf
    Azure_FortiAIGate_CPU.tf
    Azure_Ollama.tf
    variables.tf
    provider.tf
    output.tf
  Shared_Resources/
    main.tf
    variables.tf
    provider.tf
    output.tf
    Management_Access.tf
    Bootstrap.tf
    Installation_Progress.tf
    FortiAIGate_Bootstrap.sh.tftpl
    Ollama_Bootstrap.sh.tftpl
    Wait_For_Preparation.sh
    Watch_Capacity.py
    Watch_Installation.py
    Install_FortiAIGate.py
    Install_FortiAIGate_Guest.py
    Prepare_Gateway_Certificate.py
    Check_Changes.sh
    User_Input.auto.tfvars.example
    README.md
```

The root calls `module.FortiAIGate`; that shared module connects `AWS_FortiAIGate` and `Azure_FortiAIGate`. Each selected gateway owns a separate network. AWS CPU and GPU can run together, and Azure CPU can be enabled independently. Azure GPU is reserved for future work.

## Select deployments

| Input | Effect when `"yes"` |
| --- | --- |
| `create_FortiAIGate_CPU` | AWS CPU gateway |
| `create_FortiAIGate_GPU` | AWS GPU gateway, with mandatory eight-hour deletion |
| `create_Azure_FortiAIGate_CPU` | Azure CPU gateway |
| `create_AWS_Ollama` | One separate CPU Ollama host for each enabled AWS gateway |
| `create_Azure_Ollama` | One separate CPU Ollama host for the Azure CPU gateway |

All switches default to `"no"`. Ollama requires its same-cloud gateway. For AWS GPU with a companion, for example:

```hcl
username = "yourname"
create_FortiAIGate_GPU = "yes"
create_AWS_Ollama = "yes"
Management_Source_CIDR = "203.0.113.10/32" # Replace with your actual browser public IPv4.
```

A switch changed from `"yes"` to `"no"` schedules the resources owned by that switch for deletion on the next apply. Use a fresh folder and state for a separate lab. This project does not adopt CloudShell-created labs or migrate the earlier single-file CPU Terraform state.

## Authentication and first run

Use Terraform >= 1.9 and < 2.0, Python 3, and the enabled cloud's CLI (`aws` or `az`) on the computer running Terraform. CloudShell has the cloud CLI already; ensure a supported Terraform version is installed. On Windows, run Terraform in WSL2 Ubuntu with Terraform, Python 3 and the cloud CLI installed inside WSL; the local provisioner commands use a POSIX shell. PowerShell can download and extract the ZIP, but native PowerShell/cmd.exe apply is not supported. The dependency lock file pins AWS 6.71.0, AzAPI 2.13.0 and HTTP 3.5.0.

AWS uses its standard credential chain, including CloudShell credentials or an authenticated SSO profile. `AWS_Profile` is optional. The installer and watchers use that same profile. For the printed Connect/Extend commands, also export `AWS_PROFILE` in your shell or add `--profile NAME`. The caller needs permission to create the displayed EC2, network, IAM, SSM, and GPU CloudFormation/Lambda/EventBridge resources, plus `ssm:SendCommand` and `ssm:GetCommandInvocation` for application installation and progress reads.

Azure uses `az login` and the selected subscription, or normal `ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET` credentials for Terraform. The progress watcher uses the Azure CLI's selected account and subscription, so authenticate that CLI to the same subscription too. Set an existing public key in `ssh_public_key`; never enter its private key. No Azure admin password is generated or stored. Register `Microsoft.Compute` and `Microsoft.Network` before deployment; automatic subscription-wide provider registration is disabled.

```sh
cd FortiAIGate_Terraform
cp -n Shared_Resources/User_Input.auto.tfvars.example User_Input.auto.tfvars
# Edit User_Input.auto.tfvars. Set the browser source and desired switches.
terraform init
terraform validate
terraform plan -out=FortiAIGate.tfplan
terraform apply FortiAIGate.tfplan
```

If running Terraform from CloudShell, explicitly set `Management_Source_CIDR` to **your computer browser's public IPv4 /32**. The automatic lookup detects the Terraform runner, which is CloudShell's egress address in that case. Open https://checkip.amazonaws.com in your computer's browser to find the right value. Local users can leave the input null to detect the current runner IPv4. Detection fails closed. Management allows one IPv4 /32 only.

AWS administration uses Session Manager and opens no SSH port. Azure allows gateway HTTPS/WebUI from the browser `Management_Source_CIDR` and SSH from `SSH_Source_CIDR`. Leave the SSH input null to detect the computer or CloudShell runner issuing SSH, or override it with that client IPv4 /32. Azure explicitly denies other sources before the NSG default internal allow. The key file path can be supplied to `ssh -i` when connecting. Both selected addresses are shown in outputs.

Inactive AWS does not require credentials when there are no AWS resources in this state. When disabling existing AWS resources, set `AWS_Use_Credentials = "yes"` until refresh/removal completes. Existing Azure resources also need valid Azure credentials for refresh and deletion.

## Automatic AWS placement and GPU fallback

`AWS_Availability_Zone = "auto"` is the default. For AWS GPU, the Terraform-managed capacity controller reads the selected size's supported standard Availability Zones, and tries a one-GPU targeted capacity hold in those zones until one succeeds. The selected zone then hosts the single subnet, gateway `.10` and linked Ollama `.20`. A supported-zone lookup alone is not a live capacity check; the reservation attempts perform that check. You can still specify an exact zone to limit the attempts to that zone.

```hcl
AWS_Availability_Zone = "auto"
FAIG_GPU_VM_Size = "g6e.2xlarge"
AWS_GPU_Allow_Larger_Fallback = "yes" # Explicitly approve the higher-cost g6e.4xlarge fallback.
```

With that approval, only verified insufficient-capacity failures across **all** selected `g6e.2xlarge` zones permit a second pass using `g6e.4xlarge`. The preferred size always goes first. The larger pass uses its own supported zones; a manual zone stays restricted to that zone. IAM errors, quotas, timeouts and uncertain results stop the operation. There is no third size or automatic region change. Actual size and zone are reported in the GPU outputs. Changing the placement policy, preparation payload or selected base image schedules a fresh GPU lab; review that replacement in the plan. Unchanged applies and deadline extensions reuse the existing selected instance without another hold.

`AWS_GPU_Allow_Larger_Fallback` defaults to `"no"`. The CloudShell script asks after the smaller size is exhausted; Terraform requires this cost approval in the input file **before apply**. A normal Terraform resource cannot catch a failed create and present the script's interactive upgrade menu midway through its dependency graph. The managed capacity controller performs the zone/size attempts under that explicit approval.

The original eight-hour lab deadline is retained while trying zones or the approved larger size. Capacity messages and the final selected size are displayed separately from subsequent Ubuntu preparation. You can rerun the read-only capacity watcher with `python3 Shared_Resources/Watch_Capacity.py --stack-name STACK_NAME --expected-name-prefix USERNAME_TF --region REGION` to inspect an existing request.

Definite capacity errors make one allocating request per zone. Temporary transport/throttle/server failures can retry the same request up to three times after reconciling owned reservations; they never authorize another zone/size when the result remains uncertain. Gateway and linked Ollama workload IAM identities wait for capacity success. The retained cleanup scheduler screens initial absence through bounded IAM inventory but uses direct identity checks once a role is known; it stays enabled to protect future recreations. The reviewed retry/IAM-only update has an exact template compatibility mapping, so upgrading from the retained .4 configuration preserves the existing VM and timer. Other template or placement changes retain replacement protection.

AWS CPU Auto lets AWS choose its subnet zone; it does not use the GPU retry/upsizing controller. The existing CPU CloudShell script also lacks that GPU retry flow. Azure CPU remains a regional deployment without an explicit zone, matching its CloudShell behavior. Azure GPU is not included.

## Installation experience

`terraform apply` displays resource creation, then the live preparation watcher prints the same host stages and preparation messages as the CloudShell scripts. Percentages are estimated milestones; download byte counts are measured when supplied by the helper. The pinned preparation helpers, their log files and success/failure markers are unchanged. Terraform then continues through application installation:

```text
AWS CPU: i-...
Host percentages are estimated stage milestones; transfer bytes are measured when available.
Preparation [RUNNING] [############------------]  50% | Total elapsed: 04m 20s
  Current stage: download and check the CPU release archives
...
Preparation [READY] [########################] 100%
Starting the Terraform-managed FortiAIGate application installation.
Application [RUNNING]  35% | Import and verify the FortiAIGate release images
Application [RUNNING]  65% | Create the private recovery archive and start the application containers
Application [RUNNING]  85% | Verify running application containers, database health and WebUI
PASS: FortiAIGate is deployed and its WebUI is ready. Complete WebUI setup and licensing.
The required one-time API restart after WebUI setup is handled automatically.
```

`READY` / `GPU_READY` alone still means host preparation. The final application success message requires the expected containers to be running, PostgreSQL/Redis to be healthy and HTTPS `/ui` to return HTTP 200 on three consecutive checks. GPU installation also verifies CUDA with the shipped vLLM image before starting the GPU services. Licensing, model loading and successful GPU inference are separate post-license checks; application readiness does not certify those results.

The Terraform worker drives the exact checksum-pinned 8.0.2 build0055 Deployment Assistant as the normal administrator (`ubuntu` on AWS, `fortiadmin` on Azure). It imports the images, selects the matching CPU/GPU profile, keeps HTTPS on 443, generates secrets and a recovery archive on the VM, and deploys the containers. The vendor assistant and CloudShell sources are unchanged. The CPU profile uses 4 GB LLM gateway memory/8 GB log retention; GPU uses 8 GB/16 GB and the host's single GPU explicitly for Triton and vLLM.

Open the final `URL`, complete organization/admin setup and licensing. A VM-local timer checks the shipped WebUI's setup-status endpoint and performs the vendor-required API restart once after setup. It records the container identity before requesting the restart and verifies its start time afterward; an ambiguous response never causes repeated restart requests. No manual installer command or routine VM login is required.

Application passwords, private keys and recovery material stay in the vendor assistant directory `/opt/fortiaigate/Installer/faig_deployment_assistant_data`; the installer transcript is private at `/var/log/fortiaigate-terraform-install.log`. Terraform receives only nonsecret stage messages. Local worker state is under `/var/lib/fortiaigate-terraform-install`. Retain the vendor recovery archive securely before deleting a lab if you need it later.

CPU preparation uses the immutable shared release; GPU and Ollama use their respective immutable GitHub tags. Each script is checked against a pinned SHA-256 before execution. Binary installer archives stay in their existing S3 channel. No retired S3 script prefix or mutable source URL is used.

The AWS GPU helper deliberately reboots once for driver setup. The watcher reconnects and accepts only `GPU_READY`; CPU `READY` cannot complete a GPU wait. Failures take precedence over stale readiness markers. Logs: `/var/log/fortiaigate-bootstrap.log`, `/var/log/fortiaigate-prep.log`, `/var/log/fortiaigate-gpu-prep.log`, and `/var/log/ollama-lab-bootstrap.log`.

`Show_Installation_Progress = "no"` hides detailed preparation/application messages and disables the optional capacity/Ollama progress displays. It still installs every selected FortiAIGate gateway and waits for application readiness. Python 3 and the enabled cloud CLI are required in either mode. Run a preparation-only watcher separately without creating resources:

```sh
python3 Shared_Resources/Watch_Installation.py --cloud aws --edition gpu --region us-east-1 --instance-id i-YOUR_INSTANCE_ID
python3 Shared_Resources/Watch_Installation.py --cloud azure --edition cpu --resource-group YOUR_RG --vm-name YOUR_VM
```

The live capacity watcher runs for initial creation and placement-configuration changes; after external expiry and recreation with identical inputs, run it separately if you want capacity-stage output again. The host watcher still follows the new instance ID automatically.

Capacity status reads retry a timeout or known transient API/connection error up to three times within the overall watcher deadline. Each retry waits for the previous CLI process to finish and reads the same target; it never allocates another GPU or capacity hold. Authentication errors, ownership/identity mismatches and failed stack states still stop verification. Once the exact owned stack reports completion, optional resource/event/log reads cannot turn it into a failed progress check.

A progress or application failure leaves the existing cloud resources available for inspection. After fixing the issue, review the plan and retry apply. Replacing only `terraform_data.Installation_Progress` reconnects to an active application job, resumes a Terraform-owned incomplete installation or verifies an already completed application without regenerating secrets. Unmanaged existing assistant configuration/containers are refused rather than overwritten. First-boot script or Azure SSH-key changes deliberately replace the VM, so review the plan.

If `GPU_Capacity_Progress` fails while preparation or application succeeds, those results describe separate checks. Review `terraform plan` before retrying apply; a monitor-only recovery should replace only the failed `terraform_data.GPU_Capacity_Progress` resource. Do not recreate the GPU lab to retry a status read. Updating an older preparation-only Terraform installation adds the application step on its existing prepared VM; it does not reset the GPU deadline.

## Ollama behind FortiAIGate

Every linked pair uses gateway `10.250.20.10` and Ollama `10.250.20.20` in its own isolated subnet. Ollama runs `llama-lab` (Llama 3.2 1B) on a separate CPU VM, including when linked to the AWS GPU gateway. The inference path is:

```text
Your browser -> Open WebUI :3000 -> FortiAIGate API :443 -> Ollama :11434
```

Ollama's TCP 11434 is allowed only from that pair's gateway. The gateway API port is allowed from that pair's Ollama host. Open WebUI port 3000 is allowed only from the browser /32. Both hosts have stable public IPv4s for egress/management, while inference uses private addresses. If `Gateway_API_Port` differs from 443, Terraform installs a private-address TLS forwarding listener on that port; the FortiAIGate WebUI remains on HTTPS 443.

After FortiAIGate installation/licensing:

1. Add an OpenAI-compatible provider at `http://10.250.20.20:11434/v1` in FortiAIGate and select/model-map `llama-lab`.
2. Create a FortiAIGate virtual key with access to that model.
3. From the Terraform project directory, run `python3 Shared_Resources/Prepare_Gateway_Certificate.py --cloud aws --edition cpu` (use `--edition gpu` for the AWS GPU pair), or `python3 Shared_Resources/Prepare_Gateway_Certificate.py --cloud azure` for Azure CPU. The helper also requires local OpenSSL. It exports only the public certificate through authenticated cloud management, validates its current validity and private-IP SAN, checks TLS from Ollama, and imports it at `/opt/ollama-lab/imported-gateway-ca.crt`. It preserves an existing different certificate for explicit review. After a certificate change, review and retire the previous imported certificate before rerunning. No key is copied.
4. On Ollama run `sudo ollama-lab configure --manual`. Enter `https://10.250.20.10/ai/openai/v1` (adjust the API port if changed), `/opt/ollama-lab/imported-gateway-ca.crt`, the printed browser URL and the virtual key at its hidden prompt.
5. Configure verifies a real response through FortiAIGate before starting Open WebUI. Open the printed `http://PUBLIC_IP:3000` URL using the administrator email and password you chose during Configure.

Virtual keys, passwords and private certificates never enter Terraform variables or user data. `ready` for Ollama means its backend/model is ready; its WebUI stays pending until gateway configuration succeeds. Direct Ollama connections are disabled in the WebUI runtime.

## Names, sizes and lifecycle

Resources use `<username>_TF_FortiAIGate_CPU_<suffix>`, `<username>_TF_FortiAIGate_GPU_<suffix>` and `<username>_TF_Ollama_<suffix>` (AWS includes the parent edition to distinguish two companions). AWS uses Name tags for AWS-generated IDs; Azure hostnames replace underscores with hyphens. Public/private IPs, instance/VM IDs, URLs, Connect, Install/Configure instructions and installation targets are separate outputs for the enabled clouds. `Connect_URL` opens the matching VM in the AWS Session Manager browser console or Azure portal; `Connect` retains the CLI command. The `Next_Steps` output lists each selected gateway with its own WebUI and companion links, certificate command and any GPU deletion deadline. Open full URLs using your terminal’s link shortcut (Cmd-click in supported macOS terminals, Ctrl-click in supported Windows terminals), or copy them into your browser. Run `terraform output -raw Next_Steps` to display the checklist without Terraform’s heredoc wrapper. Sign in to the cloud account containing that VM; Azure connections use the supplied SSH key and allowed SSH source address.

| Host | Default size | OS disk |
| --- | --- | --- |
| AWS CPU | `t3a.large` | 128 GiB encrypted gp3 |
| AWS GPU | `g6e.2xlarge` L40S | 500 GiB encrypted gp3 |
| AWS Ollama | `t3a.large` | 64 GiB encrypted gp3 |
| Azure CPU | `Standard_B2as_v2` | 128 GiB Standard SSD |
| Azure Ollama | `Standard_B2as_v2` | 64 GiB Standard SSD |

AWS CPU/Ollama T3 credits use standard mode. Ubuntu 22.04 is used for gateways and Azure companions; AWS Ollama follows its Ubuntu 24.04 baseline. AWS GPU uses the same short-lived targeted capacity hold as the CloudShell flow: Auto tries the supported zones before the subnet and single GPU are created. The hold is released after the instance identity and private address are verified; rollback and its limited expiry are cleanup backstops. Holds can bill before launch. Selected size availability, permissions and quotas still need to be met. See the Auto/fallback inputs below.

AWS GPU runs in a Terraform-managed CloudFormation stack so the reviewed eight-hour deletion service can delete the whole GPU lab, including linked Ollama, disks and public IPs. The deadline is fixed during the initial apply, before the GPU stack is created, and is not reset by subsequent apply, connect, restart or browser use. Setup time counts toward the eight hours. Its scoped cleanup service removes the retained deletion role after the lab expires. That small cleanup stack remains managed by Terraform until destroy.

To explicitly add eight hours before expiry, run the GPU output's `Extend` command (`python3 AWS/Extend_GPU.py --stack-name STACK_NAME --region REGION`). It displays both deadlines, asks you to type `EXTEND`, updates the CloudFormation parameters, and verifies the UTC schedule and instance tags. Subsequent Terraform applies retain that extended deadline. An expired or inconsistent lab cannot be extended. Manual `terraform destroy` also removes the retained cleanup role before deleting its final-cleanup service.

After GPU expiry, `terraform plan` refreshes the absent stack. If its switch is still `"yes"`, the plan proposes a new GPU lab. To finish cleanup, set the GPU switch to `"no"` and keep AWS credentials enabled, or run `terraform destroy`. CPU labs have no automatic stop/delete timer. Stop/start retains their public IP; disks/public IPv4s can remain billable while stopped. For a stopped GPU lab, use its `Resume` output (`python3 AWS/Resume_GPU.py --stack-name STACK_NAME --region REGION`). It verifies the exact instance and original deadline, removes only that instance's verified released capacity target while stopped, and starts that same VM. It never searches for a replacement GPU or changes the deadline. A running instance is left running.

```sh
./Shared_Resources/Check_Changes.sh # Format, validate and inspect normal/destroy plan graphs only.
terraform destroy                # Review and remove resources owned by this state.
```

Use a dedicated Azure resource group; deleting it also deletes anything manually added to it. Keep the same directory, state, input settings and credentials for cleanup. State and saved plans are sensitive local artifacts and are excluded from Git and release ZIPs.

## Verification scope

Offline checks cover real provider schemas, mocked deployment combinations, network restrictions, names, bootstrap syntax, progress success/failure/reboot handling, pinned installer prompts, application recovery, secret-safe output, one-time post-setup restart and deterministic release packaging. They create no cloud labs, VMs or reservations. The GPU template size is checked after Terraform JSON encoding, including escaped characters.

Automatic application installation has also been verified on an existing AWS GPU VM: image import, CUDA verification, application deployment, database health, public WebUI availability and a clean follow-up Terraform plan. The VM identity, IP and original deletion deadline were preserved. CPU and Azure application paths remain offline-tested. WebUI setup, licensing and end-to-end inference require operator completion; the post-setup restart timer is enabled but its live completion depends on that setup.
