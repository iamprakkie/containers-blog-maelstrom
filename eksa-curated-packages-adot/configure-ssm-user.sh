#!/bin/bash

# to format display
source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

# to send commands through ssm
source ./ssm-send-command.sh
 
MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

log 'O' "Creating ssm-user if it doesn't exist and adding to docker group"
ssm-send-command ${MI_ADMIN_MACHINE} "templates/configure-ssm-user-command.json" "Configure SSM user and add to docker group"
