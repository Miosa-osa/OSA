#!/bin/sh
set -eu
vm_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$vm_dir/.build"
swiftc -parse-as-library -swift-version 5 -O -warnings-as-errors \
  -target arm64-apple-macosx13.0 -framework Virtualization \
  "$vm_dir"/Sources/*.swift -o "$vm_dir/.build/osa-opencomputers-vm"
echo "$vm_dir/.build/osa-opencomputers-vm"
