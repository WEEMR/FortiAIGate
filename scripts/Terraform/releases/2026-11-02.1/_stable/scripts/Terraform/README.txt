FortiAIGate multi-cloud Terraform source

Download the approved FortiAIGate_MultiCloud_Terraform.zip from:
https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Terraform/FortiAIGate_MultiCloud_Terraform.zip

The ZIP contains main.tf, .terraform.lock.hcl and these instructions. Extract it
into a new directory/state for each lab. Choose exactly one cloud and review the
settings in main.tf before running Terraform. Installer archives and VM images
remain in the configured S3 artifact store. Host preparation is downloaded from
the immutable shared GitHub tag and checked against the pinned SHA-256.

Use Terraform >= 1.9 and < 2.0. AWS uses your signed-in AWS CLI SSO profile;
Azure uses your normal ARM_* environment credentials and existing SSH public
key. Keep credentials, private keys, plan files and state out of Git.

Release maintenance (from the repository root):
  python3 scripts/Terraform/release.py build
  python3 scripts/Terraform/release.py publish
  python3 scripts/Terraform/release.py check
  python3 scripts/Terraform/release.py promote --version VERSION

The builder checks formatting and validates configuration using initialized,
locally available provider plugins. It never runs plan, apply or destroy. Set
TERRAFORM_BIN to a supported local Terraform executable when the PATH version
is older. First-time provider initialization is a separate operator action.
Changed published bytes require a new release version. Release ZIPs are
deterministic and contain no .terraform cache, credentials, plans or state.
