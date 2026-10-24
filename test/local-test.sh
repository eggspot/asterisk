#!/bin/sh
set -eu

export ASTERISK_IMAGE="$1"
export GATEWAY_USERNAME=gw-local
export GATEWAY_PASSWORD=local-gateway-password
export SOFTPHONE_PASSWORD=local-phone-password
compose="docker compose -f local/compose.yaml"
ari_url="http://127.0.0.1:8088/ari"

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    $compose --profile gateway logs >&2 || true
  fi
  $compose --profile gateway down -v >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

fail() {
  echo "FAILED: $1" >&2
  exit 1
}

wait_until() {
  description="$1"
  shift
  attempt=0
  until "$@" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 60 ] || fail "$description"
    sleep 1
  done
}

ari() {
  curl -fsS -u ecm:local-ari-password "$@"
}

push() {
  ari -X PUT -H 'Content-Type: application/json' -d "$2" "$ari_url/asterisk/config/dynamic/res_pjsip/$1" >/dev/null || fail "pushing $1"
}

field() {
  printf '{"attribute":"%s","value":"%s"}' "$1" "$2"
}

gateway_registered() {
  $compose exec -T server asterisk -rx "pjsip show contacts" | grep -q "$GATEWAY_USERNAME-1/"
}

$compose up -d server
wait_until "the local server's ARI doesn't answer on 127.0.0.1:8088" ari "$ari_url/asterisk/info"
$compose exec -T server grep -q "=> 127.0.0.1" /etc/asterisk/rtp.conf || fail "the local server doesn't advertise 127.0.0.1"

for port in 1 2; do
  login="$GATEWAY_USERNAME-$port"
  push "auth/$login" "{\"fields\":[$(field auth_type userpass),$(field username "$login"),$(field password "$GATEWAY_PASSWORD")]}"
  push "aor/$login" "{\"fields\":[$(field max_contacts 1),$(field remove_existing yes)]}"
  push "endpoint/$login" "{\"fields\":[$(field transport transport-tls),$(field context callcenter-from-gateway),$(field disallow all),$(field allow alaw),$(field media_encryption sdes),$(field rtp_symmetric yes),$(field force_rport yes),$(field rewrite_contact yes),$(field direct_media no),$(field identify_by "username,auth_username"),$(field auth "$login"),$(field outbound_auth "$login"),$(field aors "$login")]}"
done

$compose --profile gateway up -d fake-gateway
wait_until "the local fake gateway didn't register to the local server" gateway_registered

echo "Local setup test passed."
