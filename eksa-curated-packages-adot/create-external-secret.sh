#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./create-securestring.sh # creates ssm securestring
source ./ssm-send-command.sh # to send commands through ssm
source ./deploy-manifest.sh # deploy manifests

#check for required env variables
env_vars_check

NAMESPACE=${1:-observability}
SERVICE_ACCOUNT=${2:-external-secrets-sa}

# Get Grafana Key
GRAFANA_KEY="Grafana Key"
# Create ExternalSecretsRole
    # Create ExternalSecretsRolePolicy

# install ESO
log 'O' "Installing External Secrets Operator.."
sed -e "s|{{EKSA_CLUSTER_NAME}}|${EKSA_CLUSTER_NAME}|g" templates/install-eso-template.json > install-eso.json
MI_ADMIN_MACHINE=$(aws ssm --region $EKSA_CLUSTER_REGION describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)
ssm_send_command ${MI_ADMIN_MACHINE} install-eso.json "Installing External Secrets Operator"

# Create IRSA
log 'O' "Creating IRSA for access to SSM SecureString /eksa/eso/grafana-key"
sed -e "s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g; s|{{EKSA_ACCOUNT_ID}}|${EKSA_ACCOUNT_ID}|g" templates/securestring-perm-policy-template.json > securestring-perm-policy.json
bash ./configure-irsa.sh ${NAMESPACE} "securestring-perm-policy.json" ${SERVICE_ACCOUNT}

# create ssm securestring
create_securestring /eksa/eso/grafana-key alias/eso/kms-key ${SERVICE_ACCOUNT}-Role "${GRAFANA_KEY}"

#deploy ClusterSecretStore
log 'O' "Deploying ClusterSecretStore (eksa-eso-clustersecretstore) with IRSA based authentication.."
sed -e "s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g; s|{{SERVICE_ACCOUNT}}|${SERVICE_ACCOUNT}|g; s|{{NAMESPACE}}|${NAMESPACE}|g" templates/clustersecretstore-template.yaml > clustersecretstore.yaml
bash ./deploy-manifest.sh ./clustersecretstore.yaml "MANIFEST" "Deploying ClusterSecretStore (eksa-eso-clustersecretstore) with IRSA based authentication."

#deploy ExternalSecret
log 'O' "Deploying ExternalSecret (eksa-eso-externalsecret) in namespace ${NAMESPACE}.."
sed -e "s|{{NAMESPACE}}|${NAMESPACE}|g"  templates/externalsecret-template.yaml > externalsecret.yaml
bash ./deploy-manifest.sh ./ externalsecret.yaml "MANIFEST" "Deploying ExternalSecret (eksa-eso-externalsecret) in namespace ${NAMESPACE}."



rm -f install-eso.json clustersecretstore.yaml  externalsecret.yaml

log 'G' "EXTERNAL SECRET CREATION COMPLETE!! Access secret using target secret eksa-eso-secret."
