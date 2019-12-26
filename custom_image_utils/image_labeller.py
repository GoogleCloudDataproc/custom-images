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
"""Add label to Dataproc custom images.
"""

import logging
import subprocess

logging.basicConfig()
_LOG = logging.getLogger(__name__)
_LOG.setLevel(logging.INFO)


def _set_custom_image_label(image_name, version, project_id):
  """Sets Dataproc version label in the custom image."""

  # Convert `1.5.0-RC1-debian9` version to `1-5-0-rc1-debian9` label
  version_label = version.replace('.', '-').lower()
  label_flag = "--labels=goog-dataproc-version={}".format(version_label)
  command = [
      "gcloud", "compute", "images", "add-labels", image_name, "--project",
      project_id, label_flag
  ]
  _LOG.info("Running: {}".format(" ".join(command)))

  # get stdout from compute images list --filters
  pipe = subprocess.Popen(command)
  pipe.wait()
  if pipe.returncode != 0:
    raise RuntimeError("Cannot set dataproc version to image label.")


def add_label(args):
  """Sets Dataproc version label in the custom image."""

  if not args.dry_run:
    _LOG.info("Setting label on custom image...")
    _set_custom_image_label(args.image_name, args.dataproc_version,
                            args.project_id)
    _LOG.info("Successfully set label on custom image...")
  else:
    _LOG.info("Skip setting label on custom image (dry run).")
