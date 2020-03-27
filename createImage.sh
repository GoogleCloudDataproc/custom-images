#!/usr/bin/env bash
python generate_custom_image.py \
--image-name dataproc-custom-1-4-5-anaconda-$(date +%Y%m%d%H%M) \
--dataproc-version 1.4.25-debian9 \
--customization-script $(pwd)/boot_new.sh \
--zone us-central1-b \
--gcs-bucket gs://moove-dataproc-custom \
--disk-size 100  \
--machine-type n1-standard-8

