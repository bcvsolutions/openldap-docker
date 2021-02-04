# OpenLDAP image
Image built atop [osixia/openldap-backup](https://hub.docker.com/r/osixia/openldap-backup/) image.
Original image contains cron scheduler for backup operations. We did not want the container to manage them, so we forked the image and disabled those features.

We also added some basic internal structure to the LDAP when being initialized for the first time.

:warning: There is an user `uid=admin,ou=users,{{ LDAP_BASE_DN }}` who has his password set to `admin`. Change his password or delete the user after container is initialized.

## Image versioning
Naming scheme is pretty simple: **bcv-openldap:OSIXIA_BASEIMAGE_VERSION-rIMAGE_VERSION**.
- Image name is **bcv-openldap**.
- **OSIXIA_BASEIMAGE_VERSION** is a version of baseimage we used and tweaked. This does not reference version of OpenLDAP in any way. For example, `osixia/openldap-backup:1.4.0` contains OpenLDAP `2.4.50`.
- **IMAGE_VERSION** is an image release version written as a serial number, starting at 0. When images have the same OSIXIA_BASEIMAGE_VERSION versions but different image versions it means there were some tweaks to the baseimage (setup scripts, etc.) but baseimage which we spinned off of did not change.

Example
```
bcv-openldap:1.4.0-r0     // first release of tweaked osixia/openldap:1.4.0 image
bcv-openldap:1.4.0-r1    // second release of tweaked osixia/openldap:1.4.0 image (we made some other changes)
bcv-openldap:1.4.7-r0    // first release of tweaked osixia/openldap:1.4.7 image
```

## Building
Simply cd to the directory which contains the Dockerfile and issue `docker build -t <image tag here> ./`.

The build process:
1. Pulls official **osixia/openldap-backup:XXX** image. This image is copied from BCV repo, but those images are identical to what you find on Docker HUB.
1. Disables its internal cronjobs which make backups. We expect backup is scheduled from outside of the container.
1. Disables backup retention. We expect backup retention is managed from outside of the container.
1. Disables possibility to upload backups onto AWS S3 bucket.

No engine sizing is performed.

## Use
- Use in the same way as [original image](https://hub.docker.com/r/osixia/openldap).
- Set up following **mandatory** variables.
  - LDAP_ORGANISATION
  - LDAP_DOMAIN
  - LDAP_BASE_DN

## Environment variables
See baseimage doc.

## Backups
Container can make a persistent backup of the database, using `slapcat`, producing gzipped LDIF.
To make a backup of the database, simly run
* `docker exec -it openldap /sbin/slapd-backup-config` to backup config
* `docker exec -it openldap /sbin/slapd-backup-data` to backup data

from outside the container.

## Restore
There are always two backups made, a backup of LDAP configuration and a backup of LDAP data.
They can be restored independently. If you do not do many changes to OpenLDAP configuration, you usually need to restore just the "data" part.
To fully restore the state of LDAP server, restore both backups.

### Restore configuration
1. Enter the container
  ```
  [fiisch@dockerhost ~]$ docker exec -it openldap bash
  ```
1. Delete current configuration
  ```
  root@openldap:/# rm -r /etc/ldap/slapd.d/cn*
  ```
1. Use supplied script to restore from backup (script expects the file to be in `/data/backup`)
  ```
  /sbin/slapd-restore-config 20210204T090611-config.gz
  ```

### Restore data
1. Enter the container
  ```
  [fiisch@dockerhost ~]$ docker exec -it openldap bash
  ```
1. Delete contents of the data directory
  ```
  root@openldap:/# rm /var/lib/ldap/*
  ```
1. Use supplied script to restore from backup (script expects the file to be in `/data/backup`)
  ```
  /sbin/slapd-restore-data 20210204T090615-data.gz
  ```

## Mounted files and volumes
- Mandatory
  - Volume containing LDAP admin passwords.
    - Those passwords are used to secure `cn=admin,{{ LDAP_BASE_DN }}`, `cn=admin,cn=config` and (optional) `cn={{ LDAP_READONLY_USER_USERNAME }},{{ LDAP_BASE_DN }}` users.
    - Without this volume mounted, OpenLDAP will not initialize.
    - Example
      ```yaml
      volumes:
        - type: bind
          source: ./secrets/pwfiles
          target: /container/environment/90-adminpw
          read_only: true
      ```
- Optional
  - Directory which will hold LDAP configuration.
    - There are your persistent data in this directory.
    - Without this directory mounted, you can run the container. But you will lose LDAP configuration (=data) on container rm...
    - Example
      ```yaml
      volumes:
        - type: bind
          source: ./config
          target: /etc/ldap/slapd.d
          read_only: false
      ```
  - Directory which will hold LDAP database.
    - There are your persistent data in this directory.
    - Without this directory mounted, you can run the container. But you will lose you data on container rm...
    - Example
      ```yaml
      volumes:
        - type: bind
          source: ./data
          target: /var/lib/ldap
          read_only: false
      ```
  - Directory which will hold LDAP backups.
    - There are your backups in the directory.
    - Without this directory mounted, container will not store your database backups persistently.
    - Example
      ```yaml
      volumes:
        - type: bind
          source: ./backup
          target: /data/backup
          read_only: false
      ```
  - Directory which will hold SSL certificates.
    - SSL-related stuff is stored here. If you do not use SSL, you do not need to mount this directory.
    - Directory must be mounted in read-write mode because container will generate a DH-param file and store it there.
    - Example
      ```yaml
      volumes:
        - type: bind
          source: ./secrets/certs
          target: /container/service/slapd/assets/certs/
          read_only: false
      ```
