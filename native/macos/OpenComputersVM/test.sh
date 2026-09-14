#!/bin/sh
set -eu
vm_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$vm_dir/.build"
swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  "$vm_dir/Sources/Protocol.swift" "$vm_dir/tests/ProtocolTests.swift" \
  -o "$vm_dir/.build/ProtocolTests"
"$vm_dir/.build/ProtocolTests"
swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  "$vm_dir/Sources/Protocol.swift" "$vm_dir/Sources/OwnedStore.swift" "$vm_dir/tests/StoreTests.swift" \
  -o "$vm_dir/.build/StoreTests"
"$vm_dir/.build/StoreTests"
sh "$vm_dir/build.sh"
python3 "$vm_dir/tests/helper_protocol.py" "$vm_dir/.build/osa-opencomputers-vm"
