# Maintenance

```bash
~/hybrid/tools/check-versions.sh      # audit everything; reports only
```

Extension auto-update is deliberately **off** (background churn on a 3.6 GiB
board), so nothing updates itself. Run this occasionally.

## Things that look out of date but are not

| | Why |
|---|---|
| `cbor2` 5.x | `smp` requires `>=5.5.1,<6.0.0`. Upgrading breaks SMP/FOTA. |
| `pydantic-core` | `pydantic` pins it **exactly** (`==2.46.4`). Never bump alone. |
| Zephyr's venv | Zephyr pins its own tool versions per release. `pip list --outdated` flags them; they are deliberate. The `cryptography`/`setuptools` pins people spot live in `requirements-actions.txt`, which is **CI-only** and not part of `requirements.txt`. |
| OpenOCD `0.12.0+dev` | We build master on purpose — the newest *release* (0.12.0, 2023) predates libgpiod v2. |
| arm64 extensions | The Marketplace "latest" is frequently x64-only. If `--install-extension id@ver` says *"not found"*, there is no linux-arm64 build and you already have the newest usable one. |

`code --install-extension <id> --force` does **not** bump the version — it
reports "already installed". Name the version explicitly.

## Rebuilding OpenOCD

```bash
sudo bash ~/hybrid/tools/build-openocd.sh              # build + self-test only
sudo bash ~/hybrid/tools/build-openocd.sh --promote    # then replace /opt/openocd
```

`/opt/openocd` is owned by no Debian package, so apt can never reinstall it —
this script removes that as a single point of failure.

It builds **upstream `openocd-org/openocd` master** (pinned, overridable via
`OPENOCD_COMMIT`). Master is required: `configure.ac` checks
`libgpiod >= 2.0` and `linuxgpiod.c` uses the v2 API, while the newest release
predates that. Everything else needed is upstream too — the STM32U5 flash
driver is `stm32l4x` — and the three `.cfg` files live in `backup/mcu-firmware/`.

Only the `jimtcl` submodule is cloned; `libjaylink` is the J-Link probe driver
and `--disable-jlink` means it is never compiled.

The script builds to `/opt/openocd-rebuilt` and **self-tests against the real
MCU** — it must see `Cortex-M33` or it exits non-zero and leaves `/opt/openocd`
alone. `--promote` keeps the old install as `/opt/openocd.<timestamp>`.

All tooling honours `OCD_ROOT`, so you can trial it first:

```bash
OCD_ROOT=/opt/openocd-rebuilt ~/hybrid/mcu/flash.sh \
    ~/zephyrproject/build/zephyr/zephyr.signed.hex
```

## Upgrading Zephyr

After a version bump, re-copy the OpenOCD board support that Zephyr's runner
needs and that is not upstream:

```bash
cp -r ~/hybrid/mcu/board-support/support ~/zephyrproject/zephyr/boards/arduino/uno_q/
```

Also check the SDK requirement — Zephyr's `SDK_VERSION` file states it
(v4.4.x wants SDK 1.0.1; v4.3.0 wanted 0.17.4).

The C style is Zephyr's, copied into this repo the same way, so re-copy it too
and re-run the gate — upstream does change it between releases:

```bash
cp ~/zephyrproject/zephyr/.clang-format ~/hybrid/.clang-format
~/hybrid/tools/check.sh c
```

## Dev tooling

The lint/format/type/test toolchain is installed by script, not by hand:

```bash
~/hybrid/tools/install-dev-tools.sh   # idempotent, no sudo
~/hybrid/tools/check.sh               # run every gate
```

Versions for the Python tools live in `python/pyproject.toml` under the `dev`
extra; `shellcheck` and `shfmt` track upstream's latest release. See
[quality.md](quality.md).

## Backups

`backup/` holds the things that cannot be re-downloaded:

| | |
|---|---|
| `mcu-firmware/` | stock Arduino MCU firmware + the OpenOCD `.cfg` files |
| `opt-openocd/` | a verified copy of `/opt/openocd` (gitignored — it is a binary) |
| `remoteocd` | Arduino's flashing wrapper, kept for reference |

The repo also has an off-board remote. Push after meaningful changes — the
hardware findings in [hardware.md](hardware.md) are not written down anywhere
else.
