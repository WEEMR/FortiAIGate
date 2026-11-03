# AWS L40S GPU download catalog

AWS L40S GPU deployment, capacity fallback and managed cleanup.

[Deployment guide](https://guides.fortinetpslab.com/gpu.html) · [Public downloads](https://github.com/WEEMR/FortiAIGate)

Approved version: **2026-11-02.2**, selected by [current.json](current.json).

Current entry points and direct downloads:

- [FortiAIGate_GPU_AWS_Launcher.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh) — Approved GPU menu for Create, Destroy, Connect, Restart, deadline extension and shared cleanup management.

Versioned downloads use [immutable gpu-2026-11-02.2](https://github.com/WEEMR/FortiAIGate/releases/tag/gpu-2026-11-02.2). Older versions remain listed for reproducibility and rollback. This generated README indexes the existing files; it is separate from their frozen manifests and checksums.

## Complete file and folder index

| Type | Path | Purpose |
| --- | --- | --- |
| File | [FortiAIGate_GPU_AWS_Launcher.sh](FortiAIGate_GPU_AWS_Launcher.sh) | Approved GPU menu for Create, Destroy, Connect, Restart, deadline extension and shared cleanup management. |
| File | [current.json](current.json) | Approved manifest: selects the current tested version and records payload SHA-256 hashes and byte sizes; updated only after verification. |
| Folder | [releases/](releases/) | Retained version directories for reproducible downloads and rollback; existing snapshot bytes are preserved. |
| Folder | [releases/2026-11-02.1/](releases/2026-11-02.1/) | Published AWS L40S GPU snapshot 2026-11-02.1, associated with immutable tag gpu-2026-11-02.1. |
| File | [releases/2026-11-02.1/FortiAIGate_AWS_GPU_Lab_Scripts.zip](releases/2026-11-02.1/FortiAIGate_AWS_GPU_Lab_Scripts.zip) | AWS GPU script bundle with launcher, lifecycle actions, preparation helpers, instructions and integrity records. |
| File | [releases/2026-11-02.1/README.txt](releases/2026-11-02.1/README.txt) | L40S deployment, capacity fallback, restart, expiry, access and cleanup instructions. |
| File | [releases/2026-11-02.1/SHA256SUMS](releases/2026-11-02.1/SHA256SUMS) | SHA-256 checksums for the AWS GPU actions, helpers, instructions, required-file list and ZIP. |
| Folder | [releases/2026-11-02.1/_stable/](releases/2026-11-02.1/_stable/) | Saved approved-path files for this release; promotion/rollback restores these exact launcher and compatibility alias bytes. |
| Folder | [releases/2026-11-02.1/_stable/scripts/](releases/2026-11-02.1/_stable/scripts/) | Original public path scripts/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/AWS/](releases/2026-11-02.1/_stable/scripts/AWS/) | Original public path scripts/AWS/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/AWS/GPU/](releases/2026-11-02.1/_stable/scripts/AWS/GPU/) | Original public path scripts/AWS/GPU/ inside the saved rollback alias tree. |
| File | [releases/2026-11-02.1/_stable/scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh](releases/2026-11-02.1/_stable/scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh) | Rollback snapshot of scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh: Approved GPU menu for Create, Destroy, Connect, Restart, deadline extension and shared cleanup management. |
| File | [releases/2026-11-02.1/create_fortiaigate_gpu_aws.sh](releases/2026-11-02.1/create_fortiaigate_gpu_aws.sh) | Creates the AWS L40S lab with reviewed capacity handling, pinned preparation and its managed deletion deadline. |
| File | [releases/2026-11-02.1/destroy_fortiaigate_gpu_aws.sh](releases/2026-11-02.1/destroy_fortiaigate_gpu_aws.sh) | Reviews and tears down the selected GPU stack, linked Ollama child and owned cleanup resources. |
| File | [releases/2026-11-02.1/fortiaigate_gpu_aws_launcher.sh](releases/2026-11-02.1/fortiaigate_gpu_aws_launcher.sh) | Version-pinned GPU menu and action selector tied to this snapshot's manifest. |
| File | [releases/2026-11-02.1/manifest.json](releases/2026-11-02.1/manifest.json) | Frozen manifest for release 2026-11-02.1: exact payload names, SHA-256 hashes and byte sizes used by launchers. |
| File | [releases/2026-11-02.1/publication.json](releases/2026-11-02.1/publication.json) | Publisher verification and rollback metadata: repository/tag, all published file digests and the mapping of stable aliases to _stable copies. |
| File | [releases/2026-11-02.1/required-fortinet-files.txt](releases/2026-11-02.1/required-fortinet-files.txt) | Names of the external GPU image/installer archives the AWS lab checks before provisioning. |
| Folder | [releases/2026-11-02.1/user_data/](releases/2026-11-02.1/user_data/) | First-boot cloud-init/user-data bootstrap helpers for a new VM; these are preparation programs, not saved user documents. |
| File | [releases/2026-11-02.1/user_data/prepare_fortiaigate_cpu.sh](releases/2026-11-02.1/user_data/prepare_fortiaigate_cpu.sh) | Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment. Used by first-boot cloud-init, including the common prerequisites of GPU labs. |
| File | [releases/2026-11-02.1/user_data/prepare_fortiaigate_gpu.sh](releases/2026-11-02.1/user_data/prepare_fortiaigate_gpu.sh) | Prepares the AWS L40S host, NVIDIA driver/container runtime, GPU image transfers and readiness checks. |
| Folder | [releases/2026-11-02.2/](releases/2026-11-02.2/) | Published AWS L40S GPU snapshot 2026-11-02.2, associated with immutable tag gpu-2026-11-02.2. |
| File | [releases/2026-11-02.2/FortiAIGate_AWS_GPU_Lab_Scripts.zip](releases/2026-11-02.2/FortiAIGate_AWS_GPU_Lab_Scripts.zip) | AWS GPU script bundle with launcher, lifecycle actions, preparation helpers, instructions and integrity records. |
| File | [releases/2026-11-02.2/README.txt](releases/2026-11-02.2/README.txt) | L40S deployment, capacity fallback, restart, expiry, access and cleanup instructions. |
| File | [releases/2026-11-02.2/SHA256SUMS](releases/2026-11-02.2/SHA256SUMS) | SHA-256 checksums for the AWS GPU actions, helpers, instructions, required-file list and ZIP. |
| Folder | [releases/2026-11-02.2/_stable/](releases/2026-11-02.2/_stable/) | Saved approved-path files for this release; promotion/rollback restores these exact launcher and compatibility alias bytes. |
| Folder | [releases/2026-11-02.2/_stable/scripts/](releases/2026-11-02.2/_stable/scripts/) | Original public path scripts/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.2/_stable/scripts/AWS/](releases/2026-11-02.2/_stable/scripts/AWS/) | Original public path scripts/AWS/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.2/_stable/scripts/AWS/GPU/](releases/2026-11-02.2/_stable/scripts/AWS/GPU/) | Original public path scripts/AWS/GPU/ inside the saved rollback alias tree. |
| File | [releases/2026-11-02.2/_stable/scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh](releases/2026-11-02.2/_stable/scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh) | Rollback snapshot of scripts/AWS/GPU/FortiAIGate_GPU_AWS_Launcher.sh: Approved GPU menu for Create, Destroy, Connect, Restart, deadline extension and shared cleanup management. |
| File | [releases/2026-11-02.2/create_fortiaigate_gpu_aws.sh](releases/2026-11-02.2/create_fortiaigate_gpu_aws.sh) | Creates the AWS L40S lab with reviewed capacity handling, pinned preparation and its managed deletion deadline. |
| File | [releases/2026-11-02.2/destroy_fortiaigate_gpu_aws.sh](releases/2026-11-02.2/destroy_fortiaigate_gpu_aws.sh) | Reviews and tears down the selected GPU stack, linked Ollama child and owned cleanup resources. |
| File | [releases/2026-11-02.2/fortiaigate_gpu_aws_launcher.sh](releases/2026-11-02.2/fortiaigate_gpu_aws_launcher.sh) | Version-pinned GPU menu and action selector tied to this snapshot's manifest. |
| File | [releases/2026-11-02.2/manifest.json](releases/2026-11-02.2/manifest.json) | Frozen manifest for release 2026-11-02.2: exact payload names, SHA-256 hashes and byte sizes used by launchers. |
| File | [releases/2026-11-02.2/publication.json](releases/2026-11-02.2/publication.json) | Publisher verification and rollback metadata: repository/tag, all published file digests and the mapping of stable aliases to _stable copies. |
| File | [releases/2026-11-02.2/required-fortinet-files.txt](releases/2026-11-02.2/required-fortinet-files.txt) | Names of the external GPU image/installer archives the AWS lab checks before provisioning. |
| Folder | [releases/2026-11-02.2/user_data/](releases/2026-11-02.2/user_data/) | First-boot cloud-init/user-data bootstrap helpers for a new VM; these are preparation programs, not saved user documents. |
| File | [releases/2026-11-02.2/user_data/prepare_fortiaigate_cpu.sh](releases/2026-11-02.2/user_data/prepare_fortiaigate_cpu.sh) | Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment. Used by first-boot cloud-init, including the common prerequisites of GPU labs. |
| File | [releases/2026-11-02.2/user_data/prepare_fortiaigate_gpu.sh](releases/2026-11-02.2/user_data/prepare_fortiaigate_gpu.sh) | Prepares the AWS L40S host, NVIDIA driver/container runtime, GPU image transfers and readiness checks. |
