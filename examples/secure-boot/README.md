# Dataproc Custom Images for Secure Boot with NVIDIA GPUs

This directory contains scripts to build Google Dataproc custom images compatible with GCP's Shielded VMs, enabling Secure Boot with custom-signed NVIDIA GPU drivers.

## Features

*   **Secure Boot Enabled:** Images are built with custom signing keys injected into the EFI signature database, allowing NVIDIA kernel modules to be loaded when Secure Boot is enabled on the cluster VMs.
*   **NVIDIA Driver Installation:** Installs NVIDIA drivers, CUDA, cuDNN, and NCCL, ensuring kernel modules are signed.
*   **Proxy Support:** Scripts include logic to configure the build environment to use an HTTP/S proxy for all egress traffic.
*   **Optional Software:** Supports pre-installing PyTorch, TensorFlow, RAPIDS, and Dask.

## Prerequisites

1.  **GCP Environment Provisioned:** This guide assumes you have a functional Google Cloud project with appropriate networking (VPC, subnets, firewall rules for SSH, and routes to your proxy if applicable), IAM permissions, and enabled APIs. For examples on how to set up such an environment, including private networks, please refer to the scripts available in the [GoogleCloudDataproc/cloud-dataproc repository](https://github.com/GoogleCloudDataproc/cloud-dataproc/tree/main/gcloud). See the `README.md` in that repository for more details. The [`bin/create-dpgce-private`](https://github.com/GoogleCloudDataproc/cloud-dataproc/blob/main/gcloud/bin/create-dpgce-private) script is particularly relevant for setting up a proxy-based environment.
2.  **gcloud CLI:** Authenticated and configured.
3.  **Podman:** Installed on the build machine.
4.  **jq:** Installed on the build machine.
5.  **Google Cloud Project:** With necessary APIs enabled (Compute Engine, Secret Manager, Cloud Storage).
6.  **Service Account:** The Compute Engine default service account for your project must have `roles/dataproc.worker`, `roles/storage.objectUser`, `roles/secretmanager.secretAccessor`, `roles/compute.instanceAdmin.v1`, and `roles/iam.serviceAccountUser`.
7.  **Proxy Server Details (if used):** Host, port, and optionally a CA certificate in GCS.

## Configuration (`env.json`)

1.  Copy `examples/secure-boot/env.json.sample` to `env.json` in the root of this repository.

    ```bash
    cp examples/secure-boot/env.json.sample env.json
    ```

2.  Edit `env.json` with your specific Google Cloud project details:

    ```json
    {
      "PROJECT_ID": "YOUR_GCP_PROJECT_ID",
      "REGION": "YOUR_GCP_REGION",
      "ZONE": "YOUR_GCP_ZONE",
      "SUBNET": "main-subnet",
      "CLUSTER_NAME": "proxy-env-setup",
      "PURPOSE": "gpu-sb-test",
      "BUCKET": "YOUR_GCS_BUCKET",
      "TEMP_BUCKET": "YOUR_GCS_TEMP_BUCKET",
      "RANGE": "10.10.0.0/24",
      "PRIVATE_RANGE": "10.11.0.0/24",
      "SWP_RANGE": "10.12.0.0/24",
      "SWP_IP": "10.11.0.250",
      "SWP_PORT": "3128",
      "SWP_HOSTNAME": "swp.your.domain.com",
      "PROXY_CERT_GCS_PATH": "gs://YOUR_PROXY_CERT_BUCKET/proxy.cer",
      "PRINCIPAL_USER": "YOUR_USERNAME",
      "DOMAIN": "example.com"
    }
    ```

    *   `SUBNET`: Must be the full resource path (e.g., `projects/PROJECT/regions/REGION/subnetworks/SUBNET_NAME`).

## Building Images

The primary method involves using Podman to create an isolated build environment.

1.  **Build Podman Image:**

    ```bash
    podman build -t dataproc-secure-boot-builder:latest .
    ```

2.  **Prepare Secure Boot Signing Keys:**
    Run this once to create/validate keys in Secret Manager:

    ```bash
    bash examples/secure-boot/create-key-pair.sh
    ```

### Example: Building a Single Image (No Proxy)

```bash
# In custom-images directory root
# Assumes env.json is configured

export DATAPROC_VERSION="2.2-debian12" # Or your desired version

podman run -it --rm \
  -v ~/.config/gcloud:/root/.config/gcloud \
  -v $(pwd)/env.json:/custom-images/env.json:ro \
  -v $(pwd)/tls:/custom-images/tls \
  dataproc-secure-boot-builder:latest \
  bash examples/secure-boot/pre-init.sh "${DATAPROC_VERSION}"
```

### Example: Building a Single Image WITH Proxy

This example uses the `build-and-run-podman.sh` script, which incorporates the proxy settings from `env.json` automatically.

```bash
# Ensure your env.json is correctly configured with PROJECT_ID, ZONE, BUCKET, SUBNET,
# and all SWP_* fields, including PROXY_CERT_GCS_PATH if needed.

bash examples/secure-boot/build-and-run-podman.sh 2.2-debian12
```

### Example: Building Multiple Image Variants

To build all versions defined in `examples/secure-boot/pre-init.screenrc`:

```bash
# Configure env.json first
podman run -it --rm \
  -v ~/.config/gcloud:/root/.config/gcloud \
  -v $(pwd)/env.json:/custom-images/env.json:ro \
  -v $(pwd)/tls:/custom-images/tls \
  dataproc-secure-boot-builder:latest \
  bash examples/secure-boot/build-current-images.sh
```

*   Note: The `build-current-images.sh` script internally calls `pre-init.sh`. Since `pre-init.sh` now automatically includes proxy metadata from `env.json`, this multi-build will also work in a proxied environment, assuming `env.json` is fully configured.

## Using the Custom Images

To run Dataproc clusters with NVIDIA GPUs and Shielded VM Secure Boot enabled, you **must** use a custom image built with this process. Standard Dataproc images do not have NVIDIA kernel modules signed with keys recognized by the Secure Boot process.

The custom images produced by the scripts in this directory have:

1.  A custom signing key (DB key) injected into the image's EFI firmware.
2.  The NVIDIA kernel modules compiled and signed with this custom key during the image build process.

This allows the kernel to load the NVIDIA drivers even when Secure Boot is active, as the signatures are trusted.

**Cluster Creation Command:**

```bash
# !!! REPLACE THESE WITH YOUR VALUES !!!
export CLUSTER_NAME="gpu-proxy-cluster"
export REGION="YOUR_GCP_REGION" # e.g., us-central1
export CUSTOM_IMAGE_NAME="YOUR_BUILT_IMAGE_NAME" # e.g., dataproc-22-deb12-202601231530-gpu-proxy-test
export GCP_PROJECT=$(jq -r .PROJECT_ID env.json)
export BUILD_ZONE=$(jq -r .ZONE env.json)
export ACCELERATOR_TYPE="nvidia-tesla-t4"

gcloud dataproc clusters create "${CLUSTER_NAME}" \
    --project "${GCP_PROJECT}" \
    --region "${REGION}" \
    --zone "${BUILD_ZONE}" \
    --image "${CUSTOM_IMAGE_NAME}" \
    --master-machine-type n1-standard-4 \
    --worker-machine-type n1-standard-4 \
    --num-workers 0 \
    --accelerator "type=${ACCELERATOR_TYPE},count=1" \
    --shielded-secure-boot \
    --properties dataproc:dataproc.conscrypt.provider.enable=false
```

Using `--shielded-secure-boot` without an image prepared as described will result in the NVIDIA drivers failing to load.

## Verification

1.  SSH into the -m node:

    ```bash
    gcloud compute ssh "${CLUSTER_NAME}-m" --project "${GCP_PROJECT}" --zone "${BUILD_ZONE}"
    ```

2.  Check NVIDIA driver:

    ```bash
    nvidia-smi
    ```

3.  Verify module signature:

    ```bash
    sudo modinfo nvidia | grep signer
    ```

    Expected output includes: `signer:         Cloud Dataproc Custom Image CA`

## Key Scripts Involved

*   `env.json.sample`: Template for environment configuration.
*   `create-key-pair.sh`: Manages Secure Boot signing keys in Secret Manager.
*   `build-current-images.sh`: Orchestrates builds for multiple versions.
*   `pre-init.sh`: Sets up parameters and calls `generate_custom_image.py`, now includes proxy metadata from `env.json`.
*   `generate_custom_image.py`: Main Python script for image creation.
*   `install_gpu_driver.sh`: Core script for NVIDIA driver and software installation, includes proxy setup logic.
*   `gce-proxy-setup.sh`: Called by `install_gpu_driver.sh` to configure proxy settings within the build VM.
*   `build-and-run-podman.sh`: Wrapper script to run the build process within a Podman container.

## Additional Cluster Management Scripts

For more advanced Dataproc cluster creation and management, including setting up private networks, VPC-SC, or different cluster types, you may find the scripts in the [GoogleCloudDataproc/cloud-dataproc](https://github.com/GoogleCloudDataproc/cloud-dataproc) repository useful.

That repository contains a `gcloud` directory with various shell scripts in `bin/` and library functions in `lib/` to aid in:

*   Creating clusters with specific network configurations (e.g., `bin/create-dpgce-private`).
*   Managing firewalls and routes.
*   Setting up Kerberos or other security features.
*   Testing connectivity.

These scripts are complementary to the image building process detailed here and can be used to provision the infrastructure where your custom images will run.

## Known Issues

*   Dataproc 2.0 images (Rocky 8, Ubuntu 18) may fail to build in proxy environments due to Conda/Mamba network issues.
*   Module loading errors on the cluster (e.g., `Operation not permitted`) after a successful build usually indicate a problem with the Secure Boot key enrollment (MOK), even if the modules appear signed.