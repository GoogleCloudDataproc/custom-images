#!/bin/bash
#
# Helper script to destroy a debug VM created by create-debug-vm.sh
#

set -e

DEBUG="${DEBUG:-0}"
if (( DEBUG != 0 )); then
  set -x
fi

# Source environment variables
if [[ -f "$(dirname "$0")/../lib/env.sh" ]]; then
  source "$(dirname "$0")/../lib/env.sh"
else
  echo "ERROR: examples/secure-boot/lib/env.sh not found."
  exit 1
fi
if [[ -f "$(dirname "$0")/../lib/util.sh" ]]; then
  source "$(dirname "$0")/../lib/util.sh"
else
  echo "ERROR: examples/secure-boot/lib/util.sh not found."
  exit 1
fi

USAGE="Usage: bash $(basename "$0")"

if [[ -z "${IMAGE_VERSION}" ]]; then
  echo "ERROR: IMAGE_VERSION is not set in env.json."
  exit 1
fi
if [[ -z "${CUSTOMIZATION_SCRIPT}" ]]; then
  echo "ERROR: CUSTOMIZATION_SCRIPT is not set in env.json."
  exit 1
fi

INSTANCE_NAME="debug-$(echo "${IMAGE_VERSION}" | tr '.' '-')-$(basename "${CUSTOMIZATION_SCRIPT}" .sh | tr '.' '-' | tr '_' '-')"

echo "Attempting to delete instance: ${INSTANCE_NAME}"
echo "Project: ${PROJECT_ID}, Zone: ${ZONE}"

if gcloud compute instances describe "${INSTANCE_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" > /dev/null 2>&1; then
  run_gcloud delete_instance gcloud compute instances delete "${INSTANCE_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" -q
  echo "Instance ${INSTANCE_NAME} deleted."
else
  echo "Instance ${INSTANCE_NAME} not found."
fi

GCS_SOURCES_PATH="gs://${BUCKET}/${INSTANCE_NAME}/sources"
echo "Cleaning up GCS path: ${GCS_SOURCES_PATH}"
run_gsutil rm_gcs gsutil -m rm -r "${GCS_SOURCES_PATH}" || echo "GCS path not found, continuing..."
