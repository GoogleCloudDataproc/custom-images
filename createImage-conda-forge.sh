#!/usr/bin/env bash
sed -i '.bak' 's/GITHUB_OAUTH_TOKEN/${GITHUB_OATH_TOKEN}/g' boot_new.sh

python generate_custom_image.py \
--image-name dataproc-custom-1-4-5-qgis-forge-$(date +%Y%m%d%H%M) \
--dataproc-version 1.4.25-debian9 \
--customization-script $(pwd)/boot_new_qgis_conda_forge.sh \
--zone us-central1-b \
--gcs-bucket gs://moove-dataproc-custom \
--disk-size 100  \
--machine-type n1-standard-8

git checkout -- boot_new_qgis_conda_forge.sh