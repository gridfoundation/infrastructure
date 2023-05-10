#!/bin/bash

set -e

DATA_DIRECTORY="$HOME/.gridiron"
CONFIG_DIRECTORY="$DATA_DIRECTORY/config"
GENESIS_FILE="$CONFIG_DIRECTORY/genesis.json"
TENDERMINT_CONFIG_FILE="$CONFIG_DIRECTORY/config.toml"
CLIENT_CONFIG_FILE="$CONFIG_DIRECTORY/client.toml"
APP_CONFIG_FILE="$CONFIG_DIRECTORY/app.toml"
RPC_ADDRESS=${RPC_ADDRESS:-0.0.0.0:26657}
P2P_ADDRESS=${P2P_ADDRESS:-0.0.0.0:26656}
GRPC_ADDRESS=${GRPC_ADDRESS:-0.0.0.0:9090}
GRPC_WEB_ADDRESS=${GRPC_WEB_ADDRESS:-0.0.0.0:9091}
API_ADDRESS=${API_ADDRESS:-"0.0.0.0:1317"}
KEY_NAME=${KEY_NAME:-$MONIKER_NAME-key}

init_directories() {
    mkdir -p /home/shared/gentx
    mkdir -p /home/shared/peers
    mkdir -p /home/shared/addresses-to-fund
}

init_chain() {
    # Init the chain
    furyd init "$MONIKER_NAME" --chain-id="$CHAIN_ID"
    furyd tendermint unsafe-reset-all
    furyd keys add "$KEY_NAME" --keyring-backend test
    furyd add-genesis-account "$(furyd keys show "$KEY_NAME" -a --keyring-backend test)" 100000000000ufury
    furyd gentx "$KEY_NAME" 100000000ufury --chain-id "$CHAIN_ID" --keyring-backend test
    echo "Copying gentx files to shared volume"
    cp ~/.gridiron/config/gentx/* /home/shared/gentx/
    # ---------------------------------------------------------------------------- #
    #                                 update config                                #
    # ----------------------------------------------------------------------------
    sed -i'' -e "/\[rpc\]/,+3 s/laddr *= .*/laddr = \"tcp:\/\/$RPC_ADDRESS\"/" "$TENDERMINT_CONFIG_FILE"
    sed -i'' -e "/\[p2p\]/,+3 s/laddr *= .*/laddr = \"tcp:\/\/$P2P_ADDRESS\"/" "$TENDERMINT_CONFIG_FILE"
    sed -i'' -e "/\[grpc\]/,+6 s/address *= .*/address = \"$GRPC_ADDRESS\"/" "$APP_CONFIG_FILE"
    sed -i'' -e "/\[grpc-web\]/,+7 s/address *= .*/address = \"$GRPC_WEB_ADDRESS\"/" "$APP_CONFIG_FILE"
    sed -i'' -e "s/^chain-id *= .*/chain-id = \"$CHAIN_ID\"/" "$CLIENT_CONFIG_FILE"
    sed -i'' -e "s/^node *= .*/node = \"tcp:\/\/$SETTLEMENT_RPC\"/" "$CLIENT_CONFIG_FILE"
    sed -i'' -e 's/bond_denom": ".*"/bond_denom": "ufury"/' "$GENESIS_FILE"
    sed -i'' -e 's/mint_denom": ".*"/mint_denom": "ufury"/' "$GENESIS_FILE"
    sed -i'' -e 's/^minimum-gas-prices *= .*/minimum-gas-prices = "0ufury"/' "$APP_CONFIG_FILE"
    sed -i'' -e '/\[api\]/,+3 s/enable *= .*/enable = true/' "$APP_CONFIG_FILE"
    sed -i'' -e "/\[api\]/,+9 s/address *= .*/address = \"tcp:\/\/$API_ADDRESS\"/" "$APP_CONFIG_FILE"
}

add_genesis_accounts_from_external_keys() {
    # Wait for all the addresses to be present
    while [ $(ls /home/shared/addresses-to-fund | wc -l) -ne $NUM_ADDRESSES_TO_FUND ]; do
        echo "Waiting for all addresses to be present"
        sleep 1
    done
    # Add genesis accounts from external keys
    for file in /home/shared/addresses-to-fund/*; do
        ACCOUNT_ADDRESS=$(cat $file)
        echo "Adding $file key with address $ACCOUNT_ADDRESS to genesis file"
        furyd add-genesis-account $ACCOUNT_ADDRESS 100000000000ufury
    done
}

create_genesis() {
    echo "Copying gentx files to shared volume"
    cp ~/.gridiron/config/gentx/* /home/shared/gentx/
    # Check if the number of gentx files is equal to the number of validators. If it's not, sleep, else create the genesis file
    while [ $(ls /home/shared/gentx | wc -l) -ne $VALIDATOR_COUNT ]; do
        echo "Waiting for all gentx files to be present"
        sleep 1
    done

    echo "Adding genesis accounts from external addresses"
    add_genesis_accounts_from_external_keys

    echo "All accounts added. Creating genesis file and copying to shared volume"
    furyd collect-gentxs --gentx-dir /home/shared/gentx
    cp ~/.gridiron/config/genesis.json /home/shared/gentx/
}

wait_for_genesis() { 
    echo "Copy address to fund to shared volume"
    echo $(furyd keys show $KEY_NAME -a --keyring-backend test) > /home/shared/addresses-to-fund/$MONIKER_NAME
    # If you're not, wait until the genesis file is present
    while [ ! -f /home/shared/gentx/genesis.json ]; do
        echo "Waiting for genesis file"
        sleep 1
    done
    # Copy the genesis file to the config directory
    cp /home/shared/gentx/genesis.json ~/.gridiron/config/
}

create_peer_address() {
    PEER_ADDRESS=$(furyd tendermint show-node-id)@$HOSTNAME:26656
    echo $PEER_ADDRESS > /home/shared/peers/$HOSTNAME
}

wait_for_all_peer_addresses() {
    while [ $(ls /home/shared/peers | wc -l) -ne $VALIDATOR_COUNT ]; do
        echo "Waiting for all peers to be present"
        sleep 1
    done
}

add_peers_to_config() {
    # Once all peers are present, add them to the config.toml file
    echo "All peers present. Adding them to config.toml"
    for file in /home/shared/peers/*; do
        echo "Adding $(cat $file) to config.toml"
        sed -i "s/persistent_peers = \"\"/persistent_peers = \"$(cat $file),\"/g" ~/.gridiron/config/config.toml
    done

    # Remove the last comma from the persistent peers
    sed -i "s/,\"/\"/g" ~/.gridiron/config/config.toml
}

main() {
    init_directories
    init_chain
    if [ "$IS_GENESIS_VALIDATOR" = "true" ]; then
        create_genesis
    else
        wait_for_genesis
    fi
    create_peer_address
    wait_for_all_peer_addresses
    add_peers_to_config
    furyd start
}

main

