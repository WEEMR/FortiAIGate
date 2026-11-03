#!/bin/bash
set -euo pipefail
umask 077

Check_Project_Root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v terraform >/dev/null 2>&1; then
  printf 'Terraform was not found in PATH.\n' >&2
  exit 127
fi

Check_Temp_Dir="$(mktemp -d "${TMPDIR:-/tmp}/FortiAIGate_Check_Changes.XXXXXX")"
trap 'rm -rf "$Check_Temp_Dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'These checks create plans only; they do not apply changes or destroy resources.\n'
printf 'Providers must already be initialized. This script does not run init or upgrade providers.\n'

printf '\nChecking Terraform formatting...\n'
terraform -chdir="$Check_Project_Root" fmt -check -recursive

printf '\nValidating Terraform configuration...\n'
terraform -chdir="$Check_Project_Root" validate -no-color

printf '\nCreating a normal plan. Review the proposed changes below.\n'
terraform -chdir="$Check_Project_Root" plan -input=false -no-color -out="$Check_Temp_Dir/Normal.tfplan"

printf '\nChecking the normal plan dependency graph...\n'
terraform -chdir="$Check_Project_Root" graph -type=apply -plan="$Check_Temp_Dir/Normal.tfplan" > "$Check_Temp_Dir/Normal.dot"

printf '\nCreating a destroy-only plan. No resources will be destroyed.\n'
terraform -chdir="$Check_Project_Root" plan -destroy -input=false -no-color -out="$Check_Temp_Dir/Destroy.tfplan"

printf '\nChecking the destroy plan dependency graph...\n'
terraform -chdir="$Check_Project_Root" graph -type=apply -plan="$Check_Temp_Dir/Destroy.tfplan" > "$Check_Temp_Dir/Destroy.dot"

printf '\nAll checks passed. Review both plans before applying changes.\n'
printf 'Temporary plans are deleted when this script finishes. Use your normal Terraform commands to deploy.\n'
printf 'Passing these checks does not verify VM boot, licensing or application runtime.\n'
