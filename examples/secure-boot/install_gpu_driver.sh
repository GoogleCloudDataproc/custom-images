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
# This script installs NVIDIA GPU drivers and collects GPU utilization metrics.

set -xeuo pipefail

function os_id()       { grep '^ID='               /etc/os-release | cut -d= -f2 | xargs ; }
function os_version()  { grep '^VERSION_ID='       /etc/os-release | cut -d= -f2 | xargs ; }
function os_codename() { grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | xargs ; }

function version_ge(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|tail -n1)" ]]; }
function version_gt(){ [[ "$1" = "$2" ]]&& return 1 || version_ge "$1" "$2";}
function version_le(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|head -n1)" ]]; }
function version_lt(){ [[ "$1" = "$2" ]]&& return 1 || version_le "$1" "$2";}

readonly -A supported_os=(
  ['debian']="10 11 12"
  ['rocky']="8 9"
  ['ubuntu']="18.04 20.04 22.04"
)

# dynamically define OS version test utility functions
if [[ "$(os_id)" == "rocky" ]];
  then _os_version=$(os_version | sed -e 's/[^0-9].*$//g')
  else _os_version="$(os_version)"
fi
for os_id_val in 'rocky' 'ubuntu' 'debian' ; do
  eval "function is_${os_id_val}() { [[ \"$(os_id)\" == '${os_id_val}' ]] ; }"

  for osver in $(echo "${supported_os["${os_id_val}"]}") ; do
    eval "function is_${os_id_val}${osver%%.*}() { is_${os_id_val} && [[ \"${_os_version}\" == \"${osver}\" ]] ; }"
    eval "function ge_${os_id_val}${osver%%.*}() { is_${os_id_val} && version_ge \"${_os_version}\" \"${osver}\" ; }"
    eval "function le_${os_id_val}${osver%%.*}() { is_${os_id_val} && version_le \"${_os_version}\" \"${osver}\" ; }"
  done
done

function is_debuntu()  {  is_debian || is_ubuntu ; }

function os_vercat()   {
  if   is_ubuntu ; then os_version | sed -e 's/[^0-9]//g'
  elif is_rocky  ; then os_version | sed -e 's/[^0-9].*$//g'
                   else os_version ; fi ; }

function repair_old_backports {
  if ! is_debuntu ; then return ; fi
  # This script uses 'apt-get update' and is therefore potentially dependent on
  # backports repositories which have been archived.  In order to mitigate this
  # problem, we will use archive.debian.org for the oldoldstable repo

  # https://github.com/GoogleCloudDataproc/initialization-actions/issues/1157
  debdists="https://deb.debian.org/debian/dists"
  oldoldstable=$(curl ${curl_retry_args[@]} "${debdists}/oldoldstable/Release" | awk '/^Codename/ {print $2}');
  oldstable=$(   curl ${curl_retry_args[@]} "${debdists}/oldstable/Release"    | awk '/^Codename/ {print $2}');
  stable=$(      curl ${curl_retry_args[@]} "${debdists}/stable/Release"       | awk '/^Codename/ {print $2}');

  matched_files=( $(test -d /etc/apt && grep -rsil '\-backports' /etc/apt/sources.list*||:) )

  for filename in "${matched_files[@]}"; do
    # Fetch from archive.debian.org for ${oldoldstable}-backports
    perl -pi -e "s{^(deb[^\s]*) https?://[^/]+/debian ${oldoldstable}-backports }
                  {\$1 https://archive.debian.org/debian ${oldoldstable}-backports }g" "${filename}"
  done
}

function print_metadata_value() {
  local readonly tmpfile=$(mktemp)
  http_code=$(curl -f "${1}" -H "Metadata-Flavor: Google" -w "%{http_code}" \
    -s -o ${tmpfile} 2>/dev/null)
  local readonly return_code=$?
  # If the command completed successfully, print the metadata value to stdout.
  if [[ ${return_code} == 0 && ${http_code} == 200 ]]; then
    cat ${tmpfile}
  fi
  rm -f ${tmpfile}
  return ${return_code}
}

function print_metadata_value_if_exists() {
  local return_code=1
  local readonly url=$1
  print_metadata_value ${url}
  return_code=$?
  return ${return_code}
}

# replicates /usr/share/google/get_metadata_value
function get_metadata_value() {
  local readonly varname=$1
  local -r MDS_PREFIX=http://metadata.google.internal/computeMetadata/v1
  # Print the instance metadata value.
  print_metadata_value_if_exists ${MDS_PREFIX}/instance/${varname}
  return_code=$?
  # If the instance doesn't have the value, try the project.
  if [[ ${return_code} != 0 ]]; then
    print_metadata_value_if_exists ${MDS_PREFIX}/project/${varname}
    return_code=$?
  fi
  return ${return_code}
}

function get_metadata_attribute() {
  local -r attribute_name="$1"
  local -r default_value="${2:-}"
  set +e
  get_metadata_value "attributes/${attribute_name}" || echo -n "${default_value}"
  set -e
}

OS_NAME="$(lsb_release -is | tr '[:upper:]' '[:lower:]')"
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
readonly OS_NAME

# node role
ROLE="$(get_metadata_attribute dataproc-role)"
readonly ROLE

# CUDA version and Driver version
# https://docs.nvidia.com/deploy/cuda-compatibility/
# https://docs.nvidia.com/deeplearning/frameworks/support-matrix/index.html
# https://developer.nvidia.com/cuda-downloads

# Minimum supported version for open kernel driver is 515.43.04
# https://github.com/NVIDIA/open-gpu-kernel-modules/tags
readonly -A DRIVER_FOR_CUDA=(
    ["10.0"]="410.48" ["10.1"]="418.87.00" ["10.2"]="440.33.01"
    ["11.1"]="455.45.01" ["11.2"]="460.91.03" ["11.3"]="465.31"
    ["11.4"]="470.256.02" ["11.5"]="495.46" ["11.6"]="510.108.03"
    ["11.7"]="515.65.01" ["11.8"]="525.147.05" ["12.0"]="525.147.05"
    ["12.1"]="530.30.02" ["12.2"]="535.216.01" ["12.3"]="545.29.06"
    ["12.4"]="550.135" ["12.5"]="550.142" ["12.6"]="550.142"
    ["12.8"]="570.211.01" ["12.9"]="575.64.05"
    ["13.0"]="580.126.16" ["13.1"]="590.48.01"
)
readonly -A DRIVER_SUBVER=(
    ["410"]="410.104" ["415"]="415.27" ["418"]="418.113"
    ["430"]="430.64" ["435"]="435.21" ["440"]="440.100"
    ["450"]="450.119.03" ["455"]="455.45.01" ["460"]="460.91.03"
    ["465"]="465.31" ["470"]="470.256.02" ["495"]="495.46"
    ["510"]="510.108.03" ["515"]="515.48.07" ["520"]="525.147.05"
    ["525"]="525.147.05" ["535"]="535.216.01" ["545"]="545.29.06"
    ["550"]="550.142" ["555"]="555.58.02" ["560"]="560.35.03"
    ["565"]="565.77" ["570"]="570.211.01" ["575"]="575.64.05"
    ["580"]="580.126.16" ["590"]="590.48.01"
)
# https://developer.nvidia.com/cudnn-downloads
readonly -A CUDNN_FOR_CUDA=(
    ["10.0"]="7.4.1" ["10.1"]="7.6.4" ["10.2"]="7.6.5"
    ["11.0"]="8.0.4" ["11.1"]="8.0.5" ["11.2"]="8.1.1"
    ["11.3"]="8.2.1" ["11.4"]="8.2.4.15" ["11.5"]="8.3.1.22"
    ["11.6"]="8.4.0.27" ["11.7"]="8.9.7.29" ["11.8"]="9.5.1.17"
    ["12.0"]="8.8.1.3" ["12.1"]="8.9.3.28" ["12.2"]="8.9.5"
    ["12.3"]="9.0.0.306" ["12.4"]="9.1.0.70" ["12.5"]="9.2.1.18"
    ["12.6"]="9.6.0.74" ["12.8"]="9.8.0.87" ["12.9"]="9.10.2.21"
    ["13.0"]="9.14.0.64" ["13.1"]="9.17.0.29"
)
# https://developer.nvidia.com/nccl/nccl-download
readonly -A NCCL_FOR_CUDA=(
    ["10.0"]="2.3.7" ["10.1"]= ["11.0"]="2.7.8" ["11.1"]="2.8.3"
    ["11.2"]="2.8.4" ["11.3"]="2.9.9" ["11.4"]="2.11.4"
    ["11.5"]="2.11.4" ["11.6"]="2.12.10" ["11.7"]="2.12.12"
    ["11.8"]="2.21.5" ["12.0"]="2.16.5" ["12.1"]="2.18.3"
    ["12.2"]="2.19.3" ["12.3"]="2.19.4" ["12.4"]="2.23.4"
    ["12.5"]="2.22.3" ["12.6"]="2.23.4" ["12.8"]="2.25.1"
    ["12.9"]="2.27.3" ["13.0"]="2.27.7" ["13.1"]="2.29.2"
)
readonly -A CUDA_SUBVER=(
    ["10.0"]="10.0.130" ["10.1"]="10.1.234" ["10.2"]="10.2.89"
    ["11.0"]="11.0.3" ["11.1"]="11.1.1" ["11.2"]="11.2.2"
    ["11.3"]="11.3.1" ["11.4"]="11.4.4" ["11.5"]="11.5.2"
    ["11.6"]="11.6.2" ["11.7"]="11.7.1" ["11.8"]="11.8.0"
    ["12.0"]="12.0.1" ["12.1"]="12.1.1" ["12.2"]="12.2.2"
    ["12.3"]="12.3.2" ["12.4"]="12.4.1" ["12.5"]="12.5.1"
    ["12.6"]="12.6.3" ["12.8"]="12.8.1" ["12.9"]="12.9.1"
    ["13.0"]="13.0.2" ["13.1"]="13.1.1"
)

function set_cuda_version() {
  case "${DATAPROC_IMAGE_VERSION}" in
    "1.5" ) DEFAULT_CUDA_VERSION="11.6.2" ;;
    "2.0" ) DEFAULT_CUDA_VERSION="12.1.1" ;; # Cuda 12.1.1 - Driver v530.30.02 is the latest version supported by Ubuntu 18)
    "2.1" ) DEFAULT_CUDA_VERSION="12.4.1" ;;
    "2.2" ) DEFAULT_CUDA_VERSION="13.1.0" ;;
    "2.3" ) DEFAULT_CUDA_VERSION="13.1.0" ;;
    *   )
      echo "unrecognized Dataproc image version: ${DATAPROC_IMAGE_VERSION}"
      exit 1
      ;;
  esac
  local cuda_url
  cuda_url=$(get_metadata_attribute 'cuda-url' '')
  if [[ -n "${cuda_url}" ]] ; then
    # if cuda-url metadata variable has been passed, extract default version from url
    local CUDA_URL_VERSION
    CUDA_URL_VERSION="$(echo "${cuda_url}" | perl -pe 's{^.*/cuda_(\d+\.\d+\.\d+)_\d+\.\d+\.\d+_linux.run$}{$1}')"
    if [[ "${CUDA_URL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ; then
      DEFAULT_CUDA_VERSION="${CUDA_URL_VERSION}"
    fi
  fi
  readonly DEFAULT_CUDA_VERSION

  CUDA_VERSION=$(get_metadata_attribute 'cuda-version' "${DEFAULT_CUDA_VERSION}")
  if test -n "$(echo "${CUDA_VERSION}" | perl -ne 'print if /\d+\.\d+\.\d+/')" ; then
    CUDA_FULL_VERSION="${CUDA_VERSION}"
    CUDA_VERSION="${CUDA_VERSION%.*}"
  fi
  readonly CUDA_VERSION
  if ( ! test -v CUDA_FULL_VERSION ) ; then
    CUDA_FULL_VERSION=${CUDA_SUBVER["${CUDA_VERSION}"]}
  fi
  readonly CUDA_FULL_VERSION
}

function is_cuda12() { [[ "${CUDA_VERSION%%.*}" == "12" ]] ; }
function le_cuda12() { version_le "${CUDA_VERSION%%.*}" "12" ; }
function ge_cuda12() { version_ge "${CUDA_VERSION%%.*}" "12" ; }

function is_cuda11() { [[ "${CUDA_VERSION%%.*}" == "11" ]] ; }
function le_cuda11() { version_le "${CUDA_VERSION%%.*}" "11" ; }
function ge_cuda11() { version_ge "${CUDA_VERSION%%.*}" "11" ; }

function set_driver_version() {
  local gpu_driver_url
  gpu_driver_url=$(get_metadata_attribute 'gpu-driver-url' '')

  local cuda_url
  cuda_url=$(get_metadata_attribute 'cuda-url' '')

  local nv_xf86_x64_base="https://us.download.nvidia.com/XFree86/Linux-x86_64"

  local DEFAULT_DRIVER
  # Take default from gpu-driver-url metadata value
  if [[ -n "${gpu_driver_url}" ]] ; then
    DRIVER_URL_DRIVER_VERSION="$(echo "${gpu_driver_url}" | perl -pe 's{^.*/NVIDIA-Linux-x86_64-(\d+\.\d+\.\d+).run$}{$1}')"
    if [[ "${DRIVER_URL_DRIVER_VERSION}" =~ ^[0-9]+.*[0-9]$ ]] ; then DEFAULT_DRIVER="${DRIVER_URL_DRIVER_VERSION}" ; fi
  # Take default from cuda-url metadata value as a backup
  elif [[ -n "${cuda_url}" ]] ; then
    local CUDA_URL_DRIVER_VERSION="$(echo "${cuda_url}" | perl -pe 's{^.*/cuda_\d+\.\d+\.\d+_(\d+\.\d+\.\d+)_linux.run$}{$1}')"
    if [[ "${CUDA_URL_DRIVER_VERSION}" =~ ^[0-9]+.*[0-9]$ ]] ; then
      major_driver_version="${CUDA_URL_DRIVER_VERSION%%.*}"
      driver_max_maj_version=${DRIVER_SUBVER["${major_driver_version}"]}
      if curl ${curl_retry_args[@]} --head "${nv_xf86_x64_base}/${CUDA_URL_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${CUDA_URL_DRIVER_VERSION}.run" | grep -E -q 'HTTP.*200' ; then
        # use the version indicated by the cuda url as the default if it exists
        DEFAULT_DRIVER="${CUDA_URL_DRIVER_VERSION}"
      elif curl ${curl_retry_args[@]} --head "${nv_xf86_x64_base}/${driver_max_maj_version}/NVIDIA-Linux-x86_64-${driver_max_maj_version}.run" | grep -E -q 'HTTP.*200' ; then
        # use the maximum sub-version available for the major version indicated in cuda url as the default
        DEFAULT_DRIVER="${driver_max_maj_version}"
      fi
    fi
  fi

  if ( ! test -v DEFAULT_DRIVER ) ; then
    # If a default driver version has not been extracted, use the default for this version of CUDA
    DEFAULT_DRIVER=${DRIVER_FOR_CUDA["${CUDA_VERSION}"]}
  fi

  DRIVER_VERSION=$(get_metadata_attribute 'gpu-driver-version' "${DEFAULT_DRIVER}")

  readonly DRIVER_VERSION
  readonly DRIVER="${DRIVER_VERSION%%.*}"

  export DRIVER_VERSION DRIVER

  gpu_driver_url="${nv_xf86_x64_base}/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"

  # GCS Cache Check Logic
  local driver_filename
  driver_filename=$(basename "${gpu_driver_url}")
  local gcs_cache_path="${pkg_bucket}/nvidia/${driver_filename}"

  echo "Checking for cached NVIDIA driver at: ${gcs_cache_path}"

  if ! ${gsutil_stat_cmd} "${gcs_cache_path}" 2>/dev/null; then
    echo "Driver not found in GCS cache. Validating URL: ${gpu_driver_url}"
    # Use curl to check if the URL is valid (HEAD request)
    if curl -I ${curl_retry_args[@]} "${gpu_driver_url}" 2>/dev/null | grep -E -q 'HTTP.*200'; then
      echo "NVIDIA URL is valid. Downloading to cache..."
      local temp_driver_file="${tmpdir}/${driver_filename}"

      # Download the file
      echo "Downloading from ${gpu_driver_url} to ${temp_driver_file}"
      if curl ${curl_retry_args[@]} -o "${temp_driver_file}" "${gpu_driver_url}"; then
        echo "Download complete. Uploading to ${gcs_cache_path}"
        # Upload to GCS
        if ${gsutil_cmd} cp "${temp_driver_file}" "${gcs_cache_path}"; then
          echo "Successfully cached to GCS."
          rm -f "${temp_driver_file}"
        else
          echo "ERROR: Failed to upload driver to GCS: ${gcs_cache_path}"
          rm -f "${temp_driver_file}"
          exit 1
        fi
      else
        echo "ERROR: Failed to download driver from NVIDIA: ${gpu_driver_url}"
        rm -f "${temp_driver_file}" # File might not exist if curl failed early
        exit 1
      fi
    else
      echo "ERROR: NVIDIA driver URL is not valid or accessible: ${gpu_driver_url}"
      exit 1
    fi
  else
    echo "Driver found in GCS cache: ${gcs_cache_path}"
  fi
  # End of GCS Cache Check Logic
}

function set_cudnn_version() {
  readonly MIN_ROCKY8_CUDNN8_VERSION="8.0.5.39"
  readonly DEFAULT_CUDNN8_VERSION="8.3.1.22"
  readonly DEFAULT_CUDNN9_VERSION="9.1.0.70"

  # Parameters for NVIDIA-provided cuDNN library
  readonly DEFAULT_CUDNN_VERSION=${CUDNN_FOR_CUDA["${CUDA_VERSION}"]}
  CUDNN_VERSION=$(get_metadata_attribute 'cudnn-version' "${DEFAULT_CUDNN_VERSION}")
  # The minimum cuDNN version supported by rocky is ${MIN_ROCKY8_CUDNN8_VERSION}
  if ( is_rocky  && version_lt "${CUDNN_VERSION}" "${MIN_ROCKY8_CUDNN8_VERSION}" ) ; then
    CUDNN_VERSION="${MIN_ROCKY8_CUDNN8_VERSION}"
  elif (ge_ubuntu20 || ge_debian12) && is_cudnn8 ; then
    # cuDNN v8 is not distribution for ubuntu20+, debian12
    CUDNN_VERSION="${DEFAULT_CUDNN9_VERSION}"
  elif (le_ubuntu18 || le_debian11) && is_cudnn9 ; then
    # cuDNN v9 is not distributed for ubuntu18, debian10, debian11 ; fall back to 8
    CUDNN_VERSION="8.8.0.121"
  fi
  readonly CUDNN_VERSION
}

function is_cudnn8() { [[ "${CUDNN_VERSION%%.*}" == "8" ]] ; }
function is_cudnn9() { [[ "${CUDNN_VERSION%%.*}" == "9" ]] ; }

# Short name for urls
if is_ubuntu22  ; then
    # at the time of writing 20241125 there is no ubuntu2204 in the index of repos at
    # https://developer.download.nvidia.com/compute/machine-learning/repos/
    # use packages from previous release until such time as nvidia
    # release ubuntu2204 builds

    nccl_shortname="ubuntu2004"
    shortname="$(os_id)$(os_vercat)"
elif ge_rocky9 ; then
    # use packages from previous release until such time as nvidia
    # release rhel9 builds

    nccl_shortname="rhel8"
    shortname="rhel9"
elif is_rocky ; then
    shortname="$(os_id | sed -e 's/rocky/rhel/')$(os_vercat)"
    nccl_shortname="${shortname}"
else
    shortname="$(os_id)$(os_vercat)"
    nccl_shortname="${shortname}"
fi

function set_nv_urls() {
  # Parameters for NVIDIA-provided package repositories
  readonly NVIDIA_BASE_DL_URL='https://developer.download.nvidia.com/compute'
  readonly NVIDIA_REPO_URL="${NVIDIA_BASE_DL_URL}/cuda/repos/${shortname}/x86_64"

  # Parameter for NVIDIA-provided Rocky Linux GPU driver
  readonly NVIDIA_ROCKY_REPO_URL="${NVIDIA_REPO_URL}/cuda-${shortname}.repo"
}

function set_cuda_runfile_url() {
  local MAX_DRIVER_VERSION
  local MAX_CUDA_VERSION

  MIN_OPEN_DRIVER_VER="515.43.04"
  local MIN_DRIVER_VERSION="${MIN_OPEN_DRIVER_VER}"
  local MIN_CUDA_VERSION="11.7.1" # matches MIN_OPEN_DRIVER_VER

  if is_cuda12 ; then
    if is_debian12 ; then
      MIN_DRIVER_VERSION="545.23.06"
      MIN_CUDA_VERSION="12.3.0"
    elif is_debian10 ; then
      MAX_DRIVER_VERSION="555.42.02"
      MAX_CUDA_VERSION="12.5.0"
    elif is_ubuntu18 ; then
      MAX_DRIVER_VERSION="530.30.02"
      MAX_CUDA_VERSION="12.1.1"
    fi
  elif version_ge "${CUDA_VERSION}" "${MIN_CUDA_VERSION}" ; then
    if le_debian10 ; then
      # cuda 11 is not supported for <= debian10
      MAX_CUDA_VERSION="0"
      MAX_DRIVER_VERSION="0"
    fi
  else
    echo "Minimum CUDA version supported is ${MIN_CUDA_VERSION}.  Specified: ${CUDA_VERSION}"
  fi

  if version_lt "${CUDA_VERSION}" "${MIN_CUDA_VERSION}" ; then
    echo "Minimum CUDA version for ${shortname} is ${MIN_CUDA_VERSION}.  Specified: ${CUDA_VERSION}"
  elif ( test -v MAX_CUDA_VERSION && version_gt "${CUDA_VERSION}" "${MAX_CUDA_VERSION}" ) ; then
    echo "Maximum CUDA version for ${shortname} is ${MAX_CUDA_VERSION}.  Specified: ${CUDA_VERSION}"
  fi
  if version_lt "${DRIVER_VERSION}" "${MIN_DRIVER_VERSION}" ; then
    echo "Minimum kernel driver version for ${shortname} is ${MIN_DRIVER_VERSION}.  Specified: ${DRIVER_VERSION}"
  elif ( test -v MAX_DRIVER_VERSION && version_gt "${DRIVER_VERSION}" "${MAX_DRIVER_VERSION}" ) ; then
    echo "Maximum kernel driver version for ${shortname} is ${MAX_DRIVER_VERSION}.  Specified: ${DRIVER_VERSION}"
  fi

  # driver version named in cuda runfile filename
  # (these may not be actual driver versions - see https://us.download.nvidia.com/XFree86/Linux-x86_64/)
  readonly -A drv_for_cuda=(
      ["10.0.130"]="410.48"
      ["10.1.234"]="418.87.00"
      ["10.2.89"]="440.33.01"
      ["11.0.3"]="450.51.06"
      ["11.1.1"]="455.32.00"
      ["11.2.2"]="460.32.03"
      ["11.3.1"]="465.19.01"
      ["11.4.4"]="470.82.01"
      ["11.5.2"]="495.29.05"
      ["11.6.2"]="510.47.03"
      ["11.7.0"]="515.43.04" ["11.7.1"]="515.65.01"
      ["11.8.0"]="520.61.05"
      ["12.0.0"]="525.60.13" ["12.0.1"]="525.85.12"
      ["12.1.0"]="530.30.02" ["12.1.1"]="530.30.02"
      ["12.2.0"]="535.54.03" ["12.2.1"]="535.86.10" ["12.2.2"]="535.104.05"
      ["12.3.0"]="545.23.06" ["12.3.1"]="545.23.08" ["12.3.2"]="545.23.08"
      ["12.4.0"]="550.54.14" ["12.4.1"]="550.54.15" # 550.54.15 is not a driver indexed at https://us.download.nvidia.com/XFree86/Linux-x86_64/
      ["12.5.0"]="555.42.02" ["12.5.1"]="555.42.06" # 555.42.02 is indexed, 555.42.06 is not
      ["12.6.0"]="560.28.03" ["12.6.1"]="560.35.03" ["12.6.2"]="560.35.03" ["12.6.3"]="560.35.05"
      ["12.8.0"]="570.86.10" ["12.8.1"]="570.124.06"
      ["12.9.0"]="575.51.03" ["12.9.1"]="575.57.08"
      ["13.0.0"]="580.65.06" ["13.0.1"]="580.82.07" ["13.0.2"]="580.95.05"
      ["13.1.0"]="590.44.01"
  )

  # Verify that the file with the indicated combination exists
  local drv_ver=${drv_for_cuda["${CUDA_FULL_VERSION}"]}
  CUDA_RUNFILE="cuda_${CUDA_FULL_VERSION}_${drv_ver}_linux.run"
  local CUDA_RELEASE_BASE_URL="${NVIDIA_BASE_DL_URL}/cuda/${CUDA_FULL_VERSION}"
  local DEFAULT_NVIDIA_CUDA_URL="${CUDA_RELEASE_BASE_URL}/local_installers/${CUDA_RUNFILE}"

  NVIDIA_CUDA_URL=$(get_metadata_attribute 'cuda-url' "${DEFAULT_NVIDIA_CUDA_URL}")
  readonly NVIDIA_CUDA_URL

  CUDA_RUNFILE="$(echo ${NVIDIA_CUDA_URL} | perl -pe 's{^.+/}{}')"
  readonly CUDA_RUNFILE
  export local_cuda_runfile="${tmpdir}/${CUDA_RUNFILE}"
  local gcs_cache_path="${pkg_bucket}/nvidia/${CUDA_RUNFILE}" # Corrected path

  echo "Checking for cached CUDA runfile at: ${gcs_cache_path}"
  if ${gsutil_stat_cmd} "${gcs_cache_path}" > /dev/null 2>&1; then
    echo "CUDA runfile found in GCS cache. Downloading from ${gcs_cache_path}"
    if ! ${gsutil_cmd} cp "${gcs_cache_path}" "${local_cuda_runfile}"; then
      echo "ERROR: Failed to download CUDA runfile from GCS cache."
      exit 1
    fi
  else
    echo "CUDA runfile not found in GCS cache. Downloading from NVIDIA: ${NVIDIA_CUDA_URL}"

    # Check if URL is valid before downloading
    if ! curl ${curl_retry_args[@]} --head "${NVIDIA_CUDA_URL}" 2>/dev/null | grep -E -q 'HTTP.*200'; then
      echo "ERROR: CUDA runfile URL is NOT valid or not reachable: ${NVIDIA_CUDA_URL}"
      exit 1
    fi

    echo "Downloading from ${NVIDIA_CUDA_URL} to ${local_cuda_runfile}"
    if curl ${curl_retry_args[@]} -o "${local_cuda_runfile}" "${NVIDIA_CUDA_URL}"; then
      echo "Download complete. Uploading to GCS cache: ${gcs_cache_path}"
      if ! ${gsutil_cmd} cp "${local_cuda_runfile}" "${gcs_cache_path}"; then
        echo "WARN: Failed to upload CUDA runfile to GCS cache."
      fi
    else
      echo "ERROR: Failed to download CUDA runfile from NVIDIA."
      exit 1
    fi
  fi
  echo "DEBUG: Local CUDA runfile path: ${local_cuda_runfile}"

  if ( version_lt "${CUDA_FULL_VERSION}" "12.3.0" && ge_debian12 ) ; then
    echo "CUDA 12.3.0 is the minimum CUDA 12 version supported on Debian 12"
  elif ( version_gt "${CUDA_VERSION}" "12.1.1" && is_ubuntu18 ) ; then
    echo "CUDA 12.1.1 is the maximum CUDA version supported on ubuntu18.  Requested version: ${CUDA_VERSION}"
  elif ( version_lt "${CUDA_VERSION%%.*}" "12" && ge_debian12 ) ; then
    echo "CUDA 11 not supported on Debian 12. Requested version: ${CUDA_VERSION}"
  elif ( version_lt "${CUDA_VERSION}" "11.8" && is_rocky9 ) ; then
    echo "CUDA 11.8.0 is the minimum version for Rocky 9. Requested version: ${CUDA_VERSION}"
  fi
}

function set_cudnn_tarball_url() {
CUDNN_TARBALL="cudnn-${CUDA_VERSION}-linux-x64-v${CUDNN_VERSION}.tgz"
CUDNN_TARBALL_URL="${NVIDIA_BASE_DL_URL}/redist/cudnn/v${CUDNN_VERSION%.*}/${CUDNN_TARBALL}"
if ( version_ge "${CUDNN_VERSION}" "8.3.1.22" ); then
  # When version is greater than or equal to 8.3.1.22 but less than 8.4.1.50 use this format
  CUDNN_TARBALL="cudnn-linux-x86_64-${CUDNN_VERSION}_cuda${CUDA_VERSION%.*}-archive.tar.xz"
  if ( version_le "${CUDNN_VERSION}" "8.4.1.50" ); then
    # When cuDNN version is greater than or equal to 8.4.1.50 use this format
    CUDNN_TARBALL="cudnn-linux-x86_64-${CUDNN_VERSION}_cuda${CUDA_VERSION}-archive.tar.xz"
  fi
  # Use legacy url format with one of the tarball name formats depending on version as above
  CUDNN_TARBALL_URL="${NVIDIA_BASE_DL_URL}/redist/cudnn/v${CUDNN_VERSION%.*}/local_installers/${CUDA_VERSION}/${CUDNN_TARBALL}"
fi
if ( version_ge "${CUDA_VERSION}" "12.0" ); then
  # Use modern url format When cuda version is greater than or equal to 12.0
  CUDNN_TARBALL="cudnn-linux-x86_64-${CUDNN_VERSION}_cuda${CUDA_VERSION%%.*}-archive.tar.xz"
  CUDNN_TARBALL_URL="${NVIDIA_BASE_DL_URL}/cudnn/redist/cudnn/linux-x86_64/${CUDNN_TARBALL}"
fi
readonly CUDNN_TARBALL
readonly CUDNN_TARBALL_URL
}

# Whether to install NVIDIA-provided or OS-provided GPU driver
GPU_DRIVER_PROVIDER=$(get_metadata_attribute 'gpu-driver-provider' 'NVIDIA')
readonly GPU_DRIVER_PROVIDER

# Whether to install GPU monitoring agent that sends GPU metrics to Stackdriver
INSTALL_GPU_AGENT_METADATA=$(get_metadata_attribute 'install-gpu-agent' 'true')
ENABLE_GPU_MONITORING_METADATA=$(get_metadata_attribute 'enable-gpu-monitoring' 'true')
INSTALL_GPU_AGENT='true'
if [[ "${INSTALL_GPU_AGENT_METADATA}" == "false" ]] || [[ "${ENABLE_GPU_MONITORING_METADATA}" == "false" ]] ; then
  INSTALL_GPU_AGENT='false'
fi
readonly INSTALL_GPU_AGENT

# Dataproc configurations
readonly HADOOP_CONF_DIR='/etc/hadoop/conf'
readonly HIVE_CONF_DIR='/etc/hive/conf'
readonly SPARK_CONF_DIR='/etc/spark/conf'

NVIDIA_SMI_PATH='/usr/bin'
MIG_MAJOR_CAPS=0
IS_MIG_ENABLED=0

IS_CUSTOM_IMAGE_BUILD="false" # Default

function execute_with_retries() (
  local -r cmd="$*"

  if [[ "$cmd" =~ "^apt-get install" ]] ; then
    apt-get -y clean
    apt-get -o DPkg::Lock::Timeout=60 -y autoremove
  fi
  for ((i = 0; i < 3; i++)); do
    time eval "$cmd" > "${install_log}" 2>&1 && retval=$? || { retval=$? ; cat "${install_log}" ; }
    if [[ $retval == 0 ]] ; then return 0 ; fi
    sleep 5
  done
  return 1
)

function install_cuda_keyring_pkg() {
  is_complete cuda-keyring-installed && return
  local kr_ver=1.1
  curl ${curl_retry_args[@]} \
    "${NVIDIA_REPO_URL}/cuda-keyring_${kr_ver}-1_all.deb" \
    -o "${tmpdir}/cuda-keyring.deb"
  dpkg -i "${tmpdir}/cuda-keyring.deb"
  rm -f "${tmpdir}/cuda-keyring.deb"
  mark_complete cuda-keyring-installed
}

function uninstall_cuda_keyring_pkg() {
  apt-get purge -yq cuda-keyring
  mark_incomplete cuda-keyring-installed
}

function install_local_cuda_repo() {
  is_complete install-local-cuda-repo && return

  pkgname="cuda-repo-${shortname}-${CUDA_VERSION//./-}-local"
  CUDA_LOCAL_REPO_PKG_NAME="${pkgname}"
  readonly LOCAL_INSTALLER_DEB="${pkgname}_${CUDA_FULL_VERSION}-${DRIVER_VERSION}-1_amd64.deb"
  readonly LOCAL_DEB_URL="${NVIDIA_BASE_DL_URL}/cuda/${CUDA_FULL_VERSION}/local_installers/${LOCAL_INSTALLER_DEB}"
  readonly DIST_KEYRING_DIR="/var/${pkgname}"

  curl ${curl_retry_args[@]} \
    "${LOCAL_DEB_URL}" -o "${tmpdir}/${LOCAL_INSTALLER_DEB}"

  dpkg -i "${tmpdir}/${LOCAL_INSTALLER_DEB}"
  rm "${tmpdir}/${LOCAL_INSTALLER_DEB}"
  cp ${DIST_KEYRING_DIR}/cuda-*-keyring.gpg /usr/share/keyrings/

  if is_ubuntu ; then
    curl ${curl_retry_args[@]} \
      "${NVIDIA_REPO_URL}/cuda-${shortname}.pin" \
      -o /etc/apt/preferences.d/cuda-repository-pin-600
  fi

  mark_complete install-local-cuda-repo
}
function uninstall_local_cuda_repo(){
  apt-get purge -yq "${CUDA_LOCAL_REPO_PKG_NAME}"
  mark_incomplete install-local-cuda-repo
}

function install_local_cudnn_repo() {
  is_complete install-local-cudnn-repo && return
  pkgname="cudnn-local-repo-${shortname}-${CUDNN_VERSION%.*}"
  CUDNN_PKG_NAME="${pkgname}"
  local_deb_fn="${pkgname}_1.0-1_amd64.deb"
  local_deb_url="${NVIDIA_BASE_DL_URL}/cudnn/${CUDNN_VERSION%.*}/local_installers/${local_deb_fn}"

  # ${NVIDIA_BASE_DL_URL}/redist/cudnn/v8.6.0/local_installers/11.8/cudnn-linux-x86_64-8.6.0.163_cuda11-archive.tar.xz
  curl ${curl_retry_args[@]} \
    "${local_deb_url}" -o "${tmpdir}/local-installer.deb"

  dpkg -i "${tmpdir}/local-installer.deb"

  rm -f "${tmpdir}/local-installer.deb"

  cp /var/cudnn-local-repo-*-${CUDNN_VERSION%.*}*/cudnn-local-*-keyring.gpg /usr/share/keyrings

  mark_complete install-local-cudnn-repo
}

function uninstall_local_cudnn_repo() {
  apt-get purge -yq "${CUDNN_PKG_NAME}"
  mark_incomplete install-local-cudnn-repo
}

function install_local_cudnn8_repo() {
  is_complete install-local-cudnn8-repo && return

  if   is_ubuntu ; then cudnn8_shortname="ubuntu2004"
  elif is_debian ; then cudnn8_shortname="debian11"
  else return 0 ; fi
  if   is_cuda12 ; then CUDNN8_CUDA_VER=12.0
  elif is_cuda11 ; then CUDNN8_CUDA_VER=11.8
  else CUDNN8_CUDA_VER="${CUDA_VERSION}" ; fi
  cudnn_pkg_version="${CUDNN_VERSION}-1+cuda${CUDNN8_CUDA_VER}"

  pkgname="cudnn-local-repo-${cudnn8_shortname}-${CUDNN_VERSION}"
  CUDNN8_PKG_NAME="${pkgname}"

  deb_fn="${pkgname}_1.0-1_amd64.deb"
  local_deb_fn="${tmpdir}/${deb_fn}"
  local_deb_url="${NVIDIA_BASE_DL_URL}/redist/cudnn/v${CUDNN_VERSION%.*}/local_installers/${CUDNN8_CUDA_VER}/${deb_fn}"

  # cache the cudnn package
  cache_fetched_package "${local_deb_url}" \
                        "${pkg_bucket}/nvidia/cudnn/${CUDNN8_CUDA_VER}/${deb_fn}" \
                        "${local_deb_fn}"

  local cudnn_path="$(dpkg -c ${local_deb_fn} | perl -ne 'if(m{(/var/cudnn-local-repo-.*)/\s*$}){print $1}')"
  # If we are using a ram disk, mount another where we will unpack the cudnn local installer
  if [[ "${tmpdir}" == "/mnt/shm" ]] && ! grep -q '/var/cudnn-local-repo' /proc/mounts ; then
    mkdir -p "${cudnn_path}"
    mount -t tmpfs tmpfs "${cudnn_path}"
  fi

  dpkg -i "${local_deb_fn}"

  rm -f "${local_deb_fn}"

  cp "${cudnn_path}"/cudnn-local-*-keyring.gpg /usr/share/keyrings
  mark_complete install-local-cudnn8-repo
}

function uninstall_local_cudnn8_repo() {
  apt-get purge -yq "${CUDNN8_PKG_NAME}"
  mark_incomplete install-local-cudnn8-repo
}

function install_nvidia_nccl() {
  readonly DEFAULT_NCCL_VERSION=${NCCL_FOR_CUDA["${CUDA_VERSION}"]}
  readonly NCCL_VERSION=$(get_metadata_attribute 'nccl-version' ${DEFAULT_NCCL_VERSION})

  is_complete nccl && return

  if is_cuda11 && is_debian12 ; then
    echo "NCCL cannot be compiled for CUDA 11 on ${_shortname}"
    return
  fi

  local -r nccl_version="${NCCL_VERSION}-1+cuda${CUDA_VERSION}"

  mkdir -p "${workdir}"
  pushd "${workdir}"

  test -d "${workdir}/nccl" || {
    local tarball_fn="v${NCCL_VERSION}-1.tar.gz"
    curl ${curl_retry_args[@]} \
      "https://github.com/NVIDIA/nccl/archive/refs/tags/${tarball_fn}" \
      | tar xz
    mv "nccl-${NCCL_VERSION}-1" nccl
  }

  local build_path
  if is_debuntu ; then build_path="nccl/build/pkg/deb" ; else
                       build_path="nccl/build/pkg/rpm/x86_64" ; fi

  test -d "${workdir}/nccl/build" || {
    local build_tarball="nccl-build_${_shortname}_${nccl_version}.tar.gz"
    local local_tarball="${workdir}/${build_tarball}"
    local gcs_tarball="${pkg_bucket}/nvidia/nccl/${_shortname}/${build_tarball}"

    if [[ "$(hostname -s)" =~ ^test-gpu && "$(nproc)" < 32 ]] ; then
      # when running with fewer than 32 cores, yield to in-progress build
      sleep $(( ( RANDOM % 11 ) + 10 ))
      local output="$(${gsutil_stat_cmd} "${gcs_tarball}.building"|grep '.reation.time')"
      if [[ "$?" == "0" ]] ; then
        local build_start_time build_start_epoch timeout_epoch
        build_start_time="$(echo ${output} | awk -F': +' '{print $2}')"
        build_start_epoch="$(date -u -d "${build_start_time}" +%s)"
        timeout_epoch=$((build_start_epoch + 2700)) # 45 minutes
        while ${gsutil_stat_cmd} "${gcs_tarball}.building" ; do
          local now_epoch="$(date -u +%s)"
          if (( now_epoch > timeout_epoch )) ; then
            # detect unexpected build failure after 45m
            ${gsutil_cmd} rm "${gcs_tarball}.building"
            break
          fi
          sleep 5m
        done
      fi
    fi

    if ${gsutil_stat_cmd} "${gcs_tarball}" ; then
      # cache hit - unpack from cache
      echo "cache hit"
      ${gsutil_cmd} cat "${gcs_tarball}" | tar xvz
    else
      # build and cache
      touch "${local_tarball}.building"
      ${gsutil_cmd} cp "${local_tarball}.building" "${gcs_tarball}.building"
      building_file="${gcs_tarball}.building"
      pushd nccl
      # https://github.com/NVIDIA/nccl?tab=readme-ov-file#install
      install_build_dependencies

      # https://github.com/NVIDIA/nccl/blob/master/README.md
      # https://arnon.dk/matching-sm-architectures-arch-and-gencode-for-various-nvidia-cards/
      # Fermi:     SM_20,             compute_30
      # Kepler:    SM_30,SM_35,SM_37, compute_30,compute_35,compute_37
      # Maxwell:   SM_50,SM_52,SM_53, compute_50,compute_52,compute_53
      # Pascal:    SM_60,SM_61,SM_62, compute_60,compute_61,compute_62

      # The following architectures are suppored by open kernel driver
      # Volta:     SM_70,SM_72,       compute_70,compute_72
      # Ampere:    SM_80,SM_86,SM_87, compute_80,compute_86,compute_87

      # The following architectures are supported by CUDA v11.8+
      # Ada:       SM_89,             compute_89
      # Hopper:    SM_90,SM_90a       compute_90,compute_90a
      # Blackwell: SM_100,            compute_100
      local nvcc_gencode=("-gencode=arch=compute_80,code=sm_80" # Ampre
			  "-gencode=arch=compute_86,code=sm_86" # Ampre
			 )

      if version_gt "${CUDA_VERSION}" "11.6" ; then
        nvcc_gencode+=("-gencode=arch=compute_87,code=sm_87") # Ampre
      fi
      if version_ge "${CUDA_VERSION}" "11.8" ; then
        nvcc_gencode+=("-gencode=arch=compute_89,code=sm_89") # Lovelace
      fi
      if version_ge "${CUDA_VERSION}" "12.0" ; then
        nvcc_gencode+=("-gencode=arch=compute_90,code=sm_90") # Hopper
      fi
      # if version_ge "${CUDA_VERSION}" "12.8" ; then
      #   nvcc_gencode+=("-gencode=arch=compute_101,code=sm_101") # Blackwell
      # fi
      if version_lt "${CUDA_VERSION}" "13.0" ; then
        nvcc_gencode+=("-gencode=arch=compute_70,code=sm_70" # Volta
                       "-gencode=arch=compute_72,code=sm_72" # Volta
                       )
      fi
      if version_ge "${CUDA_VERSION}" "13.0" ; then
        nvcc_gencode+=("-gencode=arch=compute_110,code=sm_110") # Blackwell
      fi
      NVCC_GENCODE="${nvcc_gencode[*]}"

      if is_debuntu ; then
        # These packages are required to build .deb packages from source
        execute_with_retries \
          apt-get install -y -qq build-essential devscripts debhelper fakeroot
        export NVCC_GENCODE
        execute_with_retries make -j$(nproc) pkg.debian.build
      elif is_rocky ; then
        # These packages are required to build .rpm packages from source
        execute_with_retries \
          dnf -y -q install rpm-build rpmdevtools
        export NVCC_GENCODE
        execute_with_retries make -j$(nproc) pkg.redhat.build
      fi
      tar czvf "${local_tarball}" "../${build_path}"
      make clean || echo "WARN: 'make clean' failed in nccl build, continuing..."
      popd
      tar xzvf "${local_tarball}"
      ${gsutil_cmd} cp "${local_tarball}" "${gcs_tarball}"
      if ${gsutil_stat_cmd} "${gcs_tarball}.building" ; then ${gsutil_cmd} rm "${gcs_tarball}.building" || true ; fi
      building_file=""
      rm "${local_tarball}"
    fi
  }

  if is_debuntu ; then
    dpkg -i "${build_path}/libnccl${NCCL_VERSION%%.*}_${nccl_version}_amd64.deb" "${build_path}/libnccl-dev_${nccl_version}_amd64.deb"
  elif is_rocky ; then
    rpm -ivh "${build_path}/libnccl-${nccl_version}.x86_64.rpm" "${build_path}/libnccl-devel-${nccl_version}.x86_64.rpm"
  fi

  popd
  mark_complete nccl
}

function is_src_nvidia() { [[ "${GPU_DRIVER_PROVIDER}" == "NVIDIA" ]] ; }
function is_src_os()     { [[ "${GPU_DRIVER_PROVIDER}" == "OS" ]] ; }

function install_nvidia_cudnn() {
  is_complete cudnn && return
  if le_debian10 ; then return ; fi
  local major_version
  major_version="${CUDNN_VERSION%%.*}"
  local cudnn_pkg_version
  cudnn_pkg_version="${CUDNN_VERSION}-1+cuda${CUDA_VERSION}"

  if is_rocky ; then
    if is_cudnn8 ; then
      execute_with_retries dnf -y -q install \
        "libcudnn${major_version}" \
        "libcudnn${major_version}-devel"
      sync
    elif is_cudnn9 ; then
      execute_with_retries dnf -y -q install \
        "libcudnn9-static-cuda-${CUDA_VERSION%%.*}" \
        "libcudnn9-devel-cuda-${CUDA_VERSION%%.*}"
      sync
    else
      echo "Unsupported cudnn version: '${major_version}'"
    fi
  elif is_debuntu; then
    if ge_debian12 && is_src_os ; then
      apt-get -y install nvidia-cudnn
    else
      if is_cudnn8 ; then
        add_repo_cuda

        apt-get update -qq
        # Ignore version requested and use the latest version in the package index
        cudnn_pkg_version="$(apt-cache show libcudnn8 | awk "/^Ver.*cuda${CUDA_VERSION%%.*}.*/ {print \$2}" | sort -V | tail -1)"

        execute_with_retries \
          apt-get -y install --no-install-recommends \
            "libcudnn8=${cudnn_pkg_version}" \
            "libcudnn8-dev=${cudnn_pkg_version}"

        sync
      elif is_cudnn9 ; then
        install_cuda_keyring_pkg

        apt-get update -qq

        execute_with_retries \
          apt-get -y install --no-install-recommends \
          "libcudnn9-cuda-${CUDA_VERSION%%.*}" \
          "libcudnn9-dev-cuda-${CUDA_VERSION%%.*}" \
          "libcudnn9-static-cuda-${CUDA_VERSION%%.*}"

        sync
      else
        echo "Unsupported cudnn version: [${CUDNN_VERSION}]"
      fi
    fi
  else
    echo "Unsupported OS: '${OS_NAME}'"
    exit 1
  fi

  ldconfig

  echo "NVIDIA cuDNN successfully installed for ${OS_NAME}."
  mark_complete cudnn
}

function install_pytorch() {
  is_complete pytorch && return

  local env
  env=$(get_metadata_attribute 'gpu-conda-env' 'dpgce')

  local conda_root_path
  if version_lt "${DATAPROC_IMAGE_VERSION}" "2.3" ; then
    conda_root_path="/opt/conda/miniconda3"
  else
    conda_root_path="/opt/conda"
  fi
  [[ -d ${conda_root_path} ]] || return
  local envpath="${conda_root_path}/envs/${env}"
  if [[ "${env}" == "base" ]]; then
    echo "WARNING: installing to base environment known to cause solve issues" ; envpath="${conda_root_path}" ; fi
  # Set numa node to 0 for all GPUs
  for f in $(ls /sys/module/nvidia/drivers/pci:nvidia/*/numa_node) ; do echo 0 > ${f} ; done

  local build_tarball="pytorch_${env}_${_shortname}_cuda${CUDA_VERSION}.tar.gz"
  local local_tarball="${workdir}/${build_tarball}"
  local gcs_tarball="${pkg_bucket}/conda/${_shortname}/${build_tarball}"

  # We are here because the 'pytorch' sentinel is missing.
  # If the main driver install sentinel EXISTS, it means this is a re-run
  # on a system where the driver was likely already set up.
  # The missing 'pytorch' sentinel in this context is used as a signal
  # to force a purge of the PyTorch Conda environment cache and a full rebuild.
  if is_complete install_gpu_driver-main; then
    echo "INFO: Main GPU driver install sentinel found, but PyTorch sentinel missing. Triggering cache purge and environment rebuild."
    # Attempt to remove GCS cache for the PyTorch env
    echo "INFO: Removing GCS cache object: ${gcs_tarball}"
    ${gsutil_cmd} rm "${gcs_tarball}" || echo "WARN: Failed to remove GCS cache (may not exist)."

    # Attempt to remove local env directory
    if [[ -d "${envpath}" ]]; then
      echo "INFO: Removing local Conda env directory: ${envpath}"
      rm -rf "${envpath}" || echo "WARN: Failed to remove local env directory."
    fi
  fi

  # edge nodes (fewer cores than 32) in test do not build the conda
  # packages ; stand by as a big machine completes that work.

  if [[ "$(hostname -s)" =~ ^test && "$(nproc)" < 32 ]] ; then
    # when running with fewer than 32 cores, yield to in-progress build
    sleep $(( ( RANDOM % 11 ) + 10 ))
    local output="$(${gsutil_stat_cmd} "${gcs_tarball}.building"|grep '.reation.time')"
    if [[ "$?" == "0" ]] ; then
      local build_start_time build_start_epoch timeout_epoch
      build_start_time="$(echo ${output} | awk -F': +' '{print $2}')"
      build_start_epoch="$(date -u -d "${build_start_time}" +%s)"
      timeout_epoch=$((build_start_epoch + 2700)) # 45 minutes
      while ${gsutil_stat_cmd} "${gcs_tarball}.building" ; do
        local now_epoch="$(date -u +%s)"
        if (( now_epoch > timeout_epoch )) ; then
          # detect unexpected build failure after 45m
          ${gsutil_cmd} rm "${gcs_tarball}.building"
          break
        fi
        sleep 5m
      done
    fi
  fi

  if ${gsutil_stat_cmd} "${gcs_tarball}" ; then
    # cache hit - unpack from cache
    echo "cache hit"
    mkdir -p "${envpath}"
    ${gsutil_cmd} cat "${gcs_tarball}" | tar -C "${envpath}" -xz
  else
    touch "${local_tarball}.building"
    ${gsutil_cmd} cp "${local_tarball}.building" "${gcs_tarball}.building"
    building_file="${gcs_tarball}.building"
    local verb=create
    if test -d "${envpath}" ; then verb=install ; fi
    local conda_path="${conda_root_path}/bin/mamba"

    local mamba_tried=false
    if ! command -v "${conda_path}" > /dev/null 2>&1; then
      echo "Mamba not found, trying to install it..."
      mamba_tried=true
      "${conda_root_path}/bin/conda" install -n base -c conda-forge mamba -y \
        || echo "WARN: Mamba installation failed."
      if ! command -v "${conda_path}" > /dev/null 2>&1; then
        echo "Mamba not found after install attempt, falling back to conda."
        conda_path="${conda_root_path}/bin/conda"
      fi
    fi
    echo "Using installer: ${conda_path}"
    conda_pkg_list=(
      "numba" "pytorch" "tensorflow[and-cuda]" "rapids" "pyspark"
      "cuda-version<=${CUDA_VERSION}"
    )

    conda_pkg=$( IFS=' ' ; echo "${conda_pkg_list[*]}" )

    local conda_err_file="${tmpdir}/conda_create.err"
    # Install pytorch and company to this environment
    set +e
    "${conda_path}" "${verb}" -n "${env}" \
      -c conda-forge -c nvidia -c rapidsai \
      ${conda_pkg} 2> "${conda_err_file}"
    local conda_exit_code="$?"
    set -e

    if [[ "${conda_exit_code}" -ne 0 ]]; then
      cat "${conda_err_file}" >&2
      if [[ "${conda_path}" == *mamba ]] && grep -q "RuntimeError: Multi-download failed." "${conda_err_file}"; then
        echo "ERROR: Mamba failed to create the environment, likely due to a proxy issue on this platform." >&2
        echo "ERROR: Please run this initialization action in a non-proxied environment at least once to build and populate the GCS cache for '${gcs_tarball}'." >&2
        echo "ERROR: Once the cache exists, subsequent runs in the proxied environment should succeed." >&2
        exit 1
      else
        echo "ERROR: Conda/Mamba environment creation failed with exit code ${conda_exit_code}." >&2
        exit ${conda_exit_code}
      fi
    fi
    rm -f "${conda_err_file}"

    # Install jupyter kernel in this environment
    "${envpath}/bin/python3" -m pip install ipykernel

    # package environment and cache in GCS
    pushd "${envpath}"
    tar czf "${local_tarball}" .
    popd
    ${gsutil_cmd} cp "${local_tarball}" "${gcs_tarball}"
    if ${gsutil_stat_cmd} "${gcs_tarball}.building" ; then ${gsutil_cmd} rm "${gcs_tarball}.building" || true ; fi
    building_file=""
    rm "${local_tarball}"
  fi

  # register the environment as a selectable kernel
  "${envpath}/bin/python3" -m ipykernel install --name "${env}" --display-name "Python (${env})"

  mark_complete pytorch
}

function configure_dkms_certs() {
  if test -v PSN && [[ -z "${PSN}" ]]; then
      echo "No signing secret provided.  skipping";
      return 0
  fi

  # Always fetch keys if PSN is set to ensure modulus_md5sum is calculated.
  if [[ -n "${PSN}" ]]; then
    mkdir -p "${CA_TMPDIR}"

    # Retrieve cloud secrets keys
    local sig_priv_secret_name
    sig_priv_secret_name="${PSN}"
    local sig_pub_secret_name
    sig_pub_secret_name="$(get_metadata_attribute public_secret_name)"
    local sig_secret_project
    sig_secret_project="$(get_metadata_attribute secret_project)"
    local sig_secret_version
    sig_secret_version="$(get_metadata_attribute secret_version)"

    # If metadata values are not set, do not write mok keys
    if [[ -z "${sig_priv_secret_name}" ]]; then return 0 ; fi

    # Write private material to volatile storage
    gcloud secrets versions access "${sig_secret_version}" \
           --project="${sig_secret_project}" \
           --secret="${sig_priv_secret_name}" \
        | dd status=none of="${CA_TMPDIR}/db.rsa"

    # Write public material to volatile storage
    gcloud secrets versions access "${sig_secret_version}" \
           --project="${sig_secret_project}" \
           --secret="${sig_pub_secret_name}" \
        | base64 --decode \
        | dd status=none of="${CA_TMPDIR}/db.der"

    local mok_directory="$(dirname "${mok_key}")"
    mkdir -p "${mok_directory}"

    # symlink private key and copy public cert from volatile storage to DKMS directory
    ln -sf "${CA_TMPDIR}/db.rsa" "${mok_key}"
    cp  -f "${CA_TMPDIR}/db.der" "${mok_der}"

    modulus_md5sum="$(openssl rsa -noout -modulus -in "${mok_key}" | openssl md5 | awk '{print $2}')"
    echo "DEBUG: modulus_md5sum set to: ${modulus_md5sum}"
  fi
}

function clear_dkms_key {
  if [[ -z "${PSN}" ]]; then
      echo "No signing secret provided.  skipping" >&2
      return 0
  fi
  rm -rf "${CA_TMPDIR}" "${mok_key}"
}

function add_contrib_component() {
  if ! is_debuntu ; then return ; fi
  if ge_debian12 ; then
      # Include in sources file components on which nvidia-kernel-open-dkms depends
      local -r debian_sources="/etc/apt/sources.list.d/debian.sources"
      local components="main contrib"

      sed -i -e "s/Components: .*$/Components: ${components}/" "${debian_sources}"
  elif is_debian ; then
      sed -i -e 's/ main$/ main contrib/' /etc/apt/sources.list
  fi
}

function add_nonfree_components() {
  if is_src_nvidia ; then return; fi
  if ge_debian12 ; then
      # Include in sources file components on which nvidia-open-kernel-dkms depends
      local -r debian_sources="/etc/apt/sources.list.d/debian.sources"
      local components="main contrib non-free non-free-firmware"

      sed -i -e "s/Components: .*$/Components: ${components}/" "${debian_sources}"
  elif is_debian ; then
      sed -i -e 's/ main$/ main contrib non-free/' /etc/apt/sources.list
  fi
}

#
# Install package signing key and add corresponding repository
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
function add_repo_nvidia_container_toolkit() {
  local nvctk_root="https://nvidia.github.io/libnvidia-container"
  local signing_key_url="${nvctk_root}/gpgkey"
  local repo_data

  # Since there are more than one keys to go into this keychain, we can't call os_add_repo, which only works with one
  if is_debuntu ; then
    # "${repo_name}" "${signing_key_url}" "${repo_data}" "${4:-yes}" "${kr_path}" "${6:-}"
    local -r repo_name="nvidia-container-toolkit"
    local -r kr_path="/usr/share/keyrings/${repo_name}.gpg"
    GPG_PROXY_ARGS=""
    if [[ -v HTTP_PROXY ]] ; then
      GPG_PROXY="--keyserver-options http-proxy=${HTTP_PROXY}"
    elif [[ -v http_proxy ]] ; then
      GPG_PROXY="--keyserver-options http-proxy=${http_proxy}"
    fi
    import_gpg_keys --keyring-file "${kr_path}" \
                    --key-id "0xae09fe4bbd223a84b2ccfce3f60f4b3d7fa2af80" \
                    --key-id "0xeb693b3035cd5710e231e123a4b469963bf863cc" \
                    --key-id "0xc95b321b61e88c1809c4f759ddcae044f796ecb0"

    local -r repo_data="${nvctk_root}/stable/deb/\$(ARCH) /"
    local -r repo_path="/etc/apt/sources.list.d/${repo_name}.list"
    echo "deb     [signed-by=${kr_path}] ${repo_data}" >  "${repo_path}"
    echo "deb-src [signed-by=${kr_path}] ${repo_data}" >> "${repo_path}"
    execute_with_retries apt-get update
  else
    repo_data="${nvctk_root}/stable/rpm/nvidia-container-toolkit.repo"
    os_add_repo nvidia-container-toolkit \
                "${signing_key_url}" \
                "${repo_data}" \
                "no"
  fi
}

function add_repo_cuda() {
  if is_debuntu ; then
    if version_le "${CUDA_VERSION}" 11.6 ; then
      local kr_path=/usr/share/keyrings/cuda-archive-keyring.gpg
      local sources_list_path="/etc/apt/sources.list.d/cuda-${shortname}-x86_64.list"
      echo "deb [signed-by=${kr_path}] https://developer.download.nvidia.com/compute/cuda/repos/${shortname}/x86_64/ /" \
      | sudo tee "${sources_list_path}"

      GPG_PROXY_ARGS=""
      if [[ -n "${HTTP_PROXY}" ]] ; then
        GPG_PROXY="--keyserver-options http-proxy=${HTTP_PROXY}"
      elif [[ -n "${http_proxy}" ]] ; then
        GPG_PROXY="--keyserver-options http-proxy=${http_proxy}"
      fi
      import_gpg_keys --keyring-file "${kr_path}" \
                      --key-id "0xae09fe4bbd223a84b2ccfce3f60f4b3d7fa2af80" \
                      --key-id "0xeb693b3035cd5710e231e123a4b469963bf863cc"
    else
      install_cuda_keyring_pkg # 11.7+, 12.0+
    fi
  elif is_rocky ; then
    execute_with_retries "dnf config-manager --add-repo ${NVIDIA_ROCKY_REPO_URL}"
  fi
}

function execute_github_driver_build() {
      local local_tarball="$1"
      local gcs_tarball="$2"

      if ${gsutil_stat_cmd} "${gcs_tarball}" 2>&1 ; then
        echo "cache hit"
        return
      fi

      # build the kernel modules
      touch "${local_tarball}.building"
      ${gsutil_cmd} cp "${local_tarball}.building" "${gcs_tarball}.building"
      building_file="${gcs_tarball}.building"

      pushd open-gpu-kernel-modules
      install_build_dependencies
      if ( is_cuda11 && is_ubuntu22 ) ; then
        echo "Kernel modules cannot be compiled for CUDA 11 on ${_shortname}"
        exit 1
      fi
      execute_with_retries make -j$(nproc) modules \
        >  kernel-open/build.log \
        2> kernel-open/build_error.log
      make -j$(nproc) modules_install
      # Sign kernel modules
      if [[ -n "${PSN}" ]]; then
        configure_dkms_certs
        echo "DEBUG: mok_key=${mok_key}"
        echo "DEBUG: mok_der=${mok_der}"
        if [[ -f "${mok_key}" ]]; then ls -l "${mok_key}"; fi
        if [[ -f "${mok_der}" ]]; then ls -l "${mok_der}"; fi
        set -x
        for module in $(find /lib/modules/${uname_r}/kernel/drivers/video -name '*nvidia*.ko') ; do
          echo "DEBUG: Signing ${module}"
          "/lib/modules/${uname_r}/build/scripts/sign-file" sha256 \
          "${mok_key}" \
          "${mok_der}" \
          "${module}"
        done
        set +x
        clear_dkms_key
      fi
      # Collect build logs and installed binaries
      tar czvf "${local_tarball}" \
        "${workdir}/open-gpu-kernel-modules/kernel-open/"*.log \
        $(find /lib/modules/${uname_r}/ -iname 'nvidia*.ko')
      ${gsutil_cmd} cp "${local_tarball}" "${gcs_tarball}"
      if ${gsutil_stat_cmd} "${gcs_tarball}.building" ; then ${gsutil_cmd} rm "${gcs_tarball}.building" || true ; fi
      building_file=""
      rm "${local_tarball}"
      make clean
      popd
}

function build_driver_from_github() {
  # non-GPL driver will have been built on rocky8, or when driver
  # version is prior to open driver min, or GPU architecture is prior
  # to Turing
  if ( is_rocky8 \
    || version_lt "${DRIVER_VERSION}" "${MIN_OPEN_DRIVER_VER}" \
    || [[ "$((16#${pci_device_id}))" < "$((16#1E00))" ]] ) ; then
    return 0
  fi
  pushd "${workdir}"
  test -d "${workdir}/open-gpu-kernel-modules" || {
    tarball_fn="${DRIVER_VERSION}.tar.gz"

    local github_url="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${DRIVER_VERSION}.tar.gz"
    local gcs_cache_path="${pkg_bucket}/nvidia/src/${tarball_fn}"
    local local_tarball="${tmpdir}/${tarball_fn}"

    # Check 1: Local tarball
    if [[ ! -f "${local_tarball}" ]]; then
      # Check 2: GCS Cache
      echo "Checking for cached source tarball at: ${gcs_cache_path}"
      if ! ${gsutil_stat_cmd} "${gcs_cache_path}" 2>/dev/null; then
        # Check 3: Download from GitHub
        echo "Source tarball not found in GCS cache. Downloading from GitHub: ${github_url}"
        if curl ${curl_retry_args[@]} -L "${github_url}" -o "${local_tarball}"; then
          echo "Download complete. Uploading to ${gcs_cache_path}"
          if ${gsutil_cmd} cp "${local_tarball}" "${gcs_cache_path}"; then
            echo "Successfully cached to GCS."
          else
            echo "ERROR: Failed to upload source tarball to GCS: ${gcs_cache_path}"
            # Proceeding with local file anyway
          fi
        else
          echo "ERROR: Failed to download source tarball from GitHub: ${github_url}"
          exit 1
        fi
      else
        echo "Source tarball found in GCS cache. Downloading from ${gcs_cache_path}"
        if ! ${gsutil_cmd} cp "${gcs_cache_path}" "${local_tarball}"; then
          echo "ERROR: Failed to download source tarball from GCS: ${gcs_cache_path}"
          exit 1
        fi
      fi
    else
      echo "INFO: Using existing local tarball: ${local_tarball}"
    fi

    echo "Extracting source tarball..."
    tar xzf "${local_tarball}" -C "${workdir}"
    mv "${workdir}/open-gpu-kernel-modules-${DRIVER_VERSION}" "${workdir}/open-gpu-kernel-modules"
    # rm -f "${local_tarball}" # Keep the local tarball for potential reuse
  }
  local nvidia_ko_path="$(find /lib/modules/$(uname -r)/ -name 'nvidia.ko' | head -n1)"

  local needs_build=false
  if [[ -n "${nvidia_ko_path}" && -f "${nvidia_ko_path}" ]]; then
    if modinfo "${nvidia_ko_path}" | grep -qi sig ; then
      echo "NVIDIA kernel module found and appears signed."
      # Try to load it to be sure
      if ! modprobe nvidia > /dev/null 2>&1; then
        echo "Module signed but failed to load. Rebuilding."
        needs_build=true
      else
        echo "Module loaded successfully."
      fi
    else
      echo "NVIDIA kernel module found but NOT signed. Rebuilding."
      needs_build=true
    fi
  else
    echo "NVIDIA kernel module not found. Building."
    needs_build=true
  fi


  if [[ "${needs_build}" == "true" ]]; then
    # Configure certs to get modulus_md5sum for the path
    if [[ -n "${PSN}" ]]; then
      configure_dkms_certs
    fi

    local build_tarball="kmod_${_shortname}_${DRIVER_VERSION}.tar.gz"
    local local_tarball="${workdir}/${build_tarball}"
    local build_dir
    if test -v modulus_md5sum && [[ -n "${modulus_md5sum}" ]]
      then build_dir="${modulus_md5sum}"
      else build_dir="unsigned"
    fi

    local gcs_tarball="${pkg_bucket}/nvidia/kmod/${_shortname}/${uname_r}/${build_dir}/${build_tarball}"

    if [[ "$(hostname -s)" =~ ^test && "$(nproc)" < 32 ]] ; then
      # when running with fewer than 32 cores, yield to in-progress build
      sleep $(( ( RANDOM % 11 ) + 10 ))
      local output="$(${gsutil_stat_cmd} "${gcs_tarball}.building"|grep '.reation.time')"
      if [[ "$?" == "0" ]] ; then
        local build_start_time build_start_epoch timeout_epoch
        build_start_time="$(echo ${output} | awk -F': +' '{print $2}')"
        build_start_epoch="$(date -u -d "${build_start_time}" +%s)"
        timeout_epoch=$((build_start_epoch + 2700)) # 45 minutes
        while ${gsutil_stat_cmd} "${gcs_tarball}.building" ; do
          local now_epoch="$(date -u +%s)"
          if (( now_epoch > timeout_epoch )) ; then
            # detect unexpected build failure after 45m
            ${gsutil_cmd} rm "${gcs_tarball}.building" || echo "might have been deleted by a peer"
            break
          fi
          sleep 1m # could take up to 180 minutes on single core nodes
        done
      fi
    fi

    execute_github_driver_build "${local_tarball}" "${gcs_tarball}"

    ${gsutil_cmd} cat "${gcs_tarball}" | tar -C / -xzv
    depmod -a

    # Verify signature after installation
    if [[ -n "${PSN}" ]]; then
      configure_dkms_certs

      # Verify signatures and load
      local signed=true
      for module_path in $(find /lib/modules/${uname_r}/ -iname 'nvidia*.ko'); do
        module="$(basename "${module_path}" | sed -e 's/.ko$//')"
        if ! modinfo "${module}" | grep -qi ^signer: ; then
           echo "ERROR: Module ${module} is NOT signed after installation."
           signed=false
        fi
      done
      if [[ "${signed}" != "true" ]]; then
        echo "ERROR: Module signing failed."
        exit 1
      fi

      if ! modprobe nvidia; then
        echo "ERROR: Failed to load nvidia module after build and sign."
        exit 1
      fi
      echo "NVIDIA modules built, signed, and loaded successfully."
    fi
  fi

  popd
}

function build_driver_from_packages() {
  if is_debuntu ; then
    if [[ -n "$(apt-cache search -n "nvidia-driver-${DRIVER}-server-open")" ]] ; then
      local pkglist=("nvidia-driver-${DRIVER}-server-open") ; else
      local pkglist=("nvidia-driver-${DRIVER}-open") ; fi
    if is_debian ; then
      pkglist=(
        "firmware-nvidia-gsp=${DRIVER_VERSION}-1"
        "nvidia-smi=${DRIVER_VERSION}-1"
        "nvidia-alternative=${DRIVER_VERSION}-1"
        "nvidia-kernel-open-dkms=${DRIVER_VERSION}-1"
        "nvidia-kernel-support=${DRIVER_VERSION}-1"
        "nvidia-modprobe=${DRIVER_VERSION}-1"
        "libnvidia-ml1=${DRIVER_VERSION}-1"
      )
    fi
    add_contrib_component
    apt-get update -qq
    execute_with_retries apt-get install -y -qq --no-install-recommends dkms
    configure_dkms_certs
    execute_with_retries apt-get install -y -qq --no-install-recommends "${pkglist[@]}"
    sync

  elif is_rocky ; then
    configure_dkms_certs
    if execute_with_retries dnf -y -q module install "nvidia-driver:${DRIVER}-dkms" ; then
      echo "nvidia-driver:${DRIVER}-dkms installed successfully"
    else
      execute_with_retries dnf -y -q module install 'nvidia-driver:latest'
    fi
    sync
  fi
  clear_dkms_key
}

function install_nvidia_userspace_runfile() {
  # Parameters for NVIDIA-provided Debian GPU driver
  local -r USERSPACE_RUNFILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"

  local -r DEFAULT_USERSPACE_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/${USERSPACE_RUNFILE}"

  local USERSPACE_URL
  USERSPACE_URL="$(get_metadata_attribute 'gpu-driver-url' "${DEFAULT_USERSPACE_URL}")"
  readonly USERSPACE_URL

  # This .run file contains NV's OpenGL implementation as well as
  # nvidia optimized implementations of the gtk+ 2,3 stack(s) not
  # including glib (https://docs.gtk.org/glib/), and what appears to
  # be a copy of the source from the kernel-open directory of for
  # example DRIVER_VERSION=560.35.03
  #
  # https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/560.35.03.tar.gz
  #
  # wget https://us.download.nvidia.com/XFree86/Linux-x86_64/560.35.03/NVIDIA-Linux-x86_64-560.35.03.run
  # sh ./NVIDIA-Linux-x86_64-560.35.03.run -x # this will allow you to review the contents of the package without installing it.
  is_complete userspace && return
  local local_fn="${tmpdir}/${USERSPACE_RUNFILE}"

  cache_fetched_package "${USERSPACE_URL}" \
                        "${pkg_bucket}/nvidia/${USERSPACE_RUNFILE}" \
                        "${local_fn}"

  local runfile_sha256sum
  runfile_sha256sum="$(cd "${tmpdir}" && sha256sum "${USERSPACE_RUNFILE}")"
  local runfile_hash
  runfile_hash=$(echo "${runfile_sha256sum}" | awk '{print $1}')

  local runfile_args=""
  local cache_hit="0"
  local local_tarball="" # Initialize local_tarball here
  local gcs_tarball=""   # Initialize gcs_tarball here

  # Build nonfree driver on rocky8, or when driver version is prior to
  # open driver min, or when GPU architecture is prior to Turing
  if ( is_rocky8 \
    || version_lt "${DRIVER_VERSION}" "${MIN_OPEN_DRIVER_VER}" \
    || [[ "$((16#${pci_device_id}))" < "$((16#1E00))" ]] )
  then
    local nvidia_ko_path="$(find /lib/modules/$(uname -r)/ -name 'nvidia.ko')"
    test -n "${nvidia_ko_path}" && test -f "${nvidia_ko_path}" || {
      local build_tarball="kmod_${_shortname}_${DRIVER_VERSION}_nonfree.tar.gz"
      local_tarball="${workdir}/${build_tarball}" # Set within the condition
      local build_dir
      if test -v modulus_md5sum && [[ -n "${modulus_md5sum}" ]]
        then build_dir="${modulus_md5sum}"
        else build_dir="unsigned" ; fi

      gcs_tarball="${pkg_bucket}/nvidia/kmod/${_shortname}/${uname_r}/${build_dir}/${build_tarball}" # Set within the condition

      if [[ "$(hostname -s)" =~ ^test && "$(nproc)" < 32 ]] ; then
        # when running with fewer than 32 cores, yield to in-progress build
        sleep $(( ( RANDOM % 11 ) + 10 ))
        local output="$(${gsutil_stat_cmd} "${gcs_tarball}.building"|grep '.reation.time')"
        if [[ "$?" == "0" ]] ; then
          local build_start_time build_start_epoch timeout_epoch
          build_start_time="$(echo ${output} | awk -F': +' '{print $2}')"
          build_start_epoch="$(date -u -d "${build_start_time}" +%s)"
          timeout_epoch=$((build_start_epoch + 2700)) # 45 minutes
          while ${gsutil_stat_cmd} "${gcs_tarball}.building" ; do
            local now_epoch="$(date -u +%s)"
            if (( now_epoch > timeout_epoch )) ; then
              # detect unexpected build failure after 45m
              ${gsutil_cmd} rm "${gcs_tarball}.building"
              break
            fi
            sleep 5m
          done
        fi
      fi

      if ${gsutil_stat_cmd} "${gcs_tarball}" ; then
        cache_hit="1"
        if version_ge "${DRIVER_VERSION}" "${MIN_OPEN_DRIVER_VER}" ; then
          runfile_args="${runfile_args} --no-kernel-modules"
        fi
        echo "cache hit"
      else
        # build the kernel modules
        touch "${local_tarball}.building"
        ${gsutil_cmd} cp "${local_tarball}.building" "${gcs_tarball}.building"
        building_file="${gcs_tarball}.building"
        install_build_dependencies
        configure_dkms_certs
        local signing_options
        signing_options=""
        if [[ -n "${PSN}" ]]; then
          signing_options="--module-signing-hash sha256 \
          --module-signing-x509-hash sha256 \
          --module-signing-secret-key \"${mok_key}\" \
          --module-signing-public-key \"${mok_der}\" \
          --module-signing-script \"/lib/modules/${uname_r}/build/scripts/sign-file\" \
          "
        fi
        runfile_args="${signing_options}"
        if version_ge "${DRIVER_VERSION}" "${MIN_OPEN_DRIVER_VER}" ; then
          runfile_args="${runfile_args} --no-dkms"
        fi
      fi
    }
  elif version_ge "${DRIVER_VERSION}" "${MIN_OPEN_DRIVER_VER}" ; then
    runfile_args="--no-kernel-modules"
  fi

  execute_with_retries bash "${local_fn}" -e -q \
    ${runfile_args} \
    --ui=none \
    --install-libglvnd \
    --tmpdir="${tmpdir}"

  # On rocky8, or when driver version is prior to open driver min, or when GPU architecture is prior to Turing
  if ( is_rocky8 \
    || version_lt "${DRIVER_VERSION}" "${MIN_OPEN_DRIVER_VER}" \
    || [[ "$((16#${pci_device_id}))" < "$((16#1E00))" ]] ) ; then
    if [[ "${cache_hit}" == "1" ]] ; then
      ${gsutil_cmd} cat "${gcs_tarball}" | tar -C / -xzv
      depmod -a
    elif [[ -n "${local_tarball}" ]]; then # Check if local_tarball was set
      clear_dkms_key
      tar czvf "${local_tarball}" \
        /var/log/nvidia-installer.log \
        $(find /lib/modules/${uname_r}/ -iname 'nvidia*.ko')
      ${gsutil_cmd} cp "${local_tarball}" "${gcs_tarball}"

      if ${gsutil_stat_cmd} "${gcs_tarball}.building" ; then ${gsutil_cmd} rm "${gcs_tarball}.building" || true ; fi
      building_file=""
    else
      echo "DEBUG: local_tarball not set, skipping tarball creation." >&2
    fi
  fi

  rm -f "${local_fn}"
  mark_complete userspace
  sync
}

function install_cuda_runfile() {
  is_complete cuda && return

  local local_fn="${tmpdir}/${CUDA_RUNFILE}"

  cache_fetched_package "${NVIDIA_CUDA_URL}" \
                        "${pkg_bucket}/nvidia/${CUDA_RUNFILE}" \
                        "${local_fn}"

  execute_with_retries bash "${local_fn}" --toolkit --no-opengl-libs --silent --tmpdir="${tmpdir}"
  rm -f "${local_fn}"
  mark_complete cuda
  sync
}

function install_cuda_toolkit() {
  local cudatk_package=cuda-toolkit
  if ge_debian12 && is_src_os ; then
    cudatk_package="${cudatk_package}=${CUDA_FULL_VERSION}-1"
  elif [[ -n "${CUDA_VERSION}" ]]; then
    cudatk_package="${cudatk_package}-${CUDA_VERSION//./-}"
  fi
  cuda_package="cuda=${CUDA_FULL_VERSION}-1"
  readonly cudatk_package
  if is_debuntu ; then
#    if is_ubuntu ; then execute_with_retries "apt-get install -y -qq --no-install-recommends cuda-drivers-${DRIVER}=${DRIVER_VERSION}-1" ; fi
    execute_with_retries apt-get install -y -qq --no-install-recommends ${cuda_package} ${cudatk_package}
  elif is_rocky ; then
    # rocky9: cuda-11-[7,8], cuda-12-[1..6]
    execute_with_retries dnf -y -q install "${cudatk_package}"
  fi
  sync
}

function load_kernel_module() {
  # for some use cases, the kernel module needs to be removed before first use of nvidia-smi
  for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia ; do
    ( set +e
      rmmod ${module} > /dev/null 2>&1 || echo "unable to rmmod ${module}"
    )
  done

  depmod -a
  modprobe nvidia
  for suffix in uvm modeset drm; do
    modprobe "nvidia-${suffix}"
  done
  # TODO: if peermem is available, also modprobe nvidia-peermem
}

function install_cuda(){
  is_complete cuda-repo && return
  if [[ "${gpu_count}" == "0" ]] ; then return ; fi

  if ( ge_debian12 && is_src_os ) ; then
    echo "installed with the driver on ${_shortname}"
    return 0
  fi

  # The OS package distributions are unreliable
  install_cuda_runfile

  # Includes CUDA packages
  add_repo_cuda

  mark_complete cuda-repo
}

function install_nvidia_container_toolkit() {
  is_complete install-nvctk && return

  local container_runtime_default
    if command -v docker     ; then container_runtime_default='docker'
  elif command -v containerd ; then container_runtime_default='containerd'
  elif command -v crio       ; then container_runtime_default='crio'
                               else container_runtime_default='' ; fi
  CONTAINER_RUNTIME=$(get_metadata_attribute 'container-runtime' "${container_runtime_default}")

  if test -z "${CONTAINER_RUNTIME}" ; then return ; fi

  add_repo_nvidia_container_toolkit
  if is_debuntu ; then
    execute_with_retries apt-get install -y -q nvidia-container-toolkit ; else
    execute_with_retries dnf     install -y -q nvidia-container-toolkit ; fi
  nvidia-ctk runtime configure --runtime="${CONTAINER_RUNTIME}"
  systemctl restart "${CONTAINER_RUNTIME}"

  mark_complete install-nvctk
}

# Install NVIDIA GPU driver provided by NVIDIA
function install_nvidia_gpu_driver() {
  if ! modprobe nvidia > /dev/null 2>&1; then
    echo "NVIDIA module not loading. Removing completion marker to force
re-install."
    mark_incomplete gpu-driver
  fi

  is_complete gpu-driver && return
  if [[ "${gpu_count}" == "0" ]] ; then return ; fi

  if ( ge_debian12 && is_src_os ) ; then
    add_nonfree_components
    apt-get update -qq
    apt-get -yq install \
        dkms \
        nvidia-open-kernel-dkms \
        nvidia-open-kernel-support \
        nvidia-smi \
        libglvnd0 \
        libcuda1
    echo "NVIDIA GPU driver provided by ${_shortname} was installed successfully"
    return 0
  fi

  # OS driver packages do not produce reliable driver ; use runfile
  install_nvidia_userspace_runfile

  build_driver_from_github

  echo "NVIDIA GPU driver provided by NVIDIA was installed successfully"
  mark_complete gpu-driver
}

function install_ops_agent(){
  is_complete ops-agent && return

  mkdir -p /opt/google
  cd /opt/google
  # https://cloud.google.com/stackdriver/docs/solutions/agents/ops-agent/installation
  curl ${curl_retry_args[@]} -O https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  local expected="038d98644e4c4a7969d26da790946720d278c8d49bb82b677f550c2a2b858411  add-google-cloud-ops-agent-repo.sh"

  execute_with_retries bash add-google-cloud-ops-agent-repo.sh --also-install

  mark_complete ops-agent
}

# Collects 'gpu_utilization' and 'gpu_memory_utilization' metrics
function install_gpu_agent() {
  # Stackdriver GPU agent parameters
#  local -r GPU_AGENT_REPO_URL='https://raw.githubusercontent.com/GoogleCloudPlatform/ml-on-gcp/master/dlvm/gcp-gpu-utilization-metrics'
  local -r GPU_AGENT_REPO_URL='https://raw.githubusercontent.com/GoogleCloudPlatform/ml-on-gcp/refs/heads/master/dlvm/gcp-gpu-utilization-metrics'
  if ( ! command -v pip && is_debuntu ) ; then
    execute_with_retries "apt-get install -y -qq python3-pip"
  fi
  local install_dir=/opt/gpu-utilization-agent
  mkdir -p "${install_dir}"
  curl ${curl_retry_args[@]} \
    "${GPU_AGENT_REPO_URL}/requirements.txt" -o "${install_dir}/requirements.txt"
  curl ${curl_retry_args[@]} \
    "${GPU_AGENT_REPO_URL}/report_gpu_metrics.py" \
    | sed -e 's/-u --format=/--format=/' \
    | dd status=none of="${install_dir}/report_gpu_metrics.py"
  local venv="${install_dir}/venv"
  python_interpreter="/opt/conda/miniconda3/bin/python3"
  [[ -f "${python_interpreter}" ]] || python_interpreter="$(command -v python3)"
  if version_ge "${DATAPROC_IMAGE_VERSION}" "2.2" && is_debuntu ; then
    execute_with_retries "apt-get install -y -qq python3-venv"
  fi
  "${python_interpreter}" -m venv "${venv}"
(
  source "${venv}/bin/activate"
  if [[ -v METADATA_HTTP_PROXY_PEM_URI ]] && [[ -n "${METADATA_HTTP_PROXY_PEM_URI}" ]]; then
    export REQUESTS_CA_BUNDLE="${trusted_pem_path}"
    pip install pip-system-certs
    unset REQUESTS_CA_BUNDLE
  fi
  python3 -m pip install --upgrade pip
  execute_with_retries python3 -m pip install -r "${install_dir}/requirements.txt"
)
  sync

  # Generate GPU service.
  cat <<EOF >/lib/systemd/system/gpu-utilization-agent.service
[Unit]
Description=GPU Utilization Metric Agent

[Service]
Type=simple
PIDFile=/run/gpu_agent.pid
ExecStart=/bin/bash --login -c '. ${venv}/bin/activate ; python3 "${install_dir}/report_gpu_metrics.py"'
User=root
Group=root
WorkingDirectory=/
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  # Reload systemd manager configuration
  systemctl daemon-reload
  # Enable gpu-utilization-agent service
  systemctl --no-reload --now enable gpu-utilization-agent.service
}

function set_hadoop_property() {
  local -r config_file=$1
  local -r property=$2
  local -r value=$3
  "${bdcfg}" set_property \
    --configuration_file "${HADOOP_CONF_DIR}/${config_file}" \
    --name "${property}" --value "${value}" \
    --clobber
}

function configure_yarn_resources() {
  if [[ ! -d "${HADOOP_CONF_DIR}" ]] ; then
    # TODO: when running this script to customize an image, this file
    # needs to be written *after* bdutil completes

    return 0
  fi # pre-init scripts
  if [[ ! -f "${HADOOP_CONF_DIR}/resource-types.xml" ]]; then
    printf '<?xml version="1.0" ?>\n<configuration/>' >"${HADOOP_CONF_DIR}/resource-types.xml"
  fi
  set_hadoop_property 'resource-types.xml' 'yarn.resource-types' 'yarn.io/gpu'

  set_hadoop_property 'capacity-scheduler.xml' \
    'yarn.scheduler.capacity.resource-calculator' \
    'org.apache.hadoop.yarn.util.resource.DominantResourceCalculator'

  set_hadoop_property 'yarn-site.xml' 'yarn.resource-types' 'yarn.io/gpu'
}

# This configuration should be applied only if GPU is attached to the node
function configure_yarn_nodemanager() {
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.resource-plugins' 'yarn.io/gpu'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.resource-plugins.gpu.allowed-gpu-devices' 'auto'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.resource-plugins.gpu.path-to-discovery-executables' "${NVIDIA_SMI_PATH}"
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.linux-container-executor.cgroups.mount' 'true'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.linux-container-executor.cgroups.mount-path' '/sys/fs/cgroup'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.linux-container-executor.cgroups.hierarchy' 'yarn'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.container-executor.class' 'org.apache.hadoop.yarn.server.nodemanager.LinuxContainerExecutor'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.linux-container-executor.group' 'yarn'

  # Fix local dirs access permissions
  local yarn_local_dirs=()

  readarray -d ',' yarn_local_dirs < <("${bdcfg}" get_property_value \
    --configuration_file "${HADOOP_CONF_DIR}/yarn-site.xml" \
    --name "yarn.nodemanager.local-dirs" 2>/dev/null | tr -d '\n')

  if [[ "${#yarn_local_dirs[@]}" -ne "0" && "${yarn_local_dirs[@]}" != "None" ]]; then
    chown yarn:yarn -R "${yarn_local_dirs[@]/,/}"
  fi
}

function configure_gpu_exclusive_mode() {
  # only run this function when spark < 3.0
  if version_ge "${SPARK_VERSION}" "3.0" ; then return 0 ; fi
  # include exclusive mode on GPU
  nvsmi -c EXCLUSIVE_PROCESS
}

function fetch_mig_scripts() {
  mkdir -p /usr/local/yarn-mig-scripts
  sudo chmod 755 /usr/local/yarn-mig-scripts
  execute_with_retries wget -P /usr/local/yarn-mig-scripts/ https://raw.githubusercontent.com/NVIDIA/spark-rapids-examples/branch-22.10/examples/MIG-Support/yarn-unpatched/scripts/nvidia-smi
  execute_with_retries wget -P /usr/local/yarn-mig-scripts/ https://raw.githubusercontent.com/NVIDIA/spark-rapids-examples/branch-22.10/examples/MIG-Support/yarn-unpatched/scripts/mig2gpu.sh
  sudo chmod 755 /usr/local/yarn-mig-scripts/*
}

function configure_gpu_script() {
  # Download GPU discovery script
  local -r spark_gpu_script_dir='/usr/lib/spark/scripts/gpu'
  mkdir -p ${spark_gpu_script_dir}
  # need to update the getGpusResources.sh script to look for MIG devices since if multiple GPUs nvidia-smi still
  # lists those because we only disable the specific GIs via CGROUPs. Here we just create it based off of:
  # https://raw.githubusercontent.com/apache/spark/master/examples/src/main/scripts/getGpusResources.sh
  local -r gpus_resources_script="${spark_gpu_script_dir}/getGpusResources.sh"
  cat > "${gpus_resources_script}" <<'EOF'
#!/usr/bin/env bash

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Example output: {"name": "gpu", "addresses":["0","1","2","3","4","5","6","7"]}

set -e
resources_json="/dev/shm/nvidia/gpusResources.json"
if test -f "${resources_json}" ; then cat "${resources_json}" ; exit 0 ; fi

mkdir -p "$(dirname ${resources_json})"

ADDRS=$(nvidia-smi --query-gpu=index --format=csv,noheader | perl -e 'print(join(q{,},map{chomp; qq{"$_"}}<STDIN>))')

echo {\"name\": \"gpu\", \"addresses\":[${ADDRS}]} | tee "${resources_json}"
EOF

  chmod a+rx "${gpus_resources_script}"

  if version_lt "${SPARK_VERSION}" "3.0" ; then return ; fi

  local spark_defaults_conf="/etc/spark/conf.dist/spark-defaults.conf"
  local spark_defaults_dir="$(dirname "${spark_defaults_conf}")"
  if ! grep spark.executor.resource.gpu.discoveryScript "${spark_defaults_conf}" ; then
    echo "spark.executor.resource.gpu.discoveryScript=${gpus_resources_script}" >> "${spark_defaults_conf}"
  fi
  local executor_cores
  executor_cores="$(nproc | perl -MPOSIX -pe '$_ = POSIX::floor( $_ * 0.75 ); $_-- if $_ % 2')"
  [[ "${executor_cores}" == "0" ]] && executor_cores=1
  local executor_memory
  executor_memory_gb="$(awk '/^MemFree/ {print $2}' /proc/meminfo | perl -MPOSIX -pe '$_ *= 0.75; $_ = POSIX::floor( $_ / (1024*1024) )')"
  local task_cpus=2
  [[ "${task_cpus}" -gt "${executor_cores}" ]] && task_cpus="${executor_cores}"
  local gpu_amount
#  gpu_amount="$(echo $executor_cores | perl -pe "\$_ = ( ${gpu_count} / (\$_ / ${task_cpus}) )")"
  gpu_amount="$(perl -e "print 1 / ${executor_cores}")"

  # the gpu.amount properties are not appropriate for the version of
  # spark shipped with 1.5 images using the capacity scheduler.  TODO:
  # In order to get spark rapids GPU accelerated SQL working on 1.5
  # images, we must configure the Fair scheduler
  version_ge "${DATAPROC_IMAGE_VERSION}" "2.0" || return

  if ! grep -q "BEGIN : RAPIDS properties" "${spark_defaults_conf}"; then
    cat >>"${spark_defaults_conf}" <<EOF
###### BEGIN : RAPIDS properties for Spark ${SPARK_VERSION} ######
# Rapids Accelerator for Spark can utilize AQE, but when the plan is not finalized,
# query explain output won't show GPU operator, if the user has doubts
# they can uncomment the line before seeing the GPU plan explain;
# having AQE enabled gives user the best performance.
#spark.sql.autoBroadcastJoinThreshold=10m
#spark.sql.files.maxPartitionBytes=512m
spark.executor.resource.gpu.amount=1
#spark.executor.cores=${executor_cores}
#spark.executor.memory=${executor_memory_gb}G
#spark.dynamicAllocation.enabled=false
# please update this config according to your application
#spark.task.resource.gpu.amount=${gpu_amount}
#spark.task.cpus=2
#spark.yarn.unmanagedAM.enabled=false
#spark.plugins=com.nvidia.spark.SQLPlugin
###### END   : RAPIDS properties for Spark ${SPARK_VERSION} ######
EOF
  fi
}

function configure_gpu_isolation() {
  if [[ ! -d "${HADOOP_CONF_DIR}" ]]; then
     echo "Hadoop conf dir ${HADOOP_CONF_DIR} not found. Skipping GPU isolation config."
     return
  fi
  # enable GPU isolation
  sed -i "s/yarn\.nodemanager\.linux\-container\-executor\.group\=.*$/yarn\.nodemanager\.linux\-container\-executor\.group\=yarn/g" "${HADOOP_CONF_DIR}/container-executor.cfg"
  if [[ $IS_MIG_ENABLED -ne 0 ]]; then
    # configure the container-executor.cfg to have major caps
    printf '\n[gpu]\nmodule.enabled=true\ngpu.major-device-number=%s\n\n[cgroups]\nroot=/sys/fs/cgroup\nyarn-hierarchy=yarn\n' $MIG_MAJOR_CAPS >> "${HADOOP_CONF_DIR}/container-executor.cfg"
    printf 'export MIG_AS_GPU_ENABLED=1\n' >> "${HADOOP_CONF_DIR}/yarn-env.sh"
    printf 'export ENABLE_MIG_GPUS_FOR_CGROUPS=1\n' >> "${HADOOP_CONF_DIR}/yarn-env.sh"
  else
    printf '\n[gpu]\nmodule.enabled=true\n[cgroups]\nroot=/sys/fs/cgroup\nyarn-hierarchy=yarn\n' >> "${HADOOP_CONF_DIR}/container-executor.cfg"
  fi

  # Configure a systemd unit to ensure that permissions are set on restart
  cat >/etc/systemd/system/dataproc-cgroup-device-permissions.service<<EOF
[Unit]
Description=Set permissions to allow YARN to access device directories

[Service]
ExecStart=/bin/bash -c "chmod a+rwx -R /sys/fs/cgroup/cpu,cpuacct; chmod a+rwx -R /sys/fs/cgroup/devices"

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable dataproc-cgroup-device-permissions
  systemctl start dataproc-cgroup-device-permissions
}

function nvsmi() {
  local nvsmi="/usr/bin/nvidia-smi"
  if   [[ "${nvsmi_works}" == "1" ]] ; then echo -n ''
  elif [[ ! -f "${nvsmi}" ]]         ; then echo "nvidia-smi not installed" >&2 ; return 0
  elif ! eval "${nvsmi} > /dev/null" ; then echo "nvidia-smi fails" >&2 ; return 0
  else nvsmi_works="1" ; fi

  if test -v 1 && [[ "$1" == "-L" ]] ; then
    local NV_SMI_L_CACHE_FILE="/var/run/nvidia-smi_-L.txt"
    if [[ -f "${NV_SMI_L_CACHE_FILE}" ]]; then cat "${NV_SMI_L_CACHE_FILE}"
    else "${nvsmi}" $* | tee "${NV_SMI_L_CACHE_FILE}" ; fi
    return 0
  fi

  "${nvsmi}" $*
}

function install_build_dependencies() {
  is_complete build-dependencies && return

  if is_debuntu ; then
    if is_ubuntu22 && ge_cuda12 ; then
      # On ubuntu22, the default compiler does not build some kernel module versions
      # https://forums.developer.nvidia.com/t/linux-new-kernel-6-5-0-14-ubuntu-22-04-can-not-compile-nvidia-display-card-driver/278553/11
      execute_with_retries apt-get install -y -qq gcc-12
      update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11
      update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12
      update-alternatives --set gcc /usr/bin/gcc-12
    elif is_ubuntu22 && version_lt "${CUDA_VERSION}" "11.7" ; then
      # On cuda less than 11.7, the kernel driver does not build on ubuntu22
      # https://forums.developer.nvidia.com/t/latest-nvidia-driver-470-63-01-installation-fails-with-latest-linux-kernel-5-16-5-100/202972
      echo "N.B.: Older CUDA 11 known bad on ${_shortname}"
    fi

  elif is_rocky ; then
    execute_with_retries dnf -y -q install gcc

    local dnf_cmd="dnf -y -q install kernel-devel-${uname_r}"
    set +e
    eval "${dnf_cmd}" > "${install_log}" 2>&1
    local retval="$?"
    set -e

    if [[ "${retval}" == "0" ]] ; then return ; fi

    local os_ver="$(echo $uname_r | perl -pe 's/.*el(\d+_\d+)\..*/$1/; s/_/./')"
    local vault="https://download.rockylinux.org/vault/rocky/${os_ver}"
    if grep -q 'Unable to find a match: kernel-devel-' "${install_log}" ; then
      # this kernel-devel may have been migrated to the vault
      dnf_cmd="$(echo dnf -y -q --setopt=localpkg_gpgcheck=1 install \
        "${vault}/BaseOS/x86_64/os/Packages/k/kernel-${uname_r}.rpm" \
        "${vault}/BaseOS/x86_64/os/Packages/k/kernel-core-${uname_r}.rpm" \
        "${vault}/BaseOS/x86_64/os/Packages/k/kernel-modules-${uname_r}.rpm" \
        "${vault}/BaseOS/x86_64/os/Packages/k/kernel-modules-core-${uname_r}.rpm" \
        "${vault}/AppStream/x86_64/os/Packages/k/kernel-devel-${uname_r}.rpm"
       )"
    fi

    set +e
    eval "${dnf_cmd}" > "${install_log}" 2>&1
    local retval="$?"
    set -e

    if [[ "${retval}" == "0" ]] ; then return ; fi

    if grep -q 'Status code: 404 for https' "${install_log}" ; then
      local stg_url="https://download.rockylinux.org/stg/rocky/${os_ver}/devel/x86_64/os/Packages/k/"
      dnf_cmd="$(echo dnf -y -q --setopt=localpkg_gpgcheck=1 install \
        "${stg_url}/kernel-${uname_r}.rpm" \
        "${stg_url}/kernel-core-${uname_r}.rpm" \
        "${stg_url}/kernel-modules-${uname_r}.rpm" \
        "${stg_url}/kernel-modules-core-${uname_r}.rpm" \
        "${stg_url}/kernel-devel-${uname_r}.rpm"
       )"
    fi

    execute_with_retries "${dnf_cmd}"
  fi
  mark_complete build-dependencies
}

function is_complete() {
  phase="$1"
  test -f "${workdir}/complete/${phase}"
}

function mark_complete() {
  phase="$1"
  touch "${workdir}/complete/${phase}"
}

function mark_incomplete() {
  phase="$1"
  rm -f "${workdir}/complete/${phase}"
}

function install_dependencies() {
  is_complete install-dependencies && return 0

  pkg_list="screen"
  if is_debuntu ; then execute_with_retries apt-get -y -q install ${pkg_list}
  elif is_rocky ; then execute_with_retries dnf     -y -q install ${pkg_list} ; fi
  mark_complete install-dependencies
}

function prepare_gpu_env(){
  #set_support_matrix

  # if set, this variable includes a gcs path to a build-in-progress indicator
  building_file=""

  set_cuda_version
  set_driver_version

  set +e
  # NV vendor ID is 10DE
  pci_vendor_id="10DE"
  gpu_count="$(grep -i PCI_ID=${pci_vendor_id} /sys/bus/pci/devices/*/uevent | wc -l)"
  set -e

  if [[ "${gpu_count}" > "0" ]] ; then
    # N.B.: https://pci-ids.ucw.cz/v2.2/pci.ids.xz
    pci_device_id="$(grep -h -i PCI_ID=10DE /sys/bus/pci/devices/*/uevent | head -1 | awk -F: '{print $2}')"
    pci_device_id_int="$((16#${pci_device_id}))"
    case "${pci_device_id}" in
      "15F8" ) gpu_type="nvidia-tesla-p100"      ;;
      "1BB3" ) gpu_type="nvidia-tesla-p4"        ;;
      "1DB1" ) gpu_type="nvidia-tesla-v100"      ;;
      "1EB8" ) gpu_type="nvidia-tesla-t4"        ;;
      "20B2" ) gpu_type="nvidia-tesla-a100-80gb" ;;
      "20B5" ) gpu_type="nvidia-tesla-a100-80gb" ;;
      "20F3" ) gpu_type="nvidia-tesla-a100-80gb" ;;
      "20F5" ) gpu_type="nvidia-tesla-a100-80gb" ;;
      "20"*  ) gpu_type="nvidia-tesla-a100"      ;;
      "23"*  ) gpu_type="nvidia-h100"            ;; # NB: install does not begin with legacy image 2.0.68-debian10/cuda11.1
      "27B8" ) gpu_type="nvidia-l4"              ;; # NB: install does not complete with legacy image 2.0.68-debian10/cuda11.1
      *      ) gpu_type="unrecognized"
    esac

    ACCELERATOR="type=${gpu_type},count=${gpu_count}"
  fi

  nvsmi_works="0"

  if   is_cuda11 ; then gcc_ver="11"
  elif is_cuda12 ; then gcc_ver="12" ; fi

  if ! test -v DEFAULT_RAPIDS_RUNTIME ; then
    readonly DEFAULT_RAPIDS_RUNTIME='SPARK'
  fi

  # Set variables from metadata
  RAPIDS_RUNTIME=$(get_metadata_attribute 'rapids-runtime' 'SPARK')
  INCLUDE_GPUS="$(get_metadata_attribute include-gpus "")"
  INCLUDE_PYTORCH="$(get_metadata_attribute 'include-pytorch' 'no')"
  readonly RAPIDS_RUNTIME INCLUDE_GPUS INCLUDE_PYTORCH

  # determine whether we have nvidia-smi installed and working
  nvsmi

  set_nv_urls
  set_cuda_runfile_url
  set_cudnn_version
  set_cudnn_tarball_url
}

# Hold all NVIDIA-related packages from upgrading unintenionally or services like unattended-upgrades
# Users should run apt-mark unhold before they wish to upgrade these packages
function hold_nvidia_packages() {
  if ! is_debuntu ; then return ; fi

  apt-mark hold nvidia-*    > /dev/null 2>&1
  apt-mark hold libnvidia-* > /dev/null 2>&1
  if dpkg -l | grep -q "xserver-xorg-video-nvidia"; then
    apt-mark hold xserver-xorg-video-nvidia*
  fi
}

# --- Global JQ Readers for /run/dpgce-network.json ---
DPGCE_NET_FILE="/run/dpgce-network.json"

# Generic function to query the network info file
function get_network_info() {
  local jq_filter="$1"
  if [[ ! -f "${DPGCE_NET_FILE}" ]]; then
    echo "WARNING: ${DPGCE_NET_FILE} not found, running evaluate_network..." >&2
    evaluate_network > /dev/null # Run in a subshell to not affect current shell
    if [[ ! -f "${DPGCE_NET_FILE}" ]]; then
      echo "ERROR: Failed to create ${DPGCE_NET_FILE}" >&2
      echo "null"
      return 1
    fi
  fi
  jq -r "${jq_filter}" "${DPGCE_NET_FILE}"
}

# Get the primary IP address (interface 0)
function get_primary_ip() {
  get_network_info '.network_interfaces[0].ip'
}

# Get the primary network name
function get_primary_network() {
  get_network_info '.network_interfaces[0].network'
}

# Get the primary subnet name
function get_primary_subnet() {
  get_network_info '.network_interfaces[0].subnet'
}

# Check if the primary interface has an external IP
function has_external_ip() {
  local access_configs
  access_configs=$(get_network_info '.network_interfaces[0].access_configs')
  if [[ "${access_configs}" == "[]" || "${access_configs}" == "null" ]]; then
    return 1 # False
  else
    return 0 # True
  fi
}

# Check if a default route exists
function has_default_route() {
  # This check is done live, before the JSON file is written
  if ip route show default | grep -q default; then
    return 0 # True - default route found
  else
    return 1 # False - no default route
  fi
}

function is_proxy_enabled() {
  local http_proxy=$(get_network_info '.metadata_instance_http_proxy')
  local https_proxy=$(get_network_info '.metadata_instance_https_proxy')
  local proj_http_proxy=$(get_network_info '.metadata_project_http_proxy')
  local proj_https_proxy=$(get_network_info '.metadata_project_https_proxy')

  if [[ "${http_proxy}" != "null" && -n "${http_proxy}" ]] || \
     [[ "${https_proxy}" != "null" && -n "${https_proxy}" ]] || \
     [[ "${proj_http_proxy}" != "null" && -n "${proj_http_proxy}" ]] || \
     [[ "${proj_https_proxy}" != "null" && -n "${proj_https_proxy}" ]]; then
    return 0 # True
  else
    return 1 # False
  fi
}

function can_reach_gstatic() {
  get_network_info '.connectivity.can_reach_gstatic' | grep -q true
}

# --- Globally Useful Helper Functions ---

# Function to safely encode a string for JSON
function json_encode() {
  if [[ "$1" == "null" || -z "$1" ]]; then
    echo "null"
  else
    jq -n --arg v "$1" '$v'
  fi
}

# --- Main Evaluation Function ---

function evaluate_network() {
  # --- Helpers Local to evaluate_network ---
  function _get_meta() {
    local path="$1"
    local url="http://metadata.google.internal/computeMetadata/v1/instance/${path}"
    curl -f -H "Metadata-Flavor: Google" -s "${url}" 2>/dev/null || echo "null"
  }
  function _get_project_meta() {
    local path="$1"
    local url="http://metadata.google.internal/computeMetadata/v1/project/${path}"
    curl -f -H "Metadata-Flavor: Google" -s "${url}" 2>/dev/null || echo "null"
  }
  function get_meta_base() {
    _get_meta "$1" | awk -F/ '{print $NF}'
  }
  function get_meta_attr() {
    _get_meta "attributes/$1"
  }
  function get_project_meta_attr() {
    _get_project_meta "attributes/$1"
  }
  function get_net_meta() {
    local iface="$1"
    local item="$2"
    local path="network-interfaces/${iface}${item}"
    if [[ "${item}" == */ ]]; then
      # If item is a directory, list its contents as a JSON array
      local contents=$(_get_meta "${path}")
      if [[ "${contents}" == "null" || -z "${contents}" ]]; then
        echo "[]"
      else
        echo "${contents}" | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("/") | last)'
      fi
    else
      # Otherwise, fetch the value
      _get_meta "${path}"
    fi
  }
  function get_net_meta_base() {
    local iface="$1"
    local item="$2"
    _get_meta "network-interfaces/${iface}${item}" | awk -F/ '{print $NF}'
  }
  function cmd_output() {
    json_encode "$("$@")"
  }
  function file_content() {
    if [[ -f "$1" ]]; then
      json_encode "$(cat "$1")"
    else
      echo "null"
    fi
  }
  # --- End Local Helpers ---

  # --- Connectivity Checks ---
  local public_ipv4=""
  local public_ipv6=""
  local can_reach_ns1_v4=false
  local can_reach_ns1_v6=false
  local can_reach_gstatic=false
  local traceroute_gstatic="null"

  if command -v dig > /dev/null 2>&1; then
    if ping -4 -c1 -W1 ns1.google.com > /dev/null 2>&1; then
      can_reach_ns1_v4=true
      public_ipv4=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"' || echo "")
    fi
    if ping -6 -c1 -W1 ns1.google.com > /dev/null 2>&1; then
      can_reach_ns1_v6=true
      public_ipv6=$(dig -6 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"' || echo "")
    fi
  else
    echo "WARNING: dig command not found, skipping public IP checks." >&2
  fi

  if has_default_route; then
    if curl -s --head --max-time 5 http://www.gstatic.com/generate_204 | grep -E "HTTP/[0-9.]* (2..|3..)" > /dev/null; then
      can_reach_gstatic=true
      if command -v traceroute > /dev/null 2>&1; then
        traceroute_gstatic=$(traceroute -m 15 www.gstatic.com 2>/dev/null || echo "traceroute failed")
      else
         traceroute_gstatic="traceroute command not found"
      fi
    fi
  fi

  # --- Kerberos Checks ---
  local krb5_conf="/etc/krb5.conf"
  local kerberos_configured=false
  local kdc_realm="null"
  local kdc_hosts="[]"
  local can_reach_kdc=false
  if [[ -f "${krb5_conf}" ]]; then
    kerberos_configured=true
    kdc_realm=$(awk -F '=' '/default_realm/ {print $2}' "${krb5_conf}" | tr -d ' ' || echo "null")
    if [[ "${kdc_realm}" != "null" ]]; then
      local realm_hosts=$(awk "/${kdc_realm//./\\.} = {/,/}/" "${krb5_conf}" | grep kdc = | awk -F '=' '{print $2}' | tr -d ' ')
      kdc_hosts=$(echo "${realm_hosts}" | jq -R -s 'split("\n") | map(select(length > 0))')
      for host in ${realm_hosts}; do
        if ping -c1 -W1 "${host}" > /dev/null 2>&1; then
          can_reach_kdc=true
          break
        fi
      done
    fi
  fi

  local json_output
  json_output=$(jq -n \
    --arg hostname "$(_get_meta hostname)" \
    --arg instance_id "$(_get_meta id)" \
    --arg machine_type "$(get_meta_base machine-type)" \
    --arg zone "$(get_meta_base zone)" \
    --arg project_id "$(_get_project_meta project-id)" \
    --arg can_ip_forward "$(_get_meta can-ip-forward)" \
    --argjson tags "$(_get_meta tags || echo "[]")" \
    --arg metadata_instance_http_proxy "$(get_meta_attr http-proxy)" \
    --arg metadata_instance_https_proxy "$(get_meta_attr https-proxy)" \
    --arg metadata_project_http_proxy "$(get_project_meta_attr http-proxy)" \
    --arg metadata_project_https_proxy "$(get_project_meta_attr https-proxy)" \
    --arg local_ip_addr "$(ip -json addr || echo "[]")" \
    --arg local_ip_route "$(ip -json route show table all || echo "[]")" \
    --arg local_resolv_conf "$(cat /etc/resolv.conf 2>/dev/null || echo "")" \
    --arg env_http_proxy "${http_proxy:-null}" \
    --arg env_https_proxy "${https_proxy:-null}" \
    --arg env_no_proxy "${no_proxy:-null}" \
    --arg public_ipv4 "${public_ipv4}" \
    --arg public_ipv6 "${public_ipv6}" \
    --arg can_reach_ns1_v4 "${can_reach_ns1_v4}" \
    --arg can_reach_ns1_v6 "${can_reach_ns1_v6}" \
    --arg can_reach_gstatic "${can_reach_gstatic}" \
    --arg traceroute_gstatic "${traceroute_gstatic}" \
    --arg kerberos_configured "${kerberos_configured}" \
    --arg kdc_realm "${kdc_realm}" \
    --argjson kdc_hosts "${kdc_hosts}" \
    --arg can_reach_kdc "${can_reach_kdc}" \
    '{
      hostname: $hostname,
      instance_id: $instance_id,
      machine_type: $machine_type,
      zone: $zone,
      project_id: $project_id,
      can_ip_forward: ($can_ip_forward == "true"),
      tags: $tags,
      metadata_instance_http_proxy: ($metadata_instance_http_proxy | if . == "null" then null else . end),
      metadata_instance_https_proxy: ($metadata_instance_https_proxy | if . == "null" then null else . end),
      metadata_project_http_proxy: ($metadata_project_http_proxy | if . == "null" then null else . end),
      metadata_project_https_proxy: ($metadata_project_https_proxy | if . == "null" then null else . end),
      local_ip_addr: ($local_ip_addr | fromjson?),
      local_ip_route: ($local_ip_route | fromjson?),
      local_resolv_conf: ($local_resolv_conf | if . == "" then null else . end),
      env_http_proxy: ($env_http_proxy | if . == "null" then null else . end),
      env_https_proxy: ($env_https_proxy | if . == "null" then null else . end),
      env_no_proxy: ($env_no_proxy | if . == "null" then null else . end),
      connectivity: {
        public_ipv4: ($public_ipv4 | if . == "" then null else . end),
        public_ipv6: ($public_ipv6 | if . == "" then null else . end),
        can_reach_ns1_v4: ($can_reach_ns1_v4 == "true"),
        can_reach_ns1_v6: ($can_reach_ns1_v6 == "true"),
        can_reach_gstatic: ($can_reach_gstatic == "true"),
        traceroute_gstatic: ($traceroute_gstatic | if . == "traceroute failed" or . == "traceroute command not found" then null else . end)
      },
      kerberos: {
        configured: ($kerberos_configured == "true"),
        default_realm: ($kdc_realm | if . == "null" then null else . end),
        kdc_hosts: $kdc_hosts,
        can_reach_kdc: ($can_reach_kdc == "true")
      }
    }')

  # Add network interfaces
  local ifs=$(_get_meta network-interfaces/)
  local ni_array="[]"
  for iface in ${ifs}; do
    local iface_name=$(get_net_meta "${iface}" name)
    local ethtool_info="null"
    local ethtool_driver="null"
    if [[ -n "${iface_name}" && "${iface_name}" != "null" && -x "/sbin/ethtool" ]]; then
      ethtool_info=$(/sbin/ethtool "${iface_name}" 2>/dev/null || echo "")
      ethtool_driver=$(/sbin/ethtool -i "${iface_name}" 2>/dev/null || echo "")
    fi

    local ip_aliases=$(get_net_meta "${iface}" ip-aliases/)
    # Ensure access_configs are fetched and formatted as JSON array
    local ac_contents=$(_get_meta "network-interfaces/${iface}access-configs/")
    local access_configs="[]"
    if [[ "${ac_contents}" != "null" && -n "${ac_contents}" ]]; then
        readarray -t configs <<<"${ac_contents}"
        local ac_json_array="["
        local first_ac=true
        for config in "${configs[@]}"; do
            if [[ -z "${config}" ]]; then continue; fi
            if [ "$first_ac" = false ]; then ac_json_array+=","; fi
            first_ac=false
            local ext_ip=$(_get_meta "network-interfaces/${iface}access-configs/${config}external-ip")
            local ac_type=$(_get_meta "network-interfaces/${iface}access-configs/${config}type")
            ac_json_array+=$(jq -n --arg external_ip "${ext_ip}" --arg type "${ac_type}" '{external_ip: $external_ip, type: $type}')
        done
        ac_json_array+="]"
        access_configs=$ac_json_array
    fi

    local interface_json=$(jq -n \
      --arg interface "${iface%%/}" \
      --arg name "${iface_name}" \
      --arg ip "$(get_net_meta "${iface}" ip)" \
      --arg network "$(get_net_meta_base "${iface}" network)" \
      --arg subnet "$(get_net_meta_base "${iface}" subnet)" \
      --arg gateway "$(get_net_meta "${iface}" gateway)" \
      --argjson ip_aliases "${ip_aliases}" \
      --argjson access_configs "${access_configs}" \
      --arg ethtool_info "${ethtool_info}" \
      --arg ethtool_driver "${ethtool_driver}" \
      '{
        interface: $interface,
        name: ($name | if . == "null" then null else . end),
        ip: $ip,
        network: $network,
        subnet: $subnet,
        gateway: $gateway,
        ip_aliases: $ip_aliases,
        access_configs: $access_configs,
        ethtool_info: ($ethtool_info | if . == "null" or . == "" then null else . end),
        ethtool_driver: ($ethtool_driver | if . == "null" or . == "" then null else . end)
      }')
    ni_array=$(echo "$ni_array" | jq --argjson item "$interface_json" '. += [$item]')
  done

  json_output=$(echo "$json_output" | jq --argjson ni "$ni_array" '.network_interfaces = $ni')

  # Add sys_nvidia_devices
  local sys_nvidia="null"
  if [[ -d /sys/bus/pci/drivers/nvidia ]]; then
    sys_nvidia=$(ls /sys/bus/pci/drivers/nvidia || echo "")
  fi
  json_output=$(echo "$json_output" | jq --arg sys_nvidia "${sys_nvidia}" '.sys_nvidia_devices = ($sys_nvidia | if . == "null" or . == "" then null else . end)')

  # Write to file and stdout
  local output_file="/run/dpgce-network.json"
  echo "$json_output" | tee "$output_file"
  echo "Network evaluation saved to ${output_file}" >&2
}

function check_secure_boot() {
  local SECURE_BOOT="disabled"
  if command -v mokutil ; then
      SECURE_BOOT=$(mokutil --sb-state|awk '{print $2}')
  fi

  PSN="$(get_metadata_attribute private_secret_name)"
  readonly PSN

  if [[ "${SECURE_BOOT}" == "enabled" ]] && le_debian11 ; then
    echo "WARN: Secure Boot is not supported on Debian before image 2.2. Please disable Secure Boot while creating the cluster.  Continue at your own peril."
  elif [[ "${SECURE_BOOT}" == "enabled" ]] && [[ -z "${PSN}" ]]; then
    echo "Error: Secure boot is enabled, but no signing material provided."
    echo "Please either disable secure boot or provide signing material as per"
    echo "https://github.com/GoogleCloudDataproc/custom-images/tree/master/examples/secure-boot"
    return 1
  fi

  CA_TMPDIR="$(mktemp -u -d -p /run/tmp -t ca_dir-XXXX)"
  readonly CA_TMPDIR

  if is_ubuntu ; then mok_key=/var/lib/shim-signed/mok/MOK.priv
                      mok_der=/var/lib/shim-signed/mok/MOK.der
                 else mok_key=/var/lib/dkms/mok.key
                      mok_der=/var/lib/dkms/mok.pub ; fi
  return 0
}


# Function to group Hadoop/Spark config steps (called in init-action mode or deferred)
function run_hadoop_spark_config() {
  # Ensure necessary variables are available or re-evaluated
  # prepare_gpu_env needs CUDA/Driver versions, call it first if needed
  # Set GCS bucket for caching
  if [[ ! -v pkg_bucket ]] ; then
    temp_bucket="$(get_metadata_attribute dataproc-temp-bucket)"
    readonly temp_bucket
    readonly pkg_bucket="gs://${temp_bucket}/dpgce-packages"
  fi
  if [[ ! -v CUDA_VERSION || ! -v DRIVER_VERSION ]]; then prepare_gpu_env; fi
  # Re-read ROLE
  ROLE="$(get_metadata_attribute dataproc-role)";
  # Re-read SPARK_VERSION if not set or default
  if [[ ! -v SPARK_VERSION || "${SPARK_VERSION}" == "0.0" ]]; then
      SPARK_VERSION="$(spark-submit --version 2>&1 | sed -n 's/.*version[[:blank:]]\+\([0-9]\+\.[0-9]\).*/\1/p' | head -n1 || echo "0.0")"
  fi
  # Re-check GPU count
  set +e
  gpu_count="$(grep -i PCI_ID=10DE /sys/bus/pci/devices/*/uevent | wc -l)"
  set -e
  # Re-check MIG status
  IS_MIG_ENABLED=0
  NVIDIA_SMI_PATH='/usr/bin' # Reset default path
  MIG_MAJOR_CAPS=0
  if [[ "${gpu_count}" -gt "0" ]] && nvsmi >/dev/null 2>&1; then # Check if nvsmi works before querying
      migquery_result="$(nvsmi --query-gpu=mig.mode.current --format=csv,noheader || echo '[N/A]')"
      if [[ "${migquery_result}" != "[N/A]" && "${migquery_result}" != "" ]]; then
          NUM_MIG_GPUS="$(echo ${migquery_result} | uniq | wc -l)"
          if [[ "${NUM_MIG_GPUS}" -eq "1" ]] && (echo "${migquery_result}" | grep -q Enabled); then
            IS_MIG_ENABLED=1
            NVIDIA_SMI_PATH='/usr/local/yarn-mig-scripts/' # Set MIG path
            MIG_MAJOR_CAPS=$(grep nvidia-caps /proc/devices | cut -d ' ' -f 1 || echo 0)
            if [[ ! -d "/usr/local/yarn-mig-scripts" ]]; then fetch_mig_scripts || echo "WARN: Failed to fetch MIG scripts." >&2; fi
          fi
      fi
  fi

  # Ensure config directories exist
  if [[ ! -d "${HADOOP_CONF_DIR}" || ! -d "${SPARK_CONF_DIR}" ]]; then
     echo "ERROR: Config directories (${HADOOP_CONF_DIR}, ${SPARK_CONF_DIR}) not found. Cannot apply configuration."
     return 1 # Use return instead of exit in a function
  fi

  # Run config applicable to all nodes
  configure_yarn_resources

  # Run node-specific config
  if [[ "${gpu_count}" -gt 0 ]]; then
    configure_yarn_nodemanager
    install_spark_rapids # Installs JARs
    configure_gpu_script
    configure_gpu_isolation
    configure_gpu_exclusive_mode # Call this here, it checks Spark version internally
  elif [[ "${ROLE}" == "Master" ]]; then
    # Master node without GPU still needs some config
    configure_yarn_nodemanager
    install_spark_rapids # Still need JARs on Master
    configure_gpu_script
  else
    # Worker node without GPU, skip node-specific YARN/Spark config.
    :
  fi

  return 0 # Explicitly return success
}

# This function now ONLY generates the script and service file.
# It does NOT enable the service here.
function create_deferred_config_files() {
  local -r service_name="dataproc-gpu-config"
  local -r service_file="/etc/systemd/system/${service_name}.service"
  # This is the script that will contain the config logic
  local -r config_script_path="/usr/local/sbin/apply-dataproc-gpu-config.sh"

  # Use 'declare -f' to extract function definitions needed by the config logic
  # and write them, along with the config logic itself, into the new script.
  cat <<EOF > "${config_script_path}"
#!/bin/bash
# Deferred configuration script generated by install_gpu_driver.sh
set -xeuo pipefail

readonly tmpdir=/tmp
readonly config_script_path="${config_script_path}"
readonly service_name="${service_name}"
readonly service_file="${service_file}"

# --- Minimal necessary functions and variables ---
# Define constants
readonly HADOOP_CONF_DIR='/etc/hadoop/conf'
readonly SPARK_CONF_DIR='/etc/spark/conf'
readonly bdcfg="/usr/local/bin/bdconfig"
readonly workdir=/opt/install-dpgce # Needed for cache_fetched_package

# --- Define Necessary Global Arrays ---
# These need to be explicitly defined here as they are not functions.
$(declare -p DRIVER_FOR_CUDA)
$(declare -p DRIVER_SUBVER)
$(declare -p CUDNN_FOR_CUDA)
$(declare -p NCCL_FOR_CUDA)
$(declare -p CUDA_SUBVER)
# drv_for_cuda is defined within set_cuda_runfile_url, which is included below

# Define minimal metadata functions
$(declare -f print_metadata_value)
$(declare -f print_metadata_value_if_exists)
$(declare -f get_metadata_value)
$(declare -f get_metadata_attribute)

# Define nvsmi wrapper
$(declare -f nvsmi)
nvsmi_works="0" # Initialize variable used by nvsmi

# Define version comparison
$(declare -f version_ge)
$(declare -f version_gt)
$(declare -f version_le)
$(declare -f version_lt)

# Define OS check functions
$(declare -f os_id)
$(declare -f os_version)
$(declare -f os_codename) # Added os_codename as it's used by clean_up_sources_lists indirectly via os_add_repo
$(declare -f is_debian)
$(declare -f is_ubuntu)
$(declare -f is_rocky)
$(declare -f is_debuntu)
$(declare -f is_debian10)
$(declare -f is_debian11)
$(declare -f is_debian12)
$(declare -f is_rocky8)
$(declare -f is_rocky9)
$(declare -f is_ubuntu18)
$(declare -f is_ubuntu20)
$(declare -f is_ubuntu22)
$(declare -f ge_debian12)
$(declare -f le_debian10)
$(declare -f le_debian11)
$(declare -f ge_ubuntu20)
$(declare -f le_ubuntu18)
$(declare -f ge_rocky9)
$(declare -f os_vercat) # Added os_vercat as it's used by set_nv_urls/set_cuda_runfile_url
# Define _shortname (needed by install_spark_rapids -> cache_fetched_package and others)
readonly _shortname="\$(os_id)\$(os_version|perl -pe 's/(\\d+).*/\$1/')"
# Define shortname and nccl_shortname (needed by set_nv_urls)
if is_ubuntu22  ; then
    nccl_shortname="ubuntu2004"
    shortname="\$(os_id)\$(os_vercat)"
elif ge_rocky9 ; then
    nccl_shortname="rhel8"
    shortname="rhel9"
elif is_rocky ; then
    shortname="\$(os_id | sed -e 's/rocky/rhel/')\$(os_vercat)"
    nccl_shortname="\${shortname}"
else
    shortname="\$(os_id)\$(os_vercat)"
    nccl_shortname="\${shortname}"
fi
readonly shortname nccl_shortname

# Define prepare_gpu_env and its dependencies
$(declare -f prepare_gpu_env)
$(declare -f set_cuda_version)
$(declare -f set_driver_version)
$(declare -f set_nv_urls)
$(declare -f set_cuda_runfile_url)
$(declare -f set_cudnn_version)
$(declare -f set_cudnn_tarball_url)
$(declare -f is_cuda11)
$(declare -f is_cuda12)
$(declare -f le_cuda11)
$(declare -f le_cuda12)
$(declare -f ge_cuda11)
$(declare -f ge_cuda12)
$(declare -f is_cudnn8)
$(declare -f is_cudnn9)

# Define DATAPROC_IMAGE_VERSION (re-evaluate)
SPARK_VERSION="\$(spark-submit --version 2>&1 | sed -n 's/.*version[[:blank:]]\+\([0-9]\+\.[0-9]\).*/\1/p' | head -n1 || echo "0.0")"
if   version_lt "\${SPARK_VERSION}" "2.5" ; then DATAPROC_IMAGE_VERSION="1.5"
elif version_lt "\${SPARK_VERSION}" "3.2" ; then DATAPROC_IMAGE_VERSION="2.0"
elif version_lt "\${SPARK_VERSION}" "3.4" ; then DATAPROC_IMAGE_VERSION="2.1"
elif version_lt "\${SPARK_VERSION}" "3.6" ; then
  if [[ -f /etc/environment ]] ; then
    eval "\$(grep '^DATAPROC_IMAGE_VERSION' /etc/environment)" || DATAPROC_IMAGE_VERSION="2.2"
  else
    DATAPROC_IMAGE_VERSION="2.2"
  fi
else DATAPROC_IMAGE_VERSION="2.3" ; fi # Default to latest known version
readonly DATAPROC_IMAGE_VERSION

# Define set_hadoop_property
$(declare -f set_hadoop_property)

# --- Include definitions of functions called by the config logic ---
$(declare -f configure_yarn_resources)
$(declare -f configure_yarn_nodemanager)
$(declare -f install_spark_rapids)
$(declare -f configure_gpu_script)
$(declare -f configure_gpu_isolation)
$(declare -f configure_gpu_exclusive_mode)
$(declare -f fetch_mig_scripts)
$(declare -f cache_fetched_package)
$(declare -f execute_with_retries)

# --- Define gsutil/gcloud commands and curl args ---
gsutil_cmd="gcloud storage"
gsutil_stat_cmd="gcloud storage objects describe"
gcloud_sdk_version="\$(gcloud --version | awk -F'SDK ' '/Google Cloud SDK/ {print \$2}' || echo '0.0.0')"
if version_lt "\${gcloud_sdk_version}" "402.0.0" ; then
  gsutil_cmd="gsutil -o GSUtil:check_hashes=never"
  gsutil_stat_cmd="gsutil stat"
fi
curl_retry_args="-fsSL --retry-connrefused --retry 10 --retry-max-time 30"

# --- Include the main config function ---
$(declare -f run_hadoop_spark_config)

# --- Execute the config logic ---
if run_hadoop_spark_config; then
  # Configuration successful, disable the service
  systemctl disable ${service_name}.service
  rm -f "${config_script_path}" "${service_file}"
  systemctl daemon-reload
else
  echo "ERROR: Deferred configuration script (${config_script_path}) failed." >&2
  # Keep the service enabled to allow for manual inspection/retry
  exit 1
fi

# Restart services after applying config
for svc in resourcemanager nodemanager; do
  if (systemctl is-active --quiet hadoop-yarn-\${svc}.service); then
    systemctl stop  hadoop-yarn-\${svc}.service || echo "WARN: Failed to stop \${svc}"
    systemctl start hadoop-yarn-\${svc}.service || echo "WARN: Failed to start \${svc}"
  fi
done

exit 0
EOF

  chmod +x "${config_script_path}"

  cat <<EOF > "${service_file}"
[Unit]
Description=Apply Dataproc GPU configuration on first boot
# Ensure it runs after Dataproc agent and YARN services are likely up
After=google-dataproc-agent.service network-online.target hadoop-yarn-resourcemanager.service hadoop-yarn-nodemanager.service
Wants=network-online.target google-dataproc-agent.service

[Service]
Type=oneshot
ExecStart=${config_script_path} # Execute the generated config script
RemainAfterExit=no # Service is done after exec
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${service_file}"
  # Service is enabled later only if IS_CUSTOM_IMAGE_BUILD is true
}


function main() {
  # Perform installations (these are generally safe during image build)
  if (grep -qi PCI_ID=10DE /sys/bus/pci/devices/*/uevent); then

    # Check MIG status early, primarily for driver installation logic
    migquery_result="$(nvsmi --query-gpu=mig.mode.current --format=csv,noheader || echo '[N/A]')" # Use || for safety
    if [[ "${migquery_result}" == "[N/A]" ]] ; then migquery_result="" ; fi
    NUM_MIG_GPUS="$(echo ${migquery_result} | uniq | wc -l)"

    if [[ "${NUM_MIG_GPUS}" -gt 0 ]] ; then
      if [[ "${NUM_MIG_GPUS}" -eq "1" ]]; then
        if (echo "${migquery_result}" | grep Enabled); then
          IS_MIG_ENABLED=1
          # Fetch MIG scripts early if needed by driver install/check
          if [[ ! -d "/usr/local/yarn-mig-scripts" ]]; then fetch_mig_scripts || echo "WARN: Failed to fetch MIG scripts." >&2; fi
        fi
      fi
    fi

    # Install core components if MIG is not already enabled (MIG setup implies drivers exist)
    if [[ $IS_MIG_ENABLED -eq 0 ]]; then
      install_nvidia_gpu_driver
      install_nvidia_container_toolkit
      install_cuda
      load_kernel_module # Load modules after driver install

      if [[ -n ${CUDNN_VERSION} ]]; then
        install_nvidia_nccl
        install_nvidia_cudnn
      fi
      case "${INCLUDE_PYTORCH^^}" in
        "1" | "YES" | "TRUE" ) install_pytorch ;;
      esac
      #Install GPU metrics collection in Stackdriver if needed
      if [[ "${INSTALL_GPU_AGENT}" == "true" ]]; then
        #install_ops_agent
        install_gpu_agent
        echo 'GPU metrics agent successfully deployed.'
      else
        echo 'GPU metrics agent will not be installed.'
      fi

      # for some use cases, the kernel module needs to be removed before first use of nvidia-smi
      for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia ; do
        rmmod ${module} > /dev/null 2>&1 || echo "unable to rmmod ${module}"
      done

      if test -n "$(nvsmi -L)" ; then
        # cache the result of the gpu query
        ADDRS=$(nvsmi --query-gpu=index --format=csv,noheader | perl -e 'print(join(q{,},map{chomp; qq{"$_"}}<STDIN>))')
        echo "{\"name\": \"gpu\", \"addresses\":[$ADDRS]}" | tee "/var/run/nvidia-gpu-index.txt"
        chmod a+r "/var/run/nvidia-gpu-index.txt"
      fi
      MIG_GPU_LIST="$(nvsmi -L | grep -E '(MIG|[PVAH]100)' || echo -n "")"
      NUM_MIG_GPUS="$(test -n "${MIG_GPU_LIST}" && echo "${MIG_GPU_LIST}" | wc -l || echo "0")"
      if [[ "${NUM_MIG_GPUS}" -gt "0" ]] ; then
        # enable MIG on every GPU
        for GPU_ID in $(echo ${MIG_GPU_LIST} | awk -F'[: ]' '{print $2}') ; do
          if version_le "${CUDA_VERSION}" "11.6" ; then
            nvsmi -i "${GPU_ID}" --multi-instance-gpu=1
          else
            nvsmi -i "${GPU_ID}" --multi-instance-gpu 1

          fi
        done

        NVIDIA_SMI_PATH='/usr/local/yarn-mig-scripts/'
        MIG_MAJOR_CAPS="$(grep nvidia-caps /proc/devices | cut -d ' ' -f 1)"
        fetch_mig_scripts
      else
        configure_gpu_exclusive_mode
      fi
    fi

    configure_yarn_nodemanager
    install_spark_rapids
    configure_gpu_script
    configure_gpu_isolation
  elif [[ "${ROLE}" == "Master" ]]; then
    # Master node without GPU detected.
    :
  else
    # Worker node without GPU detected.
    :
  fi # End GPU detection

  # --- Generate Config Script and Service File ---
  # This happens in both modes now
  create_deferred_config_files

  # --- Apply or Defer Configuration ---
  if [[ "${IS_CUSTOM_IMAGE_BUILD}" == "true" ]]; then
    # Enable the systemd service for first boot
    systemctl enable "dataproc-gpu-config.service"
  else
    # Running as a standard init action: execute the generated script immediately
    local -r config_script_path="/usr/local/sbin/apply-dataproc-gpu-config.sh"
    if [[ -x "${config_script_path}" ]]; then
        bash -x "${config_script_path}"
    else
        echo "ERROR: Generated config script ${config_script_path} not found or not executable."
        exit 1
    fi
    # The config script handles its own cleanup and service disabling on success
  fi
  # --- End Apply or Defer ---
  mark_complete install_gpu_driver-main
}

function cache_fetched_package() {
  local src_url="$1"
  local gcs_fn="$2"
  local local_fn="$3"

  if ${gsutil_stat_cmd} "${gcs_fn}" 2>&1 ; then
    execute_with_retries ${gsutil_cmd} cp "${gcs_fn}" "${local_fn}"
  else
    time ( curl ${curl_retry_args[@]} "${src_url}" -o "${local_fn}" && \
           execute_with_retries ${gsutil_cmd} cp "${local_fn}" "${gcs_fn}" ; )
  fi
}

function clean_up_sources_lists() {
  if ! is_debuntu; then return; fi
  #
  # bigtop (primary)
  #
  local -r dataproc_repo_file="/etc/apt/sources.list.d/dataproc.list"

  if [[ -f "${dataproc_repo_file}" ]] && ! grep -q signed-by "${dataproc_repo_file}" ; then
    region="$(get_metadata_value zone | perl -p -e 's:.*/:: ; s:-[a-z]+$::')"

    local regional_bigtop_repo_uri
    regional_bigtop_repo_uri=$(cat ${dataproc_repo_file} |
      sed -E "s#/dataproc-bigtop-repo(-dev)?/#/goog-dataproc-bigtop-repo\\1-${region}/#" |
      grep -E "deb .*goog-dataproc-bigtop-repo(-dev)?-${region}.* dataproc contrib" |
      cut -d ' ' -f 2 |
      head -1)

    if [[ "${regional_bigtop_repo_uri}" == */ ]]; then
      local -r bigtop_key_uri="${regional_bigtop_repo_uri}archive.key"
    else
      local -r bigtop_key_uri="${regional_bigtop_repo_uri}/archive.key"
    fi

    local -r bigtop_kr_path="/usr/share/keyrings/bigtop-keyring.gpg"
    rm -f "${bigtop_kr_path}"
    import_gpg_keys --keyring-file "${bigtop_kr_path}" --key-url "${bigtop_key_uri}"

    sed -i -e "s:deb https:deb [signed-by=${bigtop_kr_path}] https:g" "${dataproc_repo_file}"
    sed -i -e "s:deb-src https:deb-src [signed-by=${bigtop_kr_path}] https:g" "${dataproc_repo_file}"
  fi

  #
  # adoptium
  #
  # https://adoptium.net/installation/linux/#_deb_installation_on_debian_or_ubuntu
  local -r key_url="https://packages.adoptium.net/artifactory/api/gpg/key/public"
  local -r adoptium_kr_path="/usr/share/keyrings/adoptium.gpg"
  rm -f "${adoptium_kr_path}"
  local -r old_adoptium_list="/etc/apt/sources.list.d/adoptopenjdk.list"
  if test -f "${old_adoptium_list}" ; then
    rm -f "${old_adoptium_list}"
  fi
  import_gpg_keys --keyring-file "${adoptium_kr_path}" \
                  --key-id "0x3b04d753c9050d9a5d343f39843c48a565f8f04b" \
                  --key-id "0x35baa0b33e9eb396f59ca838c0ba5ce6dc6315a3"
  echo "deb [signed-by=${adoptium_kr_path}] https://packages.adoptium.net/artifactory/deb/ $(os_codename) main" \
   > /etc/apt/sources.list.d/adoptium.list

  #
  # docker
  #
  local docker_kr_path="/usr/share/keyrings/docker-keyring.gpg"
  local docker_repo_file="/etc/apt/sources.list.d/docker.list"
  local -r docker_key_url="https://download.docker.com/linux/$(os_id)/gpg"

  rm -f "${docker_kr_path}"
  import_gpg_keys --keyring-file "${docker_kr_path}" --key-url "${docker_key_url}"
  echo "deb [signed-by=${docker_kr_path}] https://download.docker.com/linux/$(os_id) $(os_codename) stable" \
    > ${docker_repo_file}

  #
  # google cloud + logging/monitoring
  #
  local gcloud_kr_path="/usr/share/keyrings/cloud.google.gpg"
  if ls /etc/apt/sources.list.d/google-clou*.list ; then
    rm -f "${gcloud_kr_path}"
    import_gpg_keys --keyring-file "${gcloud_kr_path}" --key-url "https://packages.cloud.google.com/apt/doc/apt-key.gpg"
    for list in google-cloud google-cloud-logging google-cloud-monitoring ; do
      list_file="/etc/apt/sources.list.d/${list}.list"
      if [[ -f "${list_file}" ]]; then
        sed -i -e "s:deb https:deb [signed-by=${gcloud_kr_path}] https:g" "${list_file}"
      fi
    done
  fi

  #
  # cran-r
  #
  if [[ -f /etc/apt/sources.list.d/cran-r.list ]]; then
    local cranr_kr_path="/usr/share/keyrings/cran-r.gpg"
    rm -f "${cranr_kr_path}"
    import_gpg_keys --keyring-file "${cranr_kr_path}" \
                    --key-id "0x95c0faf38db3ccad0c080a7bdc78b2ddeabc47b7" \
                    --key-id "0xe298a3a825c0d65dfd57cbb651716619e084dab9"
    sed -i -e "s:deb http:deb [signed-by=${cranr_kr_path}] http:g" /etc/apt/sources.list.d/cran-r.list
  fi

  #
  # mysql
  #
  if [[ -f /etc/apt/sources.list.d/mysql.list ]]; then
    rm -f /usr/share/keyrings/mysql.gpg

    import_gpg_keys --keyring-file /usr/share/keyrings/mysql.gpg --key-id "0xBCA43417C3B485DD128EC6D4B7B3B788A8D3785C"

    sed -i -e 's:deb https:deb [signed-by=/usr/share/keyrings/mysql.gpg] https:g' /etc/apt/sources.list.d/mysql.list
  fi

  if [[ -f /etc/apt/trusted.gpg ]] ; then mv /etc/apt/trusted.gpg /etc/apt/old-trusted.gpg ; fi

}

function exit_handler() {
  # Purge private key material until next grant
  clear_dkms_key

  # clean up incomplete build indicators
  if test -n "${building_file}" ; then
    if ${gsutil_stat_cmd} "${building_file}" ; then ${gsutil_cmd} rm "${building_file}" || true ; fi
  fi

  set +e # Allow cleanup commands to fail without exiting script
  echo "Exit handler invoked"

  # Clear pip cache
  # TODO: make this conditional on which OSs have pip without cache purge
  pip cache purge || echo "unable to purge pip cache"


  # If system memory was sufficient to mount memory-backed filesystems
  if [[ "${tmpdir}" == "/mnt/shm" ]] ; then
    # remove the tmpfs pip cache-dir
    pip config unset global.cache-dir || echo "unable to unset global pip cache"

    # Clean up shared memory mounts
    for shmdir in /var/cache/apt/archives /var/cache/dnf /mnt/shm /tmp /var/cudnn-local ; do
      if ( grep -q "^tmpfs ${shmdir}" /proc/mounts && ! grep -q "^tmpfs ${shmdir}" /etc/fstab ) ; then
        umount -f ${shmdir}
      fi
    done

    # restart services stopped during preparation stage
    # systemctl list-units | perl -n -e 'qx(systemctl start $1) if /^.*? ((hadoop|knox|hive|mapred|yarn|hdfs)\S*).service/'
  fi

  if is_debuntu ; then
    # Clean up OS package cache
    apt-get -y -qq clean
    apt-get -y -qq -o DPkg::Lock::Timeout=60 autoremove
    # re-hold systemd package
    if ge_debian12 ; then
    apt-mark hold systemd libsystemd0 ; fi
    hold_nvidia_packages
  else
    dnf clean all
  fi

  # print disk usage statistics for large components
  if is_ubuntu ; then
    du -hs \
      /usr/lib/{pig,hive,hadoop,jvm,spark,google-cloud-sdk,x86_64-linux-gnu} \
      /usr/lib \
      /opt/nvidia/* \
      /opt/conda/miniconda3 2>/dev/null | sort -h
  elif is_debian ; then
    du -x -hs \
      /usr/lib/{pig,hive,hadoop,jvm,spark,google-cloud-sdk,x86_64-linux-gnu,} \
      /var/lib/{docker,mysql,} \
      /opt/nvidia/* \
      /opt/{conda,google-cloud-ops-agent,install-nvidia,} \
      /usr/bin \
      /usr \
      /var \
      / 2>/dev/null | sort -h
  else # Rocky
    du -hs \
      /var/lib/docker \
      /usr/lib/{pig,hive,hadoop,firmware,jvm,spark,atlas,} \
      /usr/lib64/google-cloud-sdk \
      /opt/nvidia/* \
      /opt/conda/miniconda3 2>/dev/null | sort -h
  fi

  # Process disk usage logs from installation period
  rm -f /run/keep-running-df
  sync
  sleep 5.01s
  # compute maximum size of disk during installation
  # Log file contains logs like the following (minus the preceeding #):
#Filesystem     1K-blocks    Used Available Use% Mounted on
#/dev/vda2        7096908 2611344   4182932  39% /
  df / | tee -a "/run/disk-usage.log"

  perl -e '($first, @samples) = grep { m:^/: } <STDIN>;
           unshift(@samples,$first); $final=$samples[-1];
           ($starting)=(split(/\s+/,$first))[2] =~ /^(\d+)/;
             ($ending)=(split(/\s+/,$final))[2] =~ /^(\d+)/;
           @siz=( sort { $a <= $b }
                   map { (split)[2] =~ /^(\d+)/ } @samples );
$max=$siz[0]; $min=$siz[-1]; $inc=$max-$starting;
print( "     samples-taken: ", scalar @siz, $/,
       "starting-disk-used: $starting", $/,
       "  ending-disk-used: $ending", $/,
       " maximum-disk-used: $max", $/,
       " minimum-disk-used: $min", $/,
       "      increased-by: $inc", $/ )' < "/run/disk-usage.log"

  echo "exit_handler has completed"

  # zero free disk space (only if creating image)
  if [[ "${IS_CUSTOM_IMAGE_BUILD}" == "true" ]]; then
    dd if=/dev/zero of=/zero status=progress
    sync
    sleep 3s
    rm -f /zero
  fi

  return 0
}

function set_proxy(){
  # Idempotency Check for Proxy
  if grep -q "http_proxy=" /etc/environment && [[ -n "${http_proxy:-}" ]]; then
    echo "INFO: Proxy already configured in /etc/environment. Skipping proxy setup portion."
    return 0
  fi

  local meta_http_proxy meta_https_proxy meta_proxy_uri
  meta_http_proxy=$(get_metadata_attribute 'http-proxy' '')
  meta_https_proxy=$(get_metadata_attribute 'https-proxy' '')
  meta_proxy_uri=$(get_metadata_attribute 'proxy-uri' '')
  METADATA_HTTP_PROXY_PEM_URI="$(get_metadata_attribute http-proxy-pem-uri '')"

  echo "DEBUG: set_proxy: meta_http_proxy='${meta_http_proxy}'"
  echo "DEBUG: set_proxy: meta_https_proxy='${meta_https_proxy}'"
  echo "DEBUG: set_proxy: meta_proxy_uri='${meta_proxy_uri}'"
  echo "DEBUG: set_proxy: METADATA_HTTP_PROXY_PEM_URI='${METADATA_HTTP_PROXY_PEM_URI}'"

  local http_proxy_val=""
  local https_proxy_val=""

  # Determine HTTP_PROXY value
  if [[ -n "${meta_http_proxy}" ]] && [[ "${meta_http_proxy}" != ":" ]]; then
    http_proxy_val="${meta_http_proxy}"
  elif [[ -n "${meta_proxy_uri}" ]] && [[ "${meta_proxy_uri}" != ":" ]]; then
    http_proxy_val="${meta_proxy_uri}"
  fi

  # Determine HTTPS_PROXY value
  if [[ -n "${meta_https_proxy}" ]] && [[ "${meta_https_proxy}" != ":" ]]; then
    https_proxy_val="${meta_https_proxy}"
  elif [[ -n "${meta_proxy_uri}" ]] && [[ "${meta_proxy_uri}" != ":" ]]; then
    https_proxy_val="${meta_proxy_uri}"
  fi

  local proxy_protocol="http"
  if [[ -n "${METADATA_HTTP_PROXY_PEM_URI}" ]]; then
    proxy_protocol="https"
  fi

  # Export environment variables
  if [[ -n "${http_proxy_val}" ]]; then
    export HTTP_PROXY="${proxy_protocol}://${http_proxy_val}"
    export http_proxy="${proxy_protocol}://${http_proxy_val}"
  else
    unset HTTP_PROXY
    unset http_proxy
  fi
  # Default HTTPS_PROXY to HTTP_PROXY if not separately defined
  if [[ -n "${https_proxy_val}" ]]; then
    export HTTPS_PROXY="${proxy_protocol}://${https_proxy_val}"
    export https_proxy="${proxy_protocol}://${https_proxy_val}"
  elif [[ -n "${HTTP_PROXY:-}" ]]; then
    export HTTPS_PROXY="${HTTP_PROXY}"
    export https_proxy="${http_proxy}"
  else
    unset HTTPS_PROXY
    unset https_proxy
  fi

  local default_no_proxy_list=(
    "localhost" "127.0.0.1" "::1" "metadata.google.internal" "169.254.169.254"
    ".google.com" ".googleapis.com"
  )
  local user_no_proxy
  user_no_proxy=$(get_metadata_attribute 'no-proxy' '')
  local user_no_proxy_list=()
  if [[ -n "${user_no_proxy}" ]]; then
    IFS=',' read -r -a user_no_proxy_list <<< "${user_no_proxy// /,}"
  fi
  local combined_no_proxy_list=( "${default_no_proxy_list[@]}" "${user_no_proxy_list[@]}" )
  local no_proxy
  no_proxy=$( IFS=',' ; echo "${combined_no_proxy_list[*]}" )
  export NO_PROXY="${no_proxy}"
  export no_proxy="${no_proxy}"

  # Set in /etc/environment
  sed -i -e '/^http_proxy=/d' -e '/^https_proxy=/d' -e '/^no_proxy=/d' \
    -e '/^HTTP_PROXY=/d' -e '/^HTTPS_PROXY=/d' -e '/^NO_PROXY=/d' /etc/environment
  if [[ -n "${HTTP_PROXY:-}" ]]; then echo "HTTP_PROXY=${HTTP_PROXY}" >> /etc/environment; fi
  if [[ -n "${http_proxy:-}" ]]; then echo "http_proxy=${http_proxy}" >> /etc/environment; fi
  if [[ -n "${HTTPS_PROXY:-}" ]]; then echo "HTTPS_PROXY=${HTTPS_PROXY}" >> /etc/environment; fi
  if [[ -n "${https_proxy:-}" ]]; then echo "https_proxy=${https_proxy}" >> /etc/environment; fi
  if [[ -n "${NO_PROXY:-}" ]]; then echo "NO_PROXY=${NO_PROXY}" >> /etc/environment; fi
  if [[ -n "${no_proxy:-}" ]]; then echo "no_proxy=${no_proxy}" >> /etc/environment; fi

  echo "DEBUG: set_proxy: Effective HTTP_PROXY=${HTTP_PROXY:-}"
  echo "DEBUG: set_proxy: Effective HTTPS_PROXY=${HTTPS_PROXY:-}"
  echo "DEBUG: set_proxy: Effective NO_PROXY=${NO_PROXY:-}"

  # Configure gcloud proxy
  local gcloud_version
  local -r min_gcloud_proxy_ver="547.0.0"
  gcloud_version=$(gcloud version --format="value(google_cloud_sdk)")
  if version_ge "${gcloud_version}" "${min_gcloud_proxy_ver}"; then
    if [[ -n "${http_proxy_val}" ]]; then
      local proxy_host=$(echo "${http_proxy_val}" | cut -d: -f1)
      local proxy_port=$(echo "${http_proxy_val}" | cut -d: -f2)
      gcloud config set proxy/type http
      gcloud config set proxy/address "${proxy_host}"
      gcloud config set proxy/port "${proxy_port}"
    else
      gcloud config unset proxy/type
      gcloud config unset proxy/address
      gcloud config unset proxy/port
    fi
  fi

  # Install the HTTPS proxy's certificate
  local proxy_ca_pem=""
  if [[ -n "${METADATA_HTTP_PROXY_PEM_URI}" ]] ; then
    if [[ ! "${METADATA_HTTP_PROXY_PEM_URI}" =~ ^gs:// ]] ; then echo "ERROR: http-proxy-pem-uri value must start with gs://" ; exit 1 ; fi
    echo "DEBUG: set_proxy: Processing http-proxy-pem-uri='${METADATA_HTTP_PROXY_PEM_URI}'"
    local trusted_pem_dir
    if is_debuntu ; then
      trusted_pem_dir="/usr/local/share/ca-certificates"
      proxy_ca_pem="${trusted_pem_dir}/proxy_ca.crt"
      mkdir -p "${trusted_pem_dir}"
      ${gsutil_cmd} cp "${METADATA_HTTP_PROXY_PEM_URI}" "${proxy_ca_pem}" || { echo "ERROR: Failed to download proxy CA cert from GCS." ; exit 1 ; }
      update-ca-certificates
      export trusted_pem_path="/etc/ssl/certs/ca-certificates.crt"
    elif is_rocky ; then
      trusted_pem_dir="/etc/pki/ca-trust/source/anchors"
      proxy_ca_pem="${trusted_pem_dir}/proxy_ca.crt"
      mkdir -p "${trusted_pem_dir}"
      ${gsutil_cmd} cp "${METADATA_HTTP_PROXY_PEM_URI}" "${proxy_ca_pem}" || { echo "ERROR: Failed to download proxy CA cert from GCS." ; exit 1 ; }
      update-ca-trust
      export trusted_pem_path="/etc/ssl/certs/ca-bundle.crt"
    fi
    export REQUESTS_CA_BUNDLE="${trusted_pem_path}"
    echo "DEBUG: set_proxy: trusted_pem_path set to '${trusted_pem_path}'"

    # TODO: try this on rocky - exercise the tls bypass code path
    # Add to Java/Conda trust stores
    if [[ -f "/etc/environment" ]]; then
        JAVA_HOME="$(awk -F= '/^JAVA_HOME=/ {print $2}' /etc/environment)"
        if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/bin/keytool" ]]; then
            "${JAVA_HOME}/bin/keytool" -import -cacerts -storepass changeit -noprompt -alias swp_ca -file "${proxy_ca_pem}"
        fi
    fi
    if command -v conda &> /dev/null ; then
      local conda_cert_file="/opt/conda/default/ssl/cacert.pem"
      if [[ -f "${conda_cert_file}" ]]; then
        local ca_subject=$(openssl crl2pkcs7 -nocrl -certfile "${proxy_ca_pem}" | openssl pkcs7 -print_certs -noout | grep ^subject)
        openssl crl2pkcs7 -nocrl -certfile "${conda_cert_file}" | openssl pkcs7 -print_certs -noout | grep -Fxq "${ca_subject}" || {
          cat "${proxy_ca_pem}" >> "${conda_cert_file}"
        }
      fi
    fi
  else
    export trusted_pem_path="" # Explicitly empty
  fi

  if [[ -z "${http_proxy_val}" && -z "${https_proxy_val}" ]]; then
    echo "DEBUG: set_proxy: No proxy host/port configured, skipping proxy-specific setups."
    return 0
  fi

  # Proxy is configured, proceed with tests and tool configs
  local proxy_host=$(echo "${http_proxy_val}" | cut -d: -f1)
  local proxy_port=$(echo "${http_proxy_val}" | cut -d: -f2)

  # TCP test
  if ! nc -zv -w 5 "${proxy_host}" "${proxy_port}"; then
    echo "ERROR: Failed to establish TCP connection to proxy ${proxy_host}:${proxy_port}."
    exit 1
  fi

  # External site test
  local test_url="https://www.google.com"
  local curl_test_args=(${curl_retry_args[@]:-})
  if [[ -n "${trusted_pem_path}" ]]; then
    curl_test_args+=(--cacert "${trusted_pem_path}")
  fi
  if ! curl "${curl_test_args[@]}" -vL -o /dev/null "${test_url}"; then
    echo "ERROR: Failed to fetch ${test_url} via proxy ${HTTP_PROXY}."
    exit 1
  fi

  # Configure package managers
  if is_debuntu ; then
    pkg_proxy_conf_file="/etc/apt/apt.conf.d/99proxy"
    echo "Acquire::http::Proxy \"${HTTP_PROXY}\";" > "${pkg_proxy_conf_file}"
    echo "Acquire::https::Proxy \"${HTTPS_PROXY}\";" >> "${pkg_proxy_conf_file}"
  elif is_rocky ; then
    pkg_proxy_conf_file="/etc/dnf/dnf.conf"
    touch "${pkg_proxy_conf_file}"
    sed -i.bak '/^proxy=/d' "${pkg_proxy_conf_file}"
    if grep -q "^\[main\]" "${pkg_proxy_conf_file}"; then
      sed -i.bak "/^\[main\]/a proxy=${HTTP_PROXY}" "${pkg_proxy_conf_file}"
    else
      echo -e "[main]\nproxy=${HTTP_PROXY}" >> "${pkg_proxy_conf_file}"
    fi
  fi

  # Configure dirmngr
  if is_debuntu ; then
    if ! dpkg -l | grep -q dirmngr; then
      execute_with_retries apt-get install -y -qq dirmngr
    fi
  elif is_rocky ; then
    if ! rpm -q gnupg2-smime; then
      execute_with_retries dnf install -y -q gnupg2-smime
    fi
  fi
  mkdir -p /etc/gnupg
  local dirmngr_conf="/etc/gnupg/dirmngr.conf"
  touch "${dirmngr_conf}"
  sed -i.bak '/^http-proxy/d' "${dirmngr_conf}"
  if [[ -n "${HTTP_PROXY:-}" ]]; then
    echo "http-proxy ${HTTP_PROXY}" >> "${dirmngr_conf}"
  fi

  if [[ -n "${METADATA_HTTP_PROXY_PEM_URI}" ]] ; then
    pip install pip-system-certs
    unset REQUESTS_CA_BUNDLE
  fi
  echo "DEBUG: set_proxy: Proxy setup complete."
}

function repair_boto() {
  local boto_file="/etc/boto.cfg"
  if [[ -f "${boto_file}" ]]; then
    echo "DEBUG: repair_boto: Repairing and deduplicating ${boto_file}" >&2
    
    # 1. Deduplicate sections (fix for DuplicateSectionError)
    # Use a more robust perl one-liner that also handles the content within duplicate sections
    # by only keeping the first occurrence of each section and its variables.
    perl -i -ne '
      if (/^\[(.*)\]/) {
        $section = $1;
        $skip = $seen{$section}++;
      }
      print unless $skip;
    ' "${boto_file}"
    
    # 2. Fix universe_domain if it is still a variable
    local universe_domain
    universe_domain=$(get_metadata_attribute 'universe-domain' 'googleapis.com')
    # Use a more robust replacement that handles potential escaping issues
    UNIVERSE_DOMAIN="${universe_domain}" perl -i -pe 's/\$\{universe_domain\}/$ENV{UNIVERSE_DOMAIN}/g' "${boto_file}"
    # Also fix cases where it might have been partially expanded to storage.$
    UNIVERSE_DOMAIN="${universe_domain}" perl -i -pe 's/storage\.\$/storage.$ENV{UNIVERSE_DOMAIN}/g' "${boto_file}"

    # 3. Apply proxy if set
    local meta_http_proxy=$(get_metadata_attribute 'http-proxy' '')
    local meta_proxy_uri=$(get_metadata_attribute 'proxy-uri' '')
    local effective_proxy="${meta_http_proxy:-${meta_proxy_uri}}"
    
    if [[ -n "${effective_proxy}" ]]; then
      local proxy_host="${effective_proxy%:*}"
      local proxy_port="${effective_proxy##*:}"
      
      sed -i -e '/^proxy =/d' -e '/^proxy_port =/d' "${boto_file}"
      if grep -q "^\[Boto\]" "${boto_file}"; then
        sed -i "/^\[Boto\]/a proxy = ${proxy_host}\nproxy_port = ${proxy_port}" "${boto_file}"
      else
        echo -e "\n[Boto]\nproxy = ${proxy_host}\nproxy_port = ${proxy_port}" >> "${boto_file}"
      fi
    fi
    echo "DEBUG: repair_boto: Updated ${boto_file}" >&2
  fi
}


function mount_ramdisk(){
  local free_mem
  free_mem="$(awk '/^MemFree/ {print $2}' /proc/meminfo)"
  if [[ ${free_mem} -lt 20500000 ]]; then return 0 ; fi

  # Write to a ramdisk instead of churning the persistent disk
  tmpdir="/mnt/shm"
  mkdir -p "${tmpdir}/pkgs_dirs"
  mount -t tmpfs tmpfs "${tmpdir}"

  # Download conda packages to tmpfs
  if [[ -f /opt/conda/miniconda3/bin/conda ]] ; then
    /opt/conda/miniconda3/bin/conda config --add pkgs_dirs "${tmpdir}"
  fi

  # Clear pip cache
  # TODO: make this conditional on which OSs have pip without cache purge
  pip cache purge || echo "unable to purge pip cache"

  # Download pip packages to tmpfs
  pip config set global.cache-dir "${tmpdir}" || echo "unable to set global.cache-dir"

  # Download OS packages to tmpfs
  if is_debuntu ; then
    mount -t tmpfs tmpfs /var/cache/apt/archives
  else
    mount -t tmpfs tmpfs /var/cache/dnf
  fi
}

function harden_sshd_config() {
  # disable sha1 and md5 use in kex and kex-gss features
  declare -A feature_map=(["kex"]="kexalgorithms")
  if ( is_rocky || version_ge "${DATAPROC_IMAGE_VERSION}" "2.1" ) ; then
    feature_map["kex-gss"]="gssapikexalgorithms"
  fi
  for ftr in "${!feature_map[@]}" ; do
    local feature=${feature_map[$ftr]}
    local sshd_config_line
    sshd_config_line="${feature} $(
      (sshd -T | awk "/^${feature} / {print \$2}" | sed -e 's/,/\n/g';
       ssh -Q "${ftr}" ) \
      | sort -u | grep -v -ie sha1 -e md5 | paste -sd "," -)"

    grep -iv "^${feature} " /etc/ssh/sshd_config > /tmp/sshd_config_new
    echo "$sshd_config_line" >> /tmp/sshd_config_new
    # TODO: test whether sshd will reload with this change before mv
    mv -f /tmp/sshd_config_new /etc/ssh/sshd_config
  done
  local svc=ssh
  if is_rocky ; then svc="sshd" ; fi
  systemctl reload "${svc}"
}

function prepare_to_install(){
  readonly uname_r=$(uname -r)
  # Verify OS compatability and Secure boot state
  evaluate_network
  check_os
  check_secure_boot
  # Setup temporary directories (potentially on RAM disk)
  tmpdir=/tmp/ # Default
  mount_ramdisk # Updates tmpdir if successful
  install_log="${tmpdir}/install.log" # Set install log path based on final tmpdir
  curl_retry_args="-fsSL --retry-connrefused --retry 10 --retry-max-time 30"
  # With the 402.0.0 release of gcloud sdk, `gcloud storage` can be
  # used as a more performant replacement for `gsutil`
  gsutil_cmd="gcloud storage"
  gsutil_stat_cmd="gcloud storage objects describe"
  gcloud_sdk_version="$(gcloud --version | awk -F'SDK ' '/Google Cloud SDK/ {print $2}')"
  if version_lt "${gcloud_sdk_version}" "402.0.0" ; then
    gsutil_cmd="gsutil -o GSUtil:check_hashes=never"
    gsutil_stat_cmd="gsutil stat"
  fi
  set_proxy
  repair_boto

  # --- Detect Image Build Context ---
  # Use 'initialization-actions' as the default name for clarity
  INVOCATION_TYPE="$(get_metadata_attribute invocation-type "initialization-actions")"
  if [[ "${INVOCATION_TYPE}" == "custom-images" ]]; then
    IS_CUSTOM_IMAGE_BUILD="true"
    # echo "Detected custom image build context (invocation-type=custom-images). Configuration will be deferred." # Keep silent
  else
    IS_CUSTOM_IMAGE_BUILD="false" # Ensure it's explicitly false otherwise
    # echo "Running in initialization action mode (invocation-type=${INVOCATION_TYPE})." # Keep silent
  fi

  # if fetches of nvidia packages fail, apply -k argument to the following.

  # After manually verifying the veracity of the asset, take note of sha256sum
  # of the downloaded files in your gcs bucket and submit these data with an
  # issue or pull request to the github repository
  # GoogleCloudDataproc/initialization-actions and we will include those hashes
  # with this script for manual validation at time of deployment.

  # Please provide hash data in the following format:

#      ["cuda_11.5.2_495.29.05_linux.run"]="2c33591bb5b33a3d4bffafdc7da76fe4"
#      ["cuda_11.6.2_510.47.03_linux.run"]="2989d2d2a943fa5e2a1f29f660221788"
#      ["cuda_12.1.1_530.30.02_linux.run"]="2f0a4127bf797bf4eab0be2a547cb8d0"
#      ["cuda_12.4.1_550.54.15_linux.run"]="afc99bab1d8c6579395d851d948ca3c1"
#      ["cuda_12.6.3_560.35.05_linux.run"]="29d297908c72b810c9ceaa5177142abd"
#      ["NVIDIA-Linux-x86_64-495.46.run"]="db1d6b0f9e590249bbf940a99825f000"
#      ["NVIDIA-Linux-x86_64-510.108.03.run"]="a225bcb0373cbf6c552ed906bc5c614e"
#      ["NVIDIA-Linux-x86_64-530.30.02.run"]="655b1509b9a9ed0baa1ef6b2bcf80283"
#      ["NVIDIA-Linux-x86_64-550.135.run"]="a8c3ae0076f11e864745fac74bfdb01f"
#      ["NVIDIA-Linux-x86_64-550.142.run"]="e507e578ecf10b01a08e5424dddb25b8"

  workdir=/opt/install-dpgce
  # Set GCS bucket for caching
  temp_bucket="$(get_metadata_attribute dataproc-temp-bucket)"
  readonly temp_bucket
  readonly pkg_bucket="gs://${temp_bucket}/dpgce-packages"
  readonly bdcfg="/usr/local/bin/bdconfig"
  export DEBIAN_FRONTEND=noninteractive

  # Prepare GPU environment variables (versions, URLs, counts)
  prepare_gpu_env

  mkdir -p "${workdir}/complete"
  trap exit_handler EXIT

  is_complete prepare.common && return

  harden_sshd_config

  if is_debuntu ; then
    repair_old_backports
    clean_up_sources_lists
    apt-get update -qq --allow-releaseinfo-change
    apt-get -y clean
    apt-get -o DPkg::Lock::Timeout=60 -y autoremove
    if ge_debian12 ; then
    apt-mark unhold systemd libsystemd0 ; fi
    if is_ubuntu ; then
      # Wait for gcloud to be available on Ubuntu
      while ! command -v gcloud ; do sleep 5s ; done
    fi
  else # Rocky
    dnf clean all
  fi

  # zero free disk space (only if creating image)
  if [[ "${IS_CUSTOM_IMAGE_BUILD}" == "true" ]]; then
    set +e
    time dd if=/dev/zero of=/zero status=none
    sync
    sleep 3s
    rm -f /zero
    set -e
  fi

  install_dependencies

  # Monitor disk usage in a screen session
  df / > "/run/disk-usage.log"
  touch "/run/keep-running-df"
  screen -d -m -LUS keep-running-df \
    bash -c "while [[ -f /run/keep-running-df ]] ; do df / | tee -a /run/disk-usage.log ; sleep 5s ; done"

  mark_complete prepare.common
}

function check_os() {
  if is_debian && ( ! is_debian10 && ! is_debian11 && ! is_debian12 ) ; then
      echo "Error: The Debian version ($(os_version)) is not supported. Please use a compatible Debian version."
      exit 1
  elif is_ubuntu && ( ! is_ubuntu18 && ! is_ubuntu20 && ! is_ubuntu22  ) ; then
      echo "Error: The Ubuntu version ($(os_version)) is not supported. Please use a compatible Ubuntu version."
      exit 1
  elif is_rocky && ( ! is_rocky8 && ! is_rocky9 ) ; then
      echo "Error: The Rocky Linux version ($(os_version)) is not supported. Please use a compatible Rocky Linux version."
      exit 1
  fi

  SPARK_VERSION="$(spark-submit --version 2>&1 | sed -n 's/.*version[[:blank:]]\+\([0-9]\+\.[0-9]\).*/\1/p' | head -n1)"
  readonly SPARK_VERSION
  if version_lt "${SPARK_VERSION}" "2.4" || \
     version_ge "${SPARK_VERSION}" "4.0" ; then
    echo "Error: Your Spark version (${SPARK_VERSION}) is not supported. Please use a supported version."
    exit 1
  fi

  # Detect dataproc image version
  if (! test -v DATAPROC_IMAGE_VERSION || [[ -z "${DATAPROC_IMAGE_VERSION}" ]]) ; then
    if test -v DATAPROC_VERSION ; then
      DATAPROC_IMAGE_VERSION="${DATAPROC_VERSION}"
    else
      # When building custom-images, neither of the above variables
      # are defined and we need to make a reasonable guess
      if   version_lt "${SPARK_VERSION}" "2.5" ; then DATAPROC_IMAGE_VERSION="1.5"
      elif version_lt "${SPARK_VERSION}" "3.2" ; then DATAPROC_IMAGE_VERSION="2.0"
      elif version_lt "${SPARK_VERSION}" "3.4" ; then DATAPROC_IMAGE_VERSION="2.1"
      elif version_lt "${SPARK_VERSION}" "3.6" ; then
        if [[ -f /etc/environment ]] ; then
          eval "$(grep '^DATAPROC_IMAGE_VERSION' /etc/environment)" || DATAPROC_IMAGE_VERSION="2.2"
        else
          DATAPROC_IMAGE_VERSION="2.2"
        fi
      else DATAPROC_IMAGE_VERSION="2.3" ; fi # Default to latest known version
    fi
  fi
}

#
# Generate repo file under /etc/apt/sources.list.d/
#
function apt_add_repo() {
  local -r repo_name="$1"
  local -r repo_data="$3" # "http(s)://host/path/uri argument0 .. argumentN"
  local -r include_src="${4:-yes}"
  local -r kr_path="${5:-/usr/share/keyrings/${repo_name}.gpg}"
  local -r repo_path="${6:-/etc/apt/sources.list.d/${repo_name}.list}"

  echo "deb [signed-by=${kr_path}] ${repo_data}" > "${repo_path}"
  if [[ "${include_src}" == "yes" ]] ; then
    echo "deb-src [signed-by=${kr_path}] ${repo_data}" >> "${repo_path}"
  fi

  apt-get update -qq
}

#
# Generate repo file under /etc/yum.repos.d/
#
function dnf_add_repo() {
  local -r repo_name="$1"
  local -r repo_url="$3" # "http(s)://host/path/filename.repo"
  local -r kr_path="${5:-/etc/pki/rpm-gpg/${repo_name}.gpg}"
  local -r repo_path="${6:-/etc/yum.repos.d/${repo_name}.repo}"

  curl ${curl_retry_args[@]} "${repo_url}" \
    | dd of="${repo_path}" status=progress
}

#
# Keyrings default to
# /usr/share/keyrings/${repo_name}.gpg (debian/ubuntu) or
# /etc/pki/rpm-gpg/${repo_name}.gpg    (rocky/RHEL)
#
function os_add_repo() {
  local -r repo_name="$1"
  local -r signing_key_url="$2"
  local -r repo_data="$3" # "http(s)://host/path/uri argument0 .. argumentN"
  local kr_path
  if is_debuntu ; then kr_path="${5:-/usr/share/keyrings/${repo_name}.gpg}"
                  else kr_path="${5:-/etc/pki/rpm-gpg/${repo_name}.gpg}" ; fi

  mkdir -p "$(dirname "${kr_path}")"

  import_gpg_keys --keyring-file "${kr_path}" --key-url "${signing_key_url}"

  if is_debuntu ; then apt_add_repo "${repo_name}" "${signing_key_url}" "${repo_data}" "${4:-yes}" "${kr_path}" "${6:-}"
                  else dnf_add_repo "${repo_name}" "${signing_key_url}" "${repo_data}" "${4:-yes}" "${kr_path}" "${6:-}" ; fi
}


readonly _shortname="$(os_id)$(os_version|perl -pe 's/(\d+).*/$1/')"

function install_spark_rapids() {
  if [[ "${RAPIDS_RUNTIME}" != "SPARK" ]]; then return ; fi

  # Update SPARK RAPIDS config
  local DEFAULT_SPARK_RAPIDS_VERSION
  local nvidia_repo_url
  DEFAULT_SPARK_RAPIDS_VERSION="24.08.1"
  if [[ "${DATAPROC_IMAGE_VERSION}" == "2.0" ]] ; then
    DEFAULT_SPARK_RAPIDS_VERSION="23.08.2" # Final release to support spark 3.1.3
    nvidia_repo_url='https://repo1.maven.org/maven2/com/nvidia'
  elif version_ge "${DATAPROC_IMAGE_VERSION}" "2.2" ; then
    DEFAULT_SPARK_RAPIDS_VERSION="25.08.0"
    nvidia_repo_url='https://edge.urm.nvidia.com/artifactory/sw-spark-maven/com/nvidia'
  elif version_ge "${DATAPROC_IMAGE_VERSION}" "2.1" ; then
    DEFAULT_SPARK_RAPIDS_VERSION="25.08.0"
    nvidia_repo_url='https://edge.urm.nvidia.com/artifactory/sw-spark-maven/com/nvidia'
  fi
  local DEFAULT_XGBOOST_VERSION="1.7.6" # 2.1.3

  # https://mvnrepository.com/artifact/ml.dmlc/xgboost4j-spark-gpu
  local -r scala_ver="2.12"

  readonly SPARK_RAPIDS_VERSION=$(get_metadata_attribute 'spark-rapids-version' ${DEFAULT_SPARK_RAPIDS_VERSION})
  readonly XGBOOST_VERSION=$(get_metadata_attribute 'xgboost-version' ${DEFAULT_XGBOOST_VERSION})

  local -r rapids_repo_url='https://repo1.maven.org/maven2/ai/rapids'
  local -r dmlc_repo_url='https://repo.maven.apache.org/maven2/ml/dmlc'

  local jar_basename
  local spark_jars_dir="/usr/lib/spark/jars"
  mkdir -p "${spark_jars_dir}"

  jar_basename="xgboost4j-spark-gpu_${scala_ver}-${XGBOOST_VERSION}.jar"
  cache_fetched_package "${dmlc_repo_url}/xgboost4j-spark-gpu_${scala_ver}/${XGBOOST_VERSION}/${jar_basename}" \
                        "${pkg_bucket}/xgboost4j-spark-gpu_${scala_ver}/${XGBOOST_VERSION}/${jar_basename}" \
                        "${spark_jars_dir}/${jar_basename}"

  jar_basename="xgboost4j-gpu_${scala_ver}-${XGBOOST_VERSION}.jar"
  cache_fetched_package "${dmlc_repo_url}/xgboost4j-gpu_${scala_ver}/${XGBOOST_VERSION}/${jar_basename}" \
                        "${pkg_bucket}/xgboost4j-gpu_${scala_ver}/${XGBOOST_VERSION}/${jar_basename}" \
                        "${spark_jars_dir}/${jar_basename}"

  jar_basename="rapids-4-spark_${scala_ver}-${SPARK_RAPIDS_VERSION}.jar"
  cache_fetched_package "${nvidia_repo_url}/rapids-4-spark_${scala_ver}/${SPARK_RAPIDS_VERSION}/${jar_basename}" \
                        "${pkg_bucket}/rapids-4-spark_${scala_ver}/${SPARK_RAPIDS_VERSION}/${jar_basename}" \
                        "${spark_jars_dir}/${jar_basename}"
}

# Function to download GPG keys from URLs or Keyservers and import them to a specific keyring
# Usage:
#   import_gpg_keys --keyring-file <PATH> \
#     [--key-url <URL1> [--key-url <URL2> ...]] \
#     [--key-id <ID1> [--key-id <ID2> ...]] \
#     [--keyserver <KEYSERVER_URI>]
function import_gpg_keys() {
  local keyring_file=""
  local key_urls=()
  local key_ids=()
  local keyserver="hkp://keyserver.ubuntu.com:80" # Default keyserver

  # Parse named arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keyring-file)
        keyring_file="$2"
        shift 2
        ;;
      --key-url)
        key_urls+=("$2")
        shift 2
        ;;
      --key-id)
        key_ids+=("$2")
        shift 2
        ;;
      --keyserver)
        keyserver="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  # Validate arguments
  if [[ -z "${keyring_file}" ]]; then
    echo "ERROR: --keyring-file is required." >&2
    return 1
  fi
  if [[ ${#key_urls[@]} -eq 0 && ${#key_ids[@]} -eq 0 ]]; then
    echo "ERROR: At least one --key-url or --key-id must be specified." >&2
    return 1
  fi

  # Ensure the directory for the keyring file exists
  local keyring_dir
  keyring_dir=$(dirname "${keyring_file}")
  if [[ ! -d "${keyring_dir}" ]]; then
    echo "Creating directory for keyring: ${keyring_dir}"
    mkdir -p "${keyring_dir}"
  fi

  local tmp_key_file=""
  local success=true

  # Process Key URLs
  for current_key_url in "${key_urls[@]}"; do
    echo "Attempting to download GPG key from URL: ${current_key_url}"
    tmp_key_file="${tmpdir}/key_$(basename "${current_key_url}")_$(date +%s).asc"

    if curl ${curl_retry_args[@]} "${current_key_url}" -o "${tmp_key_file}"; then
      if [[ -s "${tmp_key_file}" ]]; then
        echo "Key file downloaded to ${tmp_key_file}."
        if gpg --no-default-keyring --keyring "${keyring_file}" --import "${tmp_key_file}"; then
          echo "Key from ${current_key_url} imported successfully to ${keyring_file}."
        else
          echo "ERROR: gpg --import failed for ${tmp_key_file} from ${current_key_url}." >&2
          success=false
        fi
      else
        echo "ERROR: Downloaded key file ${tmp_key_file} from ${current_key_url} is empty." >&2
        success=false
      fi
    else
      echo "ERROR: curl failed to download key from ${current_key_url}." >&2
      success=false
    fi
    [[ -f "${tmp_key_file}" ]] && rm -f "${tmp_key_file}"
  done

  # Process Key IDs
  for key_id in "${key_ids[@]}"; do
    # Strip 0x prefix if present
    clean_key_id="${key_id#0x}"
    echo "Attempting to fetch GPG key ID ${clean_key_id} using curl from ${keyserver}"

    local fallback_key_url
    local server_host
    server_host=$(echo "${keyserver}" | sed -e 's#hkp[s]*://##' -e 's#:[0-9]*##')

    # Common keyserver URL patterns
    if [[ "${server_host}" == "keyserver.ubuntu.com" ]]; then
        fallback_key_url="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${clean_key_id}"
    elif [[ "${server_host}" == "pgp.mit.edu" ]]; then
        fallback_key_url="https://pgp.mit.edu/pks/lookup?op=get&search=0x${clean_key_id}"
    elif [[ "${server_host}" == "keys.openpgp.org" ]]; then
        fallback_key_url="https://keys.openpgp.org/vks/v1/by-fpr/${clean_key_id}"
    else
        fallback_key_url="https://${server_host}/pks/lookup?op=get&search=0x${clean_key_id}"
        echo "WARNING: Using best-guess fallback URL for ${keyserver}: ${fallback_key_url}"
    fi

    tmp_key_file="${tmpdir}/${clean_key_id}.asc"
    if curl ${curl_retry_args[@]} "${fallback_key_url}" -o "${tmp_key_file}"; then
      if [[ -s "${tmp_key_file}" ]]; then
         if grep -q -iE '<html|<head|<!DOCTYPE' "${tmp_key_file}"; then
          echo "ERROR: Output from keyserver for ${clean_key_id} appears to be HTML, not a key. Key likely not found at ${fallback_key_url}." >&2
          success=false
        elif gpg --no-default-keyring --keyring "${keyring_file}" --import "${tmp_key_file}"; then
          echo "Key ${clean_key_id} imported successfully to ${keyring_file}."
        else
          echo "ERROR: gpg --import failed for ${clean_key_id} from ${fallback_key_url}." >&2
          success=false
        fi
      else
        echo "ERROR: Downloaded key file for ${clean_key_id} is empty from ${fallback_key_url}." >&2
        success=false
      fi
    else
      echo "ERROR: curl failed to download key ${clean_key_id} from ${fallback_key_url}." >&2
      success=false
    fi
    [[ -f "${tmp_key_file}" ]] && rm -f "${tmp_key_file}"
  done

  if [[ "${success}" == "true" ]]; then
    return 0
  else
    echo "ERROR: One or more keys failed to import." >&2
    return 1
  fi
}

# Example Usage (uncomment to test)
# import_gpg_keys --keyring-file "/tmp/test-keyring.gpg" --key-url "https://nvidia.github.io/libnvidia-container/gpgkey"
# import_gpg_keys --keyring-file "/tmp/test-keyring.gpg" --key-id "A040830F7FAC5991"
# import_gpg_keys --keyring-file "/tmp/test-keyring.gpg" --key-id "B82D541C" --keyserver "hkp://keyserver.ubuntu.com:80"

# To use this in another script:
# source ./gpg-import.sh
# import_gpg_keys --keyring-file "/usr/share/keyrings/my-repo.gpg" --key-url "https://example.com/repo.key"

# --- Script Entry Point ---
prepare_to_install # Run preparation steps first
main               # Call main logic
