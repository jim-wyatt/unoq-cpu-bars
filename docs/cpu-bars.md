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

sampler = CpuSampler()
with MCU() as mcu:
    mcu.bars(sampler.sample())      # [12, 3, 0, 47] -> four bars
```

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

---

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
giving 56 distinguishable heights instead of 8. A core at 6% lights the bottom
row faintly; at 50% you get four solid rows.

An idle machine leaves the panel dark. That is deliberate: a baseline glow would
be indistinguishable from a low but real load.

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
    a = m.status()['sweeps']; time.sleep(1); b = m.status()['sweeps']
    print(b - a, 'sweeps/s')"
```

Expect **~962/s** while the panel is on (104 LEDs × 10 µs per slot). A count
stuck at zero means the refresh timer never started; a count that climbs means
the ISR is running whether or not you can see the LEDs from where you are.

The panel starts lazily on the first `app bars`, and `app matrix off` stops the
timer and releases the pins.

## Shell commands

```
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

## Tests

The rasteriser is deliberately free of Zephyr and of hardware, so it is compiled
a second time and run on the host:

```bash
~/hybrid/mcu/ztest.sh            # includes the `bars` suite
```

Those tests are the only place the drawing rules are checked at all — the panel
cannot be read back — so they assert properties (bars stay in their columns,
height never falls as load rises, rotation is a true rotation) rather than a few
remembered frames.

`python/tests/test_contract.py` parses `app_proto.h` and fails if the panel
constants in `unoq/mcu.py` drift from the firmware's.

## Gotchas

- **PF0–PF10 belong to the panel.** Anything else in the build that claims them
  will fight the refresh ISR. PF11–PF15 are untouched.
- The refresh ISR runs at 100 kHz whenever the panel is on. It is cheap, but it
  is not free — `app matrix off` if you are measuring something timing-sensitive.
- `unoq-cpu-bars` only appears on `PATH` after re-running the editable install;
  `python -m unoq.cpubars` always works.
