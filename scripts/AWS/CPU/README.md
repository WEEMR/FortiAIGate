# AWS CPU download catalog

AWS CPU lab deployment and reviewed cleanup.

[Deployment guide](https://guides.fortinetpslab.com/cpu.html) · [Public downloads](https://github.com/WEEMR/FortiAIGate)

Approved version: **2026-11-02.2**, selected by [current.json](current.json).

Current entry points and direct downloads:

- [FortiAIGate_CPU_AWS_Launcher.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/AWS/CPU/FortiAIGate_CPU_AWS_Launcher.sh) — Approved CPU menu; selects a tested release and verifies Create/Destroy payloads before execution.

Versioned downloads use [immutable cpu-2026-11-02.2](https://github.com/WEEMR/FortiAIGate/releases/tag/cpu-2026-11-02.2). Older versions remain listed for reproducibility and rollback. This generated README indexes the existing files; it is separate from their frozen manifests and checksums.

## Complete file and folder index

| Type | Path | Purpose |
| --- | --- | --- |
| File | [FortiAIGate_CPU_AWS_Launcher.sh](FortiAIGate_CPU_AWS_Launcher.sh) | Approved CPU menu; selects a tested release and verifies Create/Destroy payloads before execution. |
| File | [current.json](current.json) | Approved manifest: selects the current tested version and records payload SHA-256 hashes and byte sizes; updated only after verification. |
| Folder | [releases/](releases/) | Retained version directories for reproducible downloads and rollback; existing snapshot bytes are preserved. |
| Folder | [releases/2026-11-02.1/](releases/2026-11-02.1/) | Published AWS CPU snapshot 2026-11-02.1, associated with immutable tag cpu-2026-11-02.1. |
| Folder | [releases/2026-11-02.1/_stable/](releases/2026-11-02.1/_stable/) | Saved approved-path files for this release; promotion/rollback restores these exact launcher and compatibility alias bytes. |
| Folder | [releases/2026-11-02.1/_stable/scripts/](releases/2026-11-02.1/_stable/scripts/) | Original public path scripts/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/AWS/](releases/2026-11-02.1/_stable/scripts/AWS/) | Original public path scripts/AWS/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/AWS/CPU/](releases/2026-11-02.1/_stable/scripts/AWS/CPU/) | Original public path scripts/AWS/CPU/ inside the saved rollback alias tree. |
| File | [releases/2026-11-02.1/_stable/scripts/AWS/CPU/FortiAIGate_CPU_AWS_Launcher.sh](releases/2026-11-02.1/_stable/scripts/AWS/CPU/FortiAIGate_CPU_AWS_Launcher.sh) | Rollback snapshot of scripts/AWS/CPU/FortiAIGate_CPU_AWS_Launcher.sh: Approved CPU menu; selects a tested release and verifies Create/Destroy payloads before execution. |
| File | [releases/2026-11-02.1/create_fortiaigate_vpc.sh](releases/2026-11-02.1/create_fortiaigate_vpc.sh) | Creates the isolated AWS CPU VPC/EC2 lab, owned Elastic IP and restricted browser access, then prepares Ubuntu. |
| File | [releases/2026-11-02.1/destroy_fortiaigate_vpc.sh](releases/2026-11-02.1/destroy_fortiaigate_vpc.sh) | Reviews CPU lab ownership and removes the selected lab and linked Ollama resources while protecting shared/unrelated resources. |
| File | [releases/2026-11-02.1/fortiaigate_launcher.sh](releases/2026-11-02.1/fortiaigate_launcher.sh) | Version-pinned CPU menu that reads this snapshot's manifest instead of the moving approval pointer. |
| File | [releases/2026-11-02.1/manifest.json](releases/2026-11-02.1/manifest.json) | Frozen manifest for release 2026-11-02.1: exact payload names, SHA-256 hashes and byte sizes used by launchers. |
| File | [releases/2026-11-02.1/publication.json](releases/2026-11-02.1/publication.json) | Publisher verification and rollback metadata: repository/tag, all published file digests and the mapping of stable aliases to _stable copies. |
| Folder | [releases/2026-11-02.1/user_data/](releases/2026-11-02.1/user_data/) | First-boot cloud-init/user-data bootstrap helpers for a new VM; these are preparation programs, not saved user documents. |
| File | [releases/2026-11-02.1/user_data/prepare_fortiaigate_cpu.sh](releases/2026-11-02.1/user_data/prepare_fortiaigate_cpu.sh) | Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment. Used by first-boot cloud-init, including the common prerequisites of GPU labs. |
| Folder | [releases/2026-11-02.2/](releases/2026-11-02.2/) | Published AWS CPU snapshot 2026-11-02.2, associated with immutable tag cpu-2026-11-02.2. |
| Folder | [releases/2026-11-02.2/_stable/](releases/2026-11-02.2/_stable/) | Saved approved-path files for this release; promotion/rollback restores these exact launcher and compatibility alias bytes. |
| Folder | [releases/2026-11-02.2/_stable/scripts/](releases/2026-11-02.2/_stable/scripts/) | Original public path scripts/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.2/_stable/scripts/AWS/](releases/2026-11-02.2/_stable/scripts/AWS/) | Original public path scripts/AWS/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.2/_stable/scripts/AWS/CPU/](releases/2026-11-02.2/_stable/scripts/AWS/CPU/) | Original public path scripts/AWS/CPU/ inside the saved rollback alias tree. |
| File | [releases/2026-11-02.2/_stable/scripts/AWS/CPU/FortiAIGate_CPU_AWS_Launcher.sh](releases/2026-11-02.2/_stable/scripts/AWS/CPU/FortiAIGate_CPU_AWS_Launcher.sh) | Rollback snapshot of scripts/AWS/CPU/FortiAIGate_CPU_AWS_Launcher.sh: Approved CPU menu; selects a tested release and verifies Create/Destroy payloads before execution. |
| File | [releases/2026-11-02.2/create_fortiaigate_vpc.sh](releases/2026-11-02.2/create_fortiaigate_vpc.sh) | Creates the isolated AWS CPU VPC/EC2 lab, owned Elastic IP and restricted browser access, then prepares Ubuntu. |
| File | [releases/2026-11-02.2/destroy_fortiaigate_vpc.sh](releases/2026-11-02.2/destroy_fortiaigate_vpc.sh) | Reviews CPU lab ownership and removes the selected lab and linked Ollama resources while protecting shared/unrelated resources. |
| File | [releases/2026-11-02.2/fortiaigate_launcher.sh](releases/2026-11-02.2/fortiaigate_launcher.sh) | Version-pinned CPU menu that reads this snapshot's manifest instead of the moving approval pointer. |
| File | [releases/2026-11-02.2/manifest.json](releases/2026-11-02.2/manifest.json) | Frozen manifest for release 2026-11-02.2: exact payload names, SHA-256 hashes and byte sizes used by launchers. |
| File | [releases/2026-11-02.2/publication.json](releases/2026-11-02.2/publication.json) | Publisher verification and rollback metadata: repository/tag, all published file digests and the mapping of stable aliases to _stable copies. |
| Folder | [releases/2026-11-02.2/user_data/](releases/2026-11-02.2/user_data/) | First-boot cloud-init/user-data bootstrap helpers for a new VM; these are preparation programs, not saved user documents. |
| File | [releases/2026-11-02.2/user_data/prepare_fortiaigate_cpu.sh](releases/2026-11-02.2/user_data/prepare_fortiaigate_cpu.sh) | Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment. Used by first-boot cloud-init, including the common prerequisites of GPU labs. |
