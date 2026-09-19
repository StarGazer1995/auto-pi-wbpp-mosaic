#!/usr/bin/env bash
#
# seestar_pipeline.sh — 通用 Seestar 处理流水线（与目标无关）
#
#   ① prepare  分析光帧（帧数/夜晚/滤镜/指向聚类）→ 判定单指向 or mosaic → 按指向分组
#   ② wbpp     逐组无头叠加（帧数 ≥150 自动分块，绕开 FastIntegration 丢帧）
#   ③ correct  逐组 SPFC 流量校准（+ 可选 MGC/MARS 梯度校正）
#   ④ merge    并集画布拼接（自动继承 WCS，可交给 SPCC/MGC/注释）
#   ⑤ spcc     对最终 mosaic 做 SPCC 分光光度校色（可选）
#   ⑥ preview  导出预览 JPEG + 归档到 NAS
#
# 用法:
#   ./seestar_pipeline.sh <src_dir> <target_name> [选项]
#
# 选项:
#   --mode full|pcore|ecore   CPU/散热模式（默认 full）
#   --no-cooling              全程不碰散热设置
#   --no-mgc                  跳过 MGC（只做 SPFC）
#   --spcc                    最后对 mosaic 做 SPCC
#   --profile NAME            设备/滤镜档案：auto（默认，按 INSTRUME/FILTER 自动识别）
#                             | 相机 id（seestar / imx571 / imx533 / sony-milc / canon-5dmk2 ...）
#                             | 曲线组 id（seestar-lp / sony-uvircut ...）| none（跳过 SPFC/SPCC）
#   --filter NAME             手动指定滤镜名（覆盖元数据 FILTER，用于 ASIAir 等不写 FILTER 的数据）
#   --filter-kind KIND        滤镜类别：broadband | light-pollution | duoband | narrowband
#   --filter-nm SPEC          直接给通带波长（分号分隔！）："Ha=656.3/7;OIII=500.7/7"
#                             （给波长时会自动判定为双窄带，并写进输出文件的 FITS 关键字）
#   --min-group N             少于 N 帧的分组丢弃（默认 30；RAW/单反会话常用 10）
#   --no-platesolve           WBPP 跳过 plate solve（RAW 无坐标时省时间）
#   --mars FILE               MARS 库文件（默认自动搜索 MARS-DR1-*.xmars）
#   --chunk-size N            WBPP 分块阈值（默认 140）
#   --single                  强制按单指向处理（不做拼接）
#   --dry-run                 只做 ① 分析并打印计划
#   --from STAGE              从指定阶段开始（prepare|wbpp|correct|merge|spcc）
#
# 幂等：每个阶段的产物存在就跳过，可随时中断续跑。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${SEESTAR_WORK_ROOT:-/home/zhao/workspace/seestar_work}"
NAS_ACTIVITIES="${SEESTAR_NAS_ACTIVITIES:-/home/zhao/nas/media/activities}"
COOLING_CTL="$SCRIPT_DIR/cooling_ctl.py"
COOLING_DIR="$WORK_ROOT/cooling"
PI_BIN="${PI_BIN:-/opt/PixInsight/bin/PixInsight.sh}"
FILTER_DB="/opt/PixInsight/library/filters.xspd"

# 光帧扩展名：FITS（Seestar/ASIAir/冷冻相机）+ RAW（单反/微单）
LIGHT_EXTS=( -iname '*.fit' -o -iname '*.fits' -o -iname '*.fts'
             -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.cr3' -o -iname '*.nef'
             -o -iname '*.nrw' -o -iname '*.dng' -o -iname '*.raf' -o -iname '*.rw2'
             -o -iname '*.orf' -o -iname '*.pef' -o -iname '*.srw' )
count_lights() { find "$1" -maxdepth 1 -type f \( "${LIGHT_EXTS[@]}" \) 2>/dev/null | wc -l | tr -d ' '; }

CPU_MODE="full"; COOLING=true; DO_MGC=true; DO_SPCC=false; FORCE_SINGLE=false
PROFILE="auto"; MARS=""; CHUNK_SIZE=140; DRY_RUN=false; FROM="prepare"
MIN_GROUP=30; FILTER_OVERRIDE=""; PLATESOLVE=true
FILTER_KIND=""; FILTER_NM=""
filter_args() {   # 供 pipeline_correct.js / pipeline_spcc.js 的滤镜标注参数
  local s=""
  [[ -n "$FILTER_OVERRIDE" ]] && s="$s,filter=$FILTER_OVERRIDE"
  [[ -n "$FILTER_KIND" ]] && s="$s,filterkind=$FILTER_KIND"
  [[ -n "$FILTER_NM" ]] && s="$s,filternm=$FILTER_NM"
  printf '%s' "$s"
}
CPU_ARGS=(); COOLING_SNAPSHOT=""

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# ---------------------------------------------------------------- 散热
cooling_save_full() {
  [[ "$COOLING" == true ]] || return 0
  [[ -f "$COOLING_CTL" ]] || { COOLING=false; return 0; }
  mkdir -p "$COOLING_DIR"
  COOLING_SNAPSHOT="$COOLING_DIR/pipeline-$(date +%Y%m%d-%H%M%S).json"
  if python3 "$COOLING_CTL" save-full "$COOLING_SNAPSHOT" >/dev/null 2>&1; then
    log "cooling: 泵与风扇已拉满"
  else
    log "warning: 散热拉满失败，继续"; rm -f "$COOLING_SNAPSHOT"; COOLING_SNAPSHOT=""; COOLING=false
  fi
}
cooling_restore() {
  [[ -n "${COOLING_SNAPSHOT:-}" && -f "$COOLING_SNAPSHOT" ]] || return 0
  local out
  if out="$(python3 "$COOLING_CTL" restore "$COOLING_SNAPSHOT" 2>&1)"; then
    log "cooling: 已恢复到跑之前的配置 —— $(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g')"
  else
    err "cooling: 恢复失败 ($COOLING_SNAPSHOT)"
  fi
  ls -1t "$COOLING_DIR"/pipeline-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
  COOLING_SNAPSHOT=""
}
trap cooling_restore EXIT

# ---------------------------------------------------------------- 工具
run_pi() {   # $1 = script,args
  if command -v xvfb-run &>/dev/null; then
    env -u DISPLAY xvfb-run -a -s '-screen 0 1920x1080x24' "$PI_BIN" \
      -n --no-splash --automation-mode --force-exit -r="$SCRIPT_DIR/$1"
  else
    env -u DISPLAY "$PI_BIN" -n --no-splash --automation-mode --force-exit -r="$SCRIPT_DIR/$1"
  fi
}

find_group_master() {   # $1 = work name（兼容单次叠加与分块叠加两种布局）
  local d="$WORK_ROOT/$1" f
  f=$(find "$d/out/master" -maxdepth 1 -name 'masterLight_BIN-1*.xisf' ! -name '*_autocrop.xisf' -print -quit 2>/dev/null)
  [[ -n "$f" ]] && { printf '%s' "$f"; return; }
  f=$(find "$d"_chunked/final/out/master -maxdepth 1 -name 'masterLight_BIN-1*.xisf' ! -name '*_autocrop.xisf' -print -quit 2>/dev/null)
  [[ -n "$f" ]] && printf '%s' "$f"
}

find_latest_mars() {
  local dir="$NAS_ACTIVITIES/../dataset_backup/MARS数据包"
  [[ -d "$dir" ]] || dir="/home/zhao/nas/media/dataset_backup/MARS数据包"
  ls -1t "$dir"/MARS-DR1-*.xmars 2>/dev/null | head -1
}

# ---------------------------------------------------------------- 参数
[[ $# -ge 2 ]] || usage
SRC="$1"; TARGET="$2"; shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) CPU_MODE="${2:?}"; shift 2 ;;
    --no-cooling) COOLING=false; shift ;;
    --no-mgc) DO_MGC=false; shift ;;
    --spcc) DO_SPCC=true; shift ;;
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --filter) FILTER_OVERRIDE="${2:?}"; shift 2 ;;
    --filter-kind) FILTER_KIND="${2:?}"; shift 2 ;;
    --filter-nm) FILTER_NM="${2:?}"; shift 2 ;;
    --min-group) MIN_GROUP="${2:?}"; shift 2 ;;
    --no-platesolve) PLATESOLVE=false; shift ;;
    --mars) MARS="${2:?}"; shift 2 ;;
    --chunk-size) CHUNK_SIZE="${2:?}"; shift 2 ;;
    --single) FORCE_SINGLE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --from) FROM="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) err "未知选项: $1"; usage ;;
  esac
done

case "$CPU_MODE" in
  pcore) CPU_ARGS=(--cpus 0,2,4,6,8,10,12,14) ;;
  ecore) CPU_ARGS=(--cpus 16-23) ;;
  full)  CPU_ARGS=() ;;
  *) err "无效 --mode: $CPU_MODE"; exit 1 ;;
esac

[[ -d "$SRC" ]] || { err "源目录不存在: $SRC"; exit 1; }
WORK="$WORK_ROOT/$TARGET"
mkdir -p "$WORK/logs"
PIPELINE_LOG="$WORK/pipeline.log"

log "目标: $TARGET   源: $SRC   工作目录: $WORK"

stage_done()  # $1 = 标记文件
{ [[ -f "$1" ]]; }

should_run() {   # $1 = stage
  local order=(prepare wbpp correct merge spcc preview)
  local i
  for i in "${!order[@]}"; do
    [[ "${order[$i]}" == "$FROM" ]] && return 0
    [[ "${order[$i]}" == "$1" ]] && return 1
  done
  return 0
}

# ---------------------------------------------------------------- ① prepare
if should_run prepare; then
  if stage_done "$WORK/.stage_prepare"; then
    log "① prepare: 已有分析结果，跳过"
  else
    LIGHTS="$WORK/lights"
    SRC_N=$(count_lights "$SRC")
    HAVE_N=$(count_lights "$LIGHTS")
    [[ "$SRC_N" -gt 0 ]] || { err "源目录里没有光帧（FITS/RAW）: $SRC"; exit 1; }
    if [[ "$HAVE_N" != "$SRC_N" ]]; then
      log "① prepare: 复制 $SRC_N 帧到本地（$LIGHTS）"
      rm -rf "$LIGHTS"; mkdir -p "$LIGHTS"
      ( cd "$SRC" && tar cf - . ) | tar xf - -C "$LIGHTS" || { err "复制光帧失败"; exit 1; }
    else
      log "① prepare: 本地已有 $HAVE_N 帧，跳过复制"
    fi
    log "① prepare: 分析 + 分组"
    PREP_FILTER_ARGS=()
    [[ -n "$FILTER_OVERRIDE" ]] && PREP_FILTER_ARGS+=(--filter-name "$FILTER_OVERRIDE")
    [[ -n "$FILTER_KIND" ]] && PREP_FILTER_ARGS+=(--filter-kind "$FILTER_KIND")
    [[ -n "$FILTER_NM" ]] && PREP_FILTER_ARGS+=(--filter-nm "$FILTER_NM")
    python3 "$SCRIPT_DIR/pipeline_prepare.py" "$LIGHTS" "$WORK" \
        --min-group-frames "$MIN_GROUP" \
        "${PREP_FILTER_ARGS[@]}" \
        > "$WORK/logs/prepare.log" 2>&1 || { err "prepare 失败"; exit 1; }
    touch "$WORK/.stage_prepare"
    echo "（源目录: $SRC）" >> "$WORK/analysis.md"
    sed -n '1,20p' "$WORK/analysis.md" | sed 's/^/    /'
  fi
fi

N_GROUPS=$(python3 -c "import json;d=json.load(open('$WORK/analysis.json'));print(len(d['groups']))" 2>/dev/null || echo 0)
IS_MOSAIC=$(python3 -c "import json;d=json.load(open('$WORK/analysis.json'));print(1 if d['mosaic'] else 0)" 2>/dev/null || echo 0)
INPUT_FMT=$(python3 -c "import json;print(json.load(open('$WORK/analysis.json')).get('format','fits'))" 2>/dev/null || echo fits)
[[ "$FORCE_SINGLE" == true || "$N_GROUPS" -le 1 ]] && IS_MOSAIC=0
log "分析结果: $N_GROUPS 组，输入 = $INPUT_FMT，模式 = $([[ $IS_MOSAIC -eq 1 ]] && echo mosaic || echo 单指向)"
[[ "$INPUT_FMT" == "raw" && "$PLATESOLVE" == true ]] && log "提示: RAW 输入没有指向信息，建议加 --no-platesolve 省时间"

if $DRY_RUN; then log "(--dry-run，结束)"; exit 0; fi

cooling_save_full

# ---------------------------------------------------------------- ② wbpp
if should_run wbpp; then
  log "② wbpp: 逐组叠加"
  for gi in $WORK/groups/group*; do
    [[ -d "$gi" ]] || continue
    g=$(basename "$gi")
    n=$(count_lights "$gi")
    if [[ -n "$(find_group_master "${TARGET}_$g")" ]]; then log "   $g: master 已存在，跳过"; continue; fi
    log "   $g: $n 帧"
    WBPP_EXTRA=()
    [[ "$PLATESOLVE" == false ]] && WBPP_EXTRA+=(--no-platesolve)
    if [[ "$n" -ge "$CHUNK_SIZE" ]]; then
      "$SCRIPT_DIR/run_wbpp_chunked.sh" "$gi" "${TARGET}_$g" --chunk-size "$CHUNK_SIZE" --no-cooling \
          > "$WORK/logs/wbpp_$g.log" 2>&1
    else
      "$SCRIPT_DIR/run_wbpp_target.sh" --no-cooling "${WBPP_EXTRA[@]}" "$gi" "${TARGET}_$g" \
          > "$WORK/logs/wbpp_$g.log" 2>&1
    fi
    if [[ -z "$(find_group_master "${TARGET}_$g")" ]]; then err "   $g: 叠加失败，见 logs/wbpp_$g.log"; exit 1; fi
    log "   $g: 完成"
  done
fi

# ---------------------------------------------------------------- ③ correct
if should_run correct && [[ "$PROFILE" != "none" ]]; then
  log "③ correct: SPFC$( $DO_MGC && echo ' + MGC' )（profile=$PROFILE）"
  mkdir -p "$WORK/corrected"
  for gi in $WORK/groups/group*; do
    [[ -d "$gi" ]] || continue
    g=$(basename "$gi")
    m=$(find_group_master "${TARGET}_$g")
    [[ -n "$m" ]] || { err "   $g: 找不到 master"; exit 1; }
    out="$WORK/corrected/${g}_corrected.xisf"
    if [[ -f "$out" ]]; then log "   $g: 已校正，跳过"; continue; fi
    extra=""
    $DO_MGC && extra=",mgc=1${MARS:+,mars=$MARS}"
    extra="$extra$(filter_args)"
    log "   $g: SPFC$($DO_MGC && echo ' + MGC')"
    run_pi "pipeline_correct.js,master=$m,out=$out,profile=$PROFILE,db=$FILTER_DB${extra},log=$WORK/logs/correct_$g.log" >/dev/null 2>&1
    if [[ ! -f "$out" ]]; then err "   $g: 校正失败，见 logs/correct_$g.log"; cat "$WORK/logs/correct_$g.log"; exit 1; fi
  done
  touch "$WORK/.stage_correct"
fi

# ---------------------------------------------------------------- ④ merge
if should_run merge && [[ $IS_MOSAIC -eq 1 ]]; then
  log "④ merge: 并集画布拼接"
  M_DIR="$WORK/mosaic"; mkdir -p "$M_DIR/unions" "$M_DIR/out"
  # 选帧数最多的组作参考
  REF=""; REF_N=0
  for f in "$WORK"/corrected/group*_corrected.xisf; do
    [[ -f "$f" ]] || continue
    g=$(basename "$f" | sed 's/_corrected.xisf//')
    n=$(python3 -c "import json;d=json.load(open('$WORK/analysis.json'));print([x['n_frames'] for x in d['groups'] if x['name']=='$g'][0])" 2>/dev/null || echo 0)
    if [[ "$n" -gt "$REF_N" ]]; then REF_N="$n"; REF="$f"; fi
  done
  [[ -n "$REF" ]] || { err "   找不到参考 master"; exit 1; }
  log "   参考 master: $(basename "$REF")（$REF_N 帧）"
  LIST="$M_DIR/inputs.txt"; : > "$LIST"; echo "$REF" >> "$LIST"
  for f in "$WORK"/corrected/group*_corrected.xisf; do
    [[ "$f" == "$REF" ]] && continue
    out="$M_DIR/unions/$(basename "$f" .xisf)_union.xisf"
    if [[ ! -f "$out" ]]; then
      log "   union: $(basename "$f")"
      run_pi "pipeline_union_pair.js,ref=$REF,target=$f,out=$out,log=$M_DIR/logs_$(basename "$f" .xisf).log" >/dev/null 2>&1
      [[ -f "$out" ]] || { err "   union 失败: $f"; exit 1; }
    fi
    echo "$out" >> "$LIST"
  done
  MASTER="$M_DIR/out/${TARGET}_mosaic_master.xisf"
  if [[ ! -f "$MASTER" ]]; then
    run_pi "pipeline_finish.js,inputs=$LIST,work=$M_DIR,out=$M_DIR/out,tag=${TARGET}_mosaic,log=$WORK/logs/merge.log" >/dev/null 2>&1
    [[ -f "$MASTER" ]] || { err "   拼接失败，见 logs/merge.log"; exit 1; }
  fi
  log "   mosaic master: $MASTER"
  touch "$WORK/.stage_merge"
else
  MASTER="$(find_group_master "${TARGET}_group1")"
fi
[[ -n "${MASTER:-}" && -f "$MASTER" ]] || { err "没有可用的最终 master"; exit 1; }

# ---------------------------------------------------------------- ⑤ spcc
if should_run spcc && $DO_SPCC; then
  log "⑤ spcc: 对最终 master 做 SPCC"
  SPCC_OUT="$WORK/${TARGET}_spcc_master.xisf"
  if [[ ! -f "$SPCC_OUT" ]]; then
    run_pi "pipeline_spcc.js,master=$MASTER,out=$SPCC_OUT,profile=$PROFILE,db=$FILTER_DB$(filter_args),log=$WORK/logs/spcc.log" >/dev/null 2>&1
    [[ -f "$SPCC_OUT" ]] || { err "   SPCC 失败，见 logs/spcc.log"; exit 1; }
  fi
  MASTER="$SPCC_OUT"
  log "   SPCC master: $MASTER"
fi

# ---------------------------------------------------------------- ⑥ preview + 归档
log "⑥ preview + 归档"
PREVIEW="$WORK/${TARGET}_preview.jpg"
if [[ ! -f "$PREVIEW" ]]; then
  run_pi "pipeline_preview.js,master=$MASTER,out=$PREVIEW,log=$WORK/logs/preview.log" >/dev/null 2>&1
fi

DEST="$NAS_ACTIVITIES/$TARGET/PixInsight"
mkdir -p "$DEST"
cp -f "$MASTER"   "$DEST/$(basename "$MASTER")"
[[ -f "$PREVIEW" ]] && cp -f "$PREVIEW" "$DEST/${TARGET}_preview.jpg"
[[ -f "$WORK/analysis.md" ]] && cp -f "$WORK/analysis.md" "$DEST/${TARGET}_analysis.md"
log "已归档到 $DEST:"
ls -la "$DEST" | tail -n +2 | sed 's/^/    /'

log "==== 完成 ===="
log "master : $MASTER"
log "preview: $PREVIEW"
log "日志   : $WORK/logs/"
