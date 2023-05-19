#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

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
    log 'C' "KMS key with alias "${existingAlias}" found in region ${EKSA_CLUSTER_REGION}. Will use this KMS Key with updated validity."
    EKSA_KMS_KEY_ID=$(aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id alias/eksa-ssm-params-key --query KeyMetadata.KeyId --output text)
else
    #create kms key
    EKSA_KMS_KEY_ID=$(aws kms create-key --region ${EKSA_CLUSTER_REGION} --description "Encryption Key for EKSA SSM Paremeters" --key-spec SYMMETRIC_DEFAULT --key-usage ENCRYPT_DECRYPT --query KeyMetadata.KeyId --output text)
    aws kms create-alias --region ${EKSA_CLUSTER_REGION} --alias-name alias/eksa-ssm-params-key --target-key-id ${EKSA_KMS_KEY_ID}
    #aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id alias/eksa-ssm-params-key
fi

aws kms put-key-policy --region ${EKSA_CLUSTER_REGION} --policy-name default --key-id ${EKSA_KMS_KEY_ID} --policy file://kms-key-policy.json
#aws kms get-key-policy --region ${EKSA_CLUSTER_REGION} --policy-name default --key-id ${EKSA_KMS_KEY_ID} --output text

log 'G' "Created/Updated KMS Key ${EKSA_KMS_KEY_ID} with alias alias/eksa-ssm-params-key and validity from ${kmsStartDateLocal} till ${kmsEndDateLocal}."

#deleting permission policy file
rm kms-key-policy.json

#checking for existing ssm parameters
vSphereSSMParamCheck=$(aws ssm describe-parameters --region ${EKSA_CLUSTER_REGION} --parameter-filters Key=Name,Option=Equals,Values=/eksa/vsphere/username,/eksa/vsphere/password --query 'length(Parameters[*].Name)')

if [ $vSphereSSMParamCheck == 2 ]; then
    log 'C' "Existing SSM Secure Parameters /eksa/vsphere/username and /eksa/vsphere/password found in region ${EKSA_CLUSTER_REGION}. You can use these SSM Secure Parmaters within validity period from ${kmsStartDateLocal} and ${kmsEndDateLocal}."
else
    #get vSphere credentials
    echo -ne "vSphere Username: "
    read vSphereUsername
    echo -ne "vSphere Password: "
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

    log 'G' "Created SSM Secure Parameters /eksa/vsphere/username and /eksa/vsphere/password in region ${EKSA_CLUSTER_REGION}. You can use these SSM Secure Parmaters within validity period from ${kmsStartDateLocal} and ${kmsEndDateLocal}." 
fi

#checking for existing IAM user for read access to EKSA ECR for curated packages.
existingIAMUser=$(aws iam list-users --query "Users[?UserName=='EKSACuratedPackagesAccessUser'].UserName" --output text)

if [ ! -z ${existingIAMUser} ]; then

    attachedPoliciesCount=$(aws iam list-attached-user-policies --user-name EKSACuratedPackagesAccessUser --query 'length(AttachedPolicies)')
    attachedUserPoliciesCount=$(aws iam list-user-policies --user-name EKSACuratedPackagesAccessUser --query 'length(PolicyNames)')
    attachedUserPolicy=$(aws iam list-user-policies --user-name EKSACuratedPackagesAccessUser --query PolicyNames --output text)

    if [ ${attachedPoliciesCount} == 0 ] && [ ${attachedUserPoliciesCount} == 1 ]  && [ ${attachedUserPolicy} == 'EKSACuratedPackagesAccessPolicy' ]; then
        log 'C' "Existing IAM User with name "${existingIAMUser}" found. Will use this IAM user to create access key for read access to EKSA ECR for curated packages."
    else
        log 'R' "Existing IAM User with name "${existingIAMUser}" found with unexpected policies. Fix the policies or delete this IAM user to proceed."
        exit 1
    fi

else
    #create IAM user to generate AKID and Secret access key
    log 'O' "Creating IAM User EKSACuratedPackagesAccessUser with read access to EKSA ECR for curated packages."
    aws iam create-user --user-name EKSACuratedPackagesAccessUser

    #attach inline policy 
    aws iam put-user-policy --user-name EKSACuratedPackagesAccessUser \
        --policy-name EKSACuratedPackagesAccessPolicy \
        --policy-document file://templates/eksa-curated-packages-access-policy.json
fi

#checking for existing ssm parameters
accessKeySSMParamCheck=$(aws ssm describe-parameters --region ${EKSA_CLUSTER_REGION} --parameter-filters Key=Name,Option=Equals,Values=/eksa/iam/ecr-akid,/eksa/iam/ecr-sak --query 'length(Parameters[*].Name)')

if [ $accessKeySSMParamCheck == 2 ]; then
    log 'C' "Existing SSM Secure Parameters /eksa/iam/ecr-akid and /eksa/iam/ecr-sak found in region ${EKSA_CLUSTER_REGION}. You can use these SSM Secure Parmaters within validity period from ${kmsStartDateLocal} and ${kmsEndDateLocal}."    
else
    #Generate AKID and Secret
    log 'O' "Creating Access Key ID and Secret Access Key for IAM User EKSACuratedPackagesAccessUser."    
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
    
    log 'G' "Created SSM Secure Parameters /eksa/iam/ecr-akid and /eksa/iam/ecr-sak in region ${EKSA_CLUSTER_REGION}. You can use these SSM Secure Parmaters within validity period from ${kmsStartDateLocal} and ${kmsEndDateLocal}."         
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

        log 'G' "Updated EKSACluserConfigAccessPolicy validity in EKSAAdminMachineSSMServiceRole. You can use this policy within validity period from ${bucketStartDateLocal} and ${bucketEndDateLocal}."
    fi
fi