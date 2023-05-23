#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables

#check for required env variables
env_vars_check

NAMESPACE=${1:-observability}

#prepare curated-metrics-server-package.yaml
sed -e "s|{{NAMESPACE}}|$NAMESPACE|g" templates/curated-metrics-server-package-template.yaml > curated-metrics-server-package.yaml

# deploy package
log 'O' "Deploying curated metrics-server package in namespace ${NAMESPACE}."
bash ./deploy-manifest.sh ./curated-metrics-server-package.yaml "PACKAGE" "Deploying curated metrics-server package in namespace ${NAMESPACE}."

rm -f curated-metrics-server-package.yaml
