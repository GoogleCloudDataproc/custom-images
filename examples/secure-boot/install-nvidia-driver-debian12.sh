#!/bin/bash
set -xeu

# read secret name, project, version 
sig_pub_secret_name="$(/usr/share/google/get_metadata_value attributes/public_secret_name)"
sig_priv_secret_name="$(/usr/share/google/get_metadata_value attributes/private_secret_name)"
sig_secret_project="$(/usr/share/google/get_metadata_value attributes/secret_project)"
sig_secret_version="$(/usr/share/google/get_metadata_value attributes/secret_version)"

readonly PUBLIC_SECRET_NAME=
readonly expected_modulus_md5sum="bd40cf5905c7bba4225d330136fdbfd3"

local ca_tmpdir
ca_tmpdir="$(mktemp -u -d -p /run/tmp -t ca_dir-XXXX)"
mkdir -p "${ca_tmpdir}"

# The Microsoft Corporation UEFI CA 2011                                                                                                                                                  
local ms_uefi_ca
ms_uefi_ca="${ca_tmpdir}/MicCorUEFCA2011_2011-06-27.crt"
if [[ ! -f "${ms_uefi_ca}" ]]; then
  curl -L -o "${ms_uefi_ca}" "https://go.microsoft.com/fwlink/p/?linkid=321194"
fi

# Write private material to volatile storage                                                                                                                                              
gcloud secrets versions access "${sig_secret_version}" \
       --project="${sig_secret_project}" \
       --secret="${sig_priv_secret_name}" \
    | dd of="${ca_tmpdir}/db.rsa"

local -r cacert_der="${ca_tmpdir}/db.der"
gcloud secrets versions access "${sig_secret_version}" \
       --project="${sig_secret_project}" \
       --secret="${sig_pub_secret_name}" \
    | base64 --decode \
    | dd of="${cacert_der}"

DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
COMPONENTS="main contrib non-free non-free-firmware"

mokutil --sb-state

# Prepare DKMS to use the certificates retrieved from cloud secrets
sudo ln -sf "${ca_tmpdir}/db.rsa" /var/lib/dkms/mok.key
sudo cp "${ca_tmpdir}/db.der" /var/lib/dkms/mok.pub

# enable non-free and non-free-firmware components, update cache,
# install kernel headers and dkms
sudo sed -i -e 's/Components: .*$/Components: ${COMPONENTS}/' ${DEBIAN_SOURCES}
sudo apt-get -qq update
sudo apt-get -qq -y install dkms linux-headers-\$(uname -r)

# Install nvidia-open-current module via DKMS
sudo apt-get -qq -y install nvidia-open-kernel-dkms
sudo modprobe nvidia-current-open
