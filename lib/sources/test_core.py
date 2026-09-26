import subprocess

import pytest

from portguardian.core import (
    Listener,
    classify_exposure,
    discover_docker_bindings,
    match_container,
    parse_docker_output,
    parse_listener_output,
)


def test_listener_output_parsing() -> None:
    output = (
        'tcp LISTEN 0 128 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=4321,fd=7))\n'
        "udp UNCONN 0 0 [::]:5353 [::]:*\n"
    )
    listeners = parse_listener_output(output)
    assert listeners == [
        Listener("tcp", "127.0.0.1", 5432, "postgres", 4321),
        Listener("udp", "::", 5353),
    ]


@pytest.mark.parametrize(
    ("address", "expected"),
    [
        ("0.0.0.0", "Network exposed"),
        ("::", "Network exposed"),
        ("127.23.4.5", "Local only"),
        ("::1", "Local only"),
        ("192.168.1.20", "Interface-specific"),
        ("2001:db8::2", "Interface-specific"),
        ("localhost", "Unknown"),
    ],
)
def test_exposure_classification(address: str, expected: str) -> None:
    assert classify_exposure(address) == expected


def test_docker_ipv4_ipv6_and_protocol_parsing() -> None:
    output = (
        '{"ID":"abc123","Names":"web","Ports":"0.0.0.0:8080->80/tcp, [::]:8080->80/tcp"}\n'
        '{"ID":"def456","Names":"dns","Ports":"127.0.0.1:8080->53/udp, [::1]:9090->90/tcp"}'
    )
    bindings = parse_docker_output(output)
    assert [(item.address, item.host_port, item.protocol) for item in bindings] == [
        ("0.0.0.0", 8080, "tcp"),
        ("::", 8080, "tcp"),
        ("127.0.0.1", 8080, "udp"),
        ("::1", 9090, "tcp"),
    ]


def test_tcp_and_udp_same_port_match_separately() -> None:
    bindings = parse_docker_output(
        '{"ID":"tcp1","Names":"web","Ports":"0.0.0.0:53->53/tcp"}\n'
        '{"ID":"udp1","Names":"dns","Ports":"0.0.0.0:53->53/udp"}'
    )
    assert match_container(Listener("tcp", "0.0.0.0", 53), bindings).container_id == "tcp1"
    assert match_container(Listener("udp", "0.0.0.0", 53), bindings).container_id == "udp1"


def test_loopback_binding_does_not_match_wildcard_or_other_interface() -> None:
    bindings = parse_docker_output('{"ID":"abc","Names":"private","Ports":"127.0.0.1:8080->80/tcp"}')
    assert match_container(Listener("tcp", "0.0.0.0", 8080), bindings) is None
    assert match_container(Listener("tcp", "192.168.1.2", 8080), bindings) is None


def test_wildcard_binding_requires_same_address_family() -> None:
    bindings = parse_docker_output('{"ID":"abc","Names":"web","Ports":"[::]:8080->80/tcp"}')
    assert match_container(Listener("tcp", "0.0.0.0", 8080), bindings) is None


def test_exact_binding_matches() -> None:
    bindings = parse_docker_output('{"ID":"abc","Names":"private","Ports":"127.0.0.1:8080->80/tcp"}')
    assert match_container(Listener("tcp", "127.0.0.1", 8080), bindings) == bindings[0]


def test_malformed_docker_output_is_ignored() -> None:
    output = 'not-json\n[]\n{"ID":2,"Ports":null}\n{"ID":"ok","Ports":"broken"}'
    assert parse_docker_output(output) == []


def test_docker_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("portguardian.core.shutil.which", lambda _name: None)
    assert discover_docker_bindings() == []


@pytest.mark.parametrize(
    "error",
    [
        PermissionError(),
        subprocess.TimeoutExpired(["docker"], 1),
        subprocess.CalledProcessError(1, ["docker"]),
    ],
)
def test_docker_unavailable(monkeypatch: pytest.MonkeyPatch, error: Exception) -> None:
    monkeypatch.setattr("portguardian.core.shutil.which", lambda _name: "/usr/bin/docker")

    def fail(*_args: object, **_kwargs: object) -> None:
        raise error

    monkeypatch.setattr("portguardian.core.subprocess.run", fail)
    assert discover_docker_bindings() == []
