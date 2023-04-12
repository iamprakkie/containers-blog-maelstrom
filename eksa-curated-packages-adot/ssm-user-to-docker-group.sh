#!/bin/bash
NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow
echo -e "${Y}"

# exit when any command fails
set -e

# checking environment variables
if [ -z "${EKSA_ACCOUNT_ID}" ]; then
    echo -e "${R}env variable EKSA_ACCOUNT_ID not set${NC}"; exit 1
fi

if [ -z "${EKSA_CLUSTER_REGION}" ]; then
    echo -e "${R}env variable EKSA_CLUSTER_REGION not set${NC}"; exit 1
fi

MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

#running ssm command
ssmCommandId=$(aws ssm send-command \
    --region ${EKSA_CLUSTER_REGION} \
    --instance-ids ${MI_ADMIN_MACHINE} \
    --document-name "AWS-RunShellScript" \
    --comment "Add ssm-user to docker group" \
    --parameters commands='sudo usermod -a -G docker ssm-user' \
    --output text --query "Command.CommandId") 

#run command status    
aws ssm list-command-invocations \
    --command-id "${ssmCommandId}" \
    --region ${EKSA_CLUSTER_REGION} \
    --details \
    --query "CommandInvocations[].CommandPlugins[].{Status:Status}" \
    --output text