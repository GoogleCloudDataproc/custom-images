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


_template = """
#!/usr/bin/env bash

# Script for creating Dataproc custom image.

set -euo pipefail

RED='\\e[0;31m'
GREEN='\\e[0;32m'
NC='\\e[0m'

function exit_handler() {{
  echo 'Cleaning up before exiting.'

  if [[ -f /tmp/{run_id}/vm_created ]]; then
    echo 'Deleting VM instance.'
    gcloud compute instances delete {image_name}-install \
        --project={project_id} --zone={zone} -q
  elif [[ -f /tmp/{run_id}/disk_created ]]; then
    echo 'Deleting disk.'
    gcloud compute images delete {image_name}-install --project={project_id} --zone={zone} -q
  fi

  echo 'Uploading local logs to GCS bucket.'
  gsutil -m rsync -r {log_dir}/ {gcs_log_dir}/

  if [[ -f /tmp/{run_id}/image_created ]]; then
    echo -e "${{GREEN}}Workflow succeeded, check logs at {log_dir}/ or {gcs_log_dir}/${{NC}}"
    exit 0
  else
    echo -e "${{RED}}Workflow failed, check logs at {log_dir}/ or {gcs_log_dir}/${{NC}}"
    exit 1
  fi
}}

function main() {{
  echo 'Uploading files to GCS bucket.'
  declare -a sources_k=({sources_map_k})
  declare -a sources_v=({sources_map_v})
  for i in "${{!sources_k[@]}}"; do
    gsutil cp "${{sources_v[i]}}" "{custom_sources_path}/${{sources_k[i]}}" > /dev/null 2>&1
  done

  if [[ '{base_image_family}' = '' ||  '{base_image_family}' = 'None' ]]; then
     src_image="--source-image={dataproc_base_image}"
  else
     src_image="--source-image-family={base_image_family}"
  fi

  local cert_args=""
  if [[ -n '{trusted_cert}' ]] && [[ -f '{trusted_cert}' ]]; then
    # build tls/ directory from variables defined near the header of
    # the examples/secure-boot/create-key-pair.sh file

    eval "$(bash examples/secure-boot/create-key-pair.sh)"

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

    cert_args="--signature-database-file={trusted_cert},${{MS_UEFI_CA}} --guest-os-features=UEFI_COMPATIBLE"

    # TODO: if db certs exist on source image, append them to new image
    # gcloud compute images describe cuda-pre-init-2-2-debian12-2024-10-09-16-15 --format json | jq '.shieldedInstanceInitialState'
  fi

  date
  echo 'Creating disk.'
  set -x
  time gcloud compute images create {image_name}-install \
       --project={project_id} \
       ${{src_image}} \
       ${{cert_args}} \
       {storage_location_flag} \
       --family={family}
  set +x
  touch "/tmp/{run_id}/disk_created"

  date
  echo 'Creating VM instance to run customization script.'
  set -x
  time gcloud compute instances create {image_name}-install \
      --project={project_id} \
      --zone={zone} \
      {network_flag} \
      {subnetwork_flag} \
      {no_external_ip_flag} \
      --machine-type={machine_type} \
      --image-project {project_id} \
      --image="{image_name}-install" \
      --boot-disk-size={disk_size}G \
      --boot-disk-type=pd-ssd \
      {accelerator_flag} \
      {service_account_flag} \
      --scopes=cloud-platform \
      {metadata_flag} \
      --metadata-from-file startup-script=startup_script/run.sh
  set +x

  touch /tmp/{run_id}/vm_created

  # clean up intermediate install image
  gcloud compute images delete -q {image_name}-install --project={project_id}

  echo 'Waiting for customization script to finish and VM shutdown.'
  gcloud compute instances tail-serial-port-output {image_name}-install \
      --project={project_id} \
      --zone={zone} \
      --port=1 2>&1 \
      | grep 'startup-script' \
      | sed -e 's/ {image_name}-install.*startup-script://g' \
      | dd bs=64 of={log_dir}/startup-script.log \
      || true
  echo 'Checking customization script result.'
  date
  if grep -q 'BuildFailed:' {log_dir}/startup-script.log; then
    echo -e "${{RED}}Customization script failed.${{NC}}"
    echo "See {log_dir}/startup-script.log for details"
    exit 1
  elif grep -q 'BuildSucceeded:' {log_dir}/startup-script.log; then
    echo -e "${{GREEN}}Customization script succeeded.${{NC}}"
  else
    echo 'Unable to determine the customization script result.'
    exit 1
  fi

  date
  echo 'Creating custom image.'
  set -x
  time gcloud compute images create {image_name} \
    --project={project_id} \
    --source-disk-zone={zone} \
    --source-disk={image_name}-install \
    {storage_location_flag} \
    --family={family}
  set +x

  touch /tmp/{run_id}/image_created
}}

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
        "custom-sources-path={custom_sources_path}")
    if self.args["metadata"]:
      metadata_flag_template += ",{metadata}"
    self.args["metadata_flag"] = metadata_flag_template.format(**self.args)

  def generate(self, args):
    self._init_args(args)
    return _template.format(**args)
