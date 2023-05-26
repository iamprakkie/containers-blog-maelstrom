#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables

#check for required env variables
env_vars_check


create_securestring() {
    if [[ $# -lt 4 ]]; then
        log 'R' "Usage: create_securestring <SSM SECURESTRING NAME> <KMS KEY ALIAS> <EXISTING IAM ROLE FOR WHICH DECRYPT ACCESS IS REQUIRED> <VALUE> [UPDATE]"
        exit 1
    fi

    SECURESTRING_NAME=$1
    KMS_ALIAS=$2
    IAM_ROLE_NAME=$3
    VALUE="$4"
    UPDATE_FLAG=${5:-"NO_UPDATE"}

    #checking for existing KMS key with same alias
    existingAlias=$(aws kms list-aliases --region ${EKSA_CLUSTER_REGION} --query "Aliases[?AliasName=='${KMS_ALIAS}'].AliasName" --output text)

    if [ ! -z ${existingAlias} ]; then
        #checking for existing secure string with same kms key
        existingSecureString=$(aws ssm describe-parameters --region ${EKSA_CLUSTER_REGION} --parameter-filters Key=Type,Option=Equals,Values=SecureString Key=Name,Option=Equals,Values="${SECURESTRING_NAME}" Key=KeyId,Option=Equals,Values="${existingAlias}" --query Parameters[*].Name --output text)

        if [ -z ${existingSecureString} ]; then
            log 'C' "Existing SSM SecureString ${SECURESTRING_NAME} using KMS key with alias ${existingAlias} found in region ${EKSA_CLUSTER_REGION}."
            # UPDATE value if flag is set
            if [[ ${UPDATE_FLAG} != "UPDATE" ]]; then
                log 'R' "UPDATE flag not set. Exiting.."
                exit 1
            fi
        fi

        log 'C' "KMS key with alias "${existingAlias}" found in region ${EKSA_CLUSTER_REGION}. Will use this KMS Key.."
        EKSA_KMS_KEY_ID=$(aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id "${KMS_ALIAS}" --query KeyMetadata.KeyId --output text)
    else
        #create kms key
        EKSA_KMS_KEY_ID=$(aws kms create-key --region ${EKSA_CLUSTER_REGION} --description "Encryption Key for EKSA SSM Paremeters" --key-spec SYMMETRIC_DEFAULT --key-usage ENCRYPT_DECRYPT --query KeyMetadata.KeyId --output text)
        aws kms create-alias --region ${EKSA_CLUSTER_REGION} --alias-name "${KMS_ALIAS}" --target-key-id ${EKSA_KMS_KEY_ID}
        #aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id "${KMS_ALIAS}"

        #create key policy file
        sed -e "s|{{EKSA_ACCOUNT_ID}}|${EKSA_ACCOUNT_ID}|g; s|{{IAM_ROLE_NAME}}|${IAM_ROLE_NAME}|g" templates/kms-key-policy-template.json > kms-key-policy.json
        
        aws kms put-key-policy --region ${EKSA_CLUSTER_REGION} --policy-name default --key-id ${EKSA_KMS_KEY_ID} --policy file://kms-key-policy.json
        #aws kms get-key-policy --region ${EKSA_CLUSTER_REGION} --policy-name default --key-id ${EKSA_KMS_KEY_ID} --output text

        log 'G' "Created KMS Key ${EKSA_KMS_KEY_ID} with alias ${KMS_ALIAS}.."
        #deleting permission policy file
        rm -f kms-key-policy.json
    fi

    log 'O' "Creating/Updating SSM SecureString.."

    aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
        --name ${SECURESTRING_NAME} \
        --type "SecureString" \
        --key-id ${EKSA_KMS_KEY_ID} \
        --value "${VALUE}" \
        --overwrite

    log 'G' "SSM SecureString TASK COMPLETE!!" 

}

create_securestring $1 $2 $3 "$4" $5
