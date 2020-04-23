#!/usr/bin/env bash
### This image is manufactured using python generate_custom_image.py ###

# sets up anaconda and jupyter
rm -f /usr/local/share/google/dataproc/bdutil/components/activate/jupyter.sh
cp /opt/jupyter-custom.sh /usr/local/share/google/dataproc/bdutil/components/activate/jupyter.sh
cat >>/etc/google-dataproc/dataproc.properties <<EOF
dataproc.components.activate=anaconda
EOF
bash /usr/local/share/google/dataproc/bdutil/components/activate/anaconda.sh

# Get correct python path
source /etc/profile.d/effective-python.sh
source /etc/profile.d/conda.sh

# Setup conda environment with qgis
conda create --name moove-dataproc conda python==3.6.10
touch /root/.bashrc
echo ". /opt/conda/anaconda/etc/profile.d/conda.sh" >> /root/.bashrc
source /etc/profile.d/conda.sh
conda activate moove-dataproc
conda install jupyterlab
conda install -c anaconda libnetcdf
conda install qgis -c conda-forge
ln -s /opt/conda/anaconda/envs/moove-dataproc/lib/libnetcdf.so.18 /opt/conda/anaconda/envs/moove-dataproc/lib/libnetcdf.so.15

## Install pip packages
git clone https://GITHUB_OAUTH_TOKEN@github.com/moove-ai/moove-data-exploration.git
cd moove-data-exploration
git checkout feture-branch-panel-data-set
pip install msgpack  --upgrade --ignore-installed
pip install wrapt  --upgrade --ignore-installed
pip install -r ./requirements.txt --ignore-installed
pip install pyspark
conda install -c conda-forge pandana
pip install urbanaccess dill ujson
pip install --upgrade google-api-python-client google-cloud-bigquery google-cloud-storage

# Setup moove-dataproc environment for Jupyter in systemd
env > /etc/default/jupyter
cat >> /etc/default/jupyter <<EOF
#PYSPARK_PYTHON=/opt/conda/moove-dataproc/bin/python
#SPARK_HOME=/usr/lib/spark
EOF

## Setup spark jars
mkdir -p /usr/lib/spark/jars
gsutil cp gs://spark-lib/bigquery/spark-bigquery-latest.jar /usr/lib/spark/jars/

NODE_EXPORTER_VERSION="0.18.1"

## Setup monitoring
useradd -r node_exporter
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar xvfz "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/sbin/node_exporter

cat >> /etc/default/node_exporter <<EOF
OPTIONS=""
EOF

cat >> /usr/lib/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter

[Service]
User=node_exporter
EnvironmentFile=/etc/default/node_exporter
ExecStart=/usr/sbin/node_exporter \$OPTIONS

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter.service
systemctl start node_exporter.service
