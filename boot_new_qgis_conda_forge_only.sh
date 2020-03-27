#!/usr/bin/env bash
# This image is manufactured using python generate_custom_image.py
cat >>/etc/google-dataproc/dataproc.properties <<EOF
dataproc.components.activate=anaconda
EOF
bash /usr/local/share/google/dataproc/bdutil/components/activate/anaconda.sh
source /etc/profile.d/effective-python.sh
source /etc/profile.d/conda.sh
conda update -n base -c defaults conda
conda create --name qgis_dev
conda activate qgis_dev
conda install python==3.6.8
conda install qgis==3.4.8 --channel conda-forge

echo "checking if qgis is installed"
QGIS_INSTALLED=$(conda list | grep qgis | awk '{ print $1 }')

if [[ "${QGIS_INSTLLED}" == "qgis" ]]; then
    echo "************************************************"
    echo "************************************************"
    echo "************************************************"
    echo "qgis is installed via conda"
    echo "************************************************"
    echo "************************************************"
    echo "************************************************"
else
    echo "qgis is not installe"
    exit 99
fi

conda install jupyterlab
echo "source /etc/profile.d/effective-python.sh" >> /etc/bash.bashrc
conda install pysal geopandas
sudo apt-get update
sudo apt-get install -y mlocate uuid-dev python-qgis qgis-plugin-grass
# sudo apt-get install -y libgdal-dev default-libmysqlclient-dev libqca-qt5-2 libqt5keychain1
echo "spark jars"
mkdir -p /usr/lib/spark/jars
gsutil cp gs://spark-lib/bigquery/spark-bigquery-latest.jar /usr/lib/spark/jars/
#[ "3058dbf398ba0d73d02c7626545610f5" = "$(curl -Ss https://my-netdata.io/kickstart.sh | md5sum | cut -d ' ' -f 1)" ] && export install_netdata=true || echo "FAILED, INVALID"
#if [[ ${install_netdata} == "true" ]]; then
#    yes | bash <(curl -Ss https://my-netdata.io/kickstart.sh)  --enable-ebpf  --dont-wait
#    exit 0
#fi
echo "READY"
#sleep 10000000000;