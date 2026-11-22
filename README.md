# macOS SSH WireGuard Bypass

This utility adds per-host routes on macOS so selected servers use your direct network gateway instead of a full-tunnel VPN. It started as a WireGuard tool and keeps that name, but the mechanism is VPN-agnostic: it works the same with OpenVPN (with or without `redirect-gateway def1`), IKEv2, and L2TP, for a list of targets that should bypass the VPN.

For the full design, state flow, command semantics, troubleshooting reference, and all common ways to run the script, read [HOW-IT-WORKS.md](./HOW-IT-WORKS.md).

## Files

- `manage-ssh-bypass-routes.sh`
  - Adds, removes, tests, imports, installs launchd, and manages host routes for the server list.
- `servers.txt`
  - Source of truth for bypassed SSH destinations. It stores one hostname or IPv4 address per line.
- `resolved-history.txt`
  - Hostname-to-IPv4 memory with a last-seen time per mapping. It keeps a hostname bypassed while DNS is unavailable and lets `apply` clean up addresses a hostname has left.
- `last-applied.txt`
  - Auto-saved snapshot of the exact IPv4 targets from the last successful `apply`, plus the local source address they were bound to.
- `com.nextcloud.ssh-wireguard-bypass.plist.example`
  - `launchd` example for automatic re-apply as a root daemon.
- `data-dir` (optional, beside the script)
  - One line naming the directory that holds `servers.txt` and the two generated files. Used when the script is installed somewhere root-owned, such as `/usr/local/libexec`, so the interactive menu and the daemon work on the same writable state. `BYPASS_DATA_DIR` overrides it; explicit `--config`/`--history`/`--snapshot` override both.

## Prerequisites

- macOS with a full-tunnel VPN client (WireGuard, OpenVPN, IKEv2, or L2TP)
- Public IPv4 addresses, hostnames, or both for the servers you want to bypass
- `sudo` access on the Mac

## 1. Use the menu or edit the server list directly

Run the script with no action to open the interactive menu:

```bash
./manage-ssh-bypass-routes.sh
```

Menu actions:

- `View servers`
- `Add server`
- `Delete server`
- `Apply routes`
- `Remove routes`
- `Status`
- `Test`
- `Print gateway`
- `Prune history`
- `Import SSH config`
- `Install launchd`
- `Uninstall launchd`
- `Launchd status`
- `Quit`

You can also keep using CLI actions for automation.

## 2. Edit the server list manually if preferred

Update [servers.txt](./servers.txt) with one hostname or public IPv4 address per line:

```text
203.0.113.10
ssh.example.com
```

Blank lines and lines beginning with `#` are ignored.

When you add a server through the script, you can also paste a full `http://` or `https://` URL. The script extracts and stores only the normalized hostname or IPv4 in [servers.txt](./servers.txt).

## 3. Make the script executable

```bash
chmod +x "./manage-ssh-bypass-routes.sh"
```

## 4. Inspect the detected physical gateway

Run:

```bash
./manage-ssh-bypass-routes.sh print-gateway
```

Expected output shape:

```text
service=Wi-Fi
interface=en0
gateway=192.168.1.1
local_ip=192.168.1.42
tunnel_interfaces=utun6
ipv6_default_interfaces=none
```

`tunnel_interfaces` lists tunnel devices currently holding a default route. `ipv6_default_interfaces` lists interfaces carrying a global IPv6 default; if it is not `none`, see the IPv6 note at the end.

If this fails, connect the Mac to a normal network first and confirm Wi-Fi or Ethernet is active.

## 5. Add or delete servers from the CLI if needed

Examples:

```bash
./manage-ssh-bypass-routes.sh add ssh.example.com
./manage-ssh-bypass-routes.sh add 203.0.113.10
./manage-ssh-bypass-routes.sh add https://panel.example.com/
./manage-ssh-bypass-routes.sh add https://203.0.113.10:8443/path?q=1
./manage-ssh-bypass-routes.sh delete ssh.example.com
./manage-ssh-bypass-routes.sh view
./manage-ssh-bypass-routes.sh prune-history
./manage-ssh-bypass-routes.sh import-ssh-config
```

Hostnames are normalized to lowercase and resolved to all IPv4 `A` records at runtime. If you enter an `http://` or `https://` URL, the script stores only the normalized host portion. Current IPv4 answers are remembered in [resolved-history.txt](./resolved-history.txt) with the time they were last seen.

### Unusual targets

A literal IPv4 line in `servers.txt` is allowed, with a warning, when it is:

- loopback
- RFC1918/private
- CGNAT space
- link-local
- multicast
- unspecified or broadcast-style

The same kinds of address are **ignored when they arrive as a DNS answer for a hostname**. A public name that resolves to a private or reserved address is being answered by a filtering resolver or a captive portal (for example the `10.10.34.34`–`36` sinkhole), not by the real server. Such answers are shown by `view`/`status` as `ignored non-public DNS answers` and are never routed or remembered. To bypass a private address on purpose, add it as a literal IPv4 line.

Malformed targets are rejected, including a name whose last label is all digits (`2`, `host.123`), which the resolver would read as a shorthand IPv4 address. One of the Mac's own addresses is accepted in the list but never routed.

## 6. Preview changes with dry-run

Add `--dry-run` to any mutating action to see what would happen without changing files, routes, or `launchd` state:

```bash
./manage-ssh-bypass-routes.sh --dry-run add 192.168.1.10
./manage-ssh-bypass-routes.sh --dry-run import-ssh-config
./manage-ssh-bypass-routes.sh --dry-run prune-history
./manage-ssh-bypass-routes.sh --dry-run install-launchd
./manage-ssh-bypass-routes.sh --dry-run remove
```

## 7. Apply the bypass routes

Run:

```bash
sudo ./manage-ssh-bypass-routes.sh apply
```

`apply` makes the routing table match the target set, in both directions:

- **Adds or repairs** one host route per target through the detected physical gateway. A route is rebuilt when its gateway or interface is wrong, or when it is still bound to a local address the interface no longer holds (see "Stale source address" below).
- **Deletes** host routes it installed earlier for addresses that are no longer targets: a server removed from the list, an address a hostname stopped resolving to, a route left pointing at a previous network's gateway.

The target set for a hostname is:

- everything it resolves to now;
- addresses it resolved to within the last 24 hours (`BYPASS_LINGER_SECONDS`, default `86400`), so a CDN rotating through a pool does not cut live connections;
- if it has **no usable DNS answer right now**, its most recent known addresses, for as long as that lasts. DNS being down, filtered, or unable to resolve the name through the VPN's resolver does not tear the bypass down.

It then rewrites [resolved-history.txt](./resolved-history.txt) and [last-applied.txt](./last-applied.txt) to match. Each hostname is resolved once per run.

## 8. Verify the routes

Check script status:

```bash
./manage-ssh-bypass-routes.sh status
./manage-ssh-bypass-routes.sh test
```

`status` shows the current route state for each configured server. `test` marks each target `PASS` only when its route uses the physical gateway and interface **and** is bound to the address the interface holds now, and `FAIL` otherwise. `test` exits `1` if anything failed and prints a one-line summary, so it can be used from a script:

```bash
./manage-ssh-bypass-routes.sh test >/dev/null || echo "bypass is broken"
```

Possible states:

- `bypassed`
- `vpn/default-route` — no bypass route; traffic follows the VPN
- `stale source address (route bound to X, en0 now has Y)` — the route looks right but every ordinary connection through it fails; run `apply`
- `this Mac's own address (never routed)`

For hostname servers, the output distinguishes:

- `current resolved IPv4`
- `ignored non-public DNS answers`
- `remembered IPv4 history`
- `remembered-only IPv4` — still routed (recently seen, or last known while DNS fails)
- `expired IPv4 (no longer routed)` — past its linger window; shown, not judged, and forgotten at the next `apply`

A hostname with no usable DNS answer but known addresses is reported as `none (no usable DNS answer; last known addresses stay routed)` and is not a failure by itself.

### Stale source address

macOS binds a gatewayed host route to the local address the interface had when the route was created. If the interface later gets a different address on the same subnet (a new DHCP lease), the route still shows the right gateway and interface, but connections through it fail at once with `Can't assign requested address`. `apply` detects this per route from the `source` field and rebuilds it; `status` and `test` show it. To check by hand, compare `route -n -v get IP` (last field of the last line is the bound address) with `ifconfig en0`.

If `last-applied.txt` still contains route targets that are no longer explained by the current config or remembered hostname history, `status` and `test` report them as `snapshot-only IPv4 targets`.

Check a specific route directly:

```bash
route -n get 203.0.113.10
```

Expected result:

- `gateway:` should be your normal router, not `utun`
- `interface:` should be a physical interface such as `en0` or `en7`

With WireGuard still connected, test SSH if you want a manual end-to-end check:

```bash
ssh your-user@203.0.113.10
```

### Machine-readable output

For a GUI or another program, add `--tsv` to `status` or `test`. The human report is replaced by one tab-separated record per line. Warnings and errors still go to stderr. `test --tsv` exits 1 on any FAIL, the same as `test`. `--tsv` with any other action is an error.

```bash
./manage-ssh-bypass-routes.sh --tsv test
```

The first field names the record type. An empty value is written as `-`.

| Record | Fields after the type |
|---|---|
| `format` | `splitroute-tsv`, format version (`1`), mode (`status` or `test`) |
| `gateway` | service, interface, gateway, local IP, tunnel interfaces (space-separated), IPv6 default interfaces |
| `entry` | config entry, type (`hostname`/`ipv4`), resolution, result |
| `target` | config entry (`-` for snapshot-only), IP, kind, state, result, route gateway, route interface, route source address |
| `rejected` | config entry, the non-public DNS answer that was ignored |
| `summary` | mode, FAIL count (`-` for `status`) |

The values:

- **Entry resolution:**
  - `resolved`: DNS gave a usable answer now.
  - `last-known`: no usable answer; the last known addresses stay routed.
  - `unresolved`: nothing to route. Under `test`, a hostname in this state gets result `FAIL`.
- **Target kind:**
  - `current`: in the current DNS answer.
  - `remembered`: seen within the linger window.
  - `expired`: past the linger window. It is shown but never judged.
  - `snapshot-only`: in `last-applied.txt` but not explained by the config or history.
- **Target state:**
  - `bypassed`: the route is live.
  - `stale-source`: right gateway and interface, but the route is bound to an address the interface no longer has.
  - `vpn`: the traffic goes through the VPN or default route.
  - `local`: the address is this Mac's own.
- **Result:** `PASS` or `FAIL` under `test`, otherwise `-`.

`summary` is always the last record of a complete run. If it is missing, the run died part-way (for example, no physical gateway could be detected), and the records before it must not be trusted. Consumers should check the `format` version and refuse versions they don't know.

## 9. Remove the bypass routes

Run:

```bash
sudo ./manage-ssh-bypass-routes.sh remove
```

`remove` removes routes for:

- direct IPv4 servers from [servers.txt](./servers.txt)
- current hostname IPv4 answers
- every address named in [resolved-history.txt](./resolved-history.txt), whichever server it belonged to
- snapshot targets from [last-applied.txt](./last-applied.txt)

If the LaunchDaemon is installed it re-applies within a minute, so uninstall it first if you want the routes to stay removed.

## 10. Prune stale hostname history

Run:

```bash
./manage-ssh-bypass-routes.sh prune-history
```

This removes remembered history for deleted hostnames and trims still-configured hostnames down to their currently resolved IPv4 addresses, ending the linger window early; the next `apply` then deletes the routes for what was trimmed. A hostname with no usable DNS answer keeps its last known addresses. Routine pruning is not needed: `apply` already forgets mappings older than the linger window.

## 11. Import from SSH config

Run:

```bash
./manage-ssh-bypass-routes.sh import-ssh-config
```

The script scans `~/.ssh/config` by default, discovers importable `Host` servers with a concrete `HostName`, previews them, and imports the target hostnames or IPv4 addresses into [servers.txt](./servers.txt). Wildcard-only hosts and unsupported complex cases are skipped.

Use `--ssh-config /path/to/config` to import from a different SSH config file.

## 12. Manage launchd automatically

Preview or install the root LaunchDaemon:

```bash
./manage-ssh-bypass-routes.sh --dry-run install-launchd
sudo ./manage-ssh-bypass-routes.sh install-launchd
./manage-ssh-bypass-routes.sh launchd-status
sudo ./manage-ssh-bypass-routes.sh uninstall-launchd
```

`install-launchd` renders the plist template with the current script, config, history, and snapshot paths, installs it into `/Library/LaunchDaemons`, sets `root:wheel` ownership and `644` mode, then bootstraps and starts the daemon. It also installs a `newsyslog` rule at `/etc/newsyslog.d/com.nextcloud.ssh-wireguard-bypass.conf` that rotates `/var/log/ssh-wireguard-bypass.log` at 1 MB, keeping three compressed generations. `uninstall-launchd` removes both.

The daemon runs with `--timestamps`, so every log line starts with the local time. Re-run `install-launchd` after updating the script or the template to pick up plist changes.

## 13. Make it persistent with launchd manually if preferred

Because route state can be replaced after reboot or VPN reconnect, use the included `launchd` example as a root daemon.

1. Replace the placeholders in [com.nextcloud.ssh-wireguard-bypass.plist.example](./com.nextcloud.ssh-wireguard-bypass.plist.example):
   - `__SCRIPT_FILE__`
   - `__CONFIG_PATH__`
   - `__HISTORY_PATH__`
   - `__SNAPSHOT_PATH__`
2. Save the edited file as `/Library/LaunchDaemons/com.nextcloud.ssh-wireguard-bypass.plist`.
3. Set ownership and permissions:

```bash
sudo chown root:wheel /Library/LaunchDaemons/com.nextcloud.ssh-wireguard-bypass.plist
sudo chmod 644 /Library/LaunchDaemons/com.nextcloud.ssh-wireguard-bypass.plist
```

4. Load the daemon:

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.nextcloud.ssh-wireguard-bypass.plist
sudo launchctl enable system/com.nextcloud.ssh-wireguard-bypass
sudo launchctl kickstart -k system/com.nextcloud.ssh-wireguard-bypass
```

The example daemon:

- runs at boot/load
- re-applies routes every 60 seconds
- re-runs when `servers.txt` changes

## Notes

- The utility stores hostnames as entered after normalization and resolves them to IPv4 addresses at runtime.
- If a hostname resolves to multiple IPv4 addresses, the script applies/tests all of them.
- Remembered hostname IPs are dropped automatically once they are older than the linger window and the name resolves to something else.
- The last successful `apply` writes [last-applied.txt](./last-applied.txt) automatically.
- `install-launchd` and `uninstall-launchd` require `sudo`, but both support `--dry-run`.
- Use a host alias in `~/.ssh/config` if you want a friendly SSH name while keeping routing IP-based.
- **IPv4 only.** The script installs no IPv6 routes. That is complete as long as the Mac has no global IPv6 default route, which `print-gateway` and `status` report (`ipv6_default_interfaces=none`). If one exists, a server that also publishes an `AAAA` record can be reached over IPv6 along that path, bypass or no bypass.
- **State files and root.** `apply` runs as root while the state files usually sit in your own directory. As root the script refuses to read or write a state file that is a symbolic link, never creates one in place, and replaces files by atomic rename, so nothing in that directory can redirect a root write elsewhere. Anyone who can write `servers.txt` can still add bypass routes; keep the directory private to you.
