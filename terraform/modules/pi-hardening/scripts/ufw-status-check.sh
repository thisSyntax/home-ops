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
APP_NAME=$(get_field app_name)

if [ -z "$HOST" ] || [ -z "$SSH_USER" ] || [ -z "$KEY_PATH" ]; then
    echo "ufw-status-check.sh: missing host, user, or key_path in query input" >&2
    exit 1
fi

STATUS=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    -i "$KEY_PATH" "$SSH_USER@$HOST" \
    "sudo ufw status verbose")

active="false"
echo "$STATUS" | grep -q "^Status: active" && active="true"

default_policy_ok="false"
echo "$STATUS" | grep -q "^Default: deny (incoming), allow (outgoing)" && default_policy_ok="true"

openssh_allowed="false"
echo "$STATUS" | grep -qE "^22/tcp \(OpenSSH\)\s+ALLOW IN\s+Anywhere" && openssh_allowed="true"

app_allowed="false"
if [ -n "$APP_NAME" ]; then
    echo "$STATUS" | grep -qE "\($APP_NAME\)\s+ALLOW IN\s+Anywhere" && app_allowed="true"
fi

printf '{"active": "%s", "default_policy_ok": "%s", "openssh_allowed": "%s", "app_allowed": "%s"}\n' \
    "$active" "$default_policy_ok" "$openssh_allowed" "$app_allowed"
