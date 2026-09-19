/*
 * pipeline_finish.js — 通用：统一画幅 + ImageIntegration，输出带 WCS 的最终 master
 * 用法: -r="pipeline_finish.js,inputs=<list.txt>,work=<dir>,out=<dir>,tag=<name>[,log=...]"
 */
var A = {};
for (var i = 0; i < jsArguments.length; ++i)
{
   var kv = jsArguments[i], eq = kv.indexOf("=");
   if (eq > 0) A[kv.substring(0, eq)] = kv.substring(eq + 1);
}
var LOG = A.log !== undefined ? A.log : "/tmp/pipeline_finish.log";
var lines = [];
function L(s) { lines.push( "[" + (new Date()).toTimeString().substring(0,8) + "] " + s );
                 try { File.writeTextFile( LOG, lines.join("\n") + "\n" ); } catch (e) {} }
function ensureDir(d) { if (!File.directoryExists(d)) File.createDirectory(d, true); }
function readList(p)
{
   var res = [], raw = File.readTextFile(p).split("\n");
   for (var i = 0; i < raw.length; ++i)
   {
      var s = raw[i].replace(/^\s+|\s+$/g, "");
      if (s.length > 0 && s.charAt(0) != "#" && res.indexOf(s) < 0) res.push(s);
   }
   return res;
}
function windowIds() { var ids = [], w = ImageWindow.windows; for (var i = 0; i < w.length; ++i) ids.push(w[i].mainView.id); return ids; }
function known(ids, id) { for (var i = 0; i < ids.length; ++i) if (ids[i] == id) return true; return false; }

try
{
   var WORK = A.work, OUT = A.out, TAG = A.tag !== undefined ? A.tag : "mosaic";
   var inputs = readList( A.inputs );
   ensureDir( WORK ); ensureDir( OUT );
   L("finish: " + inputs.length + " 张输入");

   /* 1) 画布是否一致 */
   var sizes = {}, maxArea = -1, maxIdx = 0;
   for (var i = 0; i < inputs.length; ++i)
   {
      var w = ImageWindow.open( inputs[i] );
      if ( w.length == 0 ) throw new Error( "打不开: " + inputs[i] );
      var iw = w[0].mainView.image.width, ih = w[0].mainView.image.height;
      w[0].forceClose();
      L("  画布 " + iw + "x" + ih + "  " + File.extractName(inputs[i]));
      sizes[iw + "x" + ih] = true;
      if ( iw * ih > maxArea ) { maxArea = iw * ih; maxIdx = i; }
   }
   var distinct = 0; for (var s in sizes) ++distinct;

   if ( distinct > 1 )
   {
      L("画布不一致 -> 统一到 " + File.extractName(inputs[maxIdx]));
      var ADIR = WORK + "/aligned_" + TAG;
      ensureDir( ADIR );
      var U = new StarAlignment;
      U.mode = U.RegisterMatch;
      U.referenceImage = inputs[maxIdx];
      U.referenceIsFile = true;
      U.outputDirectory = ADIR;
      U.outputExtension = ".xisf";
      U.outputPrefix = "";
      U.outputPostfix = "_u";
      U.overwriteExistingFiles = true;
      U.generateDrizzleData = false;
      U.generateHistoryProperties = false;
      U.polygonSides = 5;
      U.useTriangles = false;
      U.inheritAstrometricSolution = true;
      var tg = [];
      for (var t = 0; t < inputs.length; ++t) tg.push([true, true, inputs[t]]);
      U.targets = tg;
      if ( !U.executeGlobal() ) L("   !! 统一画幅失败");
      var al = [];
      for (var a = 0; a < inputs.length; ++a)
      {
         var ap = ADIR + "/" + File.extractName(inputs[a]) + "_u.xisf";
         if ( File.exists(ap) ) al.push(ap); else L("   缺少: " + ap);
      }
      if ( al.length >= 2 ) inputs = al;
   }
   else L("画布一致，无需统一");

   /* 2) 积分 */
   var II = new ImageIntegration;
   var imgs = [];
   for (var r = 0; r < inputs.length; ++r) imgs.push( [true, inputs[r], "", ""] );
   II.images = imgs;
   II.generateIntegratedImage = true;
   II.generateRejectionMaps = false;
   II.generateDrizzleData = false;
   II.closePreviousImages = true;
   II.rejection = II.NoRejection;

   var before = windowIds();
   if ( !II.executeGlobal() ) L("   !! 积分失败");
   var resultWindow = null, after = windowIds();
   for (var m = 0; m < after.length; ++m)
      if ( !known(before, after[m]) )
      {
         var cand = ImageWindow.windowById( after[m] );
         if ( cand != null && cand.mainView.image.numberOfChannels >= 3 ) resultWindow = cand;
      }
   if ( resultWindow == null ) throw new Error( "找不到积分结果窗口" );
   L("结果: " + resultWindow.mainView.image.width + "x" + resultWindow.mainView.image.height);

   /* 3) 保存（含 WCS 继承） */
   var view = resultWindow.mainView;
   var nw = new ImageWindow( view.image.width, view.image.height, view.image.numberOfChannels, 64, true, true, "master_copy" );
   nw.mainView.beginProcess();
   nw.mainView.image.assign( view.image );
   nw.mainView.endProcess();
   /* 关键字：取第一个带关键字的输入（通常是参考帧/第一个分组） */
   var kwWin = null;
   for (var ki = 0; ki < inputs.length && kwWin == null; ++ki)
   {
      var kt = ImageWindow.open( inputs[ki] );
      if ( kt.length > 0 )
      {
         if ( kt[0].keywords.length > 0 )
         {
            try { nw.keywords = kt[0].keywords; L("关键字已继承自 " + File.extractName(inputs[ki]) + "（" + nw.keywords.length + " 条）"); }
            catch ( e ) { L("关键字继承失败: " + e ); }
            kwWin = kt[0];
         }
         else kt[0].forceClose();
      }
   }
   if ( kwWin != null ) kwWin.forceClose();
   var srcWin = null;
   for (var wi = 0; wi < inputs.length && srcWin == null; ++wi)
   {
      var test = ImageWindow.open( inputs[wi] );
      if ( test.length > 0 )
      {
         if ( test[0].hasAstrometricSolution ) { nw.copyAstrometricSolution( test[0] ); L("WCS 已继承自 " + File.extractName(inputs[wi])); srcWin = test[0]; }
         else test[0].forceClose();
      }
   }
   if ( srcWin != null ) srcWin.forceClose();
   else L("!! 输入均无 WCS，最终 master 将不带天体测量解");

   var masterPath = OUT + "/" + TAG + "_master.xisf";
   nw.saveAs( masterPath, false, false, false, true );
   L("master 已保存: " + masterPath);
}
catch ( e ) { L("!! 失败: " + e); }
