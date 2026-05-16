#!/bin/sh
# Build the Linux Kernel favouring QEMU's microvm machine type.
#
# podman run --rm -it -v .:/work --workdir /work public.ecr.aws/docker/library/alpine:3.22.4

VERSION=6.18
echo Install packages required to configure and build kernel
apk add --no-cache alpine-sdk flex bison gawk bc ncurses-dev elfutils-dev linux-headers perl git || exit 1
# flex - the build system generates lexical analysers during build.
# bison - the build system generates parsers during build
# gawk - needs it.
# ncurses-dev - needed by "make menuconfig"
# elfutils-dev - needed for gelf.h
# linux-headers - for "asm/types.h" and other headers required.
# perl - for perl used by PERLASM
# git - for cloning the Linux kernel. The alternative would be to use a tar

echo Cloning Linux kernel repository
git clone --depth 1 --branch "v$VERSION" https://github.com/torvalds/linux /linux || exit 1

start=$(pwd)
cp microvm.config /linux/.config
cd /linux

if [ -f .config ]; then
    echo Using existing .config
    make oldconfig
else
    make tinyconfig
    # Configure
    make menuconfig
fi

echo Building the Linux Kernel.
make -j4
if [ $? != 0 ];
then
    echo "Failed to build the Linux Kernel."
    exit 2
fi

cp arch/x86/boot/bzImage $(start)/microvm.bzImage &&  \
    cp .config $(start)/microvm.config && \
    cp System.map $(start)/microvm.System.map && \
    echo "Copied kernel files" || exit 3
