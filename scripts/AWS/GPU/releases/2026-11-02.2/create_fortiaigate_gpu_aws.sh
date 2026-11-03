#!/usr/bin/env bash
# FortiAIGate GPU lab; run with Bash in AWS CloudShell. Version 2026-11-02.2.
set -euo pipefail
command -v python3 >/dev/null || { printf 'Python 3 is required. Run in AWS CloudShell.\n' >&2; exit 1; }
forti_gpu_script=$(mktemp "${TMPDIR:-/tmp}/fortiaigate_gpu.XXXXXXXX.py")
trap 'rm -f "$forti_gpu_script"' EXIT
cat > "$forti_gpu_script" <<'FORTIAIGATE_GPU_PY'
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import shlex
import urllib.parse
import urllib.request
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


def aws(service, operation, *arguments, process_timeout=None, **payload):
    cmd = ["aws", service, operation, *arguments, "--region", REGION,
           "--output", "json", "--no-cli-pager", "--cli-connect-timeout", "15",
           "--cli-read-timeout", "60"]
    if payload:
        cmd += ["--cli-input-json", json.dumps(payload)]
    result = subprocess.run(cmd, text=True, capture_output=True, timeout=process_timeout)
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
    print("Inside Ubuntu: fortiaigate-prep-status; when READY, run fortiaigate-install as your normal non-root user.")
    print("GPU log: sudo tail -n 100 /var/log/fortiaigate-gpu-prep.log")
    print("Core tools log: sudo tail -n 100 /var/log/fortiaigate-prep.log")


def missing_release_files(objects, release_prefix):
    keys = {row["Key"] for row in objects if row.get("Size", 0) > 0}
    missing = []
    for component in ("api", "webui", "llm-gateway", "logd", "license_manager", "guardrail", "guardrail-scanner", "custom-triton", "faig-models", "vllm-server"):
        base = release_prefix + "/Images/FAIG_" + component + "-V8.0.2-build0055-FORTINET.tar"
        if base in keys and base + ".gz" in keys:
            missing.append(base + " (keep only one of .tar or .tar.gz)")
        elif base not in keys and base + ".gz" not in keys:
            missing.append(base + "[.gz]")
    installer = release_prefix + "/Installer/FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz"
    if installer not in keys:
        missing.append(installer)
    return missing

PREP_URL = os.environ.get("FORTIAIGATE_GPU_PREP_URL", 'https://raw.githubusercontent.com/WEEMR/FortiAIGate/gpu-2026-11-02.2/scripts/AWS/GPU/releases/2026-11-02.2/user_data/prepare_fortiaigate_gpu.sh').strip()
PREP_SHA256 = '4693ad458f687889ff074c1436f7e121ddc53d03ec0a695d672d0046325eb320'


def preparation_preflight():
    parsed = urllib.parse.urlsplit(PREP_URL)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise RuntimeError("GPU preparation needs a public HTTPS script URL without credentials, query or fragment.")
    request = urllib.request.Request(PREP_URL, headers={"User-Agent": "FortiAIGate-Lab-Preparation/2026-10-31"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content = response.read(1024 * 1024 + 1)
    except OSError as error:
        raise RuntimeError("GPU preparation script is not accessible. Upload the reviewed user_data scripts before Create. No GPU resources were created.") from error
    if len(content) > 1024 * 1024 or hashlib.sha256(content).hexdigest() != PREP_SHA256:
        raise RuntimeError("GPU preparation checksum differs from this reviewed creator. No GPU resources were created.")
    # The GPU wrapper fetches this second independently pinned script at boot.
    cpu_url = 'https://raw.githubusercontent.com/WEEMR/FortiAIGate/gpu-2026-11-02.2/scripts/AWS/GPU/releases/2026-11-02.2/user_data/prepare_fortiaigate_cpu.sh'
    request = urllib.request.Request(cpu_url, headers={"User-Agent": "FortiAIGate-Lab-Preparation/2026-10-31"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            common = response.read(1024 * 1024 + 1)
    except OSError as error:
        raise RuntimeError("The shared CPU preparation script must also be public under user_data/. No GPU resources were created.") from error
    if len(common) > 1024 * 1024 or hashlib.sha256(common).hexdigest() != 'db1cf5ca6d2a0519a2b633e6c3fd9991325d288bd064367891506d64c843ffb6':
        raise RuntimeError("The shared preparation checksum differs. No GPU resources were created.")
    print("Both GPU preparation scripts: public download and SHA-256 verified.", flush=True)


def preparation_user_data(bucket, release_prefix):
    config = {"cloud": "aws", "edition": "gpu", "region": REGION,
              "release_s3_uri": "s3://" + bucket + "/" + release_prefix + "/"}
    encoded = base64.b64encode(json.dumps(config, sort_keys=True).encode()).decode()
    return """#!/bin/bash
set -Eeuo pipefail
umask 027
install -d -m 0755 /var/lib/fortiaigate-prep
exec >> /var/log/fortiaigate-gpu-prep.log 2>&1
chmod 0640 /var/log/fortiaigate-gpu-prep.log
trap 'forti_rc=$?; printf "GPU loader failed (exit %s). Read /var/log/fortiaigate-gpu-prep.log.\\n" "$forti_rc" > /var/lib/fortiaigate-prep/GPU_FAILED; chmod 0644 /var/lib/fortiaigate-prep/GPU_FAILED; exit "$forti_rc"' ERR
printf 'gpu\\n' > /var/lib/fortiaigate-prep/edition
printf 'gpu\\n' > /var/lib/fortiaigate-prep/GPU_MODE
printf 'downloading the reviewed GPU preparation script\\n' > /var/lib/fortiaigate-prep/GPU_RUNNING
chmod 0644 /var/lib/fortiaigate-prep/edition /var/lib/fortiaigate-prep/GPU_MODE /var/lib/fortiaigate-prep/GPU_RUNNING
printf '%s' """ + shlex.quote(encoded) + """ | base64 --decode > /etc/fortiaigate-prep.json
chmod 0600 /etc/fortiaigate-prep.json
if ! command -v curl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
  apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y ca-certificates curl
fi
forti_download=$(mktemp /tmp/fortiaigate-gpu-prep.XXXXXXXX.sh)
curl --fail --location --show-error --retry 3 --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \\
  """ + shlex.quote(PREP_URL) + """ --output "$forti_download"
printf '%s  %s\\n' """ + shlex.quote(PREP_SHA256) + """ "$forti_download" | sha256sum --check
bash -n "$forti_download"
install -m 0700 "$forti_download" /usr/local/sbin/prepare_fortiaigate_gpu.sh
rm -f "$forti_download"
/usr/local/sbin/prepare_fortiaigate_gpu.sh
"""


def wait_for_gpu_preparation(instance_id):
    print("Waiting up to 45 minutes for GPU host preparation, including one automatic driver reboot...", flush=True)
    deadline = time.monotonic() + 2700
    check = """#!/bin/sh
if test -f /var/lib/fortiaigate-prep/GPU_FAILED; then
  printf 'FORTIAIGATE_GPU_PREP_FAILED\\n'
  cat /var/lib/fortiaigate-prep/GPU_FAILED
  exit 1
fi
if test -f /var/lib/fortiaigate-prep/FAILED; then
  printf 'FORTIAIGATE_GPU_PREP_FAILED\\n'
  cat /var/lib/fortiaigate-prep/FAILED
  exit 1
fi
if test -f /var/lib/fortiaigate-prep/GPU_READY; then
  printf 'FORTIAIGATE_GPU_PREP_READY\\n'
  exit 0
fi
printf 'FORTIAIGATE_GPU_PREP_RUNNING\\n'
test ! -f /var/lib/fortiaigate-prep/GPU_RUNNING || cat /var/lib/fortiaigate-prep/GPU_RUNNING
exit 2
"""
    previous = None
    while time.monotonic() < deadline:
        try:
            information = aws("ssm", "describe-instance-information", Filters=[{"Key": "InstanceIds", "Values": [instance_id]}])
            if not any(x.get("InstanceId") == instance_id and x.get("PingStatus") == "Online" for x in information.get("InstanceInformationList", [])):
                print("  Waiting for SSM registration or the driver reboot to finish...", flush=True)
                time.sleep(15)
                continue
            command = aws("ssm", "send-command", DocumentName="AWS-RunShellScript", InstanceIds=[instance_id],
                          Parameters={"commands": [check], "executionTimeout": ["30"]}, TimeoutSeconds=60,
                          Comment="Check FortiAIGate GPU host preparation")
            command_id = command["Command"]["CommandId"]
        except AwsError as error:
            if any(code in str(error) for code in ("InvalidInstanceId", "TargetNotConnected", "Throttling")):
                time.sleep(15)
                continue
            raise RuntimeError("GPU resources exist, but preparation status could not be checked: " + str(error)) from error
        result = None
        for _ in range(20):
            try:
                result = aws("ssm", "get-command-invocation", CommandId=command_id, InstanceId=instance_id)
            except AwsError as error:
                if "InvocationDoesNotExist" in str(error):
                    time.sleep(2)
                    continue
                raise
            if result.get("Status") in ("Pending", "InProgress", "Delayed"):
                time.sleep(2)
                continue
            break
        output = (result or {}).get("StandardOutputContent", "")
        lines = output.splitlines()
        if "FORTIAIGATE_GPU_PREP_FAILED" in lines:
            print(output.strip(), flush=True)
            raise RuntimeError("GPU host preparation failed. Keep this instance, inspect /var/log/fortiaigate-gpu-prep.log and retry preparation there. Do not run Create again.")
        if (result or {}).get("Status") == "Success" and (result or {}).get("ResponseCode") == 0 and "FORTIAIGATE_GPU_PREP_READY" in lines:
            print("PASS: GPU host preparation is ready; FortiAIGate has not been imported or deployed.", flush=True)
            return
        progress = lines[-1] if lines else "SSM status check is retrying after first boot or reboot"
        if progress != previous:
            print("  " + progress, flush=True)
            previous = progress
        time.sleep(15)
    raise RuntimeError("GPU preparation is not confirmed after 45 minutes. The stack remains and may still be preparing. Connect to this instance and inspect fortiaigate-prep-status and its log before any new Create.")

def template(prefix, cidr, ami, root_device, zone, bucket, release_prefix):
    def ref(name):
        return {"Ref": name}

    def sub(value):
        return {"Fn::Sub": value}

    def tag(name):
        return [{"Key": "Name", "Value": prefix + "_FortiAIGate_GPU_" + name}]

    resources = {
        "Vpc": {"Type": "AWS::EC2::VPC", "Properties": {
            "CidrBlock": "10.60.0.0/16", "EnableDnsSupport": True,
            "EnableDnsHostnames": True, "Tags": tag("VPC")}},
        "Gateway": {"Type": "AWS::EC2::InternetGateway", "Properties": {"Tags": tag("IGW")}},
        "GatewayAttachment": {"Type": "AWS::EC2::VPCGatewayAttachment", "Properties": {
            "VpcId": ref("Vpc"), "InternetGatewayId": ref("Gateway")}},
        "Subnet": {"Type": "AWS::EC2::Subnet", "Properties": {
            "VpcId": ref("Vpc"), "CidrBlock": "10.60.1.0/24", "AvailabilityZone": zone,
            "MapPublicIpOnLaunch": True, "Tags": tag("Subnet")}},
        "RouteTable": {"Type": "AWS::EC2::RouteTable", "Properties": {"VpcId": ref("Vpc"), "Tags": tag("Route_Table")}},
        "DefaultRoute": {"Type": "AWS::EC2::Route", "DependsOn": "GatewayAttachment", "Properties": {
            "RouteTableId": ref("RouteTable"), "DestinationCidrBlock": "0.0.0.0/0", "GatewayId": ref("Gateway")}},
        "SubnetRoute": {"Type": "AWS::EC2::SubnetRouteTableAssociation", "Properties": {
            "SubnetId": ref("Subnet"), "RouteTableId": ref("RouteTable")}},
        "SecurityGroup": {"Type": "AWS::EC2::SecurityGroup", "Properties": {
            "GroupName": prefix + "_FortiAIGate_GPU_NSG", "GroupDescription": "FortiAIGate GPU HTTPS from one browser IP; administration through SSM",
            "VpcId": ref("Vpc"), "SecurityGroupIngress": [{"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
            "CidrIp": cidr, "Description": "HTTPS from browser IPv4 only"}],
            "SecurityGroupEgress": [{"IpProtocol": "-1", "CidrIp": "0.0.0.0/0"}], "Tags": tag("NSG")}},
        "Role": {"Type": "AWS::IAM::Role", "Properties": {
            "RoleName": prefix + "_FortiAIGate_GPU_SSMRole",
            "AssumeRolePolicyDocument": {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]},
            "ManagedPolicyArns": [sub("arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore")],
            "Policies": [{"PolicyName": prefix + "_FortiAIGate_GPU_S3Read", "PolicyDocument": {
                "Version": "2012-10-17", "Statement": [
                    {"Effect": "Allow", "Action": "s3:ListBucket", "Resource": sub("arn:${AWS::Partition}:s3:::" + bucket),
                     "Condition": {"StringLike": {"s3:prefix": [release_prefix, release_prefix + "/", release_prefix + "/*"]}}},
                    {"Effect": "Allow", "Action": "s3:GetObject", "Resource": sub("arn:${AWS::Partition}:s3:::" + bucket + "/" + release_prefix + "/*")}]}}],
            "Tags": tag("SSMRole")}},
        "Profile": {"Type": "AWS::IAM::InstanceProfile", "Properties": {
            "InstanceProfileName": prefix + "_FortiAIGate_GPU_SSMProfile", "Roles": [ref("Role")]}},
        "Instance": {"Type": "AWS::EC2::Instance", "DependsOn": ["DefaultRoute", "SubnetRoute"], "Properties": {
            "ImageId": ami, "InstanceType": INSTANCE_TYPE, "SubnetId": ref("Subnet"), "PrivateIpAddress": "10.60.1.4",
            "SecurityGroupIds": [ref("SecurityGroup")], "IamInstanceProfile": ref("Profile"),
            "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled", "HttpPutResponseHopLimit": 1},
            "BlockDeviceMappings": [{"DeviceName": root_device, "Ebs": {"VolumeSize": 500, "VolumeType": "gp3", "Iops": 3000,
                "Encrypted": True, "DeleteOnTermination": True}}],
            "PropagateTagsToVolumeOnCreation": True, "Monitoring": False,
            "UserData": {"Fn::Base64": preparation_user_data(bucket, release_prefix)},
            "Tags": tag("Docker")}},
    }
    return {"AWSTemplateFormatVersion": "2010-09-09", "Description": "FortiAIGate 8.0.2 isolated L40S GPU lab; infrastructure only",
        "Resources": resources, "Outputs": {
            "PreparationVersion": {"Value": VERSION}, "VpcId": {"Value": ref("Vpc")}, "InstanceId": {"Value": ref("Instance")},
            "PublicIPv4": {"Value": {"Fn::GetAtt": ["Instance", "PublicIp"]}},
            "PrivateIPv4": {"Value": {"Fn::GetAtt": ["Instance", "PrivateIp"]}},
            "HttpsURL": {"Value": sub("https://${Instance.PublicIp}")},
            "RoleName": {"Value": ref("Role")}, "ReleaseBucket": {"Value": bucket}, "ReleasePrefix": {"Value": release_prefix}}}


"""Server-side GPU lab expiry. A VM shutdown cannot disable this controller."""
import datetime as budget_dt
import json as budget_json
import uuid as budget_uuid
import re as budget_re

BUDGET_VERSION = '2h-stop-12h-delete-v1'
BUDGET_CONTRIBUTOR = 'b24988ac-6180-42a0-ab88-20f7382dd24c'


def budget_time(value):
    result = budget_dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise RuntimeError('Budget timestamps must include a timezone.')
    return result.astimezone(budget_dt.timezone.utc)


def budget_stamp(value):
    return value.astimezone(budget_dt.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def budget_tags(now=None, previous=None, mode='restart'):
    now = now or budget_dt.datetime.now(budget_dt.timezone.utc)
    stop = now + budget_dt.timedelta(hours=2)
    if mode == 'extend':
        stop = max(now, budget_time(previous['BudgetStopAt'])) + budget_dt.timedelta(hours=2)
    elif mode == 'use':
        stop = budget_time(previous['BudgetStopAt'])
    elif mode != 'restart':
        raise RuntimeError('Invalid budget action.')
    delete = now + budget_dt.timedelta(hours=12)
    if stop >= delete:
        raise RuntimeError('The requested run reservation reaches the 12-hour inactivity expiry. Extend closer to the current stop time.')
    return {'BudgetVersion': BUDGET_VERSION, 'BudgetLastUsedAt': budget_stamp(now),
            'BudgetStopAt': budget_stamp(stop), 'BudgetDeleteAt': budget_stamp(delete)}



"""AWS-only eight-hour CloudFormation lab expiry; explicit extensions, no automatic stop."""
import copy as budget_copy
import json as budget_json
import time as budget_clock

AWS_GPU_INSTANCE_TYPES = ('g6e.2xlarge', 'g6e.4xlarge')

# Override only the shared functions prepended to the AWS payload. Azure retains
# its separate lifecycle policy and sources.
BUDGET_VERSION = '8h-delete-v2'
AWS_BUDGET_VERSIONS = (BUDGET_VERSION, '2h-stop-12h-delete-v1')


def budget_tags(now=None, previous=None, mode='restart'):
    """Start with eight hours; only an explicit Extend adds another eight."""
    if mode not in ('restart', 'use', 'extend'):
        raise RuntimeError('Invalid AWS lifecycle action.')
    now = now or budget_dt.datetime.now(budget_dt.timezone.utc)
    if now.tzinfo is None:
        raise RuntimeError('Budget timestamps must include a timezone.')
    if previous is not None:
        if previous.get('BudgetVersion') != BUDGET_VERSION:
            raise RuntimeError('Existing legacy timers are unchanged; use Destroy and Create for the eight-hour policy.')
        created = budget_time(previous['BudgetCreatedAt'])
        expires = budget_time(previous['BudgetDeleteAt'])
        interval = budget_dt.timedelta(hours=8)
        if expires <= created or (expires - created) % interval:
            raise RuntimeError('The lab deadline is not a positive multiple of eight hours from creation.')
        result = {key: previous[key] for key in ('BudgetVersion', 'BudgetCreatedAt', 'BudgetDeleteAt')}
        if mode == 'extend':
            if expires <= now:
                raise RuntimeError('The deletion deadline passed. Cleanup may be running; create a separate new lab.')
            result['BudgetDeleteAt'] = budget_stamp(expires + interval)
        return result
    if mode == 'extend':
        raise RuntimeError('Extend requires an existing managed lab deadline.')
    return {'BudgetVersion': BUDGET_VERSION, 'BudgetCreatedAt': budget_stamp(now),
            'BudgetDeleteAt': budget_stamp(now + budget_dt.timedelta(hours=8))}

# The builder prepends the same UTC deadline functions used by Azure.
BUDGET_LAMBDA = '''import boto3,datetime,os,re
ec2=boto3.client("ec2")
cfn=boto3.client("cloudformation")
scheduler=boto3.client("scheduler")
def deadline(name):
    item=scheduler.get_schedule(Name=name,GroupName="default")
    expression=item["ScheduleExpression"]
    if item.get("State")!="ENABLED" or not expression.startswith("at(") or not expression.endswith(")"):
        raise RuntimeError("Lifecycle schedule is not an enabled UTC deadline")
    if item.get("ScheduleExpressionTimezone","UTC")!="UTC": raise RuntimeError("Invalid schedule timezone")
    return datetime.datetime.fromisoformat(expression[3:-1]).replace(tzinfo=datetime.timezone.utc)
def linked_ollama(stack):
    # Use service-owned stack tags and validate each returned stack again.
    outputs={o["OutputKey"]:o["OutputValue"] for o in stack.get("Outputs",[])}
    vpc_id=os.environ.get("VPC_ID") or outputs.get("VpcId")
    if not vpc_id:
        row=cfn.describe_stack_resource(StackName=stack["StackId"],LogicalResourceId="Vpc")["StackResourceDetail"]
        vpc_id=row.get("PhysicalResourceId","")
    if not re.fullmatch(r"vpc-(?:[0-9a-f]{8}|[0-9a-f]{17})",vpc_id):
        raise RuntimeError("Cannot establish parent VPC for linked Ollama cleanup")
    # Read CloudFormation directly. A secondary tag index can briefly omit a new
    # child and would let the parent delete its own watchdog before VPC failure.
    request={}
    candidates=[]
    for _ in range(100):
        page=cfn.describe_stacks(**request)
        for child in page.get("Stacks",[]):
            tags={t["Key"]:t["Value"] for t in child.get("Tags",[])}
            if (tags.get("DeploymentGuide")=="FortiAIGate-Ollama-AWS-v1"
                    and tags.get("FortiAIGateVpcId")==vpc_id
                    and child.get("StackStatus")!="DELETE_COMPLETE"):
                candidates.append(child)
        token=page.get("NextToken")
        if not token: break
        request["NextToken"]=token
    else: raise RuntimeError("Linked Ollama inventory exceeded pagination limit")
    gateway=outputs.get("InstanceId")
    if candidates and not gateway:
        row=cfn.describe_stack_resource(StackName=stack["StackId"],LogicalResourceId="Instance")["StackResourceDetail"]
        gateway=row.get("PhysicalResourceId","")
    parent_arn=stack["StackId"].split(":",5)
    found=[]
    for child in candidates:
        arn=child["StackId"]
        parts=arn.split(":",5)
        if len(parts)!=6 or parts[0:5]!=parent_arn[0:5] or not parts[5].startswith("stack/Ollama-Lab-"):
            raise RuntimeError("Linked Ollama stack account/region/name could not be verified")
        tags={t["Key"]:t["Value"] for t in child.get("Tags",[])}
        prefix=tags.get("UserPrefix","")
        if (child["StackId"]!=arn or not re.fullmatch(r"[a-z][a-z0-9]{0,23}",prefix)
                or child["StackName"]!="Ollama-Lab-"+prefix
                or parts[5].split("/")[1]!=child["StackName"]
                or tags.get("DeploymentGuide")!="FortiAIGate-Ollama-AWS-v1"
                or tags.get("FortiAIGateVpcId")!=vpc_id
                or not gateway or tags.get("FortiAIGateInstanceId")!=gateway):
            raise RuntimeError("Linked Ollama stack ownership changed; parent deletion stopped")
        found.append(child)
    return found

def delete_linked_ollama(stack):
    children=linked_ollama(stack)
    for child in children:
        state=child["StackStatus"]
        if state=="DELETE_FAILED":
            raise RuntimeError("Linked Ollama deletion failed; use the current manual Destroy launcher")
        if state=="DELETE_IN_PROGRESS": continue
        if state.endswith("_IN_PROGRESS"):
            raise RuntimeError("Linked Ollama stack is busy; parent deletion deferred")
        cfn.delete_stack(StackName=child["StackId"],RoleARN=os.environ["CLEANUP_ROLE_ARN"])
    # No polling within the Lambda. The existing watchdog retries after deletion.
    return not children

def stack_resource(stack_id,logical):
    try:
        return cfn.describe_stack_resource(StackName=stack_id,LogicalResourceId=logical)["StackResourceDetail"]
    except Exception as error:
        detail=getattr(error,"response",{}).get("Error",{})
        message=detail.get("Message",str(error))
        if (detail.get("Code")=="ValidationError" and logical in message
                and ("does not exist" in message or "not exist" in message)):
            return {}
        raise

def validate_fleet_instance(instance,stack_id,template_id,vpc_id):
    tags={t["Key"]:t["Value"] for t in instance.get("Tags",[])}
    expected_type=os.environ.get("EXPECTED_INSTANCE_TYPE")
    if (not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})",instance.get("InstanceId",""))
            or tags.get("BudgetStack")!=stack_id or tags.get("FortiAIGateBudgetStack")!=stack_id
            or tags.get("BudgetVersion") not in ("8h-delete-v2","2h-stop-12h-delete-v1")
            or instance.get("VpcId")!=vpc_id
            or not expected_type or instance.get("InstanceType")!=expected_type):
        raise RuntimeError("Fleet instance ownership/configuration changed; no action performed")
    template_tag=tags.get("aws:ec2launchtemplate:id")
    if template_tag!=template_id:
        raise RuntimeError("Instance launch template identity missing or changed; no action performed")
    return instance

def managed_instance(stack_id):
    row=stack_resource(stack_id,"Instance")
    instance_id=row.get("PhysicalResourceId","")
    if instance_id.startswith("i-") and row.get("ResourceType")!="Custom::FleetInstance":
        rows=ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
        instances=[i for r in rows for i in r["Instances"]]
        if len(instances)!=1: raise RuntimeError("Expected one managed lab instance")
        instance=instances[0]
        expected_type=os.environ.get("EXPECTED_INSTANCE_TYPE","g6e.2xlarge")
        if (expected_type not in ("g6e.2xlarge","g6e.4xlarge")
                or instance.get("InstanceType")!=expected_type or instance.get("InstanceId")!=instance_id):
            raise RuntimeError("Native instance type or identity changed; no action performed")
        return instance
    # A launch can exist before CloudFormation has recorded the resolver's ID.
    # Discover it only within this stack's template, VPC and ownership tags.
    template_id=stack_resource(stack_id,"LaunchTemplate").get("PhysicalResourceId","")
    if not re.fullmatch(r"lt-(?:[0-9a-f]{8}|[0-9a-f]{17})",template_id): return None
    vpc_id=os.environ.get("VPC_ID") or stack_resource(stack_id,"Vpc").get("PhysicalResourceId","")
    if not re.fullmatch(r"vpc-(?:[0-9a-f]{8}|[0-9a-f]{17})",vpc_id):
        raise RuntimeError("Cannot verify the Fleet VPC; no action performed")
    fleet_id=stack_resource(stack_id,"Fleet").get("PhysicalResourceId","")
    members=set()
    if fleet_id.startswith("fleet-"):
        fleets=ec2.describe_fleets(FleetIds=[fleet_id]).get("Fleets",[])
        if len(fleets)!=1 or fleets[0].get("FleetId")!=fleet_id or fleets[0].get("Type")!="instant":
            raise RuntimeError("Cannot verify the managed instant Fleet")
        fleet_tags={t["Key"]:t["Value"] for t in fleets[0].get("Tags",[])}
        if fleet_tags.get("FortiAIGateBudgetStack")!=stack_id:
            raise RuntimeError("Fleet ownership changed; no action performed")
        for group in fleets[0].get("Instances",[]):
            spec=group.get("LaunchTemplateAndOverrides",{}).get("LaunchTemplateSpecification",{})
            if spec.get("LaunchTemplateId")!=template_id or group.get("Lifecycle")!="on-demand":
                raise RuntimeError("Fleet launch template/lifecycle changed; no action performed")
            for value in group.get("InstanceIds",[]):
                if not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})",value):
                    raise RuntimeError("Invalid Fleet member; no action performed")
                members.add(value)
        if len(members)>1: raise RuntimeError("Expected at most one managed Fleet instance")
    if members:
        if instance_id.startswith("i-") and instance_id not in members:
            raise RuntimeError("Fleet membership changed; no action performed")
        request={"InstanceIds":sorted(members)}
    else:
        request={"Filters":[{"Name":"vpc-id","Values":[vpc_id]},
            {"Name":"tag:aws:ec2launchtemplate:id","Values":[template_id]},
            {"Name":"tag:BudgetStack","Values":[stack_id]},
            {"Name":"tag:FortiAIGateBudgetStack","Values":[stack_id]},
            {"Name":"tag:BudgetVersion","Values":["8h-delete-v2","2h-stop-12h-delete-v1"]},
            {"Name":"instance-state-name","Values":["pending","running","stopping","stopped"]}]}
    instances=[]
    for _ in range(100):
        page=ec2.describe_instances(**request)
        instances.extend(i for r in page.get("Reservations",[]) for i in r.get("Instances",[]))
        token=page.get("NextToken")
        if not token: break
        request["NextToken"]=token
    else: raise RuntimeError("Instance inventory exceeded pagination limit")
    if len(instances)>1: raise RuntimeError("Expected at most one managed Fleet instance")
    if not instances: return None
    instance=validate_fleet_instance(instances[0],stack_id,template_id,vpc_id)
    if members and instance["InstanceId"] not in members:
        raise RuntimeError("Fleet member identity changed; no action performed")
    if instance_id.startswith("i-") and instance["InstanceId"]!=instance_id:
        raise RuntimeError("Fleet resolver identity changed; no action performed")
    return instance

def handler(event,context,now=None):
    if event.get("action") not in ("stop","expire","check"): raise RuntimeError("Unknown lifecycle action")
    stack_id=os.environ["STACK_ID"]
    stack=cfn.describe_stacks(StackName=stack_id)["Stacks"][0]
    stack_tags={t["Key"]:t["Value"] for t in stack.get("Tags",[])}
    if stack_tags.get("DeploymentGuide")!="FortiAIGate-GPU-AWS-v1" or stack["StackId"]!=stack_id:
        raise RuntimeError("Stack ownership changed; no action performed")
    if stack["StackStatus"] in ("DELETE_IN_PROGRESS","DELETE_COMPLETE"):
        return {"status":"lab already deleting"}
    # Queued events and the watchdog always re-read the authoritative expiry.
    # Even an old queued "stop" event can never stop a VM under this controller.
    delete_at=deadline(os.environ["DELETE_SCHEDULE"])
    now=now or datetime.datetime.now(datetime.timezone.utc)
    if now<delete_at:
        return {"status":"deletion deadline not reached; no action"}
    if not delete_linked_ollama(stack):
        return {"status":"linked Ollama deletion pending; parent retained until next watchdog"}
    cfn.delete_stack(StackName=stack_id,RoleARN=os.environ["CLEANUP_ROLE_ARN"])
    return {"status":"complete lab stack deletion requested"}
'''



def add_aws_budget(body, prefix, now=None):
    body = budget_copy.deepcopy(body)
    resources = body['Resources']
    instance_type = resources['Instance']['Properties']['InstanceType']
    if instance_type not in AWS_GPU_INSTANCE_TYPES:
        raise RuntimeError('GPU lifecycle protection supports only g6e.2xlarge or g6e.4xlarge.')
    clocks = budget_tags(now)
    resources['Instance']['Properties']['Tags'] += [
        {'Key': k, 'Value': v} for k, v in clocks.items()]
    resources['Instance']['Properties']['Tags'].append({'Key': 'BudgetStack', 'Value': {'Ref': 'AWS::StackId'}})
    for mapping in resources['Instance']['Properties'].get('BlockDeviceMappings', []):
        if 'Ebs' in mapping and not mapping['Ebs'].get('DeleteOnTermination'):
            raise RuntimeError('Managed expiry requires delete-on-termination on the new lab disk.')
        if 'Ebs' in mapping:
            # EC2::Instance's Ebs schema has no Throughput property. gp3's
            # default is the intended 125 MiB/s; higher values need a LaunchTemplate.
            throughput = mapping['Ebs'].pop('Throughput', 125)
            if throughput != 125:
                raise RuntimeError('This instance template supports gp3 default throughput only.')
    sub = lambda x: {'Fn::Sub': x}
    get = lambda x: {'Fn::GetAtt': [x, 'Arn']}
    # Retain the cleanup identity: deleting its inline policy would revoke the
    # permissions needed to finish its own deletion. Normal authenticated Destroy
    # removes this nonbillable role after confirming the stack is gone.
    role_names = [prefix + suffix for suffix in (
        '_FortiAIGate_GPU_SSMRole', '_FortiAIGate_GPU_LifecycleRole',
        '_FortiAIGate_GPU_SchedulerRole', '_FortiAIGate_GPU_CleanupRole')]
    role_arns = [sub('arn:${AWS::Partition}:iam::${AWS::AccountId}:role/' + n) for n in role_names]
    profile_arn = sub('arn:${AWS::Partition}:iam::${AWS::AccountId}:instance-profile/' + prefix + '_FortiAIGate_GPU_SSMProfile')
    ec2_arns = [sub('arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:' + kind + '/*')
                for kind in ('instance','vpc','subnet','internet-gateway','route-table','security-group')]
    ollama_role_arn = sub('arn:${AWS::Partition}:iam::${AWS::AccountId}:role/Ollama-Lab-*-${Vpc}-Role')
    ollama_profile_arn = sub('arn:${AWS::Partition}:iam::${AWS::AccountId}:instance-profile/Ollama-Lab-*-${Vpc}-Profile')
    ollama_stack_arn = sub('arn:${AWS::Partition}:cloudformation:${AWS::Region}:${AWS::AccountId}:stack/Ollama-Lab-*/*')
    resources['BudgetCleanupRole'] = {'Type': 'AWS::IAM::Role',
        'DeletionPolicy': 'RetainExceptOnCreate', 'UpdateReplacePolicy': 'Retain', 'Properties': {
        'RoleName': role_names[-1],
        'Tags': [{'Key':'DeploymentGuide','Value':'FortiAIGate-GPU-AWS-v1'},
                 {'Key':'UserPrefix','Value':prefix.lower()},
                 {'Key':'BudgetVersion','Value':BUDGET_VERSION},
                 {'Key':'BudgetStack','Value':{'Ref':'AWS::StackId'}}],
        'AssumeRolePolicyDocument': {'Version': '2012-10-17', 'Statement': [
            {'Effect': 'Allow', 'Principal': {'Service': 'cloudformation.amazonaws.com'}, 'Action': 'sts:AssumeRole'}]},
        'Policies': [{'PolicyName': 'DeleteOnlyThisLab', 'PolicyDocument': {'Version': '2012-10-17', 'Statement': [
            {'Effect': 'Allow', 'Action': ['ec2:Describe*'], 'Resource': '*',
             'Condition': {'StringEquals': {'ec2:Region': {'Ref': 'AWS::Region'}}}},
            {'Effect': 'Allow', 'Action': ['ec2:TerminateInstances','ec2:DeleteVpc','ec2:DeleteSubnet',
                'ec2:DeleteInternetGateway','ec2:DetachInternetGateway','ec2:DeleteRouteTable',
                'ec2:DeleteRoute','ec2:DeleteSecurityGroup','ec2:RevokeSecurityGroupIngress','ec2:RevokeSecurityGroupEgress'], 'Resource': ec2_arns,
             'Condition': {'StringEquals': {'ec2:ResourceTag/FortiAIGateBudgetStack': {'Ref': 'AWS::StackId'}}}},
            # EC2 does not expose a subnet route-table association ARN for this
            # action. CloudFormation selects the association recorded in this
            # stack; IAM restricts this otherwise-unscopable action to its region.
            {'Effect': 'Allow', 'Action': ['ec2:DisassociateRouteTable'], 'Resource': '*',
             'Condition': {'StringEquals': {'ec2:Region': {'Ref': 'AWS::Region'}}}},
            {'Effect': 'Allow', 'Action': ['iam:GetRole','iam:GetRolePolicy','iam:ListRolePolicies',
                'iam:ListAttachedRolePolicies','iam:ListInstanceProfilesForRole','iam:ListRoleTags',
                'iam:DeleteRolePolicy','iam:DetachRolePolicy','iam:DeleteRole'], 'Resource': role_arns[:-1]},
            {'Effect': 'Allow', 'Action': ['iam:GetInstanceProfile','iam:RemoveRoleFromInstanceProfile',
                'iam:DeleteInstanceProfile'], 'Resource': profile_arn},
            {'Effect': 'Allow', 'Action': ['ec2:TerminateInstances','ec2:DeleteSecurityGroup',
                'ec2:RevokeSecurityGroupIngress','ec2:RevokeSecurityGroupEgress'],
             'Resource': [sub('arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:instance/*'),
                          sub('arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:security-group/*')],
             'Condition': {'StringEquals': {'ec2:ResourceTag/DeploymentGuide': 'FortiAIGate-Ollama-AWS-v1',
                                            'ec2:ResourceTag/FortiAIGateVpcId': {'Ref': 'Vpc'}}}},
            {'Effect': 'Allow', 'Action': ['iam:GetRole','iam:GetRolePolicy','iam:ListRolePolicies',
                'iam:ListAttachedRolePolicies','iam:ListInstanceProfilesForRole','iam:ListRoleTags',
                'iam:DeleteRolePolicy','iam:DetachRolePolicy','iam:DeleteRole'],
             'Resource': ollama_role_arn},
            {'Effect': 'Allow', 'Action': ['iam:GetInstanceProfile','iam:RemoveRoleFromInstanceProfile',
                'iam:DeleteInstanceProfile'], 'Resource': ollama_profile_arn},
            {'Effect': 'Allow', 'Action': ['lambda:GetFunction','lambda:GetFunctionConfiguration',
                'lambda:ListTags','lambda:DeleteFunction'],
             'Resource': sub('arn:${AWS::Partition}:lambda:${AWS::Region}:${AWS::AccountId}:function:${AWS::StackName}-lifecycle')},
            {'Effect': 'Allow', 'Action': ['scheduler:GetSchedule','scheduler:DeleteSchedule'],
             'Resource': [sub('arn:${AWS::Partition}:scheduler:${AWS::Region}:${AWS::AccountId}:schedule/default/${AWS::StackName}-' + x)
                          for x in ('expire','watchdog')]},
            {'Effect': 'Allow', 'Action': ['logs:DescribeLogGroups'], 'Resource': '*'},
            {'Effect': 'Allow', 'Action': ['logs:DeleteLogGroup','logs:ListTagsForResource'],
             'Resource': [sub('arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${AWS::StackName}-lifecycle'),
                          sub('arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${AWS::StackName}-lifecycle:*')]}
        ]}}]}}
    for resource in resources.values():
        if resource['Type'].startswith('AWS::EC2::') and 'Tags' in resource.get('Properties', {}):
            resource['Properties']['Tags'].append({'Key': 'FortiAIGateBudgetStack', 'Value': {'Ref': 'AWS::StackId'}})
    resources['BudgetLogs'] = {'Type': 'AWS::Logs::LogGroup', 'Properties': {
        'LogGroupName': sub('/aws/lambda/${AWS::StackName}-lifecycle'), 'RetentionInDays': 1}}
    resources['BudgetRole'] = {'Type': 'AWS::IAM::Role', 'Properties': {
        'RoleName': role_names[1],
        'AssumeRolePolicyDocument': {'Version': '2012-10-17', 'Statement': [
            {'Effect': 'Allow', 'Principal': {'Service': 'lambda.amazonaws.com'}, 'Action': 'sts:AssumeRole'}]},
        'Policies': [{'PolicyName': 'ManageOnlyThisGPU', 'PolicyDocument': {'Version': '2012-10-17', 'Statement': [
            {'Effect': 'Allow', 'Action': ['cloudformation:DescribeStacks','cloudformation:DescribeStackResource','cloudformation:DeleteStack'], 'Resource': {'Ref': 'AWS::StackId'}},
            # Unfiltered authoritative inventory requires accountwide read only.
            {'Effect': 'Allow', 'Action': ['cloudformation:DescribeStacks','cloudformation:ListStacks'], 'Resource': '*'},
            {'Effect': 'Allow', 'Action': ['cloudformation:DeleteStack'], 'Resource': ollama_stack_arn,
             'Condition': {'StringEquals': {'aws:ResourceTag/DeploymentGuide': 'FortiAIGate-Ollama-AWS-v1',
                                            'aws:ResourceTag/FortiAIGateVpcId': {'Ref': 'Vpc'}}}},
            {'Effect': 'Allow', 'Action': ['scheduler:GetSchedule'],
             'Resource': [sub('arn:${AWS::Partition}:scheduler:${AWS::Region}:${AWS::AccountId}:schedule/default/${AWS::StackName}-' + x)
                          for x in ('expire',)]},
            {'Effect': 'Allow', 'Action': ['iam:PassRole'], 'Resource': get('BudgetCleanupRole'),
             'Condition': {'StringEquals': {'iam:PassedToService': 'cloudformation.amazonaws.com'}}},
            {'Effect': 'Allow', 'Action': ['logs:CreateLogStream', 'logs:PutLogEvents'],
             'Resource': sub('arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${AWS::StackName}-lifecycle:*')}
        ]}}]}}
    resources['BudgetFunction'] = {'Type': 'AWS::Lambda::Function', 'DependsOn': 'BudgetLogs', 'Properties': {
        'FunctionName': sub('${AWS::StackName}-lifecycle'), 'Runtime': 'python3.13', 'Handler': 'index.handler',
        'Role': get('BudgetRole'), 'Timeout': 60, 'MemorySize': 128,
        'Environment': {'Variables': {'STACK_ID': {'Ref': 'AWS::StackId'}, 'VPC_ID': {'Ref': 'Vpc'},
            'EXPECTED_INSTANCE_TYPE': instance_type,
            'DELETE_SCHEDULE': sub('${AWS::StackName}-expire'),
            'CLEANUP_ROLE_ARN': get('BudgetCleanupRole')}},
        'Code': {'ZipFile': BUDGET_LAMBDA}}}
    resources['BudgetSchedulerRole'] = {'Type': 'AWS::IAM::Role', 'Properties': {
        'RoleName': role_names[2],
        'AssumeRolePolicyDocument': {'Version': '2012-10-17', 'Statement': [{
            'Effect': 'Allow', 'Principal': {'Service': 'scheduler.amazonaws.com'}, 'Action': 'sts:AssumeRole',
            'Condition': {'StringEquals': {'aws:SourceAccount': {'Ref': 'AWS::AccountId'}}}}]},
        'Policies': [{'PolicyName': 'InvokeOnlyThisController', 'PolicyDocument': {'Version': '2012-10-17', 'Statement': [
            {'Effect': 'Allow', 'Action': 'lambda:InvokeFunction', 'Resource': get('BudgetFunction')} ]}}]}}
    for action, key, logical in [('expire', 'BudgetDeleteAt', 'BudgetDeleteSchedule')]:
        name = sub('${AWS::StackName}-' + action)
        resources[logical] = {'Type': 'AWS::Scheduler::Schedule', 'Properties': {
            'Name': name, 'GroupName': 'default', 'State': 'ENABLED',
            'ScheduleExpression': 'at(' + clocks[key].replace('Z', '') + ')',
            'ScheduleExpressionTimezone': 'UTC', 'FlexibleTimeWindow': {'Mode': 'OFF'},
            'Target': {'Arn': get('BudgetFunction'), 'RoleArn': get('BudgetSchedulerRole'),
                       'Input': budget_json.dumps({'action': action}),
                       'RetryPolicy': {'MaximumEventAgeInSeconds': 3600, 'MaximumRetryAttempts': 3}}}}
        body['Outputs'][logical] = {'Value': name}
    # A five-minute watchdog retries complete deletion after delayed provision,
    # linked-child cleanup or exhausted schedule delivery. It lives outside EC2.
    resources['BudgetWatchdogSchedule'] = {'Type': 'AWS::Scheduler::Schedule', 'Properties': {
        'Name': sub('${AWS::StackName}-watchdog'), 'GroupName': 'default', 'State': 'ENABLED',
        'ScheduleExpression': 'rate(5 minutes)', 'FlexibleTimeWindow': {'Mode': 'OFF'},
        'Target': {'Arn': get('BudgetFunction'), 'RoleArn': get('BudgetSchedulerRole'),
                   'Input': budget_json.dumps({'action': 'check'}),
                   'RetryPolicy': {'MaximumEventAgeInSeconds': 300, 'MaximumRetryAttempts': 2}}}}
    dependencies = resources['Instance'].get('DependsOn', [])
    if isinstance(dependencies, str): dependencies = [dependencies]
    resources['Instance']['DependsOn'] = dependencies + [
        'BudgetDeleteSchedule', 'BudgetWatchdogSchedule']
    body['Outputs']['BudgetFunctionArn'] = {'Value': get('BudgetFunction')}
    body['Outputs']['BudgetScheduleRoleArn'] = {'Value': get('BudgetSchedulerRole')}
    body['Outputs']['BudgetCleanupRoleArn'] = {'Value': get('BudgetCleanupRole')}
    for logical, resource in resources.items():
        # The cleanup role's add-on IAM scope references the VPC ID. The
        # nonbillable VPC must exist first; billable compute still waits for all protectors.
        if logical not in ('BudgetCleanupRole', 'Vpc'):
            dependencies = resource.get('DependsOn', [])
            if isinstance(dependencies, str): dependencies = [dependencies]
            resource['DependsOn'] = list(dict.fromkeys(dependencies + ['BudgetCleanupRole']))
    return body


def aws_budget_creation_preflight(prefix):
    """Retained identities must never cause a slow, billable failed recreation."""
    if gpu_find_role(prefix + '_FortiAIGate_GPU_CleanupRole') is None:
        return
    raise RuntimeError('A cleanup IAM role still exists for this username. Allow the shared service up to five minutes after stack deletion, then rerun Create. If cleanup is blocked or that service is not installed, inspect it or use Destroy. No GPU resources were created.')


def budget_schedule_input(schedule, deadline=None):
    keys = ('Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone', 'FlexibleTimeWindow',
            'Target', 'State', 'Description', 'KmsKeyArn', 'StartDate', 'EndDate', 'ActionAfterCompletion')
    result = {k: budget_copy.deepcopy(schedule[k]) for k in keys if k in schedule}
    if deadline:
        result['ScheduleExpression'] = 'at(' + deadline.replace('Z', '') + ')'
        result['State'] = 'ENABLED'
    return result


def aws_budget_target(api, stack):
    owned(stack)
    values = {o['OutputKey']: o['OutputValue'] for o in stack.get('Outputs', [])}
    required = {'InstanceId', 'BudgetDeleteSchedule', 'BudgetFunctionArn', 'BudgetScheduleRoleArn'}
    if not required.issubset(values):
        raise RuntimeError('This stack predates managed expiry; its timers were not changed. Use a new managed lab.')
    response = api('ec2', 'describe-instances', InstanceIds=[values['InstanceId']])
    instances = [i for r in response['Reservations'] for i in r['Instances']]
    if len(instances) != 1:
        raise RuntimeError('Expected one owned lab instance.')
    instance = instances[0]
    expected_type = values.get('InstanceType', 'g6e.2xlarge')
    if expected_type not in AWS_GPU_INSTANCE_TYPES or instance.get('InstanceType') != expected_type:
        raise RuntimeError('Instance type differs from the selected managed GPU lab.')
    tags = {t['Key']: t['Value'] for t in instance.get('Tags', [])}
    if (tags.get('BudgetStack') != stack['StackId'] or tags.get('FortiAIGateBudgetStack') != stack['StackId']
            or tags.get('BudgetVersion') not in AWS_BUDGET_VERSIONS):
        raise RuntimeError('Instance lifecycle ownership differs from the selected stack.')
    return values, instance, tags


def aws_budget_snapshot(api, stack, mode, now=None):
    """Read and validate ownership plus the authoritative schedule before any write."""
    if mode not in ('use', 'restart', 'extend'):
        raise RuntimeError('Invalid AWS lifecycle action.')
    values, instance, tags = aws_budget_target(api, stack)
    now = now or budget_dt.datetime.now(budget_dt.timezone.utc)
    delete_at = budget_time(tags['BudgetDeleteAt'])
    if delete_at <= now:
        raise RuntimeError('The deletion deadline passed. Cleanup may be running; create a separate new lab.')
    state = instance['State']['Name']
    if mode in ('restart', 'extend') and state not in ('running', 'stopped'):
        raise RuntimeError('VM is changing state. Wait, inspect it and retry.')
    if mode == 'use' and state != 'running':
        raise RuntimeError('Use Restart to resume the stopped VM; its deletion deadline will not change.')
    schedule = api('scheduler', 'get-schedule', Name=values['BudgetDeleteSchedule'], GroupName='default')
    if (schedule['Target'].get('Arn') != values['BudgetFunctionArn']
            or schedule['Target'].get('RoleArn') != values['BudgetScheduleRoleArn']
            or budget_json.loads(schedule['Target'].get('Input', '{}')) != {'action': 'expire'}):
        raise RuntimeError('Schedule target differs from the owned lifecycle controller.')
    if (schedule.get('State') != 'ENABLED'
            or schedule.get('ScheduleExpressionTimezone', 'UTC') != 'UTC'
            or schedule.get('ScheduleExpression') != 'at(' + budget_stamp(delete_at).replace('Z', '') + ')'):
        raise RuntimeError('The enabled UTC deletion schedule differs from the recorded lab deadline.')
    if tags['BudgetVersion'] == BUDGET_VERSION:
        budget_tags(now, previous=tags, mode=mode)
        if 'BudgetStopSchedule' in values:
            raise RuntimeError('An unexpected automatic-stop schedule remains on this eight-hour lab; inspect the stack.')
    elif mode == 'extend':
        raise RuntimeError('Legacy lab timers cannot be extended with this launcher. Use Destroy and Create for the eight-hour policy.')
    elif mode == 'restart' and budget_time(tags['BudgetStopAt']) <= now:
        raise RuntimeError('This legacy lab is past its automatic-stop deadline. Restart would be stopped again; its timers were not changed.')
    return values, instance, tags, schedule


def verify_aws_budget_write(api, stack, expected_tags, expected_schedule):
    """Bounded read-back for eventually consistent EC2 tags and Scheduler updates."""
    for attempt in range(6):
        _, _, tags = aws_budget_target(api, stack)
        schedule = api('scheduler', 'get-schedule', Name=expected_schedule['Name'], GroupName='default')
        if (all(tags.get(key) == value for key, value in expected_tags.items())
                and budget_schedule_input(schedule) == expected_schedule):
            return
        if attempt < 5:
            budget_clock.sleep(2)
    raise RuntimeError('Deletion schedule and instance deadline tags did not match the requested values.')


def update_aws_budget(api, stack, mode, now=None, expected_delete_at=None):
    """Connect/Restart preserve expiry; Extend changes only the confirmed deadline."""
    now = now or budget_dt.datetime.now(budget_dt.timezone.utc)
    values, instance, tags, schedule = aws_budget_snapshot(api, stack, mode, now)
    if mode == 'extend':
        if expected_delete_at is None or tags['BudgetDeleteAt'] != expected_delete_at:
            raise RuntimeError('The deadline changed or was not confirmed. Run Extend again to review the current deadline.')
        original_tags = {key: tags[key] for key in ('BudgetVersion', 'BudgetCreatedAt', 'BudgetDeleteAt')}
        new_tags = budget_tags(now, previous=tags, mode='extend')
        original_schedule = budget_schedule_input(schedule)
        new_schedule = budget_schedule_input(schedule, new_tags['BudgetDeleteAt'])
        try:
            # The controller reads this schedule each time, including queued old events.
            api('scheduler', 'update-schedule', **new_schedule)
            api('ec2', 'create-tags', Resources=[values['InstanceId']],
                Tags=[{'Key': 'BudgetDeleteAt', 'Value': new_tags['BudgetDeleteAt']}])
            verify_aws_budget_write(api, stack, new_tags, new_schedule)
        except (Exception, KeyboardInterrupt) as error:
            rollback_errors = []
            for service, operation, arguments in [
                    ('ec2', 'create-tags', {'Resources': [values['InstanceId']],
                        'Tags': [{'Key': 'BudgetDeleteAt', 'Value': tags['BudgetDeleteAt']}]}),
                    ('scheduler', 'update-schedule', original_schedule)]:
                try:
                    api(service, operation, **arguments)
                except Exception as rollback_error:
                    rollback_errors.append(str(rollback_error))
            try:
                verify_aws_budget_write(api, stack, original_tags, original_schedule)
            except Exception as rollback_error:
                rollback_errors.append(str(rollback_error))
                raise RuntimeError('Extension failed and rollback could not be verified. Inspect the deletion schedule and BudgetDeleteAt immediately; do not assume the lab was extended. ' + '; '.join(rollback_errors)) from error
            raise RuntimeError('Extension failed; the original deletion deadline was restored and verified.') from error
        print('PASS: lab deletion extended by 8 hours to ' + new_tags['BudgetDeleteAt'] + ' UTC.')
        print('Creation time is unchanged. No automatic stop; Connect and Restart do not extend expiry.')
    elif tags['BudgetVersion'] == BUDGET_VERSION:
        print('Automatic lab destruction: ' + tags['BudgetDeleteAt'] + ' UTC.')
        print('No automatic stop. Connect and Restart do not change this deadline.')
    else:
        print('Legacy lab: its original two-hour stop and twelve-hour deletion timers remain unchanged.')
        print('Use Destroy and Create to use the new eight-hour policy.')
        print('Existing deletion deadline: ' + tags['BudgetDeleteAt'] + ' UTC.')
    return values, instance


def clear_released_aws_capacity_target(api, stack, values, instance):
    """Resume new labs as On-Demand after their short initial capacity hold ends."""
    expected = values.get('CapacityReservationId')
    if not expected or instance['State']['Name'] != 'stopped':
        # Older labs never had this managed reservation; do not change them.
        return False
    specification = instance.get('CapacityReservationSpecification', {})
    target = specification.get('CapacityReservationTarget', {})
    if not target:
        return False
    if (not budget_re.fullmatch(r'cr-[0-9a-f]{17}', expected)
            or target != {'CapacityReservationId': expected}):
        raise RuntimeError('Instance capacity target differs from this lab reservation; nothing was changed.')
    response = api('ec2', 'describe-capacity-reservations', CapacityReservationIds=[expected])
    rows = response.get('CapacityReservations', [])
    if len(rows) != 1 or rows[0].get('CapacityReservationId') != expected:
        raise RuntimeError('Cannot verify this lab capacity reservation; its instance target was not changed.')
    reservation = rows[0]
    tags = {t['Key']: t['Value'] for t in reservation.get('Tags', [])}
    if (tags.get('DeploymentGuide') != 'FortiAIGate-GPU-AWS-v1'
            or tags.get('BudgetStack') != stack['StackId']
            or tags.get('FortiAIGateBudgetStack') != stack['StackId']
            or tags.get('CapacityLogicalId') != 'CapacityReservation'
            or not budget_re.fullmatch(r'[0-9a-f]{32}', tags.get('CapacityAttempt', ''))
            or instance.get('InstanceType') not in AWS_GPU_INSTANCE_TYPES
            or reservation.get('InstanceType') != instance.get('InstanceType')
            or reservation.get('InstancePlatform') != 'Linux/UNIX'
            or reservation.get('TotalInstanceCount') != 1
            or reservation.get('Tenancy') != 'default'
            or reservation.get('InstanceMatchCriteria') != 'targeted'):
        raise RuntimeError('Capacity reservation ownership or configuration differs; nothing was changed.')
    state = reservation.get('State')
    if state == 'active':
        # An active target can still be used. Never cancel or detach it here.
        return False
    if state not in ('cancelled', 'expired'):
        raise RuntimeError('Capacity reservation is changing state; wait and rerun Restart.')
    result = api('ec2', 'modify-instance-capacity-reservation-attributes',
        InstanceId=values['InstanceId'], CapacityReservationSpecification={'CapacityReservationPreference': 'none'})
    if result.get('Return') is not True:
        raise RuntimeError('AWS did not confirm clearing the released capacity target; the VM was not started.')
    verified = False
    for attempt in range(6):
        _, current, _ = aws_budget_target(api, stack)
        fresh = current.get('CapacityReservationSpecification', {})
        if current['State']['Name'] != 'stopped':
            break
        if fresh.get('CapacityReservationPreference') == 'none' and not fresh.get('CapacityReservationTarget'):
            verified = True
            break
        if attempt < 5:
            budget_clock.sleep(2)
    if not verified:
        raise RuntimeError('On-Demand restart settings were not verified; the VM was not started.')
    print('Released initial capacity hold: restarting this VM as On-Demand in its existing zone.')
    return True


def aws_budget_action(action):
    identity()
    prefix = prefix_of(input('GPU lab name prefix: '))
    stack = describe_stack(stack_name(prefix))
    if stack['StackStatus'] != 'CREATE_COMPLETE':
        raise RuntimeError('Inspect the existing stack before changing its timers.')
    if action not in ('connect', 'restart', 'extend'):
        raise RuntimeError('Invalid AWS lifecycle action.')
    if action == 'extend':
        _, _, tags, _ = aws_budget_snapshot(aws, stack, 'extend')
        proposed = budget_time(tags['BudgetDeleteAt']) + budget_dt.timedelta(hours=8)
        print('Current deletion deadline: ' + tags['BudgetDeleteAt'] + ' UTC')
        print('New deletion deadline:     ' + budget_stamp(proposed) + ' UTC (+8 hours)')
        print('This keeps the full lab for another eight hours; running resources continue to incur charges.')
        if input('1) Extend by 8 hours   0) Cancel [0]: ').strip() != '1':
            print('Cancelled. The deletion deadline was not changed.')
            return
        current = describe_stack(stack_name(prefix))
        if current['StackId'] != stack['StackId'] or current['StackStatus'] != 'CREATE_COMPLETE':
            raise RuntimeError('The lab changed during confirmation. No deadline was changed; inspect it first.')
        update_aws_budget(aws, current, 'extend', expected_delete_at=tags['BudgetDeleteAt'])
        return
    mode = {'connect': 'use', 'restart': 'restart'}[action]
    values, instance = update_aws_budget(aws, stack, mode)
    if action == 'restart' and instance['State']['Name'] == 'stopped':
        clear_released_aws_capacity_target(aws, stack, values, instance)
        aws('ec2', 'start-instances', InstanceIds=[values['InstanceId']])
        print('VM is starting. Use Connect once SSM is Online; GPU capacity is not guaranteed.')
    elif action == 'restart' and instance['State']['Name'] != 'running':
        raise RuntimeError('VM is changing state. Wait, inspect it and rerun Restart.')
    api_result = aws('ec2', 'describe-instances', InstanceIds=[values['InstanceId']])
    current = [i for r in api_result['Reservations'] for i in r['Instances']][0]
    if current.get('PublicIpAddress'):
        print('Current HTTPS address: https://' + current['PublicIpAddress'])
    if 'print_connection_details' in globals():
        print_connection_details(values['InstanceId'])
    if values.get('ElasticIpAllocationId'):
        print('The lab Elastic IP stays assigned across stops and restarts until the lab is destroyed.')
    else:
        print('This older lab uses an automatic public IP; restarting can change its HTTPS address.')
    if action == 'connect':
        result = subprocess.run(['aws', 'ssm', 'start-session', '--target', values['InstanceId'], '--region', REGION])
        if result.returncode:
            raise RuntimeError('SSM session failed; inspect SSM registration. The deletion deadline was not changed.')

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

"""Defer workload IAM until the GPU hold succeeds; keep protectors available."""
import copy as gpu_iam_copy


def defer_gpu_workload_iam(body):
    """Avoid creating an instance identity for an exhausted-capacity attempt.

    The cleanup/controller identities and schedules must precede the capacity
    request. Only the instance's SSM/S3 role and profile are deferred. A successful
    hold remains billable while these resources are created and propagated.
    """
    resources = body.get('Resources') if isinstance(body, dict) else None
    expected = {'Role': 'AWS::IAM::Role', 'Profile': 'AWS::IAM::InstanceProfile',
                'CapacityReservation': 'Custom::FortiAIGateCapacity'}
    if not isinstance(resources, dict) or any(
            not isinstance(resources.get(logical), dict)
            or resources[logical].get('Type') != kind
            for logical, kind in expected.items()):
        raise ValueError('Workload IAM deferral requires the expected role, profile and capacity selector.')
    result = gpu_iam_copy.deepcopy(body)
    for logical in ('Role', 'Profile'):
        resource = result['Resources'][logical]
        dependencies = resource.get('DependsOn', [])
        if isinstance(dependencies, str):
            dependencies = [dependencies]
        if (not isinstance(dependencies, list)
                or any(not isinstance(item, str) or item not in resources for item in dependencies)):
            raise ValueError('Workload IAM has invalid resource dependencies.')
        resource['DependsOn'] = list(dict.fromkeys(dependencies + ['CapacityReservation']))
    return result

"""Optional, read-only EC2 capacity signals for the local CloudShell user.

Capacity Manager must already be enabled in the selected region and the account
must have the required Unified Operations support entitlement. This module
never enables a service, launches a probe, reserves capacity, installs an SDK,
writes results to disk or sends results to this guide's website.
"""
import json as capacity_json
import os as capacity_os
import re as capacity_re
import subprocess as capacity_subprocess


class CapacityReadError(RuntimeError):
    pass


def capacity_read(operation, payload, region):
    """Bounded CLI call with an explicit region, separate from the lab region."""
    if operation not in ("get-capacity-manager-attributes", "get-capacity-manager-supportability-scores"):
        raise ValueError("Only read-only Capacity Manager operations are allowed.")
    if not capacity_re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region):
        raise ValueError("Invalid Capacity Manager region.")
    command = ["aws", "ec2", operation, "--region", region,
               "--output", "json", "--no-cli-pager", "--cli-connect-timeout", "5",
               "--cli-read-timeout", "10", "--cli-input-json", capacity_json.dumps(payload)]
    result = capacity_subprocess.run(command, text=True, capture_output=True, timeout=15)
    if result.returncode:
        # Old CLIs can print their complete command help here. Do not echo raw
        # responses or errors, which can contain account-specific information.
        raise CapacityReadError("Capacity Manager CLI request was unavailable.")
    try:
        response = capacity_json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise CapacityReadError("Capacity Manager did not return JSON.") from error
    if not isinstance(response, dict):
        raise CapacityReadError("Capacity Manager returned an unexpected response.")
    return response


def capacity_zone_ids(offered, zones):
    """Accept only a complete, unambiguous ID map for already supported zones."""
    if len(offered) > 10 or not isinstance(zones, list):
        raise CapacityReadError("Capacity Manager needs at most ten supported zones.")
    identifiers = {}
    for row in zones:
        if not isinstance(row, dict):
            raise CapacityReadError("Availability Zone metadata is malformed.")
        name = row.get("ZoneName")
        if name not in offered:
            continue
        zone_id = row.get("ZoneId")
        if (not isinstance(zone_id, str)
                or not capacity_re.fullmatch(r"[a-z0-9]+-az[1-9][0-9]*", zone_id)
                or (name in identifiers and identifiers[name] != zone_id)):
            raise CapacityReadError("Availability Zone IDs are missing or ambiguous.")
        identifiers[name] = zone_id
    if set(identifiers) != set(offered) or len(set(identifiers.values())) != len(identifiers):
        raise CapacityReadError("Supported zones do not have a complete unique ID map.")
    return identifiers


def capacity_parse_scores(response, expected_ids):
    """Unknown rows never silently become a zero-capacity result."""
    rows = response.get("CapacityManagerSupportabilityScores")
    if not isinstance(rows, list) or not rows:
        raise CapacityReadError("No usable per-zone scores were returned.")
    scores = {}
    for row in rows:
        if not isinstance(row, dict):
            raise CapacityReadError("Capacity score row is malformed.")
        zone_id, score = row.get("AvailabilityZoneId"), row.get("Score")
        if (row.get("InstanceType") != INSTANCE_TYPE or zone_id not in expected_ids
                or score not in ("high", "medium", "low")
                or (zone_id in scores and scores[zone_id] != score)):
            raise CapacityReadError("Capacity score identity or value is unexpected.")
        scores[zone_id] = score
    return scores


def rank_gpu_zones(offered, zones):
    """Prefer stronger signals while retaining every supported retry candidate.

    The API is optional: permissions, support-plan eligibility, an older CLI,
    region setup, transient errors or incomplete metadata must not be described
    as zero available GPUs. Successful results stay in the local terminal only.
    """
    original = list(offered)
    if (not original or any(not isinstance(name, str) or not capacity_re.fullmatch(
                capacity_re.escape(REGION)+r"[a-z]", name) for name in original)):
        raise ValueError("The supported GPU zone list is invalid.")
    if len(set(original)) != len(original):
        raise ValueError("The supported GPU zone list is ambiguous.")
    print("Supported GPU zones: " + ", ".join(original), flush=True)
    region = capacity_os.environ.get("FORTIAIGATE_CAPACITY_MANAGER_REGION", REGION).strip()
    try:
        if not capacity_re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region):
            raise CapacityReadError("Capacity Manager region override is invalid.")
        identifiers = capacity_zone_ids(original, zones)
        attributes = capacity_read("get-capacity-manager-attributes", {}, region)
        if attributes.get("CapacityManagerStatus") != "enabled":
            raise CapacityReadError("Capacity Manager is not enabled in the selected region.")
        response = capacity_read("get-capacity-manager-supportability-scores", {
            "MarketType": "on-demand", "CapacityAmount": 1, "CapacityUnit": "instances",
            "CapacityAvailabilityZoneIds": [identifiers[name] for name in original],
            "InstanceTypes": [INSTANCE_TYPE]}, region)
        scores = capacity_parse_scores(response, set(identifiers.values()))
    except (CapacityReadError, OSError, ValueError, TypeError, capacity_subprocess.TimeoutExpired):
        print("Capacity scoring unavailable in the selected region; support verified only, not live capacity.", flush=True)
        print("Scores require an up-to-date AWS CLI, permissions and Unified Operations support, with Capacity Manager already enabled. No settings were changed.", flush=True)
        return original
    priority = {"high": 0, "medium": 1, "unknown": 2, "low": 3}
    print("Current capacity signals (not reservations or a launch guarantee):", flush=True)
    for name in original:
        print("  " + name + ": " + scores.get(identifiers[name], "unknown"), flush=True)
    ordered = sorted(original, key=lambda name: priority[scores.get(identifiers[name], "unknown")])
    print("Preferred Auto order: " + ", ".join(ordered), flush=True)
    return ordered

"""AWS GPU zone selection helpers, embedded into the reviewed creator."""
import copy as placement_copy


def choose_availability_zone(offered):
    """None tries a targeted reservation across all supported zones."""
    print("Offered zones: " + ", ".join(offered) + " (an offering does not guarantee current capacity)")
    print("Auto chooses only supported GPU zones; capacity is not guaranteed.")
    print("Auto tries a ONE-GPU targeted capacity hold in each zone until one succeeds.")
    print("The hold starts On-Demand billing immediately; it is cancelled after your VM launches.")
    selection = input("Availability Zone [auto]: ").strip().lower() or "auto"
    if selection == "auto":
        return None
    if selection not in offered:
        raise ValueError("Choose auto or one of the offered zones above.")
    return selection


def availability_zone_label(zone):
    return zone if zone else "auto (reserve one GPU in a supported zone)"


def apply_availability_zone_selection(body, zone):
    """Set the subnet zone and let the instance inherit it.

    An unselected approval template may omit the zone. The attempt loop always
    supplies a validated supported zone before submitting CreateStack.
    """
    result = placement_copy.deepcopy(body)
    subnet = result["Resources"]["Subnet"]["Properties"]
    instance = result["Resources"]["Instance"]["Properties"]
    subnet.pop("AvailabilityZoneId", None)
    instance.pop("AvailabilityZone", None)
    if zone:
        subnet["AvailabilityZone"] = zone
    else:
        subnet.pop("AvailabilityZone", None)
    result.setdefault("Outputs", {})["AvailabilityZone"] = {
        "Value": {"Fn::GetAtt": ["Subnet", "AvailabilityZone"]}}
    return result

"""Embeddable shared GPU cleanup service. Building this module makes no API calls.

The generated CloudShell scripts supply aws(), AwsError and REGION. This service
uses a different execution role from the per-lab cleanup role it removes.
"""
import json as janitor_json
import re as janitor_re
import time as janitor_time

JANITOR_STACK = "FortiAIGate-GPU-AutoCleanup"
JANITOR_MARKER = "FortiAIGate-GPU-Janitor-v1"
JANITOR_VERSION = "2"
JANITOR_SUPPORTED_VERSIONS = ("1", JANITOR_VERSION)
JANITOR_EXPORT = "FortiAIGate-GPU-AutoCleanup-FunctionArn"
JANITOR_LAB_MARKER = "FortiAIGate-GPU-AWS-v1"
JANITOR_BUDGET_VERSION = "8h-delete-v2"
JANITOR_BUDGET_VERSIONS = ("2h-stop-12h-delete-v1", JANITOR_BUDGET_VERSION)
JANITOR_ROLE_SUFFIX = "_FortiAIGate_GPU_CleanupRole"

JANITOR_LAMBDA = r'''import boto3,json,os,random,re
iam=boto3.client("iam")
cfn=boto3.client("cloudformation",region_name=os.environ["REGION"])
ACCOUNT=os.environ["ACCOUNT_ID"]
REGION=os.environ["REGION"]
PARTITION=os.environ["PARTITION"]
MARKER="FortiAIGate-GPU-AWS-v1"
VERSIONS=("2h-stop-12h-delete-v1","8h-delete-v2")
SUFFIX="_FortiAIGate_GPU_CleanupRole"

def code(error):
    return getattr(error,"response",{}).get("Error",{}).get("Code","")

def pages(client,operation,key,**kwargs):
    request=dict(kwargs)
    for _ in range(1000):
        page=getattr(client,operation)(**request)
        for item in page.get(key,[]): yield item
        if not page.get("IsTruncated"): return
        marker=page.get("Marker")
        if not marker or marker==request.get("Marker"):
            raise RuntimeError("IAM pagination did not advance")
        request["Marker"]=marker
    raise RuntimeError("IAM pagination exceeded its safety limit")

def owned(role):
    name=role.get("RoleName","")
    match=re.fullmatch(r"([A-Za-z][A-Za-z0-9]{0,23})"+re.escape(SUFFIX),name)
    if not match: return None
    tags={t["Key"]:t["Value"] for t in role.get("Tags",[])}
    if tags.get("DeploymentGuide")!=MARKER or tags.get("BudgetVersion") not in VERSIONS: return None
    prefix=match.group(1).lower()
    if (not role.get("RoleId") or tags.get("UserPrefix")!=prefix
            or role.get("Arn")!="arn:"+PARTITION+":iam::"+ACCOUNT+":role/"+name):
        raise ValueError("Cleanup role identity disagrees with its ownership tags")
    stack_id=tags.get("BudgetStack","")
    expected="arn:"+PARTITION+":cloudformation:"+REGION+":"+ACCOUNT+":stack/FortiAIGate-GPU-"+prefix+"/"
    if not re.fullmatch(re.escape(expected)+r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",stack_id):
        raise ValueError("Cleanup role has an invalid original lab stack ARN")
    return prefix,stack_id

def stack_gone(prefix,stack_id):
    try:
        result=cfn.describe_stacks(StackName=stack_id)
    except Exception as error:
        message=getattr(error,"response",{}).get("Error",{}).get("Message","")
        if code(error)=="ValidationError" and "does not exist" in message.lower(): return True
        raise
    stacks=result.get("Stacks",[])
    if len(stacks)!=1: raise ValueError("Expected one original lab stack")
    stack=stacks[0]
    tags={t["Key"]:t["Value"] for t in stack.get("Tags",[])}
    if (stack.get("StackId")!=stack_id or stack.get("StackName")!="FortiAIGate-GPU-"+prefix
            or tags.get("DeploymentGuide")!=MARKER or tags.get("UserPrefix")!=prefix):
        raise ValueError("Original lab stack ownership could not be verified")
    return stack.get("StackStatus")=="DELETE_COMPLETE"

def cleanup(name):
    try: role=iam.get_role(RoleName=name)["Role"]
    except Exception as error:
        if code(error)=="NoSuchEntity": return "already-gone"
        raise
    target=owned(role)
    if not target: return "unowned"
    prefix,stack_id=target
    if not stack_gone(prefix,stack_id): return "stack-still-exists"
    policies=list(pages(iam,"list_role_policies","PolicyNames",RoleName=name))
    attached=list(pages(iam,"list_attached_role_policies","AttachedPolicies",RoleName=name))
    profiles=list(pages(iam,"list_instance_profiles_for_role","InstanceProfiles",RoleName=name))
    if attached or profiles or set(policies)-{"DeleteOnlyThisLab"}:
        raise ValueError("Cleanup role was modified or reused")
    if policies:
        policy=iam.get_role_policy(RoleName=name,PolicyName="DeleteOnlyThisLab")
        document=policy.get("PolicyDocument",{})
        if isinstance(document,str): document=json.loads(document)
        statements=document.get("Statement",[])
        if isinstance(statements,dict): statements=[statements]
        # Known cleanup policies scope EC2 mutations to this original stack.
        # Refuse a repurposed policy, even if its old name and tags were kept.
        if not any(isinstance(s,dict) and s.get("Condition",{}).get("StringEquals",{}).get(
                "ec2:ResourceTag/FortiAIGateBudgetStack")==stack_id for s in statements):
            raise ValueError("Cleanup policy no longer identifies the original lab")
    # Re-read authoritative ownership immediately before mutating it. Another
    # janitor invocation or authenticated Destroy can safely race these calls.
    latest=iam.get_role(RoleName=name)["Role"]
    if owned(latest)!=target or latest.get("RoleId")!=role.get("RoleId"):
        raise ValueError("Cleanup role ownership changed")
    if not stack_gone(prefix,stack_id): return "stack-still-exists"
    if policies:
        try: iam.delete_role_policy(RoleName=name,PolicyName="DeleteOnlyThisLab")
        except Exception as error:
            if code(error)!="NoSuchEntity": raise
    try: iam.delete_role(RoleName=name)
    except Exception as error:
        if code(error)!="NoSuchEntity": raise
    return "removed"

def handler(event,context):
    counts={}
    failed=0
    candidates=[]
    for item in pages(iam,"list_roles","Roles",MaxItems=1000):
        name=item.get("RoleName","")
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9]{0,23}"+re.escape(SUFFIX),name): candidates.append(name)
    # Different ordering each tick prevents a large number of slow/active roles
    # at the beginning of IAM's list from starving later retired cleanup roles.
    random.shuffle(candidates)
    for name in candidates:
        if context and context.get_remaining_time_in_millis()<15000:
            raise RuntimeError("Cleanup deferred; the next scheduled invocation will retry")
        try:
            result=cleanup(name)
            counts[result]=counts.get(result,0)+1
        except ValueError:
            counts["rejected-modified-role"]=counts.get("rejected-modified-role",0)+1
        except Exception as error:
            if code(error)=="NoSuchEntity":
                counts["already-gone"]=counts.get("already-gone",0)+1
            else:
                failed+=1
                print("Deferred a cleanup role; AWS error code:",code(error) or type(error).__name__)
    print(json.dumps({"cleanup_results":counts,"deferred_errors":failed},sort_keys=True))
    if failed: raise RuntimeError("Some cleanup roles were deferred; scheduled retries remain enabled")
    return counts
'''


def janitor_template():
    """Return the shared, non-VM management stack; no account/API lookup."""
    sub = lambda value: {"Fn::Sub": value}
    get = lambda logical: {"Fn::GetAtt": [logical, "Arn"]}
    cleanup_roles = sub("arn:${AWS::Partition}:iam::${AWS::AccountId}:role/*_FortiAIGate_GPU_CleanupRole")
    log_name = "/aws/lambda/FortiAIGate_GPU_AutoCleanup"
    return {
        "AWSTemplateFormatVersion": "2010-09-09",
        "Description": "Shared FortiAIGate GPU janitor; removes retired per-lab cleanup roles after stack deletion",
        "Resources": {
            "Logs": {"Type": "AWS::Logs::LogGroup", "Properties": {
                "LogGroupName": log_name, "RetentionInDays": 1}},
            "Role": {"Type": "AWS::IAM::Role", "Properties": {
                "RoleName": "FortiAIGate_GPU_AutoCleanup_Role",
                "Tags": [{"Key": "DeploymentGuide", "Value": JANITOR_MARKER}],
                "AssumeRolePolicyDocument": {"Version": "2012-10-17", "Statement": [{
                    "Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]},
                "Policies": [{"PolicyName": "RemoveOnlyRetiredGPUCleanupRoles", "PolicyDocument": {
                    "Version": "2012-10-17", "Statement": [
                        {"Effect": "Allow", "Action": "iam:ListRoles", "Resource": "*"},
                        {"Effect": "Allow", "Action": ["iam:GetRole", "iam:ListRolePolicies", "iam:GetRolePolicy",
                            "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"], "Resource": cleanup_roles},
                        {"Effect": "Allow", "Action": ["iam:DeleteRolePolicy", "iam:DeleteRole"], "Resource": cleanup_roles,
                         "Condition": {"StringEquals": {"aws:ResourceTag/DeploymentGuide": JANITOR_LAB_MARKER,
                            "aws:ResourceTag/BudgetVersion": list(JANITOR_BUDGET_VERSIONS)}}},
                        {"Effect": "Allow", "Action": "cloudformation:DescribeStacks",
                         "Resource": sub("arn:${AWS::Partition}:cloudformation:us-east-1:${AWS::AccountId}:stack/FortiAIGate-GPU-*/*")},
                        {"Effect": "Allow", "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
                         "Resource": sub("arn:${AWS::Partition}:logs:us-east-1:${AWS::AccountId}:log-group:"+log_name+":*")}
                    ]}}]}},
            "Function": {"Type": "AWS::Lambda::Function", "DependsOn": "Logs", "Properties": {
                "FunctionName": "FortiAIGate_GPU_AutoCleanup", "Runtime": "python3.13", "Handler": "index.handler",
                "Role": get("Role"), "Timeout": 120, "MemorySize": 128,
                "Environment": {"Variables": {"ACCOUNT_ID": {"Ref": "AWS::AccountId"}, "REGION": "us-east-1",
                                               "PARTITION": {"Ref": "AWS::Partition"}}},
                "Code": {"ZipFile": JANITOR_LAMBDA}}},
            "Rule": {"Type": "AWS::Events::Rule", "Properties": {
                "Name": "FortiAIGate_GPU_AutoCleanup", "ScheduleExpression": "rate(5 minutes)", "State": "ENABLED",
                "Targets": [{"Id": "RetiredCleanupRoles", "Arn": get("Function")}]}},
            "Permission": {"Type": "AWS::Lambda::Permission", "Properties": {
                "FunctionName": {"Ref": "Function"}, "Action": "lambda:InvokeFunction", "Principal": "events.amazonaws.com",
                "SourceArn": get("Rule"), "SourceAccount": {"Ref": "AWS::AccountId"}}}
        },
        "Outputs": {"JanitorVersion": {"Value": JANITOR_VERSION}, "JanitorFunction": {"Value": {"Ref": "Function"}},
            "JanitorFunctionArn": {"Value": get("Function"), "Export": {"Name": JANITOR_EXPORT}}}
    }


def _janitor_account():
    if REGION != "us-east-1":
        raise RuntimeError("The shared GPU cleanup service is managed only in us-east-1.")
    caller = aws("sts", "get-caller-identity")
    if not janitor_re.fullmatch(r"[0-9]{12}", caller.get("Account", "")):
        raise RuntimeError("AWS account identity could not be established.")
    return caller["Account"]


def _janitor_describe(account):
    try:
        stacks = aws("cloudformation", "describe-stacks", StackName=JANITOR_STACK).get("Stacks", [])
    except AwsError as error:
        if "ValidationError" in str(error) and "does not exist" in str(error): return None
        raise
    if len(stacks) != 1:
        raise RuntimeError("Expected exactly one shared cleanup stack.")
    stack = stacks[0]
    tags = {t["Key"]: t["Value"] for t in stack.get("Tags", [])}
    outputs = {item["OutputKey"]: item["OutputValue"] for item in stack.get("Outputs", [])}
    if (stack.get("StackName") != JANITOR_STACK or tags.get("DeploymentGuide") != JANITOR_MARKER
            or tags.get("JanitorVersion") not in JANITOR_SUPPORTED_VERSIONS
            or (not stack.get("StackStatus", "").endswith("_IN_PROGRESS")
                and outputs.get("JanitorVersion") != tags.get("JanitorVersion"))
            or not janitor_re.fullmatch(r"arn:aws:cloudformation:us-east-1:"+account+":stack/"+JANITOR_STACK+r"/[0-9a-f-]{36}", stack.get("StackId", ""))):
        raise RuntimeError("The shared cleanup stack name is already in use or ownership could not be verified.")
    return stack


def _janitor_wait(account, deleting=False, upgrading=False):
    started = janitor_time.monotonic()
    while janitor_time.monotonic()-started < 600:
        stack = _janitor_describe(account)
        state = stack.get("StackStatus") if stack else "NOT_FOUND"
        if deleting and state in ("NOT_FOUND", "DELETE_COMPLETE"):
            print("Shared GPU cleanup service removed.", flush=True)
            return None
        if not deleting and state in ("CREATE_COMPLETE", "UPDATE_COMPLETE"):
            tags = {t["Key"]: t["Value"] for t in stack.get("Tags", [])}
            outputs = {item["OutputKey"]: item["OutputValue"] for item in stack.get("Outputs", [])}
            if tags.get("JanitorVersion") != JANITOR_VERSION or outputs.get("JanitorVersion") != JANITOR_VERSION:
                if upgrading and tags.get("JanitorVersion") == outputs.get("JanitorVersion") == "1":
                    # The first DescribeStacks after UpdateStack may still show
                    # the old completed version. Wait for v2, never reuse v1.
                    state = "WAITING_FOR_UPGRADE"
                else:
                    raise RuntimeError("Shared GPU cleanup service upgrade was not verified. No GPU lab was started.")
            else:
                print("Shared GPU cleanup service ready; retired lab roles are checked every 5 minutes.", flush=True)
                return stack
        if state in ("NOT_FOUND", "DELETE_COMPLETE") or state.endswith("_FAILED") or "ROLLBACK" in state:
            raise RuntimeError("Shared GPU cleanup service is not ready: "+state+". Inspect its CloudFormation events before creating a lab.")
        print("Shared cleanup service: "+state+"   |   Elapsed: "+str(int(janitor_time.monotonic()-started))+"s", flush=True)
        janitor_time.sleep(15)
    raise RuntimeError("Shared GPU cleanup service did not finish within 10 minutes. No GPU lab was started by this setup step.")


def ensure_gpu_janitor():
    """Call after Create approval, before the lab stack/instance is created."""
    account = _janitor_account()
    existing = _janitor_describe(account)
    if existing:
        if existing.get("StackStatus") not in ("CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE"):
            raise RuntimeError("Shared cleanup service is busy or failed: "+existing.get("StackStatus", "unknown")+". Wait for it or inspect its events.")
        tags = {t["Key"]: t["Value"] for t in existing.get("Tags", [])}
        if tags["JanitorVersion"] != JANITOR_VERSION:
            # New labs need the v2 janitor policy and Lambda. Upgrade only the
            # verified shared stack; v2 retains cleanup support for old labs.
            print("Updating the shared cleanup service for eight-hour labs; existing lab timers are unchanged...", flush=True)
            tags["JanitorVersion"] = JANITOR_VERSION
            aws("cloudformation", "update-stack", StackName=existing["StackId"],
                TemplateBody=janitor_json.dumps(janitor_template()), Capabilities=["CAPABILITY_NAMED_IAM"],
                Tags=[{"Key": k, "Value": v} for k, v in tags.items()])
            return _janitor_wait(account, upgrading=True)
        print("Shared GPU cleanup service verified and ready.", flush=True)
        return existing
    print("Preparing the shared cleanup service before starting the GPU lab...", flush=True)
    aws("cloudformation", "create-stack", StackName=JANITOR_STACK,
        TemplateBody=janitor_json.dumps(janitor_template()), Capabilities=["CAPABILITY_NAMED_IAM"],
        Tags=[{"Key": "DeploymentGuide", "Value": JANITOR_MARKER}, {"Key": "JanitorVersion", "Value": JANITOR_VERSION}])
    return _janitor_wait(account)


def _janitor_cli_pages(service, operation, key, **payload):
    request = dict(payload)
    previous = None
    for _ in range(1000):
        page = aws(service, operation, **request)
        for item in page.get(key, []): yield item
        token = page.get("NextToken") if service == "cloudformation" else page.get("Marker") if page.get("IsTruncated") else None
        if not token: return
        if token == previous: raise RuntimeError("Cleanup safety inventory pagination did not advance.")
        request["NextToken" if service == "cloudformation" else "Marker"] = token
        previous = token
    raise RuntimeError("Cleanup safety inventory exceeded its pagination limit.")


def remove_gpu_janitor():
    """Authenticated opt-in removal; refuses while labs/retired roles need it."""
    account = _janitor_account()
    foundation = _janitor_describe(account)
    if not foundation or foundation.get("StackStatus") == "DELETE_COMPLETE":
        print("No shared GPU cleanup service exists in this account and region.")
        return
    for summary in _janitor_cli_pages("cloudformation", "list-stacks", "StackSummaries"):
        if summary.get("StackStatus") == "DELETE_COMPLETE" or not janitor_re.fullmatch(
                r"FortiAIGate-GPU-[a-z][a-z0-9]{0,23}", summary.get("StackName", "")):
            continue
        stack = aws("cloudformation", "describe-stacks", StackName=summary["StackId"])["Stacks"][0]
        tags = {t["Key"]: t["Value"] for t in stack.get("Tags", [])}
        if tags.get("DeploymentGuide") == JANITOR_LAB_MARKER and stack.get("StackStatus") != "DELETE_COMPLETE":
            raise RuntimeError("A GPU lab still exists or is deleting. Keep the shared cleanup service until all GPU labs are gone.")
    for item in _janitor_cli_pages("iam", "list-roles", "Roles"):
        name = item.get("RoleName", "")
        if not janitor_re.fullmatch(r"[A-Za-z][A-Za-z0-9]{0,23}"+janitor_re.escape(JANITOR_ROLE_SUFFIX), name): continue
        try:
            role = aws("iam", "get-role", RoleName=name)["Role"]
        except AwsError as error:
            if "NoSuchEntity" in str(error): continue
            raise
        tags = {t["Key"]: t["Value"] for t in role.get("Tags", [])}
        if tags.get("DeploymentGuide") == JANITOR_LAB_MARKER:
            raise RuntimeError("A per-lab cleanup role remains. Wait for automatic cleanup or run that lab's Destroy before removing the shared service.")
    if foundation.get("StackStatus") != "DELETE_IN_PROGRESS":
        print("No GPU labs or owned cleanup roles remain. Removing the shared cleanup service...", flush=True)
        # The interactive caller supplies the deletion authority. This service
        # deliberately does not try to revoke its own last IAM permissions.
        aws("cloudformation", "delete-stack", StackName=foundation["StackId"])
    return _janitor_wait(account, deleting=True)

"""Stack-owned persistent IPv4; gate network preparation on its association."""
import copy as elastic_copy
import re as elastic_re


# Ubuntu supplies Python before cloud-init user data runs. IMDS calls never use
# an HTTP proxy, credentials, AWS CLI or packages fetched from the network.
ELASTIC_IP_BOOTSTRAP = '''import ipaddress,sys,time,urllib.request
expected=str(ipaddress.IPv4Address(sys.argv[1]))
client=urllib.request.build_opener(urllib.request.ProxyHandler({}))
started=time.monotonic();deadline=started+600;notice=started
print("Waiting for the allocated Elastic IP before downloads...",flush=True)
while time.monotonic()<deadline:
    try:
        req=urllib.request.Request("http://169.254.169.254/latest/api/token",method="PUT",headers={"X-aws-ec2-metadata-token-ttl-seconds":"60"})
        with client.open(req,timeout=3) as response: token=response.read().decode("ascii").strip()
        req=urllib.request.Request("http://169.254.169.254/latest/meta-data/public-ipv4",headers={"X-aws-ec2-metadata-token":token})
        with client.open(req,timeout=3) as response: actual=response.read().decode("ascii").strip()
        if str(ipaddress.IPv4Address(actual))==expected:
            print("PASS: Elastic IP "+expected+" is associated; continuing preparation.",flush=True)
            break
    except (OSError,ValueError): pass
    if time.monotonic()>=notice:
        print("Waiting for Elastic IP association ("+str(int(time.monotonic()-started))+"s elapsed)...",flush=True)
        notice=time.monotonic()+30
    time.sleep(3)
else: sys.exit("STOP: Elastic IP association was not confirmed within 10 minutes; no downloads started.")
'''


def add_gpu_elastic_ip(body, prefix):
    """Add one address without replacing native instance/network ownership."""
    if not isinstance(prefix, str) or not elastic_re.fullmatch(r'[A-Za-z][A-Za-z0-9]{0,23}', prefix):
        raise ValueError('Elastic IP naming requires the validated lab username.')
    result = elastic_copy.deepcopy(body)
    resources = result['Resources']
    if any(key in resources for key in ('ElasticIp', 'ElasticIpAssociation')):
        raise ValueError('Elastic IP resources already exist; do not transform a lab twice.')
    required = ('Vpc', 'Subnet', 'Instance', 'GatewayAttachment', 'BudgetCleanupRole',
                'BudgetDeleteSchedule', 'BudgetWatchdogSchedule')
    if any(key not in resources for key in required):
        raise ValueError('Elastic IP setup requires the protected new GPU lab template.')
    instance = resources['Instance']
    props = instance['Properties']
    tags = {tag['Key']: tag['Value'] for tag in props['Tags']}
    ref = lambda name: {'Ref': name}
    if (instance['Type'] != 'AWS::EC2::Instance' or 'NetworkInterfaces' in props
            or props.get('SubnetId') != ref('Subnet')
            or tags.get('BudgetVersion') != '8h-delete-v2'
            or tags.get('FortiAIGateBudgetStack') != ref('AWS::StackId')
            or tags.get('BudgetStack') != ref('AWS::StackId')):
        raise ValueError('Elastic IP setup requires native instance and verified lifecycle ownership.')
    original = props.get('UserData', {}).get('Fn::Base64')
    anchor = 'if ! command -v curl >/dev/null 2>&1; then\n'
    if not isinstance(original, str) or original.count(anchor) != 1:
        raise ValueError('The preparation bootstrap changed; cannot place the Elastic IP wait safely.')
    before, after = original.split(anchor, 1)
    # The existing prelude configures error trapping/logs before this wait. Do
    # not use Fn::Sub: the original shell contains ${...} shell expressions.
    props['UserData'] = {'Fn::Base64': {'Fn::Join': ['', [before,
        "printf 'waiting for the allocated Elastic IP before downloads\\n' > /var/lib/fortiaigate-prep/GPU_RUNNING\npython3 - '",
        ref('ElasticIp'), "' <<'FORTIAIGATE_ELASTIC_IP'\n" + ELASTIC_IP_BOOTSTRAP +
        "FORTIAIGATE_ELASTIC_IP\nprintf 'downloading the reviewed GPU preparation script\\n' > /var/lib/fortiaigate-prep/GPU_RUNNING\n",
        anchor + after]]}}
    props['Tags'].append({'Key': 'PublicIpMode', 'Value': 'elastic'})
    # Preserve reservation.py's top-level fixed private IP. Disabling subnet
    # auto-addressing avoids a temporary public IP before the EIP is attached.
    resources['Subnet']['Properties']['MapPublicIpOnLaunch'] = False
    resources['ElasticIp'] = {'Type': 'AWS::EC2::EIP',
        'DependsOn': ['GatewayAttachment', 'BudgetCleanupRole'], 'Properties': {
            'Domain': 'vpc', 'Tags': [
                {'Key': 'Name', 'Value': prefix + '_FortiAIGate_GPU_Elastic_IP'},
                {'Key': 'FortiAIGateBudgetStack', 'Value': ref('AWS::StackId')},
                {'Key': 'DeploymentGuide', 'Value': 'FortiAIGate-GPU-AWS-v1'}]}}
    resources['ElasticIpAssociation'] = {'Type': 'AWS::EC2::EIPAssociation',
        'DependsOn': ['GatewayAttachment', 'BudgetCleanupRole'], 'Properties': {
            'AllocationId': {'Fn::GetAtt': ['ElasticIp', 'AllocationId']},
            'InstanceId': ref('Instance')}}
    result.setdefault('Outputs', {}).update({
        'ElasticIpAllocationId': {'Value': {'Fn::GetAtt': ['ElasticIp', 'AllocationId']}},
        'PublicIPv4': {'Value': ref('ElasticIp')},
        'HttpsURL': {'Value': {'Fn::Join': ['', ['https://', ref('ElasticIp'), '/ui']]}}})
    policies = resources['BudgetCleanupRole']['Properties']['Policies']
    cleanup = [p for p in policies if p.get('PolicyName') == 'DeleteOnlyThisLab']
    if len(cleanup) != 1:
        raise ValueError('The per-lab cleanup policy could not be identified.')
    for scope in ({'ec2:ResourceTag/FortiAIGateBudgetStack': ref('AWS::StackId')},
                  {'ec2:ResourceTag/DeploymentGuide': 'FortiAIGate-Ollama-AWS-v1',
                   'ec2:ResourceTag/FortiAIGateVpcId': ref('Vpc')}):
        cleanup[0]['PolicyDocument']['Statement'].append({
            'Effect': 'Allow', 'Action': ['ec2:DisassociateAddress', 'ec2:ReleaseAddress'],
            'Resource': {'Fn::Sub': 'arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:elastic-ip/*'},
            'Condition': {'StringEquals': scope}})
    return result

"""Keep inline Lambda code readable while fitting CloudFormation TemplateBody."""
import ast as compact_ast
import copy as compact_copy
import io as compact_io
import re as compact_re
import tokenize as compact_tokens


def _gpu_code_tokens(source):
    return list(compact_tokens.generate_tokens(compact_io.StringIO(source).readline))


def _gpu_literal_tokens(tokens):
    return [(token.type, token.string) for token in tokens
            if 'STRING' in compact_tokens.tok_name.get(token.type, '')]


def _gpu_string_lines(tokens):
    """Never adjust whitespace that is part of a multiline string literal."""
    protected = set()
    fstrings = []
    for token in tokens:
        kind = compact_tokens.tok_name.get(token.type, '')
        if kind in ('FSTRING_START', 'TSTRING_START'):
            fstrings.append(token.start[0])
        elif kind in ('FSTRING_END', 'TSTRING_END') and fstrings:
            protected.update(range(fstrings.pop() + 1, token.end[0] + 1))
        if token.type == compact_tokens.STRING or 'STRING_MIDDLE' in kind:
            protected.update(range(token.start[0] + 1, token.end[0] + 1))
    return protected


def _compact_gpu_python(source):
    """Remove comments/blank lines and reduce block indentation, not code."""
    original_ast = compact_ast.dump(compact_ast.parse(source, type_comments=True), include_attributes=False)
    original_tokens = _gpu_code_tokens(source)
    lines = source.splitlines(keepends=True)
    protected = _gpu_string_lines(original_tokens)
    # Type comments are meaningful AST content. Preserve their lines and all
    # line numbers when TypeIgnore is present (lineno is an AST field there).
    keep_line_numbers = any(token.type == compact_tokens.COMMENT and
        compact_re.match(r'#\s*type:\s*ignore', token.string) for token in original_tokens)
    for token in original_tokens:
        if token.type == compact_tokens.COMMENT and not compact_re.match(r'#\s*type:', token.string):
            row, start = token.start
            _, end = token.end
            lines[row - 1] = lines[row - 1][:start] + lines[row - 1][end:]
    source_without_comments = ''.join(line for row, line in enumerate(lines, 1)
        if keep_line_numbers or row in protected or line.strip())
    tokens = _gpu_code_tokens(source_without_comments)
    protected = _gpu_string_lines(tokens)
    # INDENT/DEDENT describe logical blocks, unlike physical leading spaces in
    # continued expressions. Continuations may also use the current block level.
    depth = 0
    levels = {}
    ignored = {compact_tokens.NL, compact_tokens.NEWLINE, compact_tokens.ENDMARKER, compact_tokens.COMMENT}
    for token in tokens:
        if token.type == compact_tokens.INDENT:
            depth += 1
        elif token.type == compact_tokens.DEDENT:
            depth -= 1
        elif token.type not in ignored:
            levels.setdefault(token.start[0], depth)
    compacted = []
    for row, line in enumerate(source_without_comments.splitlines(keepends=True), 1):
        if row in levels and row not in protected:
            line = ' ' * levels[row] + line.lstrip(' \t\f')
        compacted.append(line)
    candidate = ''.join(compacted)
    # Both checks are deliberate: an identical AST proves behavior is retained,
    # while literal-token equality forbids rewriting string spelling/content.
    if compact_ast.dump(compact_ast.parse(candidate, type_comments=True), include_attributes=False) != original_ast:
        raise ValueError('Inline Lambda compaction changed the Python AST.')
    if _gpu_literal_tokens(_gpu_code_tokens(candidate)) != _gpu_literal_tokens(original_tokens):
        raise ValueError('Inline Lambda compaction changed a string literal.')
    return candidate


def compact_gpu_template(body):
    """Copy a template and compact only inline Python Lambda ZipFile values."""
    result = compact_copy.deepcopy(body)
    for resource in result.get('Resources', {}).values():
        if resource.get('Type') != 'AWS::Lambda::Function':
            continue
        properties = resource.get('Properties', {})
        if not str(properties.get('Runtime', '')).startswith('python'):
            continue
        code = properties.get('Code', {})
        if 'ZipFile' not in code:
            continue
        if not isinstance(code['ZipFile'], str):
            raise ValueError('Inline Python Lambda source must be a literal string before compaction.')
        code['ZipFile'] = _compact_gpu_python(code['ZipFile'])
    return result


def browser_ipv4(caller_arn):
    """Use only a unique, recent browser event belonging to this caller."""
    import datetime as browser_dt
    now = browser_dt.datetime.now(browser_dt.timezone.utc)
    cutoff = now - browser_dt.timedelta(minutes=30)
    try:
        data = aws("cloudtrail", "lookup-events", "--max-items", "100", process_timeout=25,
            LookupAttributes=[{"AttributeKey": "EventSource", "AttributeValue": "cloudshell.amazonaws.com"}],
            StartTime=cutoff.isoformat(), EndTime=now.isoformat())
    except (AwsError, OSError, subprocess.TimeoutExpired):
        return None
    if data.get("NextToken"): return None
    addresses = set()
    for item in data.get("Events", []):
        try:
            event = json.loads(item["CloudTrailEvent"])
            if (event.get("eventSource") != "cloudshell.amazonaws.com"
                    or event.get("userIdentity", {}).get("arn") != caller_arn
                    or not event.get("userAgent", "").startswith("Mozilla/") or event.get("errorCode")):
                continue
            stamp = browser_dt.datetime.fromisoformat(event["eventTime"].replace("Z", "+00:00"))
            if not cutoff <= stamp <= now: continue
            address = ipaddress.ip_address(event["sourceIPAddress"])
            if address.version == 4 and address.is_global and not address.is_multicast:
                addresses.add(str(address))
        except (KeyError, ValueError, TypeError):
            continue
    return addresses.pop() if len(addresses) == 1 else None


def request_browser_ipv4(caller_arn):
    detected = browser_ipv4(caller_arn)
    link = "https://checkip.amazonaws.com"
    if sys.stdout.isatty(): link = "\033[94;4m" + link + "\033[0m"
    print("Browser public IPv4: open " + link + " in YOUR computer's browser if needed.")
    prompt = "Your browser public IPv4 for HTTPS (with or without /32)"
    if detected:
        print("Detected from your recent CloudShell browser session: " + detected)
        prompt += " [" + detected + "]"
    return ipv4_cidr(input(prompt + ": ").strip() or detected or "")


DISPLAY_PREFIX = None
_budget_original_template = template

def template(prefix, *args, **kwargs):
    display = DISPLAY_PREFIX if DISPLAY_PREFIX and DISPLAY_PREFIX.casefold() == prefix.casefold() else prefix
    zone = args[3] if len(args) > 3 else kwargs.get("zone")
    body = apply_availability_zone_selection(add_gpu_elastic_ip(add_aws_budget(_budget_original_template(display, *args, **kwargs), display), display), zone)
    # Deliberate cross-stack import: CloudFormation must reject deletion of the
    # shared service while a lab still depends on its final-cleanup authority.
    body['Outputs']['FinalCleanupService'] = {'Value': {'Fn::ImportValue': JANITOR_EXPORT}}
    return body

"""CloudShell progress for the AWS GPU lab. Embed after the base creator."""
import datetime as gpu_datetime
import ipaddress as gpu_ipaddress
import math as gpu_math

GPU_PROGRESS_STARTED = None
GPU_CREATION_TIMER = False
GPU_RESOURCE_TOTAL = None
GPU_HOST_READY = False

GPU_STATUS_PROBE = r'''#!/bin/sh
python3 - <<'FORTI_GPU_STATUS'
import datetime,json,os,subprocess
from pathlib import Path
state=Path('/var/lib/fortiaigate-prep')
helper=Path('/usr/local/bin/fortiaigate-gpu-progress')
snapshot=None
if helper.is_file() and os.access(helper,os.X_OK):
    try:
        result=subprocess.run([str(helper)],capture_output=True,text=True,timeout=10)
        if result.returncode==0:
            item=json.loads(result.stdout)
            if isinstance(item,dict): snapshot=item
    except (OSError,ValueError,subprocess.TimeoutExpired):
        pass
def read(name):
    try:return (state/name).read_text()[:240].strip()
    except FileNotFoundError:return ''
if snapshot is None:
    stage=read('GPU_RUNNING') or read('RUNNING') or 'waiting for first-boot preparation to start'
    snapshot={'status':'running' if (state/'GPU_RUNNING').is_file() or (state/'RUNNING').is_file() else 'pending',
              'stage':stage,'percent':1,'download':None,'started_at':None}
failed=(state/'GPU_FAILED').is_file() or (state/'FAILED').is_file()
ready=(state/'GPU_READY').is_file()
if failed:
    snapshot.update(status='failed',stage=read('GPU_FAILED') or read('FAILED') or 'GPU preparation failed',percent=0)
elif ready:
    snapshot.update(status='ready',stage='GPU host preparation completed',percent=100)
else:
    if snapshot.get('status')=='ready':snapshot['status']='running'
    value=snapshot.get('percent',1)
    snapshot['percent']=min(99,max(1,value)) if isinstance(value,(int,float)) else 1
snapshot['gpu_ready']=bool(ready and not failed)
if ready and not failed:
    try:snapshot['completed_at']=datetime.datetime.fromtimestamp((state/'GPU_READY').stat().st_mtime,datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')
    except FileNotFoundError:
        snapshot.update(status='running',percent=99,gpu_ready=False)
if (state/'GPU_FAILED').is_file() or (state/'FAILED').is_file():
    snapshot.update(status='failed',stage=read('GPU_FAILED') or read('FAILED') or 'GPU preparation failed',percent=0,gpu_ready=False)
print(json.dumps(snapshot,allow_nan=False))
FORTI_GPU_STATUS
'''


def start_progress_timer(total_resources=None):
    """Call after confirmation, immediately before billable stack creation."""
    global GPU_PROGRESS_STARTED, GPU_CREATION_TIMER, GPU_RESOURCE_TOTAL
    GPU_PROGRESS_STARTED = time.monotonic()
    GPU_CREATION_TIMER = True
    GPU_RESOURCE_TOTAL = total_resources if isinstance(total_resources, int) and total_resources > 0 else None


def gpu_ensure_timer():
    global GPU_PROGRESS_STARTED
    if GPU_PROGRESS_STARTED is None:
        GPU_PROGRESS_STARTED = time.monotonic()


def gpu_duration(seconds):
    seconds = max(0, int(seconds))
    hours, rest = divmod(seconds, 3600)
    minutes, seconds = divmod(rest, 60)
    return (f"{hours:02d}h " if hours else "") + f"{minutes:02d}m {seconds:02d}s"


def gpu_elapsed():
    gpu_ensure_timer()
    return gpu_duration(time.monotonic()-GPU_PROGRESS_STARTED)


def gpu_clean(value, limit=240):
    return ''.join(ch if ch.isprintable() else ' ' for ch in str(value))[:limit].strip()


def gpu_bar(percent, width=24):
    percent = max(0, min(100, int(percent)))
    filled = int(width * percent / 100)
    return '[' + '#' * filled + '-' * (width-filled) + f'] {percent:3d}%'


def gpu_progress_line(label, percent, stage):
    print(f"\n{label}   {gpu_bar(percent)}   |   Total elapsed: {gpu_elapsed()}", flush=True)
    print('  Current stage: ' + gpu_clean(stage), flush=True)


def gpu_api(service, operation, deadline=None, **payload):
    remaining = 60 if deadline is None else max(1, min(60, deadline-time.monotonic()))
    return aws(service, operation, process_timeout=remaining, **payload)


def gpu_stack_description(name, deadline, deleting):
    try:
        result = gpu_api('cloudformation','describe-stacks',deadline,StackName=name)
    except AwsError as error:
        if deleting and 'does not exist' in str(error):
            return None
        raise
    stacks = result.get('Stacks', [])
    if len(stacks) != 1:
        raise RuntimeError('CloudFormation did not return exactly one selected stack.')
    return stacks[0]


def gpu_stack_phase(summaries, stack_status=""):
    if "ROLLBACK" in stack_status or stack_status.startswith("DELETE_"):
        return "Cleaning up the failed or deleted lab; no new GPU is being launched"
    states = {row.get('LogicalResourceId'): row.get('ResourceStatus') for row in summaries}
    if any('ROLLBACK' in state or state == 'CREATE_FAILED' for state in states.values() if state):
        return 'Handling a failed allocation; CloudFormation is rolling back'
    if states.get('CapacityRelease') == 'CREATE_COMPLETE':
        return 'GPU running at 10.250.20.10; temporary capacity hold released'
    if states.get('Instance') == 'CREATE_COMPLETE':
        return 'GPU allocated; releasing the temporary capacity hold'
    if states.get('CapacityReservation') == 'CREATE_COMPLETE':
        return 'Capacity held; creating the /24 subnet and GPU at 10.250.20.10'
    if states.get('CapacityReservation') == 'CREATE_IN_PROGRESS':
        return 'Checking real GPU capacity across selected zones (attempts below)'
    if 'CapacityFunction' in states or 'CapacityRole' in states:
        return 'Creating the capacity controller and automatic timers'
    if states.get('Fleet') == 'CREATE_COMPLETE':
        return 'Checking the allocated GPU instance and its public address'
    if states.get('Fleet') == 'CREATE_IN_PROGRESS':
        return 'AWS is allocating ONE On-Demand GPU across the selected zones'
    if 'Fleet' in states or 'LaunchTemplate' in states:
        return 'Creating the network, permissions and automatic timers'
    return ''


def gpu_report_capacity_events(stack, summaries, seen, deadline):
    """Display only explicit safe provider progress, never Lambda event payloads."""
    if not any(row.get('LogicalResourceId') == 'CapacityReservation' for row in summaries):
        return
    name = stack.get('StackName', '')
    if not re.fullmatch(r'FortiAIGate-GPU-[a-z][a-z0-9]{0,23}', name):
        return
    try:
        response = gpu_api('logs', 'filter-log-events', deadline,
            logGroupName='/aws/lambda/' + name + '-capacity',
            filterPattern='"CAPACITY"', limit=100)
        for item in response.get('events', []):
            key = item.get('eventId')
            message = item.get('message', '').strip()
            if key and key not in seen and message.startswith('CAPACITY '):
                seen.add(key)
                print('    ' + gpu_clean(message, 500), flush=True)
    except (AwsError, subprocess.TimeoutExpired):
        if 'unavailable-notice' not in seen:
            seen.add('unavailable-notice')
            print('    Capacity log stream is not readable yet; stack status continues below.', flush=True)


def wait_stack(name, target, deleting=False, observer=None):
    """Count completed CloudFormation resources, rather than inventing an ETA."""
    gpu_ensure_timer()
    deadline = time.monotonic()+1800
    expected = GPU_RESOURCE_TOTAL
    if not expected:
        try:
            body = gpu_api('cloudformation','get-template',deadline,StackName=name,TemplateStage='Original').get('TemplateBody', {})
            if isinstance(body,str): body=json.loads(body)
            expected = len(body.get('Resources',{})) or None
        except (AwsError, ValueError, TypeError, subprocess.TimeoutExpired):
            expected = None
    seen_events = set()
    seen_capacity_events = set()
    last_states = {}
    print('\nProvisioning progress counts stack resources; it is not an installation-time estimate.', flush=True)
    while time.monotonic()<deadline:
        try:
            stack = gpu_stack_description(name,deadline,deleting)
            if stack is None and deleting:
                gpu_progress_line('Stack cleanup',100,'CloudFormation stack deleted')
                return
            status = stack.get('StackStatus','Unknown')
            summaries = []
            try:
                summaries = gpu_api('cloudformation','list-stack-resources',deadline,StackName=name).get('StackResourceSummaries',[])
                if observer is not None:
                    observer(stack, summaries)
            except AwsError:
                pass
            complete_states = ('DELETE_COMPLETE','DELETE_SKIPPED') if deleting else ('CREATE_COMPLETE',)
            complete = sum(row.get('ResourceStatus') in complete_states for row in summaries)
            percent = max(1,min(99,int(100*complete/expected))) if expected else 1
            if status==target:percent=100
            detail = f"{complete}/{expected} resources {('processed for cleanup' if deleting else 'created')}" if expected else status
            gpu_progress_line('Stack cleanup' if deleting else 'CloudFormation resources',percent,detail+' · '+status)
            gpu_report_capacity_events(stack, summaries, seen_capacity_events, deadline)
            phase = gpu_stack_phase(summaries, status) if not deleting else ''
            if phase:
                print('  '+phase, flush=True)
            for row in summaries:
                logical = row.get('LogicalResourceId','resource')
                state = row.get('ResourceStatus','Unknown')
                if last_states.get(logical)!=state:
                    print('    '+gpu_clean(logical)+': '+gpu_clean(state),flush=True)
                    last_states[logical]=state
            try:
                rows = gpu_api('cloudformation','describe-stack-events',deadline,StackName=name).get('StackEvents',[])
                for row in reversed(rows[:30]):
                    event_id = row.get('EventId')
                    if event_id in seen_events:continue
                    seen_events.add(event_id)
                    reason = row.get('ResourceStatusReason')
                    if reason and (row.get('ResourceStatus','').endswith('FAILED') or 'ROLLBACK' in row.get('ResourceStatus','')):
                        print('    '+gpu_clean(row.get('LogicalResourceId','resource'))+': '+gpu_clean(reason),flush=True)
            except AwsError:
                pass
        except subprocess.TimeoutExpired as error:
            raise RuntimeError('CloudFormation status request timed out. The cloud operation continues; inspect this same stack before retrying.') from error
        if status==target:
            return stack
        if not status.endswith('_IN_PROGRESS'):
            raise RuntimeError('Stack ended in '+status+'. Inspect the resource details above or CloudFormation events; use this lab’s Destroy action for cleanup.')
        time.sleep(min(10,max(0,deadline-time.monotonic())))
    raise RuntimeError('The 30-minute CloudFormation status wait ended. The cloud operation may continue; inspect this same stack before another action.')


def gpu_validate_snapshot(output):
    snapshot=json.loads(output.strip())
    if (not isinstance(snapshot,dict) or snapshot.get('status') not in ('pending','running','ready','failed')
            or not isinstance(snapshot.get('stage'),str) or not snapshot['stage'].strip()
            or len(snapshot['stage'])>240 or not snapshot['stage'].isprintable()):
        raise ValueError('GPU preparation status is malformed.')
    percent=snapshot.get('percent')
    if isinstance(percent,bool) or not isinstance(percent,(int,float)) or not gpu_math.isfinite(percent) or not 0<=percent<=100:
        raise ValueError('GPU preparation percentage is invalid.')
    if snapshot['status']=='ready':
        if snapshot.get('gpu_ready') is not True or percent!=100:
            raise ValueError('GPU readiness was not independently verified.')
    elif percent>=100:
        raise ValueError('A pending or failed GPU host cannot report 100%.')
    transfer=snapshot.get('download')
    if transfer is not None:
        if not isinstance(transfer,dict):raise ValueError('GPU download status is invalid.')
        file_name=transfer.get('file_name','')
        if not isinstance(file_name,str) or not file_name.isprintable() or len(file_name)>200 or '/' in file_name or '\\' in file_name:
            raise ValueError('GPU download filename is invalid.')
        for key in ('bytes_downloaded','total_bytes'):
            value=transfer.get(key)
            if isinstance(value,bool) or not isinstance(value,(int,float)) or not gpu_math.isfinite(value) or value<0:
                raise ValueError('GPU download byte count is invalid.')
        if transfer['bytes_downloaded']>transfer['total_bytes']:
            raise ValueError('GPU download exceeds its expected byte count.')
        rate=transfer.get('rate_bytes_per_second')
        if rate is not None and (isinstance(rate,bool) or not isinstance(rate,(int,float)) or not gpu_math.isfinite(rate) or rate<0):
            raise ValueError('GPU download rate is invalid.')
    return snapshot


def gpu_bytes(value):
    value=float(value)
    for unit in ('B','KiB','MiB','GiB','TiB'):
        if value<1024 or unit=='TiB':return f'{value:.2f} {unit}'
        value/=1024


def gpu_report_snapshot(snapshot):
    gpu_progress_line('Host preparation milestones (estimated)',snapshot['percent'],snapshot['stage'])
    transfer=snapshot.get('download')
    if transfer:
        index=transfer.get('component_index','?')
        count=transfer.get('component_count',3)
        rate=transfer.get('rate_bytes_per_second')
        print(f"  GPU file {gpu_clean(index,10)}/{gpu_clean(count,10)}: {transfer['file_name']}",flush=True)
        text=f"  Downloaded: {gpu_bytes(transfer['bytes_downloaded'])} / {gpu_bytes(transfer['total_bytes'])}"
        if rate is not None:text+='   |   '+gpu_bytes(rate)+'/s'
        if transfer.get('status')=='checking':text+='   |   Checking archive contents'
        elif transfer.get('status')=='complete':text+='   |   Archive verified'
        print(text,flush=True)


def gpu_read_snapshot(instance_id,deadline,last_snapshot):
    try:
        command=gpu_api('ssm','send-command',deadline,DocumentName='AWS-RunShellScript',InstanceIds=[instance_id],
            Parameters={'commands':[GPU_STATUS_PROBE],'executionTimeout':['30']},TimeoutSeconds=60,
            Comment='Read FortiAIGate GPU preparation and transfer progress')
        command_id=command['Command']['CommandId']
    except (KeyError,TypeError) as error:
        raise RuntimeError('SSM did not return a preparation probe command ID.') from error
    command_deadline=min(deadline,time.monotonic()+120)
    while time.monotonic()<command_deadline:
        try:
            result=gpu_api('ssm','get-command-invocation',command_deadline,CommandId=command_id,InstanceId=instance_id)
        except AwsError as error:
            if any(word in str(error) for word in ('InvocationDoesNotExist','Throttling','TargetNotConnected','InvalidInstanceId')):
                result={'Status':'Pending'}
            else:
                raise RuntimeError('The existing GPU status probe could not be read. No second command was queued; inspect SSM command '+command_id+'.') from error
        status=result.get('Status','Unknown')
        if status not in ('Pending','InProgress','Delayed'):
            if status!='Success' or result.get('ResponseCode')!=0:
                raise RuntimeError('GPU preparation probe did not succeed ('+status+'). Inspect the existing VM; no overlapping probe was started.')
            try:return gpu_validate_snapshot(result.get('StandardOutputContent',''))
            except (ValueError,TypeError) as error:
                raise RuntimeError('GPU preparation status could not be verified. Inspect the existing VM and its logs.') from error
        gpu_progress_line('Host preparation milestones (estimated)',last_snapshot['percent'],last_snapshot['stage']+'; SSM status snapshot '+status)
        time.sleep(min(5,max(0,command_deadline-time.monotonic())))
    raise RuntimeError('The GPU status probe has not finished. No second command was queued; inspect this instance’s SSM command before retrying.')


def wait_for_gpu_preparation(instance_id):
    global GPU_HOST_READY
    GPU_HOST_READY = False
    gpu_ensure_timer()
    waited=time.monotonic()
    deadline=waited+2700
    last={'status':'pending','stage':'waiting for Session Manager and first-boot preparation','percent':1,'download':None,'gpu_ready':False}
    print('\nWaiting up to 45 minutes for GPU host preparation, including one driver reboot.',flush=True)
    print('The host bar tracks estimated milestones; download bytes are reported separately from real transfers.',flush=True)
    while time.monotonic()<deadline:
        try:
            info=gpu_api('ssm','describe-instance-information',deadline,Filters=[{'Key':'InstanceIds','Values':[instance_id]}])
            online=any(row.get('InstanceId')==instance_id and row.get('PingStatus')=='Online' for row in info.get('InstanceInformationList',[]))
            if not online:
                gpu_progress_line('Host preparation milestones (estimated)',last['percent'],last['stage'])
                print('  Session Manager is reconnecting; first boot or the planned driver reboot may be in progress.',flush=True)
                time.sleep(min(15,max(0,deadline-time.monotonic())))
                continue
            last=gpu_read_snapshot(instance_id,deadline,last)
        except AwsError as error:
            if any(word in str(error) for word in ('InvalidInstanceId','TargetNotConnected','Throttling')):
                gpu_progress_line('Host preparation milestones (estimated)',last['percent'],last['stage']+'; reconnecting to Session Manager')
                time.sleep(min(15,max(0,deadline-time.monotonic())))
                continue
            raise RuntimeError('GPU resources exist but preparation status could not be read: '+str(error)) from error
        except subprocess.TimeoutExpired as error:
            raise RuntimeError('GPU status API timed out. No overlapping command was submitted; connect to the existing VM and inspect preparation.') from error
        gpu_report_snapshot(last)
        if last['status']=='failed':
            raise RuntimeError('GPU host preparation failed. Read /var/log/fortiaigate-gpu-prep.log and /var/log/fortiaigate-prep.log on this existing VM.')
        if last['status']=='ready':
            GPU_HOST_READY = True
            print('\nPASS: GPU host preparation is ready. Continue with the interactive FortiAIGate installation.',flush=True)
            print('Total '+('creation and preparation' if GPU_CREATION_TIMER else 'readiness-check')+' duration: '+gpu_elapsed(),flush=True)
            print('Readiness verification duration: '+gpu_duration(time.monotonic()-waited),flush=True)
            if last.get('started_at') and last.get('completed_at'):
                try:
                    begin=gpu_datetime.datetime.fromisoformat(str(last['started_at']).replace('Z','+00:00'))
                    end=gpu_datetime.datetime.fromisoformat(str(last['completed_at']).replace('Z','+00:00'))
                    if end>=begin:print('Host preparation duration (VM timestamps): '+gpu_duration((end-begin).total_seconds()),flush=True)
                except (ValueError,TypeError):pass
            return
        time.sleep(min(15,max(0,deadline-time.monotonic())))
    raise RuntimeError('GPU host preparation was not confirmed within 45 minutes. The lab remains available for inspection and its cloud-side deletion deadline still apply.')


def gpu_color(text, code='1;36'):
    if getattr(sys.stdout,'isatty',lambda:False)() and not os.environ.get('NO_COLOR'):
        return '\033['+code+'m'+text+'\033[0m'
    return text


def print_connection_details(instance_id):
    """Refresh the current address; new labs retain their Elastic IP."""
    session='https://'+REGION+'.console.aws.amazon.com/systems-manager/session-manager/'+instance_id+'?region='+REGION
    address=None
    tags={}
    try:
        result=gpu_api('ec2','describe-instances',InstanceIds=[instance_id])
        instances=[i for reservation in result.get('Reservations',[]) for i in reservation.get('Instances',[])]
        if len(instances)==1:
            item=instances[0]
            candidate=item.get('PublicIpAddress')
            if candidate and gpu_ipaddress.ip_address(candidate).version==4:address=candidate
            tags={row['Key']:row['Value'] for row in item.get('Tags',[])}
    except (AwsError,ValueError,KeyError,subprocess.TimeoutExpired):
        print('The current public IP could not be refreshed. Check EC2 or run Connect after the VM finishes starting.',flush=True)
    print('\n'+'='*72,flush=True)
    print(gpu_color('CONNECT TO YOUR GPU LAB','1;32'),flush=True)
    print('Instance: '+instance_id,flush=True)
    print('Session Manager — open this link:',flush=True)
    print(gpu_color(session),flush=True)
    print('Or run in AWS CloudShell:',flush=True)
    print('  aws ssm start-session --target '+instance_id+' --region '+REGION,flush=True)
    if address:
        print('\nFortiAIGate WebUI — available after the interactive deployment:',flush=True)
        print(gpu_color('https://'+address+'/ui','1;34'),flush=True)
        print('External URL for browser onboarding: https://'+address,flush=True)
    else:
        print('\nPublic IP is not assigned yet. Run Connect again after the VM is running.',flush=True)
    for key,label in [('BudgetStopAt','Legacy automatic stop'),('BudgetDeleteAt','Permanent lab-stack deletion')]:
        if tags.get(key):print(label+': '+gpu_clean(tags[key])+' UTC',flush=True)
    print('8-hour deletion deadline; option 5 adds 8 hours. Connect and Restart do not extend it. No automatic stop.' if tags.get('BudgetVersion') == '8h-delete-v2' else 'Legacy lab timers remain unchanged. Recreate the lab to use the 8-hour policy.',flush=True)
    print('Elastic IP stays assigned until Destroy; a manual stop still releases GPU compute capacity.' if tags.get('PublicIpMode') == 'elastic' else 'Legacy automatic public IP may change after a manual stop/restart.',flush=True)
    print('='*72+'\n',flush=True)


def outputs(stack):
    values={row['OutputKey']:row['OutputValue'] for row in stack.get('Outputs',[])}
    print('\nGPU lab: '+gpu_clean(stack.get('StackName',stack.get('StackId',''))),flush=True)
    for key in ('InstanceId','InstanceType','AvailabilityZone','PrivateIPv4','VpcId','RoleName','ReleaseBucket','ReleasePrefix'):
        if key in values:print(key+': '+gpu_clean(values[key]),flush=True)
    if values.get('InstanceId'):print_connection_details(values['InstanceId'])
    print('NEXT — inside the connected Ubuntu Session Manager terminal, as your normal user:',flush=True)
    print('  fortiaigate-install',flush=True)
    if GPU_HOST_READY:
        print('Host preparation is complete; the interactive installation and browser licensing follow in the guide.',flush=True)
    else:
        print('Check fortiaigate-prep-status inside Ubuntu first. Continue only after GPU preparation reports READY.',flush=True)

"""Bounded AWS GPU capacity retries. Embedded after the progress helpers.

Only an owned, nonce-bound EC2 capacity failure authorizes automatic cleanup.
No resources are created at import time; the CloudShell creator supplies aws(),
AwsError, wait_stack(), template constants and the progress clock.
"""
import copy as failover_copy
import datetime as failover_datetime
import json as failover_json
import re as failover_re
import subprocess as failover_subprocess
import tempfile as failover_tempfile
import time as failover_time
import uuid as failover_uuid
from pathlib import Path as FailoverPath

FAILOVER_ROLLBACK_SECONDS = 1800
FAILOVER_DELETE_SECONDS = 1800
FAILOVER_ROLE_SECONDS = 120


def failover_error_code(error):
    match = failover_re.search(r"An error occurred \(([A-Za-z0-9.]+)\)", str(error))
    return match.group(1) if match else ""


def failover_missing_stack(error):
    return failover_error_code(error) == "ValidationError" and "does not exist" in str(error).lower()


def failover_now():
    return failover_datetime.datetime.now(failover_datetime.timezone.utc)


def failover_aws(service, operation, *args, **payload):
    return aws(service, operation, *args, process_timeout=60, **payload)


def failover_note(message):
    elapsed = globals().get("gpu_elapsed")
    suffix = "   |   Total elapsed: " + elapsed() if elapsed else ""
    print("\n" + message + suffix, flush=True)


def failover_stack_identity(stack_id, name, account):
    pattern = (r"arn:aws:cloudformation:" + failover_re.escape(REGION) + ":" +
               failover_re.escape(account) + ":stack/" + failover_re.escape(name) +
               r"/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    if not isinstance(stack_id, str) or not failover_re.fullmatch(pattern, stack_id):
        raise RuntimeError("The capacity attempt did not return an exact owned stack ARN; no automatic cleanup was attempted.")


def failover_describe(stack_id, prefix, account, token, optional=False):
    name = "FortiAIGate-GPU-" + prefix
    failover_stack_identity(stack_id, name, account)
    try:
        rows = failover_aws("cloudformation", "describe-stacks", StackName=stack_id).get("Stacks", [])
    except AwsError as error:
        if optional and failover_missing_stack(error): return None
        raise
    if len(rows) != 1:
        raise RuntimeError("The selected capacity attempt could not be identified; no next attempt was started.")
    stack = rows[0]
    tags = {t["Key"]: t["Value"] for t in stack.get("Tags", [])}
    if (stack.get("StackId") != stack_id or stack.get("StackName") != name
            or tags.get("DeploymentGuide") != MARKER or tags.get("UserPrefix") != prefix
            or tags.get("ScriptVersion") != VERSION or tags.get("CapacityAttempt") != token):
        raise RuntimeError("Capacity-attempt ownership changed; automatic cleanup and retry were stopped.")
    return stack


def failover_pages(service, operation, key, **payload):
    request = dict(payload)
    seen = set()
    for _ in range(1000):
        page = failover_aws(service, operation, "--no-paginate", **request)
        for item in page.get(key, []): yield item
        token = page.get("NextToken") if service == "cloudformation" else page.get("Marker") if page.get("IsTruncated") else None
        if not token: return
        if token in seen: raise RuntimeError("Capacity cleanup inventory pagination did not advance; retry stopped.")
        seen.add(token)
        request["NextToken" if service == "cloudformation" else "Marker"] = token
    raise RuntimeError("Capacity cleanup inventory exceeded its safety limit; retry stopped.")


def failover_is_capacity_reason(reason):
    if not isinstance(reason, str): return False
    # A capacity substring cannot override a different actual EC2 error.
    forbidden = (r"\b(?:InstanceLimitExceeded|VcpuLimitExceeded|MaxSpotInstanceCountExceeded|"
                 r"InsufficientFreeAddressesInSubnet|UnauthorizedOperation|AuthFailure|AccessDenied(?:Exception)?|"
                 r"Unsupported|InvalidParameter(?:Value|Combination)?|InvalidAMIID\.[A-Za-z]+)\b")
    if failover_re.search(forbidden, reason, failover_re.I): return False
    if failover_re.search(r"\bInsufficientInstanceCapacity\b", reason): return True
    return bool(failover_re.search(
        r"\bWe currently do not have sufficient\s+" + failover_re.escape(INSTANCE_TYPE) + r"\s+capacity\b",
        reason, failover_re.I))


def failover_failure_evidence(stack_id, token, offered):
    reasons, candidates = [], []
    for event in failover_pages("cloudformation", "describe-stack-events", "StackEvents", StackName=stack_id):
        if event.get("StackId") != stack_id or event.get("ClientRequestToken") != token:
            continue
        if event.get("ResourceStatus") != "CREATE_FAILED": continue
        if event.get("ResourceType") == "AWS::CloudFormation::Stack": continue
        reason = event.get("ResourceStatusReason", "")
        if (event.get("LogicalResourceId") == "Instance"
                and event.get("ResourceType") == "AWS::EC2::Instance"
                and failover_is_capacity_reason(reason)):
            reasons.append(reason)
            match = failover_re.search(r"Availability Zone you requested\s*\((" +
                                       failover_re.escape(REGION) + r"[a-z])\)", reason, failover_re.I)
            if match: candidates.append(match.group(1).lower())
        elif failover_re.fullmatch(r"Resource creation cancel(?:led|ed)\.?", reason.strip(), failover_re.I):
            continue
        else:
            # Multiple independent failures are not a capacity-only attempt.
            return None
    if not reasons: return None
    if len(set(candidates)) > 1:
        raise RuntimeError("Capacity error messages disagree about the failed zone; retry stopped.")
    return {"reason": reasons[-1], "zone": candidates[0] if candidates else None}


def failover_observer(stack_id, state):
    def observe(stack, summaries):
        if stack.get("StackId") != stack_id:
            raise RuntimeError("Progress returned another stack during the capacity attempt.")
        for output in stack.get("Outputs", []):
            if output.get("OutputKey") == "AvailabilityZone":
                value = output.get("OutputValue", "")
                if failover_re.fullmatch(failover_re.escape(REGION)+r"[a-z]", value): state["zone"] = value
        if state.get("zone"): return
        subnets = [row.get("PhysicalResourceId", "") for row in summaries
                   if row.get("LogicalResourceId") == "Subnet" and row.get("ResourceType") == "AWS::EC2::Subnet"]
        for subnet_id in subnets:
            if not failover_re.fullmatch(r"subnet-(?:[0-9a-f]{8}|[0-9a-f]{17})", subnet_id): continue
            try:
                result = aws("ec2", "describe-subnets", SubnetIds=[subnet_id], process_timeout=10)
                rows = result.get("Subnets", [])
                if len(rows) == 1 and rows[0].get("SubnetId") == subnet_id:
                    zone = rows[0].get("AvailabilityZone", "")
                    if failover_re.fullmatch(failover_re.escape(REGION)+r"[a-z]", zone): state["zone"] = zone
            except (AwsError, OSError, TimeoutError, failover_subprocess.TimeoutExpired):
                # AZ observation is optional. The nonce-bound EC2 reason can
                # recover the zone after rollback removes the subnet.
                pass
    return observe


def failover_wait_rollback(stack_id, prefix, account, token):
    end = failover_time.monotonic() + FAILOVER_ROLLBACK_SECONDS
    previous = None
    while failover_time.monotonic() < end:
        stack = failover_describe(stack_id, prefix, account, token, optional=True)
        if stack is None: return None
        state = stack.get("StackStatus", "")
        if state in ("ROLLBACK_COMPLETE", "CREATE_FAILED", "DELETE_COMPLETE"): return stack
        if state not in ("CREATE_IN_PROGRESS", "ROLLBACK_IN_PROGRESS", "DELETE_IN_PROGRESS"):
            raise RuntimeError("Failed-attempt rollback stopped in " + state + "; no next zone was started. Inspect this stack and use Destroy if needed.")
        if state != previous:
            failover_note("Waiting for failed-attempt rollback: " + state)
            previous = state
        failover_time.sleep(10)
    raise RuntimeError("Failed-attempt rollback did not finish within 30 minutes. No next zone was started.")


def failover_assert_no_unexpected_retention(stack_id):
    try:
        rows = list(failover_pages("cloudformation", "list-stack-resources", "StackResourceSummaries", StackName=stack_id))
    except AwsError as error:
        if failover_missing_stack(error): return
        raise
    for row in rows:
        if row.get("ResourceStatus") == "DELETE_SKIPPED" and row.get("LogicalResourceId") != "BudgetCleanupRole":
            raise RuntimeError("The failed stack retained an unexpected resource; no next zone was started.")


def failover_cleanup_role(role_name, stack_id, prefix, account):
    role = gpu_read_role(role_name, failover_aws)
    if role is None: return
    actual = role.get("RoleName", "")
    tags = {t["Key"]: t["Value"] for t in role.get("Tags", [])}
    if (actual.casefold() != (prefix + "_FortiAIGate_GPU_CleanupRole").casefold()
            or role.get("Arn") != "arn:aws:iam::"+account+":role/"+actual
            or not role.get("RoleId") or tags.get("BudgetStack") != stack_id
            or tags.get("DeploymentGuide") != MARKER or tags.get("UserPrefix") != prefix
            or tags.get("BudgetVersion") not in ("2h-stop-12h-delete-v1", "8h-delete-v2")):
        raise RuntimeError("Failed-attempt cleanup role ownership is not exact; no next zone was started.")
    policies = list(failover_pages("iam", "list-role-policies", "PolicyNames", RoleName=actual))
    attached = list(failover_pages("iam", "list-attached-role-policies", "AttachedPolicies", RoleName=actual))
    profiles = list(failover_pages("iam", "list-instance-profiles-for-role", "InstanceProfiles", RoleName=actual))
    if set(policies)-{"DeleteOnlyThisLab"} or attached or profiles:
        raise RuntimeError("Failed-attempt cleanup role was reused or modified; no next zone was started.")
    try: fresh = failover_aws("iam", "get-role", RoleName=actual)["Role"]
    except AwsError as error:
        if failover_error_code(error) == "NoSuchEntity": return
        raise
    if fresh.get("RoleId") != role["RoleId"] or {t['Key']:t['Value'] for t in fresh.get('Tags',[])} != tags:
        raise RuntimeError("Cleanup role changed while being checked; no next zone was started.")
    for policy in policies:
        try: failover_aws("iam", "delete-role-policy", RoleName=actual, PolicyName=policy)
        except AwsError as error:
            if failover_error_code(error) != "NoSuchEntity": raise
    end = failover_time.monotonic() + FAILOVER_ROLE_SECONDS
    delete_requested = False
    while failover_time.monotonic() < end:
        # Once positively identified, use authoritative reads until deletion.
        # ListRoles may temporarily omit a known role; that is not completion.
        try:
            current = failover_aws("iam", "get-role", RoleName=actual)["Role"]
        except AwsError as error:
            if failover_error_code(error) == "NoSuchEntity": return
            raise
        if (current.get("RoleId") != role["RoleId"]
                or {t['Key']:t['Value'] for t in current.get('Tags',[])} != tags):
            raise RuntimeError("The cleanup role changed during deletion; no next zone was started.")
        if not delete_requested:
            try:
                failover_aws("iam", "delete-role", RoleName=actual)
                delete_requested = True
            except AwsError as error:
                if failover_error_code(error) == "NoSuchEntity": return
                if failover_error_code(error) not in ("DeleteConflict", "ConcurrentModification"):
                    raise
        failover_time.sleep(5)
    raise RuntimeError("The failed attempt's cleanup role is not confirmed absent; no next zone was started.")


def failover_cleanup_attempt(stack_id, prefix, account, token, role_name):
    stack = failover_wait_rollback(stack_id, prefix, account, token)
    if stack and stack.get("StackStatus") != "DELETE_COMPLETE":
        failover_note("Cleaning the failed GPU attempt before any further action")
        try: failover_aws("cloudformation", "delete-stack", StackName=stack_id)
        except AwsError as error:
            if not failover_missing_stack(error): raise
    end = failover_time.monotonic() + FAILOVER_DELETE_SECONDS
    previous = None
    while failover_time.monotonic() < end:
        current = failover_describe(stack_id, prefix, account, token, optional=True)
        state = current.get("StackStatus") if current else "NOT_FOUND"
        if state in ("DELETE_COMPLETE", "NOT_FOUND"): break
        if state not in ("DELETE_IN_PROGRESS", "ROLLBACK_COMPLETE", "CREATE_FAILED"):
            raise RuntimeError("Failed-attempt deletion stopped in " + state + "; no next zone was started.")
        if state != previous:
            failover_note("Failed-attempt cleanup: " + state)
            previous = state
        failover_time.sleep(10)
    else:
        raise RuntimeError("Failed-attempt deletion did not finish within 30 minutes. No next zone was started.")
    failover_assert_no_unexpected_retention(stack_id)
    try:
        failover_cleanup_role(role_name, stack_id, prefix, account)
    except AwsError as error:
        # The shared janitor may finish the same retired role between reads.
        # For this rare race, require authoritative absence. Do not repeat this
        # expected-failing read after ordinary completed/initially absent cleanup.
        if failover_error_code(error) != "NoSuchEntity": raise
        try: failover_aws("iam", "get-role", RoleName=role_name)
        except AwsError as current_error:
            if failover_error_code(current_error) != "NoSuchEntity": raise
        else:
            raise RuntimeError("A cleanup role still occupies the failed attempt's name; no next zone was started.")
    failover_note("Failed attempt fully removed: stack and per-lab cleanup role are gone")


def failover_budget_available(body):
    tags = {t["Key"]: t["Value"] for t in body["Resources"]["Instance"]["Properties"]["Tags"]}
    try:
        created = failover_datetime.datetime.fromisoformat(tags["BudgetCreatedAt"].replace("Z", "+00:00"))
        delete = failover_datetime.datetime.fromisoformat(tags["BudgetDeleteAt"].replace("Z", "+00:00"))
        if (tags.get("BudgetVersion") != "8h-delete-v2" or not created.tzinfo or not delete.tzinfo
                or delete - created != failover_datetime.timedelta(hours=8)):
            raise ValueError()
    except (KeyError, TypeError, ValueError) as error:
        raise RuntimeError("The approved eight-hour lab deadline is invalid; no capacity attempt was started.") from error
    if failover_now() >= delete:
        raise RuntimeError("The original eight-hour deletion deadline has passed. No new capacity attempt was started; create a new approved lab.")


def create_gpu_stack_with_failover(name, prefix, selected_zone, offered, approved_body, expected_account=None):
    """Try only supported/ranked zones in Auto, after full cleanup each time."""
    if not failover_re.fullmatch(r"[a-z][a-z0-9]{0,23}", prefix) or name != "FortiAIGate-GPU-"+prefix:
        raise ValueError("The capacity retry target is not a canonical GPU lab name.")
    account = expected_account or identity()["Account"]
    if not failover_re.fullmatch(r"[0-9]{12}", account): raise ValueError("Invalid AWS account for capacity attempts.")
    candidates = list(dict.fromkeys(offered))
    if not candidates or any(not failover_re.fullmatch(failover_re.escape(REGION)+r"[a-z]", z) for z in candidates):
        raise ValueError("The offered-zone list is invalid.")
    if selected_zone is not None and selected_zone not in candidates: raise ValueError("Manual zone is not offered.")
    retained = [key for key,resource in approved_body["Resources"].items()
                if resource.get("DeletionPolicy") not in (None, "Delete")
                and not (key == "BudgetCleanupRole" and resource.get("DeletionPolicy") in ("Retain", "RetainExceptOnCreate"))]
    if retained:
        raise RuntimeError("The approved stack retains unexpected resources; automatic capacity cleanup is disabled.")
    role_name = approved_body["Resources"]["BudgetCleanupRole"]["Properties"]["RoleName"]
    # An unconstrained subnet can land in a zone that doesn't offer this GPU.
    # Auto selects from the validated list, including on its very first attempt.
    first_zone = selected_zone if selected_zone is not None else candidates[0]
    queue = [first_zone]
    remaining = [zone for zone in candidates if zone != first_zone]
    failed_zones = set()
    attempts = 0
    while queue:
        zone = queue.pop(0)
        attempts += 1
        failover_budget_available(approved_body)
        body = apply_availability_zone_selection(approved_body, zone)
        token = "fortiaigate-gpu-" + failover_uuid.uuid4().hex
        label = zone
        failover_note("Capacity attempt " + str(attempts) + ": " + label)
        with failover_tempfile.TemporaryDirectory(prefix="fortiaigate-gpu-capacity-") as directory:
            path = FailoverPath(directory)/"stack.json"
            path.write_text(failover_json.dumps(body), encoding="utf-8")
            failover_aws("cloudformation", "validate-template", "--template-body", "file://"+str(path))
            # A create RPC timeout is ambiguous. Never turn it into another
            # CreateStack call, even though this request has an idempotency token.
            try:
                result = failover_aws("cloudformation", "create-stack", StackName=name,
                    TemplateBody=failover_json.dumps(body), OnFailure="ROLLBACK", ClientRequestToken=token,
                    Capabilities=["CAPABILITY_NAMED_IAM"], Tags=[
                        {"Key":"DeploymentGuide","Value":MARKER}, {"Key":"UserPrefix","Value":prefix},
                        {"Key":"ScriptVersion","Value":VERSION}, {"Key":"CapacityAttempt","Value":token}])
            except (failover_subprocess.TimeoutExpired, OSError) as error:
                raise RuntimeError("The CreateStack response is ambiguous. No second request was submitted; inspect "+name+" before another action.") from error
        stack_id = result.get("StackId")
        failover_stack_identity(stack_id, name, account)
        print("Created capacity attempt: " + stack_id, flush=True)
        observed = {"zone": zone}
        try:
            complete = wait_stack(stack_id, "CREATE_COMPLETE", observer=failover_observer(stack_id, observed))
        except (AwsError, RuntimeError) as failure:
            if selected_zone is not None:
                raise RuntimeError("The manually selected zone failed. Auto retry was not requested; inspect this same stack before another action. " + str(failure)) from failure
            current = failover_describe(stack_id, prefix, account, token, optional=True)
            if current and current.get("StackStatus") == "CREATE_COMPLETE":
                raise RuntimeError("This attempt completed after its status wait failed. No cleanup or second instance was started; inspect this lab.") from failure
            evidence = failover_failure_evidence(stack_id, token, candidates)
            if not evidence:
                raise RuntimeError("Auto stopped: this is not a verified capacity-only EC2 failure. The same stack remains for inspection/Destroy. " + str(failure)) from failure
            if observed.get("zone") and evidence.get("zone") and observed["zone"] != evidence["zone"]:
                raise RuntimeError("The observed subnet zone disagrees with the capacity error; no retry was started.") from failure
            failed_zone = observed.get("zone") or zone
            failed_zones.add(failed_zone)
            failover_note("Confirmed insufficient GPU capacity in " + failed_zone)
            failover_cleanup_attempt(stack_id, prefix, account, token, role_name)
            # Do not reset either timer after time spent on failed attempts.
            failover_budget_available(approved_body)
            remaining = [candidate for candidate in remaining if candidate not in failed_zones]
            if not remaining:
                raise RuntimeError("No offered GPU zones remain after capacity failures. Every failed attempt was cleaned up; the shared cleanup service was kept.") from failure
            queue.append(remaining.pop(0))
            continue
        if complete.get("StackId") != stack_id:
            raise RuntimeError("Creation returned another stack; no additional attempt was started.")
        return complete
    raise RuntimeError("No capacity attempt was selected.")

"""Select one GPU AZ before creating the lab's exact, single /24 subnet.

The short-lived targeted reservation is real billable capacity. CloudFormation
owns its custom resource; release after launch, rollback cleanup and an expiry
backstop prevent it from becoming a second long-lived compute charge.
"""
import copy as reservation_copy
import datetime as reservation_datetime
import re as reservation_re


CAPACITY_PROVIDER = r'''import boto3,datetime,hashlib,json,os,re,time,urllib.request
from botocore.config import Config
def client(attempts):
    return boto3.client("ec2",config=Config(connect_timeout=5,read_timeout=20,retries={"mode":"standard","total_max_attempts":attempts}))
ec2=client(3)
# EC2 capacity errors can carry HTTP 500, which the SDK otherwise retries.
# Reserve once per AZ; retain bounded, same-token retries only for transients.
allocator=client(1)
MARKER="FortiAIGate-GPU-AWS-v1"
LOGICAL="CapacityReservation"
TERMINAL=("cancelled","expired","failed")
CAPACITY_ERRORS=("InsufficientInstanceCapacity","InsufficientCapacity")
TRANSIENT_ERRORS=("RequestTimeout","RequestTimeoutException","PriorRequestNotComplete",
    "RequestLimitExceeded","Throttling","ThrottlingException","ThrottledException",
    "RequestThrottled","RequestThrottledException","TooManyRequestsException",
    "EC2ThrottledException","InternalError","InternalFailure","InternalServerError",
    "InternalServerException","ServiceUnavailable","ServiceUnavailableException",
    "Unavailable","ConnectTimeoutError","ReadTimeoutError","EndpointConnectionError",
    "ConnectionClosedError","HTTPClientError","ConnectionError","TimeoutError")
APPROVED_TYPES=("g6e.2xlarge","g6e.4xlarge")

def code(error):
    return (getattr(error,"response",None) or {}).get("Error",{}).get("Code",type(error).__name__)

def transient(error):
    name=code(error)
    if name in CAPACITY_ERRORS or name.startswith(("Unauthorized","AccessDenied","Auth","Invalid",
        "Validation","Unsupported","Max","Vcpu","InstanceLimit","ResourceLimit","LimitExceeded","CapacityReservationLimit",
        "OptInRequired","Signature","RequestExpired")): return False
    return name in TRANSIENT_ERRORS or (getattr(error,"response",None) or {}).get("ResponseMetadata",{}).get("HTTPStatusCode") in (500,502,503,504)

def deadline(context):
    if context is not None and context.get_remaining_time_in_millis()<120000:
        raise RuntimeError("Capacity operation deadline reached")

def note(message):
    print("CAPACITY "+message,flush=True)

def respond(event,status,physical,data=None,reason=""):
    payload=json.dumps({"Status":status,"Reason":reason or "Capacity operation complete",
        "PhysicalResourceId":physical,"StackId":event["StackId"],"RequestId":event["RequestId"],
        "LogicalResourceId":event["LogicalResourceId"],"NoEcho":False,"Data":data or {}}).encode()
    request=urllib.request.Request(event["ResponseURL"],data=payload,method="PUT",
        headers={"content-type":"","content-length":str(len(payload))})
    # Never print the event or the signed CloudFormation ResponseURL.
    with urllib.request.urlopen(request,timeout=20) as response: response.read()

def attempt_of(event):
    value="|".join((event["StackId"],event["LogicalResourceId"],event["RequestId"]))
    return hashlib.sha256(value.encode()).hexdigest()[:32]

def tags_of(row):
    return {t["Key"]:t["Value"] for t in row.get("Tags",[])}

def validate(row,p,attempt=None):
    tags=tags_of(row)
    if (not re.fullmatch(r"cr-[0-9a-f]{17}",row.get("CapacityReservationId",""))
        or tags.get("DeploymentGuide")!=MARKER
        or tags.get("FortiAIGateBudgetStack")!=os.environ["STACK_ID"]
        or tags.get("BudgetStack")!=os.environ["STACK_ID"]
        or tags.get("CapacityLogicalId")!=LOGICAL
        or not re.fullmatch(r"[0-9a-f]{32}",tags.get("CapacityAttempt",""))
        or (attempt is not None and tags.get("CapacityAttempt")!=attempt)
        or row.get("InstanceType")!=p["InstanceType"]
        or row.get("InstancePlatform")!="Linux/UNIX"
        or row.get("Tenancy")!="default" or row.get("InstanceMatchCriteria")!="targeted"
        or row.get("TotalInstanceCount")!=1
        or row.get("AvailabilityZone") not in p["AvailabilityZones"]):
        raise RuntimeError("Reservation ownership/configuration mismatch")
    return row

def inventory(p,attempt=None):
    filters=[{"Name":"tag:"+k,"Values":[v]} for k,v in {
        "FortiAIGateBudgetStack":os.environ["STACK_ID"],"CapacityLogicalId":LOGICAL}.items()]
    if attempt is not None: filters.append({"Name":"tag:CapacityAttempt","Values":[attempt]})
    request={"Filters":filters}
    rows=[]
    for _ in range(20):
        page=ec2.describe_capacity_reservations(**request)
        rows.extend(validate(row,p,attempt) for row in page.get("CapacityReservations",[]))
        token=page.get("NextToken")
        if not token: return rows
        request["NextToken"]=token
    raise RuntimeError("Reservation inventory pagination limit")

def get_owned(reservation_id,p):
    if not re.fullmatch(r"cr-[0-9a-f]{17}",reservation_id or ""):
        raise RuntimeError("Invalid reservation ID")
    try:
        rows=ec2.describe_capacity_reservations(CapacityReservationIds=[reservation_id]).get("CapacityReservations",[])
    except Exception as error:
        if code(error)=="InvalidCapacityReservationId.NotFound": return None
        raise
    if not rows: return None
    if len(rows)!=1: raise RuntimeError("Multiple reservations returned")
    if rows[0].get("CapacityReservationId")!=reservation_id: raise RuntimeError("Reservation identity changed")
    return validate(rows[0],p)

def cancel(row,p):
    row=validate(row,p)
    if row.get("State") in TERMINAL: return
    reservation_id=row["CapacityReservationId"]
    try:
        result=ec2.cancel_capacity_reservation(CapacityReservationId=reservation_id)
        if not result.get("Return",False): raise RuntimeError("Reservation cancellation unconfirmed")
    except Exception as error:
        # Resolve an ambiguous response with a read. Never cancel an unowned ID.
        current=get_owned(reservation_id,p)
        if current is not None and current.get("State") not in TERMINAL: raise error
    note("released reservation "+reservation_id)

def cleanup(p,reservation_id=None,attempt=None):
    if reservation_id and reservation_id.startswith("cr-"):
        row=get_owned(reservation_id,p)
        if row is not None: cancel(row,p)
    else:
        for row in inventory(p,attempt): cancel(row,p)

def result(row):
    return row["CapacityReservationId"],{"CapacityReservationId":row["CapacityReservationId"],
        "AvailabilityZone":row["AvailabilityZone"]}

def active(row,p,context):
    if row.get("State")=="active": return row
    # AWS documents that state can take up to five minutes to reflect.
    # Leave time for cancellation and the CloudFormation response.
    for _ in range(150):
        deadline(context)
        time.sleep(2)
        row=get_owned(row["CapacityReservationId"],p)
        if row is None: raise RuntimeError("Reservation disappeared")
        if row.get("State")=="active": return row
        if row.get("State") in TERMINAL: break
    raise RuntimeError("Reservation did not become active")

def recorded(p,attempt,zone=None):
    rows=[row for row in inventory(p,attempt) if row.get("State")!="failed"]
    if len(rows)>1: raise RuntimeError("Multiple reservations for one request")
    if not rows: return None
    if zone and rows[0]["AvailabilityZone"]!=zone:
        raise RuntimeError("Reservation zone changed")
    return rows[0]

def request_capacity(request,p,attempt,context):
    for number in range(1,4):
        deadline(context)
        try:
            return allocator.create_capacity_reservation(**request)
        except Exception as error:
            if code(error) in CAPACITY_ERRORS:
                if number>1:
                    # An earlier ambiguous response could still become visible.
                    # Never label a mixed failure as verified all-AZ exhaustion.
                    raise RuntimeError("Capacity response followed a transient error") from error
                raise
            if not transient(error) or number==3: raise
            row=recorded(p,attempt,request["AvailabilityZone"])
            if row: return {"CapacityReservation":row}
            note("transient "+code(error)+" in "+request["AvailabilityZone"]+
                "; retrying the same request ("+str(number+1)+"/3)")
            time.sleep(2**(number-1))

def choose(event,p,context=None):
    attempt=attempt_of(event)
    row=recorded(p,attempt)
    if row:
        # Duplicate delivery may occur after the release resource already ran.
        # Return the same identity, never allocate another reservation.
        note("reusing recorded result in "+row["AvailabilityZone"])
        if row.get("State") not in TERMINAL: row=active(row,p,context)
        return result(row)
    expires=datetime.datetime.fromisoformat(p["ExpiresAt"].replace("Z","+00:00"))
    now=datetime.datetime.now(datetime.timezone.utc)
    if not now+datetime.timedelta(minutes=2)<expires<=now+datetime.timedelta(minutes=21):
        raise RuntimeError("Capacity deadline invalid/expired; rerun Create")
    tags={"Name":p["DisplayPrefix"]+"_FortiAIGate_GPU_Capacity", "DeploymentGuide":MARKER,
        "FortiAIGateBudgetStack":event["StackId"],"BudgetStack":event["StackId"],
        "CapacityLogicalId":LOGICAL,"CapacityAttempt":attempt}
    capacity_failures=[]
    for index,zone in enumerate(p["AvailabilityZones"],1):
        note("trying "+zone+" ("+str(index)+"/"+str(len(p["AvailabilityZones"]))+") for "+p["InstanceType"])
        token=hashlib.sha256((attempt+"|"+zone).encode()).hexdigest()
        try:
            response=request_capacity(dict(AvailabilityZone=zone,
                InstanceType=p["InstanceType"],InstancePlatform="Linux/UNIX",InstanceCount=1,
                InstanceMatchCriteria="targeted",Tenancy="default",ClientToken=token,
                EndDateType="limited",EndDate=expires,
                TagSpecifications=[{"ResourceType":"capacity-reservation","Tags":[{"Key":k,"Value":v} for k,v in tags.items()]}]),p,attempt,context)
            row=validate(response["CapacityReservation"],p,attempt)
        except Exception as error:
            # A timeout may have succeeded server-side. Reconcile first and
            # never move to another AZ after an ambiguous or permission error.
            row=recorded(p,attempt,zone)
            if row is None:
                if code(error) in CAPACITY_ERRORS:
                    capacity_failures.append(zone)
                    note("unavailable in "+zone+" ("+code(error)+")")
                    continue
                raise RuntimeError("Reservation request stopped ("+code(error)+"); no further zones attempted") from error
        row=active(row,p,context)
        note("reserved one GPU in "+zone+"; creating the fixed-address VM")
        return result(row)
    if capacity_failures==p["AvailabilityZones"]:
        raise RuntimeError("CAPACITY_EXHAUSTED: No offered zone had reservable "+p["InstanceType"]+" capacity")
    raise RuntimeError("Capacity result unverified")

def release(p,context=None):
    reservation_id=p["ReservationId"]
    for _ in range(60):
        deadline(context)
        row=get_owned(reservation_id,p)
        if row is None:
            time.sleep(2)
            continue
        try: pages=ec2.describe_instances(InstanceIds=[p["InstanceId"]]).get("Reservations",[])
        except Exception as error:
            if code(error)!="InvalidInstanceID.NotFound": raise
            pages=[]
        instances=[item for page in pages for item in page.get("Instances",[])]
        if len(instances)>1: raise RuntimeError("Multiple lab instances returned")
        if not instances:
            time.sleep(2)
            continue
        instance=instances[0]
        tags=tags_of(instance)
        target=instance.get("CapacityReservationSpecification",{}).get("CapacityReservationTarget",{}).get("CapacityReservationId")
        comparisons=[(instance.get("InstanceId"),p["InstanceId"]),
            (instance.get("VpcId"),p["VpcId"]),(instance.get("SubnetId"),p["SubnetId"]),
            (instance.get("PrivateIpAddress"),p["PrivateIpAddress"]),(instance.get("InstanceType"),p["InstanceType"]),
            (instance.get("Placement",{}).get("AvailabilityZone"),row["AvailabilityZone"]),
            (tags.get("BudgetStack"),os.environ["STACK_ID"]),(tags.get("FortiAIGateBudgetStack"),os.environ["STACK_ID"]),
            (tags.get("BudgetVersion"),"8h-delete-v2"),(target,reservation_id)]
        if row.get("State") not in TERMINAL: comparisons.append((instance.get("CapacityReservationId"),reservation_id))
        # Retry absent eventual-consistency fields; never retry conflicting IDs,
        # ownership or addresses as if a different resource might become ours.
        if any(actual not in (None,"") and actual!=expected for actual,expected in comparisons):
            raise RuntimeError("Instance ownership/address mismatch")
        state=instance.get("State",{}).get("Name")
        if state not in (None,"pending","running"): raise RuntimeError("Instance stopped before capacity handoff")
        if state=="running" and all(actual==expected for actual,expected in comparisons): break
        time.sleep(2)
    else: raise RuntimeError("Instance identity unverified after two minutes")
    cancel(row,p)
    note("GPU instance verified at "+p["PrivateIpAddress"]+"; capacity hold released")
    return "released-"+reservation_id,{"Released":"true"}

def handler(event,context):
    physical=event.get("PhysicalResourceId") or "capacity-request-"+attempt_of(event)
    p=event.get("ResourceProperties",{})
    selecting=event.get("ResourceType")=="Custom::FortiAIGateCapacity"
    releasing=event.get("ResourceType")=="Custom::FortiAIGateCapacityRelease"
    try:
        if event.get("StackId")!=os.environ["STACK_ID"] or not (selecting or releasing):
            raise RuntimeError("Invalid capacity callback owner/type")
        if (p.get("InstanceType") not in APPROVED_TYPES or not p.get("AvailabilityZones")
            or len(p["AvailabilityZones"])>16
            or len(set(p["AvailabilityZones"]))!=len(p["AvailabilityZones"])
            or any(not re.fullmatch(r"us-east-1[a-z]",zone) for zone in p["AvailabilityZones"])):
            raise RuntimeError("Invalid GPU allocation configuration")
        kind=event.get("RequestType")
        if kind=="Delete":
            cleanup(p,physical if selecting else p.get("ReservationId"))
            respond(event,"SUCCESS",physical,reason="Owned capacity hold removed")
            return
        if kind not in ("Create","Update"): raise RuntimeError("Unsupported callback action")
        if kind=="Update":
            old=dict(event.get("OldResourceProperties",{})); new=dict(p)
            old.pop("ServiceToken",None); new.pop("ServiceToken",None)
            if old!=new: raise RuntimeError("Changed capacity configuration requires new lab")
            if selecting:
                row=get_owned(physical,p)
                if row is None: raise RuntimeError("Original reservation unverified")
                physical,data=result(row)
            else: physical,data=release(p,context)
        elif selecting: physical,data=choose(event,p,context)
        else: physical,data=release(p,context)
    except Exception as error:
        reason=str(error) if isinstance(error,RuntimeError) else "Capacity operation failed ("+code(error)+")"
        # A failed selector must release its own possibly successful API request.
        if selecting and event.get("StackId")==os.environ["STACK_ID"] and event.get("RequestType")=="Create":
            try: cleanup(p,attempt=attempt_of(event))
            except Exception as cleanup_error:
                # Do not let the launcher's optional fallback interpret an
                # unconfirmed cleanup as a clean all-zones capacity result.
                reason=reason.removeprefix("CAPACITY_EXHAUSTED: ")
                reason="Capacity cleanup not confirmed ("+code(cleanup_error)+"); bounded expiry remains; "+reason
        note("FAILED: "+reason[:500])
        respond(event,"FAILED",physical,reason=reason[:700])
        return
    # A response transport failure must not cancel a successfully handed-off
    # reservation: a duplicate event reconciles the same tagged request.
    respond(event,"SUCCESS",physical,data)
'''


def add_gpu_capacity_reservation(body, display_prefix, zones):
    """Keep native EC2 ownership, choose one AZ, and release its launch hold."""
    if not zones or len(zones) > 16 or len(set(zones)) != len(zones):
        raise ValueError('Choose distinct supported GPU zones.')
    if any(not reservation_re.fullmatch(r'us-east-1[a-z]', zone) for zone in zones):
        raise ValueError('GPU capacity zones must be supported us-east-1 zones.')
    result = reservation_copy.deepcopy(body)
    resources = result['Resources']
    if resources['Instance']['Type'] != 'AWS::EC2::Instance':
        raise ValueError('Capacity selection requires the native EC2 instance template.')
    required = ['BudgetCleanupRole', 'BudgetFunction', 'BudgetDeleteSchedule', 'BudgetWatchdogSchedule']
    if any(key not in resources for key in required):
        raise ValueError('Cloud-side eight-hour deletion protection is required.')
    ref = lambda key: {'Ref': key}
    get = lambda key, attr='Arn': {'Fn::GetAtt': [key, attr]}
    sub = lambda value: {'Fn::Sub': value}
    props = resources['Instance']['Properties']
    tags = {item['Key']: item['Value'] for item in props['Tags']}
    instance_type = props['InstanceType']
    if (instance_type not in ('g6e.2xlarge', 'g6e.4xlarge') or tags.get('BudgetStack') != ref('AWS::StackId')
            or tags.get('FortiAIGateBudgetStack') != ref('AWS::StackId')
            or tags.get('BudgetVersion') != '8h-delete-v2'):
        raise ValueError('Instance type or lifecycle ownership is not verified.')
    resources['BudgetFunction']['Properties']['Environment']['Variables']['EXPECTED_INSTANCE_TYPE'] = instance_type
    resources['Vpc']['Properties']['CidrBlock'] = '10.250.0.0/16'
    resources['Subnet']['Properties'].pop('AvailabilityZoneId', None)
    resources['Subnet']['Properties'].update(CidrBlock='10.250.20.0/24',
        AvailabilityZone=get('CapacityReservation', 'AvailabilityZone'))
    props['PrivateIpAddress'] = '10.250.20.10'
    # EC2::Instance has no direct CapacityReservationSpecification property.
    # Keep EC2 native ownership; its launch template supplies only the target.
    resources['CapacityLaunchTemplate'] = {'Type': 'AWS::EC2::LaunchTemplate', 'DependsOn': 'BudgetCleanupRole',
        'Properties': {'LaunchTemplateName': display_prefix + '_FortiAIGate_GPU_LaunchTemplate',
            'LaunchTemplateData': {'CapacityReservationSpecification': {'CapacityReservationTarget': {
                'CapacityReservationId': ref('CapacityReservation')}}},
            'TagSpecifications': [{'ResourceType': 'launch-template', 'Tags': [
                {'Key': 'Name', 'Value': display_prefix + '_FortiAIGate_GPU_LaunchTemplate'},
                {'Key': 'FortiAIGateBudgetStack', 'Value': ref('AWS::StackId')}]}]}}
    props['LaunchTemplate'] = {'LaunchTemplateId': ref('CapacityLaunchTemplate'),
                              'Version': get('CapacityLaunchTemplate', 'LatestVersionNumber')}
    role_name = display_prefix + '_FortiAIGate_GPU_CapacityRole'
    function_arn = sub('arn:${AWS::Partition}:lambda:${AWS::Region}:${AWS::AccountId}:function:${AWS::StackName}-capacity')
    log_name = sub('/aws/lambda/${AWS::StackName}-capacity')
    log_arn = sub('arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${AWS::StackName}-capacity')
    stream_arn = sub('arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${AWS::StackName}-capacity:*')
    reservation_arn = sub('arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:capacity-reservation/*')
    # CancelCapacityReservation supports aws:ResourceTag for this resource;
    # do not use the ec2-specific tag key accepted by other EC2 operations.
    ownership = {'aws:ResourceTag/FortiAIGateBudgetStack': ref('AWS::StackId'),
                 'aws:ResourceTag/DeploymentGuide': 'FortiAIGate-GPU-AWS-v1'}
    resources['CapacityLogs'] = {'Type': 'AWS::Logs::LogGroup', 'DependsOn': 'BudgetCleanupRole',
        'Properties': {'LogGroupName': log_name, 'RetentionInDays': 1}}
    resources['CapacityRole'] = {'Type': 'AWS::IAM::Role', 'DependsOn': 'BudgetCleanupRole', 'Properties': {
        'RoleName': role_name, 'AssumeRolePolicyDocument': {'Version': '2012-10-17', 'Statement': [{
            'Effect': 'Allow', 'Principal': {'Service': 'lambda.amazonaws.com'}, 'Action': 'sts:AssumeRole'}]},
        'Policies': [{'PolicyName': 'ManageOnlyThisCapacityHold', 'PolicyDocument': {'Version': '2012-10-17', 'Statement': [
            {'Effect': 'Allow', 'Action': ['ec2:DescribeCapacityReservations', 'ec2:DescribeInstances'], 'Resource': '*',
             'Condition': {'StringEquals': {'ec2:Region': ref('AWS::Region')}}},
            {'Effect': 'Allow', 'Action': 'ec2:CreateCapacityReservation', 'Resource': reservation_arn,
             'Condition': {'StringEquals': {'aws:RequestTag/FortiAIGateBudgetStack': ref('AWS::StackId'),
                'aws:RequestTag/DeploymentGuide': 'FortiAIGate-GPU-AWS-v1', 'ec2:InstanceType': instance_type,
                'ec2:InstanceMatchCriteria': 'targeted', 'ec2:InstancePlatform': 'Linux/UNIX',
                'ec2:Tenancy': 'default', 'ec2:EndDateType': 'limited', 'ec2:AvailabilityZone': list(zones)},
                'NumericEquals': {'ec2:InstanceCount': 1}}},
            {'Effect': 'Allow', 'Action': 'ec2:CreateTags', 'Resource': reservation_arn,
             'Condition': {'StringEquals': {'ec2:CreateAction': 'CreateCapacityReservation',
                'aws:RequestTag/FortiAIGateBudgetStack': ref('AWS::StackId')}}},
            {'Effect': 'Allow', 'Action': 'ec2:CancelCapacityReservation', 'Resource': reservation_arn,
             'Condition': {'StringEquals': ownership}},
            {'Effect': 'Allow', 'Action': ['logs:CreateLogStream', 'logs:PutLogEvents'], 'Resource': stream_arn}]}}]}}
    resources['CapacityFunction'] = {'Type': 'AWS::Lambda::Function', 'DependsOn': ['BudgetCleanupRole', 'CapacityLogs'],
        'Properties': {'FunctionName': sub('${AWS::StackName}-capacity'), 'Runtime': 'python3.13',
            'Handler': 'index.handler', 'Role': get('CapacityRole'), 'MemorySize': 128, 'Timeout': 600,
            'Environment': {'Variables': {'STACK_ID': ref('AWS::StackId')}}, 'Code': {'ZipFile': CAPACITY_PROVIDER}}}
    common = {'ServiceToken': get('CapacityFunction'), 'ServiceTimeout': 660,
              'InstanceType': instance_type, 'AvailabilityZones': list(zones), 'DisplayPrefix': display_prefix}
    expires = reservation_datetime.datetime.now(reservation_datetime.timezone.utc) + reservation_datetime.timedelta(minutes=20)
    resources['CapacityReservation'] = {'Type': 'Custom::FortiAIGateCapacity', 'DependsOn': required,
        'Properties': dict(common, ExpiresAt=expires.replace(microsecond=0).isoformat().replace('+00:00', 'Z'))}
    resources['CapacityRelease'] = {'Type': 'Custom::FortiAIGateCapacityRelease', 'DependsOn': ['Instance', 'BudgetCleanupRole'],
        'Properties': dict(common, ReservationId=ref('CapacityReservation'), InstanceId=ref('Instance'),
            VpcId=ref('Vpc'), SubnetId=ref('Subnet'), PrivateIpAddress='10.250.20.10')}
    result.setdefault('Outputs', {}).update(CapacityReservationId={'Value': ref('CapacityReservation')},
        AvailabilityZone={'Value': get('CapacityReservation', 'AvailabilityZone')},
        CapacityLogGroup={'Value': log_name}, InstanceType={'Value': instance_type})
    cleanup = resources['BudgetCleanupRole']['Properties']['Policies'][0]['PolicyDocument']['Statement']
    cleanup.extend([
        {'Effect': 'Allow', 'Action': 'ec2:DeleteLaunchTemplate',
         'Resource': sub('arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:launch-template/*'),
         'Condition': {'StringEquals': {'ec2:ResourceTag/FortiAIGateBudgetStack': ref('AWS::StackId')}}},
        {'Effect': 'Allow', 'Action': ['lambda:InvokeFunction', 'lambda:GetFunction', 'lambda:GetFunctionConfiguration',
            'lambda:ListTags', 'lambda:DeleteFunction'], 'Resource': function_arn},
        {'Effect': 'Allow', 'Action': ['iam:GetRole', 'iam:GetRolePolicy', 'iam:ListRolePolicies', 'iam:ListAttachedRolePolicies',
            'iam:ListInstanceProfilesForRole', 'iam:ListRoleTags', 'iam:DeleteRolePolicy', 'iam:DetachRolePolicy', 'iam:DeleteRole'],
         'Resource': sub('arn:${AWS::Partition}:iam::${AWS::AccountId}:role/' + role_name)},
        {'Effect': 'Allow', 'Action': ['logs:DeleteLogGroup', 'logs:ListTagsForResource'], 'Resource': [log_arn, stream_arn]}])
    return result

"""Submit one owned capacity-selection stack with a native fixed-IP instance."""


class GpuCapacityExhausted(RuntimeError):
    """All offered zones failed for capacity, and the failed lab is fully removed."""


def gpu_capacity_failure_evidence(stack_id,token):
    found=False
    for event in failover_pages('cloudformation','describe-stack-events','StackEvents',StackName=stack_id):
        if event.get('StackId')!=stack_id or event.get('ClientRequestToken')!=token:
            continue
        if event.get('ResourceStatus')!='CREATE_FAILED': continue
        if event.get('ResourceType')=='AWS::CloudFormation::Stack': continue
        reason=event.get('ResourceStatusReason','')
        if (event.get('LogicalResourceId')=='CapacityReservation'
                and event.get('ResourceType')=='Custom::FortiAIGateCapacity'
                and failover_re.search(r'Message returned: CAPACITY_EXHAUSTED:',reason)):
            found=True
        elif failover_re.fullmatch(r'Resource creation cancel(?:led|ed)\.?',reason.strip(),failover_re.I):
            continue
        else:
            return False
    return found


def create_gpu_stack_with_capacity(name, prefix, body, expected_account=None):
    account = expected_account or identity()["Account"]
    if (not failover_re.fullmatch(r"[a-z][a-z0-9]{0,23}", prefix)
            or name != "FortiAIGate-GPU-" + prefix
            or not failover_re.fullmatch(r"[0-9]{12}", account)):
        raise ValueError("Invalid lab identity for the GPU allocation.")
    resources = body["Resources"]
    instance = resources["Instance"]
    properties = resources["CapacityReservation"]["Properties"]
    if (instance["Type"] != "AWS::EC2::Instance"
            or instance["Properties"].get("InstanceType") not in ("g6e.2xlarge","g6e.4xlarge")
            or instance["Properties"].get("PrivateIpAddress") != "10.250.20.10"
            or resources["Subnet"]["Properties"].get("CidrBlock") != "10.250.20.0/24"
            or any(r.get("Type") == "AWS::EC2::EC2Fleet" for r in resources.values())):
        raise ValueError("The approved plan must launch one native GPU at 10.250.20.10.")
    if properties.get("InstanceType", instance["Properties"]["InstanceType"]) != instance["Properties"]["InstanceType"]:
        raise ValueError("Reservation and native instance types must match.")
    failover_budget_available(body)
    retained = [key for key, resource in resources.items()
                if resource.get("DeletionPolicy") not in (None, "Delete")
                and not (key == "BudgetCleanupRole"
                         and resource.get("DeletionPolicy") == "RetainExceptOnCreate")]
    if retained:
        raise ValueError("Unexpected retained resources prevent automatic rollback cleanup.")
    serialized = failover_json.dumps(body, separators=(",", ":"))
    if len(serialized.encode("utf-8")) > 51200:
        raise ValueError("The template exceeds CloudFormation's inline limit; no lab was submitted.")
    token = "fortiaigate-gpu-" + failover_uuid.uuid4().hex
    failover_note("Create capacity controller → try supported zones → launch ONE GPU at 10.250.20.10")
    with failover_tempfile.TemporaryDirectory(prefix="fortiaigate-gpu-capacity-") as directory:
        path = FailoverPath(directory) / "stack.json"
        path.write_text(serialized, encoding="utf-8")
        failover_aws("cloudformation", "validate-template", "--template-body", "file://" + str(path))
        try:
            result = failover_aws("cloudformation", "create-stack", StackName=name,
                TemplateBody=serialized, OnFailure="ROLLBACK", ClientRequestToken=token,
                Capabilities=["CAPABILITY_NAMED_IAM"], Tags=[
                    {"Key": "DeploymentGuide", "Value": MARKER}, {"Key": "UserPrefix", "Value": prefix},
                    {"Key": "ScriptVersion", "Value": VERSION}, {"Key": "CapacityAttempt", "Value": token},
                    {"Key": "InstanceType", "Value": instance["Properties"]["InstanceType"]}])
        except (failover_subprocess.TimeoutExpired, OSError) as error:
            raise RuntimeError("The CreateStack response is uncertain. No second launch was submitted; inspect "
                               + name + " before running Create again.") from error
    stack_id = result.get("StackId")
    failover_stack_identity(stack_id, name, account)
    print("Created managed GPU request: " + stack_id, flush=True)
    try:
        stack = wait_stack(stack_id, "CREATE_COMPLETE")
    except (AwsError, RuntimeError) as failure:
        current = failover_describe(stack_id, prefix, account, token, optional=True)
        status = current.get("StackStatus") if current else None
        if status in ("ROLLBACK_COMPLETE", "CREATE_FAILED", "ROLLBACK_IN_PROGRESS", "DELETE_COMPLETE"):
            capacity_only=gpu_capacity_failure_evidence(stack_id,token)
            failover_note("The GPU deployment failed; cleaning its owned resources")
            failover_cleanup_attempt(stack_id, prefix, account, token,
                resources["BudgetCleanupRole"]["Properties"]["RoleName"])
            if capacity_only:
                raise GpuCapacityExhausted("All selected zones rejected the capacity hold; the failed stack and cleanup role were removed.") from failure
            raise RuntimeError("The GPU request failed and its lab stack was removed. "
                               "No second stack or instance was launched. " + str(failure)) from failure
        raise RuntimeError("The GPU status could not be confirmed. No replacement was launched or healthy lab deleted; "
                           "inspect the same stack before another action. " + str(failure)) from failure
    if stack.get("StackId") != stack_id:
        raise RuntimeError("Creation returned another stack; no additional launch was started.")
    return stack

"""One explicitly approved larger L40S fallback after verified cleanup."""
import copy as size_copy
import datetime as size_datetime
from decimal import Decimal as SizeDecimal, ROUND_HALF_UP as SIZE_ROUND

GPU_SIZE_RATES = {'g6e.2xlarge': SizeDecimal('2.24208'), 'g6e.4xlarge': SizeDecimal('3.00424')}


def gpu_cost_values(instance_type):
    rate = GPU_SIZE_RATES[instance_type] + SizeDecimal('40')/730 + SizeDecimal('0.005')
    return {hours: '$'+str((rate*hours).quantize(SizeDecimal('0.01'), rounding=SIZE_ROUND)) for hours in (1,6,24)}


def gpu_cost_box(instance_type, title='Estimated lab cost'):
    if instance_type not in GPU_SIZE_RATES:
        raise ValueError('Only reviewed L40S instance sizes are allowed.')
    values = gpu_cost_values(instance_type)
    red = '\033[91m' if sys.stdout.isatty() else ''
    reset = '\033[0m' if red else ''
    width = 92
    print('\n'+'#'*width)
    def line(text):
        visible=failover_re.sub(r'\x1b\[[0-9;]*m','',text)
        print('# '+text+' '*max(0,width-4-len(visible))+' #')
    line(title)
    line(instance_type + (' | 16 vCPU | 128 GiB RAM | 1 x L40S' if instance_type=='g6e.4xlarge' else ' | 8 vCPU | 64 GiB RAM | 1 x L40S'))
    line('Estimated lab cost: 1 hour '+red+values[1]+reset+' | 6 hours '+red+values[6]+reset+' | 1 day '+red+values[24]+reset)
    line('Includes 500 GiB gp3 and one public IPv4; Linux On-Demand, us-east-1.')
    line('Rates checked 1 Nov 2026. Licensing, transfer, S3 and management extra.')
    line('Capacity holds bill before launch. Stopped disks and Elastic IPs still cost money.')
    if instance_type=='g6e.4xlarge':
        line('Increase: '+red+'$0.76/hour'+reset+' (about 33%). Availability is not guaranteed.')
    line('No auto-stop. Initial deadline: 8 hours from original Create approval.')
    line('Auto-delete: complete lab destruction at the deadline. Manual Extend adds 8 hours.')
    print('#'*width,flush=True)


def gpu_larger_preflight(selected_zone=None):
    """Read-only checks for the next approved size; never treat an offering as capacity."""
    size='g6e.4xlarge'
    print('Checking larger size '+size+' hardware, quota and supported zones...',flush=True)
    data=failover_aws('ec2','describe-instance-types',InstanceTypes=[size]).get('InstanceTypes',[])
    if len(data)!=1: raise RuntimeError('AWS did not return exactly one larger-size specification.')
    spec=data[0];gpus=spec.get('GpuInfo',{}).get('Gpus',[])
    if (len(gpus)!=1 or failover_re.sub(r'^NVIDIA\s+','',gpus[0].get('Name',''),flags=failover_re.I).upper()!='L40S'
            or gpus[0].get('Count')!=1 or gpus[0].get('MemoryInfo',{}).get('SizeInMiB',0)<44000
            or spec.get('VCpuInfo',{}).get('DefaultVCpus')!=16
            or spec.get('MemoryInfo',{}).get('SizeInMiB')!=131072):
        raise RuntimeError('Larger-size hardware is not the approved full L40S / 16 vCPU / 128 GiB configuration.')
    # A denied/unknown quota check stops rather than approving unverified growth.
    quota=failover_aws('service-quotas','get-service-quota',ServiceCode='ec2',QuotaCode='L-DB2E81BA')['Quota']['Value']
    if quota<16: raise RuntimeError('The larger size requires a G/VT On-Demand quota of at least 16 vCPUs.')
    print('G/VT quota: '+str(quota)+' vCPUs; this VM needs 16 available vCPUs (other usage counts).',flush=True)
    result=failover_aws('ec2','describe-instance-type-offerings',LocationType='availability-zone',
        Filters=[{'Name':'instance-type','Values':[size]}])
    offers={r['Location'] for r in result.get('InstanceTypeOfferings',[])}
    zones=failover_aws('ec2','describe-availability-zones',Filters=[{'Name':'state','Values':['available']}]).get('AvailabilityZones',[])
    offered=sorted(z['ZoneName'] for z in zones if z['ZoneName'] in offers and z.get('ZoneType','availability-zone')=='availability-zone')
    if selected_zone:
        if selected_zone not in offered: raise RuntimeError('The manually selected zone does not offer the larger size; no fallback submitted.')
        offered=[selected_zone]
    if not offered: raise RuntimeError('No supported zone offers '+size+' for this account.')
    print('Larger-size supported zones: '+', '.join(offered)+'; real capacity is checked next.',flush=True)
    return offered


def gpu_larger_body(body,zones):
    """Change only the approved hardware and hold; keep original lifecycle deadlines."""
    result=size_copy.deepcopy(body);resources=result['Resources'];size='g6e.4xlarge'
    if resources['Instance']['Properties'].get('InstanceType')!='g6e.2xlarge':
        raise ValueError('Only the initial smaller-size plan can be upgraded once.')
    if not zones or len(set(zones))!=len(zones) or any(not failover_re.fullmatch(r'us-east-1[a-z]',z) for z in zones):
        raise ValueError('Invalid larger-size zones.')
    resources['Instance']['Properties']['InstanceType']=size
    resources['BudgetFunction']['Properties']['Environment']['Variables']['EXPECTED_INSTANCE_TYPE']=size
    for key in ('CapacityReservation','CapacityRelease'):
        resources[key]['Properties'].update(InstanceType=size,AvailabilityZones=list(zones))
    expires=size_datetime.datetime.now(size_datetime.timezone.utc)+size_datetime.timedelta(minutes=20)
    resources['CapacityReservation']['Properties']['ExpiresAt']=expires.replace(microsecond=0).isoformat().replace('+00:00','Z')
    statements=resources['CapacityRole']['Properties']['Policies'][0]['PolicyDocument']['Statement']
    create=[row for row in statements if row.get('Action')=='ec2:CreateCapacityReservation']
    if len(create)!=1: raise RuntimeError('Larger-size capacity permission could not be identified.')
    create[0]['Condition']['StringEquals']['ec2:InstanceType']=size
    create[0]['Condition']['StringEquals']['ec2:AvailabilityZone']=list(zones)
    result.setdefault('Outputs',{})['InstanceType']={'Value':size}
    result.setdefault('Metadata',{})['EstimatedLabCost']={'InstanceType':size,
        'USD':{str(k)+'h':v for k,v in gpu_cost_values(size).items()},'PricingDate':'2026-11-01'}
    failover_budget_available(result)
    return result


def create_gpu_stack_with_size_fallback(name,prefix,body,offered,selected_zone=None,expected_account=None):
    try:
        return create_gpu_stack_with_capacity(name,prefix,body,expected_account=expected_account)
    except GpuCapacityExhausted:
        # The dedicated exception is raised only after all-zone capacity evidence
        # and deletion of the owned failed stack + cleanup role are confirmed.
        gpu_cost_box('g6e.4xlarge','CURRENT SIZE HAS NO RESERVABLE CAPACITY — TRY NEXT SIZE?')
        if input('1) Try g6e.4xlarge at the displayed cost  0) Cancel [0]: ').strip()!='1':
            raise RuntimeError('Cancelled. The original failed lab was removed; no larger instance was requested.')
        failover_budget_available(body)
        zones=gpu_larger_preflight(selected_zone)
        upgraded=gpu_larger_body(body,zones)
        print('Approved larger-size attempt: g6e.4xlarge. Original 8-hour deletion deadline is preserved.',flush=True)
        # There is no third size or implicit purchase after this single approval.
        return create_gpu_stack_with_capacity(name,prefix,upgraded,expected_account=expected_account)


def main():
    caller = identity()
    global DISPLAY_PREFIX
    raw_prefix = input("Name prefix (case-insensitive, letters/numbers): ").strip()
    prefix = prefix_of(raw_prefix)
    DISPLAY_PREFIX = raw_prefix[:-len("_FortiAIGate_GPU_VPC")] if raw_prefix.casefold().endswith("_fortiaigate_gpu_vpc") else raw_prefix
    name = stack_name(prefix)
    existing = describe_stack(name, optional=True)
    if existing:
        owned(existing)
        if existing["StackStatus"] != "CREATE_COMPLETE":
            raise RuntimeError("The GPU stack already exists with status " + existing["StackStatus"] + ". Inspect it or use GPU Destroy before retrying.")
        print("This GPU lab already exists; no resources were changed.")
        version = {o["OutputKey"]: o["OutputValue"] for o in existing.get("Outputs", [])}.get("PreparationVersion")
        if version == VERSION:
            update_aws_budget(aws, existing, "use")
            instance_id = {o["OutputKey"]: o["OutputValue"] for o in existing.get("Outputs", [])}["InstanceId"]
            wait_for_gpu_preparation(instance_id)
        else:
            print("This existing stack uses another GPU/preparation revision. No hardware or startup script was changed. Keep its matching guide or use a separate new lab name.")
        outputs(existing)
        return
    aws_budget_creation_preflight(prefix)
    cidr = request_browser_ipv4(caller["Arn"])
    bucket = os.environ.get("FORTIAIGATE_GPU_RELEASE_BUCKET", "wrady-fortiaigate-lab").strip()
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket) or ".." in bucket:
        raise ValueError("Enter a bucket name only, not an s3:// URL.")
    release_prefix = os.environ.get("FORTIAIGATE_GPU_RELEASE_PREFIX", "FortiAIGate_8.0.2_GPU").strip().strip("/")
    if not re.fullmatch(r"[A-Za-z0-9_./-]+", release_prefix) or any(p in (".", "..", "") for p in release_prefix.split("/")):
        raise ValueError("Use a nonempty S3 folder with letters, numbers, underscore, dash, dot or slash.")
    print("GPU release source: s3://" + bucket + "/" + release_prefix + "/", flush=True)
    print("Checking GPU hardware, AMI, quota and available-zone offerings...", flush=True)
    spec = aws("ec2", "describe-instance-types", "--instance-types", INSTANCE_TYPE)["InstanceTypes"][0]
    gpus = spec.get("GpuInfo", {}).get("Gpus", [])
    if len(gpus) != 1 or re.sub(r"^NVIDIA\s+", "", gpus[0].get("Name", ""), flags=re.IGNORECASE).upper() != "L40S" or gpus[0].get("Count") != 1:
        raise RuntimeError("AWS did not report exactly one L40S for g6e.2xlarge; refusing to continue.")
    gpu_memory = gpus[0].get("MemoryInfo", {}).get("SizeInMiB", spec.get("GpuInfo", {}).get("TotalGpuMemoryInMiB", 0))
    if gpu_memory < 44000:
        raise RuntimeError("AWS did not report a full L40S with at least 44000 MiB GPU memory; refusing to continue.")
    if spec["VCpuInfo"]["DefaultVCpus"] != 8 or spec["MemoryInfo"]["SizeInMiB"] != 65536:
        raise RuntimeError("AWS CPU/RAM specifications differ from the guide; refusing to continue.")
    try:
        quota = aws("service-quotas", "get-service-quota", "--service-code", "ec2", "--quota-code", "L-DB2E81BA")["Quota"]["Value"]
        print("G/VT On-Demand quota: " + str(quota) + " vCPUs; this VM needs 8 additional available vCPUs.")
        if quota < 8:
            raise RuntimeError("Request a Running On-Demand G and VT instances quota of at least 8 vCPUs in us-east-1 first.")
    except AwsError as error:
        print("Quota could not be read; verify 8 available G/VT vCPUs in Service Quotas. " + str(error))
    offerings = aws("ec2", "describe-instance-type-offerings", "--location-type", "availability-zone", "--filters", "Name=instance-type,Values=" + INSTANCE_TYPE)
    offered = {x["Location"] for x in offerings.get("InstanceTypeOfferings", [])}
    zones = aws("ec2", "describe-availability-zones", "--filters", "Name=state,Values=available")["AvailabilityZones"]
    offered = sorted(z["ZoneName"] for z in zones if z["ZoneName"] in offered and z.get("ZoneType", "availability-zone") == "availability-zone")
    if not offered:
        raise RuntimeError("No enabled us-east-1 Availability Zone offers g6e.2xlarge for this account.")
    offered = rank_gpu_zones(offered, zones)
    zone = choose_availability_zone(offered)
    ami = aws("ssm", "get-parameter", "--name", AMI_PARAMETER)["Parameter"]["Value"]
    image = aws("ec2", "describe-images", "--image-ids", ami)["Images"][0]
    if image.get("OwnerId") != "099720109477" or image.get("Architecture") != "x86_64" or image.get("State") != "available" or image.get("VirtualizationType") != "hvm" or image.get("RootDeviceType") != "ebs" or not image.get("Name", "").startswith("ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-"):
        raise RuntimeError("AMI failed the Canonical Ubuntu 22.04 x86_64 publisher/release check.")
    # Staging access is read-only; the script never makes the bucket public.
    staged = aws("s3api", "list-objects-v2", "--bucket", bucket, "--prefix", release_prefix + "/", "--expected-bucket-owner", caller["Account"])
    missing = missing_release_files(staged.get("Contents", []), release_prefix)
    if missing:
        raise RuntimeError("The full matching GPU release is not staged. Missing, empty or ambiguous files:\n  " + "\n  ".join(missing) + "\nNo GPU resources were created.")
    print("Staged release size: %.2f GiB (filenames present; verify Fortinet checksums separately)." % (sum(row.get("Size", 0) for row in staged.get("Contents", [])) / 1024**3))
    preparation_preflight()
    body = template(prefix, cidr, ami, image["RootDeviceName"], zone, bucket, release_prefix)
    print("\nCreate " + name + " in " + availability_zone_label(zone) + ": 1 L40S / 8 vCPU / 64 GiB RAM / 500 GiB encrypted gp3.")
    print("NO AUTO-STOP: the lab keeps running until you destroy it or its fixed deletion deadline.")
    print("AUTO-DELETE: complete lab stack 8 hours after Create approval, including setup. No snapshots.")
    print("Use launcher option 5 to add 8 hours. Connect, Restart and browser/SSH activity never extend it. A watchdog checks every 5 minutes.")
    print("Shared final-cleanup service removes retired lab cleanup roles automatically (checks every 5 minutes).")
    print("The shared service remains for reuse; Lambda/logging usage is separate. Launcher option 6 removes it when unused.")
    print("Estimated continuous infrastructure cost: $2.30/hour (~$1,680/month); licensing/traffic extra.")
    print("HTTPS source: " + cidr + "; SSH is not opened. S3 access is read-only to the selected folder.")
    if (input("1) Create (default)  0) Cancel [1]: ").strip() or "1") != "1":
        print("Cancelled. No resources were created.")
        return
    body = template(prefix, cidr, ami, image["RootDeviceName"], zone, bucket, release_prefix)
    body = compact_gpu_template(defer_gpu_workload_iam(add_gpu_capacity_reservation(body, DISPLAY_PREFIX, [zone] if zone else offered)))
    start_progress_timer(total_resources=len(body['Resources']))
    ensure_gpu_janitor()
    stack = create_gpu_stack_with_size_fallback(name, prefix, body, offered, zone,
                                        expected_account=caller["Account"])
    instance_id = {o["OutputKey"]: o["OutputValue"] for o in stack["Outputs"]}["InstanceId"]
    wait_for_gpu_preparation(instance_id)
    outputs(stack)


if __name__ == "__main__":
    try:
        if len(sys.argv) == 2 and sys.argv[1] in ("--connect", "--restart", "--extend"):
            aws_budget_action(sys.argv[1][2:])
        elif len(sys.argv) == 2 and sys.argv[1] == "--remove-cleanup":
            print("Remove the shared final-cleanup Lambda, role, schedule and logs only when no GPU labs need them.")
            if input("1) Remove shared service  0) Cancel [0]: ").strip() == "1":
                remove_gpu_janitor()
            else:
                print("Cancelled; the shared cleanup service was kept.")
        elif len(sys.argv) == 1:
            main()
        else:
            raise ValueError("Use --connect, --restart, --extend, --remove-cleanup, or no argument for Create.")
    except (AwsError, RuntimeError, ValueError, OSError, KeyError) as error:
        print("\nSTOPPED: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        sys.exit("Stopped. Any submitted CloudFormation operation continues; inspect its status before retrying.")

FORTIAIGATE_GPU_PY
python3 "$forti_gpu_script" "$@"
