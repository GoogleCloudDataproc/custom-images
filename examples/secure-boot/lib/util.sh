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
# Utility functions for secure-boot scripts

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure tmpdir is set
tmpdir="${tmpdir:-/tmp/secure-boot-$$}"
mkdir -p "${tmpdir}"

function print_status() {
  local message="$1"
  echo -n -e "${message}" >&2
}
export -f print_status

function report_result() {
  local result="$1"
  local log_path="$2" # Optional log path for failure details

  if [[ "${result}" == "Pass" || "${result}" == "Exists" || "${result}" == "Created" || "${result}" == "Deleted" || "${result}" == "Not Found" || "${result}" == "Done" ]]; then
    echo -e " [${GREEN}${result}${NC}]" >&2
  elif [[ "${result}" == "Fail" ]]; then
    echo -e " [${RED}${result}${NC}]" >&2
    if [[ -n "${log_path}" ]]; then
      echo -e "  ${YELLOW}-> Details in ${log_path}${NC}" >&2
    fi
  elif [[ "${result}" == "Skipped" ]]; then
    echo -e " [${BLUE}${result}${NC}]" >&2
  else
    echo -e " [${YELLOW}${result}${NC}]" >&2
  fi
}
export -f report_result


# Function to run a gcloud command and log it
function run_gcloud() {
  local log_file="$1"; shift
  local log_path="${REPRO_TMPDIR}/${log_file}"
  local cmd_array=("$@")

  print_status "  Executing: ${cmd_array[*]}..."

  "${cmd_array[@]}" > "${log_path}" 2>&1
  local retval=$?

  if [[ ${retval} -ne 0 ]]; then
    report_result "FAIL" "${log_path}"
    echo -e "${RED}ERROR: The following gcloud command failed:${NC}\n  ${cmd_array[*]}" >&2
    echo -e "${YELLOW}See log for details: ${log_path}${NC}" >&2
    echo -e "--- Log Content (${log_path}) ---" >&2
    cat "${log_path}" >&2
    echo -e "--- End Log Content ---" >&2
    # Specific check for auth issues still useful
    if grep -q -E "auth login|Application Default Credentials|problem refreshing your current auth tokens" "${log_path}"; then
      echo -e "${RED}HINT: This looks like an authentication issue.${NC}" >&2
      echo "  Inside the container, gcloud is not using the service account key as expected." >&2
      echo "  Ensure GOOGLE_APPLICATION_CREDENTIALS is set and the key is valid." >&2
    fi
  else
    report_result "OK"
  fi
  return ${retval}
}
export -f run_gcloud

# Function to run a gsutil command and log it
function run_gsutil() {
  local log_file="$1"; shift
  local cmd_str="$*"
  local log_path="${REPRO_TMPDIR}/${log_file}"

  print_status "  Executing: ${cmd_str}..."

  eval "${cmd_str}" > "${log_path}" 2>&1
  local retval=$?

  if [[ ${retval} -ne 0 ]]; then
    report_result "FAIL" "${log_path}"
    echo -e "${RED}ERROR: The following gsutil command failed:${NC}\n  ${cmd_str}" >&2
    echo -e "${YELLOW}See log for details: ${log_path}${NC}" >&2
    echo -e "--- Log Content (${log_path}) ---" >&2
    cat "${log_path}" >&2
    echo -e "--- End Log Content ---" >&2
  else
    report_result "OK"
  fi
  return ${retval}
}
export -f run_gsutil

function execute_with_retries() {
  set +x
  local -r cmd="$*"
  local install_log="${REPRO_TMPDIR}/install.log"

  for ((i = 0; i < 3; i++)); do
    if (( DEBUG != 0 )); then set -x; fi
    eval "${cmd}" > "${install_log}" 2>&1 && local retval=$? || local retval=$?
    if (( DEBUG != 0 )); then set +x; fi
    if [[ $retval == 0 ]] ; then return 0 ; fi
    sleep 5
  done
  echo "Command failed after multiple retries: ${cmd}" >&2
  echo "  -> Details in ${install_log}" >&2
  if (( DEBUG != 0 )); then cat "${install_log}" >&2; fi
  return 1
}
export -f execute_with_retries

function create_sentinel() {
  touch "${SENTINEL_DIR}/$1.$2"
}
export -f create_sentinel

function check_sentinel() {
  [[ -f "${SENTINEL_DIR}/$1.$2" ]]
}
export -f check_sentinel

function remove_sentinel() {
  rm -f "${SENTINEL_DIR}/$1.$2"
}
export -f remove_sentinel
