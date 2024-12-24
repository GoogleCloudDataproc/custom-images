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
# This script creates a custom image pre-loaded with cuda

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
    --role="roles/dataproc.worker"

  # Revoke the service account's access to buckets in this project
  for storage_object_role in 'User' 'Creator' 'Viewer' ; do
    execute_with_retries gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${GSA}" \
      --role="roles/storage.object${storage_object_role}"
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
    --role=roles/compute.instanceAdmin.v1

  execute_with_retries gcloud iam service-accounts remove-iam-policy-binding "${GSA}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/iam.serviceAccountUser
}

export PROJECT_ID="$(jq    -r .PROJECT_ID    env.json)"
export PURPOSE="$(jq       -r .PURPOSE       env.json)"
export BUCKET="$(jq        -r .BUCKET        env.json)"

SA_NAME="sa-${PURPOSE}"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "${PROJECT_ID}"

gcloud auth login

configure_service_account

# screen session name
session_name="build-current-images"

readonly timestamp="$(date +%F-%H-%M)"
#readonly timestamp="2024-12-23-22-02"
export timestamp

export tmpdir=/tmp/${timestamp};
mkdir -p ${tmpdir}
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
      | grep -A8 'Filesystem.*Avail' \
      | perl examples/secure-boot/genline.pl "${workflow_log}"
  done
}

revoke_bindings
