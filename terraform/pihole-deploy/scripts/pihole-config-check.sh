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
DNS=$(get_field dns)
INTERFACE=$(get_field interface)
HOSTS=$(get_field hosts)

if [ -z "$HOST" ] || [ -z "$SSH_USER" ] || [ -z "$KEY_PATH" ] || [ -z "$HOSTS" ]; then
    echo "pihole-config-check.sh: missing host, user, key_path, or hosts in query input" >&2
    exit 1
fi

STATUS=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    -i "$KEY_PATH" "$SSH_USER@$HOST" \
    "sudo pihole-FTL --config")

dns="false"
echo "$STATUS" | grep -q "^dns.upstreams = \[ $DNS \]" && dns="true"

interface="false"
echo "$STATUS" | grep -q "^dns.interface = $INTERFACE" && interface="true"

hosts="false"
echo "$STATUS" | grep -q "^dns.hosts = \[ $HOSTS \]" && hosts="true"

printf '{"dns": "%s", "interface": "%s", "hosts": "%s"}\n' \
    "$dns" "$interface" "$hosts"
