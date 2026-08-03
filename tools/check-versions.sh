#!/bin/bash
# Audit every toolchain dependency against what is currently released.
#
#   ~/hybrid/tools/check-versions.sh
#
# Extension auto-update is deliberately OFF on this board (it caused background
# churn on 3.6 GiB of RAM), so nothing here updates itself. Run this now and
# then. It only reports - it changes nothing.
#
# THINGS THAT LOOK OUT OF DATE BUT ARE NOT
# ----------------------------------------
#   cbor2 5.x       - `smp` requires >=5.5.1,<6.0.0. Upgrading breaks SMP/FOTA.
#   pydantic-core   - pydantic pins it EXACTLY (==2.46.4). Never bump alone.
#   Zephyr's venv   - Zephyr pins its own tool versions per release; `pip list
#                     --outdated` flags them, but they are deliberate. The
#                     cryptography/setuptools pins people notice live in
#                     requirements-actions.txt, which is CI-only and NOT part
#                     of requirements.txt.
#   OpenOCD         - we build master on purpose: the newest *release* (0.12.0,
#                     2023) predates libgpiod v2, which this board needs.
#   arm64 extensions- the Marketplace "latest" is often x64-only. If a version
#                     bump reports "not found", that build has no linux-arm64
#                     package and you already have the newest usable one.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

gh_latest() { curl -sL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('tag_name','?'))" 2>/dev/null; }

echo "=== Zephyr ==="
printf '  installed %-12s latest %s\n' \
  "$(git -c safe.directory="$HOME/zephyrproject/zephyr" -C "$HOME/zephyrproject/zephyr" describe --tags 2>/dev/null)" \
  "$(gh_latest zephyrproject-rtos/zephyr)"

echo "=== Zephyr SDK ==="
printf '  installed %-12s latest %s\n' \
  "$(basename "$(ls -d "$HOME"/zephyr-sdk-* 2>/dev/null | head -1)" | sed 's/zephyr-sdk-/v/')" \
  "$(gh_latest zephyrproject-rtos/sdk-ng)"

echo "=== host tools (uv-managed) ==="
for p in uv cmake ninja west; do
  cur=$(uv tool list 2>/dev/null | awk -v p="$p" '$1==p {print $2}' | tr -d 'v')
  [ "$p" = uv ] && cur=$(uv --version 2>/dev/null | awk '{print $2}')
  new=$(curl -sL "https://pypi.org/pypi/$p/json" 2>/dev/null \
        | python3 -c "import json,sys;print(json.load(sys.stdin)['info']['version'])" 2>/dev/null)
  flag=""; [ -n "$cur" ] && [ -n "$new" ] && [ "$cur" != "$new" ] && flag="  <-- update"
  printf '  %-8s %-14s latest %s%s\n' "$p" "${cur:-?}" "${new:-?}" "$flag"
done

echo "=== MPU python (~/hybrid/.venv) ==="
uv pip list --python "$HOME/hybrid/.venv/bin/python" --outdated 2>/dev/null | tail -n +3 \
  | sed 's/^/  /' || true
echo "  (cbor2 / pydantic-core here are PINNED - see header, do not upgrade)"

echo "=== Zephyr venv conformance to its own pins ==="
(cd "$HOME/zephyrproject" && uv pip install --python .venv/bin/python \
   -r zephyr/scripts/requirements.txt --dry-run 2>&1 | tail -2 | sed 's/^/  /')

echo "=== VS Code extensions vs Marketplace ==="
CODE="$HOME/.vscode-server/cli/servers/Stable-*/server/bin/remote-cli/code"
CODE=$(ls $CODE 2>/dev/null | head -1)
[ -x "$CODE" ] && "$CODE" --list-extensions --show-versions 2>/dev/null > /tmp/exts.txt
python3 - <<'PY'
import json, urllib.request
try:
    cur = dict(l.rsplit("@",1) for l in open("/tmp/exts.txt").read().split() if "@" in l)
except Exception:
    print("  (could not read extension list)"); raise SystemExit
url="https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"
body={"filters":[{"criteria":[{"filterType":7,"value":k} for k in cur]}],"flags":914}
req=urllib.request.Request(url, json.dumps(body).encode(),
    {"Content-Type":"application/json","Accept":"application/json;api-version=7.1-preview.1"})
try:
    d=json.load(urllib.request.urlopen(req, timeout=60))
    latest={e["publisher"]["publisherName"]+"."+e["extensionName"]: e["versions"][0]["version"]
            for e in d["results"][0]["extensions"]}
    for k,v in sorted(cur.items()):
        L=latest.get(k,"?")
        print(f"  {k:42} {v:14} -> {L}" + ("  <-- try update" if L not in (v,"?") else ""))
    print("  NOTE: a newer version may be x64-only. If `--install-extension id@ver`")
    print("        says 'not found', there is no arm64 build and you are current.")
except Exception as e:
    print("  marketplace query failed:", e)
PY

echo "=== OpenOCD ==="
printf '  installed  %s\n' "$(/opt/openocd/bin/openocd --version 2>&1 | head -1 | cut -d' ' -f1-4)"
printf '  pinned in build-openocd.sh: %s\n' "$(grep -oP 'OPENOCD_COMMIT:-\K[0-9a-f]+' "$HOME/hybrid/tools/build-openocd.sh" 2>/dev/null)"
printf '  upstream master head:       %s\n' \
  "$(curl -sL https://api.github.com/repos/openocd-org/openocd/commits/master 2>/dev/null \
     | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['sha'][:12], d['commit']['committer']['date'][:10])" 2>/dev/null)"

echo
echo "Update extensions with:  code --install-extension <id>@<version> --force"
echo "(plain --force does NOT bump the version)"
