# Port Guardian

Port Guardian is a small Fedora/GNOME utility for viewing listening TCP and UDP sockets and safely stopping their owning processes or Docker containers.

## Features

- Lists TCP and UDP listeners with addresses, ports, processes, and PIDs when available.
- Searches across listener details, ownership, source, and exposure.
- Correlates Docker publications by normalized address, host port, and protocol.
- Labels listeners as local-only, network-exposed, interface-specific, or unknown.
- Confirms stop actions, prefers SIGTERM, and refreshes after success.
- Keeps Docker optional and uses PolicyKit only when an action needs elevated permission.

## Screenshot / demo

> Screenshot placeholder: maintainer, add a real screenshot to `docs/` and replace this note.

## Installation

Install runtime dependencies on Fedora:

```bash
sudo dnf install python3 python3-gobject gtk4 libadwaita iproute polkit psmisc
```

Then install Port Guardian for the current user (no `sudo`):

```bash
./install.sh
```

The installer copies the application under `${XDG_DATA_HOME:-$HOME/.local/share}`, adds a desktop entry and icon, and creates `$HOME/.local/bin/port-guardian`. Ensure `$HOME/.local/bin` is in `PATH` to invoke the command by name.

## Uninstallation

From a repository checkout, run:

```bash
./uninstall.sh
```

It removes only the files installed by this project for the current user.

## Dependencies

Required runtime dependencies are Python 3.11+, PyGObject, GTK 4, libadwaita, `ss` from `iproute`, `pkexec` from `polkit`, and `fuser` from `psmisc` for a privileged SIGTERM when a PID is hidden. Docker is optional; install and configure Docker separately only if container correlation is wanted.

Development and test tools:

```bash
sudo dnf install python3-pytest python3-ruff desktop-file-utils
```

## Usage

Launch **Port Guardian** from GNOME or run `port-guardian`. Refresh performs a normal unprivileged scan. **Admin Scan** invokes `ss` through PolicyKit so ownership hidden from the current user may become visible. Search filters the current results.

### Exposure indicator

- **Local only:** IPv4 loopback (`127.0.0.0/8`) or IPv6 loopback (`::1`).
- **Network exposed:** an IPv4 or IPv6 wildcard (`0.0.0.0` or `::`).
- **Interface-specific:** another recognized IP address.
- **Unknown:** an address that cannot be interpreted safely.

This is a bind-address classification, not proof that a service is externally reachable. Firewalls, routing, namespaces, container configuration, and other network rules can still prevent access.

### Docker behavior

Docker discovery is best-effort and non-blocking. Port Guardian continues showing ordinary listeners if Docker is missing, stopped, inaccessible, slow, or returns malformed output. To avoid false ownership, uncertain Docker matches are left unassociated.

### Safety notes

Every stop requires confirmation and identifies the target and socket. Processes receive SIGTERM first; Port Guardian does not silently escalate to SIGKILL. PolicyKit is requested only if the current user cannot signal a process. Docker containers are stopped explicitly with `docker stop`. Targets that disappear during an action are treated as already stopped.

## Known limitations

- Process details depend on what `ss` permits the current user to see.
- The exposure label does not inspect firewall or routing policy.
- One listener represented by several ambiguous Docker publications is intentionally not attributed.
- There is no force-stop UI; use an administrative tool manually after reviewing a stubborn process.

## Development

Run directly from any working directory:

```bash
./run.sh
```

Core discovery and action code lives in `portguardian/`; GTK UI code remains in `port_guardian.py`. Tests use fixtures and mocks, so they need no display, Docker daemon, root access, or host listener state.

## Testing and linting

```bash
pytest
ruff check .
ruff format --check .
bash -n install.sh uninstall.sh run.sh
```

## License

Port Guardian is available under the [MIT License](LICENSE).
