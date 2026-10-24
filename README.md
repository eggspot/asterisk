# Asterisk

A call center phone server: [Asterisk](https://www.asterisk.org) 22 LTS, built from the official source with only the modules a
browser-to-SIM-gateway call center needs, packaged as a small container image.

```
ghcr.io/eggspot/asterisk:<version>
```

Agents call customers from a web app. The browser's audio (WebRTC) goes to this server, which calls out through a SIM gateway (Dinstar,
Yeastar, ...) or any SIP trunk. The application's backend controls it over ARI and pushes every SIP login at run time, so the image itself
holds no accounts.

## Roles

The same image runs as two roles, chosen with `ASTERISK_ROLE`.

### `server` (default)

| Variable | Example | What |
|---|---|---|
| `SIP_TLS_PORT` | `5061` | SIP over TLS, where gateways register |
| `RTP_START`, `RTP_END` | `10000`, `10999` | UDP range for call audio, about 4 ports per call |
| `HTTP_PORT` | `8088` | ARI (`/ari`) and the browsers' SIP WebSocket (`/ws`) |
| `ARI_USERNAME`, `ARI_PASSWORD` | | The backend's ARI login |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | `/etc/asterisk-tls/tls.crt` | Certificate for SIP over TLS |
| `ROUTE_URL`, `ROUTE_TOKEN` | `http://api/CallCenterInbound/Route` | Where a call coming in from a gateway asks which agent to ring; the token is sent as `X-CallCenter-Token` |
| `CERTIFICATE_CHECK_SECONDS` | `300` | How often a renewed certificate is looked for. When the files change, `res_pjsip` is reloaded (which restarts the TLS listener with the new certificate) at the first check with no call in progress |
| `CERTIFICATE_RELOAD_DEADLINE_SECONDS` | `604800` | How long a renewed certificate may wait for a quiet moment before it is reloaded anyway (7 days; cert-manager renews 30 days before expiry) |

Expose the HTTP port only to the backend and to a proxy that routes `/ws`: it serves ARI. Run the container on the host's network (a UDP
port range can't be published one port at a time), and open the SIP port and the audio range in the firewall.

- Gateways and browsers are SIP endpoints pushed through ARI's dynamic configuration and kept in Asterisk's `astdb`
  (`/var/lib/asterisk-data`; mount a volume there so they survive a restart).
- Calls placed by the backend run the `callcenter-outbound` dialplan, which reports its steps as `UserEvent(CallCenter, ...)` on ARI.
- A customer calling a gateway's SIM back reaches `callcenter-inbound`, whatever number or name the gateway puts in the request. The
  gateway is recognised by its login (Asterisk challenges the first INVITE), and the dialplan POSTs `trunk`, `caller` and `channel` (form-encoded) to `ROUTE_URL` to ask which agent to ring. The
  answer is plain text, `ring|<call id>|<agent endpoint>|<call number for the agent>|<name shown to the agent>`, or anything else
  (`missed`, `none`). Anything but `ring`, or no answer from the backend, rings for 20 seconds and hangs up; the customer's number is
  never shown to the agent.

### `sim-gateway-simulator`

(Called `fake-gateway` before 1.2.0; that name still works in 1.2.x and prints a warning.)

A stand-in SIM gateway for development: it registers to a server over TLS like a real gateway, one SIP login per SIM port. Any number
it is asked to call answers, except a few numbers kept for the failures a real line has:

| Number | Answers |
|---|---|
| any other number | Rings 3 s, answers and echoes the caller's voice, for up to 1 hour |
| `0900000002` | Busy |
| `0900000003` | Rings without answering |
| `0900000004` | Switched off (Q.850 cause 20) |
| `0900000005` | Answers, hangs up after 10 s |
| `0900000006` | Wrong number (Q.850 cause 1) |
| `0900000007` | Line failure (Q.850 cause 34): the SIM side failed, not the customer |
| `0900000009` | Rings the developer's softphone when one is registered, otherwise answers and echoes |

| Variable | What |
|---|---|
| `TARGET_HOST`, `TARGET_PORT` | The server's SIP over TLS address |
| `GATEWAY_USERNAME`, `GATEWAY_PASSWORD` | The gateway's login (each port registers as `GATEWAY_USERNAME-<n>`) |
| `GATEWAY_PORTS` | Number of SIM ports, default 2 |
| `CALLBACK_NUMBER` | The number a simulated customer calls back from with the command below, default `0900000001` |
| `CHALLENGE_CALLS` | `yes` makes it ask for the port-1 password on every call it receives, like a gateway that authenticates incoming calls; default `no` |
| `SOFTPHONE_PASSWORD` | Turns on a softphone login: username `phone`, this password, SIP over UDP on `SOFTPHONE_PORT` (default `5060`) |
| `SOFTPHONE_ADDRESS` | The address the softphone reaches the SIM gateway simulator on, default `127.0.0.1` |

Audio uses UDP 30000–30019. The SIM gateway simulator keeps sending a small audio packet every second during a call, so a server across the
internet learns where to send audio even when the SIM gateway simulator is behind a router.

- **A customer calling back**: `asterisk -rx "channel originate PJSIP/callback@server application Echo"` inside the SIM gateway simulator calls
  the server from `CALLBACK_NUMBER` on port 1. With a softphone, dial any number on it instead: the SIM gateway simulator calls the server **from
  the number you dialled**, so you can play any customer and talk to the agent who answers.
- **A real conversation**: register a free softphone (MicroSIP, Linphone, Zoiper) as `phone` and call `0900000009` from the web app; the
  softphone rings and you talk to yourself in both directions.

## Testing on your computer

You need Docker. Everything below is in `local/`; copy `local/.env.example` to `local/.env` first.

### The SIM gateway simulator against a shared server

To test with an application that already runs against a server (for example a dev environment), run only the SIM gateway simulator:

1. In that application, create a gateway with 2 ports and note port 1's SIP username and the password. Use your own: two SIM gateway simulators
   with the same login knock each other off.
2. Put the username **without the trailing `-1`** and the password in `local/.env` as `GATEWAY_USERNAME` and `GATEWAY_PASSWORD`, plus a
   `SOFTPHONE_PASSWORD` of your choice if you want a softphone.
3. Start it, pointing at the server's SIP address:

   ```bash
   cd local
   TARGET_HOST=sip.example.com TARGET_PORT=5061 docker compose --profile gateway up -d --no-deps sim-gateway-simulator
   ```

4. The gateway's ports show as online in the application within about 30 seconds. To use the softphone, register it to
   `127.0.0.1:5060` over UDP as `phone` with your `SOFTPHONE_PASSWORD`, codec PCMA (G.711 A-law).

### Everything on your computer

`docker compose up -d` starts a server with a self-signed certificate on `127.0.0.1`: ARI and the browsers' WebSocket on `8088`
(`ws://localhost:8088/ws`), SIP over TLS on `5061`, audio on UDP 20000–20019. ICE advertises `127.0.0.1` (`ADVERTISED_ADDRESS`), so a
browser on the same computer reaches the audio ports Docker publishes. Calls coming in from the SIM gateway simulator ask
`ROUTE_URL` (default `http://host.docker.internal:5014/CallCenterInbound/Route`) which agent to ring.

1. Point your application at it: ARI `http://localhost:8088/ari` with `ARI_USERNAME` / `ARI_PASSWORD` from `.env`, SIP server
   `localhost` port `5061`, WebSocket `ws://localhost:8088/ws`, and the same `ROUTE_TOKEN`.
2. Create a gateway in the application, put its login in `.env` as above, and start the SIM gateway simulator:
   `docker compose --profile gateway up -d sim-gateway-simulator`.
3. `docker compose down` stops everything; add `-v` to forget the certificate and the pushed logins.

A browser only allows the microphone on `https` or `localhost` pages, and a page on `https` may only open `ws://` to `localhost`.

## Performance

- Only the modules listed in `config/*/modules.conf` are compiled and loaded, so the image is small and starts in about a second.
- An optimized build (no debug options) that runs on any x86-64 CPU, with stripped binaries, on `debian:trixie-slim`.
- Audio is relayed, never transcoded: every endpoint uses G.711 A-law (PCMA) with 20 ms packets, and Asterisk keeps no jitter buffer of its own.
- Timing comes from `timerfd`, and only warnings and errors are logged.
- The container runs as an unprivileged user (uid and gid 10001) and needs no extra capabilities.
- Call audio uses IPv4 only (IPv6 and private addresses are left out of ICE), so browsers don't spend time trying addresses that can't work.
- Under Kubernetes, give it a CPU limit well above its use (calls are cheap, but call set-up comes in short bursts) and stop it with
  `asterisk -rx "core stop gracefully"` in a `preStop` hook, so a planned restart waits for calls in progress to end.

## Building

```bash
docker build -t asterisk .
sh test/smoke-test.sh asterisk
```

The smoke test boots both roles, checks every module is running, pushes logins over ARI and restarts the server to see them survive, registers
the SIM gateway simulator over TLS, places calls to it (an ordinary number answers, a failure number fails), checks a call from the gateway is
recognised by its login, and checks the softphone login and the local setup's advertised address. CI runs it on every push and pull request, and publishes the image to GitHub Container Registry
for every `v*.*.*` tag (`1.0.0-rc.1`, `1.0.0` and `1.0`).

## License

Asterisk is distributed under the GNU General Public License version 2. This image is built, unmodified, from the official source release named
in the `Dockerfile` (`ASTERISK_VERSION`), downloadable from <https://downloads.asterisk.org/pub/telephony/asterisk/releases/>; the build
script is this repository.
