/*
 * pipeline_audit.js — 离线校验档案表（不需要启动 PixInsight）
 *
 * 用法: node pipeline_audit.js [pipeline_profiles.jsh 路径] [filters.xspd 路径]
 *
 * 做两件事：
 *   1) 逐条相机档案，检查曲线组里的每个曲线名在滤镜库里是否真实存在
 *   2) 用真实设备元数据样本模拟自动匹配，打印会选中哪一组曲线
 */
const fs = require("fs");
const vm = require("vm");

const JSH = process.argv[2] || "/home/zhao/workspace/pixinsight/pipeline_profiles.jsh";
const DB  = process.argv[3] || "/opt/PixInsight/library/filters.xspd";

globalThis.File = { readTextFile: (p) => fs.readFileSync(p, "utf8") };
vm.runInThisContext(fs.readFileSync(JSH, "utf8"), { filename: JSH });

const lib = pipeLoadLib(DB);
const counts = Object.keys(lib).map((c) => c + "=" + Object.keys(lib[c]).length).join("  ");
console.log("滤镜库: " + DB + "   (" + counts + ")");
console.log("");

console.log("=== 1) 相机档案校验 ===");
let bad = 0;
for (const r of pipeAuditProfiles(DB)) {
  const flag = r.missing.length ? "✗ 缺 " + r.missing.join(", ") : "✓";
  if (r.missing.length) bad++;
  console.log(flag + "  " + r.id.padEnd(22) + " set=" + r.set.padEnd(20) + " " + r.label);
  if (r.missing.length) console.log("     曲线: " + r.curves);
  if (r.composites) console.log("     组合曲线: " + r.composites);
}
console.log("");
console.log("曲线不全的档案数: " + bad);
console.log("");

function win(inst, filt) {
  const kw = [];
  if (inst) kw.push("{INSTRUME,'" + inst + "',Camera model}");
  if (filt) kw.push("{FILTER,'" + filt + "',Filter used}");
  return { keywords: kw };
}

console.log("=== 1b) 滤镜目录 ===");
for (const f of PIPE_FILTERS) {
  const comp = f.composite ? "组合✓" : "组合—";
  console.log(
    f.id.padEnd(18) + f.kind.padEnd(17) + comp.padEnd(6) +
    pipeBandString(f.bands).padEnd(46) + f.label
  );
}
console.log("");

console.log("=== 1c) 滤镜解析（含自定义波长）===");
const fltCases = [
  ["L-eXtreme", null, null],
  ["L-Ultimate", null, null],
  ["NoFilter", null, null],
  ["IRCUT", null, null],
  ["LP", null, null],
  [null, "duoband", "Ha=656.3/7,OIII=500.7/7"],
  [null, "duoband", "Ha=656.3/3,OIII=500.7/3"],
  [null, "duoband", "656.3,500.7"],
  ["我的双窄带", "duoband", "Ha=656.3/6,OIII=500.7/6"],
  [null, "narrowband", "Ha=656.3/3"],
];
for (const [name, kind, nm] of fltCases) {
  const f = pipeResolveFilter(name, kind, nm);
  console.log(
    (String(name || "-") + " / " + String(kind || "-") + " / " + String(nm || "-")).padEnd(52) +
    " -> " + f.id.padEnd(20) + f.kind.padEnd(17) +
    (f.bands.length >= 2 ? "[双窄带] " : "") + pipeBandString(f.bands) +
    (f.approx ? "  (近似)" : "")
  );
  if (f.note) console.log("     说明: " + f.note);
}
console.log("");

console.log("=== 2) 自动匹配模拟 ===");
const samples = [
  ["Seestar S50", "LP"],
  ["Seestar S50", "IRCUT"],
  ["ZWO ASI2600MC Air", ""],
  ["ZWO ASI2600MC Air", "L-eXtreme"],
  ["ZWO ASI2600MC Air", "L-Ultimate"],
  ["ZWO ASI533MC Pro", "L-Ultimate"],
  ["ZWO ASI294MC Pro", ""],
  ["ZWO ASI585MC", ""],
  ["ILCE-7M3", ""],
  ["SONY ILCE-7M3", "L-eNhance"],
  ["Canon EOS 6D", ""],
  ["Nikon D850", ""],
  ["Vaonis VESPERA II", "Dual Band"],
  ["Some Unknown Camera", ""],
];
for (const [inst, filt] of samples) {
  const p = pipePickProfile(win(inst, filt), "auto", DB);
  const set = p.set || {};
  console.log(
    (inst + (filt ? " + " + filt : "")).padEnd(34) +
    " -> " + String(p.profile && p.profile.id).padEnd(18) +
    " [" + p.matched + "] " + set.id + (set.composite ? " <组合:" + set.composite + ">" : "")
  );
  console.log("     滤镜: " + p.filter.kind + "  " + pipeBandString(p.filter.bands) +
              (p.filter.bands.length >= 2 ? "  [双窄带]" : ""));
  console.log("     R=" + set.R + "  G=" + set.G + "  B=" + set.B + "  QE=" + set.QE);
  if (p.note) console.log("     说明: " + p.note);
  if (p.missing && p.missing.length) console.log("     缺失: " + p.missing.join(", "));
}
