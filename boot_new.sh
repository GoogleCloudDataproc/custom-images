#!/usr/bin/env bash
# This image is manufactured using python generate_custom_image.py

cat >>/etc/google-dataproc/dataproc.properties <<EOF
dataproc.components.activate=anaconda
EOF
bash /usr/local/share/google/dataproc/bdutil/components/activate/anaconda.sh

source /etc/profile.d/effective-python.sh
source /etc/profile.d/conda.sh

conda create --prefix /opt/conda/moove-dataproc conda python==3.6.8
echo ". /opt/conda/anaconda/etc/profile.d/conda.sh" >> ~/.bashrc
sudo ln -s /opt/conda/anaconda/etc/profile.d/conda.sh /etc/profile.d/conda.sh
source /etc/profile.d/conda.sh
conda activate /opt/conda/moove-dataproc
conda install conda python==3.6.8
conda install qgis -c conda-forge
conda install ipykernel
python -m ipykernel install --user --name moove-dataproc --display-name="Python 3.6 qgis kernel"

touch /root/.bashrc
echo "source /etc/profile.d/conda.sh" >> /root/.bashrc

#
##conda install jupyterlab
#echo "source /etc/profile.d/effective-python.sh" >> /etc/bash.bashrc
##conda install pysal geopandas
#sudo apt-get update
#sudo apt-get install -y mlocate uuid-dev libgdal-dev default-libmysqlclient-dev libqca-qt5-2 libqt5keychain1 qgis python-qgis qgis-plugin-grass
#echo "setting python path environment vars"
#echo 'export LD_LIBRARY_PATH=/opt/conda/anaconda/lib' >> /etc/bash.bashrc
#echo 'export PYTHONPATH=/opt/conda/anaconda/share/qgis/python' >> /etc/bash.bashrc
#
##echo "cloning moove datascience repo"
##git clone https://a25d5effbb396932d8adf29615b15c26ccc4bc6f@github.com/moove-ai/moove-data-exploration.git
##cd moove-data-exploration
##git checkout feture-branch-panel-data-set
##echo "pip installation"
##pip install msgpack  --upgrade --ignore-installedx``
##pip install wrapt  --upgrade --ignore-installed
##pip install -r ./requirements.txt --upgrade --ignore-installed
##pip uninstall -y numpy
##pip uninstall -y numpy
##pip uninstall -y numpy
##conda install numpy
##conda install gdal
##pip install -U urbanaccess
#
#echo "updating python path again"
#echo 'export QT_QPA_PLATFORM_PLUGIN_PATH=/opt/conda/anaconda/share/qgis/python/plugins/' >> /etc/bash.bashrc
#source /etc/bash.bashrc
#
#echo "spark jars"
#mkdir -p /usr/lib/spark/jars
#gsutil cp gs://spark-lib/bigquery/spark-bigquery-latest.jar /usr/lib/spark/jars/
##[ "3058dbf398ba0d73d02c7626545610f5" = "$(curl -Ss https://my-netdata.io/kickstart.sh | md5sum | cut -d ' ' -f 1)" ] && export install_netdata=true || echo "FAILED, INVALID"
##if [[ ${install_netdata} == "true" ]]; then
##    yes | bash <(curl -Ss https://my-netdata.io/kickstart.sh)  --enable-ebpf  --dont-wait
##    exit 0
##fi
#
#
#echo "READY"
##sleep 10000000000;
#
