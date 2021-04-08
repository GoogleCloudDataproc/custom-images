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
#
#   conda-component: (Required) Must be either ANACONDA or MINICONDA3. Please
#   make sure the base image supports the component passed here, else the
#   script will fail. Anaconda is not supported on 2.0 images. For information
#   on Anaconda vs Miniconda, refer to Miniconda's latest documentation
#   https://docs.conda.io/en/latest/miniconda.html
#
#   conda-env-config-uri: (Optional) Must be a GCS URI to the yaml config
#   file.
#
#   conda-packages: (Optional) A list of conda packages with versions to be
#   installed in the base environment. Must be of the format
#   <pkg1>:<version1>#<pkg2>:<version2>...
#
#   pip-packages: (Optional) A list of pip packages with versions to be
#   installed in the base environment. Must be of the format
#   <pkg1>:<version1>#<pkg2>:<version2>...
#
# conda-env-config-uri is mutually exclusive with conda-packages and
# pip-packages. If both are provided, the script will fail.
# If environment config file does not contain name of the environment, the name
# "custom" will be used by default.
#
#
# Examples
#
# The following example extracts config file from your environment, copies it to
# your GCS bucket and uses it to create a cluster.
#
#   conda env export --name=<env-name> > environment.yaml
#   gsutil cp environment.yaml gs://<bucket-directory-path>/environment.yaml
#   python generate_custom_image.py \
#    --image-name <image-name> \
#    --dataproc-version "1.5.34-debian10" \
#    --customization-script scripts/customize_conda.sh \
#    --zone <zone> \
#    --gcs-bucket gs://<bucket-directory-path> \
#    --metadata 'conda-component=MINICONDA3,dataproc:conda.env.config.uri=gs://<file-path>/environment.yaml'
#
#
# The following example installs the specified conda and pip packages into the
# base environment.
# python generate_custom_image.py \
#    --image-name <image-name> \
#    --dataproc-version "1.5.34-debian10" \
#    --customization-script scripts/customize_conda.sh \
#    --zone <zone> \
#    --gcs-bucket gs://<bucket-path> \
#    --metadata 'conda-component=MINICONDA3,conda-packages=pytorch:1.4.0#visions:0.7.1,pip-packages=tokenizers:0.10.1#numpy:1.19.2'


function customize_conda() {
  local conda_component
  local conda_env_config_uri
  local conda_packages
  local pip_packages
  local conda_bin_dir
  conda_component=$(/usr/share/google/get_metadata_value attributes/conda-component || true)
  conda_env_config_uri=$(/usr/share/google/get_metadata_value attributes/conda-env-config-uri || true)
  conda_packages=$(/usr/share/google/get_metadata_value attributes/conda-packages || true)
  pip_packages=$(/usr/share/google/get_metadata_value attributes/pip-packages || true)

  validate_conda_component "${conda_component}"

  if [[ -n "${conda_env_config_uri}" && (( -n "${conda_packages}" || -n "${pip_packages}" )) ]]; then
    echo "conda-env-config-uri is mutually exclusive with conda-packages and pip-packages."
    exit 1
  fi

  if [[ "${conda_component}" == 'ANACONDA' ]]; then
    conda_bin_dir="/opt/conda/anaconda/bin"
  elif [[ "${conda_component}" == 'MINICONDA3' ]]; then
    conda_bin_dir="/opt/conda/miniconda3/bin"
  fi
  if [[ -n "${conda_env_config_uri}" ]]; then
    customize_with_config_file "${conda_bin_dir}" "${conda_env_config_uri}"
  else
    customize_with_package_list "${conda_bin_dir}" "${conda_packages}" "${pip_packages}"
  fi
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

function customize_with_config_file() {
  local -r conda_bin_dir=$1
  local -r conda_env_config_uri=$2
  local temp_config_file
  temp_config_file=$(mktemp /tmp/conda_env_XXX.yaml)
  gsutil cp "${conda_env_config_uri}" "${temp_config_file}"
  conda_env_name="$(grep 'name: ' "${temp_config_file}" | awk '{print $2}')"
  if [[ -z "${conda_env_name}" ]]; then
    conda_env_name="custom"
  fi
  create_and_activate_environment "${conda_bin_dir}" "${conda_env_name}" "${temp_config_file}"
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

function customize_with_package_list() {
  local -r conda_bin_dir=$1
  local conda_packages=$2
  local pip_packages=$3
  if [[ -n "${conda_packages}" ]]; then
      local -a packages
      conda_packages=$(echo "${conda_packages}" | sed -r 's/:/==/g')
      IFS='#' read -r -a packages <<< "${conda_packages}"
      validate_package_formats "${packages[@]}"

      # Conda will upgrade dependencies only if required, and fail if conflict
      # resolution with existing packages is not possible.
      "${conda_bin_dir}/conda" install "${packages[@]}" --yes
    fi
    if [[ -n "${pip_packages}" ]]; then
      local -a packages
      pip_packages=$(echo "${pip_packages}" | sed -r 's/:/==/g')
      IFS='#' read -r -a packages <<< "${pip_packages}"
      validate_package_formats "${packages[@]}"

      # Pip will upgrade dependencies only if required. Pip does not check for
      # conflicts and may result in inconsistent environment.
      "${conda_bin_dir}/pip" install -U --upgrade-strategy only-if-needed "${packages[@]}"
    fi
}

function validate_package_formats() {
  local -r packages=("$@")
  local -r regex='.+==[0-9]+[\\.[0-9]+]*'
  for package in "${packages[@]}"; do
    if ! [[ "${package}" =~ $regex ]]; then
      echo "Invalid package format ${package}"
      exit 1
    fi
  done
}

customize_conda
