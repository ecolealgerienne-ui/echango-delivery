cd /home/amar/projects/echango-delivery
. scripts/lib/fleetbase.sh
U=$(fb_get '/int/v1/orders?limit=1' | jq -r '.orders[0].uuid')
echo "commande $U"
echo "-- sans with --"
fb_get "/int/v1/orders/$U" | jq -c 'if type=="object" then keys else "array" end'
echo "-- avec with --"
fb_get "/int/v1/orders/$U?with[]=payload&with[]=customFieldValues.customField" \
  | jq -c 'if type=="object" then keys else "array" end'
