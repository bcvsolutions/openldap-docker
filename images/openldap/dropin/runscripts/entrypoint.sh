#!/bin/bash

set -x

handle_signal() {
    # Kill the /container/tool/run process
    echo "[$0] Caught SIGTERM signal, sending it to the /container/tool/run ...";
    kill -TERM $RUN_PID
}

trap 'handle_signal' SIGTERM

/container/tool/run &
RUN_PID=$!

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
        ldapsearch -x -LLL -b "" -s base "(objectClass=*)" 2>/dev/null
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

# Function to check if the versions object exists
check_versions_object() {
    versions_dn="$1"

    ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -b "$versions_dn" "(objectClass=*)" 2>/dev/null
    result=$?

    return $result
}

# Function to check if the versions object exists and create it if necessary
check_and_create_versions_object() {
    versions_dn="$1"

    if ! check_versions_object "$versions_dn"; then
        echo "[$0] Versions object $versions_dn does not exist. Creating it."
        perform_operation "/changefiles/version_storage.ldif"
        ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: $versions_dn
changetype: add
objectClass: top
objectClass: iamVersionStorage
objectClass: organizationalUnit
appliedVersions: version_storage.ldif
EOF
    fi
}

# Function to perform ldapadd or ldapmodify based on operation type
# Default admin user cannot modify LDAP scheme inside cn=config. Because of this
# we need to use cn=admin,cn=config user if the ldif file modifies cn=config.
# Note that LDAP_CONFIG_PASSWORD env variable needs to be set in order to be able
# to successfuly bind with cn=admin,cn=config.
perform_operation() {
    file="$1"
    echo "[$0] Executing LDIF: $file ..."
    ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f "$file" 2>&1
    retcode=$?
    if [ "$retcode" -eq 0 ]; then
      echo "[$0] LDIF $file executed successfully."
    else
      echo "[$0] LDIF $file execution FAILED!"
    fi
}

updateAppliedVersions() {
    versions_dn="$1"
    ldap_version_attr="$2"
    filename="$3"

    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: $versions_dn
changetype: modify
add: $ldap_version_attr
$ldap_version_attr: $filename
EOF
}


# Function to run all ldif files in /changefiles/
run_ldif_files() {
    ldif_dir="/changefiles"
    ldap_version_attr="appliedVersions"
    ldap_base_dn="$LDAP_BASE_DN"
    versions_dn="ou=versions,$LDAP_BASE_DN"

    # Add the executed ldif file to the versions object's versioning attribute
    check_and_create_versions_object "$versions_dn"
    # Get the list of already executed ldif files from the LDAP object
    executed_ldif=$(ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -b "$versions_dn" "$ldap_version_attr" | grep "$ldap_version_attr" | cut -d' ' -f2)

    if [ -d "$ldif_dir" ]; then
        for file in "$ldif_dir"/*; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                # Check if the ldif file has not been executed before
                if ! echo "$executed_ldif" | grep -q "$filename"; then
                    echo "[$0] Running ldif file: $file"

                    # Execute the LDIF against the LDAP server
                    perform_operation "$file"
                    # TODO: properly check the return code from LDIF execution
                    updateAppliedVersions "$versions_dn" "$ldap_version_attr" "$filename"

                else
                    echo "[$0] Skipping already executed ldif file: $file"
                fi
            fi
        done
    else
        echo "[$0] LDIF directory not found: $ldif_dir"
    fi
}

echo "[$0] BCV INIT BEFORE WAIT"
# Check if LDAP is ready before proceeding
wait_for_ldap
echo "[$0] BCV INIT BEFORE LDIF"
run_ldif_files
echo "[$0] BCV INIT AFTER LDIF"
# Keep the container running
wait $RUN_PID
