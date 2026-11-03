#!/usr/bin/env python3
"""Show CloudShell preparation stages through authenticated, read-only probes."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time


PROBE = r'''#!/bin/sh
python3 - <<'FORTI_STATUS'
import json, math, os, subprocess
from pathlib import Path
kind = __EDITION__
root = Path(__ROOT__)
state = root / 'var/lib/fortiaigate-prep'
def read(path, limit=240):
    try: return path.read_text(errors='replace')[:limit].strip()
    except FileNotFoundError: return ''
snapshot = {'status': 'pending', 'stage': 'waiting for first-boot preparation to start', 'percent': 1}
log = root / 'var/log/fortiaigate-prep.log'
if kind == 'ollama':
    state = root / 'var/lib/ollama-lab'
    log = root / 'var/log/ollama-lab-bootstrap.log'
    try:
        item = json.loads(read(state / 'status.json', 12000))
        if isinstance(item, dict):
            snapshot.update(status=item.get('state', 'pending'), stage=item.get('message', item.get('stage', 'preparing Ollama')), percent=item.get('percent', 1))
    except (ValueError, OSError): pass
    if snapshot['status'] == 'configured': snapshot['status'] = 'ready'
elif kind == 'gpu':
    helper = root / 'usr/local/bin/fortiaigate-gpu-progress'
    if helper.is_file() and os.access(helper, os.X_OK):
        try:
            result = subprocess.run([str(helper)], capture_output=True, text=True, timeout=10)
            item = json.loads(result.stdout)
            if result.returncode == 0 and isinstance(item, dict): snapshot.update(item)
        except (OSError, ValueError, subprocess.TimeoutExpired): pass
    failed = (state / 'GPU_FAILED').is_file() or (state / 'FAILED').is_file()
    if failed: snapshot.update(status='failed', stage=read(state / 'GPU_FAILED') or read(state / 'FAILED') or 'GPU preparation failed', percent=0)
    elif (state / 'GPU_READY').is_file(): snapshot.update(status='ready', stage='GPU host preparation completed', percent=100)
    else:
        snapshot.update(status='running', stage=read(state / 'GPU_RUNNING') or read(state / 'RUNNING') or snapshot['stage'])
        value = snapshot.get('percent', 1)
        snapshot['percent'] = min(99, max(1, value)) if type(value) in (int, float) and math.isfinite(value) else 1
    log = root / 'var/log/fortiaigate-gpu-prep.log'
else:
    stage = read(state / 'RUNNING')
    milestones = {'validate host and configuration': 5, 'repair signed Docker repository': 10,
        'install and verify Docker and Compose': 25, 'install and verify AWS CLI v2': 35,
        'download and check the CPU release archives': 50, 'install the interactive handoff': 95}
    if (state / 'FAILED').is_file(): snapshot.update(status='failed', stage=read(state / 'FAILED') or 'host preparation failed', percent=0)
    elif (state / 'READY').is_file(): snapshot.update(status='ready', stage='host tools, release files and installer checks completed', percent=100)
    elif stage: snapshot.update(status='running', stage=stage, percent=milestones.get(stage, 1))
if kind != 'ollama':
    # Failure takes precedence even if a stale completion marker also exists.
    failed = (state / 'GPU_FAILED').is_file() or (state / 'FAILED').is_file()
    if failed: snapshot.update(status='failed', stage=read(state / 'GPU_FAILED') or read(state / 'FAILED') or 'host preparation failed', percent=0)
if snapshot.get('status') not in ('pending', 'running', 'ready', 'failed'): snapshot['status'] = 'running'
value = snapshot.get('percent', 1)
snapshot['percent'] = max(0, min(100, int(value))) if type(value) in (int, float) and math.isfinite(value) else 1
snapshot['stage'] = str(snapshot.get('stage', 'preparing host'))[:240]
# Keep Azure Run Command's 4096-byte stdout limit and SSM limits in view. Only
# known preparation messages are shown; interactive wizard/configure logs are not read.
try:
    with log.open('rb') as stream:
        stream.seek(0, 2)
        size = stream.tell()
        stream.seek(min(__OFFSET__, size) if size <= __OFFSET__ + 65536 else size - 65536)
        lines = stream.read().decode('utf-8', errors='replace').splitlines()
    selected = [line[:240] for line in lines if line.startswith(('[', 'Checked image:', 'PASS:', 'READY:', 'GPU_READY:', 'FAILED:', 'GPU FAILED:', 'STOP:', 'Model API:', 'Model name:', 'Next,', 'OLLAMA_BOOTSTRAP'))]
    messages = '\n'.join(selected)[-1300:]
except FileNotFoundError:
    size, messages = __OFFSET__, ''
download = snapshot.get('download')
if isinstance(download, dict):
    download = {key: download[key] for key in ('file_name', 'bytes_downloaded', 'total_bytes', 'bytes_per_second') if key in download}
else: download = None
print(json.dumps({'status': snapshot['status'], 'stage': snapshot['stage'], 'percent': snapshot['percent'],
    'download': download, 'log_offset': size, 'messages': messages}, ensure_ascii=True, allow_nan=False))
FORTI_STATUS
'''


def build_probe(edition, offset=0, root='/'):
    if edition not in ('cpu', 'gpu', 'ollama') or type(offset) is not int or offset < 0:
        raise ValueError('Invalid status probe arguments.')
    return PROBE.replace('__EDITION__', json.dumps(edition)).replace('__OFFSET__', str(offset)).replace('__ROOT__', json.dumps(str(root)))


def clean(value, limit=240):
    return ''.join(char if char.isprintable() else ' ' for char in str(value))[:limit].strip()


def elapsed(start):
    seconds = int(max(0, time.monotonic() - start))
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    return (f'{hours:02d}h ' if hours else '') + f'{minutes:02d}m {seconds:02d}s'


class ProbeError(RuntimeError):
    pass


class ProbeTimeout(ProbeError):
    """The local CLI process was stopped after its bounded status-read wait."""


def run_cli(command, start, last_stage, timeout=180):
    """Print heartbeats while cloud APIs wait; never start overlapping probes."""
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        deadline = time.monotonic() + timeout
        while True:
            try:
                stdout, stderr = process.communicate(timeout=min(10, max(0.01, deadline - time.monotonic())))
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    process.kill()
                    process.communicate()
                    raise ProbeTimeout('The cloud status probe timed out. No overlapping probe was started.') from None
                print(f'  Checking VM status; last reported stage: {clean(last_stage)} | Total elapsed: {elapsed(start)}', flush=True)
        if process.returncode:
            raise ProbeError(clean(stderr or stdout or 'Cloud CLI command failed.', 700))
        try:
            return json.loads(stdout)
        except ValueError:
            raise ProbeError('The cloud CLI did not return JSON.') from None


def aws_probe(target, script, start, stage):
    prefix = ['aws', '--no-cli-pager', '--region', target.get('region', 'us-east-1')]
    if target.get('aws_profile'):
        prefix += ['--profile', target['aws_profile']]
    response = run_cli(prefix + ['ssm', 'send-command', '--document-name', 'AWS-RunShellScript',
        '--instance-ids', target['instance_id'], '--timeout-seconds', '60', '--parameters',
        json.dumps({'commands': [script], 'executionTimeout': ['30']}), '--output', 'json'], start, stage, 60)
    try:
        command_id = response['Command']['CommandId']
    except (KeyError, TypeError):
        raise ProbeError('SSM did not return a command ID.') from None
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        try:
            result = run_cli(prefix + ['ssm', 'get-command-invocation', '--command-id', command_id,
                '--instance-id', target['instance_id'], '--output', 'json'], start, stage, 60)
        except ProbeError as error:
            if 'InvocationDoesNotExist' not in str(error):
                raise
            time.sleep(3)
            continue
        status = result.get('Status')
        if status in ('Pending', 'InProgress', 'Delayed'):
            print(f'  SSM status snapshot {status}; last reported stage: {clean(stage)} | Total elapsed: {elapsed(start)}', flush=True)
            time.sleep(5)
            continue
        if status != 'Success' or result.get('ResponseCode') != 0:
            raise ProbeError('SSM status probe did not pass: ' + clean(status))
        return result.get('StandardOutputContent', '')
    raise ProbeError('SSM status probe did not finish within its limit. No overlapping probe was started.')


def azure_probe(target, script, start, stage):
    command = ['az', 'vm', 'run-command', 'invoke', '--resource-group', target['resource_group'],
        '--name', target['vm_name'], '--command-id', 'RunShellScript', '--scripts', script,
        '--only-show-errors', '--output', 'json']
    response = run_cli(command, start, stage)
    if not isinstance(response, dict) or not isinstance(response.get('value'), list):
        raise ProbeError('Azure Run Command did not return its expected result.')
    messages = []
    for item in response['value']:
        code = item.get('code', '')
        if code.endswith('/failed'):
            raise ProbeError('Azure status probe failed: ' + clean(item.get('message', ''), 700))
        if code.endswith('/succeeded'):
            messages.append(item.get('message', ''))
    if not messages:
        raise ProbeError('Azure Run Command did not report a successful status probe.')
    return '\n'.join(messages)


def parse_snapshot(output):
    candidates = [line.strip() for line in output.splitlines() if line.strip().startswith('{')]
    if len(candidates) != 1:
        raise ProbeError('Preparation probe did not return exactly one JSON snapshot.')
    try:
        item = json.loads(candidates[0])
    except ValueError:
        raise ProbeError('Preparation status JSON is invalid.') from None
    if (not isinstance(item, dict) or item.get('status') not in ('pending', 'running', 'ready', 'failed')
            or not isinstance(item.get('stage'), str) or not item['stage'].strip()
            or type(item.get('percent')) is not int or not 0 <= item['percent'] <= 100
            or type(item.get('log_offset')) is not int or item['log_offset'] < 0
            or not isinstance(item.get('messages'), str)):
        raise ProbeError('Preparation probe returned an invalid status snapshot.')
    return item


def normalize_target(item):
    if not isinstance(item, dict):
        raise ValueError('Each installation target must be an object.')
    aliases = {'Cloud': 'cloud', 'Edition': 'edition', 'Instance_ID': 'instance_id', 'Region': 'region',
        'Resource_Group': 'resource_group', 'VM_Name': 'vm_name', 'AWS_Profile': 'aws_profile'}
    target = {aliases.get(key, key): value for key, value in item.items()}
    if target.get('cloud') not in ('aws', 'azure') or target.get('edition') not in ('cpu', 'gpu', 'ollama'):
        raise ValueError('Use cloud aws|azure and edition cpu|gpu|ollama.')
    for name in ('instance_id',) if target['cloud'] == 'aws' else ('resource_group', 'vm_name'):
        if not isinstance(target.get(name), str) or not target[name].strip():
            raise ValueError('Missing installation target field: ' + name)
    if target['cloud'] == 'aws' and not re.fullmatch(r'i-(?:[0-9a-f]{8}|[0-9a-f]{17})', target['instance_id']):
        raise ValueError('The AWS installation target needs an EC2 instance ID.')
    for key in ('region', 'aws_profile'):
        if key in target and target[key] is not None and not isinstance(target[key], str):
            raise ValueError('Invalid installation target field: ' + key)
    return target


def watch(target, timeout=None, interval=10, application_next=False):
    target = normalize_target(target)
    duration = timeout if timeout is not None else (5400 if target['edition'] == 'gpu' else 2700)
    start, offset, stage = time.monotonic(), 0, 'waiting for the first VM status snapshot'
    name = target.get('instance_id') or target.get('vm_name')
    print(f"\n{target['cloud'].upper()} {target['edition'].upper()}: {name}", flush=True)
    print('Host percentages are estimated stage milestones; transfer bytes are measured when available.', flush=True)
    print('Waiting for automatic host preparation; sampling the current VM stage...', flush=True)
    failures = 0
    while time.monotonic() - start < duration:
        try:
            probe = build_probe(target['edition'], offset)
            output = (aws_probe if target['cloud'] == 'aws' else azure_probe)(target, probe, start, stage)
            snapshot = parse_snapshot(output)
            failures = 0
        except ProbeError as error:
            message = str(error)
            if any(code in message for code in ('AccessDenied', 'Unauthorized', 'ExpiredToken', 'InvalidClientTokenId', 'SubscriptionNotFound', 'AuthorizationFailed', 'Please run')):
                raise
            failures += 1
            print(f'  Status not available yet: {clean(message, 400)} | Total elapsed: {elapsed(start)}', flush=True)
            if failures >= 10:
                raise ProbeError('Ten consecutive status probes failed. Inspect the existing VM and retry this watcher.') from error
            time.sleep(min(interval, max(0, duration - (time.monotonic() - start))))
            continue
        stage, offset = snapshot['stage'], snapshot['log_offset']
        percent = snapshot['percent']
        bar = '#' * (percent * 24 // 100) + '-' * (24 - percent * 24 // 100)
        print(f"\nPreparation [{snapshot['status'].upper()}] [{bar}] {percent:3d}% | Total elapsed: {elapsed(start)}", flush=True)
        print('  Current stage: ' + clean(stage), flush=True)
        for line in snapshot['messages'].splitlines():
            print('  ' + clean(line, 240), flush=True)
        transfer = snapshot.get('download')
        if isinstance(transfer, dict):
            done, total = transfer.get('bytes_downloaded'), transfer.get('total_bytes')
            if type(done) is int and type(total) is int and 0 <= done <= total and total > 0:
                print(f"  Transfer: {clean(transfer.get('file_name', ''), 100)} {done:,}/{total:,} bytes", flush=True)
        if snapshot['status'] == 'failed':
            raise ProbeError('Host preparation failed. Inspect the printed log on the existing VM; do not create another lab.')
        if snapshot['status'] == 'ready':
            if target['edition'] == 'ollama':
                print('PASS: llama-lab is ready. Configure the FortiAIGate provider, then run sudo ollama-lab configure --manual.', flush=True)
            elif application_next:
                print('PASS: host preparation is ready. Terraform will now install FortiAIGate.', flush=True)
            else:
                print('PASS: host preparation is ready. FortiAIGate has not been deployed.', flush=True)
                print('Connect as your normal SSM/SSH user and run: fortiaigate-install', flush=True)
            print('Readiness verification duration: ' + elapsed(start), flush=True)
            return
        time.sleep(min(interval, max(0, duration - (time.monotonic() - start))))
    raise ProbeError('Preparation wait timed out. The VM is retained. Connect and inspect the existing host, then retry this watcher.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cloud', choices=('aws', 'azure'))
    parser.add_argument('--edition', '--kind', choices=('cpu', 'gpu', 'ollama'))
    parser.add_argument('--instance-id')
    parser.add_argument('--region', default='us-east-1')
    parser.add_argument('--profile', dest='aws_profile', default='')
    parser.add_argument('--resource-group')
    parser.add_argument('--vm-name')
    parser.add_argument('--targets-json', help='JSON file containing targets; use - for stdin.')
    parser.add_argument('--target-json-env', help='Environment variable containing one installation target object.')
    parser.add_argument('--timeout', type=int, help='Maximum readiness wait in seconds.')
    parser.add_argument('--interval', type=int, default=10)
    args = parser.parse_args()
    if args.timeout is not None and args.timeout <= 0 or args.interval < 1:
        parser.error('Timeout and interval must be positive.')
    if args.targets_json and args.target_json_env:
        parser.error('Use only one JSON target input.')
    try:
        if args.target_json_env:
            targets = [json.loads(os.environ[args.target_json_env])]
        elif args.targets_json:
            targets = json.loads(sys.stdin.read() if args.targets_json == '-' else Path(args.targets_json).read_text())
            if isinstance(targets, dict) and 'value' in targets:
                targets = targets['value']
            if not isinstance(targets, list):
                raise ValueError('The targets JSON must be a list.')
        else:
            targets = [vars(args)]
        for target in targets:
            watch(target, args.timeout, args.interval)
    except (ProbeError, ValueError, KeyError, OSError) as error:
        print('STOP: ' + clean(error, 800), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
