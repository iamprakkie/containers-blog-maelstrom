#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./kubectl-delete.sh # to apply manifest file

#check for required env variables
env_vars_check

if [[ $# -lt 1 ]]; then
    log 'R' "Usage: remove-manifest <MANIFEST FILE NAME OR PACKAGE NAME for PACKAGES> [MANIFEST/PACKAGE] [COMMENT]"    
    exit 1
fi

MANIFEST_FILE=$1
MANIFEST_TYPE=${2:-"MANIFEST"}
CMD_COMMENT=${3:-"Deleting ${MANIFEST_TYPE} ${MANIFEST_FILE}"}

# Deploy manifest
log 'O' "Deleting manifest..."
kubectl_delete ${MANIFEST_FILE} ${MANIFEST_TYPE} "${CMD_COMMENT}"

log 'G' "Deletion COMPLETE!!!"
