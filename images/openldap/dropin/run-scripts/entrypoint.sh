#!/bin/sh

# Start the original entrypoint script /container/tool/run in the foreground
/container/tool/run &

# Wait for the OpenLDAP service to start
wait_for_ldap() {
    ldap_ready=false
    max_retries=30  # Adjust the number of retries as needed
    retries=0

    while [ $retries -lt $max_retries ]; do
        ldapsearch -x -LLL -b "" -s base "(objectClass=*)" 2>/dev/null
        if [ $? -eq 0 ]; then
            ldap_ready=true
            break
        fi

        retries=$((retries + 1))
        sleep 2
    done

    if [ "$ldap_ready" = false ]; then
        echo "BCV INIT LDAP server did not start within the specified time."
        exit 1
    fi
}

# Check if LDAP is ready before proceeding
wait_for_ldap

# Function to check if the versions object exists
check_versions_object() {
    versions_dn="$1"

    ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -b "$versions_dn" "(objectClass=*)" 2>/dev/null
    result=$?
    echo "BCV INIT ldapsearch result for $versions_dn: $result"

    return $result
}

# Function to check if the versions object exists and create it if necessary
check_and_create_versions_object() {
    versions_dn="$1"

    if ! check_versions_object "$versions_dn"; then
        echo "BCV INIT Versions object $versions_dn does not exist. Creating it."
        ldapadd -Y EXTERNAL -H ldapi:/// << EOF
dn: cn=iamVersionStorrage,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: iamVersionStorrage
olcAttributeTypes: {0}( 
    1.3.6.1.4.1.33537.1.2.2.2 
    NAME 'appliedVersions' 
    EQUALITY caseIgnoreMatch 
    DESC 'Stores all applied ldiff file names.' 
    SYNTAX 1.3.6.1.4.1.1466.115.121.1.15)
olcObjectClasses: {0}( 
    1.3.6.1.4.1.33537.1.2.1.2 
    NAME 'iamVersionStorrage' 
    DESC 'IAM appliance-managed user account' 
    SUP top 
    AUXILIARY 
    MAY ( appliedVersions ) 
    X-ORIGIN 'Object class which IAM appliance uses to store applied ldiff names' )

dn: $versions_dn
objectClass: top
objectClass: iamVersionStorrage
objectClass: organizationalUnit
EOF
    fi
}



# Function to determine the operation type based on ldiff contents
determine_operation_type() {
    file="$1"

    if grep -q "changetype: modify" "$file"; then
        echo "modify"
    else
        echo "add"
    fi
}

# Function to perform ldapadd or ldapmodify based on operation type
perform_operation() {
    operation="$1"
    file="$2"

    case "$operation" in
        "add")
            ldapadd -Y EXTERNAL -H ldapi:/// -f "$file"
            ;;
        "modify")
            ldapmodify -Y EXTERNAL -H ldapi:/// -f "$file"
            ;;
    esac
}

# Function to run all ldiff files in /bcv/changefiles/
run_ldiff_files() {
    ldiff_dir="/bcv/changefiles/"
    ldap_version_attr="appliedVersions"
    ldap_base_dn="$LDAP_BASE_DN"
    versions_dn="ou=versions,$ldap_base_dn"

    echo "BCV INIT Base DN: $ldap_base_dn"
    echo "BCV INIT Versions DN: $versions_dn"

    # Add the executed ldiff file to the versions object's versioning attribute
    check_and_create_versions_object "$versions_dn"
    # Get the list of already executed ldiff files from the LDAP object
    executed_ldiff=$(ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -b "$versions_dn" "$ldap_version_attr" | grep "$ldap_version_attr" | cut -d' ' -f2)

    echo "BCV INIT historic versions: $executed_ldiff"

    if [ -d "$ldiff_dir" ]; then
        for file in "$ldiff_dir"*.ldiff; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")

                # Check if the ldiff file has not been executed before
                if ! echo "$executed_ldiff" | grep -q "$filename"; then
                    echo "BCV INIT Running ldiff file: $file"

                    # Determine the operation type
                    operation=$(determine_operation_type "$file")

                    # Perform the appropriate ldap operation
                    perform_operation "$operation" "$file"

                    ldapmodify -Y EXTERNAL -H ldapi:/// << EOF
dn: $versions_dn
changetype: modify
add: $ldap_version_attr
$ldap_version_attr: $filename
EOF
                else
                    echo "BCV INIT Skipping already executed ldiff file: $file"
                fi
            fi
        done
    else
        echo "BCV INIT ldiff directory not found: $ldiff_dir"
    fi
}

# Call the function to run ldiff files
run_ldiff_files

# Keep the container running
tail -f /dev/null


