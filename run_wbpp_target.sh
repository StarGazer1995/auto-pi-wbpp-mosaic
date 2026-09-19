#!/usr/bin/env bash
#
# run_wbpp_target.sh
#
# 通用版：把一个目标目录（NAS 上的 Seestar 光帧）用 WBPP 无头叠加成 master。
#   复制到本地 -> run_wbpp.sh(debayer/配准/LN/积分/autocrop) -> 保留 master -> 清理中间产物
#
# 与 run_all_seestar_nights.sh 的区别：那个按“夜晚”拆分 NGC 7380，这个按“目标”处理任意目录。
#
# 用法:
#   ./run_wbpp_target.sh <src_dir> <work_name> [--mode full|pcore|ecore] [--no-cooling] [--no-platesolve]
#   例: ./run_wbpp_target.sh "/home/zhao/nas/media/activities/IC 443_sub" ic443
#
# 幂等: 已有 masterLight 的目标自动跳过。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run_wbpp.sh"
WORK_ROOT="/home/zhao/workspace/seestar_work"

# 光帧扩展名：FITS + RAW（单反/微单）
LIGHT_EXTS=( -iname '*.fit' -o -iname '*.fits' -o -iname '*.fts'
             -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.cr3' -o -iname '*.nef'
             -o -iname '*.nrw' -o -iname '*.dng' -o -iname '*.raf' -o -iname '*.rw2'
             -o -iname '*.orf' -o -iname '*.pef' -o -iname '*.srw' )

CPU_MODE="${WBPP_MODE:-full}"
COOLING_ENABLED=true
NO_PLATESOLVE=false
COOLING_CTL="$SCRIPT_DIR/cooling_ctl.py"
COOLING_SNAPSHOT=""
COOLING_DIR="$WORK_ROOT/cooling"
CPU_ARGS=()

# 与 NGC 7380 / IC 5070 验证一致的 WBPP 参数
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

if [[ "$NO_PLATESOLVE" == true ]]; then
  WBPP_PARAMS=( "${WBPP_PARAMS[@]/platesolve=true/platesolve=false}" )
fi

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }

cooling_save_full() {
  [[ "$COOLING_ENABLED" == true ]] || return 0
  if [[ ! -f "$COOLING_CTL" ]]; then
    log "warning: 找不到 $COOLING_CTL，跳过水冷全速"
    COOLING_ENABLED=false
    return 0
  fi
  mkdir -p "$COOLING_DIR"
  COOLING_SNAPSHOT="$COOLING_DIR/pre-wbpp-$(date +%Y%m%d-%H%M%S).json"
  if python3 "$COOLING_CTL" save-full "$COOLING_SNAPSHOT" >/tmp/wbpp_target_cooling.log 2>&1; then
    log "cooling: 泵与风扇已拉满 (快照: $COOLING_SNAPSHOT)"
  else
    log "warning: 强制水冷全速失败: $(tail -n 1 /tmp/wbpp_target_cooling.log 2>/dev/null)"
    rm -f "$COOLING_SNAPSHOT"; COOLING_SNAPSHOT=""; COOLING_ENABLED=false
  fi
}

cooling_restore() {
  if [[ -n "${COOLING_SNAPSHOT:-}" && -f "$COOLING_SNAPSHOT" ]]; then
    local out
    if out="$(python3 "$COOLING_CTL" restore "$COOLING_SNAPSHOT" 2>&1)"; then
      log "cooling: 已恢复到跑 WBPP 前的配置 —— $(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g')"
    else
      err "cooling: 恢复失败: $COOLING_SNAPSHOT —— $(printf '%s' "$out" | tail -n 1)"
    fi
    ls -1t "$COOLING_DIR"/pre-wbpp-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
    COOLING_SNAPSHOT=""
  fi
}
trap cooling_restore EXIT

target_is_done() {
  find "$WORK_ROOT/$1/out/master" -maxdepth 1 -name 'masterLight_BIN-1*.xisf' \
       ! -name '*_autocrop.xisf' -print -quit 2>/dev/null | grep -q .
}

process_target() {
  local src="$1" name="$2"
  local dir="$WORK_ROOT/$name"
  local lights="$dir/lights"
  local out="$dir/out"

  [[ -d "$src" ]] || { err "源目录不存在: $src"; return 1; }
  if target_is_done "$name"; then
    log "skip $name: masterLight 已存在"
    return 0
  fi

  local count
  count="$(find "$src" -maxdepth 1 -type f \( "${LIGHT_EXTS[@]}" \) 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -ge 2 ]] || { err "$name: 只有 $count 帧，跳过"; return 1; }

  rm -rf "$dir"
  mkdir -p "$lights" "$out"
  log "=== $name: 复制 $count 帧 ==="
  find "$src" -maxdepth 1 -type f \( "${LIGHT_EXTS[@]}" \) -exec cp {} "$lights/" \;

  log "=== $name: WBPP 开始 ==="
  local rc=0
  if ! ( cd "$SCRIPT_DIR" && env -u DISPLAY "$RUNNER" \
        --light-dir "$lights" -o "$out" "${CPU_ARGS[@]}" "${WBPP_PARAMS[@]}" \
        -v > "$dir/run.log" 2>&1 ); then
    rc=$?
  fi
  if [[ $rc -ne 0 ]] || ! target_is_done "$name"; then
    err "$name FAILED (rc=${rc:-0}). log: $dir/run.log"
    return 1
  fi

  rm -rf "$out/debayered" "$out/registered" "$out/drizzle" "$lights"
  log "=== $name DONE: master in $out/master ==="
  return 0
}

main() {
  local src="" name=""
  local targets=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) CPU_MODE="${2:?usage: --mode full|pcore|ecore}"; shift 2 ;;
      --no-cooling) COOLING_ENABLED=false; shift ;;
      --no-platesolve) NO_PLATESOLVE=true; shift ;;
      -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
      -*) err "未知选项: $1"; exit 1 ;;
      *) targets+=("$1"); shift ;;
    esac
  done

  if [[ ${#targets[@]} -ne 2 ]]; then
    sed -n '2,18p' "$0"; exit 2
  fi
  src="${targets[0]}"; name="${targets[1]}"

  case "$CPU_MODE" in
    pcore) CPU_ARGS=(--cpus 0,2,4,6,8,10,12,14) ;;
    ecore) CPU_ARGS=(--cpus 16-23) ;;
    full)  CPU_ARGS=() ;;
    *) err "无效 CPU_MODE: $CPU_MODE"; exit 1 ;;
  esac

  [[ -x "$RUNNER" ]] || { err "run_wbpp.sh 不可执行: $RUNNER"; exit 1; }

  log "目标: $name   源: $src   CPU 模式: $CPU_MODE"
  cooling_save_full
  process_target "$src" "$name"
}

main "$@"
