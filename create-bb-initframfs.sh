#!/bin/sh
# Create an initial RAM initramfs
#
# This is a file system in the archive of the `cpio` format which is then
# gzipped (optionally).
# The Linux kernel will extract it into the root file system once it boots up.
#
# In this case it will be formed from "busybox" alone.
#
# This is intended to be run in an container.
#
# This script creates all the files needed rather so it is self-contained in
# this single script, rather than having all the files created elsewhere.
#
# Usage:
# $ podman run --rm -it -v .:/work --workdir /work public.ecr.aws/docker/library/alpine:3.22.4
#
# Testing:
# $ qemu-system-x86_64 -kernel .\\vmlinuz-virt -initrd bbmicrovm-initramfs --append "console=ttyS0" -serial stdio
# Where \vmlinuz-virt is from alpine-netboot instead.
#
# Run on Windows:
# qemu-system-x86_64 -smp 2 -m 512m -append 'console=hvc0 reboot=triple' -kernel .\linux6.18-virtio-donno-net.bzImage -M microvm,rtc=off,acpi=off,pic=on,pit=on,accel=whpx -device virtio-serial-device -chardev stdio,id=virtiocon0,mux=on -device virtconsole,chardev=virtiocon0 -mon chardev=virtiocon0 -device virtio-net-device,netdev=net-uDC8gBXd0 -netdev user,id=net-uDC8gBXd0 -display none -initrd .\bbmicrovm-initramfs
# With ssh support add: hostfwd=tcp::2222-:22 after the net name on -netdev.
#
# Known limitations:
# - The prebuilt binary of 1.35.0 results in: ifup: applet not found.
#    `ip link set eth0 up` is not equivalent it simply switches the state.

NORMAL_USER=donno
# The name of the normal user - this is intended to currently also be a
# GitHub user in order to use the same keys for SSHing.

with_ssh=1
# Include a daemon for allowing SSH access to the instance.

# For general purpose script, the user ID should be validated to make sure it
# doesn't contain spaces.
# https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap03.html#tag_03_437

start=$(pwd)

[ -d /busybox-root ] \
    && echo "Working directory already exists - reusing existing directory." \
    || mkdir /busybox-root
cd /busybox-root
mkdir -p bin dev etc lib mnt proc sys tmp var home run && \
    mkdir -p etc/network etc/init.d var/log

# Use local copy of busybox or download it.
[ -f /work/busybox ] && cp /work/busybox bin/busybox ||
    wget -O bin/busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox

if [ ! -f bin/busybox ]; then
    echo "No busybox found - exiting"
    exit 1
fi

# Set-up symbolic links for the various utility programs to Busybox's applets.
ln -s bin/busybox init
[ -f bin/sh ] \
    && echo "BusyBox links are likely already in place." \
    || (cd bin && ./busybox --list | xargs -n1 -P8 ln -s busybox)

(cd var && [ ! -e run ] && ln -s /run run)
# /var/run was superseded by /run and it is valid to implement /var/run as a
# symlink to /run so that is what is being done.
#
# https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch05s13.html

echo Setting up user and groups.
# Reference: https://www.man7.org/linux/man-pages/man5/passwd.5.html
# Format: name:password:UID:GID:GECOS:directory:shell
cat > etc/passwd << EOF
root:x:0:0:root:/root:/bin/sh
$NORMAL_USER:x:1000:1000:root:/home/$NORMAL_USER:/bin/sh
nobody:x:65534:65534:nobody:/:/sbin/nologin
EOF

# Reference: https://www.man7.org/linux/man-pages/man5/group.5.html
# Format: group_name:password:GID:user_list
cat > etc/group << EOF
root:x:0:root
users:x:100:$NORMAL_USER
nobody:x:65534:
EOF

# Customise this script so it can have a -i / --interactive flag so the user
# that runs this script can be prompted for the password instead.
#
# This needs to be configured due to using /bin/getty below to set-up a login
# terminal instead of automatically providing access to root.
# Reference: https://www.man7.org/linux/man-pages/man5/shadow.5.html
ROOT_PASSWORD=$(mkpasswd busybox)
USER_PASSWORD=$(mkpasswd "$NORMAL_USER")
cat > etc/shadow << EOF
root:$ROOT_PASSWORD:20005::::::
$NORMAL_USER:$USER_PASSWORD:20005::::::
nobody:!::0:::::
EOF

build_dropbear()
{

    echo "  Build dropbear"
    dropbear_build=$(mktemp -d)
    (cd "$dropbear_build" && sh "$start/make-dropbear.sh" /busybox-root/bin)
}

# Set-up SSH.
# - If we were going all out there would bea /etc/skel and it would copy that
#   to the home directory.
#
# Alternative is use the AWK script and users file for the alpine-initrd.
#https://github.com/donno/warehouse51/blob/master/alpine-initrd/process-users.awk
if [ "$with_ssh" = 1 ]; then
    mkdir -p "home/$NORMAL_USER/.ssh"
    wget -O "home/$NORMAL_USER/.ssh/authorized_keys" "https://github.com/$NORMAL_USER.keys"
    chmod 700 home/$NORMAL_USER/.ssh
    chmod 600 home/$NORMAL_USER/.ssh/authorized_keys
    chown -R "1000:100" "home/$NORMAL_USER"

    # Include a SSH server/daemon
    #
    # Builds dropbear from source as the given old static build had issues
    # with user auth and the newer version has new command line options
    # that are used below tto.
    # [ ! -f bin/dropbear ] && \
    #     wget -O bin/dropbear https://static-binaries.gitlab.io/dropbear/dropbear-2019.78.x86_64-linux-android
     [ ! -f bin/dropbear ] && echo "No dropbear found" && build_dropbear
    chmod +x bin/dropbear
    mkdir -p etc/dropbear
fi

echo "/bin/sh" > /etc/shells

echo Setup initial file system mounts - used by "mount -a"
cat > etc/fstab << EOF
#device         mount-point  type      options           dump  fsck order
devtmpfs /dev devtmpfs defaults 0 0
proc /proc proc defaults 0 0
tmpfs /run tmpfs rw,noatime,nosuid,nodev,mode=755 0 0
# There is a symlinked from /var/run to /run configured.
EOF

dhcp=no
if [ -f bin/ifup ]; then
    echo "Configure network interface using /etc/network/interfaces/"
    echo "  This is possible due to the \"ifup\" applet being available."
    if [ "$dhcp" = "yes" ]; then
        echo "  Configuring networking to use DHCP."
        cat > etc/network/interfaces << EOF
auto eth0
iface eth0 inet dhcp
EOF
    else
        echo "  Configuring networking to use static IP for QEMU."
        cat > etc/network/interfaces << EOF
auto eth0
iface eth0 inet static
    address 10.0.2.15
    netmask 255.255.255.0
    gateway 10.0.2.2
    dns-nameservers 10.0.2.3
EOF
    rm -f etc/resolv.conf

    echo "ERROR: The inittab doesn't support this option"
    exit 5
    fi
else
    use_net_script="yes"
    echo "Configure network interface using ip"
    echo "  This because the \"ifup\" applet is missing."
    if [ "$dhcp" = "yes" ]; then
        echo "  Configuring networking to use DHCP."
        rm -f etc/resolv.conf
        cat > etc/init.d/S90setup-network << EOF
ip link set eth0 up
udhcpc -i eth0
ip addr show eth0 2>&1 > /dev/hvc0
EOF
        echo "ERROR: This option doesn't work"
        exit 5
    else
        cat > etc/init.d/S90setup-network << EOF
#!/bin/busybox sh
echo "Configuring networking..." > /dev/hvc0
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
ip link set eth0 mtu 1400
EOF
        echo "nameserver 10.0.2.3" > etc/resolv.conf
        # The above line will use QEMU DNS server to resolve names where
        # the below line will use Google's.
        # echo "nameserver 8.8.8.8" > etc/resolv.conf
        chmod +x etc/init.d/S90setup-network
    fi
fi

# This provides a customisation point which can be modified outside this
# script to try out new ideas.
if [ ! -f mystart.sh ]; then
    cat > mystart.sh << EOF
dmesg > /dev/hvc0
echo Hello from mystart.sh > /dev/hvc0
EOF
fi

echo Define configuration for the init daemon - busybox init.
# TODO: See if /dev/shm can be set-up in the etc/fstab instead.
cat > etc/inittab << EOF
::sysinit:/bin/sh /etc/init.d/rcS
::ctrlaltdel:/bin/reboot
::shutdown:/bin/echo SHUTTING DOWN
::shutdown:/bin/umount -a -r
tty1::respawn:/bin/getty 38400 tty1
tty2::askfirst:/bin/getty 38400 tty2
tty3::askfirst:/bin/getty 38400 tty3
tty4::askfirst:/bin/getty 38400 tty4
EOF

if [ "$with_ssh" = 1 ]; then
    cat > etc/init.d/S91setup-sshd << EOF
#!/bin/busybox sh
echo "Running SSH daemon..." > /dev/hvc0
/bin/dropbear -E -R 2>&1 > /dev/hvc0
EOF
    chmod +x etc/init.d/S91setup-sshd
    # TODO: Consider using -G to limit to a given group and setup a ssh group.
fi

echo Create initial script for init.
cat > etc/init.d/rcS << EOF
#!/bin/busybox sh
/bin/mount -a
/bin/mkdir /dev/shm /dev/pts
/bin/mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /dev/shm
/bin/mount -t devpts -o ptmxmode=666 devpts /dev/pts
/bin/hostname -F /etc/hostname
/bin/ip link set lo up
# Execute all scripts in /etc/init.d starting with 'S'
find /etc/init.d -maxdepth 1 -type f -name 'S??*' -exec /bin/busybox sh {} \;
[ -f /mystart.sh ] && /bin/sh /mystart.sh > /dev/hvc0
EOF
# TThere is a risk of find not being ordered.
#   find /etc/init.d -maxdepth 1 -type f -name 'S??*' -exec {} \;
chmod +x etc/init.d/rcS

# The above lacks the following as the kernel, that I built doesn't include
# support for the pseudo teletype terminal.
#::sysinit:/bin/mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/ptssadw

# Revisit, this later to see if it could come from a kernel command line such
# that it can be set when a virtual machine with this image is started.
echo bbmicrovm > etc/hostname

# Optionally, create a /etc/motd which will appear when a user logins.

# Build the image
build()
{
    echo Creating initial RAM filesystem.
    (cd /busybox-root && find . -not -path "." | cpio -ov --format=newc | gzip --best > /work/bbmicrovm-initramfz && \
        find . -not -path "." | cpio -ov --format=newc > /work/bbmicrovm-initramfs && \
        echo "Built images" || echo "Failed to build image")
}

# Edit a file then rebuild the image -this function is for interactive shell.
edit()
{
    path="$1"
    # If absolute path is given that is fine, otherwise ensure the path
    # is under the busybox root. Alternative is convert $1 to absolute path
    # and confirm it is under /busybox-root
    [ ! -f "$path" ] && path="/busybox-root/$path"
    start_hash=$([ -f "$path" ] && sha256sum "$path" || echo "0000")
    vi "$path"
    end_hash=$([ -f "$path" ] && sha256sum "$path" || echo "0000")
    echo "Editor exited: $start_hash vs $end_hash"
    [ "$start_hash" != "$end_hash" ] && build || echo "No change - no build."
}

build

cd "$start"
