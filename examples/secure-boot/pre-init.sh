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
metadata="${metadata},dask-runtime=standalone"
metadata="${metadata},rapids-runtime=DASK"
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

function generate() {
  local extra_args="$*"
  local image_name="${PURPOSE}-${dataproc_version/\./-}-${timestamp}"

  local image="$(jq -r ".[] | select(.name == \"${image_name}\").name" "${tmpdir}/images.json")"

  if [[ -n "${image}" ]] ; then
    echo "Image already exists"
    return
  fi

  local install_image="$(jq -r ".[] | select(.name == \"${image_name}-install\").name" "${tmpdir}/images.json")"
  if [[ -n "${install_image}" ]] ; then
    echo "Install image already exists"
    gcloud -q compute images delete "${image_name}-install"
  fi

  local instance="$(jq -r ".[] | select(.name == \"${image_name}-install\").name" "${tmpdir}/instances.json")"

  if [[ -n "${instance}" ]]; then
    # if previous run ended without cleanup...
    echo "cleaning up instance from previous run"
    gcloud -q compute instances delete "${image_name}-install" \
      --zone "${custom_image_zone}"
  fi
  set -xe
  python generate_custom_image.py \
    --machine-type         "n1-standard-8" \
    --accelerator          "type=nvidia-tesla-t4" \
    --image-name           "${image_name}" \
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

function generate_from_dataproc_version() { generate --dataproc-version "$1" ; }

function generate_from_base_purpose() {
  generate --base-image-uri "https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/images/${1}-${dataproc_version/\./-}-${timestamp}"
}

# base image -> cuda
case "${dataproc_version}" in
  "2.0-debian10" ) disk_size_gb="32" ;; # 33G   17G   15G  55% / # cuda-pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="32" ;; # 32G   19G   14G  59% / # cuda-pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="32" ;; # 31G   17G   15G  53% / # cuda-pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="34" ;; # 34G   20G   13G  63% / # cuda-pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="36" ;; # 36G   22G   15G  61% / # cuda-pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="34" ;; # 32G   20G   12G  63% / # cuda-pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="36" ;; # 36G   23G   11G  69% / # cuda-pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="37" ;; # 37G   23G   15G  62% / # cuda-pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="36" ;; # 34G   23G   12G  67% / # cuda-pre-init-2-2-ubuntu22
esac

# Install GPU drivers + cuda on dataproc base image
PURPOSE="cuda-pre-init"
customization_script="examples/secure-boot/install_gpu_driver.sh"
time generate_from_dataproc_version "${dataproc_version}"

# cuda image -> rapids
case "${dataproc_version}" in
  "2.0-debian10" ) disk_size_gb="41" ;; # 42G   29G   12G  72% / # rapids-pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="42" ;; # 42G   30G   13G  70% / # rapids-pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="41" ;; # 40G   28G   12G  70% / # rapids-pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="43" ;; # 43G   31G  9.6G  77% / # rapids-pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="45" ;; # 45G   33G   13G  72% / # rapids-pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="43" ;; # 42G   31G   12G  74% / # rapids-pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="45" ;; # 45G   33G  9.5G  78% / # rapids-pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="46" ;; # 46G   34G   13G  73% / # rapids-pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="45" ;; # 44G   33G   11G  76% / # rapids-pre-init-2-2-ubuntu22
esac

#disk_size_gb="50"

# Install dask with rapids on base image
PURPOSE="rapids-pre-init"
customization_script="examples/secure-boot/rapids.sh"
time generate_from_base_purpose "cuda-pre-init"

## Install dask without rapids on base image
#PURPOSE="dask-pre-init"
#customization_script="examples/secure-boot/dask.sh"
#time generate_from_base_purpose "cuda-pre-init"
