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

import unittest
import exceptions
from custom_image_utils import args_parser


class TestArgsParser(unittest.TestCase):

  def test_missing_required_args(self):
    """Verifies it fails if missing required args."""
    with self.assertRaises(SystemExit) as e:
      args_parser.parse_args([])

  def test_minimal_required_args(self):
    """Verifies it succeeds if all required args are present."""
    customization_script = '/tmp/my-script.sh'
    gcs_bucket = 'gs://my-bucket'
    image_name = 'my-image'
    zone = 'us-west1-a'

    args = args_parser.parse_args([
        '--image-name', image_name,
        '--customization-script', customization_script,
        '--zone', zone,
        '--gcs-bucket', gcs_bucket])

    expected_result = self._make_expected_result(
        accelerator=None,
        base_image_family="None",
        base_image_uri="None",
        customization_script="'{}'".format(customization_script),
        dataproc_version="None",
        disk_size="20",
        dry_run=False,
        extra_sources="{}",
        family="'dataproc-custom-image'",
        gcs_bucket="'{}'".format(gcs_bucket),
        image_name="'{}'".format(image_name),
        machine_type="'n1-standard-1'",
        network="'{}'".format(''),
        no_external_ip="False",
        no_smoke_test="False",
        oauth="None",
        project_id="None",
        service_account="'default'",
        shutdown_instance_timer_sec="300",
        storage_location=None,
        subnetwork="''",
        zone="'{}'".format(zone),
        metadata=None
    )
    self.assertEqual(str(args), expected_result)

  def test_optional_args(self):
    """Verifies it succeeds with optional arguments specified."""
    accelerator = 'type=nvidia-tesla-v100,count=2'
    customization_script = '/tmp/my-script.sh'
    dataproc_version = '1.4.5-debian9'
    disk_size = 40
    dry_run = True
    family = 'debian9'
    gcs_bucket = 'gs://my-bucket'
    image_name = 'my-image'
    machine_type = 'n1-standard-4'
    network = 'my-network'
    no_external_ip = True
    no_smoke_test = True
    oauth = 'xyz'
    project_id = 'my-project'
    service_account = "my-service-account"
    shutdown_instance_timer_sec = 567
    storage_location = 'us-east1'
    subnetwork = 'my-subnetwork'
    zone = 'us-west1-a'
    metadata = 'key1=value1,key2=value2'

    args = args_parser.parse_args([
        '--accelerator', str(accelerator),
        '--customization-script', customization_script,
        '--dataproc-version', dataproc_version,
        '--disk-size', str(disk_size),
        '--dry-run',
        '--family', family,
        '--gcs-bucket', gcs_bucket,
        '--image-name', image_name,
        '--machine-type', machine_type,
        '--network', network,
        '--no-external-ip',
        '--no-smoke-test',
        '--oauth', oauth,
        '--project-id', project_id,
        '--service-account', service_account,
        '--shutdown-instance-timer-sec', str(shutdown_instance_timer_sec),
        '--storage-location', str(storage_location),
        '--subnetwork', subnetwork,
        '--zone', zone,
        '--metadata', metadata,
    ])

    expected_result = self._make_expected_result(
        accelerator="'{}'".format(accelerator),
        base_image_family="None",        
        base_image_uri="None",
        customization_script="'{}'".format(customization_script),
        dataproc_version="'{}'".format(dataproc_version),
        disk_size="{}".format(disk_size),
        dry_run="{}".format(dry_run),
        extra_sources="{}",
        family="'{}'".format(family),
        gcs_bucket="'{}'".format(gcs_bucket),
        image_name="'{}'".format(image_name),
        machine_type="'{}'".format(machine_type),
        metadata="'{}'".format(metadata),
        network="'{}'".format(network),
        no_external_ip="{}".format(no_external_ip),
        no_smoke_test="{}".format(no_smoke_test),
        oauth="'{}'".format(oauth),
        project_id="'{}'".format(project_id),
        service_account="'{}'".format(service_account),
        shutdown_instance_timer_sec="{}".format(shutdown_instance_timer_sec),
        storage_location="'{}'".format(storage_location),
        subnetwork="'{}'".format(subnetwork),
        zone="'{}'".format(zone),
    )
    self.assertEqual(str(args), expected_result)

  def test_inferred_subminor_versions(self):
    """Verifies it succeeds if inferred/unspecified subminor version is correctly formatted."""
    customization_script = '/tmp/my-script.sh'
    gcs_bucket = 'gs://my-bucket'
    image_name = 'my-image'
    zone = 'us-west1-a'

    def _args_parsed(dataproc_version):
      return args_parser.parse_args([
          '--image-name', image_name,
          '--dataproc-version', dataproc_version,
          '--customization-script', customization_script,
          '--zone', zone,
          '--gcs-bucket', gcs_bucket])

    def _expected_result(dataproc_version):
       return self._make_expected_result(
          accelerator=None,
          base_image_family="None",
          base_image_uri="None",
          customization_script="'{}'".format(customization_script),
          dataproc_version="'{}'".format(dataproc_version),
          disk_size="20",
          dry_run=False,
          extra_sources="{}",
          family="'dataproc-custom-image'",
          gcs_bucket="'{}'".format(gcs_bucket),
          image_name="'{}'".format(image_name),
          machine_type="'n1-standard-1'",
          network="'{}'".format(''),
          no_external_ip="False",
          no_smoke_test="False",
          oauth="None",
          project_id="None",
          service_account="'default'",
          shutdown_instance_timer_sec="300",
          storage_location=None,
          subnetwork="''",
          zone="'{}'".format(zone),
          metadata=None
    )

    def _args_exception(dataproc_version):
      # Checks that inputs produce an exception
      try:
        _args_parsed(dataproc_version)
      except SystemExit as e:
        self.assertEqual(e.__class__, exceptions.SystemExit)
      else:
        raise ValueError("Exception not raised")

    self.assertEqual(str(_args_parsed('1.5-debian10')), _expected_result('1.5-debian10'))
    self.assertEqual(str(_args_parsed('1.3-ubuntu18')), _expected_result('1.3-ubuntu18'))
    self.assertEqual(str(_args_parsed('1.3-centos8')), _expected_result('1.3-centos8'))

    invalid_dataproc_versions = ['*.*.*-debian10', '1.**.*-debian10', '1.*.8*-debian10', '11.*.*-debian', 
      '1.*-debian10', '1.5.*-debian10', '1.5.-debian10', '1.*.*-debian10']
    try:
      for version in invalid_dataproc_versions:
        _args_exception(version)
    except ValueError as e:
      raise e

  def _make_expected_result(
      self,
      accelerator,
      base_image_family,      
      base_image_uri,
      customization_script,
      dataproc_version,
      disk_size,
      dry_run,
      extra_sources,
      family,
      gcs_bucket,
      image_name,
      machine_type,
      metadata,
      network,
      no_external_ip,
      no_smoke_test,
      oauth,
      project_id,
      service_account,
      shutdown_instance_timer_sec,
      storage_location,
      subnetwork,
      zone):
    expected_result_template = (
        "Namespace("
        "accelerator={}, "
        "base_image_family={}, "        
        "base_image_uri={}, "
        "customization_script={}, "
        "dataproc_version={}, "
        "disk_size={}, "
        "dry_run={}, "
        "extra_sources={}, "
        "family={}, "
        "gcs_bucket={}, "
        "image_name={}, "
        "machine_type={}, "
        "metadata={}, "
        "network={}, "
        "no_external_ip={}, "
        "no_smoke_test={}, "
        "oauth={}, "
        "project_id={}, "
        "service_account={}, "
        "shutdown_instance_timer_sec={}, "
        "storage_location={}, "
        "subnetwork={}, "
        "zone={})")
    return expected_result_template.format(
        accelerator,
        base_image_family,        
        base_image_uri,
        customization_script,
        dataproc_version,
        disk_size,
        dry_run,
        extra_sources,
        family,
        gcs_bucket,
        image_name,
        machine_type,
        metadata,
        network,
        no_external_ip,
        no_smoke_test,
        oauth,
        project_id,
        service_account,
        shutdown_instance_timer_sec,
        storage_location,
        subnetwork,
        zone)

if __name__ == '__main__':
    unittest.main()
