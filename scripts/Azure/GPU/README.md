# Azure H100 GPU download catalog

Azure H100 GPU deployment and access management.

[Deployment guide](https://guides.fortinetpslab.com/gpu.html) · [Public downloads](https://github.com/WEEMR/FortiAIGate)

Approved version: **2026-11-02.1**, selected by [current.json](current.json).

Current entry points and direct downloads:

- [fortiaigate_gpu_azure_launcher.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Azure/GPU/fortiaigate_gpu_azure_launcher.sh) — Approved H100 menu; verifies the selected immutable Azure GPU action before execution.

Versioned downloads use [immutable azure-gpu-2026-11-02.1](https://github.com/WEEMR/FortiAIGate/releases/tag/azure-gpu-2026-11-02.1). Older versions remain listed for reproducibility and rollback. This generated README indexes the existing files; it is separate from their frozen manifests and checksums.

## Complete file and folder index

| Type | Path | Purpose |
| --- | --- | --- |
| File | [current.json](current.json) | Approved manifest: selects the current tested version and records payload SHA-256 hashes and byte sizes; updated only after verification. |
| File | [fortiaigate_gpu_azure_launcher.sh](fortiaigate_gpu_azure_launcher.sh) | Approved H100 menu; verifies the selected immutable Azure GPU action before execution. |
| Folder | [releases/](releases/) | Retained version directories for reproducible downloads and rollback; existing snapshot bytes are preserved. |
| Folder | [releases/2026-11-02.1/](releases/2026-11-02.1/) | Published Azure H100 GPU snapshot 2026-11-02.1, associated with immutable tag azure-gpu-2026-11-02.1. |
| File | [releases/2026-11-02.1/FortiAIGate_Azure_GPU_Lab_Scripts.zip](releases/2026-11-02.1/FortiAIGate_Azure_GPU_Lab_Scripts.zip) | Archive of the Azure H100 launcher, lifecycle scripts and bootstrap/integrity files; product image binaries are separate. |
| File | [releases/2026-11-02.1/README.txt](releases/2026-11-02.1/README.txt) | Azure H100 deployment prerequisites, host preparation, access and cleanup instructions. |
| File | [releases/2026-11-02.1/SHA256SUMS](releases/2026-11-02.1/SHA256SUMS) | SHA-256 checksums for the Azure H100 scripts, host helpers and downloadable archive. |
| Folder | [releases/2026-11-02.1/_stable/](releases/2026-11-02.1/_stable/) | Saved approved-path files for this release; promotion/rollback restores these exact launcher and compatibility alias bytes. |
| Folder | [releases/2026-11-02.1/_stable/scripts/](releases/2026-11-02.1/_stable/scripts/) | Original public path scripts/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/Azure/](releases/2026-11-02.1/_stable/scripts/Azure/) | Original public path scripts/Azure/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/Azure/GPU/](releases/2026-11-02.1/_stable/scripts/Azure/GPU/) | Original public path scripts/Azure/GPU/ inside the saved rollback alias tree. |
| File | [releases/2026-11-02.1/_stable/scripts/Azure/GPU/fortiaigate_gpu_azure_launcher.sh](releases/2026-11-02.1/_stable/scripts/Azure/GPU/fortiaigate_gpu_azure_launcher.sh) | Rollback snapshot of scripts/Azure/GPU/fortiaigate_gpu_azure_launcher.sh: Approved H100 menu; verifies the selected immutable Azure GPU action before execution. |
| File | [releases/2026-11-02.1/create_fortiaigate_gpu_azure.sh](releases/2026-11-02.1/create_fortiaigate_gpu_azure.sh) | Creates the Azure H100 GPU lab and starts its pinned host preparation. |
| File | [releases/2026-11-02.1/destroy_fortiaigate_gpu_azure.sh](releases/2026-11-02.1/destroy_fortiaigate_gpu_azure.sh) | Reviews and removes the selected Azure H100 GPU lab and its owned resources. |
| File | [releases/2026-11-02.1/fortiaigate_gpu_azure_launcher.sh](releases/2026-11-02.1/fortiaigate_gpu_azure_launcher.sh) | Version-pinned Azure H100 menu for deployment, cleanup, connection and access management. |
| File | [releases/2026-11-02.1/manifest.json](releases/2026-11-02.1/manifest.json) | Frozen manifest for release 2026-11-02.1: exact payload names, SHA-256 hashes and byte sizes used by launchers. |
| File | [releases/2026-11-02.1/publication.json](releases/2026-11-02.1/publication.json) | Publisher verification and rollback metadata: repository/tag, all published file digests and the mapping of stable aliases to _stable copies. |
| File | [releases/2026-11-02.1/required-fortinet-files.txt](releases/2026-11-02.1/required-fortinet-files.txt) | Checklist of external FortiAIGate GPU image and installer archives for the H100 lab. |
| Folder | [releases/2026-11-02.1/user_data/](releases/2026-11-02.1/user_data/) | First-boot cloud-init/user-data bootstrap helpers for a new VM; these are preparation programs, not saved user documents. |
| File | [releases/2026-11-02.1/user_data/prepare_fortiaigate_cpu.sh](releases/2026-11-02.1/user_data/prepare_fortiaigate_cpu.sh) | Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment. Used by first-boot cloud-init, including the common prerequisites of GPU labs. |
| File | [releases/2026-11-02.1/user_data/prepare_fortiaigate_gpu_azure.sh](releases/2026-11-02.1/user_data/prepare_fortiaigate_gpu_azure.sh) | Azure H100 first-boot preparation for NVIDIA/container readiness and the required GPU image set. |
