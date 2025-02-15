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
IMAGE_VERSION="$(jq    -r .IMAGE_VERSION        env.json)" ; fi
PROJECT_ID="$(jq       -r .PROJECT_ID           env.json)"
PURPOSE="$(jq          -r .PURPOSE              env.json)"
BUCKET="$(jq           -r .BUCKET               env.json)"
TEMP_BUCKET="$(jq      -r .TEMP_BUCKET          env.json)"
ZONE="$(jq             -r .ZONE                 env.json)"
SUBNET="$(jq           -r .SUBNET               env.json)"
HIVE_NAME="$(jq        -r .HIVE_INSTANCE_NAME   env.json)"
HIVEDB_PW_URI="$(jq    -r .DB_HIVE_PASSWORD_URI env.json)"
KMS_KEY_URI="$(jq      -r .KMS_KEY_URI          env.json)"
PRINCIPAL_USER="$(jq   -r .PRINCIPAL            env.json)"
PRINCIPAL_DOMAIN="$(jq -r .DOMAIN               env.json)"

region="$(echo "${ZONE}" | perl -pe 's/-[a-z]+$//')"

custom_image_zone="${ZONE}"
disk_size_gb="30" # greater than or equal to 30

SA_NAME="sa-${PURPOSE}"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "${PROJECT_ID}"
gcloud config set account "${PRINCIPAL_USER}@${PRINCIPAL_DOMAIN}"

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

CUDA_VERSION="12.4.1"
case "${dataproc_version}" in
  "2.0-debian10" ) CUDA_VERSION="12.1.1" ;;
  "2.0-rocky8"   ) CUDA_VERSION="12.1.1" ;;
  "2.0-ubuntu18" ) CUDA_VERSION="12.1.1" ;;
  "2.1-debian11" ) CUDA_VERSION="12.4.1" ;;
  "2.1-rocky8"   ) CUDA_VERSION="12.4.1" ;;
  "2.1-ubuntu20" ) CUDA_VERSION="12.4.1" ;;
  "2.2-debian12" ) CUDA_VERSION="12.6.3" ;;
  "2.2-rocky9"   ) CUDA_VERSION="12.6.3" ;;
  "2.2-ubuntu22" ) CUDA_VERSION="12.6.3" ;;
esac

eval "$(bash examples/secure-boot/create-key-pair.sh)"
metadata="rapids-runtime=SPARK"
metadata="${metadata},cuda-version=${CUDA_VERSION}"
metadata="${metadata},creating-image=c9h"
metadata="${metadata},dataproc-temp-bucket=${TEMP_BUCKET}"
metadata="${metadata},include-pytorch=1"

function create_h100_instance() {
  python generate_custom_image.py \
    --machine-type         "a3-highgpu-2g" \
    --accelerator          "type=nvidia-h100-80gb,count=2" \
    $*
}

function create_t4_instance() {
  python generate_custom_image.py \
    --machine-type         "n1-standard-32" \
    --accelerator          "type=nvidia-tesla-t4,count=1" \
    $*
}

function generate() {
  local extra_args="$*"
  local image_name="${PURPOSE}-${dataproc_version//\./-}-${timestamp}"

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

  if [[ "${customization_script}" =~ "cloud-sql-proxy.sh" ]] ; then
    metadata="${metadata},hive-metastore-instance=${PROJECT_ID}:${region}:${HIVE_NAME}"
    metadata="${metadata},db-hive-password-uri=${HIVEDB_PW_URI}"
    metadata="${metadata},kms-key-uri=${KMS_KEY_URI}"
  fi
  
  set -xe
  create_t4_instance \
    --image-name           "${image_name}" \
    --customization-script "${customization_script}" \
    --service-account      "${GSA}" \
    --metadata             "${metadata}" \
    --zone                 "${custom_image_zone}" \
    --disk-size            "${disk_size_gb}" \
    --gcs-bucket           "${BUCKET}" \
    --subnet               "${SUBNET}" \
    --optional-components  "DOCKER,PIG" \
    --shutdown-instance-timer-sec=30 \
    --no-smoke-test \
    ${extra_args}
  set +x
}

function generate_from_dataproc_version() { generate --dataproc-version "$1" ; }

function generate_from_base_purpose() {
  generate --base-image-uri "https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/images/${1}-${dataproc_version/\./-}-${timestamp}"
}

# base image -> tensorflow
case "${dataproc_version}" in
  "2.0-debian10" ) disk_size_gb="42" ;; #  41.11G  36.28G     3.04G  93% / # tf-pre-init
  "2.0-rocky8"   ) disk_size_gb="45" ;; #  44.79G  38.94G     5.86G  87% / # tf-pre-init
  "2.0-ubuntu18" ) disk_size_gb="41" ;; #  39.55G  35.39G     4.14G  90% / # tf-pre-init
  "2.1-debian11" ) disk_size_gb="46" ;; #  45.04G  39.31G     3.78G  92% / # tf-pre-init
  "2.1-rocky8"   ) disk_size_gb="49" ;; #  48.79G  41.78G     7.01G  86% / # tf-pre-init
  "2.1-ubuntu20" ) disk_size_gb="46" ;; #  44.40G  39.92G     4.46G  90% / # tf-pre-init
  "2.2-debian12" ) disk_size_gb="47" ;; #  46.03G  40.76G     3.28G  93% / # tf-pre-init
  "2.2-rocky9"   ) disk_size_gb="47" ;; #  46.79G  40.85G     5.94G  88% / # tf-pre-init
  "2.2-ubuntu22" ) disk_size_gb="47" ;; #  45.37G  40.56G     4.79G  90% / # tf-pre-init
esac

#disk_size_gb="60" # greater than or equal to 40

# Install GPU drivers + cuda + rapids + cuDNN + nccl + tensorflow + pytorch on dataproc base image
PURPOSE="tf-pre-init"
customization_script="examples/secure-boot/install_gpu_driver.sh"
time generate_from_dataproc_version "${dataproc_version}"

## Execute spark-rapids/spark-rapids.sh init action on base image
PURPOSE="spark-pre-init"
customization_script="examples/secure-boot/spark-rapids.sh"
echo time generate_from_dataproc_version "${dataproc_version}"

## Execute spark-rapids/spark-rapids.sh init action on base image
PURPOSE="cloud-sql-proxy"
customization_script="examples/secure-boot/cloud-sql-proxy.sh"
echo time generate_from_dataproc_version "${dataproc_version}"

## Execute spark-rapids/mig.sh init action on base image
PURPOSE="mig-pre-init"
customization_script="examples/secure-boot/mig.sh"
echo time generate_from_dataproc_version "${dataproc_version}"

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

disk_size_gb="45"

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
  "2.0-debian10" ) disk_size_gb="44" ;; # 40.12G 37.51G   0.86G  98% / # pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="41" ;; # 38.79G 38.04G   0.76G  99% / # pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="44" ;; # 37.62G 36.69G   0.91G  98% / # pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="44" ;; # 42.09G 39.77G   0.49G  99% / # pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="44" ;; # 43.79G 41.11G   2.68G  94% / # pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="45" ;; # 39.55G 39.39G   0.15G 100% / # pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="48" ;; # 44.06G 41.73G   0.41G 100% / # pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="45" ;; # 44.79G 42.29G   2.51G  95% / # pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="46" ;; # 42.46G 41.97G   0.48G  99% / # pre-init-2-2-ubuntu22
esac

## Install pytorch on base image
PURPOSE="pytorch-pre-init"
customization_script="examples/secure-boot/pytorch.sh"
#time generate_from_base_purpose "cuda-pre-init"
