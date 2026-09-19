/*
 * pipeline_profile_probe.js — 在 PixInsight 里查看某个 master 会被判成哪个档案（只读，不做任何处理）
 *
 * 用法:
 *   -r="pipeline_profile_probe.js,master=<xisf>[,profile=auto][,filter=<滤镜名>]
 *       [,filterkind=broadband|light-pollution|duoband|narrowband][,filternm=Ha=656.3/7,OIII=500.7/7][,table=1]"
 *   master 省略时只打印档案总表
 */
#include "pipeline_profiles.jsh"

var A = {};
for (var i = 0; i < jsArguments.length; ++i)
{
   var kv = jsArguments[i], eq = kv.indexOf("=");
   if (eq > 0) A[kv.substring(0, eq)] = kv.substring(eq + 1);
}

var DB = A.db !== undefined ? A.db : PIPE_DB_DEFAULT;

var LOG = A.log !== undefined ? A.log : "/tmp/pipeline_profile_probe.log";
var BUF = [];
function P(s) { BUF.push( s ); }
function flush() { try { File.writeTextFile( LOG, BUF.join( "\n" ) + "\n" ); } catch ( e ) {} }

try
{
   if ( A.master !== undefined )
   {
      var w = ImageWindow.open( A.master );
      if ( w.length == 0 ) throw new Error( "打不开: " + A.master );
      var pick = pipePickProfile( w[0], A.profile !== undefined ? A.profile : "auto", DB, A.filter,
                                  { kind: A.filterkind, nm: A.filternm } );
      P( "文件      : " + A.master );
      P( "图像      : " + w[0].mainView.image.width + "x" + w[0].mainView.image.height );
      P( "INSTRUME  : " + (pick.inst || "(无)") );
      P( "FILTER    : " + (pick.filt || "(无)") );
      P( "匹配方式  : " + pick.matched );
      P( "相机档案  : " + (pick.profile ? pick.profile.id + " — " + pick.profile.label : "(无)") );
      P( "滤镜      : " + pick.filter.id + " — " + pick.filter.label );
      P( "滤镜类别  : " + pick.filter.kind
         + ( pick.filter.bands && pick.filter.bands.length >= 2 ? "   [双/多窄带]" : "" ) );
      P( "通带      : " + pipeBandString( pick.filter.bands ) );
      if ( pick.set )
      {
         P( "曲线组    : " + pick.set.id + (pick.set.composite ? "   组合滤镜=" + pick.set.composite : "") );
         P( "  R = " + pick.set.R );
         P( "  G = " + pick.set.G );
         P( "  B = " + pick.set.B );
         P( "  QE= " + pick.set.QE );
      }
      if ( pick.missing && pick.missing.length )
         P( "缺失曲线  : " + pick.missing.join( ", " ) );
      if ( pick.note ) P( "说明      : " + pick.note );
   }

   if ( A.table == "1" || A.master === undefined )
   {
      P( "" );
      P( "=== 相机档案表（曲线校验）===" );
      var rows = pipeAuditProfiles( DB );
      for ( var i = 0; i < rows.length; ++i )
      {
         var r = rows[i];
         P( (r.missing.length ? "✗" : "✓") + " " + r.id + "  [" + r.set + "]  " + r.label );
         if ( r.missing.length ) P( "      缺: " + r.missing.join( ", " ) );
      }
   }

   /* kw=1：把文件里已有的流水线标注关键字打出来（验证标注是否写进去了） */
   if ( A.master !== undefined && A.kw == "1" )
   {
      var w2 = ( typeof w != "undefined" && w.length > 0 ) ? w : ImageWindow.open( A.master );
      if ( w2.length > 0 )
      {
         P( "" );
         P( "=== 文件里的流水线标注 ===" );
         var found = 0;
         for ( var q = 0; q < w2[0].keywords.length; ++q )
         {
            var nm = w2[0].keywords[q].name;
            if ( nm.indexOf( "PIPE" ) == 0 )
            {
               P( "  " + nm + " = " + w2[0].keywords[q].strippedValue );
               ++found;
            }
         }
         if ( found == 0 ) P( "  (没有 PIPExxx 关键字)" );
         if ( w2 !== w ) w2[0].forceClose();
      }
   }
}
catch ( e ) { P( "ERR: " + e ); }

flush();
