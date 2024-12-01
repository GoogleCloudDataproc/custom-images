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
export SUBNET="$(jq        -r .SUBNET               env.json)"

export region="$(echo "${ZONE}" | perl -pe 's/-[a-z]+$//')"

custom_image_zone="${ZONE}"
disk_size_gb="30" # greater than or equal to 30

SA_NAME="sa-${PURPOSE}"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project ${PROJECT_ID}

#gcloud auth login

eval "$(bash examples/secure-boot/create-key-pair.sh)"
metadata="dask-runtime=standalone"
metadata="${metadata},rapids-runtime=DASK"
metadata="${metadata},cuda-version=12.4"
metadata="${metadata},creating-image=c9h"
metadata="${metadata},rapids-mirror-disk=rapids-mirror-${region}"
metadata="${metadata},rapids-mirror-host=10.42.79.42"

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
    echo "Install image already exists.  Cleaning up after aborted run."
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
    --machine-type         "n1-standard-16" \
    --accelerator          "type=nvidia-tesla-t4" \
    --image-name           "${image_name}" \
    --customization-script "${customization_script}" \
    --service-account      "${GSA}" \
    --metadata             "${metadata}" \
    --zone                 "${custom_image_zone}" \
    --disk-size            "${disk_size_gb}" \
    --gcs-bucket           "${BUCKET}" \
    --subnet               "${SUBNET}" \
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
  "2.0-debian10" ) disk_size_gb="30" ;; # 29.30G 28.29G       0 100% / # cuda-pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="30" ;; # 29.79G 28.94G   0.85G  98% / # cuda-pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="30" ;; # 28.89G 27.64G   1.24G  96% / # cuda-pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="32" ;; # 31.26G 30.74G       0 100% / # cuda-pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="34" ;; # 33.79G 32.00G   1.80G  95% / # cuda-pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="32" ;; # 30.83G 30.35G   0.46G  99% / # cuda-pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="34" ;; # 33.23G 32.71G       0 100% / # cuda-pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="35" ;; # 34.79G 33.16G   1.64G  96% / # cuda-pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="35" ;; # 33.74G 32.94G   0.78G  98% / # cuda-pre-init-2-2-ubuntu22
esac

# Install GPU drivers + cuda on dataproc base image
PURPOSE="cuda-pre-init"
customization_script="examples/secure-boot/install_gpu_driver.sh"
time generate_from_dataproc_version "${dataproc_version}"

# cuda image -> rapids
case "${dataproc_version}" in
  "2.0-debian10" ) disk_size_gb="41" ;; # 40.12G 37.51G   0.86G  98% / # rapids-pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="41" ;; # 38.79G 38.04G   0.76G  99% / # rapids-pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="40" ;; # 37.62G 36.69G   0.91G  98% / # rapids-pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="44" ;; # 42.09G 39.77G   0.49G  99% / # rapids-pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="44" ;; # 43.79G 41.11G   2.68G  94% / # rapids-pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="45" ;; # 39.55G 39.39G   0.15G 100% / # rapids-pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="46" ;; # 44.06G 41.73G   0.41G 100% / # rapids-pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="45" ;; # 44.79G 42.29G   2.51G  95% / # rapids-pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="46" ;; # 42.46G 41.97G   0.48G  99% / # rapids-pre-init-2-2-ubuntu22
esac

#disk_size_gb="50"

# Install dask with rapids on base image
PURPOSE="rapids-pre-init"
customization_script="examples/secure-boot/rapids.sh"
#time generate_from_base_purpose "cuda-pre-init"

## Install dask without rapids on base image
#PURPOSE="dask-pre-init"
#customization_script="examples/secure-boot/dask.sh"
#time generate_from_base_purpose "cuda-pre-init"

# cuda image -> pytorch
case "${dataproc_version}" in
  "2.0-debian10" ) disk_size_gb="44" ;; # 40.12G 37.51G   0.86G  98% / # rapids-pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="41" ;; # 38.79G 38.04G   0.76G  99% / # rapids-pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="44" ;; # 37.62G 36.69G   0.91G  98% / # rapids-pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="44" ;; # 42.09G 39.77G   0.49G  99% / # rapids-pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="44" ;; # 43.79G 41.11G   2.68G  94% / # rapids-pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="45" ;; # 39.55G 39.39G   0.15G 100% / # rapids-pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="48" ;; # 44.06G 41.73G   0.41G 100% / # rapids-pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="45" ;; # 44.79G 42.29G   2.51G  95% / # rapids-pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="46" ;; # 42.46G 41.97G   0.48G  99% / # rapids-pre-init-2-2-ubuntu22
esac

## Install pytorch on base image
PURPOSE="pytorch-pre-init"
customization_script="examples/secure-boot/pytorch.sh"
time generate_from_base_purpose "cuda-pre-init"
