Ollama + llama-lab behind FortiAIGate — AWS launcher 2026-11-02.1

Run ollama_aws_launcher.sh in AWS CloudShell, in the same account as your existing
FortiAIGate CPU or GPU EC2 instance. The region is fixed to US East (N. Virginia),
us-east-1, matching the parent CPU/GPU lab launchers and their linked cleanup.

The launcher asks for a separate Ollama lab prefix, then lists existing running or
stopped FortiAIGate CPU/GPU deployments in this account and region as numbered
choices. Each entry shows the EC2 name, edition, state, instance ID, private IP and
Availability Zone. Choose a number explicitly; even one match is never selected
automatically. Choose the manual-entry option for renamed or custom hosts, or 0
to cancel before provisioning. Invalid choices and instance IDs are prompted again.
The selected instance is read again before its state/network checks. Discovery
uses only EC2 describe-instances and changes no cloud resources. It matches the
CPU name <prefix>_FortiAIGate_Docker and GPU name <prefix>_FortiAIGate_GPU_Docker;
Ollama hosts and other EC2 names are excluded. Older parent address plans are
supported. If listing fails, the launcher explains the AWS error and offers manual
entry or cancellation; it does not report that the account has no deployments.

New Ollama EC2 names use <prefix>_Ollama_CPU_Docker or
<prefix>_Ollama_GPU_Docker, based on the linked FortiAIGate edition. The prefix
is the Ollama lab prefix you enter, normalized to lowercase as before. Renamed
GPU hosts can also be identified by their managed DeploymentGuide tag. If the
edition cannot be identified, choose CPU or GPU explicitly from numbered options
or cancel. CPU/GPU in this name describes the linked gateway, not the Ollama
server's hardware; the Ollama instance remains t3a.large unless overridden.
The deployment summary shows the name before provisioning. Existing instances
keep their names. Stack names, ownership tags, deployment selection and linked
CPU/GPU cleanup remain unchanged; this naming change needs no CPU/GPU release.

The remaining prompts ask for your computer's public IPv4 (/32), the FortiAIGate
API TCP port (Enter uses 443; match the port in your gateway API URL), and an SSH
password entered and confirmed
privately in CloudShell (12–128 characters, at most 128 UTF-8 bytes). No EC2 key pair
or downloaded key file is required. New Ollama servers default to t3a.large (8 GiB)
without an instance-type prompt. For an explicit t3.large override, run:
  bash ollama_aws_launcher.sh create --instance-type t3.large
For a gateway API on a custom port, select it at the prompt or run:
  bash ollama_aws_launcher.sh create --gateway-api-port 8443
The port must be 1–65535 and cannot be Ollama's backend port 11434. This setting
does not change the gateway's listener: it must already listen on that port.
The flag is available only for Create, and does not update an existing stack.
The approved launcher is published at:
https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Ollama/ollama_aws_launcher.sh
It verifies the approved manifest and downloads the full menu from its immutable
Ollama GitHub tag. The 2026-11-02.1 menu downloads the matching runtime from:
https://raw.githubusercontent.com/WEEMR/FortiAIGate/ollama-2026-11-02.1/scripts/Ollama/releases/2026-11-02.1/prepare_ollama.sh
and verifies its SHA256. The older stable prepare_ollama.sh URL retains .2
so saved .8 and earlier launchers can still verify their pinned installer.
Only t3a.large and t3.large are accepted, and --instance-type is available only for
Create. It never changes the type of an existing deployment. Create provisions a NEW
EC2 instance, 64 GiB encrypted gp3 disk, dedicated Elastic IP, SG, IAM role and profile.
The gateway's VPC/subnet are reused and never changed. The new child stack owns
one ingress rule on the selected gateway SG. The subnet must already have
an active IPv4 Internet Gateway route; this launcher does not build a NAT or VPC.

NEW Ollama deployments created with .8 use a dedicated Elastic IP. The public
address remains the same through Stop/Start for that stack's lifetime. Connect
shows the reserved address even while stopped; start the VM before using its
browser URL or SSH. Automatic public-IP assignment is disabled. First boot waits
up to 10 minutes for IMDSv2 to report the allocated Elastic IP before starting apt
or other internet downloads, then uses that address for the WebUI URL.
CloudFormation owns both the allocation and association. Destroy disassociates and
releases the address; no Retain policy leaves it allocated after stack deletion.
Elastic IP/public IPv4 charges continue while stopped, alongside EBS storage.
Existing deployments are not converted or updated automatically. Older stacks
retain their original automatic public-IP behavior and remain supported.

Model: llama3.2:1b (approximately 1.3 GB download), exposed as llama-lab by the shared
Ubuntu installer. No GPU is required on the Ollama VM. FortiAIGate's edition and
inspection hardware are separate from the model host's hardware.

Fixed private addresses for NEW CPU and GPU labs:
- VPC: 10.250.0.0/16; shared workload subnet: 10.250.20.0/24.
- FortiAIGate: 10.250.20.10; Ollama: 10.250.20.20.
The launcher reads the actual selected parent subnet and private address, checks
that the gateway address is usable inside that subnet, and requests .20 explicitly
for this new subnet. An occupied target address stops Create before provisioning;
it never substitutes an automatic address. Existing VMs are not readdressed.

Older parent labs and existing Ollama stacks remain supported. Creating Ollama in
another private parent subnet retains the previous subnet-base +5 address, while
preserving the parent's actual private IP in the output. Existing stacks are
resumed/reported as before; Connect and Destroy do not require the new address plan.
If the existing gateway or another ENI already occupies the target model address,
use another parent lab or remove its existing Ollama lab; do not change a running
VM's primary network interface. The launcher prints both actual private IPs.

Security:
- Model TCP11434 accepts only the selected FortiAIGate security group. Every ENI
  sharing that SG has the same network permission. Ollama API has no built-in auth.
- SSH TCP22 accepts only the operator public IPv4/32. Password login is limited
  to ubuntu, root SSH login is disabled, and the setup verifies effective sshd
  settings before reloading the service. Every attached SG is checked for wider
  rules admitting SSH before password authentication is enabled or reset.
- Open WebUI HTTP TCP3000 accepts only the same operator public IPv4/32.
  Docker publishes the instance's private interface and loopback; AWS maps the
  public IPv4 to that interface. Browser access does not need an SSH tunnel.
  This is an HTTP lab endpoint: login and chats are not encrypted on that hop.
- Configure selects the saved gateway URL/certificate/browser URL automatically
  and asks for the virtual key privately inside Ubuntu after you create the
  provider and key; no key is placed in CloudFormation,
  EC2 user-data, CloudShell, or command line arguments.
- New .9 stacks add one gateway ingress rule: TCP on the selected API port, from
  this new Ollama SG only. The rule belongs to the Ollama CloudFormation stack;
  Destroy/rollback removes it before deleting the source SG. Other gateway rules
  are preserved. The gateway's outbound rules are unchanged and must allow
  TCP11434 to the model (the standard CPU/GPU labs already allow outbound traffic).
- The selected gateway SG must belong to the same VPC and be attached to that
  gateway. For a timed GPU lab it must carry the parent's matching
  FortiAIGateBudgetStack tag, so the existing expiry role can revoke the rule.
- The launcher records the gateway private IP, instance ID and selected API port
  in root-only deployment metadata without credentials. Automatic Configure
  cross-checks these against authenticated certificate enrollment, uses HTTPS
  with /ai/openai/v1, and validates the saved browser URL before asking for a key.
  Missing or conflicting metadata stops setup. Custom endpoints use the explicit
  configure --manual mode; deployment port and TLS checks still apply.
- Older stacks are not modified or migrated. Connect identifies them as lacking
  a managed gateway rule. Their gateway API ingress remains a manual prerequisite.
- The provisioning/deletion identity needs EC2 describe permissions and
  AuthorizeSecurityGroupIngress/RevokeSecurityGroupIngress on the selected
  gateway SG, in addition to the existing CloudFormation/EC2/IAM/SSM permissions.

Provisioning is two stages:
1. CloudShell launcher provisions infrastructure and watches Ubuntu/model progress.
   CloudFormation reports actual stack/resource states and elapsed time. Installer
   percentages are estimated stage milestones, not download percentages or time
   remaining.
2. Complete the guide's Step 2 in FortiAIGate BEFORE running Configure on Ollama:
   AI Providers -> Add Provider -> Custom (self-hosted).
   Integration Details:
     Provider Name: Ollama
     Provider Slug: ollama
     Base URL: http://10.250.20.20:11434/v1
     API Format: OpenAI-compatible
   For an older parent subnet, use the PRIVATE model URL printed by Connect.
   Add Credential, then save it:
     Name: ollama-lab
     API Key: ollama
     Weight: 1
   This API Key is an Ollama placeholder, separate from the FortiAIGate virtual key.
   Add Model:
     Public Model Name: llama-lab
     Model ID: llama-lab
   After entering Model ID, confirm Public Model Name is explicitly llama-lab.
   Replace an automatically generated name such as ollama-llama-lab; Open WebUI
   and the lab runtime request llama-lab exactly.
   Under Model Pricing, set Input Cost, Output Cost, Cache Read Cost and
   Cache Write Cost to 0. Use Test Connectivity, then Add Model to save the model,
   then Add Integration to save the provider. Create a virtual key permitted to
   use llama-lab and apply the desired policy.
   After saving the provider and virtual key, connect to the Ollama VM.
   Run the printed SSH command on your own computer (Windows PowerShell,
   Mac or Linux terminal). It opens an interactive Ubuntu shell for setup.
   Enter the SSH password chosen privately in CloudShell and run
   sudo ollama-lab configure. It displays the selected gateway URL, certificate
   and browser URL automatically. Enter your hidden virtual key and, on first
   setup, your WebUI administrator email and password. You may close SSH after
   configuration, then open the printed browser URL
   directly in your browser and sign in to Open WebUI. The SSH
   password and the Open WebUI account/password created during configure are
   separate logins.
   The standard gateway URL is https://10.250.20.10/ai/openai/v1; its client path
   differs from the provider's Ollama /v1 path. The helper uses the actual saved
   private address and includes a custom API port when selected at Create.
   New Create attempts to prepare gateway certificate trust after installation.
   For an existing lab or a retry, choose 8 (Prepare gateway certificate) in the
   launcher. It obtains only the linked gateway's public certificate through
   authenticated AWS Systems Manager, then checks TLS against its private IP
   and selected API port before saving /opt/ollama-lab/fortiaigate-ca.crt.
   This also records the verified IP, instance ID and port for automatic setup.
   Existing consistent legacy records are upgraded; conflicts are preserved and
   reported. For a custom endpoint or CA, run sudo ollama-lab configure --manual
   to enter the URLs and trusted issuing CA bundle explicitly.
   No certificate verification is disabled and system trust is not changed.
   Wait for Configure's success message before browsing to port 3000.
   Existing servers need the pinned runtime update from
   https://guides.fortinetpslab.com/ollama#ollama-runtime-update to receive automatic
   Configure. Run menu 8 in the latest launcher before this update to refresh
   older metadata. Menu 8 prepares certificate trust and deployment metadata;
   it does not upgrade installed software. The update preserves accounts
   and chats, then Configure refreshes WebUI. Use a new chat with default settings.
   Testing defaults use 1024 context tokens, 64 reply tokens, 30-minute model
   residency and disabled WebUI background tasks. Long replies can be truncated.
   Open WebUI then sends
   requests through FortiAIGate. Use sudo ollama-lab verify and the gateway traffic
   logs to verify the route and test an applicable security policy.
   Session Manager is also available for setup and recovery. If installation readiness times out, choose
   3 (Status) and wait for the model to be ready before configuration.

Menu: 1 Create, 2 Destroy, 3 Status, 4 Connect, 5 Start, 6 Stop,
7 Set/reset SSH password, 8 Prepare gateway certificate, 0 Exit.
At the main menu, pressing Enter chooses 1 (Create). After reviewing the new-server
plan, press Enter to provision, or type 0 to cancel. Any nonempty response cancels.
Stop and Destroy retain their separate explicit confirmations.

Status, Connect, Start, Stop, Destroy and Set/reset SSH password list existing
Ollama deployments as numbered choices. Entries show the stack name and lifecycle
state, plus the EC2 running/stopped state and private IP when available. Only stacks
with this launcher's exact ownership tags and matching Ollama-Lab name are listed.
Failed stacks remain selectable for cleanup even if no EC2 instance or output
exists. Choose 0 to cancel, or use the manual-prefix option. Invalid choices and
prefixes are prompted again. The selected stack is read again by its immutable
StackId before an action; ownership changes or a deleted stack stop the action.
An explicit --prefix NAME bypasses this list. Discovery only reads CloudFormation
and EC2; it does not start, stop or delete resources. CloudFormation inventory needs
ListStacks and DescribeStacks permissions; EC2 state/IP display uses DescribeInstances.
An inventory error offers manual prefix entry or cancellation, rather than claiming
the account has no deployments. An EC2 lookup error keeps the stack in the list.

If first-boot SSH setup fails or you forget the password, choose 7 or run:
bash ollama_aws_launcher.sh reset-password --prefix NAME
Start the instance first if stopped. Session Manager remains available for recovery.
No successful password SSH connection is claimed until remote setup is confirmed.
Noninteractive action selection: bash ollama_aws_launcher.sh status --prefix NAME
Create still prompts for details and a final Enter-to-create choice. Destroy prints the stack
resources and requires its exact stack name. Existing stacks are resumed/reported,
never overwritten or duplicated. Failed stacks can be removed with Destroy.

The updated CPU/GPU Destroy flows discover and remove this linked Ollama stack
before deleting the parent FortiAIGate VPC. The separate Ollama launcher can also
delete ONLY Ollama. Stopping FortiAIGate does NOT stop this additional VM. Stop or
Destroy Ollama when finished. This Ollama launcher creates no timer; a parent GPU
lab can delete its linked Ollama server at the parent deadline. Use the GPU launcher
to check or extend that deadline. EBS storage still incurs charges while stopped.
Destroy deletes models, WebUI users, chats and the disk without snapshots, and
releases an Elastic IP owned
by the stack. New .8 deployments retain their Elastic IP through Stop/Start;
storage and Elastic IP charges continue while stopped. Older deployments can
change public IP after Start. Run Connect and use the current browser URL and SSH
address. If an older server's IP changed, run configure --manual with the new URL
on the current runtime to update
WEBUI_URL and CORS_ALLOW_ORIGIN. If YOUR public IP changes, update both operator
TCP22 and TCP3000 security-group rules to your new /32. Keep all other security
groups attached to the instance free of broader rules admitting these ports.

Upgrade an existing tunnel-based lab (no VM deletion needed):
1. In AWS EC2, open the Ollama instance's OWN security group (not the gateway SG).
   Add Custom TCP port3000 with Source = YOUR_CURRENT_PUBLIC_IPV4/32. Check all
   attached security groups; a broader allow rule takes precedence over /32-only
   intent. Keep port11434 restricted to the selected FortiAIGate security group.
2. SSH or use Session Manager into the Ollama VM. Follow "Manual upgrade when
   the saved browser URL is missing or outdated" in README-runtime.txt, using
   the instance's private/public IPs from Connect. That block verifies the
   current installer checksum, installs it, then runs configure --manual.
   It reuses the existing model/chat volumes and initialized administrator.
   Confirm http://OLLAMA_PUBLIC_IP:3000 at the browser-URL prompt. Use your
   existing WebUI login. The gateway key is still entered privately.
3. Open http://OLLAMA_PUBLIC_IP:3000 in your browser. Close SSH; the chat stays
   available while the VM is running. Existing CloudFormation templates are not
   automatically replaced; old stacks are identified as needing this upgrade.

Linked-stack cleanup contract:
CloudFormation stack: Ollama-Lab-<lowercase-prefix>
Tags: DeploymentGuide=FortiAIGate-Ollama-AWS-v1,
      FortiAIGateVpcId=<existing VPC ID>,
      FortiAIGateInstanceId=<existing gateway instance ID>, UserPrefix=<prefix>.

Verification in this repository is offline. --self-test and --template need no AWS
credentials and create nothing. Create calls AWS validate-template before creating
the stack. Root volume 64 GiB, model pulls, and installation need working internet,
DNS, VPC ACLs, and permissions for EC2, CloudFormation, SSM public-AMI read and IAM
creation/pass-role. Session Manager readiness additionally needs SSM Run Command
permission in the CloudShell operator identity. Failure to read readiness retains
the VM and prints connection details; inspect /var/log/ollama-lab-bootstrap.log.

The Ubuntu bootstrap checks a pinned SHA-256 before running prepare_ollama.sh.
When repackaging an updated installer, increment its runtime/release version,
update its immutable tag URL and refresh PREP_SHA256 before publication. Run
python3 scripts/Ollama/release.py build for offline checks and local staging;
release.py publish verifies anonymous tag downloads before promotion. package.py
stages compatibility ZIPs under output/ollama-package and never writes Site
downloads. Retained runtime snapshots cannot be overwritten. AWS CLI subprocess calls have a 120-second total
timeout; a timeout does not prove AWS rejected the operation. Inspect Status before
retrying. IAM role/profile names include the parent VPC so the GPU cleanup role can
be granted narrowly scoped linked-resource deletion. Create acknowledges named IAM
resources using CAPABILITY_NAMED_IAM. The first Open WebUI admin account is created
by sudo ollama-lab configure; sign in with that account at the printed browser URL.
New EIP-backed stacks also require allocation/tagging/association permissions on
Create, and disassociation/release permissions on Destroy (including parent-linked
cleanup). The dedicated Elastic IP carries the same lab ownership/link tags.

Sources:
https://ubuntu.com/aws/docs/aws-how-to/instances/build-cloudformation-templates/
https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-securitygroup.html
https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-eip.html
https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-eipassociation.html
https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html
https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/intrinsic-function-reference-base64.html
https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

Password setup:
The original password is read with terminal echo disabled and passed only to local
OpenSSL stdin, producing a salted SHA512-crypt hash with 100,000 rounds. Plaintext
never enters CloudFormation, EC2 user-data, SSM commands, logs, files, or command
arguments. The encrypted hash is sent using SSM Run Command in a mode 0600 temporary
JSON request (not CLI arguments), then the temporary file is removed. That hash
can remain in SSM execution history/CloudTrail; treat access to those records as
sensitive. The Ubuntu host applies it through chpasswd -e stdin. SSH changes use
00-ollama-lab-password.conf, sshd -t and effective-configuration verification, then
reload-or-restart ssh.service (compatible with Ubuntu 24.04 socket activation). Failed
validation attempts to restore the previous settings and never reports the new
password as ready.

On a fresh Ubuntu 24.04 boot, ssh.socket can be listening before ssh.service has
created /run/sshd. The launcher now prepares that directory with root ownership
and mode 0755 before testing the configuration. It checks that /etc/shadow stores
the exact requested salted hash, confirms ssh.service is active, and checks the
effective SSH settings again after restarting the service before writing a ready
record. These are host-side configuration checks; SSH login from your computer is not
claimed to have been tested. The password and encrypted hash are never printed.
Failures show a fixed setup step such as config_validation, password_verification
or service_activation, plus the SSM command ID when available. Raw remote output
and exception details are withheld. A rollback is reported as complete only after
the previous configuration/password and service recovery checks succeed; otherwise
it is explicitly unconfirmed and the new password is never reported ready.

To retry a VM created by an older launcher, download this launcher again, choose
7 (Set/reset SSH password), select the existing Ollama deployment by number, and
enter/confirm the desired password privately. The VM does not need to be recreated.
Repository tests model a first socket-only boot, a missing runtime directory,
partial password updates, incorrect stored hashes and post-restart failures. They
are offline fixtures; they do not establish a successful password login on a real
Ubuntu instance.

https://docs.openssl.org/3.3/man1/openssl-passwd/
https://ubuntu.com/server/docs/openssh-server/
https://docs.aws.amazon.com/systems-manager/latest/userguide/running-commands.html
