#!/usr/bin/env bash
# ============================================================================
# run_wbpp.sh — 命令行 WBPP 自动化脚本
# ============================================================================
# 通过 SSH 或命令行直接运行 PixInsight WeightedBatchPreprocessing (WBPP)。
# 支持 PixInsight 1.9.4+, WBPP 3.0.1+
#
# 只使用 standalone：由脚本启动独立 PI 实例（Xvfb 或 X 转发），无需桌面。
# ============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# 路径配置
# --------------------------------------------------------------------------
PI_BIN="${PI_BIN:-/opt/PixInsight/bin/PixInsight.sh}"
WBPP_SCRIPT="/opt/PixInsight/src/scripts/BatchPreprocessing/WBPP.js"

# --------------------------------------------------------------------------
# 默认值
# --------------------------------------------------------------------------
OUTPUT_DIR=""
LIGHT_DIRS=()
DARK_DIRS=()
FLAT_DIRS=()
BIAS_DIRS=()
LIGHT_FILES=()
DARK_FILES=()
FLAT_FILES=()
BIAS_FILES=()
EXTRA_PARAMS=()
RENAME_PATTERN=""
DRY_RUN=false
VERBOSE=false
CPU_LIST="${PI_CPUS:-}"   # 限制 PI 可用 CPU 列表；空=不限制

# --------------------------------------------------------------------------
# 颜色输出
# --------------------------------------------------------------------------
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'
C_NC='\033[0m'

info()    { echo -e "${C_BLUE}[wbpp]${C_NC} $*"; }
success() { echo -e "${C_GREEN}[wbpp]${C_NC} $*"; }
warn()    { echo -e "${C_YELLOW}[wbpp]${C_NC} $*"; }
err()     { echo -e "${C_RED}[wbpp] ERROR:${C_NC} $*"; }

# --------------------------------------------------------------------------
# 使用说明
# --------------------------------------------------------------------------
usage() {
    cat << 'EOF'
用法: run_wbpp.sh [选项]

通过命令行运行 PixInsight WBPP，适合 SSH/远程/批量处理。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  输入文件:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  --light-dir DIR     Light 帧所在目录 (可重复，递归搜索)
  --dark-dir DIR      Dark 帧所在目录
  --flat-dir DIR      Flat 帧所在目录
  --bias-dir DIR      Bias 帧所在目录

  --light-file FILE   单个 light 帧文件 (可重复)
  --dark-file FILE    单个 dark 帧文件
  --flat-file FILE    单个 flat 帧文件
  --bias-file FILE    单个 bias 帧文件

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  输出:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  -o, --output-dir DIR    输出目录 (必需)
  --rename PATTERN        处理后重命名，支持变量:
                           {type}   - masterLight, Light, Dark 等
                           {filter} - Ha, OIII, SII, R, G, B 等
                           {session} - 日期/场次标识
                           {name}   - 原始文件名 (不含扩展名)
                           {ext}    - 扩展名 (.xisf)
                          示例: --rename "M42_{filter}_{type}"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  配置:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  -p, --param K=V     传递 WBPP 自动化参数 (可重复，见 --help-params)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  其他:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  --dry-run           只显示命令，不执行
  -v, --verbose       详细输出
  --cpus LIST         用 taskset 限制 PI 可用 CPU (如 0-15 / 0,2,4,...,14)，空=全部
  --help              显示此帮助
  --help-params       显示所有可用的 WBPP 自动化参数
  --help-setup        显示 Xvfb/显示 设置帮助

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  示例:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # 最简用法
  ./run_wbpp.sh \
      --light-dir /data/M42/lights \
      --dark-dir /data/M42/darks \
      --flat-dir /data/M42/flats \
      -o /data/M42/output

  # 完整配置
  ./run_wbpp.sh \
      --light-dir /data/NGC7000/Light \
      --dark-dir /data/NGC7000/Dark \
      --flat-dir /data/NGC7000/Flat \
      --bias-dir /data/NGC7000/Bias \
      -o /data/NGC7000/processed \
      --rename "{session}_{filter}_{type}" \
      -p keywords=FILTER \
      -p bestFrameReferenceMethod=2 \
      -p bestFrameReferenceKeyword=FILTER \
      -p combination_4=0 \
      -p rejection_4=5 \
      -p sigmaLow_4=4.0 \
      -p sigmaHigh_4=3.0 \
      -p localNormalization=true

  # 只看命令不运行
  ./run_wbpp.sh --light-dir ./lights -o ./out --dry-run
EOF
}

# --------------------------------------------------------------------------
# Xvfb / 显示设置帮助
# --------------------------------------------------------------------------
show_setup_help() {
    cat << 'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PixInsight 无头运行环境设置
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PixInsight 是基于 Qt 的 GUI 应用，运行时需要 X11 显示服务。
通过 SSH 远程执行时，需要以下任一种方式提供显示:

  [方案 1] 安装 Xvfb (虚拟显示，推荐)
  ════════════════════════════════════
  sudo apt install xvfb
  之后脚本会自动检测并使用 Xvfb。Xvfb 在内存中模拟显示，
  不需要显卡/显示器，占用极低 (< 50MB)。

  [方案 2] SSH X11 转发
  ════════════════════════════════════
  ssh -X user@host
  ./run_wbpp.sh --light-dir ./lights -o ./out
  PI 会通过 SSH 隧道转发显示到你的本地 X 服务器。

  [方案 3] 手动设置 DISPLAY
  ════════════════════════════════════
  如果你有 X 服务器在运行:
  export DISPLAY=:0
  ./run_wbpp.sh --light-dir ./lights -o ./out

推荐方案 1 (Xvfb) — 最可靠，不受桌面环境影响。
EOF
}

# --------------------------------------------------------------------------
# WBPP 参数帮助
# --------------------------------------------------------------------------
show_params_help() {
    cat << 'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WBPP 自动化参数参考
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

参数格式: --param KEY=VALUE 或 -p KEY=VALUE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
常规
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  outputDirectory=PATH         输出目录
  smartNamingOverride=true|false  覆盖智能命名
  groupingKeywordsEnabled=true|false  启用 keyword 分组
  keywords=KEY1;KEY2 mode      分组 keywords (mode: pre/post/prepost)
                               例: keywords=FILTER;SESSION post
  fitsCoordinateConvention=0|1|2  FITS 坐标 (0=GlobalPref,1=top-down,2=bottom-up)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
校准 (Calibration)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  darkOptimizationLow=FLOAT       暗场优化低阈值 (sigma), 默认 3.0
  darkExposureTolerance=FLOAT     暗场曝光容差 (秒), 默认 10
  lightExposureTolerance=FLOAT    Light 曝光容差 (秒), 默认 2
  lightExposureTolerancePost=FLOAT  后校准曝光容差, 默认 2

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
图像集成 (Image Integration)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  N = 图像类型索引: 1=Bias, 2=Dark, 3=Flat, 4=Light

  combination_N=INT   叠加方法: 0=Average, 1=Median, 2=Minimum, 3=Maximum
  rejection_N=INT     像素剔除: 0=PercentileClip, 1=WinsorizedSigma,
                                 2=LinearFit, 3=ESD, 4=RCR, 5=Auto

  sigmaLow_N=FLOAT     WinsorizedSigma 低 sigma
  sigmaHigh_N=FLOAT    WinsorizedSigma 高 sigma
  percentileLow_N=FLOAT  PercentileClip 低
  percentileHigh_N=FLOAT PercentileClip 高
  linearFitLow_N=FLOAT   LinearFit 低
  linearFitHigh_N=FLOAT  LinearFit 高
  ESD_Outliers_N=FLOAT   ESD outliers fraction
  ESD_Significance_N=FLOAT  ESD significance
  RCR_Limit_N=FLOAT     RCR limit

  大尺度剔除 (Flats):
  flatsLargeScaleRejection=true|false
  flatsLargeScaleRejectionLayers=INT
  flatsLargeScaleRejectionGrowth=INT

  大尺度剔除 (Lights):
  lightsLargeScaleRejectionHigh=true|false
  lightsLargeScaleRejectionLayersHigh=INT
  lightsLargeScaleRejectionGrowthHigh=INT
  lightsLargeScaleRejectionLow=true|false
  lightsLargeScaleRejectionLayersLow=INT
  lightsLargeScaleRejectionGrowthLow=INT

  minWeight=FLOAT              最小权重 (lights), 默认 0.05

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
图像配准 (Image Registration) 和 星点检测
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  imageRegistration=true|false  启用配准, 默认 true
  pixelInterpolation=0-10       插值: 0=NearestNeighbor..10=Auto
  clampingThreshold=FLOAT       钳位阈值, 默认 0.3
  maxStars=INT                  最大星点数, 默认 0 (auto)
  distortionCorrection=true|false  畸变校正, 默认 false
  maxSplinePoints=INT           最大样条点, 默认 4000
  rigidTransformations=true|false  仅刚体变换

  sensitivity=FLOAT             星点检测灵敏度, 默认 0.5
  peakResponse=FLOAT            峰值响应, 默认 0.5
  brightThreshold=FLOAT         亮星剔除阈值, 默认 3.0
  maxStarDistortion=FLOAT       最大星点畸变, 默认 0.6
  structureLayers=INT           结构层数, 默认 5
  hotPixelFilterRadius=INT      热像素过滤半径, 默认 1

  bestFrameReferenceMethod=0|1|2  0=手动, 1=自动单张, 2=按keyword自动
  bestFrameReferenceKeyword=STR    keyword (method=2 时使用)
  referenceImage=PATH            手动参考帧路径 (method=0 时使用)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
子帧加权 (Subframe Weighting, 仅 WBPP)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  subframeWeightingEnabled=true|false  启用于帧加权
  subframeWeightingPreset=INT          预设
  subframesWeightsMethod=INT           0=PSFSignal, 1=PSFSNR
  FWHMWeight=INT                       FWHM 权重 (0-100)
  eccentricityWeight=INT               偏心率权重 (0-100)
  SNRWeight=INT                        SNR 权重 (0-100)
  starsWeight=INT                      星点数权重 (0-100)
  PSFSignalWeight=INT                  PSF Signal 权重 (0-100)
  PSFSNRWeight=INT                     PSF SNR 权重 (0-100)
  pedestal=INT                         Pedestal 值

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
局部归一化 (Local Normalization, 仅 WBPP)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  localNormalization=true|false         启用
  localNormalizationMethod=0|1          0=PSFFlux, 1=MultiscaleAnalysis
  localNormalizationInteractiveMode=true|false  交互模式
  localNormalizationGenerateImages=true|false   生成 LN 图像
  localNormalizationBestReferenceSelectionMethod=0-4

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
帧筛选 (Frame Selection)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  (注意: 帧筛选参数包含 "." ，必须用 -p 传递)

  -p frameSelection.FWHM.enabled=true
  -p frameSelection.FWHM.value=3.5
  -p frameSelection.FWHM.compareMode=0      0=LESS_THAN, 1=GREATER_THAN
  -p frameSelection.SNR.enabled=true
  -p frameSelection.SNR.value=20
  -p frameSelection.PSFSignalWeight.enabled=true
  -p frameSelection.PSFSignalWeight.value=0.2

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
其他
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  linearPatternSubtraction=true|false
  platesolve=true|false
  overscanEnabled=true|false
  autocrop=true|false
  integrate=true|false
  debayerOutputMethod=0|1|2    0=CombinedRGB, 1=SeparateChannels, 2=Both
  recombineRGB=true|false
  generateRejectionMaps=true|false
EOF
}

# --------------------------------------------------------------------------
# 参数解析
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --light-dir)     LIGHT_DIRS+=("$2"); shift 2 ;;
        --dark-dir)      DARK_DIRS+=("$2"); shift 2 ;;
        --flat-dir)      FLAT_DIRS+=("$2"); shift 2 ;;
        --bias-dir)      BIAS_DIRS+=("$2"); shift 2 ;;
        --light-file)    LIGHT_FILES+=("$2"); shift 2 ;;
        --dark-file)     DARK_FILES+=("$2"); shift 2 ;;
        --flat-file)     FLAT_FILES+=("$2"); shift 2 ;;
        --bias-file)     BIAS_FILES+=("$2"); shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --rename)        RENAME_PATTERN="$2"; shift 2 ;;
        -p|--param)      EXTRA_PARAMS+=("$2"); shift 2 ;;
        --cpus)          CPU_LIST="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        -v|--verbose)    VERBOSE=true; shift ;;
        --help)          usage; exit 0 ;;
        --help-params)   show_params_help; exit 0 ;;
        --help-setup)    show_setup_help; exit 0 ;;
        *) echo "未知选项: $1"; usage; exit 1 ;;
    esac
done

# --------------------------------------------------------------------------
# 检查 PixInsight 是否存在
# --------------------------------------------------------------------------
check_pixinsight() {
    if [[ ! -x "$PI_BIN" ]]; then
        if [[ -x "/usr/bin/PixInsight" ]]; then
            PI_BIN="/usr/bin/PixInsight"
        else
            err "找不到 PixInsight 可执行文件: $PI_BIN"
            err "请设置 PI_BIN 环境变量"
            exit 1
        fi
    fi
    if [[ "$VERBOSE" == true ]]; then
        info "PI_BIN=$PI_BIN"
    fi
}

# --------------------------------------------------------------------------
# 设置 X11 显示 (standalone 模式)
# --------------------------------------------------------------------------
setup_display() {
    # 如果 DISPLAY 已设置，检查是否可用
    if [[ -n "${DISPLAY:-}" ]]; then
        if xdpyinfo -display "$DISPLAY" &>/dev/null; then
            if [[ "$VERBOSE" == true ]]; then
                info "DISPLAY=$DISPLAY 可用"
            fi
            return
        fi
    fi

    # 尝试 xvfb-run (最简单)
    if command -v xvfb-run &>/dev/null; then
        # 以 wrapper 方式使用
        XVFB_WRAPPER="xvfb-run -a -s '-screen 0 1920x1080x24'"
        if [[ "$VERBOSE" == true ]]; then
            info "使用 xvfb-run wrapper"
        fi
        return
    fi

    # 尝试 Xvfb 直接启动
    local xvfb_paths=("/usr/bin/Xvfb" "/usr/bin/Xvfb")
    local xvfb_bin=""
    for candidate in "${xvfb_paths[@]}"; do
        if command -v "$candidate" &>/dev/null; then
            xvfb_bin="$candidate"
            break
        fi
    done

    if [[ -n "$xvfb_bin" ]]; then
        local display_num
        display_num=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1] % 100)" 2>/dev/null || echo $((RANDOM % 80 + 10)))
        $xvfb_bin ":$display_num" -screen 0 1920x1080x24 &
        XVFB_PID=$!
        export DISPLAY=":$display_num"
        trap 'kill $XVFB_PID 2>/dev/null' EXIT
        sleep 1
        if [[ "$VERBOSE" == true ]]; then
            info "启动 Xvfb :$display_num (PID=$XVFB_PID)"
        fi
        return
    fi

    # 到这里说明没有可用的 X 显示
    cat << 'XERR'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ⚠  PixInsight 需要 X11 显示服务，但当前环境没有。
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  选一个解决方案:

  [1] 安装 Xvfb (最简单):
      sudo apt install xvfb
      之后重新运行此脚本即可。

  [2] 使用 X11 转发:
      ssh -X user@host
      然后再运行此脚本。

  [3] 手动设置 DISPLAY:
      export DISPLAY=:0

  详细说明: ./run_wbpp.sh --help-setup
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
XERR
    exit 1
}

# --------------------------------------------------------------------------
# Standalone 模式: 启动独立 PI 实例
# --------------------------------------------------------------------------
run_standalone_mode() {
    setup_display

    # 构建 WBPP 自动化命令
    local pi_cmd
    pi_cmd=$(build_pi_command)

    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  PixInsight WBPP 自动化"
    info "  模式: standalone"
    info "  输出: $OUTPUT_DIR"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if $DRY_RUN; then
        info "[dry-run] 将执行的命令:"
        echo "  $pi_cmd"
        exit 0
    fi

    local start_time
    start_time=$(date +%s)

    # 执行 PI
    if [[ -n "${XVFB_WRAPPER:-}" ]]; then
        # xvfb-run wrapper 模式
        if ! eval "$XVFB_WRAPPER $pi_cmd"; then
            err "WBPP 执行失败 (exit code: $?)"
            exit 1
        fi
    else
        if ! eval "$pi_cmd"; then
            err "WBPP 执行失败 (exit code: $?)"
            exit 1
        fi
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local min=$((elapsed / 60))
    local sec=$((elapsed % 60))
    success "WBPP 完成于 ${min}m${sec}s"

    # 后处理
    post_process
}

# 构建 PI 命令行
build_pi_command() {
    local pi_flags="-n --no-splash --automation-mode --force-exit"

    # 先构建所有 WBPP 参数 (逗号分隔)
    local wbpp_params="$WBPP_SCRIPT,automationMode=true"

    # 添加文件
    for f in "${LIGHT_FILES[@]}";  do wbpp_params="$wbpp_params,file=$f"; done
    for d in "${LIGHT_DIRS[@]}";   do wbpp_params="$wbpp_params,dir=$d"; done
    for f in "${DARK_FILES[@]}";   do wbpp_params="$wbpp_params,file=$f"; done
    for d in "${DARK_DIRS[@]}";    do wbpp_params="$wbpp_params,dir=$d"; done
    for f in "${FLAT_FILES[@]}";   do wbpp_params="$wbpp_params,file=$f"; done
    for d in "${FLAT_DIRS[@]}";    do wbpp_params="$wbpp_params,dir=$d"; done
    for f in "${BIAS_FILES[@]}";   do wbpp_params="$wbpp_params,file=$f"; done
    for d in "${BIAS_DIRS[@]}";    do wbpp_params="$wbpp_params,dir=$d"; done

    # 输出目录
    if [[ -n "$OUTPUT_DIR" ]]; then
        wbpp_params="$wbpp_params,outputDirectory=$OUTPUT_DIR"
    fi

    # 额外参数
    for p in "${EXTRA_PARAMS[@]}"; do
        wbpp_params="$wbpp_params,$p"
    done

    if [[ -n "$CPU_LIST" ]]; then
        if ! command -v taskset &>/dev/null; then
            err "未找到 taskset，无法使用 --cpus=$CPU_LIST"
            exit 1
        fi
        echo "taskset -c $CPU_LIST $PI_BIN $pi_flags -r=\"$wbpp_params\""
    else
        echo "$PI_BIN $pi_flags -r=\"$wbpp_params\""
    fi
}

# --------------------------------------------------------------------------
# 后处理: 列表输出 + 可选重命名
# --------------------------------------------------------------------------
post_process() {
    echo ""
    info "输出文件:"
    find "$OUTPUT_DIR" -maxdepth 3 -type f \( \
        -name "*.xisf" -o -name "*.fit" -o -name "*.fits" -o -name "*.xsif" \
    \) -printf "  %f  (%s bytes)\n" 2>/dev/null || true

    if [[ -n "$RENAME_PATTERN" ]]; then
        echo ""
        info "按模式重命名: $RENAME_PATTERN"
        do_rename
    fi

    echo ""
    success "完成。"
}

# 重命名输出文件
do_rename() {
    python3 - "$OUTPUT_DIR" "$RENAME_PATTERN" << 'PYEOF'
import os, sys, re
from pathlib import Path

out_dir = Path(sys.argv[1])
pattern = sys.argv[2]

renamed = 0
for f in sorted(out_dir.rglob("*")):
    if not f.is_file():
        continue
    if f.suffix.lower() not in ('.xisf', '.fit', '.fits', '.xsif'):
        continue

    name = f.stem
    parts = name.split('_')

    # 检测类型
    detected_type = "unknown"
    for tk in ['masterLight', 'masterDark', 'masterFlat', 'masterBias',
               'Light', 'Dark', 'Flat', 'Bias', 'drizzle', 'crop', 'RGB']:
        if tk.lower() in name.lower():
            detected_type = tk
            break

    # 检测滤镜
    detected_filter = "unknown"
    filter_kws = ['Ha', 'OIII', 'O3', 'SII', 'S2', 'L', 'R', 'G', 'B',
                  'Lum', 'Red', 'Green', 'Blue', 'UV', 'IR', 'Clear', 'NII', 'Hb']
    for part in parts:
        if part.upper() in [fk.upper() for fk in filter_kws]:
            detected_filter = part
            break

    # 检测日期/场次
    detected_session = "unknown"
    for part in parts:
        if re.match(r'^\d{4}-\d{2}-\d{2}$', part) or re.match(r'^\d{6,8}$', part):
            detected_session = part
            break

    result = pattern
    result = result.replace('{type}', detected_type)
    result = result.replace('{filter}', detected_filter)
    result = result.replace('{session}', detected_session)
    result = result.replace('{name}', name)
    result = result.replace('{ext}', f.suffix.lstrip('.'))

    # 清理文件名
    result = re.sub(r'[<>:\"/\\|?*]', '_', result)

    new_path = f.parent / (result + f.suffix)
    if new_path != f:
        counter = 1
        while new_path.exists():
            new_path = f.parent / f"{result}_{counter}{f.suffix}"
            counter += 1
        print(f"  {f.name}  ->  {new_path.name}")
        f.rename(new_path)
        renamed += 1

if renamed == 0:
    print("  (无需重命名)")
else:
    print(f"  共重命名 {renamed} 个文件")
PYEOF
}

# --------------------------------------------------------------------------
# 验证输入
# --------------------------------------------------------------------------
validate_inputs() {
    local has_input=false

    if [[ ${#LIGHT_DIRS[@]} -gt 0 ]] || [[ ${#LIGHT_FILES[@]} -gt 0 ]] \
    || [[ ${#DARK_DIRS[@]} -gt 0 ]]  || [[ ${#DARK_FILES[@]} -gt 0 ]] \
    || [[ ${#FLAT_DIRS[@]} -gt 0 ]]  || [[ ${#FLAT_FILES[@]} -gt 0 ]] \
    || [[ ${#BIAS_DIRS[@]} -gt 0 ]]  || [[ ${#BIAS_FILES[@]} -gt 0 ]]; then
        has_input=true
    fi

    if ! $has_input; then
        err "未指定输入文件。用 --light-dir/--light-file/--dark-dir 等指定"
        echo ""
        usage
        exit 1
    fi

    if [[ -z "$OUTPUT_DIR" ]]; then
        err "需要指定输出目录 (-o/--output-dir)"
        echo ""
        usage
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR"
}

# --------------------------------------------------------------------------
# 主入口
# --------------------------------------------------------------------------
main() {
    check_pixinsight
    validate_inputs
    run_standalone_mode
}

main
