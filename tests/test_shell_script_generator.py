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

import unittest

from custom_image_utils import shell_script_generator

_expected_script = """
#!/usr/bin/env bash

# Script for creating Dataproc custom image.

set -euxo pipefail

RED='\\e[0;31m'
GREEN='\\e[0;32m'
NC='\\e[0m'

function exit_handler() {
  echo 'Cleaning up before exiting.'

  if [[ -f /tmp/custom-image-my-image-20190611-160823/vm_created ]]; then
    echo 'Deleting VM instance.'
    gcloud compute instances delete my-image-install         --project=my-project --zone=us-west1-a -q
  elif [[ -f /tmp/custom-image-my-image-20190611-160823/disk_created ]]; then
    echo 'Deleting disk.'
    gcloud compute disks delete my-image-install --project=my-project --zone=us-west1-a -q
  fi

  echo 'Uploading local logs to GCS bucket.'
  gsutil -m rsync -r /tmp/custom-image-my-image-20190611-160823/logs/ gs://my-bucket/custom-image-my-image-20190611-160823/logs/

  if [[ -f /tmp/custom-image-my-image-20190611-160823/image_created ]]; then
    echo -e "${GREEN}Workflow succeeded, check logs at /tmp/custom-image-my-image-20190611-160823/logs/ or gs://my-bucket/custom-image-my-image-20190611-160823/logs/${NC}"
    exit 0
  else
    echo -e "${RED}Workflow failed, check logs at /tmp/custom-image-my-image-20190611-160823/logs/ or gs://my-bucket/custom-image-my-image-20190611-160823/logs/${NC}"
    exit 1
  fi
}

function main() {
  echo 'Uploading files to GCS bucket.'
  declare -a sources_k=([0]='run.sh' [1]='init_actions.sh' [2]='ext'\\''ra_src.txt')
  declare -a sources_v=([0]='startup_script/run.sh' [1]='/tmp/my-script.sh' [2]='/path/to/extra.txt')
  for i in "${!sources_k[@]}"; do
    gsutil cp "${sources_v[i]}" "gs://my-bucket/custom-image-my-image-20190611-160823/sources/${sources_k[i]}"
  done

  echo 'Creating disk.'
  if [[ 'projects/my-dataproc-project/global/images/family/debian-10' = '' ||  'projects/my-dataproc-project/global/images/family/debian-10' = 'None' ]]; then
     IMAGE_SOURCE="--image=projects/cloud-dataproc/global/images/dataproc-1-4-deb9-20190510-000000-rc01"
  else
     IMAGE_SOURCE="--image-family=projects/my-dataproc-project/global/images/family/debian-10"
  fi
  
  gcloud compute disks create my-image-install       --project=my-project       --zone=us-west1-a       ${IMAGE_SOURCE}       --type=pd-ssd       --size=40GB

  touch "/tmp/custom-image-my-image-20190611-160823/disk_created"

  echo 'Creating VM instance to run customization script.'
  gcloud compute instances create my-image-install       --project=my-project       --zone=us-west1-a              --subnet=my-subnet       --no-address       --machine-type=n1-standard-2       --disk=auto-delete=yes,boot=yes,mode=rw,name=my-image-install       --accelerator=type=nvidia-tesla-v100,count=2 --maintenance-policy terminate       --service-account=my-service-account       --scopes=cloud-platform       --metadata=shutdown-timer-in-sec=500,custom-sources-path=gs://my-bucket/custom-image-my-image-20190611-160823/sources,key1=value1,key2=value2       --metadata-from-file startup-script=startup_script/run.sh
  touch /tmp/custom-image-my-image-20190611-160823/vm_created

  echo 'Waiting for customization script to finish and VM shutdown.'
  gcloud compute instances tail-serial-port-output my-image-install       --project=my-project       --zone=us-west1-a       --port=1 2>&1       | grep 'startup-script'       | tee /tmp/custom-image-my-image-20190611-160823/logs/startup-script.log       || true

  echo 'Checking customization script result.'
  if grep 'BuildFailed:' /tmp/custom-image-my-image-20190611-160823/logs/startup-script.log; then
    echo -e "${RED}Customization script failed.${NC}"
    exit 1
  elif grep 'BuildSucceeded:' /tmp/custom-image-my-image-20190611-160823/logs/startup-script.log; then
    echo -e "${GREEN}Customization script succeeded.${NC}"
  else
    echo 'Unable to determine the customization script result.'
    exit 1
  fi

  echo 'Creating custom image.'
  gcloud compute images create my-image       --project=my-project       --source-disk-zone=us-west1-a       --source-disk=my-image-install       --storage-location=us-east1       --family=debian9
  touch /tmp/custom-image-my-image-20190611-160823/image_created
}

trap exit_handler EXIT
mkdir -p /tmp/custom-image-my-image-20190611-160823/logs
main "$@" 2>&1 | tee /tmp/custom-image-my-image-20190611-160823/logs/workflow.log
"""


class TestShellScriptGenerator(unittest.TestCase):
  def test_generate_shell_script(self):
    args = {
        'run_id': 'custom-image-my-image-20190611-160823',
        'family': 'debian9',
        'image_name': 'my-image',
        'customization_script': '/tmp/my-script.sh',
        'metadata': 'key1=value1,key2=value2',
        'extra_sources': {"ext'ra_src.txt": "/path/to/extra.txt"},
        'machine_type': 'n1-standard-2',
        'disk_size': 40,
        'accelerator': 'type=nvidia-tesla-v100,count=2',
        'gcs_bucket': 'gs://my-bucket',
        'network': 'my-network',
        'subnetwork': 'my-subnet',
        'no_external_ip': True,
        'zone': 'us-west1-a',
        'dataproc_base_image':
          'projects/cloud-dataproc/global/images/dataproc-1-4-deb9-20190510-000000-rc01',
        'service_account': 'my-service-account',
        'oauth': '',
        'project_id': 'my-project',
        'storage_location': 'us-east1',
        'shutdown_timer_in_sec': 500,
        'base_image_family': 'projects/my-dataproc-project/global/images/family/debian-10'
    }

    script = shell_script_generator.Generator().generate(args)

    self.assertEqual(script, _expected_script)


if __name__ == '__main__':
  unittest.main()
