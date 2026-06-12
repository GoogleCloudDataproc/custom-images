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

## Boot and Build Durations

Comparison of cluster boot times and image creation times.

### Cluster Boot Times (VM Boot to Dataproc READY)

| Method | Mechanism | Boot Time | Details |
| :--- | :--- | :--- | :--- |
| **Standard Image + Init Action** | `install_gpu_driver.sh` (as Init Action) | **`7m` - `9m`** | Downloads ~4.5 GB of drivers and packages from GCS, compiles kernel modules, and configures YARN/Spark on every boot. |
| **Pre-baked Custom Image** | Pre-installed drivers + deferred systemd config | **`~4m`** | No downloads or installations. Adds ~30s to the first boot for hardware probing and writing configuration files. |

---

### Image Creation Times (Baking)

Image creation times using the Podman pipeline in `us-east4`:

| Phase | Script | Duration | Notes |
| :--- | :--- | :--- | :--- |
| **GCE Base Secure Boot Image** | `pre-init.sh` (Base Stage) | `~7m` - `11m` | Provisions VM, registers UEFI certs, and snapshots base image. (Rocky: ~11m, Debian/Ubuntu: ~7m). |
| **GPU/Conda Pre-bake Layer** | `install_gpu_driver.sh` (during baking) | `~21m` - `24m` | Compiles NVIDIA modules and builds Conda environments on a GPU VM. |
| **Total Image Suite** | `build-and-run-podman.sh` | `~25m` - `35m` | Total duration to generate the image suite. |

