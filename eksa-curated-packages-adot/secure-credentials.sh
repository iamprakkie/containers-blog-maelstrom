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
    echo -e "${R}env variable EKSA_ACCOUNT_ID not set${NC}"; exit 1
fi

if [ -z "${EKSA_CLUSTER_REGION}" ]; then
    echo -e "${R}env variable EKSA_CLUSTER_REGION not set${NC}"; exit 1
fi

kmsStartDateUTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
kmsStartDateEpoch=$(TZ="UTC" date +'%s' -d "${kmsStartDateUTC}")
kmsStartDateLocal=$(date -d "@${kmsStartDateEpoch}")

#allowing KMS Key access for two hours
kmsEndDateEpoch=$(( ${kmsStartDateEpoch} + (3600 * 2) ))
kmsEndDateLocal=$(date -d "@${kmsEndDateEpoch}")
kmsEndDateUTC=$(date -u -d "@${kmsEndDateEpoch}" '+%Y-%m-%dT%H:%M:%SZ')

#create key policy file
sed -e "s|{{EKSA_ACCOUNT_ID}}|${EKSA_ACCOUNT_ID}|g; s|{{KMS_START_TIME}}|${kmsStartDateUTC}|g; s|{{KMS_END_TIME}}|${kmsEndDateUTC}|g" templates/kms-key-policy-template.json > kms-key-policy.json

#checking for existing KMS key with same alias
existingAlias=$(aws kms list-aliases  --region ${EKSA_CLUSTER_REGION} --query "Aliases[?AliasName=='alias/eksa-ssm-params-key'].AliasName" --output text)
if [ ! -z ${existingAlias} ]; then
    echo -e "${Y}KMS key with alias "${existingAlias}" found in region ${EKSA_CLUSTER_REGION}. Will use this KMS Key with updated validity.${NC}"
    EKSA_KMS_KEY_ID=$(aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id alias/eksa-ssm-params-key --query KeyMetadata.KeyId --output text)
else
    #create kms key
    EKSA_KMS_KEY_ID=$(aws kms create-key --region ${EKSA_CLUSTER_REGION} --description "Encryption Key for EKSA SSM Paremeters" --key-spec SYMMETRIC_DEFAULT --key-usage ENCRYPT_DECRYPT --query KeyMetadata.KeyId --output text)
    aws kms create-alias --region ${EKSA_CLUSTER_REGION} --alias-name alias/eksa-ssm-params-key --target-key-id ${EKSA_KMS_KEY_ID}
    #aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id alias/eksa-ssm-params-key
fi

aws kms put-key-policy --region ${EKSA_CLUSTER_REGION} --policy-name default --key-id ${EKSA_KMS_KEY_ID} --policy file://kms-key-policy.json
#aws kms get-key-policy --region ${EKSA_CLUSTER_REGION} --policy-name default --key-id ${EKSA_KMS_KEY_ID} --output text

echo -e "${G}Created/Updated KMS Key ${EKSA_KMS_KEY_ID} with alias alias/eksa-ssm-params-key and validity from ${kmsStartDateLocal} till ${kmsEndDateLocal}.${NC}"

#deleting permission policy file
rm kms-key-policy.json

#checking for existing ssm parameters
vSphereSSMParamCheck=$(aws ssm describe-parameters --region ${EKSA_CLUSTER_REGION} --parameter-filters Key=Name,Option=Equals,Values=/eksa/vsphere/username,/eksa/vsphere/password --query 'length(Parameters[*].Name)')

if [ $vSphereSSMParamCheck == 2 ]; then
    echo -e "${G}Existing SSM Secure Parameters /eksa/vsphere/username and /eksa/vsphere/password found in region ${EKSA_CLUSTER_REGION}. You can use these SSM Secure Parmaters within validity period from ${kmsStartDateLocal} and ${kmsEndDateLocal}.${NC}"    
else
    #get vSphere credentials
    echo -ne "${Y}vSphere Username: ${NC}"
    read vSphereUsername
    echo -ne "${Y}vSphere Password: ${NC}"
    read -s vSpherePassword
    echo

    #create ssm parameters
    aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
        --name /eksa/vsphere/username \
        --type "SecureString" \
        --key-id ${EKSA_KMS_KEY_ID} \
        --value ${vSphereUsername} \
        --overwrite

    aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
        --name /eksa/vsphere/password \
        --type "SecureString" \
        --key-id ${EKSA_KMS_KEY_ID} \
        --value ${vSpherePassword} \
        --overwrite   

    echo -e "${G}Created SSM Secure Parameters /eksa/vsphere/username and /eksa/vsphere/password in region ${EKSA_CLUSTER_REGION}. You can use these SSM Secure Parmaters within validity period from ${kmsStartDateLocal} and ${kmsEndDateLocal}. ${NC}"         
fi

#checking for existing IAM user for read access to EKSA ECR for curated packages.
existingIAMUser=$(aws iam list-users --query "Users[?UserName=='EKSACuratedPackagesAccessUser'].UserName" --output text)

if [ ! -z ${existingIAMUser} ]; then

    attachedPoliciesCount=$(aws iam list-attached-user-policies --user-name EKSACuratedPackagesAccessUser --query 'length(AttachedPolicies)')
    attachedUserPoliciesCount=$(aws iam list-user-policies --user-name EKSACuratedPackagesAccessUser --query 'length(PolicyNames)')
    attachedUserPolicy=$(aws iam list-user-policies --user-name EKSACuratedPackagesAccessUser --query PolicyNames --output text)

    if [ ${attachedPoliciesCount} == 0 ] && [ ${attachedUserPoliciesCount} == 1 ]  && [ ${attachedUserPolicy} == 'EKSACuratedPackagesAccessPolicy' ]; then
        echo -e "${Y}Existing IAM User with name "${existingIAMUser}" found. Will use this IAM user to create access key for read access to EKSA ECR for curated packages.${NC}"
    else
        echo -e "${R}Existing IAM User with name "${existingIAMUser}" found with unexpected policies. Fix the policies or delete this IAM user to proceed.${NC}"
        exit 1
    fi

else
    #create IAM user to generate AKID and Secret access key
    echo -e "${Y}Creating IAM User EKSACuratedPackagesAccessUser with read access to EKSA ECR for curated packages.${NC}"    
    aws iam create-user --user-name EKSACuratedPackagesAccessUser

    #attach inline policy 
    aws iam put-user-policy --user-name EKSACuratedPackagesAccessUser \
        --policy-name EKSACuratedPackagesAccessPolicy \
        --policy-document file://templates/eksa-curated-packages-access-policy.json
fi

#checking for existing ssm parameters
accessKeySSMParamCheck=$(aws ssm describe-parameters --region ${EKSA_CLUSTER_REGION} --parameter-filters Key=Name,Option=Equals,Values=/eksa/iam/ecr-akid,/eksa/iam/ecr-sak --query 'length(Parameters[*].Name)')

if [ $accessKeySSMParamCheck == 2 ]; then
    echo -e "${G}Existing SSM Secure Parameters /eksa/iam/ecr-akid and /eksa/iam/ecr-sak found in region ${EKSA_CLUSTER_REGION}. You can use these SSM Secure Parmaters within validity period from ${kmsStartDateLocal} and ${kmsEndDateLocal}.${NC}"    
else
    #Generate AKID and Secret
    echo -e "${Y}Creating Access Key ID and Secret Access Key for IAM User EKSACuratedPackagesAccessUser.${NC}"    
    accessKeyCred=$(aws iam create-access-key --user-name EKSACuratedPackagesAccessUser --query '{AKID:AccessKey.AccessKeyId,SAK:AccessKey.SecretAccessKey}' --output text)

    accessKeyCredArr=($accessKeyCred)

    #create ssm parameters
    aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
        --name /eksa/iam/ecr-akid \
        --type "SecureString" \
        --key-id ${EKSA_KMS_KEY_ID} \
        --value ${accessKeyCredArr[0]} \
        --overwrite

    aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
        --name /eksa/iam/ecr-sak \
        --type "SecureString" \
        --key-id ${EKSA_KMS_KEY_ID} \
        --value ${accessKeyCredArr[1]} \
        --overwrite    
    
    echo -e "${G}Created SSM Secure Parameters /eksa/iam/ecr-akid and /eksa/iam/ecr-sak in region ${EKSA_CLUSTER_REGION}. You can use these SSM Secure Parmaters within validity period from ${kmsStartDateLocal} and ${kmsEndDateLocal}. ${NC}"         
fi


#allow bucket access for two hours
bucketStartDateUTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
bucketStartDateEpoch=$(TZ="UTC" date +'%s' -d "${bucketStartDateUTC}")
bucketStartDateLocal=$(date -d "@${bucketStartDateEpoch}")

bucketEndDateEpoch=$(( ${bucketStartDateEpoch} + (3600 * 2) ))
bucketEndDateLocal=$(date -d "@${bucketEndDateEpoch}")
bucketEndDateUTC=$(date -u -d "@${bucketEndDateEpoch}" '+%Y-%m-%dT%H:%M:%SZ')


existingRole=$(aws iam list-roles --query "Roles[?RoleName=='EKSAAdminMachineSSMServiceRole'].RoleName" --output text)
if [ ! -z ${existingRole} ]; then
    configBucketCheck=$(aws ssm describe-parameters --region ${EKSA_CLUSTER_REGION} --parameter-filters Key=Name,Option=Equals,Values=/eksa/config/s3bucket --query 'length(Parameters[*].Name)')
    if [ $configBucketCheck -ne 0 ]; then
        #create config-bucket-access-policy.json
        CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)
        sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{BUCKET_START_TIME}}|${bucketStartDateUTC}|g; s|{{BUCKET_END_TIME}}|${bucketEndDateUTC}|g" templates/config-bucket-access-policy-template.json > config-bucket-access-policy.json

        #attach inline policy to allow access to EKSA Curated Packages
        aws iam put-role-policy \
            --role-name EKSAAdminMachineSSMServiceRole \
            --policy-name EKSACluserConfigAccessPolicy \
            --policy-document file://config-bucket-access-policy.json

        echo -e "${G}Updated EKSACluserConfigAccessPolicy validity in EKSAAdminMachineSSMServiceRole. You can use this policy within validity period from ${bucketStartDateLocal} and ${bucketEndDateLocal}. ${NC}"
    fi
fi