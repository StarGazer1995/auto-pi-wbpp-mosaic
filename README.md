# auto-pi-wbpp-mosaic

把深空原始光帧跑成成品的**无头 PixInsight 流水线**：分析 → 分组 → WBPP 叠加 → 分光光度流量校准/梯度校正 →
mosaic 拼接 → 分光光度校色 → 预览归档。

设备无关：Seestar、ZWO ASIAir 全系、单反/微单（Sony A7M3、Canon、Nikon…）都能直接吃；
每个阶段跑完会留标记，**中断可续跑**。

> 本仓库只通过 PixInsight 的无头自动化接口（`-r=` 调用脚本 + WBPP 的 automation 参数）来编排，
> **不修改 PixInsight 自身的任何脚本或安装文件**。

---

## 1. 流水线做了什么

| 阶段 | 做什么 | 关键文件 |
|---|---|---|
| ① prepare | 复制光帧到本地 → 读数（FITS 表头 / RAW EXIF）→ 排除暗场偏置 → 分组（FITS 按指向聚类；RAW 按拍摄会话）→ 判定单指向 or mosaic | `pipeline_prepare.py` |
| ② wbpp | 逐组无头叠加；帧数 ≥ `--chunk-size`（默认 140）自动分块，绕开 WBPP 在大数据集上切 FastIntegration 丢帧的问题 | `run_wbpp.sh` / `run_wbpp_target.sh` / `run_wbpp_chunked.sh` |
| ③ correct | 逐组 SPFC 流量校准（+ 可选 MGC 用 MARS 做多尺度梯度校正），并写入滤镜/波长标注关键字 | `pipeline_correct.js` |
| ④ merge | mosaic：逐对 union 配准 → 统一画幅 → 积分，自动继承 WCS 与 FITS 关键字 | `pipeline_union_pair.js` / `pipeline_finish.js` |
| ⑤ spcc | 对最终 master 做 SPCC 分光光度校色（`--spcc`） | `pipeline_spcc.js` |
| ⑥ preview | 自动拉伸导出 JPEG + 归档 | `pipeline_preview.js` |

设备与滤镜档案在 `pipeline_profiles.jsh`，按元数据自动识别，不需要为每台设备改脚本
（41 条相机档案、14 条滤镜档案；详细表格见 [PIPELINE.md](PIPELINE.md)）。

---

## 2. 前置条件

### 2.1 系统与硬件

- **Linux x86_64**（在 Ubuntu 上开发验证）；bash ≥ 4.4、`coreutils`、`tar`
- **PixInsight 1.9.4 (Lockhart)**，默认装在 `/opt/PixInsight`（可用 `PI_BIN` 覆盖）
- **Xvfb**（无头跑 PI 必需）：`sudo apt install -y xvfb`，提供 `xvfb-run`
- **Python ≥ 3.9**（只用标准库；`pipeline_prepare.py` 直接读 FITS 头 / RAW EXIF，不依赖 astropy/exiftool）
- **Node.js ≥ 18**（仅 `pipeline_audit.js` 这个离线校验工具用）
- **taskset**（`util-linux`，`--mode pcore|ecore` 靠它绑核）
- 磁盘：光帧本地副本 + WBPP 中间产物。实测占用——
  - Seestar（1080×1920，约 2.6 MB/帧）：406 帧，峰值约 3 GB
  - ASI2600（6248×4176，约 50 MB/帧）：20 帧，峰值约 4 GB
  - 单反 24 MP ARW（约 23 MB/帧）：20 帧，峰值约 12 GB（debayered/registered 占大头）

  经验值：**预留 帧数 × 单帧大小 × 30** 的临时空间。内存建议 ≥ 32 GB，mosaic 大画布更高。
- （可选）**whyLIAN / Lian Li 水冷控制**：`cooling_ctl.py` 能在跑 WBPP 前把泵和冷排风扇拉满、
  结束后**恢复成跑之前的配置**（快照对比见 `~/workspace/seestar_work/cooling/`）。非 Lian Li 环境加 `--no-cooling` 即可。

### 2.2 PixInsight 侧的数据与设置（关键）

#### (a) Gaia DR3/SP 星表 —— SPFC / SPCC 必需

- 需要 **Gaia DR3/SP** 数据包（文件名形如 `gdr3sp-1.0.0-s-0N.xpsd`，本机副本 4 个共约 12.4 GB）。
  上游数据来自 Gaia 任务（<https://www.cosmos.esa.int/web/gaia>），PixInsight 用的封装包从
  **PixInsight 官方渠道**获取（官网/官方论坛的 Gaia DR3/SP 发布帖）。
- 配置写在 PI 设置文件 `~/.PixInsight/core-001-pxi.settings`（槽位 1）里的 **`ModuleData > Gaia`**：

  ```xml
  <i k="Gaia">
    <v k="DR3SPDatabaseFilePath00" t="s">/path/to/gdr3sp-1.0.0-s-01.xpsd</v>
    <v k="DR3SPDatabaseFilePath01" t="s">/path/to/gdr3sp-1.0.0-s-02.xpsd</v>
    <v k="DR3SPDatabaseFilePath02" t="s">/path/to/gdr3sp-1.0.0-s-03.xpsd</v>
    <v k="DR3SPDatabaseFilePath03" t="s">/path/to/gdr3sp-1.0.0-s-04.xpsd</v>
  </i>
  ```

- 两个坑：
  1. **PI 是按文件内部的 `DatabaseIdentifier` 认库的**，不是按文件名或路径。把 DR3 的库改名成 DR3/SP
     没用，请求 `DataRelease_3_SP` 时 DR3 库会被过滤掉，报 `No database files have been selected`。
  2. `ImageSolver` 的自动选库分支里**没有 DR3/SP**，所以 WBPP 的 plate solve 会回退到在线 Gaia DR2
     （无害，能解算；离线环境才需要在意）。

#### (b) MARS DR1 数据库 —— MGC（多尺度梯度校正）必需

- 官方项目页 <https://pixinsight.com/mars/>，技术说明 <https://pixinsight.com/doc/docs/MARS/MARS.html>。
- 数据包是 `.xmars` 文件（本机副本：`MARS-DR1-1.1.1.xmars` 1.45 GB 为主库、另有两个旧版/扩展包）。
- 配置在 **`ModuleData > MultiscaleProcessing`**：

  ```xml
  <i k="MultiscaleProcessing">
    <v k="MARSDatabaseFilePath000" t="s">/path/to/MARS-DR1-1.0.3.xmars</v>
    <v k="MARSDatabaseFilePath001" t="s">/path/to/MARS-DR1-1.1.1.xmars</v>
    <v k="MARSDatabaseFilePath002" t="s">/path/to/MARS-DR1-u01-1.0.1.xmars</v>
  </i>
  ```

- 坑：**MGC 的库必须进程级显式传**（`marsDatabaseFiles = [[true, path]]`）。新建进程不会带出 GUI 保存的列表，
  所以流水线要么读设置，要么用 `--mars` 指定。
- 顺序：**MGC 依赖 SPFC 的流量定标元数据**，必须先 SPFC 再 MGC，否则报
  `lacks flux calibration metadata (PCL:SPFC:ScaleFactors)`。

#### (c) 滤镜曲线库

随 PixInsight 安装：`/opt/PixInsight/library/filters.xspd`（1.9.4 里共 249 条曲线）。
流水线从这里取相机/滤镜曲线喂给 SPFC / SPCC，路径可用 `--db` 或脚本参数 `db=` 覆盖。

#### (d) PI 实例槽位（很坑，务必注意）

PI 的设置是**按实例槽位分开存**的：图形界面开在槽位 1（`core-001-pxi.settings`），
此时再启动无头进程会落到槽位 2（`core-002-pxi.settings`）→ 读到另一份设置 → 星表"消失"。
**跑无人值守流水线前先关掉图形界面的 PI。**

### 2.3 目录布局与环境变量

```bash
export SEESTAR_WORK_ROOT="$HOME/workspace/seestar_work"          # 工作目录（光帧副本/中间产物/master）
export SEESTAR_NAS_ACTIVITIES="/path/to/nas/media/activities"    # 原始光帧与成品归档所在的 NAS 路径
export PI_BIN="/opt/PixInsight/bin/PixInsight.sh"                # PixInsight 启动脚本
```

期望的原始数据布局（可不一样，只是默认值）：

```
$SEESTAR_NAS_ACTIVITIES/<目标>_sub/          # 光帧目录（FITS 或 RAW 都行）
$SEESTAR_NAS_ACTIVITIES/<目标>/PixInsight/   # 成品归档目标
```

工作目录会生成：

```
$SEESTAR_WORK_ROOT/<目标>/
  lights/                    本地光帧副本
  groups/groupN/             分组（硬链接）
  corrected/groupN_corrected.xisf   SPFC(+MGC) 后的各组 master
  mosaic/                    union 中间结果 + 最终 mosaic master
  logs/                      各阶段日志
  analysis.json / analysis.md
```

---

## 3. 安装

```bash
git clone git@github.com:StarGazer1995/auto-pi-wbpp-mosaic.git ~/workspace/pixinsight
cd ~/workspace/pixinsight
chmod +x *.sh *.py

# 自检 1：档案表与滤镜库是否对得上（不需要启动 PI）
node pipeline_audit.js

# 自检 2：确认某张 master 会被判成哪个设备/滤镜档案（只读，启动 PI）
/opt/PixInsight/bin/PixInsight.sh -n --no-splash --automation-mode --force-exit \
  -r="$(pwd)/pipeline_profile_probe.js,master=/path/to/master.xisf,table=1,log=/tmp/probe.log"
cat /tmp/probe.log
```

---

## 4. 用法

```bash
./seestar_pipeline.sh <光帧目录> <目标名> [选项]
```

### 常用选项

```
--mode full|pcore|ecore   CPU 绑核（ecore 适合长时间无人值守，温度更低）
--no-cooling              不碰散热设置
--no-mgc                  只做 SPFC，不做 MGC
--spcc                    最后对结果做 SPCC
--profile NAME            设备/滤镜档案：auto（默认）| 相机 id（seestar/imx571/sony-milc/…）
                          | 曲线组 id（seestar-lp/sony-uvircut/…）| none
--filter NAME             手动指定滤镜名（ASIAir 这类不写 FILTER 的数据用）
--filter-kind KIND        broadband | light-pollution | duoband | narrowband
--filter-nm SPEC          直接给通带波长（**用分号分隔**）："Ha=656.3/7;OIII=500.7/7"
--min-group N             少于 N 帧的分组丢弃（默认 30；单反会话常用 10）
--no-platesolve           WBPP 跳过 plate solve（RAW 无坐标时省时间）
--mars FILE               指定 .xmars；默认自动找 MARS-DR1-*.xmars
--chunk-size N            分块阈值（默认 140；0 = 关闭）
--single                  强制按单指向处理（不拼接）
--dry-run                 只做 ① 分析并打印计划
--from STAGE              从指定阶段续跑：prepare|wbpp|correct|merge|spcc
```

### 例子

```bash
# Seestar 单指向（自动识别 Seestar S50 + LP 滤镜）
./seestar_pipeline.sh "$SEESTAR_NAS_ACTIVITIES/IC 443_sub" IC443 --spcc

# Seestar 大幅 mosaic（自动判定多指向 → 逐块校准 → 并集拼接）
./seestar_pipeline.sh "$SEESTAR_NAS_ACTIVITIES/IC 5070_sub" IC5070 --spcc

# ASIAir（没有 FILTER 关键字，手动标注滤镜）
./seestar_pipeline.sh "$SEESTAR_NAS_ACTIVITIES/20260607/Light/M 16" M16 \
    --filter "L-eXtreme" --spcc

# 单反/微单 RAW（无指向信息 → 按拍摄会话分组；会话帧少要放宽 --min-group）
./seestar_pipeline.sh "/path/to/A7M3/milkyway" A7M3_MW \
    --min-group 10 --no-platesolve --profile none

# 只标注波长、不依赖滤镜型号
./seestar_pipeline.sh "<dir>" Target --filter-kind duoband --filter-nm "Ha=656.3/7;OIII=500.7/7" --spcc
```

---

## 5. 滤镜与波长的标注

除选曲线外，流水线还会把"用了什么滤镜、是不是双窄带、通带在哪"写进输出文件的 FITS 关键字，
跟着文件走（`pipeline_profile_probe.js,kw=1` 可查看）：

| 关键字 | 含义 | 例子 |
|---|---|---|
| `PIPEFILT` | 滤镜档案 id | `lextreme` / `custom-duoband` / `none` |
| `PIPEFLAB` | 滤镜描述（ASCII） | `Optolong L-eXtreme(Ha 656.3nm/7nm + OIII 500.7nm/7nm)` |
| `PIPEKIND` | 类别 | `broadband` / `light-pollution` / `duoband` / `narrowband` |
| `PIPEDUO` | **是否使用双/多窄带滤镜** | `T` / `F` |
| `PIPEBND` | 通带汇总 | `Ha 656.3nm/7nm + OIII 500.7nm/7nm` |
| `PIPEHA` / `PIPEOIII` / `PIPESII` | 各谱线波长(带半宽, nm) | `656.3/7` |
| `PIPEPROF` / `PIPESET` | 命中的相机档案 / 曲线组 | `imx571` / `imx571-uvircut` |

注意 FITS 关键字只允许 ASCII，中文描述会被清洗掉（保留括号与数字）。

**双窄带数据的颜色是合成色**：Hα 主要落 R、OIII 主要落 G/B，SPCC 只能做相对标定，
不能当作真实宽带颜色看。`analysis.md` 里会对此给出提示。

---

## 6. 实测（2026-09-19，Ubuntu + PI 1.9.4）

| 目标 | 数据 | 结果 |
|---|---|---|
| IC 443 | Seestar S50，406×10s | 分块叠加 401/406 → SPFC+MGC → SPCC → 归档；全流程约 16 分钟（含 WBPP） |
| IC 5070 | Seestar S50，3553×10s，3 个指向 | 3 组 → SPFC+MGC 逐块 → 并集拼接 1286×2658（带 WCS）→ SPCC；WBPP 之外约 2.4 分钟 |
| IC 4603 | ZWO ASI2600MC Air，10×300s | 自动识别 `imx571` → SPFC+MGC 26 s → SPCC 13 s 全通过（通道中位数 0.00758/0.01177/0.00655 → 0.00289/0.00288/0.00288） |
| 银河（A7M3） | Sony ILCE-7M3，20×30s ARW | WBPP 直接读 ARW 无需转格式（8 线程 11 分 06 秒）→ 11/20 帧通过加权；master 带 `INSTRUME=Sony ILCE-7M3`；无 WCS 所以 SPFC 失败（需先解算） |

档案表离线校验：41 条相机档案 × 249 条曲线，0 条缺曲线。

---

## 7. 已知限制

- **SPFC 只能对单块 master 做**：对拼接好的大画布（含空白区）做会因采样不足失败，
  所以流水线是"逐块 SPFC/MGC → 再拼接"。同理 SPFC 先做、MGC 后做。
- **SPFC/SPCC 需要天体测量解（WCS）**：RAW 若既没有坐标也没有焦距（例如手动镜头），
  需要先用 ImageSolver 给个大概坐标+焦距，或 `--profile none` 只做叠加。
- **黑白相机（LRGB/窄带）尚未支持**：当前链路按 OSC 三通道设计。
- **union 模式**（StarAlignment `Register/Union - Mosaic`）只能 view 执行，且同一 PI 进程内
  连续多次"新建窗口+保存"会卡死 → 流水线是"一对一个进程"。
- **硬链接**：NFS 上不能建硬链接，所以先把光帧复制到本地再分组。
- **PJSR 元数据继承**：新建 `ImageWindow` 不会自动带 FITS 关键字（也没有 `setKeywords()`），
  必须 `nw.keywords = src.keywords`，否则下游自动识别会"失明"。
- **MGC 的取舍**：MARS DR1 深度有限，对铺满暗星云的目标细尺度上可能减掉一点真实结构
  （可调 `gradientScale`，默认 1024，调大只修更大尺度）。

---

## 8. 文件说明

| 文件 | 作用 |
|---|---|
| `seestar_pipeline.sh` | 主入口（对目标/设备无关，名字是历史遗留） |
| `pipeline_prepare.py` | 分析 + 分组（FITS 头 / RAW EXIF，无需第三方库） |
| `pipeline_profiles.jsh` | 相机档案表 + 滤镜目录 + 曲线解析（被下面的 .js `#include`） |
| `pipeline_correct.js` | SPFC + 可选 MGC + 写标注 |
| `pipeline_spcc.js` | SPCC 校色 + 写标注 |
| `pipeline_union_pair.js` / `pipeline_finish.js` | mosaic：逐对并集配准 / 统一画幅+积分 |
| `pipeline_preview.js` | 自动拉伸导出 JPEG |
| `pipeline_audit.js` | 离线校验档案表（Node，不启动 PI） |
| `pipeline_profile_probe.js` | 查看某张图会命中哪个档案（只读，启动 PI） |
| `run_wbpp.sh` | WBPP 无头封装（参数化，支持 `--light-dir/--dark-dir/--flat-dir/--bias-dir`） |
| `run_wbpp_target.sh` / `run_wbpp_chunked.sh` | 单目标叠加 / 分块叠加 |
| `cooling_ctl.py` | Lian Li 水冷：跑前拉满、跑后恢复原配置（可选） |
| `strip_cfa_xisf.py` | 去掉 XISF 里多余的 CFA 属性（下游工具兼容性用） |
| `build_mosaic_groups.py` | 按指向生成 mosaic 分组的辅助脚本 |

环境相关的路径全部走 `SEESTAR_WORK_ROOT` / `SEESTAR_NAS_ACTIVITIES` / `PI_BIN`，
默认值是按作者的 NAS 布局写的，换环境时用环境变量覆盖即可。
