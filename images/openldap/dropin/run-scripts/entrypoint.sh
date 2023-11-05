#!/bin/bash

handle_signal() {
    # Kill the /container/tool/run process
    echo "Killing process $RUN_PID"

    kill $RUN_PID
    wait $RUN_PID
    exit 0
}

trap 'handle_signal' TERM INT

/container/tool/run &
RUN_PID=$!


# Password to ldap users may be stored in files inside /container/environment/90-adminpw folder.
# In that case we must fetch those and set corresponding env variables.
# See perform_operation for the motivation for this function
load_passwords() {
    for file in /container/environment/90-adminpw/*; do
        if [ -f "$file" ]; then
            # Read the variables from the file and set them as environment variables
            while IFS=: read -r VAR value; do
                VAR=$(echo "$VAR" | sed 's/^[" ]*//;s/[" ]*$//')  # Remove leading and trailing quotes and spaces
                value=$(echo "$value" | sed 's/^[" ]*//;s/[" ]*$//')  # Remove leading and trailing quotes and spaces
                export "$VAR"="$value"
            done < "$file"
        fi
    done
}


# Wait for the OpenLDAP service to start
# Underlying LDAP server starts and shuts down multiple times during container
# startup. We need to wait for it to start in order to be able to modify its
# schema and push additional data.
# This function solves this issue by trying to contact LDAP server using ldapsearch
# and measuring consecutive successful searches. If it detects 5 consecutive successful
#searches, then LDAP is considered to be started.
wait_for_ldap() {
    max_retries=30 # Adjust the number of retries as needed
    retries=0
    consecutive_success=0
    consecutive_threshold=5 # Adjust this threshold as needed

    while [ $retries -lt $max_retries ]; do
        ldapsearch -x -LLL -b "" -s base "(objectClass=*)" 2>/dev/null
        if [ $? -eq 0 ]; then
            consecutive_success=$((consecutive_success + 1))
            if [ $consecutive_success -ge $consecutive_threshold ]; then
                echo "LDAP server is ready."
                return 0
            fi
        else
            consecutive_success=0
        fi

        retries=$((retries + 1))
        sleep 2
    done

    echo "LDAP server did not start within the specified time."
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
        echo "Versions object $versions_dn does not exist. Creating it."
        perform_operation "add" "/changefiles/version_storage.ldif"
        ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
        dn: $versions_dn
changetype: add
objectClass: top
objectClass: iamVersionStorrage
objectClass: organizationalUnit
appliedVersions: version_storage.ldif
EOF
    fi
}

# Function to determine the operation type based on ldif contents
determine_operation_type() {
    file="$1"

    if grep -q "changetype: modify" "$file"; then
        echo "modify"
    else
        echo "add"
    fi
}

# Function to perform ldapadd or ldapmodify based on operation type
# Default admin user cannot modify LDAP scheme inside cn=config. Because of this
# we need to use cn=admin,cn=config user if the ldif file modifies cn=config.
# Note that LDAP_CONFIG_PASSWORD env variable needs to be set in order to be able
# to successfuly bind with cn=admin,cn=config.
perform_operation() {
    operation="$1"
    file="$2"

    # Extract the DN from the LDIF file
    dn=$(grep -oP '^dn:.*' "$file" | head -n 1)

    # Check if the DN ends with "cn=config"
    if [ "$(echo "$dn" | grep -oP '.*cn=config$')" ]; then
        # Use cn=admin,cn=config for cn=config DN
        if [ "$operation" = "add" ]; then
            ldapadd -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" -H ldapi:/// -f "$file" 2>&1
        elif [ "$operation" = "modify" ]; then
            ldapmodify -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" -H ldapi:/// -f "$file" 2>&1
        else
            echo "Unsupported operation: $operation"
        fi
    else
        # Use external authentication for other DNs
        if [ "$operation" = "add" ]; then
            ldapadd -Y EXTERNAL -Q -H ldapi:/// -f "$file" 2>&1
        elif [ "$operation" = "modify" ]; then
            ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f "$file" 2>&1
        else
            echo "Unsupported operation: $operation"
        fi
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
run_ldiff_files() {
    ldiff_dir="/changefiles"
    ldap_version_attr="appliedVersions"
    ldap_base_dn="$LDAP_BASE_DN"
    versions_dn="ou=versions,$LDAP_BASE_DN"

    # Add the executed ldif file to the versions object's versioning attribute
    check_and_create_versions_object "$versions_dn"
    # Get the list of already executed ldif files from the LDAP object
    executed_ldiff=$(ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -b "$versions_dn" "$ldap_version_attr" | grep "$ldap_version_attr" | cut -d' ' -f2)

    if [ -d "$ldiff_dir" ]; then
        for file in "$ldiff_dir"/*; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                # Check if the ldif file has not been executed before
                if ! echo "$executed_ldiff" | grep -q "$filename"; then
                    echo "Running ldif file: $file"

                    # Determine the operation type
                    operation=$(determine_operation_type "$file")

                    # Perform the appropriate ldap operation
                    perform_operation "$operation" "$file"
                    updateAppliedVersions "$versions_dn" "$ldap_version_attr" "$filename"

                else
                    echo "Skipping already executed ldif file: $file"
                fi
            fi
        done
    else
        echo "Ldif directory not found: $ldiff_dir"
    fi
}

echo "BCV INIT BEFORE WAIT"
# Check if LDAP is ready before proceeding
wait_for_ldap
echo "BCV INIT BEFORE LDIFF"
load_passwords
run_ldiff_files
# Keep the container running
wait $RUN_PID