#!/bin/bash
# Builds and runs the service tests against the real app sources, with Apple's
# frameworks replaced by the fakes in Stubs/. Needs Swift 6.2 on Linux or WSL.
#
#   Tests/run.sh [phone|watch|both] [test name prefix ...]
#   SWIFTC=/path/to/swiftc Tests/run.sh phone relay.
set -u

SWIFTC=${SWIFTC:-swiftc}
TESTS=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$TESTS")
OUT=${XDG_CACHE_HOME:-$HOME/.cache}/tvremote-tests
FLAGS="-swift-version 5 -default-isolation MainActor
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature MemberImportVisibility
  -enable-upcoming-feature DisableOutwardActorInference
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability
  -enable-upcoming-feature InferSendableFromCaptures
  -suppress-warnings"

which=${1:-both}
[ $# -gt 0 ] && shift

build_stubs() {
  rm -rf "$OUT/stubs"
  for platform in ios watchos; do
    dir=$OUT/stubs/$platform
    mkdir -p "$dir"
    extra=""
    [ "$platform" = watchos ] && extra="-D STUB_WATCHOS"
    for module in os Security CryptoKit UIKit WatchConnectivity Network; do
      [ "$platform" = watchos ] && [ "$module" = UIKit ] && continue
      "$SWIFTC" -swift-version 5 -parse-as-library -wmo -emit-library -static \
        -module-name "$module" $extra -I "$dir" \
        -emit-module-path "$dir/$module.swiftmodule" -o "$dir/lib$module.a" \
        "$TESTS/Stubs/$module.swift" || exit 1
    done
  done
}

build_phone() {
  src=$OUT/src_phone
  rm -rf "$src" "$OUT/phone_tests"
  mkdir -p "$src"
  cp "$ROOT"/TVRemote/Models/*.swift "$ROOT"/TVRemote/Services/*.swift "$src/"
  # The keychain code needs the real Security framework, so a fake stands in.
  rm "$src/CertificateManager.swift"
  # sa_family is a UInt16 on Linux and a UInt8 on Apple platforms.
  sed -i 's/saCopy.sa_family == UInt8(AF_INET)/saCopy.sa_family == sa_family_t(AF_INET)/' "$src/BonjourDiscovery.swift"
  cp "$TESTS"/Stubs/FoundationShims.swift "$TESTS"/Suites/Harness.swift "$TESTS"/Suites/ConnTests.swift \
     "$TESTS"/Suites/FakesPhone.swift "$TESTS"/Suites/PhoneTests.swift "$TESTS"/Suites/PhoneExtra.swift "$src/"
  cp "$TESTS"/Suites/main_phone.swift "$src/main.swift"
  "$SWIFTC" -Onone -o "$OUT/phone_tests" $FLAGS -I "$OUT/stubs/ios" -L "$OUT/stubs/ios" "$src"/*.swift \
    -lNetwork -lWatchConnectivity -lUIKit -lCryptoKit -lSecurity -los || exit 1
}

build_watch() {
  src=$OUT/src_watch
  rm -rf "$src" "$OUT/watch_tests"
  mkdir -p "$src"
  cp "$ROOT/TVRemote Watch App/Models/"*.swift "$ROOT/TVRemote Watch App/Services/"*.swift "$src/"
  rm "$src/WatchCertificateStore.swift"
  cp "$TESTS"/Suites/Harness.swift "$TESTS"/Suites/ConnTests.swift "$TESTS"/Suites/FakesWatch.swift \
     "$TESTS"/Suites/WatchTests.swift "$src/"
  cp "$TESTS"/Suites/main_watch.swift "$src/main.swift"
  "$SWIFTC" -Onone -o "$OUT/watch_tests" $FLAGS -I "$OUT/stubs/watchos" -L "$OUT/stubs/watchos" "$src"/*.swift \
    -lNetwork -lWatchConnectivity -lSecurity -los || exit 1
}

run() {
  binary=$1
  shift
  # HOME points here so UserDefaults starts empty and stays out of the real home.
  (cd "$OUT" && HOME=$OUT "$OUT/$binary" "$@" 2>&1 | grep -vE '^\[(DISC|PAIR|CONN)\]'; exit "${PIPESTATUS[0]}")
  status=$?
  echo "$binary exit $status"
  return $status
}

mkdir -p "$OUT"
build_stubs
result=0
case $which in
  phone) build_phone; run phone_tests "$@" || result=1 ;;
  watch) build_watch; run watch_tests "$@" || result=1 ;;
  both)
    build_phone
    build_watch
    run phone_tests "$@" || result=1
    run watch_tests "$@" || result=1
    ;;
  *) echo "usage: $0 [phone|watch|both] [test name prefix ...]"; exit 2 ;;
esac
exit $result
