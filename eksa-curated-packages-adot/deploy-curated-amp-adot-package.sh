#!/bin/bash

NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow

# exit when any command fails
set -e

#checking for required OS env variables
source ./env-vars-check.sh
env_vars_check
echo -e "${Y}"

#creating AMP workspace
export EKSA_AMP_WORKSPACE_ALIAS=${EKSA_CLUSTER_NAME}-AMP-workspace
existingAMPWorkspace=$(aws amp list-workspaces --region ${EKSA_CLUSTER_REGION} --alias ${EKSA_AMP_WORKSPACE_ALIAS} --query 'length(workspaces)')
if [ ${existingAMPWorkspace} -gt 0 ]; then
    echo -e "${Y}Existing AMP workspace found with alias ${EKSA_AMP_WORKSPACE_ALIAS} in region ${EKSA_CLUSTER_REGION}. Will use this AMP workspace.${NC}"
else
    echo -e "${Y}Creating AMP workspace with alias ${EKSA_AMP_WORKSPACE_ALIAS}.${NC}"
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
    echo -e "${Y}Existing IAM role with name ${existingRole} found. Will use this IAM role.${NC}"
else
    oidcIssuer=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/issuer --with-decryption --query Parameter.Value --output text)
    oidcProvider=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/provider --with-decryption --query Parameter.Value --output text)

    #create policy files
    sed -e "s|{{ISSUER_HOSTPATH}}|${oidcIssuer}|g; s|{{OIDCPROVIDER}}|${oidcProvider}|g; s|{{NAMESPACE}}|${namespace}|g; s|{{SERVICE_ACCOUNT}}|${serviceAccount}|g" templates/irsa-trust-policy-template.json > irsa-trust-policy.json

    sed -e "s|{{EKSA_AMP_WORKSPACE_ARN}}|${EKSA_AMP_WORKSPACE_ARN}|g" templates/irsa-amp-permission-policy-template.json > irsa-amp-permission-policy.json

    #create role with trust policy
    echo -e "${Y}Creating IAM role for AMP access to ADOT using IRSA.${NC}"
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

#prepare manifest files for pod identity webhooks
#rm -fr amazon-eks-pod-identity-webhook
#git clone https://github.com/aws/amazon-eks-pod-identity-webhook

sed -e "s|{{NAMESPACE}}|${namespace}|g; s|{{ROLEARN}}|${roleARN}|g" templates/pod-identity-webhook-auth-template.yaml > pod-identity-webhook-auth.yaml
sed -e "s|{{NAMESPACE}}|${namespace}|g; s|{{ROLEARN}}|${roleARN}|g" templates/pod-identity-webhook-deployment-template.yaml > pod-identity-webhook-deployment.yaml
sed -e "s|{{NAMESPACE}}|${namespace}|g; s|{{ROLEARN}}|${roleARN}|g" templates/pod-identity-webhook-mutatingwebhook-template.yaml > pod-identity-webhook-mutatingwebhook.yaml
sed -e "s|{{NAMESPACE}}|${namespace}|g; s|{{ROLEARN}}|${roleARN}|g" templates/pod-identity-webhook-service-template.yaml > pod-identity-webhook-service.yaml

#get config bucket name
CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)

#blocking public access for S3 bucket
echo -e "${Y}Blocking public access for S3 bucket ${CLUSTER_CONFIG_S3_BUCKET}.${NC}"
aws s3api put-public-access-block \
--region ${EKSA_CLUSTER_REGION} \
--bucket ${CLUSTER_CONFIG_S3_BUCKET} \
--public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

#upload files to config bucket
echo -e "${Y}Uploading pod identity webhook manifest files to ${CLUSTER_CONFIG_S3_BUCKET}.${NC}"
aws s3 cp pod-identity-webhook-auth.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}
aws s3 cp pod-identity-webhook-deployment.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}
aws s3 cp pod-identity-webhook-mutatingwebhook.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}
aws s3 cp pod-identity-webhook-service.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

echo -e "${Y}Deploying pod identity webhook in namespace ${namespace} with IAM role AMP-ADOT-IRSA-Role for IRSA.${NC}"
MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

#create deploy-pod-identity-webhook-command.json
sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g" templates/deploy-pod-identity-webhook-command-template.json > deploy-pod-identity-webhook-command.json

ssmCommandId=$(aws ssm send-command \
    --region ${EKSA_CLUSTER_REGION} \
    --instance-ids ${MI_ADMIN_MACHINE} \
    --document-name "AWS-RunShellScript" \
    --comment "Download pod identity webhook manifest files and deploy" \
    --cli-input-json file://deploy-pod-identity-webhook-command.json \
    --cloud-watch-output-config "CloudWatchOutputEnabled=true,CloudWatchLogGroupName=/eksa/ssm/send-command/pod-identity-webhook" \
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

echo -e "${Y}\nSSM Command Ouput: ${NC}"

aws ssm list-command-invocations \
        --command-id "${ssmCommandId}" \
        --region ${EKSA_CLUSTER_REGION} \
        --details \
        --query "CommandInvocations[].CommandPlugins[].{Output:Output}" --output text

if [ $ssmCommandStatus == "Failed" ]; then
    echo -e "${R}Pod identity webhook deployment FAILED. Check command output in Cloudwatch logs for more details.${NC}"
    exit 1
else 
    echo -e "${G}Pod identity webhook deployment COMPLETE!!! Check command output in Cloudwatch logs for more details.${NC}"
fi

#prepare curated-amp-adot-sa.yaml
sed -e "s|{{NAMESPACE}}|${namespace}|g; s|{{SERVICEACCOUNT}}|${serviceAccount}|g; s|{{ROLEARN}}|${roleARN}|g" templates/curated-amp-adot-sa-template.yaml > curated-amp-adot-sa.yaml

#upload files to config bucket
echo -e "${Y}Uploading curated-amp-adot-sa.yaml to ${CLUSTER_CONFIG_S3_BUCKET}.${NC}"
aws s3 cp curated-amp-adot-sa.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

#prepare curated-amp-adot-package.yaml
sed -e "s|{{EKSA_CLUSTER_NAME}}|$EKSA_CLUSTER_NAME|g; s|{{EKSA_CLUSTER_REGION}}|$EKSA_CLUSTER_REGION|g; s|{{EKSA_AMP_REMOTEWRITE_URL}}|$EKSA_AMP_REMOTEWRITE_URL|g; s|{{NAMESPACE}}|$namespace|g; s|{{SERVICEACCOUNT}}|$serviceAccount|g; s|{{ROLEARN}}|$roleARN|g" templates/curated-amp-adot-package-template.yaml > curated-amp-adot-package.yaml

#upload files to config bucket
echo -e "${Y}Uploading curated-amp-adot-package.yaml to ${CLUSTER_CONFIG_S3_BUCKET}.${NC}"
aws s3 cp curated-amp-adot-package.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

echo -e "${Y}Deploying curated ADOT package in namespace ${namespace}.${NC}"
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

echo -e "${Y}\nSSM Command Ouput: ${NC}"

aws ssm list-command-invocations \
        --command-id "${ssmCommandId}" \
        --region ${EKSA_CLUSTER_REGION} \
        --details \
        --query "CommandInvocations[].CommandPlugins[].{Output:Output}" --output text

if [ $ssmCommandStatus == "Failed" ]; then
    echo -e "${R}Curated ADOT deployment wth AMP FAILED. Check command output in Cloudwatch logs for more details.${NC}"
    exit 1
else 
    echo -e "${G}Curated ADOT deployment wth AMP COMPLETE!!! Check command output in Cloudwatch logs for more details.${NC}"
fi
