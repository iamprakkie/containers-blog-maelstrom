#!/bin/bash
NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow
echo -e "${R}"

# exit when any command fails
set -e

#checking for required OS env variables
source ./env-vars-check.sh
env_vars_check

read -p "This script will create S3 bucket with PUBLIC ACCESS to host well-known OpenID configuration and EKSA Cluster public signing key. Are you sure you want to proceed [y/N]? " -n 2
echo -e "${Y}\n"
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo -e "proceeding..."
    echo -e "\n"
else
    exit 1
fi


# Create S3 bucket with a random name. Feel free to set your own name here
export S3_BUCKET=${S3_BUCKET:-oidc-sample-$(cat /dev/random 2>/dev/null | LC_ALL=C tr -dc "[:alpha:]" 2> /dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null | head -c 32)}

# Create the bucket if it doesn't exist
echo -e "${Y}Creating S3 bucket ${S3_BUCKET} with ${R}PUBLIC ACCESS.${NC}"
_bucket_name=$(aws s3api list-buckets  --query "Buckets[?Name=='${S3_BUCKET}'].Name | [0]" --out text)
if [ $_bucket_name == "None" ]; then
    if [ "${EKSA_CLUSTER_REGION}" == "us-east-1" ]; then
        ####################aws s3api create-bucket --bucket ${S3_BUCKET}
        echo "will create s3 bucket ${S3_BUCKET} in us-east-1"
    else
        ####################aws s3api create-bucket --bucket ${S3_BUCKET} --create-bucket-configuration LocationConstraint=${EKSA_CLUSTER_REGION}
        echo "will create s3 bucket ${S3_BUCKET} in ${EKSA_CLUSTER_REGION}"
    fi
fi

#HOSTNAME=s3.${EKSA_CLUSTER_REGION}.amazonaws.com
#ISSUER_HOSTPATH=${HOSTNAME}/${S3_BUCKET}
ISSUER_HOSTPATH=${S3_BUCKET}.s3.amazonaws.com

#create OIDC discovery.json
sed -e "s|{{ISSUER_HOSTPATH}}|${ISSUER_HOSTPATH}|g" templates/oidc-discovery-template.json > discovery.json

#upload discovery.json to s3 bucket as .well-known/openid-configuration
####################aws s3 cp --acl public-read ./discovery.json s3://${S3_BUCKET}/.well-known/openid-configuration

#running ssm command to get public cert of EKSA cluster
echo -e "${Y}Getting public certificate of EKSA Cluster.${NC}"

MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

sed -e "s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g" templates/get-cluster-pub-cert-template.json > get-cluster-pub-cert.json

ssmCommandId=$(aws ssm send-command \
    --region ${EKSA_CLUSTER_REGION} \
    --instance-ids ${MI_ADMIN_MACHINE} \
    --document-name "AWS-RunShellScript" \
    --comment "Add ssm-user to docker group" \
    --cli-input-json file://get-cluster-pub-cert.json \
    --output text --query "Command.CommandId")

ssmCommandStatus=$(aws ssm list-command-invocations \
    --command-id "${ssmCommandId}" \
    --region ${EKSA_CLUSTER_REGION} \
    --details \
    --query "CommandInvocations[].CommandPlugins[].{Status:Status}" \
    --output text)

if [ "${ssmCommandStatus}" == "Success" ]; then
aws ssm list-command-invocations \
    --command-id "${ssmCommandId}" \
    --region ${EKSA_CLUSTER_REGION} \
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
go run ./hack/self-hosted/main.go -key ../sample-cluster-sa.pub | jq '.keys += [.keys[0]] | .keys[1].kid = ""' > ../keys.json
cd ..
rm -fr amazon-eks-pod-identity-webhook

#upload get-cluster-pub-cert.json to s3 bucket as .well-known/openid-configuration
####################aws s3 cp --acl public-read ./keys.json s3://${S3_BUCKET}/keys.json

####################TEMP
ISSUER_HOSTPATH="oidc-test-cmroeicetcuksgedlwkuciclylttpioz.s3.amazonaws.com"

#Create OIDC Identity Provider
echo -e "${Y}Creating OIDC Identity Provider for IdP ${ISSUER_HOSTPATH}.${NC}"

oidcConfigHTTPStatus=$(curl -s -o /dev/null -I -w "%{http_code}" https://${ISSUER_HOSTPATH}/.well-known/openid-configuration)
oidcKeysHTTPStatus=$(curl -s -o /dev/null -I -w "%{http_code}" https://${ISSUER_HOSTPATH}/keys.json)

if [ "${oidcConfigHTTPStatus}" != "200" ] || [ "${oidcKeysHTTPStatus}" != "200" ]; then
    echo -e "${R}Unable to reach https://${ISSUER_HOSTPATH}/.well-known/openid-configuration or https://${ISSUER_HOSTPATH}/keys.json. Cannot proceed.${NC}"
    exit 1
fi

IdPHost=$(curl -s https://${ISSUER_HOSTPATH}/.well-known/openid-configuration | jq -r '.jwks_uri | split("/")[2]')
IdPThumbPrint=$(echo | openssl s_client -servername $IdPHost -showcerts -connect $IdPHost:443 2> /dev/null \
    | sed -n -e '/BEGIN/h' -e '/BEGIN/,/END/H' -e '$x' -e '$p' | tail -n +2 \
    | openssl x509 -fingerprint -noout \
    | sed -e "s/.*=//" -e "s/://g" \
    | tr "ABCDEF" "abcdef")

if [ -z "${IdPThumbPrint}" ]; then
    echo -e "${R}Unable to get thumbprint for IdP ${ISSUER_HOSTPATH}. Cannot proceed.${NC}"
    exit 1
fi

existingOidcProvider=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::${EKSA_ACCOUNT_ID}:oidc-provider/${ISSUER_HOSTPATH} --query Url --output text)
if [ ! -z "${existingOidcProvider}" ]; then
    read -p "Existing OIDC Provider ${existingOidcProvider} found. Do you want to delete this and create new one? [y/N]? " -n 2
    echo -e "${Y}\n"
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        echo -e "${Y}Deleting existing OIDC Provider and creating new one.${NC}"
        aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::${EKSA_ACCOUNT_ID}:oidc-provider/${ISSUER_HOSTPATH}
        oidcProvider=$(aws iam create-open-id-connect-provider \
            --url https://${ISSUER_HOSTPATH} \
            --thumbprint-list "${IdPThumbPrint}" \
            --client-id-list "sts.amazonaws.com" \
            --query OpenIDConnectProviderArn --output text)
    else
        echo -e "${Y}Proceeding with existing OIDC Provider.${NC}"
        oidcProvider="arn:aws:iam::${EKSA_ACCOUNT_ID}:oidc-provider/${ISSUER_HOSTPATH}"
    fi
fi

echo "Updating Cluster Config with Pod IAM Config"

sed -e "s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{ISSUER_HOSTPATH}}|${ISSUER_HOSTPATH}|g; s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g" templates/update-cluster-config-template.json > update-cluster-config.json

ssmCommandId=$(aws ssm send-command \
    --region ${EKSA_CLUSTER_REGION} \
    --instance-ids ${MI_ADMIN_MACHINE} \
    --document-name "AWS-RunShellScript" \
    --comment "Update cluster config wit pod IAM Config" \
    --cli-input-json file://update-cluster-config.json \
    --output text --query "Command.CommandId")

ssmCommandStatus=$(aws ssm list-command-invocations \
    --command-id "${ssmCommandId}" \
    --region ${EKSA_CLUSTER_REGION} \
    --details \
    --query "CommandInvocations[].CommandPlugins[].{Status:Status}") 

if [ "${ssmCommandStatus}" != "Success" ]; then
    echo -e "${R}SSM Command ${ssmCommandId} NOT IN SUCCESS state.${NC}"
    exit 1
else
    echo -e "${G}Successfully deployed IAM for pods.${NC}"
fi
