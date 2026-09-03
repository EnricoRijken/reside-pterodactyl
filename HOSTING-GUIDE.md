# Hosting a ReSide Server

Choose the simplest option that fits your group. You do not need the Backend Servers package for an
occasional private session.

## Temporary game with friends

Open ReSide, choose **Host Server**, and invite the other players. The game closes the hosted session
when the host exits. If direct connections are unavailable, put the host and players on the same mesh
VPN, such as Tailscale or ZeroTier.

Use the Backend Servers package below only for an independently running or always-online deployment.

## What the Backend Servers package contains

The package runs the whole backend as Docker containers. Game servers are **not** started by
double-clicking a launcher: the API starts one Linux game-server container per world on demand, and
you create and control those worlds from the admin panel.

```text
ReSide-<version>-Backend-Servers/
  start.bat  start.ps1  start.sh       Guided startup for the whole stack
  stop.bat   stop.ps1   stop.sh        Graceful shutdown, preserving all data
  CollectLogs.bat/.ps1/.sh             Support-archive collector
  HOSTING-GUIDE.md                     This document
  START-HERE.txt  COLLECTING-LOGS.txt  Version.txt
  Api/
    .env                               Generated secrets and settings. Keep private.
    docker-compose.yml                 Core services: api, web, db, redis
    reside-images.tar                  All packaged images, loaded offline on first start
    run.*  stop.*  reset-database.*    Advanced direct controls
```

There is no `ServerLaunchers` folder and no native server executable in the default package. A
`Server/Win64/` payload is present only when the package was built with
`-IncludeWindowsDedicatedServer`; see [Optional native Windows server](#optional-native-windows-server).

## Docker-managed setup on Windows

Docker Desktop is the only separate prerequisite. A native Windows server is not required.

1. Extract the **entire** package. Do not move individual files out of it.
2. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and open it once.
3. Double-click **`start.bat`** at the package root. Choose who can join:
   - **Local network (LAN)** detects the host address automatically and needs no router setup.
   - **Public internet** asks for the public IP or DNS name. Router port forwarding is still required.
   - **Private network or VPN** asks for the host's VPN address. Every player must join that VPN.
   - **Custom setup** retains direct control over the advertised address and game UDP port range;
     the commented `config.toml` at the package root explains every operator-facing setting.
4. Approve the Windows permission prompt used to add the hosting firewall rules. The launcher waits
   for Docker (starting Docker Desktop itself if needed), records the selected address, adds firewall
   rules, loads the packaged images, starts the core services, waits for the API, and opens the panel.
5. The launcher opens the admin panel with a short-lived one-time sign-in code. The long-lived admin
   token is not printed or placed in the URL. If automatic sign-in fails, use `ADMIN_API_TOKEN` from
   `Api/.env` for manual recovery and keep it private.
6. Create worlds on the **Game Servers** page. See [Creating game servers](#creating-game-servers).
7. Double-click **`stop.bat`** when finished. Managed servers stop gracefully and saved data is
   preserved.

On later starts, double-click `start.bat` again. It reuses the already-loaded images, the recorded
address, the existing firewall rules, and the packaged database.

The automatic firewall rules apply to Windows networks classified as **Private** or **Domain**. If
Windows classifies a trusted home network as **Public**, the launcher warns you; change that network
profile to **Private** before hosting. Do not make an untrusted public Wi-Fi network private.

The API mounts the Docker socket so it can create game-server containers. That is effectively
host-level Docker control, so restrict the admin panel and its token to trusted administrators.

## Docker-managed setup on Linux

Docker Engine is the only separate prerequisite.

1. Extract the **entire** package and open a terminal in the extracted package root.
2. Install and start [Docker Engine](https://docs.docker.com/engine/install/). Ensure your user can
   run `docker info`.
3. Run `sh ./start.sh`.
4. Choose LAN, public internet, private VPN, or custom hosting when prompted. The launcher then
   performs the same startup steps as on Windows and prints the admin API token along with the local
   and LAN admin-panel URLs. Open a printed URL and enter the token when prompted.
5. Create worlds on the **Game Servers** page.
6. Run `sh ./stop.sh` when finished. Database and game-server data are preserved.

Using `sh` avoids executable-permission problems caused by extracting a package built on Windows.
Firewall rules are applied through `firewalld` or `ufw` when either is present and the operator
account can elevate without a password prompt; otherwise the launcher prints the rules to add and
continues. The operator account must be able to access the Docker socket, which is privileged host
access.

## Docker-managed setup on macOS

The packaged stack uses Linux containers. Install Docker Desktop, confirm `docker info` succeeds, then
run `sh ./start.sh`. The images are built for `linux/amd64`, so an Apple Silicon Mac runs the game
servers under emulation, which measurably reduces the number of players a single host can support.
Intel Macs run them natively. The package contains no native macOS game-server executable. The
launcher does not configure the macOS firewall; allow the ports below manually if one is active.

## What the launcher configures automatically

- **Hosting configuration.** The startup wizard updates the commented package-root `config.toml`.
  Before Docker starts, the launcher validates that file and copies its runtime values into the
  private generated `Api/.env`; secrets and internal Docker settings remain there. The configured
  address is handed to remote players for every managed game server. Managed
  worlds also register `127.0.0.1` as an optional same-host address, which clients use only when they
  verified this API through loopback or a private LAN/VPN address. Loopback clients use `127.0.0.1`;
  LAN/VPN clients reuse the verified API host with the world's game port.
- **Host firewall.** Inbound rules are added for TCP 3000, UDP 3002, and the UDP game-server range
  (`SERVER_MANAGER_PORT_MIN`–`SERVER_MANAGER_PORT_MAX`, `7777-7877` by default). On Windows the rules
  are scoped to the Domain and Private profiles. Later starts reuse enabled matching rules without
  requesting elevation. A new permission prompt appears only when a required rule is missing or the
  configured game-port range changes. Missing elevation produces a warning and startup continues.
- **Admin API token.** Printed after startup so it can be pasted into the panel. It is also stored in
  `Api/.env` as `ADMIN_API_TOKEN`.

The wizard's address applies to the API-managed deployment and every managed world. Choosing another
mode on a later start automatically recreates stale game-server containers with the new address while
preserving each Saved volume, world, UUID, and stopped/running state. UDP ports are managed
automatically within the configured range. Edit `config.toml` for hosting configuration; `Api/.env`
is retained for internal recovery and generated secrets.

## Creating game servers

Open the **Game Servers** page in the admin panel.

- **Host all worlds** creates a server for every world preset that is not already hosted. Every world
  uses the deployment address selected during startup and receives a unique UDP port.
- **Create server** adds and immediately starts a single world. Only the world is required:
  - **Game port** — leave blank to take the first free UDP port in the configured range.
- The world presets are **Gateway**, **New Venezia**, **Raijuku**, **La Genoa Aires**, **VLES**, and
  **Residences**. A single Residences server hosts every public showcase and owned residence.
- A notice above the table shows the deployment's LAN, public internet, private VPN, or custom mode,
  shared address, and UDP range. Change it by stopping the deployment and running the startup launcher
  again.
- Each row shows the world and its allocated port. Row actions start, stop, restart, view logs for,
  and delete a server.

The API gives each server its own persistent `Saved` volume. Stopping the stack removes managed
containers but preserves their volumes. Deleting a server in the panel is the explicit operation that
removes its saved data.

## Ports

| Port | Protocol | Purpose | Exposure |
| --- | --- | --- | --- |
| 3000 | TCP | Web gateway: admin panel, API, and docs | All interfaces, for clients and administrators |
| 3002 | UDP | LAN discovery | Trusted LAN only — never forward to the internet |
| 7777–7877 | UDP | Managed game servers, one port per world | Reachable by players |
| 3001 | TCP | Direct API for same-host game-server authorities | Loopback only — never expose |

Gateway traffic is plain HTTP. Use it only on a trusted LAN or VPN, put a TLS reverse proxy in front
for internet-facing administration, and never enter the admin token over an untrusted plaintext
network. Set `ADMIN_BIND_ADDRESS=127.0.0.1` in `Api/.env` if the gateway should not be reachable from
the LAN at all.

## Host on the same local network

No port forwarding is needed when everyone is on the same network. The launcher prints the LAN URLs;
players use the host's local IPv4 address, and the client reaches both the gateway and the game
servers directly. LAN discovery on UDP 3002 lets clients find the deployment without typing an
address.

## Host over the internet with port forwarding

1. Find the host computer's local IPv4 address:
   - **Windows:** run `ipconfig` and look for **IPv4 Address**.
   - **Linux:** run `ip address` and look for the active adapter's `inet` address.
   - **macOS:** open **System Settings → Network** and view the active connection's IP address.
2. Stop the deployment, run the startup launcher again, choose **Public internet**, and enter the
   public DNS name or IP that players will use. Startup applies it to all existing and future worlds
   without deleting Saved data or changing assigned ports.
3. Open the router's administration page and find **Port Forwarding**, **NAT**, or **Virtual Server**.
4. Forward to the host's local IPv4 address:
   - **TCP 3000**, so clients and administrators can reach the gateway.
   - **UDP 7777–7877**, or just the individual ports shown on the Game Servers page. A router that
     supports ranges can forward the whole range in one rule.
   - Do **not** forward UDP 3002.
5. Give players the public address. They reach the deployment through the gateway:

```text
http://PUBLIC_IP:3000/api
```

If a TLS reverse proxy provides the public API, also set, for example,
`SERVER_MANAGER_PUBLIC_API_URL=https://games.example.com/api`. When this setting is blank, every
managed server derives its API URL from the deployment address and `NETWORK_DISCOVERY_API_PORT`.

Do not share the router password. Reserve the host computer's local IP in the router so the
forwarding rules keep working after its address changes.

## Alternatives to port forwarding

- **Mesh VPN:** the host and every player join the same private network using software such as
  Tailscale, ZeroTier, Radmin VPN, or Hamachi. Set `SERVER_MANAGER_ADVERTISED_ADDRESS` to the host's
  VPN address and restart the stack. The host firewall must still allow the ports above.
- **Public server host:** run the Backend Servers package on a VPS, cloud machine, or dedicated
  computer with a public IP. Allow the ports in both the operating-system firewall and the provider's
  network firewall or security group.

A mesh VPN is usually simplest for a small private group. A public host is better for an always-online
deployment.

## Running several worlds

Run one managed server per world from the same package; the API allocates a distinct UDP port for
each. Do not extract a second copy of the package to host more worlds. Each deployment fixes host
ports 3000, 3001, and 3002, so two packages cannot run side by side without changing those bindings
first.

Each running world consumes additional CPU and memory. Stop worlds from the panel if the host becomes
slow or players experience lag.

## Optional native Windows server

A `Server/Win64/` folder exists only when the package was built with
`-IncludeWindowsDedicatedServer`. It is for manual native hosting and is not managed by the admin
panel.

1. Open `Server\Win64\ServerLaunchers`.
2. Run the launcher named for the world you want to host, for example `L_World_GW.bat` for Gateway.
   Every residence launcher hosts the same shared residence world; the name only selects where
   players initially arrive.
3. Keep the window open while the server runs. Press `Ctrl+C` to stop it.

The `.ps1` and `.bat` launchers both accept a port, defaulting to 7777:

```powershell
.\L_World_GW.ps1 -Port 7777
```

```bat
L_World_GW.bat -Port 7777
```

Run each world on a different UDP port and allow every port in use. Windows may prompt for network
access the first time; select **Allow access**. If no prompt appears, add an inbound rule for the
server executable on the UDP port in use.

Native servers do not read their address from the admin panel. Edit `Server\Win64\.env` before
starting one:

```dotenv
JWT_KEY=<must match Api/.env>
RESIDE_API_URL=http://localhost:3000/api
RESIDE_INTERNAL_API_URL=http://127.0.0.1:3001/api
RESIDE_ADVERTISED_ADDRESS=203.0.113.10
```

`JWT_KEY` is already generated to match `Api/.env`. Do not change it in only one file, or the API and
the server stop validating each other's tokens. `RESIDE_ADVERTISED_ADDRESS` must be a host name or IP
that players can reach; a loopback address does not work for remote clients. The launchers load `.env`
before starting, and variables already set in the process environment take precedence over the file.

`RESIDE_INTERNAL_API_URL` carries authority traffic — system status, accounts, characters, residences,
bots, backend events, media, presence, hydration, and registration. The packaged default
`http://127.0.0.1:3001/api` works only when the server shares a host with the API, because 3001 is
bound to loopback. A remote native server needs a private, firewall-restricted API endpoint instead.
`RESIDE_API_URL` stays the public address advertised to clients and is the authority fallback when no
internal URL is set. Browser clients only ever receive the public root.

Docker-managed servers need none of this: the API supplies them `http://api:3000/api` on the
deployment's private network, along with their advertised address and allocated port.

## Stopping and data

Run the stop launcher at the package root. It pauses the server manager, removes this deployment's
managed game-server containers, then stops the core services. Database volumes and each server's
`Saved` volume are preserved. Only deleting a server in the panel removes its saved data, and only
`Api/reset-database.*` erases the database.

## Collecting logs

Run `CollectLogs.bat` or `CollectLogs.ps1` on Windows, or `bash ./CollectLogs.sh` on Linux,
immediately after reproducing a problem. Collect before stopping, restarting, upgrading, or deleting
a world, and leave Docker running so managed game-server output remains available. The collector
writes a timestamped zip beside itself even when application logs are unavailable; in that case it
includes diagnostics explaining what could not be read. Archives can contain tokens, URLs, local
paths, and user data; review them before sharing.

## Troubleshooting

**The launcher reports Docker is not ready.** Open Docker Desktop or start Docker Engine, wait until
it reports running, and try again. On Linux, confirm your user can run `docker info`.

**Players cannot reach a game server.** Check that the address on the Game Servers page is one players
can actually route to; a detected LAN address does not work over the internet. Confirm the rule uses
**UDP**, that the port matches the one shown for that world, and that both the host firewall and any
router or cloud firewall allow it.

**Players cannot load the panel or connect at all.** TCP 3000 is likely blocked or not forwarded.

**Port forwarding does not work at all.** Some providers use **CGNAT**, which blocks inbound
forwarding. If the router's WAN address differs from the public IP shown by an IP-checking website,
ask the provider for a public IPv4 address, or use a mesh VPN or a public server host.

Also confirm that the server is still running in the panel, that everyone is using the correct address,
that the forwarding rule points at the host's current local IP, and that security software is not
blocking Docker. Some routers cannot connect back to their own public address, so test from outside
the network.

Only expose the ports you need, and remove forwarding rules when you stop hosting.
