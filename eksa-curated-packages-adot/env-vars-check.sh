#!/bin/bash

source ./format_display.sh

function env_vars_check() {
    # checking environment variables
    if [ -z "${EKSA_ACCOUNT_ID}" ]; then
        log 'R' "env variable EKSA_ACCOUNT_ID not set"; exit 1
    fi

    if [ -z "${EKSA_CLUSTER_REGION}" ]; then
        log 'R' "env variable EKSA_CLUSTER_REGION not set"; exit 1
    fi

    if [ -z "${EKSA_CLUSTER_NAME}" ]; then
        log 'R' "env variable EKSA_CLUSTER_NAME not set"; exit 1
    fi
}
