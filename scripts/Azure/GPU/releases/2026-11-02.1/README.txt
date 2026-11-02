FortiAIGate 8.0.2 Azure GPU lab
Version: 2026-11-02.1

Run fortiaigate_gpu_azure_launcher.sh as a saved file in Azure CloudShell Bash.
1 Create; 2 Destroy; 3 Connect with SSH; 4 Repair SSH / HTTPS access.

Default: Standard_NC40ads_H100_v5, East US; one full H100 NVL
94 GB, 40 vCPU, 320 GiB RAM. Ubuntu 22.04 x64 Gen2, Standard security,
512 GiB Standard SSD LRS OS disk, Standard static IPv4. Approx. $7.04/hour including $6.98/hour compute, $38.40/month disk and
$0.005/hour IPv4 at 730 hours/month; transfer, operations and tax extra.
Verify current regional pay-as-you-go pricing. The VM, disk and IP are billable while retained.

Before Create:
- Select the intended subscription with az account set --subscription <ID>.
- Upload the ten GPU image archives and installer into an existing private
  Blob container in that subscription: FortiAIGate_8.0.2_GPU/Images/ and
  FortiAIGate_8.0.2_GPU/Installer/. Each image must have exactly one .tar or
  .tar.gz variant. The reviewed preparation script verifies the installer.
- Your signed-in identity needs Blob read/list access, permission to create
  resource groups, VMs, networking and user-assigned identities, and permission
  to create/delete role assignments scoped to that existing container.
- The storage account must permit authenticated public HTTPS network access.
  This script does not create private endpoints or alter an existing firewall.
- Ensure 40 unused vCPUs in the VM family and Total Regional vCPU quotas.
- Register Microsoft.Compute, Microsoft.Network, Microsoft.ManagedIdentity,
  Microsoft.Storage and Microsoft.Authorization before Create.

The creator checks SKU, quota, x64 Gen2 image, private-Blob archive metadata,
RBAC permission and both pinned public preparation dependencies before VM creation.
It creates a dedicated user-assigned managed identity with only Storage Blob
Data Reader at the chosen container. It reads back that exact assignment before
creating the VM. No account keys, SAS tokens or client secrets are used.
Blob RBAC propagation and downloads are retried by the preparation helper.

The script creates an isolated <prefix>_FortiAIGate_GPU_Docker resource group.
CPU groups use different ownership tags and are not selected. SSH is limited
to CloudShell's current public IPv4 /32; HTTPS to your browser's IPv4 /32.
Connect refreshes the lab SSH rule. Repair verifies the VM's exclusive,
owned NIC NSG before changing the two access rules. No broad inbound rules
or public management ports are created.

The VM receives a root-owned 0600 /etc/fortiaigate-prep.json with Azure storage
names and its managed-identity client ID. GPU_MODE is set before preparation.
The pinned GPU helper stages the private release, installs the NVIDIA driver,
reboots once, then verifies hardware, GPU container access, all archives and
the assistant. The creator polls VM Run Command for up to 45 minutes and
prints progress about every 10 seconds. Generic CPU READY cannot unlock this
GPU wait. GPU_READY is required. Connect, run sudo fortiaigate-prep-status,
then fortiaigate-install to launch the interactive wizard.

A preparation or deployment error retains the existing resources. Inspect the
VM; do not rerun Create against the existing resource group. Logs:
/var/log/fortiaigate-gpu-prep.log and /var/log/fortiaigate-prep.log.

Keep the generated private SSH key and local inventory. Azure cannot recover
a lost private key. CloudShell storage may be temporary; save a private backup.
Destroy previews the group resources and this lab's exact container-scoped
Reader assignment, rechecks ownership/dependencies/membership, deletes that
assignment, then the GPU resource group. The storage account, container,
release files, local private key and inventory are retained. No snapshots.

Developer validation (offline, no cloud provisioning):
PYTHONDONTWRITEBYTECODE=1 python3 test_azure_gpu.py
python3 build_scripts.py
bash -n create_fortiaigate_gpu_azure.sh
bash -n destroy_fortiaigate_gpu_azure.sh
bash -n fortiaigate_gpu_azure_launcher.sh
sha256sum -c SHA256SUMS

After reviewing a new Azure GPU preparation helper, update PREP_SHA256 in
azure_lifecycle.py and run build_scripts.py. Publish the generated scripts and
matching helper together. The launcher verifies SHA256 before executing a
lifecycle script; the creator verifies SHA256 before using a preparation helper.

These scripts have been checked offline. No Azure VM was provisioned as part
of this change; live GPU readiness and licensed deny/allow inspection tests
remain deployment validation gates in the guide.

GitHub distribution:
  python3 release.py build
  python3 release.py publish
  python3 release.py check
  python3 release.py promote --version VERSION
Stable launcher: https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Azure/GPU/fortiaigate_gpu_azure_launcher.sh
Action scripts and preparation helpers use azure-gpu-<version> tags.
The private Blob container and its managed-identity access remain unchanged.
