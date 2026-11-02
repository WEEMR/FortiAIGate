#!/usr/bin/env bash
# Generated from scripts/Azure/CPU/runtime/fortiaigate_azure.py. Prompts retain terminal input.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { printf 'Python 3 is required. Use Azure CloudShell Bash.\n' >&2; exit 1; }
forti_runtime=$(mktemp "${TMPDIR:-/tmp}/fortiaigate-azure.XXXXXX")
trap 'rm -f -- "$forti_runtime"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$forti_runtime" <<'FORTI_AZURE_PY'
#!/usr/bin/env python3
"""Azure CloudShell lab lifecycle. Uses the signed-in Azure CLI account."""
import datetime
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
SIZE = "Standard_B2as_v2"
IMAGE = "Canonical:ubuntu-22_04-lts:server:latest"
DISK_GIB = 128
MANAGER = "FortiAIGateCloudShell"
LAB = "cpu-8.0.2"
SUBSCRIPTION = ""
ACTIVE_GROUP = ""
SCRIPT_VERSION = "2026-11-02.1"
SKU_CHECK_TIMEOUT = 180
PROGRESS_SECONDS = 15


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
    return Path.home() / ".ssh" / "fortiaigate-azure" / SUBSCRIPTION / group["tags"]["LabId"]


def create_key(group):
    if not shutil.which("ssh-keygen"):
        raise Failure("ssh-keygen is required; use Azure CloudShell Bash.")
    key = key_path(group)
    key.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    key.parent.chmod(0o700)
    if key.exists() or Path(str(key) + ".pub").exists():
        raise Failure(f"Refusing to overwrite an existing SSH key: {key}")
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                    "FortiAIGate Azure lab", "-f", str(key)], check=True)
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
    directory = Path.home() / ".fortiaigate" / "azure" / SUBSCRIPTION / group["tags"]["LabId"]
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
            print(f"  {SIZE} found; no location restriction reported. Capacity is checked during deployment.", flush=True)
            return
        url = page.get("nextLink")
    raise Failure(f"{SIZE} was not found for this subscription in {LOCATION}. No resources were created.")


def create():
    global ACTIVE_GROUP
    entered_name = input("Name prefix (case-insensitive): ").strip()
    name = slug(entered_name)
    resource_prefix = entered_name.replace("-", "_") + "_FortiAIGate"
    rg = resource_prefix + "_Docker"
    vm = f"{name}-fortiaigate"
    admin = "lab" + name.replace("-", "")
    # Include the previous naming format to avoid creating a duplicate existing lab.
    group_names = (rg, f"{name}-fortiaigate-rg")
    for candidate in group_names:
        if az("group", "exists", "--name", candidate):
            raise Failure(f"{candidate} already exists. Use Connect, or Destroy it before creating again. It was not changed.")
    check_vm_size()
    for namespace in ("Microsoft.Compute", "Microsoft.Network"):
        provider = az("provider", "show", "--namespace", namespace)
        if provider.get("registrationState") != "Registered":
            raise Failure(f"Register {namespace} in the subscription before running Create.")
    ssh_source = shell_ip()
    https_source = prompt_browser_ip()
    if https_source is None:
        print("Cancelled. No requested cloud changes were made.")
        return
    print(f"\nCreate {rg} in {LOCATION}:\n  Ubuntu 22.04 x64 Gen2 / {SIZE}\n"
          f"  {DISK_GIB} GiB Standard SSD LRS / Standard static IPv4\n"
          f"  Linux administrator: {admin}\n  SSH: {ssh_source}/32 (CloudShell)\n"
          f"  HTTPS: {https_source}/32 (your browser)\n"
          "  Approx. $68.15 / 730-hour month, plus disk operations and other usage.\n"
          "  Creates infrastructure only; follow the guide to install Docker and FortiAIGate.")
    if not confirm("Create these billable resources?"):
        return
    lab_id = uuid.uuid4().hex
    tags = [f"ManagedBy={MANAGER}", f"FortiAIGateLab={LAB}", f"Username={name}", f"LabId={lab_id}"]
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
    az("vm", "create", "--resource-group", rg, "--name", vm, "--location", LOCATION,
       "--image", IMAGE, "--size", SIZE, "--admin-username", admin,
       "--authentication-type", "ssh", "--ssh-key-values", str(key) + ".pub",
       "--nics", nic, "--nic-delete-option", "Delete", "--storage-sku", "StandardSSD_LRS",
       "--os-disk-size-gb", str(DISK_GIB), "--os-disk-name", resource_prefix + "_OSDisk",
       "--os-disk-delete-option", "Delete", "--security-type", "TrustedLaunch",
       "--enable-secure-boot", "true", "--enable-vtpm", "true", "--tags", *tags)
    details = az("vm", "show", "--resource-group", rg, "--name", vm, "--show-details")
    if details.get("provisioningState") != "Succeeded":
        raise Failure("VM provisioning has not succeeded; inspect the VM in Azure.")
    _, attached_nsg = vm_network(group, details, exclusive=True)
    if attached_nsg.get("name", "").casefold() != nsg.casefold():
        raise Failure("The VM is attached to a different NSG than the one created for this lab.")
    verify_access(attached_nsg, ssh_source, https_source)
    public_ip = ipv4(details.get("publicIps", ""))
    inventory = save_inventory(group, {"group": group, "vm": details, "keyPath": str(key)}, "created")
    print(f"\nCreated {rg}. Public IP: {public_ip}\nLinux administrator: {details['osProfile']['adminUsername']}\n"
          f"SSH key: {key}\nInventory: {inventory}\n"
          "Run launcher option 3 to connect. Then continue with step 3 in the guide.\n"
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
          "After connecting, run the installation steps INSIDE Ubuntu. Type exit to return to CloudShell.", flush=True)
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
    nic, nsg = vm_network(group, vm, require_managed=False, exclusive=True)
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
    fresh_nic, fresh_nsg = vm_network(group, fresh_vm, require_managed=False, exclusive=True)
    if (fresh_nic["id"].casefold() != nic["id"].casefold()
            or fresh_nsg["id"].casefold() != nsg["id"].casefold()
            or fresh_nsg.get("securityRules", []) != nsg.get("securityRules", [])):
        raise Failure("VM networking or NSG rules changed after the preview. Rerun to review them.")
    for port, priority, source in ((22, 100, ssh_source), (443, 110, https_source)):
        rule(rg, nsg["name"], names[port], priority, port, source)
    verified_vm = az("vm", "show", "--ids", vm["id"], "--show-details")
    _, verified_nsg = vm_network(group, verified_vm, require_managed=False, exclusive=True)
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
    print(f"\nPermanently delete ALL resources in {rg}:")
    for item in resources:
        print(f"  {item['type']}  {item['name']}")
    print("Includes VM, disks, NIC, public IP, NSG, VNet and any resources added to this group.\n"
          "No snapshots or backups are created. Resources outside this group are not selected.")
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
    print(f"Inventory saved: {inventory}\nDeleting in Azure; this can take several minutes...", flush=True)
    az("group", "delete", "--name", rg, "--yes")
    if az("group", "exists", "--name", rg):
        raise Failure("Azure still reports the group exists. Keep the inventory and inspect its deletion status.")
    print(f"\nDeleted {rg} and its Azure resources.\nLocal SSH key retained: {key_path(group)}\nInventory retained: {inventory}")


def main():
    try:
        setup()
        actions = {"create": create, "connect": connect, "destroy": destroy, "repair-access": repair_access}
        if len(sys.argv) != 2 or sys.argv[1] not in actions:
            raise Failure("Expected create, connect, destroy or repair-access.")
        actions[sys.argv[1]]()
    except (EOFError, KeyboardInterrupt):
        print("\nStopped. Completed cloud changes remain in effect.", file=sys.stderr)
        return 1
    except (Failure, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"\nSTOPPED: {error}", file=sys.stderr)
        if ACTIVE_GROUP:
            print(f"Resources may remain in {ACTIVE_GROUP}. Inspect it or rerun Destroy; no automatic rollback was performed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
FORTI_AZURE_PY
python3 "$forti_runtime" destroy
