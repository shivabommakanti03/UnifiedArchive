#!/bin/bash
####################################################################################
######   This Script must be run from prosfs05 box due to hard coded paths    ######
####################################################################################
SRC_FILE=$(basename $1)
SRC_SERVER="Your IP"
SRC_PATH="Source path"
DEST_SERVER="Dest IP"
DEST_PATH="Destination Path"
if [ -f  ${SRC_PATH} ]; then
    echo "$SRC_FILE Exists uploading it to Vanta site"
else
    echo "Error: $SRC_FILE does not exist. Exiting."
    exit 1
fi
ssh root@${DEST_SERVER} "cd ${DEST_PATH} && lftp -c 'open -u pfgit, sftp://pfgit@${SRC_SERVER}; pget -n 16 ${SRC_PATH}'"
exit $?
