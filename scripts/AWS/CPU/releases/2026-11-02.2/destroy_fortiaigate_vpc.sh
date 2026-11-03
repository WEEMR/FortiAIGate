cat > "${FORTIAIGATE_SCRIPT_DIR:-$HOME}/destroy_fortiaigate_vpc.py" <<'PY' && python3 -c 'from pathlib import Path; import hashlib, sys; p=Path(sys.argv[1]); raw=p.read_bytes(); expected="842b9aa8857d248e27076132d88e625c69f4b873584a0b2b4fc50d064a70825b"; hashlib.sha256(raw).hexdigest()==expected or sys.exit("Integrity check failed. Use the complete saved destroy_fortiaigate_vpc.sh file. No cleanup was started."); code=compile(raw,str(p),"exec"); sys.argv=[str(p)]; exec(code,{"__name__":"__main__","__file__":str(p)})' "${FORTIAIGATE_SCRIPT_DIR:-$HOME}/destroy_fortiaigate_vpc.py"
#!/usr/bin/env python3
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import unquote

REGION = "us-east-1"
ROLE_SUFFIX = "_FortiAIGate_Docker_SSMRole"
AWS_CLI = "aws"
os.environ.update(AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off")


def aws_cli_candidates():
    override = os.environ.get("FORTIAIGATE_AWS_CLI", "").strip()
    if override:
        path = Path(override).expanduser()
        if not path.is_absolute():
            raise RuntimeError("FORTIAIGATE_AWS_CLI must be the absolute path to the AWS CLI executable.")
        return [str(path)]
    return [
        shutil.which("aws"),
        "/usr/local/bin/aws",
        "/usr/bin/aws",
        "/usr/local/aws-cli/v2/current/bin/aws",
        str(Path.home() / ".local/bin/aws"),
        str(Path.home() / "usr/local/bin/aws"),
    ]


def resolve_aws_cli():
    checked, problems = [], []
    for candidate in aws_cli_candidates():
        if not candidate:
            continue
        path = str(Path(candidate).absolute())
        if path in checked:
            continue
        checked.append(path)
        if not Path(path).is_file() or not os.access(path, os.X_OK):
            continue
        try:
            result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as error:
            problems.append(f"{path}: {type(error).__name__}")
            continue
        version = result.stdout + "\n" + result.stderr
        match = re.search(r"\baws-cli/2\.[^\s]+", version)
        if result.returncode == 0 and match:
            return path, match.group(0)
        problems.append(f"{path}: did not return a working AWS CLI v2 version")
    details = "\n".join(problems)
    raise RuntimeError(
        "No working AWS CLI v2 was found on PATH or at the checked installation paths.\n"
        f"Operating-system user: {getpass.getuser()}\nWorking directory: {Path.cwd()}\n"
        + "Checked: " + (", ".join(checked) if checked else "no executable paths") + "\n"
        + (details + "\n" if details else "")
        + "In the AWS CloudShell panel, choose Actions > Tabs layout > New tab. "
        "Paste the complete script in that new tab.\n"
        "If the new tab still reports this error, run id -un, pwd, and command -v aws there "
        "and share their output."
    )


def prepare_aws():
    global AWS_CLI
    AWS_CLI, version = resolve_aws_cli()
    print(f"AWS CLI: {AWS_CLI} ({version})", flush=True)
    try:
        identity = call("sts", "get-caller-identity", "--cli-connect-timeout", "10", "--cli-read-timeout", "20")
    except (RuntimeError, OSError, ValueError) as error:
        raise RuntimeError(
            f"AWS CLI was found, but AWS authentication/connectivity failed: {error}\n"
            "Open a new AWS CloudShell terminal tab and run the complete script there."
        ) from error
    print(f"AWS account: {identity['Account']}\nAWS identity: {identity['Arn']}", flush=True)
    return identity["Account"]


class AwsError(RuntimeError):
    def __init__(self, message):
        super().__init__(message)
        match = re.search(r"\(([^()]+)\)", message)
        self.code = match.group(1) if match else ""


class SharedIamInUse(RuntimeError):
    """A confirmed dependency outside the selected VPC requires retaining IAM."""


def call(service, operation, *args, missing=(), region=REGION):
    if not operation.startswith(("describe-", "get-", "list-")):
        print(f"  {service} {operation}", flush=True)
    result = subprocess.run(
        [AWS_CLI, service, operation, *args, "--region", region,
         "--output", "json", "--no-cli-pager"],
        capture_output=True, text=True,
    )
    if result.returncode:
        error = AwsError(result.stderr.strip() or result.stdout.strip())
        if error.code in missing:
            return {}
        raise error
    data = json.loads(result.stdout) if result.stdout.strip() else {}
    if data.get("Unsuccessful"):
        raise RuntimeError(json.dumps(data["Unsuccessful"], indent=2))
    return data


def get(key, operation, *args, service="ec2", **kwargs):
    return call(service, operation, *args, **kwargs).get(key, [])


def tags(resource):
    return {t["Key"]: t["Value"] for t in resource.get("Tags", [])}


def wait(label, check, timeout=1800):
    print(f"Waiting for {label}...", flush=True)
    deadline, report_at = time.monotonic() + timeout, time.monotonic() + 30
    while not check():
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Timed out waiting for {label}; rerun to resume.")
        if time.monotonic() >= report_at:
            print(f"  Still waiting for {label}...", flush=True)
            report_at = time.monotonic() + 30
        time.sleep(5)


def retry(label, action, codes=("DependencyViolation", "ResourceInUse", "VolumeInUse"), timeout=1800):
    def attempt():
        try:
            action()
            return True
        except AwsError as error:
            if error.code not in codes:
                raise
            return False
    wait(label, attempt, timeout=timeout)


def iam_username(vpc, live, previous):
    candidates = {}

    def add(value):
        if value and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value):
            candidates.setdefault(value.casefold(), value)

    add(tags(vpc).get("Owner"))
    name = tags(vpc).get("Name", "")
    suffix = "_FortiAIGate_VPC"
    if name.casefold().endswith(suffix.casefold()):
        add(name[:-len(suffix)])
    add((previous.get("iam") or {}).get("username"))
    # Resolve renamed VPCs by the exact lab profile already attached to instances.
    if not candidates:
        for instance in live:
            name = instance.get("IamInstanceProfile", {}).get("Arn", "").rsplit("/", 1)[-1]
            if name.casefold().endswith(ROLE_SUFFIX.casefold()):
                add(name[:-len(ROLE_SUFFIX)])
    if len(candidates) > 1:
        raise RuntimeError("Conflicting IAM usernames in this VPC's tags, instance profiles or saved inventory: "
                           + ", ".join(candidates.values()))
    if candidates:
        return next(iter(candidates.values()))
    value = input("Original username for IAM cleanup (Enter to skip IAM for this VPC): ").strip()
    if value and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value):
        raise RuntimeError("Invalid IAM username prefix.")
    return value or None


def check_iam_usage(profile, allowed_vpc=None, allowed_asgs=()):
    """IAM is global: check EC2 and Auto Scaling in every enabled Region."""
    if not profile:
        return
    profile_arn, profile_name = profile["Arn"], profile["InstanceProfileName"]

    def matches(value):
        if isinstance(value, dict):
            value = value.get("Arn") or value.get("Name") or ""
        return bool(value) and value.casefold() in (profile_arn.casefold(), profile_name.casefold())

    regions = sorted({r["RegionName"] for r in get("Regions", "describe-regions")})
    if REGION not in regions:
        raise RuntimeError("Could not establish the enabled Regions for the IAM usage check.")
    print(f"Checking IAM profile usage in {len(regions)} enabled Regions...", flush=True)
    for region in regions:
        reservations = get("Reservations", "describe-instances", "--filters",
                           f"Name=iam-instance-profile.arn,Values={profile_arn}", region=region)
        for reservation in reservations:
            for instance in reservation["Instances"]:
                if instance["State"]["Name"] != "terminated" and not (
                        allowed_vpc and region == REGION and instance.get("VpcId") == allowed_vpc):
                    raise SharedIamInUse(f"EC2 instance {instance['InstanceId']} in {region} "
                                         f"(VPC {instance.get('VpcId', 'unknown')}) still uses this IAM profile.")
        template_cache = {}
        for group in get("AutoScalingGroups", "describe-auto-scaling-groups", service="autoscaling", region=region):
            if region == REGION and group["AutoScalingGroupName"] in allowed_asgs:
                continue
            used = False
            if group.get("LaunchConfigurationName"):
                configs = get("LaunchConfigurations", "describe-launch-configurations", "--launch-configuration-names",
                              group["LaunchConfigurationName"], service="autoscaling", region=region)
                if not configs:
                    raise RuntimeError("Could not inspect Auto Scaling launch configuration: " + group["LaunchConfigurationName"])
                used = any(matches(c.get("IamInstanceProfile")) for c in configs)
            mixed = group.get("MixedInstancesPolicy", {}).get("LaunchTemplate", {})
            specs = [group.get("LaunchTemplate"), mixed.get("LaunchTemplateSpecification")]
            specs += [o.get("LaunchTemplateSpecification") for o in mixed.get("Overrides", [])]
            for spec in filter(None, specs):
                key = json.dumps(spec, sort_keys=True)
                if key not in template_cache:
                    flag, value = ("--launch-template-id", spec["LaunchTemplateId"]) if spec.get("LaunchTemplateId") else (
                        "--launch-template-name", spec["LaunchTemplateName"])
                    versions = get("LaunchTemplateVersions", "describe-launch-template-versions", flag, value,
                                   "--versions", str(spec.get("Version", "$Default")), region=region)
                    if not versions:
                        raise RuntimeError("Could not inspect Auto Scaling launch template: " + value)
                    template_cache[key] = any(matches(v.get("LaunchTemplateData", {}).get("IamInstanceProfile")) for v in versions)
                used |= template_cache[key]
            if used:
                raise SharedIamInUse(f"Auto Scaling group {group['AutoScalingGroupName']} in {region} "
                                     "still references this IAM profile.")


def initial_iam_name_present(operation, key, name_field, id_field, name):
    """Screen an unknown orphan name; never use this to prove a known object deleted."""
    marker, markers, found = None, set(), False
    for _ in range(100):
        parameters = {"MaxItems": 1000}
        if marker is not None:
            parameters["Marker"] = marker
        page = call("iam", operation, "--no-paginate", "--cli-input-json", json.dumps(parameters))
        if (not isinstance(page, dict) or "NextToken" in page or not isinstance(page.get(key), list)
                or len(page[key]) > 1000 or type(page.get("IsTruncated")) is not bool):
            raise RuntimeError("Incomplete or malformed IAM discovery response: " + operation)
        for item in page[key]:
            if (not isinstance(item, dict)
                    or not isinstance(item.get(name_field), str)
                    or not re.fullmatch(r"[A-Za-z0-9_+=,.@-]{1,128}", item[name_field])
                    or not isinstance(item.get(id_field), str) or not item[id_field]
                    or not isinstance(item.get("Arn"), str) or not item["Arn"]):
                raise RuntimeError("Malformed IAM discovery resource: " + operation)
            found |= item[name_field].casefold() == name.casefold()
        if not page["IsTruncated"]:
            if "Marker" in page:
                raise RuntimeError("Unexpected IAM discovery marker: " + operation)
            return found
        marker = page.get("Marker")
        if (not isinstance(marker, str) or not marker.strip() or len(marker) > 1024
                or any(ord(character) < 32 for character in marker) or marker in markers):
            raise RuntimeError("Missing, invalid or repeated IAM discovery marker: " + operation)
        markers.add(marker)
    raise RuntimeError("IAM discovery exceeded its pagination limit: " + operation)


def inventory_iam(username, account, allowed_vpc=None, allowed_asgs=(), initial_discovery=False):
    plan = dict(username=username, role=None, profile=None, inline_policies=[], managed_policies=[], retained_reasons=[])
    if not username:
        return plan
    name = username + ROLE_SUFFIX
    if len(name) > 64:
        print("No creation-script IAM role can have this prefix: its name would exceed 64 characters.")
        return plan
    if initial_discovery:
        # A repeated Destroy with no VPC commonly has no remaining IAM bundle.
        # Finish both inventories before accepting that initial absence. Any
        # positive hit still receives both direct Gets and the normal checks.
        role_present = initial_iam_name_present("list-roles", "Roles", "RoleName", "RoleId", name)
        profile_present = initial_iam_name_present(
            "list-instance-profiles", "InstanceProfiles", "InstanceProfileName", "InstanceProfileId", name)
        if not role_present and not profile_present:
            return plan
    role = call("iam", "get-role", "--role-name", name, missing=("NoSuchEntity",)).get("Role")
    profile = call("iam", "get-instance-profile", "--instance-profile-name", name,
                   missing=("NoSuchEntity",)).get("InstanceProfile")
    for resource, field in ((role, "RoleName"), (profile, "InstanceProfileName")):
        if resource:
            if (resource[field].casefold() != name.casefold()
                    or resource["Arn"].split(":")[4] != account
                    or (tags(resource).get("Owner") and tags(resource)["Owner"].casefold() != username.casefold())):
                raise RuntimeError("IAM name/account/owner does not match the selected username: " + resource["Arn"])
    if profile and any(r["RoleName"].casefold() != name.casefold() for r in profile.get("Roles", [])):
        raise RuntimeError("The matching instance profile contains a different role; it will not be removed.")
    if role:
        document = role["AssumeRolePolicyDocument"]
        if isinstance(document, str):
            document = json.loads(unquote(document))
        statements = document.get("Statement", [])
        if isinstance(statements, dict):
            statements = [statements]
        for statement in statements:
            if statement.get("Effect") != "Allow":
                continue
            principal = statement.get("Principal", {})
            services = principal.get("Service") if isinstance(principal, dict) else None
            services = services if isinstance(services, list) else [services]
            actions = statement.get("Action", [])
            actions = actions if isinstance(actions, list) else [actions]
            if (set(principal) != {"Service"} or services != ["ec2.amazonaws.com"]
                    or actions != ["sts:AssumeRole"] or "NotPrincipal" in statement or "NotAction" in statement):
                raise RuntimeError("The matching role also trusts a principal other than EC2; review its other uses before deleting it.")
        bound = get("InstanceProfiles", "list-instance-profiles-for-role", "--role-name", role["RoleName"], service="iam")
        if any(not profile or p["InstanceProfileId"] != profile["InstanceProfileId"] for p in bound):
            raise RuntimeError("The matching role is associated with another instance profile; it will not be deleted.")
        plan["role"] = {k: role[k] for k in ("RoleName", "RoleId", "Arn")}
        plan["inline_policies"] = sorted(get("PolicyNames", "list-role-policies", "--role-name", role["RoleName"], service="iam"))
        plan["managed_policies"] = sorted(p["PolicyArn"] for p in get(
            "AttachedPolicies", "list-attached-role-policies", "--role-name", role["RoleName"], service="iam"))
    if profile:
        plan["profile"] = {k: profile[k] for k in ("InstanceProfileName", "InstanceProfileId", "Arn")}
        plan["profile"]["Roles"] = [{"RoleName": r["RoleName"]} for r in profile.get("Roles", [])]
    try:
        check_iam_usage(plan["profile"], allowed_vpc, allowed_asgs)
    except SharedIamInUse as error:
        # Preserve the complete IAM bundle; never detach policies used by another VPC.
        plan["retained_reasons"].append(str(error))
    return plan


def iam_plan_rows(plan):
    if plan.get("retained_reasons"):
        return [
            ("RETAIN IAM role", [plan["role"]["Arn"]] if plan["role"] else []),
            ("RETAIN IAM instance profile", [plan["profile"]["Arn"]] if plan["profile"] else []),
            ("RETAIN IAM inline policies (including S3 read)", plan["inline_policies"]),
            ("KEEP managed policy attachments", plan["managed_policies"]),
            ("Reason IAM cleanup is skipped", plan["retained_reasons"]),
        ]
    return [
        ("IAM role", [plan["role"]["Arn"]] if plan["role"] else []),
        ("IAM instance profile", [plan["profile"]["Arn"]] if plan["profile"] else []),
        ("IAM inline policies to delete (including S3 read)", plan["inline_policies"]),
        ("Managed policies to detach (policy objects retained)", plan["managed_policies"]),
    ]


def delete_iam(plan, account):
    if not plan["role"] and not plan["profile"]:
        return True
    if plan.get("retained_reasons"):
        print("Retained shared IAM role/profile and all policies: " + "; ".join(plan["retained_reasons"]), flush=True)
        return False
    # Repeat dependency and identity checks after EC2/ASG termination, just before IAM deletion.
    current = inventory_iam(plan["username"], account)
    if current.get("retained_reasons"):
        plan["retained_reasons"] = current["retained_reasons"]
        print("Retained IAM resources after rechecking usage: " + "; ".join(plan["retained_reasons"]), flush=True)
        return False
    for kind, id_key in (("role", "RoleId"), ("profile", "InstanceProfileId")):
        if current[kind] and (not plan[kind] or current[kind][id_key] != plan[kind][id_key]):
            raise RuntimeError(f"IAM {kind} was created or replaced after the preview; rerun to review it.")
    for key in ("inline_policies", "managed_policies"):
        if set(current[key]) - set(plan[key]):
            raise RuntimeError("New IAM policies appeared after the preview; rerun to review them.")
    profile, role = current["profile"], current["role"]
    if profile:
        for bound_role in profile["Roles"]:
            call("iam", "remove-role-from-instance-profile", "--instance-profile-name", profile["InstanceProfileName"],
                 "--role-name", bound_role["RoleName"], missing=("NoSuchEntity",))
        retry("IAM instance profile deletion", lambda: call("iam", "delete-instance-profile", "--instance-profile-name",
              profile["InstanceProfileName"], missing=("NoSuchEntity",)), codes=("DeleteConflict", "ConcurrentModification"), timeout=180)
    if role:
        for name in current["inline_policies"]:
            call("iam", "delete-role-policy", "--role-name", role["RoleName"], "--policy-name", name, missing=("NoSuchEntity",))
        for arn in current["managed_policies"]:
            call("iam", "detach-role-policy", "--role-name", role["RoleName"], "--policy-arn", arn, missing=("NoSuchEntity",))
        retry("IAM role deletion", lambda: call("iam", "delete-role", "--role-name", role["RoleName"], missing=("NoSuchEntity",)),
              codes=("DeleteConflict", "ConcurrentModification"), timeout=180)
    print("Deleted the inventoried IAM role/profile and inline policies; detached managed policy objects are retained.", flush=True)
    return True


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


def confirm_deletion():
    print("\n1) Permanently delete the listed resources (default)")
    print("2) Cancel")
    if (input("Choose [1]: ").strip() or "1") != "1":
        print("Cancelled. Nothing deleted.")
        return False
    return True


def main(account=None):
    selector = input("Enter a name prefix, full VPC name, or VPC ID: ").strip()
    suffix = "_FortiAIGate_VPC"
    by_id = bool(re.fullmatch(r"vpc-(?:[0-9a-f]{8}|[0-9a-f]{17})", selector, re.IGNORECASE))
    if not by_id:
        prefix = selector[:-len(suffix)] if selector.casefold().endswith(suffix.casefold()) else selector
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", prefix):
            raise RuntimeError("Enter a valid name prefix, full VPC name, or VPC ID.")
    account = account or call("sts", "get-caller-identity")["Account"]
    if by_id:
        requested_id = selector.lower()
        vpcs = get("Vpcs", "describe-vpcs", "--vpc-ids", requested_id,
                   missing=("InvalidVpcID.NotFound",))
        vpcs = [v for v in vpcs if v["VpcId"].lower() == requested_id]
    else:
        requested_name = f"{prefix}{suffix}".casefold()
        # AWS tag filters are case-sensitive; compare names locally instead.
        vpcs = get("Vpcs", "describe-vpcs", "--filters", "Name=is-default,Values=false")
        vpcs = [v for v in vpcs if not v.get("IsDefault")
                and tags(v).get("Name", "").casefold() == requested_name]
    if not vpcs:
        print(f"No matching VPC in account {account}, {REGION}.")
        if not by_id:
            iam = inventory_iam(prefix, account, initial_discovery=True)
            if iam["role"] or iam["profile"]:
                print("\nRemaining IAM resources for this username:")
                for kind, values in iam_plan_rows(iam):
                    print(f"{kind}: " + (", ".join(values) if values else "none"))
                if iam.get("retained_reasons"):
                    print("Nothing to delete: the remaining IAM resources are still shared. No resources were changed.")
                    return
                if confirm_deletion():
                    delete_iam(iam, account)
        return
    vpcs.sort(key=lambda v: v["VpcId"])
    print(f"\nAccount: {account}   Region: {REGION}")
    print("\n".join("{} {} {}".format(v["VpcId"], tags(v).get("Name", "(unnamed)"), v["CidrBlock"]) for v in vpcs))
    selected = vpcs[0]["VpcId"] if len(vpcs) == 1 else input("Select a VPC ID from the list: ").strip().lower()
    vpc = next((v for v in vpcs if v["VpcId"] == selected), None)
    if not vpc:
        raise RuntimeError("That VPC ID is not one of the matching VPCs.")
    if vpc.get("IsDefault"):
        raise RuntimeError("The default VPC cannot be deleted by this script.")
    if vpc["CidrBlock"] not in ("10.0.0.0/16", "10.250.0.0/16"):
        raise RuntimeError("VPC CIDR does not match a supported CPU lab creation script.")
    vpc_id = vpc["VpcId"]
    vpc_name = tags(vpc).get("Name") or vpc_id
    vf = f"Name=vpc-id,Values={vpc_id}"
    state_dir = Path(os.environ.get("FORTIAIGATE_STATE_DIR", str(Path.home())))
    state_file = state_dir / f"fortiaigate-cleanup-{account}-{REGION}-{vpc_id}.json"
    previous = json.loads(state_file.read_text()) if state_file.exists() else {}
    if previous and (previous.get("account"), previous.get("region"), previous.get("vpc_id")) != (account, REGION, vpc_id):
        raise RuntimeError("Cleanup inventory belongs to a different account, region or VPC.")

    def scoped(key, operation):
        # NAT gateway inventory and polling use the singular --filter option.
        filter_flag = "--filter" if operation == "describe-nat-gateways" else "--filters"
        return get(key, operation, filter_flag, vf)

    def instances():
        return [i for r in scoped("Reservations", "describe-instances")
                for i in r["Instances"] if i["State"]["Name"] != "terminated"]

    def interfaces():
        return scoped("NetworkInterfaces", "describe-network-interfaces")

    def network():
        data = {key: scoped(key, op) for key, op in (
            ("Subnets", "describe-subnets"), ("SecurityGroups", "describe-security-groups"),
            ("RouteTables", "describe-route-tables"), ("NetworkAcls", "describe-network-acls"))}
        data["InternetGateways"] = get("InternetGateways", "describe-internet-gateways", "--filters",
                                       f"Name=attachment.vpc-id,Values={vpc_id}")
        data["EgressOnlyInternetGateways"] = [g for g in get("EgressOnlyInternetGateways", "describe-egress-only-internet-gateways")
                                            if any(a["VpcId"] == vpc_id for a in g["Attachments"])]
        return data

    print("Inventorying VPC resources...", flush=True)
    live, enis, net = instances(), interfaces(), network()
    linked_ollama = inventory_ollama_stacks(call, vpc_id, account=account)
    subnet_ids = {s["SubnetId"] for s in net["Subnets"]}
    iid_scope = {i["InstanceId"] for i in live} | set(previous.get("instances", []))
    asgs = []
    for group in get("AutoScalingGroups", "describe-auto-scaling-groups", service="autoscaling"):
        subnets = set(filter(None, group.get("VPCZoneIdentifier", "").split(",")))
        members = {i["InstanceId"] for i in group.get("Instances", [])}
        if subnets & subnet_ids or members & iid_scope:
            if subnets - subnet_ids or members - iid_scope:
                raise RuntimeError(f"Auto Scaling group spans resources outside this VPC: {group['AutoScalingGroupName']}")
            asgs.append(group)
    lbs = [b for b in get("LoadBalancers", "describe-load-balancers", service="elbv2") if b.get("VpcId") == vpc_id]
    classic = [b for b in get("LoadBalancerDescriptions", "describe-load-balancers", service="elb") if b.get("VPCId") == vpc_id]
    targets = [t for t in get("TargetGroups", "describe-target-groups", service="elbv2") if t.get("VpcId") == vpc_id]
    all_nats = scoped("NatGateways", "describe-nat-gateways")
    nats = [n for n in all_nats if n["State"] not in ("deleted", "failed")]
    endpoints = [e for e in scoped("VpcEndpoints", "describe-vpc-endpoints") if e["State"] not in ("deleted", "failed", "rejected")]
    tgws = [a for a in scoped("TransitGatewayVpcAttachments", "describe-transit-gateway-vpc-attachments")
            if a["State"] not in ("deleted", "failed", "rejected")]
    peers = [p for p in get("VpcPeeringConnections", "describe-vpc-peering-connections")
             if vpc_id in (p["RequesterVpcInfo"]["VpcId"], p["AccepterVpcInfo"]["VpcId"])
             and p["Status"]["Code"] not in ("deleted", "failed", "expired", "rejected")]
    vpns = get("VpnGateways", "describe-vpn-gateways", "--filters", f"Name=attachment.vpc-id,Values={vpc_id}")
    if vpns:
        raise RuntimeError("Detach VPN gateways before cleanup: " + ", ".join(g["VpnGatewayId"] for g in vpns))

    known_managed = {x["NetworkInterfaceId"] for n in nats for x in n.get("NatGatewayAddresses", []) if x.get("NetworkInterfaceId")}
    known_managed |= {x for e in endpoints for x in e.get("NetworkInterfaceIds", [])}
    lb_descriptions = {"ELB " + b["LoadBalancerArn"].split(":loadbalancer/")[1] for b in lbs}
    lb_descriptions |= {"ELB " + b["LoadBalancerName"] for b in classic}

    def check_bound(current_instances, current_enis):
        for i in current_instances:
            if any(e.get("VpcId", vpc_id) != vpc_id for e in i.get("NetworkInterfaces", [])):
                raise RuntimeError(f"Instance has an interface in another VPC: {i['InstanceId']}")
            if any(k in tags(i) for k in ("aws:ec2:fleet-id", "aws:ec2spot:fleet-request-id", "eks:cluster-name", "aws:eks:cluster-name")):
                raise RuntimeError(f"Remove the owning fleet or EKS node group first: {i['InstanceId']}")
        for e in current_enis:
            known = (e["NetworkInterfaceId"] in known_managed or e.get("Description") in lb_descriptions
                     or (e.get("InterfaceType") == "transit_gateway" and tgws))
            owner = e.get("Attachment", {}).get("InstanceId")
            if (owner and owner not in iid_scope) or (e["Status"] != "available" and not known and (e.get("RequesterManaged") or not owner)):
                raise RuntimeError(f"Remove the owning service first: {e['NetworkInterfaceId']} {e.get('Description', '')}")

    def bound_resources(current_instances, current_enis):
        ids = set(previous.get("volumes", []))
        ids |= {m["Ebs"]["VolumeId"] for i in current_instances for m in i.get("BlockDeviceMappings", []) if "Ebs" in m}
        volumes = {v["VolumeId"]: v for v in get("Volumes", "describe-volumes", "--filters", f"Name=tag:VpcId,Values={vpc_id}")}
        ordered = sorted(ids)
        for start in range(0, len(ordered), 100):
            for volume in get("Volumes", "describe-volumes", "--filters", "Name=volume-id,Values=" + ",".join(ordered[start:start + 100])):
                volumes[volume["VolumeId"]] = volume
        for v in volumes.values():
            if any(a["InstanceId"] not in iid_scope for a in v.get("Attachments", [])) or v.get("Operator", {}).get("Managed"):
                raise RuntimeError(f"Volume is shared outside this VPC or service-managed: {v['VolumeId']}")
        eni_ids = {e["NetworkInterfaceId"] for e in current_enis}
        allocations = set(previous.get("eips", [])) | {a["AllocationId"] for n in all_nats for a in n.get("NatGatewayAddresses", []) if a.get("AllocationId")}
        addresses = [a for a in get("Addresses", "describe-addresses")
                     if a.get("AllocationId") and (a.get("NetworkInterfaceId") in eni_ids or a.get("InstanceId") in iid_scope
                     or a["AllocationId"] in allocations or tags(a).get("VpcId") == vpc_id)]
        for a in addresses:
            if a.get("InstanceId") and a["InstanceId"] not in iid_scope:
                raise RuntimeError(f"Elastic IP is associated with an instance outside this VPC: {a['AllocationId']}")
            if a.get("NetworkInterfaceId") and a["NetworkInterfaceId"] not in eni_ids:
                other = get("NetworkInterfaces", "describe-network-interfaces", "--filters", "Name=network-interface-id,Values=" + a["NetworkInterfaceId"])
                if any(e["VpcId"] != vpc_id for e in other):
                    raise RuntimeError(f"Elastic IP is associated outside this VPC: {a['AllocationId']}")
        return list(volumes.values()), addresses

    check_bound(live, enis)
    volumes, addresses = bound_resources(live, enis)
    iam = inventory_iam(iam_username(vpc, live, previous), account, vpc_id,
                        {g["AutoScalingGroupName"] for g in asgs})
    automatic_ips = sorted({i["PublicIpAddress"] for i in live if i.get("PublicIpAddress")}
                           - {a["PublicIp"] for a in addresses})
    plan = [
        ("Linked Ollama CloudFormation stacks (server, disk, SG and IAM)", [s["StackName"] for s in linked_ollama]),
        ("Instances", [i["InstanceId"] for i in live]),
        ("EBS volumes (DATA WILL BE DELETED)", [v["VolumeId"] for v in volumes]),
        ("Elastic IP allocations", [a["AllocationId"] + " / " + a["PublicIp"] for a in addresses]),
        ("Automatic public IPv4 addresses", automatic_ips),
        ("Network interfaces", [e["NetworkInterfaceId"] for e in enis]),
        ("Auto Scaling groups", [g["AutoScalingGroupName"] for g in asgs]),
        ("Load balancers", [b["LoadBalancerArn"] for b in lbs] + [b["LoadBalancerName"] for b in classic]),
        ("Target groups", [t["TargetGroupArn"] for t in targets]),
        ("NAT gateways", [n["NatGatewayId"] for n in nats]),
        ("VPC endpoints", [e["VpcEndpointId"] for e in endpoints]),
        ("Transit gateway attachments", [a["TransitGatewayAttachmentId"] for a in tgws]),
        ("VPC peering connections", [p["VpcPeeringConnectionId"] for p in peers]),
    ]
    network_keys = {"Subnets": "SubnetId", "SecurityGroups": "GroupId", "RouteTables": "RouteTableId",
                    "NetworkAcls": "NetworkAclId", "InternetGateways": "InternetGatewayId", "EgressOnlyInternetGateways": "EgressOnlyInternetGatewayId"}
    plan += [(key, [r[id_key] for r in net[key]]) for key, id_key in network_keys.items()]
    plan += iam_plan_rows(iam)
    print("\nCleanup plan (RETAIN entries will not be deleted):")
    for kind, values in plan:
        print(f"{kind}: " + (", ".join(values) if values else "none"))
    print("VPC:", vpc_id)
    print("EC2/load-balancer deletion protection will be disabled. No snapshots will be created.")
    print("Existing managed prefix lists are retained.")
    print("Unattributed detached disks/IPs and existing snapshots/AMIs are retained.")
    if not confirm_deletion():
        return

    def save_inventory():
        payload = dict(account=account, region=REGION, vpc_id=vpc_id,
                       instances=sorted(iid_scope), volumes=sorted(v["VolumeId"] for v in volumes),
                       eips=sorted(a["AllocationId"] for a in addresses), iam=iam)
        temporary = state_file.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, indent=2))
        temporary.replace(state_file)
        print("Saved resumable inventory:", state_file.resolve(), flush=True)

    save_inventory()
    # Complete stack-owned add-on cleanup before touching its VPC resources.
    delete_ollama_stacks(call, linked_ollama)
    # Prevent replacement instances, then capture any instances launched during inventory.
    for group in asgs:
        call("autoscaling", "suspend-processes", "--auto-scaling-group-name", group["AutoScalingGroupName"], "--scaling-processes", "Launch")
    fresh, fresh_enis = instances(), interfaces()
    iid_scope.update(i["InstanceId"] for i in fresh)
    check_bound(fresh, fresh_enis)
    previous.update(volumes=[v["VolumeId"] for v in volumes], eips=[a["AllocationId"] for a in addresses])
    volumes, addresses = bound_resources(fresh, fresh_enis)
    save_inventory()
    asg_names = {g["AutoScalingGroupName"] for g in asgs}
    asg_members = {i["InstanceId"] for g in asgs for i in g.get("Instances", [])}
    for instance in fresh:
        if instance["State"]["Name"] != "shutting-down":
            call("ec2", "modify-instance-attribute", "--instance-id", instance["InstanceId"], "--disable-api-termination", '{"Value":false}')
        if (instance.get("SpotInstanceRequestId") and instance["InstanceId"] not in asg_members
                and tags(instance).get("aws:autoscaling:groupName") not in asg_names):
            call("ec2", "cancel-spot-instance-requests", "--spot-instance-request-ids", instance["SpotInstanceRequestId"])
    for group in asgs:
        call("autoscaling", "delete-auto-scaling-group", "--auto-scaling-group-name", group["AutoScalingGroupName"], "--force-delete")
    for instance in fresh:
        call("ec2", "terminate-instances", "--instance-ids", instance["InstanceId"])

    for b in lbs:
        call("elbv2", "modify-load-balancer-attributes", "--load-balancer-arn", b["LoadBalancerArn"], "--attributes", "Key=deletion_protection.enabled,Value=false", missing=("LoadBalancerNotFound",))
        call("elbv2", "delete-load-balancer", "--load-balancer-arn", b["LoadBalancerArn"])
    for b in classic:
        call("elb", "delete-load-balancer", "--load-balancer-name", b["LoadBalancerName"])
    endpoint_ids = {e["VpcEndpointId"] for e in endpoints}
    for table in net["RouteTables"]:
        for route in table.get("Routes", []):
            if route.get("VpcEndpointId") in endpoint_ids:
                destination = next((k for k in ("DestinationCidrBlock", "DestinationIpv6CidrBlock", "DestinationPrefixListId") if k in route), None)
                flag = {"DestinationCidrBlock": "--destination-cidr-block", "DestinationIpv6CidrBlock": "--destination-ipv6-cidr-block", "DestinationPrefixListId": "--destination-prefix-list-id"}[destination]
                call("ec2", "delete-route", "--route-table-id", table["RouteTableId"], flag, route[destination])
    for e in endpoints:
        if e["State"] != "deleting":
            call("ec2", "delete-vpc-endpoints", "--vpc-endpoint-ids", e["VpcEndpointId"])
    for n in nats:
        if n["State"] != "deleting":
            call("ec2", "delete-nat-gateway", "--nat-gateway-id", n["NatGatewayId"])
    for a in tgws:
        if a["State"] != "deleting":
            call("ec2", "delete-transit-gateway-vpc-attachment", "--transit-gateway-attachment-id", a["TransitGatewayAttachmentId"])
    for p in peers:
        if p["Status"]["Code"] != "deleting":
            call("ec2", "delete-vpc-peering-connection", "--vpc-peering-connection-id", p["VpcPeeringConnectionId"])

    wait("instance termination", lambda: not instances())
    if asgs:
        names = {g["AutoScalingGroupName"] for g in asgs}
        wait("Auto Scaling group deletion", lambda: not any(g["AutoScalingGroupName"] in names for g in get("AutoScalingGroups", "describe-auto-scaling-groups", service="autoscaling")))
    if nats:
        wait("NAT gateway deletion", lambda: all(n["State"] in ("deleted", "failed") for n in scoped("NatGateways", "describe-nat-gateways")))
    if endpoints:
        wait("endpoint deletion", lambda: all(e["State"] in ("deleted", "failed", "rejected") for e in scoped("VpcEndpoints", "describe-vpc-endpoints")))
    if tgws:
        wait("transit gateway attachment deletion", lambda: all(a["State"] in ("deleted", "failed", "rejected") for a in scoped("TransitGatewayVpcAttachments", "describe-transit-gateway-vpc-attachments")))
    wait("network interfaces to detach", lambda: all(e["Status"] == "available" and not e.get("Attachment") for e in interfaces()))
    for t in targets:
        retry("target group deletion", lambda t=t: call("elbv2", "delete-target-group", "--target-group-arn", t["TargetGroupArn"], missing=("TargetGroupNotFound",)))

    for volume in volumes:
        vid = volume["VolumeId"]
        def delete_volume():
            current = get("Volumes", "describe-volumes", "--filters", f"Name=volume-id,Values={vid}")
            if not current or current[0]["State"] == "deleting":
                return
            if any(a["InstanceId"] not in iid_scope for a in current[0].get("Attachments", [])):
                raise RuntimeError(f"Volume became attached outside this VPC: {vid}")
            if current[0].get("Attachments"):
                raise AwsError(f"(VolumeInUse) Waiting for volume detachment: {vid}")
            if current[0].get("Operator", {}).get("Managed"):
                raise RuntimeError(f"Volume became service-managed: {vid}")
            call("ec2", "delete-volume", "--volume-id", vid, missing=("InvalidVolume.NotFound",))
        retry("volume deletion: " + vid, delete_volume)
    for address in addresses:
        aid = address["AllocationId"]
        def release_address():
            current = get("Addresses", "describe-addresses", "--filters", f"Name=allocation-id,Values={aid}")
            if not current:
                return
            a = current[0]
            if a.get("InstanceId") and a["InstanceId"] not in iid_scope:
                raise RuntimeError(f"Elastic IP became associated outside this VPC: {aid}")
            if a.get("NetworkInterfaceId"):
                attached = get("NetworkInterfaces", "describe-network-interfaces", "--filters", "Name=network-interface-id,Values=" + a["NetworkInterfaceId"])
                if not attached:
                    raise AwsError(f"(IncorrectState) Waiting for EIP association metadata to clear: {aid}")
                if any(e["VpcId"] != vpc_id for e in attached):
                    raise RuntimeError(f"Elastic IP became associated outside this VPC: {aid}")
            if a.get("AssociationId"):
                call("ec2", "disassociate-address", "--association-id", a["AssociationId"], missing=("InvalidAssociationID.NotFound",))
            call("ec2", "release-address", "--allocation-id", aid, missing=("InvalidAllocationID.NotFound",))
        retry("Elastic IP release: " + aid, release_address, codes=("InvalidIPAddress.InUse", "IncorrectState"))
    for e in interfaces():
        call("ec2", "delete-network-interface", "--network-interface-id", e["NetworkInterfaceId"], missing=("InvalidNetworkInterfaceID.NotFound",))
    if volumes:
        vids = {v["VolumeId"] for v in volumes}
        wait("EBS volumes to finish deleting", lambda: not any(v["VolumeId"] in vids for v in get("Volumes", "describe-volumes")))

    # Refresh network state after service resources have disappeared.
    current_net = network()
    for key, id_key in network_keys.items():
        unexpected = {r[id_key] for r in current_net[key]} - {r[id_key] for r in net[key]}
        if unexpected:
            raise RuntimeError(f"New network resources appeared; rerun to review: {sorted(unexpected)}")
    for g in current_net["SecurityGroups"]:
        for direction, field in (("ingress", "IpPermissions"), ("egress", "IpPermissionsEgress")):
            if g.get(field):
                call("ec2", "revoke-security-group-" + direction, "--group-id", g["GroupId"], "--ip-permissions", json.dumps(g[field]))
    for g in current_net["SecurityGroups"]:
        if g["GroupName"] != "default":
            retry("security group deletion", lambda g=g: call("ec2", "delete-security-group", "--group-id", g["GroupId"]))
    for s in current_net["Subnets"]:
        retry("subnet deletion", lambda s=s: call("ec2", "delete-subnet", "--subnet-id", s["SubnetId"]))
    for t in current_net["RouteTables"]:
        if not any(a.get("Main") for a in t.get("Associations", [])):
            for a in t.get("Associations", []):
                call("ec2", "disassociate-route-table", "--association-id", a["RouteTableAssociationId"], missing=("InvalidAssociationID.NotFound",))
            retry("route table deletion", lambda t=t: call("ec2", "delete-route-table", "--route-table-id", t["RouteTableId"]))
    for a in current_net["NetworkAcls"]:
        if not a["IsDefault"]:
            call("ec2", "delete-network-acl", "--network-acl-id", a["NetworkAclId"])
    for g in current_net["InternetGateways"]:
        call("ec2", "detach-internet-gateway", "--internet-gateway-id", g["InternetGatewayId"], "--vpc-id", vpc_id)
        call("ec2", "delete-internet-gateway", "--internet-gateway-id", g["InternetGatewayId"])
    for g in current_net["EgressOnlyInternetGateways"]:
        call("ec2", "delete-egress-only-internet-gateway", "--egress-only-internet-gateway-id", g["EgressOnlyInternetGatewayId"])
    iam_deleted = delete_iam(iam, account)
    retry("VPC deletion", lambda: call("ec2", "delete-vpc", "--vpc-id", vpc_id))
    if iam_deleted:
        state_file.unlink(missing_ok=True)
        print(f"\nDeleted {vpc_name} ({vpc_id}) and the inventoried resources successfully.")
    else:
        save_inventory()
        print(f"\nDeleted {vpc_name} ({vpc_id}) and the inventoried VPC resources successfully.")
        print("Shared IAM role/profile and all policies were retained; resources in other VPCs were not changed.")
        print(f"Retained IAM details: {state_file.resolve()}")
        print(f"To check IAM cleanup later, rerun this script with username: {iam['username']}")


if __name__ == "__main__":
    try:
        account = prepare_aws()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        sys.exit(f"\nPRECHECK FAILED: {error}\nNo cleanup was started by this run.")
    except (EOFError, KeyboardInterrupt):
        sys.exit("Stopped. No cleanup was started by this run.")
    try:
        main(account)
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"\nSTOPPED: {error}\nSome resources may remain. Keep any cleanup inventory JSON and rerun after resolving the error.", file=sys.stderr)
        sys.exit(1)
    except (EOFError, KeyboardInterrupt):
        sys.exit("Stopped. Completed deletions remain in effect; keep the inventory JSON to resume.")
PY
