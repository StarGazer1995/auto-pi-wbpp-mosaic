# 深空通用处理流水线（seestar_pipeline.sh）

与目标和设备都无关的一键流程：给一个光帧目录 + 目标名，自动跑完 分析 → 分组 → 叠加 →
流量校准/梯度校正 → 拼接 → 校色 → 预览归档。

输入支持：

* **FITS**：Seestar S50/S30、ZWO ASIAir 全系（ASI2600/533/294/585/676…）、各类冷冻相机
* **RAW**：Sony ARW（如 A7M3 / ILCE-7M3）、Canon CR2/CR3、Nikon NEF、DNG、RAF、RW2 等

设备由 `pipeline_profiles.jsh` 里的档案表按元数据自动识别，不需要为每台设备改脚本。

```bash
cd ~/workspace/pixinsight
./seestar_pipeline.sh "/home/zhao/nas/media/activities/IC 5070_sub" IC5070 --spcc
```

## 阶段

| 阶段 | 做什么 | 关键脚本 |
|---|---|---|
| ① prepare | 复制光帧到本地 → 读数（FITS 表头 / RAW EXIF）→ 排除暗场偏置 → 分组：FITS 按指向聚类，RAW 按拍摄会话 → 判定单指向 or mosaic | `pipeline_prepare.py` |
| ② wbpp | 逐组无头叠加；**帧数 ≥ `--chunk-size`(默认140) 自动分块**（绕开 WBPP 的 FastIntegration 在大数据集上丢帧的问题），再合并各块 master | `run_wbpp.sh` / `run_wbpp_chunked.sh` / `run_wbpp_target.sh` |
| ③ correct | 逐组 SPFC 分光光度流量校准（+ 可选 MGC 用 MARS 做多尺度梯度校正） | `pipeline_correct.js` |
| ④ merge | 并集画布拼接：逐对 union 配准 → 统一画幅 → 积分，**自动继承 WCS** | `pipeline_union_pair.js` / `pipeline_finish.js` |
| ⑤ spcc | 对最终 master 做 SPCC 分光光度校色（`--spcc`） | `pipeline_spcc.js` |
| ⑥ preview | 自动拉伸导出 JPEG + 归档到 NAS（master / preview / analysis.md） | `pipeline_preview.js` |

## 常用选项

```
--mode full|pcore|ecore   CPU/散热模式（ecore 适合长时间无人值守，温度更低）
--no-cooling              不碰散热设置
--no-mgc                  只做 SPFC，不做 MGC
--spcc                    对最终 master 做 SPCC
--profile NAME            设备/滤镜档案：auto（默认，自动识别）| 相机 id | 曲线组 id | none
--filter NAME             手动指定滤镜名（覆盖元数据 FILTER，用于 ASIAir 这类不写 FILTER 的数据）
--min-group N             少于 N 帧的分组丢弃（默认 30；RAW/单反会话常用 10）
--no-platesolve           WBPP 跳过 plate solve（RAW/无坐标时省时间）
--mars FILE               指定 MARS 库；默认自动取 MARS数据包 里最新的 MARS-DR1-*.xmars
--chunk-size N            分块阈值（默认 140；设为 0 关闭分块）
--single                  强制按单指向处理（不做拼接）
--dry-run                 只做 ① 分析并打印计划
--from STAGE              从指定阶段开始续跑（prepare|wbpp|correct|merge|spcc）
```

## 目录布局

```
~/workspace/seestar_work/<目标>/
  lights/                    本地光帧副本（开始前从 NAS 拷）
  groups/groupN/             按指向分组的硬链接
  corrected/groupN_corrected.xisf   SPFC(+MGC) 后的各组 master
  mosaic/unions/             并集配准中间结果
  mosaic/out/<目标>_mosaic_master.xisf  最终 mosaic（带 WCS）
  logs/                      各阶段日志
  analysis.json / analysis.md
~/workspace/seestar_work/<目标>_groupN[_chunked]/   WBPP 工作目录
NAS: /media/activities/<目标>/PixInsight/           归档（master + 预览 + 分析报告）
```

每个阶段的产物存在即跳过，可中断续跑；`--from` 可从任意阶段重新开始。

## 依赖

1. **Gaia DR3/SP 星表**（SPFC/SPCC 需要）：配置在 `~/.PixInsight/core-00N-pxi.settings` 的
   `<ModuleData><Gaia><DR3SPDatabaseFilePathNN>`；调用时 **dataRelease 必须是 DR3/SP**。
2. **MARS 库**（MGC 需要）：`<ModuleData><MultiscaleProcessing><MARSDatabaseFilePathNNN>`，
   或用 `--mars` 显式指定。
3. **滤镜曲线**：取自 `/opt/PixInsight/library/filters.xspd`（249 条），由 `pipeline_profiles.jsh`
   的档案表按 `INSTRUME` / `FILTER` 自动挑选。

## 设备/滤镜档案表（pipeline_profiles.jsh）

解析顺序：`INSTRUME` 匹配相机 → `FILTER` 匹配该相机的专用曲线组 →（若该传感器族支持）
用"传感器底座 + 滤镜"组合曲线 → 否则用基础曲线组 → 兜底通用彩色传感器。
所有曲线名在运行时都会对着 `filters.xspd` 校验，缺失会降级并在日志里写明，不会静默用错。

| 相机档案 id | 匹配 | 基础曲线组 | 组合曲线 |
|---|---|---|---|
| `seestar` | Seestar S50/S30 | `seestar-lp`（LP）/ `seestar-ircut`（IRCUT） | — |
| `imx571` | ASI2600 / ASI6200 / ASI2400 | `imx571-uvircut` + QE `Sony IMX411/455/461/533/571` | ✓ |
| `imx533` | ASI533 | `imx533-uvircut` | ✓ |
| `imx294` | ASI294 (IMX294/492) | `imx294-uvircut` + QE `Sony IMX492` | ✓ |
| `imx585` | ASI585 / ASI662 | `imx585-uvircut`（B 通道用 `ZWO B` 近似） | ✓ |
| `imx676` | ASI676 | `imx676-uvircut` | ✓ |
| `zwo-generic` | 其它 ZWO ASI | `zwo-uvircut` | ✓ |
| `sony-milc` | Sony A7/A9/A6xxx、ILCE/ILCA（如 A7M3） | `sony-uvircut` | ✓ |
| `canon-<机型>` | Canon EOS 10D…5D Mark II、1D Mark III 共 11 款 | 逐机型曲线 | — |
| `canon-fullspectrum` | 全光谱改装机（名称含 full spectrum） | `canon-fullspectrum` | ✓ |
| `nikon-<机型>` | Nikon Z6 / D3 / D40 / D50 / D70 / D80 / D90 / D200 / D300s / D3X / D700 / D3500 / D5100 / D7000 | 逐机型曲线 | — |
| `pentax-k5` / `pentax-q` | Pentax K-5 / Q | 逐机型曲线 | — |
| `vaonis-vespera2` / `vaonis-vesperapro` | Vaonis VESPERA II / Pro | CLS / Dual Band | — |
| `generic-color` | 其它一切 | `generic-color-uvir`（近似） | — |

组合曲线支持的双窄带/光害滤镜：`Opt. L-eXtreme` / `L-eNhance` / `L-Ultimate`、
`Antlia ALP-T`、`Antlia Triband`、`Baader UHC-S`
（如 `Sony CMOS R-UVIRcut / Opt. L-eXtreme`）。

离线校验（不启动 PI）：

```bash
node pipeline_audit.js            # 逐条档案校验曲线是否存在 + 用真实机身名模拟自动匹配
```

查看某个 master 会被判成哪个档案（只读）：用 `pipeline_profile_probe.js`。

## RAW（单反/微单）输入

* RAW 里没有 RA/DEC，`pipeline_prepare.py` 改为读 EXIF 后按
  **机型 + 曝光 + ISO + 焦距**分桶，再按拍摄时间间隔（默认 20 分钟）切分拍摄会话；
* 曝光短于 `--min-light-exposure`（默认 1s）的帧视为暗场/偏置，不参与叠加分组；
* WBPP 能直接读 ARW/CR2/NEF 等（走 PI 的 RAW 模块），无需先转 FITS；
* 但 RAW 通常没有 WCS，**SPFC/SPCC 需要天体测量解**：没有坐标和焦距时这两步会失败，
  需要先用 ImageSolver 手动给个大概坐标+焦距，或直接用 `--profile none` 只做叠加。

## 已知限制 / 注意事项

- **PI 实例槽位**：设置是**按槽位分开存**的（`core-001-pxi.settings` = 槽位 1）。如果图形界面的 PI 正开着（占用槽位 1），无头进程会落到槽位 2、读另一份设置 → 星表"消失"。长时间无人值守跑流水线时，建议先关掉图形界面的 PI。
- **SPFC 只能对单块 master 做**：对拼接好的大画布（含空白区）做 SPFC 会因采样不足失败。所以流水线是"逐块 SPFC/MGC → 再拼接"。
- **MGC 的取舍**：MARS DR1 深度有限，对铺满暗星云的目标，细尺度上可能减掉一点真实结构。可调 `gradientScale`（默认 1024，调大只修更大尺度）。
- **union 模式与保存**：StarAlignment 的 `Register/Union - Mosaic` 只能 view 执行，且同一 PI 进程内连续多次"新建窗口+保存"会卡死 → 所以是"一对一个进程"。
- **硬链接**：NFS 上不能建硬链接，所以必须先把光帧复制到本地再分组。
- **元数据继承**：PJSR 里新建 `ImageWindow` 不会自动带 FITS 关键字（`nw.setKeywords()` 也不存在），
  必须 `nw.keywords = src.keywords`。流水线各脚本已显式继承，否则下游的自动档案识别会"失明"。

## 实测（2026-09-19）

| 目标 | 类型 | 帧数 | 结果 |
|---|---|---|---|
| IC 443 | 单指向 | 406 | 分块叠加 401/406 → SPFC+MGC → SPCC → 归档；全流程 ~16 分钟（含 WBPP） |
| IC 5070 | mosaic | 3553 | 3 组 → SPFC+MGC 逐块 → 拼接（带 WCS）→ SPCC → 归档；MBPP 之外的阶段 ~2.4 分钟 |
| IC 4603（ZWO ASI2600MC Air，真实 ASIAir 数据） | 单指向 | 10×300s | 自动档案 `imx571` → SPFC+MGC 26 s → SPCC 13 s 全通过（SPCC 后通道中位数 0.00758/0.01177/0.00655 → 0.00289/0.00288/0.00288） |
| A7M3 银河（RAW） | session | 20×30s | WBPP 直接读 ARW 无需转格式（8 线程 11 分 06 秒）→ 11/20 帧通过加权（9 帧权重 0.000 被拒）→ master 带 `INSTRUME=Sony ILCE-7M3`；**无 WCS 所以 SPFC 失败**，需先解算 |

档案表离线校验：41 条相机档案、曲线库 249 条曲线，**0 条缺曲线**（`node pipeline_audit.js`）。
