# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Render the repository's markdown into the static site the board serves.

    unoq-build-docs                    # docs/ -> share/learn/
    python -m unoq.docsite --out /tmp/site

WHY A GENERATOR AND NOT HAND-WRITTEN HTML
-----------------------------------------
The same words have to reach a reader three ways: on GitHub, over the board's
web server, and off the USB drive when the laptop has no internet at all. Write
them once as markdown and render; write them twice and the drive and the web
page start disagreeing about what this board does, which is the one thing
`share/build-image.sh` already goes out of its way to prevent.

WHY NO MARKDOWN LIBRARY
-----------------------
Every dependency here is one more thing that has to be installed on a board that
may be offline, kept in step, and trusted. This repository already refuses the
`pre-commit` framework for that reason. The markdown that needs rendering is
ours, so the subset it uses is ours to decide, and a few hundred lines of
straightforward parsing is cheaper to own than a supply chain.

The subset is deliberately small: headings, paragraphs, fenced code, lists,
tables, block quotes, rules, and inline code/bold/italic/links. If a page needs
something outside it, the page is probably trying to be clever.

WHY THE CSS IS INLINE
---------------------
A stylesheet is a second request, and the drive is read by machines that may
never have been on a network. One file per page, no fetches, no fonts, no CDN -
the page you open is the page, complete. It costs a few KB of duplication per
page and buys a site that cannot half-load.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from html import escape
from pathlib import Path

# Where the learning path lives, relative to docs/. Everything else directly
# under docs/ is treated as reference material.
LEARN_DIR = "learn"

# --------------------------------------------------------------------------
# inline markup
# --------------------------------------------------------------------------

_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC = re.compile(r"(?<!\*)\*([^*\s][^*]*)\*(?!\*)")
_CODE_SPLIT = re.compile(r"(`[^`]+`)")


# Where a reader is sent for files the site does not carry - source code, the
# licence, shell scripts. Rendering those as pages too was tempting, but the
# course is prose about code, not a code browser, and the repository is public.
SOURCE_BASE = "https://github.com/jim-wyatt/unoq-cpu-bars/blob/main/"


def rewrite_link(target: str) -> str:
    """Point a markdown link at something that exists.

    Three cases:

    - `.md` becomes `.html`. The site is flat - every page lands in one
      directory - so `docs/usb.md`, `../usb.md` and `usb.md` all mean the same
      file and all become `usb.html`.
    - Anything already external, or an in-page anchor, is left alone.
    - Everything else is a repository path the site does not carry:
      `../python/unoq/cpu.py`, `LICENSE`, a shell script. Those become links to
      the repository, because a link that 404s off the drive is worse than one
      that needs the network - the reader can at least see where to look.
    """
    if target.startswith(("http://", "https://", "#", "mailto:")):
        return target
    anchor = ""
    if "#" in target:
        target, _, anchor = target.partition("#")
        anchor = f"#{anchor}"
    if target.endswith(".md"):
        return f"{Path(target).stem}.html{anchor}"
    if target.endswith(".html"):
        return f"{target}{anchor}"
    return SOURCE_BASE + target.lstrip("./").removeprefix("../") + anchor


def _render_plain(text: str) -> str:
    """Everything inline except links: code spans, bold, italic, escaping.

    Code spans are split out first and escaped without further processing, so
    that `**not bold**` inside backticks survives as literal asterisks - which
    matters constantly in a document about shell and C.
    """
    out: list[str] = []
    for part in _CODE_SPLIT.split(text):
        if len(part) > 1 and part.startswith("`") and part.endswith("`"):
            out.append(f"<code>{escape(part[1:-1])}</code>")
            continue
        piece = escape(part)
        piece = _BOLD.sub(r"<strong>\1</strong>", piece)
        piece = _ITALIC.sub(r"<em>\1</em>", piece)
        out.append(piece)
    return "".join(out)


def render_inline(text: str) -> str:
    """Render inline markup, escaping everything that is not markup.

    Links are matched FIRST, on the raw text, and their label is then rendered
    like any other run. Doing it the other way round - code spans first - splits
    ``[`unoq/cpu.py`](mpu.md)`` into three pieces before the link pattern ever
    sees it, so the brackets survive into the page as literal text. Eighteen
    links across this repository were rendering that way, because naming a file
    in a link label is the single most natural thing to write in these docs.
    """
    out: list[str] = []
    pos = 0
    for match in _LINK.finditer(text):
        out.append(_render_plain(text[pos : match.start()]))
        href = escape(rewrite_link(match.group(2)))
        out.append(f'<a href="{href}">{_render_plain(match.group(1))}</a>')
        pos = match.end()
    out.append(_render_plain(text[pos:]))
    return "".join(out)


def slugify(text: str) -> str:
    """An anchor id for a heading, so the nav can link into a page."""
    cleaned = re.sub(r"[^a-z0-9\s-]", "", text.lower())
    return re.sub(r"[\s-]+", "-", cleaned).strip("-")


# --------------------------------------------------------------------------
# block markup
# --------------------------------------------------------------------------


@dataclass
class _Reader:
    """Lines plus a cursor. A tiny class, but it keeps every block handler
    from having to pass an index back and forth and get it wrong once."""

    lines: list[str]
    i: int = 0

    def done(self) -> bool:
        return self.i >= len(self.lines)

    def peek(self) -> str:
        return self.lines[self.i] if not self.done() else ""

    def take(self) -> str:
        line = self.lines[self.i]
        self.i += 1
        return line


def _render_table(reader: _Reader) -> str:
    """A pipe table: header row, a dashed separator, then body rows."""
    header = [c.strip() for c in reader.take().strip().strip("|").split("|")]
    reader.take()  # the |---|---| separator, already validated by the caller
    rows: list[list[str]] = []
    while not reader.done() and "|" in reader.peek() and reader.peek().strip():
        rows.append([c.strip() for c in reader.take().strip().strip("|").split("|")])
    head = "".join(f"<th>{render_inline(c)}</th>" for c in header)
    body = "".join(
        "<tr>" + "".join(f"<td>{render_inline(c)}</td>" for c in row) + "</tr>" for row in rows
    )
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def _render_list(reader: _Reader, ordered: bool) -> str:
    """A list, taking continuation lines as part of the preceding item."""
    pattern = re.compile(r"^\s*\d+\.\s+(.*)$" if ordered else r"^\s*[-*]\s+(.*)$")
    items: list[str] = []
    while not reader.done():
        match = pattern.match(reader.peek())
        if match:
            reader.take()
            items.append(match.group(1))
        elif items and reader.peek().startswith(("  ", "\t")) and reader.peek().strip():
            items[-1] += " " + reader.take().strip()
        else:
            break
    tag = "ol" if ordered else "ul"
    body = "".join(f"<li>{render_inline(item)}</li>" for item in items)
    return f"<{tag}>{body}</{tag}>"


def render_markdown(text: str) -> tuple[str, list[tuple[int, str, str]]]:
    """Render markdown to HTML.

    Returns the body and the heading outline as (level, text, anchor), which is
    what the per-page contents list is built from.
    """
    reader = _Reader(text.splitlines())
    out: list[str] = []
    outline: list[tuple[int, str, str]] = []
    paragraph: list[str] = []

    def flush() -> None:
        if paragraph:
            out.append(f"<p>{render_inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    while not reader.done():
        line = reader.peek()
        stripped = line.strip()

        # HTML comments: the SPDX header every file in this repo carries.
        if stripped.startswith("<!--"):
            flush()
            while not reader.done() and "-->" not in reader.take():
                pass
            continue

        if not stripped:
            flush()
            reader.take()
            continue

        if stripped.startswith("```"):
            flush()
            lang = reader.take().strip()[3:].strip()
            code: list[str] = []
            while not reader.done() and not reader.peek().strip().startswith("```"):
                code.append(reader.take())
            if not reader.done():
                reader.take()
            cls = f' class="lang-{escape(lang)}"' if lang else ""
            out.append(f"<pre><code{cls}>{escape(chr(10).join(code))}</code></pre>")
            continue

        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading:
            flush()
            reader.take()
            level = len(heading.group(1))
            title = heading.group(2).strip()
            anchor = slugify(title)
            outline.append((level, title, anchor))
            out.append(f'<h{level} id="{anchor}">{render_inline(title)}</h{level}>')
            continue

        if re.match(r"^(-{3,}|\*{3,}|_{3,})$", stripped):
            flush()
            reader.take()
            out.append("<hr>")
            continue

        if stripped.startswith(">"):
            flush()
            quote: list[str] = []
            while not reader.done() and reader.peek().strip().startswith(">"):
                quote.append(reader.take().strip().lstrip(">").strip())
            out.append(f"<blockquote><p>{render_inline(' '.join(quote))}</p></blockquote>")
            continue

        # A table needs a separator row underneath it, or it is just a
        # paragraph that happens to contain pipes.
        if "|" in line and reader.i + 1 < len(reader.lines):
            nxt = reader.lines[reader.i + 1]
            if re.match(r"^\s*\|?[\s:-]*-[\s|:-]*$", nxt) and "|" in nxt:
                flush()
                out.append(_render_table(reader))
                continue

        if re.match(r"^\s*[-*]\s+", line):
            flush()
            out.append(_render_list(reader, ordered=False))
            continue

        if re.match(r"^\s*\d+\.\s+", line):
            flush()
            out.append(_render_list(reader, ordered=True))
            continue

        paragraph.append(stripped)
        reader.take()

    flush()
    return "\n".join(out), outline


# --------------------------------------------------------------------------
# pages
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Page:
    """One rendered page and where it sits in the navigation."""

    slug: str
    title: str
    section: str
    order: int
    body: str
    outline: list[tuple[int, str, str]]


def page_title(text: str, fallback: str) -> str:
    """The first level-1 heading, or the filename if the page has none."""
    for line in text.splitlines():
        match = re.match(r"^#\s+(.*)$", line.strip())
        if match:
            return match.group(1).strip()
    return fallback


def _order_and_name(stem: str) -> tuple[int, str]:
    """`03-two-computers` sorts as 3 and is titled from the rest.

    The number is a sequencing device for the author, not something a reader
    should have to see in a URL or a nav entry.
    """
    match = re.match(r"^(\d+)[-_](.*)$", stem)
    if match:
        return int(match.group(1)), match.group(2)
    return 999, stem


# Repository-root pages worth carrying onto the board. The learning path links
# to both, so without them the site has dead links - and the README is the one
# page that explains what the project as a whole is.
ROOT_PAGES = ("README.md", "THIRD-PARTY.md")


def load_pages(docs: Path) -> list[Page]:
    """Read docs/learn/*.md as the learning path and docs/*.md as reference."""
    pages: list[Page] = []
    for path in sorted((docs / LEARN_DIR).glob("*.md")):
        order, name = _order_and_name(path.stem)
        text = path.read_text(encoding="utf-8")
        body, outline = render_markdown(text)
        pages.append(Page(name, page_title(text, name), "learn", order, body, outline))
    reference = sorted(docs.glob("*.md"))
    reference += [p for name in ROOT_PAGES if (p := docs.parent / name).is_file()]
    for path in reference:
        text = path.read_text(encoding="utf-8")
        body, outline = render_markdown(text)
        pages.append(Page(path.stem, page_title(text, path.stem), "reference", 500, body, outline))
    return pages


# --------------------------------------------------------------------------
# the page shell
# --------------------------------------------------------------------------

# No web fonts: they are a network request, and this site is read on machines
# that may never have had one. The system stack looks native everywhere and
# costs nothing.
STYLE = """
:root {
  --bg: #ffffff; --fg: #1c2024; --muted: #5b6570; --rule: #e3e8ee;
  --accent: #0b6cbd; --accent-soft: #eaf3fb; --code-bg: #f6f8fa;
  --side: #fbfcfd; --warn-bg: #fff8e6; --warn-edge: #e0a800;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14181c; --fg: #dde3ea; --muted: #93a1b0; --rule: #262d35;
    --accent: #5aa9f0; --accent-soft: #17222d; --code-bg: #1b2127;
    --side: #11151a; --warn-bg: #241f10; --warn-edge: #8a6d1a;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
        "Helvetica Neue", Arial, sans-serif;
}
.wrap { display: flex; align-items: flex-start; max-width: 1180px; margin: 0 auto; }
nav {
  width: 250px; flex: 0 0 250px; padding: 28px 18px 60px; background: var(--side);
  border-right: 1px solid var(--rule); position: sticky; top: 0; max-height: 100vh;
  overflow-y: auto;
}
nav .brand { font-weight: 700; font-size: 15px; letter-spacing: .01em; display: block;
  color: var(--fg); text-decoration: none; margin-bottom: 4px; }
nav .tag { color: var(--muted); font-size: 12.5px; margin-bottom: 22px; }
nav h3 { font-size: 11px; text-transform: uppercase; letter-spacing: .09em;
  color: var(--muted); margin: 22px 0 8px; }
nav ol { list-style: none; margin: 0; padding: 0; counter-reset: step; }
nav li { margin: 1px 0; }
nav a { display: block; padding: 5px 9px; border-radius: 6px; text-decoration: none;
  color: var(--fg); font-size: 14px; }
nav a:hover { background: var(--accent-soft); }
nav a.here { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
nav ol.steps a::before { counter-increment: step; content: counter(step) ". ";
  color: var(--muted); font-variant-numeric: tabular-nums; }
main { flex: 1 1 auto; min-width: 0; padding: 40px 44px 96px; }
h1, h2, h3, h4 { line-height: 1.25; margin: 1.9em 0 .55em; }
h1 { font-size: 2.05rem; margin-top: 0; letter-spacing: -.015em; }
h2 { font-size: 1.42rem; padding-bottom: .28em; border-bottom: 1px solid var(--rule); }
h3 { font-size: 1.13rem; }
h4 { font-size: 1rem; color: var(--muted); }
p, ul, ol, table, pre, blockquote { margin: 0 0 1.05em; }
a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }
ul, ol { padding-left: 1.4em; }
li { margin: .3em 0; }
code {
  font: 13.5px/1.5 ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  background: var(--code-bg); padding: .14em .38em; border-radius: 4px;
}
pre {
  background: var(--code-bg); border: 1px solid var(--rule); border-radius: 8px;
  padding: 13px 15px; overflow-x: auto;
}
pre code { background: none; padding: 0; font-size: 13px; line-height: 1.55; }
blockquote {
  margin-left: 0; padding: .7em 1em; background: var(--warn-bg);
  border-left: 3px solid var(--warn-edge); border-radius: 0 6px 6px 0;
}
blockquote p { margin: 0; }
.tablewrap { overflow-x: auto; margin-bottom: 1.05em; }
table { border-collapse: collapse; width: 100%; font-size: 14.5px; }
th, td { text-align: left; padding: 7px 11px; border-bottom: 1px solid var(--rule);
  vertical-align: top; }
th { font-size: 12.5px; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); }
hr { border: 0; border-top: 1px solid var(--rule); margin: 2.2em 0; }
.pager { display: flex; justify-content: space-between; gap: 14px; margin-top: 56px;
  padding-top: 20px; border-top: 1px solid var(--rule); font-size: 14.5px; }
.pager a { display: block; padding: 11px 15px; border: 1px solid var(--rule);
  border-radius: 8px; text-decoration: none; max-width: 47%; }
.pager a:hover { border-color: var(--accent); }
.pager span { display: block; color: var(--muted); font-size: 11.5px;
  text-transform: uppercase; letter-spacing: .07em; }
.menu { display: none; }
@media (max-width: 860px) {
  .wrap { display: block; }
  nav { width: auto; max-height: none; position: static; border-right: 0;
        border-bottom: 1px solid var(--rule); }
  main { padding: 26px 20px 70px; }
}
"""


def _nav(pages: list[Page], current: str) -> str:
    """The sidebar. The learning path is numbered by CSS so the author can
    renumber files without every entry needing to be edited."""
    out = [
        '<a class="brand" href="index.html">Arduino UNO Q</a>',
        '<div class="tag">Hybrid MPU + MCU development, from scratch</div>',
    ]
    for section, label, cls in (
        ("learn", "Learning path", "steps"),
        ("reference", "Reference", ""),
    ):
        entries = [p for p in pages if p.section == section]
        if not entries:
            continue
        out.append(f"<h3>{label}</h3>")
        out.append(f'<ol class="{cls}">' if cls else "<ol>")
        for page in entries:
            here = ' class="here"' if page.slug == current else ""
            out.append(f'<li><a href="{page.slug}.html"{here}>{escape(page.title)}</a></li>')
        out.append("</ol>")
    return "\n".join(out)


def _pager(pages: list[Page], index: int) -> str:
    """Previous/next within the learning path, so the site reads as a course
    rather than a pile of pages."""
    learn = [p for p in pages if p.section == "learn"]
    if pages[index].section != "learn":
        return ""
    pos = learn.index(pages[index])
    parts = ['<div class="pager">']
    if pos > 0:
        parts.append(
            f'<a href="{learn[pos - 1].slug}.html"><span>Previous</span>'
            f"{escape(learn[pos - 1].title)}</a>"
        )
    else:
        parts.append("<span></span>")
    if pos < len(learn) - 1:
        parts.append(
            f'<a href="{learn[pos + 1].slug}.html"><span>Next</span>'
            f"{escape(learn[pos + 1].title)}</a>"
        )
    parts.append("</div>")
    return "".join(parts)


def render_page(pages: list[Page], index: int) -> str:
    """One complete, self-contained HTML file."""
    page = pages[index]
    # Tables get a scroll container so a wide one cannot force the whole page
    # sideways on a phone.
    body = page.body.replace("<table>", '<div class="tablewrap"><table>').replace(
        "</table>", "</table></div>"
    )
    return (
        "<!doctype html>\n"
        '<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{escape(page.title)} - Arduino UNO Q</title>\n"
        f"<style>{STYLE}</style>\n</head>\n<body>\n"
        f'<div class="wrap">\n<nav>{_nav(pages, page.slug)}</nav>\n'
        f"<main>\n{body}\n{_pager(pages, index)}\n</main>\n</div>\n</body>\n</html>\n"
    )


def build_site(docs: Path, out: Path) -> list[Path]:
    """Render every page, plus an index that redirects into the first lesson."""
    pages = load_pages(docs)
    if not pages:
        raise FileNotFoundError(f"no markdown found under {docs}")
    out.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for i, page in enumerate(pages):
        target = out / f"{page.slug}.html"
        target.write_text(render_page(pages, i), encoding="utf-8")
        written.append(target)
    first = next((p for p in pages if p.section == "learn"), pages[0])
    index = out / "index.html"
    index.write_text(render_page(pages, pages.index(first)), encoding="utf-8")
    written.append(index)
    return written


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description="Render the docs into a static site.")
    parser.add_argument("--docs", default=str(here / "docs"), help="markdown source directory")
    parser.add_argument("--out", default=str(here / "share" / "learn"), help="output directory")
    args = parser.parse_args(argv)
    try:
        written = build_site(Path(args.docs), Path(args.out))
    except FileNotFoundError as exc:
        print(f"unoq-build-docs: {exc}", file=sys.stderr)
        return 1
    print(f"unoq-build-docs: wrote {len(written)} pages to {args.out}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
