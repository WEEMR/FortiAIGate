GitHub script migration (2026-11-02.1)
New releases are published to WEEMR/FortiAIGate. The approved branch serves
the stable scripts/AWS/GPU launcher and current manifest. Payloads and both
preparation helpers are pinned to gpu-<version> tags under
scripts/AWS/GPU/releases/<version>/. Existing S3 script history is retained;
FortiAIGate image archives and installers stay in their private artifact stores.
Use distribution/release.py build, publish, check, or promote --version VERSION.
GitHub publication uses authenticated Git/GitHub CLI and requires no AWS
publishing credentials or bucket-policy changes. Dated distribution notes at
the end describe earlier S3 delivery and remain for saved-script compatibility.

FortiAIGate 8.0.2 build0055 - AWS L40S GPU lab
Current versioned GPU release: 2026-11-02.1

Run in AWS CloudShell, us-east-1:
  curl -fsSLo "$HOME/FortiAIGate_GPU_AWS_Launcher.sh" https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh && bash "$HOME/FortiAIGate_GPU_AWS_Launcher.sh"

Launcher choices
1 Create: isolated g6e.2xlarge/L40S lab (optional approved g6e.4xlarge fallback),
  encrypted 500 GiB gp3 disk,
  HTTPS from the browser IPv4 /32, Session Manager; no SSH inbound rule.
2 Destroy: review and delete the selected marked CloudFormation lab stack.
3 Connect: open Session Manager without changing the deletion deadline.
4 Restart / resume: repair a cancelled reservation target and start a stopped
  VM, without changing the deadline. Restart capacity is not guaranteed.
5 Extend: add eight hours to the current future deletion deadline after review
  and explicit confirmation. It does not start a stopped VM.
6 Remove the shared final-cleanup service, only when no labs need it.
0 Exit.

Timers (new AWS GPU labs only)
- Full lab deletion is scheduled eight hours from Create approval, including
  provisioning and preparation. There is no automatic stop and no inactivity
  timer. Connect, Restart and browser/terminal traffic do not extend the lab.
- Option 5 explicitly adds eight hours to the current deadline, preserves the
  original creation time and verifies both the schedule and instance tag.
  It refuses expired or legacy labs and rolls back a failed update.
- EventBridge Scheduler invokes the lifecycle Lambda in AWS. CloudShell need
  not stay open or signed in. A five-minute watchdog retries overdue deletion;
  scheduled delivery and deletion take time. No snapshots/backups are made.
- Deadlines are printed in UTC. GPU instances keep running until Destroy,
  scheduled deletion, or a manual stop. CPU lab timers are not changed.
- Existing lab timers and IP assignments are not migrated. Destroy/recreate
  to use this policy. Current Destroy retains support for older marked labs.

Names and cleanup
- Input Waleed creates Name tags Waleed_FortiAIGate_GPU_VPC, _NSG, _Subnet,
  _Route_Table, _IGW and _Docker. IAM names use the same display prefix.
  Selection remains case-insensitive. CloudFormation stack names use
  FortiAIGate-GPU-lowercaseusername because underscores are not allowed there.
- Expiry calls DeleteStack to terminate the instance and root disk and remove
  networking, Elastic IP, instance role/profile, policies, schedules, controller
  and logs. A linked Ollama stack is deleted first, including its Elastic IP.
  A per-lab CleanupRole remains available until CloudFormation finishes.
  The shared final-cleanup service then removes that role automatically on its
  next five-minute check. No extra Destroy run is needed after automatic expiry.
- Create installs or reuses the shared FortiAIGate-GPU-AutoCleanup stack in this
  account, us-east-1. It contains a Lambda, execution role, scheduled rule,
  invocation permission and log group. This management service intentionally
  remains for future labs; Lambda/logging usage is billed separately. It is
  not a per-lab leftover. Use launcher option 6 to remove it when no GPU labs
  or pending cleanup roles remain. Active lab references prevent its deletion.
- The janitor requires the exact lab role name, ownership tags and original
  stack ARN. It verifies that stack is deleted and refuses roles with unexpected
  policies, managed attachments or instance profiles. Failed checks are logged
  and retried; it does not remove roles while a stack is still deleting.
- Manual Destroy removes that cleanup role after confirming stack deletion.
  Older marked GPU stacks remain supported. CPU VPC cleanup is separate.
- The template is submitted inline from a temporary local file; no template
  object is uploaded to S3. AWS retains deleted-stack history. Source release
  files, shared preparation scripts and the source bucket are retained.

Availability Zone and the real capacity check
- CloudFormation still owns the entire lab. It first creates a small capacity
  controller and the automatic timers, then tries ONE immediate targeted
  On-Demand Capacity Reservation in each supported zone, in displayed order.
  Manual AZ selection checks only that zone. Capacity errors try the next zone;
  permission, quota and ambiguous errors stop safely without another allocation.
- The console displays CAPACITY messages for each AZ attempt and the winning
  zone from CloudWatch Logs. Logs can arrive slightly late. The foundation still
  takes time; this is not a promise of instantaneous provisioning.
- The successful hold chooses the AZ for subnet 10.250.20.0/24. Native EC2 then
  launches exactly one g6e.2xlarge at 10.250.20.10 using that held capacity.
  No probe VM, Fleet or alternate GPU type is created.
- A reservation starts On-Demand billing as soon as it is active, including
  the short idle period before VM launch. Occupied capacity is not charged twice.
  It is cancelled once the VM is running; cancellation leaves that VM running.
  Rollback also cancels owned holds. A limited end time is a crash fallback;
  AWS can take up to an additional hour to expire a hold, so this is not a
  precise 20-minute billing cap. No future-dated commitment is purchased.
- Restart clears the cancelled reservation target on the stopped, verified
  instance before starting it. Capacity after a stop is not guaranteed.
- The original eight-hour deletion deadline includes setup and survives retries.
  CloudFormation rollback/Destroy and the expiry controller retain ownership.
  The same native instance, networking, controllers and IAM roles are deleted.
- Optional Capacity Manager signals can rank the zones but are not required.
  No support plan or AWS account service is enabled by the script.
- Existing Fleet-based labs keep their existing resources and cleanup support.
  Their instances are not readdressed or converted by this release.

Files and preparation
- Preset source: s3://wrady-fortiaigate-lab/FortiAIGate_8.0.2_GPU/
  Images/: seven core archives plus vllm-server, faig-models, custom-triton.
  Installer/: FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz
  Eleven nonempty archives, approximately 42 GiB; folder markers are ignored.
- The instance role has List/Get read-only access to this prefix. No bucket
  permissions are changed. Use SSE-S3 for private release objects. A separate
  source can be set explicitly with FORTIAIGATE_GPU_RELEASE_BUCKET and
  FORTIAIGATE_GPU_RELEASE_PREFIX.
- Create verifies exact L40S hardware, quota/AZ, archive names and both public
  preparation script SHA-256 pins before creating resources. Both helpers are
  pinned to the gpu-<version> GitHub tag under
  scripts/AWS/GPU/releases/<version>/user_data/ in the selected release.
- Preparation repairs Docker signing, installs Docker/Compose/AWS CLI, checks
  core archives and assistant, downloads/checks the three GPU archives, installs
  the pinned R580 compute driver, reboots once, configures NVIDIA Container
  Toolkit and verifies the full L40S/runtime. It does not import/deploy the app.
- CloudFormation progress counts resources. Host percentages are estimated
  milestones, not a time prediction. Transfer bytes/rates are measured. Only
  verified GPU_READY reaches 100%. Final duration includes stack creation.
- Final output highlights fresh Session Manager and https://PUBLIC-IP/ui URLs.
  WebUI is available after interactive deployment. New labs keep one Elastic
  IP across stops/restarts; Destroy and expiry release it. Disk and EIP charges
  continue during a manual stop. Existing labs keep their prior IP behavior.
- The website's blue IP button detects/copies the browser's IPv4. CloudShell
  best-effort detection uses recent caller-bound browser CloudTrail events;
  otherwise paste the browser address. Never use CloudShell's curl egress IP.

Continue inside Ubuntu, as the normal Session Manager user:
  fortiaigate-install
Follow the website for image import, shipped-image CUDA check, deployment and
licensing. GPU hardware readiness is not proof of licensed inspection. Keep
licenses, generated .env files and recovery archives private.

Optional troubleshooting inside Ubuntu:
  fortiaigate-prep-status
  fortiaigate-gpu-progress
  sudo tail -n 100 /var/log/fortiaigate-gpu-prep.log
  sudo tail -n 100 /var/log/fortiaigate-prep.log

Build/release entry point (no cloud operations for build):
  python3 scripts/AWS/GPU/distribution/release.py build
Refresh preparation pins before the production builder. Publish the creator,
Destroy, launcher, GPU prep and manifest together; mismatched pins fail closed.
Offline tests and AWS ValidateTemplate check syntax/contracts, not live GPU
deployment, timer delivery or licensed inspection. No VM was launched for this
release verification.

Current GitHub publication
- Publish: python3 scripts/AWS/GPU/distribution/release.py publish
- Check anonymously: python3 scripts/AWS/GPU/distribution/release.py check
- Check retained version: use check --version VERSION.
- Roll back: use promote --version VERSION.
- Authenticate Git and GitHub CLI for WEEMR/FortiAIGate publication. No AWS
  publishing profile or S3 policy update is needed for script delivery.
- The stable approved/scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh reads
  approved/scripts/AWS/GPU/current.json. It selects gpu-<version> tagged files
  under scripts/AWS/GPU/releases/<version>/, checks SHA-256/size/syntax and
  preserves terminal input. Retained manifests keep their original internal
  fortiaigate_gpu_aws_launcher.sh filename.
- Each snapshot contains Create, Destroy, the pinned menu, both preparation
  helpers, README, required-file list, deterministic ZIP and SHA256SUMS. The
  publisher verifies anonymous tagged downloads before promoting approval.
- Website launcher aliases redirect to the approved launcher. Other download
  routes resolve the approved manifest to an immutable tagged file. Keep the
  maintained distribution/site_redirects.mjs template in sync with the Site's
  lib/gpu-script-redirects.mjs; do not restore executable Site mirrors.
- Existing S3 script entry points, version history and unrelated bucket policy
  remain in place for saved scripts. The legacy S3 retirement/policy actions
  are disabled by the current GitHub configuration.

Fixed private addresses (2026-11-01.7):
New AWS CPU and GPU labs use VPC 10.250.0.0/16, workload subnet
10.250.20.0/24, FortiAIGate 10.250.20.10 and optional Ollama 10.250.20.20.
CPU retains its empty secondary public subnet 10.250.21.0/24. GPU creates only
one workload subnet in the capacity-selected AZ. Existing VMs keep their current
addresses. PrivateIPv4 is printed in the stack outputs.

Linked Ollama cleanup (2026-11-01.1):
The current manual Destroy discovers the separately launched Ollama stack linked
to this VPC, previews it, and deletes it before the GPU stack. New GPU deployments
also remove linked Ollama stacks on eight-hour expiry (or the extended deadline). Already-deployed controllers
are not automatically updated; use the latest manual Destroy for older labs.
Ollama compute is separate: manually stopping the GPU does not stop Ollama.
New Ollama deployments own an Elastic IP that is released with their stack.

Larger-size fallback (introduced 2026-11-01.8)
- After verified capacity exhaustion in every selected zone, the owned failed
  stack and cleanup role are removed before any larger-size prompt. Only the
  reviewed g6e.4xlarge (16 vCPU,128 GiB,one full L40S) can be offered next.
- Enter/0 cancels. Explicit 1 authorizes one larger-size attempt. Permission,
  quota, validation, transport, mixed or ambiguous errors do not enable fallback.
- The larger-size fallback box shows 1 hour,6 hours,1 day. USD values are red in interactive
  CloudShell, plain in redirected logs. Current .2 totals: $2.30,$13.81,$55.24.
  Larger .4 totals: $3.06,$18.38,$73.54. Includes 500GiB gp3 and one publicIPv4.
  Linux On-Demand us-east-1 rates checked 1Nov2026; licensing,traffic,S3,
  management requests/taxes and temporary capacity-hold waiting are additional.
- Fallback preserves the original eight-hour deletion deadline. Six-hour/day values are comparisons; use Extend for longer runs.
Historical script delivery (S3 releases through 2026-11-01)
These paths describe retained older releases. New publication uses GitHub as
documented above; binary image/installer archives still use their artifact store.
- Older launchers defaulted to public HTTPS S3 scripts at:
  https://wrady-fortiaigate-lab.s3.us-east-1.amazonaws.com/scripts/
  It prints the source, verifies the pinned child SHA256 and runs a saved file
  with interactive stdin intact. Website routes now select GitHub releases.
- Existing S3 user_data helpers and versioned script releases are retained for
  saved launchers. New preparation helpers are immutable GitHub-tagged payloads.

Historical versioned S3 distribution (2026-11-01.9)
- Old stable scripts/ keys are small HTTPS loaders. They validate scripts/gpu/current.json,
  fetch the approved immutable payload, verify SHA256/size/shell syntax and preserve stdin.
- Each scripts/gpu/releases/<version>/ snapshot contains Create, Destroy, pinned
  menu launcher, both GPU/common preparation payloads, README, required-file list,
  ZIP and SHA256SUMS. Every object is checked by anonymous HTTPS before promotion.
- ZIP timestamps are fixed for repeatable builds. The pinned menu reads its own
  versioned manifest. The stable launcher always reads the current pointer.
- The GPU preparation script pins the common preparation helper from the same
  GPU release; CPU's separate current pointer never changes a GPU snapshot.
- The guide previously redirected script and download URLs to S3. Current
  redirects use GitHub. Older unversioned S3 user_data helpers
  remain available for previously issued scripts and are not overwritten here.
- GPU Sid FortiAIGateGpuScriptDownloads grants only HTTPS s3:GetObject on
  scripts/gpu/* and the exact GPU launcher key. CPU statements, image
  prefixes, bucket settings and unrelated access are preserved.

Historical S3 launcher consolidation (2026-11-01.10)
- The S3 stable path was scripts/FortiAIGate_GPU_AWS_Launcher.sh; its menu offered Create, Destroy,
  Connect, Restart or Extend. The menu loads its action from the approved
  versioned release; it does not need top-level Create/Destroy shortcuts.
- Full action scripts, preparation files, checksums and rollback history stay
  in scripts/gpu/releases/<version>/. Nothing from immutable history is removed.
- Older website Create/Destroy links resolve the current manifest directly to
  the corresponding immutable action script, retaining the original action.
- GPU Create/Destroy S3 aliases were retired through the earlier coordinated
  transition. This migration retains existing S3 entry points and history;
  current GitHub configuration disables further S3 retirement commands.

Historical launcher rename (2026-11-01.11)
- Canonical stable filename: FortiAIGate_GPU_AWS_Launcher.sh. S3 names are case-sensitive.
- Old and new website launcher download paths now redirect to the GitHub
  approved launcher with this same canonical filename.
- Retained manifests keep their internal fortiaigate_gpu_aws_launcher.sh filename
  so previously saved launchers continue loading the approved release.
- That filename-only release left deployments, addresses and timers unchanged.

Eight-hour expiry and persistent IPs (2026-11-01.12)
- New GPU labs use an initial eight-hour deletion deadline with explicit +8h
  extensions, no auto-stop, and a stack-owned Elastic IP. Expiry removes linked
  Ollama resources first. New CPU Elastic IP support is a separate CPU release;
  the GPU timer does not apply to CPU labs. Existing labs are unchanged.
