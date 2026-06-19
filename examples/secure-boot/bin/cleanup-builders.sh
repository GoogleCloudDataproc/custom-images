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
# This script cleans up any lingering builder VMs using screen.

set -e

DEBUG="${DEBUG:-0}"
if (( DEBUG != 0 )); then
  set -x
fi

source examples/secure-boot/lib/env.sh
source examples/secure-boot/lib/util.sh

print_status "Searching for lingering builder VMs in project ${PROJECT_ID}, zone ${ZONE}..."

INSTANCE_LIST=$(gcloud compute instances list \
  --project="${PROJECT_ID}" \
  --zones="${ZONE}" \
  --filter="name ~ -install$" \
  --format="value(name)")

if [[ -z "${INSTANCE_LIST}" ]]; then
  report_result "None Found"
  echo "No lingering builder VMs found to clean up." >&2
  exit 0
fi

report_result "Found"
echo "The following builder VMs will be deleted in detached screen sessions:" >&2
echo "${INSTANCE_LIST}" >&2

read -p "Continue with deletion? (y/N): " confirm
if [[ "${confirm}" != [yY] ]]; then
  echo "Deletion cancelled." >&2
  exit 0
fi

TEMP_SCREENRC="${tmpdir}/temp_cleanup.screenrc"
rm -f "${TEMP_SCREENRC}"
touch "${TEMP_SCREENRC}"

echo "The following builder VMs will be deleted in a new screen session:" >&2
echo "${INSTANCE_LIST}" >&2

read -p "Continue with deletion? (y/N): " confirm
if [[ "${confirm}" != [yY] ]]; then
  echo "Deletion cancelled." >&2
  exit 0
fi

i=1
for instance in ${INSTANCE_LIST}; do
  echo "Queueing deletion for ${instance} in screen window ${i}" >&2
  SCREEN_CMD="
attempt=0
while true; do
  gcloud beta compute instances delete ${instance} --zone=${ZONE} --project=${PROJECT_ID} --quiet --no-graceful-shutdown && break
  attempt=$((attempt + 1))
  if [[ ${attempt} -ge 3 ]]; then
    echo 'Max retries reached for ${instance}'
    break
  fi
  echo 'Failed, retrying in 5 seconds...'
  read -t 5
done
echo \"Delete command for ${instance} finished with exit code $?\"
echo \"Window will close in 5 seconds...\"
read -t 5
"
  echo "screen -t delete-${i}-${instance} ${i} bash -c '${SCREEN_CMD}'" >> "${TEMP_SCREENRC}"
  i=$((i + 1))
  sleep 0.1 # Small delay
done


echo "Launching screen session from ${TEMP_SCREENRC}..." >&2
screen -c "${TEMP_SCREENRC}"

rm -f "${TEMP_SCREENRC}"
echo "Screen session exited." >&2
