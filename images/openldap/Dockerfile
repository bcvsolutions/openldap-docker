FROM repo.iamappliance.com:8443/osixia/openldap-backup:1.4.0


ENV RUNSCRIPTS_PATH /runscripts
ENV CHANGEFILES_PATH /changefiles

# comment-out backup cronjob because we are invoking it from outside of the container
# also comment-out backup retention an possible upload to AWS bucket
RUN sed -i 's/^/#/g' /container/service/slapd-backup/assets/cronjobs
    
COPY ./dropin/slapd-backup /container/service/slapd-backup/assets/tool/slapd-backup
RUN chmod 755 /container/service/slapd-backup/assets/tool/slapd-backup

COPY ./dropin/slapd-restore /container/service/slapd-backup/assets/tool/slapd-restore
RUN chmod 755 /container/service/slapd-backup/assets/tool/slapd-restore

RUN mkdir -pv /container/service/slapd/assets/config/bootstrap/ldif/custom/
COPY ./dropin/initial-data/* /container/service/slapd/assets/config/bootstrap/ldif/custom/

RUN mkdir -pv $CHANGEFILES_PATH
COPY ./dropin/changefiles/* $CHANGEFILES_PATH
RUN chmod -R 755 $CHANGEFILES_PATH

RUN mkdir -pv $RUNSCRIPTS_PATH
COPY ./dropin/run-scripts/* $RUNSCRIPTS_PATH
RUN chmod -R 755 $RUNSCRIPTS_PATH

# override entrypoint from https://github.com/osixia/docker-light-baseimage in order to
# enable post-start script run
ENTRYPOINT ["/runscripts/entrypoint.sh"]
