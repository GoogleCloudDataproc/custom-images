# Copyright 2019 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the 'License');
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#            http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an 'AS IS' BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""
Infer arguments for Dataproc custom image build.
"""

import logging
import os
import re
import subprocess
import tempfile

_IMAGE_PATH = "projects/{}/global/images/{}"
_IMAGE_URI = re.compile(
    r"https:\/\/www\.googleapis\.com\/compute\/([^\/]+)\/projects\/([^\/]+)\/global\/images\/([^\/]+)$"
)
logging.basicConfig()
_LOG = logging.getLogger(__name__)
_LOG.setLevel(logging.INFO)


def _get_project_id():
  """Get project id from gcloud config."""
  gcloud_command = ["gcloud", "config", "get-value", "project"]
  with tempfile.NamedTemporaryFile() as temp_file:
    pipe = subprocess.Popen(gcloud_command, stdout=temp_file)
    pipe.wait()
    if pipe.returncode != 0:
      raise RuntimeError("Cannot find gcloud project ID. "
                         "Please setup the project ID in gcloud SDK")
    # get proejct id
    temp_file.seek(0)
    stdout = temp_file.read()
    return stdout.decode('utf-8').strip()


def _extract_image_name_and_project(image_uri):
  """Get Dataproc image name and project."""
  m = _IMAGE_URI.match(image_uri)
  return m.group(2), m.group(3)  # project, image_name


def _get_dataproc_image_version(image_uri):
  """Get Dataproc image version from image URI."""
  project, image_name = _extract_image_name_and_project(image_uri)
  command = [
      "gcloud", "compute", "images", "describe", image_name, "--project",
      project, "--format=value(labels.goog-dataproc-version)"
  ]

  # get stdout from compute images list --filters
  with tempfile.NamedTemporaryFile() as temp_file:
    pipe = subprocess.Popen(command, stdout=temp_file)
    pipe.wait()
    if pipe.returncode != 0:
      raise RuntimeError(
          "Cannot find dataproc base image, please check and verify "
          "the base image URI.")

    temp_file.seek(0)  # go to start of the stdout
    stdout = temp_file.read()
    # parse the first ready image with the dataproc version attached in labels
    if stdout:
      parsed_line = stdout.decode('utf-8').strip()  # should be just one value
      return parsed_line

  raise RuntimeError("Cannot find dataproc base image: %s", image_uri)


def _extract_image_path(image_uri):
  """Get the partial image URI from the full image URI."""
  project, image_name = _extract_image_name_and_project(image_uri)
  return _IMAGE_PATH.format(project, image_name)


def _get_dataproc_image_path_by_version(version):
  """Get Dataproc base image name from version."""
  # version regex already checked in arg parser
  parsed_version = version.split(".")
  filter_arg = "--filter=labels.goog-dataproc-version=\'{}-{}-{}\'".format(
      parsed_version[0], parsed_version[1], parsed_version[2])
  command = [
      "gcloud", "compute", "images", "list", "--project", "cloud-dataproc",
      filter_arg, "--format=csv[no-heading=true](name,status)"
  ]

  # get stdout from compute images list --filters
  with tempfile.NamedTemporaryFile() as temp_file:
    pipe = subprocess.Popen(command, stdout=temp_file)
    pipe.wait()
    if pipe.returncode != 0:
      raise RuntimeError(
          "Cannot find dataproc base image, please check and verify "
          "[--dataproc-version]")

    temp_file.seek(0)  # go to start of the stdout
    stdout = temp_file.read()
    # parse the first ready image with the dataproc version attached in labels
    if stdout:
      parsed_line = stdout.decode('utf-8').strip().split(
          ",")  # should only be one image
      if len(
          parsed_line) == 2 and parsed_line[0] and parsed_line[1] == "READY":
        return _IMAGE_PATH.format('cloud-dataproc', parsed_line[0])

  raise RuntimeError(
      "Cannot find dataproc base image with "
      "dataproc-version=%s.", version)


def _infer_project_id(args):
  if not args.project_id:
    args.project_id = _get_project_id()


def _infer_base_image(args):
  # get dataproc base image from dataproc version
  _LOG.info("Getting Dataproc base image name...")
  args.parsed_image_version = False
  if args.base_image_uri:
    args.dataproc_base_image = _extract_image_path(args.base_image_uri)
    args.dataproc_version = _get_dataproc_image_version(args.base_image_uri)
    args.parsed_image_version = True
  elif args.dataproc_version:
    args.dataproc_base_image = _get_dataproc_image_path_by_version(args.dataproc_version)
  else:
    raise RuntimeError(
        "Neither --dataproc-version nor --base-image-uri is specified.")
  _LOG.info("Returned Dataproc base image: %s", args.dataproc_base_image)


def _infer_oauth(args):
  if args.oauth:
    args.oauth = "\n    \"OAuthPath\": \"{}\",".format(
        os.path.abspath(args.oauth))
  else:
    args.oauth = ""


def _infer_daisy_sources(args):
  if args.daisy_path:
    run_script_path = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                                   "startup_script/run.sh")
    daisy_sources = {
        "run.sh": run_script_path,
        "init_actions.sh": os.path.abspath(args.customization_script)
    }
    daisy_sources.update(args.extra_sources)
    args.sources = ",\n".join([
        "\"{}\": \"{}\"".format(source, path)
        for source, path in daisy_sources.items()
    ])


def _infer_network(args):
  # When the user wants to create a VM in a shared VPC,
  # only the subnetwork argument has to be provided whereas
  # the network one has to be left empty.
  if not args.network and not args.subnetwork:
    args.network = 'global/networks/default'
  # The --network flag requires format global/networks/<network>, which works
  # for Daisy but not for gcloud, here we convert it to
  # projects/<project>/global/networks/<network>, so that works for both.
  if args.network.startswith('global/networks/'):
    args.network = 'projects/{}/{}'.format(args.project_id, args.network)


def infer_args(args):
  _infer_project_id(args)
  _infer_base_image(args)
  _infer_oauth(args)
  _infer_daisy_sources(args)
  _infer_network(args)
  args.shutdown_timer_in_sec = args.shutdown_instance_timer_sec
