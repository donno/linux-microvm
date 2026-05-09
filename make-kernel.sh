#!/bin/sh
# Build the Linux Kernel favouring QEMU's microvm machine type.
#
# podman run --rm -it -v .:/work --workdir /work public.ecr.aws/docker/library/alpine:3.22.4

echo Install packages required to configure and build kernel
apk add --no-cache alpine-sdk flex bison gawk bc ncurses-dev elfutils-dev git || exit 1
# git - for cloning the Linux kernel. The alternative would be to use a tar
# elfutils-dev - needed for gelf.h
# ncurses-dev - needed by "make menuconfig"

echo Cloning Linux kernel repository
git clone --depth 1 --branch "v6.18" https://github.com/torvalds/linux /linux || exit 1

if [ -f .config ]; then
    echo Using existing .config
    make oldconfig
else
    make tinyconfig
    # Configure
    make menuconfig
fi
make -j4
