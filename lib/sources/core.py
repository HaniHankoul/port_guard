"""Listener discovery, Docker parsing, and address correlation."""

from __future__ import annotations

import ipaddress
import json
import logging
import re
import shutil
import subprocess
from dataclasses import dataclass

LOGGER = logging.getLogger(__name__)
PROCESS_RE = re.compile(r'users:\(\("([^"]+)",pid=(\d+)')
DOCKER_PORT_RE = re.compile(
    r"(?:^|,\s*)(?P<host>\[[^]]+\]|[^:,\s]+):(?P<host_port>\d+)"
    r"->(?P<container_port>\d+)/(?P<protocol>tcp|udp)(?=,|$)",
    re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class ContainerBinding:
    address: str
    host_port: int
    protocol: str
    container_id: str
    container_name: str


@dataclass(frozen=True, slots=True)
class Listener:
    protocol: str
    address: str
    port: int
    process: str = "-"
    pid: int | None = None
    container_id: str | None = None
    container_name: str | None = None

    @property
    def exposure(self) -> str:
        return classify_exposure(self.address)

    @property
    def source(self) -> str:
        return f"Docker: {self.container_name}" if self.container_name else "Process"


def normalize_address(value: str) -> str | None:
    """Return a canonical IP string, accepting brackets and IPv6 zone suffixes."""
    address = value.strip()
    if address.startswith("[") and address.endswith("]"):
        address = address[1:-1]
    if address == "*":
        return None
    address = address.split("%", 1)[0]
    try:
        return str(ipaddress.ip_address(address))
    except ValueError:
        return None


def classify_exposure(address: str) -> str:
    normalized = normalize_address(address)
    if normalized is None:
        return "Unknown"
    parsed = ipaddress.ip_address(normalized)
    if parsed.is_loopback:
        return "Local only"
    if parsed.is_unspecified:
        return "Network exposed"
    return "Interface-specific"


def parse_endpoint(endpoint: str) -> tuple[str, int] | None:
    value = endpoint.strip()
    if value.startswith("["):
        match = re.fullmatch(r"\[([^]]+)]:(\d+)", value)
        return (match.group(1), int(match.group(2))) if match else None
    if ":" not in value:
        return None
    host, raw_port = value.rsplit(":", 1)
    if not raw_port.isdigit() or not 0 <= int(raw_port) <= 65535:
        return None
    return host, int(raw_port)


def parse_listener_output(output: str) -> list[Listener]:
    listeners: list[Listener] = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        protocol = parts[0].lower()
        if protocol not in {"tcp", "udp"}:
            continue
        endpoint = parse_endpoint(parts[4])
        if endpoint is None:
            continue
        address, port = endpoint
        process_match = PROCESS_RE.search(" ".join(parts[5:]))
        process = process_match.group(1) if process_match else "-"
        pid = int(process_match.group(2)) if process_match else None
        listeners.append(Listener(protocol, address, port, process, pid))
    return listeners


def parse_docker_output(output: str) -> list[ContainerBinding]:
    bindings: list[ContainerBinding] = []
    for line in output.splitlines():
        try:
            item = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(item, dict):
            continue
        container_id = item.get("ID")
        ports = item.get("Ports")
        if not isinstance(container_id, str) or not container_id or not isinstance(ports, str):
            continue
        name_value = item.get("Names")
        name = name_value if isinstance(name_value, str) and name_value else container_id[:12]
        for match in DOCKER_PORT_RE.finditer(ports):
            address = normalize_address(match.group("host"))
            host_port = int(match.group("host_port"))
            if address is None or not 0 <= host_port <= 65535:
                continue
            bindings.append(
                ContainerBinding(address, host_port, match.group("protocol").lower(), container_id, name)
            )
    return bindings


def discover_docker_bindings(timeout: float = 5) -> list[ContainerBinding]:
    if shutil.which("docker") is None:
        return []
    try:
        result = subprocess.run(
            ["docker", "ps", "--format", "{{json .}}"],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, UnicodeError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
        return []
    return parse_docker_output(result.stdout)


def match_container(listener: Listener, bindings: list[ContainerBinding]) -> ContainerBinding | None:
    address = normalize_address(listener.address)
    if address is None:
        return None
    candidates = [
        binding
        for binding in bindings
        if binding.host_port == listener.port and binding.protocol == listener.protocol.lower()
    ]
    exact = [binding for binding in candidates if binding.address == address]
    if len(exact) == 1:
        return exact[0]
    # Some ss versions report a wildcard family differently. Only correlate
    # wildcard-to-wildcard, never a loopback or interface address to a wildcard.
    listener_ip = ipaddress.ip_address(address)
    wildcard = [
        binding
        for binding in candidates
        if (binding_ip := ipaddress.ip_address(binding.address)).is_unspecified
        and binding_ip.version == listener_ip.version
    ]
    if listener_ip.is_unspecified and len(wildcard) == 1:
        return wildcard[0]
    return None


def correlate_containers(
    listeners: list[Listener], bindings: list[ContainerBinding]
) -> list[Listener]:
    correlated: list[Listener] = []
    for listener in listeners:
        binding = match_container(listener, bindings)
        if binding is None:
            correlated.append(listener)
        else:
            correlated.append(
                Listener(
                    listener.protocol,
                    listener.address,
                    listener.port,
                    binding.container_name,
                    listener.pid,
                    binding.container_id,
                    binding.container_name,
                )
            )
    return correlated


def discover_listeners(admin: bool = False, timeout: float = 15) -> list[Listener]:
    command = ["ss", "-H", "-ltnup"]
    if admin:
        command = ["pkexec", *command]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as exc:
        raise RuntimeError("The required 'ss' command was not found.") from exc
    except PermissionError as exc:
        raise RuntimeError("Permission was denied while reading listeners.") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("Listener discovery timed out.") from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() if exc.stderr else "listener discovery failed"
        raise RuntimeError(detail) from exc
    listeners = parse_listener_output(result.stdout)
    return sorted(
        correlate_containers(listeners, discover_docker_bindings()),
        key=lambda item: (item.port, item.protocol, item.address),
    )
