# Azure CPU download catalog

Azure CPU deployment and interactive access management.

[Deployment guide](https://guides.fortinetpslab.com/cpu.html) · [Public downloads](https://github.com/WEEMR/FortiAIGate)

Approved version: **2026-11-02.1**, selected by [current.json](current.json).

Current entry points and direct downloads:

- [create_fortiaigate_azure.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Azure/CPU/create_fortiaigate_azure.sh) — Approved direct Create download. Creates the Azure CPU VM and its owned networking, then starts verified Ubuntu host preparation.
- [destroy_fortiaigate_azure.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Azure/CPU/destroy_fortiaigate_azure.sh) — Approved direct Destroy download. Reviews and deletes the selected Azure CPU lab resources while preserving unrelated deployments.
- [fortiaigate_azure_launcher.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Azure/CPU/fortiaigate_azure_launcher.sh) — Approved Azure CPU menu; verifies its pinned Create/Destroy actions before running them.

Versioned downloads use [immutable azure-cpu-2026-11-02.1](https://github.com/WEEMR/FortiAIGate/releases/tag/azure-cpu-2026-11-02.1). Older versions remain listed for reproducibility and rollback. This generated README indexes the existing files; it is separate from their frozen manifests and checksums.

## Complete file and folder index

| Type | Path | Purpose |
| --- | --- | --- |
| File | [create_fortiaigate_azure.sh](create_fortiaigate_azure.sh) | Approved direct Create download. Creates the Azure CPU VM and its owned networking, then starts verified Ubuntu host preparation. |
| File | [current.json](current.json) | Approved manifest: selects the current tested version and records payload SHA-256 hashes and byte sizes; updated only after verification. |
| File | [destroy_fortiaigate_azure.sh](destroy_fortiaigate_azure.sh) | Approved direct Destroy download. Reviews and deletes the selected Azure CPU lab resources while preserving unrelated deployments. |
| File | [fortiaigate_azure_launcher.sh](fortiaigate_azure_launcher.sh) | Approved Azure CPU menu; verifies its pinned Create/Destroy actions before running them. |
| Folder | [releases/](releases/) | Retained version directories for reproducible downloads and rollback; existing snapshot bytes are preserved. |
| Folder | [releases/2026-11-02.1/](releases/2026-11-02.1/) | Published Azure CPU snapshot 2026-11-02.1, associated with immutable tag azure-cpu-2026-11-02.1. |
| File | [releases/2026-11-02.1/FortiAIGate_Azure_CloudShell_Scripts.zip](releases/2026-11-02.1/FortiAIGate_Azure_CloudShell_Scripts.zip) | Azure CPU CloudShell launcher, Create/Destroy scripts and usage instructions in one source archive. |
| File | [releases/2026-11-02.1/README.txt](releases/2026-11-02.1/README.txt) | Azure CPU CloudShell prerequisites, SSH/access repair, deployment and cleanup instructions. |
| File | [releases/2026-11-02.1/SHA256SUMS](releases/2026-11-02.1/SHA256SUMS) | SHA-256 checksums for the Azure CPU launcher, lifecycle scripts, instructions and ZIP. |
| Folder | [releases/2026-11-02.1/_stable/](releases/2026-11-02.1/_stable/) | Saved approved-path files for this release; promotion/rollback restores these exact launcher and compatibility alias bytes. |
| Folder | [releases/2026-11-02.1/_stable/scripts/](releases/2026-11-02.1/_stable/scripts/) | Original public path scripts/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/Azure/](releases/2026-11-02.1/_stable/scripts/Azure/) | Original public path scripts/Azure/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/Azure/CPU/](releases/2026-11-02.1/_stable/scripts/Azure/CPU/) | Original public path scripts/Azure/CPU/ inside the saved rollback alias tree. |
| File | [releases/2026-11-02.1/_stable/scripts/Azure/CPU/create_fortiaigate_azure.sh](releases/2026-11-02.1/_stable/scripts/Azure/CPU/create_fortiaigate_azure.sh) | Rollback snapshot of scripts/Azure/CPU/create_fortiaigate_azure.sh: Approved direct Create download. Creates the Azure CPU VM and its owned networking, then starts verified Ubuntu host preparation. |
| File | [releases/2026-11-02.1/_stable/scripts/Azure/CPU/destroy_fortiaigate_azure.sh](releases/2026-11-02.1/_stable/scripts/Azure/CPU/destroy_fortiaigate_azure.sh) | Rollback snapshot of scripts/Azure/CPU/destroy_fortiaigate_azure.sh: Approved direct Destroy download. Reviews and deletes the selected Azure CPU lab resources while preserving unrelated deployments. |
| File | [releases/2026-11-02.1/_stable/scripts/Azure/CPU/fortiaigate_azure_launcher.sh](releases/2026-11-02.1/_stable/scripts/Azure/CPU/fortiaigate_azure_launcher.sh) | Rollback snapshot of scripts/Azure/CPU/fortiaigate_azure_launcher.sh: Approved Azure CPU menu; verifies its pinned Create/Destroy actions before running them. |
| File | [releases/2026-11-02.1/create_fortiaigate_azure.sh](releases/2026-11-02.1/create_fortiaigate_azure.sh) | Creates the Azure CPU VM and its owned networking, then starts verified Ubuntu host preparation. |
| File | [releases/2026-11-02.1/destroy_fortiaigate_azure.sh](releases/2026-11-02.1/destroy_fortiaigate_azure.sh) | Reviews and deletes the selected Azure CPU lab resources while preserving unrelated deployments. |
| File | [releases/2026-11-02.1/fortiaigate_azure_launcher.sh](releases/2026-11-02.1/fortiaigate_azure_launcher.sh) | Version-pinned Azure CPU menu for Create, Destroy, SSH connection and access repair. |
| File | [releases/2026-11-02.1/manifest.json](releases/2026-11-02.1/manifest.json) | Frozen manifest for release 2026-11-02.1: exact payload names, SHA-256 hashes and byte sizes used by launchers. |
| File | [releases/2026-11-02.1/publication.json](releases/2026-11-02.1/publication.json) | Publisher verification and rollback metadata: repository/tag, all published file digests and the mapping of stable aliases to _stable copies. |
