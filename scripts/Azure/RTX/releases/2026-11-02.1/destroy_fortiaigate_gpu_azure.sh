#!/usr/bin/env bash
# Version: 2026-11-02.1
# Run as a saved file in Azure CloudShell Bash; prompts read the terminal.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { printf 'Use Azure CloudShell Bash; Python 3 is required.\n' >&2; exit 1; }
forti_runtime=$(mktemp "${TMPDIR:-/tmp}/fortiaigate-azure-gpu.XXXXXXXX")
trap 'rm -f -- "$forti_runtime"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$forti_runtime" <<'FORTI_AZURE_GPU_PY'
#!/usr/bin/env python3
"""Azure CloudShell lab lifecycle. Uses the signed-in Azure CLI account."""
import base64
import hashlib
import datetime
import shlex
import tempfile
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

LOCATION = "eastus"
SIZE = "Standard_NC72lds_xl_RTXPRO6000BSE_v6"
IMAGE = "Canonical:ubuntu-22_04-lts:server:latest"
DISK_GIB = 512
MANAGER = "FortiAIGateCloudShell"
LAB = "gpu-8.0.2-rtx-preview"
SUBSCRIPTION = ""
ACTIVE_GROUP = ""
SCRIPT_VERSION = "2026-11-02.1"
SKU_CHECK_TIMEOUT = 180
PROGRESS_SECONDS = 10

# Public preparation script; pin its bytes before running it as root.
PREP_URL = "https://raw.githubusercontent.com/WEEMR/FortiAIGate/azure-rtx-2026-11-02.1/scripts/Azure/RTX/releases/2026-11-02.1/user_data/prepare_fortiaigate_gpu_azure_rtx.sh"
PREP_SHA256 = "fc2d0bb76795b2282e4e326391e9db534997bc1a67fcd37ad3c63185772e8f43"
CPU_PREP_URL = "https://raw.githubusercontent.com/WEEMR/FortiAIGate/shared-2026-11-02.1/scripts/Home/releases/2026-11-02.1/prepare_fortiaigate_cpu.sh"
CPU_PREP_SHA256 = "db1cf5ca6d2a0519a2b633e6c3fd9991325d288bd064367891506d64c843ffb6"
PREP_READY_SENTINEL = "FORTIAIGATE_GPU_READY"
PREP_TIMEOUT_SECONDS = 2700
BLOB_READER_ROLE = "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
BUILD = "V8.0.2-build0055-FORTINET"
COMPONENTS = "api webui llm-gateway logd license_manager guardrail guardrail-scanner custom-triton faig-models vllm-server".split()
PREP_WAIT_SCRIPT = """#!/bin/sh
if test -f /var/lib/fortiaigate-prep/GPU_FAILED || test -f /var/lib/fortiaigate-prep/FAILED; then
  printf 'FORTIAIGATE_GPU_FAILED\\n'
elif test -f /var/lib/fortiaigate-prep/GPU_READY; then
  printf 'FORTIAIGATE_GPU_READY\\n'
else
  printf 'FORTIAIGATE_GPU_WAITING\\n'
fi
"""


def verify_preparation_download(url, digest, label):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password
            or parsed.query or parsed.fragment or not re.fullmatch(r"[0-9a-f]{64}", digest)):
        raise RuntimeError("Preparation needs a public HTTPS URL without credentials/query and a reviewed SHA-256 pin.")
    if not shutil.which("curl"):
        raise RuntimeError("curl is required in CloudShell to verify the preparation script.")
    try:
        result = subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                                 "--proto", "=https", "--tlsv1.2", "--connect-timeout", "15",
                                 "--max-time", "90", "--retry", "2", url], capture_output=True,
                                timeout=280)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("Preparation preflight download timed out. No resources were created.") from error
    if result.returncode:
        raise RuntimeError(f"{label} download failed before creation. Publish the matching reviewed preparation scripts first. " + result.stderr.decode(errors="replace").strip())
    if len(result.stdout) > 1024 * 1024 or hashlib.sha256(result.stdout).hexdigest() != digest:
        raise RuntimeError(f"{label} checksum differs from this reviewed creator. No resources were created.")
    print(f"{label}: public download and SHA-256 verified.", flush=True)


def preparation_preflight():
    """Check both pinned dependencies before any billable resources exist."""
    verify_preparation_download(PREP_URL, PREP_SHA256, "Azure GPU preparation")
    verify_preparation_download(CPU_PREP_URL, CPU_PREP_SHA256, "Shared host preparation")


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
touch /var/lib/fortiaigate-prep/GPU_MODE
printf '%s' """ + shlex.quote(encoded) + """ | base64 --decode > /etc/fortiaigate-prep.json
chmod 0600 /etc/fortiaigate-prep.json
if ! command -v curl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  for forti_attempt in 1 2 3; do
    if apt-get -o DPkg::Lock::Timeout=300 update && apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates curl; then break; fi
    test "$forti_attempt" -lt 3 || false
    sleep 10
  done
fi
forti_download=$(mktemp /tmp/fortiaigate-prep.XXXXXXXX)
curl --fail --location --show-error --retry 3 --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \\
  """ + shlex.quote(PREP_URL) + """ --output "$forti_download"
printf '%s  %s\\n' """ + shlex.quote(PREP_SHA256) + """ "$forti_download" | sha256sum --check
bash -n "$forti_download"
install -m 0755 "$forti_download" /usr/local/sbin/prepare_fortiaigate_gpu_azure_rtx.sh
rm -f "$forti_download"
/usr/local/sbin/prepare_fortiaigate_gpu_azure_rtx.sh
"""



class Failure(RuntimeError):
    pass


def az(*args, scoped=True, timeout=None, progress=None):
    command = ["az", *map(str, args), "--only-show-errors", "--output", "json"]
    if scoped:
        command += ["--subscription", SUBSCRIPTION]
    mutating = any(a in args for a in ("create", "delete", "update"))
    timeout = timeout if timeout is not None else (1800 if mutating else 120)
    label = progress or "az " + " ".join(args[:3])
    print(f"  {label}", flush=True)
    started = time.monotonic()
    # A separate process group lets timeout/Ctrl+C stop only this CLI invocation.
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as process:
        try:
            while True:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    raise Failure(f"{label} exceeded its {timeout:.0f}-second limit. Azure CLI was stopped.")
                try:
                    stdout, stderr = process.communicate(timeout=min(PROGRESS_SECONDS, remaining))
                    break
                except subprocess.TimeoutExpired:
                    print(f"  Still waiting: {label} ({time.monotonic() - started:.0f}s elapsed)", flush=True)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
        if process.returncode:
            raise Failure(stderr.strip() or stdout.strip() or "Azure CLI failed.")
    return json.loads(stdout) if stdout.strip() else None


def setup():
    global SUBSCRIPTION
    if not shutil.which("az"):
        raise Failure("Open Azure CloudShell and choose Bash; Azure CLI is required.")
    os.environ["AZURE_CORE_ONLY_SHOW_ERRORS"] = "true"
    # Explicit login mode and a clean child-process environment prevent stored
    # CloudShell keys/SAS/connection strings from replacing the signed-in user.
    for variable in ("AZURE_STORAGE_KEY", "AZURE_STORAGE_SAS_TOKEN", "AZURE_STORAGE_CONNECTION_STRING",
                     "AZURE_STORAGE_SERVICE_ENDPOINT", "AZURE_STORAGE_BLOB_ENDPOINT"):
        os.environ.pop(variable, None)
    print(f"FortiAIGate Azure scripts: {SCRIPT_VERSION}", flush=True)
    account = az("account", "show", scoped=False)
    SUBSCRIPTION = account["id"]
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", SUBSCRIPTION):
        raise Failure("Azure returned an invalid subscription ID.")
    print(f"\nSubscription: {account['name']} ({SUBSCRIPTION})")
    print(f"Signed in as: {account.get('user', {}).get('name', '(Azure identity)')}")
    print("Use az account set --subscription <ID> first if this is the wrong subscription.")


def slug(value):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,19}", value):
        raise Failure("Use 1–20 letters, digits, hyphens or underscores; start with a letter.")
    return value.lower().replace("_", "-")


def ipv4(value):
    value = value.strip()
    if value.endswith("/32"):
        value = value[:-3]
    address = ipaddress.ip_address(value)
    if address.version != 4 or not address.is_global:
        raise Failure("Enter one public IPv4 address, optionally followed by /32.")
    return str(address)


def shell_ip():
    with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=15) as response:
        return ipv4(response.read(128).decode())


def prompt_browser_ip():
    print("Open https://checkip.amazonaws.com in YOUR computer's browser and copy the IPv4 address.")
    print("CloudShell's IP is used for SSH; your computer's IP is needed for browser HTTPS access.")
    while True:
        value = input("Your browser's public IPv4 for HTTPS (with or without /32; 0 to cancel): ").strip()
        if value == "0":
            return None
        try:
            return ipv4(value)
        except ValueError:
            print("Enter a public IPv4 address, optionally ending in /32. A blank value is not valid.")
        except Failure as error:
            print(error)


def confirm(prompt):
    choice = input(prompt + "\n1) Continue (default)   0) Cancel\nChoice [1]: ").strip() or "1"
    if choice != "1":
        print("Cancelled. No requested cloud changes were made.")
        return False
    return True


def lab_tags(group):
    tags = group.get("tags") or {}
    return (tags.get("ManagedBy") == MANAGER and tags.get("FortiAIGateLab") == LAB
            and re.fullmatch(r"[0-9a-f]{32}", tags.get("LabId", "")))


def select_group():
    global ACTIVE_GROUP
    groups = [g for g in az("group", "list") if lab_tags(g)]
    if not groups:
        raise Failure("No resource groups created by these FortiAIGate scripts exist in this subscription.")
    print("\nAvailable labs:")
    for group in groups:
        print(f"  {group['name']}  [{group['location']}]  user={group['tags'].get('Username', '')}")
    value = input("Enter username, resource-group name, or resource-group ID: ").strip()
    token = value.casefold()
    normalized = token.replace("_", "-")
    matches = [g for g in groups if token in (g["name"].casefold(), g["id"].casefold())
               or normalized == g["tags"].get("Username", "").casefold()]
    if len(matches) != 1:
        raise Failure("No unique matching lab. Use the exact resource-group name from the list.")
    group = matches[0]
    ACTIVE_GROUP = group["name"]
    return group


def key_path(group):
    if not lab_tags(group):
        raise Failure("The resource group does not have valid FortiAIGate ownership tags.")
    return Path.home() / ".ssh" / "fortiaigate-azure-gpu" / SUBSCRIPTION / group["tags"]["LabId"]


def create_key(group):
    if not shutil.which("ssh-keygen"):
        raise Failure("ssh-keygen is required; use Azure CloudShell Bash.")
    key = key_path(group)
    key.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    key.parent.chmod(0o700)
    if key.exists() or Path(str(key) + ".pub").exists():
        raise Failure(f"Refusing to overwrite an existing SSH key: {key}")
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                    "FortiAIGate Azure GPU lab", "-f", str(key)], check=True)
    key.chmod(0o600)
    return key


def rule_values(rule_data, singular, plural):
    """Azure may return one value in a scalar or several in an array."""
    values = list(rule_data.get(plural) or [])
    if rule_data.get(singular):
        values.append(rule_data[singular])
    return set(map(str, values))


def verify_rule(rule_data, name, priority, port, source):
    expected_source = ipv4(source) + "/32"
    prefixes = rule_values(rule_data, "sourceAddressPrefix", "sourceAddressPrefixes")
    try:
        prefixes = {str(ipaddress.ip_network(p, strict=True)) for p in prefixes}
    except ValueError:
        prefixes = set()
    checks = (
        str(rule_data.get("name", "")).casefold() == name.casefold(),
        str(rule_data.get("direction", "")).casefold() == "inbound",
        str(rule_data.get("access", "")).casefold() == "allow",
        str(rule_data.get("protocol", "")).casefold() == "tcp",
        rule_data.get("priority") == priority,
        prefixes == {expected_source},
        rule_values(rule_data, "sourcePortRange", "sourcePortRanges") == {"*"},
        rule_values(rule_data, "destinationPortRange", "destinationPortRanges") == {str(port)},
        rule_values(rule_data, "destinationAddressPrefix", "destinationAddressPrefixes") == {"*"},
        not rule_data.get("sourceApplicationSecurityGroups"),
        not rule_data.get("destinationApplicationSecurityGroups"),
    )
    if not all(checks):
        raise Failure(f"NSG rule {name} did not verify as Allow inbound TCP {port} from {expected_source}. "
                      "Inspect the attached NSG or use launcher option 4 to repair access.")


def rule(group, nsg, name, priority, port, source):
    source = ipv4(source)
    az("network", "nsg", "rule", "create", "--resource-group", group, "--nsg-name", nsg,
       "--name", name, "--priority", str(priority), "--direction", "Inbound",
       "--access", "Allow", "--protocol", "Tcp", "--source-address-prefixes", source + "/32",
       "--source-port-ranges", "*", "--destination-address-prefixes", "*",
       "--destination-port-ranges", str(port))
    saved = az("network", "nsg", "rule", "show", "--resource-group", group,
               "--nsg-name", nsg, "--name", name)
    verify_rule(saved, name, priority, port, source)
    print(f"  Verified {name}: inbound TCP {port} from {source}/32", flush=True)


def permits_port(rule_data, port):
    if (str(rule_data.get("direction", "")).casefold() != "inbound"
            or str(rule_data.get("access", "")).casefold() != "allow"
            or str(rule_data.get("protocol", "")).casefold() not in ("tcp", "*")):
        return False
    ranges = rule_values(rule_data, "destinationPortRange", "destinationPortRanges")
    for value in ranges:
        if value == "*":
            return True
        pieces = value.split("-")
        if len(pieces) == 1 and pieces[0].isdigit() and int(pieces[0]) == port:
            return True
        if len(pieces) == 2 and all(p.isdigit() for p in pieces) and int(pieces[0]) <= port <= int(pieces[1]):
            return True
    return False


def access_rule_names(nsg, ports=(22, 443)):
    """Reuse known lab/portal rules; stop instead of leaving a broader rule behind."""
    names = {22: ("FortiAIGate_SSH_CloudShell", "FortiAIGate-SSH-CloudShell", "SSH"),
             443: ("FortiAIGate_HTTPS_Client", "FortiAIGate-HTTPS-Client", "HTTPS")}
    rules = nsg.get("securityRules") or []
    chosen = {}
    for port in ports:
        known = {n.casefold() for n in names[port]}
        matches = [r for r in rules if r.get("name", "").casefold() in known]
        if len(matches) > 1:
            raise Failure(f"Multiple lab {'SSH' if port == 22 else 'HTTPS'} rules exist. Resolve the duplicate rules before retrying.")
        chosen[port] = matches[0]["name"] if matches else names[port][0]
        other = [r.get("name", "(unnamed)") for r in rules
                 if permits_port(r, port) and r.get("name", "").casefold() not in known]
        if other:
            raise Failure(f"Other inbound rules also allow TCP {port}: {', '.join(other)}. "
                          "Review them first; adding a /32 rule would not restrict those existing rules.")
        priority = 100 if port == 22 else 110
        conflicts = [r.get("name", "(unnamed)") for r in rules
                     if str(r.get("direction", "")).casefold() == "inbound"
                     and r.get("priority") == priority
                     and r.get("name", "").casefold() != chosen[port].casefold()]
        if conflicts:
            raise Failure(f"NSG priority {priority} is already used by {', '.join(conflicts)}. No unrelated rule was replaced.")
    return chosen


def vm_network(group, vm, *, require_managed=True, exclusive=False):
    interfaces = vm.get("networkProfile", {}).get("networkInterfaces", [])
    if len(interfaces) != 1 or not own_id(group, interfaces[0]["id"]):
        raise Failure("Expected one VM network interface in the selected resource group.")
    nic_id = interfaces[0]["id"]
    nic = az("network", "nic", "show", "--ids", nic_id)
    attached_vm = (nic.get("virtualMachine") or {}).get("id", "")
    if attached_vm.casefold() != vm["id"].casefold():
        raise Failure("The network interface does not report attachment to the selected VM.")
    nsg_id = (nic.get("networkSecurityGroup") or {}).get("id", "")
    if not own_id(group, nsg_id):
        raise Failure("The VM has no NIC-level NSG in this resource group. Review its networking before retrying.")
    nsg = az("network", "nsg", "show", "--ids", nsg_id)
    if require_managed and (nsg.get("tags") or {}).get("LabId") != group["tags"]["LabId"]:
        raise Failure("The attached NSG is not tagged for this lab.")
    if exclusive:
        attached = {n["id"].casefold() for n in nsg.get("networkInterfaces", [])}
        if attached != {nic_id.casefold()} or nsg.get("subnets"):
            raise Failure("The NSG is shared or its exclusive attachment could not be verified. Inspect its associations before retrying.")
        subnets = {c.get("subnet", {}).get("id", "") for c in nic.get("ipConfigurations", [])}
        if not subnets or "" in subnets:
            raise Failure("Could not verify the VM subnet before changing access rules.")
        for subnet_id in subnets:
            subnet = az("network", "vnet", "subnet", "show", "--ids", subnet_id)
            if subnet.get("networkSecurityGroup"):
                raise Failure("A subnet NSG also controls this VM. Review both NSGs before retrying.")
    return nic, nsg


def verify_access(nsg, ssh_source, https_source):
    names = access_rule_names(nsg)
    for port, priority, source in ((22, 100, ssh_source), (443, 110, https_source)):
        matches = [r for r in nsg.get("securityRules", []) if r.get("name", "").casefold() == names[port].casefold()]
        if len(matches) != 1:
            raise Failure(f"TCP {port} rule is missing from the VM's attached NSG. Use launcher option 4 to repair access.")
        verify_rule(matches[0], names[port], priority, port, source)
    print(f"PASS: attached NSG {nsg['name']} has SSH from {ipv4(ssh_source)}/32 "
          f"and HTTPS from {ipv4(https_source)}/32.", flush=True)


def own_id(group, resource_id):
    return resource_id.casefold().startswith(group["id"].casefold().rstrip("/") + "/providers/")


def save_inventory(group, data, label):
    directory = Path.home() / ".fortiaigate" / "azure-gpu" / SUBSCRIPTION / group["tags"]["LabId"]
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    path = directory / f"{label}-{stamp}.json"
    with path.open("x") as stream:
        path.chmod(0o600)
        json.dump(data, stream, indent=2)
    return path


def check_vm_size():
    # Filter on Azure's server: list-skus may enumerate the entire SKU catalog.
    query = urllib.parse.urlencode({"api-version": "2021-07-01", "$filter": f"location eq '{LOCATION}'"})
    url = f"https://management.azure.com/subscriptions/{SUBSCRIPTION}/providers/Microsoft.Compute/skus?{query}"
    deadline = time.monotonic() + SKU_CHECK_TIMEOUT
    seen = set()
    while url:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "management.azure.com" or url in seen:
            raise Failure("Azure returned an unexpected SKU pagination URL; no resources were created.")
        seen.add(url)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Failure("VM-size lookup exceeded three minutes; no resources were created. Retry later.")
        page = az("rest", "--method", "GET", "--url", url, timeout=remaining,
                  progress=f"Checking {SIZE} in {LOCATION}, page {len(seen)} (3-minute total limit)")
        if not isinstance(page, dict) or not isinstance(page.get("value"), list):
            raise Failure("Azure returned an invalid SKU response; no resources were created.")
        for sku in page["value"]:
            if sku.get("name") != SIZE or sku.get("resourceType") != "virtualMachines":
                continue
            if LOCATION.casefold() not in [location.casefold() for location in sku.get("locations", [])]:
                continue
            for restriction in sku.get("restrictions", []):
                if restriction.get("type", "").casefold() != "location":
                    continue
                locations = (restriction.get("restrictionInfo") or {}).get("locations") or restriction.get("values", [])
                if not locations or LOCATION.casefold() in [location.casefold() for location in locations]:
                    reason = restriction.get("reasonCode", "subscription restriction")
                    raise Failure(f"{SIZE} is restricted in {LOCATION}: {reason}. No resources were created.")
            verify_gpu_sku(sku)
            check_quota(sku)
            print(f"  {SIZE}: one 48 GB RTX PRO 6000 allocation, 72 vCPU, 132 GiB RAM; no location restriction. Capacity is checked during deployment.", flush=True)
            return
        url = page.get("nextLink")
    raise Failure(f"{SIZE} was not found for this subscription in {LOCATION}. No resources were created.")


def verify_gpu_sku(sku):
    caps = {c.get("name", "").casefold(): str(c.get("value", ""))
            for c in sku.get("capabilities", [])}
    expected = {"vcpus": 72, "memorygb": 132}
    try:
        valid = all(float(caps.get(key, "nan")) == value for key, value in expected.items())
        # Azure may describe the physical GPU count as 1 rather than its 1/2 allocation.
        if "gpus" in caps:
            valid = valid and float(caps["gpus"]) in (0.5, 1.0)
        memory = caps.get("gpumemorygb", caps.get("gpumemoryingb"))
        if memory is not None:
            valid = valid and float(memory) == 48
        if "vcpusavailable" in caps:
            valid = valid and int(caps["vcpusavailable"]) == 72
    except (ValueError, TypeError):
        valid = False
    generations = {v.strip().upper() for v in caps.get("hypervgenerations", "").split(",")}
    if sku.get("name") != SIZE or not valid or "V2" not in generations or not sku.get("family"):
        raise Failure("Expected Standard_NC72lds_xl_RTXPRO6000BSE_v6: 48 GB allocation, 72 vCPU, 132 GiB RAM, Gen2. No VM was created.")


def check_quota(sku):
    usage = az("vm", "list-usage", "--location", LOCATION)
    if not isinstance(usage, list):
        raise Failure("Azure did not return a valid regional quota response. No VM was created.")
    values = {str(item.get("name", {}).get("value", "")).casefold(): item for item in usage}
    for name in (sku["family"], "cores"):
        item = values.get(name.casefold())
        try:
            available = int(item["limit"]) - int(item["currentValue"])
        except (TypeError, ValueError, KeyError, OverflowError):
            available = -1
        if available < 72:
            raise Failure(f"Need at least 72 unused vCPUs in both {sku['family']} and Total Regional vCPUs in {LOCATION}. Request quota or free capacity before Create. No VM was created.")
    print("  Family and total regional quotas each have at least 72 unused vCPUs.", flush=True)


def check_image():
    image = az("vm", "image", "show", "--urn", IMAGE, "--location", LOCATION)
    if str(image.get("hyperVGeneration", "")).upper() != "V2" or str(image.get("architecture", "")).casefold() != "x64":
        raise Failure("The selected Ubuntu 22.04 image did not verify as x64 Gen2. No VM was created.")


def validate_release(account, container, prefix):
    if not re.fullmatch(r"[a-z0-9]{3,24}", account):
        raise Failure("Enter a 3–24 character lowercase Azure storage account name.")
    if (not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", container)
            or "--" in container):
        raise Failure("Enter a valid private Blob container name (3–63 lowercase letters, digits or single hyphens).")
    if (not prefix or len(prefix) > 512 or not re.fullmatch(r"[A-Za-z0-9_./-]+", prefix)
            or any(part in ("", ".", "..") for part in prefix.split("/"))):
        raise Failure("Enter a release prefix without empty, . or .. path segments.")


def inspect_release(blobs, prefix):
    """Metadata only: eleven nonempty, unambiguous archives; no object contents."""
    sizes = {}
    for blob in blobs:
        properties = blob.get("properties") or {}
        sizes[blob.get("name", "")] = properties.get("contentLength", blob.get("contentLength", 0))
    names = [f"Images/FAIG_{part}-{BUILD}.tar" for part in COMPONENTS]
    names.append(f"Installer/FAIG_deploy-docker-compose-cli-{BUILD}.tar.gz")
    selected = []
    for name in names:
        variants = [name] if name.startswith("Installer/") else [name, name + ".gz"]
        present = [prefix + "/" + variant for variant in variants if prefix + "/" + variant in sizes]
        if len(present) != 1:
            raise Failure(f"Private release has missing or duplicate variants: {name}. Finish uploads before Create.")
        try:
            nonempty = int(sizes[present[0]]) > 0
        except (ValueError, TypeError):
            nonempty = False
        if not nonempty:
            raise Failure(f"Private release contains an empty archive: {name}.")
        selected.append(present[0])
    return selected


def release_preflight():
    account = input("Existing private Azure storage account: ").strip()
    container = input("Private Blob container: ").strip()
    prefix = input("GPU release prefix [FortiAIGate_8.0.2_GPU]: ").strip() or "FortiAIGate_8.0.2_GPU"
    prefix = prefix.strip("/")
    validate_release(account, container, prefix)
    matches = [item for item in az("storage", "account", "list") if item.get("name") == account]
    if len(matches) != 1:
        raise Failure("Storage account must already exist in the selected subscription. It was not created or changed.")
    storage = matches[0]
    if (storage.get("publicNetworkAccess", "Enabled") != "Enabled"
            or (storage.get("networkRuleSet") or {}).get("defaultAction", "Allow") != "Allow"):
        raise Failure("This storage account restricts public network access. The new GPU VNet has no private endpoint or firewall exception. Use an existing private container reachable over its authenticated public HTTPS endpoint; storage networking was not changed. No VM was created.")
    endpoint = storage.get("primaryEndpoints", {}).get("blob", "")
    if endpoint != f"https://{account}.blob.core.windows.net/":
        raise Failure("This script requires an Azure public-cloud Blob HTTPS endpoint.")
    # Explicit login mode prevents Azure CLI from fetching account keys.
    metadata = az("storage", "container", "show", "--account-name", account, "--name", container,
                  "--auth-mode", "login")
    public_access = (metadata.get("properties") or {}).get("publicAccess")
    if public_access not in (None, "None", "none", ""):
        raise Failure("Release container is public. Use an existing private container; permissions were not changed.")
    blobs = az("storage", "blob", "list", "--account-name", account, "--container-name", container,
               "--prefix", prefix + "/", "--num-results", "*", "--auth-mode", "login")
    selected = inspect_release(blobs, prefix)
    print(f"  Private Blob release: {len(selected)}/11 archives present and nonempty (metadata checked with your signed-in identity).", flush=True)
    return {"account": account, "container": container, "prefix": prefix,
            "scope": storage["id"].rstrip("/") + "/blobServices/default/containers/" + container}


def allows_action(permission, action):
    import fnmatch
    return (any(fnmatch.fnmatchcase(action.casefold(), str(pattern).casefold()) for pattern in permission.get("actions", []))
            and not any(fnmatch.fnmatchcase(action.casefold(), str(pattern).casefold()) for pattern in permission.get("notActions", [])))


def check_assignment_permission(scope):
    url = f"https://management.azure.com{scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    permissions = []
    seen = set()
    deadline = time.monotonic() + 180
    while url:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "management.azure.com" or url in seen or len(seen) >= 20:
            raise Failure("Unexpected authorization pagination response. No VM was created.")
        seen.add(url)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Failure("Authorization permission check exceeded three minutes. No VM was created.")
        result = az("rest", "--method", "GET", "--url", url, timeout=remaining)
        if not isinstance(result, dict) or not isinstance(result.get("value"), list):
            raise Failure("Invalid authorization permission response. No VM was created.")
        permissions.extend(result["value"])
        url = result.get("nextLink")
    for action in ("Microsoft.Authorization/roleAssignments/write", "Microsoft.Authorization/roleAssignments/delete"):
        if not any(allows_action(permission, action) for permission in permissions):
            raise Failure("Your signed-in identity needs roleAssignments/write and /delete on this container (for example Role Based Access Control Administrator at this scope). No VM was created. Existing storage permissions were not changed.")


def assignment_id(group, scope):
    name = str(uuid.uuid5(uuid.NAMESPACE_URL, group["tags"]["LabId"] + "|" + scope.casefold()))
    return scope.rstrip("/") + "/providers/Microsoft.Authorization/roleAssignments/" + name


def verify_assignment(assignment, principal, scope, expected_id):
    # `az role assignment` flattens properties; raw ARM `az rest` retains them.
    properties = assignment.get("properties") or assignment
    if (str(properties.get("principalId", "")).casefold() != principal.casefold()
            or str(properties.get("scope", "")).casefold() != scope.casefold()
            or str(properties.get("roleDefinitionId", "")).split("/")[-1].casefold() != BLOB_READER_ROLE
            or str(assignment.get("id", "")).casefold() != expected_id.casefold()
            or properties.get("condition")):
        raise Failure("The dedicated identity's exact container-scoped Blob Reader assignment did not verify. No VM was created; inspect retained lab resources.")


def create_release_identity(group, name, release, tags):
    identity = az("identity", "create", "--resource-group", group["name"], "--name", name,
                  "--location", LOCATION, "--tags", *tags)
    if not own_id(group, identity.get("id", "")):
        raise Failure("Managed identity was not created inside the dedicated GPU resource group.")
    for field in ("clientId", "principalId"):
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", identity.get(field, "")):
            raise Failure("Managed identity has an invalid client/principal ID. No VM was created.")
    expected_id = assignment_id(group, release["scope"])
    assigned = az("role", "assignment", "create", "--assignee-object-id", identity["principalId"],
                  "--assignee-principal-type", "ServicePrincipal", "--role", BLOB_READER_ROLE,
                  "--scope", release["scope"], "--name", expected_id.rsplit("/", 1)[-1])
    verify_assignment(assigned, identity["principalId"], release["scope"], expected_id)
    # Read back the persisted ARM object; data-plane propagation is retried by prep.
    saved = az("rest", "--method", "GET", "--url", "https://management.azure.com" + expected_id + "?api-version=2022-04-01")
    verify_assignment(saved, identity["principalId"], release["scope"], expected_id)
    print("  Verified dedicated UAMI and container-only Storage Blob Data Reader assignment before VM creation.", flush=True)
    return identity


def owned_reader_assignment(group, resources):
    scope = group["tags"].get("ReleaseContainerScope", "")
    scope_pattern = rf"/subscriptions/{re.escape(SUBSCRIPTION)}/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[a-z0-9]{{3,24}}/blobServices/default/containers/[a-z0-9-]{{3,63}}"
    if not re.fullmatch(scope_pattern, scope, re.IGNORECASE):
        raise Failure("This GPU lab has no valid container scope tag. Review its identity and Reader assignment before deletion.")
    identities = [r for r in resources if r.get("type", "").casefold() == "microsoft.managedidentity/userassignedidentities"]
    assignments = az("role", "assignment", "list", "--scope", scope,
                     "--fill-principal-name", "false", "--fill-role-definition-name", "false")
    expected_id = assignment_id(group, scope)
    matches = [a for a in assignments if str(a.get("id", "")).casefold() == expected_id.casefold()]
    if not matches:
        return None
    if len(matches) != 1 or len(identities) != 1 or not own_id(group, identities[0]["id"]):
        raise Failure("Could not uniquely verify this GPU lab's managed identity and Reader assignment; deletion stopped.")
    identity = az("identity", "show", "--ids", identities[0]["id"])
    if (identity.get("tags") or {}).get("LabId") != group["tags"]["LabId"]:
        raise Failure("Managed identity ownership differs from the selected GPU lab; deletion stopped.")
    verify_assignment(matches[0], identity["principalId"], scope, expected_id)
    return matches[0]



def wait_for_preparation(rg, vm):
    print("Waiting up to 45 minutes for GPU preparation and its automatic reboot...", flush=True)
    started = time.monotonic()
    deadline = started + PREP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        try:
            result = az("vm", "run-command", "invoke", "--resource-group", rg, "--name", vm,
                        "--command-id", "RunShellScript", "--scripts", PREP_WAIT_SCRIPT,
                        timeout=min(180, remaining), progress="Checking GPU preparation")
        except Failure as error:
            # RunCommand/VM-agent reconnects can fail around the one automatic reboot.
            if not re.search(r"(?i)(agent.*(?:unavailable|not.ready|not.respond)|VMExtensionProvisioningError|OperationPreempted|Conflict|another.*(?:operation|command)|in.progress|timeout|timed.out|exceeded.*limit|VM.*(?:not.running|reboot))", str(error)):
                raise
            print("  GPU preparation is rebooting or the VM agent is busy; retrying.", flush=True)
        else:
            if not isinstance(result, dict) or not isinstance(result.get("value"), list):
                raise Failure("Invalid GPU preparation status response; inspect the existing VM.")
            lines = {line.strip() for item in result["value"] if isinstance(item, dict)
                     for line in str(item.get("message", "")).splitlines()}
            if "FORTIAIGATE_GPU_FAILED" in lines:
                raise Failure("GPU preparation failed. Connect to the retained VM; run sudo fortiaigate-prep-status and inspect /var/log/fortiaigate-gpu-prep.log. Do not rerun Create.")
            if PREP_READY_SENTINEL in lines:
                print("PASS: GPU_READY: NVIDIA driver, Docker GPU access, release files and assistant verified. Run fortiaigate-install to start the wizard.", flush=True)
                return
        elapsed = time.monotonic() - started
        print(f"  Please wait... GPU preparation ({elapsed:.0f}s elapsed).", flush=True)
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(10, remaining))
    raise Failure("GPU preparation exceeded 45 minutes. Resources were retained. Connect and inspect sudo fortiaigate-prep-status and /var/log/fortiaigate-gpu-prep.log before continuing.")


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


def budget_workflow(group, vm_id, location):
    """Consumption workflow: RG-scoped identity, no public HTTP trigger or secrets."""
    rg_id = group['id']
    if (not budget_re.fullmatch(r'/subscriptions/[a-fA-F0-9-]{36}/resourceGroups/[A-Za-z0-9_.()-]+', rg_id)
            or not budget_re.fullmatch(r'[a-f0-9]{32}', group['tags']['LabId'])
            or not budget_re.fullmatch(budget_re.escape(rg_id) + r'/providers/Microsoft\.Compute/virtualMachines/[A-Za-z0-9_-]+', vm_id, budget_re.I)):
        raise RuntimeError('Budget target must be the VM inside the dedicated lab group.')
    rg_uri = 'https://management.azure.com' + rg_id + '?api-version=2021-04-01'
    def http(method, uri, body=None, after=None):
        inputs = {'method': method, 'uri': uri,
                  'authentication': {'type': 'ManagedServiceIdentity', 'audience': 'https://management.azure.com/'}}
        if body is not None: inputs['body'] = body
        return {'type': 'Http', 'inputs': inputs, 'runAfter': after or {}}
    deletion = http('DELETE', rg_uri)
    deallocation = http('POST', 'https://management.azure.com' + vm_id + '/deallocate?api-version=2024-07-01')
    stop_record = http('PATCH', 'https://management.azure.com' + rg_id + '/providers/Microsoft.Resources/tags/default?api-version=2021-04-01',
        {'operation': 'Merge', 'properties': {'tags': {'BudgetStopSentFor': "@body('Get_group')?['tags']?['BudgetStopAt']"}}},
        {'Deallocate_VM': ['Succeeded']})
    stop_condition = {
        'type': 'If', 'runAfter': {},
        'expression': "@and(lessOrEquals(ticks(body('Get_group')?['tags']?['BudgetStopAt']),ticks(utcNow())),not(equals(body('Get_group')?['tags']?['BudgetStopSentFor'],body('Get_group')?['tags']?['BudgetStopAt'])))",
        'actions': {'Deallocate_VM': deallocation, 'Record_stop': stop_record}, 'else': {'actions': {}}}
    expiry = {'type': 'If', 'runAfter': {},
              'expression': "@lessOrEquals(ticks(body('Get_group')?['tags']?['BudgetDeleteAt']),ticks(utcNow()))",
              'actions': {'Delete_dedicated_lab_group': deletion}, 'else': {'actions': {'Stop_if_due': stop_condition}}}
    owner = group['tags']['LabId']
    owned = {'type': 'If', 'runAfter': {'Get_group': ['Succeeded']},
             'expression': "@and(equals(body('Get_group')?['tags']?['LabId'],'" + owner + "'),equals(body('Get_group')?['tags']?['BudgetVersion'],'" + BUDGET_VERSION + "'))",
             'actions': {'Expiry_or_stop': expiry}, 'else': {'actions': {}}}
    definition = {'$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#',
                  'contentVersion': '1.0.0.0',
                  'triggers': {'Every_five_minutes': {'type': 'Recurrence', 'recurrence': {'frequency': 'Minute', 'interval': 5},
                    'runtimeConfiguration': {'concurrency': {'runs': 1}}}},
                  'actions': {'Get_group': http('GET', rg_uri), 'Verify_owned_lab': owned}, 'outputs': {}}
    return {'location': location, 'identity': {'type': 'SystemAssigned'},
            'tags': {'ManagedBy': group['tags']['ManagedBy'], 'LabId': owner},
            'properties': {'state': 'Enabled', 'definition': definition, 'parameters': {}}}


def install_budget(api, group, vm_id, location, now=None):
    # This controller is created BEFORE the VM: protection is not a best-effort post-step.
    workflow_id = group['id'] + '/providers/Microsoft.Logic/workflows/FortiAIGate_lab_lifecycle'
    uri = 'https://management.azure.com' + workflow_id + '?api-version=2019-05-01'
    body = budget_workflow(group, vm_id, location)
    result = api('rest', '--method', 'put', '--url', uri, '--body', budget_json.dumps(body))
    principal = ((result or {}).get('identity') or {}).get('principalId', '')
    try: budget_uuid.UUID(principal)
    except (ValueError, TypeError, AttributeError):
        raise RuntimeError('Lifecycle managed identity was not created; no VM was created.')
    role_name = str(budget_uuid.uuid5(budget_uuid.NAMESPACE_URL, workflow_id + group['tags']['LabId']))
    assigned = api('role', 'assignment', 'create', '--name', role_name, '--assignee-object-id', principal,
                   '--assignee-principal-type', 'ServicePrincipal', '--role', BUDGET_CONTRIBUTOR,
                   '--scope', group['id'])
    if (assigned.get('principalId', '').casefold() != principal.casefold()
            or assigned.get('scope', '').casefold() != group['id'].casefold()
            or not assigned.get('roleDefinitionId', '').casefold().endswith('/' + BUDGET_CONTRIBUTOR)):
        raise RuntimeError('Could not verify RG-scoped lifecycle permission; no VM was created.')
    role_id = group['id'] + '/providers/Microsoft.Authorization/roleAssignments/' + role_name
    fresh = api('rest', '--method', 'get', '--url', 'https://management.azure.com' + role_id + '?api-version=2022-04-01')
    fresh = (fresh or {}).get('properties') or {}
    if (fresh.get('principalId', '').casefold() != principal.casefold()
            or fresh.get('scope', '').casefold() != group['id'].casefold()
            or not fresh.get('roleDefinitionId', '').casefold().endswith('/' + BUDGET_CONTRIBUTOR)):
        raise RuntimeError('Lifecycle role assignment read-back did not match; no VM was created.')
    tags = budget_tags(now)
    tags['BudgetWorkflowId'] = workflow_id
    api('tag', 'update', '--resource-id', group['id'], '--operation', 'Merge', '--tags',
        *[k + '=' + v for k, v in tags.items()])
    current = api('group', 'show', '--name', group['name'])
    if any((current.get('tags') or {}).get(k) != v for k, v in tags.items()):
        raise RuntimeError('Lifecycle deadline tags did not persist; no VM was created.')
    print_budget(current)
    return current


def touch_budget(api, group, mode='use', now=None):
    old = group.get('tags') or {}
    if old.get('BudgetVersion') != BUDGET_VERSION:
        raise RuntimeError('This lab predates automatic expiry. Its timers were not changed; create a new managed lab.')
    now = now or budget_dt.datetime.now(budget_dt.timezone.utc)
    if budget_time(old['BudgetDeleteAt']) <= now:
        raise RuntimeError('The deletion deadline has passed. Cleanup may be running; create a separate new lab.')
    expected = group['id'] + '/providers/Microsoft.Logic/workflows/FortiAIGate_lab_lifecycle'
    if old.get('BudgetWorkflowId', '').casefold() != expected.casefold():
        raise RuntimeError('Lifecycle workflow ownership does not match this lab.')
    workflow = api('rest', '--method', 'get', '--url', 'https://management.azure.com' + expected + '?api-version=2019-05-01')
    if ((workflow.get('tags') or {}).get('LabId') != old.get('LabId')
            or workflow.get('properties', {}).get('state') != 'Enabled'):
        raise RuntimeError('Lifecycle protection is missing or disabled. Inspect the existing lab.')
    tags = budget_tags(now, old, mode)
    api('tag', 'update', '--resource-id', group['id'], '--operation', 'Merge', '--tags',
        *[k + '=' + v for k, v in tags.items()])
    current = api('group', 'show', '--name', group['name'])
    if any((current.get('tags') or {}).get(k) != v for k, v in tags.items()):
        raise RuntimeError('Deadline update was not verified. Do not assume the lab was extended.')
    print_budget(current)
    return current


def print_budget(group):
    tags = group['tags']
    print('Scheduled VM deallocation: ' + tags['BudgetStopAt'] + ' UTC')
    print('Permanent lab deletion after no launcher usage: ' + tags['BudgetDeleteAt'] + ' UTC')
    print('Create/Connect/Restart/Extend refresh the 12-hour clock. Browser/SSH keystrokes do not.')
    print('Cloud control-plane actions are checked every 5 minutes; source Blob files are retained.')


def create():
    global ACTIVE_GROUP
    entered_name = input("Name prefix (case-insensitive): ").strip()
    name = slug(entered_name)
    resource_prefix = entered_name.replace("-", "_") + "_FortiAIGate_RTX_GPU"
    rg = resource_prefix + "_Docker"
    vm = f"{name}-fortiaigate-gpu"
    admin = "lab" + name.replace("-", "")
    # Include the previous naming format to avoid creating a duplicate existing lab.
    group_names = (rg, f"{name}-fortiaigate-gpu-rg")
    for candidate in group_names:
        if az("group", "exists", "--name", candidate):
            raise Failure(f"{candidate} already exists. Use Connect, or Destroy it before creating again. It was not changed.")
    preparation_preflight()
    check_vm_size()
    for namespace in ("Microsoft.Compute", "Microsoft.Network", "Microsoft.ManagedIdentity", "Microsoft.Storage", "Microsoft.Authorization", "Microsoft.Logic"):
        provider = az("provider", "show", "--namespace", namespace)
        if provider.get("registrationState") != "Registered":
            raise Failure(f"Register {namespace} in the subscription before running Create.")
    release = release_preflight()
    check_assignment_permission(release["scope"])
    check_image()
    ssh_source = shell_ip()
    https_source = prompt_browser_ip()
    if https_source is None:
        print("Cancelled. No requested cloud changes were made.")
        return
    print(f"\nCreate {rg} in {LOCATION}:\n  Ubuntu 22.04 x64 Gen2 / {SIZE}\n"
          f"  {DISK_GIB} GiB Standard SSD LRS / Standard static IPv4\n"
          f"  Linux administrator: {admin}\n  SSH: {ssh_source}/32 (CloudShell)\n"
          f"  HTTPS: {https_source}/32 (your browser)\n"
          "  Approx. $2.50/hour including compute, 512 GiB SSD and IPv4; other usage and tax extra.\n"
          f"  Private release: {release['account']}/{release['container']}/{release['prefix']}\n"
          "  Creates a dedicated managed identity with Blob Data Reader on this container only.\n"
          "  AUTO-EXPIRY: deallocate after 2 hours; delete all lab-group resources after 12 hours without launcher usage. No backups.\n  RTX PREVIEW: prepares GRID and MIG CUDA access; vendor engine/licensing tests remain required. After the wizard, exit and run fortiaigate-bind-mig before deploying.")
    if not confirm("Create these billable resources?"):
        return
    lab_id = uuid.uuid4().hex
    tags = [f"ManagedBy={MANAGER}", f"FortiAIGateLab={LAB}", f"Username={name}", f"LabId={lab_id}", f"ReleaseContainerScope={release['scope']}"]
    group = {"id": f"/subscriptions/{SUBSCRIPTION}/resourceGroups/{rg}", "name": rg,
             "tags": dict(t.split("=", 1) for t in tags)}
    key = create_key(group)
    print(f"\nPrivate SSH key: {key}\nKeep this file private. Download a backup through CloudShell Manage files.")
    # Repeat the collision check immediately before creating the dedicated group.
    for candidate in group_names:
        if az("group", "exists", "--name", candidate):
            raise Failure(f"{candidate} now exists. Refusing to change it; generated SSH key was retained.")
    ACTIVE_GROUP = rg
    az("group", "create", "--name", rg, "--location", LOCATION, "--tags", *tags)
    group = az("group", "show", "--name", rg)
    identity = create_release_identity(group, resource_prefix + "_Identity", release, tags)
    group = install_budget(az, group, group["id"] + "/providers/Microsoft.Compute/virtualMachines/" + vm, LOCATION)
    nsg = resource_prefix + "_NSG"
    vnet = resource_prefix + "_VNet"
    pip = resource_prefix + "_IP"
    nic = resource_prefix + "_NIC"
    subnet = resource_prefix + "_Subnet"
    az("network", "vnet", "create", "--resource-group", rg, "--name", vnet,
       "--location", LOCATION, "--address-prefixes", "10.30.0.0/16", "--subnet-name", subnet,
       "--subnet-prefixes", "10.30.1.0/24", "--tags", *tags)
    az("network", "nsg", "create", "--resource-group", rg, "--name", nsg, "--location", LOCATION, "--tags", *tags)
    rule(rg, nsg, "FortiAIGate_SSH_CloudShell", 100, 22, ssh_source)
    rule(rg, nsg, "FortiAIGate_HTTPS_Client", 110, 443, https_source)
    az("network", "public-ip", "create", "--resource-group", rg, "--name", pip,
       "--location", LOCATION, "--sku", "Standard", "--allocation-method", "Static",
       "--version", "IPv4", "--tags", *tags)
    az("network", "nic", "create", "--resource-group", rg, "--name", nic,
       "--location", LOCATION, "--vnet-name", vnet, "--subnet", subnet,
       "--network-security-group", nsg, "--public-ip-address", pip, "--tags", *tags)
    print("\nCreating the VM; this can take several minutes...", flush=True)
    with tempfile.TemporaryDirectory(prefix="fortiaigate-cloud-init-") as directory:
        cloud_init = Path(directory) / "prepare.sh"
        cloud_init.write_text(preparation_user_data({
            "cloud": "azure", "edition": "gpu", "storage_account": release["account"],
            "container": release["container"], "release_prefix": release["prefix"],
            "identity_client_id": identity["clientId"]
        }))
        cloud_init.chmod(0o600)
        az("vm", "create", "--resource-group", rg, "--name", vm, "--location", LOCATION,
           "--image", IMAGE, "--size", SIZE, "--admin-username", admin,
           "--authentication-type", "ssh", "--ssh-key-values", str(key) + ".pub",
           "--custom-data", str(cloud_init),
           "--nics", nic, "--nic-delete-option", "Delete", "--storage-sku", "StandardSSD_LRS",
           "--os-disk-size-gb", str(DISK_GIB), "--os-disk-name", resource_prefix + "_OSDisk",
           "--os-disk-delete-option", "Delete", "--security-type", "Standard",
           "--assign-identity", identity["id"], "--tags", *tags)
    details = az("vm", "show", "--resource-group", rg, "--name", vm, "--show-details")
    if details.get("provisioningState") != "Succeeded":
        raise Failure("VM provisioning has not succeeded; inspect the VM in Azure.")
    _, attached_nsg = vm_network(group, details, exclusive=True)
    if attached_nsg.get("name", "").casefold() != nsg.casefold():
        raise Failure("The VM is attached to a different NSG than the one created for this lab.")
    verify_access(attached_nsg, ssh_source, https_source)
    public_ip = ipv4(details.get("publicIps", ""))
    wait_for_preparation(rg, vm)
    inventory = save_inventory(group, {"group": group, "vm": details, "keyPath": str(key)}, "created")
    print(f"\nCreated {rg}. Public IP: {public_ip}\nLinux administrator: {details['osProfile']['adminUsername']}\n"
          f"SSH key: {key}\nInventory: {inventory}\n"
          "Run launcher option 3 to connect. Inside Ubuntu run sudo fortiaigate-prep-status, then fortiaigate-install.\n"
          "If CloudShell storage is temporary, download the private key before closing the session.")


def connect():
    group = select_group()
    rg = group["name"]
    vms = az("vm", "list", "--resource-group", rg)
    if len(vms) != 1 or (vms[0].get("tags") or {}).get("LabId") != group["tags"]["LabId"]:
        raise Failure("Expected exactly one VM owned by this lab. Inspect the resource group.")
    vm = az("vm", "show", "--ids", vms[0]["id"], "--show-details")
    if vm.get("powerState") != "VM running":
        raise Failure("The VM is not running. Start it in the Azure portal, then reconnect.")
    address = ipv4(vm.get("publicIps", ""))
    admin = vm.get("osProfile", {}).get("adminUsername", "")
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", admin):
        raise Failure("Could not read a valid Linux administrator username from the VM.")
    key = key_path(group)
    if not key.is_file():
        raise Failure(f"Private key missing: {key}\nUpload your saved key and restore it to exactly this path. "
                      "Azure cannot recover a lost private key. A different new key will not authenticate.")
    key.chmod(0o600)
    _, nsg = vm_network(group, vm, exclusive=True)
    ssh_rule = access_rule_names(nsg, ports=(22,))[22]
    source = shell_ip()
    print(f"\nVM: {vm['name']}\nSSH destination: {admin}@{address}\nKey: {key}\n"
          f"Refreshing only this lab's SSH rule to CloudShell {source}/32.")
    rule(rg, nsg["name"], ssh_rule, 100, 22, source)
    print("On first connection, verify the SSH host-key fingerprint before accepting it.\n"
          "Azure VM > Run command > RunShellScript can display it with:\n"
          "  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub\n"
          "After connecting: sudo fortiaigate-prep-status, then fortiaigate-install. Type exit to return to CloudShell.", flush=True)
    touch_budget(az, group, "use")
    result = subprocess.run(["ssh", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=30",
                             "-i", str(key), f"{admin}@{address}"])
    if result.returncode:
        raise Failure(f"SSH ended with status {result.returncode}. Check the key, NSG and VM state.")


def repair_access():
    """Repair only the dedicated NIC NSG selected by the user, including portal VMs."""
    rg = input("Existing resource-group name (exact name from Azure): ").strip()
    if not rg or rg.startswith("-"):
        raise Failure("Enter the resource-group name shown in Azure.")
    group = az("group", "show", "--name", rg)
    if not lab_tags(group):
        raise Failure("Repair only accepts resource groups owned by these GPU scripts. CPU labs and unrelated VMs were not changed.")
    rg = group["name"]
    vms = az("vm", "list", "--resource-group", rg)
    if not vms:
        raise Failure("No VMs were found in that resource group.")
    print("\nVMs in this resource group:")
    for vm in vms:
        print("  " + vm["name"])
    default = vms[0]["name"] if len(vms) == 1 else ""
    name = input(f"VM name{' [' + default + ']' if default else ''}: ").strip() or default
    matches = [v for v in vms if v["name"].casefold() == name.casefold()]
    if len(matches) != 1 or not own_id(group, matches[0]["id"]):
        raise Failure("Select one VM from the displayed list.")
    vm = az("vm", "show", "--ids", matches[0]["id"], "--show-details")
    if (vm.get("tags") or {}).get("LabId") != group["tags"]["LabId"]:
        raise Failure("Selected VM is not tagged for this GPU lab; access rules were not changed.")
    nic, nsg = vm_network(group, vm, require_managed=True, exclusive=True)
    names = access_rule_names(nsg)
    ssh_source = shell_ip()
    https_source = prompt_browser_ip()
    if https_source is None:
        print("Cancelled. No access rules were changed.")
        return
    print(f"\nVM: {vm['name']}\nResource group: {rg}\nAttached NSG: {nsg['name']}")
    for port, source in ((22, ssh_source), (443, https_source)):
        old = next((r for r in nsg.get("securityRules", []) if r["name"].casefold() == names[port].casefold()), None)
        before = ", ".join(sorted(rule_values(old, "sourceAddressPrefix", "sourceAddressPrefixes"))) if old else "missing"
        print(f"  {names[port]}: TCP {port}, source {before} -> {source}/32")
    print("Only the two named inbound rules will change. Existing SSH keys, disks and application data are retained.")
    if not confirm("Apply these SSH/HTTPS access rules?"):
        return
    # Recheck attachment and rules after the prompt to avoid changing a newly shared NSG.
    fresh_vm = az("vm", "show", "--ids", vm["id"], "--show-details")
    fresh_nic, fresh_nsg = vm_network(group, fresh_vm, require_managed=True, exclusive=True)
    if (fresh_nic["id"].casefold() != nic["id"].casefold()
            or fresh_nsg["id"].casefold() != nsg["id"].casefold()
            or fresh_nsg.get("securityRules", []) != nsg.get("securityRules", [])):
        raise Failure("VM networking or NSG rules changed after the preview. Rerun to review them.")
    for port, priority, source in ((22, 100, ssh_source), (443, 110, https_source)):
        rule(rg, nsg["name"], names[port], priority, port, source)
    verified_vm = az("vm", "show", "--ids", vm["id"], "--show-details")
    _, verified_nsg = vm_network(group, verified_vm, require_managed=True, exclusive=True)
    if verified_nsg["id"].casefold() != nsg["id"].casefold():
        raise Failure("The VM's NSG attachment changed during repair. Inspect its current access rules.")
    verify_access(verified_nsg, ssh_source, https_source)
    print("Access rules verified. HTTPS also requires FortiAIGate to be running and listening on port 443.")


def check_vm_dependencies(group, resources):
    # Avoid Azure VM delete options removing a disk or NIC in another resource group.
    for resource in resources:
        if resource.get("type", "").casefold() != "microsoft.compute/virtualmachines":
            continue
        vm = az("vm", "show", "--ids", resource["id"])
        disks = [vm.get("storageProfile", {}).get("osDisk", {})] + vm.get("storageProfile", {}).get("dataDisks", [])
        ids = [d.get("managedDisk", {}).get("id", "") for d in disks]
        ids += [n.get("id", "") for n in vm.get("networkProfile", {}).get("networkInterfaces", [])]
        if any(rid and not own_id(group, rid) for rid in ids):
            raise Failure("A VM references a disk or NIC outside this group. Review those dependencies before deletion.")


def destroy():
    group = select_group()
    rg = group["name"]
    resources = az("resource", "list", "--resource-group", rg)
    locks = az("lock", "list", "--resource-group", rg)
    if locks:
        raise Failure("Deletion locks exist in this resource group. Review them in Azure before retrying.")
    check_vm_dependencies(group, resources)
    reader = owned_reader_assignment(group, resources)
    print(f"  Container-scoped Reader assignment: {reader['id']}" if reader else "  No retained container Reader assignment.")
    print(f"\nPermanently delete ALL resources in {rg}:")
    for item in resources:
        print(f"  {item['type']}  {item['name']}")
    print("Includes VM, disks, NIC, public IP, NSG, VNet, managed identity and this lab's Reader assignment.\n"
          "The private storage account, container and release files are retained. No snapshots or backups are created.")
    if not confirm(f"Delete resource group {rg} in subscription {SUBSCRIPTION}?"):
        return
    current = az("group", "show", "--name", rg)
    if not lab_tags(current) or current["tags"]["LabId"] != group["tags"]["LabId"]:
        raise Failure("Lab ownership changed after the preview; deletion stopped.")
    latest = az("resource", "list", "--resource-group", rg)
    if {r["id"].casefold() for r in latest} != {r["id"].casefold() for r in resources}:
        raise Failure("Resource membership changed after the preview. Rerun to review the current inventory.")
    # Attachments can change during the prompt without changing group membership.
    check_vm_dependencies(current, latest)
    inventory = save_inventory(current, {"group": current, "resources": latest}, "before-delete")
    fresh_reader = owned_reader_assignment(current, latest)
    if (fresh_reader or {}).get("id") != (reader or {}).get("id"):
        raise Failure("The container Reader assignment changed after the preview. Rerun Destroy.")
    if fresh_reader:
        az("role", "assignment", "delete", "--ids", fresh_reader["id"])
    print(f"Inventory saved: {inventory}\nDeleting in Azure; this can take several minutes...", flush=True)
    az("group", "delete", "--name", rg, "--yes")
    if az("group", "exists", "--name", rg):
        raise Failure("Azure still reports the group exists. Keep the inventory and inspect its deletion status.")
    print(f"\nDeleted {rg} and its Azure resources.\nLocal SSH key retained: {key_path(group)}\nInventory retained: {inventory}")



def budget_action(mode):
    group = select_group()
    machines = az("vm", "list", "--resource-group", group["name"])
    if len(machines) != 1 or (machines[0].get("tags") or {}).get("LabId") != group["tags"]["LabId"]:
        raise Failure("Expected exactly one VM owned by this lab.")
    vm = az("vm", "show", "--ids", machines[0]["id"], "--show-details")
    if mode == "extend" and vm.get("powerState") != "VM running":
        raise Failure("Use Restart to resume a stopped VM and give it a new 2-hour window.")
    if mode == "restart" and vm.get("powerState") not in ("VM running", "VM stopped", "VM deallocated"):
        raise Failure("VM is changing state. Wait and inspect it before restarting.")
    touch_budget(az, group, mode)
    if mode == "restart" and vm.get("powerState") != "VM running":
        az("vm", "start", "--ids", vm["id"])
    print("Use Connect to open SSH. Browser/SSH activity does not reset expiry.")


def main():
    try:
        setup()
        actions = {"create": create, "connect": connect, "destroy": destroy, "repair-access": repair_access, "restart": lambda: budget_action("restart"), "extend": lambda: budget_action("extend")}
        if len(sys.argv) != 2 or sys.argv[1] not in actions:
            raise Failure("Expected create, connect, destroy or repair-access.")
        actions[sys.argv[1]]()
    except (EOFError, KeyboardInterrupt):
        print("\nStopped. Completed cloud changes remain in effect.", file=sys.stderr)
        return 1
    except (Failure, RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"\nSTOPPED: {error}", file=sys.stderr)
        if ACTIVE_GROUP:
            print(f"Resources may remain in {ACTIVE_GROUP}. Inspect it or rerun Destroy; no automatic rollback was performed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

FORTI_AZURE_GPU_PY

[[ $# -eq 0 ]] || { printf 'Usage: bash destroy_fortiaigate_gpu_azure.sh\n' >&2; exit 2; }
python3 "$forti_runtime" destroy
