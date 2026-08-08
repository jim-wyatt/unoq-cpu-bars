<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# IP over USB, and the fileshare

Plug the board's USB-C port into a computer and it becomes a USB device: a
network adapter, and a read-only drive with the VS Code installers and the
learning content on it.

```
your computer                          UNO Q
─────────────                          ─────
10.55.0.10-.100  ◄── USB-C cable ──►   10.55.0.1
   (by DHCP)                           http://10.55.0.1:8080/
                                       "UNO-Q" drive, read-only
```

Set it up once with:

```bash
sudo bash ~/hybrid/share/fetch-vscode.sh    # ~1.8 GB, needs internet
sudo bash ~/hybrid/share/build-image.sh     # FAT32 image
sudo bash ~/hybrid/provision/60-usb-gadget.sh
```

Then plug it in. Nothing to configure on the computer.

---

## The one thing that surprises people

**The USB-C port cannot be a host and a device at the same time.**

There is exactly one USB data controller on this board — `4e00000.usb`, a dwc3
with `dr_mode = "otg"`. While the board is a device, it is not a host: a hub,
dock, network dongle, keyboard or USB stick plugged into it is *gone* until you
disconnect from the computer.

That is a hardware fact, not a configuration choice. If you develop with a USB
Ethernet dongle, you are choosing between the dongle and the gadget.

## You cannot switch the role from software

This catches people who have done USB gadgets on a Raspberry Pi, where you
write `dr_mode` or `echo device > .../role`. Here:

| | |
|---|---|
| `/sys/class/usb_role/4e00000.usb-role-switch/role` | **does not exist** |
| `/sys/class/typec/port0/data_role` | read-only |
| dwc3 `mode` attribute | not exposed |

The role switch registers without its `role` attribute because the driver does
not set `allow_userspace_control`. The **Type-C controller** (`anx7625`) picks
host or device from the CC lines when a cable is plugged in.

So the design here is event-driven, not boot-time:

```
plug into a computer
   → Type-C negotiates: computer = host, board = device
   → a UDC appears in /sys/class/udc
   → udev rule 99-unoq-usb-gadget.rules fires
   → unoq-usb-gadget.service binds the gadget
   → usb0 appears, joins br-usb, dnsmasq answers the computer's DHCP
```

At boot with nothing plugged in, the service builds the gadget definition and
exits. That is not a failure — there is simply nothing to bind to yet.

## What the computer sees

The gadget offers two configurations, and the host picks the one it supports:

| Config | Functions | Chosen by |
|---|---|---|
| `c.1` | RNDIS + mass storage | Windows (via the MS OS descriptors) |
| `c.2` | NCM + mass storage | Linux, macOS |

Two configurations rather than two network functions in one: a host must not
bind two network interfaces to the same device. The drive is in both, so it is
there whichever way the negotiation goes.

On the board, both `rndis.usb0` and `ncm.usb0` register a netdev. Rather than
racing to work out which one the host chose, both are enslaved to a bridge
(`br-usb`) which carries the address. Only the active one ever passes a frame.

## Addressing

| | |
|---|---|
| Board | `10.55.0.1/24`, static, on `br-usb` |
| Computer | `10.55.0.10`–`10.55.0.100`, by DHCP |
| Gateway / DNS | **deliberately not offered** |

`10.55.0.0/24` is deliberately obscure. A board handing out `192.168.0.x` or
`10.0.0.x` on a cable would collide with the network the laptop is already on.

No default route is offered either, for the same class of reason: the board is
the thing you are connecting *to*, and a device that silently becomes a
laptop's default gateway breaks its internet in a way that takes an afternoon
to diagnose.

To set the computer's address by hand instead: `10.55.0.2/24`, no gateway, no
DNS.

### The DHCP server does not leak onto your LAN

`dnsmasq` runs with `--interface=br-usb --bind-dynamic`, so it answers DHCP
only on the gadget bridge. It still *binds* `0.0.0.0:67` — that is inherent to
DHCP, whose clients broadcast from `0.0.0.0` — so the socket listing is not
the thing that makes it safe; the interface filter is.

Verify it on a board that is also on a real network:

```bash
sudo ss -ulnp | grep :67          # will show 0.0.0.0:67 - this is expected
```

and confirm no `10.55.0.x` offer appears when a DHCP request goes out on your
LAN interface.

## The fileshare

`share/build-image.sh` builds a FAT32 image — the one filesystem Windows,
macOS and Linux all mount with no driver — and it is the **only** copy of the
content:

```
/home/arduino/unoq-share.img     the image (on the big partition)
  └─ mounted read-only at /srv/unoq-share
        ├─ index.html            the learning page
        └─ vscode/               installers + SHA256SUMS.txt
```

The same file is what `usb_f_mass_storage` exports and what `unoq-learn`
serves, so the drive and the web page cannot disagree about what is on the
board. It lives on `/home/arduino` because `/` has under 5 GB spare once
Zephyr is built.

**It is exported read-only, and mounted read-only.** The host and the board
would otherwise both be writing the same blocks with neither one's page cache
aware of the other, which destroys a FAT filesystem quickly.

To update the content:

```bash
sudo bash ~/hybrid/usb/gadget-down.sh      # unbind first
sudo bash ~/hybrid/share/build-image.sh    # remounts rw, syncs, remounts ro
sudo systemctl restart unoq-usb-gadget
```

## adb is disabled

`adbd` binds its *own* gadget to the first free UDC. With this installed there
would be two gadgets racing for one controller. `provision/60-usb-gadget.sh`
disables `adbd` for that reason.

adb over TCP still works once the link is up:

```bash
adb connect 10.55.0.1:5555
```

To go back to adb over USB: `sudo systemctl disable --now unoq-usb-gadget &&
sudo systemctl enable --now adbd`.

## Troubleshooting

**Nothing appears on the computer.** Check a UDC exists — if `/sys/class/udc`
is empty the Type-C negotiation did not make the board a device. Try the other
cable orientation, and make sure the cable is a data cable (charge-only USB-C
cables are common and look identical).

```bash
ls /sys/class/udc                 # empty = not a device right now
cat /sys/kernel/config/usb_gadget/unoq/UDC
journalctl -u unoq-usb-gadget -n 40
```

**The drive is there but the network is not** (or the reverse). The host bound
a configuration whose network function it does not support, or NetworkManager
grabbed the gadget interface. `ip -br addr show br-usb` should show
`10.55.0.1/24`, and `bridge link` should list a `usb*` port.

**Windows shows an unknown device.** It picked `c.1` but did not apply the
RNDIS driver. Check the MS OS descriptors survived:

```bash
cat /sys/kernel/config/usb_gadget/unoq/os_desc/use          # 1
cat /sys/kernel/config/usb_gadget/unoq/functions/rndis.usb0/os_desc/interface.rndis/compatible_id
```

**Powering the board from the computer.** As a device the board is a power
sink. A laptop USB-C port that only supplies 0.5 A will brown it out under
load — the four cores plus the MCU want considerably more. If the board
reboots when you run a build, power it properly.
