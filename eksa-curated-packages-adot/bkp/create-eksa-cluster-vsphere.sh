#!/bin/bash

NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow
echo -e "${Y}"

# exit when any command fails
set -e

# read -p "This script need to be run from ADMIN MACHINE. Are you sure and want to proceed [y/N]? " -n 2
# echo -e "\n"
# if [[ $REPLY =~ ^[Yy]$ ]]
# then
#     echo -e "proceeding..."
#     echo -e "\n"
# else
#     exit 1
# fi

#checking for required OS env variables
source env-vars-check.sh
env_vars_check

export EKSA_VSPHERE_USERNAME=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/vsphere/username --with-decryption --query Parameter.Value --output text)
export EKSA_VSPHERE_PASSWORD=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/vsphere/password --with-decryption --query Parameter.Value --output text)

#capturing AKID and Secret of IAM user for read access to EKSA ECR for curated packages. 
export EKSA_AWS_ACCESS_KEY_ID=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/iam/ecr-akid --with-decryption --query Parameter.Value --output text)
export EKSA_AWS_SECRET_ACCESS_KEY=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/iam/ecr-sak --with-decryption --query Parameter.Value --output text)
export EKSA_AWS_REGION=$EKSA_CLUSTER_REGION

#creating EKSA Cluster
if [ ! -f ./${EKSA_CLUSTER_NAME}.yaml ]; then
    echo -e "${R}${EKSA_CLUSTER_NAME}.yaml not found in current location ($PWD).${NC}"
    exit 1
fi

#Creating OIDC Issuer. This is required for IRSA.
echo -e "${Y}Creating OIDC Issuer. This is required for IRSA.${NC}"
sh ./create-oidc-issuer.sh

#create EKSA cluster
echo -e "${Y}Creating EKSA cluster ${EKSA_CLUSTER_NAME}.${NC}"
eksctl anywhere -v9 create cluster -f \
    ./${EKSA_CLUSTER_NAME}-with-iampodconfig.yaml --force-cleanup 2>&1 | \
    tee ./${EKSA_CLUSTER_NAME}-cluster-creation.log

#moving cluster config dir to home directory
mv ${EKSA_CLUSTER_NAME} $HOME
ln -s ${HOME}/${EKSA_CLUSTER_NAME}/ ${EKSA_CLUSTER_NAME}

echo -e "${G}CLUSTER CREATION COMPLETE!!! Cluster configuration files are in ${HOME}/${EKSA_CLUSTER_NAME}.${NC}"

