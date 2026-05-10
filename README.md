Provided a starting point for using [QEMU][0]'s [microvm][1] machine type.

* QEMU
* `microvm` is minimalist machine type without PCI nor ACPI support.
    * Inspired by Firecracker
    * Designed for short-lived guests.

# Quick Start

* Build initial root file system:
  `podman run --rm -v .:/work --workdir /work public.ecr.aws/docker/library/alpine:3.22.4 create-bb-initframfs.sh`
* Build kernel - TODO
* Run
  `qemu-system-x86_64 -m 512m -append 'console=hvc0 reboot=triple' -kernel .\linux6.18-virtio-donno-net.bzImage -M microvm,rtc=off,acpi=off,pic=on,pit=on -device virtio-serial-device -chardev stdio,id=virtiocon0,mux=on -device virtconsole,chardev=virtiocon0 -mon chardev=virtiocon0 -device virtio-net-device,netdev=net-uDC8gBXd0 -netdev user,id=net-uDC8gBXd0 -display none -initrd .\bbmicrovm-initramfs -accel whpx`
  * Tweak accel from whpx to kvm if on Linux instead of Windows.

# Components

* Linux Kernel
* Initial RAM file system ([initramfs][2])
* QEMU

## Linux Kernel

Rough notes which I plan to clean-up.

I used Alpine 3.22.

* `apk add alpine-sdk flex bison gawk bc ncurses-dev elfutils-dev git`
    * The other packages are needed for building.
    * `git` was used to clone the repository. A tar could have been used
      instead.
    * `ncurses-dev` is needed for the configuration menu.
    * `elfutils-dev` was needed for `gelf.h`

`difftool` may be useful needed to avoid `diff: unrecognized option: I`caused
by BusyBox's `diff` applet.

```sh
git clone --depth 1 --branch "v6.18" https://github.com/torvalds/linux
make tinyconfig
make menuconfig
make -j4
cp arch/x86/boot/bzImage /mnt/d/vms/qemu/linux6.18-virtio-donno-net.bzImage
cp System.map /mnt/d/vms/qemu/linux6.18-virtio-donno-net.System.map
cp .config /mnt/d/vms/qemu/linux6.18-virtio-donno-net.config
```

### Kernel Configuration

Assume all the options below should be enabled when listed unless otherwise told to disable.

* Linux Kernel Configuration
  * 64-bit Kernel
  * Process type and features
    * Symmetric multi-processing support
    * Linux Guest support

TODO:

* Consider Device Drivers -> Generic Driver Options -> Maintain a devtmpfs filesystem to mount at /dev (CONFIG_DEVTMPFS=y)

## Initial RAM file system

This was built in a Linux container (Alpine 3.23.4) where a directory on the
host was volume mounted to `/host` within the container.

The file system is in the archive of the `cpio` format which is then gzipped.
The Linux kernel will extract it into the root file system once it boots up.
It will then execute the "init" to bring up the system. Typically, it will use
this to mount the block device that has the real root device, in our case we
simply run from the initial file system for now.

```
(cd bin && ./busybox --list | xargs -n1 -P8 ln -s busybox)
find . | cpio -o -H newc --owner=root:root > /host/bbmicrovm-initramfs
```

Additional files will end up as:
* [/etc/passw](https://man7.org/linux/man-pages/man5/passwd.5.html) - Define users (the password file)
* /etc/hostname - Define the host name - this is read during `init` and set as the hostname of the machine.
* /etc/group - Define groups
* /etc/shadow - Define the passwords
* /etc/fstab - Define describesfile systems that can be mounted (`mount -a`)
* [/etc/resolv.conf](https://man7.org/linux/man-pages/man5/resolv.conf.5.html) - Define namespaces for resolving domain names.
* /etc/inittab - configuration file for the init daemon (BusyBox's init).
* /etc/init.d/rcS
* /etc/init.d/S99setup-network

### Build
```sh
podman run --rm -v .:/work --workdir /work public.ecr.aws/docker/library/alpine:3.22.4 create-bb-initframfs.sh
```

## Interactive Build
```sh
podman run -it --rm -v .:/work --workdir /work public.ecr.aws/docker/library/alpine:3.22.4
# Within container:
./create-bb-initframfs.sh
vi /busybox-root/mystart.sh
./create-bb-initframfs.sh
```

* TODO: Consider making this automated -> shell script for adding a build and edit-build (edit a file with vi then rebuild on close).

## QEMU

The following command is for Microsoft Windows with the Hypervisor Platform
(whpx), but you should likely be able to change that for `kvm` for a Linux
host.

```sh
qemu-system-x86_64 -smp 2 -m 512m -append 'printk.time=1 console=hvc0' -kernel .\linux6.18-virtio-donno-net.bzImage -M microvm,rtc=off,acpi=off,pic=on,pit=on,accel=whpx -device virtio-serial-device -chardev stdio,id=virtiocon0,mux=on -device virtconsole,chardev=virtiocon0 -mon chardev=virtiocon0 -device virtio-net-device,netdev=net-uDC8gBXd0 -netdev user,id=net-uDC8gBXd0,ipv6=off -display none -initrd bbmicrovm-initramfs
```

For using the normal machine type, which is how some of it was tested
```sh
-kernel .\linux6.18-virtio-donno-net.bzImage -initrd bbmicrovm-initramfs --append "console=ttyS0" -serial stdio  -device virtio-net-pci,netdev=net-uDC8gBXd0 -netdev user,id=net-uDC8gBXd0,ipv6=off
```

When using the custom kernel, `-nic user -net user` can't be used as that
expects a normal emulated network card rather than the virtio-net based card.

### Command Breakdown

* `-smp 2` specific the use of 2 cores
* `-m 512m` specifics allocation of 512 megabytes of memory for the VM.
* `-kernel` specifies the compressed kernel image to use.
* `-M` specifics the machine type
    * `microvm` - The machine type that controls what devices are provided.
    * `accel=whpx` - Use acceleration via the Windows Hypervisor Platform.
    * `rtc=off` - Turn off MC146818 RTC - Real-Time Clock
    * `acpi=off`
    * `pic=on` - Turn on i8259 PIC - Programmable interrupt controller
    * `pit=on` - Turn on i8254 PIT - Programmable interval timers
* `initrd` specifies the initial RAM disk to use.
* Kernel command line (provided via `-apend`)
    * `printk.time=1` - Adds the unmodified local hardware clock timestamp to
      printk messages. Essentially provides easy way to see the boot time.
    * `earlyprintk=hvc0 console=hvc0` - Use the virtual console for output.
    * `reboot=triple` - Informs the kernel to perform a triple fault which is
      how QEMU's recommended way to trigger a guest-initiated shut down.
* Set-up virtual console using the `virtio-serial-device` and output it to stdio.
    * The `mux=on` allows it to also be connected to QEMU monitor via the `-mon` argument.
    * By extension configure QEMU monitor to output to standard output.
* Set-up virtio network device
* Disable the display as there is no VGA device (`-display none`)

# Journey
This is the longer form version of the journey to where I ended up getting to.

## First initial RAM file system
The first iteration with a handwritten script to serve as `init`.

```sh
mkdir busybox-root && cd busybox-root
mkdir -p bin dev etc lib mnt proc sys tmp var home
wget -O bin/busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
cat > init << EOF
#!/bin/busybox sh
/bin/busybox --install /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
sh
EOF
cat > etc/passwd << EOF
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/:/sbin/nologin
EOF
cat > etc/group << EOF
root:x:0:root
nobody:x:65534:
EOF
find . | cpio -ov --format=newc | gzip --best > /host/bb-initramfz && find . | cpio -ov --format=newc > /host/bb-initramfs && echo "Built images"
```

* The passwd and group were set-up as I was trying out  `mdev` and that
  dealt with different users.
* The command at the end rebuilds the images.
* I suspect that this init failed when using the kernel built ourselves because
  the `CONFIG_BINFMT_SCRIPT` option was not provided.. The documentation even says
  > Most systems will not boot if you say M or N here. If unsure, say Y.

## Using BusyBox's init

The piece of this puzzle I was missing and didn't understand was `/etc/inittab`
in the final image.

Essentially instead of commands in the `init` shell script, the commands to run
can be put in the `inittab` under `sysinit` which as the name suggests occurs
when you do the `init`.

```
::sysinit:/bin/mount -a
::sysinit:/bin/hostname -F /etc/hostname
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/ln -sf pts/ptmx /dev/ptmx
::sysinit:/bin/mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts
::sysinit:/bin/mkdir -p /dev/shm
::sysinit:/bin/mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /dev/shm
::sysinit:/bin/ip link set lo up
::ctrlaltdel:/bin/reboot
::shutdown:/bin/echo SHUTTING DOWN
::shutdown:/bin/umount -a -r
tty1::respawn:/bin/getty 38400 tty1
tty2::askfirst:/bin/getty 38400 tty2
tty3::askfirst:/bin/getty 38400 tty3
tty4::askfirst:/bin/getty 38400 tty4
```

* What about mounting `/dev` and `/proc`?
    * That is handled by `/etc/fstab`
      ```
      devtmpfs /dev devtmpfs defaults 0 0
      proc /proc proc defaults 0 0
      ```
    * The question to follow-up is, why isn't `/dev/shm` setup through `fstab`?
* Since this reads `/etc/hostname` that file needs to be created.
  `echo bbmicrovm > etc/hostname`
  * It would be good to be able to set this via a kernel parameter so its
    provided on the command line of the kernel.
* Downside is due to the use of `getty` it now wants to login rather than
  auto-login.
    * This requires setting up `/etc/shadows` with a password.
* To save me having to add an entry every time I wanted to try something else
   out on initalisation, I added `::sysinit:/bin/sh /mystart` such that it
   will call the script `mystart`.

## Various Issues
```
mount: mounting devpts on /dev/pts failed: No such device
```

* The first error was due kernel and  `/etc/inittab` configuration
    * The problematic line of the `inittab` was `::sysinit:/bin/mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts`
    * This is simply because those the pseudo teletype terminal wasn't
      configured. I didn't write down which kernel configuration this was
      related to.
    * The other `/dev/pts` parts are also removed.

## Building Kernel

Since my host operating system is Microsoft Windows, I used the Alpine 3.22
distribution I had in WSL2.

The main source for setting-up the kernel was [bluedragon1221][7.1]'s
[minimal Linux project][7.2]. This also served as a great example of what I was
missing from being able to use BusyBox's init instead of my own shell script.

* `apk add alpine-sdk flex bison gawk bc ncurses-dev elfutils-dev git`
    * The other packages are needed for building.
    * `git` was used to clone the repository. A tar could have been used
      instead.
    * `ncurses-dev` is needed for the configuration menu.
    * `elfutils-dev` was needed for `gelf.h`

```sh
git clone --depth 1 --branch "v6.18" https://github.com/torvalds/linux
make tinyconfig
make menuconfig
make -j4
cp arch/x86/boot/bzImage /mnt/d/vms/qemu/linux6.18-virtio-donno-net.bzImage
cp System.map /mnt/d/vms/qemu/linux6.18-virtio-donno-net.System.map
cp .config /mnt/d/vms/qemu/linux6.18-virtio-donno-net.config
```

* With v3.19 (7d0a66e4b) and ended up with a 800kb kernel (bzImage).
* It didn't do the logging on boot.

* [CONFIG_VIRTIO_MMIO][6] - Required due to `microvm` machine type lacking a PCI bus.

## Timings

The initial output didn't include the timing information.
```
NET: Registered PF_INET6 protocol family
Unpacking initramfs...
printk: legacy console [hvc0] enabled
Segment Routing with IPv6
In-situ OAM (IOAM) with IPv6
```

Eventually I stumped across [CONFIG_PRINTK_TIME][3.2] which was turned off
when this kernel was built. however, thee behavior can be controlled by the
[kernel command line parameter][kernel-parameters] `printk.time=1`, so that is
what I used instead, as seen below:
```
[    0.056001] NET: Registered PF_INET6 protocol family
[    0.056001] Unpacking initramfs...
[    0.080003] printk: legacy console [hvc0] enabled
[    0.096004] Segment Routing with IPv6
[    0.096004] In-situ OAM (IOAM) with IPv6
```

## Networking
Turned on the networking stack as seen by
```
NET: Registered PF_NETLINK/PF_ROUTE protocol family
NET: Registered PF_VSOCK protocol family
NET: Registered PF_INET protocol family
```
The latter option corresponds with [CONFIG_INET][10]

* However, still had no `eth0`.
* The cause "Network Device Support" was not enabled
    * This setting was found under the Device Drivers option.
    * The config name for this setting is [CONFIG_NETDEVICES][4]
* Need "Virtio network driver"
    * This is Device Drivers -> Network device support
    * The config name for this setting is [CONFIG_VIRTIO_NET][5]
* I also enabled "Wireguard secure network tunnel" just in case.

The next part was setting up DHCP so in the `/mystart` script added the
following:
```sh
ip link show > /dev/hvc0
udhcpc --interface eth0 --foreground --script /usr/share/udhcpc/default.script > /dev/hvc0
ip link show > /dev/hvc0
```

The result (omitting the ip link as that isn't relevant yet) was didn't work:
```
udhcpc: started, v1.35.0
udhcpc: socket(AF_PACKET,2,8): Address family not supported by protocol
```

* Need "Packet socket"
    * Found Kernel Configuration -> Networking Support -> Networking options
    * The [CONFIG_PACKET][9] configuration corresponds to a module called `af_packet`.

Rerunning it:
```
udhcpc: started, v1.35.0
udhcpc: broadcasting discover
udhcpc: sendto: Network is down
udhcpc: read error: Network is down, reopening socket
```

Fix: `ip link set eth0 up` first.

It still wasn't working, but at least once I ended up with:
```
udhcpc: started, v1.35.0
udhcpc: broadcasting discover
udhcpc: broadcasting select for 10.0.2.15, server 10.0.2.2
```

Take step back and try static IP with `ip addr add 192.168.1.100/24 dev eth0`
which resulted in error, which was hard to find, needed to copy a static version
of `strace` into the image.
```
socket(AF_UNIX, SOCK_DGRAM|SOCK_CLOEXEC, 0) = -1 EAFNOSUPPORT (Address family not supported by protocol)
```

* That problem can be fixed by enabling Unix Domain Sockets.
    * In the config it is under Networking support ->  Networking options -> Unix domain sockets

There is the following message output from `dmesg`:
> could not register sysctl

* Need "Sysctl support"
    * This enables /proc/sys
    * > The sysctl interface provides a means of dynamically changing certain kernel parameters and variables on the fly without requiring
    * Found Kernel Configuration -> File systems -> Pseudo filesystems > Sysctl support (/proc/sys)
    * This is the [CONFIG_PROC_SYSCTL][12] configuration option.
    * The warning associated with this is it will add 8KB to the kernel.

Still doesn't work it gets stuck (no IP is selected) and when an IP is selected
it never returns.

**Progress**: discovered `/etc/network/interfaces` is used by `ifup` and the build
of BusyBox that is being used doesn't include that applet so its configuration
is pointless. Switching to a purely manual approach, does improve it but
hits an error:

```sh
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
ip link set eth0 up
```

The error is:
> ip: RTNETLINK answers: Network unreachable

The fix is to set-up the link first.
```sh
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
```

Now there is no errors and:
```sh
ip addr show eth0 2>&1 > /dev/hvc0
```

Outputs:
```
4: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
    inet 10.0.2.15/24 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::5054:ff:fe12:3456/64 scope link tentative
       valid_lft forever preferred_lft forever
```

Next problem is the networking is hanging, `wget` and `nslookup`.

This is due to the Windows Hypervisor Platform (WHPX) having issues
delivering interrupts due to `pic=on` on Microsoft Windows 10 as per
the [QEMU documentation][15]. The fix is to turn on [CONFIG_KVM_GUEST][14] as
the documentation from 6.18.13 states:
>  It includes a paravirtualized clock, so that instead of relying on a PIT
   (or probably other) emulation by the underlying device model, the host
provides the guest with timing infrastructure such as time of day, and system time

This setting was under Processor type and features -> Linux guest support >
 >KVM Guest support (including kvmclock). This in turn meant turning on
[CONFIG_HYPERVISOR_GUEST][13] which enables basic hypervisor detection and
platform setup.

The expectation if this works is `cp /proc/interrupts /dev/hvc0` should show
show IO-APIC next to the interrupt for the VirtIO network device. However, in my case
it still stays XT-PIC, however after playing around it ended up saying IO-APIC.
That said, when I turn off `pic` and `pit` on QEMU, there is no output
from QEMU after it says the accelerator is operational

The following should be in the output of `dmesg`:
> IOAPIC[0]: apic_id 2, version 32, address 0xfec00000, GSI 0-23

**Before**
```
  0:         29   XT-PIC      timer
  2:          0   XT-PIC      cascade
 11:          2   XT-PIC      virtio1
 12:         15   XT-PIC      virtio0
 ```
**After**
Removing `noapic nolapic acpi=off` from the kernel command line, the last
option was doing nothing as it is being ignored anyway.
```
  0:         66  IO-APIC   2-edge      timer
  2:          0   XT-PIC      cascade
 11:          2  IO-APIC  11-edge      virtio1
 12:         18  IO-APIC  12-edge      virtio0
```

Now check the network is working by adding the following to the `mystart.sh`
```
wget http://ifconfig.me/all -O -
```

## Set-up SSH Server
For this, the plan is to use [`dropbear`][dropbear] which can be statically
compiled.
```sh
wget -O bin/dropbear https://static-binaries.gitlab.io/dropbear/dropbear-2019.78.x86_64-linux-android
chmod +x bin/dropbear
```

Trying to run it inthe foreground to ensure we have everything working:
* > setsockopt(4, SOL_IPV6, IPV6_TCLASS, [16], 4) = -1 ENOPROTOOPT (Protocol not available)
* > openat(AT_FDCWD, "/var/run/dropbear.pid", O_WRONLY|O_CREAT|O_TRUNC, 0666) = -1 ENOENT (No such file or directory)
  * This looks promatic.
  * [`/var/run`][rhs-varrun] is for run-time variable data and has since been
    moved to `/run` but Dropbear seems to be following the old ways.
    * It is valid to implement /var/run as a symlink to /run.


## TODO:
* Compare configuration settings to https://github.com/bsbernd/tiny-qemu-virtio-kernel-config
* Consider building own busybox - that could have saved a lot of effort with
  the lack of `ifup`. It may be needed for the `hardshutdown` applet to cause
  the VM to stop - this wasn't needed in the end enabling the APIC allowed
  reboot to do the triple fault.
  * Alternative is try to use `sysctl kernel.reboot=1"` since I turned on the
   `sysctl` config. See https://docs.kernel.org/admin-guide/sysctl/kernel.html
* Set-up GitHub Actions for building the file system and kernel.
* Build BusyBox and Dropbear from source so there is no question about GPL
  conformance.
* Consider addressing the following seen when running `dropbear` (SSH server).
  > setsockopt(4, SOL_IPV6, IPV6_TCLASS, [16], 4) = -1 ENOPROTOOPT (Protocol not available)

## Future Kernel Options

Additional features that I would consider enabling in the future are:
* File system support
    * Provide a place for persistent storage
* Container support (or container kernel variant)
    * Namespace
    * Control groups
* Symmetric multi-processing support
* Linux guest support
* Link Time Optimization (LTO)

## Initial file system

Outside of busybox which populates `/bin`

The folder/file list looks like so
```
./bin/busybox
./bin/... (symlinks to busybox here)
./dev
./root
./sbin
./sbin/init
./etc
./etc/fstab
./etc/hostname
./etc/inittab
./etc/shadow
./etc/environment
./etc/passwd
./etc/group
./init.old
./init
./mystart
./proc
./usr
./usr/sbin
```

Optionally a `/etc/motd` could be provided which will be shown when a user
logins.

# Reminder

Redistributing the kernel and the RAM disk is subject to the licences of
the software that makes it up. For both the Linux kernel and
[BusyBox](https://busybox.net/license.html) that is GNU General Public
License, version 2

[0]: https://www.qemu.org/
[1]: https://www.qemu.org/docs/master/system/i386/microvm.html
[2]: https://www.kernel.org/doc/html/latest/filesystems/ramfs-rootfs-initramfs.html#what-is-initramfs
[3.1]: https://lwn.net/Articles/827334/I
[3.2]: https://www.kernelconfig.io/CONFIG_PRINTK_TIME
[4]: https://www.kernelconfig.io/CONFIG_NETDEVICES
[5]: https://www.kernelconfig.io/CONFIG_VIRTIO_NET
[6]: https://www.kernelconfig.io/CONFIG_VIRTIO_MMIO
[7.1]: https://github.com/bluedragon1221
[7.2]: https://github.com/bluedragon1221/minlinux2
[8]: https://www.kernelconfig.io/CONFIG_EARLY_PRINTK
[9]: https://www.kernelconfig.io/CONFIG_PACKET
[10]: https://www.kernelconfig.io/CONFIG_INET
[11]: https://www.kernelconfig.io/CONFIG_UNIX
[12]: https://www.kernelconfig.io/CONFIG_PROC_SYSCTL
[13]: https://www.kernelconfig.io/CONFIG_HYPERVISOR_GUEST
[14]: https://www.kernelconfig.io/CONFIG_KVM_GUEST?q=&kernelversion=6.18.23&arch=x86
[15]: https://www.qemu.org/docs/master/system/whpx.html
[16]: https://www.kernelconfig.io/CONFIG_X86_MPPARSE
[20]: https://blinry.org/tiny-linux/

[rhs-varrun]: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch05s13.html
[kernel-parameters]: https://www.kernel.org/doc/Documentation/admin-guide/kernel-parameters.rst
[dropbear]: https://matt.ucc.asn.au/dropbear/dropbear.html
