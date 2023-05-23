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
bash ./deploy-manifest.sh ./curated-amp-adot-package.yaml

rm -f curated-amp-adot-package.yaml

#upload files to config bucket
log 'O' "Uploading curated-amp-adot-package.yaml to ${CLUSTER_CONFIG_S3_BUCKET}."
aws s3 cp curated-amp-adot-package.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

log 'O' "Deploying curated ADOT package in NAMESPACE ${NAMESPACE}."
MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

#create deploy-curated-amp-adot-command.json
sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g" templates/deploy-curated-amp-adot-command-template.json > deploy-curated-amp-adot-command.json

ssmCommandId=$(aws ssm send-command \
    --region ${EKSA_CLUSTER_REGION} \
    --instance-ids ${MI_ADMIN_MACHINE} \
    --document-name "AWS-RunShellScript" \
    --comment "Deploying curated AMP ADOT package" \
    --cli-input-json file://deploy-curated-amp-adot-command.json \
    --cloud-watch-output-config "CloudWatchOutputEnabled=true,CloudWatchLogGroupName=/eksa/ssm/send-command/amp-adot" \
    --output text --query "Command.CommandId")
echo -e "\nSSM Command ID: ${ssmCommandId}"
ssmCommandStatus="None"
until [ $ssmCommandStatus == "Success" ] || [ $ssmCommandStatus == "Failed" ]; do
    ssmCommandStatus=$(aws ssm list-command-invocations \
        --command-id "${ssmCommandId}" \
        --region ${EKSA_CLUSTER_REGION} \
        --details \
        --query "CommandInvocations[].CommandPlugins[].{Status:Status}" --output text)
    echo $ssmCommandStatus        
    sleep 3s # Waits 3 seconds
done

log 'O' "\nSSM Command Ouput: "

aws ssm list-command-invocations \
        --command-id "${ssmCommandId}" \
        --region ${EKSA_CLUSTER_REGION} \
        --details \
        --query "CommandInvocations[].CommandPlugins[].{Output:Output}" --output text

if [ $ssmCommandStatus == "Failed" ]; then
    log 'R' "Curated ADOT deployment wth AMP FAILED. Check command output in Cloudwatch logs for more details."
    exit 1
else 
    log 'G' "Curated ADOT deployment wth AMP COMPLETE!!! Check command output in Cloudwatch logs for more details."
fi

rm -f irsa-trust-policy.json irsa-amp-permission-policy.json pod-identity-webhook-auth.yaml pod-identity-webhook-deployment.yaml pod-identity-webhook-mutatingwebhook.yaml pod-identity-webhook-service.yaml deploy-pod-identity-webhook-command.json
