#!/bin/bash

# Copyright 2024, Google LLC

set -x
set -e

# Set the following variables to something that reflects a realistic environment:
ZONE="us-central1-f"
PROJECT_ID="${USER}-project-$(date +%F)"
REALM="boston.engineering.example.com"

# https://github.com/glevand/secure-boot-utils

# https://cloud.google.com/compute/shielded-vm/docs/creating-shielded-images#adding-shielded-image

# https://cloud.google.com/compute/shielded-vm/docs/creating-shielded-images#generating-security-keys-certificates

# https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#Creating_keys

ITERATION=0

function create_key () {
    local CN_VAL="$1"

    if [[ -f "tls/db.rsa" ]]; then
	echo "key exists"
	return
    fi
    mkdir -p tls

    local PRIVATE_KEY="tls/db.rsa"
    local CACERT="tls/db.pem"
    local CACERT_DER="tls/db.der"

    echo "generating ${CN_VAL} ${CACERT}, ${CACERT_DER} and ${PRIVATE_KEY}"
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
	    -out "${CACERT_DER}"

    # Create a new secret containing private key
    gcloud secrets create "efi-db-priv-key-${USER}" \
	   --project="${PROJECT_ID}" \
	   --replication-policy="automatic" \
	   --data-file="${PRIVATE_KEY}"

    # Create a new secret containing public key
    cat "${CACERT_DER}" | base64 > "${CACERT_DER}.base64"
    gcloud secrets create "efi-db-pub-key-${USER}" \
	   --project="${PROJECT_ID}" \
	   --replication-policy="automatic" \
	   --data-file="${CACERT_DER}.base64"

    # Create a new secret containing public key (pem)
    gcloud secrets create "efi-db-pem-key-${USER}" \
	   --project="${PROJECT_ID}" \
	   --replication-policy="automatic" \
	   --data-file="${CACERT}"
}

gcloud config set account ${USER}@${REALM}

create_key "Signature Database Key"


# gcloud compute images list --format json | jq > image-list-$(date +%F).json
# https://www.googleapis.com/compute/v1/projects/debian-cloud/global/images/debian-12-bookworm-v20240617

#SOURCE_IMAGE="debian-12-bookworm-v20240110"
#SOURCE_IMAGE="debian-12-bookworm-v20240515"
SOURCE_IMAGE="debian-12-bookworm-v20240617"
IMAGE_WITH_CERTS="${SOURCE_IMAGE}-with-cert-db-${USER}"

TMPDIR=$(mktemp -d)
mkdir "${TMPDIR}/tls"
CA_TMPDIR="${TMPDIR}/tls"

sig_priv_secret_name="efi-db-priv-key-${USER}"
sig_pub_secret_name="efi-db-pub-key-${USER}"
sig_secret_project="${PROJECT_ID}"
sig_secret_version=1

gcloud secrets versions access "${sig_secret_version}" \
       --project="${sig_secret_project}" \
       --secret="${sig_pub_secret_name}" \
    | base64 --decode \
    | dd of="${CA_TMPDIR}/db.der"

gcloud secrets versions access "${sig_secret_version}" \
       --project="${sig_secret_project}" \
       --secret="${sig_priv_secret_name}" \
    | dd of="${CA_TMPDIR}/db.rsa"

if ( gcloud compute images describe ${IMAGE_WITH_CERTS} > /dev/null 2>&1 ) ; then
    echo "image ${IMAGE_WITH_CERTS} already exists"
else

    # The Microsoft Corporation UEFI CA 2011
    MS_UEFI_CA="tls/MicCorUEFCA2011_2011-06-27.crt"
    test -f "${MS_UEFI_CA}" || \
	curl -L -o ${MS_UEFI_CA} 'https://go.microsoft.com/fwlink/p/?linkid=321194'

    gcloud compute images create "${IMAGE_WITH_CERTS}" \
       --source-image "${SOURCE_IMAGE}" \
       --source-image-project debian-cloud \
       --signature-database-file="${CA_TMPDIR}/db.der,${MS_UEFI_CA}" \
       --guest-os-features="UEFI_COMPATIBLE"
fi

# Everything below here can be done with the custom image script.  I
# will make that change in a future commit


# boot a VM with this image
MACHINE_TYPE=n1-standard-8
INSTANCE_NAME="${USER}-secure-boot-$(date +%F)"
if ( gcloud compute instances describe "${INSTANCE_NAME}" > /dev/null 2>&1 ) ; then
    echo "instance ${INSTANCE_NAME} already online"
else 
    gcloud compute instances create "${INSTANCE_NAME}" \
	   --machine-type=${MACHINE_TYPE} \
	   --maintenance-policy TERMINATE \
	   --shielded-secure-boot \
	   --accelerator=type=nvidia-tesla-t4 \
	   --zone=us-central1-f \
	   --image-project ${PROJECT_ID} \
	   --image="${IMAGE_WITH_CERTS}"

    sleep 45
fi

gcloud compute \
       scp --recurse "${TMPDIR}/tls" \
       --zone us-central1-f \
       "${INSTANCE_NAME}:/tmp" \
       --project "${PROJECT_ID}" \
       --tunnel-through-iap

rm -rf "${TMPDIR}"

# https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot
# bootctl
# od --address-radix=n --format=u1 /sys/firmware/efi/efivars/SecureBoot-*
#    6   0   0   0   1
# for var in PK KEK db dbx ; do efi-readvar -v $var -o old_${var}.esl ; done

# Verify cert was installed:
# sudo apt-get install efitools
# sudo efi-readvar -v db
DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
COMPONENTS="main contrib non-free non-free-firmware"
gcloud compute ssh \
       --zone us-central1-f \
       "${INSTANCE_NAME}" \
       --project "${PROJECT_ID}" \
       --tunnel-through-iap \
       --command "
       mokutil --sb-state
       sudo sed -i -e 's/Components: .*$/Components: ${COMPONENTS}/' ${DEBIAN_SOURCES} && echo 'sources updated' &&
       sudo apt-get -qq update && echo 'package cache updated' &&
       sudo apt-get -qq -y install dkms linux-headers-\$(uname -r) > /dev/null 2>&1 && echo 'dkms and kernel headers installed' &&
       sudo cp /tmp/tls/db.rsa /var/lib/dkms/mok.key &&
       sudo cp /tmp/tls/db.der /var/lib/dkms/mok.pub &&
       echo 'mok files created' &&
       sudo apt-get -qq -y install nvidia-open-kernel-dkms && echo 'nvidia open kernel package built' &&
       sudo modprobe nvidia-current-open &&
       echo 'kernel module loaded'"

set +x
