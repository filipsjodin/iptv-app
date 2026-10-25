#!/usr/bin/env bash
# Source before running swift locally on Windows: source scripts/swift-env.sh
# No-op on other systems (macOS/Linux have swift on PATH).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    _swift_root="$(cygpath -u "$LOCALAPPDATA")/Programs/Swift"
    export SDKROOT="$LOCALAPPDATA/Programs/Swift/Platforms/6.4.1/Windows.platform/Developer/SDKs/Windows.sdk/"
    export PATH="$_swift_root/Toolchains/6.4.1+Asserts/usr/bin:$_swift_root/Runtimes/6.4.1/usr/bin:$PATH"
    unset _swift_root
    ;;
esac
