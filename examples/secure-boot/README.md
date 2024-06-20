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
bash examples/secure-boot/create-key-pair.sh
private_secret_name=$(cat tls/private-key-secret-name.txt)
public_secret_name=$(cat tls/public-key-secret-name.txt)
secret_project="$(gcloud config get project)"
secret_version=1
custom_image_zone="$(gcloud config get compute/zone)"
my_bucket="$(gsutil ls | tail -1)"
echo "$0: remove this line, modify the my_bucket line and remove the sleep."
echo "default bucket is '${my_bucket}'.  Ctrl-C to select a better default"
sleep 10s
echo "you still have 20 seconds"
sleep 20s
gcloud auth login

metadata="public_secret_name=${public_secret_name}"
metadata="${metadata},private_secret_name=${private_secret_name}"
metadata="${metadata},secret_project=${secret_project}"
metadata="${metadata},secret_version=${secret_version}"

#dataproc_version=2.1-debian11
dataproc_version=2.2-debian12
customization_script=examples/secure-boot/install-nvidia-driver-debian11.sh
#customization_script=examples/secure-boot/install-nvidia-driver-debian12.sh
image_name="nvidia-open-kernel-bullseye"
#image_name="nvidia-open-kernel-bookworm"

python generate_custom_image.py \
    --image-name ${image_name} \
    --dataproc-version ${dataproc_version} \
    --trusted-cert "tls/db.der" \
    --customization-script ${customization_script} \
    --metadata "${metadata}" \
    --zone "${custom_image_zone}" \
    --shutdown-instance-timer-sec=900 \
    --gcs-bucket "${my_bucket}"
```




