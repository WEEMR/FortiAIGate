// Copy to User_Input.auto.tfvars at the project root, then edit that file.
username = "fortilab"

// Each switch uses "yes" or "no". Each AWS gateway gets its own network.
create_FortiAIGate_CPU       = "no"
create_FortiAIGate_GPU       = "no"
create_Azure_FortiAIGate_CPU = "no"
create_AWS_Ollama           = "no"
create_Azure_Ollama         = "no"

// Required override in CloudShell: use YOUR browser public IPv4, not CloudShell's.
// Management_Source_CIDR = "203.0.113.10/32" // Your browser IPv4; /32 allows only this IP.
// SSH_Source_CIDR = "203.0.113.10/32" // Optional Azure SSH override; null detects runner/CloudShell.
// AWS_Profile = "your-profile"  // Optional; standard AWS authentication also works.
virginia_region = "us-east-1"
AWS_Availability_Zone = "auto"
Azure_Region = "eastus"
// ssh_public_key = "ssh-ed25519 ..." // Azure requires existing .pub contents.

FAIG_CPU_VM_Size = "t3a.large"
FAIG_GPU_VM_Size = "g6e.2xlarge"
// Opt in only if you approve paying for g6e.4xlarge when 2xlarge capacity is exhausted.
AWS_GPU_Allow_Larger_Fallback = "no"
Ollama_VM_Size = "t3a.large"
AZ_FAIG_CPU_VM_Size = "Standard_B2as_v2"
AZ_Ollama_VM_Size = "Standard_B2as_v2"
Gateway_API_Port = 443
Show_Installation_Progress = "yes"
// AWS_Use_Credentials = "yes" // Keep credentials when disabling existing AWS resources.
// Azure: authenticate with az login / ARM_* environment variables. Do not save secrets here.
