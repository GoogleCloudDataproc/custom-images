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
# This script creates a custom image with the script specified loaded
#
# pre-init.sh <dataproc version>

set -e
readonly timestamp="$(date +%F-%H-%M)"

IMAGE_VERSION="$1"
if [[ -z "${IMAGE_VERSION}" ]] ; then
export IMAGE_VERSION="$(jq -r .IMAGE_VERSION        env.json)" ; fi
export PROJECT_ID="$(jq    -r .PROJECT_ID           env.json)"
export PURPOSE="$(jq       -r .PURPOSE              env.json)"
export BUCKET="$(jq        -r .BUCKET               env.json)"
export ZONE="$(jq          -r .ZONE                 env.json)"

custom_image_zone="${ZONE}"
disk_size_gb="30" # greater than or equal to 30

SA_NAME="sa-${PURPOSE}"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project ${PROJECT_ID}

#gcloud auth login

eval "$(bash examples/secure-boot/create-key-pair.sh)"
metadata="public_secret_name=${public_secret_name}"
metadata="${metadata},private_secret_name=${private_secret_name}"
metadata="${metadata},secret_project=${secret_project}"
metadata="${metadata},secret_version=${secret_version}"
metadata="${metadata},dask-runtime=yarn"
metadata="${metadata},rapids-runtime=SPARK"
metadata="${metadata},cuda-version=12.4"

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

# base image -> cuda
# case "${dataproc_version}" in
#   "2.2-rocky9"   ) disk_size_gb="54" ;;
#   "2.1-rocky8"   ) disk_size_gb="36" ;;
#   "2.0-rocky8"   ) disk_size_gb="33" ;;
#   "2.2-ubuntu22" ) disk_size_gb="40" ;;
#   "2.1-ubuntu20" ) disk_size_gb="37" ;;
#   "2.0-ubuntu18" ) disk_size_gb="37" ;;
#   "2.2-debian12" ) disk_size_gb="40" ;;
#   "2.1-debian11" ) disk_size_gb="40" ;;
#   "2.0-debian10" ) disk_size_gb="40" ;;
# esac

# cuda image -> dask
# case "${dataproc_version}" in
#   "2.2-rocky9"   ) disk_size_gb="54" ;;
#   "2.1-rocky8"   ) disk_size_gb="37" ;;
#   "2.0-rocky8"   ) disk_size_gb="40" ;;
#   "2.2-ubuntu22" ) disk_size_gb="45" ;;
#   "2.1-ubuntu20" ) disk_size_gb="42" ;;
#   "2.0-ubuntu18" ) disk_size_gb="37" ;;
#   "2.2-debian12" ) disk_size_gb="46" ;;
#   "2.1-debian11" ) disk_size_gb="40" ;;
#   "2.0-debian10" ) disk_size_gb="40" ;;
# esac

# dask image -> rapids
case "${dataproc_version}" in
  "2.2-rocky9"   ) disk_size_gb="54" ;;
  "2.1-rocky8"   ) disk_size_gb="37" ;;
  "2.0-rocky8"   ) disk_size_gb="40" ;;
  "2.2-ubuntu22" ) disk_size_gb="45" ;;
  "2.1-ubuntu20" ) disk_size_gb="42" ;;
  "2.0-ubuntu18" ) disk_size_gb="37" ;;
  "2.2-debian12" ) disk_size_gb="46" ;;
  "2.1-debian11" ) disk_size_gb="40" ;;
  "2.0-debian10" ) disk_size_gb="40" ;;
esac


function generate() {
  local extra_args="$*"
  set -x
  python generate_custom_image.py \
    --machine-type         "n1-standard-4" \
    --accelerator          "type=nvidia-tesla-t4" \
    --image-name           "${PURPOSE}-${dataproc_version/\./-}-${timestamp}" \
    --customization-script "${customization_script}" \
    --service-account      "${GSA}" \
    --metadata             "${metadata}" \
    --zone                 "${custom_image_zone}" \
    --disk-size            "${disk_size_gb}" \
    --gcs-bucket           "${BUCKET}" \
    --shutdown-instance-timer-sec=30 \
    --no-smoke-test \
    ${extra_args}
  set +x
}

function generate_from_dataproc_version() {
  local dataproc_version="$1"
  generate --dataproc-version "${dataproc_version}"
}

function generate_from_base_purpose() {
  local base_purpose="$1"
  generate --base-image-uri "https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/images/${base_purpose}-${dataproc_version/\./-}-${timestamp}"
}

# Install GPU drivers + cuda on dataproc base image
PURPOSE="cuda-pre-init"
customization_script="examples/secure-boot/install_gpu_driver.sh"

time generate_from_dataproc_version "${dataproc_version}"

# Install dask on cuda base image
base_purpose="${PURPOSE}"
PURPOSE="dask-pre-init"
customization_script="examples/secure-boot/dask.sh"

time generate_from_base_purpose "${base_purpose}"

# Install rapids on dask base image
base_purpose="${PURPOSE}"
PURPOSE="rapids-pre-init"
customization_script="examples/secure-boot/rapids.sh"

time generate_from_base_purpose "${base_purpose}"
