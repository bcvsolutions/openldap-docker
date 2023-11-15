#!/bin/bash

set -x

handle_signal() {
    # Kill the /container/tool/run process
    echo "[$0] Caught SIGTERM signal, sending it to the /container/tool/run ...";
    kill -TERM $RUN_PID
}

trap 'handle_signal' SIGTERM

# script global variables
LDAPCLIENT_AUTH_OPTS="-Y EXTERNAL -Q -H ldapi:///"
LDAPCLIENT_OTHER_OPTS="-LLL -o ldif-wrap=no"
LDAP_VERSIONS_DN="ou=versions,$LDAP_BASE_DN"
LDAP_VERSION_ATTR="appliedVersion"

# Wait for the OpenLDAP service to start
# Underlying LDAP server starts and shuts down multiple times during container
# startup. We need to wait for it to start in order to be able to modify its
# schema and push additional data.
# This function solves this issue by trying to contact LDAP server using ldapsearch
# and measuring consecutive successful searches. If it detects 5 consecutive successful
#searches, then LDAP is considered to be started.
wait_for_ldap() {
    max_retries=30 # Adjust the number of retries as needed
    consecutive_threshold=5 # Adjust this threshold as needed

    retries=0
    consecutive_success=0
    while [ $retries -lt $max_retries ]; do
        ldapsearch $LDAPCLIENT_AUTH_OPTS $LDAPCLIENT_OTHER_OPTS -b "" -s base "(objectClass=*)" 2>/dev/null
        if [ $? -eq 0 ]; then
            consecutive_success=$((consecutive_success + 1))
            if [ $consecutive_success -ge $consecutive_threshold ]; then
                echo "[$0] LDAP server is ready."
                return 0
            fi
        else
            consecutive_success=0
        fi

        retries=$((retries + 1))
        sleep 2
    done

    echo "[$0] LDAP server did not start within the specified time. Exiting the runscript."
    exit 1
}

updateAppliedVersions() {
    filename="$1"

    ldapmodify $LDAPCLIENT_AUTH_OPTS <<EOF
dn: $LDAP_VERSIONS_DN
changetype: modify
add: $LDAP_VERSION_ATTR
$LDAP_VERSION_ATTR: $filename
EOF
}

# TODO: docs
perform_operation() {
  file="$1"
  filename=$(basename "$file")
  # parse LDIF file header
  file_header=$(cat "$file" | sed -n '/----- LDIF HEADER BEGIN -----/,/----- LDIF HEADER END -----/p')
  # those are mandatory
  header_version=$(echo "$file_header" | grep -oE 'header-version: [0-9]+' | sed -e 's/header-version: //')
  if [ "x$header_version" != "1" ]; then
    echo "[$0] Invalid LDIF changefile $file. Bad 'header-version' parameter in the header."
    return 1
  fi
  # those can be empty
  lookup_context=$(echo "$file_header" | grep -oE 'lookup-context: (data|config)' | sed -e 's/lookup-context: //')
  searchbase="cn=config"
  if [ "$lookup_context" = "data" ]; then
    searchbase="$LDAP_BASE_DN"
  fi
  # those can be empty; also do the template substitution
  dn_lookup=$(echo "$file_header" | grep -oE 'dn-lookup: .*$' | sed -e 's/dn-lookup: //')
  dn_lookup=$(echo "$dn_lookup" | sed -e "s/__LDAP_DOMAIN__/$LDAP_DOMAIN/" -e "s/__LDAP_BASE_DN__/$LDAP_BASE_DN/" -e "s/__LDAP_READONLY_USERNAME__/$LDAP_READONLY_USERNAME/")
  presence_check=$(echo "$file_header" | grep -oE 'presence-check: .*$' | sed -e 's/presence-check: //')
  presence_check=$(echo "$presence_check" | sed -e "s/__LDAP_DOMAIN__/$LDAP_DOMAIN/" -e "s/__LDAP_BASE_DN__/$LDAP_BASE_DN/" -e "s/__LDAP_READONLY_USERNAME__/$LDAP_READONLY_USERNAME/")
  # those have some defaults if empty
  on_present=$(echo "$file_header" | grep -oE 'on-present: (skip|execute|persist-versioning)' | sed -e 's/on-present: //')
  if [ "x$on_present" = "x" ]; then
    on_present='execute'
  fi
  on_failure=$(echo "$file_header" | grep -oE 'on-failure: (fail|success)' | sed -e 's/on-failure: //')
  if [ "x$on_failure" = "x" ]; then
    on_failure='fail'
  fi
  echo "[$0] LDIF changefile $file header summary BEGIN:"
  echo "[$0] header-version: $header_version"
  echo "[$0] lookup-context: $lookup_context"
  echo "[$0] dn-lookup: $dn_lookup"
  echo "[$0] presence-check: $presence_check"
  echo "[$0] on-present: $on_present"
  echo "[$0] on-failure: $on_failure"
  echo "[$0] LDIF changefile $file header summary END."

  # do the presence-check if defined; search base according to lookup-context
  # branch according to on-present
  if [ "x$presence_check" != "x" ]; then
    presence_check_res=$(ldapsearch $LDAPCLIENT_AUTH_OPTS $LDAPCLIENT_OTHER_OPTS -b "$searchbase" "$presence_check" 1.1 | grep ^dn)
    if [ "x$presence_check_res" != "x" ]; then
      # entry is present
      if [ "$on_present" = "skip" ]; then
        echo "[$0] Presence-check: entry is present and 'skip' was set. Skipping LDIF."
        return 0
      fi
      if [ "$on_present" = "persist-versioning" ]; then
        echo "[$0] Presence-check: entry is present and 'persist-versioning' was set. Persisting version but skipping LDIF execution."
        updateAppliedVersions "$filename"
        return 0
      fi
      # the 'execute' is default so we do not need to explicitly branch on it
      # we just leave it to the rest of the function
    fi
  fi
  # do the dn-lookup if defined; search base according to lookup-context
  # fill the RESOLVED_ENTRY_DN variable; do not forget to un-base64 if needed
  if [ "x$dn_lookup" != "x" ]; then
    dn_lookup_res=$(ldapsearch $LDAPCLIENT_AUTH_OPTS $LDAPCLIENT_OTHER_OPTS -b "$searchbase" "$dn_lookup" 1.1 | grep ^dn | head -n1)
    echo -n "$dn_lookup_res" | grep -q "^dn::"
    if [ "$?" -eq 0 ]; then
      # dn is base64-encoded, we must decode it
      RESOLVED_ENTRY_DN=$(echo -n "$dn_lookup_res" | sed -e 's/^dn:: //' | base64 -d)
    else
      # otherwise, just strip the dn:
      RESOLVED_ENTRY_DN=$(echo -n "$dn_lookup_res" | sed -e 's/^dn: //')
    fi
    echo "[$0] Dn-lookup: Resolved entryDN is $RESOLVED_ENTRY_DN ."
  fi
  # load the actual LDIF body into variable
  # do the templating on the LDIF body with LDAP_DOMAIN, LDAP_BASE_DN, LDAP_READONLY_USERNAME, RESOLVED_ENTRY_DN
  ldif_final=$(cat "$file" | sed -e "s/__LDAP_DOMAIN__/$LDAP_DOMAIN/" -e "s/__LDAP_BASE_DN__/$LDAP_BASE_DN/" -e "s/__LDAP_READONLY_USERNAME__/$LDAP_READONLY_USERNAME/" -e "s/__RESOLVED_ENTRY_DN__/$RESOLVED_ENTRY_DN/")

  # execute the LDIF body
  # grad the return code and branch accordingly
  echo "[$0] Executing LDIF: $file ..."
  ldapmodify $LDAPCLIENT_AUTH_OPTS <<< "$ldif_final"
  retcode=$?
  if [ "$retcode" -eq 0 ]; then
    echo "[$0] LDIF $file executed successfully. Persisting version..."
    updateAppliedVersions "$filename"
    return 0
  else
    if [ "$on_failure" = "success" ]; then
      echo "[$0] LDIF $file execution FAILED but ON-FAILURE=SUCCESS defined. Acting as if nothing bad happenned. Persisting version..."
      updateAppliedVersions "$filename"
      return 0
    else
      echo "[$0] LDIF $file execution FAILED!"
      return 1
    fi
  fi
  # we should never get here
  return 3
}

# Function to run all ldif files in /changefiles/
run_ldif_files() {
  # Get the list of already executed ldif files from the LDAP object.
  # If the version object does not exist, this search returns empty list
  # which, in turn, leads to execution of 000000-version-storage.ldif which creates new versioning object.
  # We expect ASCII-only values in 'appliedVersion' attribute values.
  executed_ldif=$(ldapsearch $LDAPCLIENT_AUTH_OPTS $LDAPCLIENT_OTHER_OPTS -b "$LDAP_VERSIONS_DN" "$LDAP_VERSION_ATTR" | grep "$LDAP_VERSION_ATTR" | cut -d' ' -f2)

  for file in "$CHANGEFILES_PATH"/*.ldif; do
    if [ -f "$file" ]; then
      filename=$(basename "$file")
      # Check if the ldif file has not been executed before
      # If it was already executed, disregard it without even inspecting its contents.
      if ! echo "$executed_ldif" | grep -q "$filename"; then
        echo "[$0] Running LDIF file: $file"
        # Execute the LDIF against the LDAP server
        perform_operation "$file"
        retcode="$?"
        if [ "$retcode" -ne 0 ]; then
          echo "[$0] Error while executing LDIF: $file . Skipping the rest of LDIFs."
          return
        fi
      else
        echo "[$0] Skipping already executed LDIF file: $file"
      fi
    fi
  done
}

/container/tool/run &
RUN_PID=$!

echo "[$0] BCV INIT BEFORE WAIT"
# Check if LDAP is ready before proceeding
wait_for_ldap
echo "[$0] BCV INIT BEFORE LDIF"
run_ldif_files
echo "[$0] BCV INIT AFTER LDIF"

# Wait here until the runc stops running
wait $RUN_PID

echo "[$0] Starting to wait (in a loop) for runc to terminate.";
# when exiting, wait at most 30 seconds
for i in {1..30}; do
  procs=$(ps -ef | grep -Ec "/[c]ontainer/tool/run");
  if [ "$procs" -eq 0 ]; then
    break;
  fi
  sleep 1;
  echo "[$0] Loop waited.";
done
# safety to get other processes in proctree chance to terminate
echo "[$0] Safety sleep 1 second before terminating the container.";
sleep 1
