#!/bin/bash
NC='\033[0m'       # Text Reset
R='\033[0;31m'          # Red
G='\033[0;32m'        # Green
Y='\033[0;33m'       # Yellow
echo -e "${R}"

function env_vars_check() {
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
}
