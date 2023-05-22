#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./ssm-send-command.sh # to send commands through ssm

#check for required env variables
env_vars_check

deploy_pod_identity_webhook() {
    if [[ $# -ne 1 ]]; then
        log 'R' "Usage: deploy_pod_identity_webhook <NAMESPACE>"
        exit 1
    fi

    NAMESPACE=$1

    #prepare manifest files for pod identity webhooks
    #rm -fr amazon-eks-pod-identity-webhook
    #git clone https://github.com/aws/amazon-eks-pod-identity-webhook

    sed -e "s|{{NAMESPACE}}|${NAMESPACE}|g" templates/pod-identity-webhook-auth-template.yaml > pod-identity-webhook-auth.yaml
    sed -e "s|{{NAMESPACE}}|${NAMESPACE}|g" templates/pod-identity-webhook-deployment-template.yaml > pod-identity-webhook-deployment.yaml
    sed -e "s|{{NAMESPACE}}|${NAMESPACE}|g" templates/pod-identity-webhook-mutatingwebhook-template.yaml > pod-identity-webhook-mutatingwebhook.yaml
    sed -e "s|{{NAMESPACE}}|${NAMESPACE}|g" templates/pod-identity-webhook-service-template.yaml > pod-identity-webhook-service.yaml

    #get config bucket name
    CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)

    #blocking public access for S3 bucket
    log 'O' "Blocking public access for S3 bucket ${CLUSTER_CONFIG_S3_BUCKET}."
    aws s3api put-public-access-block \
        --region ${EKSA_CLUSTER_REGION} \
        --bucket ${CLUSTER_CONFIG_S3_BUCKET} \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    #upload files to config bucket
    log 'O' "Uploading pod identity webhook manifest files to ${CLUSTER_CONFIG_S3_BUCKET}."
    aws s3 cp pod-identity-webhook-auth.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}
    aws s3 cp pod-identity-webhook-deployment.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}
    aws s3 cp pod-identity-webhook-mutatingwebhook.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}
    aws s3 cp pod-identity-webhook-service.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

    #create deploy-pod-identity-webhook-command.json
    sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g" templates/deploy-pod-identity-webhook-command-template.json > deploy-pod-identity-webhook-command.json

    # deploy pod identity webhook
    log 'O' "Deploying pod identity webhook in namespace ${NAMESPACE}."
    MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)
    ssm_send_command ${MI_ADMIN_MACHINE} "deploy-pod-identity-webhook-command.json" "Download pod identity webhook manifest files and deploy"

    log 'G' "Pod identity webhook deployment in namespace ${NAMESPACE} COMPLETE!!!"

    rm -f pod-identity-webhook-auth.yaml pod-identity-webhook-deployment.yaml pod-identity-webhook-mutatingwebhook.yaml pod-identity-webhook-service.yaml deploy-pod-identity-webhook-command.json
}