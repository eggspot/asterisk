#!/bin/sh
set -eu

image="$1"
work="$(mktemp -d)"
network="asterisk-smoke"
server="asterisk-smoke-server"
gateway="asterisk-smoke-gateway"
ari_url="http://localhost:8098/ari"
gateway_password="smoke-gateway-password"

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    for container in "$server" "$gateway"; do
      echo "--- $container ---" >&2
      docker logs "$container" >&2 2>&1 || true
      echo "--- $container SIP messages ---" >&2
      sip_history "$container" >&2 || true
    done
  fi
  docker rm -f "$server" "$gateway" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

sip_history() {
  for entry in $(docker exec "$1" asterisk -rx "pjsip show history" | awk '$1 ~ /^[0-9]+$/ { print $1 }'); do
    docker exec "$1" asterisk -rx "pjsip show history entry $entry"
  done
}

record_sip() {
  docker exec "$1" asterisk -rx "pjsip set history on" >/dev/null
}

originate() {
  output="$(docker exec "$1" asterisk -rx "channel originate $2")"
  case "$output" in
    *"No such command"*|*"Unable to"*|*"not found"*) echo "$output" >&2; return 1 ;;
  esac
}

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

booted() {
  docker exec "$1" asterisk -rx "core waitfullybooted"
}

check_modules() {
  loaded="$(docker exec "$1" asterisk -rx "module show")"
  for module in $(grep '^load' "config/$2/modules.conf" | sed 's/^load *= *//'); do
    echo "$loaded" | grep -q "^$module .*Running" || fail "$module isn't running in the $2 role"
  done
}

ari() {
  curl -fsS -u smoke:smoke-password "$@"
}

push() {
  ari -X PUT -H 'Content-Type: application/json' -d "$2" "$ari_url/asterisk/config/dynamic/res_pjsip/$1" >/dev/null || fail "pushing $1"
}

field() {
  printf '{"attribute":"%s","value":"%s"}' "$1" "$2"
}

gateway_registered() {
  docker exec "$server" asterisk -rx "pjsip show contacts" | grep -q "gw-smoke-1/"
}

inbound_call_identified() {
  docker exec "$server" asterisk -rx "core show channels concise" | grep -q "^PJSIP/gw-smoke-1-"
}

gateway_received_call() {
  docker exec "$gateway" asterisk -rx "core show channels count" | grep -Eq "^[1-9][0-9]* calls? processed"
}

server_has_channel() {
  docker exec "$server" asterisk -rx "core show channels count" | grep -Eq "^[1-9][0-9]* active channels?"
}

server_is_quiet() {
  docker exec "$server" asterisk -rx "core show channels count" | grep -q "^0 active channels"
}

hang_up_everything() {
  docker exec "$server" asterisk -rx "channel request hangup all" >/dev/null
  docker exec "$gateway" asterisk -rx "channel request hangup all" >/dev/null
  wait_until "calls didn't end after hanging up" server_is_quiet
}

certificate_reloaded() {
  docker logs "$server" 2>&1 | grep -q "Reloaded the renewed TLS certificate"
}

new_certificate() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$server" -keyout "$work/tls.key" -out "$work/tls.crt" 2>/dev/null
  chmod 755 "$work"
  chmod 644 "$work/tls.key" "$work/tls.crt"
}

new_certificate
docker network create "$network" >/dev/null

docker run -d --name "$server" --network "$network" -p 8098:8098 \
  -e SIP_TLS_PORT=5071 -e RTP_START=20000 -e RTP_END=20099 -e HTTP_PORT=8098 \
  -e ARI_USERNAME=smoke -e ARI_PASSWORD=smoke-password -e ROUTE_URL=http://127.0.0.1:9/route -e ROUTE_TOKEN=smoke-token \
  -e TLS_CERT_FILE=/tls/tls.crt -e TLS_KEY_FILE=/tls/tls.key -e CERTIFICATE_CHECK_SECONDS=1 \
  -v "$work:/tls:ro" "$image" >/dev/null

wait_until "the server didn't start" booted "$server"
check_modules "$server" server
docker exec "$server" asterisk -rx "pjsip show transports" | grep -q "transport-tls" || fail "the TLS transport isn't up"
docker exec "$server" asterisk -rx "pjsip show transports" | grep -q "transport-ws" || fail "the WebSocket transport isn't up"
docker exec "$server" asterisk -rx "dialplan show s@callcenter-outbound" | grep -q "PJSIP_DIAL_CONTACTS" || fail "the call center dialplan isn't loaded"
docker exec "$server" asterisk -rx "core show function PJSIP_DIAL_CONTACTS" | grep -qi "PJSIP_DIAL_CONTACTS" || fail "PJSIP_DIAL_CONTACTS isn't available"
wait_until "ARI doesn't answer" ari "$ari_url/asterisk/info"

push auth/gw-smoke-1 "{\"fields\":[$(field auth_type userpass),$(field username gw-smoke-1),$(field password "$gateway_password")]}"
push aor/gw-smoke-1 "{\"fields\":[$(field max_contacts 1),$(field remove_existing yes),$(field qualify_frequency 60)]}"
push endpoint/gw-smoke-1 "{\"fields\":[$(field transport transport-tls),$(field context callcenter-from-gateway),$(field disallow all),$(field allow alaw),$(field media_encryption sdes),$(field rtp_symmetric yes),$(field force_rport yes),$(field rewrite_contact yes),$(field direct_media no),$(field identify_by "username,auth_username"),$(field auth gw-smoke-1),$(field outbound_auth gw-smoke-1),$(field aors gw-smoke-1)]}"

agent_md5="$(printf 'agent-smoke:test-realm:agent-password' | md5sum | cut -d' ' -f1)"
push auth/agent-smoke "{\"fields\":[$(field auth_type md5),$(field username agent-smoke),$(field realm test-realm),$(field md5_cred "$agent_md5")]}"
push aor/agent-smoke "{\"fields\":[$(field max_contacts 1),$(field remove_existing yes)]}"
push endpoint/agent-smoke "{\"fields\":[$(field webrtc yes),$(field dtls_auto_generate_cert yes),$(field context callcenter-agents),$(field disallow all),$(field allow alaw),$(field auth agent-smoke),$(field aors agent-smoke)]}"

docker restart "$server" >/dev/null
wait_until "the server didn't come back after a restart" booted "$server"
wait_until "ARI doesn't answer after a restart" ari "$ari_url/asterisk/info"
record_sip "$server"
ari "$ari_url/endpoints/PJSIP/gw-smoke-1" >/dev/null || fail "the pushed gateway login didn't survive a restart"
ari "$ari_url/endpoints/PJSIP/agent-smoke" >/dev/null || fail "the pushed agent login didn't survive a restart"

docker run -d --name "$gateway" --network "$network" \
  -e ASTERISK_ROLE=fake-gateway -e TARGET_HOST="$server" -e TARGET_PORT=5071 \
  -e GATEWAY_USERNAME=gw-smoke -e GATEWAY_PASSWORD="$gateway_password" -e GATEWAY_PORTS=1 -e CHALLENGE_CALLS=yes \
  "$image" >/dev/null

wait_until "the fake gateway didn't start" booted "$gateway"
check_modules "$gateway" fake-gateway
record_sip "$gateway"
wait_until "the fake gateway didn't register over TLS" gateway_registered

ari -X POST "$ari_url/channels?endpoint=PJSIP/0900000001@gw-smoke-1&context=callcenter-agents&extension=s&priority=1&timeout=20" >/dev/null || fail "couldn't originate a test call"
wait_until "the test call didn't reach the fake gateway" gateway_received_call

hang_up_everything

originate "$gateway" "PJSIP/1000@server application Wait 10" || fail "the fake gateway couldn't call the server"
wait_until "a call from the gateway wasn't recognised as the gateway" inbound_call_identified
hang_up_everything

originate "$gateway" "PJSIP/gw-smoke-1@server application Wait 10" || fail "the fake gateway couldn't call the server by name"
wait_until "a call from the gateway to a name instead of a number wasn't accepted" inbound_call_identified
hang_up_everything

originate "$server" "PJSIP/0900000009@gw-smoke-1 application Wait 60" || fail "couldn't start a long test call"
wait_until "the long test call didn't start" server_has_channel
new_certificate
sleep 5
certificate_reloaded && fail "the certificate was reloaded during a call"
hang_up_everything
wait_until "the renewed certificate wasn't reloaded once the server was quiet" certificate_reloaded
docker exec "$server" asterisk -rx "pjsip show transports" | grep -q "transport-tls" || fail "the TLS transport is gone after a reload"
wait_until "the fake gateway didn't register again after the reload" gateway_registered

echo "Smoke test passed."
