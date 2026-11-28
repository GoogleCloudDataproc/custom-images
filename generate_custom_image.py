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
  3. Run Shell script to create a custom Dataproc image.
    1. Create a disk with Dataproc's base image.
    2. Create an GCE instance with the disk.
    3. Run custom install packages script to install custom packages.
    4. Shutdown instance.
    5. Create custom Dataproc image from the disk.
  4. Set the custom image label (required for launching custom Dataproc image).
  5. Run a Dataproc workflow to smoke test the custom image.

Once this script is completed, the custom Dataproc image should be ready to use.

"""

import logging
import os
import sys

from custom_image_utils import args_parser

logging.basicConfig()
_LOG = logging.getLogger(__name__)
_LOG.setLevel(logging.WARN)


def get_execution_engine(args):
  """Instantiates the appropriate execution engine."""
  if args.execution_engine == "api":
    from custom_image_utils.api_execution_engine import ApiExecutionEngine

    credentials = None
    if args.oauth:
      import google.auth

      credentials, _ = google.auth.load_credentials_from_file(args.oauth)

    return ApiExecutionEngine(credentials=credentials)
  else:
    from custom_image_utils.cli_execution_engine import CliExecutionEngine

    return CliExecutionEngine()


def main():
  """Generates custom image."""

  # Parse args
  args = args_parser.parse_args(sys.argv[1:])
  _LOG.info("Parsed args: {}".format(args))

  # Get selected execution engine
  engine = get_execution_engine(args)

  # Infer remaining arguments and check customization script path
  is_gcs_script = args.customization_script.startswith("gs://")
  if not is_gcs_script and not os.path.isfile(args.customization_script):
    raise Exception(
        "Invalid path to customization script: '{}' is not a file.".format(
            args.customization_script
        )
    )

  engine.infer_args(args)
  _LOG.info("Inferred args: {}".format(args))

  # Run custom image creation workflow
  engine.perform_sanity_checks(args)
  engine.create_image(args)
  engine.add_label(args)
  engine.run_smoke_test(args)
  engine.notify_expiration(args)


if __name__ == "__main__":
  main()
