#!/bin/sh
# Build the Dropbox
#
# usage: make-dropbear.sh [target-directory]
#
# Consider adding MULTI=1, to build both client and server in same executable.

VERSION=2026.91
TAR_SHA256=defa924475abf6bc1e74abc00173e46bfdc804bd47caafa14f5a4ef0cc76da34
echo Install packages required to configure and build dropbear
apk add --no-cache --quiet gcc musl-dev zlib-dev zlib-static make || exit 1
# gcc for the C compiler.
# musl-dev for the C runtime.
# zlib-dev for the headers for zlib.
# zlib-static for libz (zlib).
# make for GNU Make (build system).

check_download()
{
    echo "$TAR_SHA256 source.tar.bz2" | sha256sum -c > /dev/null
}

download()
{
    echo "Fetching dropbear $VERSION source code"
    wget -O source.tar.bz2 "https://matt.ucc.asn.au/dropbear/releases/dropbear-$VERSION.tar.bz2"
    if [ $? != 0 ];
    then
        echo "  Download failed - Aborting"
        exit 1
    fi
    check_download
}

[ -f "source.tar.bz2" ] && check_download || download

echo "Extracting source"
tar xf source.tar.bz2 || exit 1

echo "Building dropbear"
cd "dropbear-$VERSION" 
./configure --enable-static
make -

./dropbear -V 2> /dev/null > /dev/null
if [ $? != 0 ];
then
    echo "Dropbear failed to run."
    exit 2
fi

[ $# -eq 1 ] && cp ./dropbear "$1/dropbear" && echo "copied dropbear to $1"

echo "dropbear is ready"
