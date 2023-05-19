#!/bin/bash

source ./format_display.sh

# exit when any command fails
set -e

# checking environment variables
source ./env-vars-check.sh
env_vars_check

serviceAccountIssuerCheck=$(grep "serviceAccountIssuer:" ./${EKSA_CLUSTER_NAME}.yaml | wc -l)
if [ $serviceAccountIssuerCheck -gt 0 ]; then
    log 'O' "${EKSA_CLUSTER_NAME}.yaml has serviceAccountIssuer already. Will proceed with OIDC issuer configured here for IRSA."
    cp ./${EKSA_CLUSTER_NAME}.yaml ./${EKSA_CLUSTER_NAME}.yaml.bkp
    cp ./${EKSA_CLUSTER_NAME}.yaml ./${EKSA_CLUSTER_NAME}-with-iampodconfig.yaml

    S3_BUCKET=$(grep "serviceAccountIssuer:" ./${EKSA_CLUSTER_NAME}-with-iampodconfig.yaml | sed 's/^[[:space:]]*//g' | cut -d'/' -f3 | cut -d'.' -f1)
    #HOSTNAME=s3.${EKSA_CLUSTER_REGION}.amazonaws.com
    #ISSUER_HOSTPATH=${HOSTNAME}/${S3_BUCKET}
    ISSUER_HOSTPATH=${S3_BUCKET}.s3.${EKSA_CLUSTER_REGION}.amazonaws.com

else    

    existingBucket=$(sudo aws ssm get-parameters --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/s3bucket --query Parameters[0].Name --output text)

    if [ ${existingBucket} != "None" ]; then
        S3_BUCKET=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/oidc/s3bucket --with-decryption --query Parameter.Value --output text)
        log 'C' "Existing S3 bucket ${S3_BUCKET} found. Will proceed with using this bucket for OIDC issuer."
        ISSUER_HOSTPATH=${S3_BUCKET}.s3.${EKSA_CLUSTER_REGION}.amazonaws.com

    else
        log 'R' "WARNING!!"
        read -p "This step will create S3 bucket with PUBLIC ACCESS to host well-known OpenID configuration and EKSA Cluster public signing key. Are you sure you want to proceed [Y/N]? " -n 2
        
        if [[ $REPLY =~ ^[Y]$ ]]
        then
            echo -e "proceeding..."
            echo -e "\n"
        else
            exit 1
        fi

        # Create S3 bucket with a random name. Feel free to set your own name here
        export S3_BUCKET=${S3_BUCKET:-oidc-sample-$(cat /dev/random 2>/dev/null | LC_ALL=C tr -dc "[:alpha:]" 2> /dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null | head -c 32)}
        ####################TEMP
        S3_BUCKET="oidc-sample-qxbklbapzdlntiwiitxiavnsraujyrdd-constant"
        
        ISSUER_HOSTPATH=${S3_BUCKET}.s3.${EKSA_CLUSTER_REGION}.amazonaws.com

        #create ssm parameters
        EKSA_KMS_KEY_ID=$(aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id alias/eksa-ssm-params-key --query KeyMetadata.KeyId --output text)

        log 'O' "Creating SSM Secure Parameter /eksa/oidc/s3bucket in region ${EKSA_CLUSTER_REGION}."
        aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
            --name /eksa/oidc/s3bucket \
            --type "SecureString" \
            --key-id ${EKSA_KMS_KEY_ID} \
            --value ${S3_BUCKET} \
            --overwrite

        # Create the bucket if it doesn't exist
        log 'R' "Creating S3 bucket ${S3_BUCKET} with PUBLIC ACCESS."
        _bucket_name=$(aws s3api list-buckets  --query "Buckets[?Name=='${S3_BUCKET}'].Name | [0]" --out text)
        if [ $_bucket_name == "None" ]; then
            if [ "${EKSA_CLUSTER_REGION}" == "us-east-1" ]; then
                log 'O' "Create S3 bucket ${S3_BUCKET} in us-east-1"
                ####################aws s3api create-bucket --region ${EKSA_CLUSTER_REGION} --bucket ${S3_BUCKET}            
            else
                log 'O' "Creating S3 bucket ${S3_BUCKET} in ${EKSA_CLUSTER_REGION}"
                ####################aws s3api create-bucket --region ${EKSA_CLUSTER_REGION} --bucket ${S3_BUCKET} --create-bucket-configuration LocationConstraint=${EKSA_CLUSTER_REGION}            
            fi
        fi

        ####################aws s3api put-public-access-block --region ${EKSA_CLUSTER_REGION} --bucket ${S3_BUCKET} --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=true,RestrictPublicBuckets=true"
        ####################aws s3api put-bucket-ownership-controls --region ${EKSA_CLUSTER_REGION} --bucket ${S3_BUCKET} --ownership-controls="Rules=[{ObjectOwnership=BucketOwnerPreferred}]"

    fi

    #create OIDC discovery.json
    sed -e "s|{{ISSUER_HOSTPATH}}|${ISSUER_HOSTPATH}|g" templates/oidc-discovery-template.json > discovery.json

    #upload discovery.json to s3 bucket as .well-known/openid-configuration
    ####################aws s3 cp --acl public-read ./discovery.json s3://${S3_BUCKET}/.well-known/openid-configuration    
fi

#Create IAM Identity provider for OpenID Connect
log 'O' "Creating IAM Identity provider for OpenID Connect URL: ${ISSUER_HOSTPATH}."

oidcConfigHTTPStatus=$(curl -s -o /dev/null -I -w "%{http_code}" https://${ISSUER_HOSTPATH}/.well-known/openid-configuration)

if [ "${oidcConfigHTTPStatus}" != "200" ]; then
    log 'R' "Unable to reach https://${ISSUER_HOSTPATH}/.well-known/openid-configuration. Cannot proceed."
    exit 1
fi

IdPHost=$(curl -s https://${ISSUER_HOSTPATH}/.well-known/openid-configuration | jq -r '.jwks_uri | split("/")[2]')
IdPThumbPrint=$(echo | openssl s_client -servername $IdPHost -showcerts -connect $IdPHost:443 2> /dev/null \
    | sed -n -e '/BEGIN/h' -e '/BEGIN/,/END/H' -e '$x' -e '$p' | tail -n +2 \
    | openssl x509 -fingerprint -noout \
    | sed -e "s/.*=//" -e "s/://g" \
    | tr "ABCDEF" "abcdef")

if [ -z "${IdPThumbPrint}" ]; then
    log 'R' "Unable to get thumbprint for IdP ${ISSUER_HOSTPATH}. Cannot proceed."
    exit 1
fi

existingOidcProvider=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?Arn=='arn:aws:iam::${EKSA_ACCOUNT_ID}:oidc-provider/${ISSUER_HOSTPATH}'].Arn" --output text)
if [ ! -z "${existingOidcProvider}" ]; then
    read -p "Existing OIDC Provider ${existingOidcProvider} found. Do you want to delete this and create new one? [y/N]? " -n 2
    
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        log 'O' "Deleting existing OIDC Provider and creating new one."
        aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::${EKSA_ACCOUNT_ID}:oidc-provider/${ISSUER_HOSTPATH}
        oidcProvider=$(aws iam create-open-id-connect-provider \
            --url https://${ISSUER_HOSTPATH} \
            --thumbprint-list "${IdPThumbPrint}" \
            --client-id-list "sts.amazonaws.com" \
            --query OpenIDConnectProviderArn --output text)
    else
        log 'C' "Proceeding with existing OIDC Provider."
        oidcProvider="arn:aws:iam::${EKSA_ACCOUNT_ID}:oidc-provider/${ISSUER_HOSTPATH}"
    fi
else
        oidcProvider=$(aws iam create-open-id-connect-provider \
            --url https://${ISSUER_HOSTPATH} \
            --thumbprint-list "${IdPThumbPrint}" \
            --client-id-list "sts.amazonaws.com" \
            --query OpenIDConnectProviderArn --output text)

fi

if [ $serviceAccountIssuerCheck -eq 0 ]; then
    log 'O' "Updating Cluster Config with Pod IAM Config."
    cp ./${EKSA_CLUSTER_NAME}.yaml ./${EKSA_CLUSTER_NAME}.yaml.bkp
    awk -v ISSUER_HOSTPATH="${ISSUER_HOSTPATH}" '{print} /spec:/ && !n {print "  podIamConfig:\n    serviceAccountIssuer: https://"ISSUER_HOSTPATH; n++}' ./${EKSA_CLUSTER_NAME}.yaml > ./${EKSA_CLUSTER_NAME}-with-iampodconfig.yaml
fi

#create ssm parameters
EKSA_KMS_KEY_ID=$(aws kms describe-key --region ${EKSA_CLUSTER_REGION} --key-id alias/eksa-ssm-params-key --query KeyMetadata.KeyId --output text)

aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
    --name /eksa/oidc/issuer \
    --type "SecureString" \
    --key-id ${EKSA_KMS_KEY_ID} \
    --value ${ISSUER_HOSTPATH} \
    --overwrite

aws ssm put-parameter --region ${EKSA_CLUSTER_REGION} \
    --name /eksa/oidc/provider \
    --type "SecureString" \
    --key-id ${EKSA_KMS_KEY_ID} \
    --value ${oidcProvider} \
    --overwrite    

log 'G' "\nSuccessfully completed following tasks: "
log 'G' "\tCreated IAM Identity provider for OpenID Connect URL (issuer): ${ISSUER_HOSTPATH}."
log 'G' "\tCreated cluster config file ./${EKSA_CLUSTER_NAME}-with-iampodconfig.yaml with podIamConfig."
log 'G' "\tCreated/Updated SSM Secure Parameters /eksa/oidc/s3bucket, /eksa/oidc/issuer and /eksa/oidc/provider in region ${EKSA_CLUSTER_REGION}.\n"
