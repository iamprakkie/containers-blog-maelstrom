#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./create-irsa-role.sh # to create IRSA role

#check for required env variables
env_vars_check

if [[ $# -lt 2 ]]; then
    log 'R' "Usage: configure-irsa.sh <NAMESPACE> <IAM PERMISSION POLICY FILE NAME> [SERVICEACCOUNT NAME]"
    exit 1
fi

NAMESPACE=$1
PERMISSION_POLICY_FILE=$2
SERVICEACCOUNT=${3:-"${NAMESPACE}-irsa-sa"}

#create IAM role for IRSA
log 'O' "Configuring IRSA..."
create_irsa_role "${NAMESPACE}" "${SERVICEACCOUNT}" ${PERMISSION_POLICY_FILE}

log 'G' "Namespace ${NAMESPACE} is activated for IRSA with ${PERMISSION_POLICY_FILE} in namespace ${NAMESPACE} using service account ${SERVICEACCOUNT}!!!"
