# FortiAIGate public downloads

Approved launchers, versioned runtime scripts, Ubuntu preparation helpers and Terraform source bundles used by the [FortiAIGate deployment guides](https://guides.fortinetpslab.com). Public downloads require no GitHub sign-in.

Choose your environment in the guide, then use its current launcher or download. The approved branch provides stable entry points; immutable release tags retain the exact tested payloads and their integrity records. Product images, installers and licenses remain in their separate artifact stores.

Legacy S3 scripts/ and user_data/ download URLs were retired on 2026-11-02. Use the current guide commands and GitHub downloads; older frozen instructions may mention retired URLs. S3 continues to host the separate product installer/image files.

| Download family | Purpose | Approved version | Guide |
| --- | --- | --- | --- |
| [AWS CPU](scripts/AWS/CPU/README.md) | AWS CPU lab deployment and reviewed cleanup. | 2026-11-02.2 | [Deployment guide](https://guides.fortinetpslab.com/cpu.html) |
| [AWS L40S GPU](scripts/AWS/GPU/README.md) | AWS L40S GPU deployment, capacity fallback and managed cleanup. | 2026-11-02.2 | [Deployment guide](https://guides.fortinetpslab.com/gpu.html) |
| [Azure CPU](scripts/Azure/CPU/README.md) | Azure CPU deployment and interactive access management. | 2026-11-02.1 | [Deployment guide](https://guides.fortinetpslab.com/cpu.html) |
| [Azure H100 GPU](scripts/Azure/GPU/README.md) | Azure H100 GPU deployment and access management. | 2026-11-02.1 | [Deployment guide](https://guides.fortinetpslab.com/gpu.html) |
| [Azure RTX GPU](scripts/Azure/RTX/README.md) | Azure RTX GPU deployment with restart and extension controls. | 2026-11-02.1 | [Deployment guide](https://guides.fortinetpslab.com/gpu.html) |
| [Home / Ubuntu](scripts/Home/README.md) | Shared Ubuntu preparation and interactive installation helpers. | 2026-11-02.1 | [Deployment guide](https://guides.fortinetpslab.com/cpu.html) |
| [Ollama model host](scripts/Ollama/README.md) | A separate Ollama/Open WebUI server linked to a FortiAIGate lab. | 2026-11-02.2 | [Deployment guide](https://guides.fortinetpslab.com/ollama.html) |
| [Terraform](scripts/Terraform/README.md) | Organized AWS CPU/GPU, Azure CPU and linked Ollama Terraform project, plus retained standalone CPU downloads. | 2026-11-02.8 | [Deployment guide](https://guides.fortinetpslab.com/cpu.html) |

Browse [all script folders](scripts/README.md), [AWS](scripts/AWS/README.md) or [Azure](scripts/Azure/README.md). Each family catalog describes its current downloads and every retained file/folder without modifying the release snapshots.
