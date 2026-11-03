#!/usr/bin/env python3
"""Terraform application deployment for prepared AWS CPU/GPU and Azure CPU VMs."""
import argparse
import base64
import contextlib
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import time

from Watch_Installation import ProbeError, aws_probe, azure_probe, clean, elapsed, normalize_target, watch


HERE = Path(__file__).resolve().parent
STATUS_SCRIPT = r'''python3 - <<'FORTIAIGATE_APPLICATION_STATUS'
import json,pathlib,subprocess
path=pathlib.Path('/var/lib/fortiaigate-terraform-install/status.json')
item=json.loads(path.read_text()) if path.is_file() else {'status':'pending','stage':'waiting for the Terraform application worker','percent':0}
state=subprocess.run(['systemctl','show','fortiaigate-terraform-install.service','--property=ActiveState','--value'],capture_output=True,text=True).stdout.strip()
if item.get('status') not in ('ready','failed') and state in ('failed','inactive'):
    item={'status':'failed','stage':'The application worker stopped before readiness. Inspect its private VM log.','percent':0}
print(json.dumps(item))
FORTIAIGATE_APPLICATION_STATUS
'''


def configuration(target):
    target = normalize_target(target)
    if target['edition'] not in ('cpu', 'gpu') or target['cloud'] == 'azure' and target['edition'] != 'cpu':
        raise ValueError('Automatic FortiAIGate installation supports AWS CPU/GPU and Azure CPU.')
    config = {'edition': target['edition'], 'operator': 'ubuntu' if target['cloud'] == 'aws' else 'fortiadmin',
              'gateway_api_port': target.get('gateway_api_port', 443)}
    port = config['gateway_api_port']
    if type(port) is not int or not 1 <= port <= 65535 or port in (22, 3000, 11434):
        raise ValueError('Use a valid gateway API port.')
    return target, config


def launch_script(config, worker=None):
    worker = (HERE / 'Install_FortiAIGate_Guest.py').read_bytes() if worker is None else worker
    encoded = base64.b64encode(gzip.compress(worker, mtime=0)).decode()
    digest = hashlib.sha256(worker).hexdigest()
    settings = base64.b64encode(json.dumps(config, sort_keys=True).encode()).decode()
    # The task payload is shipped with the reviewed Terraform bundle. No mutable
    # download route, cloud credential, application password or licence is used.
    return "python3 - <<'FORTIAIGATE_APPLICATION_START'\n" + f'''
import base64,fcntl,gzip,hashlib,json,os,pathlib,subprocess
state=pathlib.Path('/var/lib/fortiaigate-terraform-install')
if os.geteuid()!=0: raise SystemExit('Cloud management must launch the application worker as root.')
os.umask(0o077)
state.mkdir(mode=0o755,exist_ok=True)
if state.is_symlink(): raise SystemExit('Refusing symbolic-link installation state.')
with (state/'bootstrap.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    config=json.loads(base64.b64decode('{settings}'))
    existing=state/'config.json'
    if existing.is_symlink() or (existing.exists() and json.loads(existing.read_text())!=config):
        raise SystemExit('Existing Terraform application configuration differs; it was left unchanged.')
    active=subprocess.run(['systemctl','show','fortiaigate-terraform-install.service','--property=ActiveState','--value'],capture_output=True,text=True).stdout.strip() in ('active','activating','reloading')
    if active:
        running=pathlib.Path('/usr/local/libexec/fortiaigate-terraform-install.py')
        if not running.is_file() or hashlib.sha256(running.read_bytes()).hexdigest()!='{digest}':
            raise SystemExit('A different application worker revision is already running; wait for it before retrying.')
        print('Application installation is already running; reconnecting to its status.')
    else:
        payload=gzip.decompress(base64.b64decode('{encoded}'))
        if hashlib.sha256(payload).hexdigest()!='{digest}': raise SystemExit('Application worker checksum mismatch.')
        executable=pathlib.Path('/usr/local/libexec/fortiaigate-terraform-install.py')
        executable.parent.mkdir(mode=0o755,parents=True,exist_ok=True)
        if executable.is_symlink(): raise SystemExit('Refusing symbolic-link worker.')
        executable.write_bytes(payload); executable.chmod(0o700)
        existing.write_text(json.dumps(config)); existing.chmod(0o600)
        pending=state/'status.json'
        if pending.is_symlink(): raise SystemExit('Refusing symbolic-link status.')
        pending.write_text(json.dumps({{'status':'pending','stage':'starting the application installation worker','percent':0}})); pending.chmod(0o644)
        unit=pathlib.Path('/etc/systemd/system/fortiaigate-terraform-install.service')
        unit.write_text('[Unit]\\nDescription=Terraform FortiAIGate application installation\\nAfter=network-online.target docker.service\\nWants=network-online.target\\n[Service]\\nType=oneshot\\nUMask=0077\\nTimeoutStartSec=10800\\nExecStart=/usr/bin/python3 '+str(executable)+'\\nStandardOutput=journal\\nStandardError=journal\\n')
        subprocess.run(['systemctl','daemon-reload'],check=True)
        subprocess.run(['systemctl','reset-failed','fortiaigate-terraform-install.service'],check=False)
        subprocess.run(['systemctl','start','--no-block','fortiaigate-terraform-install.service'],check=True)
        print('Started the Terraform application installation worker on this existing VM.')
''' + 'FORTIAIGATE_APPLICATION_START\n'


def deploy(target, timeout=10800, interval=10, show_progress=True):
    target, config = configuration(target)
    if show_progress:
        watch(target, application_next=True)
    else:
        with contextlib.redirect_stdout(io.StringIO()):
            watch(target, application_next=True)
    start = time.monotonic()
    transport = aws_probe if target['cloud'] == 'aws' else azure_probe
    print('\nStarting the Terraform-managed FortiAIGate application installation.', flush=True)
    # Submission is not automatically retried: an ambiguous CLI failure may
    # have started the service. A later apply reconnects to the same guarded job.
    transport(target, launch_script(config), start, 'starting the application worker')
    failures = 0
    while time.monotonic() - start < timeout:
        try:
            output = transport(target, STATUS_SCRIPT, start, 'waiting for application installation')
            lines = [line.strip() for line in output.splitlines() if line.strip().startswith('{')]
            if len(lines) != 1:
                raise ProbeError('The application worker did not return one status object.')
            status = json.loads(lines[0])
            if (not isinstance(status, dict) or status.get('status') not in ('pending', 'running', 'ready', 'failed')
                    or not isinstance(status.get('stage'), str) or type(status.get('percent')) is not int
                    or not 0 <= status['percent'] <= 100):
                raise ProbeError('Invalid application installation status.')
            failures = 0
        except (ProbeError, ValueError) as error:
            if any(code in str(error) for code in ('AccessDenied','Unauthorized','ExpiredToken','InvalidClientTokenId','AuthorizationFailed')):
                raise
            failures += 1
            if failures >= 5:
                raise ProbeError('Application status could not be verified. The existing worker is retained; inspect the VM and retry.') from error
            print('  Application status temporarily unavailable; the same worker remains in place.', flush=True)
            time.sleep(interval)
            continue
        if show_progress:
            print(f"Application [{status['status'].upper()}] {status['percent']:3d}% | {clean(status['stage'])} | Elapsed: {elapsed(start)}", flush=True)
        if status['status'] == 'failed':
            raise ProbeError(clean(status['stage']) + ' Log on VM: /var/log/fortiaigate-terraform-install.log (private).')
        if status['status'] == 'ready':
            print('PASS: FortiAIGate is deployed and its WebUI is ready. Complete WebUI setup and licensing.', flush=True)
            print('The required one-time API restart after WebUI setup is handled automatically.', flush=True)
            return
        time.sleep(interval)
    raise ProbeError('Application installation status wait timed out. The existing VM/worker were retained; no replacement was requested.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target-json-env', required=True)
    parser.add_argument('--show-progress', choices=('yes','no'), default='yes')
    parser.add_argument('--timeout', type=int, default=10800)
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error('Timeout must be positive.')
    try:
        deploy(json.loads(os.environ[args.target_json_env]), timeout=args.timeout, show_progress=args.show_progress == 'yes')
    except (ProbeError, ValueError, KeyError, OSError) as error:
        print('STOP: ' + clean(error, 1000), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
