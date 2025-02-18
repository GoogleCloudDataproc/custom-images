# Copyright 2019,2020,2024 Google LLC. All Rights Reserved.
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
"""
Shell script based image creation workflow generator.
"""

from datetime import datetime


_template = """#!/usr/bin/env bash

# Script for creating Dataproc custom image.

set -euo pipefail

RED='\\e[0;31m'
GREEN='\\e[0;32m'
NC='\\e[0m'

base_obj_type="images"

function execute_with_retries() (
  set +x
  local -r cmd="$*"

  for ((i = 0; i < 3; i++)); do
    if eval "$cmd"; then return 0 ; fi
    sleep 12
  done
  return 1
)

function gsutil() {{ ${{gsutil_cmd}} $* ; }}

function version_ge() ( set +x ;  [ "$1" = "$(echo -e "$1\n$2" | sort -V | tail -n1)" ] ; )
function version_gt() ( set +x ;  [ "$1" = "$2" ] && return 1 || version_ge $1 $2 ; )
function version_le() ( set +x ;  [ "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ] ; )
function version_lt() ( set +x ;  [ "$1" = "$2" ] && return 1 || version_le $1 $2 ; )

function prepare() {{
  # With the 402.0.0 release of gcloud sdk, `gcloud storage` can be
  # used as a more performant replacement for `gsutil`
  gsutil_cmd="gcloud storage"
  gcloud_sdk_version="$(gcloud --version | awk -F'SDK ' '/Google Cloud SDK/ {{print $2}}')"
  if version_lt "${{gcloud_sdk_version}}" "402.0.0" ; then
    gsutil_cmd="$(which gsutil) -o GSUtil:check_hashes=never"
  fi
}}

function exit_handler() {{
  echo 'Cleaning up before exiting.'

  if [[ -f /tmp/{run_id}/vm_created ]]; then ( set +e
    echo 'Deleting VM instance.'
    execute_with_retries \
      gcloud compute instances delete {image_name}-install --project={project_id} --zone={zone} -q
  ) elif [[ -f /tmp/{run_id}/disk_created ]]; then
    echo 'Deleting disk.'
    execute_with_retries gcloud compute ${{base_obj_type}} delete {image_name}-install --project={project_id} -q
  fi

  echo 'Uploading local logs to GCS bucket.'
  gsutil rsync -r {log_dir}/ {gcs_log_dir}/

  if [[ -f /tmp/{run_id}/image_created ]]; then
    echo -e "${{GREEN}}Workflow succeeded${{NC}}, check logs at {log_dir}/ or {gcs_log_dir}/"
    exit 0
  else
    echo -e "${{RED}}Workflow failed${{NC}}, check logs at {log_dir}/ or {gcs_log_dir}/"
    exit 1
  fi
}}

function test_element_in_array {{
  local test_element="$1" ; shift
  local -a test_array=("$@")

  for item in "${{test_array[@]}}"; do
    if [[ "${{item}}" == "${{test_element}}" ]]; then return 0 ; fi
  done
  return 1
}}

function print_modulus_md5sum {{
  local derfile="$1"
  openssl x509 -noout -modulus -in "${{derfile}}" | openssl md5 | awk '{{print $2}}'
}}

function print_img_dbs_modulus_md5sums() {{
  local long_img_name="$1"
  local img_name="$(echo ${{long_img_name}} | sed -e 's:^.*/::')"
  local json_tmpfile="/tmp/{run_id}/${{img_name}}.json"
  gcloud compute images describe ${{long_img_name}} --format json > "${{json_tmpfile}}"

  local -a db_certs=()
  mapfile -t db_certs < <( cat ${{json_tmpfile}} | jq -r 'try .shieldedInstanceInitialState.dbs[].content' )

  local -a modulus_md5sums=()
  for key in "${{!db_certs[@]}}" ; do
    local derfile="/tmp/{run_id}/${{img_name}}.${{key}}.der"
    echo "${{db_certs[${{key}}]}}" | \
      perl -M'MIME::Base64(decode_base64url)' -ne 'chomp; print( decode_base64url($_) )' \
      > "${{derfile}}"
    modulus_md5sums+=( $(print_modulus_md5sum "${{derfile}}") )
  done

  echo "${{modulus_md5sums[@]}}"
}}

function main() {{
  echo 'Uploading files to GCS bucket.'
  declare -a sources_k=({sources_map_k})
  declare -a sources_v=({sources_map_v})
  for i in "${{!sources_k[@]}}"; do
    gsutil cp "${{sources_v[i]}}" "{custom_sources_path}/${{sources_k[i]}}" > /dev/null 2>&1
  done

  local cert_args=""
  local num_src_certs="0"
  metadata_arg="{metadata_flag}"
  if [[ -n '{trusted_cert}' ]] && [[ -f '{trusted_cert}' ]]; then
    # build tls/ directory from variables defined near the header of
    # the examples/secure-boot/create-key-pair.sh file

    eval "$(bash examples/secure-boot/create-key-pair.sh)"
    metadata_arg="${{metadata_arg}},public_secret_name=${{public_secret_name}},private_secret_name=${{private_secret_name}},secret_project=${{secret_project}},secret_version=${{secret_version}}"

    # by default, a gcloud secret with the name of efi-db-pub-key-042 is
    # created in the current project to store the certificate installed
    # as the signature database file for this disk image

    # The MS UEFI CA is a reasonable base from which to build trust.  We
    # will trust code signed by this CA as well as code signed by
    # trusted_cert (tls/db.der)

    # The Microsoft Corporation UEFI CA 2011
    local -r MS_UEFI_CA="tls/MicCorUEFCA2011_2011-06-27.crt"
    test -f "${{MS_UEFI_CA}}" || \
      curl -L -o ${{MS_UEFI_CA}} 'https://go.microsoft.com/fwlink/p/?linkid=321194'

    local -a cert_list=()

    local -a default_cert_list
    default_cert_list=("{trusted_cert}" "${{MS_UEFI_CA}}")
    local -a src_img_modulus_md5sums=()

    mapfile -t src_img_modulus_md5sums < <(print_img_dbs_modulus_md5sums {dataproc_base_image})
    num_src_certs="${{#src_img_modulus_md5sums[@]}}"
    echo "debug - num_src_certs: [${{#src_img_modulus_md5sums[*]}}]"
    echo "value of src_img_modulus_md5sums: [${{src_img_modulus_md5sums}}]"
    if [[ -z "${{src_img_modulus_md5sums}}" ]]; then
      num_src_certs=0
      echo "no db certificates in source image"
      cert_list=( "${{default_cert_list[@]}}" )
    else
      echo "${{num_src_certs}} db certificates attached to source image"
      echo "db certs exist in source image"
      for cert in ${{default_cert_list[*]}}; do
        if test_element_in_array "$(print_modulus_md5sum ${{cert}})" ${{src_img_modulus_md5sums[@]}} ; then
          echo "cert ${{cert}} is already in source image's db list"
        else
          cert_list+=("${{cert}}")
        fi
      done
      # append source image's cert list
      local img_name="$(echo {dataproc_base_image} | sed -e 's:^.*/::')"
      if [[ ${{#cert_list[@]}} -ne 0 ]] && compgen -G "/tmp/{run_id}/${{img_name}}.*.der" > /dev/null ; then
        cert_list+=(/tmp/{run_id}/${{img_name}}.*.der)
      fi
    fi

    if [[ ${{#cert_list[@]}} -eq 0 ]]; then
      echo "all certificates already included in source image's db list"
    else
      cert_args="--signature-database-file=$(IFS=, ; echo "${{cert_list[*]}}") --guest-os-features=UEFI_COMPATIBLE"
    fi
  fi

  date

  if [[ -z "${{cert_args}}" && "${{num_src_certs}}" -ne "0" ]]; then
    echo 'Re-using base image'
    base_obj_type="reuse"
    instance_disk_args='--image-project={project_id} --image={dataproc_base_image} --boot-disk-size={disk_size}G --boot-disk-type=pd-ssd'

  elif [[ -n "${{cert_args}}" ]] ; then
    echo 'Creating image.'
    base_obj_type="images"
    instance_disk_args='--image-project={project_id} --image={image_name}-install --boot-disk-size={disk_size}G --boot-disk-type=pd-ssd'
    execute_with_retries \
      gcloud compute images create {image_name}-install \
      --project={project_id} \
      --source-image={dataproc_base_image} \
      ${{cert_args}} \
      {storage_location_flag} \
      --family={family}
    touch "/tmp/{run_id}/disk_created"
  else
    echo 'Creating disk.'
    base_obj_type="disks"
    instance_disk_args='--disk=auto-delete=yes,boot=yes,mode=rw,name={image_name}-install'
    execute_with_retries gcloud compute disks create {image_name}-install \
      --project={project_id} \
      --zone={zone} \
      --image={dataproc_base_image} \
      --type=pd-ssd \
      --size={disk_size}GB
    touch "/tmp/{run_id}/disk_created"
  fi

  date
  echo 'Creating VM instance to run customization script.'
  execute_with_retries gcloud compute instances create {image_name}-install \
      --project={project_id} \
      --zone={zone} \
      {network_flag} \
      {subnetwork_flag} \
      {no_external_ip_flag} \
      --machine-type={machine_type} \
      ${{instance_disk_args}} \
      {accelerator_flag} \
      {service_account_flag} \
      --scopes=cloud-platform \
      "${{metadata_arg}}" \
      --metadata-from-file startup-script=startup_script/run.sh

  touch /tmp/{run_id}/vm_created

  # clean up intermediate install image
  if [[ "${{base_obj_type}}" == "images" ]] ; then ( set +e
    # This sometimes returns an API error but deletes the image despite the failure
    gcloud compute images delete -q {image_name}-install --project={project_id}
  ) fi

  echo "Monitor startup logs in {log_dir}/startup-script.log"
  echo 'Waiting for customization script to finish and VM shutdown.'
  set -x
  # too many serial port output requests per minute occur if they all occur at once
  sleep $(( ( RANDOM % 60 ) + 20 ))

  gcloud compute instances describe --format json {image_name}-install --zone {zone} | tee {log_dir}/instance.json

  execute_with_retries gcloud compute instances tail-serial-port-output {image_name}-install \
      --project={project_id} \
      --zone={zone} \
      --port=1 2>&1 \
      | grep 'startup-script' | grep -v '^\\[' \
      | sed -e 's/ {image_name}-install.*startup-script://g' \
      | dd bs=1 status=none of={log_dir}/startup-script.log \
      || true
  echo 'Checking customization script result.'
  date
  if grep -q 'BuildSucceeded:' {log_dir}/startup-script.log; then
    echo -e "${{GREEN}}Customization script succeeded.${{NC}}"
  else
    echo -e "${{RED}}Customization script failed.${{NC}}"
    echo "See {log_dir}/startup-script.log for details"
    exit 1
  fi

  date
  echo 'Creating custom image.'
  execute_with_retries gcloud compute images create {image_name} \
    --project={project_id} \
    --source-disk-zone={zone} \
    --source-disk={image_name}-install \
    {storage_location_flag} \
    --family={family}

  touch /tmp/{run_id}/image_created
}}

prepare
trap exit_handler EXIT
mkdir -p {log_dir}
main "$@" 2>&1 | tee {log_dir}/workflow.log
"""

class Generator:
  """Shell script based image creation workflow generator."""

  def _init_args(self, args):
    self.args = args
    if "run_id" not in self.args:
      self.args["run_id"] = "custom-image-{image_name}-{timestamp}".format(
          timestamp=datetime.now().strftime("%Y%m%d-%H%M%S"), **self.args)
    self.args["bucket_name"] = self.args["gcs_bucket"].replace("gs://", "")
    self.args["custom_sources_path"] = "gs://{bucket_name}/{run_id}/sources".format(**self.args)

    all_sources = {
        "run.sh": "startup_script/run.sh",
        "init_actions.sh": self.args["customization_script"]
    }
    all_sources.update(self.args["extra_sources"])

    sources_map_items = tuple(enumerate(all_sources.items()))
    self.args["sources_map_k"] = " ".join([
        "[{}]='{}'".format(i, kv[0].replace("'", "'\\''")) for i, kv in sources_map_items])
    self.args["sources_map_v"] = " ".join([
        "[{}]='{}'".format(i, kv[1].replace("'", "'\\''")) for i, kv in sources_map_items])

    self.args["log_dir"] = "/tmp/{run_id}/logs".format(**self.args)
    self.args["gcs_log_dir"] = "gs://{bucket_name}/{run_id}/logs".format(
      **self.args)
    if self.args["subnetwork"]:
      self.args["subnetwork_flag"] = "--subnet={subnetwork}".format(**self.args)
      self.args["network_flag"] = ""
    elif self.args["network"]:
      self.args["network_flag"] = "--network={network}".format(**self.args)
      self.args["subnetwork_flag"] = ""
    if self.args["service_account"]:
      self.args[
        "service_account_flag"] = "--service-account={service_account}".format(
        **self.args)
    self.args["no_external_ip_flag"] = "--no-address" if self.args[
      "no_external_ip"] else ""
    self.args[
      "accelerator_flag"] = "--accelerator={accelerator} --maintenance-policy terminate".format(
        **self.args) if self.args["accelerator"] else ""
    self.args[
      "storage_location_flag"] = "--storage-location={storage_location}".format(
        **self.args) if self.args["storage_location"] else ""
    metadata_flag_template = (
        "--metadata=shutdown-timer-in-sec={shutdown_timer_in_sec},"
        "custom-sources-path={custom_sources_path}"
    )
    if self.args["zone"]:
      region = "-".join(self.args["zone"].split("-")[:-1])
      metadata_flag_template += ',dataproc-region="{}"'.format(region)
    if self.args["optional_components"]:
      optional_components = self.args["optional_components"].split(',')
      # convert to component names used inside image and join to set as metadata value
      optional_image_components = '.'.join(self._get_optional_to_image_components(optional_components))
      metadata_flag_template += ',optional-components="{}"'.format(optional_image_components)
    if self.args["dataproc_version"]:
      dataproc_version = self.args["dataproc_version"]
      metadata_flag_template += ',dataproc_dataproc_version="{}"'.format(dataproc_version)
    if self.args["metadata"]:
      metadata_flag_template += ",{metadata}"
    self.args["metadata_flag"] = metadata_flag_template.format(**self.args)

  def _get_optional_to_image_components(self, optional_components):
    """Get the equivalent component names in the image for user provided optional components."""
    # Add new component here, if component name inside image scripts is different.
    optional_to_image_component_map = {
      "DOCKER": "DOCKER-CE",
      "HIVE_WEBHCAT": "HIVE-WEBHCAT-SERVER",
      "SOLR": "SOLR-SERVER",
    }
    optional_image_components = []
    for component in optional_components:
      image_component = optional_to_image_component_map.get(component, component)
      optional_image_components.append(image_component)

    return optional_image_components

  def generate(self, args):
    self._init_args(args)
    return _template.format(**args)
