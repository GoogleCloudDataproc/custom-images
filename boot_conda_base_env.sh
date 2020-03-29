#!/usr/bin/env bash
### This image is manufactured using python generate_custom_image.py ###

## Sets up anaconda
cat >>/etc/google-dataproc/dataproc.properties <<EOF
dataproc.components.activate=anaconda
EOF
bash /usr/local/share/google/dataproc/bdutil/components/activate/anaconda.sh

## Get correct python path
source /etc/profile.d/effective-python.sh
source /etc/profile.d/conda.sh

## Setup conda environment with qgis
touch /root/.bashrc
echo ". /opt/conda/anaconda/etc/profile.d/conda.sh" >> /root/.bashrc
ln -s /opt/conda/anaconda/etc/profile.d/conda.sh /etc/profile.d/conda.sh
source /etc/profile.d/conda.sh
conda install jupyterlab
conda install python==3.6.10
conda install -c anaconda libnetcdf
wget https://anaconda.org/conda-forge/qgis/3.12.1/download/linux-64/qgis-3.12.1-py36h77e4444_2.tar.bz2 -O /opt/qgis-3.12.1-py36h77e4444_2.tar.bz2
conda install --use-local /opt/qgis-3.12.1-py36h77e4444_2.tar.bz2
conda install ipykernel
ln -s /opt/conda/anaconda/lib/libnetcdf.so.18 /opt/conda/anaconda/lib/libnetcdf.so.15
python -m ipykernel install --user --name moove-dataproc --display-name="Python 3.6 qgis kernel"

## Install pip packages
git clone https://GITHUB_OAUTH_TOKEN@github.com/moove-ai/moove-data-exploration.git
cd moove-data-exploration
git checkout feture-branch-panel-data-set
echo "pip installation"
pip install msgpack  --upgrade --ignore-installed
pip install wrapt  --upgrade --ignore-installed
pip install -r ./requirements.txt --upgrade --ignore-installed

## Setup spark jars
mkdir -p /usr/lib/spark/jars
gsutil cp gs://spark-lib/bigquery/spark-bigquery-latest.jar /usr/lib/spark/jars/

### Install Netdata
#[ "3058dbf398ba0d73d02c7626545610f5" = "$(curl -Ss https://my-netdata.io/kickstart.sh | md5sum | cut -d ' ' -f 1)" ] && export install_netdata=true || echo "FAILED, INVALID"
#if [[ ${install_netdata} == "true" ]]; then
#    yes | bash <(curl -Ss https://my-netdata.io/kickstart.sh)  --enable-ebpf  --dont-wait
#    exit 0
#fi
