#!/bin/bash
NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow
echo -e "${Y}"

# exit when any command fails
set -e

read -p "This script need to be run from ADMIN MACHINE. Are you sure and want to proceed [y/N]? " -n 2
echo -e "\n"
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo -e "proceeding..."
    echo -e "\n"
else
    exit 1
fi

# checking environment variables
if [ -z "${EKSA_ACCOUNT_ID}" ]; then
    echo -e "${R}env variable EKSA_ACCOUNT_ID not set${NC}"; exit 1
fi

if [ -z "${EKSA_CLUSTER_REGION}" ]; then
    echo -e "${R}env variable EKSA_CLUSTER_REGION not set${NC}"; exit 1
fi

if [ -z "${EKSA_CLUSTER_NAME}" ]; then
    echo -e "${R}env variable EKSA_CLUSTER_NAME not set${NC}"; exit 1
fi

#get kubeconfig
if [ -f ${HOME}/${EKSA_CLUSTER_NAME}/${EKSA_CLUSTER_NAME}-eks-a-cluster.kubeconfig ]; then
    export KUBECONFIG=${HOME}/${EKSA_CLUSTER_NAME}/${EKSA_CLUSTER_NAME}-eks-a-cluster.kubeconfig
else
    echo -e "${R}${HOME}/${EKSA_CLUSTER_NAME}/${EKSA_CLUSTER_NAME}-eks-a-cluster.kubeconfig not found.${NC}"
    exit 1
fi

#capturing AKID and Secret of IAM user for read access to EKSA ECR for curated packages.

export EKSA_AWS_ACCESS_KEY_ID=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/iam/ecr-akid --with-decryption --query Parameter.Value --output text)
export EKSA_AWS_SECRET_ACCESS_KEY=$(sudo aws ssm get-parameter --region ${EKSA_CLUSTER_REGION} --name /eksa/iam/ecr-sak --with-decryption --query Parameter.Value --output text)
export EKSA_AWS_REGION=$EKSA_CLUSTER_REGION

#checking for package controller
existingPackageController=$(kubectl get pods -n eksa-packages -o=name --field-selector=status.phase=Running | grep "eks-anywhere-packages")
if [ ! -z ${existingPackageController} ]; then
    if [ ! -f ./${EKSA_CLUSTER_NAME}.yaml ]; then
        echo -e "${R}${EKSA_CLUSTER_NAME}.yaml not found in current location ($PWD).${NC}"
        exit 1
    fi
    echo -e "${Y}Installing Package Controller in \"eksa-packages\" namespace.${NC}"
    eksctl anywhere install packagecontroller -f ./${EKSA_CLUSTER_NAME}.yaml
fi

existingADOT=$(kubectl get po -n observability -l app.kubernetes.io/instance=my-adot -o=name --field-selector=status.phase=Running)
if [ -z ${existingADOT} ]; then
    echo -e "${G}Existing ADOT curated package found in \"observability\" namespace.${NC}"
    exit 0
else
    #safety cleanup
    eksctl anywhere delete package curated-adot --cluster ${EKSA_CLUSTER_NAME} 2> /dev/null

    #create ADOT packages yaml
    sed -e "s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g" templates/adot-curated-packages-template.yaml > adot-curated-packages.yaml

    #deploy ADOT curated package
    echo -e "${Y}Deploying ADOT curated package in \"observability\" namespace.${NC}"
    eksctl anywhere create packages -f ./adot-curated-packages.yaml
fi

