#!/bin/bash
COMPONENT=Faucet
echo "$(date "+%F %X.%3N") I $(basename "$0"):${LINENO} $$ ${COMPONENT}:StartScript {} Start ${COMPONENT} service"
if [ -z "$SOLANA_URL" ]; then
  echo "$(date "+%F %X.%3N") I $(basename "$0"):${LINENO} $$ ${COMPONENT}:StartScript {} Start ${COMPONENT} SOLANA_URL is not set"
  exit 1
fi

echo "$(date "+%F %X.%3N") I $(basename "$0"):${LINENO} $$ ${COMPONENT}:StartScript {} Extracting NEON-EVM's ELF parameters"
#export EVM_LOADER=$(solana address -k /spl/bin/evm_loader-keypair.json)

solana config set --url "$SOLANA_URL"
echo "$NEON_OPERATOR_KEYPAIR" > "$HOME/.config/solana/id.json"

export $(/spl/bin/neon-cli --commitment confirmed --url "$SOLANA_URL" --evm_loader="$EVM_LOADER" neon-elf-params \
  | jq --raw-output '.value | to_entries | [.[] | .key + "=" + .value] | .[]')

BALANCE=$(solana balance | tr '.' '\t'| tr '[:space:]' '\t' | cut -f1)
if [ "$BALANCE" -eq 0 ]; then
    echo "$(date "+%F %X.%3N") W $(basename "$0"):${LINENO} $$ ${COMPONENT}:StartScript {} SOL balance is 0"
    exit 1
fi

if [ "$(spl-token balance "$NEON_TOKEN_MINT" || echo 0)" -eq 0 ]; then
    echo "$(date "+%F %X.%3N") W $(basename "$0"):${LINENO} $$ ${COMPONENT}:StartScript {} NEON balance is 0"
    exit 1
fi

faucet run
