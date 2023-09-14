#!/bin/bash
# set -x

COMMAND="${1}"

if [[ -f "${COMMAND}" ]]; then
    exec bash -c "./${*}"
elif [[ $(command -v "${COMMAND}") > /dev/null ]]; then
    exec "${*}"
else
    if [[ "${COMMAND}" == "run-faucet" ]]; then
        exec ./run-faucet.sh
    elif [[ "${COMMAND}" == "auto-refill" ]]; then
        exec ./run-auto-refill.sh
    elif [[ "${COMMAND}" == "sleep" ]]; then
        exec sleep infinity
    else
        echo "command \"${COMMAND}\" not support, exit."
        exit 1
    fi
fi
