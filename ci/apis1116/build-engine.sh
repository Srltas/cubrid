#!/bin/bash
# build-engine.sh base|patched: builds the checked-out engine (debug) and installs it into $CUBRID.
# base is a full build.sh build; patched rebuilds only what the patch changed, on top of it.
source "$(dirname "$0")/common.sh"
phase=${1:?base or patched}
cd "$SRC" || exit 1
build_log=$OUT/build-$phase.log

# The manager server is not part of these checks, and up to 11.3 it does not link in this image.
cmake_options="-DWITH_CMSERVER=OFF"
options=()
case $VERSION in
  11.3) options=(-g ninja) ;;
  11.2)
    # The bundled libraries of 11.2 call a bare `make`, which cannot join the parent's job server.
    MAKEFLAGS=-j$(nproc)
    export PATH=$CI_DIR/bin:$PATH MAKEFLAGS
    cmake_options="$cmake_options -DCMAKE_MAKE_PROGRAM=/usr/bin/gmake"
    ;;
esac

log "$phase build: stopping CUBRID"
server_stop
log "$phase build: building"
if [ "$phase" = base ]; then
  ./build.sh "${options[@]}" -c "$cmake_options" -m debug -b "$BUILD" -p "$CUBRID" build > "$build_log" 2>&1
else
  cmake --build "$BUILD" > "$build_log" 2>&1 &&
    { log "$phase build: installing"; cmake --build "$BUILD" --target install >> "$build_log" 2>&1; }
fi
rc=$?

if [ $rc -ne 0 ] && [ "$VERSION" = 11.2 ]; then
  log "the parallel build failed ($rc), finishing it without parallel jobs"
  unset MAKEFLAGS
  { cmake --build "$BUILD" && cmake --build "$BUILD" --target install; } >> "$build_log" 2>&1
  rc=$?
fi
if [ $rc -ne 0 ]; then
  mkdir -p "$OUT/build-logs"
  find "$BUILD" -path '*Stamp*' -name '*.log' -exec cp {} "$OUT/build-logs/" ';' 2> /dev/null
  tail -60 "$build_log"
  echo "::error::the $phase build failed"
  exit $rc
fi

ccache -s 2> /dev/null | grep -E 'cache hit|cache miss' || true
log "$phase build installed: $(cubrid_rel 2> /dev/null | grep -o 'CUBRID [^)]*)' | head -1)"
