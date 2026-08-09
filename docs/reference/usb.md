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
sudo bash ~/two-computers-one-board/share/fetch-vscode.sh    # ~1.8 GB, needs internet
sudo bash ~/two-computers-one-board/share/build-image.sh     # FAT32 image
sudo bash ~/two-computers-one-board/provision/60-usb-gadget.sh
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
boot, nothing plugged in
   → unoq-usb-gadget.service builds the definition, br-usb and DHCP, exits
     (RemainAfterExit=yes — it stays "active" having bound nothing)

plug into a computer
   → Type-C negotiates: computer = host, board = device
   → a UDC appears in /sys/class/udc
   → udev fires SYSTEMD_WANTS=unoq-usb-bind.service
   → that binds the gadget to the UDC
   → usb0/usb1 appear → udev fires the bind unit again
   → they join br-usb; dnsmasq answers the computer's DHCP
```

**Why two units.** The obvious design is one unit that udev restarts. It does
not work: the boot-time unit is `RemainAfterExit=yes`, and systemd will not
re-run `ExecStart` for a oneshot it still considers active — so a udev trigger
aimed at it is silently a no-op and the gadget never binds. `unoq-usb-bind.service`
exists solely to be re-runnable: `Type=oneshot`, no `RemainAfterExit`, back to
`inactive` the moment it finishes, ready for the next plug-in.

At boot with nothing plugged in, the prepare unit builds the definition and
exits. That is not a failure — there is simply nothing to bind to yet.

## What the computer sees

The gadget offers two configurations. A host enumerates configuration 1 and
stops, so `c.1` is what almost every computer actually uses:

| Config | Functions | Used by |
|---|---|---|
| `c.1` | **NCM** + mass storage | Windows 10 ≥1903, Windows 11, macOS ≥Catalina, Linux |
| `c.2` | RNDIS + mass storage | fallback, selected by hand, for genuinely old Windows |

**NCM first, not RNDIS** — the opposite of most USB-gadget recipes, which
predate two changes at Microsoft's end:

- Windows has shipped a native NCM class driver (`UsbNcm.sys`) since Windows 10
  version 1903, so NCM needs no driver and no INF.
- RNDIS is deprecated and its driver has been **removed from recent Windows 11
  builds**. A Windows 11 host offered RNDIS in `c.1` binds nothing for
  networking: you get the drive, no IP, and no obvious error anywhere.

Override for a pre-1903 Windows host:

```bash
sudo UNOQ_GADGET_PRIMARY=rndis ~/two-computers-one-board/usb/gadget-up.sh
```

Two configurations rather than two network functions in one: a host must not
bind two network interfaces to the same device. The drive is in both, so it is
there whichever way the negotiation goes.

On the board, both `rndis.usb0` and `ncm.usb0` register a netdev. Rather than
racing to work out which one the host chose, both are enslaved to a bridge
(`br-usb`) which carries the address. Only the active one ever passes a frame.

## Addressing

There are two modes, and which one you want depends on whether the computer is
sharing its internet. The mode lives in `/etc/default/unoq-usb`, which
`60-usb-gadget.sh` writes once and never rewrites, so an edit survives
re-provisioning:

```bash
UNOQ_USB_MODE=server     # default
UNOQ_USB_MODE=client     # for a host that shares its connection
sudo systemctl restart unoq-usb-gadget
```

| | `server` (default) | `client` |
|---|---|---|
| Board | `10.55.0.1/24` static | `10.55.0.1` **and** whatever the host leases |
| Computer | `10.55.0.10`–`.100` by DHCP from us | its own fixed address, its own DHCP server |
| Runs DHCP | `dnsmasq`, ours | the host's |
| Right when | the computer is something you reach the board *from* | the computer is sharing its internet *with* the board |

### Server mode

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

### Client mode, and why Windows forces it

Turn on Internet Connection Sharing in Windows and it stops negotiating: it
pins the shared adapter to **`192.168.137.1/24`** and runs its own DHCP server
there. It will never take a lease from us. macOS Internet Sharing does the same
thing at `192.168.2.1`.

So a board sitting at `10.55.0.1` in front of a host at `192.168.137.1` is two
`/24`s on one wire with no route between them. Both ends look configured, the
cable looks dead, and nothing logs an error — there is nothing wrong with
either end in isolation.

In client mode the board asks instead of answering:

```bash
sudo systemctl restart unoq-usb-gadget    # with UNOQ_USB_MODE=client set
~/two-computers-one-board/usb/status.sh
```

```
  dhcp mode              client - udhcpc is asking the host for an address
  leased address         192.168.137.210/24
  gateway                192.168.137.1
```

Nothing is hardcoded to Microsoft's numbering — the same code works for macOS,
for a Linux host running its own dnsmasq, and for whatever ICS gets changed to.
`busybox udhcpc` is the client, because this image ships no other one and
busybox is already here.

Three things worth knowing:

- **`10.55.0.1` stays on the bridge in client mode too.** It is the address the
  board still answers on when the host's DHCP server is not running. With wifi
  off that is the difference between a fixable board and a serial console — from
  the host, `route add 10.55.0.0 mask 255.255.255.0 192.168.137.1` (elevated)
  gets you back to it.
- **The address is sticky.** The last lease is remembered in
  `/var/lib/unoq/usb-dhcp-last` and re-requested next time, so "what do I ssh
  to" has an answer you can write down. ICS honours the request in practice.
- **Use the leased IP, not the `.local` name.** avahi does publish on `br-usb`,
  and Windows 11 and macOS both resolve `.local` natively — but avahi advertises
  *every* address on that bridge, and in client mode there are two:

  ```
  Registering new address record for 10.55.0.1 on br-usb.IPv4
  Registering new address record for 192.168.137.210 on br-usb.IPv4
  ```

  A host querying over the cable gets both A records back and picks one. Half
  the time that is `10.55.0.1`, which is the address it has no route to. The
  name is therefore a coin flip and the address is not, which is the other
  reason the lease is made sticky rather than left to chance.

---

## Running on the USB link alone

The radio is the largest thing on this board that can simply be switched off,
and on a board that is plugged into a computer anyway it is also the most
redundant. As a device the board is a power sink at USB default current with no
PD contract, so it is worth reclaiming.

```bash
~/two-computers-one-board/usb/wifi.sh check      # would it be safe right now?
sudo ~/two-computers-one-board/usb/wifi.sh off
sudo ~/two-computers-one-board/usb/wifi.sh on
```

`check` and `off` run the same preflight, and `off` refuses if it fails:

```
  gadget bound, and 192.168.137.1 answers on br-usb
  the host is NAT-ing: the board keeps its internet over USB

  RECONNECT ON:  arduino@192.168.137.210   (or quentin.local)
```

This is not a wrapper around `nmcli radio wifi off` for the sake of it. You are
almost certainly typing that command over the wifi it is about to turn off, and
if the USB link is not actually carrying traffic — gadget did not bind, cable is
charge-only, host is not sharing, board is in server mode in front of an ICS
host — then the moment the radio drops there is no path to the board at all.
Not slow: absent.

The reachability check is ARP, not ping. **Windows blocks ICMP to its ICS
adapter by default**, so the gateway that is routing your traffic perfectly well
does not answer a ping, and refusing on that basis would refuse in the normal
case. A resolved neighbour proves frames cross the wire and get answered, which
is the property "will I still be able to reach this board" actually depends on.

`off` also kicks the DHCP client into renewing, because NetworkManager owns
`/etc/resolv.conf` and rewrites it — without our nameservers — the moment the
radio goes down. `usb-dhcp.sh` puts them back on a lease event, and without the
kick that would not happen until the lease next renewed, which on an ICS lease
is days. The symptom is `ping 8.8.8.8` working and `apt` not.

### Two ways back, when the board is on USB only

Turning wifi off means the gadget is the only way in, so both failure modes have
an automatic path back to a board you can log into.

| What failed | What catches it | What it does |
|---|---|---|
| The bind is killing the board — brownout loop | `bind-guard.sh` | Refuses to bind after 3 unconfirmed boots, **and turns the radio back on** |
| The bind works and there is still no internet | `unoq-uplink-fallback.service` | Waits 240s after boot, then turns the radio back on |

The second one exists because the guard cannot see it: everything the guard
checks succeeded. The gadget bound, `br-usb` came up, the address is there — and
the board still has no way out, because the computer is asleep, or is not
sharing, or woke up with sharing switched off, or is a different computer.

It is a deadline after boot rather than a watchdog on a timer. A poll that ran
forever would flip the radio every time the host slept or the cable was jostled,
and would fight anyone who turned wifi off deliberately. Boot is when the
question is live and nobody is watching. Falling back then stays fallen back
until a person unmakes it, which is what you want from something you are relying
on.

```bash
UNOQ_UPLINK_FALLBACK=0       # in /etc/default/unoq-usb, to disable it
UNOQ_UPLINK_DEADLINE=240     # seconds to wait after boot
```

```bash
journalctl -b -u unoq-uplink-fallback -t unoq-uplink-fallback
```

Both are enabled unconditionally by `60-usb-gadget.sh`, including on a board
whose wifi is on — where the fallback looks, sees a radio already up and exits.
The moment either is needed is the moment nobody can enable it.

### The board's own route out

The board does not offer the computer a gateway, but it does take one *from*
it. When dnsmasq leases the host an address, `usb-route.sh` points the board's
default route at that address, metric **700** — so a board with no other uplink
can reach the internet through the computer, provided the computer is NAT-ing
(Internet Connection Sharing, or `New-NetNat`, on Windows).

The metric is the whole safety story, and it is worth stating plainly because
getting it wrong is quiet:

| Link | Metric | |
|---|---|---|
| Ethernet (NetworkManager) | 100 | wins |
| **Wifi** (NetworkManager) | **600** | wins |
| USB gadget (this) | **700** | fallback only |

Higher metric = lower priority, so the USB route is only ever used when the
board has nothing better. **This was 500 and therefore beat wifi**, which is a
bad failure to diagnose: SSH keeps working, because that is a connected route
on the LAN rather than the default, so the board looks reachable and healthy
while every outbound connection is being sent to a computer that probably is
not routing. `apt`, `git` and anything else wanting the internet just stop.

If you never want the gadget touching the default route:

```bash
UNOQ_USB_DEFAULT_ROUTE=0     # in the unit's environment
```

Check which route actually won, with the cable plugged in:

```bash
ip route show default        # lowest metric is the one in use
```

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
sudo bash ~/two-computers-one-board/usb/gadget-down.sh      # unbind first
sudo bash ~/two-computers-one-board/share/build-image.sh    # remounts rw, syncs, remounts ro
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

Start here, because it prints everything below in one go:

```bash
~/two-computers-one-board/usb/status.sh
```

Role and power, the UDC, both configurations and their functions, the bridge
and its ports, which end is running DHCP and what it leased, the nameservers,
the wifi radio, the default routes in priority order, the bind guard's counter,
and the recent log. Read-only, no root.

It matters more than a convenience script normally would. When the board is
powered over the same cable that carries the gadget, every cable change is also
a power cut — you cannot watch a plug-in happen and no session survives one, so
whatever went wrong has always already finished by the time you can look. After
an unexplained reset the evidence is in the **previous** boot:

```bash
journalctl -b -1 -u unoq-usb-bind -t unoq-bind-guard
```

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
