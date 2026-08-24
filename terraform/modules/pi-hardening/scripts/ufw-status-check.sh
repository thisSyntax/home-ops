#!/bin/bash

# Exit if any of the intermediate steps fail
set -e

# Terraform invokes bash.exe directly (non-interactive, no profile sourcing),
# so Git for Windows' usual PATH setup never runs - add it explicitly here.
export PATH="/c/Program Files/Git/usr/bin:$PATH"

QUERY=$(cat)

get_field() {
    echo "$QUERY" | grep -oP "\"$1\"\s*:\s*\"\K[^\"]*"
}

HOST=$(get_field host)
SSH_USER=$(get_field user)
KEY_PATH=$(get_field key_path)
APP_NAME=$(get_field app_name)

if [ -z "$HOST" ] || [ -z "$SSH_USER" ] || [ -z "$KEY_PATH" ] || [ -z "$APP_NAME" ]; then
    echo "ufw-status-check.sh: missing host, user, key_path, or app_name in query input" >&2
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
echo "$STATUS" | grep -qE "\($APP_NAME\)\s+ALLOW IN\s+Anywhere" && app_allowed="true"

printf '{"active": "%s", "default_policy_ok": "%s", "openssh_allowed": "%s", "app_allowed": "%s"}\n' \
    "$active" "$default_policy_ok" "$openssh_allowed" "$app_allowed"
