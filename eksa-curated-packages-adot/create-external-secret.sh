#!/bin/bash

set -e # exit when any command fails

source ./format-display.sh # format display
source ./env-vars-check.sh # checking environment variables
source ./create-securestring.sh # creates ssm securestring
source ./ssm-send-command.sh # to send commands through ssm

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
MI_ADMIN_MACHINE=$(aws ssm --region $EKSA_CLUSTER_REGION describe-instance-information --filters Key=tag:Environment,Values=EKSA Key=tag:MachineType,Values=Admin --query InstanceInformationList[].InstanceId --output text)
ssm_send_command ${MI_ADMIN_MACHINE} templates/install-eso.json "Installing External Secrets Operator"

# Create IRSA
log 'O' "Creating IRSA for access to SSM SecureString /eksa/eso/grafana-key"
sed -e "s|{{EKSA_CLUSTER_REGION}}|${EKSA_CLUSTER_REGION}|g; s|{{EKSA_ACCOUNT_ID}}|${EKSA_ACCOUNT_ID}|g" templates/securestring-perm-policy-template.json > securestring-perm-policy.json
bash ./configure-irsa.sh ${NAMESPACE} "securestring-perm-policy.json" ${SERVICE_ACCOUNT}

# create ssm securestring
create_securestring /eksa/eso/grafana-key alias/eso/kms-key ${SERVICE_ACCOUNT}-Role "${GRAFANA_KEY}"
