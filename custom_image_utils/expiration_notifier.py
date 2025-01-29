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
Notify expiration for Dataproc custom images.
"""

import datetime
import logging
import subprocess
import tempfile

logging.basicConfig()
_LOG = logging.getLogger(__name__)
_LOG.setLevel(logging.WARN)

_expiration_notification_text = """\

#####################################################################
  WARNING: DATAPROC CUSTOM IMAGE '{}'
           WILL EXPIRE ON {}.
#####################################################################

"""


def _parse_date_time(timestamp_string):
  """Parses a timestamp string (RFC3339) to datetime format."""

  return datetime.datetime.strptime(timestamp_string[:-6],
                                    "%Y-%m-%dT%H:%M:%S.%f")


def _get_image_creation_timestamp(image_name, project_id):
  """Gets the creation timestamp of the custom image."""

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


def notify(args):
  """Notifies when the image will expire."""

  if not args.dry_run:
    _LOG.info("Successfully built Dataproc custom image: %s", args.image_name)
    creation_date = _parse_date_time(
        _get_image_creation_timestamp(args.image_name, args.project_id))
    expiration_date = creation_date + datetime.timedelta(days=365)
    _LOG.info(
        _expiration_notification_text.format(args.image_name,
                                             str(expiration_date)))
  else:
    _LOG.info("Dry run succeeded.")
