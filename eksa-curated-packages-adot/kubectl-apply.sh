#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

# to send commands through ssm
source ./ssm-send-command.sh

kubectl_apply() {
    if [[ $# -ne 2 ]]; then
        log 'R' "Usage: kubectl_apply <MANIFEST FILE NAME> \"<COMMENT>\""
        exit 1
    fi

    MANIFEST_FILE=$1
    CMD_COMMENT="$2"

    #get config bucket name
    CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)

    #upload manifest file to config bucket
    aws s3 cp "${MANIFEST_FILE}" s3://${CLUSTER_CONFIG_S3_BUCKET}

    sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{MANIFEST_FILE}}|${MANIFEST_FILE}|g" templates/kubectl-apply-manifest-template.json > kubectl-apply-manifest.json

    MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)
    ssm-send-command ${MI_ADMIN_MACHINE} "kubectl-apply-manifest.json" "${CMD_COMMENT}"

    rm -f kubectl-apply-manifest.json

}    