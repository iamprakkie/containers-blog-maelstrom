#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

#Enabling Advanced Managed Instance Activation Tier. This is required to use Session Manager with your on-premises instances
managedInstanceActivationTier=$(aws ssm get-service-setting --region ${EKSA_CLUSTER_REGION} --setting-id /ssm/managed-instance/activation-tier --query ServiceSetting.SettingValue --output text)

if [ $managedInstanceActivationTier != "advanced" ]; then
    echo -e "\n"
    log 'O' "Enabling advanced-instances tier to use Session Manager with your on-premises instances.\n"
    aws ssm update-service-setting --region ${EKSA_CLUSTER_REGION} --setting-id /ssm/managed-instance/activation-tier --setting-value advanced
fi

#checking for existing IAM Role for EKSA Admin machine
existingRole=$(aws iam list-roles --query "Roles[?RoleName=='EKSAAdminMachineSSMServiceRole'].RoleName" --output text)
if [ ! -z ${existingRole} ]; then
    log 'O' "Existing IAM role with name ${existingRole} found. Will use this IAM role for EKSA Admin machine."
else
    #create trust policy
    sed -e "s|{{EKSA_ACCOUNT_ID}}|${EKSA_ACCOUNT_ID}|g; s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g" templates/eksa-admin-machine-trust-policy-template.json > eksa-admin-machine-trust-policy.json

    #create role with trust policy
    log 'O' "Creating IAM role for EKSA Admin machine: "
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

    #deleting permission policy file
    rm eksa-admin-machine-trust-policy.json

    #get role and policy
    #aws iam get-role --role-name EKSAAdminMachineSSMServiceRole
    #aws iam get-role-policy --role-name EKSAAdminMachineSSMServiceRole --policy-name AmazonSSMManagedInstanceCore
    #aws iam list-attached-role-policies --role-name EKSAAdminMachineSSMServiceRole --query "length(AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'])"

    # wait till role gets created and SSM trust principal is created
    # roleCheck=$(aws iam list-roles --query "length(Roles[?RoleName=='EKSAAdminMachineSSMServiceRole'])")
    # while [ $roleCheck -eq 0 ]; do
    #     log 'O' "Waiting for role to get created"
    #     sleep 5s # Waits 5 seconds
    #     roleCheck=$(aws iam list-roles --query "length(Roles[?RoleName=='EKSAAdminMachineSSMServiceRole'])")        
    # done
    # rolePolicyCheck=$(aws iam list-attached-role-policies --role-name EKSAAdminMachineSSMServiceRole --query "length(AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'])")
    # while [ $rolePolicyCheck -eq 0 ]; do
    #     log 'O' "Waiting for role policy AmazonSSMManagedInstanceCore to get attached"
    #     sleep 5s # Waits 5 seconds
    #     rolePolicyCheck=$(aws iam list-attached-role-policies --role-name EKSAAdminMachineSSMServiceRole --query "length(AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'])")
    # done
    trustPolicyCheck=$(aws iam get-role --role-name EKSAAdminMachineSSMServiceRole --query "Role.AssumeRolePolicyDocument.Statement[].Principal[].Service")
    while [ $trustPolicyCheck != "ssm.amazonaws.com" ]; do
        log 'O' "Waiting for role policy AmazonSSMManagedInstanceCore to get attached"
        sleep 5s # Waits 5 seconds
        trustPolicyCheck=$(aws iam get-role --role-name EKSAAdminMachineSSMServiceRole --query "Role.AssumeRolePolicyDocument.Statement[].Principal[].Service")
    done

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

log 'G' "Above mentioned Activation Code and Activation ID will expire on ${expirationDateLocal}."
