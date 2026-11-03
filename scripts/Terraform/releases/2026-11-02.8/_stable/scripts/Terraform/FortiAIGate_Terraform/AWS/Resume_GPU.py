#!/usr/bin/env python3
"""Resume the exact Terraform GPU VM without resetting its deletion deadline."""
import argparse
import datetime as dt
import json
import re
import shlex
import subprocess
import time

from Extend_GPU import AWS, inspect, utc


def owned_instance(aws, name):
    stack, parameters = inspect(aws, name)
    outputs = {row['OutputKey']: row['OutputValue'] for row in stack['Outputs']}
    rows = aws.call('ec2', 'describe-instances', '--instance-ids', outputs['InstanceId'])
    instances = [item for group in rows.get('Reservations', []) for item in group.get('Instances', [])]
    if len(instances) != 1:
        raise RuntimeError('The exact GPU VM could not be verified; nothing was started.')
    instance = instances[0]
    tags = {row['Key']: row['Value'] for row in instance.get('Tags', [])}
    if (instance.get('InstanceId') != outputs['InstanceId']
            or instance.get('InstanceType') != outputs.get('InstanceType', parameters['InstanceType'])
            or tags.get('BudgetStack') != stack['StackId']
            or tags.get('FortiAIGateBudgetStack') != stack['StackId']
            or tags.get('BudgetVersion') != '8h-delete-v2'
            or tags.get('BudgetDeleteAt') != parameters['BudgetDeleteAt']):
        raise RuntimeError('GPU VM identity or deadline changed; nothing was started.')
    if utc(parameters['BudgetDeleteAt']) <= dt.datetime.now(dt.timezone.utc):
        raise RuntimeError('The deletion deadline passed; the existing lab cannot be resumed.')
    return stack, parameters, outputs, instance


def clear_released_target(aws, stack, outputs, instance):
    expected = outputs.get('CapacityReservationId')
    target = instance.get('CapacityReservationSpecification', {}).get('CapacityReservationTarget', {})
    if not target:
        return False
    if not re.fullmatch(r'cr-[0-9a-f]{17}', expected or '') or target != {'CapacityReservationId': expected}:
        raise RuntimeError('The capacity target differs from this lab; nothing was changed.')
    rows = aws.call('ec2', 'describe-capacity-reservations', '--capacity-reservation-ids', expected).get('CapacityReservations', [])
    if len(rows) != 1 or rows[0].get('CapacityReservationId') != expected:
        raise RuntimeError('The owned initial capacity hold could not be verified; nothing was changed.')
    row = rows[0]
    tags = {item['Key']: item['Value'] for item in row.get('Tags', [])}
    if (tags.get('DeploymentGuide') != 'FortiAIGate-GPU-AWS-v1'
            or tags.get('BudgetStack') != stack['StackId'] or tags.get('FortiAIGateBudgetStack') != stack['StackId']
            or tags.get('CapacityLogicalId') != 'CapacityReservation'
            or not re.fullmatch(r'[0-9a-f]{32}', tags.get('CapacityAttempt', ''))
            or row.get('InstanceType') != instance['InstanceType']
            or row.get('InstancePlatform') != 'Linux/UNIX' or row.get('TotalInstanceCount') != 1
            or row.get('Tenancy') != 'default' or row.get('InstanceMatchCriteria') != 'targeted'):
        raise RuntimeError('Capacity hold ownership or configuration changed; nothing was changed.')
    if row.get('State') == 'active':
        return False
    if row.get('State') not in ('cancelled', 'expired'):
        raise RuntimeError('The initial capacity hold is changing state; wait and retry Resume.')
    result = aws.call('ec2', 'modify-instance-capacity-reservation-attributes', '--instance-id', instance['InstanceId'],
        '--capacity-reservation-specification', json.dumps({'CapacityReservationPreference': 'none'}))
    if result.get('Return') is not True:
        raise RuntimeError('Clearing the released capacity target was not confirmed; the VM was not started.')
    return True


def resume(aws, name):
    stack, parameters, outputs, instance = owned_instance(aws, name)
    state = instance.get('State', {}).get('Name')
    if state == 'running':
        print('GPU VM is already running. Its deletion deadline is unchanged: ' + parameters['BudgetDeleteAt'])
        return instance['InstanceId']
    if state != 'stopped':
        raise RuntimeError('The GPU VM is changing state; wait and retry Resume. Nothing was started.')
    changed = clear_released_target(aws, stack, outputs, instance)
    for attempt in range(6):
        fresh_stack, fresh_parameters, _, fresh = owned_instance(aws, name)
        specification = fresh.get('CapacityReservationSpecification', {})
        if (fresh_stack['StackId'] != stack['StackId'] or fresh['InstanceId'] != instance['InstanceId']
                or fresh.get('State', {}).get('Name') != 'stopped'
                or fresh_parameters['BudgetDeleteAt'] != parameters['BudgetDeleteAt']):
            raise RuntimeError('The exact stopped VM or deadline changed during Resume; nothing was started.')
        if not changed or specification.get('CapacityReservationPreference') == 'none' and not specification.get('CapacityReservationTarget'):
            break
        if attempt < 5:
            time.sleep(2)
    else:
        raise RuntimeError('On-Demand restart settings were not verified; the VM was not started.')
    result = aws.call('ec2', 'start-instances', '--instance-ids', instance['InstanceId'])
    rows = result.get('StartingInstances', [])
    if len(rows) != 1 or rows[0].get('InstanceId') != instance['InstanceId'] or rows[0].get('CurrentState', {}).get('Name') not in ('pending', 'running'):
        raise RuntimeError('The start response was not confirmed; inspect this same VM before retrying.')
    print('PASS: AWS accepted start for the existing GPU VM in its existing zone.')
    print('Deletion deadline unchanged: ' + parameters['BudgetDeleteAt'])
    return instance['InstanceId']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stack-name', required=True)
    parser.add_argument('--region', default='us-east-1')
    parser.add_argument('--profile')
    args = parser.parse_args()
    if not re.fullmatch(r'FortiAIGate-GPU-[a-z][a-z0-9-]{0,19}-TF', args.stack_name):
        parser.error('Use the exact Stack_Name output of this Terraform GPU lab.')
    aws = AWS(args.region, args.profile)
    instance_id = resume(aws, args.stack_name)
    command = ['aws', *aws.options, 'ssm', 'start-session', '--target', instance_id]
    print('Connect when Session Manager is ready: ' + shlex.join(command))


if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit('STOP: ' + str(error)) from None
