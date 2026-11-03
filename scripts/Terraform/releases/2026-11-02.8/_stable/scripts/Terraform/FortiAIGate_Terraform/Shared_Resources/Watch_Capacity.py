#!/usr/bin/env python3
"""Read-only CloudFormation and real GPU capacity progress for one owned lab."""
import argparse
import datetime as dt
import json
import os
import re
import sys
import time

from Watch_Installation import ProbeError, ProbeTimeout, clean, elapsed, run_cli


MARKER = 'FortiAIGate-GPU-AWS-v1'
ACTIVE = {'REVIEW_IN_PROGRESS', 'CREATE_IN_PROGRESS', 'UPDATE_IN_PROGRESS', 'UPDATE_COMPLETE_CLEANUP_IN_PROGRESS'}
COMPLETE = {'CREATE_COMPLETE', 'UPDATE_COMPLETE'}


def utc(value):
    if not isinstance(value, str):
        raise ValueError('Expected a UTC creation timestamp.')
    result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('The creation timestamp needs a timezone.')
    return result.astimezone(dt.timezone.utc)


def target_config(item):
    if not isinstance(item, dict) or item.get('cloud', 'aws') != 'aws':
        raise ValueError('Capacity progress requires an AWS target object.')
    item = dict(item)
    name, prefix = item.get('stack_name'), item.get('expected_name_prefix')
    if not isinstance(prefix, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,19}_TF', prefix):
        raise ValueError('Use the exact <username>_TF name prefix for this GPU lab.')
    expected = 'FortiAIGate-GPU-' + prefix[:-3].lower().replace('_', '-') + '-TF'
    if name != expected:
        raise ValueError('The GPU stack name and exact name prefix disagree.')
    region = item.setdefault('region', 'us-east-1')
    if not isinstance(region, str) or not re.fullmatch(r'[a-z]{2}(?:-gov)?-[a-z]+-\d', region):
        raise ValueError('Use a valid AWS region.')
    if item.get('aws_profile') is not None and not isinstance(item.get('aws_profile'), str):
        raise ValueError('The AWS profile must be a string.')
    if item.get('min_created_at'):
        utc(item['min_created_at'])
    if item.get('stack_id') and not isinstance(item['stack_id'], str):
        raise ValueError('The expected stack ID must be an ARN string.')
    if item.get('configuration_hash') is not None and not re.fullmatch(r'[0-9a-f]{64}', str(item['configuration_hash'])):
        raise ValueError('The allocation configuration hash must be a lowercase SHA-256.')
    return item


def verify_stack(stack, target, observed_id=None):
    """Pin the first observed ARN, with exact Terraform ownership and parameters."""
    if not isinstance(stack, dict) or stack.get('StackName') != target['stack_name']:
        raise ProbeError('CloudFormation returned another stack name; progress stopped.')
    arn = stack.get('StackId', '')
    match = re.fullmatch(r'arn:(aws(?:-us-gov|-cn)?):cloudformation:([^:]+):(\d{12}):stack/([^/]+)/([A-Za-z0-9-]+)', arn)
    if not match or match[2] != target['region'] or match[4] != target['stack_name']:
        raise ProbeError('GPU stack ARN does not match the intended name and region.')
    if observed_id and arn != observed_id or target.get('stack_id') and arn != target['stack_id']:
        raise ProbeError('GPU stack identity changed during capacity progress; no replacement is followed.')
    if target.get('account_id') and match[3] != target['account_id']:
        raise ProbeError('GPU stack account does not match the intended AWS account.')
    tags = {item['Key']: item['Value'] for item in stack.get('Tags', [])}
    prefix = target['expected_name_prefix']
    parameters = {item['ParameterKey']: item.get('ParameterValue') for item in stack.get('Parameters', [])}
    if (tags.get('ManagedBy') != 'Terraform' or tags.get('DeploymentGuide') != MARKER
            or tags.get('Owner') != prefix[:-3] or parameters.get('NamePrefix') != prefix):
        raise ProbeError('GPU stack ownership or name-prefix parameters conflict; progress stopped.')
    try:
        created = utc(stack['CreationTime'])
    except (KeyError, TypeError, ValueError):
        raise ProbeError('GPU stack did not return a valid creation timestamp.') from None
    if target.get('min_created_at') and created < utc(target['min_created_at']):
        raise ProbeError('An older GPU stack already occupies this name; progress stopped.')
    status = stack.get('StackStatus')
    if not isinstance(status, str):
        raise ProbeError('GPU stack status is missing.')
    return arn, created, status


def phase(rows):
    states = {row.get('LogicalResourceId'): row.get('ResourceStatus') for row in rows}
    if states.get('CapacityRelease') == 'CREATE_COMPLETE':
        return 'GPU running at 10.250.20.10; temporary capacity hold released'
    if states.get('Instance') == 'CREATE_COMPLETE':
        return 'GPU allocated; verifying it and releasing the temporary capacity hold'
    if states.get('CapacityReservation') == 'CREATE_COMPLETE':
        return 'Capacity held; creating the subnet and GPU at 10.250.20.10'
    if states.get('CapacityReservation') == 'CREATE_IN_PROGRESS':
        return 'Checking real GPU capacity across selected zones (attempts below)'
    if 'CapacityFunction' in states or 'CapacityRole' in states:
        return 'Creating the capacity controller and automatic timers'
    return 'Creating the network, scoped permissions and automatic timers'


def missing_stack(error):
    message = str(error)
    return 'ValidationError' in message and 'does not exist' in message


def retryable_read(error):
    """Retry only timeouts and known transient failures of read-only APIs."""
    if isinstance(error, ProbeTimeout):
        return True
    message = str(error)
    return bool(re.search(r'\((?:Throttling|ThrottlingException|RequestLimitExceeded|'
                          r'ServiceUnavailable|InternalError|InternalFailure|RequestTimeout)\)', message)
                or any(text in message for text in (
                    'Read timeout on endpoint URL', 'Connect timeout on endpoint URL',
                    'Could not connect to the endpoint URL',
                    'Connection was closed before we received a valid response')))


class AWS:
    def __init__(self, target, started, deadline):
        self.started = started
        self.deadline = deadline
        self.prefix = ['aws', '--no-cli-pager', '--region', target['region'],
                       '--cli-connect-timeout', '10', '--cli-read-timeout', '20']
        if target.get('aws_profile'):
            self.prefix += ['--profile', target['aws_profile']]

    def call(self, service, operation, stage, *arguments):
        # These operations only inspect the existing stack and its capacity log.
        # Never reuse this retry policy for allocation, SSM execution or cleanup.
        if (service, operation) not in {
                ('cloudformation', 'describe-stacks'), ('cloudformation', 'list-stack-resources'),
                ('cloudformation', 'describe-stack-events'), ('logs', 'filter-log-events')}:
            raise ProbeError('Capacity progress can only call its approved read-only APIs.')
        label = service + ' ' + operation
        for attempt in range(1, 4):
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeError('Capacity progress deadline reached while reading ' + label + '. Inspect the existing stack.')
            try:
                return run_cli(self.prefix + [service, operation, *arguments, '--output', 'json'],
                               self.started, stage, timeout=min(60, remaining))
            except ProbeError as error:
                if not retryable_read(error):
                    raise ProbeError(label + ': ' + str(error)) from error
                remaining = self.deadline - time.monotonic()
                if attempt == 3 or remaining <= 0:
                    raise ProbeError(label + ': status could not be verified after ' + str(attempt)
                                     + ' read attempt(s). ' + str(error)
                                     + ' Inspect the existing stack; no resources were changed by this monitor.') from error
                print('  Temporary status-read failure: ' + label + ' (attempt ' + str(attempt)
                      + '/3). Retrying the same read; provisioning continues independently. '
                      + clean(error, 240), flush=True)
                time.sleep(min(2 ** attempt, remaining))


def watch(target, timeout=2700, interval=10):
    target = target_config(target)
    started, observed_id = time.monotonic(), None
    api = AWS(target, started, started + timeout)
    seen_events, seen_logs, previous_states = set(), set(), {}
    stage, log_notice, configuration_shown = 'waiting for the owned CloudFormation stack to appear', False, False
    print('\nGPU capacity and provisioning: ' + target['stack_name'], flush=True)
    print('Resource counts reflect CloudFormation states; they are not installation-time estimates.', flush=True)
    print('Capacity holds start On-Demand billing. The approved sizes and eight-hour deadline remain unchanged.', flush=True)
    while time.monotonic() - started < timeout:
        try:
            result = api.call('cloudformation', 'describe-stacks', stage,
                              '--stack-name', observed_id or target['stack_name'])
        except ProbeError as error:
            if missing_stack(error) and observed_id is None:
                print('  Waiting for Terraform to submit the GPU stack | Total elapsed: ' + elapsed(started), flush=True)
                time.sleep(min(interval, max(0, timeout - (time.monotonic() - started))))
                continue
            raise
        stacks = result.get('Stacks') if isinstance(result, dict) else None
        if not isinstance(stacks, list) or len(stacks) != 1:
            raise ProbeError('CloudFormation did not return exactly one intended GPU stack.')
        stack = stacks[0]
        candidate_id, created, status = verify_stack(stack, target, observed_id)
        tags = {item['Key']: item['Value'] for item in stack.get('Tags', [])}
        if target.get('configuration_hash') and tags.get('AllocationConfigurationHash') != target['configuration_hash']:
            if observed_id is not None:
                raise ProbeError('The observed GPU allocation configuration changed during progress; no replacement is followed.')
            print('  Waiting for the expected GPU allocation configuration; the previous owned stack is still visible | Total elapsed: ' + elapsed(started), flush=True)
            time.sleep(min(interval, max(0, timeout - (time.monotonic() - started))))
            continue
        observed_id = candidate_id
        if not configuration_shown:
            parameters = {item['ParameterKey']: item.get('ParameterValue') for item in stack.get('Parameters', [])}
            preferred, zone = parameters.get('InstanceType'), parameters.get('AvailabilityZone')
            if preferred in ('g6e.2xlarge', 'g6e.4xlarge'):
                print('Phase 1: check real ' + preferred + ' capacity across supported zones before launching one GPU.', flush=True)
            if zone == 'auto':
                print('  Availability Zone: automatic; supported offerings and each real capacity attempt are reported below.', flush=True)
            elif isinstance(zone, str):
                print('  Availability Zone: ' + clean(zone, 80), flush=True)
            if parameters.get('AllowLargerFallback') == 'yes' and preferred == 'g6e.2xlarge':
                print('Phase 2 is explicitly approved: try g6e.4xlarge only after every preferred-size zone reports capacity exhaustion.', flush=True)
            elif 'AllowLargerFallback' in parameters:
                print('  No additional larger instance size is authorized.', flush=True)
            configuration_shown = True
        # The verified stack status is authoritative. Optional resource/event/log
        # reads must not turn an already completed stack into a failed progress check.
        if status in COMPLETE:
            print('PASS: GPU infrastructure is complete. Host preparation continues in Watch_Installation.py.', flush=True)
            print('Capacity/provisioning verification duration: ' + elapsed(started), flush=True)
            return
        summary = api.call('cloudformation', 'list-stack-resources', stage, '--stack-name', observed_id)
        rows = summary.get('StackResourceSummaries') if isinstance(summary, dict) else None
        if not isinstance(rows, list):
            raise ProbeError('CloudFormation did not return resource progress.')
        stage = phase(rows)
        complete = sum(row.get('ResourceStatus') == 'CREATE_COMPLETE' for row in rows)
        print(f'\nCloudFormation resources: {complete}/{len(rows)} discovered resources created | {clean(status)} | Total elapsed: {elapsed(started)}', flush=True)
        print('  Current stage: ' + stage, flush=True)
        for row in rows:
            logical, resource_status = row.get('LogicalResourceId', ''), row.get('ResourceStatus', '')
            if previous_states.get(logical) != resource_status:
                print('    ' + clean(logical, 100) + ': ' + clean(resource_status, 80), flush=True)
                previous_states[logical] = resource_status
        events = api.call('cloudformation', 'describe-stack-events', stage,
                          '--stack-name', observed_id, '--max-items', '30')
        for event in reversed(events.get('StackEvents', [])):
            key = event.get('EventId')
            if not key or key in seen_events or event.get('StackId') != observed_id:
                continue
            seen_events.add(key)
            if event.get('ResourceStatus', '').endswith('_FAILED'):
                print('    ' + clean(event.get('LogicalResourceId', ''), 100) + ': ' + clean(event.get('ResourceStatusReason', 'resource failed'), 700), flush=True)
        if any(row.get('LogicalResourceId') == 'CapacityLogs' for row in rows):
            try:
                logs = api.call('logs', 'filter-log-events', stage,
                    '--log-group-name', '/aws/lambda/' + target['stack_name'] + '-capacity',
                    '--filter-pattern', '"CAPACITY"', '--start-time', str(int(created.timestamp() * 1000)), '--limit', '100')
                for item in logs.get('events', []):
                    key, message = item.get('eventId'), item.get('message', '').strip()
                    if (key and key not in seen_logs and message.startswith('CAPACITY ')
                            and isinstance(item.get('timestamp'), (int, float))
                            and item['timestamp'] >= int(created.timestamp() * 1000)):
                        seen_logs.add(key)
                        print('    ' + clean(message, 700), flush=True)
            except ProbeError as error:
                if not log_notice:
                    print('    Capacity log stream is not readable yet; stack progress continues. ' + clean(error, 240), flush=True)
                    log_notice = True
        if status not in ACTIVE:
            raise ProbeError('GPU provisioning ended with ' + clean(status) + '. Inspect the same owned stack; this watcher never creates or deletes resources.')
        time.sleep(min(interval, max(0, timeout - (time.monotonic() - started))))
    raise ProbeError('GPU capacity/provisioning wait timed out. Inspect the existing stack; no additional request was submitted.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target-json-env', help='Environment variable containing one AWS capacity target object.')
    parser.add_argument('--stack-name')
    parser.add_argument('--expected-name-prefix')
    parser.add_argument('--region', default='us-east-1')
    parser.add_argument('--profile', dest='aws_profile', default='')
    parser.add_argument('--min-created-at')
    parser.add_argument('--configuration-hash')
    parser.add_argument('--timeout', type=int, default=2700)
    parser.add_argument('--interval', type=int, default=10)
    args = parser.parse_args()
    if args.timeout < 1 or args.interval < 1:
        parser.error('Timeout and interval must be positive.')
    try:
        target = json.loads(os.environ[args.target_json_env]) if args.target_json_env else vars(args)
        watch(target, args.timeout, args.interval)
    except (ProbeError, ValueError, KeyError, OSError) as error:
        print('STOP: ' + clean(error, 900), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
