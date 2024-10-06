FROM python:3.11-slim

# To build: docker build -t dataproc-custom-images:latest .
# To run: docker run -it dataproc-custom-images:latest /bin/bash

# and then from the docker bash shell, run the
# generate_custom_image.py as per examples/secure-boot/README.md

# python generate_custom_image.py \
#     --image-name ${image_name} \
#     --dataproc-version ${dataproc_version} \
#     --trusted-cert "tls/db.der" \
#     --customization-script ${customization_script} \
#     --metadata "${metadata}" \
#     --zone "${custom_image_zone}" \
#     --disk-size "${disk_size_gb}" \
#     --no-smoke-test \
#     --gcs-bucket "${my_bucket}"

WORKDIR /custom-images

RUN apt-get -qq update \
  && apt-get -y -qq install \
     apt-transport-https ca-certificates gnupg curl jq less
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

# This will only work so long as google-cloud-cli installs to Buster
RUN apt-get -y -qq update && apt-get -y -qq install google-cloud-cli && apt-get clean

RUN apt-get -y -qq install emacs-nox vim && apt-get clean

COPY . ${WORKDIR}

CMD ["/bin/bash"]

