#!/bin/bash
#
# Workstation-side orchestrator for idempotent, interactive image customization.
# 
# Workflow:
# 1. Detects or provisions the GCE debug VM.
# 2. Checks if a customization screen session is already running on the VM.
# 3. If running: Instantly attaches the workstation terminal to the active session.
# 4. If not running: Syncs the latest local code to GCS, triggers a remote
#    background launch, and immediately attaches to the live session.

set -euo pipefail

DEBUG="${DEBUG:-0}"
if (( DEBUG != 0 )); then
  set -x
fi
# --- Parse Options ---
CLEAN_BUILD=0
USE_PROXY=0
FORCE_APPLY=0
FORCE_DELETE=0
USAGE="Usage: bash \$(basename "\$0") [-c] [-p] [-r]"

while getopts "cpr" opt; do
  case ${opt} in
    c )
      CLEAN_BUILD=1
      FORCE_APPLY=1
      ;;
    p ) USE_PROXY=1 ;;
    r ) FORCE_DELETE=1 ;;
    \? ) echo "${USAGE}" >&2; exit 1 ;;
  esac
done
shift $((OPTIND -1))
# --- Source Environment & Helpers ---
BIN_DIR=$(dirname "$(readlink -f "$0")")
ENV_SH="${BIN_DIR}/../lib/env.sh"
UTIL_SH="${BIN_DIR}/../lib/util.sh"

if [[ -f "${ENV_SH}" && -f "${UTIL_SH}" ]]; then
  source "${ENV_SH}"
  source "${UTIL_SH}"
else
  echo "ERROR: Helper libraries not found in examples/secure-boot/lib/." >&2
  exit 1
fi

if [[ -z "${IMAGE_VERSION}" || -z "${CUSTOMIZATION_SCRIPT}" ]]; then
  echo "ERROR: IMAGE_VERSION or CUSTOMIZATION_SCRIPT not set in env.json." >&2
  exit 1
fi

# Generate the unique instance name based on configuration
INSTANCE_NAME="debug-$(echo "${IMAGE_VERSION}" | tr '.' '-')-$(basename "${CUSTOMIZATION_SCRIPT}" .sh | tr '.' '-' | tr '_' '-')"
GCS_SOURCES_PATH="gs://${BUCKET}/${INSTANCE_NAME}/sources"

echo "DEBUG: Target Instance: ${INSTANCE_NAME}" >&2
echo "DEBUG: GCS Staging Path: ${GCS_SOURCES_PATH}" >&2

# ========================================================================
# Step 1: Ensure GCE Instance is Online
# ========================================================================
VM_WAS_CREATED="false"
if ! gcloud compute instances describe "${INSTANCE_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" &>/dev/null || [[ "${FORCE_DELETE}" -eq 1 ]]; then
  if [[ "${FORCE_DELETE}" -eq 1 ]]; then
    echo "INFO: Recreation forced (-r). Re-provisioning debug VM ${INSTANCE_NAME}..." >&2
  else
    echo "INFO: Debug VM ${INSTANCE_NAME} does not exist. Provisioning a new instance..." >&2
  fi
  # Call the pre-existing provisioner (cold start)
  declare -a create_args=()
  if [[ "${FORCE_DELETE}" -eq 1 ]]; then
    create_args+=("-f")
  fi
  if [[ "${USE_PROXY}" -eq 1 ]]; then
    create_args+=("-p")
  fi
  bash "${BIN_DIR}/create-debug-vm.sh" "${create_args[@]}"
  VM_WAS_CREATED="true"
else
  echo "INFO: Active debug VM ${INSTANCE_NAME} detected. Re-using instance." >&2
fi

if [[ "${VM_WAS_CREATED}" == "true" ]]; then
  echo "INFO: Waiting for GCE Identity-Aware Proxy (IAP) tunnel to sync..." >&2
  set +e
  IAP_READY=1
  for i in {1..36}; do
    if ssh -o ControlMaster=no -o ConnectTimeout=3 -o BatchMode=yes "${INSTANCE_NAME}" "uptime" &>/dev/null; then
      IAP_READY=0
      break
    fi
    echo "DEBUG: Waiting for IAP tunnel (+5s)..." >&2
    sleep 5
  done
  set -e
  
  if [[ ${IAP_READY} -ne 0 ]]; then
    echo "ERROR: Timeout waiting for IAP tunnel to sync. VM is online but unreachable." >&2
    exit 1
  fi
  echo "INFO: IAP tunnel is active and accepting connections." >&2
fi

# ========================================================================
# Step 1.1: Dynamically Inject SWP Proxy Metadata (Optional Warm Start)
# ========================================================================
if [[ "${USE_PROXY}" -eq 1 ]]; then
  # Resolve path to cloud-dataproc/gcloud/env.json relative to the authoritative repository root
  # already resolved and exported by env.sh.
  GCLOUD_ENV_JSON="${DATAPROC_EVOLUTION_DIR}/cloud-dataproc/gcloud/env.json"
  if [[ -f "${GCLOUD_ENV_JSON}" ]]; then
    SWP_IP=$(jq -r .SWP_IP "${GCLOUD_ENV_JSON}")
    SWP_PORT=$(jq -r .SWP_PORT "${GCLOUD_ENV_JSON}")
    if [[ -n "${SWP_IP}" && "${SWP_IP}" != "null" && -n "${SWP_PORT}" && "${SWP_PORT}" != "null" ]]; then
      echo "INFO: Dynamically ensuring SWP Proxy metadata is set on the running VM..." >&2
      gcloud compute instances add-metadata "${INSTANCE_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --metadata="^;^http-proxy=${SWP_IP}:${SWP_PORT};https-proxy=${SWP_IP}:${SWP_PORT};proxy-uri=${SWP_IP}:${SWP_PORT};no-proxy=metadata.google.internal,${PROJECT_ID}.svc.id.goog" \
        --quiet
    else
      echo "ERROR: SWP_IP or SWP_PORT not found in cloud-dataproc/gcloud/env.json." >&2
      exit 1
    fi
  else
    echo "ERROR: cloud-dataproc/gcloud/env.json not found. Cannot resolve SWP proxy configurations." >&2
    exit 1
  fi
fi

# ========================================================================
# Step 1.2: Clean Build Artifacts & Sentinels (Optional)
# ========================================================================
if [[ "${CLEAN_BUILD}" -eq 1 ]]; then
  echo "INFO: Cleaning up all past build artifacts, active screen sessions, and sentinels on the VM..." >&2
  ssh -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=5 "${INSTANCE_NAME}" "
    screen -S customization -X quit 2>/dev/null || true
    sudo rm -rf /tmp/dataproc-repro
  " &>/dev/null || true
fi

# ========================================================================
# Step 2: Check if customization is already running in screen
# ========================================================================
echo "DEBUG: Checking VM for active customization screen session..." >&2
set +e
ssh -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=5 "${INSTANCE_NAME}" "screen -ls | grep -q customization" &>/dev/null
SCREEN_STATUS=$?
set -e

# ========================================================================
# Step 3: Branching Idempotent Execution
# ========================================================================
if [[ ${SCREEN_STATUS} -eq 0 ]]; then
  # ----------------------------------------------------------------------
  # CASE A: Customization is already running. Attach immediately.
  # ----------------------------------------------------------------------
  cat <<EOF >&2
========================================================================
   ATTACHING TO ACTIVE CUSTOMIZATION SESSION
========================================================================
An active customization build was detected running on the VM.
Connecting your terminal to the live screen session...

(To detach from screen and leave it running in the background, press:
 Ctrl+A followed by D)
========================================================================
EOF
  sleep 1
  
  # Connect and attach
  ssh -t "${INSTANCE_NAME}" screen -rxU customization
  
else
  # ----------------------------------------------------------------------
  # CASE B: Customization is not running. Sync, launch, and attach.
  # ----------------------------------------------------------------------
  echo "INFO: Customization is not active on the VM. Syncing latest code..." >&2

  # 1. Sync local workstation scripts to GCS staging using a single bulk upload
  echo "DEBUG: Syncing local assets to GCS: ${GCS_SOURCES_PATH}" >&2
  
  # Create a local staging directory in the temp folder for fast preparation
  LOCAL_STAGING="${REPRO_TMPDIR}/staging"
  mkdir -p "${LOCAL_STAGING}"
  
  # Cleanly resolve customization script path
  custom_script_path="${DATAPROC_EVOLUTION_DIR}/custom-images/${CUSTOMIZATION_SCRIPT}"
  
  # Stage all files locally (near-instantaneous)
  cp "${DATAPROC_EVOLUTION_DIR}/custom-images/startup_script/run.sh" "${LOCAL_STAGING}/run.sh"
  cp "${custom_script_path}" "${LOCAL_STAGING}/init_actions.sh"
  cp "${DATAPROC_EVOLUTION_DIR}/custom-images/examples/secure-boot/lib/env.sh" "${LOCAL_STAGING}/env.sh"
  cp "${DATAPROC_EVOLUTION_DIR}/custom-images/examples/secure-boot/lib/util.sh" "${LOCAL_STAGING}/util.sh"
  cp "${DATAPROC_EVOLUTION_DIR}/custom-images/examples/secure-boot/install-in-screen.sh" "${LOCAL_STAGING}/install-in-screen.sh"
  cp "${DATAPROC_EVOLUTION_DIR}/custom-images/startup_script/gce-proxy-setup.sh" "${LOCAL_STAGING}/gce-proxy-setup.sh"
  
  # Perform a single, parallelized bulk upload to GCS (minimizes connection overhead)
  gsutil -m cp -r "${LOCAL_STAGING}/*" "${GCS_SOURCES_PATH}/" >/dev/null

  echo "INFO: Launching customization on VM..." >&2

  # 2. SSH in, download GCS assets, and trigger the background screen launcher
  ssh -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=10 "${INSTANCE_NAME}" "
    GCS_PATH=\$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/custom-sources-path)
    rm -rf /tmp/sources
    mkdir -p /tmp/sources
    gsutil -m cp -r \"\${GCS_PATH}/*\" /tmp/sources/ >/dev/null
    chmod +x /tmp/sources/*.sh
    # Spawn the guest screen bootstrap wrapper in the background, passing FORCE_APPLY status
    nohup env FORCE_APPLY=${FORCE_APPLY} bash /tmp/sources/install-in-screen.sh /tmp/sources/init_actions.sh >/tmp/launcher.log 2>&1 &
    sleep 1
  "

  echo "DEBUG: Customization launched. Checking status in 2 seconds..." >&2
  sleep 2

  # 3. Check if the customization already completed instantly before attempting to attach
  set +e
  ssh -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=3 "${INSTANCE_NAME}" "[[ -f /tmp/sources/customization.exit ]]" &>/dev/null
  INSTANT_COMPLETED=$?
  set -e

  attach_success=0
  if [[ ${INSTANT_COMPLETED} -eq 0 ]]; then
    echo "INFO: Customization completed instantly on the VM. Skipping screen attachment." >&2
    attach_success=0
  else
    # Connect and attach the developer interactively to the newly spawned session (belongs to cjac, so no sudo!)
    set +e
    ssh -t "${INSTANCE_NAME}" screen -rxU customization
    attach_success=$?
    set -e
  fi

  # If we failed to attach (e.g., screen exited before we connected),
  # harvest the exit status and logs from the VM so the developer gets immediate feedback!
  if [[ ${attach_success} -ne 0 ]]; then
    echo "INFO: Customization session closed or exited early. Harvesting logs from VM..." >&2
    set +e
    # Fetch exit code
    exit_code=$(ssh -o BatchMode=yes "${INSTANCE_NAME}" "cat /tmp/sources/customization.exit" 2>/dev/null)
    has_exit=$?
    set -e
    
    if [[ ${has_exit} -eq 0 && -n "${exit_code}" ]]; then
      # Define ANSI colors for the local shell output
      GREEN='\033[0;32m'
      RED='\033[0;31m'
      NC='\033[0m'
      
      echo "========================================================================" >&2
      echo "   GUEST-SIDE EXECUTION LOG (Harvested from VM)" >&2
      echo "========================================================================" >&2
      ssh -o BatchMode=yes "${INSTANCE_NAME}" "cat /tmp/sources/customization-output.log" || true
      echo "========================================================================" >&2
      
      if [[ "${exit_code}" -eq 0 ]]; then
        echo -e "${GREEN}🎉 BUILD SUCCESSFUL (Exit Code: 0)${NC}" >&2
        exit 0
      else
        echo -e "${RED}❌ BUILD FAILED (Exit Code: ${exit_code})${NC}" >&2
        exit "${exit_code}"
      fi
    else
      echo "ERROR: Failed to attach to screen, and no exit status was recorded on the VM." >&2
      echo "This indicates the startup launcher crashed or failed to spawn the screen." >&2
      echo "See /tmp/launcher.log on the VM for details." >&2
      exit 1
    fi
  fi
fi

# ========================================================================
# Step 4: Validate Build Exit Status
# ========================================================================
echo "INFO: Customization session closed. Fetching build exit status from VM..." >&2

set +e
EXIT_CODE=$(ssh -o ControlMaster=no -o ConnectTimeout=5 "${INSTANCE_NAME}" "cat /tmp/sources/customization.exit" 2>/dev/null)
SSH_STATUS=$?
set -e

if [[ ${SSH_STATUS} -ne 0 || -z "${EXIT_CODE}" ]]; then
  # Check if the screen session is still active (meaning the developer detached)
  set +e
  screen_still_active=$(ssh -o ControlMaster=no -o ConnectTimeout=5 "${INSTANCE_NAME}" "screen -ls | grep -q customization" 2>/dev/null; echo $?)
  set -e
  
  if [[ ${screen_still_active} -eq 0 ]]; then
    cat <<EOF >&2
========================================================================
   ℹ️  DETACHED FROM ACTIVE CUSTOMIZATION
========================================================================
The customization build is still executing in the background on the VM.
To re-attach and monitor the live run later, simply run this script again:

  bash examples/secure-boot/bin/customize-in-screen.sh
========================================================================
EOF
    exit 0
  else
    echo "ERROR: Customization finished but exit status was not recorded on the VM." >&2
    exit 1
  fi
fi

# Trim whitespace
EXIT_CODE=$(echo "${EXIT_CODE}" | xargs)

if [[ "${EXIT_CODE}" == "0" ]]; then
  cat <<EOF >&2
========================================================================
   🎉 BUILD SUCCESSFUL
========================================================================
The customization script completed successfully with exit code 0!
You can now proceed to convert this VM to a custom image:

  gcloud compute instances stop ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID}
  gcloud compute images create [IMAGE_NAME] --source-disk=${INSTANCE_NAME} ...
========================================================================
EOF
  exit 0
else
  cat <<EOF >&2
========================================================================
   ❌ BUILD FAILED (Exit Code: ${EXIT_CODE})
========================================================================
The customization script failed inside the screen session.

DIAGNOSTICS & RETRY WORKFLOW:
1. View the full build log:
   ssh ${INSTANCE_NAME} "cat /tmp/sources/customization-output.log"

2. Hot-fix the script directly on the VM for instant testing:
   ssh ${INSTANCE_NAME}

3. Correct the local script on your workstation:
   Edit: ${CUSTOMIZATION_SCRIPT}

4. Retry the entire pipeline (this will sync your fix and restart the build):
   bash examples/secure-boot/bin/customize-in-screen.sh
========================================================================
EOF
  exit "${EXIT_CODE}"
fi
