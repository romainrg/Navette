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
  # NAVETTE_IT_KEEP=1 keeps the temporary folder (server logs) for debugging.
  if [[ -n "${NAVETTE_IT_KEEP:-}" ]]; then echo "integration: kept $DIR" >&2; else rm -rf "$DIR"; fi
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
  ssh-keygen -q -t ed25519 -f "$dir/locked_key" -N 'integration passphrase'
  cat "$dir/client_key.pub" "$dir/locked_key.pub" > "$dir/authorized_keys"
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

start_webdav() {
  local port="${NAVETTE_IT_WEBDAV_PORT:-28080}" dir="$DIR/webdav"
  mkdir -p "$dir/root" "$dir/lock"
  /usr/sbin/htpasswd -bc "$dir/htpasswd" navette "integration password" 2>/dev/null
  cat > "$dir/httpd.conf" <<EOF
ServerRoot /usr
ServerName localhost
Listen 127.0.0.1:$port
PidFile $dir/httpd.pid
Mutex file:$dir/lock
ErrorLog $dir/error.log
LoadModule mpm_prefork_module libexec/apache2/mod_mpm_prefork.so
LoadModule unixd_module libexec/apache2/mod_unixd.so
LoadModule authz_core_module libexec/apache2/mod_authz_core.so
LoadModule authn_core_module libexec/apache2/mod_authn_core.so
LoadModule authn_file_module libexec/apache2/mod_authn_file.so
LoadModule authz_user_module libexec/apache2/mod_authz_user.so
LoadModule auth_basic_module libexec/apache2/mod_auth_basic.so
LoadModule dav_module libexec/apache2/mod_dav.so
LoadModule dav_fs_module libexec/apache2/mod_dav_fs.so
DavLockDB $dir/lock/davlock
DocumentRoot $dir/root
<Directory $dir/root>
  Dav On
  AuthType Basic
  AuthName "Navette integration"
  AuthUserFile $dir/htpasswd
  Require valid-user
</Directory>
EOF
  # Apache signals its whole process group when it stops: give it its own session so it cannot take this script down.
  perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /usr/sbin/httpd -f "$dir/httpd.conf" -DFOREGROUND > "$dir/httpd.log" 2>&1 &
  PIDS+=("$!")
  wait_for_port "$port"
  export NAVETTE_IT_WEBDAV_URL="http://127.0.0.1:$port" NAVETTE_IT_WEBDAV_USER=navette NAVETTE_IT_WEBDAV_PASSWORD="integration password"
}

# FTP needs a server macOS does not ship: vsftpd from Homebrew (plain FTP only, it is built without TLS).
# Point NAVETTE_IT_VSFTPD_TLS at a TLS-enabled vsftpd build to run the FTPS tests as well.
start_ftp() {
  local binary="$1" name="$2" port="$3" reuse="$4" tls="$5" dir="$DIR/$2"
  mkdir -p "$dir/root" "$dir/empty"
  cat > "$dir/vsftpd.conf" <<EOF
listen=YES
listen_port=$port
listen_address=127.0.0.1
background=NO
run_as_launching_user=YES
anonymous_enable=YES
anon_root=$dir/root
no_anon_password=YES
write_enable=YES
anon_upload_enable=YES
anon_mkdir_write_enable=YES
anon_other_write_enable=YES
anon_umask=022
local_enable=NO
seccomp_sandbox=NO
secure_chroot_dir=$dir/empty
pasv_min_port=$((port + 1))
pasv_max_port=$((port + 60))
xferlog_enable=YES
log_ftp_protocol=YES
vsftpd_log_file=$dir/vsftpd.log
EOF
  if [[ "$tls" == yes ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 2 -subj "/CN=localhost" 2>/dev/null
    cat >> "$dir/vsftpd.conf" <<EOF
ssl_enable=YES
allow_anon_ssl=YES
force_anon_logins_ssl=YES
force_anon_data_ssl=YES
rsa_cert_file=$dir/cert.pem
rsa_private_key_file=$dir/key.pem
require_ssl_reuse=$reuse
ssl_ciphers=HIGH
EOF
  fi
  "$binary" "$dir/vsftpd.conf" 0<>"$dir/vsftpd.err" > /dev/null 2>&1 &
  PIDS+=("$!")
  wait_for_port "$port"
}

start_sftp
start_webdav

VSFTPD="$(command -v vsftpd || true)"
[[ -z "$VSFTPD" && -x /opt/homebrew/sbin/vsftpd ]] && VSFTPD=/opt/homebrew/sbin/vsftpd
if [[ -n "$VSFTPD" ]]; then
  start_ftp "$VSFTPD" ftp 22100 NO no
  export NAVETTE_IT_FTP_PORT=22100 NAVETTE_IT_FTP_ROOT="$DIR/ftp/root"
else
  echo "integration: vsftpd not found, FTP tests are skipped (brew install vsftpd)" >&2
fi
if [[ -n "${NAVETTE_IT_VSFTPD_TLS:-}" && -x "$NAVETTE_IT_VSFTPD_TLS" ]]; then
  start_ftp "$NAVETTE_IT_VSFTPD_TLS" ftps 22200 NO yes
  start_ftp "$NAVETTE_IT_VSFTPD_TLS" ftps-reuse 22300 YES yes
  export NAVETTE_IT_FTPS_PORT=22200 NAVETTE_IT_FTPS_REUSE_PORT=22300
  export NAVETTE_IT_FTPS_CERT_SHA256="$(openssl x509 -in "$DIR/ftps/cert.pem" -outform der | shasum -a 256 | cut -d' ' -f1)"
  export NAVETTE_IT_FTPS_CERT_SHA256_REUSE="$(openssl x509 -in "$DIR/ftps-reuse/cert.pem" -outform der | shasum -a 256 | cut -d' ' -f1)"
fi

# The askpass helper is built with the app (make build). Its end-to-end test is skipped without it.
HELPER="${NAVETTE_IT_ASKPASS_HELPER:-$PWD/build/Build/Products/Debug/navette-askpass}"
if [[ -x "$HELPER" ]]; then export NAVETTE_IT_ASKPASS_HELPER="$HELPER"; fi

swift test --package-path NavetteCore --filter "${1:-IntegrationTests}"
