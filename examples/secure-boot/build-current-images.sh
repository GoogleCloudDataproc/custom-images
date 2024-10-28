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
# This script creates a custom image pre-loaded with cuda

set -ex

function configure_service_account() {
  # Create service account
  if gcloud iam service-accounts list --filter email="${GSA}" 2>&1 | grep -q 'Listed 0 items.' ; then
    # Create service account for this purpose
    echo "creating pre-init customization service account ${GSA}"
    gcloud iam service-accounts create "${SA_NAME}" \
      --description="Service account for pre-init customization" \
      --display-name="${SA_NAME}"
  fi

  if [[ -d tls ]] ; then mv tls "tls-$(date +%s)" ; fi
  eval "$(bash examples/secure-boot/create-key-pair.sh)"

  # Grant service account access to bucket
  gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/storage.objectViewer" > /dev/null 2>&1

  # Grant the service account access to list secrets for the project
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.viewer" > /dev/null 2>&1

  # Grant service account permission to access the private secret
  gcloud secrets add-iam-policy-binding "${private_secret_name}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.secretAccessor" > /dev/null 2>&1

  # Grant service account permission to access the public secret
  gcloud secrets add-iam-policy-binding "${public_secret_name}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.secretAccessor" > /dev/null 2>&1
}

function revoke_bindings() {
  # Revoke permission to access the private secret
  gcloud secrets remove-iam-policy-binding "${private_secret_name}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.secretAccessor" > /dev/null 2>&1

  # Revoke access to bucket
  gcloud storage buckets remove-iam-policy-binding "gs://${BUCKET}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/storage.objectViewer" > /dev/null 2>&1

  # Revoke access to list secrets for the project
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/secretmanager.viewer" > /dev/null 2>&1
}

export PROJECT_ID="$(jq    -r .PROJECT_ID    env.json)"
export PURPOSE="$(jq       -r .PURPOSE       env.json)"
export BUCKET="$(jq        -r .BUCKET        env.json)"

SA_NAME="sa-${PURPOSE}"
GSA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "${PROJECT_ID}"

gcloud auth login

configure_service_account

# screen session name
session_name="build-current-images"

readonly timestamp="$(date +%F-%H-%M)"
#readonly timestamp="2024-10-24-04-21"
export timestamp

export tmpdir=/tmp/${timestamp};
mkdir ${tmpdir}
export ZONE="$(jq -r .ZONE env.json)"
gcloud compute instances list --zones "${ZONE}" --format json > ${tmpdir}/instances.json
gcloud compute images    list                   --format json > ${tmpdir}/images.json

# Run generation scripts simultaneously for each dataproc image version
screen -US "${session_name}" -c examples/secure-boot/pre-init.screenrc

# tail -n 3 /tmp/custom-image-*/logs/workflow.log
# tail -n 3 /tmp/custom-image-*/logs/startup-script.log
# tail -n 3 /tmp/custom-image-${PURPOSE}-2-*/logs/workflow.log
function find_disk_usage() {
  test -f /tmp/genline.pl || cat > /tmp/genline.pl<<'EOF'
#!/usr/bin/perl -w
use strict;

my $fn = $ARGV[0];
my( $config ) = ( $fn =~ /custom-image-(.*-(debian|rocky|ubuntu)\d+)-\d+/ );

my @raw_lines = <STDIN>;
my( $l ) = grep { m: /dev/.*/\s*$: } @raw_lines;
my( $stats ) = ( $l =~ m:\s*/dev/\S+\s+(.*?)\s*$: );

my( $dp_version ) = ($config =~ /-pre-init-(.+)/);
$dp_version =~ s/-/./;

my($max) = map { / maximum-disk-used: (\d+)/ } @raw_lines;
$max+=3;
my $i_dp_version = sprintf(q{%-15s}, qq{"$dp_version"});

print( qq{  $i_dp_version) disk_size_gb="$max" ;; # $stats # $config}, $/ );
EOF
  for f in $(grep -l 'Customization script suc' /tmp/custom-image-*/logs/workflow.log|sed -e 's/workflow.log/startup-script.log/')
  do
    grep -A20 'Filesystem.*Avail' $f | perl /tmp/genline.pl $f
  done
}

# sleep 8m ; grep 'Customization script' /tmp/custom-image-*/logs/workflow.log
# grep maximum-disk-used /tmp/custom-image-*/logs/startup-script.log

revoke_bindings
