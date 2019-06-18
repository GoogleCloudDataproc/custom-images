# Copyright 2017 Google Inc. All Rights Reserved.
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
"""Generate custom Dataproc image.

This python script is used to generate a custom Dataproc image for the user.

With the required arguments such as custom install packages script and
Dataproc version, this script will run the following steps in order:
  1. Get user's gcloud project ID.
  2. Get Dataproc's base image name with Dataproc version.
  3. Run Shell script or Daisy workflow to create a custom Dataproc image.
    1. Create a disk with Dataproc's base image.
    2. Create an GCE instance with the disk.
    3. Run custom install packages script to install custom packages.
    4. Shutdown instance.
    5. Create custom Dataproc image from the disk.
  4. Set the custom image label (required for launching custom Dataproc image).
  5. Run a Dataproc workflow to smoke test the custom image.

Once this script is completed, the custom Dataproc image should be ready to use.

"""

import datetime
import logging
import os
import re
import subprocess
import sys
import tempfile
import uuid

from custom_image_utils import args_parser
from custom_image_utils import args_inferer
from custom_image_utils import constants
from custom_image_utils import daisy_image_creator
from custom_image_utils import image_labeller
from custom_image_utils import shell_image_creator
from custom_image_utils import smoke_test_runner


logging.basicConfig()
_LOG = logging.getLogger(__name__)
_LOG.setLevel(logging.INFO)


def get_custom_image_creation_timestamp(image_name, project_id):
  """Get the creation timestamp of the custom image."""
  # version regex already checked in arg parser
  command = [
      "gcloud", "compute", "images", "describe", image_name, "--project",
      project_id, "--format=csv[no-heading=true](creationTimestamp)"
  ]

  with tempfile.NamedTemporaryFile() as temp_file:
    pipe = subprocess.Popen(command, stdout=temp_file)
    pipe.wait()
    if pipe.returncode != 0:
      raise RuntimeError("Cannot get custom image creation timestamp.")

    # get creation timestamp
    temp_file.seek(0)
    stdout = temp_file.read()
    return stdout.decode('utf-8').strip()


def _parse_date_time(timestamp_string):
  """Parse a timestamp string (RFC3339) to datetime format."""
  return datetime.datetime.strptime(timestamp_string[:-6],
                                    "%Y-%m-%dT%H:%M:%S.%f")


def parse_args(raw_args):
  """Parses and infers command line arguments."""

  args = args_parser.parse_args(raw_args)
  _LOG.info("Parsed args: {}".format(args))
  args_inferer.infer_args(args)
  _LOG.info("Inferred args: {}".format(args))
  return args


def perform_sanity_checks(args):
  _LOG.info("Performing sanity checks...")

  # Daisy binary
  if args.daisy_path and not os.path.isfile(args.daisy_path):
    raise Exception("Invalid path to Daisy binary: '{}' is not a file.".format(
        args.daisy_path))

  # Customization script
  if not os.path.isfile(args.customization_script):
    raise Exception("Invalid path to customization script: '{}' is not a file.".format(
        args.customization_script))

  # Check the image doesn't already exist.
  command = "gcloud compute images describe {} --project={}".format(
      args.image_name, args.project_id)
  with open(os.devnull, 'w') as devnull:
    pipe = subprocess.Popen(
        [command], stdout=devnull, stderr=devnull, shell=True)
    pipe.wait()
    if pipe.returncode == 0:
      raise RuntimeError("Image {} already exists.".format(args.image_name))

  _LOG.info("Passed sanity checks...")


def notify_expiration(args):
  """Notifies when the image will expire."""

  if not args.dry_run:
    _LOG.info("Successfully built Dataproc custom image: %s", args.image_name)
    creation_date = _parse_date_time(
        get_custom_image_creation_timestamp(args.image_name, args.project_id))
    expiration_date = creation_date + datetime.timedelta(days=60)
    _LOG.info(
        constants.notify_expiration_text.format(args.image_name,
                                                str(expiration_date)))
  else:
    _LOG.info("Dry run succeeded.")

def run():
  """Generates custom image."""

  args = parse_args(sys.argv[1:])
  perform_sanity_checks(args)
  if args.daisy_path:
    daisy_image_creator.create(args)
  else:
    shell_image_creator.create(args)
  image_labeller.add_label(args)
  smoke_test_runner.run(args)
  notify_expiration(args)


if __name__ == "__main__":
  run()
