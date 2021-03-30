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

# This customization-script can be used to customize the conda environment.
# It expects the following metadata:
#   conda-component: (Required) Must be either ANACONDA or MINICONDA3
#   conda-env-config-uri: (Optional) Must be a gsutil path to the yaml config
#   file.
#   conda-packages: (Optional) A list of conda packages with versions to be
#   installed in the base environment. Must be of the format
#   <pkg1>:<version1>_<pkg2>:<version2>...
#   Example: conda-packages=pytorch:1.4.0_visions:0.7.1
#   conda-packages: (Optional) A list of pip packages with versions to be
#   installed in the base environment. Must be of the format
#   <pkg1>:<version1>_<pkg2>:<version2>...
#   Example: tokenizers:0.10.1_datasets:1.5.0
# conda-env-config-uri is mutually exclusive with conda-packages and
# pip-packages.


function customize_conda() {
  local -r conda_component=$(/usr/share/google/get_metadata_value attributes/conda-component)
  local -r conda_env_config_uri=$(/usr/share/google/get_metadata_value attributes/conda-env-config-uri)
  local conda_packages=$(/usr/share/google/get_metadata_value attributes/conda-packages)
  local pip_packages=$(/usr/share/google/get_metadata_value attributes/pip-packages)

  validate_conda_component "${conda_component}"

  if [[ -n "${conda_env_config_uri}" && (( "${conda_packages}" || "${pip_packages}" )) ]]; then
    echo "conda-env-config-uri is mutually exclusive with conda-packages and pip-packages."
    exit 1
  fi

  local conda_bin_dir
  if [[ "${conda_component}" == 'ANACONDA' ]]; then
    conda_bin_dir="/opt/conda/anaconda/bin"
  else
    conda_bin_dir="/opt/conda/miniconda3/bin"
  fi
  if [[ -n "${conda_env_config_uri}" ]]; then
    local temp_config_file
    temp_config_file=$(mktemp /tmp/conda_env_XXX.yaml)
    gsutil cp "${conda_env_config_uri}" "${temp_config_file}"
    conda_env_name="$(grep 'name: ' "${temp_config_file}" | awk '{print $2}')"
    if [[ -z "${conda_env_name}" ]]; then
      conda_env_name="custom"
    fi
    create_and_activate_environment "${conda_bin_dir}" "${conda_env_name}" "${temp_config_file}"
  else
    if [[ -n "${conda_packages}" ]]; then
      local -a packages
      conda_packages=$(echo "${conda_packages}" | sed -r 's/:/==/g')
      IFS='_' read -r -a packages <<< "${conda_packages}"
      validate_package_formats "${packages}"

      # Conda will upgrade dependencies only if required, and fail if conflict
      # resolution with existing packages is not possible.
      "${conda_bin_dir}/conda" install "${packages[@]}" --yes
    fi
    if [[ -n "${pip_packages}" ]]; then
      local -a packages
      pip_packages=$(echo "${pip_packages}" | sed -r 's/:/==/g')
      IFS='_' read -r -a packages <<< "${pip_packages}"
      validate_package_formats "${packages}"

      # Pip will upgrade dependencies only if required. Pip does not check for
      # conflicts and may result in inconsistent environment.
      "${conda_bin_dir}/pip" install -U --upgrade-strategy only-if-needed "${packages[@]}"
    fi
  fi
}

function create_and_activate_environment() {
  local -r conda_bin_dir=$1
  local -r conda_env_name=$2
  local -r conda_env_config=$3
  "${conda_bin_dir}/conda" env create --quiet --name="${conda_env_name}" --file="${conda_env_config}"
  source "${conda_bin_dir}/activate" "${conda_env_name}"

  # Set property conda.env, which can be used during activate of the conda
  # component to activate the right environment.
  local -r conda_properties_path=/etc/google-dataproc/conda.properties
  echo "conda.env=$conda_env_name" >> "${conda_properties_path}"
}

function validate_conda_component() {
  local -r conda_component=$1

  if [[ -z "${conda_component}" ]]; then
    echo "Expected metadata conda-component not found"
    exit 1
  fi

  if [[ "${conda_component}" != 'ANACONDA' && "${conda_component}" != 'MINICONDA3' ]]; then
    echo "Metadata conda-component should either be ANACONDA or MINICONDA3"
    exit 1
  fi
}

function parse_packages() {
  local packages=$1
  local -n packages_array=$2

  packages=$(echo "${packages}" | sed -r 's/:/==/g')
  IFS='_' read -r -a packages_array <<< "${packages}"
}

function validate_package_formats() {
  local -r packages=$1
  local -r regex='.+==[0-9]+[\\.[0-9]+]*'
  for package in packages; do
    if ! [[ "${package}" =~ $regex ]]; then
      echo "Invalid package format ${package}"
      exit 1
    fi
  done
}

customize_conda
