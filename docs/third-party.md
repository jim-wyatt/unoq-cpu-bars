# Third-party material

Everything in this repository is MIT-licensed (see [LICENSE](../LICENSE)) **except**
the files listed here, which belong to other projects and keep their own terms.
Each one carries its original licence header — do not replace those with this
project's.

| File | Owner | Licence |
|---|---|---|
| `.vscode/STM32U585.svd` | STMicroelectronics | Apache-2.0 |
| `.clang-format` | The Zephyr Project | Apache-2.0 |

## Derived work

`mcu/app/src/matrix.c` implements the 8×13 LED panel from scratch, but two
facts in it were read out of Arduino's own implementation
([ArduinoCore-zephyr](https://github.com/arduino/ArduinoCore-zephyr),
`loader/matrix.inc`, Apache-2.0): which ordered pin pair lights which LED, and
the 10 µs slot. That wiring is not described anywhere else — not in the UNO Q
datasheet and not in Zephyr's `arduino_uno_q` board definition, which does not
mention the panel at all. The grayscale scheme, the refresh ISR and the
register-level `MODER`/`BSRR` handling are this project's.

## Build-time dependencies

Not redistributed here — you install them yourself, and they are listed for
completeness because the firmware links against them:

| | Licence |
|---|---|
| [Zephyr RTOS](https://github.com/zephyrproject-rtos/zephyr) (+ MCUboot) | Apache-2.0 |
| [OpenOCD](https://openocd.org/) — built by `tools/build-openocd.sh` | GPL-2.0-or-later |
| `pyserial`, `gpiod`, `smpclient` | BSD-3-Clause / LGPL-2.1 / Apache-2.0 |
| [MkDocs](https://www.mkdocs.org/) + [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/) | BSD-2-Clause / MIT |

OpenOCD is GPL. `tools/build-openocd.sh` builds it from upstream source into
`/opt/openocd`; no OpenOCD code is vendored into this repository.

## Inside the site you are reading

This page is part of a site built by Material for MkDocs, and the build copies
some of that project's work into the output. That output ships on the USB drive
and is served over the network, so it is redistribution and belongs here.

| In `share/learn/` | Owner | Licence |
|---|---|---|
| `assets/stylesheets/`, `assets/javascripts/` | Martin Donath (squidfunk) and contributors | MIT |
| `assets/javascripts/lunr/` | The lunr.js authors | MIT |
| `assets/external/unpkg.com/mermaid@11/` | The Mermaid authors | MIT |
| `assets/javascripts/mermaid-init.js` | This project | MIT |
| Icons (inlined as SVG) | Material Design Icons / FontAwesome / Octicons | Apache-2.0 / CC-BY-4.0 / MIT |

The `privacy` plugin is what puts the last two there: it downloads at build
time anything the theme would otherwise fetch from a CDN while the page is
loading, so that a reader with no network still gets a complete site. The
consequence is that the copies travel with the drive, which is the point, and
which is why they are listed.

None of it is in this repository — `share/learn/` is generated output and is in
`.gitignore`. Rebuild it with `tools/build-docs.sh`.

## Downloaded onto your board, never redistributed

`share/fetch-vscode.sh` downloads Microsoft's official Visual Studio Code
installers onto the board so it can hand them to a laptop that has no internet
of its own — over the USB fileshare and over `unoq-learn`.

| | Owner | Terms |
|---|---|---|
| VS Code installers (`.exe`, `.zip`, `.deb`, `.tar.gz`) | Microsoft | [Microsoft Software Licence Terms](https://code.visualstudio.com/license) |

They are **not** in this repository and are not published by this project. They
are fetched from `update.code.visualstudio.com` at the moment you run that
script, onto your own hardware, and land inside `unoq-share.img` which is
likewise not tracked here. Handing them on to other people is redistribution
and is governed by Microsoft's terms, not by this project's MIT licence.

Note that the official builds are not the MIT-licensed `vscode` source — they
add Microsoft-proprietary components. If you would rather ship something freely
redistributable, point the script at [VSCodium](https://vscodium.com/) builds
instead.

## Not included

Earlier revisions of this project kept a `backup/` directory holding Arduino's
stock MCU firmware image, Arduino's `remoteocd` helper binary, and OpenOCD
target configuration files. Those are other people's build artefacts and are
not this project's to redistribute, so they are not published here and have
been removed from the git history.

If you want the stock firmware back on your own board you need your own copy,
taken **before** you purge the Arduino tree — see
[Keep your own copies](../README.md#keep-your-own-copies) in the README for the
commands. `mcu/restore-arduino-firmware.sh` uses it via `STOCK_FW`.
