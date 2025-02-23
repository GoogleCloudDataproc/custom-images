#!/bin/bash

# Copyright 2019,2020,2021,2022,2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This initialization action script will install pytorch on a Dataproc
# cluster.

set -euxo pipefail

function os_id()       ( set +x ;  grep '^ID=' /etc/os-release | cut -d= -f2 | xargs ; )
function os_version()  ( set +x ;  grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | xargs ; )
function is_ubuntu()   ( set +x ;  [[ "$(os_id)" == 'ubuntu' ]] ; )
function is_ubuntu18() ( set +x ;  is_ubuntu && [[ "$(os_version)" == '18.04'* ]] ; )
function is_debian()   ( set +x ;  [[ "$(os_id)" == 'debian' ]] ; )
function is_debuntu()  ( set +x ;  is_debian || is_ubuntu ; )

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

function get_metadata_value() {
  set +x
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
  set -x
  return ${return_code}
}

function get_metadata_attribute() (
  set +x
  local -r attribute_name="$1"
  local -r default_value="${2:-}"
  get_metadata_value "attributes/${attribute_name}" || echo -n "${default_value}"
)

function is_cuda12() { [[ "${CUDA_VERSION%%.*}" == "12" ]] ; }
function is_cuda11() { [[ "${CUDA_VERSION%%.*}" == "11" ]] ; }

function install_pytorch() {
#To enable CUDA support, UCX requires the CUDA Runtime library (libcudart).
#The library can be installed with the appropriate command below:

#* For CUDA 11, run:    conda install cudatoolkit cuda-version=11
#* For CUDA 12, run:    conda install cuda-cudart cuda-version=12

  if is_cuda12 ; then
    local python_spec="python>=3.11"
    local cuda_spec="cuda-version>=12,<13"
    local cudart_spec="cuda-cudart"
  elif is_cuda11 ; then
    local python_spec="python>=3.9"
    local cuda_spec="cuda-version>=11,<12.0a0"
    local cudart_spec="cudatoolkit"
  fi

  local numba_spec="numba"
  local tensorflow_spec="tensorflow-gpu"
  local pytorch_spec="pytorch"

  CONDA_PACKAGES=(
    "${cuda_spec}"
    "${cudart_spec}"
    "${tensorflow_spec}"
    "${pytorch_spec}"
    "cudf"
    "${numba_spec}"
  )

  # Install cuda, pytorch
  mamba="${CONDA_ROOT}/bin/mamba"
  conda="${CONDA_ROOT}/bin/conda"

  # Unpin conda version and upgrade
#  perl -ni -e 'print unless /^conda /' "${CONDA_ROOT}/conda-meta/pinned"
#  "${mamba}" install conda mamba libmamba libmambapy conda-libmamba-solver

  # This error occurs when we set channel_alias
#  util_files_to_patch="$(find "${CONDA_ROOT}" -name utils.py | grep mamba/utils.py)"
#  perl -pi -e 's[raise ValueError\("missing key][print("missing key]' ${util_files_to_patch}
#  File "/home/zhyue/mambaforge/lib/python3.9/site-packages/mamba/utils.py", line 393, in compute_final_precs
#  raise ValueError("missing key {} in channels: {}".format(key, lookup_dict))

  CONDA_EXE="${CONDA_ROOT}/bin/conda"
  CONDA_PYTHON_EXE="${CONDA_ROOT}/bin/python"
  PATH="${CONDA_ROOT}/bin/condabin:${CONDA_ROOT}/bin:${PATH}"

  ( set +e
  local is_installed="0"
  for installer in "${mamba}" "${conda}" ; do
    echo "${installer}" "create" -q -m -n "${PYTORCH_ENV_NAME}" -y --no-channel-priority \
      -c 'conda-forge' -c 'nvidia' -c 'rapidsai'  \
      ${CONDA_PACKAGES[*]} \
      "${python_spec}"
#    read placeholder
    # for debugging, consider -vvv
    time "${installer}" "create" -q -m -n "${PYTORCH_ENV_NAME}" -y --no-channel-priority \
      -c 'conda-forge' -c 'nvidia' -c 'rapidsai'  \
      ${CONDA_PACKAGES[*]} \
      "${python_spec}" \
      && retval=$? || retval=$?
    sync
    if [[ "$retval" == "0" ]] ; then
      is_installed="1"
      break
    else
      test -d "${PYTORCH_CONDA_ENV}" && ( "${conda}" remove -n "${PYTORCH_ENV_NAME}" --all > /dev/null 2>&1 || rm -rf "${PYTORCH_CONDA_ENV}" )
      "${conda}" config --set channel_priority flexible
      df -h
      clean_conda_cache
    fi
  done
  if [[ "${is_installed}" == "0" ]]; then
    echo "failed to install pytorch"
    return 1
  fi
  )
}

function main() {
  # Install PYTORCH
  install_pytorch

  echo "Pytorch successfully initialized."
  if [[ "${ROLE}" == "Master" ]]; then
    systemctl restart hadoop-yarn-resourcemanager.service
    # Restart NodeManager on Master as well if this is a single-node-cluster.
    if systemctl list-units | grep hadoop-yarn-nodemanager; then
      systemctl restart hadoop-yarn-nodemanager.service
    fi
  else
    systemctl restart hadoop-yarn-nodemanager.service
  fi
}

function clean_conda_cache() {
  if ! grep -q "${rapids_mirror_mountpoint}" /proc/mounts ; then
    "${CONDA}" clean -a
  fi
}

function exit_handler() {
  set +e
  set -x
  echo "Exit handler invoked"

  unmount_rapids_mirror

  mv ~/.condarc.default ~/.condarc
  mv /root/.config/pip/pip.conf.default /root/.config/pip/pip.conf

  # If system memory was sufficient to mount memory-backed filesystems
  if [[ "${tmpdir}" == "/mnt/shm" ]] ; then
    echo "cleaning up tmpfs mounts"

    # Clean up shared memory mounts
    for shmdir in /var/cache/apt/archives /var/cache/dnf /mnt/shm /tmp ; do
      if grep -q "^tmpfs ${shmdir}" /proc/mounts ; then
        sync
        umount -f ${shmdir}
      fi
    done
  else
    clean_conda_cache
    # Clear pip cache from non-tmpfs
    pip cache purge || echo "unable to purge pip cache"
  fi

  # Clean up OS package cache ; re-hold systemd package
  if is_debuntu ; then
    apt-get -y -qq clean
    apt-get -y -qq autoremove
  else
    dnf clean all
  fi

  # print disk usage statistics for large components
  if is_ubuntu ; then
    du -hs \
      /usr/lib/{pig,hive,hadoop,jvm,spark,google-cloud-sdk,x86_64-linux-gnu} \
      /usr/lib \
      /opt/nvidia/* \
      /usr/local/cuda-1?.? \
      ${CONDA_ROOT}
  elif is_debian ; then
    du -hs \
      /usr/lib/{pig,hive,hadoop,jvm,spark,google-cloud-sdk,x86_64-linux-gnu} \
      /usr/lib \
      /usr/local/cuda-1?.? \
      ${CONDA_ROOT}
  else
    du -hs \
      /var/lib/docker \
      /usr/lib/{pig,hive,hadoop,firmware,jvm,spark,atlas} \
      /usr/lib64/google-cloud-sdk \
      /usr/lib \
      /opt/nvidia/* \
      /usr/local/cuda-1?.? \
      ${CONDA_ROOT}
  fi

  # Process disk usage logs from installation period
  rm -f /run/keep-running-df
  sync
  sleep 5.01s
  # compute maximum size of disk during installation
  # Log file contains logs like the following (minus the preceeding #):
#Filesystem     1K-blocks    Used Available Use% Mounted on
#/dev/vda2        7096908 2611344   4182932  39% /
  set +x
  df / | tee -a "/run/disk-usage.log"
  perl -e '@siz=( sort { $a => $b }
                   map { (split)[2] =~ /^(\d+)/ }
                  grep { m:^/: } <STDIN> );
$max=$siz[0]; $min=$siz[-1]; $inc=$max-$min;
print( "    samples-taken: ", scalar @siz, $/,
       "maximum-disk-used: $max", $/,
       "minimum-disk-used: $min", $/,
       "     increased-by: $inc", $/ )' < "/run/disk-usage.log"
  set -x
  echo "exit_handler has completed"

  # zero free disk space
  if [[ -n "$(get_metadata_attribute creating-image)" ]]; then
    eval "dd if=/dev/zero of=/zero"
    sync
    sleep 3s
    rm -f /zero
  fi

  return 0
}

function unmount_rapids_mirror() {
  if ! grep -q "${rapids_mirror_mountpoint}" /proc/mounts ; then return ; fi

  umount "${rapids_mirror_mountpoint}"
  umount "${rapids_mirror_mountpoint}_ro"
  gcloud compute instances detach-disk "$(hostname -s)" \
    --device-name "${RAPIDS_MIRROR_DISK_NAME}" \
    --zone       "${ZONE}" \
    --disk-scope regional
}

function mount_rapids_mirror() {
  # use a regional mirror instead of fetching from cloudflare CDN
  export RAPIDS_MIRROR_DISK_NAME="$(gcloud compute disks list | awk "/${RAPIDS_MIRROR_DISK}-/ {print \$1}" | sort | tail -1)"
  export RAPIDS_DISK_FQN="projects/${PROJECT_ID}/regions/${REGION}/disks/${RAPIDS_MIRROR_DISK_NAME}"

  if [[ -z "${RAPIDS_MIRROR_DISK_NAME}" ]]; then return ; fi

  # If the service account can describe the disk, attempt to attach and mount it
  eval gcloud compute disks describe "${RAPIDS_MIRROR_DISK_NAME}" --region "${REGION}" > /tmp/mirror-disk.txt
  if [[ "$?" != "0" ]] ; then return ; fi
  
  if ! grep -q "${rapids_mirror_mountpoint}" /proc/mounts ; then 
    gcloud compute instances attach-disk "$(hostname -s)" \
      --disk        "${RAPIDS_DISK_FQN}" \
      --device-name "${RAPIDS_MIRROR_DISK_NAME}" \
      --disk-scope  "regional" \
      --zone        "${ZONE}" \
      --mode=ro

    mkdir -p "${rapids_mirror_mountpoint}" "${rapids_mirror_mountpoint}_ro" "${tmpdir}/overlay" "${tmpdir}/workdir"
    mount -o ro "/dev/disk/by-id/google-${RAPIDS_MIRROR_DISK_NAME}" "${rapids_mirror_mountpoint}_ro"
    mount -t overlay overlay -o lowerdir="${rapids_mirror_mountpoint}_ro",upperdir="${tmpdir}/overlay",workdir="${tmpdir}/workdir" "${rapids_mirror_mountpoint}"
  fi
  ${CONDA} config --add pkgs_dirs "${rapids_mirror_mountpoint}/conda_cache"
#  echo "${CONDA}" config --set channel_alias "file://${rapids_mirror_mountpoint}/conda.anaconda.org"
#  for channel in 'rapidsai' 'nvidia' 'pkgs/main' 'pkgs/r' 'conda-forge' ; do
#    echo "${CONDA}" config --set \
#      "custom_channels.${channel}" "file://${rapids_mirror_mountpoint}/conda.anaconda.org/"
#  done
  # patch conda to install from mirror
#  files_to_patch=$(find ${CONDA_ROOT}/ -name 'download.py' | grep conda/gateways/connection)
#  perl -i -pe 's{if "://" not in self.url:}{if "file://" in self.url or "://" not in self.url:}' \
#    ${files_to_patch}
#  perl -i -pe 's{self.url = url$}{self.url = url.replace("file://","")}' \
#    ${files_to_patch}

#  time for d in dask main nvidia r rapidsai conda-forge ; do
#    find "${rapids_mirror_mountpoint}/conda.anaconda.org/${d}" -name '*.conda' -o -name '*.tar.bz2' -print0 | \
#      xargs -0 ln -sf -t "${pkgs_dir}"
#  done

  # Point to the cache built with the mirror
#  for channel in 'rapidsai' 'nvidia' 'main' 'r' 'conda-forge' ; do
#    for plat in noarch linux-64 ; do
#      echo ${CONDA} config --add pkgs_dirs "/srv/mirror/conda.anaconda.org/${channel}/${plat}"
#    done
#  done

#  for channel in pkgs/main pkgs/r ; do
#    echo ${CONDA} config --add default_channels "file://${rapids_mirror_mountpoint}/conda.anaconda.org/${channel}"
#  done

}

function prepare_to_install() {
  readonly DEFAULT_CUDA_VERSION="12.4"
  CUDA_VERSION=$(get_metadata_attribute 'cuda-version' ${DEFAULT_CUDA_VERSION})
  readonly CUDA_VERSION

  readonly ROLE=$(get_metadata_attribute dataproc-role)
  readonly MASTER=$(get_metadata_attribute dataproc-master)

  export CONDA_ROOT=/opt/conda/miniconda3
  export CONDA="${CONDA_ROOT}/bin/conda"

  readonly PYTORCH_ENV_NAME="pytorch"
  readonly PYTORCH_CONDA_ENV="${CONDA_ROOT}/envs/${PYTORCH_ENV_NAME}"

  readonly PROJECT_ID="$(gcloud config get project)"
  zone="$(get_metadata_value zone)"
  export ZONE="$(echo $zone | sed -e 's:.*/::')"
  export REGION="$(echo ${ZONE} | perl -pe 's/^(.+)-[^-]+$/$1/')"

  export RAPIDS_MIRROR_DISK="$(get_metadata_attribute 'rapids-mirror-disk' '')"
  export RAPIDS_MIRROR_HOST="$(get_metadata_attribute 'rapids-mirror-host' '')"

  rapids_mirror_mountpoint=/srv/mirror

  free_mem="$(awk '/^MemFree/ {print $2}' /proc/meminfo)"
  # With a local conda mirror mounted, use reduced ram disk size
  if [[ -n "${RAPIDS_MIRROR_DISK}" ]] ; then
    min_mem=18500000
    pkgs_dir=
  else
    min_mem=33300000
  fi
  # Write to a ramdisk instead of churning the persistent disk
  if [[ ${free_mem} -ge ${min_mem} ]]; then
    tmpdir=/mnt/shm
    mkdir -p "${tmpdir}"
    mount -t tmpfs tmpfs "${tmpdir}"

    # Minimum of 11G of capacity required for pytorch package install via conda
    # + 5G without rapids mirror mounted
    mount -t tmpfs tmpfs "${tmpdir}"
  else
    tmpdir=/tmp
  fi

  install_log="${tmpdir}/install.log"
  trap exit_handler EXIT

  touch ~/.condarc
  cp ~/.condarc ~/.condarc.default

  #"${CONDA}" config --set verbosity 3
  # Clean conda cache
  clean_conda_cache

  mount_rapids_mirror

  if [[ -n "${RAPIDS_MIRROR_HOST}" ]] && nc -vz "${RAPIDS_MIRROR_HOST}" 80 > /dev/null 2>&1 ; then
    for channel in 'conda-forge' 'rapidsai' 'nvidia' 'pkgs/r' 'pkgs/main' ; do
      echo "${CONDA}" config --set \
        "custom_channels.${channel}" "http://${RAPIDS_MIRROR_HOST}/conda.anaconda.org/"
    done
  fi

  if grep -q "${rapids_mirror_mountpoint}" /proc/mounts ; then
    # if we are using the mirror disk, install exclusively from its cache
    extra_conda_args="--offline"
  else
    pkgs_dir="${tmpdir}/pkgs_dir"
    mkdir -p "${pkgs_dir}"
    "${CONDA}" config --add pkgs_dirs "${pkgs_dir}"
  fi

  # Monitor disk usage in a screen session
  if is_debuntu ; then
    command -v screen || \
      apt-get install -y -qq screen
  else
    command -v screen || \
      dnf -y -q install screen
  fi
  df / > "/run/disk-usage.log"
  touch "/run/keep-running-df"
  screen -d -m -US keep-running-df \
    bash -c "while [[ -f /run/keep-running-df ]] ; do df / | tee -a /run/disk-usage.log ; sleep 5s ; done"
}

prepare_to_install

main
