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

test_wildcard_patch_version_debian() {
  local image_name="test-image-wildcard-${TEST_SUFFIX}"
  echo "Creating custom debian image with wildcard patch version: ${image_name}"
  # Expected image - 1.3.88-debian10 - dataproc-1-3-deb10-20210311-093551-rc01
  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version '1.3.*-debian10' \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10 \
    --dry-run
}

test_wildcard_minor_and_patch_version_debian() {
  local image_name="test-image-wildcard-${TEST_SUFFIX}"
  echo "Creating custom debian image with wildcard minor and patch versions: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version '1.*.*-debian10' \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10 \
    --dry-run
}

test_wildcard_ubuntu() {
  local image_name="test-image-wildcard-${TEST_SUFFIX}"
  echo "Creating custom ubuntu image with wildcard minor and patch versions: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version '1.*.*-ubuntu18' \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10 \
    --dry-run
}

test_wildcard_centos() {
  local image_name="test-image-wildcard-${TEST_SUFFIX}"
  echo "Creating custom centos image with wildcard minor and patch versions: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version '1.*.*-centos8' \
    --customization-script "${REPO_DIR}/examples/customization_script.sh" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10 \
    --dry-run
}

test_wildcard_patch_version_debian
test_wildcard_minor_and_patch_version_debian
test_wildcard_ubuntu
test_wildcard_centos

echo "All custom image tests with wildcard dataproc versions succeeded"