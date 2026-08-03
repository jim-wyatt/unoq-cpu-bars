# The hardware, honestly

The UNO Q is two computers sharing a board.

| | **MPU** (Linux side) | **MCU** (real-time side) |
|---|---|---|
| Part | Qualcomm QRB2210 (`arduino,imola`) | STM32U585 Cortex-M33 |
| Runs | Debian, Python, your services | Zephyr firmware |
| Memory | 3.6 GiB shared | 2 MB flash / 768 KB RAM |
| Reached via | native Linux syscalls | SWD, or a serial link |

Most Arduino-header GPIO is wired to the **MCU**, not the MPU. The MPU has its
own separate GPIO / I²C / SPI — that is what [`unoq`](mpu.md) talks to.

---

## The two GPIOs nobody documents

**Read this before debugging anything.** `arduino-router` used to drive two MPU
GPIO lines the MCU depends on. That service is now disabled, so these must be
set by us — and when they are wrong, a perfectly good board looks broken.

| `gpiochip1` line | Function | Symptom when wrong |
|---|---|---|
| **37** | MCU **BOOT0**, latched at reset | Firmware flashes *and verifies*, but never runs. PC sits around `0x0bf9xxxx` — the STM32 ROM bootloader. |
| **70** | **UART link enable** | MCU transmits fine (`LPUART1 CR1=0x2d`, TC/TXE set) but `/dev/ttyHS1` reads zero bytes. |
| 25 / 26 / 38 | SWD swdio / swclk / srst | — |

```bash
~/hybrid/mcu/link-up.sh      # BOOT0=0, link-enable=1
```

`flash.sh` calls this automatically, and `unoq.MCU` calls it on construction.
`unoq-link.service` applies it at boot.

Pin state **persists after the `gpioset` process exits** — the SoC pinctrl keeps
driving the last value — which is why a one-shot is enough and no daemon is
needed. BOOT0 is only sampled at MCU reset, so set it *before* resetting.

> ### Never `gpioget` these two lines
>
> `gpioget` **requests the line as an input**, and that drops the drive the same
> way a reboot without `unoq-link.service` would. Reading the pins is enough to
> break the link — you get plausible-looking values back (`37=active`,
> `70=inactive`, i.e. exactly the broken state) and the MCU goes quiet.
>
> Check them without touching them. `gpioinfo` only reads line *info*, never
> requests the line:
>
> ```bash
> gpioinfo -c gpiochip1 37 70      # both must say `output`
> hpy -c "from unoq.link import link_state; print(link_state())"
> ```
>
> `output` means driven. `input` means floating — run `link-up.sh`. This is why
> `unoq.link.link_state()` reports *direction* rather than value: there is no way
> to read the value that does not also destroy it.

> `mcu/link-up.sh` is referenced by `/etc/systemd/system/unoq-link.service`.
> **Do not move or rename it** without reinstalling that unit.

---

## The two UARTs

They are **not** interchangeable.

| Node | Pins | Goes to |
|---|---|---|
| `lpuart1` | PG7/PG8 + RTS/CTS on PG6/PG5 | **the Linux MPU** → `/dev/ttyHS1` |
| `usart1` | PB6/PB7 | the Arduino header pins (D0/D1) |

Upstream Zephyr's `arduino_uno_q` board defaults `zephyr,console` to **`usart1`**,
so a stock `hello_world` prints to the *header pins* and you see nothing from
Linux. Override it in a board overlay — see
[`mcu/app/boards/arduino_uno_q.overlay`](../mcu/app/boards/arduino_uno_q.overlay).

The RTS/CTS pair on `lpuart1` is the giveaway: hardware flow control means a
board-to-board link.

---

## The LED matrix

104 blue LEDs in an 8×13 grid, wired to the **MCU** on **PF0–PF10** and
charlieplexed: each LED is one *ordered* pair of those eleven pins, lit by
driving one high, one low, and leaving the other nine as inputs. Eleven pins
give 110 ordered pairs; the panel uses the first 104, in that order.

Upstream Zephyr's `arduino_uno_q` board **does not mention the matrix at all**,
and neither does the datasheet. The wiring is recorded in exactly one place —
Arduino's own core (`ArduinoCore-zephyr`, `loader/matrix.inc`) — which is where
this project's pin map and 10 µs refresh slot come from. Nothing else from that
core is used; the driver is
[`mcu/app/src/matrix.c`](../mcu/app/src/matrix.c) and the devicetree nodes it
needs (`gpiof`, `timers17`) are declared in the app's board overlay.

PF11–PF15 are *not* part of the panel — PF14/PF15 reach the Arduino header — so
the driver masks only the low eleven pins when it tri-states the port.

See [cpu-bars.md](cpu-bars.md) for the display built on this.

## How the MPU flashes the MCU

There is no external debug probe. The MPU bit-bangs SWD on its own GPIO lines
using OpenOCD's `linuxgpiod` driver:

```
Info : Linux GPIOD JTAG/SWD bitbang driver (libgpiod v2)
Info : SWD DPIDR 0x0be12477
Info : [stm32u5.cpu] Cortex-M33 r0p4 processor detected
```

No root needed — your user is in the `gpiod` group.

> **`/opt/openocd` is owned by no Debian package.** `dpkg -S /opt/openocd` finds
> nothing; it was placed there by an install script, so apt will never reinstall
> it. A verified copy is in `backup/opt-openocd`, and it is reproducible from
> source — see [maintenance.md](maintenance.md).

`apt install openocd` does **not** substitute: Debian ships 0.12.0 (2023), which
predates the libgpiod v2 support this board needs.

---

## Flash layout

```
0x08000000  boot_partition   64K   MCUboot (38K used)
0x08010000  slot0           416K   running signed app
0x08078000  slot1           416K   staged update
0x080e0000  storage         128K   NVS (settings, boot counter)
```

Images link at `0x08010000` and must be **signed** — MCUboot refuses a raw
image. See [mcu.md](mcu.md).
