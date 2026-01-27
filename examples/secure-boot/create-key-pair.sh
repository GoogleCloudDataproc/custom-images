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
# This script creates a key pair and publishes to cloud secrets or
# fetches an already published key pair from cloud secrets

set -e

DEBUG="${DEBUG:-0}"
if (( DEBUG != 0 )); then
  set -x
fi

source examples/secure-boot/lib/env.sh
source examples/secure-boot/lib/util.sh

# https://github.com/glevand/secure-boot-utils
# https://cloud.google.com/compute/shielded-vm/docs/creating-shielded-images#adding-shielded-image
# https://cloud.google.com/compute/shielded-vm/docs/creating-shielded-images#generating-security-keys-certificates
# https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#Creating_keys

ITERATION=0009

SENTINEL_DIR="${REPRO_TMPDIR}/sentinels/create_key_pair"
mkdir -p "${SENTINEL_DIR}"

function create_key () {
    local EFI_VAR_NAME="$1"
    local CN_VAL="$2"
    local PRIVATE_KEY="tls/${EFI_VAR_NAME}.rsa"
    local CACERT="tls/${EFI_VAR_NAME}.pem"
    local CACERT_DER="tls/${EFI_VAR_NAME}.der"
        CA_KEY_SECRET_NAME="efi-${EFI_VAR_NAME}-priv-key-${ITERATION}"
        CA_CERT_SECRET_NAME="efi-${EFI_VAR_NAME}-pub-key-${ITERATION}"

        mkdir -p tls

        # Check if local files exist
        if [[ -f "${PRIVATE_KEY}" && -f "${CACERT}" && -f "${CACERT_DER}" && -f "tls/modulus-md5sum.txt" ]]; then
          print_status "Local key files and md5sum found."
          modulus_md5sum="$(cat tls/modulus-md5sum.txt)"
          report_result "Skipped"
          return 0
        fi

        # Check if secrets exist in Secret Manager
        print_status "Checking for existing secret: ${CA_CERT_SECRET_NAME}"
        if run_gcloud "check_pub_secret" gcloud secrets describe "${CA_CERT_SECRET_NAME}" --project="${PROJECT_ID}"; then
          report_result "Exists"
          print_status "Checking for existing secret: ${CA_KEY_SECRET_NAME}"
          if run_gcloud "check_priv_secret" gcloud secrets describe "${CA_KEY_SECRET_NAME}" --project="${PROJECT_ID}"; then
            report_result "Exists"
            print_status "Fetching existing secrets to local tls/ directory..."

            run_gcloud "fetch_priv_key" gcloud secrets versions access "1" \
              --project="${PROJECT_ID}" \
              --secret="${CA_KEY_SECRET_NAME}" --out-file="${PRIVATE_KEY}"

            run_gcloud "fetch_pub_key" gcloud secrets versions access "1" \
              --project="${PROJECT_ID}" \
              --secret="${CA_CERT_SECRET_NAME}" --out-file="${CACERT_DER}.base64"
            cat "${CACERT_DER}.base64" | base64 --decode > "${CACERT_DER}"
            rm "${CACERT_DER}.base64"

            openssl x509 -inform DER -in "${CACERT_DER}" -outform PEM -out "${CACERT}"
            report_result "Fetched"
          else
            report_result "Not Found"
            echo "Error: Public key secret exists but private key secret does not. Manual intervention required."
            return 1
          fi
        else
          report_result "Not Found"
          # Secrets don't exist, so generate keys and create secrets
          print_status "Generating new key pair: '${CN_VAL}'"
          openssl req \
                  -newkey rsa:3072 \
                  -nodes \
                  -keyout "${PRIVATE_KEY}" \
                  -new \
                  -x509 \
                  -sha256 \
                  -days 3650 \
                  -subj "/CN=${CN_VAL}/" \
                  -out "${CACERT}" > /dev/null 2>&1

          openssl x509 -outform DER -in "${CACERT}" -out "${CACERT_DER}"
          report_result "Generated"

          print_status "Creating secret: ${CA_KEY_SECRET_NAME}"
          if run_gcloud "create_priv_secret" gcloud secrets create "${CA_KEY_SECRET_NAME}" \
                 --project="${PROJECT_ID}" \
                 --replication-policy="automatic" \
                 --data-file="${PRIVATE_KEY}"; then
            report_result "Created"
          else
            report_result "Fail"
            return 1
          fi

          print_status "Creating secret: ${CA_CERT_SECRET_NAME}"
          cat "${CACERT_DER}" | base64 > "${CACERT_DER}.base64"
          if run_gcloud "create_pub_secret" gcloud secrets create "${CA_CERT_SECRET_NAME}" \
                 --project="${PROJECT_ID}" \
                 --replication-policy="automatic" \
                 --data-file="${CACERT_DER}.base64"; then
            report_result "Created"
          else
            report_result "Fail"
            return 1
          fi
          rm "${CACERT_DER}.base64"
        fi

        # Common steps after fetching or creating
        MS_UEFI_CA="tls/MicCorUEFCA2011_2011-06-27.crt"
        if [[ ! -f "${MS_UEFI_CA}" ]]; then
          print_status "Downloading Microsoft UEFI CA cert..."
          curl -s -L -o "${MS_UEFI_CA}" 'https://go.microsoft.com/fwlink/p/?linkid=321194'
          report_result "Done"
        fi

        echo "${CA_KEY_SECRET_NAME}" > tls/private-key-secret-name.txt
        echo "${CA_CERT_SECRET_NAME}" > tls/public-key-secret-name.txt

        print_status "Calculating modulus md5sum..."
        modulus_md5sum="$(openssl rsa -noout -modulus -in ${PRIVATE_KEY} | openssl md5 | awk '{print $2}' | tee tls/modulus-md5sum.txt)"
        report_result "Done"
}

EFI_VAR_NAME=db

create_key "${EFI_VAR_NAME}" "Cloud Dataproc Custom Image CA ${ITERATION}"

# Output variables for the calling script
echo "modulus_md5sum=${modulus_md5sum}"
echo "private_secret_name=${CA_KEY_SECRET_NAME}"
echo "public_secret_name=${CA_CERT_SECRET_NAME}"
echo "secret_project=${PROJECT_ID}"
echo "secret_version=1"
