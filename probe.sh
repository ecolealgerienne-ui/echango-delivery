cd /home/amar/projects/echango-delivery
. scripts/lib/fleetbase.sh
U=$(fb_get '/int/v1/orders?limit=1' | jq -r '.orders[0].uuid')
fb_get "/int/v1/orders/$U?with[]=orderConfig" \
 | jq -c '.order.order_config.flow | to_entries | map({k: .key, complete: .value.complete, keys: (.value|keys)})'
