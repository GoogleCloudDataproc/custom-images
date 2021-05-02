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

test_script_with_environment_config_metadata() {
  local image_name="test-image-custom-conda-env-${TEST_SUFFIX}"
  echo "Creating custom image: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version 1.5.34-debian10 \
    --customization-script "${REPO_DIR}/scripts/customize_conda.sh" \
    --metadata "conda-component=MINICONDA3,conda-env-config-uri=gs://dataproc-integration-test/conda-integration-test/test-env-15.yaml" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10
}

test_script_with_packages_metadata() {
  local image_name="test-image-custom-conda-packages-${TEST_SUFFIX}"
  echo "Creating custom image: ${image_name}"

  python2 "${REPO_DIR}/generate_custom_image.py" \
    --image-name "${image_name}" \
    --dataproc-version 1.5.34-debian10 \
    --customization-script "${REPO_DIR}/scripts/customize_conda.sh" \
    --metadata "conda-component=MINICONDA3,conda-packages=pytorch:1.4.0_visions:0.7.1,pip-packages=tokenizers:0.10.1_numpy:1.19.2" \
    --zone "${TEST_ZONE}" \
    --gcs-bucket "${TEST_BUCKET}" \
    --shutdown-instance-timer-sec 10
}

test_script_with_environment_config_metadata
test_script_with_packages_metadata

echo "All customize conda script tests succeeded"
