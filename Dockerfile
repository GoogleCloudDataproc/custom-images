FROM python:slim

# To build: docker build -t dataproc-custom-images:latest .
# To run: docker run -it dataproc-custom-images:latest /bin/bash

# Then from the docker bash shell, run examples/secure-boot/cuda.sh

WORKDIR /custom-images

RUN apt-get -qq update \
  && apt-get -y -qq install \
     apt-transport-https ca-certificates gnupg curl jq less screen
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

RUN apt-get -y -qq update && apt-get -y -qq install google-cloud-cli && apt-get clean

RUN apt-get -y -qq install emacs-nox vim && apt-get clean

COPY . ${WORKDIR}

CMD ["/bin/bash"]

