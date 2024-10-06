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
