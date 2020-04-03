#!/usr/bin/env bash
### This image is manufactured using python generate_custom_image.py ###

# sets up anaconda and jupyter
rm -f /usr/local/share/google/dataproc/bdutil/components/activate/jupyter.sh
mv /tmp/jupyter.sh /usr/local/share/google/dataproc/bdutil/components/activate/jupyter.sh
wget https://storage.googleapis.com/hadoop-lib/gcs/gcs-connector-hadoop2-latest.jar -O /usr/local/share/google/dataproc/lib/gcs-connector-hadoop2-latest.jar
cat >>/etc/google-dataproc/dataproc.properties <<EOF
dataproc.components.activate=anaconda jupyter
EOF
bash /usr/local/share/google/dataproc/bdutil/components/activate/anaconda.sh
bash /usr/local/share/google/dataproc/bdutil/components/activate/jupyter.sh

## Get correct python path
source /etc/profile.d/effective-python.sh
source /etc/profile.d/conda.sh

## Setup conda environment with qgis
conda create --prefix /opt/conda/moove-dataproc conda python==3.6.10
touch /root/.bashrc
echo ". /opt/conda/anaconda/etc/profile.d/conda.sh" >> /root/.bashrcx
ln -s /opt/conda/anaconda/etc/profile.d/conda.sh /etc/profile.d/conda.sh
source /etc/profile.d/conda.sh
conda activate /opt/conda/moove-dataproc
conda install jupyterlab
conda install -c anaconda libnetcdf
conda install qgis==3.12.1=py36h77e4444_2 -c conda-forge
conda install ipykernel
ln -s /opt/conda/moove-dataproc/lib/libnetcdf.so.18 /opt/conda/moove-dataproc/lib/libnetcdf.so.15
python -m ipykernel install --user --name qgis-test-kernel --display-name="qgis-test-kernel"

## Install pip packages
git clone https://GITHUB_OAUTH_TOKEN@github.com/moove-ai/moove-data-exploration.git
cd moove-data-exploration
git checkout feture-branch-panel-data-set
echo "pip installation"
pip install msgpack  --upgrade --ignore-installed
pip install wrapt  --upgrade --ignore-installed
pip install -r ./requirements.txt --upgrade --ignore-installed
conda install -c conda-forge pandana

pip install dill
pip install urbanaccess
pip install --upgrade google-api-python-client
pip install --upgrade google-cloud-bigquery
pip install --upgrade google-cloud-storage


## Setup spark jars
mkdir -p /usr/lib/spark/jars
gsutil cp gs://spark-lib/bigquery/spark-bigquery-latest.jar /usr/lib/spark/jars/
sleep 10000;
### Install Netdata
#[ "3058dbf398ba0d73d02c7626545610f5" = "$(curl -Ss https://my-netdata.io/kickstart.sh | md5sum | cut -d ' ' -f 1)" ] && export install_netdata=true || echo "FAILED, INVALID"
#if [[ ${install_netdata} == "true" ]]; then
#    yes | bash <(curl -Ss https://my-netdata.io/kickstart.sh)  --enable-ebpf  --dont-wait
#    exit 0
#fi
