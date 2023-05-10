#!/bin/sh

set -e

KEY_NAME=${KEY_NAME:-local-user}
CELESTIA_NETWORK=${CELESTIA_NETWORK:-mocha}
CELESTIA_BRIDGE_NODE_ENDPOINT=${CELESTIA_BRIDGE_NODE_ENDPOINT:-https://rpc-mocha.pops.one}
CELESTIA_BRIDGE_NODE_PORT=${CELESTIA_BRIDGE_NODE_PORT:-9090}

init_light_client() {
    echo "Initializing celestia light client"
    celestia light init --p2p.network $CELESTIA_NETWORK
}

add_key_to_keyring() {
    echo "Adding celestia light node to keyring"
    echo '12345678' | cel-key import $KEY_NAME /celestia-light-client.pk --keyring-backend test --node.type light --p2p.network $CELESTIA_NETWORK
}

start_light_client() {
    celestia light start --core.ip $CELESTIA_BRIDGE_NODE_ENDPOINT --core.grpc.port $CELESTIA_BRIDGE_NODE_PORT --gateway --gateway.addr 127.0.0.1 --gateway.port 26659 --keyring.accname $KEY_NAME --p2p.network $CELESTIA_NETWORK
}

main() {
    init_light_client
    add_key_to_keyring
    start_light_client
}

main 