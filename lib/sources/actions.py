"""Validated, explicit destructive operations."""

from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ActionResult:
    success: bool
    message: str


def validate_pid(pid: int) -> None:
    if not isinstance(pid, int) or pid <= 1:
        raise ValueError("Invalid process ID.")


def validate_port(port: int) -> None:
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("Invalid port number.")


def terminate_by_port(port: int, protocol: str) -> ActionResult:
    """Ask PolicyKit to SIGTERM an owner whose PID is hidden from ss."""
    validate_port(port)
    normalized_protocol = protocol.lower()
    if normalized_protocol not in {"tcp", "udp"}:
        raise ValueError("Invalid socket protocol.")
    try:
        result = subprocess.run(
            ["pkexec", "fuser", "-k", "-TERM", "-n", normalized_protocol, str(port)],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired) as exc:
        return ActionResult(False, f"Could not request permission: {exc}")
    if result.returncode == 0:
        return ActionResult(True, "SIGTERM was sent to the socket owner.")
    detail = result.stderr.strip() or result.stdout.strip()
    if result.returncode == 1 and not detail:
        return ActionResult(True, "The socket owner had already stopped.")
    return ActionResult(False, detail or "Permission or termination was denied.")


def terminate_process(pid: int, wait_seconds: float = 2) -> ActionResult:
    """Send SIGTERM, using PolicyKit only if normal permission is denied."""
    validate_pid(pid)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return ActionResult(True, "The process had already stopped.")
    except PermissionError:
        try:
            result = subprocess.run(
                ["pkexec", "kill", "-TERM", str(pid)],
                check=False,
                capture_output=True,
                text=True,
                timeout=15,
            )
        except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired) as exc:
            return ActionResult(False, f"Could not request permission: {exc}")
        if result.returncode != 0:
            detail = result.stderr.strip()
            if "No such process" in detail:
                return ActionResult(True, "The process had already stopped.")
            return ActionResult(False, detail or "Permission or termination was denied.")
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return ActionResult(True, "The process stopped after SIGTERM.")
        except PermissionError:
            break
        time.sleep(0.1)
    return ActionResult(
        False,
        "SIGTERM was sent, but the process is still running. No force-stop was attempted.",
    )


def stop_container(container_id: str) -> ActionResult:
    if not container_id or not all(character.isalnum() or character in "_.-" for character in container_id):
        raise ValueError("Invalid container ID.")
    try:
        result = subprocess.run(
            ["docker", "stop", container_id], check=False, capture_output=True, text=True, timeout=30
        )
    except FileNotFoundError:
        return ActionResult(False, "Docker is not installed or is no longer available.")
    except PermissionError:
        return ActionResult(False, "Permission to run Docker was denied.")
    except subprocess.TimeoutExpired:
        return ActionResult(False, "Docker did not respond before the stop request timed out.")
    if result.returncode == 0:
        return ActionResult(True, "The container stopped.")
    detail = result.stderr.strip() or result.stdout.strip()
    if "No such container" in detail:
        return ActionResult(True, "The container had already stopped.")
    return ActionResult(False, detail or "Docker could not stop the container.")
