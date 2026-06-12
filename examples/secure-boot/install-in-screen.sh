#!/bin/bash
#
# Bootstrap wrapper to run GCE image customization scripts inside a detached,
# inspectable screen session. This protects long-running builds from timeouts,
# allows real-time developer attachment, and ensures logs are still streamed
# to the serial console for the orchestrator.

set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TARGET_SCRIPT="${1:-${SCRIPT_DIR}/no-customization.sh}"

if [[ ! -f "${TARGET_SCRIPT}" ]]; then
  echo "ERROR: Target customization script ${TARGET_SCRIPT} not found." >&2
  exit 1
fi

echo "INFO: Preparing to run customization: ${TARGET_SCRIPT}" >&2

# --- Retrieve VM Details from Cache ---
# We use the local JSON cache to print the exact SSH command for the developer
CACHE_DIR="/dev/shm/metadata_cache"
PROJECT_ID="UNKNOWN_PROJECT"
ZONE="UNKNOWN_ZONE"
VM_NAME="UNKNOWN_VM"

if [[ -d "${CACHE_DIR}" ]]; then
  # Parse cached values using jq
  if [[ -f "${CACHE_DIR}/project_attributes.json" ]]; then
     PROJECT_ID=$(jq -r '.["project-id"] // "UNKNOWN_PROJECT"' "${CACHE_DIR}/project_attributes.json")
  fi
  # We can also query standard GCE metadata paths from the VM
  # (These are not attributes, so they might not be in the cache, but they are safe to query once)
  VM_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name || echo "UNKNOWN_VM")
  ZONE_FULL=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone || echo "UNKNOWN_ZONE")
  ZONE="${ZONE_FULL##*/}"
fi

# --- Print Developer Diagnostic Instructions ---
# This goes to stderr/console so it is visible in the GCE serial port logs immediately
cat <<EOF >&2
========================================================================
   CUSTOMIZATION SCREEN AUTOMATION ACTIVE
========================================================================
The customization script is executing inside a detached screen session.

To attach to the live session and monitor/debug in real-time, 
run the following command from your workstation:

  gcloud compute ssh ${VM_NAME} \\
    --project=${PROJECT_ID} \\
    --zone=${ZONE} \\
    --tunnel-through-iap \\
    --command="screen -rxU customization"

========================================================================
EOF

# --- Launch Customization in Screen ---
LOG_FILE="/tmp/sources/customization-output.log"
EXIT_FILE="/tmp/sources/customization.exit"
touch "${LOG_FILE}"
rm -f "${EXIT_FILE}"

echo "INFO: Spawning screen session 'customization'..." >&2

# We spawn the screen as the normal user, but run the inner payload as root via sudo
screen -dmS customization sudo FORCE_APPLY="${FORCE_APPLY:-0}" bash -c "
  # Define ANSI colors inside the root shell
  BLUE='\\033[0;34m'
  GREEN='\\033[0;32m'
  YELLOW='\\033[1;33m'
  RED='\\033[0;31m'
  NC='\\033[0m'

  set +e
  
  # 1. Source guest-side harvester libraries inside the root shell (defines get_metadata_attribute)
  source /tmp/sources/gce-proxy-setup.sh
  set +e
  
  # 2. Globally export all metadata helper functions to match Dataproc environment fidelity
  export -f get_metadata_attribute get_metadata_value print_metadata_value print_metadata_value_if_exists get_cached_state os_id is_debuntu is_rocky
  
  # 3. Wait for developer to attach (guarantees visibility for fast scripts/probes)
  echo -e \"\${YELLOW}INFO: Spawning screen. Waiting 5 seconds for developer to attach...\${NC}\" >&2
  for i in 5 4 3 2 1; do
    echo -e \"\${YELLOW}Starting customization in \${i} seconds...\${NC}\" >&2
    sleep 1
  done
  
  # 4. Execute the target script with a clean colored header
  echo -e \"\${BLUE}========================================================================\${NC}\"
  echo -e \"\${BLUE}   LAUNCHING CUSTOMIZATION SCRIPT: ${TARGET_SCRIPT}\${NC}\"
  echo -e \"\${BLUE}========================================================================\${NC}\"
  echo ''
  
  bash ${TARGET_SCRIPT} 2>&1 | tee ${LOG_FILE}
  EXIT_CODE=\${PIPESTATUS[0]}
  
  # 5. Print clean colored final status indicator
  echo ''
  echo -e \"\${BLUE}========================================================================\${NC}\"
  if [[ \${EXIT_CODE} -eq 0 ]]; then
    echo -e \"\${GREEN}   🎉 CUSTOMIZATION SUCCESSFUL (Exit Code: 0)\${NC}\"
  else
    echo -e \"\${RED}   ❌ CUSTOMIZATION FAILED (Exit Code: \${EXIT_CODE})\${NC}\"
  fi
  echo -e \"\${BLUE}========================================================================\${NC}\"
  
  echo \${EXIT_CODE} > ${EXIT_FILE}
  chmod 644 ${EXIT_FILE} ${LOG_FILE} 2>/dev/null || true
"

# --- Wait and Stream Logs ---
# We find the PID of the newly spawned screen session
sleep 2
SCREEN_PID=$(screen -ls | grep customization | awk '{print $1}' | cut -d. -f1 || echo "")

if [[ -z "${SCREEN_PID}" ]]; then
  # If the screen is gone, check if it already completed instantly
  if [[ -f "${EXIT_FILE}" ]]; then
    echo "INFO: Customization completed instantly." >&2
    exit 0
  fi
  echo "ERROR: Failed to spawn screen session." >&2
  exit 1
fi

echo "DEBUG: Screen session spawned with PID ${SCREEN_PID}. Streaming logs to serial port..." >&2

# Start tailing the log file in the background to stream to GCE serial port
tail -f "${LOG_FILE}" &
TAIL_PID=$!

# Block until the screen session exits
while kill -0 "${SCREEN_PID}" 2>/dev/null; do
  sleep 5
done

# Stop the background tailing
kill "${TAIL_PID}" &>/dev/null || true

# --- Propagate Exit Code ---
# Read the exit code written by the script inside the screen session
if [[ -f "${EXIT_FILE}" ]]; then
  EXIT_CODE=$(cat "${EXIT_FILE}")
  echo "INFO: Customization script finished with exit code ${EXIT_CODE}" >&2
  
  if [[ "${EXIT_CODE}" -eq 0 ]]; then
    echo "startup-script: BuildSucceeded: Customization complete." >&2
  else
    echo "startup-script: BuildFailed: Customization failed." >&2
  fi
  exit "${EXIT_CODE}"
else
  echo "ERROR: Customization finished but exit code was not recorded." >&2
  exit 1
fi
