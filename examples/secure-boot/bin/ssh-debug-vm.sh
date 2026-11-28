#!/bin/bash
#
# Helper script to SSH into a debug VM created by create-debug-vm.sh
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

USAGE="Usage: bash $(basename "$0") [command...]"

if [[ -z "${IMAGE_VERSION}" ]]; then
  echo "ERROR: IMAGE_VERSION is not set in env.json."
  exit 1
fi
if [[ -z "${CUSTOMIZATION_SCRIPT}" ]]; then
  echo "ERROR: CUSTOMIZATION_SCRIPT is not set in env.json."
  exit 1
fi

COMMAND_TO_RUN=("$@")

INSTANCE_NAME="debug-$(echo "${IMAGE_VERSION}" | tr '.' '-')-$(basename "${CUSTOMIZATION_SCRIPT}" .sh | tr '.' '-' | tr '_' '-')"

echo "Attempting to SSH into instance: ${INSTANCE_NAME}"
echo "Project: ${PROJECT_ID}, Zone: ${ZONE}"

declare -a gcloud_ssh_args
gcloud_ssh_args=(
  gcloud compute ssh
  --zone "${ZONE}"
  --project "${PROJECT_ID}"
  --tunnel-through-iap
  "${INSTANCE_NAME}"
)

if [[ ${#COMMAND_TO_RUN[@]} -eq 0 ]]; then
  # Interactive session
  gcloud_ssh_args+=( -- -t -o ConnectTimeout=60 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -AY )
else
  # Command execution
  gcloud_ssh_args+=( --command "${COMMAND_TO_RUN[*]}" )
fi

"${gcloud_ssh_args[@]}"
