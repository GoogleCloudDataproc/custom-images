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

export PROJECT_ID="$(jq    -r .PROJECT_ID    env.json)"
export PURPOSE="$(jq       -r .PURPOSE       env.json)"
export BUCKET="$(jq        -r .BUCKET        env.json)"
export IMAGE_VERSION="$(jq -r .IMAGE_VERSION env.json)"
export ZONE="$(jq          -r .ZONE          env.json)"

custom_image_zone="${ZONE}"
disk_size_gb="50" # greater than or equal to 30

SA_NAME="sa-${PURPOSE}"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project ${PROJECT_ID}

gcloud auth login

if [[ -d tls ]] ; then mv tls "tls-$(date +%s)" ; fi
eval "$(bash examples/secure-boot/create-key-pair.sh)"

metadata="public_secret_name=${public_secret_name}"
metadata="${metadata},private_secret_name=${private_secret_name}"
metadata="${metadata},secret_project=${secret_project}"
metadata="${metadata},secret_version=${secret_version}"

if gcloud iam service-accounts list --filter email="${GSA}" 2>&1 | grep 'Listed 0 items.' ; then
  # Create service account for this purpose
  echo "creating pre-init customization service account ${GSA}"
  gcloud iam service-accounts create "${SA_NAME}" \
    --description="Service account for pre-init customization" \
    --display-name="${SA_NAME}"
fi

# Grant service account access to bucket
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${GSA}" \
  --role="roles/storage.objectViewer"

# Grant the service account access to list secrets for the project
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA}" \
  --role="roles/secretmanager.viewer"

# Grant service account permission to access the private secret
gcloud secrets add-iam-policy-binding "${private_secret_name}" \
  --member="serviceAccount:${GSA}" \
  --role="roles/secretmanager.secretAccessor"

# Grant service account permission to access the public secret
gcloud secrets add-iam-policy-binding "${public_secret_name}" \
  --member="serviceAccount:${GSA}" \
  --role="roles/secretmanager.secretAccessor"

# If no OS family specified, default to debian
if [[ "${IMAGE_VERSION}" != *-* ]] ; then
  case "${IMAGE_VERSION}" in
    "2.2" ) dataproc_version="${IMAGE_VERSION}-debian12" ;;
    "2.1" ) dataproc_version="${IMAGE_VERSION}-debian11" ;;
    "2.0" ) dataproc_version="${IMAGE_VERSION}-debian10" ;;
  esac
else
  dataproc_version="${IMAGE_VERSION}"
fi

#dataproc_version="${IMAGE_VERSION}-ubuntu22"
#dataproc_version="${IMAGE_VERSION}-rocky9"
#customization_script="examples/secure-boot/install-nvidia-driver-debian11.sh"
#customization_script="examples/secure-boot/install-nvidia-driver-debian12.sh"
customization_script="examples/secure-boot/install_gpu_driver.sh"
#echo "#!/bin/bash\necho no op" | dd of=empty.sh
#customization_script=empty.sh
#image_name="nvidia-open-kernel-2.2-ubuntu22-$(date +%F)"
#image_name="nvidia-open-kernel-2.2-rocky9-$(date +%F)"
#image_name="nvidia-open-kernel-2.2-debian12-$(date +%F)"
#image_name="nvidia-open-kernel-${dataproc_version}-$(date +%F)"
image_name="cuda-${dataproc_version/\./-}-$(date +%F-%H-%M)"

python generate_custom_image.py \
    --accelerator "type=nvidia-tesla-t4" \
    --image-name "${image_name}" \
    --dataproc-version "${dataproc_version}" \
    --trusted-cert "tls/db.der" \
    --customization-script "${customization_script}" \
    --service-account "${GSA}" \
    --metadata "${metadata}" \
    --zone "${custom_image_zone}" \
    --disk-size "${disk_size_gb}" \
    --no-smoke-test \
    --gcs-bucket "${BUCKET}" \
    --shutdown-instance-timer-sec=30

# Revoke permission to access the private secret
gcloud secrets remove-iam-policy-binding "${private_secret_name}" \
  --member="serviceAccount:${GSA}" \
  --role="roles/secretmanager.secretAccessor"

# Revoke access to bucket
gcloud storage buckets remove-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${GSA}" \
  --role="roles/storage.objectViewer"

# Revoke access to list secrets for the project
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA}" \
  --role="roles/secretmanager.viewer"


set +x
