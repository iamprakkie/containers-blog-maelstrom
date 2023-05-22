#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./ssm-send-command.sh # to apply manifest file

#check for required env variables
env_vars_check

#get config bucket name
CLUSTER_CONFIG_S3_BUCKET=$(aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)

#get admin machine instance id
MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

# preparing 
cat > create-eksa-cluster-command.json << EOF
{
    "Parameters": {
        "commands": [
            "su ssm-user --shell bash -c 'export KUBECONFIG=/home/ssm-user/${EKSA_CLUSTER_NAME}/${EKSA_CLUSTER_NAME}-eks-a-cluster.kubeconfig; set -o pipefail; kubectl exec -n test-ns awscli -- aws s3 ls ${CLUSTER_CONFIG_S3_BUCKET}'"
        ]
    }
}
EOF

exit 22

ssm_send_command ${MI_ADMIN_MACHINE} "create-eksa-cluster-command.json" "Download cluster config to ADMIN MACHINE and create EKSA cluster"

log 'G' "CLUSTER CREATION COMPLETE!!!"

rm -f create-eksa-cluster-command.json



ssmCommandId=$(aws ssm send-command --region ${EKSA_CLUSTER_REGION} \
    --instance-ids ${MI_ADMIN_MACHINE} --document-name "AWS-RunShellScript" \
    --parameters 'commands=["kubectl exec -n test-ns awscli -- aws s3 ls $CLUSTER_CONFIG_S3_BUCKET"]' \
    --output text --query "Command.CommandId")
    
sleep 3s # Waits 3 seconds

aws ssm list-command-invocations --command-id ${ssmCommandId} \
    --region ${EKSA_CLUSTER_REGION} --details \
    --query "CommandInvocations[].CommandPlugins[].{Output:Output}" --output text

if [[ $# -ne 1 ]]; then
    log 'R' "Usage: deploy-manifest <MANIFEST FILE NAME> [COMMENT]"
    exit 1
fi

MANIFEST_FILE=$1
CMD_COMMENT=${2:-"Deploying manifest file ${MANIFEST_FILE}"}


# Deploy manifest file here.
log 'O' "Deploying manifest file..."
kubectl_apply ${MANIFEST_FILE} "${CMD_COMMENT}"

log 'G' "Deployment of manifest file ${MANIFEST_FILE} is COMPLETE!!!"
