#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

# to send commands through ssm
source ./ssm-send-command.sh

#running ssm command to get public cert of EKSA cluster and upload to config s3 bucket
CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)
sed -e "s|{{EKSA_CLUSTER_NAME}}|$EKSA_CLUSTER_NAME|g; s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g" templates/get-cluster-pub-cert-command-template.json > get-cluster-pub-cert-command.json

log 'O' "Getting public certificate of EKSA Cluster."
MI_ADMIN_MACHINE=$(aws ssm --region $EKSA_CLUSTER_REGION describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)
ssm_send_command ${MI_ADMIN_MACHINE} "get-cluster-pub-cert-command.json" "Get cluster public cert"

#downloading pub file from config s3 bucket
aws s3 cp s3://${CLUSTER_CONFIG_S3_BUCKET}/${EKSA_CLUSTER_NAME}-sa.pub ./${EKSA_CLUSTER_NAME}-sa.pub

log 'O' "Creating keys.json from public certificate."
rm -fr amazon-eks-pod-identity-webhook
git clone https://github.com/aws/amazon-eks-pod-identity-webhook
cd amazon-eks-pod-identity-webhook
go run ./hack/self-hosted/main.go -key ../${EKSA_CLUSTER_NAME}-sa.pub | jq '.keys += [.keys[0]] | .keys[1].kid = ""' > ../keys.json
cd ..
rm -fr amazon-eks-pod-identity-webhook
rm -f get-cluster-pub-cert-command.json

S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/s3bucket --with-decryption --query Parameter.Value --output text)

log 'O' "Uploading keys.json to ${S3_BUCKET}."
#upload get-cluster-pub-cert.json to s3 bucket as .well-known/openid-configuration
####################aws s3 cp --acl public-read ./keys.json s3://${S3_BUCKET}/keys.json
echo "Temporary:: Manually upload keys.json to s3 bucket ${S3_BUCKET}"

rm -f ../${EKSA_CLUSTER_NAME}-sa.pub ../keys.json

log 'G' "PUBLIC CERT UPLOADED TO OIDC ISSUER!!!"