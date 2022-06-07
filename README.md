# Build Dataproc custom images

This page describes how to generate a custom Dataproc image.

## Important notes

To help ensure that clusters receive the latest service updates and bug fixes,
the creation of clusters with a custom image is limited to **60 days** from the
image creation date, but existing custom-image clusters can run indefinitely.
Automation to continuously build a custom image may be necessary if you wish to
create clusters with a custom image for a period greater than 60 days.

Creating clusters with expired custom images is possible by following these
[instructions](https://cloud.google.com/dataproc/docs/guides/dataproc-images#how_to_create_a_cluster_with_an_expired_custom_image),
but Cloud Dataproc cannot guarantee support of issues that arise with these
clusters.

## Requirements

1.  Python 2.7+.
2.  gcloud 181.0.0 (2017-11-30).
3.  Bash 3.0.
4.  A GCE project with billing, Google Cloud Dataproc API, Google Compute Engine
    API, and Google Cloud Storage APIs enabled.
5.  Use `gcloud config set project <your-project>` to specify which project to
    use to create and save your custom image.

## Generate custom image

To generate a custom image, you can run the following command:

```shell
python generate_custom_image.py \
    --image-name '<new_custom_image_name>' \
    --dataproc-version '<dataproc_version>' \
    --customization-script '<custom_script_to_install_custom_packages>' \
    --zone '<zone_to_create_instance_to_build_custom_image>' \
    --gcs-bucket '<gcs_bucket_to_write_logs>'
```

### Arguments

*   **--image-name**: The name for custom image.
*   **--dataproc-version**: The Dataproc version for this custom image to build
    on. Examples: `1.5.9-debian10`, `1.5.0-RC10-debian10`, `1.5.9-ubuntu18`. If
    the sub-minor version is unspecified, the latest available one will be used.
    Examples: `1.5-centos8`, `2.0-debian10`. For a complete list of Dataproc
    image versions, please refer to Dataproc
    [release notes](https://cloud.google.com/dataproc/docs/release-notes). To
    understand Dataproc versioning, please refer to
    [documentation](https://cloud.google.com/dataproc/docs/concepts/versioning/overview).
    **This argument is mutually exclusive with `--base-image-uri` and
    `--source-image-family`**.
*   **--base-image-uri**: The full image URI for the base Dataproc image. The
    customization script will be executed on top of this image instead of an
    out-of-the-box Dataproc image. This image must be a valid Dataproc image.
    **This argument is mutually exclusive with `--dataproc-version` and
    `--source-image-family`**.
*   **--base-image-family**: The image family that the boot disk will be
    initialized with. The latest non-deprecated image from the family will be
    used. An example base image family URI is
    `projects/PROJECT_NAME/global/images/family/<FAMILY_NAME>`. To get the list
    of image families (and the associated image), run `gcloud compute images
    list [--project <PROJECT_NAME>]`. **This argument is mutually exclusive with
    `--dataproc-version` and `--base-image-uri`**.
*   **--customization-script**: The script used to install custom packages on
    the image.
*   **--zone**: The GCE zone for running your GCE instance.
*   **--gcs-bucket**: A GCS bucket to store the logs of building custom image.

#### Optional Arguments

*   **--family**: The family of the source image. This will cause the latest
    non-deprecated image in the family to be used as the source image.
*   **--project-id**: The project Id of the project where the custom image is
    created and saved. The default project Id is the current project id
    specified in `gcloud config get-value project`.
*   **--oauth**: The OAuth credential file used to call Google Cloud APIs. The
    default OAuth is the application-default credentials from gcloud.
*   **--machine-type**: The machine type used to build custom image. The default
    is `n1-standard-1`.
*   **--no-smoke-test**: This parameter is used to disable smoke testing the
    newly built custom image. The smoke test is used to verify if the newly
    built custom image can create a functional Dataproc cluster. Disabling this
    step will speed up the custom image build process; however, it is not
    advised. Note: The smoke test will create a Dataproc cluster with the newly
    built image, runs a short job and deletes the cluster in the end.
*   **--network**: This parameter specifies the GCE network to be used to launch
    the GCE VM instance which builds the custom Dataproc image. The default
    network is 'global/networks/default'. If the default network does not exist
    in your project, please specify a valid network interface. For more
    information on network interfaces, please refer to
    [GCE VPC documentation](https://cloud.google.com/vpc/docs/vpc).
*   **--subnetwork**: This parameter specifies the subnetwork that is used to
    launch the VM instance that builds the custom Dataprocimage. A full
    subnetwork URL is required. The default subnetwork is None. For more
    information, please refer to
    [GCE VPC documentation](https://cloud.google.com/vpc/docs/vpc).
*   **--no-external-ip**: This parameter is used to disables external IP for the
    image build VM. The VM will not be able to access the internet, but if
    [Private Google Access](https://cloud.google.com/vpc/docs/configure-private-google-access)
    is enabled for the subnetwork, it can still access Google services (e.g.,
    GCS) through internal IP of the VPC.
*   **--service-account**: The service account that is used to launch the VM
    instance that builds the custom Dataproc image. The scope of this service
    account is defaulted to "/auth/cloud-platform", which authorizes VM instance
    the access to all cloud platform services that is granted by IAM roles.
    Note: IAM role must allow the VM instance to access GCS bucket in order to
    access scripts and write logs.
*   **--extra-sources**: Additional files/directories uploaded along with
    customization script. This argument is evaluated to a json dictionary.
*   **--disk-size**: The size in GB of the disk attached to the VM instance used
    to build custom image. The default is `20` GB.
*   **--accelerator**: The accelerators (e.g. GPUs) attached to the VM instance
    used to build custom image. This flag supports the same
    [values](https://cloud.google.com/sdk/gcloud/reference/compute/instances/create#--accelerator)
    as `gcloud compute instances create --accelerator` flag. By default no
    accelerators are attached.
*   **--base-image-uri**: The partial image URI for the base Dataproc image. The
    customization script will be executed on top of this image instead of an
    out-of-the-box Dataproc image. This image must be a valid Dataproc image.
    The format of the partial image URI is the following:
    `projects/<project_id>/global/images/<image_name>`.
*   **--storage-location**: The storage location (e.g. US, us-central1) of the
    custom GCE image. This flag supports the same
    [values](https://cloud.google.com/sdk/gcloud/reference/compute/images/create#--storage-location)
    as `gcloud compute images create --storage-location` flag. If not specified,
    the default GCE image storage location is used.
*   **--shutdown-instance-timer-sec**: The time to wait in seconds before
    shutting down the VM instance. This value may need to be increased if your
    init script generates a lot of output on stdout. If not specified, the
    default value of 300 seconds will be used.
*   **--dry-run**: Dry run mode which only validates input and generates
    workflow script without creating image. Disabled by default.
*   **--metadata**: VM metadata which can be read by the customization script
    with `/usr/share/google/get_metadata_value attributes/<key>` at runtime. The
    value of this flag takes the form of `key1=value1,key2=value2,...`. If the
    value includes special characters (e.g., `=`, `,` or spaces) which needs to
    be escaped, consider encoding the value, then decode it back in the
    customization script. See more information about VM metadata on
    https://cloud.google.com/sdk/gcloud/reference/compute/instances/create.

#### Overriding cluster properties with a custom image

You can use custom images to overwrite any
[cluster properties](https://cloud.google.com/dataproc/docs/concepts/configuring-clusters/cluster-properties)
set during cluster creation. If a user creates a cluster with your custom image
but sets cluster properties different from those you set with your custom image,
your custom image cluster property settings will take precedence.

To set cluster properties with your custom image:

In your custom image
[customization script](https://cloud.google.com/dataproc/docs/guides/dataproc-images#running_the_code),
create a `dataproc.custom.properties` file in `/etc/google-dataproc`, then set
cluster property values in the file.

*   Sample `dataproc.custom.properties` file contents:

    ```shell
    dataproc.conscrypt.provider.enable=true
    dataproc.logging.stackdriver.enable=false
    ```

*   Sample customization script file-creation snippet to override two cluster
    properties:

    ```shell
    cat <<EOF >/etc/google-dataproc/dataproc.custom.properties
    dataproc.conscrypt.provider.enable=true
    dataproc.logging.stackdriver.enable=false EOF
    ```

### Examples

#### Create a custom image

Create a custom image with name `custom-image-1-5-9` with Dataproc version
`1.5.9-debian10`:

```shell
python generate_custom_image.py \
    --image-name custom-image-1-5-9 \
    --dataproc-version 1.5.9-debian10 \
    --customization-script ~/custom-script.sh \
    --metadata 'key1=value1,key2=value2' \
    --zone us-central1-f \
    --gcs-bucket gs://my-test-bucket
```

#### Create a custom image without running smoke test

```shell
python generate_custom_image.py \
    --image-name custom-image-1-5-9 \
    --dataproc-version 1.5.9-debian10 \
    --customization-script ~/custom-script.sh \
    --zone us-central1-f \
    --gcs-bucket gs://my-test-bucket \
    --no-smoke-test
```
