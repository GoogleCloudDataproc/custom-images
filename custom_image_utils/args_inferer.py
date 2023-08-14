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
    r"^(https://www\.googleapis\.com/compute/([^/]+)/)?projects/([^/]+)/global/images/([^/]+)$"
)
_IMAGE_FAMILY_PATH = "projects/{}/global/images/family/{}"
_IMAGE_FAMILY_URI = re.compile(
    r"^(https://www\.googleapis\.com/compute/([^/]+)/)?projects/([^/]+)/global/images/family/([^/]+)$"
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
    # get project id
    temp_file.seek(0)
    stdout = temp_file.read()
    return stdout.decode('utf-8').strip()


def _extract_image_name_and_project(image_uri):
  """Get Dataproc image name and project."""
  m = _IMAGE_URI.match(image_uri)
  return m.group(3), m.group(4)  # project, image_name


def _extract_image_name_and_project_from_family_uri(image_uri):
  """Get Dataproc image family name and project."""
  m = _IMAGE_FAMILY_URI.match(image_uri)
  return m.group(3), m.group(4)  # project, image_name


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


def _get_dataproc_version_from_image_family(image_family_uri):
  """Get Dataproc image family version from family name."""
  project, image_family_name = _extract_image_name_and_project_from_family_uri(image_family_uri)
  command = [
      "gcloud", "compute", "images", "describe-from-family", image_family_name, "--project",
      project, "--format=value(labels.goog-dataproc-version)"
  ]

  # get stdout from compute images list --filters
  with tempfile.NamedTemporaryFile() as temp_file:
    pipe = subprocess.Popen(command, stdout=temp_file)
    pipe.wait()
    if pipe.returncode != 0:
      raise RuntimeError(
          "Cannot find dataproc base family image, please check and verify "
          "the family URI.")

    temp_file.seek(0)  # go to start of the stdout
    stdout = temp_file.read()
    # parse the first ready image with the dataproc version attached in labels
    if stdout:
      dataproc_version = stdout.decode('utf-8').strip()  # should be just one value
      return dataproc_version

  raise RuntimeError("Cannot find dataproc base image family: %s" %
                     image_family_uri)

def _extract_image_path(image_uri):
  """Get the partial image URI from the full image URI."""
  project, image_name = _extract_image_name_and_project(image_uri)
  return _IMAGE_PATH.format(project, image_name)

def _extract_image_family_path(image_family_uri):
  """Get the partial image family URI from the full image family URI."""
  project, image_name = _extract_image_name_and_project_from_family_uri(image_family_uri)
  return _IMAGE_FAMILY_PATH.format(project, image_name)

def _get_dataproc_image_path_by_version(version):
  """Get Dataproc base image name from version."""
  # version regex already checked in arg parser
  parsed_version = version.split(".")
  major_version = parsed_version[0]
  if len(parsed_version) == 2:
    # The input version must be of format 1.5-debian10 in which case we need to
    # expand it to 1-5-\d+-debian10 so we can do a regexp on the minor version
    minor_version = parsed_version[1].split("-")[0]
    parsed_version[1] = parsed_version[1].replace("-", "-\d+-")
    filter_arg = ("labels.goog-dataproc-version ~ ^{}-{} AND NOT name ~ -eap$"
                  " AND status = READY").format(parsed_version[0],
                                                parsed_version[1])
  else:
    major_version = parsed_version[0]
    minor_version = parsed_version[1]
    # Moreover, push the filter of READY status and name not containing 'eap' to
    # gcloud command so we don't have to iterate the list
    filter_arg = ("labels.goog-dataproc-version = {}-{}-{} AND NOT name ~ -eap$"
                  " AND status = READY").format(parsed_version[0],
                                                parsed_version[1],
                                                parsed_version[2])
  command = [
    "gcloud", "compute", "images", "list", "--project", "cloud-dataproc",
    "--filter", filter_arg, "--format",
    "csv[no-heading=true](name,labels.goog-dataproc-version)",
    "--sort-by=~creationTimestamp"
  ]

  _LOG.info("Executing command: {}".format(command))
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
      # in case there are multiple images
      parsed_lines = stdout.decode('utf-8').strip().split('\n')
      expected_prefix = "dataproc-{}-{}".format(major_version, minor_version)
      _LOG.info("Filtering images : %s", expected_prefix)
      image_versions=[]
      all_images_for_version = {}
      for line in parsed_lines:
        parsed_image = line.split(",")
        if len(parsed_image) == 2:
          parsed_image_name = parsed_image[0]
          if not parsed_image_name.startswith(expected_prefix):
            _LOG.info("Skipping non-release image %s", parsed_image_name)
            # Not a regular dataproc release image. Maybe a custom image with same label.
            continue
          parsed_image_version = parsed_image[1]
          if parsed_image_version not in all_images_for_version:
            all_images_for_version[parsed_image_version] = [_IMAGE_PATH.format("cloud-dataproc", parsed_image_name)]
            image_versions.append(parsed_image_version)
          else:
            all_images_for_version[parsed_image_version].append(_IMAGE_PATH.format("cloud-dataproc", parsed_image_name))

      _LOG.info("All Images : %s", all_images_for_version)
      _LOG.info("All Image-Versions : %s", image_versions)

      latest_available_version = image_versions[0]
      if (len(all_images_for_version[latest_available_version]) > 1):
        raise RuntimeError(
          "Found more than one images for latest dataproc-version={}. Images: {}".format(
            latest_available_version,
            str(all_images_for_version[latest_available_version])))

      _LOG.info("Choosing image %s with version %s", all_images_for_version[image_versions[0]][0], image_versions[0])
      return all_images_for_version[image_versions[0]][0], image_versions[0]

  raise RuntimeError(
    "Cannot find dataproc base image with dataproc-version=%s." % version)


def _infer_project_id(args):
  if not args.project_id:
    args.project_id = _get_project_id()


def _infer_base_image(args):
  # get dataproc base image from dataproc version
  _LOG.info("Getting Dataproc base image name...")
  if args.base_image_uri:
    args.dataproc_base_image = _extract_image_path(args.base_image_uri)
    args.dataproc_version = _get_dataproc_image_version(args.base_image_uri)
  elif args.dataproc_version:
    args.dataproc_base_image, args.dataproc_version = _get_dataproc_image_path_by_version(
        args.dataproc_version)
  elif args.base_image_family:
    args.dataproc_base_image = _extract_image_family_path(args.base_image_family)
    args.dataproc_version = _get_dataproc_version_from_image_family(args.base_image_family)
  else:
    raise RuntimeError(
        "Neither --dataproc-version nor --base-image-uri nor --source-image-family-uri is specified.")
  _LOG.info("Returned Dataproc base image: %s", args.dataproc_base_image)
  _LOG.info("Returned Dataproc version   : %s", args.dataproc_version)


def _infer_oauth(args):
  if args.oauth:
    args.oauth = "\n    \"OAuthPath\": \"{}\",".format(
        os.path.abspath(args.oauth))
  else:
    args.oauth = ""


def _infer_network(args):
  # When the user wants to create a VM in a shared VPC,
  # only the subnetwork argument has to be provided whereas
  # the network one has to be left empty.
  if not args.network and not args.subnetwork:
    args.network = 'global/networks/default'
  # The --network flag requires format global/networks/<network>,
  # which does not work for gcloud, here we convert it to
  # projects/<project>/global/networks/<network>.
  if args.network.startswith('global/networks/'):
    args.network = 'projects/{}/{}'.format(args.project_id, args.network)


def infer_args(args):
  _infer_project_id(args)
  _infer_base_image(args)
  _infer_oauth(args)
  _infer_network(args)
  args.shutdown_timer_in_sec = args.shutdown_instance_timer_sec
