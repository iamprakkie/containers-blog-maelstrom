#!/bin/bash

set -e # exit when any command fails

source ./format_display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./ssm-send-command.sh # to send commands through ssm
source ./deploy-pod-identity-webhook.sh # to deploy pod-identity-webhook

#check for required env variables
env_vars_check

create_irsa_role() {
    if [[ $# -ne 3 ]]; then
        log 'R' "Usage: create_irsa_role <NAMESPACE> <SERVICEACCOUNT> <PERMISSION POLICY FILE NAME>"
        exit 1
    fi

    NAMESPACE=$1
    SERVICEACCOUNT=$2
    PERMISSION_POLICY_FILE=$3
    
    #checking for existing IAM Role
    existingRole=$(aws iam list-roles --query "Roles[?RoleName=='${SERVICEACCOUNT}-Role'].RoleName" --output text)
    if [ ! -z ${existingRole} ]; then
        log 'C' "Existing IAM role with name ${existingRole} found. Will use this IAM role."
    else
        OIDCISSUER=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/issuer --with-decryption --query Parameter.Value --output text)
        OIDCPROVIDER=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/provider --with-decryption --query Parameter.Value --output text)

        #create policy files
        sed -e "s|{{ISSUER_HOSTPATH}}|${OIDCISSUER}|g; s|{{OIDCPROVIDER}}|${OIDCPROVIDER}|g; s|{{NAMESPACE}}|${NAMESPACE}|g; s|{{SERVICE_ACCOUNT}}|${SERVICEACCOUNT}|g" templates/irsa-trust-policy-template.json > irsa-trust-policy.json

        #create role with trust policy
        log 'O' "Creating IAM role ${SERVICEACCOUNT}-Role for IRSA."
        aws iam create-role \
            --role-name ${SERVICEACCOUNT}-Role \
            --query Role.Arn --output text \
            --assume-role-policy-document file://irsa-trust-policy.json

        #attach inline policy to allow remote write access to AMP using IRSA
        aws iam put-role-policy \
            --role-name ${SERVICEACCOUNT}-Role \
            --policy-name IRSA-AMP-PermissionPolicy \
            --policy-document file://${PERMISSION_POLICY_FILE}
    fi

    ROLEARN=$(aws iam list-roles --query "Roles[?RoleName=='${SERVICEACCOUNT}-Role'].Arn" --output text)

    #
    log 'O' "Deploying pod-identity-webhook in namespace ${NAMESPACE}..."
    deploy_pod_identity_webhook ${NAMESPACE}

    #prepare sa yaml
    sed -e "s|{{NAMESPACE}}|${NAMESPACE}|g; s|{{SERVICEACCOUNT}}|${SERVICEACCOUNT}|g; s|{{ROLEARN}}|${ROLEARN}|g" templates/irsa-sa-template.yaml > irsa-sa.yaml

    #upload files to config bucket
    log 'O' "Uploading irsa-sa.yaml to ${CLUSTER_CONFIG_S3_BUCKET}."
    aws s3 cp irsa-sa.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

    #create irsa sa
    sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g" templates/create-irsa-sa-command-template.json > create-irsa-sa-command.json
    
    MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)
    
    log 'O' "Deploying sa in namespace ${NAMESPACE}."
    ssm_send_command ${MI_ADMIN_MACHINE} "create-irsa-sa-command.json" "Deploying SA for IRSA"

    log 'G' "IRSA SETUP COMPLETE!!!"

    rm -f irsa-trust-policy.json irsa-sa.yaml create-irsa-sa-command.json
}    