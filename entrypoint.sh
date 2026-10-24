#!/bin/sh
set -eu

role="${ASTERISK_ROLE:-server}"
export CALLBACK_NUMBER="${CALLBACK_NUMBER:-0900000001}"
templates="/etc/asterisk-templates/$role"

case "$role" in
  server)
    variables='$SIP_TLS_PORT $RTP_START $RTP_END $HTTP_PORT $ARI_USERNAME $ARI_PASSWORD $TLS_CERT_FILE $TLS_KEY_FILE $ROUTE_URL $ROUTE_TOKEN'
    ;;
  fake-gateway)
    variables='$TARGET_HOST $TARGET_PORT $CALLBACK_NUMBER'
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
fi

certificate_fingerprint() {
  cat "$TLS_CERT_FILE" "$TLS_KEY_FILE" 2>/dev/null | sha256sum
}

reload_renewed_certificate() {
  loaded="$(certificate_fingerprint)"
  while sleep "${CERTIFICATE_CHECK_SECONDS:-300}"; do
    current="$(certificate_fingerprint)"
    if [ "$current" != "$loaded" ] && asterisk -rx "module reload res_pjsip.so" >/dev/null; then
      echo "Reloaded the renewed TLS certificate."
      loaded="$current"
    fi
  done
}

if [ "$role" = "server" ]; then
  reload_renewed_certificate &
fi

exec asterisk -f -n
