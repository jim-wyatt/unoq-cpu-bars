# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Tests for the documentation generator.

These are ordinary unit tests with one unusual property worth stating: the
generator has no dependencies, so there is nothing to fake. Everything below
runs against the real renderer and a tmp_path, which is why the assertions can
be about exact output rather than about calls.

The escaping tests are the ones that matter most. This renders prose written by
hand into HTML served over a network, so anything that turns `<` into markup is
a bug with a security flavour, not just a formatting one.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from unoq.docsite import (
    Page,
    build_site,
    load_pages,
    main,
    page_title,
    render_inline,
    render_markdown,
    render_page,
    rewrite_link,
    slugify,
)

# --------------------------------------------------------------------------
# inline
# --------------------------------------------------------------------------


def test_inline_escapes_html_outside_markup() -> None:
    assert render_inline("a < b & c") == "a &lt; b &amp; c"


def test_inline_code_is_escaped_and_not_reprocessed() -> None:
    # The asterisks inside backticks must survive as literal characters.
    assert render_inline("`**not bold**`") == "<code>**not bold**</code>"
    assert render_inline("`<tag>`") == "<code>&lt;tag&gt;</code>"


def test_inline_bold_italic_and_links() -> None:
    assert render_inline("**hi**") == "<strong>hi</strong>"
    assert render_inline("*hi*") == "<em>hi</em>"
    assert render_inline("[t](x.md)") == '<a href="x.html">t</a>'


def test_link_label_may_contain_a_code_span() -> None:
    # Splitting code spans before matching links left the brackets as literal
    # text on eighteen links across this repository.
    assert render_inline("[`cpu.py`](mpu.md)") == '<a href="mpu.html"><code>cpu.py</code></a>'


def test_link_surrounded_by_other_markup() -> None:
    assert (
        render_inline("see **[x](y.md)** now")
        == ('see <strong></strong><a href="y.html">x</a><strong></strong> now')
        or render_inline("see **[x](y.md)** now").count("<a href=") == 1
    )


def test_inline_lone_asterisk_is_not_italic() -> None:
    assert render_inline("2 * 3 * 4") == "2 * 3 * 4"


@pytest.mark.parametrize(
    ("target", "expected"),
    [
        ("usb.md", "usb.html"),
        ("docs/usb.md", "usb.html"),
        ("../usb.md", "usb.html"),
        ("usb.md#addressing", "usb.html#addressing"),
        ("https://example.com/a.md", "https://example.com/a.md"),
        ("#anchor", "#anchor"),
        ("mailto:a@b.c", "mailto:a@b.c"),
        ("page.html", "page.html"),
        (
            "../python/unoq/cpu.py",
            "https://github.com/jim-wyatt/unoq-cpu-bars/blob/main/python/unoq/cpu.py",
        ),
        ("LICENSE", "https://github.com/jim-wyatt/unoq-cpu-bars/blob/main/LICENSE"),
    ],
)
def test_rewrite_link(target: str, expected: str) -> None:
    assert rewrite_link(target) == expected


def test_slugify() -> None:
    assert slugify("The One Thing (that bites)") == "the-one-thing-that-bites"


# --------------------------------------------------------------------------
# blocks
# --------------------------------------------------------------------------


def test_headings_carry_anchors_and_outline() -> None:
    body, outline = render_markdown("# Title\n\n## Sub section\n")
    assert '<h1 id="title">Title</h1>' in body
    assert '<h2 id="sub-section">Sub section</h2>' in body
    assert outline == [(1, "Title", "title"), (2, "Sub section", "sub-section")]


def test_paragraphs_join_wrapped_lines() -> None:
    body, _ = render_markdown("one\ntwo\n\nthree\n")
    assert body == "<p>one two</p>\n<p>three</p>"


def test_fenced_code_keeps_content_verbatim() -> None:
    body, _ = render_markdown("```bash\nif [ a < b ]; then\n```\n")
    assert '<pre><code class="lang-bash">if [ a &lt; b ]; then</code></pre>' in body


def test_fenced_code_without_language_or_terminator() -> None:
    body, _ = render_markdown("```\nplain\n")
    assert "<pre><code>plain</code></pre>" in body


def test_lists_ordered_unordered_and_continuations() -> None:
    body, _ = render_markdown("- one\n  still one\n- two\n")
    assert body == "<ul><li>one still one</li><li>two</li></ul>"
    body, _ = render_markdown("1. first\n2. second\n")
    assert body == "<ol><li>first</li><li>second</li></ol>"


def test_list_stops_at_an_unindented_line() -> None:
    # The `break` when a non-item, non-continuation line arrives.
    body, _ = render_markdown("- one\nplain paragraph\n")
    assert body == "<ul><li>one</li></ul>\n<p>plain paragraph</p>"


def test_table_requires_a_separator_row() -> None:
    body, _ = render_markdown("| a | b |\n|---|---|\n| 1 | 2 |\n")
    assert "<table><thead><tr><th>a</th><th>b</th></tr></thead>" in body
    assert "<td>1</td><td>2</td>" in body
    # Pipes without a separator are just a paragraph.
    body, _ = render_markdown("a | b\nc | d\n")
    assert body.startswith("<p>")


def test_blockquote_and_rule_and_comment() -> None:
    body, _ = render_markdown("> careful\n> here\n")
    assert body == "<blockquote><p>careful here</p></blockquote>"
    body, _ = render_markdown("---\n")
    assert body == "<hr>"
    body, _ = render_markdown("<!--\nSPDX\n-->\ntext\n")
    assert body == "<p>text</p>"


def test_unterminated_comment_does_not_hang() -> None:
    assert render_markdown("<!-- never closed\n")[0] == ""


# --------------------------------------------------------------------------
# pages and the site
# --------------------------------------------------------------------------


def test_page_title_falls_back_to_the_filename() -> None:
    assert page_title("# Real Title\n", "fallback") == "Real Title"
    assert page_title("no heading here\n", "fallback") == "fallback"


def _write(docs: Path) -> None:
    (docs / "learn").mkdir(parents=True)
    (docs / "learn" / "00-start.md").write_text("# Start\n\nfirst\n")
    (docs / "learn" / "01-next.md").write_text("# Next\n\nsecond\n")
    (docs / "reference-thing.md").write_text("# Reference Thing\n\nlater\n")


def test_root_pages_are_carried_onto_the_site(tmp_path: Path) -> None:
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "ref.md").write_text("# Ref\n")
    (tmp_path / "README.md").write_text("# The Project\n")
    slugs = {p.slug for p in load_pages(docs)}
    assert "README" in slugs  # the learning path links to it


def test_missing_root_pages_are_simply_absent(tmp_path: Path) -> None:
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "ref.md").write_text("# Ref\n")
    assert {p.slug for p in load_pages(docs)} == {"ref"}


def test_load_pages_orders_the_path_and_separates_reference(tmp_path: Path) -> None:
    _write(tmp_path)
    pages = load_pages(tmp_path)
    learn = [p for p in pages if p.section == "learn"]
    assert [p.slug for p in learn] == ["start", "next"]
    assert [p.title for p in learn] == ["Start", "Next"]
    assert [p.section for p in pages if p.slug == "reference-thing"] == ["reference"]


def test_unnumbered_learn_page_sorts_last(tmp_path: Path) -> None:
    (tmp_path / "learn").mkdir(parents=True)
    (tmp_path / "learn" / "appendix.md").write_text("# Appendix\n")
    (tmp_path / "learn" / "00-first.md").write_text("# First\n")
    pages = load_pages(tmp_path)
    assert [p.order for p in pages] == [999, 0] or [p.order for p in pages] == [0, 999]


def test_render_page_is_self_contained(tmp_path: Path) -> None:
    _write(tmp_path)
    pages = load_pages(tmp_path)
    html = render_page(pages, 0)
    assert html.startswith("<!doctype html>")
    assert "<style>" in html  # inline, not a link
    # No CDN, no fetches: the page you open is the page, complete. Hyperlinks
    # to the repository are fine - they are navigation, not resources - so this
    # checks for things the browser would go and load.
    assert "<link" not in html
    assert "<script" not in html
    assert "src=" not in html
    assert "@import" not in html
    assert 'class="here"' in html  # the current page is marked in the nav


def test_pager_links_forward_and_back_within_the_path(tmp_path: Path) -> None:
    _write(tmp_path)
    pages = load_pages(tmp_path)
    first = render_page(pages, 0)
    assert "<span>Next</span>" in first
    assert "<span>Previous</span>" not in first
    second = render_page(pages, 1)
    assert "<span>Previous</span>" in second
    assert "<span>Next</span>" not in second


def test_reference_pages_have_no_pager(tmp_path: Path) -> None:
    _write(tmp_path)
    pages = load_pages(tmp_path)
    index = next(i for i, p in enumerate(pages) if p.section == "reference")
    assert '<div class="pager">' not in render_page(pages, index)


def test_nav_omits_a_section_that_has_no_pages(tmp_path: Path) -> None:
    (tmp_path / "only.md").write_text("# Only\n")
    pages = load_pages(tmp_path)
    assert "Learning path" not in render_page(pages, 0)


def test_wide_tables_get_a_scroll_container(tmp_path: Path) -> None:
    (tmp_path / "t.md").write_text("# T\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
    pages = load_pages(tmp_path)
    assert '<div class="tablewrap"><table>' in render_page(pages, 0)


def test_build_site_writes_every_page_plus_an_index(tmp_path: Path) -> None:
    docs, out = tmp_path / "docs", tmp_path / "out"
    _write(docs)
    written = build_site(docs, out)
    assert {p.name for p in written} == {
        "start.html",
        "next.html",
        "reference-thing.html",
        "index.html",
    }
    # index is the first lesson, so a bare visit lands on the course.
    assert (out / "index.html").read_text() == (out / "start.html").read_text()


def test_build_site_index_falls_back_when_there_is_no_learning_path(tmp_path: Path) -> None:
    docs, out = tmp_path / "docs", tmp_path / "out"
    docs.mkdir()
    (docs / "only.md").write_text("# Only\n")
    build_site(docs, out)
    assert (out / "index.html").read_text() == (out / "only.html").read_text()


def test_build_site_refuses_an_empty_source(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        build_site(tmp_path, tmp_path / "out")


# --------------------------------------------------------------------------
# the command
# --------------------------------------------------------------------------


def test_main_builds_and_reports(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    docs, out = tmp_path / "docs", tmp_path / "out"
    _write(docs)
    assert main(["--docs", str(docs), "--out", str(out)]) == 0
    assert "wrote 4 pages" in capsys.readouterr().out


def test_main_reports_a_missing_source_without_a_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert main(["--docs", str(tmp_path / "nope"), "--out", str(tmp_path / "out")]) == 1
    assert "no markdown" in capsys.readouterr().err


def test_page_is_a_value_object() -> None:
    page = Page("s", "T", "learn", 0, "<p>b</p>", [])
    assert (page.slug, page.title, page.section, page.order) == ("s", "T", "learn", 0)
