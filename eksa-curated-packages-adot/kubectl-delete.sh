#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./ssm-send-command.sh # to send commands through ssm
source ./get-name-from-manifest.sh # to get name from manifest file

#check for required env variables
env_vars_check

kubectl_delete() {
    if [[ $# -ne 3 ]]; then
        log 'R' "Usage: kubectl_delete <MANIFEST FILE NAME OR PACKAGE NAME for PACKAGES> [MANIFEST/PACKAGE] [COMMENT]"
        exit 1
    fi

    MANIFEST_FILE=$1
    MANIFEST_TYPE=${2:-"MANIFEST"}
    CMD_COMMENT=${3:-"Deleting ${MANIFEST_TYPE} ${MANIFEST_FILE}"}

    #get config bucket name
    CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)

    #upload manifest file to config bucket
    aws s3 cp "${MANIFEST_FILE}" s3://${CLUSTER_CONFIG_S3_BUCKET}

    if [[ "${MANIFEST_TYPE}" == "MANIFEST" ]]; then
        sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{MANIFEST_FILE}}|`basename ${MANIFEST_FILE}`|g" templates/kubectl-delete-manifest-command-template.json > kubernetes-run-command.json
    elif [[ "${MANIFEST_TYPE}" == "PACKAGE" ]]; then
        PACKAGE_NAME=${MANIFEST_FILE}
        sed -e "s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{PACKAGE_NAME}}|${PACKAGE_NAME}|g" templates/eksctl-delete-package-command-template.json > kubernetes-run-command.json
    else
        log 'R' "Invalid manifest type ${MANIFEST_TYPE}"
        exit 1
    fi

    
    MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)
    ssm_send_command ${MI_ADMIN_MACHINE} "kubernetes-run-command.json" "${CMD_COMMENT}"

    rm -f kubernetes-run-command.json

}    