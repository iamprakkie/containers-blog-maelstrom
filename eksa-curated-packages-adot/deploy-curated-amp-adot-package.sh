#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

# to send commands through ssm
source ./ssm-send-command.sh

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

namespace=${1:-observability}
serviceAccount=${2:-curated-amp-adot-sa}

#create IAM role for IRSA 
#checking for existing IAM Role
existingRole=$(aws iam list-roles --query "Roles[?RoleName=='AMP-ADOT-IRSA-Role'].RoleName" --output text)
if [ ! -z ${existingRole} ]; then
    log 'C' "Existing IAM role with name ${existingRole} found. Will use this IAM role."
else
    oidcIssuer=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/issuer --with-decryption --query Parameter.Value --output text)
    oidcProvider=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/provider --with-decryption --query Parameter.Value --output text)

    #create policy files
    sed -e "s|{{ISSUER_HOSTPATH}}|${oidcIssuer}|g; s|{{OIDCPROVIDER}}|${oidcProvider}|g; s|{{NAMESPACE}}|${namespace}|g; s|{{SERVICE_ACCOUNT}}|${serviceAccount}|g" templates/irsa-trust-policy-template.json > irsa-trust-policy.json

    sed -e "s|{{EKSA_AMP_WORKSPACE_ARN}}|${EKSA_AMP_WORKSPACE_ARN}|g" templates/irsa-amp-permission-policy-template.json > irsa-amp-permission-policy.json

    #create role with trust policy
    log 'O' "Creating IAM role for AMP access to ADOT using IRSA."
    aws iam create-role \
        --role-name AMP-ADOT-IRSA-Role \
        --query Role.Arn --output text \
        --assume-role-policy-document file://irsa-trust-policy.json

    #attach inline policy to allow remote write access to AMP using IRSA
    aws iam put-role-policy \
        --role-name AMP-ADOT-IRSA-Role \
        --policy-name IRSA-AMP-PermissionPolicy \
        --policy-document file://irsa-amp-permission-policy.json

fi

roleARN=$(aws iam list-roles --query "Roles[?RoleName=='AMP-ADOT-IRSA-Role'].Arn" --output text)



#prepare curated-amp-adot-sa.yaml
sed -e "s|{{NAMESPACE}}|${namespace}|g; s|{{SERVICEACCOUNT}}|${serviceAccount}|g; s|{{ROLEARN}}|${roleARN}|g" templates/curated-amp-adot-sa-template.yaml > curated-amp-adot-sa.yaml

#upload files to config bucket
log 'O' "Uploading curated-amp-adot-sa.yaml to ${CLUSTER_CONFIG_S3_BUCKET}."
aws s3 cp curated-amp-adot-sa.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

#prepare curated-amp-adot-package.yaml
sed -e "s|{{EKSA_CLUSTER_NAME}}|$EKSA_CLUSTER_NAME|g; s|{{EKSA_CLUSTER_REGION}}|$EKSA_CLUSTER_REGION|g; s|{{EKSA_AMP_REMOTEWRITE_URL}}|$EKSA_AMP_REMOTEWRITE_URL|g; s|{{NAMESPACE}}|$namespace|g; s|{{SERVICEACCOUNT}}|$serviceAccount|g; s|{{ROLEARN}}|$roleARN|g" templates/curated-amp-adot-package-template.yaml > curated-amp-adot-package.yaml

#upload files to config bucket
log 'O' "Uploading curated-amp-adot-package.yaml to ${CLUSTER_CONFIG_S3_BUCKET}."
aws s3 cp curated-amp-adot-package.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

log 'O' "Deploying curated ADOT package in namespace ${namespace}."
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
