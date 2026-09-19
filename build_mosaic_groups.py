#!/usr/bin/env python3
"""按指向（FITS 表头 RA/DEC）给 mosaic 光帧分组，并用硬链接建立每组目录。

用法:
    python3 build_mosaic_groups.py <lights_dir> <work_dir> [--min-frames N]

输出:
    <work_dir>/groups/group<N>.txt   每组帧路径清单
    <work_dir>/groups/group<N>/      指向该组的硬链接（供 run_wbpp.sh 扫描）
    <work_dir>/groups/summary.txt    分组摘要
"""

import argparse
import collections
import os
import sys

HEADER_BYTES = 2880 * 3


def read_pointing(path):
    """从 FITS 头部读出 (RA, DEC)，失败返回 None。"""
    with open(path, "rb") as fh:
        head = fh.read(HEADER_BYTES)
    ra = dec = None
    for i in range(0, len(head) - 79, 80):
        card = head[i:i + 80].decode("ascii", "replace")
        if card.startswith("RA      ="):
            ra = card[10:30].split("/")[0].strip()
        elif card.startswith("DEC     ="):
            dec = card[10:30].split("/")[0].strip()
    if ra is None or dec is None:
        return None
    try:
        return float(ra), float(dec)
    except ValueError:
        return None


def angular_sep_arcmin(ra1, dec1, ra2, dec2):
    import math
    d1, d2 = math.radians(dec1), math.radians(dec2)
    dra = math.radians(ra2 - ra1)
    cos_sep = math.sin(d1) * math.sin(d2) + math.cos(d1) * math.cos(d2) * math.cos(dra)
    cos_sep = max(-1.0, min(1.0, cos_sep))
    return math.degrees(math.acos(cos_sep)) * 60.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lights_dir")
    ap.add_argument("work_dir")
    ap.add_argument("--min-frames", type=int, default=50,
                    help="少于该帧数的指向不单独成组（默认 50）")
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.lights_dir) if f.lower().endswith(".fit"))
    if not files:
        sys.exit(f"没有找到 .fit 文件: {args.lights_dir}")

    # 1) 按 0.001° 归并指向
    bins = collections.defaultdict(list)
    for name in files:
        path = os.path.join(args.lights_dir, name)
        pt = read_pointing(path)
        if pt is None:
            print(f"  !! 读不到 RA/DEC: {name}", file=sys.stderr)
            continue
        bins[(round(pt[0], 3), round(pt[1], 3))].append(path)

    # 2) 合并 5 角分以内的 bin（同一指向的抖动）
    centers = sorted(bins.keys(), key=lambda k: -len(bins[k]))
    merged = []          # [(ra, dec, [paths...])]
    for c in centers:
        for m in merged:
            if angular_sep_arcmin(c[0], c[1], m[0], m[1]) < 5.0:
                m[2].extend(bins[c])
                break
        else:
            merged.append([c[0], c[1], list(bins[c])])

    groups = [m for m in merged if len(m[2]) >= args.min_frames]
    groups.sort(key=lambda m: (m[1], m[0]))          # 按 Dec 再 RA 排序，便于对照
    dropped = [m for m in merged if len(m[2]) < args.min_frames]

    groups_dir = os.path.join(args.work_dir, "groups")
    os.makedirs(groups_dir, exist_ok=True)

    summary = []
    total = 0
    for idx, (ra, dec, paths) in enumerate(groups, start=1):
        gdir = os.path.join(groups_dir, f"group{idx}")
        os.makedirs(gdir, exist_ok=True)
        with open(os.path.join(groups_dir, f"group{idx}.txt"), "w") as fh:
            for p in sorted(paths):
                fh.write(p + "\n")
                link = os.path.join(gdir, os.path.basename(p))
                if not os.path.exists(link):
                    os.link(p, link)
        total += len(paths)
        summary.append(f"group{idx}: RA={ra:.5f} Dec={dec:.5f} frames={len(paths)}")

    for m in dropped:
        summary.append(f"[丢弃] RA={m[0]:.5f} Dec={m[1]:.5f} frames={len(m[2])}")
    summary.append(f"total grouped = {total} / {len(files)} files")

    with open(os.path.join(groups_dir, "summary.txt"), "w") as fh:
        fh.write("\n".join(summary) + "\n")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
