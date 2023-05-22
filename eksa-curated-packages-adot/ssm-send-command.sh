#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

ssm_send_command() {
    if [[ $# -ne 3 ]]; then
        log 'R' "Usage: ssm_send_command <MI_ADMIN_MACHINE> <COMMAND FILE NAME> <COMMENT>"
        exit 1
    fi

    MI_ADMIN_MACHINE=$1
    CMD_FILE=$2
    CMD_COMMENT=$3

    ssmCommandId=$(aws ssm send-command \
        --region ${EKSA_CLUSTER_REGION} \
        --instance-ids ${MI_ADMIN_MACHINE} \
        --document-name "AWS-RunShellScript" \
        --comment "${CMD_COMMENT}" \
        --cli-input-json file://${CMD_FILE} \
        --cloud-watch-output-config "CloudWatchOutputEnabled=true,CloudWatchLogGroupName=/eksa/ssm/send-command/cluster-creation" \
        --output text --query "Command.CommandId")

    log 'O' "SSM Command ID: ${ssmCommandId}"
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
        log 'R' "SSM command run FAILED. Check command output in Cloudwatch logs for more details."
        exit 1
    else 
        log 'G' "SSM command run COMPLETE!!! Check command output in Cloudwatch logs for more details."
    fi
}