#!/usr/bin/env bash
#
# run_wbpp_chunked.sh
#
# 按“分块”跑 WBPP：绕开 WBPP 的 FastIntegration 自动启用（帧数 >=150 时启用，
# 部分数据集上快速配准会大量丢帧），改用标准 StarAlignment 路径。
#
#   1. 把帧按时间顺序切成 <=CHUNK_SIZE 的小块，每块单独跑 run_wbpp.sh（走标准配准）
#   2. 收集各块 master，按 NGC7380 的既定做法用 strip_cfa_xisf.py 抹掉 CFA 元数据
#   3. 再跑一次 WBPP 把各块 master 合成最终 master
#
# 用法:
#   ./run_wbpp_chunked.sh <src_dir> <work_name> [--chunk-size 140] [--no-cooling]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run_wbpp.sh"
STRIP="$SCRIPT_DIR/strip_cfa_xisf.py"
COOLING_CTL="$SCRIPT_DIR/cooling_ctl.py"
WORK_ROOT="/home/zhao/workspace/seestar_work"
COOLING_DIR="$WORK_ROOT/cooling"

CHUNK_SIZE=140
COOLING_ENABLED=true
COOLING_SNAPSHOT=""

WBPP_PARAMS=(
  -p platesolve=true
  -p platesolveFallbackManual=false
  -p imageRegistration=true
  -p distortionCorrection=false
  -p bestFrameReferenceMethod=1
  -p subframeWeightingEnabled=true
  -p localNormalization=true
  -p localNormalizationInteractiveMode=false
  -p integrate=true
  -p autocrop=true
  -p debayerOutputMethod=0
  -p recombineRGB=false
  -p generateRejectionMaps=false
  -p combination_4=0
  -p rejection_4=5
  -p sigmaLow_4=4.0
  -p sigmaHigh_4=3.0
  -p minWeight=0.05
)

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }

cooling_save_full() {
  [[ "$COOLING_ENABLED" == true ]] || return 0
  [[ -f "$COOLING_CTL" ]] || { COOLING_ENABLED=false; return 0; }
  mkdir -p "$COOLING_DIR"
  COOLING_SNAPSHOT="$COOLING_DIR/pre-wbpp-$(date +%Y%m%d-%H%M%S).json"
  if python3 "$COOLING_CTL" save-full "$COOLING_SNAPSHOT" >/tmp/chunked_cooling.log 2>&1; then
    log "cooling: 泵与风扇已拉满 (快照: $COOLING_SNAPSHOT)"
  else
    log "warning: 强制水冷全速失败"
    rm -f "$COOLING_SNAPSHOT"; COOLING_SNAPSHOT=""; COOLING_ENABLED=false
  fi
}

cooling_restore() {
  if [[ -n "${COOLING_SNAPSHOT:-}" && -f "$COOLING_SNAPSHOT" ]]; then
    local out
    if out="$(python3 "$COOLING_CTL" restore "$COOLING_SNAPSHOT" 2>&1)"; then
      log "cooling: 已恢复到跑 WBPP 前的配置 —— $(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g')"
    else
      err "cooling: 恢复失败: $COOLING_SNAPSHOT"
    fi
    ls -1t "$COOLING_DIR"/pre-wbpp-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
    COOLING_SNAPSHOT=""
  fi
}
trap cooling_restore EXIT

run_wbpp() {   # $1=lights dir  $2=out dir  $3=log file
  local lights="$1" out="$2" logs="$3"
  ( cd "$SCRIPT_DIR" && env -u DISPLAY "$RUNNER" \
      --light-dir "$lights" -o "$out" "${WBPP_PARAMS[@]}" -v > "$logs" 2>&1 )
}

find_master() { find "$1" -maxdepth 1 -name 'masterLight_BIN-1*.xisf' ! -name '*_autocrop.xisf' -print -quit 2>/dev/null; }

main() {
  local src="" name=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --chunk-size) CHUNK_SIZE="${2:?}"; shift 2 ;;
      --no-cooling) COOLING_ENABLED=false; shift ;;
      -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
      -*) err "未知选项: $1"; exit 1 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ ${#positional[@]} -eq 2 ]] || { sed -n '2,20p' "$0"; exit 2; }
  src="${positional[0]}"; name="${positional[1]}"

  [[ -d "$src" ]] || { err "源目录不存在: $src"; exit 1; }
  [[ -x "$RUNNER" ]] || { err "run_wbpp.sh 不可执行"; exit 1; }

  local work="$WORK_ROOT/${name}_chunked"
  local final_master="$work/final/out/master"

  if [[ -n "$(find_master "$final_master")" ]]; then
    log "skip $name: 最终 master 已存在 ($(find_master "$final_master"))"
    exit 0
  fi

  mkdir -p "$work"
  find "$src" -maxdepth 1 -name '*.fit' | sort > "$work/all_lights.txt"
  local total
  total="$(wc -l < "$work/all_lights.txt" | tr -d ' ')"
  [[ "$total" -ge 2 ]] || { err "帧数不足: $total"; exit 1; }

  local nchunks=$(( (total + CHUNK_SIZE - 1) / CHUNK_SIZE ))
  log "目标 $name: $total 帧 -> $nchunks 块（每块 <= $CHUNK_SIZE 帧，强制标准配准）"
  cooling_save_full

  local i=0
  rm -f "$work"/chunklist_*.txt
  split -l "$CHUNK_SIZE" -d --additional-suffix=.txt "$work/all_lights.txt" "$work/chunklist_"
  for cfile in "$work"/chunklist_*.txt; do
    i=$((i + 1))
    local cdir="$work/$(printf 'chunk%02d' "$i")"
    local clights="$cdir/lights"
    local cout="$cdir/out"
    if [[ -n "$(find_master "$cout/master")" ]]; then
      log "chunk$i: 已有 master，跳过"
      continue
    fi
    rm -rf "$cdir"
    mkdir -p "$clights" "$cout"
    while IFS= read -r f; do cp "$f" "$clights/"; done < "$cfile"
    local cnt
    cnt="$(find "$clights" -maxdepth 1 -name '*.fit' | wc -l | tr -d ' ')"
    log "=== chunk$i: $cnt 帧 -> WBPP ==="
    if ! run_wbpp "$clights" "$cout" "$cdir/run.log"; then
      err "chunk$i WBPP 失败，见 $cdir/run.log"
      exit 1
    fi
    local cmaster
    cmaster="$(find_master "$cout/master")"
    [[ -n "$cmaster" ]] || { err "chunk$i 没有产出 master"; exit 1; }
    local rate
    rate="$(grep -hE 'Registration completed|success rate' "$(ls -t "$cout/logs/"*.log | head -1)" | tail -1)"
    log "chunk$i DONE: $(basename "$cmaster")  [$rate]"
    rm -rf "$cout/debayered" "$cout/registered" "$cout/drizzle" "$clights"
  done

  # 收集各块 master -> strip CFA 元数据 -> 最终合并
  local fl="$work/final/lights"
  rm -rf "$work/final"
  mkdir -p "$fl" "$work/final/out"
  i=0
  for m in "$work"/chunk*/out/master/masterLight_BIN-1*.xisf; do
    [[ -f "$m" ]] || continue
    case "$m" in *_autocrop.xisf) continue ;; esac
    i=$((i + 1))
    cp "$m" "$fl/$(printf 'chunk%02d_' "$i")$(basename "$m")"
  done
  [[ "$i" -ge 2 ]] || { err "有效 master 不足（$i 张），无法合并"; exit 1; }
  log "=== 合并 $i 张 chunk master（先抹除 CFA 元数据）==="
  python3 "$STRIP" "$fl"/*.xisf >/dev/null 2>&1 || log "warning: strip_cfa_xisf.py 返回非 0"

  if ! run_wbpp "$fl" "$work/final/out" "$work/final/run.log"; then
    err "最终合并失败，见 $work/final/run.log"
    exit 1
  fi
  local fmaster
  fmaster="$(find_master "$final_master")"
  [[ -n "$fmaster" ]] || { err "最终没有产出 master"; exit 1; }
  log "=== $name 完成: $fmaster ==="
}

main "$@"
