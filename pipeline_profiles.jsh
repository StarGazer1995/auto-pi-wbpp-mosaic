/*
 * pipeline_profiles.jsh — 设备/滤镜档案表：把图像元数据映射到 SPFC/SPCC 需要的曲线
 *
 * 曲线全部取自 PixInsight 的滤镜库（默认 /opt/PixInsight/library/filters.xspd），
 * 运行时会逐条校验曲线名是否存在；缺失会降级并在日志里写明原因，不会静默用错曲线。
 *
 * 解析顺序：
 *   1) 用 INSTRUME（退化 TELESCOP / CREATOR）匹配相机条目
 *   2) 用 FILTER 关键字匹配该相机的专用曲线组（如 Seestar 的 LP / IRCUT）
 *   3) 若没命中且该传感器族支持"传感器底座 + 滤镜"的组合曲线（Sony CMOS / Canon 全光谱），
 *      则动态拼出组合曲线名（如 "Sony CMOS R-UVIRcut / Opt. L-eXtreme"）
 *   4) 都不行就用相机的基础曲线组；基础组也缺通道，则退回通用彩色传感器曲线
 */

var PIPE_DB_DEFAULT = "/opt/PixInsight/library/filters.xspd";

/* ------------------------------------------------------------------ 曲线库 */

var __pipeLib = null, __pipeLibPath = "";

/* 解析一次滤镜库，缓存成 { 通道: { 曲线名: 数据 } } */
function pipeLoadLib( dbPath )
{
   var p = dbPath || PIPE_DB_DEFAULT;
   if ( __pipeLib && __pipeLibPath == p )
      return __pipeLib;
   var lib = { R: {}, G: {}, B: {}, Q: {}, PAN: {}, L: {} };
   try
   {
      var txt = File.readTextFile( p );
      var re = /<Filter name="([^"]*)" channel="([^"]*)"[^>]*?data="([^"]*)"/g, m;
      while ( (m = re.exec( txt )) !== null )
         if ( lib[m[2]] !== undefined )
            lib[m[2]][m[1]] = m[3];
   }
   catch ( e ) {}
   __pipeLib = lib;
   __pipeLibPath = p;
   return lib;
}

function pipeCurve( dbPath, name, channel )
{
   if ( !name ) return "";
   var set = pipeLoadLib( dbPath )[channel] || {};
   return set[name] !== undefined ? set[name] : "";
}

function pipeHasCurve( dbPath, name, channel )
{
   var set = pipeLoadLib( dbPath )[channel] || {};
   return set[name] !== undefined;
}

/* ------------------------------------------------------------- 曲线组定义 */

var PIPE_SETS = {};

/* 完整定义一组曲线 */
function pipeDefSet( id, R, G, B, QE )
{
   PIPE_SETS[id] = { R: R, G: G, B: B, QE: QE || "Ideal QE curve" };
}

/* 按"前缀 + 通道后缀"批量定义同族机型的曲线组（Canon/Nikon/Pentax 都是这种命名） */
function pipeDefModel( id, prefix, qe )
{
   pipeDefSet( id, prefix + " R", prefix + " G", prefix + " B", qe );
}

/* --- 智能望远镜 / 一体机 ------------------------------------------------- */
pipeDefSet( "seestar-lp", "Seestar-LP-R", "Seestar-LP-G", "Seestar-LP-B", "Ideal QE curve" );
pipeDefSet( "seestar-ircut", "Sony IMX 462-662-585-UVIRCut R",
                            "Sony IMX 462-662-585-UVIRCut G",
                            "Sony IMX 462-662-585-UVIRCut B", "Ideal QE curve" );

/* --- ZWO ASI 各传感器 + UV/IR cut ---------------------------------------- */
pipeDefSet( "imx571-uvircut", "Sony Color Sensor R-UVIRcut", "Sony Color Sensor G-UVIRcut",
                              "Sony Color Sensor B-UVIRcut", "Sony IMX411/455/461/533/571" );
pipeDefSet( "imx533-uvircut", "Sony-IMX533 R", "Sony-IMX533 G", "Sony-IMX533 B",
                              "Sony IMX411/455/461/533/571" );
pipeDefSet( "imx294-uvircut", "Sony IMX 294 UV-IR CUT R", "Sony IMX 294 UV-IR CUT G",
                              "Sony IMX 294 UV-IR CUT B", "Sony IMX492" );
/* IMX585 库里没有 B 通道曲线，B 用 ZWO 通用曲线近似 */
pipeDefSet( "imx585-uvircut", "Sony IMX 585 R", "Sony IMX 585 G", "ZWO B", "Sony IMX585" );
pipeDefSet( "imx676-uvircut", "Sony IMX 676 R", "Sony IMX 676 G", "Sony IMX 676 B",
                              "Ideal QE curve" );
pipeDefSet( "zwo-uvircut", "ZWO R", "ZWO G", "ZWO B", "Ideal QE curve" );

/* --- Sony 机身（微单/单电，含 A7M3 = ILCE-7M3）--------------------------- */
pipeDefSet( "sony-uvircut", "Sony Color Sensor R-UVIRcut", "Sony Color Sensor G-UVIRcut",
                             "Sony Color Sensor B-UVIRcut", "Ideal QE curve" );
pipeDefSet( "sony-uvcut", "Sony Color Sensor R-UVcut", "Sony Color Sensor G-UVcut",
                           "Sony Color Sensor B-UVcut", "Ideal QE curve" );

/* --- Canon 机身（逐机型曲线）-------------------------------------------- */
pipeDefModel( "canon-1dmk3", "Canon EOS 1D Mark III" );
pipeDefModel( "canon-5dmk2", "Canon EOS 5D Mark II" );
pipeDefModel( "canon-5d", "Canon EOS 5D" );
pipeDefModel( "canon-60d", "Canon EOS 60D" );
pipeDefModel( "canon-600d", "Canon EOS 600D" );
pipeDefModel( "canon-50d", "Canon EOS 50D" );
pipeDefModel( "canon-500d", "Canon EOS 500D" );
pipeDefModel( "canon-40d", "Canon EOS 40D" );
pipeDefModel( "canon-400d", "Canon EOS 400D" );
pipeDefModel( "canon-300d", "Canon EOS 300D" );
pipeDefModel( "canon-20d", "Canon EOS 20D" );
pipeDefModel( "canon-10d", "Canon EOS 10D" );
/* 全光谱改装机（拆了低通/IR cut）：只有这一族有和窄带滤镜的组合曲线 */
pipeDefModel( "canon-fullspectrum", "Canon Full Spectrum" );

/* --- Nikon 机身 ---------------------------------------------------------- */
pipeDefModel( "nikon-z6", "Nikon Z6" );
pipeDefModel( "nikon-d3500", "Nikon D3500" );
pipeDefModel( "nikon-d7000", "Nikon D7000" );
pipeDefModel( "nikon-d5100", "Nikon D5100" );
pipeDefModel( "nikon-d300s", "Nikon D300s" );
pipeDefModel( "nikon-d3x", "Nikon D3X" );
pipeDefModel( "nikon-d700", "Nikon D700" );
pipeDefModel( "nikon-d3", "Nikon D3" );
pipeDefModel( "nikon-d200", "Nikon D200" );
pipeDefModel( "nikon-d90", "Nikon D90" );
pipeDefModel( "nikon-d80", "Nikon D80" );
pipeDefModel( "nikon-d70", "Nikon D70" );
pipeDefModel( "nikon-d50", "Nikon D50" );
pipeDefModel( "nikon-d40", "Nikon D40" );

/* --- Pentax / Vaonis ----------------------------------------------------- */
pipeDefModel( "pentax-k5", "Pentax K-5" );
pipeDefModel( "pentax-q", "Pentax Q" );
pipeDefSet( "vaonis-vespera2-cls", "Vaonis VESPERA II, 3-CLS R", "Vaonis VESPERA II, 3-CLS G",
                                    "Vaonis VESPERA II, 3-CLS B", "Ideal QE curve" );
pipeDefSet( "vaonis-vespera2-dual", "Vaonis VESPERA II, 3-Dual Band R",
                                     "Vaonis VESPERA II, 3-Dual Band G",
                                     "Vaonis VESPERA II, 3-Dual Band B", "Ideal QE curve" );
pipeDefSet( "vaonis-vesperapro-cls", "Vaonis VESPERA Pro 2-CLS R", "Vaonis VESPERA Pro 2-CLS G",
                                     "Vaonis VESPERA Pro 2-CLS B", "Ideal QE curve" );
pipeDefSet( "vaonis-vesperapro-dual", "Vaonis VESPERA Pro 2-Dual Band R",
                                      "Vaonis VESPERA Pro 2-Dual Band G",
                                      "Vaonis VESPERA Pro 2-Dual Band B", "Ideal QE curve" );

/* --- 兜底 ---------------------------------------------------------------- */
pipeDefSet( "generic-color-uvir", "Sony Color Sensor R-UVIRcut", "Sony Color Sensor G-UVIRcut",
                                  "Sony Color Sensor B-UVIRcut", "Ideal QE curve" );

/* ------------------------------------------------------- 传感器族与组合曲线 */

/*
 * family 决定"传感器底座 + 滤镜"的组合曲线怎么写：
 *   sony-cmos   -> "Sony CMOS R-UVIRcut / <滤镜>"
 *   canon-fs    -> "Canon Full Spectrum R / <滤镜>"
 * 其余族不支持组合曲线，用了双窄带滤镜时只能退回底座曲线（会在日志里提示）。
 */
var PIPE_COMPOSITES = {
   "sony-cmos": { R: "Sony CMOS R-UVIRcut / ", G: "Sony CMOS G-UVIRcut / ",
                  B: "Sony CMOS B-UVIRcut / " },
   "canon-fs":  { R: "Canon Full Spectrum R / ", G: "Canon Full Spectrum G / ",
                  B: "Canon Full Spectrum B / " }
};

/* 支持组合曲线的滤镜（左右两侧的写法在两族里并不一致，所以各自存一份）*/
var PIPE_COMPOSITE_FILTERS = [
   { id: "lextreme", label: "Optolong L-eXtreme", filt: /l[\s_-]?extreme|extreme/i,
     sony: "Opt. L-eXtreme", canon: "Opt. L-eXtreme" },
   { id: "lenhance", label: "Optolong L-eNhance", filt: /l[\s_-]?enhance|enhance/i,
     sony: "Opt. L-eNhance", canon: "Opt. L-eNhance" },
   { id: "lultimate", label: "Optolong L-Ultimate", filt: /l[\s_-]?ultimate|ultimate/i,
     sony: "Opt. L-Ultimate", canon: "Opt. L-Ultimate" },
   { id: "alpt", label: "Antlia ALP-T", filt: /alp[\s_-]?t|alpt/i,
     sony: "Antlia-ALP-T", canon: "Antlia ALP-T" },
   { id: "triband", label: "Antlia Triband", filt: /tri[\s_-]?band/i,
     sony: "Antlia Triband", canon: "Antlia Triband" },
   { id: "uhcs", label: "Baader UHC-S", filt: /uhc[\s_-]?s/i,
     sony: "Baader UHC-S", canon: "Baader UHC-S" }
];

/* -------------------------------------------------------------- 相机档案表 */

/*
 * 每条：
 *   id / label  标识与说明
 *   inst        匹配 INSTRUME（正则，自上而下取第一条命中）
 *   family      传感器族，决定能否用组合曲线（可省略）
 *   set         基础曲线组 id
 *   filterSets  按 FILTER 关键字覆盖曲线组（可省略）
 *   approx      true 表示这条是近似匹配，日志会标注
 */
var PIPE_CAMERAS = [
   { id: "seestar", label: "Seestar S50/S30", inst: /seestar/i, family: "seestar",
     set: "seestar-lp",
     filterSets: [ { filterId: "ircut", set: "seestar-ircut" },
                   { filt: /ircut|ir[\s_-]?cut|clear|no ?filter|none/i, set: "seestar-ircut" } ] },

   { id: "imx571", label: "ZWO ASI2600/6200/2400 (IMX571)", family: "sony-cmos",
     inst: /(asi\s?2600|asi\s?6200|asi\s?2400|imx\s?571|zwo\s?26\d\d)/i,
     set: "imx571-uvircut" },
   { id: "imx533", label: "ZWO ASI533 (IMX533)", family: "sony-cmos",
     inst: /(asi\s?533|imx\s?533)/i, set: "imx533-uvircut" },
   { id: "imx294", label: "ZWO ASI294 (IMX294/492)", family: "sony-cmos",
     inst: /(asi\s?294|imx\s?294|imx\s?492)/i, set: "imx294-uvircut" },
   { id: "imx585", label: "ZWO ASI585/662 (IMX585)", family: "sony-cmos",
     inst: /(asi\s?585|asi\s?662|imx\s?585|imx\s?662)/i, set: "imx585-uvircut" },
   { id: "imx676", label: "ZWO ASI676 (IMX676)", family: "sony-cmos",
     inst: /(asi\s?676|imx\s?676)/i, set: "imx676-uvircut" },
   { id: "zwo-generic", label: "其它 ZWO ASI 相机", family: "sony-cmos",
     inst: /(zwo|asi\s?\d)/i, set: "zwo-uvircut" },

   { id: "sony-milc", label: "Sony 微单/单电（A7/A9/A6xxx、ILCE/ILCA）", family: "sony-cmos",
     inst: /(ilce|ilca|sony|alpha|a7[a-z]?|a9|a6\d{3}|nex)/i, set: "sony-uvircut" },

   /* 全光谱改装机要显式命中（机身名里带 full spectrum），否则会被普通机型条目抢走 */
   { id: "canon-fullspectrum", label: "Canon 全光谱改装机", family: "canon-fs",
     inst: /(full[\s_-]?spectrum|fullspectrum|改机|modded)/i, set: "canon-fullspectrum" },
   { id: "canon-1dmk3", label: "Canon EOS 1D Mark III",
     inst: /(1d\s?mark\s?iii|1dmk3|1d3)/i, set: "canon-1dmk3" },
   { id: "canon-5dmk2", label: "Canon EOS 5D Mark II",
     inst: /(5d\s?mark\s?ii|5dmk2|5d2|5dii)/i, set: "canon-5dmk2" },
   { id: "canon-5d", label: "Canon EOS 5D",
     inst: /(eos\s?5d(?!\s?mark)|5d)/i, set: "canon-5d" },
   { id: "canon-60d", label: "Canon EOS 60D",
     inst: /(eos\s?60d|60d)/i, set: "canon-60d" },
   { id: "canon-600d", label: "Canon EOS 600D",
     inst: /(eos\s?600d|600d|t3i|kiss\s?x5)/i, set: "canon-600d" },
   { id: "canon-50d", label: "Canon EOS 50D",
     inst: /(eos\s?50d|50d)/i, set: "canon-50d" },
   { id: "canon-500d", label: "Canon EOS 500D",
     inst: /(eos\s?500d|500d|t1i|kiss\s?x3)/i, set: "canon-500d" },
   { id: "canon-40d", label: "Canon EOS 40D",
     inst: /(eos\s?40d|40d)/i, set: "canon-40d" },
   { id: "canon-400d", label: "Canon EOS 400D",
     inst: /(eos\s?400d|400d|xti|kiss\s?x)/i, set: "canon-400d" },
   { id: "canon-300d", label: "Canon EOS 300D",
     inst: /(eos\s?300d|300d|digital\s?rebel)/i, set: "canon-300d" },
   { id: "canon-20d", label: "Canon EOS 20D",
     inst: /(eos\s?20d|20d)/i, set: "canon-20d" },
   { id: "canon-10d", label: "Canon EOS 10D",
     inst: /(eos\s?10d|10d)/i, set: "canon-10d" },
   { id: "canon-generic", label: "其它 Canon 机身（近似）",
     inst: /(canon|eos)/i, set: "generic-color-uvir", approx: true },

   { id: "nikon-z6", label: "Nikon Z6", inst: /(nikon\s?z\s?6|z\s?6)/i, set: "nikon-z6" },
   { id: "nikon-d3500", label: "Nikon D3500", inst: /(nikon\s?d3500|d3500)/i, set: "nikon-d3500" },
   { id: "nikon-d7000", label: "Nikon D7000", inst: /(nikon\s?d7000|d7000)/i, set: "nikon-d7000" },
   { id: "nikon-d5100", label: "Nikon D5100", inst: /(nikon\s?d5100|d5100)/i, set: "nikon-d5100" },
   { id: "nikon-d300s", label: "Nikon D300s", inst: /(nikon\s?d300s|d300s)/i, set: "nikon-d300s" },
   { id: "nikon-d3x", label: "Nikon D3X", inst: /(nikon\s?d3x|d3x)/i, set: "nikon-d3x" },
   { id: "nikon-d700", label: "Nikon D700", inst: /(nikon\s?d700|d700)/i, set: "nikon-d700" },
   { id: "nikon-d3", label: "Nikon D3", inst: /(nikon\s?d3|d3)/i, set: "nikon-d3" },
   { id: "nikon-d200", label: "Nikon D200", inst: /(nikon\s?d200|d200)/i, set: "nikon-d200" },
   { id: "nikon-d90", label: "Nikon D90", inst: /(nikon\s?d90|d90)/i, set: "nikon-d90" },
   { id: "nikon-d80", label: "Nikon D80", inst: /(nikon\s?d80|d80)/i, set: "nikon-d80" },
   { id: "nikon-d70", label: "Nikon D70", inst: /(nikon\s?d70|d70)/i, set: "nikon-d70" },
   { id: "nikon-d50", label: "Nikon D50", inst: /(nikon\s?d50|d50)/i, set: "nikon-d50" },
   { id: "nikon-d40", label: "Nikon D40", inst: /(nikon\s?d40|d40)/i, set: "nikon-d40" },
   { id: "nikon-generic", label: "其它 Nikon 机身（近似）", inst: /(nikon|d\d{2,4}|z\s?\d)/i,
     set: "generic-color-uvir", approx: true },

   { id: "pentax-k5", label: "Pentax K-5", inst: /(pentax\s?k-?5)/i, set: "pentax-k5" },
   { id: "pentax-q", label: "Pentax Q", inst: /(pentax\s?q)/i, set: "pentax-q" },

   { id: "vaonis-vespera2", label: "Vaonis VESPERA II", inst: /(vespera\s?ii)/i,
     set: "vaonis-vespera2-cls",
     filterSets: [ { filt: /dual|双窄/i, set: "vaonis-vespera2-dual" } ] },
   { id: "vaonis-vesperapro", label: "Vaonis VESPERA Pro", inst: /(vespera\s?pro)/i,
     set: "vaonis-vesperapro-cls",
     filterSets: [ { filt: /dual|双窄/i, set: "vaonis-vesperapro-dual" } ] },

   { id: "generic-color", label: "兜底：通用彩色传感器 + UV/IR cut", inst: /.*/,
     set: "generic-color-uvir", approx: true }
];

/* -------------------------------------------------------------- 滤镜目录 */

/*
 * 每个滤镜条目：
 *   id      标识
 *   label   人可读名称（会写进日志和输出文件的 FITS 关键字）
 *   kind    滤镜类别：broadband（宽带/无滤镜）| light-pollution（光害）| duoband（双/多窄带）
 *   bands   通带，[] 表示不限定；{ name, nm, bw }（bw 为半宽，单位 nm，不确定的填 null）
 *   filt    用元数据 FILTER 或 --filter 的名字匹配
 *   composite  PixInsight 滤镜库里“传感器底座 + 滤镜”的组合曲线后缀：
 *              { sony: "...", canon: "..." }；null 表示库里没有对应组合曲线
 */
var PIPE_FILTERS = [
   { id: "none", label: "无滤镜（仅传感器 UV/IR cut）", kind: "broadband", bands: [],
     filt: /^(none|nofilter|no[\s_-]?filter|clear|uvir|uv[\s\/_-]?ir.*|l|lum|luminance)$/i,
     composite: null },

   { id: "ircut", label: "红外截止滤镜（IRCUT）", kind: "broadband", bands: [],
     filt: /^ir[\s_-]?cut$/i, composite: null },

   { id: "uhcs", label: "Baader UHC-S", kind: "light-pollution", bands: [],
     filt: /uhc[\s_-]?s/i, composite: { sony: "Baader UHC-S", canon: "Baader UHC-S" } },

   { id: "lp", label: "光害滤镜（LP / CLS / L-Pro）", kind: "light-pollution",
     bands: [ { name: "Ha", nm: 656.3, bw: null } ],
     filt: /^(lp|light[\s_-]?pollution)$|^cls|^l-pro|neodymium|skyglow/i, composite: null },

   { id: "lextreme", label: "Optolong L-eXtreme（Ha 656.3nm/7nm + OIII 500.7nm/7nm）",
     kind: "duoband",
     bands: [ { name: "Ha", nm: 656.3, bw: 7 }, { name: "OIII", nm: 500.7, bw: 7 } ],
     filt: /l[\s_-]?extreme|extreme/i,
     composite: { sony: "Opt. L-eXtreme", canon: "Opt. L-eXtreme" } },

   { id: "lultimate", label: "Optolong L-Ultimate（Ha 656.3nm/3nm + OIII 500.7nm/3nm）",
     kind: "duoband",
     bands: [ { name: "Ha", nm: 656.3, bw: 3 }, { name: "OIII", nm: 500.7, bw: 3 } ],
     filt: /l[\s_-]?ultimate|ultimate/i,
     composite: { sony: "Opt. L-Ultimate", canon: "Opt. L-Ultimate" } },

   { id: "lenhance", label: "Optolong L-eNhance（Ha + OIII + Hβ 三带）",
     kind: "duoband",
     bands: [ { name: "Ha", nm: 656.3, bw: null }, { name: "OIII", nm: 500.7, bw: null },
              { name: "Hb", nm: 486.1, bw: null } ],
     filt: /l[\s_-]?enhance|enhance/i,
     composite: { sony: "Opt. L-eNhance", canon: "Opt. L-eNhance" } },

   { id: "alpt", label: "Antlia ALP-T（Ha 656.3nm/5nm + OIII 500.7nm/5nm）",
     kind: "duoband",
     bands: [ { name: "Ha", nm: 656.3, bw: 5 }, { name: "OIII", nm: 500.7, bw: 5 } ],
     filt: /alp[\s_-]?t|alpt/i,
     composite: { sony: "Antlia-ALP-T", canon: "Antlia ALP-T" } },

   { id: "triband", label: "Antlia Triband RGB Ultra（Ha + OIII + Hβ）",
     kind: "duoband",
     bands: [ { name: "Ha", nm: 656.3, bw: null }, { name: "OIII", nm: 500.7, bw: null },
              { name: "Hb", nm: 486.1, bw: null } ],
     filt: /tri[\s_-]?band/i,
     composite: { sony: "Antlia Triband", canon: "Antlia Triband" } },

   { id: "nbz", label: "IDAS NBZ（Ha + OIII 双窄带）", kind: "duoband",
     bands: [ { name: "Ha", nm: 656.3, bw: 12 }, { name: "OIII", nm: 500.7, bw: 12 } ],
     filt: /nbz/i, composite: null },

   { id: "dual-narrowband", label: "双窄带滤镜（未指定型号）", kind: "duoband",
     bands: [ { name: "Ha", nm: 656.3, bw: null }, { name: "OIII", nm: 500.7, bw: null } ],
     filt: /dual[\s_-]?band|duo[\s_-]?band|双窄/i,
     composite: { sony: "Opt. L-eXtreme", canon: "Opt. L-eXtreme" }, approx: true },

   { id: "ha", label: "Hα 单窄带", kind: "narrowband",
     bands: [ { name: "Ha", nm: 656.3, bw: null } ], filt: /^ha$|h[\s_-]?alpha|hα/i,
     composite: null },
   { id: "oiii", label: "OIII 单窄带", kind: "narrowband",
     bands: [ { name: "OIII", nm: 500.7, bw: null } ], filt: /^oiii$|o[\s_-]?iii/i,
     composite: null },
   { id: "sii", label: "SII 单窄带", kind: "narrowband",
     bands: [ { name: "SII", nm: 672.4, bw: null } ], filt: /^sii$|s[\s_-]?ii/i,
     composite: null }
];

/* 常见谱线的标准波长（nm），用于把用户给的纯数字波长翻译成名字 */
var PIPE_LINES = [
   { name: "OIII", nm: 500.7 }, { name: "Hb", nm: 486.1 }, { name: "Ha", nm: 656.3 },
   { name: "SII", nm: 672.4 }, { name: "NII", nm: 658.3 }
];

function pipeLineName( nm )
{
   var best = null, bestD = 1e9;
   for ( var i = 0; i < PIPE_LINES.length; ++i )
   {
      var d = Math.abs( PIPE_LINES[i].nm - nm );
      if ( d < bestD ) { bestD = d; best = PIPE_LINES[i]; }
   }
   return ( best && bestD <= 12 ) ? best.name : null;
}

/* 把 "Ha=656.3/7,OIII=500.7/7" 或 "656.3,500.7" 解析成通带数组 */
function pipeParseBands( spec )
{
   var bands = [];
   if ( !spec ) return bands;
   var parts = spec.split( /[;,]/ );
   for ( var i = 0; i < parts.length; ++i )
   {
      var t = parts[i].replace( /^\s+|\s+$/g, "" );
      if ( t.length == 0 ) continue;
      var name = null, rest = t;
      var eq = t.indexOf( "=" );
      if ( eq > 0 ) { name = t.substring( 0, eq ).replace( /^\s+|\s+$/g, "" ); rest = t.substring( eq + 1 ); }
      var sl = rest.split( "/" );
      var nm = parseFloat( sl[0] );
      if ( isNaN( nm ) ) continue;
      var bw = ( sl.length > 1 ) ? parseFloat( sl[1] ) : null;
      if ( bw !== null && isNaN( bw ) ) bw = null;
      if ( !name ) name = pipeLineName( nm ) || ( "λ" + nm );
      bands.push( { name: name, nm: nm, bw: bw } );
   }
   return bands;
}

function pipeBandString( bands )
{
   if ( !bands || bands.length == 0 ) return "(未指定通带)";
   var s = [];
   for ( var i = 0; i < bands.length; ++i )
   {
      var b = bands[i];
      s.push( b.name + " " + b.nm.toFixed( 1 ) + "nm" + ( b.bw ? "/" + b.bw + "nm" : "" ) );
   }
   return s.join( " + " );
}

/* 自定义双窄带：按通带数量与带宽，找最接近的内置组合曲线 */
function pipeNearestCompositeFilter( bands )
{
   var best = null, bestScore = 1e9;
   for ( var i = 0; i < PIPE_FILTERS.length; ++i )
   {
      var f = PIPE_FILTERS[i];
      if ( f.kind != "duoband" || !f.composite || !f.bands || f.bands.length != bands.length )
         continue;
      if ( f.approx ) continue;
      var score = 0, ok = true;
      for ( var b = 0; b < bands.length; ++b )
      {
         var nb = bands[b].bw, fb = f.bands[b].bw;
         if ( nb !== null && fb !== null ) score += Math.abs( nb - fb );
         else score += 1.5;
      }
      if ( score < bestScore ) { bestScore = score; best = f; }
   }
   return ( best && bestScore <= 4 ) ? { filter: best, score: bestScore } : null;
}

/*
 * 解析滤镜：优先用显式波长（nmSpec），其次用名字（filtName），
 * kindHint = broadband|light-pollution|duoband|narrowband 可强制类别。
 * 返回 { id, label, kind, bands, composite, approx, note }
 */
function pipeResolveFilter( filtName, kindHint, nmSpec )
{
   var name = ( filtName || "" ).replace( /^\s+|\s+$/g, "" );
   var bands = pipeParseBands( nmSpec );
   var matched = null;
   if ( name.length > 0 )
      for ( var i = 0; i < PIPE_FILTERS.length; ++i )
         if ( PIPE_FILTERS[i].filt.test( name ) ) { matched = PIPE_FILTERS[i]; break; }

   var kind = kindHint || ( matched ? matched.kind : null );

   if ( bands.length > 0 )
   {
      if ( !kind )
         kind = ( bands.length >= 2 ) ? "duoband" : "narrowband";
      var base = ( matched && matched.kind != "broadband" )
                 ? matched.label.split( "（" )[0] + " 自定义通带" : "自定义滤镜";
      var fid = ( matched && matched.kind != "broadband" ) ? matched.id + "+custom" : "custom-" + kind;
      var f = { id: fid,
                label: base + "（" + pipeBandString( bands ) + "）",
                kind: kind, bands: bands, composite: null, approx: false, note: "" };
      if ( matched && matched.composite && matched.bands.length == bands.length )
         f.composite = matched.composite;
      else if ( kind == "duoband" )
      {
         var near = pipeNearestCompositeFilter( bands );
         if ( near )
         {
            f.composite = near.filter.composite;
            f.approx = true;
            f.note = "自定义通带按带宽最近似匹配到 " + near.filter.label.split( "（" )[0];
         }
         else f.note = "自定义双窄带在滤镜库里没有对应的组合曲线，将使用相机底座曲线";
      }
      return f;
   }

   if ( matched )
   {
      var r = { id: matched.id, label: matched.label, kind: kind, bands: matched.bands,
                composite: matched.composite, approx: matched.approx === true, note: "" };
      if ( kindHint && kindHint != matched.kind )
         r.note = "类别被 --filter-kind 覆盖为 " + kindHint + "（原判为 " + matched.kind + "）";
      return r;
   }

   /* 名字没命中任何已知滤镜 */
   if ( name.length > 0 )
      return { id: "unknown:" + name, label: name + "（未收录）", kind: kind || "unknown",
               bands: [], composite: null, approx: true,
               note: "滤镜未收录，无法判断通带；可用 --filter-nm 直接给波长（如 Ha=656.3/7,OIII=500.7/7）" };
   return { id: "unknown", label: "（未标注）", kind: kind || "unknown", bands: [],
            composite: null, approx: false,
            note: ( kind && kind != "unknown" ) ? ""
                : "元数据里没有 FILTER 关键字，无法判断是否用了双/多窄带；"
                  + "建议用 --filter / --filter-kind / --filter-nm 明确标注" };
}

/* 把滤镜标注写成 FITS 关键字（写进输出文件，跟着文件走） */
/* FITS 关键字值只允许 ASCII，非 ASCII 字符必须去掉，否则读出来是乱码 */
function pipeAscii( s )
{
   if ( s === null || s === undefined ) return "";
   var t = ( "" + s ).replace( /（/g, "(" ).replace( /）/g, ")" )
                     .replace( /；/g, ";" ).replace( /，/g, "," )
                     .replace( /＋/g, "+" ).replace( /／/g, "/" );
   var out = "";
   for ( var i = 0; i < t.length; ++i )
      if ( t.charCodeAt( i ) >= 32 && t.charCodeAt( i ) < 127 ) out += t.charAt( i );
   return out.replace( /^\s+|\s+$/g, "" ).replace( /\s{2,}/g, " " );
}

function pipeApplyAnnotation( win, filt, extra )
{
   try
   {
      var kw = win.keywords.slice( 0 );
      function setkw( name, value, comment )
      {
         var v = pipeAscii( value );
         if ( v.length == 0 ) return;
         for ( var i = 0; i < kw.length; ++i )
            if ( kw[i].name == name ) { kw.splice( i, 1 ); break; }
         kw.push( new FITSKeyword( name, v, comment ) );
      }
      setkw( "PIPEFILT", filt.id, "astro pipeline: filter id" );
      setkw( "PIPEFLAB", pipeAscii( filt.label ) || filt.id, "astro pipeline: filter description" );
      setkw( "PIPEKIND", filt.kind, "astro pipeline: broadband/light-pollution/duoband/narrowband" );
      setkw( "PIPEBND", pipeBandString( filt.bands ), "astro pipeline: passbands" );
      if ( filt.bands && filt.bands.length >= 2 ) setkw( "PIPEDUO", "T", "astro pipeline: multi-band (duoband) filter used" );
      else setkw( "PIPEDUO", "F", "astro pipeline: multi-band (duoband) filter used" );
      for ( var b = 0; b < ( filt.bands || [] ).length; ++b )
         setkw( "PIPE" + filt.bands[b].name.toUpperCase(),
                filt.bands[b].nm + ( filt.bands[b].bw ? "/" + filt.bands[b].bw : "" ),
                "astro pipeline: passband nm (and fwhm nm)" );
      if ( extra )
         for ( var k in extra )
            if ( extra.hasOwnProperty( k ) ) setkw( k, extra[k], "astro pipeline" );
      win.keywords = kw;
      return kw.length;
   }
   catch ( e ) { return -1; }
}

/* ---------------------------------------------------------------- 元数据读取 */

/* ImageWindow.keywords 返回 {KEY,value,comment} 形式的字符串数组 */
function pipeKeywords( win )
{
   var d = {};
   try
   {
      var kw = win.keywords;
      for ( var i = 0; i < kw.length; ++i )
      {
         var s = kw[i].toString();
         var parts = s.replace( /^\{|\}$/g, "" ).split( "," );
         if ( parts.length >= 2 )
         {
            var key = parts[0].trim();
            var val = parts[1].trim().replace( /^\x27|\x27$/g, "" );
            d[key] = val;
         }
      }
   }
   catch ( e ) {}
   return d;
}

/* --------------------------------------------------------------- 档案解析 */

function pipeFindCamera( inst )
{
   for ( var i = 0; i < PIPE_CAMERAS.length; ++i )
      if ( PIPE_CAMERAS[i].inst.test( inst ) )
         return PIPE_CAMERAS[i];
   return PIPE_CAMERAS[PIPE_CAMERAS.length - 1];
}

function pipeFindCompositeFilter( filt )
{
   if ( !filt ) return null;
   for ( var i = 0; i < PIPE_COMPOSITE_FILTERS.length; ++i )
      if ( PIPE_COMPOSITE_FILTERS[i].filt.test( filt ) )
         return PIPE_COMPOSITE_FILTERS[i];
   return null;
}

/* 由曲线组 id + 传感器族 + 已解析的滤镜，组装出最终三个通道的曲线名 */
function pipeResolveSet( setId, family, filterObj, db, wantQE )
{
   var base = PIPE_SETS[setId];
   if ( !base ) return null;
   var out = { id: setId, R: base.R, G: base.G, B: base.B, QE: wantQE || base.QE,
               composite: null, missing: [] };
   var pre = family ? PIPE_COMPOSITES[family] : null;
   if ( filterObj && filterObj.composite && pre )
   {
      var suffix = (family == "canon-fs") ? filterObj.composite.canon : filterObj.composite.sony;
      out.R = pre.R + suffix;
      out.G = pre.G + suffix;
      out.B = pre.B + suffix;
      out.composite = filterObj.id;
   }
   return out;
}

/* 校验一组曲线是否真的在库里存在，返回缺失的通道列表 */
function pipeValidateSet( set, db )
{
   var missing = [];
   if ( !set ) return [ "整组缺失" ];
   if ( !pipeHasCurve( db, set.R, "R" ) ) missing.push( "R:" + set.R );
   if ( !pipeHasCurve( db, set.G, "G" ) ) missing.push( "G:" + set.G );
   if ( !pipeHasCurve( db, set.B, "B" ) ) missing.push( "B:" + set.B );
   if ( !pipeHasCurve( db, set.QE, "Q" ) ) missing.push( "Q:" + set.QE );
   return missing;
}

/*
 * 主入口：wanted 为空 / "auto" 时按元数据自动匹配；也可指定相机 id 或预设组 id。
 * 返回 { profile, set, inst, filt, matched, note, missing }
 */
function pipePickProfile( win, wanted, dbPath, filtOverride, filterHint )
{
   var db = dbPath || PIPE_DB_DEFAULT;
   wanted = wanted || "auto";
   var meta = pipeKeywords( win );
   var inst = meta["INSTRUME"] || meta["TELESCOP"] || meta["CREATOR"] || "";
   var filt = filtOverride || meta["FILTER"] || "";
   var hint = filterHint || {};
   var flt = pipeResolveFilter( filt, hint.kind, hint.nm );
   var r = { profile: null, set: null, inst: inst, filt: filt, filter: flt,
             matched: "", note: flt.note || "", missing: [] };

   if ( wanted == "none" )
   {
      r.matched = "disabled";
      r.note = "profile=none，跳过分光光度定标";
      return r;
   }

   var cam = null;
   if ( wanted != "auto" )
   {
      /* 先当相机 id 找，再当曲线组 id 找 */
      for ( var i = 0; i < PIPE_CAMERAS.length; ++i )
         if ( PIPE_CAMERAS[i].id == wanted ) { cam = PIPE_CAMERAS[i]; break; }
      if ( !cam && PIPE_SETS[wanted] )
      {
         r.matched = "explicit-set";
         r.set = pipeResolveSet( wanted, null, null, db );
         r.missing = pipeValidateSet( r.set, db );
         return r;
      }
      if ( !cam )
      {
         r.matched = "unknown-id:" + wanted;
         r.note = "未知档案 id，按 auto 处理";
      }
      else
         r.matched = "explicit";
   }
   if ( !cam )
   {
      cam = pipeFindCamera( inst );
      r.matched = "auto";
   }
   r.profile = cam;

   /* FILTER 专用曲线组 */
   var setId = cam.set, via = null;
   if ( cam.filterSets )
   {
      for ( var k = 0; k < cam.filterSets.length; ++k )
      {
         var fs = cam.filterSets[k];
         if ( fs.filterId && fs.filterId == flt.id ) { setId = fs.set; via = "filter-id"; break; }
         if ( fs.filt && filt && fs.filt.test( filt ) ) { setId = fs.set; via = "filter"; break; }
      }
   }

   var set = pipeResolveSet( setId, cam.family, flt, db );
   if ( !set )
   {
      set = pipeResolveSet( "generic-color-uvir", null, null, db );
      r.note = "曲线组缺失，退回通用彩色传感器曲线";
   }
   var missing = pipeValidateSet( set, db );
   if ( missing.length > 0 )
   {
      /* 组合曲线不齐（比如库里没有该滤镜的组合）就退回不带滤镜的底座曲线 */
      var fb = pipeResolveSet( cam.set, null, null, db );
      if ( fb )
      {
         var fbMissing = pipeValidateSet( fb, db );
         r.note = "曲线缺失 [" + missing.join( ", " ) + "]，退回 " + fb.id
                + ( fbMissing.length ? "（该组还缺 " + fbMissing.join( ", " ) + "）" : "" );
         set = fb;
         missing = fbMissing;
      }
   }
   if ( missing.length > 0 )
   {
      set = pipeResolveSet( "generic-color-uvir", null, null, db );
      missing = pipeValidateSet( set, db );
      r.note += " 最终退回通用彩色传感器曲线";
   }

   r.set = set;
   r.missing = missing;
   if ( via ) r.note += ( r.note ? " " : "" ) + "FILTER=" + filt + " 命中专用曲线组(" + via + ")";
   if ( cam.approx )
      r.note += ( r.note ? " " : "" )
              + "（库里没有该机型的专用曲线，用通用彩色传感器曲线近似；可用 profile= 或 filter= 手动指定）";
   return r;
}

/* 供文档/诊断用：把所有相机档案解析一遍并校验曲线 */
function pipeAuditProfiles( dbPath )
{
   var db = dbPath || PIPE_DB_DEFAULT;
   var rows = [];
   for ( var i = 0; i < PIPE_CAMERAS.length; ++i )
   {
      var cam = PIPE_CAMERAS[i];
      var set = pipeResolveSet( cam.set, cam.family, null, db );
      var missing = pipeValidateSet( set, db );
      var composites = [];
      if ( cam.family )
         for ( var f = 0; f < PIPE_FILTERS.length; ++f )
         {
            var pf = PIPE_FILTERS[f];
            if ( !pf.composite || cam.family == "seestar" ) continue;
            var cs = pipeResolveSet( cam.set, cam.family, pf, db );
            var cm = pipeValidateSet( cs, db );
            composites.push( pf.id + ( cm.length ? "(缺:" + cm.join( "," ) + ")" : "✓" ) );
         }
      rows.push( { id: cam.id, label: cam.label, set: set.id,
                   curves: set.R + " | " + set.G + " | " + set.B + " | QE=" + set.QE,
                   missing: missing, composites: composites.join( " " ) } );
   }
   return rows;
}
