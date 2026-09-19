#!/usr/bin/env python3
"""astro pipeline 第 ① ② 步：分析光帧 + 分组

支持两类输入：
  * FITS（Seestar / ASIAir / 各类冷冻相机）：读 FITS 头，按 RA/DEC 做指向聚类
  * RAW（Sony ARW / Canon CR2-CR3 / Nikon NEF / DNG ...）：读 EXIF，RAW 里没有指向信息，
    改按「机型号 + 曝光 + ISO + 拍摄时间间隔」切分拍摄会话

用法:
    pipeline_prepare.py <lights_dir> <work_dir> [选项]

选项:
    --min-group-frames N      少于 N 帧的组丢弃（默认 50；RAW 会话帧少，可用 10）
    --merge-radius-arcmin X   指向聚类合并半径（默认 5.0′，仅 FITS 路径）
    --session-gap-min N       RAW 会话切分阈值（默认 20 分钟）

产出:
    <work_dir>/analysis.json    分析结果（供后续脚本读取）
    <work_dir>/analysis.md      人可读报告
    <work_dir>/groups/groupN/   链接到光帧的目录（供 run_wbpp.sh 扫描）
"""

import argparse
import collections
import datetime
import json
import math
import os
import re
import struct
import sys

HEADER_BYTES = 2880 * 3

# FITS（Seestar/ASIAir/冷冻相机）与 RAW（单反/微单）两类输入
FITS_EXTS = (".fit", ".fits", ".fts")
RAW_EXTS = (".arw", ".cr2", ".cr3", ".nef", ".nrw", ".dng",
            ".raf", ".rw2", ".orf", ".pef", ".srw")

# ------------------------------------------------------------------ RAW EXIF
# 远端没有 exiftool，直接解析 TIFF/EXIF 结构取叠加分组要用的几个字段。
_TIFF_SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 12: 8}


def _tiff_ifd(data, endian, offset):
    if offset <= 0 or offset + 2 > len(data):
        return {}
    n = struct.unpack(endian + "H", data[offset:offset + 2])[0]
    out = {}
    for i in range(n):
        p = offset + 2 + 12 * i
        if p + 12 > len(data):
            break
        tag, typ, cnt = struct.unpack(endian + "HHI", data[p:p + 8])
        size = _TIFF_SIZES.get(typ, 1) * cnt
        if size <= 4:
            raw = data[p + 8:p + 8 + size]
        else:
            off = struct.unpack(endian + "I", data[p + 8:p + 12])[0]
            raw = data[off:off + size]
        out[tag] = (typ, cnt, raw)
    return out


def _tiff_str(ifd, tag):
    v = ifd.get(tag)
    return v[2].split(b"\x00")[0].decode("ascii", "replace").strip() if v else None


def _tiff_uint(ifd, tag):
    v = ifd.get(tag)
    if not v:
        return None
    if v[0] == 3:
        return v[2][0]
    if v[0] == 4 and len(v[2]) >= 4:
        return struct.unpack("<I", v[2][:4])[0]
    return None


def _tiff_rat(ifd, tag):
    v = ifd.get(tag)
    if not v or v[0] != 5 or len(v[2]) < 8:
        return None
    num, den = struct.unpack("<II", v[2][:8])
    return num / den if den else None


def read_raw_exif(path):
    """读 RAW 的 机型/镜头/曝光/ISO/焦距/拍摄时间"""
    try:
        with open(path, "rb") as fh:
            data = fh.read(400000)
    except OSError:
        return None
    if data[:2] not in (b"II", b"MM"):
        return None
    endian = "<" if data[:2] == b"II" else ">"
    ifd0 = _tiff_ifd(data, endian, struct.unpack(endian + "I", data[4:8])[0])
    exif = _tiff_ifd(data, endian, _tiff_uint(ifd0, 0x8769) or 0)
    dt = _tiff_str(exif, 0x9003) or _tiff_str(exif, 0x0132) or _tiff_str(ifd0, 0x0132)
    when = None
    if dt:
        try:
            when = datetime.datetime.strptime(dt, "%Y:%m:%d %H:%M:%S")
        except ValueError:
            when = None
    return {
        "INSTRUME": _tiff_str(ifd0, 0x0110),
        "LENS": _tiff_str(exif, 0xA434),
        "EXPTIME": _tiff_rat(exif, 0x829A),
        "ISO": _tiff_uint(exif, 0x8827),
        "FOCAL": _tiff_rat(exif, 0x920A),
        "DATE-OBS": dt,
        "_when": when,
    }


def read_header(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(HEADER_BYTES)
    except OSError:
        return None
    d = {}
    for i in range(0, len(head) - 79, 80):
        card = head[i:i + 80].decode("ascii", "replace")
        key = card[:8].strip()
        if key in ("RA", "DEC", "EXPTIME", "EXPOSURE", "FILTER", "NAXIS1", "NAXIS2",
                   "BAYERPAT", "OBJECT", "DATE-OBS", "INSTRUME", "CCD-TEMP"):
            d[key] = card[10:30].split("/")[0].strip().strip("'").strip()
        if key == "END":
            break
    return d


def sep_arcmin(ra1, dec1, ra2, dec2):
    d1, d2 = math.radians(dec1), math.radians(dec2)
    dra = math.radians(ra2 - ra1)
    c = math.sin(d1) * math.sin(d2) + math.cos(d1) * math.cos(d2) * math.cos(dra)
    return math.degrees(math.acos(max(-1.0, min(1.0, c)))) * 60.0


# ------------------------------------------------------------------ 滤镜标注
# 与 pipeline_profiles.jsh 里的 PIPE_FILTERS / PIPE_LINES 保持一致
SPECTRAL_LINES = [("OIII", 500.7), ("Hb", 486.1), ("Ha", 656.3), ("SII", 672.4), ("NII", 658.3)]


def line_name(nm):
    best, best_d = None, 1e9
    for name, wl in SPECTRAL_LINES:
        d = abs(wl - nm)
        if d < best_d:
            best_d, best = d, name
    return best if best_d <= 12 else None


def parse_bands(spec):
    """'Ha=656.3/7;OIII=500.7/7' 或 '656.3,500.7' -> [{name,nm,bw}]"""
    bands = []
    for part in re.split(r"[;,]", spec or ""):
        t = part.strip()
        if not t:
            continue
        name, _, rest = t.partition("=")
        if not rest:
            rest, name = name, ""
        bits = rest.split("/")
        try:
            nm = float(bits[0])
        except ValueError:
            continue
        bw = None
        if len(bits) > 1:
            try:
                bw = float(bits[1])
            except ValueError:
                bw = None
        bands.append({"name": name.strip() or line_name(nm) or f"λ{nm:g}", "nm": nm, "bw": bw})
    return bands


def band_string(bands):
    if not bands:
        return "(未指定通带)"
    return " + ".join(b["name"] + f" {b['nm']:.1f}nm" + (f"/{b['bw']:g}nm" if b["bw"] else "")
                      for b in bands)


def infer_kind(name):
    if re.search(r"extreme|ultimate|enhance|alp[\s_-]?t|alpt|tri[\s_-]?band|dual[\s_-]?band|"
                 r"duo[\s_-]?band|nbz|双窄", name, re.I):
        return "duoband"
    if re.search(r"light[\s_-]?pollution|^lp$|^cls|uhc|^l-pro|neodymium|skyglow", name, re.I):
        return "light-pollution"
    if re.search(r"^(none|nofilter|clear|uvir|ir[\s_-]?cut|ha|oiii|sii)", name, re.I):
        return "broadband" if re.match(r"^(none|no|clear|uvir|ir)", name, re.I) else "narrowband"
    return "unknown"


def resolve_filter(name, kind, nm_spec, meta_filters):
    """返回滤镜标注 dict；优先级：显式波长 > 显式名字 > 元数据里的 FILTER"""
    source = "cli" if (name or kind or nm_spec) else "metadata"
    bands = parse_bands(nm_spec)
    label = name.strip()
    if not label and meta_filters:
        mf = sorted(meta_filters)[0]
        # 只用命令行指定了类别/波长时，别把元数据里的滤镜名当成最终结论
        label = f"自定义（元数据 FILTER={mf}，类别/波长由命令行指定）" if (kind or bands) else mf
    if not label:
        label = "(未标注)"
    if not kind:
        kind = infer_kind(label) if label != "(未标注)" else "unknown"
    if bands and kind in ("", "unknown"):
        kind = "duoband" if len(bands) >= 2 else "narrowband"
    if not bands and kind == "duoband":
        bands = [{"name": "Ha", "nm": 656.3, "bw": None}, {"name": "OIII", "nm": 500.7, "bw": None}]
    return {"name": label, "kind": kind, "bands": bands,
            "band_string": band_string(bands), "duoband": len(bands) >= 2,
            "source": source}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lights_dir")
    ap.add_argument("work_dir")
    ap.add_argument("--min-group-frames", type=int, default=50)
    ap.add_argument("--merge-radius-arcmin", type=float, default=5.0)
    ap.add_argument("--session-gap-min", type=float, default=20.0)
    ap.add_argument("--min-light-exposure", type=float, default=1.0,
                    help="短于该曝光时间(秒)的帧视为暗场/偏置，不参与叠加分组（默认 1.0）")
    ap.add_argument("--filter-name", default="", help="手动指定滤镜名（覆盖元数据 FILTER）")
    ap.add_argument("--filter-kind", default="",
                    help="滤镜类别：broadband | light-pollution | duoband | narrowband")
    ap.add_argument("--filter-nm", default="",
                    help="直接给通带波长，分号分隔：Ha=656.3/7;OIII=500.7/7")
    args = ap.parse_args()

    files = []
    for dirpath, _, names in os.walk(args.lights_dir):
        for fn in sorted(names):
            ext = os.path.splitext(fn)[1].lower()
            if ext in FITS_EXTS:
                files.append((os.path.join(dirpath, fn), "fits"))
            elif ext in RAW_EXTS:
                files.append((os.path.join(dirpath, fn), "raw"))
    files.sort()
    if not files:
        sys.exit(f"没有找到光帧（支持 {', '.join(FITS_EXTS + RAW_EXTS)}）: {args.lights_dir}")
    kinds = sorted({k for _, k in files})
    fmt = kinds[0] if len(kinds) == 1 else "mixed"

    nights = collections.Counter()
    filters = collections.Counter()
    exps = collections.Counter()
    models = collections.Counter()
    bins = collections.defaultdict(list)
    meta = {}
    per_file = {}
    for path, kind in files:
        if kind == "fits":
            h = read_header(path) or {}
            try:
                exptime = float(h["EXPOSURE"]) if h.get("EXPOSURE") else (
                    float(h["EXPTIME"]) if h.get("EXPTIME") else None)
            except ValueError:
                exptime = None
            rec = {"kind": "fits", "INSTRUME": h.get("INSTRUME"), "FILTER": h.get("FILTER"),
                   "EXPTIME": exptime, "ISO": None, "OBJECT": h.get("OBJECT"),
                   "DATE-OBS": h.get("DATE-OBS"), "BAYERPAT": h.get("BAYERPAT"),
                   "NAXIS1": h.get("NAXIS1"), "NAXIS2": h.get("NAXIS2"),
                   "ra": None, "dec": None, "when": None}
            try:
                rec["ra"] = float(h["RA"])
                rec["dec"] = float(h["DEC"])
            except (KeyError, TypeError, ValueError):
                pass
            if h.get("DATE-OBS"):
                try:
                    rec["when"] = datetime.datetime.fromisoformat(h["DATE-OBS"][:19])
                except ValueError:
                    pass
        else:
            r = read_raw_exif(path) or {}
            rec = {"kind": "raw", "INSTRUME": r.get("INSTRUME"), "FILTER": None,
                   "EXPTIME": r.get("EXPTIME"), "ISO": r.get("ISO"),
                   "OBJECT": None, "DATE-OBS": r.get("DATE-OBS"), "BAYERPAT": None,
                   "NAXIS1": None, "NAXIS2": None, "LENS": r.get("LENS"),
                   "FOCAL": r.get("FOCAL"), "ra": None, "dec": None,
                   "when": r.get("_when")}
        per_file[path] = rec
        rec["is_calib"] = (rec.get("EXPTIME") is not None
                           and rec["EXPTIME"] < args.min_light_exposure)

        if not meta:
            meta = {k: rec.get(k) for k in ("NAXIS1", "NAXIS2", "BAYERPAT", "INSTRUME", "OBJECT")}
        if rec.get("EXPTIME"):
            exps[f"{rec['EXPTIME']:g}s"] += 1
        if rec.get("FILTER"):
            filters[rec["FILTER"]] += 1
        if rec.get("INSTRUME"):
            models[rec["INSTRUME"]] += 1
        if rec.get("when"):
            nights[rec["when"].strftime("%Y-%m-%d")] += 1
        elif re.search(r"(\d{8})-\d{6}", os.path.basename(path)):
            nights[re.search(r"(\d{8})-\d{6}", os.path.basename(path)).group(1)] += 1
        h = per_file[path]
        try:
            pt = (float(h["ra"]), float(h["dec"]))
        except (KeyError, TypeError, ValueError):
            continue
        if pt[0] is not None and pt[1] is not None and not h.get("is_calib"):
            bins[(round(pt[0], 3), round(pt[1], 3))].append(path)

    calib = [p for p, r in per_file.items() if r.get("is_calib")]
    grouping = "pointing" if bins else "session"
    flt = resolve_filter(args.filter_name, args.filter_kind, args.filter_nm, filters)

    clusters = []
    if grouping == "pointing":
        # ---- FITS：按 RA/DEC 聚类，合并相近指向 ----
        centers = sorted(bins.keys(), key=lambda k: -len(bins[k]))
        for c in centers:
            for cl in clusters:
                if sep_arcmin(c[0], c[1], cl["ra"], cl["dec"]) < args.merge_radius_arcmin:
                    cl["files"].extend(bins[c])
                    n = len(cl["files"])
                    cl["ra"] = (cl["ra"] * (n - len(bins[c])) + c[0] * len(bins[c])) / n
                    cl["dec"] = (cl["dec"] * (n - len(bins[c])) + c[1] * len(bins[c])) / n
                    break
            else:
                clusters.append({"ra": c[0], "dec": c[1], "files": list(bins[c]),
                                 "kind": "pointing",
                                 "label": f"RA {c[0]:.3f} / Dec {c[1]:.3f}"})
        clusters.sort(key=lambda c: -len(c["files"]))
    else:
        # ---- RAW（或没有坐标的 FITS）：RAW 里没有指向信息 ----
        # 按 机型 + 曝光 + ISO + 焦距 分桶，再按拍摄时间间隔切分拍摄会话。
        keyed = collections.defaultdict(list)
        for path, rec in per_file.items():
            if rec.get("is_calib"):
                continue
            if rec["kind"] == "fits" and rec.get("ra") is not None:
                continue
            key = (rec.get("INSTRUME") or "?",
                   f"{rec.get('EXPTIME') or 0:g}",
                   rec.get("ISO") or 0,
                   round(rec["FOCAL"]) if rec.get("FOCAL") else 0)
            keyed[key].append(path)
        sessions = []
        for key, paths in keyed.items():
            paths.sort(key=lambda p: per_file[p].get("when") or datetime.datetime.min)
            current = []
            for p in paths:
                if current:
                    t0 = per_file[current[-1]].get("when")
                    t1 = per_file[p].get("when")
                    if t0 and t1 and (t1 - t0).total_seconds() > args.session_gap_min * 60:
                        sessions.append(current)
                        current = []
                current.append(p)
            if current:
                sessions.append(current)
        sessions.sort(key=len, reverse=True)
        clusters = []
        for s in sessions:
            r0 = per_file[s[0]]
            clusters.append({
                "files": s, "ra": None, "dec": None,
                "label": f"{r0.get('INSTRUME') or '?'} {r0.get('EXPTIME') or 0:g}s "
                         f"ISO{r0.get('ISO') or '?'} 自 {r0.get('DATE-OBS') or '?'}",
            })

    kept = [c for c in clusters if len(c["files"]) >= args.min_group_frames]
    dropped = [c for c in clusters if len(c["files"]) < args.min_group_frames]

    spread = 0.0
    if grouping == "pointing" and len(clusters) > 1:
        base = (clusters[0]["ra"], clusters[0]["dec"])
        spread = max(sep_arcmin(base[0], base[1], c["ra"], c["dec"]) for c in clusters[1:])

    analysis = {
        "source": args.lights_dir,
        "format": fmt,
        "grouping": grouping,
        "target": meta.get("OBJECT") or os.path.basename(os.path.normpath(args.lights_dir)),
        "n_frames": len(files),
        "nights": dict(sorted(nights.items())),
        "filters": dict(filters),
        "exposures": dict(exps),
        "cameras": dict(models),
        "filter": flt,
        "n_light_frames": len(files) - len(calib),
        "calibration_frames": [
            {"n_frames": n, "exposure_s": e}
            for e, n in sorted(collections.Counter(
                f"{per_file[p]['EXPTIME']:g}s" for p in calib).items())
        ],
        "sensor": meta,
        "pointing_spread_arcmin": round(spread, 2),
        "mosaic": grouping == "pointing" and len(kept) > 1,
        "groups": [],
        "dropped": [],
    }

    groups_dir = os.path.join(args.work_dir, "groups")
    os.makedirs(groups_dir, exist_ok=True)
    for idx, c in enumerate(kept, start=1):
        name = f"group{idx}"
        gdir = os.path.join(groups_dir, name)
        os.makedirs(gdir, exist_ok=True)
        for p in sorted(c["files"]):
            link = os.path.join(gdir, os.path.basename(p))
            if not os.path.exists(link):
                try:
                    os.link(p, link)
                except OSError:
                    import shutil
                    shutil.copy2(p, link)
        entry = {
            "name": name,
            "kind": c.get("kind", "pointing"),
            "label": c.get("label"),
            "n_frames": len(c["files"]),
            "files": sorted(os.path.basename(p) for p in c["files"]),
        }
        if c.get("ra") is not None:
            entry["ra"] = round(c["ra"], 5)
            entry["dec"] = round(c["dec"], 5)
        times = [per_file[p].get("when") for p in c["files"] if per_file[p].get("when")]
        if times:
            entry["start"] = min(times).strftime("%Y-%m-%d %H:%M:%S")
            entry["end"] = max(times).strftime("%Y-%m-%d %H:%M:%S")
        entry["exposure_s"] = per_file[c["files"][0]].get("EXPTIME")
        entry["iso"] = per_file[c["files"][0]].get("ISO")
        analysis["groups"].append(entry)
    for c in dropped:
        analysis["dropped"].append({"ra": c.get("ra"), "dec": c.get("dec"),
                                    "label": c.get("label"),
                                    "n_frames": len(c["files"])})

    with open(os.path.join(args.work_dir, "analysis.json"), "w", encoding="utf-8") as fh:
        json.dump(analysis, fh, ensure_ascii=False, indent=2)

    total_min = sum(float(e.rstrip("s")) * n for e, n in exps.items()) / 60.0
    lines = [
        f"# {analysis['target']} 分析报告",
        "",
        f"- 源目录: `{args.lights_dir}`",
        f"- 输入格式: **{fmt}**，分组方式: **{grouping}**",
        f"- 帧数: **{analysis['n_frames']}**，夜晚 {len(nights)}，合计约 **{total_min:.1f} 分钟**",
        f"- 光帧 **{analysis['n_light_frames']}** 帧；另有暗场/偏置 {len(calib)} 帧"
        f"（曝光 < {args.min_light_exposure:g}s，不参与叠加）"
        f"{'：' + str(analysis['calibration_frames']) if calib else ''}",
        f"- 曝光/滤镜: {dict(exps)} / {dict(filters) or '(无 FILTER 关键字)'}",
        f"- 相机: {dict(models) or '(未知)'}   传感器: {analysis['sensor']}",
        f"- 滤镜: **{flt['name']}**   类别 `{flt['kind']}`"
        + ("   **[双/多窄带]**" if flt["duoband"] else "")
        + f"   通带 {flt['band_string']}（来源: {flt['source']}）",
    ]
    if flt["duoband"]:
        lines.append("- 注意：双/多窄带数据的颜色是合成色（Ha 主要落 R、OIII 主要落 G/B），"
                     "SPCC 只能做相对标定，不能当真实宽带色看。")
    if grouping == "pointing":
        lines.append(f"- 指向聚类: **{len(kept)}** 组，跨度 {analysis['pointing_spread_arcmin']}′ → "
                     f"{'**mosaic（需拼接）**' if analysis['mosaic'] else '单指向（直接 WBPP）'}")
        lines += ["", "| 组 | RA | Dec | 帧数 |", "|---|---|---|---|"]
        for g in analysis["groups"]:
            lines.append(f"| {g['name']} | {g['ra']} | {g['dec']} | {g['n_frames']} |")
        for d in analysis["dropped"]:
            lines.append(f"| (丢弃) | {d['ra']} | {d['dec']} | {d['n_frames']} |")
    else:
        lines.append(f"- 拍摄会话: **{len(kept)}** 组（RAW 无指向信息，按 机型+曝光+ISO+焦距 分桶后，"
                     f"以 {args.session_gap_min:g} 分钟间隔切分）")
        lines += ["", "| 组 | 帧数 | 曝光 | ISO | 起止 | 说明 |", "|---|---|---|---|---|---|"]
        for g in analysis["groups"]:
            span = f"{g.get('start', '?')} → {g.get('end', '?')}" if g.get("start") else "?"
            lines.append(f"| {g['name']} | {g['n_frames']} | {g.get('exposure_s') or '?'}s | "
                         f"{g.get('iso') or '-'} | {span} | {g.get('label') or ''} |")
        for d in analysis["dropped"]:
            lines.append(f"| (丢弃) | {d['n_frames']} | - | - | - | {d.get('label') or ''} |")
    with open(os.path.join(args.work_dir, "analysis.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print("\n".join(lines))
    print()
    print(f"analysis.json: {os.path.join(args.work_dir, 'analysis.json')}")


if __name__ == "__main__":
    main()
