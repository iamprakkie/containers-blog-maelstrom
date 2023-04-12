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

namespace=${1:-observability}

#get config bucket name
CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)

#blocking public access for S3 bucket
echo -e "${Y}Blocking public access for S3 bucket ${CLUSTER_CONFIG_S3_BUCKET}.${NC}"
aws s3api put-public-access-block \
--region ${EKSA_CLUSTER_REGION} \
--bucket ${CLUSTER_CONFIG_S3_BUCKET} \
--public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

#prepare curated-metrics-server-package.yaml
sed -e "s|{{EKSA_CLUSTER_NAME}}|$EKSA_CLUSTER_NAME|g; s|{{EKSA_CLUSTER_REGION}}|$EKSA_CLUSTER_REGION|g; s|{{EKSA_AMP_REMOTEWRITE_URL}}|$EKSA_AMP_REMOTEWRITE_URL|g; s|{{NAMESPACE}}|$namespace|g; s|{{SERVICEACCOUNT}}|$serviceAccount|g; s|{{ROLEARN}}|$roleARN|g" templates/curated-metrics-server-package-template.yaml > curated-metrics-server-package.yaml

#upload files to config bucket
echo -e "${Y}Uploading curated-metrics-server-package.yaml to ${CLUSTER_CONFIG_S3_BUCKET}.${NC}"
aws s3 cp curated-metrics-server-package.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

echo -e "${Y}Deploying curated metrics-server package in namespace ${namespace}.${NC}"
MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

#create config-bucket-access-policy.json
sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{NAMESPACE}}|$namespace|g; s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g" templates/deploy-curated-metrics-server-command-template.json > deploy-curated-metrics-server-command.json

ssmCommandId=$(aws ssm send-command \
    --region ${EKSA_CLUSTER_REGION} \
    --instance-ids ${MI_ADMIN_MACHINE} \
    --document-name "AWS-RunShellScript" \
    --comment "Deploying curated metrics-server package" \
    --cli-input-json file://deploy-curated-metrics-server-command.json \
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
    echo -e "${R}Curated metrics-server deployment FAILED. Check command output in Cloudwatch logs for more details.${NC}"
    exit 1
else 
    echo -e "${G}Curated metrics-server deployment COMPLETE!!! Check command output in Cloudwatch logs for more details.${NC}"
fi
