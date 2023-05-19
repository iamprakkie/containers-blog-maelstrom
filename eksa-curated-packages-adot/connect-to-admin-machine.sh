#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)
#start SSM session to admin machine
aws ssm start-session --region ${EKSA_CLUSTER_REGION} --target ${MI_ADMIN_MACHINE}
