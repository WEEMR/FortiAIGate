#!/usr/bin/env python3
"""Copy only an authenticated gateway public certificate to its linked Ollama host.

Run after fortiaigate-install and licensing, from the Terraform project directory.
No private key or gateway virtual key is read. Configure stays interactive.
"""
import argparse
import base64
import hashlib
import inspect
import ipaddress
import json
from pathlib import Path
import re
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time

from Watch_Installation import ProbeError, aws_probe, azure_probe, normalize_target


CERTIFICATE_PATH = '/opt/ollama-lab/imported-gateway-ca.crt'


def validate_public_certificate(pem, gateway_ip):
    """Validate one PEM, current validity and the exact private-IP TLS identity."""
    if not isinstance(pem, str) or not 64 <= len(pem) <= 16384 or 'PRIVATE KEY' in pem:
        raise ValueError('Expected one public PEM certificate, without a private key.')
    pem = pem.replace('\r\n', '\n').strip() + '\n'
    if not re.fullmatch(r'-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+-----END CERTIFICATE-----\n', pem):
        raise ValueError('Expected one public PEM certificate, without a bundle.')
    ssl.create_default_context().load_verify_locations(cadata=pem)
    with tempfile.TemporaryDirectory(prefix='fortiaigate-public-certificate-') as folder:
        certificate = Path(folder) / 'gateway.crt'
        certificate.write_text(pem)
        certificate.chmod(0o600)
        result = subprocess.run(['openssl', 'verify', '-partial_chain', '-purpose', 'sslserver',
            '-CAfile', str(certificate), '-verify_ip', gateway_ip, str(certificate)],
            capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise ValueError('Gateway certificate is expired, invalid, or missing the gateway private-IP SAN.')
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def remote_python(code):
    return "set +x\npython3 - <<'FORTIAIGATE_PUBLIC_CERTIFICATE'\n" + code + '\nFORTIAIGATE_PUBLIC_CERTIFICATE'


def certificate_reader(gateway_ip):
    code = 'import hashlib,json,re,ssl,subprocess,tempfile\nfrom pathlib import Path\n'
    code += inspect.getsource(validate_public_certificate)
    code += '\npem = subprocess.run(["docker","exec","faig-nginx","cat","/etc/nginx/certs/tls.crt"], capture_output=True, timeout=10, check=True).stdout.decode("ascii")\n'
    code += 'fingerprint = validate_public_certificate(pem, ' + repr(gateway_ip) + ')\n'
    code += 'print(json.dumps({"status":"public_certificate", "pem":pem, "sha256":fingerprint}))\n'
    return remote_python(code)


def certificate_installer(pem, fingerprint, gateway_ip, port):
    payload = base64.b64encode(pem.encode('ascii')).decode('ascii')
    code = 'import base64,hashlib,json,os,re,socket,ssl,subprocess,tempfile\nfrom pathlib import Path\n'
    code += inspect.getsource(validate_public_certificate)
    code += inspect.getsource(install_public_certificate)
    code += '\npem = base64.b64decode(' + repr(payload) + ').decode("ascii")\n'
    code += 'expected = ' + repr(fingerprint) + '\ngateway_ip = ' + repr(gateway_ip) + '\nport = ' + repr(port) + '\n'
    code += 'destination = Path(' + repr(CERTIFICATE_PATH) + ')\n'
    code += 'install_public_certificate(pem, expected, gateway_ip, port, destination)\n'
    code += 'print(json.dumps({"status":"installed", "path":str(destination), "sha256":expected}))\n'
    return remote_python(code)


def install_public_certificate(pem, expected, gateway_ip, port, destination, require_root=True):
    """Verify live TLS before replacing a matching public trust file.

    require_root=False is used only by local TLS tests in a temporary directory;
    generated cloud commands always use the default protected root context.
    """
    if require_root and os.geteuid() != 0:
        raise ValueError('Certificate import needs the authenticated root run-command context.')
    if validate_public_certificate(pem, gateway_ip) != expected:
        raise ValueError('Authenticated certificate fingerprint did not match.')
    destination = Path(destination)
    root = destination.parent
    owner = 0 if require_root else os.geteuid()
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != owner or root.stat().st_mode & 0o022:
        raise ValueError('Prepare Ollama first; its configuration directory must be root-owned and protected.')
    if destination.is_symlink():
        raise ValueError('Refusing a symlink at the public certificate destination.')
    if destination.exists():
        if not destination.is_file() or destination.stat().st_uid != owner or destination.stat().st_mode & 0o022:
            raise ValueError('Existing certificate is not a protected root-owned file; it was preserved.')
        if validate_public_certificate(destination.read_text(), gateway_ip) != expected:
            raise ValueError('A different certificate already exists and was preserved; review it before replacing it.')
    with tempfile.TemporaryDirectory(prefix='.public-certificate-', dir=root) as folder:
        candidate = Path(folder) / 'gateway.crt'
        candidate.write_text(pem)
        candidate.chmod(0o600)
        context = ssl.create_default_context(cafile=str(candidate))
        with socket.create_connection((gateway_ip, port), timeout=10) as connection:
            with context.wrap_socket(connection, server_hostname=gateway_ip) as secured:
                if hashlib.sha256(secured.getpeercert(binary_form=True)).hexdigest() != expected:
                    raise ValueError('Live gateway TLS certificate differs from the authenticated export.')
        os.replace(candidate, destination)


def response_json(output):
    lines = [line.strip() for line in output.splitlines() if line.strip().startswith('{')]
    if len(lines) != 1:
        raise ValueError('Authenticated run-command did not return exactly one certificate result.')
    result = json.loads(lines[0])
    if not isinstance(result, dict):
        raise ValueError('Authenticated run-command returned invalid certificate metadata.')
    return result


def select_deployment(outputs, cloud, edition):
    if cloud == 'azure' and edition != 'cpu':
        raise ValueError('Azure GPU is not implemented; select --edition cpu.')
    prefix = 'AWS' if cloud == 'aws' else 'Azure'
    gateway = outputs[prefix + '_FortiAIGate_' + edition.upper()]['value']
    ollama = outputs[prefix + '_Ollama']['value']
    if cloud == 'aws':
        ollama = ollama[edition.upper()]
    targets = outputs['Installation_Targets']['value']
    gateway_target = normalize_target(targets[prefix + '_' + edition.upper()])
    ollama_target = normalize_target(targets[prefix + '_Ollama' + ('_' + edition.upper() if cloud == 'aws' else '')])
    address = ipaddress.IPv4Address(gateway['Private_IP'])
    if not any(address in ipaddress.ip_network(block) for block in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')):
        raise ValueError('Gateway certificate import requires the linked private IPv4 address.')
    from urllib.parse import urlsplit
    parsed = urlsplit(ollama['Gateway_URL'])
    if (parsed.scheme != 'https' or parsed.hostname != str(address) or parsed.username
            or parsed.password or parsed.query or parsed.fragment or parsed.path != '/ai/openai/v1'):
        raise ValueError('Gateway output URL and linked gateway private IPv4 disagree.')
    if gateway_target['cloud'] != cloud or gateway_target['edition'] != edition or ollama_target['cloud'] != cloud or ollama_target['edition'] != 'ollama':
        raise ValueError('Gateway and Ollama progress targets do not match the selected deployment.')
    return gateway_target, ollama_target, str(address), parsed.port or 443


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cloud', choices=('aws', 'azure'), required=True)
    parser.add_argument('--edition', choices=('cpu', 'gpu'), default='cpu')
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    try:
        result = subprocess.run(['terraform', '-chdir=' + str(project), 'output', '-json'],
            capture_output=True, text=True, timeout=30, check=True)
        gateway, ollama, address, port = select_deployment(json.loads(result.stdout), args.cloud, args.edition)
        invoke = aws_probe if args.cloud == 'aws' else azure_probe
        started = time.monotonic()
        print('Reading only the gateway public certificate through authenticated ' + ('AWS Session Manager.' if args.cloud == 'aws' else 'Azure Run Command.'), flush=True)
        exported = response_json(invoke(gateway, certificate_reader(address), started, 'reading public certificate'))
        fingerprint = validate_public_certificate(exported.get('pem'), address)
        if exported.get('status') != 'public_certificate' or exported.get('sha256') != fingerprint:
            raise ValueError('Authenticated certificate export did not pass fingerprint validation.')
        print('Checking gateway private-IP SAN, validity and live TLS from linked Ollama before saving trust.', flush=True)
        installed = response_json(invoke(ollama, certificate_installer(exported['pem'], fingerprint, address, port), started, 'verifying gateway TLS'))
        if installed != {'status': 'installed', 'path': CERTIFICATE_PATH, 'sha256': fingerprint}:
            raise ValueError('Ollama did not confirm the authenticated public certificate import.')
        print('PASS: authenticated gateway public certificate imported; private-IP TLS identity verified.')
        print('Certificate SHA-256: ' + fingerprint)
        print('On Ollama run sudo ollama-lab configure --manual; enter ' + CERTIFICATE_PATH + ' at the CA certificate prompt.')
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, ProbeError):
        print('STOP: gateway public certificate transfer was not confirmed. Complete gateway installation, check the selected Terraform outputs, cloud authentication, private-IP certificate SAN and connectivity, then retry. Existing trust was preserved.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
