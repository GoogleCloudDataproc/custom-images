#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS-IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This script loads and validates environment variables from env.json

if [[ -z "${ENV_JSON_PATH:-}" ]]; then
  ENV_JSON_PATH="env.json"
fi

if [[ -z "${DATAPROC_EVOLUTION_DIR:-}" ]]; then
  # Traverse upwards from env.sh's directory to resolve the repository root
  # containing both custom-images and cloud-dataproc, bypassing nested git boundaries.
  current_dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
  while [[ "${current_dir}" != "/" ]]; do
    if [[ -d "${current_dir}/custom-images" && -d "${current_dir}/cloud-dataproc" ]]; then
      export DATAPROC_EVOLUTION_DIR="${current_dir}"
      break
    fi
    current_dir=$(dirname "${current_dir}")
  done
  if [[ -z "${DATAPROC_EVOLUTION_DIR:-}" ]]; then
    echo "ERROR: Cannot resolve dataproc-evolution repository root from ${BASH_SOURCE[0]}." >&2
    exit 1
  fi
fi

if [[ ! -f "${ENV_JSON_PATH}" ]]; then
  echo "Error: ${ENV_JSON_PATH} not found. Please create it by copying env.json.sample"
  exit 1
fi

# Load variables
PROJECT_ID="$(jq       -r .PROJECT_ID           "${ENV_JSON_PATH}")"
PURPOSE="$(jq          -r .PURPOSE              "${ENV_JSON_PATH}")"
BUCKET="$(jq           -r .BUCKET               "${ENV_JSON_PATH}")"
TEMP_BUCKET="$(jq      -r .TEMP_BUCKET          "${ENV_JSON_PATH}")"
ZONE="$(jq             -r .ZONE                 "${ENV_JSON_PATH}")"
SUBNET="$(jq           -r .SUBNET               "${ENV_JSON_PATH}")"
HIVE_NAME="$(jq        -r .HIVE_INSTANCE_NAME   "${ENV_JSON_PATH}")"
HIVEDB_PW_URI="$(jq    -r .DB_HIVE_PASSWORD_URI "${ENV_JSON_PATH}")"
SECRET_NAME="$(jq      -r .SECRET_NAME          "${ENV_JSON_PATH}")"
KMS_KEY_URI="$(jq      -r .KMS_KEY_URI          "${ENV_JSON_PATH}")"
PRINCIPAL_USER="$(jq   -r .PRINCIPAL            "${ENV_JSON_PATH}")"
DOMAIN="$(jq -r .DOMAIN               "${ENV_JSON_PATH}")"
IMAGE_VERSION="$(jq    -r .IMAGE_VERSION        "${ENV_JSON_PATH}")"
CUSTOMIZATION_SCRIPT="$(jq -r .CUSTOMIZATION_SCRIPT  "${ENV_JSON_PATH}")"

SWP_IP="$(jq -r .SWP_IP "${ENV_JSON_PATH}")"; [[ "${SWP_IP}" == "null" ]] && SWP_IP=""
SWP_PORT="$(jq -r .SWP_PORT "${ENV_JSON_PATH}")"; [[ "${SWP_PORT}" == "null" ]] && SWP_PORT=""
PROXY_CERT_GCS_PATH="$(jq -r .PROXY_CERT_GCS_PATH "${ENV_JSON_PATH}")"; [[ "${PROXY_CERT_GCS_PATH}" == "null" ]] && PROXY_CERT_GCS_PATH=""

# Validate all required variables from env.json
missing_vars=()
required_vars=(PROJECT_ID PURPOSE BUCKET TEMP_BUCKET ZONE SUBNET PRINCIPAL_USER DOMAIN IMAGE_VERSION CUSTOMIZATION_SCRIPT)
for var in "${required_vars[@]}"; do
  if [[ "$(eval echo "${!var}")" == "null" ]]; then
    missing_vars+=("${var}")
  fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
  echo "Error: The following required variables are not defined in ${ENV_JSON_PATH}:"
  i=1
  for var in "${missing_vars[@]}"; do
    echo "  - ${var} [${i}]"
    i=$((i + 1))
  done
  echo
  echo "Footnotes:"
  i=1
  for var in "${missing_vars[@]}"; do
    echo "  [${i}] Please add the '${var}' key and a valid value to your ${ENV_JSON_PATH} file."
    i=$((i + 1))
  done
  exit 1
fi

export PROJECT_ID PURPOSE BUCKET TEMP_BUCKET ZONE SUBNET HIVE_NAME HIVEDB_PW_URI SECRET_NAME KMS_KEY_URI PRINCIPAL_USER DOMAIN IMAGE_VERSION CUSTOMIZATION_SCRIPT SWP_IP SWP_PORT PROXY_CERT_GCS_PATH

PRINCIPAL="${PRINCIPAL_USER}@${DOMAIN}"
export PRINCIPAL

region="$(echo "${ZONE}" | perl -pe 's/-[a-z]+$//')"
export region

SA_NAME="sa-${PURPOSE}"
if [[ "${PROJECT_ID}" =~ ":" ]] ; then
  GSA="${SA_NAME}@${PROJECT_ID#*:}.${PROJECT_ID%:*}.iam.gserviceaccount.com"
else
  GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
fi
export SA_NAME GSA

# Setup main temp directory for the run
timestamp="${timestamp:-$(date "+%Y%m%d-%H%M%S")}"
export timestamp
REPRO_TMPDIR="/tmp/dataproc-repro/${timestamp}"
export REPRO_TMPDIR
mkdir -p "${REPRO_TMPDIR}"
SENTINEL_DIR="${REPRO_TMPDIR}/sentinels/general"
export SENTINEL_DIR
mkdir -p "${SENTINEL_DIR}"
