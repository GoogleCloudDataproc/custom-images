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

  # Grant service account access to bucket
  gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/storage.objectViewer" > /dev/null 2>&1

  # Grant the service account access to list secrets for the project
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.viewer" > /dev/null 2>&1

  # Grant service account permission to access the private secret
  gcloud secrets add-iam-policy-binding "${private_secret_name}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.secretAccessor" > /dev/null 2>&1

  # Grant service account permission to access the public secret
  gcloud secrets add-iam-policy-binding "${public_secret_name}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.secretAccessor" > /dev/null 2>&1

  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/compute.instanceAdmin.v1 > /dev/null 2>&1

  gcloud iam service-accounts add-iam-policy-binding "${GSA}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/iam.serviceAccountUser > /dev/null 2>&1

}

function revoke_bindings() {
  # Revoke permission to access the private secret
  gcloud secrets remove-iam-policy-binding "${private_secret_name}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.secretAccessor" > /dev/null 2>&1

  # Revoke access to bucket
  gcloud storage buckets remove-iam-policy-binding "gs://${BUCKET}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/storage.objectViewer" > /dev/null 2>&1

  # Revoke access to list secrets for the project
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.viewer" > /dev/null 2>&1

  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/compute.instanceAdmin.v1 > /dev/null 2>&1

  gcloud iam service-accounts remove-iam-policy-binding "${GSA}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/iam.serviceAccountUser > /dev/null 2>&1

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
#readonly timestamp="2024-11-29-07-12"
export timestamp

export tmpdir=/tmp/${timestamp};
mkdir -p ${tmpdir}
export ZONE="$(jq -r .ZONE env.json)"
gcloud compute instances list --zones "${ZONE}" --format json > ${tmpdir}/instances.json
gcloud compute images    list                   --format json > ${tmpdir}/images.json

# Run generation scripts simultaneously for each dataproc image version
screen -L -US "${session_name}" -c examples/secure-boot/pre-init.screenrc

function find_disk_usage() {
  grep 'Customization script' /tmp/custom-image-*/logs/workflow.log
#  grep maximum-disk-used /tmp/custom-image-*/logs/startup-script.log
  for workflow_log in $(grep -l "Customization script" /tmp/custom-image-*/logs/workflow.log) ; do
    startup_log=$(echo "${workflow_log}" | sed -e 's/workflow.log/startup-script.log/')
    grep -A5 'Filesystem.*1K-blocks' "${startup_log}" | perl examples/secure-boot/genline.pl "${workflow_log}"
  done
}

revoke_bindings
