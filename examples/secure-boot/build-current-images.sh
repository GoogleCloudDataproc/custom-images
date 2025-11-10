#!/bin/bash

# Copyright 2024 Google LLC and contributors
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
# This script creates a custom image pre-loaded with
#
# GPU drivers + cuda + rapids + cuDNN + nccl + tensorflow + pytorch + ipykernel + numba

# To run the script, the following will bootstrap
#
# git clone git@github.com:GoogleCloudDataproc/custom-images
# cd custom-images
# git checkout 2025.02
# cp examples/secure-boot/env.json.sample env.json
# vi env.json
# docker build -f Dockerfile -t custom-images-builder:latest .
# export timestamp=$(date "+%Y%m%d-%H%M%S")
# echo "Log directory: ./tmp/logs/${timestamp}"
# mkdir -p ./tmp/logs/${timestamp}
# time podman run -it \
#   -v ~/.config/gcloud:/root/.config/gcloud \
#   -v ./tmp/logs/${timestamp}:/tmp \
#   -e DEBUG=0 \
#   -e timestamp=${timestamp} \
#   custom-images-builder:latest \
#   bash examples/secure-boot/build-current-images.sh


set -e

DEBUG="${DEBUG:-0}"
if (( DEBUG != 0 )); then
  set -x
fi

# Activate service account
source examples/secure-boot/lib/env.sh
source examples/secure-boot/lib/util.sh

export tmpdir="${REPRO_TMPDIR}"
mkdir -p "${tmpdir}/sentinels"

# screen session name
session_name="build-current-images"

print_status "Starting screen session ${session_name} to build images... "
screen -L -US "${session_name}" -c examples/secure-boot/pre-init.screenrc
#report_result "Done"

function find_disk_usage() {
  print_status "Analyzing disk usage... "
  #  grep maximum-disk-used /tmp/custom-image-*/logs/startup-script.log
  grep -H 'Customization script' /tmp/custom-image-*/logs/workflow.log
  echo '# DP_IMG_VER       RECOMMENDED_DISK_SIZE   DSK_SZ  D_USED   D_FREE  D%F     PURPOSE'
# workflow_log=/tmp/custom-image-dataproc-2-0-deb10-20250424-232955-tf-20250425-230559/logs/workflow.log
  for workflow_log in $(grep -Hl "Customization script" /tmp/custom-image-*/logs/workflow.log) ; do
    startup_log="${workflow_log/workflow/startup-script}"
    grep -v '^\['  "${startup_log}" \
      | grep -A20 'Filesystem.*Avail' | tail -20 \
      | perl examples/secure-boot/genline.pl "${startup_log}"
  done
  report_result "Done"
}
