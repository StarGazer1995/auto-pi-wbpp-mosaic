/*
 * pipeline_union_pair.js — 通用：把单个 master 以 StarAlignment Register/Union - Mosaic 配准到参考帧并另存
 * 用法: -r="pipeline_union_pair.js,ref=<xisf>,target=<xisf>,out=<xisf>[,log=<path>]"
 * 说明：union 模式只能 view 执行；且同一 PI 进程里连续多次"新建窗口+保存"会卡死，所以一次只处理一对。
 */
var A = {};
for (var i = 0; i < jsArguments.length; ++i)
{
   var kv = jsArguments[i], eq = kv.indexOf("=");
   if (eq > 0) A[kv.substring(0, eq)] = kv.substring(eq + 1);
}
var LOG = A.log !== undefined ? A.log : "/tmp/pipeline_union_pair.log";
function L(s) { try { File.writeTextFile( LOG, "[" + (new Date()).toTimeString().substring(0,8) + "] " + s + "\n" ); } catch (e) {} }

try
{
   var refWins = ImageWindow.open( A.ref );
   if ( refWins.length == 0 ) throw new Error( "打不开 ref: " + A.ref );
   var tgtWins = ImageWindow.open( A.target );
   if ( tgtWins.length == 0 ) throw new Error( "打不开 target: " + A.target );

   var SA = new StarAlignment;
   SA.mode = SA.RegisterUnion;
   SA.intersection = SA.MosaicOnly;
   SA.referenceImage = refWins[0].mainView.id;
   SA.referenceIsFile = false;
   SA.generateDrizzleData = false;
   SA.generateHistoryProperties = false;
   SA.polygonSides = 5;
   SA.useTriangles = false;
   SA.inheritAstrometricSolution = true;      // 并集结果继承参考帧的 WCS

   var before = [];
   var wins = ImageWindow.windows;
   for (var i = 0; i < wins.length; ++i) before.push( wins[i].mainView.id );

   var ok = SA.executeOn( tgtWins[0].mainView );
   if ( !ok ) throw new Error( "配准失败" );

   var outWin = null;
   wins = ImageWindow.windows;
   for (var k = 0; k < wins.length; ++k)
   {
      var id = wins[k].mainView.id, known = false;
      for (var b = 0; b < before.length; ++b) if (before[b] == id) known = true;
      if (!known && wins[k].mainView.image.numberOfChannels >= 3) outWin = wins[k];
   }
   if (outWin == null) throw new Error( "没找到并集输出窗口" );

   var w = outWin.mainView.image.width, h = outWin.mainView.image.height;
   L("并集画布 " + w + "x" + h + "  WCS=" + outWin.hasAstrometricSolution);

   var nw = new ImageWindow( w, h, outWin.mainView.image.numberOfChannels, 64, true, true, "union_copy" );
   nw.mainView.beginProcess();
   nw.mainView.image.assign( outWin.mainView.image );
   nw.mainView.endProcess();
   /* 继承参考帧的 FITS 关键字，保证并集结果仍能被自动档案识别 */
   try { nw.keywords = refWins[0].keywords; L("继承 " + nw.keywords.length + " 条关键字（来自参考帧）"); }
   catch ( e ) { L("关键字继承失败: " + e ); }
   if ( outWin.hasAstrometricSolution ) nw.copyAstrometricSolution( outWin );
   nw.saveAs( A.out, false, false, false, true );
   nw.forceClose();
   L("已保存 " + A.out);
}
catch ( e ) { L("!! 失败: " + e); }
