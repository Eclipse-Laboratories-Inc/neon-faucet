#!/bin/bash

REFILL_DEBUG=${REFILL_DEBUG:false}
if [[ -n "${REFILL_DEBUG}" ]] && "${REFILL_DEBUG}"; then
    set -x
fi

# WEB3_RPC_URL=https://api.evm.qa01.dev.eclipsenetwork.xyz/
# REFILL_THRESHOLD="1000"
# REFILL_AMOUNT="100"
# REFILL_ADDRESS="0xbB41a3B478b08c356B1df3334d68C78720555453"
REFILL_TELEGRAM_TOKEN=${REFILL_TELEGRAM_TOKEN:-""}
REFILL_TELEGRAM_CHAT_ID=${REFILL_TELEGRAM_CHAT_ID:-""}
BALANCE_JSON=("{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${REFILL_ADDRESS}\",\"latest\"],\"id\":1}")
REFILL_JSON=("{\"wallet\":\"${REFILL_ADDRESS}\",\"amount\":${REFILL_AMOUNT}}")

echo_log() {
    echo "$(date "+%F %X.%3N") $*"
}

if [[ -z "${WEB3_RPC_URL}" ]]; then
    echo_log "WEB3_RPC_URL not exist. exit."
    exit 1
fi

if [[ -z "${REFILL_THRESHOLD}" ]]; then
    echo_log "REFILL_THRESHOLD not exist. exit."
    exit 1
fi

if [[ -z "${REFILL_AMOUNT}" ]]; then
    echo_log "REFILL_AMOUNT not exist. exit."
    exit 1
fi

if [[ -z "${REFILL_ADDRESS}" ]]; then
    echo_log "REFILL_ADDRESS not exist. exit."
    exit 1
fi

send_telegram_notification() {
    local text
    text="${1}"
    tg_post_respond=$(curl -s -X POST https://api.telegram.org/bot${REFILL_TELEGRAM_TOKEN}/sendMessage \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${REFILL_TELEGRAM_CHAT_ID}\", \"text\": \"${text}\", \"disable_notification\": false}")
    echo_log "Telegram post respond: ${tg_post_respond}"
}

refill() {
    local balance tg_message
    while nc -z localhost "${FAUCET_RPC_PORT}" >/dev/null; do
        echo_log "Stop faucet."
        pkill -SIGINT faucet
        sleep 1
    done
    while ! nc -z localhost "${FAUCET_RPC_PORT}" >/dev/null; do
        echo_log "Start faucet."
        NEON_ETH_PER_TIME_MAX_AMOUNT=${REFILL_AMOUNT} NEON_ETH_MAX_AMOUNT=${REFILL_AMOUNT} /run-faucet.sh &
        sleep 5
    done
    # shellcheck disable=SC2128
    before_balance=$(curl -s -H "Content-Type: application/json" -X POST --data "${BALANCE_JSON}" ${WEB3_RPC_URL} | jq -r ".result" | sed "s/0x//g")
    before_balance=$(echo "ibase=16;obase=A;$(echo "${before_balance}" | tr '[:lower:]' '[:upper:]')" | bc)
    echo_log "Before refill amount: ${before_balance}"

    # Refill
    # shellcheck disable=SC2128
    refill_respond=$(curl -s -X POST http://localhost:${FAUCET_RPC_PORT}/request_neon -H 'Content-Type: application/json' -d "${REFILL_JSON}")
    echo_log "Refill respond: ${refill_respond} wei"

    # shellcheck disable=SC2128
    after_balance=$(curl -s -H "Content-Type: application/json" -X POST --data "${BALANCE_JSON}" ${WEB3_RPC_URL} | jq -r ".result" | sed "s/0x//g")
    after_balance=$(echo "ibase=16;obase=A;$(echo "${after_balance}" | tr '[:lower:]' '[:upper:]')" | bc)
    echo_log "After refill amount: ${after_balance} wei"

    if [[ "${REFILL_TELEGRAM_TOKEN}" != "" ]] && [[ "${REFILL_TELEGRAM_CHAT_ID}" != "" ]]; then
        tg_message="Auto refill balance \n"
        tg_message+="Address: ${REFILL_ADDRESS} \n"
        tg_message+="Before balance: ${before_balance} wei \n"
        tg_message+="After balance: ${after_balance} wei \n"
        # tg_message+="After balance(eth) : ${after_balance:-18}\n"

        send_telegram_notification "${tg_message}"
    fi

    while pidof faucet >/dev/null; do
        echo_log "Stop faucet."
        pkill -SIGINT faucet
        sleep 1
    done
}

main() {
    local balance re
    echo_log "Start auto-refill process."

    while true; do
        # shellcheck disable=SC2128
        balance=$(curl -s -H "Content-Type: application/json" -X POST --data "${BALANCE_JSON}" ${WEB3_RPC_URL} | jq -r ".result" | sed "s/0x//g")
        balance=$(echo "ibase=16;obase=A;$(echo "${balance}" | tr '[:lower:]' '[:upper:]')" | bc)
        re='^[0-9]+$'
        if ! [[ $balance =~ $re ]]; then
            echo_log "Balance is not a number: \"${balance}\", retry after ${REFILL_TIME_PERIOD_SECS} second."
        elif [[ ${#balance} -gt 18 ]]; then
            if [[ ${balance:0:-18} -lt ${REFILL_THRESHOLD} ]]; then
                echo_log "Balance ${balance:0:-18} is less than ${REFILL_THRESHOLD}, start re-fill amount ${REFILL_AMOUNT}."
                refill
            else
                echo_log "Balance ${balance:0:-18} is greater equal than ${REFILL_THRESHOLD}, nothing to do."
            fi
        elif [[ ${#balance} -le 18 ]]; then
            if [[ ${balance} -eq ${REFILL_THRESHOLD} ]]; then
                echo_log "Balance ${balance} is equal refill threshold ${REFILL_THRESHOLD}, nothing to do."
            else
                echo_log "Balance ${balance} wei is less than 1+E18 wei, start re-fill amount."
                refill
            fi
        else
            echo_log "Balance: ${balance} ???, retry after ${REFILL_TIME_PERIOD_SECS} second."
        fi

        sleep "${REFILL_TIME_PERIOD_SECS}"
    done

}

main "$@"
