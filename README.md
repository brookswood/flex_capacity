# Flex Capacity Automation (`retry-flex-cron.sh`)

An automated lifecycle management script designed to schedule and manage Dynamic Workload Scheduler (DWS) Flex Start compute instances via scheduled cron execution.

## Overview

`retry-flex-cron.sh` provides an unattended, idempotent mechanism for provisioning and monitoring DWS Flex Start instances. Executed via a cron schedule, the script verifies the current state of a targeted compute instance and submits an optimized Flex Start request if no active instance or pending request exists.

### Key Capabilities

- **Idempotency & State Awareness**: Detects existing instances prior to submission. Avoids duplicate requests if an instance is actively running or already pending in the queue.
- **Standardized DWS Parameters**: Submits requests with preconfigured Flex Start specifications:
  - `--provisioning-model=FLEX_START`
  - `--request-valid-for-duration=2h` (Queue validity window)
  - `--max-run-duration=7d` (Maximum runtime once provisioned)
  - `--instance-termination-action=DELETE` & `--maintenance-policy=TERMINATE` (Automatic cleanup upon workload completion)
- **Comprehensive Logging**: Appends timestamped status updates and command output to a designated log file for auditing and operational tracking.
- **Flexible CLI Interface**: Supports custom instance names, machine types, image families, projects, and deployment zones via command-line arguments.

---

## Workflow Logic

```mermaid
flowchart TD
    Start([Cron Trigger]) --> CheckInstance[Describe Instance via CLI]
    CheckInstance --> Exists{Instance Exists?}
    
    Exists -- Yes --> CheckStatus{Status == RUNNING?}
    CheckStatus -- Yes --> LogRunning[Log SUCCESS: Instance RUNNING] --> ExitSuccess([Exit 0])
    CheckStatus -- No --> LogQueued[Log INFO: Request Pending in Queue] --> ExitQueued([Exit 0])
    
    Exists -- No --> SubmitRequest[Submit DWS Flex Start Request]
    SubmitRequest --> CheckExit{Exit Code == 0?}
    CheckExit -- Yes --> LogSubmitSuccess[Log SUCCESS: Request Submitted] --> ExitDone([Exit 0])
    CheckExit -- No --> LogSubmitError[Log ERROR: Command Failed] --> ExitError([Exit 1])
```

---

## Prerequisites

1. **`gcloud` CLI**: Ensure the `gcloud` command-line utility is installed and configured in the execution environment.
2. **Authentication & Permissions**: The executing identity (user or service account) must have permissions to view and create compute instances:
   - `roles/compute.instanceAdmin.v1` (or equivalent custom role)
3. **Execution Permissions**: Ensure the script has execute permissions:
   ```bash
   chmod +x retry-flex-cron.sh
   ```

---

## Configuration & CLI Options

The script accepts the following command-line flags:

| Flag | Long Option | Description | Default | Required |
| :--- | :--- | :--- | :--- | :--- |
| `-p` | `--project` | Target Project ID | *None* | **Yes** |
| `-n` | `--name` | Target instance name | `tpu-v7x-flex` | No |
| `-z` | `--zone` | Target deployment zone | `us-central1-c` | No |
| `-m` | `--machine-type` | Compute / accelerator machine type | `tpu7x-standard-4t` | No |
| `-f` | `--image-family` | OS image family | `ubuntu-accel-2404-amd64-tpu-tpu7x` | No |
| `-i` | `--image-project` | Image project name | `ubuntu-os-accelerator-images` | No |
| `-l` | `--log-file` | Target log file path | `/tmp/retry-flex-cron.log` | No |
| `-h` | `--help` | Display usage and exit | — | — |

---

## Usage Examples

### Manual Execution

Run the script directly to validate parameters and verify configuration:

```bash
./retry-flex-cron.sh \
  --project "example-project-id" \
  --name "accelerator-workload-01" \
  --zone "us-central1-c" \
  --machine-type "tpu7x-standard-4t"
```

### Scheduled Cron Execution

To run the script automatically every 2 hours (aligning with the default 2-hour queue request validity window):

1. Open the user crontab:
   ```bash
   crontab -e
   ```

2. Add the scheduled entry:
   ```cron
   # Execute Flex Start automated retry every 2 hours
   0 */2 * * * /path/to/retry-flex-cron.sh --project "example-project-id" --name "accelerator-workload-01" --zone "us-central1-c" >> /tmp/retry-flex-cron-wrapper.log 2>&1
   ```

> **Note on Environment Paths**: Scheduled cron tasks run in a restricted environment. Ensure the directory containing `gcloud` is included in the `PATH` definition within your crontab, or prepend the path directly:
> ```cron
> PATH=/usr/local/bin:/usr/bin:/bin:/path/to/cloud-sdk/bin
> ```

---

## Logging & Observability

All operational events and output streams are appended with timestamps to the configured log destination (default: `/tmp/retry-flex-cron.log`).

### Monitoring Logs

View recent activity and real-time execution logs:

```bash
tail -f /tmp/retry-flex-cron.log
```

### Sample Log Output

```text
[2026-09-04 20:00:00] --- Cron run started for accelerator-workload-01 in us-central1-c ---
[2026-09-04 20:00:01] INFO: No instance found. Submitting DWS Flex request (valid for 2 hours)...
[2026-09-04 20:00:06] SUCCESS: Flex request submitted successfully.
[2026-09-04 22:00:00] --- Cron run started for accelerator-workload-01 in us-central1-c ---
[2026-09-04 22:00:01] SUCCESS: TPU v7x instance 'accelerator-workload-01' is RUNNING! No action needed.
```

---

## Technical Specifications

- **Provisioning Model**: `FLEX_START` (Dynamic Workload Scheduler)
- **Request Validity Window**: 2 hours (`--request-valid-for-duration=2h`)
- **Maximum Execution Duration**: 7 days (`--max-run-duration=7d`)
- **Lifecycle Termination Actions**: Delete on shutdown (`--instance-termination-action=DELETE`, `--maintenance-policy=TERMINATE`)
- **Reservation Policy**: None (`--reservation-affinity=none`)
