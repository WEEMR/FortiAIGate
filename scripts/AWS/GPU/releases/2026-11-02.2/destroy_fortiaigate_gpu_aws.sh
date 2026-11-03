#!/usr/bin/env bash
# FortiAIGate GPU lab; run with Bash in AWS CloudShell. Version 2026-11-02.2.
set -euo pipefail
command -v python3 >/dev/null || { printf 'Python 3 is required. Run in AWS CloudShell.\n' >&2; exit 1; }
forti_gpu_script=$(mktemp "${TMPDIR:-/tmp}/fortiaigate_gpu.XXXXXXXX.py")
trap 'rm -f "$forti_gpu_script"' EXIT
cat > "$forti_gpu_script" <<'FORTIAIGATE_GPU_PY'
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

VERSION = "2026-11-02.2"
REGION = "us-east-1"
INSTANCE_TYPE = "g6e.2xlarge"
MARKER = "FortiAIGate-GPU-AWS-v1"
AMI_PARAMETER = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
os.environ.update(AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off")


class AwsError(RuntimeError):
    pass


def aws(service, operation, *arguments, **payload):
    cmd = ["aws", service, operation, *arguments, "--region", REGION,
           "--output", "json", "--no-cli-pager", "--cli-connect-timeout", "15",
           "--cli-read-timeout", "60"]
    if payload:
        cmd += ["--cli-input-json", json.dumps(payload)]
    result = subprocess.run(cmd, text=True, capture_output=True)
    if result.returncode:
        raise AwsError(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def prefix_of(value):
    value = value.strip()
    suffix = "_fortiaigate_gpu_vpc"
    if value.casefold().endswith(suffix):
        value = value[:-len(suffix)]
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]{0,23}", value):
        raise ValueError("Use a name starting with a letter, followed by letters/numbers; maximum 24 characters.")
    return value.lower()


def ipv4_cidr(value):
    raw = value.strip()
    if "/" not in raw:
        raw += "/32"
    net = ipaddress.ip_network(raw, strict=True)
    if net.version != 4 or net.prefixlen != 32 or not net.network_address.is_global:
        raise ValueError("Enter your browser's public IPv4 address, optionally ending in /32.")
    return str(net)


def stack_name(prefix):
    return "FortiAIGate-GPU-" + prefix


def identity():
    if not shutil.which("aws"):
        raise RuntimeError("AWS CLI is missing. Run this script in AWS CloudShell, not inside the Ubuntu instance.")
    result = aws("sts", "get-caller-identity")
    print("FortiAIGate AWS GPU lab " + VERSION)
    print("Account: " + result["Account"] + " | Region: " + REGION)
    return result


def describe_stack(name, optional=False):
    try:
        return aws("cloudformation", "describe-stacks", "--stack-name", name)["Stacks"][0]
    except AwsError as error:
        if optional and "does not exist" in str(error):
            return None
        raise


def owned(stack):
    tags = {t["Key"]: t["Value"] for t in stack.get("Tags", [])}
    if tags.get("DeploymentGuide") != MARKER or not tags.get("UserPrefix"):
        raise RuntimeError("This stack is not marked as a lab created by this GPU script; refusing to change it.")
    prefix = prefix_of(tags["UserPrefix"])
    if stack["StackName"] != stack_name(prefix):
        raise RuntimeError("GPU stack name and ownership tags disagree; refusing to change it.")
    return prefix


def events(name):
    try:
        data = aws("cloudformation", "describe-stack-events", "--stack-name", name)
        for row in data.get("StackEvents", [])[:15]:
            if row.get("ResourceStatusReason"):
                print("  " + row["LogicalResourceId"] + ": " + row["ResourceStatusReason"])
    except AwsError:
        pass


def wait_stack(name, target, deleting=False):
    previous = None
    for _ in range(180):
        stack = describe_stack(name, optional=deleting)
        if stack is None and deleting:
            return
        state = stack["StackStatus"]
        if state != previous:
            print("Stack status: " + state, flush=True)
            previous = state
        if state == target:
            return stack
        if not state.endswith("_IN_PROGRESS"):
            events(name)
            raise RuntimeError("Stack ended in " + state + ". Inspect CloudFormation events; use this GPU Destroy script to remove remaining stack resources.")
        time.sleep(10)
    raise RuntimeError("The 30-minute wait ended. The stack may still be working; inspect CloudFormation before running another action.")


def outputs(stack):
    values = {o["OutputKey"]: o["OutputValue"] for o in stack.get("Outputs", [])}
    for key, value in values.items():
        print(key + ": " + value)
    if values.get("InstanceId"):
        instance_id = values["InstanceId"]
        print("Session Manager: https://" + REGION + ".console.aws.amazon.com/systems-manager/session-manager/" + instance_id + "?region=" + REGION)
        print("Or run in CloudShell: aws ssm start-session --target " + instance_id + " --region " + REGION)
        print("If the instance is not connected yet, allow a few minutes for first boot and retry.")
    print("GPU drivers, Docker and FortiAIGate are installed in the next guide steps.")


def resolve_stack(value):
    if re.fullmatch(r"vpc-[0-9a-fA-F]+", value.strip(), re.IGNORECASE):
        vpc_id = value.strip().lower()
        vpcs = aws("ec2", "describe-vpcs", "--vpc-ids", vpc_id)["Vpcs"]
        if not vpcs or vpcs[0].get("IsDefault"):
            raise RuntimeError("Refusing to delete the default VPC.")
        resources = aws("cloudformation", "describe-stack-resources", "--physical-resource-id", vpc_id)["StackResources"]
        matches = {r["StackId"] for r in resources if r.get("PhysicalResourceId") == vpc_id and r.get("ResourceType") == "AWS::EC2::VPC"}
        if len(matches) != 1:
            raise RuntimeError("This VPC cannot be uniquely resolved to a CloudFormation GPU stack.")
        stack = describe_stack(matches.pop())
    else:
        prefix = prefix_of(value)
        stack = describe_stack(stack_name(prefix), optional=True)
        if stack is None:
            print("No GPU lab stack exists for that name in us-east-1. Checking for its retained cleanup role.")
            return None
    owned(stack)
    return stack


"""Embedded by parent Destroy scripts; no local imports or remote helper needed."""

OLLAMA_STACK_MARKER = "FortiAIGate-Ollama-AWS-v1"


def ollama_stack_tags(stack):
    values = {}
    for item in stack.get("Tags", []):
        if item["Key"] in values:
            raise RuntimeError("Duplicate Ollama stack ownership tags; no deletion performed.")
        values[item["Key"]] = item["Value"]
    return values


def validate_ollama_stack(stack, vpc_id, gateway_ids=None, account=None):
    values = ollama_stack_tags(stack)
    prefix = values.get("UserPrefix", "")
    gateway = values.get("FortiAIGateInstanceId", "")
    stack_id = stack.get("StackId", "")
    arn = re.fullmatch(r"arn:([a-z-]+):cloudformation:([a-z0-9-]+):([0-9]{12}):stack/([^/]+)/([a-f0-9-]+)", stack_id)
    if (values.get("DeploymentGuide") != OLLAMA_STACK_MARKER
            or values.get("FortiAIGateVpcId") != vpc_id
            or not re.fullmatch(r"[a-z][a-z0-9]{0,23}", prefix)
            or not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", gateway)
            or not arn or arn.group(2) != REGION
            or (account and arn.group(3) != account)
            or stack.get("StackName") != "Ollama-Lab-" + prefix
            or arn.group(4) != stack["StackName"]
            or (gateway_ids is not None and gateway not in gateway_ids)):
        raise RuntimeError("Linked Ollama stack ownership could not be verified: " + stack.get("StackName", stack_id))
    return stack


def inventory_ollama_stacks(api, vpc_id, gateway_ids=None, account=None):
    """Select only explicitly linked add-on stacks, never by name prefix alone."""
    result = api("cloudformation", "describe-stacks")
    if result.get("NextToken"):
        raise RuntimeError("Ollama stack inventory was incomplete; no parent deletion performed.")
    matches = []
    for stack in result.get("Stacks", []):
        if stack.get("StackStatus") == "DELETE_COMPLETE":
            continue
        values = ollama_stack_tags(stack)
        if values.get("DeploymentGuide") != OLLAMA_STACK_MARKER:
            continue
        if values.get("FortiAIGateVpcId") != vpc_id:
            continue
        matches.append(validate_ollama_stack(stack, vpc_id, gateway_ids, account))
    return sorted(matches, key=lambda s: s["StackName"])


def delete_ollama_stacks(api, stacks, timeout=1800):
    """Complete child deletion before allowing parent VPC/stack destruction."""
    for original in stacks:
        stack_id = original["StackId"]
        reviewed = ollama_stack_tags(original)
        previous = None
        deadline = time.monotonic() + timeout
        requested = False
        while True:
            try:
                data = api("cloudformation", "describe-stacks", "--stack-name", stack_id)
            except RuntimeError as error:
                if "does not exist" in str(error):
                    break
                raise
            current = data.get("Stacks", [])
            if len(current) != 1:
                raise RuntimeError("Cannot establish linked Ollama stack deletion status: " + stack_id)
            stack = current[0]
            if stack.get("StackStatus") == "DELETE_COMPLETE":
                break
            if (stack.get("StackId") != stack_id or stack.get("StackName") != original["StackName"]
                    or ollama_stack_tags(stack) != reviewed):
                raise RuntimeError("Linked Ollama stack ownership changed after preview; parent deletion stopped.")
            state = stack["StackStatus"]
            if state != previous:
                print("Linked Ollama " + original["StackName"] + ": " + state, flush=True)
                previous = state
            if state == "DELETE_FAILED" and requested:
                raise RuntimeError("Linked Ollama deletion failed; parent deletion stopped. Inspect CloudFormation events: " + stack_id)
            if state != "DELETE_IN_PROGRESS" and not requested:
                if state.endswith("_IN_PROGRESS"):
                    raise RuntimeError("Linked Ollama stack is busy (" + state + "); parent deletion stopped.")
                api("cloudformation", "delete-stack", "--stack-name", stack_id)
                requested = True
            if time.monotonic() >= deadline:
                raise RuntimeError("Timed out deleting linked Ollama stack; parent deletion stopped. Rerun Destroy to resume.")
            time.sleep(5)
        print("Deleted linked Ollama stack: " + original["StackName"], flush=True)


"""Quiet IAM existence screening; mutations still require authoritative reads.

ListRoles is eventually consistent, just like other IAM reads. A complete list
can avoid predictable GetRole failures, but never authorizes deleting a role.
CreateRole uniqueness and the ownership-checked janitor remain the backstops
for an identity appearing after the inventory was read.
"""
import re as gpu_iam_re


def gpu_find_role(name, api=None):
    api = api or aws
    if not isinstance(name, str) or not gpu_iam_re.fullmatch(r'[A-Za-z0-9_+=,.@-]{1,64}', name):
        raise ValueError('Invalid IAM role name for inventory.')
    request, seen, match = {}, set(), None
    for _ in range(1000):
        page = api('iam', 'list-roles', '--no-paginate', MaxItems=1000, **request)
        if (not isinstance(page, dict) or not isinstance(page.get('Roles'), list)
                or type(page.get('IsTruncated')) is not bool):
            raise RuntimeError('IAM role inventory is incomplete or malformed; no cleanup or Create was authorized.')
        for row in page['Roles']:
            if not isinstance(row, dict) or not isinstance(row.get('RoleName'), str):
                raise RuntimeError('IAM role inventory contains an invalid identity.')
            if row['RoleName'].casefold() == name.casefold():
                if match is not None or not isinstance(row.get('RoleId'), str) or not row['RoleId']:
                    raise RuntimeError('IAM role inventory contains an ambiguous identity.')
                match = row
        if not page['IsTruncated']:
            return match
        marker = page.get('Marker')
        if not isinstance(marker, str) or not marker or marker in seen:
            raise RuntimeError('IAM role inventory pagination did not advance.')
        seen.add(marker)
        request['Marker'] = marker
    raise RuntimeError('IAM role inventory exceeded its pagination safety limit.')


def gpu_read_role(name, api=None):
    api = api or aws
    candidate = gpu_find_role(name, api)
    if candidate is None:
        return None
    try:
        role = api('iam', 'get-role', RoleName=candidate['RoleName'])['Role']
    except AwsError as error:
        # The shared janitor may delete a listed role before this read.
        if gpu_iam_re.search(r'An error occurred \(NoSuchEntity\)', str(error)):
            return None
        raise
    if (role.get('RoleName', '').casefold() != name.casefold()
            or role.get('RoleId') != candidate['RoleId']):
        raise RuntimeError('IAM role identity changed after inventory; no cleanup was authorized.')
    return role


def cleanup_budget_role(prefix, expected_stack=None):
    try:
        _cleanup_budget_role(prefix, expected_stack)
    except AwsError as error:
        # Authenticated Destroy and the janitor may finish the same role.
        # Only exact missing-resource errors plus authoritative role absence
        # are idempotent success; permission/transport errors remain failures.
        if not re.search(r"An error occurred \(NoSuchEntity\)", str(error)):
            raise
        try:
            aws("iam", "get-role", RoleName=prefix + "_FortiAIGate_GPU_CleanupRole")
        except AwsError as current_error:
            if not re.search(r"An error occurred \(NoSuchEntity\)", str(current_error)):
                raise
        else:
            raise


def _cleanup_budget_role(prefix, expected_stack=None):
    name = prefix + "_FortiAIGate_GPU_CleanupRole"
    role = gpu_read_role(name)
    if role is None: return
    # IAM names are case-insensitive; use its returned spelling for every mutation.
    name = role["RoleName"]
    tags = {t["Key"]:t["Value"] for t in role.get("Tags", [])}
    owner = tags.get("BudgetStack", "")
    if (name.casefold() != (prefix + "_FortiAIGate_GPU_CleanupRole").casefold()
            or tags.get("DeploymentGuide") != MARKER or tags.get("UserPrefix") != prefix
            or tags.get("BudgetVersion") not in ("2h-stop-12h-delete-v1", "8h-delete-v2")
            or (expected_stack and owner != expected_stack)
            or not re.fullmatch(r"arn:[a-z-]+:cloudformation:us-east-1:[0-9]{12}:stack/" + re.escape(stack_name(prefix)) + r"/[a-f0-9-]{36}", owner)):
        raise RuntimeError("Retained cleanup role ownership could not be verified; it was not changed.")
    remaining = describe_stack(owner, optional=True)
    if remaining and remaining["StackStatus"] != "DELETE_COMPLETE":
        raise RuntimeError("The lab stack still exists. Its cleanup identity must remain until deletion completes.")
    inline = aws("iam", "list-role-policies", RoleName=name).get("PolicyNames", [])
    attached = aws("iam", "list-attached-role-policies", RoleName=name).get("AttachedPolicies", [])
    profiles = aws("iam", "list-instance-profiles-for-role", RoleName=name).get("InstanceProfiles", [])
    if attached or profiles or set(inline) - {"DeleteOnlyThisLab"}:
        raise RuntimeError("Cleanup role was modified or reused; inspect it before removing it.")
    fresh = aws("iam", "get-role", RoleName=name)["Role"]
    if (fresh.get("RoleId") != role["RoleId"]
            or {t["Key"]: t["Value"] for t in fresh.get("Tags", [])} != tags):
        raise RuntimeError("Cleanup role identity changed; it was not removed.")
    for policy in inline:
        aws("iam", "delete-role-policy", RoleName=name, PolicyName=policy)
    aws("iam", "delete-role", RoleName=name)
    print("Removed the retained, nonbillable lab cleanup role.")


def main():
    identity()
    target = input("GPU lab name prefix, full GPU VPC name, or VPC ID: ")
    stack = resolve_stack(target)
    if stack is None:
        cleanup_budget_role(prefix_of(target))
        return
    prefix = owned(stack)
    name = stack["StackName"]
    state = stack["StackStatus"]
    if state == "DELETE_IN_PROGRESS":
        print("This GPU stack is already deleting; waiting for its result.")
        wait_stack(stack["StackId"], "DELETE_COMPLETE", deleting=True)
        cleanup_budget_role(prefix, stack["StackId"])
        print("GPU lab deletion completed.")
        return
    if state.endswith("_IN_PROGRESS"):
        raise RuntimeError("The stack is busy (" + state + "). Wait for it to finish before deleting.")
    resources = aws("cloudformation", "list-stack-resources", "--stack-name", stack["StackId"])["StackResourceSummaries"]
    vpc_ids = {r["PhysicalResourceId"] for r in resources
               if r["ResourceType"] == "AWS::EC2::VPC" and r.get("PhysicalResourceId")}
    gateway_ids = {r["PhysicalResourceId"] for r in resources
                   if (r["ResourceType"] == "AWS::EC2::Instance"
                       or (r["ResourceType"] == "Custom::FleetInstance" and r.get("LogicalResourceId") == "Instance"))
                   and re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", r.get("PhysicalResourceId", ""))}
    if len(vpc_ids) > 1:
        raise RuntimeError("GPU stack has multiple VPCs; linked Ollama ownership is ambiguous.")
    linked_ollama = inventory_ollama_stacks(aws, next(iter(vpc_ids)), gateway_ids,
        account=stack["StackId"].split(":")[4]) if vpc_ids else []
    print("\nGPU stack: " + name)
    print("The following stack-owned resources will be permanently deleted:")
    for row in resources:
        print("  " + row["ResourceType"] + "  " + row.get("PhysicalResourceId", row.get("LogicalResourceId", "unknown")))
    print("Linked Ollama stacks (server, disk, SG and IAM): " +
          (", ".join(item["StackName"] for item in linked_ollama) or "none"))
    print("This terminates the GPU VM and deletes its root disk, network, role, instance profile and inline S3 policy.")
    print("Your S3 release bucket/files are retained. Resources added manually can block stack deletion; they are not force-deleted.")
    if (input("1) Destroy this GPU lab (default)  0) Cancel [1]: ").strip() or "1") != "1":
        print("Cancelled. No resources were changed.")
        return
    delete_ollama_stacks(aws, linked_ollama)
    aws("cloudformation", "delete-stack", "--stack-name", stack["StackId"])
    wait_stack(stack["StackId"], "DELETE_COMPLETE", deleting=True)
    cleanup_budget_role(prefix, stack["StackId"])
    print("Deleted the isolated FortiAIGate GPU stack and its stack-owned resources.")


if __name__ == "__main__":
    try:
        main()
    except (AwsError, RuntimeError, ValueError, OSError, KeyError) as error:
        print("\nSTOPPED: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        sys.exit("Stopped. Any submitted CloudFormation operation continues; inspect its status before retrying.")

FORTIAIGATE_GPU_PY
python3 "$forti_gpu_script"
