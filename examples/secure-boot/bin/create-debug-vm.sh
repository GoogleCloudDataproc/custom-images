#!/bin/bash

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

FORCE_DELETE=0
USE_PROXY=0
USAGE="Usage: bash $(basename "$0") [-f] [-p]"

# Parse options
while getopts "fp" opt; do
  case ${opt} in
    f ) FORCE_DELETE=1 ;;
    p ) USE_PROXY=1 ;;
    \? ) echo "${USAGE}" >&2; exit 1 ;;
  esac
done
shift $((OPTIND -1))

if [[ -z "${IMAGE_VERSION}" ]]; then
  echo "ERROR: IMAGE_VERSION is not set in env.json."
  exit 1
fi
if [[ -z "${CUSTOMIZATION_SCRIPT}" ]]; then
  echo "ERROR: CUSTOMIZATION_SCRIPT is not set in env.json."
  exit 1
fi

INSTANCE_NAME="debug-$(echo "${IMAGE_VERSION}" | tr '.' '-')-$(basename "${CUSTOMIZATION_SCRIPT}" .sh | tr '.' '-' | tr '_' '-')"

# Override PURPOSE to a fixed value for the service account name
SA_NAME="sa-tf-pre-init"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

GCS_SOURCES_PATH="gs://${BUCKET}/${INSTANCE_NAME}/sources"
CACHE_FILE="/tmp/latest_dataproc_$(echo "${IMAGE_VERSION}" | tr './-' '_').txt"
CACHE_TTL_SECONDS=$((24 * 60 * 60)) # Cache for 1 day

if [[ "${FORCE_DELETE}" -eq 1 ]]; then
  rm -f "${CACHE_FILE}"
fi

# Determine Dataproc Image
if [[ -n "${DATAPROC_IMAGE:-}" ]]; then
  echo "Using image from ENV: ${DATAPROC_IMAGE}"
elif [[ -f "${CACHE_FILE}" ]] && [[ $(($(date +%s) - $(stat -c %Y "${CACHE_FILE}"))) -lt "${CACHE_TTL_SECONDS}" ]]; then
  DATAPROC_IMAGE=$(cat "${CACHE_FILE}")
  echo "Using cached image: ${DATAPROC_IMAGE}"
else
  echo "DATAPROC_IMAGE not set or cache stale, querying for the latest ${IMAGE_VERSION} image..."
  IMAGE_PREFIX="dataproc-$(echo "${IMAGE_VERSION}" | sed -e 's/\./-/g' -e 's/-debian12/-deb12/g' -e 's/-debian11/-deb11/g' -e 's/-ubuntu22/-ubu22/g' -e 's/-rocky9/-roc9/g')"
  DATAPROC_IMAGE=$(gcloud compute images list --project cloud-dataproc \
    --filter="name:${IMAGE_PREFIX} AND status=READY" \
    --format="value(name)" | \
    grep -v "eap" | \
    sort -r | \
    head -n 1)
  if [[ -z "${DATAPROC_IMAGE}" ]]; then
    echo "ERROR: Could not find a suitable ${IMAGE_VERSION} image."
    exit 1
  fi
  echo "${DATAPROC_IMAGE}" > "${CACHE_FILE}"
  echo "Using new image: ${DATAPROC_IMAGE} (cached to ${CACHE_FILE})"
fi

# Check instance existence and handle --force
if gcloud compute instances describe "${INSTANCE_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" > /dev/null 2>&1; then
  echo "Instance ${INSTANCE_NAME} already exists."
  if [[ "${FORCE_DELETE}" -eq 1 ]]; then
    echo "Deleting existing instance due to --force flag..."
    run_gcloud delete_instance gcloud compute instances delete "${INSTANCE_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" -q
    echo "Instance deleted."
  else
    echo "ERROR: Instance exists. Use -f to delete and recreate."
    exit 1
  fi
else
  echo "Instance ${INSTANCE_NAME} not found, proceeding."
fi

# Clean up GCS path
run_gsutil rm_gcs gsutil -m rm -r "${GCS_SOURCES_PATH}" || echo "GCS path not found, continuing..."

# Upload scripts from local repo to GCS
REPO_ROOT="$(git rev-parse --show-toplevel)"
run_gsutil cp_run gsutil cp "${REPO_ROOT}/startup_script/run.sh" "${GCS_SOURCES_PATH}/run.sh"
run_gsutil cp_init gsutil cp "${REPO_ROOT}/${CUSTOMIZATION_SCRIPT}" "${GCS_SOURCES_PATH}/init_actions.sh"
run_gsutil cp_env gsutil cp "${REPO_ROOT}/examples/secure-boot/lib/env.sh" "${GCS_SOURCES_PATH}/env.sh"
run_gsutil cp_util gsutil cp "${REPO_ROOT}/examples/secure-boot/lib/util.sh" "${GCS_SOURCES_PATH}/util.sh"
run_gsutil cp_proxy gsutil cp "${REPO_ROOT}/startup_script/gce-proxy-setup.sh" "${GCS_SOURCES_PATH}/gce-proxy-setup.sh"

if [[ "${USE_PROXY}" -eq 1 ]]; then
  # Resolve path to cloud-dataproc/gcloud/env.json relative to the authoritative repository root
  # already resolved and exported by env.sh.
  GCLOUD_ENV_JSON="${DATAPROC_EVOLUTION_DIR}/cloud-dataproc/gcloud/env.json"
  if [[ ! -f "${GCLOUD_ENV_JSON}" ]]; then
    echo "ERROR: cloud-dataproc/gcloud/env.json not found. Cannot resolve SWP proxy configurations." >&2
    exit 1
  fi
  SWP_IP=$(jq -r .SWP_IP "${GCLOUD_ENV_JSON}")
  SWP_PORT=$(jq -r .SWP_PORT "${GCLOUD_ENV_JSON}")
  if [[ -z "${SWP_IP}" || "${SWP_IP}" == "null" || -z "${SWP_PORT}" || "${SWP_PORT}" == "null" ]]; then
    echo "ERROR: SWP_IP or SWP_PORT is not configured in cloud-dataproc/gcloud/env.json." >&2
    exit 1
  fi
  echo "INFO: Enabling SWP Proxy Egress: ${SWP_IP}:${SWP_PORT}" >&2
fi

declare -a METADATA_ARRAY=(
  "VmDnsSetting=ZonalOnly"
  "shutdown-timer-in-sec=86400" # 1 day timer for debugging
  "custom-sources-path=${GCS_SOURCES_PATH}"
  "dataproc-region=${region}"
  "dataproc_dataproc_version=${IMAGE_VERSION}"
  "invocation-type=custom-images"
  "dataproc-temp-bucket=${TEMP_BUCKET}"
)

if [[ "${USE_PROXY}" -eq 1 ]]; then
  METADATA_ARRAY+=(
    "http-proxy=${SWP_IP}:${SWP_PORT}"
    "https-proxy=${SWP_IP}:${SWP_PORT}"
    "proxy-uri=${SWP_IP}:${SWP_PORT}"
    "no-proxy=metadata.google.internal,${PROJECT_ID}.svc.id.goog"
  )
fi

# Use a custom delimiter (^;^) to allow commas in metadata values (like no-proxy)
# This prevents gcloud from splitting on commas inside the no-proxy value.
METADATA_STRING="^;^$(IFS=';'; echo "${METADATA_ARRAY[*]}")"

# Create the instance
declare -a gcloud_create_args=(
    gcloud compute instances create "${INSTANCE_NAME}"
    --project "${PROJECT_ID}"
    --zone "${ZONE}"
    --machine-type n1-standard-2
    --image "${DATAPROC_IMAGE}"
    --image-project cloud-dataproc
    --boot-disk-size 30G
    --boot-disk-type pd-ssd
    --scopes "https://www.googleapis.com/auth/cloud-platform"
    --service-account "${GSA}"
    --subnet "${SUBNET}"
    --metadata="${METADATA_STRING}"
)
run_gcloud create_instance "${gcloud_create_args[@]}"

echo "Instance ${INSTANCE_NAME} created."

SERIAL_LOG_FILE="${REPRO_TMPDIR}/serial_${INSTANCE_NAME}.log"
echo "Tailing serial port output to ${SERIAL_LOG_FILE} in the background..."
gcloud compute instances tail-serial-port-output "${INSTANCE_NAME}" --zone "${ZONE}" --project "${PROJECT_ID}" > "${SERIAL_LOG_FILE}" 2>&1 &
TAIL_PID=$!
echo "Tail PID: ${TAIL_PID}"
echo "To stop tailing: kill ${TAIL_PID}"

echo "To SSH into the instance:"
echo "bash $(dirname "$0")/ssh-debug-vm.sh"
