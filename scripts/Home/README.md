# Home / Ubuntu download catalog

Shared Ubuntu preparation and interactive installation helpers.

[Deployment guide](https://guides.fortinetpslab.com/cpu.html) · [Public downloads](https://github.com/WEEMR/FortiAIGate)

Approved version: **2026-11-02.1**, selected by [current.json](current.json).

Current entry points and direct downloads:

- [prepare_fortiaigate_cpu.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Home/prepare_fortiaigate_cpu.sh) — Approved verifier for the tagged helper. Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment.
- [start_fortiaigate_install.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Home/start_fortiaigate_install.sh) — Approved verifier for the tagged helper. Starts the interactive FortiAIGate deployment assistant after preparation readiness checks.
- [wait_fortiaigate_install.sh](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Home/wait_fortiaigate_install.sh) — Approved verifier for the tagged helper. Watches host-preparation progress and reports readiness or failure to the installer handoff.
- [required-cpu-files.txt](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Home/required-cpu-files.txt) — Checklist of CPU image and installer archives required in the external artifact store.
- [README.txt](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Home/README.txt) — Ubuntu host-preparation prerequisites and the subsequent interactive installation workflow.

Versioned downloads use [immutable shared-2026-11-02.1](https://github.com/WEEMR/FortiAIGate/releases/tag/shared-2026-11-02.1). Older versions remain listed for reproducibility and rollback. This generated README indexes the existing files; it is separate from their frozen manifests and checksums.

## Complete file and folder index

| Type | Path | Purpose |
| --- | --- | --- |
| File | [README.txt](README.txt) | Ubuntu host-preparation prerequisites and the subsequent interactive installation workflow. |
| File | [current.json](current.json) | Approved manifest: selects the current tested version and records payload SHA-256 hashes and byte sizes; updated only after verification. |
| File | [prepare_fortiaigate_cpu.sh](prepare_fortiaigate_cpu.sh) | Approved verifier for the tagged helper. Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment. |
| Folder | [releases/](releases/) | Retained version directories for reproducible downloads and rollback; existing snapshot bytes are preserved. |
| Folder | [releases/2026-11-02.1/](releases/2026-11-02.1/) | Published Home / Ubuntu snapshot 2026-11-02.1, associated with immutable tag shared-2026-11-02.1. |
| File | [releases/2026-11-02.1/README.txt](releases/2026-11-02.1/README.txt) | Ubuntu host-preparation prerequisites and the subsequent interactive installation workflow. |
| Folder | [releases/2026-11-02.1/_stable/](releases/2026-11-02.1/_stable/) | Saved approved-path files for this release; promotion/rollback restores these exact launcher and compatibility alias bytes. |
| Folder | [releases/2026-11-02.1/_stable/scripts/](releases/2026-11-02.1/_stable/scripts/) | Original public path scripts/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/Home/](releases/2026-11-02.1/_stable/scripts/Home/) | Original public path scripts/Home/ inside the saved rollback alias tree. |
| File | [releases/2026-11-02.1/_stable/scripts/Home/README.txt](releases/2026-11-02.1/_stable/scripts/Home/README.txt) | Rollback snapshot of scripts/Home/README.txt: Ubuntu host-preparation prerequisites and the subsequent interactive installation workflow. |
| File | [releases/2026-11-02.1/_stable/scripts/Home/prepare_fortiaigate_cpu.sh](releases/2026-11-02.1/_stable/scripts/Home/prepare_fortiaigate_cpu.sh) | Rollback snapshot of scripts/Home/prepare_fortiaigate_cpu.sh: Approved verifier for the tagged helper. Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment. |
| File | [releases/2026-11-02.1/_stable/scripts/Home/required-cpu-files.txt](releases/2026-11-02.1/_stable/scripts/Home/required-cpu-files.txt) | Rollback snapshot of scripts/Home/required-cpu-files.txt: Checklist of CPU image and installer archives required in the external artifact store. |
| File | [releases/2026-11-02.1/_stable/scripts/Home/start_fortiaigate_install.sh](releases/2026-11-02.1/_stable/scripts/Home/start_fortiaigate_install.sh) | Rollback snapshot of scripts/Home/start_fortiaigate_install.sh: Approved verifier for the tagged helper. Starts the interactive FortiAIGate deployment assistant after preparation readiness checks. |
| File | [releases/2026-11-02.1/_stable/scripts/Home/wait_fortiaigate_install.sh](releases/2026-11-02.1/_stable/scripts/Home/wait_fortiaigate_install.sh) | Rollback snapshot of scripts/Home/wait_fortiaigate_install.sh: Approved verifier for the tagged helper. Watches host-preparation progress and reports readiness or failure to the installer handoff. |
| File | [releases/2026-11-02.1/manifest.json](releases/2026-11-02.1/manifest.json) | Frozen manifest for release 2026-11-02.1: exact payload names, SHA-256 hashes and byte sizes used by launchers. |
| File | [releases/2026-11-02.1/prepare_fortiaigate_cpu.sh](releases/2026-11-02.1/prepare_fortiaigate_cpu.sh) | Prepares Ubuntu prerequisites, Docker and FortiAIGate base images before interactive deployment. |
| File | [releases/2026-11-02.1/publication.json](releases/2026-11-02.1/publication.json) | Publisher verification and rollback metadata: repository/tag, all published file digests and the mapping of stable aliases to _stable copies. |
| File | [releases/2026-11-02.1/required-cpu-files.txt](releases/2026-11-02.1/required-cpu-files.txt) | Checklist of CPU image and installer archives required in the external artifact store. |
| File | [releases/2026-11-02.1/start_fortiaigate_install.sh](releases/2026-11-02.1/start_fortiaigate_install.sh) | Starts the interactive FortiAIGate deployment assistant after preparation readiness checks. |
| File | [releases/2026-11-02.1/wait_fortiaigate_install.sh](releases/2026-11-02.1/wait_fortiaigate_install.sh) | Watches host-preparation progress and reports readiness or failure to the installer handoff. |
| File | [required-cpu-files.txt](required-cpu-files.txt) | Checklist of CPU image and installer archives required in the external artifact store. |
| File | [start_fortiaigate_install.sh](start_fortiaigate_install.sh) | Approved verifier for the tagged helper. Starts the interactive FortiAIGate deployment assistant after preparation readiness checks. |
| File | [wait_fortiaigate_install.sh](wait_fortiaigate_install.sh) | Approved verifier for the tagged helper. Watches host-preparation progress and reports readiness or failure to the installer handoff. |
