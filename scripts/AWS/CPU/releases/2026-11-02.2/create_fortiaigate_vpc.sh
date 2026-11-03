cat > create_fortiaigate_vpc.py <<'PY' && python3 -c 'from pathlib import Path; import hashlib, sys; p=Path("create_fortiaigate_vpc.py"); raw=p.read_bytes(); expected="93c31e7ca153ab2914c0a8a703c77d45134229ade5df9a3f72c4e8ba0b871c3c"; hashlib.sha256(raw).hexdigest()==expected or sys.exit("Integrity check failed. Use the complete saved create_fortiaigate_vpc.sh file. No resources were created."); code=compile(raw,str(p),"exec"); sys.argv=[str(p)]; exec(code,{"__name__":"__main__","__file__":str(p)})'
#!/usr/bin/env python3
"""Create the FortiAIGate network and the Ubuntu EC2 lab in us-east-1."""
import base64
import hashlib
import ipaddress
import json
import os
import re
import subprocess
import shutil
import shlex
import urllib.parse
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import unquote

REGION = "us-east-1"
AMI_PARAMETER = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
# Public Canonical publisher ID, retained to verify trusted Ubuntu AMIs.
# This is not a lab user account.
CANONICAL_OWNER = "099720109477"
INSTANCE_TYPE = "t3a.large"
ROOT_VOLUME_GIB = 128
ROLE_SUFFIX = "_FortiAIGate_Docker_SSMRole"
SSM_POLICY = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
# Shared lab release bucket; optional environment overrides need no extra prompts.
S3_BUCKET = os.environ.get("FORTIAIGATE_S3_BUCKET", "").strip() or "wrady-fortiaigate-lab"
S3_PREFIX = "FortiAIGate_8.0.2_CPU/"
os.environ.update(AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off")

# Public preparation script; pin its bytes before running it as root.
PREP_URL = os.environ.get("FORTIAIGATE_PREP_URL", "https://raw.githubusercontent.com/WEEMR/FortiAIGate/cpu-2026-11-02.2/scripts/AWS/CPU/releases/2026-11-02.2/user_data/prepare_fortiaigate_cpu.sh").strip()
PREP_SHA256 = "db1cf5ca6d2a0519a2b633e6c3fd9991325d288bd064367891506d64c843ffb6"
PREP_READY_SENTINEL = "FORTIAIGATE_PREP_READY"



def preparation_preflight():
    """Verify public script availability and integrity before billable changes."""
    parsed = urllib.parse.urlsplit(PREP_URL)
    if (parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password
            or parsed.query or parsed.fragment or not re.fullmatch(r"[0-9a-f]{64}", PREP_SHA256)):
        raise RuntimeError("Preparation needs a public HTTPS URL without credentials/query and a reviewed SHA-256 pin.")
    if not shutil.which("curl"):
        raise RuntimeError("curl is required in CloudShell to verify the preparation script.")
    try:
        result = subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                                 "--proto", "=https", "--tlsv1.2", "--connect-timeout", "15",
                                 "--max-time", "90", "--retry", "2", PREP_URL], capture_output=True,
                                timeout=280)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("Preparation preflight download timed out. No resources were created.") from error
    if result.returncode:
        raise RuntimeError("Preparation download failed before creation. Upload the reviewed prepare_fortiaigate_cpu.sh to user_data/ first. " + result.stderr.decode(errors="replace").strip())
    if len(result.stdout) > 1024 * 1024 or hashlib.sha256(result.stdout).hexdigest() != PREP_SHA256:
        raise RuntimeError("Preparation script checksum differs from this reviewed creator. No resources were created.")
    print("Preparation script: public download and SHA-256 verified.", flush=True)


def preparation_user_data(configuration):
    """A small first-boot loader; configuration contains no cloud credentials."""
    encoded = base64.b64encode(json.dumps(configuration, sort_keys=True).encode()).decode()
    return """#!/bin/bash
set -Eeuo pipefail
umask 027
install -d -m 0755 /var/lib/fortiaigate-prep
exec >> /var/log/fortiaigate-prep.log 2>&1
chmod 0640 /var/log/fortiaigate-prep.log
trap 'forti_rc=$?; printf "First-boot preparation loader failed (exit %s). See /var/log/fortiaigate-prep.log.\\n" "$forti_rc" > /var/lib/fortiaigate-prep/FAILED; chmod 0644 /var/lib/fortiaigate-prep/FAILED; exit "$forti_rc"' ERR
rm -f /var/lib/fortiaigate-prep/FAILED
printf '%s' """ + shlex.quote(encoded) + """ | base64 --decode > /etc/fortiaigate-prep.json
chmod 0644 /etc/fortiaigate-prep.json
if ! command -v curl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  for forti_attempt in 1 2 3; do
    if apt-get -o DPkg::Lock::Timeout=300 update && apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates curl; then break; fi
    test "$forti_attempt" -lt 3 || false
    sleep 10
  done
fi
forti_download=$(mktemp /tmp/fortiaigate-prep.XXXXXXXX.sh)
curl --fail --location --show-error --retry 3 --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \\
  """ + shlex.quote(PREP_URL) + """ --output "$forti_download"
printf '%s  %s\\n' """ + shlex.quote(PREP_SHA256) + """ "$forti_download" | sha256sum --check
bash -n "$forti_download"
install -m 0755 "$forti_download" /usr/local/sbin/prepare_fortiaigate_cpu.sh
rm -f "$forti_download"
/usr/local/sbin/prepare_fortiaigate_cpu.sh
"""


"""Embedded, read-only preparation snapshots and operator progress reporting."""
import datetime as prep_datetime

DEPLOYMENT_STARTED = None
LAST_PREPARATION_STAGE = "waiting for the first VM status snapshot"
CREATOR_PROGRESS_VERSION = "2026-10-31.6"

# The probe finishes immediately. Cloud APIs buffer command output, so a long
# remote polling loop cannot provide changing stages to the CloudShell terminal.
PREP_STATUS_SCRIPT = r'''#!/bin/sh
python3 - <<'FORTI_PREP_STATUS_PY'
import datetime,json,re
from pathlib import Path
state=Path('/var/lib/fortiaigate-prep')
log=Path('/var/log/fortiaigate-prep.log')
started=None
try:
    with log.open('rb') as stream:
        stream.seek(0,2)
        stream.seek(max(0,stream.tell()-262144))
        lines=stream.read().decode('utf-8',errors='replace').splitlines()
    for line in lines:
        match=re.fullmatch(r'\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z)\] validate host and configuration',line)
        if match: started=match.group(1)
except FileNotFoundError:
    pass
def text(name):
    try: return (state/name).read_text()[:240].strip()
    except FileNotFoundError: return ''
if (state/'FAILED').is_file():
    status,stage='failed',text('FAILED') or 'host preparation failed'
elif (state/'READY').is_file():
    status,stage='ready','host tools, release files and installer checks completed'
elif (state/'RUNNING').is_file():
    status,stage='running',text('RUNNING') or 'preparation is changing stages'
else:
    status,stage='pending','waiting for first-boot preparation to start'
completed=None
if status=='ready':
    try:
        completed=datetime.datetime.fromtimestamp((state/'READY').stat().st_mtime,datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')
    except FileNotFoundError:
        status,stage='pending','preparation state changed; checking again'
# Recheck failure after the other files to avoid trusting a stale READY marker.
if (state/'FAILED').is_file():
    status,stage,completed='failed',text('FAILED') or 'host preparation failed',None
print(json.dumps({'status':status,'stage':stage,'started_at':started,'completed_at':completed}))
FORTI_PREP_STATUS_PY
'''
PREP_WAIT_SCRIPT = PREP_STATUS_SCRIPT


def format_elapsed(seconds):
    seconds = max(0, int(seconds))
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return (f"{hours:02d}h " if hours else "") + f"{minutes:02d}m {seconds:02d}s"


def start_deployment_timer():
    global DEPLOYMENT_STARTED
    DEPLOYMENT_STARTED = time.monotonic()


def deployment_elapsed():
    if DEPLOYMENT_STARTED is None:
        return "not started"
    return format_elapsed(time.monotonic() - DEPLOYMENT_STARTED)


def validate_preparation_status(output):
    """Accept exactly one JSON status line, including Azure's stdout wrapper."""
    candidates = [line.strip() for line in output.splitlines() if line.strip().startswith('{')]
    if len(candidates) != 1:
        raise ValueError("Preparation probe did not return exactly one JSON status snapshot.")
    snapshot = json.loads(candidates[0])
    if (not isinstance(snapshot, dict) or snapshot.get('status') not in ('pending','running','ready','failed')
            or not isinstance(snapshot.get('stage'), str) or not snapshot['stage'].strip()
            or len(snapshot['stage']) > 240 or not snapshot['stage'].isprintable()):
        raise ValueError("Preparation probe returned an invalid status or stage.")
    for key in ('started_at', 'completed_at'):
        if snapshot.get(key) is not None:
            if not isinstance(snapshot[key], str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', snapshot[key]):
                raise ValueError("Preparation probe returned an invalid timestamp.")
            prep_datetime.datetime.fromisoformat(snapshot[key].replace('Z','+00:00'))
    return snapshot


def report_preparation_status(snapshot, wait_started):
    global LAST_PREPARATION_STAGE
    LAST_PREPARATION_STAGE = snapshot['stage']
    elapsed = deployment_elapsed() if DEPLOYMENT_STARTED is not None else format_elapsed(time.monotonic()-wait_started)
    label = "Total elapsed" if DEPLOYMENT_STARTED is not None else "Readiness wait elapsed"
    print(f"  Preparation [{snapshot['status'].upper()}]: {snapshot['stage']} | {label}: {elapsed}", flush=True)


def preparation_heartbeat(wait_started, detail="checking VM status"):
    elapsed = deployment_elapsed() if DEPLOYMENT_STARTED is not None else format_elapsed(time.monotonic()-wait_started)
    label = "Total elapsed" if DEPLOYMENT_STARTED is not None else "Readiness wait elapsed"
    print(f"  {detail}; last reported stage: {LAST_PREPARATION_STAGE} | {label}: {elapsed}", flush=True)


def finish_preparation(wait_started, snapshot=None):
    print("\nPASS: host preparation is ready. FortiAIGate has not been deployed.", flush=True)
    if DEPLOYMENT_STARTED is not None:
        print("Total creation duration: " + deployment_elapsed(), flush=True)
    print("Readiness verification duration: " + format_elapsed(time.monotonic()-wait_started), flush=True)
    if snapshot and snapshot.get('started_at') and snapshot.get('completed_at'):
        begin = prep_datetime.datetime.fromisoformat(snapshot['started_at'].replace('Z','+00:00'))
        end = prep_datetime.datetime.fromisoformat(snapshot['completed_at'].replace('Z','+00:00'))
        if end >= begin:
            print("Host preparation duration (VM timestamps): " + format_elapsed((end-begin).total_seconds()), flush=True)
    print(flush=True)



class AwsError(RuntimeError):
    def __init__(self, message):
        super().__init__(message)
        match = re.search(r"\(([^()]+)\) when calling", message)
        self.code = match.group(1) if match else ""


def call(service, operation, *args, region=REGION, missing=(), process_timeout=None, aws_max_attempts=None, **parameters):
    command = ["aws", service, operation, *args]
    if parameters:
        command += ["--cli-input-json", json.dumps(parameters)]
    command += ["--region", region, "--output", "json", "--no-cli-pager"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=process_timeout,
                            env=({**os.environ, "AWS_MAX_ATTEMPTS": str(aws_max_attempts)}
                                 if aws_max_attempts is not None else None))
    if result.returncode:
        error = AwsError(result.stderr.strip() or result.stdout.strip())
        if error.code in missing:
            return {}
        raise error
    return json.loads(result.stdout) if result.stdout.strip() else {}


def iam_retry(action):
    """Retry only IAM propagation errors, with a fixed time limit."""
    for attempt in range(36):
        try:
            return action()
        except AwsError as error:
            transient = error.code in ("NoSuchEntity", "InvalidIamInstanceProfile.NotFound")
            if not transient or attempt == 35:
                raise
            if attempt % 6 == 0:
                print("Waiting for the IAM role/instance profile to propagate...", flush=True)
            time.sleep(5)


"""Confirmed browser access for new CPU labs; embedded by the release builder."""


def ipv4_cidr(value):
    """Accept one public unicast IPv4 address, optionally followed by /32."""
    value = value.strip()
    if not re.fullmatch(r"[0-9.]+(?:/32)?", value):
        raise ValueError("Enter one public IPv4 address, with or without /32.")
    network = ipaddress.ip_network(value if "/" in value else value + "/32", strict=True)
    address = network.network_address
    if (network.version != 4 or network.prefixlen != 32
            or not address.is_global or address.is_multicast):
        raise ValueError("HTTPS access requires one public IPv4 address (/32), not a private address or wider network.")
    return str(network)


def browser_ipv4(caller_arn):
    """Suggest only a unique, recent browser IPv4 belonging to this caller."""
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(minutes=30)
    try:
        data = call("cloudtrail", "lookup-events", "--max-items", "100", process_timeout=25,
                    region=os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or REGION,
                    LookupAttributes=[{"AttributeKey": "EventSource", "AttributeValue": "cloudshell.amazonaws.com"}],
                    StartTime=cutoff.isoformat(), EndTime=now.isoformat())
    except (AwsError, OSError, subprocess.TimeoutExpired, ValueError):
        return None
    if not isinstance(data, dict) or data.get("NextToken") or not isinstance(data.get("Events", []), list):
        return None
    addresses = set()
    for item in data.get("Events", []):
        try:
            event = json.loads(item["CloudTrailEvent"])
            if (not isinstance(event, dict) or event.get("eventSource") != "cloudshell.amazonaws.com"
                    or event.get("userIdentity", {}).get("arn") != caller_arn
                    or not event.get("userAgent", "").startswith("Mozilla/") or event.get("errorCode")):
                continue
            stamp = datetime.fromisoformat(event["eventTime"].replace("Z", "+00:00"))
            if not cutoff <= stamp <= now:
                continue
            address = ipaddress.ip_address(event["sourceIPAddress"])
            addresses.add(ipv4_cidr(str(address)).removesuffix("/32"))
        except (KeyError, ValueError, TypeError, AttributeError):
            continue
    return addresses.pop() if len(addresses) == 1 else None


def request_browser_ipv4(caller_arn):
    print("Looking up your recent browser IPv4 address in CloudTrail...", flush=True)
    detected = browser_ipv4(caller_arn)
    print("Browser public IPv4: open https://checkip.amazonaws.com in YOUR computer's browser if needed.", flush=True)
    prompt = "Your browser public IPv4 for HTTPS (with or without /32)"
    if detected:
        print("Detected from your recent CloudShell browser session: " + detected, flush=True)
        prompt += " [" + detected + "]"
    else:
        print("Automatic detection unavailable: enter your browser's public IPv4 below.", flush=True)
    return ipv4_cidr(input(prompt + ": ").strip() or detected or "")


def verify_cpu_https_access(group_id, vpc_id, source_cidr):
    """Check the complete initial inbound policy before allocating or launching."""
    deadline = time.monotonic() + 30
    for attempt in range(6):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            result = call("ec2", "describe-security-groups", GroupIds=[group_id],
                          missing=("InvalidGroup.NotFound",), process_timeout=min(10, remaining))
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("CPU security-group verification timed out. No instance was launched; inspect the new VPC or use Destroy.") from error
        groups = (result or {}).get("SecurityGroups", [])
        if groups:
            if len(groups) != 1 or groups[0].get("GroupId") != group_id or groups[0].get("VpcId") != vpc_id:
                raise RuntimeError("CPU security-group verification returned a different group or VPC. No instance was launched.")
            permissions = groups[0].get("IpPermissions", [])
            if permissions:
                rule = permissions[0]
                ranges = rule.get("IpRanges", [])
                if (len(permissions) != 1 or rule.get("IpProtocol") not in ("tcp", "6")
                        or rule.get("FromPort") != 443 or rule.get("ToPort") != 443
                        or len(ranges) != 1 or ranges[0].get("CidrIp") != source_cidr
                        or rule.get("Ipv6Ranges") or rule.get("PrefixListIds") or rule.get("UserIdGroupPairs")):
                    raise RuntimeError("CPU security group contains unexpected inbound access; expected only HTTPS 443 from "
                                       + source_cidr + ". No instance was launched; inspect the new VPC or use Destroy.")
                return
        if attempt < 5:
            time.sleep(min(3, max(0, deadline - time.monotonic())))
    raise RuntimeError("CPU HTTPS ingress could not be verified within 30 seconds. No instance was launched; inspect the new VPC or use Destroy.")


def check_role(role):
    policy = role.get("AssumeRolePolicyDocument", {})
    if isinstance(policy, str):
        policy = json.loads(unquote(policy))
    statements = policy.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]

    def values(value):
        return value if isinstance(value, list) else [value]

    allowed = False
    for statement in statements:
        if statement.get("Effect") == "Deny":
            raise RuntimeError("Existing IAM role has a custom Deny trust policy; review it before reuse.")
        principal = statement.get("Principal", {})
        if (statement.get("Effect") == "Allow" and not statement.get("Condition")
                and isinstance(principal, dict)
                and "ec2.amazonaws.com" in values(principal.get("Service"))
                and "sts:AssumeRole" in values(statement.get("Action"))):
            allowed = True
    if not allowed:
        raise RuntimeError("Existing IAM role does not have an unconditional EC2 sts:AssumeRole trust. No trust policy was changed.")


def check_profile(profile, role_name):
    roles = profile.get("Roles", [])
    if roles and (len(roles) != 1 or roles[0]["RoleName"].casefold() != role_name.casefold()):
        raise RuntimeError("Existing instance profile contains a different role. No second role will be added.")


def wait_for_profile(profile_name, role_name):
    for attempt in range(36):
        profile = call("iam", "get-instance-profile", InstanceProfileName=profile_name,
                       missing=("NoSuchEntity",)).get("InstanceProfile", {})
        check_profile(profile, role_name)
        if profile.get("Roles"):
            return profile
        if attempt % 6 == 0:
            print("Waiting for the role to appear in its instance profile...", flush=True)
        time.sleep(5)
    raise RuntimeError("The IAM instance profile did not become ready within 3 minutes.")


def wait_for_ssm(instance_id):
    print("Waiting up to 10 minutes for SSM to report Online...", flush=True)
    for attempt in range(60):
        try:
            information = call("ssm", "describe-instance-information",
                               Filters=[{"Key": "InstanceIds", "Values": [instance_id]}])
        except AwsError as error:
            print(f"Instance created, but SSM readiness could not be checked: {error}", flush=True)
            return False
        if any(i.get("InstanceId") == instance_id and i.get("PingStatus") == "Online"
               for i in information.get("InstanceInformationList", [])):
            print("SSM: Online", flush=True)
            return True
        if attempt % 3 == 0:
            print("  Instance exists; waiting for SSM registration...", flush=True)
        time.sleep(10)
    print("Instance created, but SSM has not reported Online. Check the instance's IAM permissions, agent and outbound connectivity.")
    return False


"""Embedded initial CPU IAM discovery; known-resource checks remain direct reads."""


def cpu_iam_candidate(name, operation, collection, name_key, id_key):
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_+=,.@-]{1,64}", name):
        raise ValueError("Invalid CPU IAM discovery name.")
    request, markers, candidate = {"MaxItems": 1000}, set(), None
    deadline = time.monotonic() + 60
    for _ in range(100):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("IAM discovery exceeded its time limit; no creation was authorized.")
        page = call("iam", operation, "--no-paginate", process_timeout=min(30, remaining), **request)
        if (not isinstance(page, dict) or not isinstance(page.get(collection), list)
                or type(page.get("IsTruncated")) is not bool or "NextToken" in page):
            raise RuntimeError("IAM discovery returned an incomplete or malformed inventory.")
        for row in page[collection]:
            if (not isinstance(row, dict) or not isinstance(row.get(name_key), str)
                    or not row[name_key]):
                raise RuntimeError("IAM discovery returned an invalid identity.")
            if row[name_key].casefold() == name.casefold():
                if candidate is not None or not isinstance(row.get(id_key), str) or not row[id_key]:
                    raise RuntimeError("IAM discovery returned an ambiguous identity.")
                candidate = row
        if not page["IsTruncated"]:
            if "Marker" in page:
                raise RuntimeError("IAM discovery returned an unexpected final-page marker.")
            return candidate
        marker = page.get("Marker")
        if not isinstance(marker, str) or not marker or len(marker) > 1024 or marker in markers:
            raise RuntimeError("IAM discovery pagination did not advance.")
        markers.add(marker)
        request["Marker"] = marker
    raise RuntimeError("IAM discovery exceeded its pagination limit.")


def discover_cpu_iam(name):
    """Skip expected-absent gets only when neither part of a new bundle is seen."""
    specs = (("list-roles", "Roles", "RoleName", "RoleId", "get-role", "Role"),
             ("list-instance-profiles", "InstanceProfiles", "InstanceProfileName",
              "InstanceProfileId", "get-instance-profile", "InstanceProfile"))
    candidates = [cpu_iam_candidate(name, *spec[:4]) for spec in specs]
    if not any(candidates):
        # Create APIs still enforce uniqueness if an eventually consistent list
        # omitted a resource. Never infer deletion of a known resource here.
        return None, None
    resources = []
    for candidate, (_, _, name_key, id_key, operation, key) in zip(candidates, specs):
        try:
            response = call("iam", operation, **{name_key: name})
        except AwsError as error:
            if error.code != "NoSuchEntity":
                raise
            resources.append(None)
            continue
        resource = response.get(key) if isinstance(response, dict) else None
        if (not isinstance(resource, dict) or not isinstance(resource.get(name_key), str)
                or resource[name_key].casefold() != name.casefold()
                or not isinstance(resource.get(id_key), str) or not resource[id_key]
                or (candidate is not None and resource[id_key] != candidate[id_key])):
            raise RuntimeError("IAM identity changed or could not be verified after discovery.")
        resources.append(resource)
    return tuple(resources)

"""Embedded CPU creator helpers; no AWS calls occur when this source is loaded."""


def cpu_address_owned(address, expected_tags):
    actual = {tag.get("Key"): tag.get("Value") for tag in address.get("Tags", [])}
    return (address.get("Domain") == "vpc"
            and all(actual.get(key) == value for key, value in expected_tags.items()))


def read_cpu_address(allocation_id, deadline):
    """Allow EC2's read-after-write delay without retrying allocation/association."""
    for attempt in range(24):
        if time.monotonic() >= deadline:
            break
        addresses = call("ec2", "describe-addresses", AllocationIds=[allocation_id],
                         missing=("InvalidAllocationID.NotFound",),
                         process_timeout=max(1, min(30, deadline-time.monotonic()))).get("Addresses", [])
        if addresses:
            if len(addresses) != 1:
                raise RuntimeError("AWS returned an ambiguous Elastic IP allocation.")
            return addresses[0]
        if attempt < 23:
            time.sleep(min(5, max(0, deadline-time.monotonic())))
    return None


def release_unused_cpu_address(allocation_id, expected_tags):
    """Only release this Create attempt's unassociated address; never detach it."""
    try:
        parameters = ({"AllocationIds": [allocation_id]} if allocation_id else {
            "Filters": [{"Name": "tag:" + key, "Values": [value]}
                        for key, value in expected_tags.items()]})
        deadline = time.monotonic() + 30
        addresses = []
        for attempt in range(6):
            if time.monotonic() >= deadline:
                break
            addresses = call("ec2", "describe-addresses", **parameters,
                             missing=("InvalidAllocationID.NotFound",),
                             process_timeout=max(1, min(10, deadline-time.monotonic()))).get("Addresses", [])
            if addresses:
                break
            if attempt < 5:
                time.sleep(min(5, max(0, deadline-time.monotonic())))
        if not addresses:
            print("Elastic IP cleanup is unconfirmed: no matching allocation could be confirmed. "
                  "Use Destroy for VPC " + expected_tags["VpcId"] + " to check its tagged addresses.", flush=True)
            return
        for address in addresses:
            aid = address.get("AllocationId")
            if not aid or not cpu_address_owned(address, expected_tags):
                print("Elastic IP cleanup refused: allocation ownership could not be verified.", flush=True)
                continue
            if any(address.get(key) for key in ("AssociationId", "InstanceId", "NetworkInterfaceId")):
                print(f"Retained associated Elastic IP {aid}; inspect the existing lab before retrying.", flush=True)
                continue
            call("ec2", "release-address", AllocationId=aid,
                 missing=("InvalidAllocationID.NotFound",), process_timeout=60, aws_max_attempts=1)
            print(f"Released unused Elastic IP: {aid}", flush=True)
    except Exception as error:
        print("Could not release the new unused Elastic IP: " + str(error), flush=True)
        print("Use Destroy for VPC " + expected_tags["VpcId"] + " to review its tagged allocations.", flush=True)


def allocate_cpu_address(resource_tags, create_token):
    """One allocation request, tagged atomically so failed creates remain cleanable."""
    tags = list(resource_tags) + [{"Key": "FortiAIGateCreateToken", "Value": create_token}]
    expected = {tag["Key"]: tag["Value"] for tag in tags
                if tag["Key"] in ("Project", "Owner", "VpcId", "FortiAIGateCreateToken")}
    if set(expected) != {"Project", "Owner", "VpcId", "FortiAIGateCreateToken"} or not all(expected.values()):
        raise RuntimeError("Elastic IP ownership tags are incomplete; no address was allocated.")
    allocation = None
    try:
        # AllocateAddress has no idempotency token. Disable CLI retries rather
        # than risk allocating more than one address after an ambiguous reply.
        allocation = call("ec2", "allocate-address", Domain="vpc",
                          TagSpecifications=[{"ResourceType": "elastic-ip", "Tags": tags}],
                          process_timeout=60, aws_max_attempts=1)
        aid = allocation.get("AllocationId", "")
        if not re.fullmatch(r"eipalloc-(?:[0-9a-f]{8}|[0-9a-f]{17})", aid):
            raise RuntimeError("AWS did not return a valid Elastic IP allocation ID.")
        public_ip = str(ipaddress.IPv4Address(allocation["PublicIp"]))
        if allocation.get("Domain") != "vpc":
            raise RuntimeError("AWS did not return a VPC Elastic IP allocation.")
        print(f"Allocated Elastic IPv4: {public_ip} ({aid})", flush=True)
        return {"AllocationId": aid, "PublicIp": public_ip, "ExpectedTags": expected}
    except Exception as error:
        # Even when the API response is lost, the unique create-token tag plus
        # VpcId identifies a possible allocation without touching other labs.
        aid = allocation.get("AllocationId") if isinstance(allocation, dict) else None
        if aid and not re.fullmatch(r"eipalloc-(?:[0-9a-f]{8}|[0-9a-f]{17})", aid):
            aid = None
        rejected = isinstance(error, AwsError) and error.code in {
            "AddressLimitExceeded", "UnauthorizedOperation", "AuthFailure",
            "InvalidParameterValue", "InvalidParameterCombination", "InvalidTag"}
        if not rejected:
            release_unused_cpu_address(aid, expected)
        raise RuntimeError("Elastic IP allocation failed; no EC2 instance was launched: " + str(error)) from error


def cpu_primary_interface(instance_id, vpc_id, private_ip, process_timeout=60):
    instances = [instance for reservation in call("ec2", "describe-instances",
                 InstanceIds=[instance_id], process_timeout=process_timeout).get("Reservations", [])
                 for instance in reservation.get("Instances", [])]
    if len(instances) != 1 or instances[0].get("InstanceId") != instance_id:
        raise RuntimeError("Could not verify the newly created CPU instance.")
    instance = instances[0]
    interfaces = [interface for interface in instance.get("NetworkInterfaces", [])
                  if interface.get("Attachment", {}).get("DeviceIndex") == 0]
    if (instance.get("VpcId") != vpc_id or len(interfaces) != 1
            or interfaces[0].get("VpcId") != vpc_id
            or interfaces[0].get("PrivateIpAddress") != private_ip
            or not interfaces[0].get("NetworkInterfaceId")):
        raise RuntimeError("CPU primary network interface does not match the new lab; no Elastic IP was moved.")
    return instance, interfaces[0]


def associate_cpu_address(allocation, instance_id, vpc_id, private_ip):
    """Associate once, then verify both sides before reporting a persistent URL."""
    aid, public_ip = allocation["AllocationId"], allocation["PublicIp"]
    deadline = time.monotonic() + 120
    instance, interface = cpu_primary_interface(instance_id, vpc_id, private_ip,
                          process_timeout=max(1, min(30, deadline-time.monotonic())))
    eni_id = interface["NetworkInterfaceId"]
    current = read_cpu_address(aid, deadline)
    if (current is None or current.get("AllocationId") != aid
            or current.get("PublicIp") != public_ip
            or not cpu_address_owned(current, allocation["ExpectedTags"])
            or any(current.get(key) for key in ("AssociationId", "InstanceId", "NetworkInterfaceId"))):
        raise RuntimeError("The new Elastic IP is not an owned, unused allocation; association was refused.")
    if time.monotonic() >= deadline:
        raise RuntimeError("Elastic IP setup timed out before association; no address was moved.")
    occupied = call("ec2", "describe-addresses",
                    Filters=[{"Name": "network-interface-id", "Values": [eni_id]}],
                    process_timeout=max(1, min(30, deadline-time.monotonic()))).get("Addresses", [])
    if occupied:
        raise RuntimeError("The CPU interface already has an Elastic IP; the existing allocation will not be displaced.")
    if time.monotonic() >= deadline:
        raise RuntimeError("Elastic IP setup timed out before association; no address was moved.")
    call("ec2", "associate-address", AllocationId=aid, NetworkInterfaceId=eni_id,
         PrivateIpAddress=private_ip, AllowReassociation=False,
         process_timeout=max(1, min(30, deadline-time.monotonic())), aws_max_attempts=1)
    for attempt in range(24):
        if time.monotonic() >= deadline:
            break
        address = read_cpu_address(aid, deadline)
        if address is None:
            break
        if not cpu_address_owned(address, allocation["ExpectedTags"]):
            raise RuntimeError("Elastic IP ownership changed during verification; inspect the existing lab.")
        if (address.get("AllocationId") != aid or address.get("PublicIp") != public_ip
                or address.get("NetworkInterfaceId") not in (None, eni_id)
                or address.get("InstanceId") not in (None, instance_id)
                or address.get("PrivateIpAddress") not in (None, private_ip)):
            raise RuntimeError("Elastic IP association points outside the new CPU instance; inspect the existing lab.")
        if time.monotonic() >= deadline:
            break
        instance, interface = cpu_primary_interface(instance_id, vpc_id, private_ip,
                              process_timeout=max(1, min(30, deadline-time.monotonic())))
        if (address.get("AssociationId") and address.get("NetworkInterfaceId") == eni_id
                and address.get("PrivateIpAddress") == private_ip
                and instance.get("PublicIpAddress") == public_ip
                and interface.get("Association", {}).get("PublicIp") == public_ip):
            return instance
        if attempt < 23:
            time.sleep(min(5, max(0, deadline-time.monotonic())))
    raise RuntimeError("Elastic IP association did not verify within two minutes. Keep this lab and inspect its address; do not rerun Create.")

"""Embedded CPU RunInstances helper; importing this file performs no cloud calls."""


def cpu_launch_error_kind(error):
    """Classify known CLI errors; unknown/permission/capacity errors fail closed."""
    if isinstance(error, (subprocess.TimeoutExpired, TimeoutError, ConnectionError, ValueError)):
        return "ambiguous"
    if not isinstance(error, AwsError):
        return "terminal"
    if error.code in {"NoSuchEntity", "InvalidIamInstanceProfile.NotFound"}:
        return "propagation"
    if (error.code == "InvalidParameterValue"
            and "invalid iam instance profile arn" in str(error).lower()):
        return "propagation"
    if error.code in {"RequestLimitExceeded", "Throttling", "ThrottlingException",
                      "RequestThrottled", "RequestThrottledException", "EC2ThrottledException",
                      "TooManyRequestsException", "PriorRequestNotComplete"}:
        return "transient"
    if error.code in {"RequestTimeout", "RequestTimeoutException", "InternalError",
                      "InternalFailure", "ServiceUnavailable", "ServiceUnavailableException"}:
        return "ambiguous"
    if not error.code and any(message in str(error).lower() for message in (
            "read timeout on endpoint url", "connect timeout on endpoint url",
            "could not connect to the endpoint url",
            "connection was closed before we received a valid response",
            "connection reset by peer")):
        return "ambiguous"
    return "terminal"


def validate_cpu_launch_instance(instance, launch):
    """Accept only the one intended instance, including after an uncertain reply."""
    if not isinstance(instance, dict) or not isinstance(instance.get("InstanceId"), str):
        raise RuntimeError("CPU launch reconciliation returned an invalid instance identity.")
    interface = launch["NetworkInterfaces"][0]
    expected_tags = {tag["Key"]: tag["Value"] for spec in launch["TagSpecifications"]
                     if spec["ResourceType"] == "instance" for tag in spec["Tags"]}
    actual_tags = {tag.get("Key"): tag.get("Value") for tag in instance.get("Tags", [])}
    groups = instance.get("SecurityGroups", [])
    matches = (
        re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", instance.get("InstanceId", ""))
        and instance.get("ClientToken") == launch["ClientToken"]
        and instance.get("ImageId") == launch["ImageId"]
        and instance.get("InstanceType") == launch["InstanceType"]
        and instance.get("Placement", {}).get("AvailabilityZone") == launch["Placement"]["AvailabilityZone"]
        and instance.get("VpcId") == expected_tags["VpcId"]
        and instance.get("SubnetId") == interface["SubnetId"]
        and instance.get("PrivateIpAddress") == interface["PrivateIpAddress"]
        and {group.get("GroupId") for group in groups} == set(interface["Groups"])
        and instance.get("IamInstanceProfile", {}).get("Arn") == launch["IamInstanceProfile"]["Arn"]
        and all(actual_tags.get(key) == value for key, value in expected_tags.items())
        and instance.get("State", {}).get("Name") in {"pending", "running"})
    if not matches:
        raise RuntimeError("CPU launch response does not match the intended instance, token, ownership, "
                           "network, or IAM profile. Inspect the existing lab; do not rerun Create.")
    return instance


def run_cpu_instance(launch):
    """Use one SDK attempt per request; retry only bounded, recognized transients."""
    # Freeze all parameters, including the already-issued idempotency token.
    request = json.loads(json.dumps(launch))
    token = request.get("ClientToken")
    if (not isinstance(token, str) or not token or len(token) > 64
            or request.get("MinCount") != 1 or request.get("MaxCount") != 1
            or len(request.get("NetworkInterfaces", [])) != 1):
        raise RuntimeError("CPU launch requires one instance and a stable client token.")
    profile_arn = request.get("IamInstanceProfile", {}).get("Arn", "")
    if not re.fullmatch(r"arn:aws:iam::[0-9]{12}:instance-profile/[A-Za-z0-9_+=,.@/-]+", profile_arn):
        raise RuntimeError("CPU launch requires the verified IAM instance profile ARN.")
    deadline = time.monotonic() + 180
    uncertain = False
    transient_failures = 0
    last_error = None

    def bounded_call(operation, *args, **parameters):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("CPU launch reconciliation exceeded its three-minute limit.")
        return call("ec2", operation, *args, **parameters, aws_max_attempts=1,
                    process_timeout=min(30, remaining))

    def reconcile():
        """Complete bounded pagination; omission alone never permits a new token."""
        instances, seen_tokens = [], set()
        next_token = None
        for _ in range(10):
            parameters = {"Filters": [{"Name": "client-token", "Values": [token]}], "MaxResults": 1000}
            if next_token:
                parameters["NextToken"] = next_token
            page = bounded_call("describe-instances", "--no-paginate", **parameters)
            if not isinstance(page, dict) or not isinstance(page.get("Reservations"), list):
                raise RuntimeError("CPU launch reconciliation returned an incomplete instance inventory.")
            for reservation in page["Reservations"]:
                if not isinstance(reservation, dict) or not isinstance(reservation.get("Instances"), list):
                    raise RuntimeError("CPU launch reconciliation returned a malformed reservation.")
                instances.extend(reservation["Instances"])
            if len(instances) > 1:
                raise RuntimeError("More than one instance matched the CPU launch token; inspect the lab.")
            if "NextToken" not in page:
                if instances:
                    return {"Instances": [validate_cpu_launch_instance(instances[0], request)]}
                return None
            next_token = page["NextToken"]
            if not isinstance(next_token, str) or not next_token or next_token in seen_tokens:
                raise RuntimeError("CPU launch reconciliation returned an invalid pagination token.")
            seen_tokens.add(next_token)
        raise RuntimeError("CPU launch reconciliation exceeded its inventory page limit.")

    def unresolved(error):
        return RuntimeError("CPU launch outcome is unconfirmed for client token " + token
                            + ". Inspect the existing lab before any new Create; do not change the token. "
                            + str(error))

    for attempt in range(36):
        if time.monotonic() >= deadline:
            break
        if uncertain:
            try:
                found = reconcile()
                if found:
                    return found
            except (AwsError, subprocess.TimeoutExpired, TimeoutError, ConnectionError, ValueError) as error:
                if cpu_launch_error_kind(error) == "terminal":
                    raise unresolved(error) from error
                last_error = error
                # A failed read cannot authorize a write retry.
                if attempt < 35:
                    time.sleep(min(5, max(0, deadline - time.monotonic())))
                continue
            except RuntimeError as error:
                raise unresolved(error) from error
        try:
            result = bounded_call("run-instances", **request)
        except (AwsError, subprocess.TimeoutExpired, TimeoutError, ConnectionError, ValueError) as error:
            last_error = error
            kind = cpu_launch_error_kind(error)
            if kind == "terminal":
                if uncertain:
                    try:
                        found = reconcile()
                        if found:
                            return found
                    except Exception as read_error:
                        raise unresolved(read_error) from error
                    raise unresolved(error) from error
                raise
            uncertain |= kind == "ambiguous"
            if kind in {"transient", "ambiguous"}:
                transient_failures += 1
            # The former SDK budget was three requests in standard mode.
            # Only genuine IAM propagation retains the longer 36-attempt wait.
            if transient_failures >= 3:
                exhausted = RuntimeError("CPU launch stopped after 3 transient AWS request failures. "
                                         "Inspect the existing lab before retrying Create.")
                if uncertain:
                    try:
                        found = reconcile()
                        if found:
                            return found
                    except Exception as read_error:
                        raise unresolved(read_error) from error
                    raise unresolved(exhausted) from error
                raise exhausted from error
            if attempt % 6 == 0:
                print("Waiting for CPU launch after a transient AWS or IAM propagation error...", flush=True)
        else:
            if (not isinstance(result, dict) or not isinstance(result.get("Instances"), list)
                    or len(result["Instances"]) != 1):
                raise RuntimeError("AWS did not return exactly one CPU instance. Inspect the lab; do not rerun Create.")
            # A successful RunInstances reply is authoritative for this exact
            # request. Other metadata may be omitted while the instance starts;
            # cpu_primary_interface verifies its network before EIP association.
            instance = result["Instances"][0]
            if (not isinstance(instance, dict)
                    or not isinstance(instance.get("InstanceId"), str)
                    or not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", instance.get("InstanceId", ""))
                    or ("ClientToken" in instance and instance["ClientToken"] != token)):
                raise RuntimeError("AWS returned an invalid CPU instance ID or conflicting client token. "
                                   "Inspect the existing lab; do not rerun Create.")
            return result
        if attempt < 35:
            time.sleep(min(5, max(0, deadline - time.monotonic())))
    if uncertain:
        if time.monotonic() < deadline:
            try:
                found = reconcile()
                if found:
                    return found
            except Exception as error:
                raise unresolved(error) from error
        raise unresolved(last_error) from last_error
    if last_error is not None:
        raise last_error
    raise RuntimeError("CPU launch exceeded its three-minute limit; inspect the existing lab before retrying.")


def wait_for_preparation(instance_id):
    wait_started = time.monotonic()
    deadline = wait_started + 1800
    print("Waiting up to 30 minutes for automatic host preparation; sampling the current VM stage...", flush=True)
    while time.monotonic() < deadline:
        try:
            command_id = call("ssm", "send-command", DocumentName="AWS-RunShellScript",
                              InstanceIds=[instance_id], TimeoutSeconds=60,
                              Parameters={"commands": [PREP_STATUS_SCRIPT], "executionTimeout": ["30"]},
                              process_timeout=min(60,max(1,deadline-time.monotonic())),
                              Comment="Read FortiAIGate CPU preparation stage")['Command']['CommandId']
            command_deadline = min(deadline, time.monotonic()+120)
            while time.monotonic() < command_deadline:
                try:
                    result = call("ssm", "get-command-invocation", CommandId=command_id, InstanceId=instance_id,
                                  process_timeout=min(60,max(1,command_deadline-time.monotonic())))
                except AwsError as error:
                    if error.code != "InvocationDoesNotExist":
                        raise
                    preparation_heartbeat(wait_started, "Waiting for SSM to publish the status snapshot")
                    time.sleep(min(5, max(0, command_deadline-time.monotonic())))
                    continue
                status = result.get("Status", "Unknown")
                if status not in ("Pending", "InProgress", "Delayed"):
                    break
                preparation_heartbeat(wait_started, "SSM status snapshot " + status)
                time.sleep(min(5, max(0, command_deadline-time.monotonic())))
            else:
                print("The status probe did not finish within its limit. No overlapping probe was started; inspect the existing instance.", flush=True)
                return False
        except AwsError as error:
            print("Preparation status could not be read: " + str(error), flush=True)
            return False
        except subprocess.TimeoutExpired:
            print("Preparation status API timed out. No overlapping probe was started; inspect the existing instance.", flush=True)
            return False
        if status != "Success" or result.get("ResponseCode") != 0:
            print("Preparation status probe did not pass (" + status + "). Connect and inspect /var/log/fortiaigate-prep.log.", flush=True)
            return False
        try:
            snapshot = validate_preparation_status(result.get("StandardOutputContent", ""))
        except (ValueError, TypeError) as error:
            print("Could not verify the preparation snapshot: " + str(error), flush=True)
            return False
        report_preparation_status(snapshot, wait_started)
        if snapshot['status'] == 'ready':
            finish_preparation(wait_started, snapshot)
            return True
        if snapshot['status'] == 'failed':
            print("Preparation failed. Inspect /var/log/fortiaigate-prep.log on the existing instance.", flush=True)
            return False
        time.sleep(min(15, max(0, deadline-time.monotonic())))
    print("Preparation status wait timed out after " + format_elapsed(time.monotonic()-wait_started) + "; the existing instance may still be preparing.", flush=True)
    return False


def main():
    username = input("Enter your name prefix (1-37 characters): ").strip()
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,36}", username)
            or username.lower().startswith("sg-")):
        raise RuntimeError("Use 1-37 letters, digits, underscores or hyphens; start with a letter or digit and avoid sg-. The IAM role name must fit AWS's 64-character limit.")
    if (not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", S3_BUCKET)
            or ".." in S3_BUCKET or re.fullmatch(r"\d+\.\d+\.\d+\.\d+", S3_BUCKET)):
        raise RuntimeError("FORTIAIGATE_S3_BUCKET must be an existing S3 bucket name: 3-63 lowercase letters, digits, dots or hyphens, without wildcards, a path or an s3:// prefix.")
    preparation_preflight()
    identity = call("sts", "get-caller-identity")
    print(f"Account: {identity['Account']}   Region: {REGION}", flush=True)
    source_cidr = request_browser_ipv4(identity["Arn"])

    vpc_name = f"{username}_FortiAIGate_VPC"
    sg_name = f"{username}_FortiAIGate_NSG"
    instance_name = f"{username}_FortiAIGate_Docker"
    role_name = username + ROLE_SUFFIX
    profile_name = role_name
    s3_policy_name = f"{username}-FortiAIGate-S3Read"

    def resource_tags(name, vpc_id=None):
        tags = [{"Key": "Name", "Value": name}, {"Key": "Owner", "Value": username},
                {"Key": "Project", "Value": "FortiAIGate"}]
        if vpc_id:
            tags.append({"Key": "VpcId", "Value": vpc_id})
        return tags

    def tag_spec(resource_type, name, vpc_id=None):
        return [{"ResourceType": resource_type, "Tags": resource_tags(name, vpc_id)}]

    # All preflight checks below are read-only. Do not guess AMIs or replace a role.
    zones = call("ec2", "describe-availability-zones", ZoneNames=["us-east-1a", "us-east-1f"],
                 Filters=[{"Name": "state", "Values": ["available"]}])["AvailabilityZones"]
    if {z["ZoneName"] for z in zones if z["State"] == "available"} != {"us-east-1a", "us-east-1f"}:
        raise RuntimeError("Both us-east-1a and us-east-1f must be available to your account.")
    offerings = call("ec2", "describe-instance-type-offerings", LocationType="availability-zone",
                     Filters=[{"Name": "instance-type", "Values": [INSTANCE_TYPE]},
                              {"Name": "location", "Values": ["us-east-1a"]}])["InstanceTypeOfferings"]
    if not any(o["InstanceType"] == INSTANCE_TYPE and o["Location"] == "us-east-1a" for o in offerings):
        raise RuntimeError(f"{INSTANCE_TYPE} is not offered in your account's us-east-1a.")
    # Canonical publishes 22.04 as ebs-gp2; RunInstances overrides its root to gp3.
    # https://ubuntu.com/aws/docs/aws-how-to/instances/find-ubuntu-images/
    ami_id = call("ssm", "get-parameter", Name=AMI_PARAMETER)["Parameter"]["Value"]
    images = call("ec2", "describe-images", ImageIds=[ami_id], Owners=[CANONICAL_OWNER])["Images"]
    if len(images) != 1:
        raise RuntimeError("The Ubuntu AMI could not be verified against Canonical's owner account.")
    image = images[0]
    if (image.get("OwnerId") != CANONICAL_OWNER or image.get("Architecture") != "x86_64"
            or image.get("State") != "available" or image.get("RootDeviceType") != "ebs"
            or image.get("VirtualizationType") != "hvm"
            or not image.get("Name", "").startswith("ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-")):
        raise RuntimeError("The AMI does not match Canonical Ubuntu Server 22.04 x86_64 HVM/EBS.")
    root_device = image["RootDeviceName"]
    print(f"Ubuntu AMI: {ami_id} ({image['Name']})", flush=True)
    role, profile = discover_cpu_iam(role_name)
    if role:
        check_role(role)
        role_name = role["RoleName"]
    if profile:
        check_profile(profile, role_name)
        profile_name = profile["InstanceProfileName"]

    print(f"Network access: inbound HTTPS 443 only from {source_cidr}. Administration uses Session Manager (SSM); no SSH ingress is opened.", flush=True)
    print("Optional Ollama access is configured by its launcher only when deployed.", flush=True)
    print("This lab reserves one Elastic IPv4 address. It remains allocated and billed while stopped; Destroy releases it.", flush=True)
    start_deployment_timer()
    print(f"\nCreating {vpc_name} and {instance_name}: {INSTANCE_TYPE}, us-east-1a, encrypted {ROOT_VOLUME_GIB} GiB gp3 root.", flush=True)
    if not role:
        trust = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
                 "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]}
        role = call("iam", "create-role", RoleName=role_name, AssumeRolePolicyDocument=json.dumps(trust),
                    Description=f"SSM access for {instance_name}", Tags=resource_tags(role_name))["Role"]
        print(f"Created IAM role: {role['Arn']}", flush=True)
    else:
        print(f"Reusing IAM role: {role['Arn']}", flush=True)
    iam_retry(lambda: call("iam", "attach-role-policy", RoleName=role_name, PolicyArn=SSM_POLICY))
    s3_read_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow", "Action": "s3:ListBucket",
                "Resource": f"arn:aws:s3:::{S3_BUCKET}",
                "Condition": {"StringLike": {"s3:prefix": [S3_PREFIX, S3_PREFIX + "*"]}},
            },
            {
                "Effect": "Allow", "Action": "s3:GetObject",
                "Resource": f"arn:aws:s3:::{S3_BUCKET}/{S3_PREFIX}*",
            },
        ],
    }
    iam_retry(lambda: call("iam", "put-role-policy", RoleName=role_name,
                           PolicyName=s3_policy_name, PolicyDocument=json.dumps(s3_read_policy)))
    print(f"S3 inline policy: {s3_policy_name} (list/read s3://{S3_BUCKET}/{S3_PREFIX})", flush=True)
    if not profile:
        profile = call("iam", "create-instance-profile", InstanceProfileName=profile_name,
                       Tags=resource_tags(profile_name))["InstanceProfile"]
        print(f"Created IAM instance profile: {profile['Arn']}", flush=True)
    if not profile.get("Roles"):
        iam_retry(lambda: call("iam", "add-role-to-instance-profile",
                               InstanceProfileName=profile_name, RoleName=role_name))
    profile = wait_for_profile(profile_name, role_name)
    print(f"Instance profile: {profile['Arn']}", flush=True)

    vpc_id = call("ec2", "create-vpc", CidrBlock="10.250.0.0/16",
                  TagSpecifications=tag_spec("vpc", vpc_name))["Vpc"]["VpcId"]
    print(f"VPC: {vpc_id} ({vpc_name})", flush=True)
    call("ec2", "wait", "vpc-available", VpcIds=[vpc_id])
    call("ec2", "modify-vpc-attribute", VpcId=vpc_id, EnableDnsSupport={"Value": True})
    call("ec2", "modify-vpc-attribute", VpcId=vpc_id, EnableDnsHostnames={"Value": True})
    igw_id = call("ec2", "create-internet-gateway",
                  TagSpecifications=tag_spec("internet-gateway", f"{username}_FortiAIGate_IGW", vpc_id))["InternetGateway"]["InternetGatewayId"]
    print(f"Internet gateway: {igw_id}", flush=True)
    call("ec2", "attach-internet-gateway", InternetGatewayId=igw_id, VpcId=vpc_id)
    subnets = []
    for zone, cidr, label in (("us-east-1a", "10.250.20.0/24", "1A"), ("us-east-1f", "10.250.21.0/24", "1F")):
        subnet_id = call("ec2", "create-subnet", VpcId=vpc_id, AvailabilityZone=zone, CidrBlock=cidr,
                         TagSpecifications=tag_spec("subnet", f"{username}_FortiAIGate_Public_{label}", vpc_id))["Subnet"]["SubnetId"]
        subnets.append(subnet_id)
        print(f"Public subnet {label}: {subnet_id} ({cidr})", flush=True)
    call("ec2", "wait", "subnet-available", SubnetIds=subnets)
    route_table_id = call("ec2", "create-route-table", VpcId=vpc_id,
                          TagSpecifications=tag_spec("route-table", f"{username}_FortiAIGate_Public_RT", vpc_id))["RouteTable"]["RouteTableId"]
    print(f"Public route table: {route_table_id}", flush=True)
    call("ec2", "create-route", RouteTableId=route_table_id, DestinationCidrBlock="0.0.0.0/0", GatewayId=igw_id)
    for subnet_id in subnets:
        call("ec2", "modify-subnet-attribute", SubnetId=subnet_id, MapPublicIpOnLaunch={"Value": True})
        call("ec2", "associate-route-table", SubnetId=subnet_id, RouteTableId=route_table_id)

    sg_id = call("ec2", "create-security-group", VpcId=vpc_id, GroupName=sg_name,
                 Description=f"FortiAIGate access for {username}",
                 TagSpecifications=tag_spec("security-group", sg_name, vpc_id))["GroupId"]
    print(f"Instance security group: {sg_id} ({sg_name})", flush=True)
    call("ec2", "authorize-security-group-ingress", GroupId=sg_id, IpPermissions=[
        {"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
         "IpRanges": [{"CidrIp": source_cidr, "Description": "HTTPS from user"}]},
    ])
    verify_cpu_https_access(sg_id, vpc_id, source_cidr)
    launch = {
        "ImageId": ami_id, "InstanceType": INSTANCE_TYPE, "MinCount": 1, "MaxCount": 1,
        "ClientToken": str(uuid.uuid4()),
        # AWS CLI/Botocore encodes RunInstances UserData; keep this as raw text.
        "UserData": preparation_user_data({"cloud": "aws", "region": REGION,
                                           "release_s3_uri": f"s3://{S3_BUCKET}/{S3_PREFIX}"}),
        "Placement": {"AvailabilityZone": "us-east-1a", "Tenancy": "default"},
        "IamInstanceProfile": {"Arn": profile["Arn"]},
        "NetworkInterfaces": [{"DeviceIndex": 0, "SubnetId": subnets[0], "Groups": [sg_id],
                               "PrivateIpAddress": "10.250.20.10", "AssociatePublicIpAddress": True, "DeleteOnTermination": True}],
        "BlockDeviceMappings": [{"DeviceName": root_device, "Ebs": {
            "VolumeSize": ROOT_VOLUME_GIB, "VolumeType": "gp3", "Iops": 3000, "Throughput": 125,
            "Encrypted": True, "DeleteOnTermination": True}}],
        "CreditSpecification": {"CpuCredits": "standard"}, "Monitoring": {"Enabled": False},
        "TagSpecifications": (tag_spec("instance", instance_name, vpc_id)
                              + tag_spec("volume", instance_name + "_Root", vpc_id)
                              + tag_spec("network-interface", instance_name + "_ENI", vpc_id)),
    }
    # No KeyName: administration uses Session Manager. UserData prepares the host only.
    # Reuse this token for every propagation retry to avoid duplicate launches.
    # The automatic public address supports first-boot downloads until the
    # persistent address is associated. AWS releases that automatic address.
    allocation = allocate_cpu_address(resource_tags(instance_name + "_EIP", vpc_id), launch["ClientToken"])
    try:
        print(f"Launching {instance_name}...", flush=True)
        instance_id = run_cpu_instance(launch)["Instances"][0]["InstanceId"]
        print(f"EC2 instance: {instance_id} ({instance_name})", flush=True)
        print("Waiting for the instance to run before associating its Elastic IP...", flush=True)
        call("ec2", "wait", "instance-running", InstanceIds=[instance_id])
        instance = associate_cpu_address(allocation, instance_id, vpc_id, "10.250.20.10")
        print("Waiting for EC2 status checks...", flush=True)
        call("ec2", "wait", "instance-status-ok", InstanceIds=[instance_id])
    except Exception as error:
        release_unused_cpu_address(allocation["AllocationId"], allocation["ExpectedTags"])
        raise RuntimeError(f"CPU creation or Elastic IP setup failed in {vpc_id}: {error}. "
                           "Inspect the existing lab or use Destroy; do not rerun Create.") from error
    print("Private IPv4: 10.250.20.10 (fixed; optional Ollama uses 10.250.20.20)", flush=True)
    print(f"Elastic IPv4: {allocation['PublicIp']} ({allocation['AllocationId']})", flush=True)
    print(f"Browser URL after installation: https://{allocation['PublicIp']}/ui", flush=True)
    print("This address stays with the instance across stop/start. Destroy releases it; IPv4 charges continue while stopped.", flush=True)
    print(f"\nCreated {vpc_name} and {instance_name} in {REGION}.", flush=True)
    print(f"Instance security group: {sg_name} ({sg_id}). Inbound HTTPS 443 only from {source_cidr}; administration uses Session Manager (SSM).", flush=True)
    ready = wait_for_ssm(instance_id)
    print(f"\nConnect with Session Manager: aws ssm start-session --target {instance_id} --region {REGION}")
    if not ready:
        print("Use the existing instance ID to troubleshoot SSM; rerunning creation would create another VPC and instance.")
        return 2
    prepared = wait_for_preparation(instance_id)
    if not prepared:
        print("\nPreparation troubleshooting inside Ubuntu:")
        print("  Status: sudo fortiaigate-prep-status")
        print("  Log: sudo tail -n 100 /var/log/fortiaigate-prep.log\n")
        print("Keep this instance. Resolve preparation failures there; do not rerun Create.")
        return 2
    print("Next: connect to the Ubuntu EC2 instance:")
    print(f"  aws ssm start-session --target {instance_id} --region {REGION}\n")
    print("After the session opens, continue with step 2 in the guide.")
    print("Run its installation command inside Ubuntu as your normal non-root session user, without sudo.")
    print("A separate preparation status check is not required.\n")
    print("Optional troubleshooting inside Ubuntu:")
    print("  Status: sudo fortiaigate-prep-status")
    print("  Log: sudo tail -n 100 /var/log/fortiaigate-prep.log\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"\nSTOPPED: {error}\nAny resources already created remain; use the IDs printed above to inspect or clean them up.", file=sys.stderr)
        sys.exit(1)
    except (EOFError, KeyboardInterrupt):
        sys.exit("Stopped. Any resources already created remain; keep their IDs from the output above.")
PY
