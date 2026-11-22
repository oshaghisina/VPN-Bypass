# WireGuard SSH Bypass Utility: How It Works

This document is the full internal and operational reference for the macOS WireGuard SSH bypass utility in this directory. It is written for both human operators and AI tools that need to understand how the utility behaves, what files it uses, and how its state changes over time.

Use [README.md](./README.md) as the quickstart. Use this file when you need to understand the design, state flow, command semantics, and troubleshooting behavior.

## Purpose and Scope

### What problem this utility solves

When a full-tunnel VPN is active on macOS, traffic to every destination follows the VPN route. This utility creates host-specific macOS routes so selected server targets use the normal local network gateway instead of the tunnel.

It was written for WireGuard and keeps that name in its paths and labels, but nothing in it is WireGuard-specific. A `/32` host route wins longest-prefix match over WireGuard's and OpenVPN `redirect-gateway def1`'s `0/1` + `128.0/1` and over a plain replaced `default` alike, and the physical gateway is detected without relying on the default route, so it also works with OpenVPN (either mode), IKEv2 (`ipsec`), and L2TP/PPTP (`ppp`).

The goal is:

- keep the VPN enabled for normal traffic
- bypass it only for selected server destinations
- make that bypass repeatable, inspectable, and self-healing across DNS changes, network changes, and restarts

### What it does

The utility:

- stores a list of servers to bypass
- resolves hostnames to IPv4 addresses
- adds per-host routes through the physical macOS gateway
- deletes those routes again once a target is no longer wanted
- remembers recent hostname IPs, with the time each was last seen, so a rotating or temporarily unresolvable hostname stays bypassed and stale routes get cleaned up
- records the last successfully applied target set
- can install a `launchd` daemon to re-apply routes automatically

### What it does not do

The utility does not:

- modify any VPN configuration
- modify SSH authentication or keys
- change `~/.ssh/config` automatically unless you explicitly import from it
- route all SSH traffic globally
- support IPv6 route targets
- guarantee that a hostname always resolves to the same IP

### Why macOS host routes are used

The utility works by adding destination-specific host routes in the macOS routing table. This is the simplest reliable way to bypass the VPN for a small set of targets while leaving the rest of the traffic unchanged.

That is why the script talks in terms of:

- physical gateway
- physical interface
- host routes
- resolved IPv4 targets

It is not changing SSH itself. It is changing how macOS reaches the selected servers.

## Directory Overview

This directory contains the complete utility bundle:

- `manage-ssh-bypass-routes.sh`
  - Main script and entrypoint.
  - Provides menu mode and CLI mode.
  - Owns route application, removal, status, testing, import, history, snapshot, and launchd actions.

- `servers.txt`
  - Primary source of truth for the configured bypass server list.
  - Stores one hostname or IPv4 address per line.

- `resolved-history.txt`
  - Memory of hostname-to-IPv4 mappings with the time each was last seen.
  - Keeps a hostname bypassed through DNS rotation and DNS failure, and tells `apply` and `remove` which older addresses may still hold a route.

- `last-applied.txt`
  - Snapshot of the exact IPv4 target set from the last successful `apply`.
  - Used as an additional cleanup and reporting source.

- `com.nextcloud.ssh-wireguard-bypass.plist.example`
  - Template plist for running the script automatically through `launchd`.
  - Used by the manual workflow and by `install-launchd`.

- `README.md`
  - Quickstart operator guide.
  - Short operational summary, not the full design reference.

- `data-dir` (optional)
  - A one-line pointer file beside the script naming the directory that holds `servers.txt`, `resolved-history.txt`, and `last-applied.txt`.
  - Exists because the deployed copy of the script lives in a root-owned directory where an interactive user cannot write. See "Script location".

## High-Level Architecture

### Source-of-truth layers

The utility uses three levels of state:

1. Configured servers
   - Stored in `servers.txt`
   - These are the servers the operator explicitly wants to bypass

2. Remembered hostname history
   - Stored in `resolved-history.txt`
   - This tracks old IPv4 answers for configured hostname servers

3. Last-applied snapshot
   - Stored in `last-applied.txt`
   - This records the exact target set from the last successful route apply

These three layers exist for different reasons:

- config answers “what should we bypass?”
- history answers “what old hostname IPs might still need cleanup?”
- snapshot answers “what did we actually apply last time?”

### Runtime resolution flow

When the script processes a hostname server:

1. Read the hostname from `servers.txt`
2. Normalize it
3. Resolve current IPv4 `A` records, once per run
4. Discard any answer that is not a public address
5. Add the remaining IPv4s to the current target set
6. Record them in the history with the time of this run

This means hostname targets are dynamic at runtime, but they also leave a short history trail.

### Route application flow

`apply` does this:

1. Read `servers.txt`
2. Detect the physical gateway, interface, and local address; stop here, changing nothing, if there is none
3. Read the previous snapshot and the history
4. Build the target set (below)
5. For each target, leave the route alone if it is already correct, otherwise delete and re-add it
6. Delete host routes it installed earlier for addresses that are no longer targets
7. Drop history mappings that are no longer routed and write `resolved-history.txt`
8. Save the exact applied target set to `last-applied.txt`

The target set is, per configured server:

- a literal IPv4: that address
- a hostname: what it resolves to now, plus addresses it resolved to within the linger window (`BYPASS_LINGER_SECONDS`, default 24 hours), plus — only when it has no usable answer right now — its most recent known addresses

One of the Mac's own addresses is never a target.

A route counts as "already correct" only if all of these hold: its gateway and interface are the detected physical ones; the previous snapshot was taken under the local address the interface still has; and the route's own bound source address, read from `route -n -v get`, equals that address. If the bound address cannot be read, the route must at least be one the previous snapshot lists.

Step 6 only considers addresses the script itself recorded (previous snapshot and history file) and only touches one if the kernel actually holds a static, gatewayed host route for it outside any tunnel interface.

### Route removal flow

`remove` is intentionally broader than `apply`.

It removes routes from:

- direct IPv4 servers in `servers.txt`
- current IPv4 results for hostname servers
- every address named in `resolved-history.txt`, whichever server it belonged to
- snapshot targets from `last-applied.txt`

This is why `remove` can still clean up routes even if DNS changed since the last `apply`.

### Persistence via launchd

The script can be installed as a system LaunchDaemon. In that mode, `launchd` runs the script with `apply` so routes are re-applied:

- at boot/load
- every 60 seconds
- as soon as `servers.txt` changes (`WatchPaths`)

This is the persistence mechanism for macOS restarts, VPN reconnects, and network changes. The periodic run is what self-heals: moving to another Wi-Fi network or getting a new DHCP lease is noticed on the next run and every route is rebuilt.

The daemon runs with `--timestamps` and logs to `/var/log/ssh-wireguard-bypass.log`, which `install-launchd` puts under `newsyslog` rotation.

### Why history and snapshot both exist

They solve different failure modes:

- `resolved-history.txt`
  - fixes hostname DNS churn and DNS failure
  - keeps recent hostname IPs routed, and known for cleanup

- `last-applied.txt`
  - fixes “what did we really apply last time?”
  - is how `apply` finds the route of a server that has since been deleted from the list
  - records the local source address the routes were created under

They overlap somewhat, but they are not redundant.

## How to Run the Script

This section explains the common ways to invoke the script from Terminal and when each form should be used.

### Script location

The script file lives here:

```text
$HOME/.local/share/wireguard-ssh-bypass/manage-ssh-bypass-routes.sh
```

That directory is the working copy and holds the state files. A second, root-owned copy of the script is deployed at `/usr/local/libexec/wireguard-ssh-bypass/`; it is the one the LaunchDaemon runs and the one the `bypass` shell alias points at. A `data-dir` file beside the deployed script names the directory above, so both copies read and write the same `servers.txt`, history, and snapshot.

State directory resolution order: `$BYPASS_DATA_DIR`, then the `data-dir` pointer beside the script, then the script's own directory. Explicit `--config`, `--history`, and `--snapshot` override all three.

When updating the deployed copy, copy to a temporary name in the same directory and rename it into place. The daemon starts every 60 seconds and a plain `cp` over the live file can be read half-written.

### Run from the script directory

This is the easiest form for normal interactive use.

```bash
cd "$HOME/.local/share/wireguard-ssh-bypass"
./manage-ssh-bypass-routes.sh
```

Important:

- `./manage-ssh-bypass-routes.sh` only works if your current directory is the one that contains the script
- `./script` means “run the script from the current directory”

### Run by full path from anywhere

Use this when you are in another directory and do not want to `cd` first.

```bash
"$HOME/.local/share/wireguard-ssh-bypass/manage-ssh-bypass-routes.sh" view
```

This is usually the safest command shape when:

- the path contains spaces
- you are calling the script from another directory
- you want copy-paste commands that work consistently

### Run through `bash` explicitly

If the script already has execute permission, this is optional. It is still useful when you want to invoke the script through the shell directly.

```bash
bash "$HOME/.local/share/wireguard-ssh-bypass/manage-ssh-bypass-routes.sh" view
```

Use this when:

- you are unsure whether the executable bit is set
- you want to be explicit about the interpreter

### Run menu mode

Menu mode means running the script with no action argument.

Examples:

```bash
cd "$HOME/.local/share/wireguard-ssh-bypass"
./manage-ssh-bypass-routes.sh
```

or:

```bash
"$HOME/.local/share/wireguard-ssh-bypass/manage-ssh-bypass-routes.sh"
```

Menu mode is best for:

- browsing the current state
- guided one-off usage
- users who do not want to remember CLI actions

### Run CLI mode

CLI mode means passing an action, and sometimes a value.

Examples:

```bash
./manage-ssh-bypass-routes.sh view
./manage-ssh-bypass-routes.sh add ssh.example.com
./manage-ssh-bypass-routes.sh add "https://panel.example.com/"
./manage-ssh-bypass-routes.sh delete ssh.example.com
./manage-ssh-bypass-routes.sh status
./manage-ssh-bypass-routes.sh test
```

CLI mode is best for:

- repeatable commands
- automation
- precise control
- AI/tool usage

### Run privileged commands with `sudo`

Some actions need elevated privileges because they change system routes or system `launchd` state.

Examples:

```bash
sudo ./manage-ssh-bypass-routes.sh apply
sudo ./manage-ssh-bypass-routes.sh remove
sudo ./manage-ssh-bypass-routes.sh install-launchd
sudo ./manage-ssh-bypass-routes.sh uninstall-launchd
```

Normally, `sudo` is not needed for:

- `view`
- `status`
- `test`
- `print-gateway`
- `launchd-status`
- normal menu browsing

### Run safe previews with `--dry-run`

`--dry-run` previews mutating actions without changing files, routes, or `launchd` state.

Examples:

```bash
./manage-ssh-bypass-routes.sh --dry-run add "https://panel.example.com/"
./manage-ssh-bypass-routes.sh --dry-run apply
./manage-ssh-bypass-routes.sh --dry-run install-launchd
```

Use this before a real mutating command when you want to confirm what the script would do.

### Run automatically with `launchd`

This is the non-interactive automation mode.

In this mode, `launchd` invokes the script for you, typically with `apply`, after installation.

Relevant commands:

```bash
./manage-ssh-bypass-routes.sh --dry-run install-launchd
sudo ./manage-ssh-bypass-routes.sh install-launchd
./manage-ssh-bypass-routes.sh launchd-status
sudo ./manage-ssh-bypass-routes.sh uninstall-launchd
```

This is the right mode when you want the routes to persist across reboot, reconnect, or daemon reload events.

### Recommended daily usage

For normal interactive usage:

```bash
cd "$HOME/.local/share/wireguard-ssh-bypass"
./manage-ssh-bypass-routes.sh
```

For one-off commands from anywhere:

```bash
"$HOME/.local/share/wireguard-ssh-bypass/manage-ssh-bypass-routes.sh" status
```

Use `sudo` only for:

- route-changing actions
- `launchd` install/remove actions

### Common launch and execution mistakes

#### `zsh: no such file or directory`

Usually means:

- you ran `./manage-ssh-bypass-routes.sh` from the wrong directory
- you mistyped the path
- you forgot to quote a path that contains spaces

Example of the wrong pattern:

```bash
cd "$HOME/Downloads/some-other-folder"
./manage-ssh-bypass-routes.sh
```

That fails because the script is not in that directory.

#### `permission denied`

Usually means one of these:

- the script is not executable yet
- a state file such as `resolved-history.txt` or `last-applied.txt` is owned by `root`

Possible fixes:

```bash
chmod +x "$HOME/.local/share/wireguard-ssh-bypass/manage-ssh-bypass-routes.sh"
```

If the problem is state-file ownership, inspect the file permissions before changing them.

#### `command not found`

Usually means:

- you did not use `./`
- you used only the script name from a directory that does not contain it
- the script directory is not on your `PATH`

The safe fallback is to use either:

- the script directory plus `./manage-ssh-bypass-routes.sh`
- the full quoted absolute path

## Command Model

### Menu mode

If you run the script with no action:

```bash
./manage-ssh-bypass-routes.sh
```

it opens an interactive numbered menu.

Menu mode is useful for:

- operators who prefer guided usage
- browsing state
- running one-off tasks without remembering commands

### CLI mode

If you pass an action, the script runs directly in CLI mode.

Example:

```bash
./manage-ssh-bypass-routes.sh view
sudo ./manage-ssh-bypass-routes.sh apply
./manage-ssh-bypass-routes.sh --dry-run install-launchd
```

CLI mode is useful for:

- automation
- repeatable ops commands
- `launchd`
- AI agent usage

### Dry-run mode

`--dry-run` applies only to mutating actions.

It previews:

- file changes
- route changes
- launchd changes

It does not modify:

- config files
- state files
- routes
- launchd state

It still performs enough read-only work to explain what would happen.

Example:

```bash
./manage-ssh-bypass-routes.sh --dry-run apply
```

### Action summary

#### `view`

- Reads config and state
- Resolves current hostname IPv4s
- Refreshes remembered history
- Shows:
  - configured server
  - current resolved IPv4
  - remembered IPv4 history
  - remembered-only IPv4
  - unusual target warnings

#### `add VALUE`

- Adds one server to `servers.txt`
- Accepts hostname, IPv4, or `http(s)` URL input
- Stores only the normalized hostname or IPv4
- Normalizes hostnames to lowercase
- Warns on unusual-but-allowed IPv4 ranges
- Rejects malformed values

#### `delete VALUE`

- Removes one exact server from `servers.txt`
- Matches the normalized stored value
- URL input is normalized to the same stored host/IP before matching

#### `apply`

- Requires `sudo` unless `--dry-run`
- Detects physical gateway/interface
- Adds or repairs routes for the target set
- Deletes its own routes for addresses that left the target set
- Trims `resolved-history.txt` and updates `last-applied.txt`

#### `remove`

- Requires `sudo` unless `--dry-run`
- Removes routes using config, history, and snapshot sources

#### `status`

- Read-only
- Reports route state for configured servers
- Also reports `snapshot-only IPv4 targets` when present

#### `test`

- Same target scope as `status`
- Adds pass/fail output and a one-line summary
- Exits `1` if any target failed, `0` otherwise

#### `prune-history`

- Trims `resolved-history.txt` to what configured hostnames resolve to now
- Keeps the last known addresses of a hostname that has no usable answer
- Rarely needed: `apply` already forgets mappings past the linger window

#### `import-ssh-config`

- Reads `~/.ssh/config` by default
- Finds importable `Host` definitions with concrete `HostName`
- Skips wildcard-only and unsupported cases
- Imports discovered targets into `servers.txt`

#### `install-launchd`

- Renders the plist template with current paths
- Installs it into `/Library/LaunchDaemons`
- Sets ownership and mode
- Installs the `newsyslog` log rotation rule
- bootstraps/enables/kickstarts the daemon

#### `uninstall-launchd`

- disables and boots out the daemon
- removes the installed plist and the log rotation rule

#### `launchd-status`

- Shows whether the plist is installed
- Shows whether the launchd service is loaded

#### `print-gateway`

- Shows the detected physical service, interface, gateway, and local address
- Lists tunnel interfaces holding a default route
- Lists interfaces carrying a global IPv6 default route

## State and Data Flow

### Server normalization

When a server is read or added:

- surrounding whitespace is trimmed
- `http://` and `https://` URLs are accepted as input convenience and reduced to their host only
- IPv4 addresses remain unchanged
- hostnames are lowercased
- trailing dot is removed from hostnames

This normalized value is what gets stored and compared.

### Hostname resolution

For hostname servers, the script asks the system resolver (`dscacheutil`), which is what applications use. Only if that returns no usable address does it ask `dig` as a second opinion. Each hostname is resolved once per run and the answer reused.

The result is:

- IPv4 only
- public addresses only
- deduplicated
- runtime-dependent

If a hostname resolves to multiple IPv4s, all of them are used.

An answer that is private, loopback, link-local, CGNAT, multicast, or reserved is discarded. A public name answering with such an address is being answered by a filtering resolver or a captive portal — `10.10.34.34`–`36` is the usual sinkhole — not by the server. Routing it does nothing useful, and treating it as the name's address would let the real route lapse. Discarded answers are listed by `view` and `status` as `ignored non-public DNS answers`. If every answer is discarded, the hostname is treated as having no answer, and its last known addresses stay routed.

### Current vs remembered history

For a hostname server:

- current resolved IPv4
  - what DNS says now

- remembered IPv4 history
  - every IPv4 remembered in `resolved-history.txt`

- remembered-only IPv4
  - remembered history minus current resolved IPv4
  - still routed: either seen within the linger window, or the last known addresses of a name that has no usable answer

- expired IPv4
  - remembered, but past the linger window while the name resolves to something else
  - no longer routed; the next `apply` deletes its route and forgets it

### Snapshot-only targets

`last-applied.txt` may contain IPv4s that are not explained anymore by:

- current config
- current DNS answers
- remembered hostname history

When that happens, `status` and `test` report:

- `snapshot-only IPv4 targets`

This tells you the system previously applied routes that current state no longer fully describes.

### Deduplication rules

Deduplication happens at several points:

- duplicate servers in `servers.txt` are skipped
- duplicate hostname IPv4 answers are collapsed
- duplicate history mappings are collapsed
- duplicate route targets from config/history/snapshot are collapsed

This keeps route actions idempotent and reporting readable.

## File Formats

### `servers.txt`

Format:

- one hostname or IPv4 per line
- blank lines allowed
- lines beginning with `#` are ignored

Important:

- `servers.txt` stores only hostname or IPv4 values
- URLs are accepted only when entered through script actions such as `add`
- a URL like `https://panel.example.com/path` is stored as `panel.example.com`

Example:

```text
# SSH bypass targets
203.0.113.10
ssh.example.com
```

Invalid examples:

```text
user@host
bad host name
```

### `resolved-history.txt`

Format:

- one hostname-to-IPv4 mapping per line
- exact format: `hostname ip last-seen-epoch`
- the third field is the Unix time of the last run that resolved the name to that address; a line without it (written by an older version) is read as "seen long ago"
- blank lines allowed
- lines beginning with `#` are ignored
- a line whose address is not public is ignored on read and dropped on the next write

Example:

```text
# One hostname-to-IPv4 mapping per line.
# Format: hostname ip last-seen-epoch
ssh.example.com 203.0.113.10 1795160000
ssh.example.com 203.0.113.11 1795167591
```

Invalid examples:

```text
203.0.113.10
ssh.example.com
ssh.example.com not-an-ip
```

### `last-applied.txt`

Format:

- optional comment header lines
- one IPv4 address per line

Example:

```text
# Last successful apply at 2026-04-24T10:30:00Z
# source-ip: 192.168.1.42
203.0.113.10
203.0.113.11
```

`source-ip` is the local address the routes were created under. A different address at the next `apply` forces every route to be rebuilt.

### `com.nextcloud.ssh-wireguard-bypass.plist.example`

This is a template file with placeholders:

- `__SCRIPT_FILE__`
- `__CONFIG_PATH__`
- `__HISTORY_PATH__`
- `__SNAPSHOT_PATH__`

The script or the operator replaces those placeholders with concrete absolute paths.

Besides `apply`, the template passes `--timestamps`, sets `StartInterval` to 60 seconds, and lists the config path under `WatchPaths` so an edit to `servers.txt` triggers a run immediately.

## Operational Flows

### First-time setup

1. Open the menu or use CLI
2. Run `print-gateway`
3. Add servers or import from SSH config
4. Run `view`
5. Run `apply`
6. Run `status` and `test`
7. Install `launchd` if persistence is wanted

### Adding a new server

Example:

```bash
./manage-ssh-bypass-routes.sh add ssh.example.com
./manage-ssh-bypass-routes.sh view
sudo ./manage-ssh-bypass-routes.sh apply
```

### Importing from SSH config

Example:

```bash
./manage-ssh-bypass-routes.sh import-ssh-config
```

What happens:

1. Parse `~/.ssh/config`
2. Find concrete `Host` + `HostName` pairs
3. Preview importable targets
4. Add targets into `servers.txt`
5. Warn on unusual-but-allowed IPv4 targets

### Applying routes

Example:

```bash
sudo ./manage-ssh-bypass-routes.sh apply
```

What happens:

1. Detect gateway/interface
2. Resolve hostnames and build the target set
3. Add or repair host routes
4. Delete routes for addresses that left the target set
5. Trim and save history
6. Save snapshot

### Validating routes

Examples:

```bash
./manage-ssh-bypass-routes.sh status
./manage-ssh-bypass-routes.sh test
route -n get 203.0.113.10
```

Interpretation:

- if `gateway` is the physical router, `interface` is like `en0`, and `source` is the address that interface has now, bypass is working
- if route points to `utun` or the VPN path, bypass is not working
- if gateway and interface are right but `source` is some other address, the route is stale and every ordinary connection through it fails with `Can't assign requested address`; `apply` rebuilds it

`route -n get` alone cannot show the third case. The script reads the bound address from `route -n -v get`, where it is the last field of the last line. The end-to-end check is to compare an unbound connection with a source-bound one, which must behave the same:

```bash
nc -4 -z -G 3 203.0.113.10 443
nc -4 -z -G 3 -s 192.168.1.42 203.0.113.10 443
```

### Removing routes

Example:

```bash
sudo ./manage-ssh-bypass-routes.sh remove
```

This is the cleanup step when you want to unwind bypass behavior.

### Pruning history

Example:

```bash
./manage-ssh-bypass-routes.sh prune-history
```

Use this when you want the history file to reflect current DNS immediately instead of waiting out the linger window. Hostnames that currently have no usable answer keep their last known addresses.

### Installing or uninstalling launchd

Examples:

```bash
./manage-ssh-bypass-routes.sh --dry-run install-launchd
sudo ./manage-ssh-bypass-routes.sh install-launchd
./manage-ssh-bypass-routes.sh launchd-status
sudo ./manage-ssh-bypass-routes.sh uninstall-launchd
```

## Warnings and Safety Rules

### Unusual-but-allowed IPv4 ranges

The script warns but allows these IPv4 categories:

- loopback
- RFC1918/private
- CGNAT/shared
- link-local
- multicast
- unspecified/reserved
- broadcast-style

These are warnings because they are unusual for public bypass targets, but not always wrong in every environment.

This applies to literal IPv4 lines in `servers.txt` only. The same kinds of address are discarded when they arrive as a DNS answer for a hostname; see "Hostname resolution".

### Rejected targets

Malformed targets are rejected. Examples:

- invalid IP syntax
- invalid hostnames
- non-HTTP(S) URLs
- URLs with embedded credentials
- usernames or `user@host` syntax
- a name whose last label is all digits, such as `2` or `host.123`, which the resolver would read as a shorthand IPv4 address

### When `sudo` is required

Normally required for:

- `apply`
- `remove`
- `install-launchd`
- `uninstall-launchd`

Not required for:

- `view`
- `status`
- `test`
- `print-gateway`
- `prune-history`
- `import-ssh-config`
- `launchd-status`

### What dry-run does not do

`--dry-run` does not:

- add routes
- remove routes
- write config/history/snapshot files
- install or remove launchd plist

It only explains what would happen.

## Troubleshooting

### Gateway detection fails

Symptoms:

- `print-gateway` fails
- `apply` errors before route work starts

Likely causes:

- no active physical network
- only VPN/tunnel route is visible
- interface state is unusual

Checks:

```bash
./manage-ssh-bypass-routes.sh print-gateway
netstat -rn -f inet
ifconfig
```

### Route does not show as bypassed

Symptoms:

- `status` says `vpn/default-route`
- `test` says `FAIL`

Checks:

```bash
route -n get YOUR_SERVER_IP
./manage-ssh-bypass-routes.sh status
```

Confirm that:

- gateway is the physical router
- interface is `en0`/similar, not `utun`
- `source` in `status` is the interface's current address

If `status` reports `stale source address`, run `apply`. With the LaunchDaemon installed this repairs itself within a minute.

### Hostname resolves to no IPv4

Symptoms:

- `current resolved IPv4: none`

Likely causes:

- DNS failure
- the VPN's resolver cannot resolve the name
- every answer was a non-public address and was ignored (shown as `ignored non-public DNS answers`)
- hostname has only IPv6
- typo in hostname

If the hostname resolved before, its last known addresses stay routed and the line reads `none (no usable DNS answer; last known addresses stay routed)`. Only a hostname that has never resolved to a public address has no bypass at all.

### Stale remembered IPs

Symptoms:

- old IPs appear under `remembered-only IPv4`

Meaning:

- DNS changed
- the older answers are still inside the linger window and deliberately still routed

They expire by themselves. To drop them now:

```bash
./manage-ssh-bypass-routes.sh prune-history
```

### Snapshot-only targets remain

Symptoms:

- `status` or `test` shows `snapshot-only IPv4 targets`

Meaning:

- last successful apply included targets that current config/history no longer explain

Typical fix:

```bash
sudo ./manage-ssh-bypass-routes.sh remove
./manage-ssh-bypass-routes.sh prune-history
```

### Launchd installed but not loaded

Checks:

```bash
./manage-ssh-bypass-routes.sh launchd-status
sudo launchctl print system/com.nextcloud.ssh-wireguard-bypass
```

Common causes:

- plist not installed
- wrong plist permissions
- bad rendered paths
- launchctl bootstrap failure

### SSH config import skips entries

The import intentionally skips:

- wildcard-only hosts
- unsupported complex definitions
- entries without a concrete `HostName`
- malformed targets

Use a direct `Host` + `HostName` pair if you want it imported reliably.

## Design Notes / Invariants

### IPv4-only routing

This utility is IPv4-only for route application and reporting. Hostnames that resolve only to IPv6 will not become bypass targets.

Whether that leaves a gap depends on the Mac having a global IPv6 default route. `print-gateway` and `status` report it. With none, nothing can reach a server over IPv6 and the IPv4 bypass is complete. With one, a server that also publishes an `AAAA` record can be reached over IPv6 along that route, whatever the IPv4 bypass says. Interface-scoped IPv6 defaults, which macOS keeps on every `utun`, are not usable defaults and are not counted.

### User-facing “Server” vs internal `entry`

The user interface says `Server` because that is clearer for operators. Internally, some helper names still use `entry` because they predate the wording change and are implementation details only.

### History expires by age

A mapping stays in `resolved-history.txt` for the linger window after the hostname last resolved to it, and is then dropped by `apply` together with its route. Two things are exempt: the mappings a hostname resolves to now, and the most recent known mappings of a hostname that currently has no usable answer.

This bounds both the file and the routing table. Before, history only grew and `apply` never deleted a route, so an address a CDN had moved away from stayed outside the VPN until reboot.

### State files and root

`apply` runs as root while the state files normally sit in the invoking user's directory. As root the script refuses a state file that is a symbolic link, never creates one in place, sets owner and mode on a private temporary file, and renames that over the destination. In the daemon log, a rejected line is reported by line number only.

### File descriptors under bash 3.2

The per-server loop must not use `done < <(...)`. Under the bash 3.2 that macOS ships, each such process substitution leaves a descriptor open until the script exits. `launchd` starts jobs with a limit of 256, and past the limit command substitutions silently return nothing.

### Snapshot writes after successful apply

`last-applied.txt` is updated after a successful apply flow. It records what the system attempted to use as the actual target set for that apply.

### Remove is broader than apply

This is intentional. `apply` deletes only what left the target set. `remove` deletes everything the script knows about. That asymmetry exists so cleanup still works after:

- DNS changes
- config changes
- partial state drift

## Example Interpretation

Example `status` fragment:

```text
Configured server: ssh.example.com (hostname)
  current resolved IPv4: 203.0.113.11
    state    : bypassed
    gateway  : 192.168.1.1
    interface: en0
    source   : 192.168.1.42
  remembered IPv4 history: 203.0.113.10, 203.0.113.11
  remembered-only IPv4: 203.0.113.10
    state    : bypassed
    gateway  : 192.168.1.1
    interface: en0
    source   : 192.168.1.42
```

This means:

- current DNS answer is `203.0.113.11`
- current target is bypassed correctly
- the host resolved to `203.0.113.10` within the linger window
- that address is still remembered and still bypassed

Once the linger window passes, the next `apply` deletes the route for `203.0.113.10` and forgets it. In between, `status` may show it as `expired IPv4 (no longer routed)`.

## Example Dry-Run Output

Example:

```text
DRY-RUN: Would delete any existing host route for 203.0.113.10
DRY-RUN: Would add host route 203.0.113.10 via 192.168.1.1
DRY-RUN: Would delete stale host route for 203.0.113.99
DRY-RUN: Would write resolved-history.txt with 2 hostname-to-IPv4 mappings
DRY-RUN: Would write last-applied.txt with 1 applied IPv4 targets
```

Interpretation:

- the route would be replaced or added
- a route for an address that is no longer a target would be deleted
- history would be trimmed and saved
- snapshot would be updated
- but nothing has actually changed yet because this is dry-run

## Final Notes

If you are an operator:

- use `README.md` for quick usage
- use this file when behavior is unclear

If you are an AI or automation tool:

- treat `servers.txt` as configured intent
- treat `resolved-history.txt` as recent-answer memory with last-seen times
- treat `last-applied.txt` as the last applied target snapshot
- remember that `remove` intentionally uses a broader target set than `apply`
- do not trust `route -n get` alone to prove a bypass works; check `source` in `status`, or use `test` and its exit code
