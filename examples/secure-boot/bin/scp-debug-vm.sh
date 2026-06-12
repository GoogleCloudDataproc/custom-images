#!/bin/bash
#
# Helper script to SCP files to the /tmp directory of a debug VM
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

USAGE="Usage: bash $(basename "$0") <local-path>"

if [[ -z "${IMAGE_VERSION}" ]]; then
  echo "ERROR: IMAGE_VERSION is not set in env.json."
  exit 1
fi
if [[ -z "${CUSTOMIZATION_SCRIPT}" ]]; then
  echo "ERROR: CUSTOMIZATION_SCRIPT is not set in env.json."
  exit 1
fi

LOCAL_PATH="${1}"
if [[ -z "${LOCAL_PATH}" ]]; then
  echo "ERROR: Missing local path argument."
  echo "${USAGE}"
  exit 1
fi

if [[ ! -e "${LOCAL_PATH}" ]]; then
  echo "ERROR: Local path not found: ${LOCAL_PATH}"
  exit 1
fi

INSTANCE_NAME="debug-$(echo "${IMAGE_VERSION}" | tr '.' '-')-$(basename "${CUSTOMIZATION_SCRIPT}" .sh | tr '.' '-' | tr '_' '-')"

echo "Attempting to SCP '${LOCAL_PATH}' to ${INSTANCE_NAME}:/tmp/"
echo "Project: ${PROJECT_ID}, Zone: ${ZONE}"

gcloud compute scp --recurse --zone "${ZONE}" --project "${PROJECT_ID}" --tunnel-through-iap "${LOCAL_PATH}" "${INSTANCE_NAME}:/tmp/"

echo "File/directory copied successfully to ${INSTANCE_NAME}:/tmp/$(basename "${LOCAL_PATH}")"
