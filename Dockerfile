# since this script depends on python 2.7, we need a stable base from which to run it
FROM python:2.7-slim

RUN apt-get update && apt-get -y install apt-transport-https ca-certificates gnupg curl
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

# This will only work so long as google-cloud-cli installs to Buster
RUN apt-get -y update && apt-get -y install google-cloud-cli


COPY . ${WORKDIR}

CMD ["/bin/bash"]

