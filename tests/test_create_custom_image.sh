#!/usr/bin/env bash

# Copyright 2019 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the 'License');
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#            http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an 'AS IS' BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

this_dir=$(cd $(dirname ${BASH_SOURCE[0]}) >/dev/null 2>&1 && pwd)
repo_dir=$(realpath ${this_dir}/..)

daisy_path=$(which daisy)
if [[ -n "${daisy_path}" ]]; then
  suffix=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
  image_name=test-image-deb9-daisy-${suffix}
  echo "Creating custom Debian image with Daisy: ${image_name}"

  python2 ${repo_dir}/generate_custom_image.py \
    --image-name ${image_name} \
    --dataproc-version 1.4.5-debian9 \
    --daisy-path ${daisy_path} \
    --customization-script ${repo_dir}/examples/customization_script.sh \
    --zone us-west1-a \
    --gcs-bucket gs://dataproc-custom-images-presubmit \
    --shutdown-instance-timer-sec 30
  if [[ $? != 0 ]]; then
    echo "Creating image failed"
    exit 1
  fi
else
  echo "Daisy was not installed"
  exit 1
fi

suffix=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
image_name=test-image-deb9-${suffix}
echo "Creating custom Debian image: ${image_name}"

python2 ${repo_dir}/generate_custom_image.py \
  --image-name ${image_name} \
  --dataproc-version 1.4.5-debian9 \
  --customization-script ${repo_dir}/examples/customization_script.sh \
  --zone us-west1-a \
  --gcs-bucket gs://dataproc-custom-images-presubmit \
  --shutdown-instance-timer-sec 30
if [[ $? != 0 ]]; then
  echo "Creating image failed"
  exit 1
fi

suffix=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
image_name=test-image-ubu18-${suffix}
echo "Creating custom Ubuntu image: ${image_name}"

python2 ${repo_dir}/generate_custom_image.py \
  --image-name ${image_name} \
  --base-image-uri https://www.googleapis.com/compute/v1/projects/cloud-dataproc/global/images/dataproc-1-4-ubu18-20190606-000000-rc01 \
  --customization-script ${repo_dir}/examples/customization_script.sh \
  --zone us-west1-a \
  --gcs-bucket gs://dataproc-custom-images-presubmit \
  --shutdown-instance-timer-sec 30

if [[ $? != 0 ]]; then
  echo "Creating image failed"
  exit 1
fi
