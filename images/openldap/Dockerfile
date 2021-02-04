FROM repo.iamappliance.com:8443/osixia/openldap-backup:1.4.0

# comment-out backup cronjob because we are invoking it from outside of the container
# also comment-out backup retention an possible upload to AWS bucket
RUN sed -i 's/^/#/g' /container/service/slapd-backup/assets/cronjobs && \
    \
    sed -i -e 's/^find.*LDAP_BACKUP_TTL.*/#this line was stripped out from original image/g' \
    -e 's/aws\ss3\scp.*/echo "Upload stripped out from original image"/g' /container/service/slapd-backup/assets/tool/slapd-backup


RUN mkdir -pv /container/service/slapd/assets/config/bootstrap/ldif/custom/
COPY ./dropin/initial-data/* /container/service/slapd/assets/config/bootstrap/ldif/custom/
