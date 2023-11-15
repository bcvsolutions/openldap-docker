# ----- LDIF HEADER BEGIN -----
# header-version: 1
#     // This is for future needs. So far, only version 1 exists.
#     // This attribute is mandatory!
#
# lookup-context: data | config
#     // Specifies on which LDAP database to perform dn-lookup and presence-check operations.
#     // data: perform lookups on user datastore
#     // config (default): perform lookups on OLC (cn=config subtree)
#
# dn-lookup: (&(objectClass=olcSchemaConfig)(cn={*}iamManagedUser))
#     // Contains LDAP filter used to look up actual entry DN. This will work globally but is really intended only for
#     // sequentially-numbered entries inside config tree (i.e. schema or modules).
#     // If not specified, the ldif is simply executed without prior dn lookup.
#     // The resolved entry is made available to the ldif file as __RESOLVED_ENTRY_DN__ . This variable *is not* available to header directives.
#
# presence-check: (entryDN=dn=cn=admin,ou=users,dc=__LDAP_BASE_DN__)
#     // Contains LDAP filter to be run as a check. If any entry is returned, the check result is considered to be "true".
#
# on-present: skip | execute | persist-versioning
#     // Takes effect only if presence-check is "true" and the ldif WAS NOT already executed.
#     //
#     // skip: skip this changescript and DO NOT mark it as executed
#     // execute (default): execute this changescript (effectively, the presence check is ignored by default)
#     // persist-versioning: do not execute the ldif but do mark it as executed
#
# on-failure: fail | success
#     // What to do if application of ldif fails.
#     //
#     // fail (default): do not continue further with schema updates
#     // success: act as if the changescript executed without errors, including marking it as executed
#
# ----- LDIF HEADER END -----

# first, fill-out the header above. delete settings you do not need
# second, add your ldif content below the header
