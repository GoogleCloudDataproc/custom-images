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

test_inferred_subminor_version_debian() {
  local image_name="test-image-infer-subminor-${TEST_SUFFIX}"
  echo "Creating custom debian image with inferred subminor version: ${image_name}"
  # Expected image - 1.5.35-debian10 - dataproc-1-5-deb10-20210413-000000-rc01, as of 2021-06-30.
  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version '1.5-debian10' \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10 \
    --dry-run
}

test_inferred_subminor_version_ubuntu() {
  local image_name="test-image-wildcard-${TEST_SUFFIX}"
  echo "Creating custom ubuntu image with inferred subminor version: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version '1.5-ubuntu18' \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10 \
    --dry-run
}

test_inferred_subminor_version_centos() {
  local image_name="test-image-wildcard-${TEST_SUFFIX}"
  echo "Creating custom centos image with inferred subminor version: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version '1.5-centos8' \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10 \
    --dry-run
}

test_inferred_subminor_version_debian
test_inferred_subminor_version_ubuntu
test_inferred_subminor_version_centos

echo "All custom image tests with unspecified subminor dataproc versions succeeded"