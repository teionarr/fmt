#!/usr/bin/env bash
# Islo-vs-baselines benchmark. Same script in every environment.
# usage: bench.sh <mode> <env-label>
#   full        env_info, deps, clone, configure, build_cold, test, build_warm, test, incr  (fmt)
#   ci-resume   ephemeral-CI analog of "resume": deps, clone, configure, build (restored cache), test, incr
#   resume      persistent-env resume: env_info + bg-process check + incr (repo already present)
#   start-bg    start a heartbeat process (to test "processes survive pause/resume")
#   opencv      env_info, deps, OpenCV 5.0.0 locked config: build_cold, build_warm (-j$JOBS)
#   py-full     FastAPI 0.141.1: env_info, uv, clone, install_cold (empty uv cache), test, install_warm, edit+test
#   py-ci-resume  ephemeral analog: uv, clone, install (restored uv cache), test, edit+test
#   py-resume   persistent-env resume: env_info + bg-process check + edit+test (venv already present)
# Output: one JSON line per phase to stdout and to $W/results.jsonl
set -uo pipefail
MODE=${1:?mode}; ENV=${2:?env-label}
JOBS=${JOBS:-4}
W=${BENCH_DIR:-$HOME/bench}; mkdir -p "$W"
export CCACHE_DIR=${CCACHE_DIR:-$HOME/.ccache-bench} CCACHE_MAXSIZE=3G
FMT_REPO=https://github.com/teionarr/fmt.git; FMT_REF=bench-v1
export UV_CACHE_DIR=${UV_CACHE_DIR:-$HOME/.cache/uv-bench} UV_PYTHON_INSTALL_DIR=$HOME/.uv-python
UV_VERSION=0.12.19; PY_REF=0.141.1
SUDO=; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo -n"

now() { date +%s.%N; }
emit() { # phase start end ok extra-json
  local line; line=$(printf '{"env":"%s","mode":"%s","phase":"%s","start":%s,"end":%s,"secs":%.2f,"ok":%s%s}' \
    "$ENV" "$MODE" "$1" "$2" "$3" "$(awk "BEGIN{print $3 - $2}")" "$4" "${5:-}")
  echo "$line" | tee -a "$W/results.jsonl"
}
# run a phase: captures wall + CPU (user+sys of children) via bash `time`
phase() { # name cmd...
  local name=$1; shift; local s e rc t
  s=$(now); t=$( { TIMEFORMAT='%U %S'; time "$@" >"$W/$name.log" 2>&1; } 2>&1 ); rc=$?; e=$(now)
  set -- $t; emit "$name" "$s" "$e" "$([ $rc -eq 0 ] && echo true || echo false)" ",\"cpu_user\":${1:-0},\"cpu_sys\":${2:-0}"
  if [ $rc -ne 0 ]; then echo "PHASE FAILED: $name (rc=$rc)" >&2; tail -20 "$W/$name.log" >&2; exit 3; fi  # fail fast: no silent 'success'
  return 0
}
jsonstr() { printf '%s' "$1" | tr -d '\n"\\' | cut -c1-200; }

env_info() {
  local s; s=$(now)
  local model; model=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2;exit}')
  local virt; virt=$(systemd-detect-virt 2>/dev/null || cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
  local ib; ib=$( (command -v ib_console ibconsole xgConsole 2>/dev/null; ls -d /opt/incredibuild* 2>/dev/null) | tr '\n' ' ')
  local tools=""; for t in cmake ninja ccache g++ clang++ git; do tools="$tools $t=$(command -v $t >/dev/null && ($t --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) || echo -)"; done
  emit env_info "$s" "$(now)" true ",\"nproc\":$(nproc),\"cpu_model\":\"$(jsonstr "$model")\",\"mem_mb\":$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo),\"swap_mb\":$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo),\"kernel\":\"$(uname -r)\",\"boot_id\":\"$(cat /proc/sys/kernel/random/boot_id)\",\"uptime_s\":$(awk '{print int($1)}' /proc/uptime),\"virt\":\"$(jsonstr "$virt")\",\"os\":\"$(. /etc/os-release 2>/dev/null; jsonstr "${PRETTY_NAME:-unknown}")\",\"root\":$([ "$(id -u)" -eq 0 ] && echo true || echo false),\"incredibuild\":\"$(jsonstr "$ib")\",\"tools\":\"$(jsonstr "$tools")\""
}

deps() { # install only what's missing (never pay for preinstalled tools)
  local need=""; for t in cmake ninja ccache g++ git; do command -v $t >/dev/null || need="$need $t"; done
  [ -z "$need" ] && return 0
  if command -v apt-get >/dev/null; then
    local pk=${need/ninja/ninja-build}; $SUDO apt-get update -qq && $SUDO apt-get install -y -qq $pk
  elif command -v dnf >/dev/null; then local pk=${need/ninja/ninja-build}; pk=${pk/g++/gcc-c++}; $SUDO dnf install -y -q $pk
  elif command -v apk >/dev/null; then $SUDO apk add -q ${need/g++/build-base} ${need/ninja/samurai}
  else echo "no known package manager for:$need" >&2; return 1; fi
}

clone_fmt() { rm -rf "$W/fmt"; git clone -q --depth 1 --branch "$FMT_REF" "$FMT_REPO" "$W/fmt"; }
configure_fmt() { cmake -S "$W/fmt" -B "$W/fmt/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER_LAUNCHER=ccache; }
build_fmt() { ninja -C "$W/fmt/build" -j"$JOBS"; }
test_fmt() { # pass only if all tests pass; record the count
  (cd "$W/fmt/build" && ctest -j"$JOBS" --output-on-failure) > "$W/ctest.out" 2>&1; local rc=$?
  grep -oE '[0-9]+% tests passed, [0-9]+ tests failed out of [0-9]+' "$W/ctest.out" | tail -1 > "$W/ctest.sum"; return $rc; }
tests_json() { local t; t=$(cat "$W/ctest.sum" 2>/dev/null); echo ",\"tests\":\"$t\""; }
cc_json() { ccache -s 2>/dev/null | awk '/Hits:/ && !h {h=$2" of "$4} /Misses:/ && !m {m=$2} END{printf ",\"ccache_hits\":\"%s\",\"ccache_misses\":\"%s\"",h,m}'; }
sha_json() { echo ",\"commit\":\"$(git -C "$W/fmt" rev-parse --short HEAD 2>/dev/null)\""; }
incr() { # a real edit changes CODE: touch = ccache hit; a comment = hit too (ccache hashes preprocessed source)
  local n; n=$(date +%s%N)
  echo "namespace { [[maybe_unused]] volatile int bench_edit_$n = 1; }" >> "$W/fmt/src/format.cc" && build_fmt && test_fmt; }

bg_check() { # is the heartbeat process from start-bg still alive, and when did it last beat?
  local pid alive=false gap=-1
  pid=$(cat "$W/bg.pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null && alive=true
  [ -f "$W/heartbeat" ] && gap=$(( $(date +%s) - $(cat "$W/heartbeat") ))
  local s; s=$(now); emit bg_check "$s" "$s" true ",\"bg_alive\":$alive,\"heartbeat_age_s\":$gap"
}

# ---- Python workload (FastAPI, uv-locked deps; uv also installs Python 3.11 itself) ----
uv_bin() { command -v uv 2>/dev/null || echo "$HOME/.local/bin/uv"; }
get_uv() { [ -x "$(uv_bin)" ] && "$(uv_bin)" --version | grep -q "$UV_VERSION" && return 0
  curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" | env UV_NO_MODIFY_PATH=1 sh; }
clone_py() { rm -rf "$W/fastapi"; git clone -q --depth 1 --branch "$PY_REF" https://github.com/fastapi/fastapi.git "$W/fastapi"; }
install_py() { (cd "$W/fastapi" && "$(uv_bin)" sync --frozen --no-dev --group tests --extra all); }
test_py() { (cd "$W/fastapi" && PYTHONPATH=./docs_src "$(uv_bin)" run --no-sync pytest -q -p no:cacheprovider -n "$JOBS" --dist loadgroup tests scripts/tests/) > "$W/pytest.out" 2>&1; local rc=$?
  tail -1 "$W/pytest.out" | tr -d '=' | sed 's/^ *//' > "$W/pytest.sum"; return $rc; }
pytests_json() { echo ",\"tests\":\"$(cat "$W/pytest.sum" 2>/dev/null)\""; }
edit_py() { echo "# bench edit $(date +%s%N)" >> "$W/fastapi/fastapi/routing.py" && test_py; }

case "$MODE" in
  full)
    env_info
    phase deps deps
    phase clone clone_fmt
    phase configure configure_fmt
    ccache -C >/dev/null 2>&1; ccache -z >/dev/null 2>&1
    phase build_cold build_fmt; phase test test_fmt; emit test_result "$(now)" "$(now)" true "$(tests_json)$(cc_json)$(sha_json)"
    ninja -C "$W/fmt/build" -t clean >/dev/null; ccache -z >/dev/null 2>&1
    phase build_warm build_fmt; emit warm_ccache "$(now)" "$(now)" true "$(cc_json)"
    ccache -z >/dev/null 2>&1; phase incr incr; emit incr_result "$(now)" "$(now)" true "$(tests_json)$(cc_json)" ;;
  ci-resume)
    env_info; ccache -z >/dev/null 2>&1
    phase deps deps; phase clone clone_fmt; phase configure configure_fmt
    phase build_restored build_fmt; emit restored_ccache "$(now)" "$(now)" true "$(cc_json)"
    ccache -z >/dev/null 2>&1; phase incr incr; emit incr_result "$(now)" "$(now)" true "$(tests_json)$(cc_json)$(sha_json)" ;;
  start-bg)
    nohup bash -c "while :; do date +%s > '$W/heartbeat'; sleep 1; done" >/dev/null 2>&1 &
    echo $! > "$W/bg.pid"; sleep 2; bg_check ;;
  resume)
    env_info; bg_check; ccache -z >/dev/null 2>&1
    [ -d "$W/fmt/build" ] && emit files_intact "$(now)" "$(now)" true || emit files_intact "$(now)" "$(now)" false
    phase incr incr; emit incr_result "$(now)" "$(now)" true "$(tests_json)$(cc_json)" ;;
  opencv)
    env_info; phase deps deps
    rm -rf "$W/opencv"; phase clone_opencv git clone -q --depth 1 --branch 5.0.0 https://github.com/opencv/opencv.git "$W/opencv"
    phase configure_opencv cmake -S "$W/opencv" -B "$W/opencv/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_LIST=core,imgproc,imgcodecs,features,geometry,calib,dnn -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
      -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF -DBUILD_opencv_python3=OFF -DBUILD_DOCS=OFF \
      -DENABLE_CCACHE=ON -DOPENCV_PYTHON_SKIP_DETECTION=ON
    ccache -C >/dev/null 2>&1; ccache -z >/dev/null 2>&1
    phase opencv_cold ninja -C "$W/opencv/build" -j"$JOBS"
    ninja -C "$W/opencv/build" -t clean >/dev/null; ccache -z >/dev/null 2>&1
    phase opencv_warm ninja -C "$W/opencv/build" -j"$JOBS"; emit opencv_ccache "$(now)" "$(now)" true "$(cc_json)" ;;
  py-full)
    env_info; phase uv get_uv; phase py_clone clone_py
    rm -rf "$UV_CACHE_DIR"; phase py_install_cold install_py
    phase py_test test_py; emit py_test_result "$(now)" "$(now)" true "$(pytests_json),\"python\":\"$("$W/fastapi/.venv/bin/python" -c 'import sys;print(sys.version.split()[0], sys.base_prefix)' 2>/dev/null)\""
    rm -rf "$W/fastapi/.venv"; phase py_install_warm install_py
    phase py_edit_test edit_py; emit py_edit_result "$(now)" "$(now)" true "$(pytests_json)" ;;
  py-ci-resume)
    env_info; phase uv get_uv; phase py_clone clone_py; phase py_install_restored install_py
    phase py_test test_py; phase py_edit_test edit_py; emit py_edit_result "$(now)" "$(now)" true "$(pytests_json)" ;;
  py-resume)
    env_info; bg_check
    [ -d "$W/fastapi/.venv" ] && emit files_intact "$(now)" "$(now)" true || emit files_intact "$(now)" "$(now)" false
    phase py_edit_test edit_py; emit py_edit_result "$(now)" "$(now)" true "$(pytests_json)" ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
