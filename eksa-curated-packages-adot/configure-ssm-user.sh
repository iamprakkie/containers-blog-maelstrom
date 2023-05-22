#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./ssm-send-command.sh # to send commands through ssm

#check for required env variables
env_vars_check
 
MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

log 'O' "Creating ssm-user if it doesn't exist and adding to docker group"
ssm_send_command ${MI_ADMIN_MACHINE} "templates/configure-ssm-user-command.json" "Configure SSM user and add to docker group"
