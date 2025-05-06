#!/bin/bash

# Copyright 2024 Google LLC and contributors
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
# This script creates a custom image pre-loaded with
#
# GPU drivers + cuda + rapids + cuDNN + nccl + tensorflow + pytorch + ipykernel + numba

# To run the script, the following will bootstrap
#
# git clone git@github.com:GoogleCloudDataproc/custom-images
# cd custom-images
# git checkout 2025.02
# cp examples/secure-boot/env.json.sample env.json
# vi env.json
# docker build -f Dockerfile -t custom-images-builder:latest .
# time docker run -it custom-images-builder:latest bash examples/secure-boot/build-current-images.sh


set -ex

function execute_with_retries() (
  set +x
  local -r cmd="$*"
  local install_log="${tmpdir}/install.log"

  for ((i = 0; i < 3; i++)); do
    set -x
    eval "$cmd" > "${install_log}" 2>&1 && retval=$? || { retval=$? ; cat "${install_log}" ; }
    set +x
    if [[ $retval == 0 ]] ; then return 0 ; fi
    sleep 5
  done
  return 1
)

function configure_service_account() {
  # Create service account
  if gcloud iam service-accounts list --filter email="${GSA}" 2>&1 | grep -q 'Listed 0 items.' ; then
    # Create service account for this purpose
    echo "creating pre-init customization service account ${GSA}"
    gcloud iam service-accounts create "${SA_NAME}" \
      --description="Service account for pre-init customization" \
      --display-name="${SA_NAME}"
  fi

  if [[ -d tls ]] ; then mv tls "tls-$(date +%s)" ; fi
  eval "$(bash examples/secure-boot/create-key-pair.sh)"

  execute_with_retries gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/dataproc.worker" \
    --condition=None

  # Grant the service account access to buckets in this project
  # TODO: this is over-broad and should be limited only to the buckets
  # used by these clusters
  for storage_object_role in 'User' 'Creator' 'Viewer' ; do
    execute_with_retries gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${GSA}" \
      --role="roles/storage.object${storage_object_role}" \
      --condition=None
  done

  for secret in "${public_secret_name}" "${private_secret_name}" ; do
    for sm_role in 'viewer' 'secretAccessor' ; do
      # Grant the service account permission to list the secret
      execute_with_retries gcloud secrets -q add-iam-policy-binding "${secret}" \
        --member="serviceAccount:${GSA}" \
        --role="roles/secretmanager.${sm_role}" \
        --condition=None
    done
  done

  execute_with_retries gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/compute.instanceAdmin.v1 \
    --condition=None

  execute_with_retries gcloud iam service-accounts add-iam-policy-binding "${GSA}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/iam.serviceAccountUser \
    --condition=None
}

function revoke_bindings() {
  execute_with_retries gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/dataproc.worker" \
    --condition=None

  # Revoke the service account's access to buckets in this project
  for storage_object_role in 'User' 'Creator' 'Viewer' ; do
    execute_with_retries gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${GSA}" \
      --role="roles/storage.object${storage_object_role}" \
      --condition=None
  done

  for secret in "${public_secret_name}" "${private_secret_name}" ; do
    # Revoke the service account's permission to list and access the secret
    for sm_role in 'viewer' 'secretAccessor' ; do
      execute_with_retries gcloud secrets -q remove-iam-policy-binding "${secret}" \
        --member="serviceAccount:${GSA}" \
        --role="roles/secretmanager.${sm_role}" \
        --condition=None
    done
  done

  execute_with_retries gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/compute.instanceAdmin.v1 \
    --condition=None

  execute_with_retries gcloud iam service-accounts remove-iam-policy-binding "${GSA}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/iam.serviceAccountUser \
    --condition=None
}


export DOMAIN="$(jq           -r .DOMAIN        env.json)"
export PROJECT_ID="$(jq       -r .PROJECT_ID    env.json)"
export PURPOSE="$(jq          -r .PURPOSE       env.json)"
export BUCKET="$(jq           -r .BUCKET        env.json)"
export SECRET_NAME="$(jq      -r .SECRET_NAME   env.json)"
export REGION="$(jq           -r .REGION        env.json)"
export ZONE="$(jq             -r .ZONE          env.json)"
export PRINCIPAL_USER="$(jq   -r .PRINCIPAL     env.json)"
export PRINCIPAL_DOMAIN="$(jq -r .DOMAIN        env.json)"
export PRINCIPAL="${PRINCIPAL_USER}@${PRINCIPAL_DOMAIN}"

echo -n "setting gcloud config..."
CURRENT_ACCOUNT="$(gcloud config get account)"
if [[ "${CURRENT_ACCOUNT}" != "${PRINCIPAL}" ]]; then
    echo "setting gcloud account"
    gcloud config set account "${PRINCIPAL}"
fi
CURRENT_PROJECT_ID="$(gcloud config get project)"
if [[ "${CURRENT_PROJECT_ID}" != "${PROJECT_ID}" ]]; then
    echo "setting gcloud project"
    gcloud config set project ${PROJECT_ID}
fi

gcloud auth login

CURRENT_COMPUTE_REGION="$(gcloud config get compute/region)"
if [[ "${CURRENT_COMPUTE_REGION}" != "${REGION}" ]]; then
    echo "setting compute region"
    gcloud config set compute/region "${REGION}"
fi
CURRENT_DATAPROC_REGION="$(gcloud config get dataproc/region)"
if [[ "${CURRENT_DATAPROC_REGION}" != "${REGION}" ]]; then
    echo "setting dataproc region"
    gcloud config set dataproc/region "${REGION}"
fi
CURRENT_COMPUTE_ZONE="$(gcloud config get compute/zone)"
if [[ "${CURRENT_COMPUTE_ZONE}" != "${ZONE}" ]]; then
    echo "setting compute zone"
    gcloud config set compute/zone "${ZONE}"
fi
SA_NAME="sa-${PURPOSE}"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
if [[ "${PROJECT_ID}" =~ ":" ]] ; then
  GSA="${SA_NAME}@${PROJECT_ID#*:}.${PROJECT_ID%:*}.iam.gserviceaccount.com"
else
   GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
fi

readonly timestamp="$(date "+%Y%m%d-%H%M%S")"
#readonly timestamp="$(date +%F-%H-%M)"
#readonly timestamp="2025-04-15-23-04"
export timestamp

export tmpdir=/tmp/${timestamp};
mkdir -p ${tmpdir}

configure_service_account

# screen session name
session_name="build-current-images"

export ZONE="$(jq -r .ZONE env.json)"
gcloud compute instances list --zones "${ZONE}" --format json > ${tmpdir}/instances.json
gcloud compute images    list                   --format json > ${tmpdir}/images.json

# Run generation scripts simultaneously for each dataproc image version
screen -L -US "${session_name}" -c examples/secure-boot/pre-init.screenrc

function find_disk_usage() {
  #  grep maximum-disk-used /tmp/custom-image-*/logs/startup-script.log
  grep -H 'Customization script' /tmp/custom-image-*/logs/workflow.log
  for workflow_log in $(grep -Hl "Customization script" /tmp/custom-image-*/logs/workflow.log) ; do
    startup_log=$(echo "${workflow_log}" | sed -e 's/workflow.log/startup-script.log/')
    grep -v '^\['  "${startup_log}" \
      | grep -A7 'Filesystem.*Avail' \
      | perl examples/secure-boot/genline.pl "${workflow_log}"
  done
}

revoke_bindings
