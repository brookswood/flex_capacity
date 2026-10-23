#!/bin/bash

# Default Log File
LOG_FILE="/tmp/retry-flex-cron.log"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -p, --project            Target GCP Project ID (required)"
  echo "  -g, --gpu-profile        GPU profile to provision: 'both' (2x A100 + 2x H100), 'a100' (2x A100),"
  echo "                           'h100' (2x H100), or 'custom' (default: both)"
  echo "  -z, --zone               Deployment Zone or comma-separated fallback zones (default: us-central1-c)"
  echo "  -e, --end-date, --until  Campaign expiration timestamp in ISO-8601 UTC"
  echo "                           (default: 2027-02-28T23:59:59Z — end of February 2027)"
  echo "  --a100-name              Instance name for 2x A100 workload (default: a100-2x-flex)"
  echo "  --a100-machine-type      Machine type for 2x A100 workload (default: a2-highgpu-2g)"
  echo "  --h100-name              Instance name for 2x H100 workload (default: h100-2x-flex)"
  echo "  --h100-machine-type      Machine type for 2x H100 workload (default: a3-highgpu-2g)"
  echo "  -n, --name               Custom instance name (used when --gpu-profile=custom or single override)"
  echo "  -m, --machine-type       Custom machine type (used when --gpu-profile=custom or single override)"
  echo "  -f, --image-family       Image family (default: ubuntu-accelerator-2404-amd64-with-nvidia-580)"
  echo "  -i, --image-project      Image project (default: ubuntu-os-accelerator-images)"
  echo "  -l, --log-file           Log file path (default: /tmp/retry-flex-cron.log)"
  echo "  -s, --notify-script      Path to notification Python script (default: notify.py if present)"
  echo "  --notify-on              Trigger condition: 'running' or 'all' (default: running)"
  echo "  --no-notify              Disable notification hook"
  echo "  -h, --help               Show this help message"
  exit 1
}

# Helper function to write to the log file with timestamps
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# 1. Define internal defaults (2x A100 and 2x H100 GPUs until end of February 2027)
DEFAULT_GPU_PROFILE="both"
DEFAULT_A100_INSTANCE_NAME="a100-2x-flex"
DEFAULT_A100_MACHINE_TYPE="a2-highgpu-2g"
DEFAULT_H100_INSTANCE_NAME="h100-2x-flex"
DEFAULT_H100_MACHINE_TYPE="a3-highgpu-2g"

DEFAULT_INSTANCE_NAME=""
DEFAULT_MACHINE_TYPE=""
DEFAULT_PROJECT=""
DEFAULT_ZONE="us-central1-c,us-central1-b,us-central1-a,us-central1-f"
DEFAULT_IMAGE_FAMILY="ubuntu-accelerator-2404-amd64-with-nvidia-580"
DEFAULT_IMAGE_PROJECT="ubuntu-os-accelerator-images"
DEFAULT_END_DATE="2027-02-28T23:59:59Z"
MAX_LEASE_SECONDS=604800 # 7 days (DWS Flex Start maximum run duration)
MIN_LEASE_SECONDS=600    # 10 minutes (GCE minimum max-run-duration)

# Locate script directory to auto-detect default notify.py if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_NOTIFY_SCRIPT=""
if [ -f "${SCRIPT_DIR}/notify.py" ]; then
  DEFAULT_NOTIFY_SCRIPT="${SCRIPT_DIR}/notify.py"
fi
DEFAULT_NOTIFY_ON="running"

# 2. Parse command-line arguments (Flags)
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -g|--gpu-profile) GPU_PROFILE_ARG="$2"; shift ;;
    --a100-name) A100_NAME_ARG="$2"; shift ;;
    --a100-machine-type) A100_MACHINE_TYPE_ARG="$2"; shift ;;
    --h100-name) H100_NAME_ARG="$2"; shift ;;
    --h100-machine-type) H100_MACHINE_TYPE_ARG="$2"; shift ;;
    -n|--name) INSTANCE_NAME_ARG="$2"; shift ;;
    -p|--project) PROJECT_ARG="$2"; shift ;;
    -z|--zone) ZONE_ARG="$2"; shift ;;
    -m|--machine-type) MACHINE_TYPE_ARG="$2"; shift ;;
    -f|--image-family) IMAGE_FAMILY_ARG="$2"; shift ;;
    -i|--image-project) IMAGE_PROJECT_ARG="$2"; shift ;;
    -e|--end-date|--until) END_DATE_ARG="$2"; shift ;;
    -l|--log-file) LOG_FILE="$2"; shift ;;
    -s|--notify-script) NOTIFY_SCRIPT_ARG="$2"; shift ;;
    --notify-on) NOTIFY_ON_ARG="$2"; shift ;;
    --no-notify) NOTIFY_SCRIPT_ARG="none" ;;
    -h|--help) usage ;;
    *) echo "Error: Unknown parameter passed: $1" >> "$LOG_FILE"; exit 1 ;;
  esac
  shift
done

# 3. Assign values: Check argument first, fallback to default
GPU_PROFILE="${GPU_PROFILE_ARG:-$DEFAULT_GPU_PROFILE}"
A100_INSTANCE_NAME="${A100_NAME_ARG:-$DEFAULT_A100_INSTANCE_NAME}"
A100_MACHINE_TYPE="${A100_MACHINE_TYPE_ARG:-$DEFAULT_A100_MACHINE_TYPE}"
H100_INSTANCE_NAME="${H100_NAME_ARG:-$DEFAULT_H100_INSTANCE_NAME}"
H100_MACHINE_TYPE="${H100_MACHINE_TYPE_ARG:-$DEFAULT_H100_MACHINE_TYPE}"

CUSTOM_INSTANCE_NAME="${INSTANCE_NAME_ARG:-$DEFAULT_INSTANCE_NAME}"
CUSTOM_MACHINE_TYPE="${MACHINE_TYPE_ARG:-$DEFAULT_MACHINE_TYPE}"

# If user explicitly passed -n/--name or -m/--machine-type without specifying -g/--gpu-profile,
# switch to custom single-instance mode for backward compatibility.
if [ -z "$GPU_PROFILE_ARG" ] && { [ -n "$INSTANCE_NAME_ARG" ] || [ -n "$MACHINE_TYPE_ARG" ]; }; then
  GPU_PROFILE="custom"
  CUSTOM_INSTANCE_NAME="${CUSTOM_INSTANCE_NAME:-gpu-flex-instance}"
  CUSTOM_MACHINE_TYPE="${CUSTOM_MACHINE_TYPE:-$DEFAULT_A100_MACHINE_TYPE}"
fi

PROJECT="${PROJECT_ARG:-$DEFAULT_PROJECT}"
ZONE_LIST="${ZONE_ARG:-$DEFAULT_ZONE}"
IMAGE_FAMILY="${IMAGE_FAMILY_ARG:-$DEFAULT_IMAGE_FAMILY}"
IMAGE_PROJECT="${IMAGE_PROJECT_ARG:-$DEFAULT_IMAGE_PROJECT}"
END_DATE="${END_DATE_ARG:-$DEFAULT_END_DATE}"

if [ "$NOTIFY_SCRIPT_ARG" = "none" ]; then
  NOTIFY_SCRIPT=""
else
  NOTIFY_SCRIPT="${NOTIFY_SCRIPT_ARG:-$DEFAULT_NOTIFY_SCRIPT}"
fi
NOTIFY_ON="${NOTIFY_ON_ARG:-$DEFAULT_NOTIFY_ON}"

# 4. Validate required shared parameters
if [ -z "$PROJECT" ] || [ -z "$ZONE_LIST" ] || [ -z "$IMAGE_FAMILY" ] || [ -z "$IMAGE_PROJECT" ]; then
  log "ERROR: One or more required configuration variables (PROJECT, ZONE, IMAGE_FAMILY, IMAGE_PROJECT) are missing."
  exit 1
fi

# 5. Parse campaign end date (End of February 2027: 2027-02-28T23:59:59Z) and calculate remaining lease duration
parse_epoch() {
  local ts="$1"
  if date -u -d "$ts" +%s &>/dev/null; then
    date -u -d "$ts" +%s
  elif command -v python3 &>/dev/null; then
    python3 -c "import sys, datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00')).timestamp()))" "$ts" 2>/dev/null
  else
    echo ""
  fi
}

NOW_EPOCH=$(date -u +%s)
END_EPOCH=$(parse_epoch "$END_DATE")

if [ -z "$END_EPOCH" ]; then
  log "ERROR: Failed to parse --end-date '$END_DATE'. Use ISO-8601 UTC format (e.g., 2027-02-28T23:59:59Z)."
  exit 1
fi

if [ "$NOW_EPOCH" -ge "$END_EPOCH" ]; then
  log "INFO: Campaign end date ($END_DATE) reached. Stopping DWS Flex Start requests for 2x A100 and 2x H100 GPUs."
  exit 0
fi

REMAINING_SECONDS=$((END_EPOCH - NOW_EPOCH))
if [ "$REMAINING_SECONDS" -lt "$MIN_LEASE_SECONDS" ]; then
  log "INFO: Remaining window (${REMAINING_SECONDS}s) until $END_DATE is shorter than GCE minimum run duration (${MIN_LEASE_SECONDS}s). Exiting."
  exit 0
elif [ "$REMAINING_SECONDS" -lt "$MAX_LEASE_SECONDS" ]; then
  MAX_RUN_DURATION="${REMAINING_SECONDS}s"
  log "INFO: Approaching campaign end date ($END_DATE). Capping --max-run-duration to ${MAX_RUN_DURATION}."
else
  MAX_RUN_DURATION="7d"
fi

# Helper function to invoke notification hook if configured
notify_hook() {
  local event_type="$1"
  local instance_status="$2"
  local inst_name="$3"
  local mach_type="$4"
  local inst_zone="$5"
  local gpu_type="$6"
  local gpu_count="$7"

  if [ -z "$NOTIFY_SCRIPT" ] || [ ! -f "$NOTIFY_SCRIPT" ]; then
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    log "WARNING: python3 not found on PATH; skipping notification hook."
    return 0
  fi

  log "INFO: Triggering notification hook ($NOTIFY_SCRIPT) for '$inst_name' ($gpu_count x $gpu_type) event '$event_type' with status '$instance_status'..."

  # Attempt to extract allocated IP if instance is running
  local ip_addr="N/A"
  if [ "$instance_status" = "RUNNING" ]; then
    ip_addr=$(gcloud compute instances describe "$inst_name" \
      --project="$PROJECT" \
      --zone="$inst_zone" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)
    if [ -z "$ip_addr" ]; then
      ip_addr=$(gcloud compute instances describe "$inst_name" \
        --project="$PROJECT" \
        --zone="$inst_zone" \
        --format="value(networkInterfaces[0].networkIP)" 2>/dev/null)
    fi
  fi

  python3 "$NOTIFY_SCRIPT" \
    --event "$event_type" \
    --status "$instance_status" \
    --name "$inst_name" \
    --project "$PROJECT" \
    --zone "$inst_zone" \
    --machine-type "$mach_type" \
    --gpu-type "$gpu_type" \
    --gpu-count "$gpu_count" \
    --end-date "$END_DATE" \
    --ip "${ip_addr:-N/A}" \
    --log-file "$LOG_FILE" \
    --timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$LOG_FILE" 2>&1

  local hook_exit=$?
  if [ $hook_exit -eq 0 ]; then
    log "INFO: Notification hook executed successfully for '$inst_name'."
  else
    log "WARNING: Notification hook returned exit code $hook_exit for '$inst_name'."
  fi
}

# 6. Provision or check a single GPU instance across configured zone(s)
provision_or_check_instance() {
  local inst_name="$1"
  local mach_type="$2"
  local gpu_type="$3"
  local gpu_count="$4"

  if [ -z "$inst_name" ] || [ -z "$mach_type" ]; then
    log "ERROR: Missing instance name or machine type for GPU workload ($gpu_type)."
    return 1
  fi

  IFS=',' read -r -a ZONES <<< "$ZONE_LIST"
  local existing_status=""
  local existing_zone=""

  # First check if the instance already exists in any of the configured zones
  for z in "${ZONES[@]}"; do
    z="$(echo "$z" | xargs)"
    [ -z "$z" ] && continue
    local st
    st=$(gcloud compute instances describe "$inst_name" \
      --project="$PROJECT" \
      --zone="$z" \
      --format="value(status)" 2>/dev/null)
    if [ -n "$st" ]; then
      existing_status="$st"
      existing_zone="$z"
      break
    fi
  done

  if [ -n "$existing_status" ]; then
    if [ "$existing_status" = "RUNNING" ]; then
      log "SUCCESS: Instance '$inst_name' (${gpu_count}x ${gpu_type}, ${mach_type}) is RUNNING in ${existing_zone}! No action needed."
      notify_hook "resource_found" "$existing_status" "$inst_name" "$mach_type" "$existing_zone" "$gpu_type" "$gpu_count"
      return 0
    else
      log "INFO: Instance '$inst_name' (${gpu_count}x ${gpu_type}) exists in ${existing_zone} with status: ${existing_status}. Flex request is active in queue."
      if [ "$NOTIFY_ON" = "all" ]; then
        notify_hook "resource_queued" "$existing_status" "$inst_name" "$mach_type" "$existing_zone" "$gpu_type" "$gpu_count"
      fi
      return 0
    fi
  fi

  # Submit DWS Flex Start request across candidate zones until one succeeds
  for z in "${ZONES[@]}"; do
    z="$(echo "$z" | xargs)"
    [ -z "$z" ] && continue
    log "INFO: No active instance '$inst_name' found. Submitting DWS Flex Start request for ${gpu_count}x ${gpu_type} (${mach_type}) in ${z} (valid for 2h, max-run-duration=${MAX_RUN_DURATION}, until=${END_DATE})..."

    gcloud compute instances create "$inst_name" \
      --project="$PROJECT" \
      --zone="$z" \
      --machine-type="$mach_type" \
      --image-family="$IMAGE_FAMILY" \
      --image-project="$IMAGE_PROJECT" \
      --provisioning-model=FLEX_START \
      --max-run-duration="$MAX_RUN_DURATION" \
      --request-valid-for-duration=2h \
      --instance-termination-action=DELETE \
      --maintenance-policy=TERMINATE \
      --reservation-affinity=none >> "$LOG_FILE" 2>&1

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
      log "SUCCESS: Flex request submitted successfully for '$inst_name' (${gpu_count}x ${gpu_type}) in ${z}."
      return 0
    else
      log "WARNING: gcloud command failed for '$inst_name' in ${z} with exit code $exit_code."
    fi
  done

  log "ERROR: Failed to submit DWS Flex Start request for '$inst_name' (${gpu_count}x ${gpu_type}) across zones: ${ZONE_LIST}."
  return 1
}

log "=== Cron run started (Profile: $GPU_PROFILE | Zones: $ZONE_LIST | Until: $END_DATE | Max Lease: $MAX_RUN_DURATION) ==="

OVERALL_EXIT=0

case "$GPU_PROFILE" in
  both)
    provision_or_check_instance "$A100_INSTANCE_NAME" "$A100_MACHINE_TYPE" "NVIDIA_A100" "2" || OVERALL_EXIT=1
    provision_or_check_instance "$H100_INSTANCE_NAME" "$H100_MACHINE_TYPE" "NVIDIA_H100" "2" || OVERALL_EXIT=1
    ;;
  a100)
    provision_or_check_instance "${CUSTOM_INSTANCE_NAME:-$A100_INSTANCE_NAME}" "${CUSTOM_MACHINE_TYPE:-$A100_MACHINE_TYPE}" "NVIDIA_A100" "2" || OVERALL_EXIT=1
    ;;
  h100)
    provision_or_check_instance "${CUSTOM_INSTANCE_NAME:-$H100_INSTANCE_NAME}" "${CUSTOM_MACHINE_TYPE:-$H100_MACHINE_TYPE}" "NVIDIA_H100" "2" || OVERALL_EXIT=1
    ;;
  custom)
    provision_or_check_instance "$CUSTOM_INSTANCE_NAME" "$CUSTOM_MACHINE_TYPE" "CUSTOM_ACCELERATOR" "1" || OVERALL_EXIT=1
    ;;
  *)
    log "ERROR: Invalid --gpu-profile '$GPU_PROFILE'. Must be 'both', 'a100', 'h100', or 'custom'."
    exit 1
    ;;
esac

exit $OVERALL_EXIT
