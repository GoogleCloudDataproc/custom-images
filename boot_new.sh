#!/usr/bin/env bash
# This image is manufactured using python generate_custom_image.py

cat >>/etc/google-dataproc/dataproc.properties <<EOF
dataproc.components.activate=anaconda
EOF
bash /usr/local/share/google/dataproc/bdutil/components/activate/anaconda.sh

source /etc/profile.d/effective-python.sh
source /etc/profile.d/conda.sh

#conda update -n base -c defaults conda

conda install python==3.6.8

wget -q https://anaconda.org/conda-forge/qgis/3.12.1/download/linux-64/qgis-3.12.1-py36h77e4444_2.tar.bz2 -O /tmp/qgis-3.12.1-py36h77e4444_2.tar.bz2
conda install --offline --use-local /tmp/qgis-3.8.3-py36hee8cbbe_0.tar.bz2

#wget -q https://anaconda.org/conda-forge/libspatialindex/1.9.3/download/win-64/libspatialindex-1.9.3-he025d50_3.tar.bz2 -O /tmp/libspatialindex-1.9.3-he025d50_3.tar.bz2
#conda install --offline --use-local /tmp/libspatialindex-1.9.3-he025d50_3.tar.bz2

conda install jupyterlab
echo "source /etc/profile.d/effective-python.sh" >> /etc/bash.bashrc


conda install pysal geopandas

sudo apt-get update
#sudo apt-get install -y qgis python-qgis qgis-plugin-grass libspatialindex-dev uuid-dev libgdal-dev default-libmysqlclient-dev
sudo apt-get install -y mlocate uuid-dev libgdal-dev default-libmysqlclient-dev libqca-qt5-2 libqt5keychain1 qgis python-qgis qgis-plugin-grass

#echo "Linking libsptailindex"
#sudo ln -s /opt/conda/anaconda/lib/libspatialindex.so.6.1.1 /opt/conda/anaconda/lib/libspatialindex.so.5
#sudo ln -s /opt/conda/jupyternb/lib/libspatialindex.so.6.1.1 /opt/conda/jupyternb/lib/libspatialindex.so.5

echo "setting python path environment vars"
echo 'export LD_LIBRARY_PATH=/opt/conda/anaconda/lib' >> /etc/bash.bashrc
echo 'export PYTHONPATH=/opt/conda/anaconda/share/qgis/python' >> /etc/bash.bashrc

#echo "cloning moove datascience repo"
#git clone https://a25d5effbb396932d8adf29615b15c26ccc4bc6f@github.com/moove-ai/moove-data-exploration.git
#cd moove-data-exploration
#git checkout feture-branch-panel-data-set
#
#
#echo "pip installation"
##pip install msgpack  --upgrade --ignore-installed
##pip install wrapt  --upgrade --ignore-installed
##pip install -r ./requirements.txt --upgrade --ignore-installed
#
## ensure pip is missing. This command should be run three times
#echo "ensure pip numpy is missing"
#pip uninstall -y numpy
#pip uninstall -y numpy
#pip uninstall -y numpy
#
#echo "ensure conda pip is installed"
#conda install numpy
#
#echo "ensure gdal is installed"
#conda install gdal
#
#echo "enusre urbanaccess is installed"
#pip install -U urbanaccess


echo "updating python path again"
echo 'export QT_QPA_PLATFORM_PLUGIN_PATH=/opt/conda/anaconda/share/qgis/python/plugins/' >> /etc/bash.bashrc
source /etc/bash.bashrc

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

