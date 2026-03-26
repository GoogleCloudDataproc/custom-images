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

# Ensure gcloud is configured for the correct universe to prevent b/454030974
# First try the metadata key 'universe-domain' which we now pass explicitly
UNIVERSE_DOMAIN=$(/usr/share/google/get_metadata_value attributes/universe-domain || /usr/share/google/get_metadata_value attributes/universe_domain || echo "googleapis.com")
echo "startup-script: INFO: Ensuring gcloud universe_domain is set to ${UNIVERSE_DOMAIN}..."
if [[ "$(gcloud config get core/universe_domain 2>/dev/null)" != "${UNIVERSE_DOMAIN}" ]]; then
  echo "startup-script: INFO: Setting core/universe_domain to ${UNIVERSE_DOMAIN}"
  gcloud config set core/universe_domain "${UNIVERSE_DOMAIN}"
else
  echo "startup-script: INFO: core/universe_domain is already set to ${UNIVERSE_DOMAIN}."
fi

echo "startup-script: DEBUG: Starting startup_script/run.sh"

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
        echo "startup-script: BuildFailed: timed out waiting for gsutil to be available on Ubuntu."
      fi
    done
  else
    ready="true"
  fi
}

function download_scripts() {
  echo "startup-script: DEBUG: Attempting to download scripts from ${CUSTOM_SOURCES_PATH}"
  ${gsutil_cp_cmd} -r "${CUSTOM_SOURCES_PATH}/*" ./
  echo "startup-script: DEBUG: gsutil exit code: $?"
}

function setup_proxy() {
  # Always run setup/repair script if it exists
  if [[ -f ./gce-proxy-setup.sh ]]; then
    echo "startup-script: DEBUG: Running gce-proxy-setup.sh"
    bash -x ./gce-proxy-setup.sh
    if [[ $? -ne 0 ]]; then
      echo "startup-script: BuildFailed: gce-proxy-setup.sh failed."
      return 1
    fi
    echo "startup-script: DEBUG: Finished gce-proxy-setup.sh"
  fi
  # Ensure boto.cfg is repaired even if customizations fail later
  repair_boto
  return 0
}

function run_custom_script() {
  # run init actions
  echo "startup-script: DEBUG: Running init_actions.sh"
  bash -x ./init_actions.sh

  # return code
  return $?
}

function cleanup() {
  # .config and .gsutil dirs are created by the gsutil command. It contains
  # transient authentication keys to access gcs bucket. The init_actions.sh and
  # run.sh are your customization and bootstrap scripts (this) which must be
  # removed after creating the image
  rm -rf ~/.config/ ~/.gsutil/
  rm ./init_actions.sh ./run.sh
}

function repair_boto() {
  local boto_file="/etc/boto.cfg"
  if [[ -f "${boto_file}" ]]; then
    echo "startup-script: repair_boto: Repairing and deduplicating ${boto_file}" >&2
    
    # 1. Deduplicate sections (fix for DuplicateSectionError)
    perl -i -ne '
      if (/^\[(.*)\]/) {
        $section = $1;
        $skip = $seen{$section}++;
      }
      print unless $skip;
    ' "${boto_file}"
    
    # 2. Fix universe_domain if it is still a variable
    local universe_domain
    universe_domain=$(/usr/share/google/get_metadata_value attributes/universe-domain || echo "googleapis.com")
    UNIVERSE_DOMAIN="${universe_domain}" perl -i -pe 's/\$\{universe_domain\}/$ENV{UNIVERSE_DOMAIN}/g' "${boto_file}"
    # Also fix cases where it might have been partially expanded to storage.$
    UNIVERSE_DOMAIN="${universe_domain}" perl -i -pe 's/storage\.\$/storage.$ENV{UNIVERSE_DOMAIN}/g' "${boto_file}"

    # 3. Apply proxy if set in metadata
    local meta_http_proxy=$(/usr/share/google/get_metadata_value attributes/http-proxy || echo "")
    local meta_proxy_uri=$(/usr/share/google/get_metadata_value attributes/proxy-uri || echo "")
    local effective_proxy="${meta_http_proxy:-${meta_proxy_uri}}"
    
    if [[ -n "${effective_proxy}" ]] && [[ "${effective_proxy}" != ":" ]]; then
      local proxy_host="${effective_proxy%:*}"
      local proxy_port="${effective_proxy##*:}"
      
      sed -i -e '/^proxy =/d' -e '/^proxy_port =/d' "${boto_file}"
      if grep -q "^\[Boto\]" "${boto_file}"; then
        sed -i "/^\[Boto\]/a proxy = ${proxy_host}\nproxy_port = ${proxy_port}" "${boto_file}"
      else
        echo -e "\n[Boto]\nproxy = ${proxy_host}\nproxy_port = ${proxy_port}" >> "${boto_file}"
      fi
    fi
    echo "startup-script: repair_boto: Updated ${boto_file}" >&2
  fi
}

function patch_bdutil_universe() {
  # Apply workaround for b/454030974 directly to bdutil scripts if they exist
  local bdutil_universe_script="/usr/local/share/google/dataproc/bdutil/bdutil_universe.sh"
  if [[ -f "${bdutil_universe_script}" ]] && ! grep -q 'if [[ -z "${universe_domain}" ]]' "${bdutil_universe_script}"; then
    echo "startup-script: Patching ${bdutil_universe_script} to fix universe_domain resolution..."
    cp "${bdutil_universe_script}" "${bdutil_universe_script}.bak"
    cat << 'EOF' > /tmp/patch_universe.sh
#!/bin/bash
awk '
/function get_universe_domain\(\) \{/ {
    print
    print "  local universe_domain"
    print "  universe_domain=\"$(gcloud config get core/universe_domain 2> /dev/null || true)\""
    print "  if [[ -z \"${universe_domain}\" ]]; then"
    print "    echo \"googleapis.com\""
    print "  else"
    print "    echo \"${universe_domain}\""
    print "  fi"
    print "}"
    in_func = 1
    next
}
in_func && /^\}/ {
    in_func = 0
    next
}
!in_func { print }
' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
EOF
    bash /tmp/patch_universe.sh "${bdutil_universe_script}"
    rm -f /tmp/patch_universe.sh
  fi

  # Call repair_boto to ensure /etc/boto.cfg is clean before disk capture
  repair_boto
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
    set -a
    source /etc/environment
    set +a
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
    echo "startup-script: BuildFailed: Dataproc optional component installation Failed. Please check logs."
    exit ${RET_CODE}
  else
    echo "startup-script: BuildSucceeded: Dataproc optional component installation Succeeded."
  fi
}

function main() {
  wait_until_ready

  if [[ "${ready}" == "true" ]]; then
    if ! download_scripts; then
      echo "startup-script: BuildFailed: failed to download scripts from ${CUSTOM_SOURCES_PATH}."
      exit 1
    fi

    if ! setup_proxy; then
      exit 1
    fi

    run_install_optional_components_script
    run_custom_script
    local script_ret_code=$?

    patch_bdutil_universe
    cleanup

    if [[ ${script_ret_code} -ne 0 ]]; then
      echo "startup-script: BuildFailed: Customization failed."
      exit 1
    else
      echo "startup-script: BuildSucceeded: Customization complete."
    fi
  fi

  echo "startup-script: Sleep ${SHUTDOWN_TIMER_IN_SEC}s before shutting down..."
  echo "You can change the timeout value with --shutdown-instance-timer-sec"
  sleep "${SHUTDOWN_TIMER_IN_SEC}" # wait for stdout to flush
  shutdown -h now
}

main "$@"
