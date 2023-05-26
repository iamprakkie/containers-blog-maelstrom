#!/bin/bash
NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow
echo -e "${Y}"

# exit when any command fails
set -e

# checking environment variables
if [ -z "${EKSA_ACCOUNT_ID}" ]; then
    echo -e "${R}env variable EKSA_ACCOUNT_ID not set.${NC}"; exit 1
fi

if [ -z "${EKSA_CLUSTER_REGION}" ]; then
    echo -e "${R}env variable EKSA_CLUSTER_REGION not set.${NC}"; exit 1
fi

curr_dir=${PWD}

#Enabling Advanced Managed Instance Activation Tier. This is required to use Session Manager with your on-premises instances
managedInstanceActivationTier=$(aws ssm get-service-setting --region ${EKSA_CLUSTER_REGION} --setting-id /ssm/managed-instance/activation-tier --query ServiceSetting.SettingValue --output text)

if [ $managedInstanceActivationTier != "advanced" ]; then
    echo -e "\n"
    echo -e "${Y}Enabling advanced-instances tier to use Session Manager with your on-premises instances.${NC}\n"
    aws ssm update-service-setting \
    --region ${EKSA_CLUSTER_REGION} --setting-id /ssm/managed-instance/activation-tier \
    --setting-value advanced
fi

#checking for existing IAM Role for EKSA Admin machine
existingRole=$(aws iam list-roles --query 'Roles[?RoleName==`EKSAAdminMachineSSMServiceRole`].RoleName' --output text)
if [ ! -z ${existingRole} ]; then
    echo -e "${Y}Existing IAM role with name ${existingRole} found. Will use this IAM role for EKSA Admin machine.${NC}"
else
    #create trust policy
    sed -e "s|{{EKSA_ACCOUNT_ID}}|${EKSA_ACCOUNT_ID}|g; s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g" templates/eksa-admin-machine-trust-policy-template.json > eksa-admin-machine-trust-policy.json

    #create role with trust policy
    echo -e "${Y}Creating IAM role for EKSA Admin machine: ${NC}"
    aws iam create-role \
        --path /service-role/ \
        --role-name EKSAAdminMachineSSMServiceRole \
        --query Role.Arn --output text \
        --assume-role-policy-document file://eksa-admin-machine-trust-policy.json

    #attaches policy for managed node to use AWS Systems Manager service core functionality
    aws iam attach-role-policy \
        --role-name EKSAAdminMachineSSMServiceRole \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

    #attaches policy to allow the CloudWatch agent to run on your managed nodes.
    aws iam attach-role-policy \
        --role-name EKSAAdminMachineSSMServiceRole \
        --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

    #attaches policy to allow access to EKSA Curated Packages
    aws iam put-role-policy \
        --role-name EKSAAdminMachineSSMServiceRole \
        --policy-name EKSACuratedPackagesAccessPolicy \
        --policy-document file://templates/eksa-curated-packages-access-policy.json

    #deleting permission policy file
    rm eksa-admin-machine-trust-policy.json

    #get role and policy
    #aws iam get-role --role-name EKSAAdminMachineSSMServiceRole
    #aws iam get-role-policy --role-name EKSAAdminMachineSSMServiceRole --policy-name EKSACuratedPackagesAccessPolicy

    #inducing wait to have role created before creating activation
    sleep 5s # Waits 5 seconds
fi

expirationDate=$(date -u -d '+2 hour' '+%F %T')
expirationDateUTC=$(TZ="UTC" date +'%s' -d "${expirationDate}")
expirationDateLocal=$(date -d "@${expirationDateUTC}")

#create activation
aws ssm create-activation \
  --default-instance-name EKSA-AdminMachine \
  --description "Activation for EKSA Admin machine" \
  --iam-role service-role/EKSAAdminMachineSSMServiceRole \
  --registration-limit 1 \
  --region ${EKSA_CLUSTER_REGION} \
  --expiration-date "${expirationDate}" \
  --tags "Key=Environment,Value=EKSA" "Key=MachineType,Value=Admin" \
  --output table

echo -e "${G}Above mentioned Activation Code and Activation ID will expire on ${expirationDateLocal}.${NC}"