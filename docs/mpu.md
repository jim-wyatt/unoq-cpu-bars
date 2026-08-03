# MPU workflow

The Linux side: direct hardware access, the `unoq` package for talking to the
MCU, and the CPU-bars demo that uses both halves of the board at once.

```bash
hpy your_script.py          # alias for ~/hybrid/.venv/bin/python
```

## Direct hardware

The MPU's own GPIO / I²C / SPI — separate from the Arduino headers, which are
wired to the MCU.

```python
import gpiod, smbus2, spidev, serial
```

| Interface | Device | Notes |
|---|---|---|
| GPIO | `/dev/gpiochip0..2` | chip1 has 127 lines; also carries SWD + BOOT0 |
| I²C | `/dev/i2c-0..2` | needs the `i2c` group |
| SPI | `/dev/spidev0.0` | needs the `spi` group + udev rule |
| Serial | `/dev/ttyHS1` | the MCU link |

Group membership and the udev rule are set up by
[`provision/20-dev-tools.sh`](../provision/20-dev-tools.sh).

## The `unoq` package

Installed editable from `~/hybrid/python` into `~/hybrid/.venv`.

```python
from unoq import MCU, fota, link_up, link_state

link_up()                      # BOOT0 low + UART enable (idempotent)
link_state()                   # {'boot0': 'OUTPUT', 'link_enable': 'OUTPUT'}

with MCU() as mcu:
    mcu.status()               # {'uptime_ms': 12216, 'flip': 0, 'sweeps': 1043712}

    mcu.bars([12, 3, 0, 47])   # LED matrix: one bar per value, 0..100
    mcu.matrix_px(7, 0)        # light one LED - finds the panel's orientation
    mcu.matrix_flip()          # rotate 180 degrees, persisted in NVS
    mcu.matrix_off()

    mcu.cmd('kernel threads')  # any shell command, parsed into lines
```

The class wraps the firmware's own `app` command group and nothing else. The
shell's built-in groups — `gpio`, `i2c`, `device`, `kernel`, `devmem` — are one
`mcu.cmd()` away, or you can type them straight into `tio`; wrapping each in a
Python method bought nothing but more surface to keep in step with Zephyr.

`MCU` is a context manager **on purpose** — the UART is a single shared
resource and a stale handle blocks `tio`, `mcucon`, and SMP alike.

`mcu.cmd()` reads until the shell prompt reappears rather than sleeping a fixed
time, so slow commands (`device list`) and fast ones each cost what they should.
It raises `MCUError` on `command not found` and on any line the firmware
prefixes with `Error:`, and `ShellTimeout` if no prompt comes back.

### Firmware update

```python
from unoq import fota
fota.images()    # slot table
fota.upload(path); fota.test(); fota.reset(); fota.confirm()
```

See [mcu.md](mcu.md#update-over-serial-no-swd).

---

# CPU bars on the LED matrix

Host CPU load, one bar per core, on the board's 8×13 panel. It is the smallest
thing that uses both halves of the board for what each is good at: Linux reads
`/proc/stat`, the STM32 holds a 100 kHz refresh loop steady while it does.

```bash
unoq-cpu-bars                       # until Ctrl-C
python -m unoq.cpubars --interval 0.25 --count 20
```

```python
from unoq import MCU, CpuSampler

sampler = CpuSampler()              # takes the first reading
with MCU() as mcu:
    mcu.bars(sampler.sample())      # [12, 3, 0, 47] -> four bars
```

`/proc/stat` holds counters since boot, so a single reading is the average since
power-on; keep one `CpuSampler` alive and take differences.

## At every boot

```bash
sudo bash ~/hybrid/provision/50-cpu-bars.sh      # install + enable
journalctl -u unoq-cpu-bars -f
```

> **It holds `/dev/ttyHS1` open.** pyserial opens the port exclusively, so while
> the service runs, `mcucon`, `tio`, `unoq.MCU` and FOTA all fail with *device
> busy*. Stop it before working on the MCU:
>
> ```bash
> sudo systemctl stop unoq-cpu-bars
> ```
>
> Flashing over SWD (`flash.sh`, `zflash`) is unaffected — that is OpenOCD on
> the GPIO lines, not the UART.

The unit sets `KillSignal=SIGINT`, which is load-bearing rather than
stylistic. systemd's default SIGTERM kills Python outright, so the `finally:`
that blanks the panel never runs and the last frame stays lit indefinitely —
measured: SIGTERM exits 143 with the refresh still sweeping, SIGINT exits 0 with
the panel dark. `Restart=on-failure` covers the case where the MPU reaches
`multi-user.target` before the MCU's shell is answering.

It also declares `Requires=unoq-link.service`, because `/dev/ttyHS1` reads
nothing until that unit has driven the UART-enable GPIO. Ordering alone would
let this start against a silent port and restart forever.

## Which half does what

| | Runs on | File |
|---|---|---|
| Read `/proc/stat`, turn counters into percentages | MPU | [`python/unoq/cpu.py`](../python/unoq/cpu.py) |
| Send `app bars 12 3 0 47` over `/dev/ttyHS1` | MPU | [`python/unoq/mcu.py`](../python/unoq/mcu.py) |
| Percentages → 104 grayscale pixels | MCU | [`mcu/app/src/bars.c`](../mcu/app/src/bars.c) |
| Charlieplex those pixels onto PF0–PF10 | MCU | [`mcu/app/src/matrix.c`](../mcu/app/src/matrix.c) |

The wire format is whole percentages, so `app bars 100 50 0 0` typed into `tio`
does exactly what the daemon does. Nothing on the MCU knows what a CPU core is,
and nothing on the MPU knows how a bar is drawn.

## Reading the display

Bars are 2 columns wide with a 1-column gap, centred, growing from the bottom.

Eight rows would quantise load into 12.5% steps, so the top pixel of each bar is
dimmed in proportion to the remainder — the 3-bit grayscale is used as a vernier,
giving 56 distinguishable heights instead of 8.

The scale is linear, which has one consequence worth knowing before you decide
the display is broken: a core needs **13%** before it lights one row at full
brightness, and **2%** before it lights anything at all. An idle UNO Q therefore
shows a dark panel with at most a faint dot or two along the bottom edge, and
looks exactly like a service that failed to start. Put some load on before
judging it:

```bash
for i in 1 2 3 4; do (timeout 10 bash -c 'while :; do :; done' &) ; done
```

The dark idle state is deliberate — a baseline glow would be indistinguishable
from a low but real load.

## Orientation

**The panel's rows run in whichever direction your board is mounted**, and the
firmware cannot know which. If the bars hang from the top instead of standing on
the bottom, flip them once:

```
unoq:~$ app matrix px 7 0 7      # lights the bottom-left LED, as you should see it
unoq:~$ app matrix flip          # wrong corner? rotate 180 degrees
ok flip=1
```

`flip` is stored in NVS, so it survives reboots and firmware updates. `app
status` reports it. From Python: `mcu.matrix_px(7, 0)` and `mcu.matrix_flip()`.

## Is it actually running?

A charlieplexed panel is invisible to software — nothing the MCU can read back
tells you what is lit. The one observable is the refresh sweep counter:

```bash
hpy -c "
from unoq import MCU; import time
with MCU() as m:
    t0 = time.monotonic(); a = m.status()['sweeps']
    time.sleep(1)
    t1 = time.monotonic(); b = m.status()['sweeps']
    print(round((b - a) / (t1 - t0)), 'sweeps/s')"
```

Expect **~962/s** while the panel is on (104 LEDs × 10 µs per slot); measured
958. A count stuck at zero means the refresh timer never started; a count that
climbs means the ISR is running whether or not you can see the LEDs from where
you are.

> Divide by the *measured* interval, not by the sleep. A `status()` round trip
> costs ~0.30 s — `cmd()` blocks in `read()` until its timeout even after the
> prompt has arrived — so the obvious `sleep(1); b - a` version reports ~1250
> and looks like a panel refreshing 30% faster than the hardware allows.

The panel starts lazily on the first `app bars`, and `app matrix off` stops the
timer and releases the pins.

## Shell commands

```
app status                      uptime_ms, flip, sweeps
app bars <pct> [pct ...]        1..7 values, 0..100 each
app matrix px <row> <col> <lvl> light one LED; row 0..7, col 0..12, lvl 0..7
app matrix flip                 rotate 180 degrees, persisted
app matrix off                  blank the panel, stop the refresh
```

## Why seven bars

Bars are at least one column wide and always separated by one blank column, so
*n* bars need 2*n*−1 columns. Thirteen columns therefore cap it at seven. The
UNO Q's MPU has four cores, so this is not a limit you will meet; a bigger host
gets `cpu0..cpu6` and a warning on stderr, never a silent truncation.

## How the panel works

104 LEDs on eleven pins (PF0–PF10), charlieplexed: each LED is one *ordered*
pair of pins, lit by driving one high, one low, and leaving the other nine
floating as inputs. Eleven pins give 11 × 10 = 110 ordered pairs; the panel uses
the first 104.

Only one LED is ever on. A TIM17 counter callback walks all 104 every 1.04 ms,
and brightness comes from lighting a given LED in *L* of the seven sweeps that
make up a grayscale cycle — so the whole panel redraws at ~137 Hz.

That is why [`matrix.c`](../mcu/app/src/matrix.c) writes `MODER` and `BSRR`
directly instead of calling `gpio_pin_configure_dt()`: pins must change
*direction*, not just level, 100,000 times a second.

> Upstream Zephyr's `arduino_uno_q` board does not describe the matrix at all.
> The pin pairing and the 10 µs slot were taken from Arduino's own core
> (`ArduinoCore-zephyr`, `loader/matrix.inc`) — the only description of this
> wiring that exists. Nothing else from that core is used here, and the
> devicetree nodes it needs are declared in
> [`mcu/app/boards/arduino_uno_q.overlay`](../mcu/app/boards/arduino_uno_q.overlay).

## Gotchas

- **PF0–PF10 belong to the panel.** Anything else in the build that claims them
  will fight the refresh ISR. PF11–PF15 are untouched.
- The refresh ISR runs at 100 kHz whenever the panel is on. It is cheap, but it
  is not free — `app matrix off` if you are measuring something timing-sensitive.
- `unoq-cpu-bars` only appears on `PATH` after re-running the editable install;
  `python -m unoq.cpubars` always works.
- **Close the shell handle before using SMP.** `MCU` and `fota` both want the
  same UART, and reopening it immediately after a close drops the first SMP
  frame — which looks exactly like a firmware fault but is a host-side race.
  Leave the `with MCU()` block first, and give it a moment.
- `cbor2` is capped `<6.0.0` by `smp`, and `pydantic` pins `pydantic-core`
  exactly. Both show as "outdated" and **must not** be upgraded — see the
  maintenance notes in [the README](../README.md#things-that-look-out-of-date-but-are-not).
- Reading `/dev/ttyHS1` returns zero bytes if GPIO line 70 is not driven high.
  `MCU()` calls `link_up()` for you; raw `pyserial` does not.
