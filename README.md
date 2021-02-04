# openldap-docker
Fork of [osixia/openldap-backup](https://hub.docker.com/r/osixia/openldap-backup/) image for use by BCV.

It elevates original image capabilities to backup and restore but:
- Disables its internal cronjobs which make backups. We expect backup is scheduler from outside of the container.
- Disables backup retention. We expect backup retention is managed from outside of the container.
- Disables possibility to upload backups onto AWS S3 bucket.

This image can be used as general-purpose image.

## Directory structure
- **compose/** - contains simple/sample docker-compose files for images from this repo.
- **images/** - contains sources for building docker images.

## Additional info
- Release tags on this repository correspond to release tags on individual images.
- See **README.md** in [images/openldap/](images/openldap/) to get more information about the docker image.
- See **README.md** in [compose/](compose/) for compose YAML files and for starting image as a part of the infrastructure.
