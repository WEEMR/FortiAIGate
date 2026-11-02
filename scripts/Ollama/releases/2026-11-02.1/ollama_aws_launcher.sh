#!/usr/bin/env bash
# Ollama test lab on a NEW EC2 host beside an existing FortiAIGate CPU/GPU host.
# Run in AWS CloudShell. Version 2026-11-02.1. No cloud API calls for --self-test/--template/--help.
set -euo pipefail
command -v python3 >/dev/null || { printf 'Python 3 is required. Use AWS CloudShell.\n' >&2; exit 1; }
ollama_launcher_python=$(mktemp "${TMPDIR:-/tmp}/ollama-aws.XXXXXXXX.py")
trap 'rm -f -- "$ollama_launcher_python"' EXIT
cat > "$ollama_launcher_python" <<'OLLAMA_AWS_PY'
import argparse
import base64
import datetime
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import warnings

VERSION = "2026-11-02.1"
LAB_SUBNET_CIDR = "10.250.20.0/24"
MARKER = "FortiAIGate-Ollama-AWS-v1"
AMI_PARAMETER = "/aws/service/canonical/ubuntu/server/noble/stable/current/amd64/hvm/ebs-gp3/ami-id"
PREP_URL = "https://raw.githubusercontent.com/WEEMR/FortiAIGate/ollama-2026-11-02.1/scripts/Ollama/releases/2026-11-02.1/prepare_ollama.sh"
PREP_SHA256 = "3623fafd5bb1822fb096008fc2f4a5a04c2521f10506e9ee4c2610366a42ab19"
REGION = "us-east-1"
os.environ.update(AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off")


class AwsError(RuntimeError):
    pass


GATEWAY_CA_PATH = "/opt/ollama-lab/fortiaigate-ca.crt"
GATEWAY_CA_METADATA_PATH = "/opt/ollama-lab/fortiaigate-ca.json"
GATEWAY_CERTIFICATE_FAILURES = {
    "link": "The Ollama instance and its linked gateway network/identity could not be verified.",
    "state": "Start both the Ollama instance and its linked FortiAIGate instance before enrollment.",
    "ssm": "Session Manager could not confirm the certificate operation; check both instances and SSM permissions.",
    "certificate_format": "The gateway did not return one valid public PEM certificate; private keys and certificate bundles are not accepted.",
    "certificate_identity": "The gateway public certificate is expired or does not cover its verified private IP address.",
    "gateway_read": "The public certificate could not be read from faig-nginx through Session Manager.",
    "existing_certificate": "A different or unreadable certificate already exists on Ollama and was preserved; review it manually before replacement.",
    "existing_metadata": "Existing certificate enrollment metadata belongs to another certificate or gateway and was preserved.",
    "existing_access": "Existing gateway access metadata is unsafe or conflicts with the selected deployment and was preserved; review its gateway IP, instance ID and API port before retrying.",
    "tls": "Strict TLS verification of the live gateway failed; existing trust files were preserved.",
    "busy": "Ollama installation or configuration is running; wait for it to finish before retrying enrollment.",
    "install": "Certificate file promotion could not be confirmed; inspect the trust files through Session Manager before retrying.",
}


class GatewayCertificateError(RuntimeError):
    def __init__(self, code):
        self.code = code if isinstance(code, str) and code in GATEWAY_CERTIFICATE_FAILURES else "ssm"
        super().__init__(GATEWAY_CERTIFICATE_FAILURES[self.code]
            + " VM retained. Choose menu 8 to retry, or use sudo ollama-lab configure --manual with a verified gateway URL and public CA certificate.")


def public_certificate(pem):
    if not isinstance(pem, str) or not 64 <= len(pem) <= 16384 or "PRIVATE KEY" in pem:
        raise GatewayCertificateError("certificate_format")
    try:
        pem.encode("ascii")
        normalized = pem.replace("\r\n", "\n").strip() + "\n"
        match = re.fullmatch(r"-----BEGIN CERTIFICATE-----\n([A-Za-z0-9+/=\n]+)-----END CERTIFICATE-----\n", normalized)
        if not match:
            raise ValueError
        der = base64.b64decode(match[1].replace("\n", ""), validate=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cadata=normalized)
    except (ValueError, UnicodeError, ssl.SSLError):
        raise GatewayCertificateError("certificate_format") from None
    return normalized, hashlib.sha256(der).hexdigest()


def gateway_certificate_link(stack):
    assert_owned(stack)
    if stack.get("StackStatus") not in ("CREATE_COMPLETE", "UPDATE_COMPLETE"):
        raise GatewayCertificateError("state")
    tags = {tag["Key"]: tag["Value"] for tag in stack.get("Tags", [])}
    outputs = stack_outputs(stack)
    gateway_id, vpc_id = tags["FortiAIGateInstanceId"], tags["FortiAIGateVpcId"]
    if outputs.get("GatewayInstanceId", gateway_id) != gateway_id:
        raise GatewayCertificateError("link")
    instance = managed_instance(stack)
    child_tags = {tag["Key"]: tag["Value"] for tag in instance.get("Tags", [])}
    if (instance.get("VpcId") != vpc_id or child_tags.get("FortiAIGateVpcId") != vpc_id
            or child_tags.get("FortiAIGateInstanceId") != gateway_id
            or (outputs.get("PrivateIp") and outputs["PrivateIp"] != instance.get("PrivateIpAddress"))):
        raise GatewayCertificateError("link")
    gateway = instance_by_id(gateway_id)
    if (gateway.get("InstanceId") != gateway_id or gateway.get("VpcId") != vpc_id
            or any(tag.get("Key") == "DeploymentGuide" and tag.get("Value") == MARKER for tag in gateway.get("Tags", []))):
        raise GatewayCertificateError("link")
    if instance.get("State", {}).get("Name") != "running" or gateway.get("State", {}).get("Name") != "running":
        raise GatewayCertificateError("state")
    try:
        for host in (gateway, instance):
            address = ipaddress.IPv4Address(host.get("PrivateIpAddress", ""))
            if not any(address in ipaddress.IPv4Network(block) for block in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
                raise ValueError
        gateway_ip = str(ipaddress.IPv4Address(gateway["PrivateIpAddress"]))
        if outputs.get("GatewayPrivateIp", gateway_ip) != gateway_ip:
            raise ValueError
        port = gateway_api_port(outputs.get("GatewayApiPort", "443"))
    except (ValueError, KeyError):
        raise GatewayCertificateError("link") from None
    return instance, gateway, gateway_ip, port


def certificate_ssm_json(instance_id, script, phase):
    try:
        command = aws("ssm", "send-command", DocumentName="AWS-RunShellScript", InstanceIds=[instance_id],
            TimeoutSeconds=60, Parameters={"commands": [script], "executionTimeout": ["120"]})
        command_id = command["Command"]["CommandId"]
        if not isinstance(command_id, str) or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", command_id):
            raise ValueError
        output = wait_ssm_result(command_id, instance_id, timeout=180, phase=phase)
    except (AwsError, RuntimeError, ValueError, KeyError, OSError, subprocess.TimeoutExpired):
        raise GatewayCertificateError("ssm") from None
    try:
        if not isinstance(output, str) or len(output.encode("utf-8")) > 20000:
            raise ValueError
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError
                result[key] = value
            return result
        result = json.loads(output, object_pairs_hook=unique)
        if not isinstance(result, dict) or type(result.get("schema_version")) is not int or result["schema_version"] != 1:
            raise ValueError
    except (ValueError, UnicodeError):
        raise GatewayCertificateError("certificate_format") from None
    if result.get("status") == "error":
        raise GatewayCertificateError(result.get("code"))
    return result


def gateway_certificate_read_script(gateway_ip):
    script = r'''import base64,hashlib,ipaddress,json,re,ssl,subprocess,tempfile
from pathlib import Path
expected_ip = GATEWAY_IP_VALUE
code = "gateway_read"
try:
    ipaddress.IPv4Address(expected_ip)
    result = subprocess.run(["docker","exec","faig-nginx","cat","/etc/nginx/certs/tls.crt"],
        capture_output=True,timeout=30,check=True)
    code = "certificate_format"
    if not 64 <= len(result.stdout) <= 16384:
        raise ValueError()
    pem = result.stdout.decode("ascii").replace("\r\n","\n").strip()+"\n"
    match = re.fullmatch(r"-----BEGIN CERTIFICATE-----\n([A-Za-z0-9+/=\n]+)-----END CERTIFICATE-----\n",pem)
    if "PRIVATE KEY" in pem or not match:
        raise ValueError()
    der = base64.b64decode(match[1].replace("\n",""),validate=True)
    ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cadata=pem)
    code = "certificate_identity"
    with tempfile.TemporaryDirectory(prefix="ollama-gateway-public-cert-") as directory:
        public_file = Path(directory) / "certificate.pem"
        public_file.write_text(pem)
        public_file.chmod(0o600)
        subprocess.run(["openssl","verify","-partial_chain","-purpose","sslserver","-CAfile",str(public_file),
            "-verify_ip",expected_ip,str(public_file)],capture_output=True,timeout=15,check=True)
    print(json.dumps({"schema_version":1,"status":"public_certificate","gateway_private_ip":expected_ip,
        "certificate_sha256":hashlib.sha256(der).hexdigest(),"pem":pem}))
except Exception:
    print(json.dumps({"schema_version":1,"status":"error","code":code}))
'''.replace("GATEWAY_IP_VALUE", repr(gateway_ip))
    return "set +x\n/usr/bin/python3 - <<'OLLAMA_GATEWAY_CERT_READ'\n" + script + "\nOLLAMA_GATEWAY_CERT_READ"


def gateway_certificate_install_script(gateway_ip, gateway_id, port, pem, fingerprint):
    payload = {"gateway_private_ip": gateway_ip, "gateway_instance_id": gateway_id,
               "api_port": port, "pem": pem, "certificate_sha256": fingerprint}
    script = r'''import base64,datetime,fcntl,hashlib,ipaddress,json,os,re,socket,ssl,stat,tempfile
from pathlib import Path
data = json.loads(CERTIFICATE_DATA_VALUE)
root = Path("/opt/ollama-lab")
state = Path("/var/lib/ollama-lab")
certificate = root / "fortiaigate-ca.crt"
metadata_file = root / "fortiaigate-ca.json"
access_file = state / "gateway-access.json"
code = "install"
staged = []
previous = {}
promoted = []
lock = None
def certificate_value(value):
    if not isinstance(value,str) or not 64 <= len(value) <= 16384 or "PRIVATE KEY" in value:
        raise ValueError()
    value.encode("ascii")
    normalized = value.replace("\r\n","\n").strip()+"\n"
    match = re.fullmatch(r"-----BEGIN CERTIFICATE-----\n([A-Za-z0-9+/=\n]+)-----END CERTIFICATE-----\n",normalized)
    if not match:
        raise ValueError()
    der = base64.b64decode(match[1].replace("\n",""),validate=True)
    ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cadata=normalized)
    return normalized,hashlib.sha256(der).hexdigest()
def unique_json(content):
    def unique(pairs):
        result = {}
        for key,value in pairs:
            if key in result:
                raise ValueError()
            result[key] = value
        return result
    value = json.loads(content,object_pairs_hook=unique)
    if not isinstance(value,dict):
        raise ValueError()
    return value
def temporary(content,mode=0o600,directory=None):
    descriptor,path = tempfile.mkstemp(prefix=".fortiaigate-ca-",dir=directory or root)
    path = Path(path)
    staged.append(path)
    with os.fdopen(descriptor,"wb") as stream:
        os.fchown(stream.fileno(),0,0)
        os.fchmod(stream.fileno(),mode)
        stream.write(content)
    return path
try:
    if os.geteuid()!=0 or root.is_symlink() or state.is_symlink():
        raise ValueError()
    root.mkdir(mode=0o700,parents=True,exist_ok=True)
    state.mkdir(mode=0o700,parents=True,exist_ok=True)
    for directory in (root,state):
        info = directory.stat()
        if not directory.is_dir() or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError()
    lock = open(state / "install.lock","a")
    code = "busy"
    fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
    code = "certificate_format"
    pem,fingerprint = certificate_value(data["pem"])
    if fingerprint != data["certificate_sha256"]:
        raise ValueError()
    gateway_ip = str(ipaddress.IPv4Address(data["gateway_private_ip"]))
    if not any(ipaddress.IPv4Address(gateway_ip) in ipaddress.IPv4Network(block)
            for block in ("10.0.0.0/8","172.16.0.0/12","192.168.0.0/16")):
        raise ValueError()
    if not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})",data["gateway_instance_id"]):
        raise ValueError()
    port = data["api_port"]
    if type(port) is not int or not 1 <= port <= 65535 or port == 11434:
        raise ValueError()
    for path,code,limit in ((certificate,"existing_certificate",20000),
            (metadata_file,"existing_metadata",8192),(access_file,"existing_access",4096)):
        if path.is_symlink():
            raise ValueError()
        previous[path] = None
        if path.exists():
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022 or info.st_size > limit:
                raise ValueError()
            previous[path] = (path.read_bytes(),info.st_mode & 0o777)
    if previous[certificate] is not None:
        code = "existing_certificate"
        if certificate_value(previous[certificate][0].decode("ascii"))[1] != fingerprint:
            raise ValueError()
    if previous[metadata_file] is not None:
        code = "existing_metadata"
        old = unique_json(previous[metadata_file][0])
        if (type(old.get("schema_version")) is not int or old["schema_version"] != 1 or old.get("source") != "aws-ssm"
                or any(old.get(key)!=data[key] for key in ("gateway_private_ip","gateway_instance_id","certificate_sha256"))
                or ("api_port" in old and (type(old["api_port"]) is not int or old["api_port"] != port))):
            raise ValueError()
    if previous[access_file] is not None:
        code = "existing_access"
        old = unique_json(previous[access_file][0])
        if (old.get("gateway_private_ip") != gateway_ip or type(old.get("api_port")) is not int or old["api_port"] != port
                or ("gateway_instance_id" in old and old["gateway_instance_id"] != data["gateway_instance_id"])
                or ("schema_version" in old and (type(old["schema_version"]) is not int or old["schema_version"] != 1))):
            raise ValueError()
    code = "install"
    candidate = temporary(pem.encode("ascii"))
    code = "tls"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_verify_locations(cafile=str(candidate))
    with socket.create_connection((gateway_ip,port),timeout=10) as connection:
        with context.wrap_socket(connection,server_hostname=gateway_ip) as verified:
            if hashlib.sha256(verified.getpeercert(binary_form=True)).hexdigest()!=fingerprint:
                raise ValueError()
    code = "install"
    metadata = {"schema_version":1,"gateway_private_ip":gateway_ip,"gateway_instance_id":data["gateway_instance_id"],
        "api_port":port,"certificate_sha256":fingerprint,"source":"aws-ssm",
        "enrolled_at":datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z")}
    staged_metadata = temporary((json.dumps(metadata)+"\n").encode())
    access = {"schema_version":1,"gateway_private_ip":gateway_ip,"gateway_instance_id":data["gateway_instance_id"],"api_port":port}
    staged_access = temporary((json.dumps(access)+"\n").encode(),directory=state)
    backups = {path:temporary(value[0],value[1],path.parent) if value is not None else None for path,value in previous.items()}
    try:
        for source,target in ((candidate,certificate),(staged_metadata,metadata_file),(staged_access,access_file)):
            os.replace(source,target)
            promoted.append(target)
    except Exception:
        for target in reversed(promoted):
            if backups[target] is None:
                target.unlink(missing_ok=True)
            else:
                os.replace(backups[target],target)
        raise
    print(json.dumps(dict(metadata,status="ready",ca_path=str(certificate))))
except Exception:
    print(json.dumps({"schema_version":1,"status":"error","code":code}))
finally:
    for path in staged:
        path.unlink(missing_ok=True)
    if lock is not None:
        lock.close()
'''.replace("CERTIFICATE_DATA_VALUE", repr(json.dumps(payload)))
    return "set +x\n/usr/bin/python3 - <<'OLLAMA_GATEWAY_CERT_INSTALL'\n" + script + "\nOLLAMA_GATEWAY_CERT_INSTALL"


def prepare_gateway(stack):
    try:
        instance, gateway, gateway_ip, port = gateway_certificate_link(stack)
    except (AwsError, ValueError, KeyError, RuntimeError) as error:
        if isinstance(error, GatewayCertificateError):
            raise
        raise GatewayCertificateError("link") from None
    print("Reading only the public certificate from linked gateway " + gateway["InstanceId"] + " through authenticated AWS Session Manager.")
    source = certificate_ssm_json(gateway["InstanceId"], gateway_certificate_read_script(gateway_ip), "Reading gateway public certificate")
    if source.get("status") != "public_certificate" or source.get("gateway_private_ip") != gateway_ip:
        raise GatewayCertificateError("certificate_format")
    pem, fingerprint = public_certificate(source.get("pem"))
    if source.get("certificate_sha256") != fingerprint:
        raise GatewayCertificateError("certificate_format")
    result = certificate_ssm_json(instance["InstanceId"],
        gateway_certificate_install_script(gateway_ip, gateway["InstanceId"], port, pem, fingerprint), "Verifying and enrolling gateway certificate")
    if (result.get("status") != "ready" or result.get("gateway_private_ip") != gateway_ip
            or result.get("gateway_instance_id") != gateway["InstanceId"] or result.get("certificate_sha256") != fingerprint
            or type(result.get("api_port")) is not int or result["api_port"] != port
            or result.get("source") != "aws-ssm" or result.get("ca_path") != GATEWAY_CA_PATH):
        raise GatewayCertificateError("install")
    try:
        enrolled = datetime.datetime.fromisoformat(result["enrolled_at"].replace("Z", "+00:00"))
        if enrolled.utcoffset() != datetime.timedelta(0):
            raise ValueError
    except (KeyError, ValueError, AttributeError, TypeError):
        raise GatewayCertificateError("install") from None
    print("PASS: authenticated gateway certificate enrolled and live TLS identity/validity verified.")
    print("Source: " + gateway["InstanceId"] + " | gateway private IP: " + gateway_ip + " | certificate SHA256: " + fingerprint)
    print("CA file: " + GATEWAY_CA_PATH + " (root-only on Ollama).")
    print("FortiAIGate API URL: https://" + gateway_ip + (":" + str(port) if port != 443 else "") + "/ai/openai/v1")
    print("Continue with sudo ollama-lab configure. The current helper selects the verified API URL, certificate and saved browser URL automatically.")
    print("Enter only your virtual key privately, then WebUI account details if this is the first setup.")
    return result


SSH_SETUP_FAILURES = {
    "account": "The standard Ubuntu login account could not be verified.",
    "runtime_dir": "OpenSSH's runtime directory could not be prepared.",
    "config_write": "The managed SSH configuration could not be written.",
    "config_validation": "OpenSSH rejected its configuration before the password was changed.",
    "effective_config": "The effective SSH settings did not permit the expected password login.",
    "password_write": "Ubuntu did not accept the encrypted password update.",
    "password_verification": "The stored Ubuntu password did not match the requested encrypted password.",
    "service_activation": "The SSH service could not be started and confirmed active.",
    "post_restart_validation": "SSH configuration checks failed after restarting the service.",
    "marker_write": "The verified SSH readiness record could not be written.",
    "security_group": "The instance's SSH access rules could not be confirmed as one public IPv4 /32.",
    "instance_state": "Start the Ollama VM and wait until running before setting its SSH password.",
    "ssm_permission": "SSM permission was denied; allow SendCommand and GetCommandInvocation.",
    "ssm_not_ready": "SSH setup was not attempted: Ubuntu bootstrap/Session Manager is not ready.",
    "ssm_submission": "Session Manager did not confirm acceptance of the private SSH setup request.",
    "ssm_execution": "The Session Manager SSH setup command did not succeed.",
    "ssm_timeout": "Remote SSH setup was not confirmed before its time limit.",
    "confirmation": "The SSH setup command returned no verified readiness confirmation.",
}
REMOTE_SSH_STEPS = frozenset(("account", "runtime_dir", "config_write", "config_validation",
    "effective_config", "password_write", "password_verification", "service_activation",
    "post_restart_validation", "marker_write"))


class SshSetupError(RuntimeError):
    """Only fixed diagnostics and a validated, nonsensitive SSM command ID may escape."""
    def __init__(self, step, command_id=None, rollback=None):
        self.step = step if step in SSH_SETUP_FAILURES else "ssm_execution"
        message = "SSH setup failed at " + self.step + ": " + SSH_SETUP_FAILURES[self.step]
        if isinstance(command_id, str) and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", command_id):
            message += " SSM command: " + command_id + "."
        if rollback == "complete":
            message += " Previous SSH settings and password were retained or restored."
        elif rollback == "unconfirmed":
            message += " Rollback could not be fully confirmed; inspect the host through Session Manager."
        super().__init__(message + " VM retained; use menu 7 or Session Manager to recover.")


def aws(service, operation, *arguments, **payload):
    command = ["aws", service, operation, *arguments, "--region", REGION,
               "--output", "json", "--no-cli-pager", "--cli-connect-timeout", "15",
               "--cli-read-timeout", "60"]
    if payload:
        command += ["--cli-input-json", json.dumps(payload)]
    result = subprocess.run(command, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise AwsError(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def aws_private(service, operation, payload):
    """Keep a sensitive request body out of argv and remove its private file."""
    with tempfile.TemporaryDirectory(prefix="ollama-private-") as folder:
        path = Path(folder) / "request.json"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream)
        try:
            return aws(service, operation, "--cli-input-json", "file://" + str(path))
        except AwsError:
            # A CLI validation error can quote request fields. Never relay it.
            raise AwsError("The private SSM password request failed. Values were withheld; use Session Manager or menu 7 to retry.") from None


def prompt_password_hash():
    if not shutil.which("openssl"):
        raise RuntimeError("OpenSSL is required to hash the SSH password locally. Run in AWS CloudShell.")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            password = getpass.getpass("Choose an SSH password for ubuntu (hidden, 12–128 characters): ")
            confirmation = getpass.getpass("Confirm SSH password (hidden): ")
    except getpass.GetPassWarning:
        raise RuntimeError("A private terminal is required for password entry. Open AWS CloudShell interactively and rerun.") from None
    if password != confirmation:
        raise ValueError("Passwords do not match; no resources were changed.")
    if not 12 <= len(password) <= 128 or len(password.encode("utf-8")) > 128 or any(c in password for c in "\r\n\x00"):
        raise ValueError("Use an SSH password of 12–128 characters (at most 128 UTF-8 bytes), without line breaks or NUL.")
    salt = "rounds=100000$" + "".join(secrets.choice("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./") for _ in range(16))
    result = subprocess.run(["openssl", "passwd", "-6", "-salt", salt, "-stdin"],
                            input=password + "\n", text=True, capture_output=True, timeout=30)
    del password, confirmation
    value = result.stdout.strip()
    if result.returncode or not re.fullmatch(r"\$6\$rounds=100000\$[./A-Za-z0-9]{16}\$[./A-Za-z0-9]{86}", value):
        raise RuntimeError("OpenSSL could not produce the encrypted SSH password. No plaintext values were printed.")
    return value


def prefix_of(value):
    value = value.strip()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]{0,23}", value):
        raise ValueError("Name must start with a letter and use only letters/numbers (maximum 24 characters).")
    return value.lower()


def caller_cidr(value):
    raw = value.strip()
    if "/" not in raw:
        raw += "/32"
    network = ipaddress.ip_network(raw, strict=True)
    if network.version != 4 or network.prefixlen != 32 or not network.network_address.is_global:
        raise ValueError("Enter your own PUBLIC IPv4 address, optionally followed by /32. Wider ranges are not accepted.")
    return str(network)


def gateway_api_port(value):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]{1,5}", str(value)):
        raise ValueError("Enter one gateway API TCP port from 1 to 65535.")
    port = int(value)
    if not 1 <= port <= 65535 or port == 11434:
        raise ValueError("Use a gateway API TCP port from 1 to 65535, not Ollama's backend port 11434.")
    return port


def check_gateway_security_group(gateway, group_id):
    if group_id not in {group.get("GroupId") for group in gateway.get("SecurityGroups", [])}:
        raise ValueError("The chosen security group is not attached to the selected FortiAIGate host.")
    groups = aws("ec2", "describe-security-groups", "--group-ids", group_id).get("SecurityGroups", [])
    if len(groups) != 1 or groups[0].get("GroupId") != group_id or groups[0].get("VpcId") != gateway["VpcId"]:
        raise ValueError("The chosen gateway security group could not be verified in the selected VPC.")
    parent_tags = {tag["Key"]: tag.get("Value", "") for tag in gateway.get("Tags", [])}
    if "FortiAIGateBudgetStack" in parent_tags:
        group_tags = {tag["Key"]: tag.get("Value", "") for tag in groups[0].get("Tags", [])}
        owner = parent_tags["FortiAIGateBudgetStack"]
        if not owner or group_tags.get("FortiAIGateBudgetStack") != owner:
            raise ValueError("Choose the timed GPU lab's own security group so its automatic cleanup can remove the Ollama access rule. No resources were changed.")


def stack_name(prefix):
    return "Ollama-Lab-" + prefix_of(prefix)


def describe_stack(name, optional=False):
    try:
        return aws("cloudformation", "describe-stacks", "--stack-name", name)["Stacks"][0]
    except AwsError as error:
        if optional and "does not exist" in str(error):
            return None
        raise


def assert_owned(stack):
    tags = {row["Key"]: row["Value"] for row in stack.get("Tags", [])}
    if (tags.get("DeploymentGuide") != MARKER or not tags.get("UserPrefix")
            or not re.fullmatch(r"vpc-(?:[0-9a-f]{8}|[0-9a-f]{17})", tags.get("FortiAIGateVpcId", ""))
            or not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", tags.get("FortiAIGateInstanceId", ""))):
        raise RuntimeError("Ownership tags do not match this Ollama launcher. No resources were changed.")
    prefix = prefix_of(tags["UserPrefix"])
    if stack["StackName"] != stack_name(prefix):
        raise RuntimeError("Stack name and ownership tags disagree. No resources were changed.")
    return prefix


def stack_outputs(stack):
    return {row["OutputKey"]: row["OutputValue"] for row in stack.get("Outputs", [])}


def elastic_public_ip(outputs):
    allocation_id = outputs.get("ElasticIpAllocationId", "")
    if not isinstance(allocation_id, str) or not re.fullmatch(r"eipalloc-(?:[0-9a-f]{8}|[0-9a-f]{17})", allocation_id):
        return None
    try:
        address = ipaddress.IPv4Address(outputs.get("PublicIp", ""))
    except ipaddress.AddressValueError:
        return None
    return str(address) if address.is_global else None


def discover_ollama_stacks():
    # The AWS CLI aggregates describe-stacks pages; no secondary tag index is used.
    response = aws("cloudformation", "describe-stacks")
    candidates = {}
    for stack in response.get("Stacks", []):
        try:
            name = stack.get("StackName", "")
            status = stack.get("StackStatus", "")
            if (not name.startswith("Ollama-Lab-") or not isinstance(status, str)
                    or not re.fullmatch(r"[A-Z]+(?:_[A-Z]+)+", status) or status == "DELETE_COMPLETE"):
                continue
            assert_owned(stack)
            stack_id = stack.get("StackId", "")
            if not re.fullmatch(r"arn:aws:cloudformation:" + re.escape(REGION)
                    + r":[0-9]{12}:stack/" + re.escape(name)
                    + r"/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", stack_id):
                continue
        except (AttributeError, KeyError, TypeError, ValueError, RuntimeError):
            continue
        # A failed stack may have no outputs or EC2 instance and still needs cleanup.
        candidates.setdefault(stack_id, stack)
    return sorted(candidates.values(), key=lambda stack: (stack["StackName"].casefold(), stack["StackId"]))


def select_ollama_stack():
    print("\nExisting Ollama deployments in " + REGION + ":")
    try:
        candidates = discover_ollama_stacks()
    except (AwsError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        print("Could not list Ollama deployments: " + str(error))
        print("Enter a lab prefix manually, or cancel and check your CloudFormation read permissions / AWS connection.")
        candidates = []
    else:
        if not candidates:
            print("No Ollama deployments owned by this launcher were found.")
    for index, stack in enumerate(candidates, 1):
        try:
            private_ip = stack_outputs(stack).get("PrivateIp") or "private IP unavailable"
        except (KeyError, TypeError):
            private_ip = "private IP unavailable"
        instance_state = "unavailable"
        try:
            instance = managed_instance(stack)
            instance_state = instance.get("State", {}).get("Name", "unavailable")
            private_ip = instance.get("PrivateIpAddress") or private_ip
        except (AwsError, subprocess.TimeoutExpired, OSError, ValueError, RuntimeError, KeyError, TypeError):
            # An absent/failed EC2 resource must not hide its stack from Destroy.
            pass
        print(f"  {index}) {stack['StackName']} | {stack['StackStatus']} | EC2 {instance_state} | {private_ip}")
    manual = len(candidates) + 1
    print(f"  {manual}) Enter an Ollama lab prefix manually")
    print("  0) Cancel")
    while True:
        choice = input("Choose the Ollama deployment number: ").strip()
        if choice == "0":
            return None
        if not choice.isdecimal() or not 1 <= int(choice) <= manual:
            print("Invalid selection. Choose a listed number, or 0 to cancel.")
            continue
        number = int(choice)
        if number <= len(candidates):
            return candidates[number - 1]["StackId"]
        while True:
            prefix = input("Your existing Ollama lab prefix (0 to cancel): ").strip()
            if prefix == "0":
                return None
            try:
                return stack_name(prefix)
            except ValueError as error:
                print(str(error))


def instance_by_id(instance_id):
    if not re.fullmatch(r"i-[0-9a-f]{8,17}", instance_id):
        raise ValueError("Enter an EC2 instance ID such as i-0123456789abcdef0.")
    reservations = aws("ec2", "describe-instances", "--instance-ids", instance_id).get("Reservations", [])
    rows = [row for reservation in reservations for row in reservation.get("Instances", [])]
    if len(rows) != 1:
        raise RuntimeError("Expected exactly one EC2 instance.")
    return rows[0]


def gateway_edition(instance):
    tags = {tag["Key"]: tag["Value"] for tag in instance.get("Tags", [])}
    if tags.get("DeploymentGuide") == MARKER:
        return None
    if tags.get("DeploymentGuide") == "FortiAIGate-GPU-AWS-v1":
        return "GPU"
    name = tags.get("Name", "")
    if re.fullmatch(r".+_FortiAIGate_GPU_Docker", name):
        return "GPU"
    if re.fullmatch(r".+_FortiAIGate_Docker", name):
        return "CPU"
    return None


def select_gateway_edition(instance):
    edition = gateway_edition(instance)
    if edition:
        return edition
    print("\nThe selected host's FortiAIGate edition could not be identified from its tags.")
    print("Choose its edition for the Ollama server name. Ollama itself still uses t3a.large by default.")
    print("  1) CPU FortiAIGate\n  2) GPU FortiAIGate\n  0) Cancel")
    while True:
        choice = input("Choose the selected FortiAIGate's edition: ").strip()
        if choice == "0":
            return None
        if choice in ("1", "2"):
            return {"1": "CPU", "2": "GPU"}[choice]
        print("Choose 1 for CPU, 2 for GPU, or 0 to cancel.")


def discover_gateways():
    """Read existing CPU/GPU lab hosts, including older address plans."""
    response = aws("ec2", "describe-instances", "--filters",
        "Name=instance-state-name,Values=running,stopped",
        "Name=tag:Name,Values=*_FortiAIGate_Docker,*_FortiAIGate_GPU_Docker")
    candidates = {}
    for reservation in response.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            instance_id = instance.get("InstanceId", "")
            if (gateway_edition(instance) and instance.get("State", {}).get("Name") in ("running", "stopped")
                    and re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", instance_id)):
                candidates.setdefault(instance_id, instance)
    def order(instance):
        tags = {tag["Key"]: tag["Value"] for tag in instance.get("Tags", [])}
        return (tags.get("Name", "").casefold(), instance["InstanceId"])
    return sorted(candidates.values(), key=order)


def select_gateway():
    print("\nExisting FortiAIGate deployments in " + REGION + ":")
    try:
        candidates = discover_gateways()
    except (AwsError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        print("Could not list deployments: " + str(error))
        print("Enter an instance ID manually, or cancel and check your EC2 read permissions / AWS connection.")
        candidates = []
    else:
        if not candidates:
            print("No running or stopped CPU/GPU lab hosts matched the launcher names.")
            print("For a renamed or custom host, enter its instance ID manually.")
    for index, instance in enumerate(candidates, 1):
        tags = {tag["Key"]: tag["Value"] for tag in instance.get("Tags", [])}
        print(f"  {index}) {tags['Name']} | {gateway_edition(instance)} | {instance['State']['Name']}")
        print("     " + instance["InstanceId"] + " | " + instance.get("PrivateIpAddress", "no private IP")
              + " | " + instance.get("Placement", {}).get("AvailabilityZone", "unknown AZ"))
    manual = len(candidates) + 1
    print(f"  {manual}) Enter an instance ID manually (renamed/custom host)")
    print("  0) Cancel")
    while True:
        choice = input("Choose the FortiAIGate deployment number: ").strip()
        if choice == "0":
            return None
        if not choice.isdecimal() or not 1 <= int(choice) <= manual:
            print("Invalid selection. Choose a listed number, or 0 to cancel.")
            continue
        number = int(choice)
        if number <= len(candidates):
            return candidates[number - 1]["InstanceId"]
        while True:
            instance_id = input("Existing FortiAIGate CPU/GPU EC2 instance ID (0 to cancel): ").strip()
            if instance_id == "0":
                return None
            if re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", instance_id):
                return instance_id
            print("Enter an EC2 instance ID such as i-0123456789abcdef0, or 0 to cancel.")


def managed_instance(stack):
    assert_owned(stack)
    instance_id = stack_outputs(stack).get("InstanceId")
    if not instance_id:
        raise RuntimeError("The stack has no instance output yet. Check CloudFormation events or use Destroy for a failed stack.")
    row = instance_by_id(instance_id)
    tags = {tag["Key"]: tag["Value"] for tag in row.get("Tags", [])}
    if tags.get("DeploymentGuide") != MARKER or tags.get("UserPrefix") != assert_owned(stack):
        raise RuntimeError("The EC2 instance ownership tags do not match. No resources were changed.")
    return row


def private_subnet(subnet_cidr):
    subnet = ipaddress.ip_network(subnet_cidr, strict=True)
    private_ranges = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
    if (subnet.version != 4 or not 16 <= subnet.prefixlen <= 28
            or not any(subnet.subnet_of(ipaddress.ip_network(block)) for block in private_ranges)):
        raise ValueError("Use the parent lab's RFC1918 IPv4 subnet (/16 through /28).")
    return subnet


def fixed_model_address(subnet_cidr):
    subnet = private_subnet(subnet_cidr)
    # Keep new labs on the agreed address plan and retain older parent subnets.
    offset = 20 if str(subnet) == LAB_SUBNET_CIDR else 5
    return str(subnet.network_address + offset)


def gateway_address(subnet_cidr, address):
    subnet = private_subnet(subnet_cidr)
    if not isinstance(address, str) or not address:
        raise ValueError("The selected gateway has no private IPv4 address. No resources were changed.")
    gateway = ipaddress.ip_address(address)
    if (gateway.version != 4 or gateway not in subnet
            or int(gateway) < int(subnet.network_address) + 4 or gateway == subnet.broadcast_address):
        raise ValueError("The selected gateway private IPv4 must be a usable address inside its subnet. No resources were changed.")
    if str(gateway) == fixed_model_address(subnet_cidr):
        raise ValueError("The selected gateway already uses the fixed Ollama address. No resources were changed.")
    return str(gateway)


def ensure_model_address_available(subnet_id, address):
    interfaces = aws("ec2", "describe-network-interfaces", "--filters",
                     "Name=subnet-id,Values=" + subnet_id,
                     "Name=addresses.private-ip-address,Values=" + address).get("NetworkInterfaces", [])
    if interfaces:
        raise RuntimeError("The fixed Ollama address " + address + " is already in use. No replacement address or VM was created; use a fresh parent lab or remove its existing Ollama lab first.")


def build_template(prefix, vpc_id, subnet_id, gateway_id, gateway_sg, cidr, instance_type="t3a.large", subnet_cidr=LAB_SUBNET_CIDR, gateway_private_ip=None, api_port=443, edition="CPU"):
    prefix = prefix_of(prefix)
    if edition not in ("CPU", "GPU"):
        raise ValueError("The linked FortiAIGate edition must be CPU or GPU.")
    cidr = caller_cidr(cidr)
    api_port = gateway_api_port(api_port)
    model_private_ip = fixed_model_address(subnet_cidr)
    default_gateway_offset = 10 if str(private_subnet(subnet_cidr)) == LAB_SUBNET_CIDR else 4
    gateway_private_ip = gateway_address(subnet_cidr, gateway_private_ip if gateway_private_ip is not None
        else str(private_subnet(subnet_cidr).network_address + default_gateway_offset))
    for value, pattern in [(vpc_id, r"vpc-[0-9a-f]{8,17}"), (subnet_id, r"subnet-[0-9a-f]{8,17}"),
                           (gateway_id, r"i-[0-9a-f]{8,17}"), (gateway_sg, r"sg-[0-9a-f]{8,17}")]:
        if not re.fullmatch(pattern, value):
            raise ValueError("Invalid AWS resource identifier: " + value)
    if instance_type not in ("t3a.large", "t3.large"):
        raise ValueError("Use t3a.large or t3.large.")
    tags = [{"Key": "DeploymentGuide", "Value": MARKER}, {"Key": "UserPrefix", "Value": prefix},
            {"Key": "FortiAIGateVpcId", "Value": vpc_id}, {"Key": "FortiAIGateInstanceId", "Value": gateway_id}]
    user_data = """#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/ollama-lab-bootstrap.log | logger -t ollama-lab -s 2>/dev/console) 2>&1
bootstrap_failed() {
    bootstrap_code=$?
    install -d -m 0700 /var/lib/ollama-lab
    printf '%s\\n' '{"state":"failed","stage":"bootstrap","percent":0,"message":"Ubuntu bootstrap failed; inspect /var/log/ollama-lab-bootstrap.log"}' > /var/lib/ollama-lab/status.json
    chmod 0600 /var/lib/ollama-lab/status.json
    printf 'OLLAMA_BOOTSTRAP_FAILED: inspect /var/log/ollama-lab-bootstrap.log\\n'
    exit "$bootstrap_code"
}
trap bootstrap_failed ERR
export DEBIAN_FRONTEND=noninteractive
printf 'OLLAMA_BOOTSTRAP: preparing a separate Ubuntu model host\\n'
expected_public_ip='ELASTIC_IP_VALUE'
python3 - "$expected_public_ip" <<'OLLAMA_EIP_WAIT'
import ipaddress,sys,time,urllib.error,urllib.request
expected = ipaddress.ip_address(sys.argv[1])
if expected.version != 4 or not expected.is_global:
    raise SystemExit('The allocated Elastic IP is not a public IPv4 address.')
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
metadata = 'http://169.254.169.254/latest/'
started = time.monotonic()
deadline = started + 600
last_report = None
while time.monotonic() < deadline:
    try:
        token_request = urllib.request.Request(metadata + 'api/token', method='PUT',
            headers={'X-aws-ec2-metadata-token-ttl-seconds': '1200'})
        with opener.open(token_request, timeout=3) as response:
            token = response.read().decode().strip()
        request = urllib.request.Request(metadata + 'meta-data/public-ipv4',
            headers={'X-aws-ec2-metadata-token': token})
        with opener.open(request, timeout=3) as response:
            observed = response.read().decode().strip()
        if observed == str(expected):
            print('OLLAMA_BOOTSTRAP: allocated Elastic IP association confirmed', flush=True)
            break
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        pass
    now = time.monotonic()
    if last_report is None or now - last_report >= 30:
        print('OLLAMA_BOOTSTRAP: waiting for Elastic IP association; elapsed ' + str(int(now-started)) + 's', flush=True)
        last_report = now
    time.sleep(5)
else:
    raise SystemExit('Elastic IP association was not confirmed within 10 minutes; package downloads were not started.')
OLLAMA_EIP_WAIT
public_ip="$expected_public_ip"
install -d -m 0700 /var/lib/ollama-lab
printf '%s\\n' GATEWAY_ACCESS_VALUE > /var/lib/ollama-lab/gateway-access.json
chmod 0600 /var/lib/ollama-lab/gateway-access.json
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates curl
token=$(curl --fail --silent --show-error --retry 5 --connect-timeout 5 --max-time 15 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' http://169.254.169.254/latest/api/token)
private_ip=$(curl --fail --silent --show-error --retry 5 --connect-timeout 5 --max-time 15 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/local-ipv4)
install -d -m 0755 /opt/ollama-lab-bootstrap
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 5 --connect-timeout 15 --max-time 180 PREP_URL_VALUE -o /opt/ollama-lab-bootstrap/prepare_ollama.sh
printf '%s  %s\\n' PREP_SHA256_VALUE /opt/ollama-lab-bootstrap/prepare_ollama.sh | sha256sum -c -
bash -n /opt/ollama-lab-bootstrap/prepare_ollama.sh
bash /opt/ollama-lab-bootstrap/prepare_ollama.sh --install --bind-address "$private_ip" --webui-url "http://$public_ip:3000"
printf 'OLLAMA_BOOTSTRAP_COMPLETE: configure FortiAIGate provider and virtual key, then run sudo ollama-lab configure\\n'
""".replace("PREP_URL_VALUE", shlex.quote(PREP_URL)).replace("PREP_SHA256_VALUE", shlex.quote(PREP_SHA256)).replace(
        "GATEWAY_ACCESS_VALUE", shlex.quote(json.dumps({"schema_version": 1, "api_port": api_port,
            "gateway_private_ip": gateway_private_ip, "gateway_instance_id": gateway_id})))
    # Ref only the allocation here. Depending on its association would cycle:
    # allocation -> instance -> association; user-data waits for the last step.
    before_ip, after_ip = user_data.split("ELASTIC_IP_VALUE")
    bootstrap = {"Fn::Base64": {"Fn::Join": ["", [before_ip, {"Ref": "OllamaElasticIp"}, after_ip]]}}
    return {
        "AWSTemplateFormatVersion": "2010-09-09",
        "Description": "Separate Ollama host with a stack-owned private API access rule on the selected FortiAIGate gateway.",
        "Parameters": {"UbuntuAmi": {"Type": "AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>", "Default": AMI_PARAMETER}},
        "Resources": {
            "OllamaElasticIp": {"Type": "AWS::EC2::EIP", "Properties": {
                "Domain": "vpc", "Tags": tags + [{"Key": "Name", "Value": prefix + "_Ollama_ElasticIP"}]}},
            "OllamaSecurityGroup": {"Type": "AWS::EC2::SecurityGroup", "Properties": {
                "GroupDescription": "Ollama model from selected FortiAIGate security group; SSH and browser from operator /32",
                "VpcId": vpc_id, "Tags": tags + [{"Key": "Name", "Value": prefix + "_Ollama_NSG"}],
                "SecurityGroupIngress": [
                    {"IpProtocol": "tcp", "FromPort": 11434, "ToPort": 11434, "SourceSecurityGroupId": gateway_sg,
                     "Description": "FortiAIGate private model traffic only"},
                    {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "CidrIp": cidr,
                     "Description": "Operator SSH administration"},
                    {"IpProtocol": "tcp", "FromPort": 3000, "ToPort": 3000, "CidrIp": cidr,
                     "Description": "Operator direct HTTP browser access"}],
                "SecurityGroupEgress": [{"IpProtocol": "-1", "CidrIp": "0.0.0.0/0", "Description": "Package/image downloads and gateway responses"}]}},
            "GatewayApiIngress": {"Type": "AWS::EC2::SecurityGroupIngress", "Properties": {
                "GroupId": gateway_sg, "IpProtocol": "tcp", "FromPort": api_port, "ToPort": api_port,
                "SourceSecurityGroupId": {"Ref": "OllamaSecurityGroup"},
                "Description": "Ollama " + prefix + " private gateway API access; owned by its child stack"}},
            "OllamaRole": {"Type": "AWS::IAM::Role", "Properties": {
                "RoleName": "Ollama-Lab-" + prefix + "-" + vpc_id + "-Role",
                "AssumeRolePolicyDocument": {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]},
                "ManagedPolicyArns": [{"Fn::Sub": "arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"}], "Tags": tags}},
            "OllamaInstanceProfile": {"Type": "AWS::IAM::InstanceProfile", "Properties": {"InstanceProfileName": "Ollama-Lab-" + prefix + "-" + vpc_id + "-Profile", "Roles": [{"Ref": "OllamaRole"}]}},
            "OllamaInstance": {"Type": "AWS::EC2::Instance", "Properties": {
                "ImageId": {"Ref": "UbuntuAmi"}, "InstanceType": instance_type,
                "IamInstanceProfile": {"Ref": "OllamaInstanceProfile"},
                "MetadataOptions": {"HttpTokens": "required", "HttpPutResponseHopLimit": 1},
                "NetworkInterfaces": [{"DeviceIndex": "0", "AssociatePublicIpAddress": False, "SubnetId": subnet_id, "PrivateIpAddress": model_private_ip, "GroupSet": [{"Ref": "OllamaSecurityGroup"}]}],
                "BlockDeviceMappings": [{"DeviceName": "/dev/sda1", "Ebs": {"VolumeType": "gp3", "VolumeSize": 64, "Encrypted": True, "DeleteOnTermination": True}}],
                "Tags": tags + [{"Key": "Name", "Value": prefix + "_Ollama_" + edition + "_Docker"}], "UserData": bootstrap}},
            "OllamaElasticIpAssociation": {"Type": "AWS::EC2::EIPAssociation", "Properties": {
                "AllocationId": {"Fn::GetAtt": ["OllamaElasticIp", "AllocationId"]},
                "InstanceId": {"Ref": "OllamaInstance"}}},
        },
        "Outputs": {
            "InstanceId": {"Value": {"Ref": "OllamaInstance"}},
            "PrivateIp": {"Value": {"Fn::GetAtt": ["OllamaInstance", "PrivateIp"]}},
            "PublicIp": {"Value": {"Ref": "OllamaElasticIp"}},
            "ElasticIpAllocationId": {"Value": {"Fn::GetAtt": ["OllamaElasticIp", "AllocationId"]}},
            "SecurityGroupId": {"Value": {"Ref": "OllamaSecurityGroup"}},
            "WebUIAccessMode": {"Value": "http-public-ip-32"},
            "OperatorCidr": {"Value": cidr},
            "GatewayPrivateIp": {"Value": gateway_private_ip},
            "GatewayApiPort": {"Value": str(api_port)},
            "GatewayAccessMode": {"Value": "child-sg-api-port"},
            "GatewayInstanceId": {"Value": gateway_id}, "GatewaySecurityGroupId": {"Value": gateway_sg}
        }
    }


def ensure_public_subnet(vpc_id, subnet_id):
    subnets = aws("ec2", "describe-subnets", "--subnet-ids", subnet_id)["Subnets"]
    if len(subnets) != 1 or subnets[0]["VpcId"] != vpc_id or subnets[0].get("State") != "available":
        raise RuntimeError("The gateway subnet is unavailable or its VPC does not match.")
    routes = aws("ec2", "describe-route-tables", "--filters", "Name=vpc-id,Values=" + vpc_id)["RouteTables"]
    explicit = [table for table in routes if any(a.get("SubnetId") == subnet_id for a in table.get("Associations", []))]
    matching = explicit or [table for table in routes if any(a.get("Main") for a in table.get("Associations", []))]
    if len(matching) != 1 or not any(r.get("DestinationCidrBlock") == "0.0.0.0/0" and r.get("GatewayId", "").startswith("igw-") and r.get("State") == "active" for r in matching[0].get("Routes", [])):
        raise RuntimeError("This launcher needs the gateway's subnet to have an active IPv4 Internet Gateway default route. No network settings were changed.")
    return subnets[0]


def progress_duration(started, now=None):
    seconds = max(0, int((time.monotonic() if now is None else now) - started))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return (f"{hours:02d}h " if hours else "") + f"{minutes:02d}m {seconds:02d}s"


def report_progress(phase, detail, started, now=None):
    print(f"\n{phase} | Elapsed {progress_duration(started, now)}", flush=True)
    print("  Current stage: " + detail, flush=True)


def preparation_progress(snapshot):
    """Only known status fields become progress text; never relay runtime logs."""
    if not isinstance(snapshot, dict):
        raise ValueError("Installation status is not a JSON object.")
    value = snapshot.get("percent", 0)
    try:
        if isinstance(value, bool):
            raise ValueError
        percent = int(value)
        if not 0 <= percent <= 100 or isinstance(value, float) and value != percent:
            raise ValueError
    except (TypeError, ValueError, OverflowError):
        raise ValueError("Installation milestone percentage is invalid.") from None
    state = snapshot.get("state", "")
    if not isinstance(state, str):
        raise ValueError("Installation state is invalid.")
    state = state.lower()
    stage = snapshot.get("stage", "")
    stages = {
        "bootstrap": "Preparing Ubuntu and downloading the verified installer",
        "preflight": "Checking the separate Ubuntu model host",
        "docker": "Installing and preparing Docker Engine",
        "runtime": "Installing Ollama lab commands and status reporting",
        "images": "Downloading the Ollama container image" if percent < 40 else "Downloading the Open WebUI container image",
        "model_server": "Starting the private Ollama model API",
        "model_download": "Downloading Llama 3.2 1B (about 1.3 GB)",
        "model_alias": "Creating the llama-lab model alias",
        "model_test": "Testing a real model response; first CPU inference may take a few minutes",
        "ready": "Finishing model preparation",
        "configure": "Preparing the FortiAIGate connection settings",
        "webui": "Starting Open WebUI with gateway routing",
        "configured": "Finishing Open WebUI configuration",
    }
    detail = stages.get(stage, "Waiting for Ubuntu bootstrap" if not stage else "Installing the Ollama model host") if isinstance(stage, str) else "Installing the Ollama model host"
    if state in ("failed", "error"):
        detail = "Ubuntu bootstrap failed" if stage == "bootstrap" else "Ollama installation failed"
    elif state in ("ready", "installed", "awaiting_configuration", "awaiting-config", "awaiting_config", "complete", "completed"):
        detail = "llama-lab model is ready; configure FortiAIGate and Open WebUI next"
    elif state == "configured":
        detail = "Ollama and Open WebUI are configured"
    return state, percent, detail


def report_stack_resources(name, deleting, previous):
    """Optional read-only resource detail; it must not gate the stack waiter."""
    labels = {
        "OllamaElasticIp": "Reserved Elastic IP",
        "OllamaElasticIpAssociation": "Elastic IP association",
        "OllamaSecurityGroup": "Ollama security group",
        "GatewayApiIngress": "Private access to FortiAIGate API",
        "OllamaRole": "Session Manager IAM role",
        "OllamaInstanceProfile": "EC2 instance profile",
        "OllamaInstance": "Ubuntu EC2 instance",
    }
    try:
        response = aws("cloudformation", "list-stack-resources", "--stack-name", name)
        rows = response.get("StackResourceSummaries", [])
        if not isinstance(rows, list):
            raise ValueError("Invalid resource status.")
        rows = [row for row in rows if isinstance(row, dict)
                and row.get("LogicalResourceId") in labels
                and isinstance(row.get("ResourceStatus"), str)
                and re.fullmatch(r"[A-Z]+(?:_[A-Z]+)+", row["ResourceStatus"])]
    except (AwsError, subprocess.TimeoutExpired, OSError, ValueError, AttributeError, TypeError):
        print("  Resource detail unavailable; continuing to check the CloudFormation stack.", flush=True)
        return
    if not rows:
        print("  Waiting for CloudFormation to report its first resources.", flush=True)
        return
    complete_states = ("DELETE_COMPLETE", "DELETE_SKIPPED") if deleting else ("CREATE_COMPLETE", "UPDATE_COMPLETE")
    completed = sum(row["ResourceStatus"] in complete_states for row in rows)
    active = sum(row["ResourceStatus"].endswith("_IN_PROGRESS") for row in rows)
    verb = "processed for cleanup" if deleting else "created"
    print(f"  Resources reported: {completed} {verb}, {active} in progress.", flush=True)
    for row in rows:
        logical, status = row["LogicalResourceId"], row["ResourceStatus"]
        if previous.get(logical) != status:
            print("    " + labels[logical] + ": " + status.replace("_", " ").lower(), flush=True)
            previous[logical] = status
    active_resources = {row["LogicalResourceId"] for row in rows if row["ResourceStatus"].endswith("_IN_PROGRESS")}
    if "OllamaInstance" in active_resources and not deleting:
        print("  Launching the Ubuntu VM; installation continues after AWS creates the instance.", flush=True)
    elif "OllamaElasticIpAssociation" in active_resources and not deleting:
        print("  Associating the reserved Elastic IP; Ubuntu waits for this before package downloads.", flush=True)
    elif active_resources & {"OllamaRole", "OllamaInstanceProfile"} and not deleting:
        print("  Preparing the IAM role and instance profile for Session Manager.", flush=True)


def wait_stack(name, desired, deleting=False):
    start = time.monotonic()
    previous = None
    last_report = None
    resource_states = {}
    phase = "CloudFormation cleanup" if deleting else "CloudFormation deployment"
    while time.monotonic() - start < 1800:
        stack = describe_stack(name, optional=deleting)
        now = time.monotonic()
        if stack is None and deleting:
            report_progress(phase, "Stack deleted", start, now)
            return None
        state = stack["StackStatus"]
        if state != previous or last_report is None or now - last_report >= 30:
            report_progress(phase, "CloudFormation: " + state, start, now)
            previous = state
            last_report = now
            if state.endswith("_IN_PROGRESS"):
                report_stack_resources(name, deleting or "ROLLBACK" in state, resource_states)
        if state == desired:
            return stack
        if not state.endswith("_IN_PROGRESS"):
            events = aws("cloudformation", "describe-stack-events", "--stack-name", name)
            for row in events.get("StackEvents", [])[:12]:
                if row.get("ResourceStatusReason"):
                    print(row["LogicalResourceId"] + ": " + row["ResourceStatusReason"])
            raise RuntimeError("Stack ended in " + state + ". Inspect CloudFormation; use this launcher's Destroy to remove its own resources.")
        time.sleep(10)
    raise RuntimeError("The 30-minute stack wait ended. Use Status before taking another action; the stack may still be working.")


def read_prep(instance_id):
    data = aws("ssm", "send-command", DocumentName="AWS-RunShellScript", InstanceIds=[instance_id],
               TimeoutSeconds=30, Parameters={"commands": ["if test -f /var/lib/ollama-lab/status.json; then cat /var/lib/ollama-lab/status.json; else echo '{\"state\":\"starting\",\"percent\":0,\"message\":\"Waiting for Ubuntu bootstrap\"}'; fi"], "executionTimeout": ["20"]})
    command_id = data["Command"]["CommandId"]
    for _ in range(12):
        try:
            result = aws("ssm", "get-command-invocation", "--command-id", command_id, "--instance-id", instance_id)
        except AwsError as error:
            if "InvocationDoesNotExist" not in str(error):
                raise
        else:
            if result.get("Status") == "Success":
                return json.loads(result["StandardOutputContent"])
            if result.get("Status") not in ("Pending", "InProgress", "Delayed"):
                raise RuntimeError("Readiness check: " + result.get("Status", "unknown"))
        time.sleep(2)
    raise RuntimeError("The readiness check timed out. It did not stop the installation.")


def wait_preparation(instance_id):
    start = time.monotonic()
    previous = None
    last_report = None
    print("\nInstallation progress reports estimated milestones, not download bytes or time remaining.", flush=True)
    ready_states = ("ready", "installed", "awaiting_configuration", "awaiting-config", "awaiting_config", "configured", "complete", "completed")
    while time.monotonic() - start < 1800:
        state = ""
        percent = None
        try:
            state, percent, detail = preparation_progress(read_prep(instance_id))
        except (AwsError, ValueError, RuntimeError, TypeError):
            detail = "Waiting for Session Manager and the next installation status snapshot"
        now = time.monotonic()
        snapshot = (state, percent, detail)
        if (snapshot != previous or last_report is None or now - last_report >= 30
                or state in ("failed", "error") or state in ready_states):
            report_progress("Ollama installation", detail, start, now)
            if percent is not None:
                bar = "#" * (percent // 5) + "-" * (20 - percent // 5)
                print(f"  Milestones (estimated): [{bar}] {percent:3}%", flush=True)
            previous, last_report = snapshot, now
        if state in ("failed", "error"):
            raise RuntimeError("Ollama preparation failed. Connect and inspect sudo tail -n 100 /var/log/ollama-lab-bootstrap.log and sudo ollama-lab logs.")
        if state in ready_states:
            return True
        time.sleep(20)
    print("The 30-minute readiness wait ended. The VM is retained; install may still be downloading. Use Status or connect and inspect the bootstrap log.", flush=True)
    return False


def wait_ssm_result(command_id, instance_id, timeout=300, phase="Session Manager check"):
    start = time.monotonic()
    deadline = start + timeout
    previous = None
    last_report = None
    while time.monotonic() < deadline:
        status = "Waiting for Session Manager command"
        try:
            result = aws("ssm", "get-command-invocation", "--command-id", command_id, "--instance-id", instance_id)
        except AwsError as error:
            if "InvocationDoesNotExist" not in str(error):
                step = "ssm_permission" if any(code in str(error) for code in ("AccessDenied", "UnauthorizedOperation")) else "ssm_execution"
                raise SshSetupError(step, command_id) from None
        except subprocess.TimeoutExpired:
            raise SshSetupError("ssm_timeout", command_id) from None
        else:
            status = result.get("Status")
            failure_step = None
            rollback = None
            # Never relay remote output. Accept only exact, fixed diagnostic tokens.
            for field in ("StandardOutputContent", "StandardErrorContent"):
                for line in str(result.get(field, "")).splitlines():
                    if line.startswith("OLLAMA_SSH_PASSWORD_FAILED:"):
                        candidate = line.removeprefix("OLLAMA_SSH_PASSWORD_FAILED:")
                        if candidate in REMOTE_SSH_STEPS:
                            failure_step = candidate
                    elif line in ("OLLAMA_SSH_ROLLBACK:complete", "OLLAMA_SSH_ROLLBACK:unconfirmed"):
                        rollback = line.removeprefix("OLLAMA_SSH_ROLLBACK:")
            if failure_step:
                raise SshSetupError(failure_step, command_id, rollback)
            if status == "Success":
                return result.get("StandardOutputContent", "")
            if status not in ("Pending", "InProgress", "Delayed"):
                raise SshSetupError("ssm_timeout" if status == "TimedOut" else "ssm_execution", command_id)
        now = time.monotonic()
        if status != previous or last_report is None or now - last_report >= 30:
            report_progress(phase, status, start, now)
            previous, last_report = status, now
        time.sleep(3)
    raise SshSetupError("ssm_timeout", command_id)


def ssh_setup_script(password_hash, caller_ip):
    if not re.fullmatch(r"\$6\$rounds=100000\$[./A-Za-z0-9]{16}\$[./A-Za-z0-9]{86}", password_hash):
        raise ValueError("Invalid encrypted-password format.")
    caller_ip = str(ipaddress.ip_network(caller_cidr(caller_ip)).network_address)
    # Only a salted hash enters this command. The original password never does.
    script = '''import datetime,json,os,pwd,subprocess,sys
from pathlib import Path
password_hash = HASH_VALUE
caller_ip = IP_VALUE
config = Path("/etc/ssh/sshd_config.d/00-ollama-lab-password.conf")
marker = Path("/var/lib/ollama-lab/ssh-password-ready.json")
previous = None
old_hash = None
snapshot_ready = False
changed_password = False
step = "account"
def run(arguments, data=None):
    return subprocess.run(arguments,input=data,text=True,capture_output=True,check=True,timeout=45)
def shadow_hash():
    return next(row.split(":",2)[1] for row in Path("/etc/shadow").read_text().splitlines() if row.startswith("ubuntu:"))
def verify_effective_config():
    effective = [line.strip().lower() for line in run(["/usr/sbin/sshd","-T","-C","user=ubuntu,host=localhost,addr="+caller_ip]).stdout.splitlines()]
    for expected in ("passwordauthentication yes","kbdinteractiveauthentication no","authenticationmethods password","allowusers ubuntu","permitrootlogin no","allowtcpforwarding local","permitopen 127.0.0.1:3000"):
        if expected not in effective:
            raise RuntimeError("Effective SSH configuration mismatch")
try:
    if os.geteuid() != 0 or pwd.getpwnam("ubuntu").pw_uid < 1000:
        raise RuntimeError("Expected the standard Ubuntu login account")
    previous = config.read_bytes() if config.exists() else None
    old_hash = shadow_hash()
    snapshot_ready = True
    step = "runtime_dir"
    # Ubuntu 24.04 may have only ssh.socket running on the first boot. Its
    # ssh.service RuntimeDirectory does not exist until that service starts.
    runtime = Path("/run/sshd")
    if runtime.is_symlink():
        raise RuntimeError("Unexpected SSH runtime directory symlink")
    runtime.mkdir(mode=0o755,parents=True,exist_ok=True)
    os.chown(runtime,0,0)
    runtime.chmod(0o755)
    step = "config_write"
    config.parent.mkdir(mode=0o755,parents=True,exist_ok=True)
    config.write_text("# Managed by Ollama AWS launcher; SSH allowed only for ubuntu\\nPasswordAuthentication yes\\nKbdInteractiveAuthentication no\\nAuthenticationMethods password\\nAllowUsers ubuntu\\nPermitRootLogin no\\nAllowTcpForwarding local\\nPermitOpen 127.0.0.1:3000\\nPermitTunnel no\\n")
    config.chmod(0o644)
    step = "config_validation"
    run(["/usr/sbin/sshd","-t"])
    step = "effective_config"
    verify_effective_config()
    step = "password_write"
    # A command can update a password before returning an error; rollback must
    # be attempted even when chpasswd itself reports failure.
    changed_password = True
    run(["/usr/sbin/chpasswd","-e"], "ubuntu:"+password_hash+"\\n")
    step = "password_verification"
    if shadow_hash() != password_hash:
        raise RuntimeError("Encrypted password verification failed")
    step = "service_activation"
    run(["systemctl","reload-or-restart","ssh.service"])
    run(["systemctl","is-active","--quiet","ssh.service"])
    step = "post_restart_validation"
    run(["/usr/sbin/sshd","-t"])
    verify_effective_config()
    step = "password_verification"
    if shadow_hash() != password_hash:
        raise RuntimeError("Encrypted password changed during SSH activation")
    step = "marker_write"
    marker.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    marker.write_text(json.dumps({"state":"ready","user":"ubuntu","version":"2026-11-01.7","configured_at":datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    marker.chmod(0o600)
    print("OLLAMA_SSH_PASSWORD_READY")
except Exception:
    rollback_ok = True
    if snapshot_ready:
        try:
            if previous is None:
                config.unlink(missing_ok=True)
                if config.exists():
                    raise RuntimeError("Configuration rollback was not confirmed")
            else:
                config.write_bytes(previous)
                config.chmod(0o644)
                if config.read_bytes() != previous:
                    raise RuntimeError("Configuration rollback was not confirmed")
        except Exception:
            rollback_ok = False
    if changed_password:
        try:
            run(["/usr/sbin/chpasswd","-e"], "ubuntu:"+old_hash+"\\n")
            if shadow_hash() != old_hash:
                raise RuntimeError("Password rollback was not confirmed")
        except Exception:
            rollback_ok = False
    if snapshot_ready:
        try:
            marker.unlink(missing_ok=True)
            run(["systemctl","reload-or-restart","ssh.service"])
            run(["systemctl","is-active","--quiet","ssh.service"])
        except Exception:
            rollback_ok = False
    print("OLLAMA_SSH_PASSWORD_FAILED:"+step,file=sys.stderr)
    print("OLLAMA_SSH_ROLLBACK:"+("complete" if rollback_ok else "unconfirmed"),file=sys.stderr)
    sys.exit(1)
'''.replace("HASH_VALUE", repr(password_hash)).replace("IP_VALUE", repr(caller_ip))
    return "set +x\n/usr/bin/python3 - <<'OLLAMA_PASSWORD_PY'\n" + script + "\nOLLAMA_PASSWORD_PY"


def ssh_operator_cidr(groups):
    sources = set()
    for group in groups:
        for entry in group.get("IpPermissions", []):
            protocol = str(entry.get("IpProtocol", ""))
            admits_ssh = protocol == "-1" or (protocol in ("tcp", "6") and entry.get("FromPort", 0) <= 22 <= entry.get("ToPort", 65535))
            if not admits_ssh:
                continue
            if entry.get("Ipv6Ranges") or entry.get("UserIdGroupPairs") or entry.get("PrefixListIds"):
                raise RuntimeError("SSH ingress must permit only one operator public IPv4/32; SG, prefix-list and IPv6 SSH sources are not accepted.")
            for row in entry.get("IpRanges", []):
                sources.add(caller_cidr(row.get("CidrIp", "")))
    if len(sources) != 1:
        raise RuntimeError("Expected one operator public /32 across every rule admitting SSH. Inspect the Ollama security groups before setting its password.")
    return next(iter(sources))


def set_ssh_password(stack, password_hash=None):
    instance = managed_instance(stack)
    if instance["State"]["Name"] != "running":
        raise SshSetupError("instance_state")
    password_hash = password_hash or prompt_password_hash()
    group_ids = [g["GroupId"] for g in instance.get("SecurityGroups", [])]
    if not group_ids:
        raise SshSetupError("security_group")
    try:
        groups = aws("ec2", "describe-security-groups", "--group-ids", *group_ids).get("SecurityGroups", [])
        caller_ip = ssh_operator_cidr(groups)
    except (AwsError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        raise SshSetupError("security_group") from None
    print("Waiting for Ubuntu/Session Manager to accept SSH setup...", flush=True)
    ssh_start = time.monotonic()
    deadline = ssh_start + 900
    previous = None
    last_report = None
    while time.monotonic() < deadline:
        detail = "Waiting for Ubuntu bootstrap and Session Manager"
        try:
            progress = read_prep(instance["InstanceId"])
            try:
                _, _, detail = preparation_progress(progress)
            except (ValueError, TypeError):
                detail = "Ubuntu installation status received"
            # A real stage is written only after cloud-init reaches user-data.
            # Its earlier default-user/password modules have then finished.
            if progress.get("stage"):
                report_progress("SSH setup", detail + "; applying the private SSH settings next", ssh_start)
                break
        except (AwsError, RuntimeError, ValueError, TypeError) as error:
            if "AccessDenied" in str(error) or "UnauthorizedOperation" in str(error):
                raise SshSetupError("ssm_permission") from None
        now = time.monotonic()
        if detail != previous or last_report is None or now - last_report >= 30:
            report_progress("SSH setup", detail, ssh_start, now)
            previous, last_report = detail, now
        time.sleep(15)
    else:
        raise SshSetupError("ssm_not_ready")
    try:
        command = aws_private("ssm", "send-command", {
            "DocumentName": "AWS-RunShellScript", "InstanceIds": [instance["InstanceId"]], "TimeoutSeconds": 120,
            "Parameters": {"commands": [ssh_setup_script(password_hash, caller_ip)], "executionTimeout": ["120"]}})
    except (AwsError, subprocess.TimeoutExpired):
        raise SshSetupError("ssm_submission") from None
    command_id = command["Command"]["CommandId"]
    del password_hash, command
    output = wait_ssm_result(command_id, instance["InstanceId"], phase="Applying SSH settings")
    if "OLLAMA_SSH_PASSWORD_READY" not in output.splitlines():
        raise SshSetupError("confirmation", command_id)
    print("Password SSH is configured for ubuntu: stored encrypted password, effective SSH settings and active service verified. Use the password you entered privately in CloudShell.")


def ssh_password_ready(instance_id):
    try:
        command = aws("ssm", "send-command", DocumentName="AWS-RunShellScript", InstanceIds=[instance_id], TimeoutSeconds=30,
            Parameters={"commands": ["if test -f /var/lib/ollama-lab/ssh-password-ready.json; then cat /var/lib/ollama-lab/ssh-password-ready.json; else echo '{}'; fi"], "executionTimeout": ["20"]})
        result = json.loads(wait_ssm_result(command["Command"]["CommandId"], instance_id, timeout=45))
        return result.get("state") == "ready" and result.get("user") == "ubuntu"
    except (AwsError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        return False


def show_access(stack, password_ready=None):
    instance = managed_instance(stack)
    outputs = stack_outputs(stack)
    private = instance.get("PrivateIpAddress", outputs.get("PrivateIp", ""))
    reserved_public = elastic_public_ip(outputs)
    public = instance.get("PublicIpAddress") or reserved_public
    print("\nOllama instance: " + instance["InstanceId"] + " | " + instance["State"]["Name"])
    if reserved_public:
        print("Elastic IP: " + reserved_public + " (reserved until this Ollama stack is destroyed; unchanged by Stop/Start)")
    print("\nFORTIAIGATE MODEL PROVIDER (private backend):")
    print("  OpenAI-compatible base URL: http://" + private + ":11434/v1")
    if outputs.get("GatewayPrivateIp"):
        print("  FortiAIGate private IP: " + outputs["GatewayPrivateIp"] + " | Ollama private IP: " + private)
    print("  Provider model: llama-lab | Gateway model alias: llama-lab")
    print("  Provider API key, if required by the form: ollama (placeholder; the private Ollama API has no authentication)")
    print("  Model API ingress: only EC2 instances using " + outputs.get("GatewaySecurityGroupId", "the selected FortiAIGate SG"))
    if outputs.get("GatewayAccessMode") == "child-sg-api-port":
        api_port = gateway_api_port(outputs.get("GatewayApiPort", ""))
        print("  Gateway API ingress: TCP" + str(api_port) + " from this Ollama security group only (child-stack managed).")
        print("  Automatic Configure uses the enrolled gateway private IP and API port " + str(api_port) + ".")
        print("  Gateway egress is unchanged; it must allow TCP11434 to Ollama. Destroy removes only this stack's gateway ingress rule.")
    else:
        print("  This older stack has no managed gateway rule. Allow Ollama private-IP/SG -> the gateway API port and gateway -> Ollama TCP11434.")
    if outputs.get("GatewayPrivateIp"):
        api_port = gateway_api_port(outputs.get("GatewayApiPort", "443"))
        print("  FortiAIGate API URL: https://" + outputs["GatewayPrivateIp"]
              + (":" + str(api_port) if api_port != 443 else "") + "/ai/openai/v1")
    print("  Gateway certificate: choose 8 (Prepare gateway certificate) to verify/install " + GATEWAY_CA_PATH + ".")
    print("  Connect does not check this CA file's availability. Automatic Configure requires successful enrollment; use --manual only for a custom setup.")
    if public:
        print("\nOPEN WEBUI — DIRECT BROWSER ACCESS (available after sudo ollama-lab configure):")
        print("  http://" + public + ":3000")
        print("  Sign in using the admin account created by configure, then select llama-lab.")
        print("  HTTP lab access on TCP3000: " + outputs.get("OperatorCidr", "your configured public IPv4 /32") + ". No SSH tunnel is required.")
        if outputs.get("WebUIAccessMode") != "http-public-ip-32":
            print("  This stack predates direct browser access. If not already upgraded, follow downloads/ollama/README-aws.txt before using this URL.")
        if not reserved_public:
            print("  This older lab uses an automatic public IP. If it changes after Stop/Start, run sudo ollama-lab configure --manual with the current browser URL.")
    if password_ready is None:
        password_ready = instance["State"]["Name"] == "running" and ssh_password_ready(instance["InstanceId"])
    if public and password_ready and instance["State"]["Name"] == "running":
        print("\nSSH ADMINISTRATION / FIRST CONFIGURATION (Windows PowerShell, Mac or Linux terminal):")
        print("  ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no ubuntu@" + public)
        print("  Enter the SSH password chosen privately in CloudShell. No key file is needed.")
        print("  After model status is ready, run at the Ubuntu prompt: sudo ollama-lab configure")
        print("  The current helper selects the verified API URL, certificate and saved browser URL automatically, then asks for your virtual key (hidden).")
        print("  First setup also asks for the WebUI administrator email and password. Older helpers can be updated using the guide.")
        print("  You can close the SSH session after configuration; browser access is independent.")
    elif reserved_public and instance["State"]["Name"] != "running":
        print("\nThe Elastic IP remains reserved while the VM is " + instance["State"]["Name"] + ". Start it before using the browser or SSH.")
    elif not public:
        print("\nNo current public IP. Start the instance, then run Connect again for its current browser URL and SSH address.")
    else:
        print("\nPassword SSH is not configured or could not be verified. Choose menu 7 (Set/reset SSH password) in CloudShell.")
        print("Session Manager remains the recovery path. No password SSH success is being assumed.")
    print("\nOPTIONAL RECOVERY — SESSION MANAGER (run in CloudShell only if SSH needs repair):")
    print("  aws ssm start-session --target " + instance["InstanceId"] + " --region " + REGION)
    print("  Use it for configuration or repairs; browser access does not need an SSH session.")
    print("\nThis launcher can Stop or Destroy only Ollama. The updated FortiAIGate CPU/GPU Destroy also removes this linked Ollama stack.")
    print("FortiAIGate Stop does not stop this VM. Stopped EBS storage still incurs charges; Destroy deletes model and WebUI data.")
    print("This Ollama launcher creates no timer. A parent GPU lab can delete its linked Ollama server at the parent deadline.")
    print("Use the GPU launcher to check or extend that deadline.")
    if reserved_public:
        print("Elastic IP charges also continue while stopped. Destroy disassociates and releases this stack's Elastic IP.")
    print("CPU/GPU gateway choice does not enable scanning by itself. Verify the gateway's live inspection and test a policy.")


def create(prefix, instance_type="t3a.large", api_port=None):
    if instance_type not in ("t3a.large", "t3.large"):
        raise ValueError("Use t3a.large or t3.large.")
    if api_port is not None:
        api_port = gateway_api_port(api_port)
    name = stack_name(prefix)
    existing = describe_stack(name, optional=True)
    if existing:
        assert_owned(existing)
        print("Existing Ollama stack found; no duplicate or update will be created: " + name)
        if existing["StackStatus"] == "CREATE_IN_PROGRESS":
            existing = wait_stack(name, "CREATE_COMPLETE")
        show_access(existing)
        return
    gateway_id = select_gateway()
    if gateway_id is None:
        print("Cancelled. No resources were changed.")
        return
    # Re-read after selection: the listing is only a snapshot of the host.
    gateway = instance_by_id(gateway_id)
    if gateway["State"]["Name"] not in ("running", "stopped"):
        raise RuntimeError("The FortiAIGate instance must be running or stopped.")
    if any(tag.get("Key") == "DeploymentGuide" and tag.get("Value") == MARKER for tag in gateway.get("Tags", [])):
        raise RuntimeError("The selected instance is an Ollama host. Choose the FortiAIGate CPU/GPU instance.")
    vpc_id, subnet_id = gateway["VpcId"], gateway["SubnetId"]
    subnet = ensure_public_subnet(vpc_id, subnet_id)
    gateway_private_ip = gateway_address(subnet["CidrBlock"], gateway.get("PrivateIpAddress"))
    model_private_ip = fixed_model_address(subnet["CidrBlock"])
    ensure_model_address_available(subnet_id, model_private_ip)
    groups = gateway.get("SecurityGroups", [])
    if not groups:
        raise RuntimeError("No gateway security group was found.")
    for index, group in enumerate(groups, 1):
        print(f"  {index}) {group['GroupId']}  {group['GroupName']}")
    choice = 1 if len(groups) == 1 else int(input("Choose the FortiAIGate security group number allowed to reach Ollama: "))
    if choice < 1 or choice > len(groups):
        raise ValueError("Invalid security group selection.")
    gateway_sg = groups[choice-1]["GroupId"]
    check_gateway_security_group(gateway, gateway_sg)
    edition = select_gateway_edition(gateway)
    if edition is None:
        print("Cancelled. No resources were changed.")
        return
    cidr = caller_cidr(input("Your computer's PUBLIC IPv4 for browser access and SSH (/32): "))
    if api_port is None:
        api_port = gateway_api_port(input("FortiAIGate API port (match its API URL) [443]: ").strip() or "443")
    template = build_template(prefix, vpc_id, subnet_id, gateway_id, gateway_sg, cidr, instance_type,
                              subnet_cidr=subnet["CidrBlock"], gateway_private_ip=gateway_private_ip, api_port=api_port, edition=edition)
    password_hash = prompt_password_hash()
    print("\nCreate " + name + " beside FortiAIGate " + gateway_id)
    print("Ollama EC2 name: " + prefix_of(prefix) + "_Ollama_" + edition + "_Docker (linked to " + edition + " FortiAIGate).")
    print("Reuse VPC " + vpc_id + " / subnet " + subnet_id + "; create a NEW " + instance_type + " (8 GiB), 64 GiB encrypted gp3 disk, Elastic IP, dedicated SG and SSM role.")
    print("Private IPs: FortiAIGate " + gateway_private_ip + " | Ollama " + model_private_ip + " (fixed).")
    print("Private model API: selected FortiAIGate SG only. SSH and HTTP WebUI port 3000: " + cidr + ". No browser tunnel.")
    print("Add gateway TCP" + str(api_port) + " ingress on " + gateway_sg + " from this new Ollama SG only; child Destroy/rollback removes that rule.")
    print("The public Elastic IP stays the same across Stop/Start and is released by Destroy. EBS and Elastic IP charges continue while stopped.")
    print("Normal EC2 charges apply while running. This Ollama launcher creates no timer.")
    print("A parent GPU lab can delete its linked Ollama server at the parent deadline. Use the GPU launcher to check or extend that deadline.")
    if input("Press Enter to create this Ollama server, or type 0 to cancel: ").strip():
        print("Cancelled.")
        return
    with tempfile.TemporaryDirectory(prefix="ollama-cfn-") as folder:
        template_path = Path(folder) / "template.json"
        template_path.write_text(json.dumps(template))
        aws("cloudformation", "validate-template", "--template-body", "file://" + str(template_path))
        aws("cloudformation", "create-stack", "--stack-name", name, "--template-body", "file://" + str(template_path),
            "--capabilities", "CAPABILITY_NAMED_IAM", "--on-failure", "ROLLBACK", "--tags",
            "Key=DeploymentGuide,Value=" + MARKER, "Key=UserPrefix,Value=" + prefix,
            "Key=FortiAIGateVpcId,Value=" + vpc_id, "Key=FortiAIGateInstanceId,Value=" + gateway_id)
    stack = wait_stack(name, "CREATE_COMPLETE")
    try:
        set_ssh_password(stack, password_hash)
    except (AwsError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        show_access(stack, password_ready=False)
        if isinstance(error, SshSetupError):
            raise RuntimeError("The VM was created, but SSH password setup was not confirmed. " + str(error)) from None
        raise RuntimeError("The VM was created, but SSH password setup was not confirmed. Choose menu 7 to set/reset it, or use Session Manager. No password values were printed.") from None
    finally:
        del password_hash
    show_access(stack, password_ready=True)
    print("\nWatching model installation (large image/model downloads may take several minutes)...")
    if wait_preparation(managed_instance(stack)["InstanceId"]):
        try:
            prepare_gateway(stack)
        except (GatewayCertificateError, AwsError, ValueError, RuntimeError, KeyError, subprocess.TimeoutExpired, OSError) as error:
            print("\nThe Ollama model is ready; automatic gateway certificate enrollment was not confirmed. The provisioned VM is retained.")
            if isinstance(error, GatewayCertificateError):
                print(str(error))
            print("Choose menu 8 (Prepare gateway certificate) to retry when gateway/SSM/TLS is ready. For custom setups, upload a verified public CA and use sudo ollama-lab configure --manual.")
        print("\nNext: configure the FortiAIGate provider and virtual key using the website, then sudo ollama-lab configure inside this Ollama VM.")
    else:
        print("\nModel readiness is not confirmed. Choose 3 (Status), wait until the model is ready, then continue the website's configuration steps.")


def destroy(stack):
    assert_owned(stack)
    name = stack["StackName"]
    target = stack.get("StackId", name)
    if stack["StackStatus"].endswith("_IN_PROGRESS"):
        raise RuntimeError("The stack is busy. Wait for its current action to finish before deletion.")
    resources = aws("cloudformation", "list-stack-resources", "--stack-name", target)["StackResourceSummaries"]
    allowed_types = {"AWS::EC2::Instance", "AWS::EC2::SecurityGroup", "AWS::EC2::SecurityGroupIngress", "AWS::EC2::EIP", "AWS::EC2::EIPAssociation",
                     "AWS::IAM::Role", "AWS::IAM::InstanceProfile"}
    for resource in resources:
        if resource["ResourceType"] not in allowed_types:
            raise RuntimeError("Unexpected resource type in this Ollama stack; refusing automated deletion.")
    print("\nDelete ONLY this Ollama stack and its resources:")
    for row in resources:
        print("  " + row["ResourceType"] + "  " + (row.get("PhysicalResourceId") or row.get("LogicalResourceId", "unknown")))
    print("The attached 64 GiB disk, models, WebUI accounts and chats are permanently deleted. No snapshots are created.")
    print("The existing FortiAIGate instance, VPC, subnet and gateway SG are retained.")
    if any(row["ResourceType"] == "AWS::EC2::SecurityGroupIngress" for row in resources):
        print("CloudFormation removes this child stack's gateway API ingress rule before deleting the Ollama security group.")
    if any(row["ResourceType"] == "AWS::EC2::EIP" for row in resources):
        print("The Ollama stack's Elastic IP is disassociated and released by CloudFormation.")
    if input("Type the exact stack name " + name + " to delete: ").strip() != name:
        print("Cancelled.")
        return
    aws("cloudformation", "delete-stack", "--stack-name", target)
    wait_stack(target, "DELETE_COMPLETE", deleting=True)
    print("Deleted " + name + ". Remove its old provider from FortiAIGate if no longer needed.")


def self_test():
    template = build_template("tester", "vpc-0123456789abcdef0", "subnet-0123456789abcdef0", "i-0123456789abcdef0", "sg-0123456789abcdef0", "8.8.8.8")
    rules = template["Resources"]["OllamaSecurityGroup"]["Properties"]["SecurityGroupIngress"]
    assert len(rules) == 3 and rules[0]["SourceSecurityGroupId"] == "sg-0123456789abcdef0"
    assert rules[0]["FromPort"] == 11434 and "CidrIp" not in rules[0]
    assert rules[1]["CidrIp"] == "8.8.8.8/32" and rules[1]["FromPort"] == 22
    assert rules[2]["CidrIp"] == "8.8.8.8/32" and rules[2]["FromPort"] == rules[2]["ToPort"] == 3000
    assert template["Resources"]["OllamaInstance"]["Properties"]["NetworkInterfaces"][0]["PrivateIpAddress"] == "10.250.20.20"
    assert template["Outputs"]["GatewayPrivateIp"]["Value"] == "10.250.20.10"
    assert template["Resources"]["OllamaElasticIp"]["Properties"]["Domain"] == "vpc"
    assert template["Resources"]["OllamaInstance"]["Properties"]["NetworkInterfaces"][0]["AssociatePublicIpAddress"] is False
    assert template["Outputs"]["PublicIp"]["Value"] == {"Ref": "OllamaElasticIp"}
    ingress = template["Resources"]["GatewayApiIngress"]["Properties"]
    assert ingress["SourceSecurityGroupId"] == {"Ref": "OllamaSecurityGroup"} and ingress["FromPort"] == ingress["ToPort"] == 443
    print("PASS: fixed addresses, Elastic IP, child-owned gateway API rule, private model API and /32 SSH/browser ingress.")


def main():
    global REGION
    parser = argparse.ArgumentParser(description="Create a NEW small Ollama EC2 host beside an existing FortiAIGate CPU/GPU lab. Run in AWS CloudShell.")
    parser.add_argument("action", nargs="?", choices=["create", "destroy", "status", "connect", "start", "stop", "reset-password", "prepare-gateway"])
    parser.add_argument("--region", choices=["us-east-1"], default="us-east-1", help="Fixed to us-east-1 to match the parent CPU/GPU labs and cleanup")
    parser.add_argument("--prefix", help="Letters/numbers, starting with a letter; max 24 characters")
    parser.add_argument("--instance-type", choices=["t3a.large", "t3.large"],
                        help="Create only: new Ollama EC2 type (default: t3a.large)")
    parser.add_argument("--gateway-api-port", type=gateway_api_port,
                        help="Create only: TCP port in the FortiAIGate API URL (interactive default: 443)")
    parser.add_argument("--self-test", action="store_true", help="Offline tests; no AWS calls")
    parser.add_argument("--template", action="store_true", help="Print an example CloudFormation template; no AWS calls")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.template:
        print(json.dumps(build_template("example", "vpc-0123456789abcdef0", "subnet-0123456789abcdef0", "i-0123456789abcdef0", "sg-0123456789abcdef0", "8.8.8.8"), indent=2))
        return
    REGION = args.region
    if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-\d", REGION):
        raise ValueError("Invalid AWS region.")
    if not shutil.which("aws"):
        raise RuntimeError("AWS CLI is missing. Run in AWS CloudShell, not inside Ubuntu.")
    identity = aws("sts", "get-caller-identity")
    print("\nOllama + llama-lab AWS launcher " + VERSION + " | Account " + identity["Account"] + " | " + REGION)
    action = args.action
    if not action:
        print("\n1) Create a NEW Ollama server\n2) Destroy ONLY the Ollama server\n3) Status / installation progress\n4) Connect / access details\n5) Start\n6) Stop\n7) Set/reset SSH password\n8) Prepare gateway certificate\n0) Exit\n")
        choice = input("Choose [1 = Create]: ").strip() or "1"
        if choice == "0":
            return
        action = {"1": "create", "2": "destroy", "3": "status", "4": "connect", "5": "start", "6": "stop", "7": "reset-password", "8": "prepare-gateway"}.get(choice)
        if not action:
            raise ValueError("Invalid menu choice.")
    if args.instance_type and action != "create":
        parser.error("--instance-type is available only with Create.")
    if args.gateway_api_port is not None and action != "create":
        parser.error("--gateway-api-port is available only with Create.")
    if action == "create":
        prefix = prefix_of(args.prefix or input("Your Ollama lab name prefix: "))
        create(prefix, instance_type=args.instance_type or "t3a.large", api_port=args.gateway_api_port)
        return
    target = stack_name(args.prefix) if args.prefix else select_ollama_stack()
    if target is None:
        print("Cancelled. No resources were changed.")
        return
    # Use the selected immutable ID so a replacement with the same name is not selected.
    stack = describe_stack(target)
    assert_owned(stack)
    if target.startswith("arn:") and stack.get("StackId") != target:
        raise RuntimeError("The selected Ollama stack identity changed. No resources were changed.")
    if stack.get("StackStatus") == "DELETE_COMPLETE":
        raise RuntimeError("The selected Ollama stack was deleted. No resources were changed.")
    if action == "destroy":
        destroy(stack)
        return
    if action == "status":
        print("CloudFormation: " + stack["StackStatus"])
        instance = managed_instance(stack)
        print("EC2: " + instance["State"]["Name"])
        if instance["State"]["Name"] == "running":
            try:
                print(json.dumps(read_prep(instance["InstanceId"]), indent=2))
            except (AwsError, ValueError, RuntimeError) as error:
                print("Readiness unavailable: " + str(error))
        show_access(stack)
        return
    if action == "connect":
        show_access(stack)
        return
    if action == "prepare-gateway":
        prepare_gateway(stack)
        return
    if action == "reset-password":
        if stack["StackStatus"] not in ("CREATE_COMPLETE", "UPDATE_COMPLETE"):
            raise RuntimeError("Wait for the stack to finish before setting its SSH password.")
        set_ssh_password(stack)
        show_access(stack, password_ready=True)
        return
    if stack["StackStatus"] not in ("CREATE_COMPLETE", "UPDATE_COMPLETE"):
        raise RuntimeError("The stack is not ready for instance lifecycle actions.")
    instance = managed_instance(stack)
    state = instance["State"]["Name"]
    if action == "start":
        if state != "stopped":
            print("Instance is " + state + "; no start call sent.")
            return
        aws("ec2", "start-instances", "--instance-ids", instance["InstanceId"])
        if elastic_public_ip(stack_outputs(stack)):
            print("Starting. The reserved Elastic IP is unchanged; use Connect for the browser URL and SSH details.")
        else:
            print("Starting. Run Connect again once running to get the CURRENT public IP; it may change after Stop/Start.")
    elif action == "stop":
        if state != "running":
            print("Instance is " + state + "; no stop call sent.")
            return
        stop_costs = "EBS and Elastic IP charges continue" if elastic_public_ip(stack_outputs(stack)) else "disk charges continue"
        if input("Type STOP to stop only " + instance["InstanceId"] + " (" + stop_costs + "): ").strip() == "STOP":
            aws("ec2", "stop-instances", "--instance-ids", instance["InstanceId"])
            print("Stopping only the Ollama VM. FortiAIGate is unchanged.")
        else:
            print("Cancelled.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        print("ERROR: AWS CLI exceeded its 120-second limit. Use Status before retrying a cloud action; it may have been accepted.", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted. Existing cloud resources are retained; use Status to inspect.", file=sys.stderr)
        sys.exit(130)
    except (AwsError, ValueError, RuntimeError, KeyError, EOFError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
OLLAMA_AWS_PY
python3 "$ollama_launcher_python" "$@"
