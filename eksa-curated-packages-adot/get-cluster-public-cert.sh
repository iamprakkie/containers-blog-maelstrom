
#!/bin/bash

NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow

# exit when any command fails
set -e

#checking for required OS env variables
source ./env-vars-check.sh
env_vars_check
echo -e "${Y}"

#running ssm command to get public cert of EKSA cluster
echo -e "${Y}Getting public certificate of EKSA Cluster.${NC}"

MI_ADMIN_MACHINE=$(aws ssm --region $EKSA_CLUSTER_REGION describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

sed -e "s|{{EKSA_CLUSTER_NAME}}|$EKSA_CLUSTER_NAME|g" templates/get-cluster-pub-cert-command-template.json > get-cluster-pub-cert-command.json

ssmCommandId=$(aws ssm send-command \
    --region $EKSA_CLUSTER_REGION \
    --instance-ids $MI_ADMIN_MACHINE \
    --document-name "AWS-RunShellScript" \
    --comment "Get cluster public cert" \
    --cli-input-json file://get-cluster-pub-cert-command.json \
    --output text --query "Command.CommandId")

ssmCommandStatus=$(aws ssm list-command-invocations \
    --command-id "$ssmCommandId" \
    --region $EKSA_CLUSTER_REGION \
    --details \
    --query "CommandInvocations[].CommandPlugins[].{Status:Status}" \
    --output text)

if [ "${ssmCommandStatus}" == "Success" ]; then
aws ssm list-command-invocations \
    --command-id "$ssmCommandId" \
    --region $EKSA_CLUSTER_REGION \
    --details \
    --query "CommandInvocations[].CommandPlugins[].{Output:Output}" \
    --output text > ${EKSA_CLUSTER_NAME}-sa.pub
else
    echo -e "${R}SSM Command ${ssmCommandId} NOT IN SUCCESS state. Cannot proceed.${NC}"
    exit 1
fi

echo -e "${Y}Creating keys.json from public certificate.${NC}"
rm -fr amazon-eks-pod-identity-webhook
git clone https://github.com/aws/amazon-eks-pod-identity-webhook
cd amazon-eks-pod-identity-webhook
go run ./hack/self-hosted/main.go -key ../${EKSA_CLUSTER_NAME}-sa.pub | jq '.keys += [.keys[0]] | .keys[1].kid = ""' > ../keys.json
cd ..
rm -fr amazon-eks-pod-identity-webhook

S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/s3bucket --with-decryption --query Parameter.Value --output text)

echo -e "${Y}Uploading keys.json to ${S3_BUCKET}.${NC}"
#upload get-cluster-pub-cert.json to s3 bucket as .well-known/openid-configuration
####################aws s3 cp --acl public-read ./keys.json s3://${S3_BUCKET}/keys.json
echo "will upload keys.json to s3 bucket ${S3_BUCKET}"

echo -e "${G}PUBLIC CERT UPLOADED TO OIDC ISSUER!!! Check command output in Cloudwatch logs for more details.${NC}"