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
#start SSM session to admin machine
aws ssm start-session --region ${EKSA_CLUSTER_REGION} --target ${MI_ADMIN_MACHINE}
