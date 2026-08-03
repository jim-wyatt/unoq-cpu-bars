"""
unoq - talk to the Arduino UNO Q's STM32U585 from the Linux side.

    from unoq import MCU, link_up

    link_up()                      # BOOT0 low + UART enable (safe to re-run)
    with MCU() as mcu:
        print(mcu.status())        # {'uptime_ms': 12216, 'ticks': 25, ...}
        mcu.gpio_set('gpioh', 11, 1)
        print(mcu.echo('ping'))    # via SMP, not the shell

Wraps the Zephyr shell running on lpuart1 (/dev/ttyHS1) and the SMP/MCUmgr
endpoint sharing the same UART. See ~/hybrid/README.md for the hardware notes.
"""

from . import fota
from .link import BOOT0_LINE, LINK_ENABLE_LINE, link_state, link_up
from .mcu import MCU, MCUError, ShellTimeout

__all__ = [
    "fota",
    "MCU",
    "MCUError",
    "ShellTimeout",
    "link_up",
    "link_state",
    "BOOT0_LINE",
    "LINK_ENABLE_LINE",
]
__version__ = "0.1.0"
