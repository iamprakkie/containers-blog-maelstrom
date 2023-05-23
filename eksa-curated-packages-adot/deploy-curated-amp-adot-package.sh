#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./ssm-send-command.sh # to send commands through ssm

#check for required env variables
env_vars_check

#creating AMP workspace
export EKSA_AMP_WORKSPACE_ALIAS=${EKSA_CLUSTER_NAME}-AMP-workspace
existingAMPWorkspace=$(aws amp list-workspaces --region ${EKSA_CLUSTER_REGION} --alias ${EKSA_AMP_WORKSPACE_ALIAS} --query 'length(workspaces)')
if [ ${existingAMPWorkspace} -gt 0 ]; then
    log 'C' "Existing AMP workspace found with alias ${EKSA_AMP_WORKSPACE_ALIAS} in region ${EKSA_CLUSTER_REGION}. Will use this AMP workspace."
else
    log 'O' "Creating AMP workspace with alias ${EKSA_AMP_WORKSPACE_ALIAS}."
    aws amp create-workspace --region ${EKSA_CLUSTER_REGION} --alias ${EKSA_AMP_WORKSPACE_ALIAS}
fi

EKSA_AMP_WORKSPACE_ID=$(aws amp list-workspaces --region=${EKSA_CLUSTER_REGION} --alias ${EKSA_AMP_WORKSPACE_ALIAS} --query 'workspaces[0].[workspaceId]' --output text)
EKSA_AMP_WORKSPACE_ARN=$(aws amp list-workspaces --region=${EKSA_CLUSTER_REGION} --alias ${EKSA_AMP_WORKSPACE_ALIAS} --region=${EKSA_CLUSTER_REGION} --query 'workspaces[0].[arn]' --output text)
EKSA_AMP_REMOTEWRITE_URL=$(aws amp describe-workspace --region=${EKSA_CLUSTER_REGION} --workspace-id ${EKSA_AMP_WORKSPACE_ID} --query workspace.prometheusEndpoint --output text)api/v1/remote_write

NAMESPACE=${1:-observability}
SERVICE_ACCOUNT=${2:-curated-amp-adot-sa}

#configure IRSA
bash ./configure-irsa.sh ${NAMESPACE} "templates/irsa-trust-policy-template.json" ${SERVICE_ACCOUNT}

=====

#prepare curated-amp-adot-package.yaml

ROLEARN=$(aws iam list-roles --query "Roles[?RoleName=='${SERVICEACCOUNT}-Role'].Arn" --output text)

sed -e "s|{{EKSA_CLUSTER_NAME}}|$EKSA_CLUSTER_NAME|g; s|{{EKSA_CLUSTER_REGION}}|$EKSA_CLUSTER_REGION|g; s|{{EKSA_AMP_REMOTEWRITE_URL}}|$EKSA_AMP_REMOTEWRITE_URL|g; s|{{NAMESPACE}}|$NAMESPACE|g; s|{{SERVICEACCOUNT}}|$SERVICE_ACCOUNT|g; s|{{ROLEARN}}|${ROLEARN}|g" templates/curated-amp-adot-package-template.yaml > curated-amp-adot-package.yaml

log 'O' "Deploying curated ADOT package in namespace ${NAMESPACE}."
bash ./deploy-manifest.sh "PACKAGE" ./curated-amp-adot-package.yaml

rm -f curated-amp-adot-package.yaml