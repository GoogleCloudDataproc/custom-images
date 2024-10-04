To generate a key pair for use with the custom image, run the
create-key-pair.sh script.  You can then specify the full path to
**tls/db.der** with the argument **--trusted-cert=.../tls/db.der**

Kernel drivers signed with the private side of this key pair can then
be loaded into kernels on systems with secure boot enabled.

To create a custom image with a self-signed, trusted certificate
inserted into the boot sector, and then run a script to install nvidia
kernel drivers on a Dataproc image, the following commands can be
run from the root of the custom-images git repository:

```bash
PROJECT_ID=your-project-here
CLUSTER_NAME=your-cluster-name-here
my_bucket=your-bucket-here
custom_image_zone=your-zone-here

export SA_NAME=sa-${CLUSTER_NAME}
export GSA=${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com

# Instructions for creating the service account can be found here:
# https://github.com/LLC-Technologies-Collier/dataproc-repro/blob/78945b5954ab47aac56f55ac22b3c35569d154e0/shared-functions.sh#L759
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	--member=serviceAccount:${GSA} \
	--role=roles/secretmanager.secretAccessor
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	--member=serviceAccount:${GSA} \
	--role=roles/secretmanager.viewer
gcloud config set project ${PROJECT_ID}

gcloud auth login

# variables *_secret_name_, secret_project, secret_version, modulus_md5sum defined here:
eval $(bash examples/secure-boot/create-key-pair.sh)
metadata="public_secret_name=${public_secret_name}"
metadata="${metadata},private_secret_name=${private_secret_name}"
metadata="${metadata},secret_project=${secret_project}"
metadata="${metadata},secret_version=${secret_version}"
metadata="${metadata},modulus_md5sum=${modulus_md5sum}"

dataproc_version=2.2-debian12
#dataproc_version=2.2-ubuntu22
#dataproc_version=2.2-rocky9
#customization_script=examples/secure-boot/install-nvidia-driver-debian11.sh
#customization_script=examples/secure-boot/install-nvidia-driver-debian12.sh
#customization_script="../initialization-actions/gpu/install_gpu_driver.sh"
echo "#!/bin/bash\necho no op" > empty.sh
customization_script=empty.sh
#image_name="nvidia-open-kernel-2.2-ubuntu22-$(date +%F)"
#image_name="nvidia-open-kernel-2.2-rocky9-$(date +%F)"
#image_name="nvidia-open-kernel-2.2-debian12-$(date +%F)"
#image_name="nvidia-open-kernel-${dataproc_version}-$(date +%F)"
image_name="custom-${dataproc_version/\./-}-$(date +%F)"
disk_size_gb="50"

python generate_custom_image.py \
    --image-name ${image_name} \
    --dataproc-version ${dataproc_version} \
    --trusted-cert "tls/db.der" \
    --customization-script ${customization_script} \
    --metadata "${metadata}" \
    --zone "${custom_image_zone}" \
    --disk-size "${disk_size_gb}" \
    --no-smoke-test \
    --gcs-bucket "${my_bucket}"
```




