/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Render the ```mermaid fences. The library itself is NOT loaded by this file
 * and is not next to it: Material vendors mermaid (the `privacy` plugin turns
 * its CDN reference into a local copy under assets/external/) and emits its own
 * script tag for it. All this file supplies is the call that draws them.
 *
 * WHY NOT MATERIAL'S BUILT-IN INTEGRATION
 * ---------------------------------------
 * Material knows how to render mermaid, and it was doing so - but it fetches
 * the library itself, at a path baked into its shared JavaScript bundle, and
 * neither available form of that path works here:
 *
 *   site_url SET     the `privacy` plugin rewrites it to an ABSOLUTE url on the
 *                    public site, so every page with a diagram fetches the
 *                    library over the network. Dead on the USB drive.
 *   site_url UNSET   it comes out relative - and one bundle is shared by pages
 *                    at different depths, so `assets/external/...` resolves
 *                    correctly only from the site root. Every diagram in this
 *                    course lives under learn/ or reference/, where it 404s.
 *
 * Measured, not guessed: a headless Chromium render of learn/from-power-to-
 * prompt.html reported 0 blocks with `data-processed`, and
 * /learn/assets/external/... returned 404 while /assets/external/... returned
 * 200.
 *
 * `extra_javascript` does not have that problem: Material emits it as a script
 * tag per page, with the right number of ../ for that page's depth. So the
 * library is loaded here instead, and rendering is driven from here too.
 *
 * The one cost is that the file is a checked-in third-party blob (3.5 MB, MIT,
 * listed in docs/third-party.md) rather than something the build fetches. That
 * is the right trade: the whole point of these pages is that they work with no
 * network at all.
 */

(() => {
  let done = false;

  const render = () => {
    if (done) return;
    // The library is loaded by a plain <script> AFTER this file, and its very
    // last statement is the one that publishes the global:
    //
    //   globalThis["mermaid"] = globalThis.__esbuild_esm_mermaid_nm["mermaid"].default
    //
    // So "not defined yet" is the normal state on the first attempt, and the
    // caller below retries rather than giving up. Measured: without the retry,
    // every page reported 0 rendered blocks while the same script and the same
    // library rendered correctly in isolation.
    if (typeof mermaid === "undefined") return;
    done = true;

    // startOnLoad is deliberately off. This script runs on DOMContentLoaded
    // anyway, and leaving mermaid to hook load as well means two passes over
    // the same elements on some browsers.
    mermaid.initialize({
      startOnLoad: false,
      // Match the page, including the reader's light/dark choice. Material puts
      // the scheme on <body data-md-color-scheme>, which is set before this
      // runs.
      theme:
        document.body.getAttribute("data-md-color-scheme") === "slate"
          ? "dark"
          : "default",
      fontFamily: "inherit",
      securityLevel: "strict",
      flowchart: { htmlLabels: true, curve: "basis" },
    });

    const blocks = document.querySelectorAll("pre.mermaid:not([data-processed])");
    if (blocks.length) mermaid.run({ nodes: blocks });
  };

  // Three chances, deliberately. DOMContentLoaded is usually enough; `load`
  // covers a slow parse of a 3.5 MB library; and a short poll covers the case
  // where the theme's own bundle is still doing something to the page. Each is
  // a no-op once one has succeeded.
  document.addEventListener("DOMContentLoaded", render);
  window.addEventListener("load", render);

  let tries = 0;
  const poll = setInterval(() => {
    render();
    if (done || ++tries > 40) clearInterval(poll);
  }, 100);

  render();
})();
