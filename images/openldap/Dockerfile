FROM repo.iamappliance.com:8443/osixia/openldap-backup:1.4.0

# comment-out backup cronjob because we are invoking it from outside of the container
# also comment-out backup retention an possible upload to AWS bucket
RUN sed -i 's/^/#/g' /container/service/slapd-backup/assets/cronjobs
    
COPY ./dropin/slapd-backup /container/service/slapd-backup/assets/tool/slapd-backup
RUN chmod 755 /container/service/slapd-backup/assets/tool/slapd-backup

COPY ./dropin/slapd-restore /container/service/slapd-backup/assets/tool/slapd-restore
RUN chmod 755 /container/service/slapd-backup/assets/tool/slapd-restore

RUN mkdir -pv /container/service/slapd/assets/config/bootstrap/ldif/custom/
COPY ./dropin/initial-data/* /container/service/slapd/assets/config/bootstrap/ldif/custom/
