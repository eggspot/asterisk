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

### `fake-gateway`

A stand-in SIM gateway for development: it registers to a server like a real gateway and answers by the number's last two digits.

| Ends in | Answers |
|---|---|
| `01` | Rings 3 s, answers and echoes the caller's voice |
| `02` | Busy |
| `03` | Rings without answering |
| `04` | Switched off (Q.850 cause 20) |
| `05` | Answers, hangs up after 10 s |
| `09` | Rings 5 s, answers and echoes |

| Variable | What |
|---|---|
| `TARGET_HOST`, `TARGET_PORT` | The server's SIP over TLS address |
| `GATEWAY_USERNAME`, `GATEWAY_PASSWORD` | The gateway's login (each port registers as `GATEWAY_USERNAME-<n>`) |
| `GATEWAY_PORTS` | Number of SIM ports, default 2 |
| `CALLBACK_NUMBER` | The number a simulated customer calls back from, default `0900000001` |
| `CHALLENGE_CALLS` | `yes` makes it ask for the port-1 password on every call it receives, like a gateway that authenticates incoming calls; default `no` |

Simulate a customer calling back: `asterisk -rx "channel originate PJSIP/1000@server application Echo"` inside the fake gateway.

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
the fake gateway over TLS, places a call to it, and checks a call from the gateway is recognised by its login. CI runs it on every push and pull request, and publishes the image to GitHub Container Registry
for every `v*.*.*` tag (`1.0.0-rc.1`, `1.0.0` and `1.0`).

## License

Asterisk is distributed under the GNU General Public License version 2. This image is built, unmodified, from the official source release named
in the `Dockerfile` (`ASTERISK_VERSION`), downloadable from <https://downloads.asterisk.org/pub/telephony/asterisk/releases/>; the build
script is this repository.
