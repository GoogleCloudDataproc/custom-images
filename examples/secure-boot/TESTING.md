# Testing & Validating Secure Boot Custom Images

This document outlines the verification steps to confirm that your custom pre-baked GCE images have successfully enrolled your UEFI certificates, compiled/signed kernel modules, and provisioned clusters under active Shielded VM Secure Boot constraints.

---

## Verification Workflow

To validate a newly built custom image (e.g., `dataproc-2-2-deb12-YYYYMMDD-HHMM-tf`), execute the following steps:

### 1. Provision the Test Cluster
Deploy a fresh Dataproc cluster from your custom image by enabling both `--custom` and `--gpu` flags on the recreation script:
```bash
# From cloud-dataproc/gcloud directory
./bin/recreate-dpgce --custom --gpu
```
*   `--custom`: Automatically instructs GCE to boot the nodes from your `CUSTOM_IMAGE_URI` defined in `env.json` and binds the Shielded VM verification hardware flags (`--shielded-secure-boot`).
*   `--gpu`: Attaches physical GPUs and runs the initialization validation checks.

### 2. SSH into the -m Node
Once the cluster creation operation returns SUCCESS, establish an IAP SSH connection to the master instance:
```bash
./bin/ssh-m
```

### 3. Verify NVIDIA Driver Load
Ensure the NVIDIA drivers are fully active and querying resources on the PCIe bus:
```bash
nvidia-smi
```
*   If the drivers are loaded and display your GPU device list, the kernel modules have bypassed Secure Boot block checks successfully!

### 4. Check UEFI Module Signature
Confirm that the running NVIDIA kernel module was custom-signed by your generated UEFI key pair during the image pre-bake layer build:
```bash
sudo modinfo nvidia | grep signer
```
*   **Expected Output:**
    ```
    signer:         Cloud Dataproc Custom Image CA
    ```
*   If the signer displays `Cloud Dataproc Custom Image CA`, the module was signed inline using your local GSA keys and verified by the enrolled UEFI certificates in the GCE Signature Database (`db`).

### 5. Audit Kernel Logs for Secure Boot Events
Audit `dmesg` events to verify that the hypervisor booted the Linux kernel under active UEFI hardware enforcement:
```bash
dmesg | grep -iE "Secure Boot|NVRM|nvidia"
```
*   Verify that the logs state `Secure Boot Enabled` and no module load denials or taint errors are present.

---

## Measured Custom Image Build Timing Reference

The following table lists the empirical, real-world durations of the various image building and compilation phases observed during sequential and parallel builds inside a standard `us-east4` project:

| Image Build Phase | Customization Script / Action | Typical Duration | Performance & Cache Notes |
| :--- | :--- | :--- | :--- |
| **GCE Base Secure Boot Image** | `examples/secure-boot/no-customization.sh` | `~7m 20s` - `11m 05s` | Boots the unaccelerated VM instance, registers UEFI db public certs, and snapshots the `secure-boot` GCE image. Rocky Linux builds take ~11m, Debian/Ubuntu take ~7m. |
| **Total Baseline Custom Image Build** | `examples/secure-boot/build-and-run-podman.sh` | `~7m` - `11m` | Total OCI/Podman Stage 1 parallel compilation time to generate the UEFI baseline custom images. |
| **GPU/Conda Pre-bake Build (Cold Cache)** | `initialization-actions/gpu/install_gpu_driver.sh` | `~21m` - `24m` | Boots a T4 GPU VM instance, compiles the NVIDIA modules, compiles NCCL, and builds TensorFlow, PyTorch, and RAPIDS Conda environments via Mamba. |
| **GPU/Conda Pre-bake Build (GCS Cache Hit)** | `initialization-actions/gpu/install_gpu_driver.sh` | **`1m 45s`** | Downloads pre-compiled Blackwell drivers and zipped Conda tarballs directly from GCS over Private Google Access routes. |
| **Total Production custom image Build** | `examples/secure-boot/build-and-run-podman.sh` | `~25m` - `35m` | Total end-to-end parallel OCI build duration to generate the final, fully pre-baked production custom images (`-tf`). |

