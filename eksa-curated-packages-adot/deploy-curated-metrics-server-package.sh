#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./ssm-send-command.sh # to send commands through ssm

#check for required env variables
env_vars_check

NAMESPACE=${1:-observability}

#configure IRSA
sed -e "s|{{EKSA_AMP_WORKSPACE_ARN}}|${EKSA_AMP_WORKSPACE_ARN}|g" templates/amp-permission-policy-template.json > amp-permission-policy.json
bash ./configure-irsa.sh ${NAMESPACE} "amp-permission-policy.json" ${SERVICE_ACCOUNT}

#prepare curated-amp-adot-package.yaml


#prepare curated-metrics-server-package.yaml
sed -e "s|{{NAMESPACE}}|$NAMESPACE|g" templates/curated-metrics-server-package-template.yaml > curated-metrics-server-package.yaml

# deploy package
log 'O' "Deploying curated metrics-server package in namespace ${NAMESPACE}."
bash ./deploy-manifest.sh ./curated-metrics-server-package.yaml "PACKAGE" "Deploying curated metrics-server package in namespace ${NAMESPACE}."

rm -f curated-metrics-server-package.yaml
