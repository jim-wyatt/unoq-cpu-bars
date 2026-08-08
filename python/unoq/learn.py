# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Static web server for the on-board learning content.

    unoq-learn                         # serve /var/lib/unoq-share on :8080
    python -m unoq.learn --root ./share --port 9000

The board is often the only computer in the room with the material on it - it
is plugged into a laptop that may have no internet at all. So this serves from
disk, has no dependencies outside the standard library, and never fetches
anything: a page that needs a CDN is a page that is blank exactly when you
need it.

It is deliberately read-only and unauthenticated. It is reachable over the USB
link (and whatever else the board is on), so treat it as public to anyone who
can plug in a cable - do not put anything here you would not hand out.
"""

from __future__ import annotations

import argparse
import contextlib
import socket
import sys
from collections.abc import Callable
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_ROOT = "/var/lib/unoq-share"
DEFAULT_PORT = 8080
# Every interface: the point is to be reachable over the USB gadget link, whose
# address the board does not know until a host is plugged in.
DEFAULT_HOST = "0.0.0.0"


class QuietHandler(SimpleHTTPRequestHandler):
    """Serve a directory, logging one line per request to stdout.

    SimpleHTTPRequestHandler writes to stderr in a format of its own; under
    systemd that lands in the journal as an error stream, which makes a normal
    page load look like a fault. Routing it to stdout keeps `journalctl` honest
    about what is and is not a problem.
    """

    # Sent on every response. The content is static and the board's clock is
    # often wrong (no battery-backed RTC), so a validator-based cache would
    # misfire; telling the browser not to cache at all is the honest answer.
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    # The parameter is named `format` because that is the base class's
    # signature; renaming it would silently stop overriding the method.
    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.address_string()} {format % args}", flush=True)


def make_server(
    root: str | Path = DEFAULT_ROOT,
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
) -> ThreadingHTTPServer:
    """Build a server rooted at `root`, bound but not yet serving.

    Binding here rather than inside serve() is what lets a test ask for port 0
    and then find out which port it actually got.
    """
    path = Path(root).expanduser()
    if not path.is_dir():
        raise FileNotFoundError(f"{path} is not a directory - nothing to serve")
    handler: Callable[..., SimpleHTTPRequestHandler] = partial(QuietHandler, directory=str(path))
    # Threading, so one slow client fetching a 120 MB installer does not block
    # the page load behind it. allow_reuse_address so a restart does not have
    # to wait out TIME_WAIT on a board you are iterating on.
    ThreadingHTTPServer.allow_reuse_address = True
    return ThreadingHTTPServer((host, port), handler)


def addresses(port: int) -> list[str]:
    """Best-effort list of URLs this board is reachable on.

    Purely informational - it is printed at startup so you can read the address
    off the console instead of guessing what the USB link came up as.
    """
    urls = []
    with contextlib.suppress(OSError):  # no network at all is not an error here
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addr = info[4][0]
            url = f"http://{addr}:{port}/"
            if url not in urls:
                urls.append(url)
    return urls


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-learn",
        description="Serve the on-board learning content and installers over HTTP.",
    )
    parser.add_argument("--root", default=DEFAULT_ROOT, help="directory to serve")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="TCP port")
    parser.add_argument("--host", default=DEFAULT_HOST, help="address to bind")
    args = parser.parse_args(argv)

    try:
        server = make_server(args.root, args.host, args.port)
    except FileNotFoundError as exc:
        print(f"unoq-learn: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        # Almost always "address already in use" - worth saying plainly rather
        # than as a traceback in the journal.
        print(f"unoq-learn: cannot bind {args.host}:{args.port}: {exc}", file=sys.stderr)
        return 1

    bound = server.server_address[1]
    print(f"serving {args.root} on port {bound}", flush=True)
    for url in addresses(bound):
        print(f"  {url}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass  # Ctrl-C and SIGINT are how you stop this, not failures.
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
