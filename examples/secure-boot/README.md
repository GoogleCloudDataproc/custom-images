# Dataproc Custom Images for Secure Boot with NVIDIA GPUs

This directory contains scripts to build Google Dataproc custom images compatible with GCP's Shielded VMs, enabling Secure Boot with custom-signed NVIDIA GPU drivers.

## Features

*   **Secure Boot Enabled:** Images are built with custom signing keys injected into the EFI signature database, allowing NVIDIA kernel modules to be loaded when Secure Boot is enabled on the cluster VMs.
*   **NVIDIA Driver Installation:** Installs NVIDIA drivers, CUDA, cuDNN, and NCCL, ensuring kernel modules are signed.
*   **Proxy Support:** Scripts configure the build environment and can configure cluster nodes to use an HTTP/S proxy for all egress traffic.
*   **Optional Software:** Supports pre-installing PyTorch, TensorFlow, RAPIDS, and Dask.

## Prerequisites

1.  **GCP Project:** With necessary APIs enabled (Compute Engine, Secret Manager, Cloud Storage, Artifact Registry).
2.  **gcloud CLI:** Authenticated and configured.
3.  **Podman & jq:** Installed on the build machine.
4.  **Service Account Permissions:** The Compute Engine default service account for your project must have `roles/dataproc.worker`, `roles/storage.objectUser`, `roles/secretmanager.secretAccessor`, `roles/compute.instanceAdmin.v1`, and `roles/iam.serviceAccountUser`.

## Configuration (`env.json`)

A single `env.json` file in the root of the `custom-images` repository is used to configure both the network/proxy environment setup and the image building process.

1.  **Clone Repositories:** You need both forks for the complete setup:
    ```bash
    git clone https://github.com/LLC-Technologies-Collier/cloud-dataproc.git
    git clone https://github.com/LLC-Technologies-Collier/custom-images.git
    cd cloud-dataproc
    git checkout proxy-sync-2026-01
    cd ../custom-images
    git checkout proxy-exercise-2025-11
    ```

2.  **Create and Edit `env.json`:**
    ```bash
    # Inside custom-images directory
    cp examples/secure-boot/env.json.sample env.json
    ```
    Edit `custom-images/env.json` with your project, region, zone, subnet, bucket details, AND your proxy settings (`SWP_IP`, `SWP_PORT`, `PROXY_CERT_GCS_PATH`).

3.  **Provision GCP Network & Proxy Resources:** This uses scripts from the `cloud-dataproc` repository, which will read the `env.json` from the `custom-images` directory via a symlink.
    ```bash
    cd ../cloud-dataproc/gcloud
    ln -sf ../../custom-images/env.json env.json
    bash bin/create-dpgce-private --no-create-cluster
    cd ../../custom-images
    ```

### Network and Proxy Prerequisites

If you intend to build images that will run in a proxy-only environment, you **must** first provision the necessary GCP network resources, including the Secure Web Proxy (SWP). This is done using the scripts in the `GoogleCloudDataproc/cloud-dataproc` repository, specifically `bin/create-dpgce-private`.

Assuming you have cloned both repositories and configured `env.json` as described above, run the network creation script:

```bash
# From the custom-images directory
cd ../cloud-dataproc/gcloud
ln -sf ../../custom-images/env.json env.json
bash bin/create-dpgce-private --no-create-cluster
cd ../../custom-images
```
This sets up the VPC, subnets, SWP, certificates, and firewall rules. The `build-and-run-podman.sh` script relies on this infrastructure being in place for builds requiring proxy access.

## Building Images with Podman

The `examples/secure-boot/build-and-run-podman.sh` script is the main entry point for building the Secure Boot enabled custom images for a *single* Dataproc version. This script automates the setup and execution, simplifying the process.

**Key tasks performed by `build-and-run-podman.sh`:**

1.  **Service Account & IAM:** Configures the Google Service Account specified in `env.json` and binds necessary IAM roles for image building, secret access, and compute instance administration.
2.  **Service Account Key:** Generates a temporary `key.json` for the service account to be used within the container.
3.  **Secure Boot Keys:** Ensures Secure Boot signing keys are created and available in Google Secret Manager using `examples/secure-boot/create-key-pair.sh`.
4.  **Podman Image Build:** Builds the `custom-images-builder:latest` container image using the project's Dockerfile.
5.  **Container Execution:** Runs the `custom-images-builder` container, mounting necessary volumes (including the SA key) and setting environment variables.
6.  **Image Generation:** Executes `examples/secure-boot/pre-init.sh` inside the container with the specified Dataproc version. This will generate the layered Dataproc custom images (`secure-boot`, `secure-proxy`, `tf`, `proxy-tf`) for that single version.

**Steps:**

1.  **Ensure Prerequisites:** Confirm you have `podman`, `jq`, and authenticated `gcloud` on your host machine.
2.  **Configure `env.json`:** Make sure your `custom-images/env.json` is correctly filled out with your project, region, zone, subnet, GSA, and proxy details (`SWP_IP`, etc.).
3.  **Run the Build Script:**
    *   **Specific Dataproc Version:** To build images for a specific Dataproc version (e.g., 2.3-debian12):
        ```bash
        bash examples/secure-boot/build-and-run-podman.sh 2.3-debian12
        ```
    *   **Default Version:** If no version is provided, it defaults to `2.2-debian12`:
        ```bash
        bash examples/secure-boot/build-and-run-podman.sh
        ```

The script will output the names of the generated images. Look for the image ending in `-proxy-tf` for use in proxy-only environments.

## Understanding Image Targets

The build process creates layered images. The key ones for this solution are:

*   `...-secure-boot`: Base image with Secure Boot keys enrolled.
*   `...-secure-proxy`: Based on `secure-boot`, with OS-level proxy settings applied using `gce-proxy-setup.sh` during the image build. This image is designed to have proxy settings baked in.
*   `...-tf`: Based on `secure-boot`, with NVIDIA drivers and ML libraries installed. This image does *not* have persistent proxy settings baked in.
*   `...-proxy-tf`: Based on `secure-proxy`, with NVIDIA drivers and ML libraries installed. This image *does* have persistent proxy settings baked in, inherited from `secure-proxy`.

**Which Image to Use:**

*   **For proxy-only environments:** Use the image ending in `-proxy-tf`. This image is designed to work without requiring the `startup-script-url` metadata for proxy setup at cluster creation time.
*   **For environments without a strict proxy:** You could use the `-tf` image, but would need to ensure the nodes have internet access or provide proxy details via metadata at runtime if needed.

## Using the Custom Images

To run Dataproc clusters with NVIDIA GPUs and Shielded VM Secure Boot enabled:

1.  **Identify Custom Image Name:** Note the image name output by the build script. For a proxied environment, this should be like `dataproc-22-deb12-YYYYMMDDHHMM-proxy-tf`.

2.  **Create Cluster (Option 1: Using `-proxy-tf` Image with Baked-in Proxy):**
    ```bash
    export CLUSTER_NAME="your-cluster-name"
    export REGION="$(jq -r .REGION env.json)"
    export CUSTOM_IMAGE_NAME="<your-built-proxy-tf-image-name>"
    export GCP_PROJECT=$(jq -r .PROJECT_ID env.json)
    export BUILD_ZONE=$(jq -r .ZONE env.json)
    export ACCELERATOR_TYPE="nvidia-tesla-t4"
    export SUBNET=$(jq -r .SUBNET env.json)

    gcloud dataproc clusters create "${CLUSTER_NAME}" \
        --project "${GCP_PROJECT}" \
        --region "${REGION}" \
        --zone "${BUILD_ZONE}" \
        --subnet "${SUBNET}" \
        --image "${CUSTOM_IMAGE_NAME}" \
        --master-machine-type n1-standard-4 \
        --num-workers 0 \
        --accelerator "type=${ACCELERATOR_TYPE},count=1" \
        --shielded-secure-boot \
        --properties dataproc:dataproc.conscrypt.provider.enable=false
    ```
    *   Note: No explicit proxy metadata or startup script is needed here, as the settings are in the image.

3.  **Create Cluster (Option 2: Using `-tf` Image with Runtime Proxy Metadata):**
    ```bash
    export CLUSTER_NAME="your-cluster-name"
    export REGION="$(jq -r .REGION env.json)"
    export CUSTOM_IMAGE_NAME="<your-built-tf-image-name>"
    export GCP_PROJECT=$(jq -r .PROJECT_ID env.json)
    export BUILD_ZONE=$(jq -r .ZONE env.json)
    export ACCELERATOR_TYPE="nvidia-tesla-t4"
    export SUBNET=$(jq -r .SUBNET env.json)

    # IMPORTANT: METADATA FOR PROXY SETUP ON CLUSTER NODES
    PROXY_METADATA=""
    if [[ -n "$(jq -r .SWP_IP env.json)" && "$(jq -r .SWP_IP env.json)" != "null" ]]    then
      PROXY_ADDR="$(jq -r .SWP_IP env.json):$(jq -r .SWP_PORT env.json)"
      PROXY_METADATA="http-proxy=${PROXY_ADDR}"
      PROXY_CERT_PATH="$(jq -r .PROXY_CERT_GCS_PATH env.json)"
      if [[ -n "${PROXY_CERT_PATH}" && "${PROXY_CERT_PATH}" != "null" ]]      then
        PROXY_METADATA="${PROXY_METADATA},http-proxy-pem-uri=${PROXY_CERT_PATH}"
      fi
    fi

    GCS_STARTUP_SCRIPT="gs://$(jq -r .BUCKET env.json)/custom-image-deps/gce-proxy-setup.sh"
    # Ensure gce-proxy-setup.sh is uploaded:
    # gsutil cp startup_script/gce-proxy-setup.sh gs://$(jq -r .BUCKET env.json)/custom-image-deps/

    gcloud dataproc clusters create "${CLUSTER_NAME}" \
        --project "${GCP_PROJECT}" \
        --region "${REGION}" \
        --zone "${BUILD_ZONE}" \
        --subnet "${SUBNET}" \
        --image "${CUSTOM_IMAGE_NAME}" \
        --master-machine-type n1-standard-4 \
        --num-workers 0 \
        --accelerator "type=${ACCELERATOR_TYPE},count=1" \
        --shielded-secure-boot \
        --properties dataproc:dataproc.conscrypt.provider.enable=false \
        ${PROXY_METADATA:+"--metadata=${PROXY_METADATA}," startup-script-url=${GCS_STARTUP_SCRIPT}
    ```
    *   `--shielded-secure-boot`: Enables Secure Boot.
    *   `--metadata=startup-script-url=.../gce-proxy-setup.sh`: **Essential** for runtime proxy configuration when using the `-tf` image.

## Verification
    export CLUSTER_NAME="your-cluster-name"
    export REGION="$(jq -r .REGION env.json)"
    export CUSTOM_IMAGE_NAME="<your-built-image-name>"
    export GCP_PROJECT=$(jq -r .PROJECT_ID env.json)
    export BUILD_ZONE=$(jq -r .ZONE env.json)
    export ACCELERATOR_TYPE="nvidia-tesla-t4"
    export SUBNET=$(jq -r .SUBNET env.json)

    # IMPORTANT: METADATA FOR PROXY SETUP ON CLUSTER NODES
    PROXY_METADATA=""
    if [[ -n "$(jq -r .SWP_IP env.json)" && "$(jq -r .SWP_IP env.json)" != "null" ]]
    then
      PROXY_ADDR="$(jq -r .SWP_IP env.json):$(jq -r .SWP_PORT env.json)"
      PROXY_METADATA="http-proxy=${PROXY_ADDR}"
      PROXY_CERT_PATH="$(jq -r .PROXY_CERT_GCS_PATH env.json)"
      if [[ -n "${PROXY_CERT_PATH}" && "${PROXY_CERT_PATH}" != "null" ]]
      then
        PROXY_METADATA="${PROXY_METADATA},http-proxy-pem-uri=${PROXY_CERT_PATH}"
      fi
    fi

    gcloud dataproc clusters create "${CLUSTER_NAME}" \
        --project "${GCP_PROJECT}" \
        --region "${REGION}" \
        --zone "${BUILD_ZONE}" \
        --subnet "${SUBNET}" \
        --image "${CUSTOM_IMAGE_NAME}" \
        --master-machine-type n1-standard-4 \
        --num-workers 0 \
        --accelerator "type=${ACCELERATOR_TYPE},count=1" \
        --shielded-secure-boot \
        --properties dataproc:dataproc.conscrypt.provider.enable=false \
        ${PROXY_METADATA:+"--metadata=${PROXY_METADATA}"} \
        --metadata=startup-script-url=gs://$(jq -r .BUCKET env.json)/custom-image-deps/gce-proxy-setup.sh
    ```
    *   `--shielded-secure-boot`: Enables Secure Boot.
    *   `--metadata=startup-script-url=.../gce-proxy-setup.sh`: **Essential** for proxied environments. This ensures the cluster nodes also get the OS-level proxy settings on boot. You must upload `startup_script/gce-proxy-setup.sh` to your bucket.
        ```bash
        gsutil cp startup_script/gce-proxy-setup.sh gs://$(jq -r .BUCKET env.json)/custom-image-deps/
        ```
    *   The `${PROXY_METADATA:+...}` part conditionally adds the proxy metadata flags if SWP_IP is set in `env.json`.

## Verification

1.  **SSH into the -m node:**
    ```bash
    # From cloud-dataproc/gcloud directory
    bash bin/ssh-m ${CLUSTER_NAME}
    # OR directly:
    # gcloud compute ssh "${CLUSTER_NAME}-m" --project "${GCP_PROJECT}" --zone "${BUILD_ZONE}"
    ```

2.  **Check NVIDIA driver:** `nvidia-smi`
3.  **Verify module signature:** `sudo modinfo nvidia | grep signer` (Expected: `Cloud Dataproc Custom Image CA`)
4.  **Check dmesg:** `dmesg | grep -iE "Secure Boot|NVRM|nvidia"`

## Manual Customization & Interactive Debugging

For complex troubleshooting, hot-patching, or script development, developers can bypass the automated containerized pipeline and run an **idempotent, interactive debugging loop** from their workstation.

This workflow is orchestrated by a single, powerful workstation-side script: **`customize-in-screen.sh`**.

### 1. Configure the Target
In `custom-images/env.json`, configure the target Dataproc version and the script you wish to test/debug:
```json
{
  "IMAGE_VERSION": "2.1-debian11",
  "CUSTOMIZATION_SCRIPT": "examples/secure-boot/no-customization.sh"
}
```

### 2. Run the Idempotent Customizer
From the `custom-images` directory on your workstation, execute the orchestrator:
```bash
bash examples/secure-boot/bin/customize-in-screen.sh
```

**How it behaves (Idempotency in Action)**:
*   **First-Time Run (Cold Start)**: If the debug VM does not exist, it automatically calls `create-debug-vm.sh` to provision a raw, persistent VM (configured with a 24-hour shutdown timer and no automated startup script). It syncs your local code to GCS, triggers a remote background launch of `install-in-screen.sh`, and instantly attaches your terminal to the live screen session.
*   **Subsequent Runs (Warm Start / Re-use)**: If the VM is already online, **it bypasses GCE provisioning entirely!** It instantly uploads your latest local edits to GCS, SSHes into the VM, downloads the new scripts, restarts the customization inside a detached `screen` session, and attaches your terminal. **Time to execution is under 5 seconds.**
*   **Re-attaching to a Live Build**: If you run the script while a customization build is *already active* on the VM, it detects the running session, bypasses launching, and **instantly attaches your terminal to the live build.**

### 3. Interactive Attachment & Control
Once attached, you are inside a live, interactive `screen` session on the VM:
*   **Real-Time Debugging**: You can watch the compilation, press `Ctrl+C` to halt, edit files locally in `/tmp/sources/` on the VM, and manually re-run steps to test fixes.
*   **Safe Detachment**: To detach from the screen session and leave it running in the background on the VM (allowing you to close your laptop or disconnect), press:
    `Ctrl+A` followed by `D`.
*   **Re-attaching**: To re-attach later, simply run `bash examples/secure-boot/bin/customize-in-screen.sh` again from your workstation.

### 4. Run Workstation-Side Diagnostics
While the customization is running (or after a failure), you can audit the VM's active network and proxy state with a single command from your workstation terminal:
```bash
bash examples/secure-boot/audit-image-customizer.sh
```
This remote prober connects via IAP SSH in non-interactive batch mode and prints a pretty-printed JSON **System Audit Report** showing GCS and external network connectivity (verifying if Private Google Access and the SWP proxy are routing correctly).

### 5. Cleanup
Once debugging is complete, delete the GCE VM and clean up the GCS staging assets:
```bash
bash examples/secure-boot/bin/destroy-debug-vm.sh
```

## Key Scripts Involved

*   `custom-images/env.json`: Single source of truth for configuration.
*   `custom-images/examples/secure-boot/create-key-pair.sh`: Manages Secure Boot signing keys.
*   `initialization-actions/gpu/install_gpu_driver.sh`: Installs and signs NVIDIA components.
*   `custom-images/startup_script/gce-proxy-setup.sh`: Configures OS proxy settings (used in image build and on cluster boot).
*   `custom-images/examples/secure-boot/build-and-run-podman.sh`: Main build orchestrator.
*   `cloud-dataproc/gcloud/bin/create-dpgce-private`: Sets up the network and proxy infrastructure.
