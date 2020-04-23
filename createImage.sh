#!/usr/bin/env bash
if [ "$#" -ne 1 ]; then
    echo "Please enter the name of the boot script"
    exit 1
fi

BOOT_SCRIPT=$1

if ! test -f ${BOOT_SCRIPT}; then
    echo "please enter a valid boot script"
    exit 1
fi

echo "Boot script: ${BOOT_SCRIPT}"

sed -i '.bak' "s/GITHUB_OAUTH_TOKEN/$GITHUB_OAUTH_TOKEN/g" ${BOOT_SCRIPT}

python generate_custom_image.py \
--image-name dataproc-custom-1-4-5-anaconda-$(date +%Y%m%d%H%M) \
--dataproc-version 1.4.25-debian9 \
--customization-script $(pwd)/${BOOT_SCRIPT} \
--zone us-central1-a \
--gcs-bucket gs://moove-dataproc-custom-2 \
--disk-size 100  \
--machine-type n1-standard-8 \
--project moove-platform-staging \
--extra-sources "{\"/opt/jupyter-custom.sh\": \"jupyter.sh\", \"/usr/lib/spark/conf/spark.metrics.properties\": \"spark.metrics.properties\"}"

git checkout -- ${BOOT_SCRIPT}
