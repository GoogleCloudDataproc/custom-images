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
"""Run smoke test for Dataproc custom images.
"""

import datetime
import logging
import subprocess
import uuid

logging.basicConfig()
_LOG = logging.getLogger(__name__)
_LOG.setLevel(logging.WARN)

def _create_workflow_template(workflow_name, image_name, project_id, zone, region,
                              network, subnet, no_external_ip):
  """Create a Dataproc workflow template for testing."""
  create_command = [
      "gcloud", "dataproc", "workflow-templates", "create",
      workflow_name, "--project", project_id, "--region", region
  ]
  set_cluster_command = [
      "gcloud", "dataproc", "workflow-templates",
      "set-managed-cluster", workflow_name, "--project", project_id, "--image",
      image_name, "--zone", zone, "--region", region
  ]
  if network and not subnet:
    set_cluster_command.extend(["--network", network])
  else:
    set_cluster_command.extend(["--subnet", subnet])
  if no_external_ip:
    set_cluster_command.extend(["--no-address"])
  add_job_command = [
      "gcloud", "dataproc", "workflow-templates", "add-job", "spark",
      "--workflow-template", workflow_name, "--project", project_id, "--region", region,
      "--step-id", "001", "--class", "org.apache.spark.examples.SparkPi",
      "--jars", "file:///usr/lib/spark/examples/jars/spark-examples.jar", "--",
      "1000"
  ]
  pipe = subprocess.Popen(create_command)
  pipe.wait()
  if pipe.returncode != 0:
    raise RuntimeError("Error creating Dataproc workflow template '%s'.",
                       workflow_name)

  pipe = subprocess.Popen(set_cluster_command)
  pipe.wait()
  if pipe.returncode != 0:
    raise RuntimeError(
        "Error setting cluster for Dataproc workflow template '%s'.",
        workflow_name)

  pipe = subprocess.Popen(add_job_command)
  pipe.wait()
  if pipe.returncode != 0:
    raise RuntimeError("Error adding job to Dataproc workflow template '%s'.",
                       workflow_name)


def _instantiate_workflow_template(workflow_name, project_id, region):
  """Run a Dataproc workflow template to test the newly built custom image."""
  command = [
      "gcloud", "dataproc", "workflow-templates", "instantiate",
      workflow_name, "--project", project_id, "--region", region
  ]
  pipe = subprocess.Popen(command)
  pipe.wait()
  if pipe.returncode != 0:
    raise RuntimeError("Unable to instantiate workflow template.")


def _delete_workflow_template(workflow_name, project_id, region):
  """Delete a Dataproc workflow template."""
  command = [
      "gcloud", "dataproc", "workflow-templates", "delete",
      workflow_name, "-q", "--project", project_id, "--region", region
  ]
  pipe = subprocess.Popen(command)
  pipe.wait()
  if pipe.returncode != 0:
    raise RuntimeError("Error deleting workfloe template %s.", workflow_name)


def _verify_custom_image(image_name, project_id, zone, network, subnetwork, no_external_ip):
  """Verifies if custom image works with Dataproc."""
  region = zone[:-2]
  date = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
  # Note: workflow_name can collide if the script runs more than 10000
  # times/second.
  workflow_name = "verify-image-{}-{}".format(date, uuid.uuid4().hex[-8:])
  try:
    _LOG.info("Creating Dataproc workflow-template %s with image %s...",
              workflow_name, image_name)
    _create_workflow_template(workflow_name, image_name, project_id, zone, region,
                              network, subnetwork, no_external_ip)
    _LOG.info(
        "Successfully created Dataproc workflow-template %s with image %s...",
        workflow_name, image_name)
    _LOG.info("Smoke testing Dataproc workflow-template %s...")
    _instantiate_workflow_template(workflow_name, project_id, region)
    _LOG.info("Successfully smoke tested Dataproc workflow-template %s...",
              workflow_name)
  except RuntimeError as e:
    err_msg = "Verification of custom image {} failed: {}".format(
        image_name, e)
    _LOG.error(err_msg)
    raise RuntimeError(err_msg)
  finally:
    try:
      _LOG.info("Deleting Dataproc workflow-template %s...", workflow_name)
      _delete_workflow_template(workflow_name, project_id, region)
      _LOG.info("Successfully deleted Dataproc workflow-template %s...",
                workflow_name)
    except RuntimeError:
      pass


def run(args):
  """Runs smoke test."""

  if not args.dry_run:
    if not args.no_smoke_test:
      _LOG.info("Verifying the custom image...")
      _verify_custom_image(args.image_name, args.project_id, args.zone,
                           args.network, args.subnetwork, args.no_external_ip)
      _LOG.info("Successfully verified the custom image...")
  else:
    _LOG.info("Skip running smoke test (dry run).")
