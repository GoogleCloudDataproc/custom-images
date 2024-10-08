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

set -e

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

# Run all image generation scripts simultaneously
screen -US "${session_name}" -c examples/secure-boot/pre-init.screenrc

# tail -n 3 /tmp/custom-image-cuda-pre-init-2-*/logs/workflow.log
# grep -A6 'Filesystem.*Avail' /tmp/custom-image-cuda-pre-init-2-*/logs/startup-script.log | perl -ne 'print $1,$/ if( m:( Filesystem.* Avail.*| /dev/.*/\s*$|^--): )'

revoke_bindings

#
# disk size - 20241009
#
#  Filesystem      Size  Used Avail Use% Mounted on

#  /dev/sda1        40G   29G  9.1G  76% / # 2.0-debian10
#  /dev/sda2        33G   30G  3.4G  90% / # 2.0-rocky8
#  /dev/sda1        36G   29G  7.0G  81% / # 2.0-ubuntu18
#  /dev/sda1        40G   35G  2.7G  93% / # 2.1-debian11
#  /dev/sda2        36G   33G  3.4G  91% / # 2.1-rocky8
#  /dev/root        36G   34G  2.1G  95% / # 2.1-ubuntu20
#  /dev/sda1        40G   37G  1.1G  98% / # 2.2-debian12
#  /dev/sda2        54G   34G   21G  63% / # 2.2-rocky9
#  /dev/root        39G   37G  2.4G  94% / # 2.2-ubuntu22
