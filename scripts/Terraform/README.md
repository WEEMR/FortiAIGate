# Terraform download catalog

Downloadable AWS/Azure Terraform configuration and provider lockfile.

[Deployment guide](https://guides.fortinetpslab.com/cpu.html) · [Public downloads](https://github.com/WEEMR/FortiAIGate)

Approved version: **2026-11-02.1**, selected by [current.json](current.json).

Current entry points and direct downloads:

- [main.tf](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Terraform/main.tf) — Terraform configuration for selecting and deploying one AWS or Azure CPU lab with its own state.
- [.terraform.lock.hcl](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Terraform/.terraform.lock.hcl) — Exact AWS/Azure provider selections and accepted provider package checksums; retain beside main.tf.
- [FortiAIGate_MultiCloud_Terraform.zip](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Terraform/FortiAIGate_MultiCloud_Terraform.zip) — Downloadable Terraform source bundle containing main.tf, its provider lockfile and usage instructions.
- [README.txt](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Terraform/README.txt) — Terraform version requirements, cloud inputs, credentials setup and separate-state usage instructions.
- [SHA256SUMS](https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Terraform/SHA256SUMS) — SHA-256 checksums for the Terraform configuration, lockfile, instructions and source ZIP.

Versioned downloads use [immutable terraform-2026-11-02.1](https://github.com/WEEMR/FortiAIGate/releases/tag/terraform-2026-11-02.1). Older versions remain listed for reproducibility and rollback. This generated README indexes the existing files; it is separate from their frozen manifests and checksums.

## Complete file and folder index

| Type | Path | Purpose |
| --- | --- | --- |
| File | [.terraform.lock.hcl](.terraform.lock.hcl) | Exact AWS/Azure provider selections and accepted provider package checksums; retain beside main.tf. |
| File | [FortiAIGate_MultiCloud_Terraform.zip](FortiAIGate_MultiCloud_Terraform.zip) | Downloadable Terraform source bundle containing main.tf, its provider lockfile and usage instructions. |
| File | [README.txt](README.txt) | Terraform version requirements, cloud inputs, credentials setup and separate-state usage instructions. |
| File | [SHA256SUMS](SHA256SUMS) | SHA-256 checksums for the Terraform configuration, lockfile, instructions and source ZIP. |
| File | [current.json](current.json) | Approved manifest: selects the current tested version and records payload SHA-256 hashes and byte sizes; updated only after verification. |
| File | [main.tf](main.tf) | Terraform configuration for selecting and deploying one AWS or Azure CPU lab with its own state. |
| Folder | [releases/](releases/) | Retained version directories for reproducible downloads and rollback; existing snapshot bytes are preserved. |
| Folder | [releases/2026-11-02.1/](releases/2026-11-02.1/) | Published Terraform snapshot 2026-11-02.1, associated with immutable tag terraform-2026-11-02.1. |
| File | [releases/2026-11-02.1/.terraform.lock.hcl](releases/2026-11-02.1/.terraform.lock.hcl) | Exact AWS/Azure provider selections and accepted provider package checksums; retain beside main.tf. |
| File | [releases/2026-11-02.1/FortiAIGate_MultiCloud_Terraform.zip](releases/2026-11-02.1/FortiAIGate_MultiCloud_Terraform.zip) | Downloadable Terraform source bundle containing main.tf, its provider lockfile and usage instructions. |
| File | [releases/2026-11-02.1/README.txt](releases/2026-11-02.1/README.txt) | Terraform version requirements, cloud inputs, credentials setup and separate-state usage instructions. |
| File | [releases/2026-11-02.1/SHA256SUMS](releases/2026-11-02.1/SHA256SUMS) | SHA-256 checksums for the Terraform configuration, lockfile, instructions and source ZIP. |
| Folder | [releases/2026-11-02.1/_stable/](releases/2026-11-02.1/_stable/) | Saved approved-path files for this release; promotion/rollback restores these exact launcher and compatibility alias bytes. |
| Folder | [releases/2026-11-02.1/_stable/scripts/](releases/2026-11-02.1/_stable/scripts/) | Original public path scripts/ inside the saved rollback alias tree. |
| Folder | [releases/2026-11-02.1/_stable/scripts/Terraform/](releases/2026-11-02.1/_stable/scripts/Terraform/) | Original public path scripts/Terraform/ inside the saved rollback alias tree. |
| File | [releases/2026-11-02.1/_stable/scripts/Terraform/.terraform.lock.hcl](releases/2026-11-02.1/_stable/scripts/Terraform/.terraform.lock.hcl) | Rollback snapshot of scripts/Terraform/.terraform.lock.hcl: Exact AWS/Azure provider selections and accepted provider package checksums; retain beside main.tf. |
| File | [releases/2026-11-02.1/_stable/scripts/Terraform/FortiAIGate_MultiCloud_Terraform.zip](releases/2026-11-02.1/_stable/scripts/Terraform/FortiAIGate_MultiCloud_Terraform.zip) | Rollback snapshot of scripts/Terraform/FortiAIGate_MultiCloud_Terraform.zip: Downloadable Terraform source bundle containing main.tf, its provider lockfile and usage instructions. |
| File | [releases/2026-11-02.1/_stable/scripts/Terraform/README.txt](releases/2026-11-02.1/_stable/scripts/Terraform/README.txt) | Rollback snapshot of scripts/Terraform/README.txt: Terraform version requirements, cloud inputs, credentials setup and separate-state usage instructions. |
| File | [releases/2026-11-02.1/_stable/scripts/Terraform/SHA256SUMS](releases/2026-11-02.1/_stable/scripts/Terraform/SHA256SUMS) | Rollback snapshot of scripts/Terraform/SHA256SUMS: SHA-256 checksums for the Terraform configuration, lockfile, instructions and source ZIP. |
| File | [releases/2026-11-02.1/_stable/scripts/Terraform/main.tf](releases/2026-11-02.1/_stable/scripts/Terraform/main.tf) | Rollback snapshot of scripts/Terraform/main.tf: Terraform configuration for selecting and deploying one AWS or Azure CPU lab with its own state. |
| File | [releases/2026-11-02.1/main.tf](releases/2026-11-02.1/main.tf) | Terraform configuration for selecting and deploying one AWS or Azure CPU lab with its own state. |
| File | [releases/2026-11-02.1/manifest.json](releases/2026-11-02.1/manifest.json) | Frozen manifest for release 2026-11-02.1: exact payload names, SHA-256 hashes and byte sizes used by launchers. |
| File | [releases/2026-11-02.1/publication.json](releases/2026-11-02.1/publication.json) | Publisher verification and rollback metadata: repository/tag, all published file digests and the mapping of stable aliases to _stable copies. |
