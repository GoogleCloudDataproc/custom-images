#!/usr/bin/env bash
### This image is manufactured using python generate_custom_image.py ###

## sets up anaconda and jupyter
rm -f /usr/local/share/google/dataproc/bdutil/components/activate/jupyter.sh
cp /opt/jupyter-custom.sh /usr/local/share/google/dataproc/bdutil/components/activate/jupyter.sh
cat >>/etc/google-dataproc/dataproc.properties <<EOF
dataproc.components.activate=anaconda
EOF
bash /usr/local/share/google/dataproc/bdutil/components/activate/anaconda.sh

## Get correct python path
source /etc/profile.d/effective-python.sh
source /etc/profile.d/conda.sh

## Setup conda environment with qgis
conda create --prefix /opt/conda/moove-dataproc conda python==3.6.10
touch /root/.bashrc
echo ". /opt/conda/anaconda/etc/profile.d/conda.sh" >> /root/.bashrcx
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
conda install pyspark
pip install pysal pyshp jenkspy urbanaccess dill ujson pandas-gbq
pip install --upgrade google-api-python-client
pip install --upgrade google-cloud-bigquery
pip install --upgrade google-cloud-storage

# Setup moove-dataproc environment for Jupyter in systemd
env > /etc/default/jupyter
echo "PYSPARK_PYTHON=/opt/conda/moove-dataproc/bin/python" >> /etc/default/jupyter
echo "PYSPARK_DRIVER_PYTHON=/opt/conda/moove-dataproc/bin/python" >> /etc/default/jupyter
## Setup spark jars
mkdir -p /usr/lib/spark/jars
gsutil cp gs://spark-lib/bigquery/spark-bigquery-latest.jar /usr/lib/spark/jars/

## Setup monitoring
wget https://github.com/prometheus/node_exporter/releases/download/v0.18.1/node_exporter-0.18.1.linux-amd64.tar.gz
tar xvfz node_exporter-*.*-amd64.tar.gz
mv node_exporter /usr/sbin/node_exporter

cat >> /etc/default/node_exporter <<EOF
OPTIONS=""
EOF

cat >> /usr/lib/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter

[Service]
User=node_exporter
EnvironmentFile=/etc/default/node_exporter
ExecStart=/usr/sbin/node_exporter $OPTIONS

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter.service
systemctl start node_exporter.service
