#!/bin/bash

# Default Log File
LOG_FILE="/tmp/retry-flex-cron.log"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -n, --name           Instance name"
  echo "  -p, --project        GCP Project ID"
  echo "  -z, --zone           GCP Zone"
  echo "  -m, --machine-type   Machine type (e.g., tpu7x-standard-4t)"
  echo "  -f, --image-family   Image family"
  echo "  -i, --image-project  Image project"
  echo "  -l, --log-file       Log file path (default: /tmp/retry-flex-cron.log)"
  echo "  -h, --help           Show this help message"
  exit 1
}

# Helper function to write to the log file with timestamps
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# 1. Define internal defaults
DEFAULT_INSTANCE_NAME="tpu-v7x-flex"
DEFAULT_PROJECT=""
DEFAULT_ZONE="us-central1-c"
DEFAULT_MACHINE_TYPE="tpu7x-standard-4t"
DEFAULT_IMAGE_FAMILY="ubuntu-accel-2404-amd64-tpu-tpu7x"
DEFAULT_IMAGE_PROJECT="ubuntu-os-accelerator-images"

# 2. Parse command-line arguments (Flags)
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -n|--name) INSTANCE_NAME_ARG="$2"; shift ;;
    -p|--project) PROJECT_ARG="$2"; shift ;;
    -z|--zone) ZONE_ARG="$2"; shift ;;
    -m|--machine-type) MACHINE_TYPE_ARG="$2"; shift ;;
    -f|--image-family) IMAGE_FAMILY_ARG="$2"; shift ;;
    -i|--image-project) IMAGE_PROJECT_ARG="$2"; shift ;;
    -l|--log-file) LOG_FILE="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "Error: Unknown parameter passed: $1" >> "$LOG_FILE"; exit 1 ;;
  esac
  shift
done

# 3. Assign values: Check argument first, fallback to default
INSTANCE_NAME="${INSTANCE_NAME_ARG:-$DEFAULT_INSTANCE_NAME}"
PROJECT="${PROJECT_ARG:-$DEFAULT_PROJECT}"
ZONE="${ZONE_ARG:-$DEFAULT_ZONE}"
MACHINE_TYPE="${MACHINE_TYPE_ARG:-$DEFAULT_MACHINE_TYPE}"
IMAGE_FAMILY="${IMAGE_FAMILY_ARG:-$DEFAULT_IMAGE_FAMILY}"
IMAGE_PROJECT="${IMAGE_PROJECT_ARG:-$DEFAULT_IMAGE_PROJECT}"

# 4. Validate that none of the values ended up completely empty
if [ -z "$INSTANCE_NAME" ] || [ -z "$PROJECT" ] || [ -z "$ZONE" ] || \
   [ -z "$MACHINE_TYPE" ] || [ -z "$IMAGE_FAMILY" ] || [ -z "$IMAGE_PROJECT" ]; then
  log "ERROR: One or more required configuration variables are missing."
  exit 1
fi

log "--- Cron run started for $INSTANCE_NAME in $ZONE ---"

# 5. Check if the instance already exists and get its status
STATUS=$(gcloud compute instances describe "$INSTANCE_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --format="value(status)" 2>/dev/null)
  
if [ -n "$STATUS" ]; then
  if [ "$STATUS" = "RUNNING" ]; then
    log "SUCCESS: TPU v7x instance '$INSTANCE_NAME' is RUNNING! No action needed."
    exit 0
  else
    log "INFO: Instance exists with status: $STATUS. Flex request is active in queue. Exiting."
    exit 0
  fi
fi

# 6. Submit DWS Flex request if no instance exists
log "INFO: No instance found. Submitting DWS Flex request (valid for 2 hours)..."

# Note: gcloud stdout and stderr are redirected to the log file
gcloud compute instances create "$INSTANCE_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --image-family="$IMAGE_FAMILY" \
  --image-project="$IMAGE_PROJECT" \
  --provisioning-model=FLEX_START \
  --max-run-duration=7d \
  --request-valid-for-duration=2h \
  --instance-termination-action=DELETE \
  --maintenance-policy=TERMINATE \
  --reservation-affinity=none >> "$LOG_FILE" 2>&1

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  log "SUCCESS: Flex request submitted successfully."
else
  log "ERROR: gcloud command failed with exit code $EXIT_CODE."
fi
