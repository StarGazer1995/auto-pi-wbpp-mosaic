/*
 * pipeline_spcc.js — 通用：对 master 做 SPCC 分光光度校色（可选另存 + 预览）
 * 用法: -r="pipeline_spcc.js,master=<xisf>[,out=<xisf>][,profile=auto|id][,filter=<滤镜名>]
 *        [,filterkind=broadband|light-pollution|duoband|narrowband][,filternm=Ha=656.3/7,OIII=500.7/7]
 *        [,log=<path>][,db=<filters.xspd>]"
 */
#include "pipeline_profiles.jsh"

var A = {};
for (var i = 0; i < jsArguments.length; ++i)
{
   var kv = jsArguments[i], eq = kv.indexOf("=");
   if (eq > 0) A[kv.substring(0, eq)] = kv.substring(eq + 1);
}
var LOG = A.log !== undefined ? A.log : "/tmp/pipeline_spcc.log";
var LOGLINES = [];
function L(s) { LOGLINES.push( "[" + (new Date()).toTimeString().substring(0,8) + "] " + s );
                try { File.writeTextFile( LOG, LOGLINES.join("\n") + "\n" ); } catch (e) {} }

var DB = A.db !== undefined ? A.db : PIPE_DB_DEFAULT;

try
{
   var w = ImageWindow.open( A.master );
   if ( w.length == 0 ) throw new Error( "打不开: " + A.master );
   var view = w[0].mainView;

   var pick = pipePickProfile( w[0], A.profile !== undefined ? A.profile : "auto", DB, A.filter,
                               { kind: A.filterkind, nm: A.filternm } );
   L("元数据: INSTRUME=" + (pick.inst || "(无)") + "  FILTER=" + (pick.filt || "(无)"));
   L("档案: " + (pick.profile ? pick.profile.id + " — " + pick.profile.label : "(无)")
     + "  匹配=" + pick.matched + (pick.note ? "  " + pick.note : ""));
   L("滤镜: " + pick.filter.label + "  类别=" + pick.filter.kind
     + "  通带=" + pipeBandString( pick.filter.bands )
     + ( pick.filter.bands && pick.filter.bands.length >= 2 ? "  [双/多窄带]" : "" ));

   var C = new SpectrophotometricColorCalibration;
   var set = pick.set;
   if ( A.profile != "none" && set )
   {
      L("曲线组: " + set.id + (set.composite ? "（组合:" + set.composite + "）" : ""));
      L("  R=" + set.R + "  G=" + set.G + "  B=" + set.B);
      C.redFilterName = set.R;   C.redFilterTrCurve = pipeCurve(DB, set.R, "R");
      C.greenFilterName = set.G; C.greenFilterTrCurve = pipeCurve(DB, set.G, "G");
      C.blueFilterName = set.B;  C.blueFilterTrCurve = pipeCurve(DB, set.B, "B");
   }
   var before = view.computeOrFetchProperty("Median");
   var ok = C.executeOn( view );
   var after = view.computeOrFetchProperty("Median");
   L("SPCC = " + ok + "  通道中位数 "
     + before.at(0).toFixed(5) + "/" + before.at(1).toFixed(5) + "/" + before.at(2).toFixed(5)
     + " -> " + after.at(0).toFixed(5) + "/" + after.at(1).toFixed(5) + "/" + after.at(2).toFixed(5));

   if ( A.out !== undefined )
   {
      var nw = new ImageWindow( view.image.width, view.image.height, view.image.numberOfChannels, 32, true, true, "spcc_out" );
      nw.mainView.beginProcess();
      nw.mainView.image.assign( view.image );
      nw.mainView.endProcess();
      try { nw.keywords = w[0].keywords; } catch ( e ) {}
      try
      {
         pipeApplyAnnotation( nw, pick.filter,
                              { "PIPEPROF": pick.profile ? pick.profile.id : "none",
                                "PIPESET": pick.set ? pick.set.id : "none" } );
      }
      catch ( e ) {}
      if ( w[0].hasAstrometricSolution ) { try { nw.copyAstrometricSolution( w[0] ); } catch (e) {} }
      nw.saveAs( A.out, false, false, false, true );
      nw.forceClose();
      L("已保存 " + A.out);
   }
}
catch ( e ) { L("!! 失败: " + e); }
