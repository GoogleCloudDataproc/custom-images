#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/../../bdutil_env.sh"
source "$(dirname "$0")/../../bdutil_helpers.sh"
source "$(dirname "$0")/../shared/anaconda.sh"
source "$(dirname "$0")/../shared/jupyter.sh"

readonly DATAPROC_MASTER="$(get_metadata_master)"
readonly DATAPROC_BUCKET="$(get_metadata_bucket)"

# GCS directory in which to store notebooks.
# DATAPROC_BUCKET must not include gs:// and bucket must exist
readonly DEFAULT_NOTEBOOK_DIR="${DATAPROC_BUCKET}/notebooks/jupyter"

# Install cached wheels.
pip install -r "${JUPYTER_EXTRA_PACKAGES}" --no-index --find-links="${GCP_WHEEL}"

install -d "${JUPYTER_ETC_DIR}"
chmod a+r "${JUPYTER_ETC_DIR}"

# Check if a user-specified notebook location was provided.
readonly USER_NOTEBOOK_LOCATION=$(get_dataproc_property \
  jupyter.notebook.gcs.dir)

NOTEBOOK_DIR="${DEFAULT_NOTEBOOK_DIR}"
if [[ "${USER_NOTEBOOK_LOCATION}" != "" ]]; then
  # Strip 'gs://' prefix.
  NOTEBOOK_DIR=${USER_NOTEBOOK_LOCATION/gs:\/\//}
fi
NOTEBOOK_BUCKET=$(echo "${NOTEBOOK_DIR}" | cut -d '/' -f 1)
NOTEBOOK_PATH=${NOTEBOOK_DIR#"${NOTEBOOK_BUCKET}/"}

# Verify we can access the GCS bucket.
check_gcs_bucket_access "gs://${NOTEBOOK_DIR}" 'jupyter'

# Create storage path if it does not exist
hadoop fs -mkdir -p "gs://${NOTEBOOK_DIR}"

# Get user-provided port.
JUPYTER_PORT=$(get_dataproc_property jupyter.port)
JUPYTER_PORT=${JUPYTER_PORT:-8123}

cat <<EOF >>"${JUPYTER_CONFIG_FILE}"
import base64
import json
import logging
import mimetypes
import posixpath

import nbformat
from notebook.services.contents.manager import ContentsManager
from notebook.services.contents.checkpoints import Checkpoints, GenericCheckpointsMixin
from tornado.web import HTTPError
from traitlets import Unicode, default

from google.cloud import storage


utf8_encoding = 'utf-8'


class GCSCheckpointManager(GenericCheckpointsMixin, Checkpoints):
  checkpoints_dir = '.ipynb_checkpoints'

  def __init__(self, **kwargs):
    self._kwargs = kwargs
    self._parent = kwargs['parent']

  @property
  def bucket(self):
    return self._parent.bucket

  def checkpoint_path(self, checkpoint_id, path):
    path = (path or '').strip('/')
    return posixpath.join(self.checkpoints_dir, path, checkpoint_id)

  def checkpoint_blob(self, checkpoint_id, path, create_if_missing=False):
    blob_name = self.checkpoint_path(checkpoint_id, path)
    blob = self.bucket.get_blob(blob_name)
    if not blob and create_if_missing:
      blob = self.bucket.blob(blob_name)
    return blob

  def create_file_checkpoint(self, content, format, path):
    checkpoint_id = 'checkpoint'
    blob = self.checkpoint_blob(checkpoint_id, path, create_if_missing=True)
    content_type = 'text/plain' if format == 'text' else 'application/octet-stream'
    blob.upload_from_string(content, content_type=content_type)
    return {
      'id': checkpoint_id,
      'last_modified': blob.updated,
    }

  def create_notebook_checkpoint(self, nb, path):
    content = nbformat.writes(nb)
    return self.create_file_checkpoint(content, 'text', path)

  def _checkpoint_contents(self, checkpoint_id, path):
    blob = self.checkpoint_blob(checkpoint_id, path)
    if not blob:
      raise HTTPError(404, 'No such checkpoint for "{}": {}'.format(path, checkpoint_id))
    return blob.download_as_string(), blob.content_type

  def get_file_checkpoint(self, checkpoint_id, path):
    contents, content_type = self._checkpoint_contents(checkpoint_id, path)
    checkpoint_obj = {
      'type': 'file',
      'content': contents.decode(utf8_encoding),
    }
    content_obj['format'] = 'text' if content_type == 'text/plain' else 'base64'
    return content_obj

  def get_notebook_checkpoint(self, checkpoint_id, path):
    contents, _ = self._checkpoint_contents(checkpoint_id, path)
    checkpoint_obj = {
      'type': 'notebook',
      'content':  nbformat.reads(contents, as_version=4),
    }
    return content_obj

  def delete_checkpoint(self, checkpoint_id, path):
    blob = self.checkpoint_blob(checkpoint_id, path)
    if blob:
      blob.delete()
    return None

  def list_checkpoints(self, path):
    checkpoints = []
    for b in self.bucket.list_blobs(prefix=posixpath.join(self.checkpoints_dir, path)):
      checkpoint = {
          'id': posixpath.basename(b.name),
          'last_modified': b.updated,
      }
      checkpoints.append(checkpoint)
    return checkpoints

  def rename_checkpoint(self, checkpoint_id, old_path, new_path):
    blob = self.checkpoint_blob(checkpoint_id, old_path)
    if not blob:
      return None
    new_blob_name = self.checkpoint_path(checkpoint_id, new_path)
    self.bucket.rename_blob(blob, new_blob_name)
    return None


class GCSContentsManager(ContentsManager):

  bucket_name = Unicode(config=True)

  bucket_notebooks_path = Unicode(config=True)

  @default('checkpoints_class')
  def _checkpoints_class_default(self):
    return GCSCheckpointManager

  @default('bucket_notebooks_path')
  def _bucket_notebooks_path_default(self):
    return ''

  def __init__(self, **kwargs):
    super(GCSContentsManager, self).__init__(**kwargs)
    self._bucket = None

  @property
  def bucket(self):
    if not self._bucket:
      storage_client = storage.Client()
      self._bucket = storage_client.get_bucket(self.bucket_name)
    return self._bucket

  def _normalize_path(self, path):
    path = path or ''
    return path.strip('/')

  def _gcs_path(self, normalized_path):
    if not self.bucket_notebooks_path:
      return normalized_path
    if not normalized_path:
      return self.bucket_notebooks_path
    return posixpath.join(self.bucket_notebooks_path, normalized_path)

  def is_hidden(self, path):
    try:
      path = self._normalize_path(path)
      return posixpath.basename(path).startswith('.')
    except HTTPError as err:
      raise err
    except Exception as ex:
      raise HTTPError(500, 'Internal server error: {}'.format(str(ex)))

  def file_exists(self, path):
    try:
      path = self._normalize_path(path)
      if not path:
        return False
      blob_name = self._gcs_path(path)
      blob = self.bucket.get_blob(blob_name)
      return blob is not None
    except HTTPError as err:
      raise err
    except Exception as ex:
      raise HTTPError(500, 'Internal server error: {}'.format(str(ex)))

  def dir_exists(self, path):
    try:
      path = self._normalize_path(path)
      if not path:
        return self.bucket.exists()

      dir_gcs_path = self._gcs_path(path)
      if self.bucket.get_blob(dir_gcs_path):
        # There is a regular file matching the specified directory.
        #
        # Would could have both a blob matching a directory path
        # and other blobs under that path. In that case, we cannot
        # treat the path as both a directory and a regular file,
        # so we treat the regular file as overriding the logical
        # directory.
        return False

      dir_contents = self.bucket.list_blobs(prefix=dir_gcs_path)
      for _ in dir_contents:
        return True

      return False
    except HTTPError as err:
      raise err
    except Exception as ex:
      raise HTTPError(500, 'Internal server error: {}'.format(str(ex)))

  def _blob_model(self, normalized_path, blob, content=True):
    blob_obj = {}
    blob_obj['path'] = normalized_path
    blob_obj['name'] = posixpath.basename(normalized_path)
    blob_obj['last_modified'] = blob.updated
    blob_obj['created'] = blob.time_created
    blob_obj['writable'] = True
    blob_obj['type'] = 'notebook' if blob_obj['name'].endswith('.ipynb') else 'file'
    if not content:
      blob_obj['mimetype'] = None
      blob_obj['format'] = None
      blob_obj['content'] = None
      return blob_obj

    content_str = blob.download_as_string() if content else None
    if blob_obj['type'] == 'notebook':
      blob_obj['mimetype'] = None
      blob_obj['format'] = 'json'
      blob_obj['content'] = nbformat.reads(content_str, as_version=4)
    elif blob.content_type.startswith('text/'):
      blob_obj['mimetype'] = 'text/plain'
      blob_obj['format'] = 'text'
      blob_obj['content'] = content_str.decode(utf8_encoding)
    else:
      blob_obj['mimetype'] = 'application/octet-stream'
      blob_obj['format'] = 'base64'
      blob_obj['content'] = base64.b64encode(content_str)

    return blob_obj

  def _empty_dir_model(self, normalized_path, content=True):
    dir_obj = {}
    dir_obj['path'] = normalized_path
    dir_obj['name'] = posixpath.basename(normalized_path)
    dir_obj['type'] = 'directory'
    dir_obj['mimetype'] = None
    dir_obj['writable'] = True
    dir_obj['last_modified'] = self.bucket.time_created
    dir_obj['created'] = self.bucket.time_created
    dir_obj['format'] = None
    dir_obj['content'] = None
    if content:
      dir_obj['format'] = 'json'
      dir_obj['content'] = []
    return dir_obj

  def _list_dir(self, normalized_path, content=True):
    dir_obj = self._empty_dir_model(normalized_path, content=content)
    if not content:
      return dir_obj

    # We have to convert a list of GCS blobs, which may include multiple
    # entries corresponding to a single sub-directory, into a list of immediate
    # directory contents with no duplicates.
    #
    # To do that, we keep a dictionary of immediate children, and then convert
    # that dictionary into a list once it is fully populated.
    children = {}
    def add_child(name, model, override_existing=False):
      """Add the given child model (for either a regular file or directory), to
      the list of children for the current directory model being built.

      It is possible that we will encounter a GCS blob corresponding to a
      regular file after we encounter blobs indicating that name should be a
      directory. For example, if we have the following blobs:
          some/dir/path/
          some/dir/path/with/child
          some/dir/path
      ... then the first two entries tell us that 'path' is a subdirectory of
      'dir', but the third one tells us that it is a regular file.

      In this case, we treat the regular file as shadowing the directory. The
      'override_existing' keyword argument handles that by letting the caller
      specify that the child being added should override (i.e. hide) any
      pre-existing children with the same name.
      """
      if self.is_hidden(model['path']) and not self.allow_hidden:
        return
      if (name in children) and not override_existing:
        return
      children[name] = model

    dir_gcs_path = self._gcs_path(normalized_path)
    for b in self.bucket.list_blobs(prefix=dir_gcs_path):
      # For each nested blob, identify the corresponding immediate child
      # of the directory, and then add that child to the directory model.
      prefix_len = len(dir_gcs_path)+1 if dir_gcs_path else 0
      suffix = b.name[prefix_len:]
      if suffix:  # Ignore the place-holder blob for the directory itself
        first_slash = suffix.find('/')
        if first_slash < 0:
          child_path = posixpath.join(normalized_path, suffix)
          add_child(suffix,
                    self._blob_model(child_path, b, content=False),
                    override_existing=True)
        else:
          subdir = suffix[0:first_slash]
          if subdir:
            child_path = posixpath.join(normalized_path, subdir)
            add_child(subdir, self._empty_dir_model(child_path, content=False))

    for child in children:
      dir_obj['content'].append(children[child])

    return dir_obj

  def get(self, path, content=True, type=None, format=None):
    try:
      path = self._normalize_path(path)
      if not type and self.dir_exists(path):
        type = 'directory'
      if type == 'directory':
        return self._list_dir(path, content=content)

      gcs_path = self._gcs_path(path)
      blob = self.bucket.get_blob(gcs_path)
      return self._blob_model(path, blob, content=content)
    except HTTPError as err:
      raise err
    except Exception as ex:
      raise HTTPError(500, 'Internal server error: {}'.format(str(ex)))

  def _mkdir(self, normalized_path):
    gcs_path = self._gcs_path(normalized_path)+'/'
    blob = self.bucket.blob(gcs_path)
    blob.upload_from_string('', content_type='text/plain')
    return self._empty_dir_model(normalized_path, content=False)

  def save(self, model, path):
    try:
      self.run_pre_save_hook(model=model, path=path)

      normalized_path = self._normalize_path(path)
      if model['type'] == 'directory':
        return self._mkdir(normalized_path)

      gcs_path = self._gcs_path(normalized_path)
      blob = self.bucket.get_blob(gcs_path)
      if not blob:
        blob = self.bucket.blob(gcs_path)

      content_type = model.get('mimetype', None)
      if not content_type:
        content_type, _ = mimetypes.guess_type(normalized_path)
      contents = model['content']
      if model['type'] == 'notebook':
        contents = nbformat.writes(nbformat.from_dict(contents))

      blob.upload_from_string(contents, content_type=content_type)
      return self.get(path, type=model['type'], content=False)
    except HTTPError as err:
      raise err
    except Exception as ex:
      raise HTTPError(500, 'Internal server error: {}'.format(str(ex)))

  def delete_file(self, path):
    try:
      normalized_path = self._normalize_path(path)
      gcs_path = self._gcs_path(normalized_path)
      blob = self.bucket.get_blob(gcs_path)
      if blob:
        # The path corresponds to a regular file; just delete it.
        blob.delete()
        return None

      # The path (possibly) corresponds to a directory. Delete
      # every file underneath it.
      for blob in self.bucket.list_blobs(prefix=gcs_path):
        blob.delete()

      return None
    except HTTPError as err:
      raise err
    except Exception as ex:
      raise HTTPError(500, 'Internal server error: {}'.format(str(ex)))

  def rename_file(self, old_path, new_path):
    try:
      old_gcs_path = self._gcs_path(self._normalize_path(old_path))
      new_gcs_path = self._gcs_path(self._normalize_path(new_path))
      blob = self.bucket.get_blob(old_gcs_path)
      if blob:
        # The path corresponds to a regular file.
        self.bucket.rename_blob(blob, new_gcs_path)
        return None

      # The path (possibly) corresponds to a directory. Rename
      # every file underneath it.
      for b in self.bucket.list_blobs(prefix=old_gcs_path):
        self.bucket.rename_blob(b, b.name.replace(old_gcs_path, new_gcs_path))
      return None
    except HTTPError as err:
      raise err
    except Exception as ex:
      raise HTTPError(500, 'Internal server error: {}'.format(str(ex)))


c.Application.log_level = 'DEBUG'
c.JupyterApp.answer_yes = True
c.NotebookApp.ip = '*'
c.NotebookApp.allow_root= True
c.NotebookApp.open_browser = False
c.NotebookApp.port = ${JUPYTER_PORT}
c.NotebookApp.token = u''
c.NotebookApp.contents_manager_class = GCSContentsManager
c.GCSContentsManager.bucket_name = '${NOTEBOOK_BUCKET}'
c.GCSContentsManager.bucket_notebooks_path = '${NOTEBOOK_PATH}'
EOF

# If Knox is enabled, set some additional config options to allow proxying
if is_component_selected knox; then
  readonly cluster_ui_hostname=$(get_dataproc_property \
    dataproc.proxy.public.hostname |
    sed 's/\\:/:/') # Unescape the colon in the URL
  cat <<EOF >>"${JUPYTER_CONFIG_FILE}"
c.NotebookApp.base_url = "/gateway/default/jupyter"
c.NotebookApp.allow_origin_pat = "(https?://)?(${cluster_ui_hostname}|localhost:8443)"
c.NotebookApp.disable_check_xsrf = True
EOF
fi

# Create ipython profile
"${CONDA_DIRECTORY}"/bin/ipython profile create

# Load google-cloud-bigquery when ipython starts
ipython_profile_location="$("${CONDA_DIRECTORY}"/bin/ipython profile locate default)"
echo "c.InteractiveShellApp.extensions.append('google.cloud.bigquery')" >>"${ipython_profile_location}/ipython_config.py"

# Enable Jupyter extensions
if is_version_at_least "${DATAPROC_VERSION}" "1.5"; then
  "${ANACONDA_BIN_DIR}/jupyter" nbextension enable widgetsnbextension --py --system
  "${ANACONDA_BIN_DIR}/jupyter" nbextension install nbdime --py --system
  "${ANACONDA_BIN_DIR}/jupyter" nbextension enable nbdime --py --system
  "${ANACONDA_BIN_DIR}/jupyter" serverextension enable jupyter_http_over_ws --py --system
  "${ANACONDA_BIN_DIR}/jupyter" serverextension enable jupyterlab_git --py --system
  "${ANACONDA_BIN_DIR}/jupyter" serverextension enable nbdime --py --system
  "${ANACONDA_BIN_DIR}/jupyter" lab build
  "${ANACONDA_BIN_DIR}/jupyter" lab clean
fi

# Enable SparkMonitor for Jupyter only for Dataproc 1.5+
# This for now will only work with Python 3 kernel. Details are at (b/134432143)
if is_version_at_least "${DATAPROC_VERSION}" "1.5"; then
  "${CONDA_DIRECTORY}"/bin/jupyter nbextension install sparkmonitor --py --system --symlink
  "${CONDA_DIRECTORY}"/bin/jupyter nbextension enable sparkmonitor --py --system
  "${CONDA_DIRECTORY}"/bin/jupyter serverextension enable --py --system sparkmonitor
  ipython_profile_location="$("${CONDA_DIRECTORY}"/bin/ipython profile locate default)"
  echo "c.InteractiveShellApp.extensions.append('sparkmonitor.kernelextension')" >>"${ipython_profile_location}/ipython_kernel_config.py"
fi

echo "Creating kernelspec"
mkdir -p "$(dirname "${PYSPARK_KERNELSPEC}")"
chmod a+r "$(dirname "${PYSPARK_KERNELSPEC}")"

# Jupyter requires Anaconda.
PYTHON=/opt/conda/anaconda/bin/python

# {connection_file} is a magic variable that Jupyter fills in for us
# Note: we can only use it in argv, so cannot use env to set those
# environment variables.
echo "Generating ${PYSPARK_KERNELSPEC}"
cat <<EOF >"${PYSPARK_KERNELSPEC}"
{
  "argv": [
    "bash",
    "-c",
    "PYSPARK_DRIVER_PYTHON_OPTS='kernel -f {connection_file}' pyspark"
  ],
  "display_name": "PySpark",
  "language": "python",
  "env": {
    "PYSPARK_DRIVER_PYTHON": "/opt/conda/anaconda/bin/ipython",
    "PYSPARK_PYTHON": "${PYTHON}"
  }
}
EOF

# Update Python kernel with needed environment variables for PySpark libs.
# Get python major version.
PYTHON_MAJOR_VERSION=$("${PYTHON}" -c "import platform; print(platform.python_version())" | cut -f1 -d'.')

PYTHON_KERNELSPEC=$(ls /opt/conda/anaconda/share/jupyter/kernels/python*/kernel.json)
echo "Generating ${PYTHON_KERNELSPEC}"
cat <<EOF >"${PYTHON_KERNELSPEC}"
{
  "argv": [
    "${PYTHON}",
    "-m",
    "ipykernel_launcher",
    "-f",
    "{connection_file}"
  ],
  "display_name": "Python ${PYTHON_MAJOR_VERSION}",
  "language": "python",
  "env": {
    "PYSPARK_PYTHON": "${PYTHON}",
    "SPARK_HOME": "/usr/lib/spark"
  }
}
EOF

# Ensure Jupyter has picked up the new kernel
jupyter kernelspec list | grep kernels/pyspark ||
  log_and_fail "jupyter" "Failed to create PySpark kernelspec"
jupyter kernelspec list | grep kernels/python ||
  log_and_fail "jupyter" "Failed to create Python kernelspec"

if is_version_at_least "${DATAPROC_VERSION}" "1.4"; then
  jupyter kernelspec list | grep kernels/spylon ||
    log_and_fail "jupyter" "Failed to create Spylon kernelspec"
fi

if is_version_at_least "${DATAPROC_VERSION}" "1.5"; then
  jupyter kernelspec list | grep kernels/ir ||
    log_and_fail "jupyter" "Failed to create R kernelspec"

  # Fix R kernel to get Spark libraries out of the box.
  echo "Generating ${R_KERNELSPEC}"
  cat <<EOF >"${R_KERNELSPEC}"
{
  "argv": [
    "R",
    "--slave",
    "-e",
    "IRkernel::main()",
    "--args",
    "{connection_file}"
  ],
  "display_name": "R",
  "language": "R",
  "env": {
    "SPARK_HOME": "/usr/lib/spark",
    "R_LIBS_USER": "/opt/conda/anaconda/lib/R/library:/usr/lib/spark/R/lib"
  }
}
EOF
fi

parse_jupyterhub_env() {
  python3 - <<END
import json
import os

env_string = os.environ['JUPYTERHUB_ENV']
env_dict = json.loads(env_string)

for key, value in env_dict.items():
  print(f'Environment={key}={value}')
END
}

JUPYTERHUB_ENABLED=$(get_dataproc_property jupyter.hub.enabled)

cat <<EOF > "${JUPYTER_ENV_FILE}"
PATH=/opt/conda/moove-dataproc/bin:/opt/conda/moove-dataproc/condabin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PYTHONPATH=/opt/conda/moove-dataproc/share/qgis/python/plugins:/opt/conda/moove-dataproc/share/qgis/python
GDAL_DATA=/opt/conda/moove-dataproc/share/gdal
PROJ_LIB=/opt/conda/moove-dataproc/share/proj
QT_QPA_PLATFORM=offscreen
EOF


# If Jupyterhub is enabled, then pass it the environment and arguments.
# Frontend validation will ensure that the image being used has python3 as the
# default and has the expected dependencies before running Jupyterhub-singleuser
if [[ "${JUPYTERHUB_ENABLED}" == "true" ]]; then

  # Formatted as a JSON-parsable string of (key,value) pairs by the
  # DataprocSpawner, will be parsed into a dictionary later
  # Reference: https://jupyterhub.readthedocs.io/en/stable/api/spawner.html#jupyterhub.spawner.Spawner.environment
  JUPYTERHUB_ENV=$(get_dataproc_property jupyter.hub.env)
  export JUPYTERHUB_ENV=$JUPYTERHUB_ENV
  # Formatted as ENVIRONMENT={key}={value}
  JUPYTERHUB_ENV_PARSED=$(parse_jupyterhub_env)
  JUPYTERHUB_ARGS=$(get_dataproc_property jupyter.hub.args)

  # Disable xsrf in case this is an AI Platform JupyterHub spawned notebook
  # that lives behind the inverting proxy
  echo 'c.NotebookApp.disable_check_xsrf = True' >> "${JUPYTER_CONFIG_FILE}"

  echo "Generating ${JUPYTERHUB_SYSTEMD_UNIT}"
  cat <<EOF >"${JUPYTERHUB_SYSTEMD_UNIT}"
  [Unit]
  Description=Jupyter Notebook Server
  After=hadoop-yarn-resourcemanager.service
  [Service]
  Type=simple
  EnvironmentFile=${JUPYTER_ENV_FILE}
  ExecStart=/bin/bash -c '/opt/conda/moove-dataproc/bin/jupyter-lab &> /var/log/jupyter_notebook.log'
  Restart=on-failure
  [Install]
  WantedBy=multi-user.target
EOF

  run_with_retries systemctl daemon-reload
  run_with_retries systemctl enable jupyterhub
  run_with_retries systemctl start jupyterhub

else
  echo "Generating ${JUPYTER_SYSTEMD_UNIT}"
  cat <<EOF >"${JUPYTER_SYSTEMD_UNIT}"
  [Unit]
  Description=Jupyter Notebook Server
  After=hadoop-yarn-resourcemanager.service
  [Service]
  Type=simple
  EnvironmentFile=${JUPYTER_ENV_FILE}
  ExecStart=/bin/bash -c '/opt/conda/moove-dataproc/bin/jupyter-lab &> /var/log/jupyter_notebook.log'
  Restart=on-failure
  [Install]
  WantedBy=multi-user.target
EOF

  run_with_retries systemctl daemon-reload
  run_with_retries systemctl enable jupyter
  run_with_retries systemctl start jupyter
fi
