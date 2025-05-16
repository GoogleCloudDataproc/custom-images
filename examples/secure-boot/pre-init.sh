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

function version_ge(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|tail -n1)" ]]; }
function version_gt(){ [[ "$1" = "$2" ]]&& return 1 || version_ge "$1" "$2";}
function version_le(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|head -n1)" ]]; }
function version_lt(){ [[ "$1" = "$2" ]]&& return 1 || version_le "$1" "$2";}

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
SECRET_NAME="$(jq      -r .SECRET_NAME          env.json)"
KMS_KEY_URI="$(jq      -r .KMS_KEY_URI          env.json)"

PRINCIPAL_USER="$(jq   -r .PRINCIPAL            env.json)"
PRINCIPAL_DOMAIN="$(jq -r .DOMAIN               env.json)"
PRINCIPAL="${PRINCIPAL_USER}@${PRINCIPAL_DOMAIN}"
gcloud config set project "${PROJECT_ID}"
gcloud config set account "${PRINCIPAL}"

region="$(echo "${ZONE}" | perl -pe 's/-[a-z]+$//')"

custom_image_zone="${ZONE}"
disk_size_gb="30" # greater than or equal to 30 (32 for rocky8)

SA_NAME="sa-${PURPOSE}"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# If no OS family specified, default to debian
if [[ "${IMAGE_VERSION}" != *-* ]] ; then
  case "${IMAGE_VERSION}" in
    "2.3" ) dataproc_version="${IMAGE_VERSION}-debian12" ;;
    "2.2" ) dataproc_version="${IMAGE_VERSION}-debian12" ;;
    "2.1" ) dataproc_version="${IMAGE_VERSION}-debian11" ;;
    "2.0" ) dataproc_version="${IMAGE_VERSION}-debian10" ;;
    "1.5" ) dataproc_version="${IMAGE_VERSION}-debian10" ;;
  esac
else
  dataproc_version="${IMAGE_VERSION}"
fi

CUDA_VERSION="12.4.1"
case "${dataproc_version}" in
  "1.5-debian10"     ) CUDA_VERSION="11.5.2" ; short_dp_ver=1.5-deb10 ; disk_size_gb="20";;
  "2.0-debian10"     ) CUDA_VERSION="12.1.1" ; short_dp_ver=2.0-deb10 ;;
  "2.0-rocky8"       ) CUDA_VERSION="12.1.1" ; short_dp_ver=2.0-roc8 ; disk_size_gb="32";;
  "2.0-ubuntu18"     ) CUDA_VERSION="12.1.1" ; short_dp_ver=2.0-ubu18 ;;
  "2.1-debian11"     ) CUDA_VERSION="12.4.1" ; short_dp_ver=2.1-deb11 ;;
  "2.1-rocky8"       ) CUDA_VERSION="12.4.1" ; short_dp_ver=2.1-roc8 ;;
  "2.1-ubuntu20"     ) CUDA_VERSION="12.4.1" ; short_dp_ver=2.1-ubu20 ;;
  "2.1-ubuntu20-arm" ) CUDA_VERSION="12.4.1" ; short_dp_ver=2.1-ubu20-arm ;;
  "2.2-debian12"     ) CUDA_VERSION="12.6.3" ; short_dp_ver=2.2-deb12 ;;
  "2.2-rocky9"       ) CUDA_VERSION="12.6.3" ; short_dp_ver=2.2-roc9 ;;
  "2.2-ubuntu22"     ) CUDA_VERSION="12.6.3" ; short_dp_ver=2.2-ubu22 ;;
  "2.3-debian12"     ) CUDA_VERSION="12.6.3" ; short_dp_ver=2.3-deb12 ;;
  "2.3-rocky9"       ) CUDA_VERSION="12.6.3" ; short_dp_ver=2.3-roc9 ;;
  "2.3-ubuntu22"     ) CUDA_VERSION="12.6.3" ; short_dp_ver=2.3-ubu22 ;;
  "2.3-ml-ubuntu22"  ) CUDA_VERSION="12.6.3" ; short_dp_ver=2.3-ml-ubu22 ; disk_size_gb="50";;
esac

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

function create_unaccelerated_instance() {
  python generate_custom_image.py \
    --machine-type         "n1-standard-2" \
    $*
}

OPTIONAL_COMPONENTS_ARG=""

function generate() {
  local extra_args="$*"
#  local image_name="${PURPOSE}-${timestamp}-${dataproc_version//\./-}"
  local image_name="dataproc-${short_dp_ver//\./-}-${timestamp}-${PURPOSE}"

  local image="$(jq -r ".[] | select(.name == \"${image_name}\").name" "${tmpdir}/images.json")"

  if [[ -n "${image}" ]] ; then
    echo "Image already exists"
    return
  fi

  local metadata="invocation-type=custom-images"
  metadata="${metadata},dataproc-temp-bucket=${TEMP_BUCKET}"

  local install_image="$(jq -r ".[] | select(.name == \"${image_name}-install\").name" "${tmpdir}/images.json")"
  if [[ -n "${install_image}" ]] ; then
    echo "Install image already exists.  Cleaning up after aborted run."
    gcloud -q compute images delete "${image_name}-install"
  fi

  local instance="$(jq -r ".[] | select(.name == \"${image_name}-install\").name" "${tmpdir}/instances.json")"

  if [[ -n "${instance}" ]]; then
    # if previous run ended without cleanup...
    echo "cleaning up instance from previous run"
    gcloud -q compute instances delete "${image_name}-install"
  fi

  create_function="create_unaccelerated_instance"

  if [[ "${customization_script}" =~ "cloud-sql-proxy.sh"  ]] ; then
    metadata="${metadata},hive-metastore-instance=${PROJECT_ID}:${region}:${HIVE_NAME}"
    metadata="${metadata},db-hive-password-uri=${HIVEDB_PW_URI}"
    metadata="${metadata},kms-key-uri=${KMS_KEY_URI}"
  fi

  # For actions requiring access to the MOK during runtime, pass the requisite
  # metadata to extract the signing material
  if [[ "${customization_script}" =~ "install_gpu_driver.sh" ]] ; then
    eval "$(bash examples/secure-boot/create-key-pair.sh)"
    metadata="${metadata},public_secret_name=${public_secret_name}"
    metadata="${metadata},private_secret_name=${private_secret_name}"
    metadata="${metadata},secret_project=${secret_project}"
    metadata="${metadata},secret_version=${secret_version}"
    metadata="${metadata},modulus_md5sum=${modulus_md5sum}"
  fi

  if [[ "${customization_script}" =~ "install_gpu_driver.sh" ]] ; then
    metadata="${metadata},cuda-version=${CUDA_VERSION}"
    metadata="${metadata},include-pytorch=1"
    create_function="create_t4_instance"
  fi

  if [[ "${customization_script}" =~ "spark-rapids.sh" ]] ; then
    metadata="${metadata},rapids-runtime=SPARK"
    create_function="create_t4_instance"
  fi

  if [[ "${customization_script}" =~ "rapids.sh" ]] ; then
    metadata="${metadata},rapids-runtime=DASK"
    create_function="create_t4_instance"
  fi

  # check for known retry-able errors after failed completion
  local do_retry=1
  set -x
  while [[ "${do_retry}" == "1" ]]; do
    do_retry=0
    set +e
    "${create_function}" \
      --image-name           "${image_name}" \
      --customization-script "${customization_script}" \
      --service-account      "${GSA}" \
      --metadata             "${metadata}" \
      --zone                 "${custom_image_zone}" \
      --disk-size            "${disk_size_gb}" \
      --gcs-bucket           "${BUCKET}" \
      --subnet               "${SUBNET}" \
      ${OPTIONAL_COMPONENTS_ARG} \
      --shutdown-instance-timer-sec=30 \
      --no-smoke-test \
      ${extra_args}
    if [[ "$?" != "0" ]]; then
      local img_build_dir="$(ls -d /tmp/custom-image-${image_name}-*)"
      # retry if the startup-script.log file does not exist or is empty
      local startup_script_log="${img_build_dir}/logs/startup-script.log"
      if [[ ! -f "${startup_script_log}" ]] || [[ "$(wc -l < $startup-script.log)" == "0" ]]; then
        do_retry=1
        mkdir -p /tmp/old
        mv "${img_build_dir}" /tmp/old
      else
        exit 1
      fi
    fi
  done
  set +x
}

function generate_from_dataproc_version() { generate --dataproc-version "$1" ; }

function generate_from_prerelease_version() {
  # base image -> tensorflow
  local img_pfx="https://www.googleapis.com/compute/v1/projects/cloud-dataproc/global/images"
#  local src_timestamp="20250410-165100"
  local src_timestamp="20250505-045100"
  case "${dataproc_version}" in
#    "1.5-debian10"     ) image_uri="${img_pfx}/dataproc-1-5-deb10-${src_timestamp}-rc01"  ;;
#    "1.5-debian10"     ) image_uri="${img_pfx}/dataproc-1-5-deb10-20200820-160220-rc01"  ;;
#    "1.5-debian10"     ) image_uri="https://www.googleapis.com/compute/v1/projects/cloud-dataproc-ci/global/images/dataproc-1-5-deb10-20230909-165100-rc01" ;;
    "1.5-debian10"     ) image_uri="https://www.googleapis.com/compute/v1/projects/cloud-dataproc/global/images/dataproc-1-5-deb10-20230909-165100-rc01" ;;
    "2.0-debian10"     ) image_uri="${img_pfx}/dataproc-2-0-deb10-${src_timestamp}-rc01"  ;;
    "2.0-rocky8"       ) image_uri="${img_pfx}/dataproc-2-0-roc8-${src_timestamp}-rc01"   ;;
    "2.0-ubuntu18"     ) image_uri="${img_pfx}/dataproc-2-0-ubu18-${src_timestamp}-rc01"  ;;
    "2.1-debian11"     ) image_uri="${img_pfx}/dataproc-2-1-deb11-${src_timestamp}-rc01"  ;;
    "2.1-rocky8"       ) image_uri="${img_pfx}/dataproc-2-1-roc8-${src_timestamp}-rc01"   ;;
    "2.1-ubuntu20"     ) image_uri="${img_pfx}/dataproc-2-1-ubu20-${src_timestamp}-rc01"  ;;
    "2.1-ubuntu20-arm" ) image_uri="${img_pfx}/dataproc-2-1-ubu20-arm-${src_timestamp}-rc01"  ;;
    "2.2-debian12"     ) image_uri="${img_pfx}/dataproc-2-2-deb12-${src_timestamp}-rc01"  ;;
    "2.2-rocky9"       ) image_uri="${img_pfx}/dataproc-2-2-roc9-${src_timestamp}-rc01"   ;;
    "2.2-ubuntu22"     ) image_uri="${img_pfx}/dataproc-2-2-ubu22-${src_timestamp}-rc01"  ;;
    "2.3-debian12"     ) image_uri="${img_pfx}/dataproc-2-3-deb12-${src_timestamp}-rc01"  ;;
    "2.3-rocky9"       ) image_uri="${img_pfx}/dataproc-2-3-roc9-${src_timestamp}-rc01"   ;;
    "2.3-ubuntu22"     ) image_uri="${img_pfx}/dataproc-2-3-ubu22-${src_timestamp}-rc01"  ;;
    "2.3-ml-ubuntu22"  ) image_uri="${img_pfx}/dataproc-2-3-ml-ubu22-${src_timestamp}-rc01"  ;;
  esac
  generate --base-image-uri "${image_uri}"
}

function generate_from_base_purpose() {
#  local image_name="dataproc-${short_dp_ver//\./-}-${timestamp}-${PURPOSE}"
# https://pantheon.corp.google.com/compute/imagesDetail/projects/cloud-dataproc-ci/global/images/dataproc-2-0-deb10-20250422-193049-secure-boot?project=cloud-dataproc-ci
# https://www.googleapis.com/compute/v1/projects/dataproc-cloud-dataproc-ci/global/images/dataproc-2-0-deb10-20250422-193049-secure-boot
# https://www.googleapis.com/compute/v1/projects/cloud-dataproc-ci/global/images/dataproc-2-0-deb10-20250422-193049-secure-bootprojects/dataproc-${PROJECT_ID}/global/images"
#  local img_pfx="https://www.googleapis.com/compute/v1/projects/dataproc-${PROJECT_ID}/global/images"
  local img_pfx="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/images"
  generate --base-image-uri "${img_pfx}/dataproc-${short_dp_ver/\./-}-${timestamp}-${1}"
#  generate --base-image-uri "${img_pfx}/${1}-${dataproc_version/\./-}-${timestamp}"
}

# base image -> secure-boot

# Install secure-boot certs without customization
PURPOSE="secure-boot"
customization_script="examples/secure-boot/no-customization.sh"
time generate_from_dataproc_version "${dataproc_version}"

#time generate_from_prerelease_version "${dataproc_version}"

if version_ge "${IMAGE_VERSION}" "2.3" ; then

  ## run the installer for the DOCKER optional component
  PURPOSE="docker"
  OPTIONAL_COMPONENTS_ARG='--optional-components=DOCKER'
  customization_script="examples/secure-boot/no-customization.sh"
  time generate_from_base_purpose "secure-boot"

  ## run the installer for the ZEPPELIN optional component
  PURPOSE="zeppelin"
  OPTIONAL_COMPONENTS_ARG='--optional-components=ZEPPELIN'
  customization_script="examples/secure-boot/no-customization.sh"
  time generate_from_base_purpose "secure-boot"

  ## run the installer for the DOCKER,PIG optional components
  PURPOSE="docker-pig"
  OPTIONAL_COMPONENTS_ARG='--optional-components=PIG'
  customization_script="examples/secure-boot/no-customization.sh"
  time generate_from_base_purpose "docker"

fi

OPTIONAL_COMPONENTS_ARG=""

## Execute spark-rapids/spark-rapids.sh init action on base image
PURPOSE="cloud-sql-proxy"
customization_script="examples/secure-boot/cloud-sql-proxy.sh"
echo time generate_from_base_purpose "secure-boot"

# secure-boot -> tensorflow

case "${dataproc_version}" in
# DP_IMG_VER       RECOMMENDED_DISK_SIZE   DSK_SZ  D_USED   D_FREE  D%F     DATE_SAMPLED

  "2.0-debian10"     ) disk_size_gb="36" ;; #  35.20G  30.74G    2.91G  92% / # 20250507-083009-tf
  "2.0-rocky8"       ) disk_size_gb="43" ;; #  48.79G  36.34G   12.45G  75% / # 20250507-083009-tf
  "2.0-ubuntu18"     ) disk_size_gb="38" ;; #  36.65G  32.24G    4.39G  89% / # 20250507-083009-tf

  "2.1-debian11"     ) disk_size_gb="42" ;; #  41.11G  35.82G    3.50G  92% / # 20250507-083009-tf
  "2.1-rocky8"       ) disk_size_gb="45" ;; #  59.79G  38.41G   21.39G  65% / # 20250429-193537-tf
  "2.1-ubuntu20"     ) disk_size_gb="42" ;; #  47.31G  36.02G   11.27G  77% / # 20250507-083009-tf
  "2.1-ubuntu20-arm" ) disk_size_gb="45" ;; # 39.55G 39.39G   0.15G 100% / # pre-init-2-1-ubuntu20

  "2.2-debian12"     ) disk_size_gb="51" ;; #  58.82G  43.88G   12.44G  78% / # 20250429-193537-tf
  "2.2-rocky9"       ) disk_size_gb="51" ;; #  49.79G  43.51G    6.28G  88% / # 20250429-193537-tf
  "2.2-ubuntu22"     ) disk_size_gb="50" ;; #  48.28G  43.32G    4.94G  90% / # 20250429-193537-tf

  "2.3-debian12"     ) disk_size_gb="42" ;; #  41.11G  36.20G    3.12G  93% / # 20250507-083009-tf
  "2.3-rocky9"       ) disk_size_gb="44" ;; #  49.79G  37.82G   11.98G  76% / # 20250507-083009-tf
  "2.3-ubuntu22"     ) disk_size_gb="42" ;; #  40.52G  36.18G    4.33G  90% / # 20250507-083009-tf
  "2.3-ml-ubuntu22"  ) disk_size_gb="70" ;; #  40.52G  36.18G    4.33G  90% / # 20250507-083009-tf

esac

# Install GPU drivers + cuda + rapids + cuDNN + nccl + tensorflow + pytorch on dataproc base image
PURPOSE="tf"
customization_script="examples/secure-boot/install_gpu_driver.sh"
time generate_from_base_purpose "secure-boot"

## Execute spark-rapids/spark-rapids.sh init action on base image
PURPOSE="spark"
customization_script="examples/secure-boot/spark-rapids.sh"
time generate_from_base_purpose "tf"

## Execute spark-rapids/mig.sh init action on base image
PURPOSE="mig-pre-init"
customization_script="examples/secure-boot/mig.sh"
echo time generate_from_base_purpose "tf"

# tf image -> rapids
case "${dataproc_version}" in
  "2.0-debian10" ) disk_size_gb="41" ;; # 40.12G 37.51G   0.86G  98% / # rapids-pre-init-2-0-debian10
  "2.0-rocky8"   ) disk_size_gb="41" ;; # 38.79G 38.04G   0.76G  99% / # rapids-pre-init-2-0-rocky8
  "2.0-ubuntu18" ) disk_size_gb="40" ;; # 37.62G 36.69G   0.91G  98% / # rapids-pre-init-2-0-ubuntu18
  "2.1-debian11" ) disk_size_gb="44" ;; # 42.09G 39.77G   0.49G  99% / # rapids-pre-init-2-1-debian11
  "2.1-rocky8"   ) disk_size_gb="44" ;; # 43.79G 41.11G   2.68G  94% / # rapids-pre-init-2-1-rocky8
  "2.1-ubuntu20" ) disk_size_gb="45" ;; # 39.55G 39.39G   0.15G 100% / # rapids-pre-init-2-1-ubuntu20
  "2.1-ubuntu20-arm" ) disk_size_gb="45" ;; # 39.55G 39.39G   0.15G 100% / # pre-init-2-1-ubuntu20
  "2.2-debian12" ) disk_size_gb="46" ;; # 44.06G 41.73G   0.41G 100% / # rapids-pre-init-2-2-debian12
  "2.2-rocky9"   ) disk_size_gb="45" ;; # 44.79G 42.29G   2.51G  95% / # rapids-pre-init-2-2-rocky9
  "2.2-ubuntu22" ) disk_size_gb="46" ;; # 42.46G 41.97G   0.48G  99% / # rapids-pre-init-2-2-ubuntu22
esac

#disk_size_gb="45"

# Install dask with rapids on base image
PURPOSE="rapids"
customization_script="examples/secure-boot/rapids.sh"
echo time generate_from_base_purpose "tf"
#time generate_from_base_purpose "cuda-pre-init"

## Install dask without rapids on base image
PURPOSE="dask"
customization_script="examples/secure-boot/dask.sh"
echo time generate_from_base_purpose "secure-boot"
#time generate_from_base_purpose "cuda-pre-init"

# cuda image -> pytorch
case "${dataproc_version}" in
  "2.0-debian10"     ) disk_size_gb="44" ;; # 40.12G 37.51G   0.86G  98% / # pre-init-2-0-debian10
  "2.0-rocky8"       ) disk_size_gb="41" ;; # 38.79G 38.04G   0.76G  99% / # pre-init-2-0-rocky8
  "2.0-ubuntu18"     ) disk_size_gb="44" ;; # 37.62G 36.69G   0.91G  98% / # pre-init-2-0-ubuntu18
  "2.1-debian11"     ) disk_size_gb="44" ;; # 42.09G 39.77G   0.49G  99% / # pre-init-2-1-debian11
  "2.1-rocky8"       ) disk_size_gb="44" ;; # 43.79G 41.11G   2.68G  94% / # pre-init-2-1-rocky8
  "2.1-ubuntu20"     ) disk_size_gb="45" ;; # 39.55G 39.39G   0.15G 100% / # pre-init-2-1-ubuntu20
  "2.1-ubuntu20-arm" ) disk_size_gb="45" ;; # 39.55G 39.39G   0.15G 100% / # pre-init-2-1-ubuntu20
  "2.2-debian12"     ) disk_size_gb="48" ;; # 44.06G 41.73G   0.41G 100% / # pre-init-2-2-debian12
  "2.2-rocky9"       ) disk_size_gb="48" ;; # 44.79G 42.29G   2.51G  95% / # pre-init-2-2-rocky9
  "2.2-ubuntu22"     ) disk_size_gb="46" ;; # 42.46G 41.97G   0.48G  99% / # pre-init-2-2-ubuntu22
  "2.3-debian12"     ) disk_size_gb="42" ;; # 41.11G 36.20G   3.12G  93% / # 20250507-083009-tf
  "2.3-rocky9"       ) disk_size_gb="44" ;; # 49.79G 37.82G  11.98G  76% / # 20250507-083009-tf
  "2.3-ubuntu22"     ) disk_size_gb="42" ;; # 40.52G 36.18G   4.33G  90% / # 20250507-083009-tf
  "2.3-ml-ubuntu22"  ) disk_size_gb="60" ;; # 40.52G 36.18G   4.33G  90% / # 20250507-083009-tf
esac

## Install pytorch on base image
PURPOSE="pytorch"
customization_script="examples/secure-boot/pytorch.sh"
echo time generate_from_base_purpose "tf"

