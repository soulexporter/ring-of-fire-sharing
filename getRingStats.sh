#!/bin/bash

cd "$( dirname "${BASH_SOURCE[0]}" )/."

echo "{"

config_file=ringOfFireConfig.json
if [ ! -f "$config_file" ]; then
  echo "$config_file does not exists."
  return
fi

config=$(jq -c '.' "$config_file")
implementation=$(echo "$config" | jq -r '.implementation' | tr -d '"')
method=$(echo "$config" | jq -r '.method' | tr -d '"')
if [[ "$method" == 'rest' ]]
then
  macaroon=$(echo "$config" | jq -r '.macaroon' | tr -d '"')
  MACAROON_HEADER="Grpc-Metadata-macaroon: $(xxd -ps -u -c 1000 $macaroon)"
  rest_url=$(echo "$config" | jq -r '.restUrl' | tr -d '"')
  tlscert=$(echo "$config" | jq -r '.tlscert' | tr -d '"')
else
  cli=$(echo "$config" | jq -r '.cli' | tr -d '"')
fi

if [[ "$implementation" == 'c-lightning' ]]
then
  if [[ "$cli" == 'null' ]]
  then
    cli="lightning-cli"
  fi

  node_info=$(${cli} getinfo)
  my_node_id=$(echo "$node_info" | jq -r '.id')
  alias=$(echo "$node_info" | jq -r '.alias')
  color=$(echo "$node_info" | jq -r '.color')
  color="#$color"
else
  if [[ "$method" == 'rest' ]]
  then
    node_info=$(curl -s -X GET --cacert "$tlscert" --header "$MACAROON_HEADER" "$rest_url"/v1/getinfo)
  else
    if [[ "$cli" == 'null' ]]
    then
      cli="lncli"
    fi
    node_info=$(${cli} getinfo)
  fi
  my_node_id=$(echo "$node_info" | jq -r '.identity_pubkey')
  alias=$(echo "$node_info" | jq -r '.alias')
  color=$(echo "$node_info" | jq -r '.color')
  feeReport=$(${cli} feereport | jq -r '.')
fi

peers=$(echo "$config" | jq -r '.peers[]')

echo "\"nodeId\":\"${my_node_id}\","
echo "\"alias\":\"${alias}\","
echo "\"color\":\"${color}\","
if [ -n "$peerInfo" ]
then
  echo "\"feeReport\":${feeReport},"
fi

last=$(echo "$peers" | tail -1)
echo "\"peers\": ["
echo "$peers" | while read peer; do
  if [ "$last" != "$peer" ]
  then
    echo "\"$peer\","
  else
    echo "\"$peer\""
  fi
done
echo "],"

echo "\"ringPeers\": ["
echo "$peers" | while read peer; do
  peer=$(echo "$peer" | tr -d '"')
  node_id=$(echo "$peer" | cut -f1 -d@)

  if [[ "$implementation" == 'c-lightning' ]]
  then
    channels=$(${cli} listpeers "$node_id" | jq -r '.peers[]' | jq -r '.channels[0]' | jq -r --arg node_id "$node_id" '{ nodeId: $node_id, chan_id: .short_channel_id, local_balance: .spendable_msatoshi, remote_balance: .receivable_msatoshi }')
  else
    if [[ "$method" == 'rest' ]]
    then
      encoded_node_id=$(echo "$node_id" | xxd -r -p | base64)
      channels=$(curl -G -s --cacert "$tlscert" --header "$MACAROON_HEADER" --data-urlencode "peer=$encoded_node_id" "https://127.0.0.1:8080/v1/channels")
    else
      channels=$(${cli} listchannels --peer "$node_id")
    fi
    peerInfo=$(echo "$channels" | jq -r --arg node_id "$node_id" '.channels[] | select(contains({"remote_pubkey": $node_id}))' | jq -r '{ nodeId: .remote_pubkey, chan_id: .chan_id, local_balance: ((.local_balance | tonumber) * 1000), remote_balance: ((.remote_balance | tonumber) * 1000), active: .active }')
  fi

  if [ -n "$peerInfo" ]
  then
    echo "$peerInfo,"
  #else
    #TODO check whether we can ping nodes we are not having a channel with
    #peerInfo=$(lncli connect "$node_id")
    #echo "\"${node_id}\":${peerInfo},"
  fi
done

echo "{}]"
echo "}"