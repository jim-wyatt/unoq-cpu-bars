# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Build-time hooks for the documentation site.

MkDocs loads this file directly from `hooks:` in mkdocs.yml - it is not a
plugin and needs no package, no entry point and no extra dependency. Two jobs,
both of which exist so that the SAME markdown reads correctly in two places:
on GitHub, and on the rendered site the board serves.

    docs/**/*.md  --+--> GitHub renders it raw
                    |
                    +--> this hook --> python-markdown --> Material --> site

Neither transformation is allowed to make the source worse to read. That rules
out the usual approach of writing site-flavoured markdown and accepting that
GitHub shows the syntax as literal text.
"""

from __future__ import annotations

import posixpath
import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover - import-time only, for type checkers
    from mkdocs.config.defaults import MkDocsConfig
    from mkdocs.structure.files import Files
    from mkdocs.structure.pages import Page

# --------------------------------------------------------------------------
# 1. links that point out of docs/
# --------------------------------------------------------------------------
#
# The course talks about source files constantly - `../../mcu/app/src/bars.c`
# and friends. Those paths are correct on GitHub, where the reader is standing
# in the repository. The site is built from docs/ alone and has no such file,
# so a relative link would 404 exactly where a reader is most curious.
#
# Rewriting them to the repository means one dead-ish link class (needs the
# network) instead of another (needs a file that was never shipped). A reader
# offline on the USB drive can still see WHERE to look, which is most of the
# value; a 404 tells them nothing.

_LINK = re.compile(r"(?<!!)\[([^\]]*)\]\(([^)\s]+)(\s+\"[^\"]*\")?\)")
_FENCE = re.compile(r"^\s*(```|~~~)")


def _is_local(target: str) -> bool:
    return not target.startswith(("http://", "https://", "#", "mailto:", "/"))


def _rewrite_target(target: str, page_dir: str, repo_blob: str) -> str:
    """Return `target` unchanged, or an absolute repository URL for it."""
    if not _is_local(target):
        return target
    path, _, anchor = target.partition("#")
    if not path:  # a bare "#anchor" - same page
        return target
    resolved = posixpath.normpath(posixpath.join(page_dir, path))
    if not resolved.startswith("../"):
        return target  # still inside docs/ - MkDocs will resolve and validate it
    return repo_blob + resolved.removeprefix("../") + (f"#{anchor}" if anchor else "")


# --------------------------------------------------------------------------
# 2. GitHub alerts -> Material admonitions
# --------------------------------------------------------------------------
#
# GitHub renders this as a coloured callout:
#
#     > [!TIP]
#     > **Go deeper** - the reference pages have the exact detail.
#
# python-markdown renders it as a blockquote whose first line is the literal
# text "[!TIP]". Material's own syntax (`!!! tip`) has the mirror-image problem:
# GitHub shows the bangs. Converting here means the source keeps the form that
# degrades most gracefully - a plain blockquote - and the site still gets a
# proper admonition.

_ALERT = re.compile(r"^>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$")
_ADMONITION = {
    "NOTE": "note",
    "TIP": "tip",
    "IMPORTANT": "info",
    "WARNING": "warning",
    "CAUTION": "danger",
}


def _convert_alerts(markdown: str) -> str:
    out: list[str] = []
    lines = markdown.splitlines()
    i = 0
    fence = ""
    while i < len(lines):
        line = lines[i]

        # Code blocks are verbatim: a shell transcript may legitimately contain
        # a line that looks like an alert marker.
        opener = _FENCE.match(line)
        if fence:
            out.append(line)
            if opener and line.strip().startswith(fence):
                fence = ""
            i += 1
            continue
        if opener:
            fence = opener.group(1)
            out.append(line)
            i += 1
            continue

        alert = _ALERT.match(line)
        if not alert:
            out.append(line)
            i += 1
            continue

        i += 1
        body: list[str] = []
        while i < len(lines) and lines[i].startswith(">"):
            body.append(lines[i].lstrip(">").removeprefix(" "))
            i += 1
        out.append(f'!!! {_ADMONITION[alert.group(1)]} ""')
        out.append("")
        # Four spaces is the admonition body indent. Blank lines stay blank so
        # a multi-paragraph callout survives the trip.
        out.extend(f"    {b}" if b.strip() else "" for b in body)
        out.append("")
    return "\n".join(out)


# --------------------------------------------------------------------------
# the hook MkDocs calls
# --------------------------------------------------------------------------


def on_page_markdown(
    markdown: str,
    *,
    page: Page,
    config: MkDocsConfig,
    files: Files,  # noqa: ARG001 - part of the MkDocs hook signature
) -> str:
    repo_blob = config.repo_url.rstrip("/") + "/blob/main/"
    page_dir = posixpath.dirname(page.file.src_uri)

    def replace(match: re.Match[str]) -> str:
        label, target, title = match.group(1), match.group(2), match.group(3) or ""
        return f"[{label}]({_rewrite_target(target, page_dir, repo_blob)}{title})"

    # Same fence-awareness as the alert pass: a code sample that shows markdown
    # link syntax must come out the other side unedited.
    out: list[str] = []
    fence = ""
    for line in markdown.splitlines():
        opener = _FENCE.match(line)
        if fence:
            out.append(line)
            if opener and line.strip().startswith(fence):
                fence = ""
            continue
        if opener:
            fence = opener.group(1)
            out.append(line)
            continue
        out.append(_LINK.sub(replace, line))
    return _convert_alerts("\n".join(out))
