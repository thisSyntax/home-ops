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
REMOTE_PATH=$(get_field remote_path)

if [ -z "$HOST" ] || [ -z "$SSH_USER" ] || [ -z "$KEY_PATH" ] || [ -z "$REMOTE_PATH" ]; then
    echo "remote-file-hash.sh: missing host, user, key_path, or remote_path in query input" >&2
    exit 1
fi

HASH=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    -i "$KEY_PATH" "$SSH_USER@$HOST" \
    "md5sum '$REMOTE_PATH' 2>/dev/null | awk '{print \$1}'")

if [ -z "$HASH" ]; then
    HASH="missing"
fi

printf '{"hash": "%s"}\n' "$HASH"
