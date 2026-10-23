#!/usr/bin/env python3
"""
Notification Hook for Flex Capacity Automation (`retry-flex-cron.sh`)

This script is invoked by `retry-flex-cron.sh` when compute resources (such as
2x NVIDIA A100 and 2x NVIDIA H100 GPUs) are found or confirmed in a running
state. It receives detailed findings via command-line arguments and provides an
extensible foundation for custom notification logic.

NOTE: Out of the box, this script logs findings locally and does NOT send external
network requests. Implement your custom delivery mechanism (Slack, Webhook,
Email, PagerDuty, etc.) in the `send_custom_notification` function below.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone


def parse_arguments() -> argparse.Namespace:
    """Parse incoming command-line arguments provided by the caller script."""
    parser = argparse.ArgumentParser(
        description="Process instance discovery findings and dispatch notifications."
    )
    parser.add_argument(
        "--event",
        default="resource_found",
        help="Event type (e.g., resource_found, resource_queued)",
    )
    parser.add_argument(
        "--status",
        default="UNKNOWN",
        help="Instance status (e.g., RUNNING, PROVISIONING)",
    )
    parser.add_argument(
        "--name",
        default="unknown-instance",
        help="Instance name",
    )
    parser.add_argument(
        "--project",
        default="unknown-project",
        help="Project ID",
    )
    parser.add_argument(
        "--zone",
        default="unknown-zone",
        help="Deployment zone",
    )
    parser.add_argument(
        "--machine-type",
        default="unknown-machine-type",
        help="Machine / accelerator type (e.g., a2-highgpu-2g, a3-highgpu-2g)",
    )
    parser.add_argument(
        "--gpu-type",
        default="NVIDIA_GPU",
        help="Accelerator model (e.g., NVIDIA_A100, NVIDIA_H100)",
    )
    parser.add_argument(
        "--gpu-count",
        type=int,
        default=2,
        help="Number of GPUs attached to the instance (default: 2)",
    )
    parser.add_argument(
        "--end-date",
        default="2027-02-28T23:59:59Z",
        help="Campaign expiration timestamp (ISO 8601 UTC)",
    )
    parser.add_argument(
        "--ip",
        default="N/A",
        help="Allocated IP address if available",
    )
    parser.add_argument(
        "--timestamp",
        default=datetime.now(timezone.utc).isoformat(),
        help="Timestamp of the discovery event (ISO 8601)",
    )
    parser.add_argument(
        "--log-file",
        default=None,
        help="Path to the caller log file",
    )
    return parser.parse_args()


def send_custom_notification(findings: dict) -> None:
    """
    User Implementation Hook.

    Implement your custom delivery logic here (e.g., Slack webhook, Discord,
    SMTP email, HTTP endpoint, PagerDuty, etc.).

    Example implementations:

    --- Example 1: Webhook (Slack, Discord, Custom API) ---
    ```python
    import urllib.request
    webhook_url = os.environ.get("NOTIFICATION_WEBHOOK_URL")
    if webhook_url:
        payload = json.dumps({
            "text": (
                f"Compute resource found: {findings['instance_name']} "
                f"({findings['gpu_count']}x {findings['gpu_type']}, {findings['machine_type']}) "
                f"is {findings['status']} in {findings['zone']} (Campaign active until {findings['end_date']})."
            )
        }).encode("utf-8")
        req = urllib.request.Request(
            webhook_url,
            data=payload,
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req) as response:
            print(f"Webhook delivered: {response.status}")
    ```

    --- Example 2: SMTP Email ---
    ```python
    import smtplib
    from email.message import EmailMessage
    smtp_host = os.environ.get("SMTP_HOST")
    if smtp_host:
        msg = EmailMessage()
        msg.set_content(json.dumps(findings, indent=2))
        msg["Subject"] = f"Resource Alert: {findings['instance_name']} ({findings['status']})"
        msg["From"] = "alerts@example.com"
        msg["To"] = "team@example.com"
        with smtplib.SMTP(smtp_host) as s:
            s.send_message(msg)
    ```
    """
    # By default, no external notification is sent.
    # The user can customize this block according to their requirements.
    pass


def main() -> int:
    args = parse_arguments()

    findings = {
        "event": args.event,
        "status": args.status,
        "instance_name": args.name,
        "project": args.project,
        "zone": args.zone,
        "machine_type": args.machine_type,
        "gpu_type": args.gpu_type,
        "gpu_count": args.gpu_count,
        "end_date": args.end_date,
        "ip_address": args.ip,
        "timestamp": args.timestamp,
        "log_file": args.log_file,
    }

    # Format findings for local logging / inspection
    output_summary = (
        f"[Notification Hook] Event: {findings['event']} | "
        f"Instance: {findings['instance_name']} | "
        f"GPU: {findings['gpu_count']}x {findings['gpu_type']} ({findings['machine_type']}) | "
        f"Status: {findings['status']} | "
        f"Zone: {findings['zone']} | "
        f"IP: {findings['ip_address']} | "
        f"Until: {findings['end_date']}"
    )

    print(output_summary)

    # Dispatch user-defined custom notification
    try:
        send_custom_notification(findings)
    except Exception as exc:
        print(f"[Notification Hook ERROR] Failed to dispatch notification: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
