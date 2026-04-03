#!/bin/sh

DEST=~/wksp/buildroot

echo "Export sysroot to $DEST"

rm -rf $DEST
cp -a $STAGING_DIR $DEST
