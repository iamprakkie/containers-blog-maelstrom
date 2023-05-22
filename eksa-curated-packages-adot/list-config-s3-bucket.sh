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

# preparing ssm command file
cat > list-config-s3-bucket-command.json << EOF
{
    "Parameters": {
        "commands": [
            "su ssm-user --shell bash -c 'export KUBECONFIG=/home/ssm-user/${EKSA_CLUSTER_NAME}/${EKSA_CLUSTER_NAME}-eks-a-cluster.kubeconfig; set -o pipefail; kubectl exec -n test-ns awscli -- aws s3 ls ${CLUSTER_CONFIG_S3_BUCKET}'"
        ]
    }
}
EOF

ssm_send_command ${MI_ADMIN_MACHINE} "list-config-s3-bucket-command.json" "List contents of config s3 bucket"

rm -f list-config-s3-bucket-command.json
