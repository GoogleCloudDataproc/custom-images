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

# This initialization action script will install rapids on a Dataproc
# cluster.

set -euxo pipefail

function os_id()       { grep '^ID=' /etc/os-release | cut -d= -f2 | xargs ; }
function is_ubuntu()   { [[ "$(os_id)" == 'ubuntu' ]] ; }
function is_debian()   { [[ "$(os_id)" == 'debian' ]] ; }
function is_debuntu()  { is_debian || is_ubuntu ; }

# Detect dataproc image version from its various names
if (! test -v DATAPROC_IMAGE_VERSION) && test -v DATAPROC_VERSION; then
  DATAPROC_IMAGE_VERSION="${DATAPROC_VERSION}"
fi

function get_metadata_attribute() {
  local -r attribute_name=$1
  local -r default_value="${2:-}"
  /usr/share/google/get_metadata_value "attributes/${attribute_name}" || echo -n "${default_value}"
}

DEFAULT_CUDA_VERSION="12.4"

# RAPIDS config
readonly RAPIDS_RUNTIME=$(get_metadata_attribute 'rapids-runtime' 'DASK')
readonly DEFAULT_CUDA_VERSION
CUDA_VERSION=$(get_metadata_attribute 'cuda-version' ${DEFAULT_CUDA_VERSION})

readonly CUDA_VERSION
function is_cuda12() { [[ "${CUDA_VERSION%%.*}" == "12" ]] ; }
function is_cuda11() { [[ "${CUDA_VERSION%%.*}" == "11" ]] ; }

readonly DEFAULT_DASK_RAPIDS_VERSION="24.08"
readonly RAPIDS_VERSION=$(get_metadata_attribute 'rapids-version' ${DEFAULT_DASK_RAPIDS_VERSION})

readonly ROLE=$(/usr/share/google/get_metadata_value attributes/dataproc-role)
readonly MASTER=$(/usr/share/google/get_metadata_value attributes/dataproc-master)

readonly RUN_WORKER_ON_MASTER=$(get_metadata_attribute 'dask-cuda-worker-on-master' 'true')

# Scala config
readonly SCALA_VER="2.12"

# Dask config
readonly DASK_RUNTIME="$(/usr/share/google/get_metadata_value attributes/dask-runtime || echo 'standalone')"
readonly DASK_LAUNCHER=/usr/local/bin/dask-launcher.sh
readonly DASK_SERVICE=dask-cluster
readonly DASK_WORKER_SERVICE=dask-worker
readonly DASK_SCHEDULER_SERVICE=dask-scheduler
readonly DASK_YARN_CONFIG_FILE=/etc/dask/config.yaml

function execute_with_retries() {
  local -r cmd="$*"
  for i in {0..9} ; do
    if eval "$cmd"; then
      return 0 ; fi
    sleep 5
  done
  echo "Cmd '${cmd}' failed."
  return 1
}

readonly conda_env="/opt/conda/miniconda3/envs/dask-rapids"
function install_dask_rapids() {
  if is_cuda12 ; then
    local python_spec="python>=3.11"
    local cuda_spec="cuda-version>=12,<13"
    local dask_spec="dask>=2024.5"
    local numba_spec="numba"
  elif is_cuda11 ; then
    local python_spec="python>=3.9"
    local cuda_spec="cuda-version>=11,<=11.8"
    local dask_spec="dask"
    local numba_spec="numba"
  fi

  local CONDA_PACKAGES=(
    "${cuda_spec}"
    "rapids=${RAPIDS_VERSION}"
    "${dask_spec}"
    "dask-bigquery"
    "dask-ml"
    "dask-sql"
    "cudf"
    "${numba_spec}"
  )

  # Install cuda, rapids, dask
  local is_installed="0"
  mamba="/opt/conda/miniconda3/bin/mamba"
  conda="/opt/conda/miniconda3/bin/conda"

  "${conda}" remove -n dask --all || echo "unable to remove conda environment [dask]"

  for installer in "${mamba}" "${conda}" ; do
    set +e
    test -d "${conda_env}" || \
      time "${installer}" "create" -m -n 'dask-rapids' -y --no-channel-priority \
      -c 'conda-forge' -c 'nvidia' -c 'rapidsai'  \
      ${CONDA_PACKAGES[*]} \
      "${python_spec}"
    sync
    if [[ "$?" == "0" ]] ; then
      is_installed="1"
      break
    else
      "${conda}" config --set channel_priority flexible
    fi
    set -e
  done
  if [[ "${is_installed}" == "0" ]]; then
    echo "failed to install dask"
    return 1
  fi
  set -e
}

enable_worker_service="0"
function install_systemd_dask_worker() {
  echo "Installing systemd Dask Worker service..."
  local -r dask_worker_local_dir="/tmp/${DASK_WORKER_SERVICE}"

  mkdir -p "${dask_worker_local_dir}"

  local DASK_WORKER_LAUNCHER="/usr/local/bin/${DASK_WORKER_SERVICE}-launcher.sh"

  cat <<EOF >"${DASK_WORKER_LAUNCHER}"
#!/bin/bash
LOGFILE="/var/log/${DASK_WORKER_SERVICE}.log"
nvidia-smi -c DEFAULT
echo "dask-cuda-worker starting, logging to \${LOGFILE}"
${conda_env}/bin/dask-cuda-worker "${MASTER}:8786" --local-directory="${dask_worker_local_dir}" --memory-limit=auto >> "\${LOGFILE}" 2>&1
EOF

  chmod 750 "${DASK_WORKER_LAUNCHER}"

  local -r dask_service_file="/usr/lib/systemd/system/${DASK_WORKER_SERVICE}.service"
  cat <<EOF >"${dask_service_file}"
[Unit]
Description=Dask Worker Service
[Service]
Type=simple
Restart=on-failure
ExecStart=/bin/bash -c 'exec ${DASK_WORKER_LAUNCHER}'
[Install]
WantedBy=multi-user.target
EOF
  chmod a+r "${dask_service_file}"

  systemctl daemon-reload

  # Enable the service
  if [[ "${ROLE}" != "Master" ]]; then
    enable_worker_service="1"
  else
    # Enable service on single-node cluster (no workers)
    local worker_count="$(/usr/share/google/get_metadata_value attributes/dataproc-worker-count)"
    if [[ "${worker_count}" == "0" || "${RUN_WORKER_ON_MASTER}" == "true" ]]; then
      enable_worker_service="1"
    fi
  fi

  if [[ "${enable_worker_service}" == "1" ]]; then
    systemctl enable "${DASK_WORKER_SERVICE}"
    systemctl restart "${DASK_WORKER_SERVICE}"
  fi
}

function configure_dask_yarn() {
  # Replace config file on cluster.
  mkdir -p "$(dirname "${DASK_YARN_CONFIG_FILE}")"
  cat <<EOF >"${DASK_YARN_CONFIG_FILE}"
# Config file for Dask Yarn.
#
# These values are joined on top of the default config, found at
# https://yarn.dask.org/en/latest/configuration.html#default-configuration

yarn:
  environment: python://${conda_env}/bin/python

  worker:
    count: 2
    gpus: 1
    class: "dask_cuda.CUDAWorker"
EOF
}

function main() {
  if [[ "${RAPIDS_RUNTIME}" == "DASK" ]]; then
    # Install RAPIDS
    install_dask_rapids

    # In "standalone" mode, Dask relies on a shell script to launch.
    # In "yarn" mode, it relies a config.yaml file.
    if [[ "${DASK_RUNTIME}" == "standalone" ]]; then
      install_systemd_dask_worker
    elif [[ "${DASK_RUNTIME}" == "yarn" ]]; then
      configure_dask_yarn
    fi
    echo "RAPIDS installed with Dask runtime"
  else
    echo "Unsupported RAPIDS Runtime: ${RAPIDS_RUNTIME}"
    exit 1
  fi

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

function exit_handler() {
  set +e
  # Free conda cache
  /opt/conda/miniconda3/bin/conda clean -a > /dev/null 2>&1

  # Clear pip cache
  pip cache purge || echo "unable to purge pip cache"

  # remove the tmpfs conda pkgs_dirs
  if [[ -d /mnt/shm ]] ; then /opt/conda/miniconda3/bin/conda config --remove pkgs_dirs /mnt/shm ; fi

  # Clean up shared memory mounts
  for shmdir in /var/cache/apt/archives /var/cache/dnf /mnt/shm ; do
    if grep -q "^tmpfs ${shmdir}" /proc/mounts ; then
      rm -rf ${shmdir}/*
      umount -f ${shmdir}
    fi
  done

  # Clean up OS package cache ; re-hold systemd package
  if is_debuntu ; then
    apt-get -y -qq clean
    apt-get -y -qq autoremove
  else
    dnf clean all
  fi

  # print disk usage statistics
  if is_debuntu ; then
    # Rocky doesn't have sort -h and fails when the argument is passed
    du --max-depth 3 -hx / | sort -h | tail -10
  fi

  # Process disk usage logs from installation period
  rm -f /tmp/keep-running-df
  sleep 6s
  # compute maximum size of disk during installation
  # Log file contains logs like the following (minus the preceeding #):
#Filesystem      Size  Used Avail Use% Mounted on
#/dev/vda2       6.8G  2.5G  4.0G  39% /
  df --si
  perl -e '$max=( sort
                   map { (split)[2] =~ /^(\d+)/ }
                  grep { m:^/: } <STDIN> )[-1];
print( "maximum-disk-used: $max", $/ );' < /tmp/disk-usage.log

  echo "exit_handler has completed"

  # zero free disk space
  if [[ -n "$(get_metadata_attribute 'creating-image')" ]]; then
    dd if=/dev/zero of=/zero ; sync ; rm -f /zero
  fi

  return 0
}

trap exit_handler EXIT

function prepare_to_install(){
  free_mem="$(awk '/^MemFree/ {print $2}' /proc/meminfo)"
  # Write to a ramdisk instead of churning the persistent disk
  if [[ ${free_mem} -ge 5250000 ]]; then
    mkdir -p /mnt/shm
    mount -t tmpfs tmpfs /mnt/shm

    # Download conda packages to tmpfs
    /opt/conda/miniconda3/bin/conda config --add pkgs_dirs /mnt/shm
    mount -t tmpfs tmpfs /mnt/shm

    # Download pip packages to tmpfs
    pip config set global.cache-dir /mnt/shm || echo "unable to set global.cache-dir"

    # Download OS packages to tmpfs
    if is_debuntu ; then
      mount -t tmpfs tmpfs /var/cache/apt/archives
    else
      mount -t tmpfs tmpfs /var/cache/dnf
    fi
  fi

  # Monitor disk usage in a screen session
  if is_debuntu ; then
      apt-get install -y -qq screen
  elif is_rocky ; then
      dnf -y -q install screen
  fi
  rm -f /tmp/disk-usage.log
  touch /tmp/keep-running-df
  screen -d -m -US keep-running-df \
    bash -c 'while [[ -f /tmp/keep-running-df ]] ; do df --si / | tee -a /tmp/disk-usage.log ; sleep 5s ; done'
}

prepare_to_install

main
