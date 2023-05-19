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
 
# # create and create ssm-user
# userCheck=$(grep -c eksa /etc/passwd)
# if [ $userCheck -eq 0 ]; then
#     adduser -U -m ssm-user
# tee /etc/sudoers.d/ssm-agent-users <<'EOF'
#     # User rules for ssm-user
#     ssm-user ALL=(ALL) NOPASSWD:ALL
# EOF
#     sudo chmod 440 /etc/sudoers.d/ssm-agent-users
    
#     #creating .ssh 
#     sudo mkdir -p /home/ssm-user/.ssh
#     sudo chmod 700 /home/ssm-user/.ssh
#     sudo chown -R ssm-user:ssm-user /home/ssm-user
# fi

MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

ssm-send-command ${MI_ADMIN_MACHINE} "templates/configure-ssm-user-command.json" "Configure SSM user and add to docker group"

# #running ssm command
# ssmCommandId=$(aws ssm send-command \
#     --region ${EKSA_CLUSTER_REGION} \
#     --instance-ids ${MI_ADMIN_MACHINE} \
#     --document-name "AWS-RunShellScript" \
#     --comment "Add ssm-user to docker group" \
#     --parameters commands='sudo usermod -a -G docker ssm-user' \
#     --output text --query "Command.CommandId") 

# #run command status    
# aws ssm list-command-invocations \
#     --command-id "${ssmCommandId}" \
#     --region ${EKSA_CLUSTER_REGION} \
#     --details \
#     --query "CommandInvocations[].CommandPlugins[].{Status:Status}" \
#     --output text