/*
 * pipeline_preview.js — 通用：对 master 做自动拉伸并导出 JPEG 预览
 * 用法: -r="pipeline_preview.js,master=<xisf>,out=<jpg>[,log=<path>]"
 */
var A = {};
for (var i = 0; i < jsArguments.length; ++i)
{
   var kv = jsArguments[i], eq = kv.indexOf("=");
   if (eq > 0) A[kv.substring(0, eq)] = kv.substring(eq + 1);
}
var LOG = A.log !== undefined ? A.log : "/tmp/pipeline_preview.log";
function L(s) { try { File.writeTextFile( LOG, "[" + (new Date()).toTimeString().substring(0,8) + "] " + s + "\n" ); } catch (e) {} }

try
{
   var wins = ImageWindow.open( A.master );
   if ( wins.length == 0 ) throw new Error( "打不开: " + A.master );
   var view = wins[0].mainView;
   var n = view.image.isColor ? 3 : 1;
   var med = view.computeOrFetchProperty("Median");
   var mad = view.computeOrFetchProperty("MAD");
   mad.mul(1.4826);
   var c0 = 0, mid = 0;
   for (var c = 0; c < n; ++c) { c0 += med.at(c) - 2.8 * mad.at(c); mid += med.at(c); }
   c0 = Math.range(c0 / n, 0, 1);
   var mt = Math.mtf(0.25, mid / n - c0);
   var HT = new HistogramTransformation;
   HT.H = [[c0, mt, 1, 0, 1], [c0, mt, 1, 0, 1], [c0, mt, 1, 0, 1], [0, 0.5, 1, 0, 1]];
   HT.executeOn( view );
   view.window.saveAs( A.out, false, false, false, true );
   L("预览已保存 " + A.out + "  (shadows=" + c0.toFixed(5) + " midtones=" + mt.toFixed(5) + ")");
}
catch ( e ) { L("!! 失败: " + e); }
