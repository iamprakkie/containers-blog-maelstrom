#!/bin/bash

NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow
echo -e "${R}"

# exit when any command fails
set -e

read -p "This script will clean up all resources deployed as part of the blog post. Are you sure you want to proceed [y/N]? " -n 2
echo -e "\n"
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo -e "${Y}proceeding with clean up steps.${NC}"
    echo -e "\n"
else
    exit 1
fi

#checking for required OS env variables
source ./env-vars-check.sh
env_vars_check
echo -e "${Y}"

#delete cluster
#delete OIDC
#delete SSM send commands
#delete SSM Cloudwatch logs
#delete AMG
#delete AMP
#delete S3 buckets
#delete SSM params
#delete keys
#delete IAM user
#delete roles



echo -e "${Y}deleting SSM parameters /eksa/iam/ecr-akid and /eksa/iam/ecr-sak.${NC}"
#delete deleting SSM parameters /eksa/iam/ecr-akid and /eksa/iam/ecr-sak
aws ssm delete-parameters --region ${EKSA_CLUSTER_REGION} \
    --names "/eksa/iam/ecr-akid" "/eksa/iam/ecr-sak"

echo -e "${Y}deleting IAM user EKSACuratedPackagesAccessUser and their access keys.${NC}"
#delete AKIDs of IAM user EKSACuratedPackagesAccessUser
for i in `aws iam list-access-keys --user-name EKSACuratedPackagesAccessUser --query AccessKeyMetadata[].AccessKeyId --output text`; do
    aws iam delete-access-key --user-name EKSACuratedPackagesAccessUser --access-key-id $i
done

#delete user policy of IAM user EKSACuratedPackagesAccessUser
aws iam delete-user-policy --user-name EKSACuratedPackagesAccessUser --policy-name EKSACuratedPackagesAccessPolicy

#delete IAM user EKSACuratedPackagesAccessUser
aws iam delete-user --user-name EKSACuratedPackagesAccessUser

####################
exit 2
####################

#delete EKSAAdminMachineSSMServiceRole Role
echo -e "${Y}deleting EKSAAdminMachineSSMServiceRole.${NC}"
# datach role policy
for i in $(aws iam list-attached-role-policies --role-name EKSAAdminMachineSSMServiceRole --query AttachedPolicies[*].PolicyArn[] --output text); do
    echo -e "${Y}detaching policy $i from role EKSAAdminMachineSSMServiceRole${NC}"
    aws iam detach-role-policy --role-name EKSAAdminMachineSSMServiceRole --policy-arn $i
done

for i in $(aws iam list-role-policies --role-name EKSAAdminMachineSSMServiceRole --query PolicyNames --output text); do
    echo -e "${Y}deleting inline policy $i from role EKSAAdminMachineSSMServiceRole${NC}"
    aws iam delete-role-policy --role-name EKSAAdminMachineSSMServiceRole --policy-name $i
done

aws iam delete-role --role-name EKSAAdminMachineSSMServiceRole

echo -e "\n${G}CLEANUP COMPLETE!!${NC}"

