# Build Dataproc custom images for moove.ai

This page describes how to generate a custom Dataproc image. This is a mix of google documentation and moove.ai docs.
Sections pertaining to moove are noted with (moove.ai)

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

## Build Automation (moove.ai)
Opening a PR to the master branch (in the moove org, not google) will start build automation.
1. The createImage.sh script is called.
    * This script takes one argument and defaults to boot.sh.
    * The argument determines which script to run to build the new image.
2. createImage.sh decrypts a github token and injects it into the boot script so we can clone a private repo.
3. The image is then built and tagged
4. The latest image is always tagged "version: latest"
5. Older images are tagged based on the git commit that created it with the `git_hash` label.
6. Python packages are installed from [moove-data-exploration](https://github.com/moove-ai/moove-data-exploration) 
    * requirements.txt file
    * Uses the master branch

## Requirements

1.  Python 2.7+.
2.  gcloud >= 181.0.0 (2017-11-30)
    *   gcloud beta components is required. Use `gcloud components install beta`
        or `sudo apt-get install google-cloud-sdk`.
3.  Bash 4.0+.
4.  A GCE project with billing, Google Cloud Dataproc API, Google Compute Engine
    API, and Google Cloud Storage APIs enabled.
5.  Use `gcloud config set project <your-project>` to specify which project to
    use to create and save your custom image.

## Generate custom image

To generate a custom image, you can run the following command:

```shell
python generate_custom_image.py \
    --image-name <new_custom_image_name> \
    --dataproc-version <Dataproc version> \
    --customization-script <custom script to install custom packages> \
    --zone <zone to create instance to build custom image> \
    --gcs-bucket <gcs bucket to write logs>
```

### Arguments

*   **--image-name**: The name for custom image.
*   **--dataproc-version**: The Dataproc version for this custom image to build
    on. Examples: `1.4.5-debian9`, `1.4.0-RC10-debian9`, `1.4.5-ubuntu18`. For a
    complete list of Dataproc image versions, please refer to Dataproc
    [release notes](https://cloud.google.com/dataproc/docs/release-notes). To
    understand Dataproc versioning, please refer to
    [documentation](https://cloud.google.com/dataproc/docs/concepts/versioning/overview).
    **This argument is mutually exclusive with --base-image-uri**.
*   **--base-image-uri**: The full image URI for the base Dataproc image. The
    customization script will be executed on top of this image instead of an
    out-of-the-box Dataproc image. This image must be a valid Dataproc image.
    **This argument is mutually exclusive with --dataproc-version.**
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
    to build custom image. The default is `15` GB.
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
    [values](https://cloud.google.com/sdk/gcloud/reference/beta/compute/images/create#--storage-location)
    as `gcloud compute images create --storage-location` flag. If not specified,
    the default GCE image storage location is used.
*   **--shutdown-instance-timer-sec**: The time to wait in seconds before
    shutting down the VM instance. This value may need to be increased if your
    init script generates a lot of output on stdout. If not specified, the
    default value of 300 seconds will be used.
*   **--dry-run**: Dry run mode which only validates input and generates
    workflow script without creating image. Disabled by default.

### Examples

#### Create a custom image

Create a custom image with name `custom-image-1-4-5` with Dataproc version
`1.4.5-debian9`:

```shell
python generate_custom_image.py \
    --image-name custom-image-1-4-5 \
    --dataproc-version 1.4.5-debian9 \
    --customization-script ~/custom-script.sh \
    --zone us-central1-f \
    --gcs-bucket gs://my-test-bucket
```

#### Create a custom image without running smoke test

```shell
python generate_custom_image.py \
    --image-name custom-image-1-4-5 \
    --dataproc-version 1.4.5-debian9 \
    --customization-script ~/custom-script.sh \
    --zone us-central1-f \
    --gcs-bucket gs://my-test-bucket \
    --no-smoke-test
```
