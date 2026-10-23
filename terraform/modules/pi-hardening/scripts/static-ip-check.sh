#!/bin/bash

set -e

export PATH="/c/Program Files/Git/usr/bin:$PATH"

QUERY=$(cat)

get_field() {
    echo "$QUERY" | grep -oP "\"$1\"\s*:\s*\"\K[^\"]*"
}

HOST=$(get_field host)
SSH_USER=$(get_field user)
KEY_PATH=$(get_field key_path)
INTERFACE=$(get_field interface)
EXPECTED_IP=$(get_field expected_ip)
EXPECTED_GATEWAY=$(get_field expected_gateway)
EXPECTED_DNS=$(get_field expected_dns)
EXPECTED_IPV6_TOKEN=$(get_field expected_ipv6_token || true)

if [ -z "$HOST" ] || [ -z "$SSH_USER" ] || [ -z "$KEY_PATH" ] || [ -z "$INTERFACE" ]; then
    echo "static-ip-check.sh: missing host, user, key_path, or interface in query input" >&2
    exit 1
fi

RESULT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    -i "$KEY_PATH" "$SSH_USER@$HOST" bash -s <<REMOTE_SCRIPT
CON=\$(nmcli -t -f NAME,DEVICE con show | grep '$INTERFACE' | cut -d: -f1)
echo "ADDR=\$(nmcli -g ipv4.addresses con show "\$CON")"
echo "GATEWAY=\$(nmcli -g ipv4.gateway con show "\$CON")"
echo "DNS=\$(nmcli -g ipv4.dns con show "\$CON")"
echo "METHOD=\$(nmcli -g ipv4.method con show "\$CON")"
echo "IPV6_METHOD=\$(nmcli -g ipv6.method con show "\$CON")"
echo "IPV6_TOKEN=\$(nmcli -g ipv6.token con show "\$CON")"
REMOTE_SCRIPT
)

ADDR=$(echo "$RESULT" | grep '^ADDR=' | cut -d= -f2-)
GATEWAY=$(echo "$RESULT" | grep '^GATEWAY=' | cut -d= -f2-)
DNS=$(echo "$RESULT" | grep '^DNS=' | cut -d= -f2-)
METHOD=$(echo "$RESULT" | grep '^METHOD=' | cut -d= -f2-)

address_ok="false"
[ "$ADDR" = "$EXPECTED_IP" ] && address_ok="true"

gateway_ok="false"
[ "$GATEWAY" = "$EXPECTED_GATEWAY" ] && gateway_ok="true"

dns_ok="false"
[ "$DNS" = "$EXPECTED_DNS" ] && dns_ok="true"

method_ok="false"
[ "$METHOD" = "manual" ] && method_ok="true"

IPV6_METHOD=$(echo "$RESULT" | grep '^IPV6_METHOD=' | cut -d= -f2-)
IPV6_TOKEN=$(echo "$RESULT" | grep '^IPV6_TOKEN=' | cut -d= -f2-)

# No expected token means IPv6 isn't managed for this host - nothing to drift
ipv6_ok="true"
if [ -n "$EXPECTED_IPV6_TOKEN" ]; then
    ipv6_ok="false"
    [ "$IPV6_METHOD" = "auto" ] && [ "$IPV6_TOKEN" = "$EXPECTED_IPV6_TOKEN" ] && ipv6_ok="true"
fi

printf '{"address_ok": "%s", "gateway_ok": "%s", "dns_ok": "%s", "method_ok": "%s", "ipv6_ok": "%s"}\n' \
    "$address_ok" "$gateway_ok" "$dns_ok" "$method_ok" "$ipv6_ok"
