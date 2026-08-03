# MPU workflow

The Linux side: direct hardware access, plus the `unoq` package for talking to
the MCU.

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
    mcu.status()               # {'uptime_ms':…, 'ticks':…, 'boots':…, 'wdt':1}
    mcu.blink(250)
    mcu.uptime_ms()
    mcu.devices()              # [('gpio@42021c00','READY'), …]
    mcu.gpio_conf('gpioh', 11, 'o')
    mcu.gpio_set('gpioh', 11, 1)
    mcu.gpio_get('gpioh', 11)
    mcu.i2c_scan('i2c2')       # MCU-side bus
    mcu.echo('ping')           # via SMP, not the shell
    mcu.cmd('kernel threads')  # any raw shell command
    mcu.reboot()
```

`MCU` is a context manager **on purpose** — the UART is a single shared
resource and a stale handle blocks `tio`, `mcucon`, and SMP alike.

`mcu.cmd()` reads until the shell prompt reappears rather than sleeping a fixed
time, so slow commands (`device list`) and fast ones each cost what they should.

### Firmware update

```python
from unoq import fota
fota.images()    # slot table
fota.upload(path); fota.test(); fota.reset(); fota.confirm()
```

See [mcu.md](mcu.md#update-over-serial-no-swd).

## Gotchas

- **Handing the port from the shell to SMP needs a settle delay.** Reopening
  immediately drops the first SMP frame and times out — which looks exactly like
  a firmware fault but is a host-side race. `unoq` handles this
  (`SMP_SETTLE_S`) and retries once.
- `cbor2` is capped `<6.0.0` by `smp`, and `pydantic` pins `pydantic-core`
  exactly. Both show as "outdated" and **must not** be upgraded — see
  [maintenance.md](maintenance.md).
- Reading `/dev/ttyHS1` returns zero bytes if GPIO line 70 is not driven high.
  `MCU()` calls `link_up()` for you; raw `pyserial` does not.
