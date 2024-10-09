## Secure Boot

Secure Boot is a security technology implemented in UEFI firmware that
verifies the integrity of the boot process of a computer system. It
ensures that only trusted software, such as the operating system,
firmware, and drivers, are loaded during startup. This helps prevent
malicious software from gaining control of the system before security
measures can be implemented.

Secure Boot achieves this by verifying the digital signature of
drivers and other software against a recognized root of trust. The EFI
DB variable stores the cryptographic keys and certificates used for
this verification process.

How Secure Boot impacts VPC SC:

Enhanced Security Perimeter: By verifying the integrity of the boot
process, Secure Boot strengthens the foundation of the security
perimeter created by VPC SC. This reduces the risk of unauthorized
access or data exfiltration due to compromised host systems.
Improved Trust in Service Perimeter Resources: VPC SC relies on the
trust that the resources within a service perimeter are secure. Secure
Boot helps to establish and maintain this trust by ensuring that these
resources are protected from malicious boot-time attacks.
Compliance and Regulatory Requirements: Many security compliance
standards, such as PCI DSS and HIPAA, require specific measures to
protect sensitive data. Secure Boot can be a valuable component of
meeting these requirements by providing additional assurance of system
integrity.

Reduced Attack Surface: By preventing unauthorized software from
loading during startup, Secure Boot reduces the potential attack
surface for malicious actors. This can help to mitigate the risk of
successful cyberattacks.

In summary, Secure Boot provides a crucial layer of protection for VPC
SC by ensuring that the underlying infrastructure is secure and
trusted. This helps to strengthen the overall security posture of
Google Cloud Platform environments and protect sensitive data.

## Examples

To create a custom image with a self-signed, trusted certificate
inserted into the boot sector, and then run a script to install cuda
on a Dataproc image, the commands from cuda.sh can be run from the
root of the custom-images git repository or from a docker container.

First, write an env.json to the directory from which you will run the
customization script.  There is a sample which you can copy and edit
in the file examples/secure-boot/env.json.sample.

```bash
cp examples/secure-boot/env.json.sample env.json
vi env.json
docker build -t dataproc-custom-images:latest .
docker run -it dataproc-custom-images:latest /bin/bash examples/secure-boot/cuda.sh
```

To do the same, but for all dataproc variants including supported
versions and image families, the same env.json steps as above should
be executed, and then the examples/secure-boot/build-current-images.sh
script can be run in docker:

```bash
cp examples/secure-boot/env.json.sample env.json
vi env.json
docker build -t dataproc-custom-images:latest .
docker run -it dataproc-custom-images:latest /bin/bash examples/secure-boot/build-current-images.sh
```
