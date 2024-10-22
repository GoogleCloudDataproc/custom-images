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
#readonly timestamp="2024-10-19-18-46"
#readonly timestamp="2024-10-21-19-29"

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
  local img_list="$(gcloud compute images list --filter="name=( \"${image_name}\" )" 2>&1)"
  set +e
  echo ${img_list} | grep -q 'Listed 0 items.'
  if [[ $? != 0 ]] ; then
#  if gcloud compute images describe "${image_name}" > /dev/null ; then
    echo "Image already exists"
    return
  fi
  local instance_list="$(gcloud compute instances list --zones "${custom_image_zone}" --filter="name=( \"${image_name}-install\" )" 2>&1)"
  echo ${instance_list} | grep -q 'Listed 0 items.'
  if [[ $? != 0 ]]; then
#  if gcloud compute instances describe "${image_name}-install" > /dev/null ; then
    # if previous run ended without cleanup...
    gcloud -q compute instances delete "${image_name}-install" \
      --zone "${custom_image_zone}"
  fi
  set -xe
  python generate_custom_image.py \
    --machine-type         "n1-standard-4" \
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

function generate_from_dataproc_version() {
  local dataproc_version="$1"
  generate --dataproc-version "${dataproc_version}"
}

function generate_from_base_purpose() {
  generate --base-image-uri "https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/images/${1}-${dataproc_version/\./-}-${timestamp}"
}

# base image -> cuda
case "${dataproc_version}" in
  "2.0-debian10" ) disk_size_gb="31" ;; # 40G   29G  9.1G  76% / # cuda-pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="32" ;; # 33G   30G  3.4G  90% / # cuda-pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="31" ;; # 36G   29G  7.0G  81% / # cuda-pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="37" ;; # 40G   35G  2.7G  93% / # cuda-pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="35" ;; # 36G   33G  3.3G  91% / # cuda-pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="36" ;; # 36G   34G  2.1G  95% / # cuda-pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="39" ;; # 40G   37G  1.1G  98% / # cuda-pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="36" ;; # 54G   34G   20G  63% / # cuda-pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="39" ;; # 39G   37G  2.4G  94% / # cuda-pre-init-2-2-ubuntu22
esac

# Install GPU drivers + cuda on dataproc base image
PURPOSE="cuda-pre-init"
customization_script="examples/secure-boot/install_gpu_driver.sh"
time generate_from_dataproc_version "${dataproc_version}"

# cuda image -> dask
case "${dataproc_version}" in
  "2.0-debian10" ) disk_size_gb="34" ;; # 40G   32G  6.4G  83% / # dask-pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="35" ;; # 65G   33G   33G  51% / # dask-pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="35" ;; # 36G   32G  4.3G  89% / # dask-pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="40" ;; # 40G   38G  111M 100% / # dask-pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="37" ;; # 37G   36G  1.7G  96% / # dask-pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="38" ;; # 41G   37G  4.3G  90% / # dask-pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="41" ;; # 46G   39G  4.4G  90% / # dask-pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="39" ;; # 54G   37G   18G  68% / # dask-pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="41" ;; # 44G   39G  4.9G  89% / # dask-pre-init-2-2-ubuntu22
esac

# Install dask on cuda base image
PURPOSE="dask-pre-init"
customization_script="examples/secure-boot/dask.sh"
time generate_from_base_purpose "cuda-pre-init"

# dask image -> rapids
case "${dataproc_version}" in
   "2.0-debian10" ) disk_size_gb="52" ;; # 64G   49G   13G  80% / # rapids-pre-init-2-0-debian10
   "2.0-rocky8"   ) disk_size_gb="52" ;; # 65G   50G   15G  78% / # rapids-pre-init-2-0-rocky8
   "2.0-ubuntu18" ) disk_size_gb="53" ;; # 63G   49G   14G  78% / # rapids-pre-init-2-0-ubuntu18
   "2.1-debian11" ) disk_size_gb="58" ;; # 64G   55G  6.2G  90% / # rapids-pre-init-2-1-debian11
   "2.1-rocky8"   ) disk_size_gb="55" ;; # 65G   53G   12G  82% / # rapids-pre-init-2-1-rocky8
   "2.1-ubuntu20" ) disk_size_gb="58" ;; # 63G   54G  9.1G  86% / # rapids-pre-init-2-1-ubuntu20
   "2.2-debian12" ) disk_size_gb="59" ;; # 64G   56G  5.2G  92% / # rapids-pre-init-2-2-debian12
   "2.2-rocky9"   ) disk_size_gb="56" ;; # 65G   54G   12G  83% / # rapids-pre-init-2-2-rocky9
   "2.2-ubuntu22" ) disk_size_gb="60" ;; # 63G   56G  7.1G  89% / # rapids-pre-init-2-2-ubuntu22
esac

#disk_size_gb="65"

# Install rapids on dask base image
PURPOSE="rapids-pre-init"
customization_script="examples/secure-boot/rapids.sh"
time generate_from_base_purpose "dask-pre-init"
