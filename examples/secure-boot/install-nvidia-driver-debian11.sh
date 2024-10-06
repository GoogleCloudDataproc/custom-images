#!/bin/bash
set -xeu

WORKDIR=/opt/install-nvidia-driver
mkdir -p ${WORKDIR}
cd $_

nv_driver_ver="550.54.14"
nv_cuda_ver="12.4.0"

# read secret name, project, version
sig_pub_secret_name="$(/usr/share/google/get_metadata_value attributes/public_secret_name)"
sig_priv_secret_name="$(/usr/share/google/get_metadata_value attributes/private_secret_name)"
sig_secret_project="$(/usr/share/google/get_metadata_value attributes/secret_project)"
sig_secret_version="$(/usr/share/google/get_metadata_value attributes/secret_version)"
expected_modulus_md5sum="$(/usr/share/google/get_metadata_value attributes/modulus_md5sum)"
readonly expected_modulus_md5sum

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

mokutil --sb-state

# configure the nvidia-container-toolkit package source
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# add non-free components
sed -i -e 's/ main$/ main contrib non-free/' /etc/apt/sources.list

# update package cache
apt-get update -qq

# install nvidia-container-toolkit and kernel headers
apt-get --no-install-recommends -qq -y install \
     nvidia-container-toolkit \
     "linux-headers-$(uname -r)"

apt-get clean
apt-get autoremove -y

# fetch .run file
curl -o driver.run \
  "https://download.nvidia.com/XFree86/Linux-x86_64/${nv_driver_ver}/NVIDIA-Linux-x86_64-${nv_driver_ver}.run"
# Install all but kernel driver
bash driver.run --no-kernel-modules --silent --install-libglvnd
rm driver.run

# Fetch open souce kernel module with corresponding tag
git clone https://github.com/NVIDIA/open-gpu-kernel-modules.git --branch "${nv_driver_ver}" --single-branch
cd ${WORKDIR}/open-gpu-kernel-modules
#
# build kernel modules
#
make -j$(nproc) modules > /var/log/open-gpu-kernel-modules-build.log
# sign
for module in $(find kernel-open -name '*.ko'); do
    /lib/modules/$(uname -r)/build/scripts/sign-file sha256 \
      "${ca_tmpdir}/db.rsa" \
      "${ca_tmpdir}/db.der" \
      "${module}"
done
# install
make modules_install >> /var/log/open-gpu-kernel-modules-build.log
# rebuilt module index
depmod -a
cd ${WORKDIR}

#
# Install CUDA
#
cuda_runfile="cuda_${nv_cuda_ver}_${nv_driver_ver}_linux.run"
curl -fsSL --retry-connrefused --retry 10 --retry-max-time 30 \
     "https://developer.download.nvidia.com/compute/cuda/${nv_cuda_ver}/local_installers/${cuda_runfile}" \
     -o cuda.run
bash cuda.run --silent --toolkit --no-opengl-libs
rm cuda.run
