FortiAIGate shared host preparation - 2026-10-31.1

Publish prepare_fortiaigate_cpu.sh to:
  s3://YOUR-SCRIPTS-BUCKET/user_data/prepare_fortiaigate_cpu.sh
The host needs read access to that object. A downloaded bootstrap must be
verified against the Create script's pinned SHA-256 before running as root.
No cloud credentials or access keys belong in user-data or this file.

Supported targets:
- Fresh Ubuntu Server 22.04 amd64 on AWS, Azure or at home.
- Terraform can use cloud=aws/azure configuration below for preparation;
  its separate automation may continue through the full installer afterward.
- The GPU outer preparation script can use this for common tools/core files
  with edition=gpu, then install its extra GPU files/driver/runtime. This base
  script does not install NVIDIA drivers or declare the GPU ready itself.

Root configuration: /etc/fortiaigate-prep.json
No shell evaluation is used; owner must be root and group/world write disabled.

AWS (instance role has read-only access to this release prefix):
{
  "cloud": "aws",
  "region": "us-east-1",
  "release_s3_uri": "s3://YOUR-PRIVATE-RELEASE-BUCKET/FortiAIGate_8.0.2_CPU/"
}

Azure (public HTTPS downloads; no AWS credentials needed):
{
  "cloud": "azure",
  "release_https_base": "https://YOUR-BUCKET.s3.us-east-1.amazonaws.com/FortiAIGate_8.0.2_CPU"
}

Home (normal local user with sudo; Docker workloads must not exist):
  sudo bash prepare_fortiaigate_cpu.sh --home \
    https://YOUR-BUCKET.s3.us-east-1.amazonaws.com/FortiAIGate_8.0.2_CPU
This creates the root-owned home configuration if none exists. An existing
configuration is reused only when it matches; other configurations are not
overwritten. Home users may be asked for their normal sudo password.

Cloud-init invocation, after writing configuration/downloading/verifying script:
  bash /usr/local/sbin/prepare_fortiaigate_cpu.sh
A custom JSON config path can be supplied as its only argument. An optional
"edition": "gpu" value switches the global status/helper to GPU readiness.
For GPU, release_s3_uri may point at FortiAIGate_8.0.2_GPU/.

What preparation does:
- Refuses non-Ubuntu-22.04/non-amd64 targets and existing Docker containers.
- Backs up docker.list/docker.sources before installing Docker's official
  signing key and signed repository. Does not disable signature validation.
- Installs Docker, Compose, Buildx, supporting tools and official AWS CLI v2.
- Runs hello-world and requires Docker active and Compose 2.23.1 or newer.
- Downloads seven matching core image TARs plus the pinned Deployment Assistant
  to /opt/fortiaigate/Images and /opt/fortiaigate/Installer.
- Supports .tar or .tar.gz image alternatives. Checks all TAR structures and
  pins installer SHA-256. Extracts only deploy-docker-compose.sh and USER-GUIDE.md.
- Runs the assistant's built-in self-test, verifies 60 GiB Docker free space,
  and installs status/interactive handoff helpers.
- Does not import FortiAIGate images, answer the wizard, deploy the app or license
  it. Those actions remain the user's hands-on portion.

Status and logs inside the VM:
  fortiaigate-prep-status
  sudo tail -n 100 /var/log/fortiaigate-prep.log
Exit status: 0 READY; 1 FAILED; 2 PENDING/RUNNING.

Root state markers in /var/lib/fortiaigate-prep:
  READY / FAILED / RUNNING - common host preparation
  edition                - nonsecret selected edition
For edition=gpu or a GPU_MODE marker, readiness instead requires GPU_READY;
GPU_FAILED or common FAILED reports failure. GPU_RUNNING gives GPU progress.
The GPU wrapper owns these GPU markers and /var/log/fortiaigate-gpu-prep.log.

Short wait-and-start command (normal interactive Ubuntu user, without sudo):
  curl -fsSLo ~/faig-start.sh https://guides.fortinetpslab.com/start.sh && bash ~/faig-start.sh
For GPU, append 2700 after faig-start.sh to allow 45 minutes.
The launcher verifies the downloaded wait helper before running it.

Manual installation after status reports READY:
  fortiaigate-install
Run this as the non-root SSM/SSH/local operator, without sudo. It requires a
real interactive terminal and refuses while preparation is pending/failed.
On first use it creates ONLY the fixed assistant state directory through sudo:
  /opt/fortiaigate/Installer/faig_deployment_assistant_data
The first connected operator owns this state; it is not assigned to ssm-user
during first boot because SSM may create that user only at first connection.
All generated Compose state remains at the guide's original path.

Wait and start installation automatically from the operator's terminal:
  bash wait_fortiaigate_install.sh
The guide downloads this small helper separately, verifies its SHA-256, and
runs the saved file without sudo. No user-data change is required, so the
same command also works with hosts using the existing preparation script.
It checks the existing status helper every 10 seconds, prints elapsed time
and the current preparation stage, then opens fortiaigate-install once READY.
It can be started before the preparation helpers are installed. CPU readiness
requires the normal checks; GPU readiness still requires GPU_READY, not only
the common CPU files. A failure or unrecognized status stops without installing.
The default wait limit is 1800 seconds; the GPU guide uses:
  bash wait_fortiaigate_install.sh 2700
An optional timeout accepts 1-86400 seconds. A timeout exits 124 and leaves
background preparation running. Ctrl+C cancels only the wait. Check the status
and logs before retrying. Keep this command attached to a real terminal so
the interactive installer can ask its questions normally; do not pipe to bash.

Retries:
After resolving a failed download/repository/access problem, run inside a cloud VM:
  sudo bash /usr/local/sbin/prepare_fortiaigate_cpu.sh
At Home, rerun the guide's original download/checksum/preparation block.
The Home block uses a temporary script, so the cloud retry path is not installed.
It reuses structurally valid image downloads and a checksum-valid installer.
A matching completed configuration is a no-op. It refuses to replace an
existing application configuration or work around unrelated containers.
Do not wait on cloud-init from this script itself; that would deadlock its own
cloud-init execution. Creators poll readiness outside cloud-init.

Checks performed locally:
  python3 check_prepare.py
  python3 test_wait_install.py
  python3 test_start_install.py
Five offline checks pass: shell/embedded syntax, config validation, CPU/GPU
status semantics, interactive handoff/failure gates, existing-container guard.
The separate waiting-helper checks cover readiness transitions, existing CPU
and GPU readiness semantics, failure, timeout, cancellation, argument/terminal
validation, missing first-boot helpers and the interactive handoff exit status.
Only inert mocked commands and temporary files are executed by these checks.
Live APT/package/cloud/VM installation still requires an end-to-end lab test.

Primary references:
https://docs.docker.com/engine/install/ubuntu/
https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
https://docs.cloud-init.io/en/latest/explanation/failure_states.html
Bundled FortiAIGate 8.0.2 build0055 deploy-docker-compose.sh and USER-GUIDE.md.
