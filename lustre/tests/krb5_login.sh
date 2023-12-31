#!/bin/bash
#
# krb5_login.sh - obtain and cache Kerberos ticket-granting ticket
#
###############################################################################

#
# nothing need for root
#
[ $UID -eq 0 ] && exit 0

#
# list Kerberos 5 credentials silently
# exit status:
# 0 - klist finds a credentials cache
# 1 - klist does not find a credentials cache or the tickets are expired
#
klist -5 -s && exit 0

# get the user name for uid $UID
GSS_USER=$(getent passwd $UID | cut -d: -f1)

GSS_PASS=${GSS_PASS:-"$GSS_USER"}

echo "***** refresh Kerberos V5 TGT for uid $UID *****"
if [ -z "$GSS_PASS" ]; then
    kinit
else
    echo $GSS_PASS | kinit
fi
ret=$?
exit $ret
