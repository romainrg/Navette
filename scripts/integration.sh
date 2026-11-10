#!/usr/bin/env bash
# Starts local development servers as the current user, on high ports and in a temporary folder,
# runs the integration tests against them, then stops them. No system setting is changed.
# Usage: scripts/integration.sh [test-name-filter]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then
  export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort | tail -1)/Contents/Developer"
fi

DIR="$(mktemp -d /tmp/navette-it.XXXXXX)"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done
  rm -rf "$DIR"
}
trap cleanup EXIT

wait_for_port() {
  for _ in $(seq 1 50); do
    if nc -z 127.0.0.1 "$1" 2>/dev/null; then return 0; fi
    perl -e 'select(undef, undef, undef, 0.1)'
  done
  echo "integration: nothing is listening on port $1" >&2
  return 1
}

start_sftp() {
  local port="${NAVETTE_IT_SFTP_PORT:-22222}" dir="$DIR/sftp"
  mkdir -p "$dir/root"
  ssh-keygen -q -t ed25519 -f "$dir/host_key" -N ''
  ssh-keygen -q -t ed25519 -f "$dir/client_key" -N ''
  cp "$dir/client_key.pub" "$dir/authorized_keys"
  chmod 600 "$dir/authorized_keys"
  cat > "$dir/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_key
AuthorizedKeysFile $dir/authorized_keys
PidFile $dir/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
StrictModes no
PerSourcePenalties no
Subsystem sftp /usr/libexec/sftp-server
EOF
  /usr/sbin/sshd -D -e -f "$dir/sshd_config" > "$dir/sshd.log" 2>&1 &
  PIDS+=("$!")
  wait_for_port "$port"
  echo "[127.0.0.1]:$port $(cut -d' ' -f1,2 "$dir/host_key.pub")" > "$dir/known_hosts"
  export NAVETTE_IT_SFTP_PORT="$port" NAVETTE_IT_SFTP_DIR="$dir"
}

start_sftp

swift test --package-path NavetteCore --filter "${1:-IntegrationTests}"
