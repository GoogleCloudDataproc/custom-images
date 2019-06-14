# This Dockerfile creates an image for running presubmit tests.

FROM gcr.io/cloud-builders/gcloud

# Copy everything into the container
COPY . /dataproc-custom-images/
RUN ls -a /dataproc-custom-images

ENTRYPOINT ["bash", "/dataproc-custom-images/cloud_build/presubmit.sh"]
