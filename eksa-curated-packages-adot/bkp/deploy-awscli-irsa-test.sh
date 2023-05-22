#!/bin/bash

set -e # exit when any command fails

source ./format_display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./create-irsa-role.sh # to create IRSA role
source ./kubectl-apply.sh # to apply manifest file

#check for required env variables
env_vars_check

# sample NAMESPACE and sa name
NAMESPACE=${1:-test-irsa}
SERVICEACCOUNT=${2:-test-irsa-sa}

#get config bucket name
CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)

#configure perm policy. You can bring your own permission policy here.
sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g" templates/awscli-irsa-test-permission-policy-template.json > awscli-irsa-test-permission-policy.json

#create IAM role for IRSA
log 'O' "Configuring IRSA in namespace ${NAMESPACE} using service account ${SERVICEACCOUNT}..."
create_irsa_role "${NAMESPACE}" "${SERVICEACCOUNT}" "awscli-irsa-test-permission-policy.json"

#You can bring your own manifest file here.
log 'O' "Deploying awscli pod for testing IRSA in namespace ${NAMESPACE}"
sed -e "s|{{NAMESPACE}}|${NAMESPACE}|g; s|{{SERVICEACCOUNT}}|${SERVICEACCOUNT}|g" templates/awscli-irsa-test-template.yaml > awscli-irsa-test.yaml

log 'O' "Deploying awscli pod for testing IRSA in namespace ${NAMESPACE}"
kubectl_apply "awscli-irsa-test.yaml" "Deploying awscli pod for testing IRSA in namespace ${NAMESPACE}"

rm -f awscli-irsa-test-permission-policy.json awscli-irsa-test.yaml

log 'G' "Deployment of awscli pod for testing IRSA in namespace ${NAMESPACE} is COMPLETE!!!"