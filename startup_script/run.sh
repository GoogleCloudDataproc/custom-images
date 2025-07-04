#!/bin/bash

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

# run.sh will be used by image build workflow to run custom initialization
# script when creating a custom image.
#
# Immediately after image build workflow creates an GCE instance, it will
# execute run.sh on the GCE instance that it just created:
# 1. Download user's custom init action script from cloud Storage bucket.
# 2. Run the custom init action script.
# 3. Check for init action script output, and print success or failure
#    message.
# 4. Shutdown GCE instance.

set -x

# get custom-sources-path
CUSTOM_SOURCES_PATH=$(/usr/share/google/get_metadata_value attributes/custom-sources-path)
# get time to wait for stdout to flush
SHUTDOWN_TIMER_IN_SEC=$(/usr/share/google/get_metadata_value attributes/shutdown-timer-in-sec)

USER_DATAPROC_COMPONENTS=$( /usr/share/google/get_metadata_value attributes/optional-components | tr '[:upper:]' '[:lower:]' | tr '.' ' ' || echo "")
DATAPROC_IMAGE_VERSION=$(/usr/share/google/get_metadata_value attributes/dataproc_dataproc_version | cut -c1-3 | tr '-' '.' || echo "")
DATAPROC_IMAGE_TYPE=$(/usr/share/google/get_metadata_value attributes/dataproc_image_type || echo "standard")
export REGION=$(/usr/share/google/get_metadata_value attributes/dataproc-region)
[[ -n "${DATAPROC_IMAGE_TYPE}" ]] # Sanity validation
export DATAPROC_IMAGE_TYPE
[[ "${DATAPROC_IMAGE_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]] # Sanity validation
export DATAPROC_IMAGE_VERSION
# Startup script that performs first boot configuration for Dataproc cluster.

ready=""

function version_le(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|head -n1)" ]]; }
function version_lt(){ [[ "$1" = "$2" ]]&& return 1 || version_le "$1" "$2";}

# With the 402.0.0 release of gcloud sdk, `gcloud storage` can be
# used as a more performant replacement for `gsutil`
if gcloud --help >/dev/null 2>&1 && gcloud storage --help >/dev/null 2>&1; then
  gsutil_cmd="gcloud storage"
  gsutil_cp_cmd="${gsutil_cmd} cp"
else
  gsutil_cmd="gsutil"
  gsutil_cp_cmd="${gsutil_cmd} -m cp"
fi

function wait_until_ready() {
  # For Ubuntu, wait until /snap is mounted, so that gsutil is unavailable.
  if [[ $(. /etc/os-release && echo "${ID}") == ubuntu ]]; then
    for i in {0..10}; do
      if command -v "${gsutil_cmd/ *}" >/dev/null; then
        ready="true"
        break
      fi

      sleep 5

      if ((i == 10)); then
        echo "BuildFailed: timed out waiting for gsutil to be available on Ubuntu."
      fi
    done
  else
    ready="true"
  fi
}

function download_scripts() {

  ${gsutil_cp_cmd} -r "${CUSTOM_SOURCES_PATH}/*" ./
}

function run_custom_script() {
  if ! download_scripts; then
    echo "BuildFailed: failed to download scripts from ${CUSTOM_SOURCES_PATH}."
    return 1
  fi

  # run init actions
  bash -x ./init_actions.sh

  # get return code
  RET_CODE=$?

  # print failure message if install fails
  if [[ $RET_CODE -ne 0 ]]; then
    echo "BuildFailed: Dataproc Initialization Actions Failed. Please check your initialization script."
  else
    echo "BuildSucceeded: Dataproc Initialization Actions Succeeded."
  fi
}

function cleanup() {
  # .config and .gsutil dirs are created by the gsutil command. It contains
  # transient authentication keys to access gcs bucket. The init_actions.sh and
  # run.sh are your customization and bootstrap scripts (this) which must be
  # removed after creating the image
  rm -rf ~/.config/ ~/.gsutil/
  rm ./init_actions.sh ./run.sh
}

function is_version_at_least() {
  local -r VERSION=$1
  if [[ $(echo "$DATAPROC_IMAGE_VERSION >= $VERSION" | bc -l) -eq 1 ]]; then
    return 0
  else
    return 1
  fi
}

function run_install_optional_components_script() {
  if ! is_version_at_least "2.3" || [[ -z "$USER_DATAPROC_COMPONENTS" ]]; then
    return
  fi

  (
    export BDUTIL_DIR="/usr/local/share/google/dataproc/bdutil"
    # Install Optional components
    set -Ee
    source /etc/environment
    source "${BDUTIL_DIR}/bdutil_env.sh"
    source "${BDUTIL_DIR}/bdutil_helpers.sh"
    source "${BDUTIL_DIR}/bdutil_metadata.sh"
    source "${BDUTIL_DIR}/bdutil_misc.sh"
    source "${BDUTIL_DIR}/components/components-helpers.sh"
    set -x

    export USER_DATAPROC_COMPONENTS=(${USER_DATAPROC_COMPONENTS})
    source "${BDUTIL_DIR}/install_optional_components.sh"
  )
  # get return code
  local RET_CODE=$?

  # print failure message if install fails
  if [[ $RET_CODE -ne 0 ]]; then
    echo "BuildFailed: Dataproc optional component installation Failed. Please check logs."
  else
    echo "BuildSucceeded: Dataproc optional component installation Succeeded."
  fi
}

function main() {
  wait_until_ready

  if [[ "${ready}" == "true" ]]; then
    run_install_optional_components_script
    run_custom_script
    cleanup
  fi

  echo "Sleep ${SHUTDOWN_TIMER_IN_SEC}s before shutting down..."
  echo "You can change the timeout value with --shutdown-instance-timer-sec"
  sleep "${SHUTDOWN_TIMER_IN_SEC}" # wait for stdout to flush
  shutdown -h now
}

main "$@"
