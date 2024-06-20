#!/bin/bash

set -e

# https://github.com/glevand/secure-boot-utils

# https://cloud.google.com/compute/shielded-vm/docs/creating-shielded-images#adding-shielded-image

# https://cloud.google.com/compute/shielded-vm/docs/creating-shielded-images#generating-security-keys-certificates

# https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#Creating_keys

ITERATION=005

CURRENT_PROJECT_ID="$(gcloud config get project)"
if [[ -z "${CURRENT_PROJECT_ID}" ]]; then
    echo 'project is not set.  please set with `gcloud config set project ${PROJECT_ID}`'
    exit -1
fi
PROJECT_ID="${CURRENT_PROJECT_ID}"


function create_key () {
    local EFI_VAR_NAME="$1"
    local CN_VAL="$2"

    if [[ -f "tls/${EFI_VAR_NAME}.rsa" ]]; then
        echo "key already exists.  Skipping generation."
        return
    fi
    mkdir -p tls

    local PRIVATE_KEY="tls/${EFI_VAR_NAME}.rsa"
    local CACERT="tls/${EFI_VAR_NAME}.pem"
    local CACERT_DER="tls/${EFI_VAR_NAME}.der"

    echo "generating '${CN_VAL}' '${CACERT}', '${CACERT_DER}' and '${PRIVATE_KEY}'"
    # Generate new x.509 key and cert
    openssl req \
            -newkey rsa:3072 \
            -nodes \
            -keyout "${PRIVATE_KEY}" \
            -new \
            -x509 \
            -sha256 \
            -days 3650 \
            -subj "/CN=${CN_VAL}/" \
            -out "${CACERT}"

    # Create a DER-format version of the cert
    openssl x509 \
            -outform DER \
            -in "${CACERT}" \
            -outform DER \
            -in "${CACERT}" \
            -out "${CACERT_DER}"

    # Create a new secret containing private key
    CA_KEY_SECRET_NAME="efi-${EFI_VAR_NAME}-priv-key-${ITERATION}"
    gcloud secrets create "${CA_KEY_SECRET_NAME}" \
           --project="${PROJECT_ID}" \
           --replication-policy="automatic" \
           --data-file="${PRIVATE_KEY}"

    echo "Private key secret name: '${CA_KEY_SECRET_NAME}'"
    echo "${CA_KEY_SECRET_NAME}" > tls/private-key-secret-name.txt

    # Create a new secret containing public key
    CA_CERT_SECRET_NAME="efi-${EFI_VAR_NAME}-pub-key-${ITERATION}"
    cat "${CACERT_DER}" | base64 > "${CACERT_DER}.base64"
    gcloud secrets create "${CA_CERT_SECRET_NAME}" \
           --project="${PROJECT_ID}" \
           --replication-policy="automatic" \
           --data-file="${CACERT_DER}.base64"

    echo "Public key secret name: '${CA_CERT_SECRET_NAME}'"
    echo "${CA_CERT_SECRET_NAME}" > tls/public-key-secret-name.txt

}

EFI_VAR_NAME=db

create_key "${EFI_VAR_NAME}" "Cloud Dataproc Custom Image CA ${ITERATION}"
