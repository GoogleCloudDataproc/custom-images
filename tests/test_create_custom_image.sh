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

set -euxo pipefail

readonly CURRENT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
readonly REPO_DIR=$(realpath "${CURRENT_DIR}/..")

readonly TEST_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
readonly TEST_BUCKET="gs://dataproc-custom-images-presubmit"
readonly TEST_ZONE="us-central1-a"

test_debian_with_image_version() {
  local image_name="test-image-deb9-${TEST_SUFFIX}"
  echo "Creating custom Debian image: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version 1.4.15-debian9 \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --metadata "key1=value1,key2=value2" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10
}

test_ubuntu_with_image_uri() {
  local image_name="test-image-ubu18-${TEST_SUFFIX}"
  echo "Creating custom Ubuntu image: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --base-image-uri projects/cloud-dataproc/global/images/dataproc-1-4-ubu18-20190606-000000-rc01 \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --metadata "key1=value1,key2=value2" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10
}

test_extra_sources() {
  local image_name="test-image-extra-src-${TEST_SUFFIX}"
  echo "Creating custom image: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version 1.4.15-ubuntu18 \
    --customization-script "${REPO_DIR}/tests/data/customization_script_with_extra_sources.sh" \
    --metadata "key1=value1,key2=value2" \
    --extra-sources "{\"extra/source.txt\": \"${REPO_DIR}/tests/data/extra_source.txt\"}" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10
}

test_debian_with_image_version
test_ubuntu_with_image_uri
test_extra_sources

echo "All custom image tests succedded"
