#!/bin/bash
set -xeu

# read secret name, project, version
sig_pub_secret_name="$(/usr/share/google/get_metadata_value attributes/public_secret_name)"
sig_priv_secret_name="$(/usr/share/google/get_metadata_value attributes/private_secret_name)"
sig_secret_project="$(/usr/share/google/get_metadata_value attributes/secret_project)"
sig_secret_version="$(/usr/share/google/get_metadata_value attributes/secret_version)"

readonly expected_modulus_md5sum="bd40cf5905c7bba4225d330136fdbfd3"

ca_tmpdir="$(mktemp -u -d -p /run/tmp -t ca_dir-XXXX)"
mkdir -p "${ca_tmpdir}"

# The Microsoft Corporation UEFI CA 2011
ms_uefi_ca="${ca_tmpdir}/MicCorUEFCA2011_2011-06-27.crt"
if [[ ! -f "${ms_uefi_ca}" ]]; then
  curl -L -o "${ms_uefi_ca}" "https://go.microsoft.com/fwlink/p/?linkid=321194"
fi

# Write private material to volatile storage
gcloud secrets versions access "${sig_secret_version}" \
       --project="${sig_secret_project}" \
       --secret="${sig_priv_secret_name}" \
    | dd of="${ca_tmpdir}/db.rsa"

readonly cacert_der="${ca_tmpdir}/db.der"
gcloud secrets versions access "${sig_secret_version}" \
       --project="${sig_secret_project}" \
       --secret="${sig_pub_secret_name}" \
    | base64 --decode \
    | dd of="${cacert_der}"

DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
COMPONENTS="main contrib non-free non-free-firmware"

mokutil --sb-state

# configure the nvidia-container-toolkit package source
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# enable non-free and non-free-firmware components, update cache
sed -i -e "s/Components: .*$/Components: ${COMPONENTS}/" ${DEBIAN_SOURCES}
apt-get -qq update

# install DKMS
apt-get --no-install-recommends -qq -y install dkms

# Prepare DKMS to use the certificates retrieved from cloud secrets
ln -sf "${ca_tmpdir}/db.rsa" /var/lib/dkms/mok.key
cp "${ca_tmpdir}/db.der" /var/lib/dkms/mok.pub

# install dkms and nvidia packages
apt-get --no-install-recommends -qq -y install \
     dkms \
     "linux-headers-$(uname -r)" \
     nvidia-container-toolkit \
     nvidia-open-kernel-dkms \
     nvidia-open-kernel-support \
     nvidia-smi \
     libglvnd0 \
     libcuda1

# Insert the symbols into the kernel's memory
modprobe nvidia-current-open
