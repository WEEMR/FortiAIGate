FortiAIGate 8.0.2 CPU - Azure CloudShell scripts
Version: 2026-11-02.1

Run in Azure CloudShell, with Bash selected and the intended subscription active.
Your Azure identity needs permission to create/delete resource groups and their
compute/network resources. Microsoft.Compute and Microsoft.Network must already
be registered. The VM size also needs quota and capacity in East US.

1. CREATE: bash create_fortiaigate_azure.sh
   Enter your name prefix and your computer's public IPv4 for HTTPS.
   Both a plain IPv4 and IPv4/32 are accepted and normalized to one /32 address.
   Open https://checkip.amazonaws.com on your own computer to find that IPv4.
   The script detects CloudShell's separate public IPv4 for SSH automatically.
   Blank/invalid HTTPS IP entries prompt again. Enter 0 at that prompt to cancel.
   VM-size discovery uses Azure's server-side regional filter with pagination,
   a three-minute total limit and progress updates every 15 seconds while waiting.
   A failed lookup stops creation; it is never treated as permission to continue.
   Each SSH/HTTPS rule is read back from Azure and verified. After VM creation,
   the script checks the actual NIC/NSG attachment and prints a PASS with both
   source /32s. It stops if the rules are missing, broad or attached elsewhere.
   Review the subscription and plan. Enter 1 or press Enter to create.

   Creates a dedicated tagged resource group, VNet, subnet, NSG, NIC, Standard
   static IPv4 and Ubuntu 22.04 Gen2 VM (Standard_B2as_v2, 2 vCPU, 8 GiB RAM).
   OS disk: 128 GiB Standard SSD LRS. Trusted Launch, Secure Boot and vTPM on.
   SSH-key login; no password, IAM role or AWS credentials are required.
   Create prepares Docker, tools and release files automatically. Continue the guide for the interactive application installer.

   Resource group: <User>_FortiAIGate_Docker
   VNet / subnet: <User>_FortiAIGate_VNet / <User>_FortiAIGate_Subnet
   NSG / NIC / public IP: <User>_FortiAIGate_NSG / _NIC / _IP
   OS disk: <User>_FortiAIGate_OSDisk
   VM: <user>-fortiaigate (lowercase, with hyphens)
   Resource names preserve the case you enter; name matching ignores case.
   Hyphens in the prefix become underscores outside the VM name. SSH and HTTPS
   rule names also use underscores. Existing labs keep their original names;
   Connect and Destroy support both formats. Create refuses a duplicate legacy lab.

   A unique SSH key is generated under:
   ~/.ssh/fortiaigate-azure/<subscription-id>/<lab-id>
   The exact path is printed. Use CloudShell Manage files > Download to save a
   private backup. The private key is never included in a script, S3 or the VM.
   If CloudShell has temporary storage, download the key before ending the session.
   Create does not overwrite existing groups. After a partial failure, inspect
   the named group or use Destroy, then retry Create.

2. CONNECT: bash create_fortiaigate_azure.sh --connect
   Enter the name prefix or full resource-group name/ID. Names ignore case.
   The script retrieves the current VM public IP and Linux admin username,
   finds the saved key, and refreshes the lab SSH rule to CloudShell's current
   /32. HTTPS remains restricted to the client IP supplied during Create.
   Your Azure login authorizes the lookup; SSH uses the VM's Linux account.
   Check the first SSH host-key fingerprint against Azure VM > Run command:
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   Run host installation commands in the resulting Ubuntu session.
   Type exit to return to CloudShell before using the launcher again.
   If the private key is missing, restore your backup at the exact printed path.
   It cannot be recovered from Azure. Never substitute a newly generated key.

3. DESTROY: bash destroy_fortiaigate_azure.sh
   Enter your name prefix, resource-group name or full resource-group ID.
   Only groups tagged by these scripts in the active subscription can be selected.
   Review the full inventory. Enter 1 or press Enter to permanently delete the
   group and ALL its resources. Enter 0 to cancel. No backups are created.
   Locks and VM disk/NIC references outside the group stop deletion for review.
   Inventories and the private SSH key remain in CloudShell after deletion.
   This does not remove S3 files or resources in other resource groups.

4. REPAIR ACCESS: bash create_fortiaigate_azure.sh --repair-access
   Use this for an existing VM with a missing HTTPS rule, a changed client IP,
   or an open SSH rule. No VM recreation or SSH private key is needed.
   Enter the exact resource-group name and select its VM. Portal-created VMs
   are supported; this does not add lab tags or make them eligible for Destroy.
   Enter your computer's public IPv4 with or without /32. CloudShell's current
   IPv4 is detected separately for SSH. Review the VM, attached NSG and sources.
   Enter 1 or press Enter to apply; 0 cancels before any rules change.
   The existing SSH/HTTPS rules are restricted to the two /32 sources, or missing
   rules are created. This reuses portal names SSH/HTTPS and both lab name formats.
   SSH uses priority 100 and HTTPS priority 110. Read-back verifies the result.
   A shared NSG, subnet NSG, duplicate rule, occupied priority, or other custom
   rule allowing these ports stops repair for review. Other rules are preserved.
   This verifies NSG configuration; the app must also listen on HTTPS port 443.

Launcher: bash fortiaigate_azure_launcher.sh
Options: 1 Create, 2 Destroy, 3 Connect, 4 Repair SSH / HTTPS access, 0 Exit.
The stable launcher is published at:
https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Azure/CPU/fortiaigate_azure_launcher.sh
It downloads the matching Create/Destroy from an immutable azure-cpu-VERSION tag,
verifies exact SHA-256 and byte size, checks shell syntax and release version,
and preserves interactive input. FORTIAIGATE_AZURE_SCRIPTS_URL can override the
HTTPS payload prefix; the reviewed checksums still apply.

Maintain source in scripts/Azure/CPU/runtime/ and
scripts/shared/cpu-prep/integrate_creators.py. The prepared
Create retains automatic host preparation; Destroy uses the tested lifecycle
source. Build all generated copies with:
  python3 scripts/Azure/CPU/release.py build
Publish a new version through the GitHub publisher after offline checks:
  python3 scripts/Azure/CPU/release.py publish
Check/roll back with release.py check or release.py promote --version VERSION.
Never overwrite released tags. Website routes link or redirect to GitHub and
must not keep executable mirrors. Binary installation archives retain their
existing S3 download sources; no cloud credentials belong in GitHub.

Sizing/cost: the selected small VM is below the installer's CPU/RAM recommendations.
The installer requires 60 GiB FREE for Docker; 128 GiB is capacity, not free space.
Review preflight results. The East US base estimate is $68.15 per 730-hour month,
plus Standard SSD transactions, data transfer, licensing and other usage.
Stopping/deallocating the VM stops compute billing; disks and public IP still bill.

Validation: shell/Python syntax and mocked Azure CLI lifecycle checks; no live
Azure provisioning test was performed. Subscription policy/quota may require changes.
