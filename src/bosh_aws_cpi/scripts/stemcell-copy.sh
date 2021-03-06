#!/bin/sh
#
# This script runs as root through sudo without the need for a password,
# so it needs to make sure it can't be abused.
#

# make sure we have a secure PATH
PATH=/bin:/usr/bin
export PATH
if [ $# -ne 2 ]; then
  echo "usage: $0 <image-file> <block device>"
  exit 1
fi

IMAGE="$1"
OUTPUT="$2"

# workaround for issue on 12.04 LTS, use LANG=C
echo ${IMAGE} | LANG=C egrep '^/[A-Za-z0-9_/-]+/image$' > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: illegal image file: ${IMAGE}"
  exit 1
fi

echo ${OUTPUT} | egrep '^/dev/[svx]+d[a-z0-9]+$' > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: illegal device: ${OUTPUT}"
  exit 1
fi

if [ ! -b ${OUTPUT} ]; then
  echo "ERROR: not a device: ${OUTPUT}"
  exit 1
fi

# copy image to block device with 1 MB block size
tar -xzf ${IMAGE} -O root.img | dd bs=1M of=${OUTPUT}
