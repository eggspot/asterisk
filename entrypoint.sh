#!/bin/sh
set -eu

role="${ASTERISK_ROLE:-server}"
export CALLBACK_NUMBER="${CALLBACK_NUMBER:-0900000001}"
if [ "${CHALLENGE_CALLS:-no}" = "yes" ]; then
  export INBOUND_AUTH="auth = port-1"
else
  export INBOUND_AUTH=""
fi
templates="/etc/asterisk-templates/$role"

case "$role" in
  server)
    variables='$SIP_TLS_PORT $RTP_START $RTP_END $HTTP_PORT $ARI_USERNAME $ARI_PASSWORD $TLS_CERT_FILE $TLS_KEY_FILE $ROUTE_URL $ROUTE_TOKEN'
    ;;
  fake-gateway)
    variables='$TARGET_HOST $TARGET_PORT $CALLBACK_NUMBER $INBOUND_AUTH'
    ;;
  *)
    echo "Unknown ASTERISK_ROLE: $role" >&2
    exit 1
    ;;
esac

rm -f /etc/asterisk/*.conf
for template in "$templates"/*.conf; do
  envsubst "$variables" < "$template" > "/etc/asterisk/$(basename "$template")"
done

if [ "$role" = "fake-gateway" ]; then
  port=1
  while [ "$port" -le "${GATEWAY_PORTS:-2}" ]; do
    cat >> /etc/asterisk/pjsip.conf <<EOF

[port-$port]
type=registration
transport=transport-tls
outbound_auth=port-$port
server_uri=sip:$TARGET_HOST:$TARGET_PORT;transport=tls
client_uri=sip:$GATEWAY_USERNAME-$port@$TARGET_HOST:$TARGET_PORT;transport=tls
contact_user=$GATEWAY_USERNAME-$port
retry_interval=30
forbidden_retry_interval=60
expiration=300

[port-$port]
type=auth
auth_type=userpass
username=$GATEWAY_USERNAME-$port
password=$GATEWAY_PASSWORD
EOF
    port=$((port + 1))
  done

  if [ -n "${SOFTPHONE_PASSWORD:-}" ]; then
    cat >> /etc/asterisk/pjsip.conf <<EOF

[transport-phone]
type=transport
protocol=udp
bind=0.0.0.0:${SOFTPHONE_PORT:-5060}
external_media_address=${SOFTPHONE_ADDRESS:-127.0.0.1}
external_signaling_address=${SOFTPHONE_ADDRESS:-127.0.0.1}

[phone]
type=endpoint
transport=transport-phone
context=from-phone
disallow=all
allow=alaw
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
direct_media=no
identify_by=username
auth=phone
aors=phone

[phone]
type=auth
auth_type=userpass
username=phone
password=$SOFTPHONE_PASSWORD

[phone]
type=aor
max_contacts=1
remove_existing=yes
EOF
  fi
fi

if [ "$role" = "server" ] && [ -n "${ADVERTISED_ADDRESS:-}" ]; then
  container_address="$(getent hosts "$(cat /etc/hostname)" | awk '{ print $1; exit }')"
  printf '\n[ice_host_candidates]\n%s => %s\n' "$container_address" "$ADVERTISED_ADDRESS" >> /etc/asterisk/rtp.conf
fi

certificate_fingerprint() {
  cat "$TLS_CERT_FILE" "$TLS_KEY_FILE" 2>/dev/null | sha256sum
}

active_channels() {
  asterisk -rx "core show channels count" 2>/dev/null | awk '/active channel/ { print $1 }'
}

reload_renewed_certificate() {
  loaded="$(certificate_fingerprint)"
  renewed_at=""
  while sleep "${CERTIFICATE_CHECK_SECONDS:-300}"; do
    current="$(certificate_fingerprint)"
    if [ "$current" = "$loaded" ]; then
      renewed_at=""
      continue
    fi

    now="$(date +%s)"
    renewed_at="${renewed_at:-$now}"
    channels="$(active_channels)"
    if [ "${channels:-1}" -gt 0 ] && [ $((now - renewed_at)) -lt "${CERTIFICATE_RELOAD_DEADLINE_SECONDS:-604800}" ]; then
      continue
    fi

    if asterisk -rx "module reload res_pjsip.so" >/dev/null; then
      echo "Reloaded the renewed TLS certificate (${channels:-unknown} channels in progress)."
      loaded="$current"
      renewed_at=""
    fi
  done
}

if [ "$role" = "server" ]; then
  reload_renewed_certificate &
fi

exec asterisk -f -n
