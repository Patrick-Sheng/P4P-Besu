# Live QR-code demo

Runs the 4-validator Besu network, a fresh `VotingSystem` election and the
website on this VM. The audience scans a QR code, their phone is registered
automatically, and they vote from the phone.

```bash
demo/start-demo.sh --new-election   # fresh election (new contract, new join code)
demo/start-demo.sh                  # restart, keeping the current election and votes
demo/stop-demo.sh                   # stop website + tunnel
demo/stop-demo.sh --all             # ...and the validators
```

The script prints two links:

- **Presenter screen**: `http://localhost:3000/demo?admin=<token>`. Open it
  on the VM and put it on the projector. It shows the QR code, registered/voted
  counts, a live tally and **Open voting / Close voting** buttons.
- **Join link**: `https://<random>.trycloudflare.com/vote?code=<code>`. This
  is what the QR code encodes.

Candidate names: `DEMO_CANDIDATES="Labour,National,Green" demo/start-demo.sh --new-election`.

## Flow

1. Audience scans the QR. `/vote` generates a keypair **in the phone's
   browser** and keeps it in localStorage, so the same phone always comes back
   as the same voter.
2. The phone sends only its address and the join code to `/api/register`. The
   server holds the contract admin key and calls `registerVoter()`, which
   takes one block (~2 s).
3. Presenter clicks **Open voting**.
4. The phone signs `castVote()` with its own key and relays it through
   `/api/rpc` to the validators. The receipt shows the block and tx hash.
5. The tally on the projector and the phones updates every block.

## How it is wired

```
phone ──HTTPS──▶ Cloudflare quick tunnel ──▶ Next.js :3000 (127.0.0.1)
                                              ├─ /vote, /demo        pages
                                              ├─ /api/register       admin-signed registerVoter
                                              ├─ /api/admin          open/close (token required)
                                              ├─ /api/status         tally + voter state
                                              └─ /api/rpc            whitelisted JSON-RPC relay
                                                     │ round-robin + failover
                                                     ▼
                                   besu validators :8545-8548 (localhost only)
```

- The VM is behind VirtualBox NAT, so phones can't reach it directly. The
  quick tunnel (`demo/bin/cloudflared`, downloaded on first run) gives a
  public HTTPS URL with no account or router setup, and works on mobile data.
  The URL changes every time the tunnel restarts. The QR code always shows
  the current one.
- Besu RPC listens on localhost only. `/api/rpc` forwards only read methods,
  plus `eth_sendRawTransaction` for a `castVote()` transaction to the election
  contract.
- Registration needs the join code from the QR, and is capped at
  `DEMO_MAX_VOTERS` (default 500).
- Every process is a memory-capped `systemd --user` unit in `p4p-demo.slice`
  (`p4p-demo-besu1..4`, `p4p-demo-web`, `p4p-demo-tunnel`), so an OOM can't
  take down VS Code. Logs: `journalctl --user -u p4p-demo-web -f`.
- Secrets (join code, admin token, admin key) are in `demo/.state/`, which is
  gitignored and `chmod 600`.

## Without the tunnel (`--lan`)

`demo/start-demo.sh --lan` serves on `0.0.0.0:3000` and puts
`http://<VM IP>:3000` in the QR. Phones then need to reach the VM directly:
switch the VirtualBox adapter to *Bridged* and put the phones on the same
Wi-Fi, or add a NAT port-forward (host 3000 → guest 3000) and set
`DEMO_PUBLIC_URL=http://<host LAN IP>:3000`. Venue Wi-Fi often isolates
clients, so test this beforehand. The tunnel avoids the problem.

## Demo-grade caveats

- A voter's key lives in the phone's browser storage. Clearing site data or
  using a private tab makes a new voter, and anyone holding the join code can
  register. This is fine for a demo, not for an election.
- The quick tunnel is a free Cloudflare service with no uptime guarantee. If
  it drops, re-run `demo/start-demo.sh`. Votes are kept, but the URL and QR
  change.
