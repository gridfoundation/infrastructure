#!/bin/bash

set -e

TOKEN_AMOUNT=${TOKEN_AMOUNT:-1000000000000000000000urap}
STAKING_AMOUNT=${STAKING_AMOUNT:-500000000000000000000urap}
KEY_NAME=${KEY_NAME:-local-user}
GRIDIRON_CHAIN_ID=${GRIDIRON_CHAIN_ID:-gridiron}
ROLLAPP_ID=${ROLLAPP_ID:-rollapp}
API_ADDRESS=${API_ADDRESS:-"0.0.0.0:1317"}
RPC_LADDRESS=${RPC_LADDRESS:-"0.0.0.0:26657"}
P2P_LADDRESS=${P2P_LADDRESS:-"0.0.0.0:26656"}
GRPC_LADDRESS=${GRPC_LADDRESS:-"0.0.0.0:9090"}
GRPC_WEB_LADDRESS=${GRPC_WEB_LADDRESS:-"0.0.0.0:9091"}

CHAIN_DIR="$HOME/.rollapp"
LOG_FILE_PATH=${LOG_FILE_PATH:-"$CHAIN_DIR/log/rollapp.log"}
CONFIG_DIRECTORY="$CHAIN_DIR/config"
GENESIS_FILE="$CONFIG_DIRECTORY/genesis.json"
TENDERMINT_CONFIG_FILE="$CONFIG_DIRECTORY/config.toml"
CLIENT_CONFIG_FILE="$CONFIG_DIRECTORY/client.toml"
APP_CONFIG_FILE="$CONFIG_DIRECTORY/app.toml"
EXECUTABLE="rollappd"
KEYRING_PATH=$CHAIN_DIR


DENOM='urap'

init_directories() {
    mkdir -p /home/shared/gentx
    mkdir -p /home/shared/peers
    mkdir -p /home/shared/addresses-to-fund
}

init_chain() {
    # Init the chain
    $EXECUTABLE init "$MONIKER_NAME" --chain-id="$CHAIN_ID"
    $EXECUTABLE furyint unsafe-reset-all
    $EXECUTABLE keys add "$KEY_NAME" --keyring-backend test

    # ------------------------------- client config ------------------------------ #
    sed -i'' -e "s/^chain-id *= .*/chain-id = \"$CHAIN_ID\"/" "$CLIENT_CONFIG_FILE"

    # -------------------------------- app config -------------------------------- #
    sed -i'' -e 's/^minimum-gas-prices *= .*/minimum-gas-prices = "0urap"/' "$APP_CONFIG_FILE"
    sed -i'' -e '/\[api\]/,+3 s/enable *= .*/enable = true/' "$APP_CONFIG_FILE"
    sed -i'' -e "/\[api\]/,+9 s/address *= .*/address = \"tcp:\/\/$API_ADDRESS\"/" "$APP_CONFIG_FILE"
    sed -i'' -e "/\[grpc\]/,+6 s/address *= .*/address = \"$GRPC_LADDRESS\"/" "$APP_CONFIG_FILE"
    sed -i'' -e "/\[grpc-web\]/,+7 s/address *= .*/address = \"$GRPC_WEB_LADDRESS\"/" "$APP_CONFIG_FILE"
    sed -i'' -e "/\[rpc\]/,+3 s/laddr *= .*/laddr = \"tcp:\/\/$RPC_LADDRESS\"/" "$TENDERMINT_CONFIG_FILE"
    sed -i'' -e "/\[p2p\]/,+3 s/laddr *= .*/laddr = \"tcp:\/\/$P2P_LADDRESS\"/" "$TENDERMINT_CONFIG_FILE"

    # ------------------------------ genesis config ------------------------------ #
    sed -i'' -e 's/bond_denom": ".*"/bond_denom": "urap"/' "$GENESIS_FILE"
    sed -i'' -e 's/mint_denom": ".*"/mint_denom": "urap"/' "$GENESIS_FILE"
}

create_genesis() {
    $EXECUTABLE add-genesis-account "$KEY_NAME" "$TOKEN_AMOUNT" --keyring-backend test
    echo "Funding external keys"
    add_genesis_accounts_from_external_keys
    echo "Creating genesis transaction"
    $EXECUTABLE gentx "$KEY_NAME" "$STAKING_AMOUNT" --chain-id "$CHAIN_ID" --keyring-backend test
    $EXECUTABLE collect-gentxs
    cp ~/.rollapp/config/genesis.json /home/shared/gentx/
}

add_genesis_accounts_from_external_keys() {
    # Wait for all the addresses to be present
    while [ $(ls /home/shared/addresses-to-fund | wc -l) -ne $NUM_ADDRESSES_TO_FUND ]; do
        echo "Waiting for all addresses to be present"
        sleep 1
    done
    # Check if the directory is empty
    if [ ! "$(ls -A /home/shared/addresses-to-fund)" ]; then
        echo "No addresses to fund"
        return
    fi
    # Add genesis accounts from external keys
    for file in /home/shared/addresses-to-fund/*; do
        ACCOUNT_ADDRESS=$(cat $file)
        echo "Adding $file key with address $ACCOUNT_ADDRESS to genesis file"
        $EXECUTABLE add-genesis-account $ACCOUNT_ADDRESS $TOKEN_AMOUNT
    done
}

wait_for_genesis() { 
    while [ ! -f /home/shared/gentx/genesis.json ]; do
        echo "Waiting for genesis file"
        sleep 1
    done
    # Copy the genesis file to the config directory
    cp /home/shared/gentx/genesis.json ~/.rollapp/config/
}

create_peer_address() {
    PEER_ADDRESS=$($EXECUTABLE furyint show-node-id)@$(hostname -i):26656
    echo $PEER_ADDRESS > /home/shared/peers/$HOSTNAME
}

wait_for_all_peer_addresses() {
    while [ $(ls /home/shared/peers | wc -l) -ne $NODE_COUNT ]; do
        echo "Waiting for all peers to be present"
        sleep 1
    done
}

add_peers_to_variable() {
    # Once all peers are present, contact them and add them to the variable
    echo "All peers present. Adding them to variable"
    for file in /home/shared/peers/*; do
        echo "Adding $(cat $file) to variable"
        P2P_SEEDS="$P2P_SEEDS,$(cat $file)"
    done
    # Remove the first comma from the persistent peers
    P2P_SEEDS=${P2P_SEEDS:1}
    # Add the p2p seeds to the shared var script
    echo "P2P_SEEDS=$P2P_SEEDS" >> /app/scripts/shared.sh
}

create_key_for_hub() {
    furyd keys add $KEY_NAME_FURY --keyring-backend test --keyring-dir $KEYRING_PATH 
    # Write the key address to the shared directory
    echo $(furyd keys show $KEY_NAME_FURY -a --keyring-backend test --keyring-dir $KEYRING_PATH) > /home/hub/addresses-to-fund/$CHAIN_ID
}

wait_for_hub() {
    # get hub host and port from the rpc address
    HUB_HOST=$(echo $SETTLEMENT_RPC | cut -d':' -f1)
    HUB_PORT=$(echo $SETTLEMENT_RPC | cut -d':' -f2)
    # Wait for the hub to be up using curl on port 26657
    while ! curl -s $HUB_HOST:$HUB_PORT; do
        echo "Waiting for the hub to be up"
        sleep 1
    done
}

register_rollapp_to_hub() {
    sleep 5
    echo "Registering Rollapp to Hub"
    furyd tx rollapp create-rollapp "$ROLLAPP_ID" stamp1 "genesis-path/1" 3 100 '{"Addresses":[]}' \
    --from "$KEY_NAME_FURY" \
    --keyring-backend test \
    --keyring-dir $KEYRING_PATH \
    --node "tcp://$SETTLEMENT_RPC" \
    --chain-id "$HUB_CHAIN_ID" \
    --broadcast-mode block \
    --yes
}

register_sequencer_to_hub() {
    echo "Registering Sequencer to Hub"
    #Register Sequencer
    DESCRIPTION="{\"Moniker\":\"$MONIKER_NAME\",\"Identity\":\"\",\"Website\":\"\",\"SecurityContact\":\"\",\"Details\":\"\"}";
    SEQ_PUB_KEY="$($EXECUTABLE furyint show-sequencer)"

    furyd tx sequencer create-sequencer "$SEQ_PUB_KEY" "$ROLLAPP_ID" "$DESCRIPTION" \
    --from "$KEY_NAME_FURY" \
    --keyring-backend test \
    --keyring-dir $KEYRING_PATH \
    --node "tcp://$SETTLEMENT_RPC" \
    --chain-id "$HUB_CHAIN_ID" \
    --broadcast-mode block \
    --yes
}

main() {
    init_directories
    init_chain
    if [ "$IS_GENESIS_SEQUENCER" = "true" ]; then
        create_genesis
        create_key_for_hub
        wait_for_hub
        register_rollapp_to_hub
        register_sequencer_to_hub
    else
        wait_for_genesis
    fi
    create_peer_address
    wait_for_all_peer_addresses
    add_peers_to_variable
    # Start the sequencer a few seconds later to make sure all peers are present
    # so that that peers won't miss the first block
    if [ "$IS_GENESIS_SEQUENCER" = "true" ]; then
        echo "Waiting for 10 seconds before starting sequencer to make sure all peers are present"
        sleep 10
        sh /app/scripts/run_rollapp.sh
    else    
        echo "Starting full node"
        sh /app/scripts/run_rollapp.sh
    fi
}

main

