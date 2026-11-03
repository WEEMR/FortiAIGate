#!/usr/bin/env python3
"""Explicitly add eight hours to one Terraform-owned AWS GPU lab deadline."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def utc(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", value):
        raise ValueError("The GPU lifecycle timestamp is not an exact UTC timestamp.")
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def extension(parameters, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    created, expires = utc(parameters["BudgetCreatedAt"]), utc(parameters["BudgetDeleteAt"])
    interval = dt.timedelta(hours=8)
    if expires <= now or expires <= created or (expires - created) % interval:
        raise ValueError("The GPU deadline expired or is not a positive eight-hour interval; extension refused.")
    if parameters["DeleteScheduleTime"] != parameters["BudgetDeleteAt"].removesuffix("Z"):
        raise ValueError("The saved GPU deadline and schedule parameters disagree.")
    return (expires + interval).strftime("%Y-%m-%dT%H:%M:%SZ")


def update_parameters(previous, deadline):
    changed = {"BudgetDeleteAt": deadline, "DeleteScheduleTime": deadline.removesuffix("Z")}
    return [{"ParameterKey": key, "ParameterValue": changed[key]} if key in changed else {
        "ParameterKey": key, "UsePreviousValue": True} for key in previous]


class AWS:
    def __init__(self, region, profile=None):
        self.options = ["--region", region]
        if profile:
            self.options += ["--profile", profile]

    def call(self, service, operation, *arguments):
        command = ["aws", *self.options, service, operation, *arguments, "--output", "json", "--no-cli-pager"]
        result = subprocess.run(command, text=True, capture_output=True, timeout=120,
                                env=dict(os.environ, AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off"))
        if result.returncode:
            raise RuntimeError(f"AWS {service} {operation} failed; inspect the exact lab in AWS before retrying.")
        return json.loads(result.stdout or "{}")


def inspect(aws, name):
    stacks = aws.call("cloudformation", "describe-stacks", "--stack-name", name).get("Stacks", [])
    if len(stacks) != 1:
        raise RuntimeError("Expected one exact GPU stack.")
    stack = stacks[0]
    tags = {item["Key"]: item["Value"] for item in stack.get("Tags", [])}
    if (stack.get("StackName") != name or tags.get("ManagedBy") != "Terraform"
            or tags.get("DeploymentGuide") != "FortiAIGate-GPU-AWS-v1"
            or stack.get("StackStatus") not in ("CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE")):
        raise RuntimeError("The exact Terraform GPU stack is not in a stable owned state; extension refused.")
    parameters = {item["ParameterKey"]: item["ParameterValue"] for item in stack["Parameters"]}
    outputs = {item["OutputKey"]: item["OutputValue"] for item in stack["Outputs"]}
    schedule = aws.call("scheduler", "get-schedule", "--name", outputs["BudgetDeleteSchedule"], "--group-name", "default")
    if (schedule.get("State") != "ENABLED" or schedule.get("ScheduleExpressionTimezone", "UTC") != "UTC"
            or schedule.get("ScheduleExpression") != "at(" + parameters["DeleteScheduleTime"] + ")"):
        raise RuntimeError("The authoritative UTC schedule disagrees with the saved deadline; extension refused.")
    rows = aws.call("ec2", "describe-instances", "--instance-ids", outputs["InstanceId"])
    instances = [row for reservation in rows.get("Reservations", []) for row in reservation.get("Instances", [])]
    if len(instances) != 1:
        raise RuntimeError("The exact GPU instance could not be verified.")
    instance = instances[0]
    instance_tags = {item["Key"]: item["Value"] for item in instance.get("Tags", [])}
    allowed_types = [parameters["InstanceType"]]
    if parameters["InstanceType"] == "g6e.2xlarge" and parameters.get("AllowLargerFallback", "no") == "yes":
        allowed_types.append("g6e.4xlarge")
    actual_type = outputs.get("InstanceType", parameters["InstanceType"])
    if (actual_type not in allowed_types or instance.get("InstanceId") != outputs["InstanceId"] or instance.get("InstanceType") != actual_type
            or instance_tags.get("BudgetStack") != stack["StackId"] or instance_tags.get("BudgetVersion") != "8h-delete-v2"
            or instance_tags.get("BudgetCreatedAt") != parameters["BudgetCreatedAt"]
            or instance_tags.get("BudgetDeleteAt") != parameters["BudgetDeleteAt"]):
        raise RuntimeError("The GPU instance identity or lifecycle tags disagree; extension refused.")
    return stack, parameters


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-name", required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--profile")
    args = parser.parse_args()
    if not re.fullmatch(r"FortiAIGate-GPU-[a-z][a-z0-9-]{0,19}-TF", args.stack_name):
        parser.error("Use the exact Stack_Name output of this Terraform GPU deployment.")
    aws = AWS(args.region, args.profile)
    stack, parameters = inspect(aws, args.stack_name)
    deadline = extension(parameters)
    print("GPU stack: " + args.stack_name)
    print("Current deletion deadline (UTC): " + parameters["BudgetDeleteAt"])
    print("New deletion deadline (UTC):     " + deadline)
    print("This adds eight hours; Connect and Restart never extend the lab.")
    if input("Type EXTEND to approve: ").strip() != "EXTEND":
        print("Cancelled; the deadline is unchanged.")
        return
    # Re-read after approval; never overwrite another operator's extension.
    latest, current = inspect(aws, args.stack_name)
    if latest["StackId"] != stack["StackId"] or current != parameters:
        raise RuntimeError("The GPU deployment changed during approval; rerun Extend to review its current deadline.")
    extension(current)
    request = {"StackName": stack["StackId"], "UsePreviousTemplate": True,
               "Capabilities": ["CAPABILITY_NAMED_IAM"], "Parameters": update_parameters(parameters, deadline)}
    with tempfile.TemporaryDirectory(prefix="fortiaigate-extend-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        path.chmod(0o600)
        aws.call("cloudformation", "update-stack", "--cli-input-json", "file://" + str(path))
    started = time.monotonic()
    while time.monotonic() - started < 1800:
        stacks = aws.call("cloudformation", "describe-stacks", "--stack-name", stack["StackId"])["Stacks"]
        status = stacks[0]["StackStatus"]
        if status == "UPDATE_COMPLETE":
            final, verified = inspect(aws, args.stack_name)
            if final["StackId"] != stack["StackId"] or verified["BudgetDeleteAt"] != deadline:
                raise RuntimeError("Extension completion could not be verified; inspect the CloudFormation stack.")
            print("PASS: UTC schedule, GPU tags and CloudFormation deadline verified: " + deadline)
            return
        if status not in ("UPDATE_IN_PROGRESS", "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS"):
            raise RuntimeError("CloudFormation update ended with " + status + "; extension is not reported ready. Inspect its events and rollback state.")
        print("GPU extension: " + status + " | elapsed " + str(int(time.monotonic() - started)) + "s", flush=True)
        time.sleep(15)
    raise RuntimeError("GPU extension update timed out; inspect the stack before retrying.")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit("STOP: " + str(error)) from None
