#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

#creating EKSA Cluster
if [ ! -f ./${EKSA_CLUSTER_NAME}.yaml ]; then
    log 'R' "${EKSA_CLUSTER_NAME}.yaml not found in current location ($PWD)."
    exit 1
fi

#configuring ssm-user and adding to docker group
sh ./configure-ssm-user.sh

log 'O' "Creating OIDC Issuer for IRSA."
sh ./create-oidc-issuer.sh

existingConfigBucket=$(sudo aws ssm get-parameters --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --query Parameters[0].Name --output text)

if [ ${existingConfigBucket} != "None" ]; then
    CLUSTER_CONFIG_S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/config/s3bucket --with-decryption --query Parameter.Value --output text)
else
    #create s3 bucket and upload cluster config file
    export CLUSTER_CONFIG_S3_BUCKET=${CLUSTER_CONFIG_S3_BUCKET:-eksa-cluster-config-$(cat /dev/random 2>/dev/null | LC_ALL=C tr -dc "[:alpha:]" 2> /dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null | head -c 32)}

    #create ssm parameters
    EKSA_KMS_KEY_ID=$(aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id alias/eksa-ssm-params-key --query KeyMetadata.KeyId --output text)

    log 'O' "Creating SSM Secure Parameter /eksa/config/s3bucket in region ${EKSA_CLUSTER_REGION}."
    aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
        --name /eksa/config/s3bucket \
        --type "SecureString" \
        --key-id ${EKSA_KMS_KEY_ID} \
        --value ${CLUSTER_CONFIG_S3_BUCKET} \
        --overwrite    
fi

# Create the bucket if it doesn't exist
log 'O' "Creating/Using S3 bucket ${CLUSTER_CONFIG_S3_BUCKET} for storing cluster config files."
_bucket_name=$(aws s3api list-buckets  --query "Buckets[?Name=='${CLUSTER_CONFIG_S3_BUCKET}'].Name | [0]" --out text)
if [ $_bucket_name == "None" ]; then
    if [ "${EKSA_CLUSTER_REGION}" == "us-east-1" ]; then
        aws s3api create-bucket --region us-east-1 \
            --bucket ${CLUSTER_CONFIG_S3_BUCKET}
    else
        aws s3api create-bucket --region ${EKSA_CLUSTER_REGION} \
            --bucket ${CLUSTER_CONFIG_S3_BUCKET} \
            --create-bucket-configuration LocationConstraint=${EKSA_CLUSTER_REGION}
    fi
fi

#blocking public access for S3 bucket
log 'O' "Blocking public access for S3 bucket ${CLUSTER_CONFIG_S3_BUCKET}."
aws s3api put-public-access-block \
--region ${EKSA_CLUSTER_REGION} \
--bucket ${CLUSTER_CONFIG_S3_BUCKET} \
--public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

#upload files to config bucket
log 'O' "Uploading ./${EKSA_CLUSTER_NAME}-with-iampodconfig.yaml to ${CLUSTER_CONFIG_S3_BUCKET}."
aws s3 cp ./${EKSA_CLUSTER_NAME}-with-iampodconfig.yaml s3://${CLUSTER_CONFIG_S3_BUCKET}

#allow bucket access for two hours
bucketStartDateUTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
bucketStartDateEpoch=$(TZ="UTC" date +'%s' -d "${bucketStartDateUTC}")
bucketStartDateLocal=$(date -d "@${bucketStartDateEpoch}")

bucketEndDateEpoch=$(( ${bucketStartDateEpoch} + (3600 * 2) ))
bucketEndDateLocal=$(date -d "@${bucketEndDateEpoch}")
bucketEndDateUTC=$(date -u -d "@${bucketEndDateEpoch}" '+%Y-%m-%dT%H:%M:%SZ')

#create config-bucket-access-policy.json
sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{BUCKET_START_TIME}}|${bucketStartDateUTC}|g; s|{{BUCKET_END_TIME}}|${bucketEndDateUTC}|g" templates/config-bucket-access-policy-template.json > config-bucket-access-policy.json

#attach inline policy to allow access to EKSA Curated Packages
aws iam put-role-policy \
    --role-name EKSAAdminMachineSSMServiceRole \
    --policy-name EKSACluserConfigAccessPolicy \
    --policy-document file://config-bucket-access-policy.json

#download cluster config in ADMIN MACHINE and initate cluster creation
log 'O' "\nDownloading cluster config file in ADMIN MACHINE and initiating cluster creation."
MI_ADMIN_MACHINE=$(aws ssm --region ${EKSA_CLUSTER_REGION} describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)

#create config-bucket-access-policy.json
sed -e "s|{{CLUSTER_CONFIG_S3_BUCKET}}|${CLUSTER_CONFIG_S3_BUCKET}|g; s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g; s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g" templates/create-eksa-cluster-command-template.json > create-eksa-cluster-command.json

ssmCommandId=$(aws ssm send-command \
    --region ${EKSA_CLUSTER_REGION} \
    --instance-ids ${MI_ADMIN_MACHINE} \
    --document-name "AWS-RunShellScript" \
    --comment "Download cluster config to ADMIN MACHINE and create EKSA cluster" \
    --cli-input-json file://create-eksa-cluster-command.json \
    --cloud-watch-output-config "CloudWatchOutputEnabled=true,CloudWatchLogGroupName=/eksa/ssm/send-command/cluster-creation" \
    --output text --query "Command.CommandId")
echo -e "\nSSM Command ID: ${ssmCommandId}"
ssmCommandStatus="None"
until [ $ssmCommandStatus == "Success" ] || [ $ssmCommandStatus == "Failed" ]; do
    ssmCommandStatus=$(aws ssm list-command-invocations \
        --command-id "${ssmCommandId}" \
        --region ${EKSA_CLUSTER_REGION} \
        --details \
        --query "CommandInvocations[].CommandPlugins[].{Status:Status}" --output text)
    echo $ssmCommandStatus        
    sleep 3s # Waits 3 seconds
done

log 'O' "\nSSM Command Ouput: "

aws ssm list-command-invocations \
        --command-id "${ssmCommandId}" \
        --region ${EKSA_CLUSTER_REGION} \
        --details \
        --query "CommandInvocations[].CommandPlugins[].{Output:Output}" --output text

if [ $ssmCommandStatus == "Failed" ]; then
    log 'R' "Cluster creation FAILED. Check command output in Cloudwatch logs for more details."
    exit 1
else 
    log 'G' "CLUSTER CREATION COMPLETE!!! Check command output in Cloudwatch logs for more details."
fi

#get get public cert of EKSA cluster
sh ./get-cluster-public-cert.sh
