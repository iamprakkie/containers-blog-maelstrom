#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./kubectl-apply.sh # to apply manifest file

#check for required env variables
env_vars_check

if [[ $# -lt 1 ]]; then
    log 'R' "Usage: deploy-manifest <MANIFEST FILE NAME> [COMMENT]"
    exit 1
fi

MANIFEST_FILE=$1
CMD_COMMENT=${2:-"Deploying manifest file ${MANIFEST_FILE}"}


# Deploy manifest file here.
log 'O' "Deploying manifest file..."
kubectl_apply ${MANIFEST_FILE} "${CMD_COMMENT}"

log 'G' "Deployment of manifest file ${MANIFEST_FILE} is COMPLETE!!!"
