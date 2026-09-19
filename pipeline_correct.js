/*
 * pipeline_correct.js — 通用：对一个 master 做 SPFC（分光光度流量校准）+ 可选 MGC（MARS 梯度校正），另存结果
 *
 * 用法:
 *   -r="pipeline_correct.js,master=<in.xisf>,out=<out.xisf>[,profile=auto][,filter=<滤镜名>]
 *       [,filterkind=broadband|light-pollution|duoband|narrowband][,filternm=Ha=656.3/7,OIII=500.7/7]
 *       [,mgc=1][,mars=<.xmars>][,log=<path>][,db=<filters.xspd>]"
 *
 * profile: auto（默认，按 INSTRUME/FILTER 自动匹配档案）| <相机档案 id> | <曲线组 id> | none
 * filter     : 手动指定滤镜名（覆盖元数据里的 FILTER），用于 ASIAir 这类不写 FILTER 的数据
 * filterkind : 强制滤镜类别（双窄带务必标 duoband）
 * filternm   : 直接给通带波长，如 "Ha=656.3/7,OIII=500.7/7"
 */
#include "pipeline_profiles.jsh"

var A = {};
for (var i = 0; i < jsArguments.length; ++i)
{
   var kv = jsArguments[i], eq = kv.indexOf("=");
   if (eq > 0) A[kv.substring(0, eq)] = kv.substring(eq + 1);
}

var LOG = A.log !== undefined ? A.log : "/tmp/pipeline_correct.log";
var out = [];
function L(s) { out.push(s); try { File.writeTextFile(LOG, out.join("\n") + "\n"); } catch (e) {} }

var DB = A.db !== undefined ? A.db : PIPE_DB_DEFAULT;

try
{
   var wanted = A.profile !== undefined ? A.profile : "auto";

   var w = ImageWindow.open( A.master );
   if ( w.length == 0 ) throw new Error( "打不开: " + A.master );
   var view = w[0].mainView;
   L(File.extractName(A.master) + "  " + view.image.width + "x" + view.image.height
     + "  WCS=" + w[0].hasAstrometricSolution);

   var pick = pipePickProfile( w[0], wanted, DB, A.filter,
                               { kind: A.filterkind, nm: A.filternm } );
   L("   元数据: INSTRUME=" + (pick.inst || "(无)") + "  FILTER=" + (pick.filt || "(无)"));
   L("   档案: " + (pick.profile ? pick.profile.id + " — " + pick.profile.label : "(无)")
     + "   匹配=" + pick.matched);
   L("   滤镜: " + pick.filter.label
     + "   类别=" + pick.filter.kind
     + "   通带=" + pipeBandString( pick.filter.bands )
     + ( pick.filter.kind == "duoband" || (pick.filter.bands && pick.filter.bands.length >= 2)
         ? "   [双/多窄带]" : "" ));
   if ( pick.note ) L("   说明: " + pick.note);

   var okF = "skipped";
   var set = pick.set;
   if ( wanted != "none" && set )
   {
      L("   曲线组: " + set.id + (set.composite ? "（组合:" + set.composite + "）" : ""));
      L("     R=" + set.R + "  G=" + set.G + "  B=" + set.B + "  QE=" + set.QE);
      if ( pick.missing && pick.missing.length )
         L("!! 警告：库里缺 " + pick.missing.join( ", " ));

      var F = new SpectrophotometricFluxCalibration;
      F.redFilterName = set.R;     F.redFilterTrCurve = pipeCurve(DB, set.R, "R");
      F.greenFilterName = set.G;   F.greenFilterTrCurve = pipeCurve(DB, set.G, "G");
      F.blueFilterName = set.B;    F.blueFilterTrCurve = pipeCurve(DB, set.B, "B");
      F.deviceQECurveName = set.QE; F.deviceQECurve = pipeCurve(DB, set.QE, "Q");
      if ( !F.redFilterTrCurve || !F.deviceQECurve )
         L("!! 警告：曲线数据为空（检查滤镜库里是否有这些名字）");
      okF = F.executeOn( view );
   }
   L("   SPFC = " + okF);

   var okG = "skipped";
   if ( A.mgc == "1" || A.mgc == "true" )
   {
      var Gm = new MultiscaleGradientCorrection;
      Gm.useMARSDatabase = true;
      if ( A.mars !== undefined ) Gm.marsDatabaseFiles = [[true, A.mars]];
      okG = Gm.executeOn( view );
      L("   MGC(+MARS) = " + okG);
   }

   var nw = new ImageWindow( view.image.width, view.image.height, view.image.numberOfChannels, 32, true, true, "pipeline_out" );
   nw.mainView.beginProcess();
   nw.mainView.image.assign( view.image );
   nw.mainView.endProcess();
   /* 新窗口默认不带 FITS 关键字，必须显式继承，否则下游（自动档案 / 元数据）会失明 */
   try { nw.keywords = w[0].keywords; L("   已继承 " + nw.keywords.length + " 条 FITS 关键字"); }
   catch ( e ) { L("   关键字继承失败: " + e ); }
   var nk = pipeApplyAnnotation( nw, pick.filter,
                                 { "PIPEPROF": pick.profile ? pick.profile.id : "none",
                                   "PIPESET": set ? set.id : "none" } );
   L( nk > 0 ? "   已写入滤镜标注（关键字共 " + nk + " 条）" : "   滤镜标注写入失败" );
   if ( w[0].hasAstrometricSolution )
   {
      try { nw.copyAstrometricSolution( w[0] ); L("   WCS 已保留"); }
      catch ( e ) { L("   WCS 复制失败: " + e ); }
   }
   nw.saveAs( A.out, false, false, false, true );
   nw.forceClose();
   L("   已保存: " + A.out);
}
catch ( e ) { L("ERR: " + e); }
