#!/bin/bash

set -e

VOLUME_HOME_DIR=${VOLUME_HOME_DIR:-"/home/relayer"}
# ----------------------------- rollapp configuration ----------------------------- #
ROLLAPP_KEY=${ROLLAPP_KEY:-"rollapp-key"}
ROLLAPP_IBC_CONF=${ROLLAPP_IBC_CONF:-"$VOLUME_HOME_DIR/rollapp-base.json"}
# ----------------------------- hub configuration ---------------------------- #
HUB_KEY=${HUB_KEY:-"hub-key"}
HUB_IBC_CONF=${HUB_IBC_CONF:-"$VOLUME_HOME_DIR/hub-base.json"}
# --------------------------- relayer configuration -------------------------- #
HOME_DIR=${HOME_DIR:-"$HOME/.relayer"}
SETTLEMENT_CONFIG=${SETTLEMENT_CONFIG:-"{\"node_address\": \"http://$HUB_RPC\", \"fury_account_name\": \"$HUB_KEY\", \"keyring_home_dir\": \"$HOME_DIR\", \"keyring_backend\":\"test\"}"}
RELAYER_PATH=${RELAYER_PATH:-"rollapp-hub"}
IBC_PORT=${IBC_PORT:-"transfer"}
IBC_VERSION=${IBC_VERSION:-"ics20-1"}
DEBUG_ADDR=${DEBUG_ADDR:-"0.0.0.0:7597"}
LINK_TIMEOUT=${LINK_TIMEOUT:-"30s"}
LINK_MAX_RETRIES=${LINK_MAX_RETRIES:-"10"}


init_relayer() {
    echo "Initializing relayer"
    rly config init --settlement-config "$SETTLEMENT_CONFIG"
}

get_ibc_config() {
    tmp_for_swap=$(mktemp)
    result=$(mktemp)
    KEY=$1
    CHAIN_ID=$2
    RPC=$3
    IBC_CONF=$4
    jq --arg key "$KEY" '.value.key = $key' $IBC_CONF > "$tmp_for_swap" && mv "$tmp_for_swap" "$result"
    jq --arg chain "$CHAIN_ID" '.value."chain-id" = $chain' $result > "$tmp_for_swap" && mv "$tmp_for_swap" "$result"
    jq --arg rpc "tcp://$RPC" '.value."rpc-addr" = $rpc' $result > "$tmp_for_swap" && mv "$tmp_for_swap" "$result"
    echo $result
}

wait_for_chain() {
    RPC_HOST=$(echo $1 | cut -d':' -f1)
    RPC_PORT=$(echo $1 | cut -d':' -f2)
    # Wait for the hub to be up using curl on port 26657
    while ! curl -s $RPC_HOST:$RPC_PORT; do
        echo "Waiting for $1 to be up"
        sleep 5
    done
}

add_chains_to_relayer() {
    echo "Updating relayer config"
    rollapp_ibc_config=$(get_ibc_config "$ROLLAPP_KEY" "$ROLLAPP_CHAIN_ID" "$ROLLAPP_RPC" "$ROLLAPP_IBC_CONF")
    hub_ibc_config=$(get_ibc_config "$HUB_KEY" "$HUB_CHAIN_ID" "$HUB_RPC" "$HUB_IBC_CONF")
    echo "Adding chains to relayer"
    rly chains add -f $rollapp_ibc_config $ROLLAPP_CHAIN_ID
    rly chains add -f $hub_ibc_config $HUB_CHAIN_ID
}

create_keys_for_hub_and_rollapp() {
    echo "Creating keys for hub and rollapp"
    rly keys add $ROLLAPP_CHAIN_ID $ROLLAPP_KEY
    rly keys add $HUB_CHAIN_ID $HUB_KEY
    echo "Writing address to shared volume"
    relayer_rollapp_address=$(rly keys show $ROLLAPP_CHAIN_ID $ROLLAPP_KEY)
    relayer_hub_address=$(rly keys show $HUB_CHAIN_ID $HUB_KEY)
    echo $relayer_rollapp_address > /home/rollapp-a/addresses-to-fund/$relayer_rollapp_address
    echo $relayer_hub_address > /home/hub/addresses-to-fund/$relayer_hub_address
}

create_ibc_link() {
    echo "Creating IBC link"
    rly paths new "$ROLLAPP_CHAIN_ID" "$HUB_CHAIN_ID" "$RELAYER_PATH" --src-port "$IBC_PORT" --dst-port "$IBC_PORT" --version "$IBC_VERSION"
    ## TODO: query the hub for the first batch and wait for it to be written
    echo "Waiting sequencer to write the first batch.."
    sleep 60
    rly transact link "$RELAYER_PATH" --src-port "$IBC_PORT" --dst-port "$IBC_PORT" --version "$IBC_VERSION" --timeout $LINK_TIMEOUT --max-retries $LINK_MAX_RETRIES
}

start_relayer() {
    echo "Starting relayer"
    rly start "$RELAYER_PATH" --debug-addr "$DEBUG_ADDR"
}

wait_for_chains() {
    echo "Waiting for chains to be ready"
    wait_for_chain "$HUB_RPC"
    wait_for_chain "$ROLLAPP_RPC"
}

main() {
    init_relayer
    add_chains_to_relayer
    create_keys_for_hub_and_rollapp
    wait_for_chains
    create_ibc_link
    start_relayer
}

main