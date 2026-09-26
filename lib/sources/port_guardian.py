#!/usr/bin/env python3
"""GTK application for Port Guardian."""
from __future__ import annotations

import logging
import sys
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk

from portguardian.actions import (
    ActionResult,
    stop_container,
    terminate_by_port,
    terminate_process,
    validate_port,
)
from portguardian.core import Listener, discover_listeners

APP_ID = "io.github.kassemyahia.PortGuardian"
LOGGER = logging.getLogger(__name__)


class PortGuardianWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application) -> None:
        super().__init__(application=app, title="Port Guardian")
        self.set_default_size(980, 640)
        self.entries: list[Listener] = []
        self.admin_scan = False
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)
        header = Adw.HeaderBar()
        root.append(header)
        header.set_title_widget(Adw.WindowTitle(title="Port Guardian", subtitle="Listening socket viewer"))
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Refresh listening ports")
        refresh.connect("clicked", lambda *_: self.refresh())
        header.pack_start(refresh)
        admin = Gtk.Button(label="Admin Scan", tooltip_text="Ask for permission to reveal hidden owners")
        admin.connect("clicked", lambda *_: self.refresh(admin=True))
        header.pack_start(admin)
        self.search = Gtk.SearchEntry(
            placeholder_text="Filter by port, process, address, exposure, or source"
        )
        self.search.connect("search-changed", lambda *_: self.render())
        root.append(self.search)
        self.status = Gtk.Label(xalign=0)
        self.status.add_css_class("dim-label")
        self.status.set_margin_start(18)
        self.status.set_margin_end(18)
        self.status.set_margin_top(10)
        self.status.set_margin_bottom(8)
        root.append(self.status)
        scroller = Gtk.ScrolledWindow(vexpand=True)
        root.append(scroller)
        self.listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.listbox.add_css_class("boxed-list")
        self.listbox.set_margin_start(14)
        self.listbox.set_margin_end(14)
        self.listbox.set_margin_bottom(14)
        scroller.set_child(self.listbox)
        self.refresh()

    def refresh(self, admin: bool | None = None) -> None:
        if admin is not None:
            self.admin_scan = admin
        self.status.set_text("Scanning listening sockets…")
        threading.Thread(target=self._discover, daemon=True).start()

    def _discover(self) -> None:
        try:
            entries, error = discover_listeners(self.admin_scan), None
        except RuntimeError as exc:
            entries, error = [], str(exc)
        except Exception:
            LOGGER.exception("Unexpected listener discovery failure")
            entries, error = [], "An unexpected error occurred while reading listeners."
        GLib.idle_add(self._finish_refresh, entries, error)

    def _finish_refresh(self, entries: list[Listener], error: str | None) -> bool:
        self.entries = entries
        if error:
            self.status.set_text(f"Could not read listening sockets: {error}")
        else:
            mode = "admin" if self.admin_scan else "normal"
            self.status.set_text(
                f"{len(entries)} listening sockets ({mode} scan). Docker integration is optional."
            )
        self.render()
        return False

    def render(self) -> None:
        while child := self.listbox.get_first_child():
            self.listbox.remove(child)
        query = self.search.get_text().strip().lower()
        visible = [entry for entry in self.entries if self.matches(entry, query)]
        if not visible:
            row = Gtk.ListBoxRow(selectable=False)
            label = Gtk.Label(label="No matching listening sockets.", xalign=0)
            label.set_margin_top(20)
            label.set_margin_bottom(20)
            label.set_margin_start(18)
            row.set_child(label)
            self.listbox.append(row)
        for entry in visible:
            self.listbox.append(self.row_for(entry))

    @staticmethod
    def matches(entry: Listener, query: str) -> bool:
        text = (
            f"{entry.protocol} {entry.address} {entry.port} {entry.process} "
            f"{entry.pid or ''} {entry.source} {entry.exposure}"
        ).lower()
        return not query or query in text

    def row_for(self, entry: Listener) -> Gtk.ListBoxRow:
        row = Gtk.ListBoxRow(selectable=False)
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        box.set_margin_top(12)
        box.set_margin_bottom(12)
        box.set_margin_start(14)
        box.set_margin_end(14)
        row.set_child(box)
        port = Gtk.Label(label=str(entry.port), width_chars=6, xalign=0)
        port.add_css_class("title-3")
        box.append(port)
        details = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        box.append(details)
        title = Gtk.Label(label=f"{entry.protocol.upper()}  {entry.address}:{entry.port}", xalign=0)
        title.add_css_class("heading")
        details.append(title)
        owner = str(entry.pid) if entry.pid else "owner hidden"
        subtitle = Gtk.Label(
            label=f"{entry.process} · {entry.source} · {owner} · Exposure: {entry.exposure}",
            xalign=0,
        )
        subtitle.add_css_class("dim-label")
        subtitle.set_ellipsize(3)
        details.append(subtitle)
        stop = Gtk.Button(label="Stop")
        stop.add_css_class("destructive-action")
        stop.set_sensitive(True)
        stop.set_tooltip_text("Stop this container or process gracefully")
        stop.connect("clicked", lambda *_: self.confirm_stop(entry))
        box.append(stop)
        return row

    def confirm_stop(self, entry: Listener) -> None:
        if entry.container_id:
            identity = f"Docker container {entry.container_name} ({entry.container_id[:12]})"
        elif entry.pid:
            identity = f"process {entry.process} (PID {entry.pid})"
        else:
            identity = "the process owning this socket (PID hidden)"
        body = (
            f"Stop {identity}?\n\n"
            f"Listening socket: {entry.address}:{entry.port}/{entry.protocol}\n\n"
            "Processes receive SIGTERM; Port Guardian never silently sends SIGKILL."
        )
        dialog = Adw.AlertDialog(heading="Stop listener owner?", body=body)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("stop", "Stop")
        dialog.set_response_appearance("stop", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.connect(
            "response",
            lambda _dialog, response: self._start_stop(entry) if response == "stop" else None,
        )
        dialog.present(self)

    def _start_stop(self, entry: Listener) -> None:
        threading.Thread(target=self._stop, args=(entry,), daemon=True).start()

    def _stop(self, entry: Listener) -> None:
        try:
            validate_port(entry.port)
            if entry.container_id:
                result = stop_container(entry.container_id)
            elif entry.pid:
                result = terminate_process(entry.pid)
            else:
                result = terminate_by_port(entry.port, entry.protocol)
        except ValueError as exc:
            result = ActionResult(False, str(exc))
        except Exception:
            LOGGER.exception("Unexpected stop failure")
            result = ActionResult(False, "An unexpected error occurred while stopping the target.")
        GLib.idle_add(self._finish_stop, result)

    def _finish_stop(self, result: ActionResult) -> bool:
        self.show_message("Stopped" if result.success else "Stop failed", result.message)
        if result.success:
            self.refresh()
        return False

    def show_message(self, heading: str, body: str) -> None:
        dialog = Adw.AlertDialog(heading=heading, body=body)
        dialog.add_response("ok", "OK")
        dialog.present(self)


class PortGuardianApp(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self) -> None:
        window = self.props.active_window or PortGuardianWindow(self)
        window.present()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    return PortGuardianApp().run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
