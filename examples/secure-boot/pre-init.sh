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
# pre-init.sh <dataproc version> <customization script>

set -e

IMAGE_VERSION="$1"
if [[ -z "${IMAGE_VERSION}" ]] ; then
export IMAGE_VERSION="$(jq -r .IMAGE_VERSION env.json)" ; fi
export PROJECT_ID="$(jq    -r .PROJECT_ID    env.json)"
export PURPOSE="$(jq       -r .PURPOSE       env.json)"
export BUCKET="$(jq        -r .BUCKET        env.json)"
export ZONE="$(jq          -r .ZONE          env.json)"

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

case "${dataproc_version}" in
  "2.2-rocky9"   ) disk_size_gb="54" ;;
  "2.1-rocky8"   ) disk_size_gb="36" ;;
  "2.0-rocky8"   ) disk_size_gb="33" ;;
  "2.2-ubuntu22" ) disk_size_gb="40" ;;
  "2.1-ubuntu20" ) disk_size_gb="37" ;;
  "2.0-ubuntu18" ) disk_size_gb="37" ;;
  "2.2-debian12" ) disk_size_gb="40" ;;
  "2.1-debian11" ) disk_size_gb="40" ;;
  "2.0-debian10" ) disk_size_gb="40" ;;
esac

customization_script="${2:-empty.sh}"
echo "#!/bin/bash\necho no op" | dd of=empty.sh
#customization_script=empty.sh
image_name="${PURPOSE}-${dataproc_version/\./-}-$(date +%F-%H-%M)"

set -x +e
python generate_custom_image.py \
    --machine-type         "n1-highcpu-4" \
    --accelerator          "type=nvidia-tesla-t4" \
    --image-name           "${image_name}" \
    --dataproc-version     "${dataproc_version}" \
    --trusted-cert         "tls/db.der" \
    --customization-script "${customization_script}" \
    --service-account      "${GSA}" \
    --metadata             "${metadata}" \
    --zone                 "${custom_image_zone}" \
    --disk-size            "${disk_size_gb}" \
    --no-smoke-test \
    --gcs-bucket           "${BUCKET}" \
    --shutdown-instance-timer-sec=300
set +x
