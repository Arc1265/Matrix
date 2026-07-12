//+------------------------------------------------------------------+
//| MatrixRegressionChannel_FIX2_CONTEXT_CONTINUATION_GATE_DIAGNOSTIC.mq5         |
//| Deterministic polynomial regression channel with closed-bar      |
//| context-aware lifecycle, continuation gate, adaptive HUD and CSV QA. |
//+------------------------------------------------------------------+
#property copyright "AI Quantum Trader / ArNi QA"
#property version   "2.10"
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   5

#property indicator_label1  "Polynomial Trend"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "Upper Channel"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrCrimson
#property indicator_style2  STYLE_DOT
#property indicator_width2  1

#property indicator_label3  "Lower Channel"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrLimeGreen
#property indicator_style3  STYLE_DOT
#property indicator_width3  1

#property indicator_label4  "BUY Confirmed"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrLime
#property indicator_width4  3

#property indicator_label5  "SELL Confirmed"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrRed
#property indicator_width5  3

#define MRC_VERSION       "FIX2_CONTEXT_CONTINUATION_GATE_DIAGNOSTIC"
#define MRC_MODEL_DEGREE  2
#define MRC_COEFF_COUNT   3
#define MRC_PANEL_LINES   21

input group "--- Базовые настройки матрицы ---"
input int        InpPeriod          = 60;       // Окно квадратичной регрессии, баров
input double     InpDev             = 2.0;      // Полуширина канала в остаточных sigma

input group "--- Закрытый HTF-фильтр ---"
input bool       InpUseHTFFilter    = true;     // Разрешать сигнал только по закрытому HTF
input ENUM_TIMEFRAMES InpFilterTF   = PERIOD_H1;// Старший таймфрейм

input group "--- Signal State Engine ---"
input int        InpSetupMaxBars    = 5;        // Максимальный возраст незавершённого возврата
input double     InpMinRR2          = 1.30;     // Минимальный RR до противоположной границы
input int        InpMinReversalPhaseBars = 8;    // Минимальная зрелость встречного локального тренда
input double     InpMinReversalExtension = 1.30; // Ход тренда / полуширина канала для разворота

input group "--- Сигналы, алерты и риск ---"
input bool       InpUseAlerts       = true;     // Алерт только по новому закрытому бару
input int        InpStopIndentPoints= 20;       // Отступ SL в points инструмента

input group "--- QA-диагностика MQL5\\Files ---"
input bool       InpEnableDiagnostics = true;  // Обязательный CSV runtime-log
input int        InpDiagHistoryBars   = 500;   // Сколько последних закрытых баров писать при старте
input int        InpDiagMaxRowsPerRun = 20000; // Защита от бесконечного роста файла
input int        InpDiagFlushEveryRows= 20;    // Периодический FileFlush

//--- indicator buffers
double BufferTrend[];
double BufferUpper[];
double BufferLower[];
double BufferBuyArrows[];
double BufferSellArrows[];

//--- calculation-only series
double g_sigma[];
double g_velocity[];
double g_curvature[];

//--- normalized quadratic least-squares projection
matrix g_design;
matrix g_projection;

//--- lifecycle states
enum ENUM_MRC_SETUP_STATE
{
   MRC_WATCH = 0,
   MRC_BUY_EXCURSION,
   MRC_SELL_EXCURSION,
   MRC_BUY_LOCKED,
   MRC_SELL_LOCKED
};

struct RegressionResult
{
   bool   valid;
   double trend;
   double sigma;
   double velocity;
   double curvature;
};

struct HTFContext
{
   bool     ready;
   datetime source_time;
   double   velocity;
   double   curvature;
   string   direction;
   string   reason;
};

struct SignalEngine
{
   ENUM_MRC_SETUP_STATE state;
   datetime              anchor_time;
   string                setup_id;
   double                anchor_boundary;
   double                anchor_extreme;
   int                   age_bars;
};

struct MarketPhaseTracker
{
   string   direction;
   int      age_bars;
   double   origin_trend;
   double   extension;
   double   extension_ratio;
   datetime start_time;
};

struct DecisionRecord
{
   int      bar_index;
   datetime bar_time;
   datetime bar_close_time;
   string   event_name;
   string   state_before;
   string   state_after;
   string   setup_id;
   string   candidate;
   string   decision;
   string   reason;

   double   open_price;
   double   high_price;
   double   low_price;
   double   close_price;

   double   trend_prev;
   double   upper_prev;
   double   lower_prev;
   double   trend_curr;
   double   upper_curr;
   double   lower_curr;
   double   sigma_curr;
   double   local_velocity;
   double   local_curvature;
   string   local_direction;
   double   channel_width;
   string   phase_direction;
   int      phase_age;
   double   phase_origin_trend;
   double   phase_extension;
   double   phase_extension_ratio;
   string   candidate_route;
   string   context_gate;
   string   context_reason;
   double   candle_range;
   double   candle_body;
   double   close_location;
   double   boundary_penetration;
   double   boundary_penetration_sigma;

   bool     buy_excursion;
   bool     sell_excursion;
   double   anchor_boundary;
   double   anchor_extreme;
   int      setup_age;

   bool     htf_ready;
   datetime htf_source_time;
   double   htf_velocity;
   double   htf_curvature;
   string   htf_direction;

   double   entry_price;
   double   stop_loss;
   double   tp1_trend;
   double   tp2_opposite;
   double   rr1;
   double   rr2;
   bool     signal_emitted;
};

SignalEngine       g_engine;
MarketPhaseTracker g_phase;
DecisionRecord     g_last_record;
bool               g_have_last_record=false;

//--- HTF cache: one regression calculation per closed HTF candle
datetime   g_htf_cache_time=0;
bool       g_htf_cache_valid=false;
HTFContext g_htf_cache;

//--- runtime guards
int      g_last_processed_bar=-1;
datetime g_last_processed_time=0;
bool     g_runtime_ready=false;

//--- diagnostics
int    g_log_handle=INVALID_HANDLE;
string g_log_filename="";
string g_run_id="";
long   g_log_row_id=0;
int    g_rows_since_flush=0;
bool   g_log_limit_reported=false;

//--- object ownership
string g_object_prefix="";

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
string StateToString(const ENUM_MRC_SETUP_STATE state)
{
   switch(state)
   {
      case MRC_WATCH:          return "WATCH";
      case MRC_BUY_EXCURSION:  return "BUY_EXCURSION";
      case MRC_SELL_EXCURSION: return "SELL_EXCURSION";
      case MRC_BUY_LOCKED:     return "BUY_LOCKED";
      case MRC_SELL_LOCKED:    return "SELL_LOCKED";
   }
   return "UNKNOWN";
}

string DirectionFromVelocity(const double velocity)
{
   const double eps=1.0e-12;
   if(velocity>eps)  return "UP";
   if(velocity<-eps) return "DOWN";
   return "FLAT";
}

string SafeTime(const datetime value)
{
   if(value<=0) return "";
   return TimeToString(value,TIME_DATE|TIME_MINUTES|TIME_SECONDS);
}

string PriceToString(const double value)
{
   if(!MathIsValidNumber(value) || value==EMPTY_VALUE) return "";
   return DoubleToString(value,_Digits);
}

string NumberToString(const double value,const int digits=6)
{
   if(!MathIsValidNumber(value) || value==EMPTY_VALUE) return "";
   return DoubleToString(value,digits);
}

string SanitizeFileToken(string value)
{
   StringReplace(value,".","_");
   StringReplace(value,":","_");
   StringReplace(value," ","_");
   StringReplace(value,"/","_");
   StringReplace(value,"\\","_");
   return value;
}

void ResetSignalEngine()
{
   g_engine.state=MRC_WATCH;
   g_engine.anchor_time=0;
   g_engine.setup_id="";
   g_engine.anchor_boundary=EMPTY_VALUE;
   g_engine.anchor_extreme=EMPTY_VALUE;
   g_engine.age_bars=0;
}

void ClearEngineAnchor()
{
   g_engine.anchor_time=0;
   g_engine.setup_id="";
   g_engine.anchor_boundary=EMPTY_VALUE;
   g_engine.anchor_extreme=EMPTY_VALUE;
   g_engine.age_bars=0;
}

void ResetMarketPhase()
{
   g_phase.direction="NONE";
   g_phase.age_bars=0;
   g_phase.origin_trend=EMPTY_VALUE;
   g_phase.extension=0.0;
   g_phase.extension_ratio=0.0;
   g_phase.start_time=0;
}

void UpdateMarketPhase(const string direction,
                       const datetime bar_time,
                       const double trend_value,
                       const double channel_width)
{
   if(direction!="UP" && direction!="DOWN")
   {
      ResetMarketPhase();
      g_phase.direction="FLAT";
      g_phase.start_time=bar_time;
      return;
   }

   if(g_phase.direction!=direction || g_phase.age_bars<=0 ||
      !MathIsValidNumber(g_phase.origin_trend) || g_phase.origin_trend==EMPTY_VALUE)
   {
      g_phase.direction=direction;
      g_phase.age_bars=1;
      g_phase.origin_trend=trend_value;
      g_phase.extension=0.0;
      g_phase.extension_ratio=0.0;
      g_phase.start_time=bar_time;
   }
   else
   {
      g_phase.age_bars++;
      if(direction=="UP")
         g_phase.extension=MathMax(0.0,trend_value-g_phase.origin_trend);
      else
         g_phase.extension=MathMax(0.0,g_phase.origin_trend-trend_value);

      const double half_width=channel_width*0.5;
      g_phase.extension_ratio=(half_width>0.0 ? g_phase.extension/half_width : 0.0);
   }
}

bool IsRegressionValid(const RegressionResult &result)
{
   return result.valid &&
          MathIsValidNumber(result.trend) &&
          MathIsValidNumber(result.sigma) &&
          MathIsValidNumber(result.velocity) &&
          MathIsValidNumber(result.curvature) &&
          result.sigma>=0.0;
}

//+------------------------------------------------------------------+
//| Build normalized X in [-1,+1]. This sharply improves conditioning|
//| while retaining the existing deterministic 3-coefficient model. |
//+------------------------------------------------------------------+
bool BuildProjectionMatrix()
{
   g_design.Init(InpPeriod,MRC_COEFF_COUNT);
   for(int i=0;i<InpPeriod;i++)
   {
      const double x=-1.0+(2.0*(double)i/(double)(InpPeriod-1));
      g_design[i,0]=1.0;
      g_design[i,1]=x;
      g_design[i,2]=x*x;
   }

   matrix xt=g_design.Transpose();
   matrix xtx=xt.MatMul(g_design);
   matrix xtx_inv=xtx.Inv();
   if(xtx_inv.Rows()!=MRC_COEFF_COUNT || xtx_inv.Cols()!=MRC_COEFF_COUNT)
      return false;

   g_projection=xtx_inv.MatMul(xt);
   if(g_projection.Rows()!=MRC_COEFF_COUNT || g_projection.Cols()!=InpPeriod)
      return false;

   for(int r=0;r<MRC_COEFF_COUNT;r++)
      for(int c=0;c<InpPeriod;c++)
         if(!MathIsValidNumber(g_projection[r,c]))
            return false;

   return true;
}

bool RegressionFromSeries(const double &series[],const int start_index,RegressionResult &result)
{
   result.valid=false;
   if(start_index<0) return false;

   double w0=0.0,w1=0.0,w2=0.0;
   for(int i=0;i<InpPeriod;i++)
   {
      const double y=series[start_index+i];
      if(!MathIsValidNumber(y)) return false;
      w0+=g_projection[0,i]*y;
      w1+=g_projection[1,i]*y;
      w2+=g_projection[2,i]*y;
   }

   double sse=0.0;
   for(int i=0;i<InpPeriod;i++)
   {
      const double x=-1.0+(2.0*(double)i/(double)(InpPeriod-1));
      const double model=w0+w1*x+w2*x*x;
      const double error=series[start_index+i]-model;
      sse+=error*error;
   }

   const int dof=InpPeriod-MRC_COEFF_COUNT;
   if(dof<=0) return false;

   const double dx_per_bar=2.0/(double)(InpPeriod-1);
   result.trend=w0+w1+w2; // x=+1, the newest sample
   result.sigma=MathSqrt(MathMax(0.0,sse/(double)dof));
   result.velocity=(w1+2.0*w2)*dx_per_bar;
   result.curvature=(2.0*w2)*dx_per_bar*dx_per_bar;
   result.valid=MathIsValidNumber(result.trend) &&
                MathIsValidNumber(result.sigma) &&
                MathIsValidNumber(result.velocity) &&
                MathIsValidNumber(result.curvature);
   return result.valid;
}

bool RegressionFromArray(const double &values[],RegressionResult &result)
{
   result.valid=false;
   if(ArraySize(values)<InpPeriod) return false;

   double w0=0.0,w1=0.0,w2=0.0;
   for(int i=0;i<InpPeriod;i++)
   {
      const double y=values[i];
      if(!MathIsValidNumber(y)) return false;
      w0+=g_projection[0,i]*y;
      w1+=g_projection[1,i]*y;
      w2+=g_projection[2,i]*y;
   }

   double sse=0.0;
   for(int i=0;i<InpPeriod;i++)
   {
      const double x=-1.0+(2.0*(double)i/(double)(InpPeriod-1));
      const double model=w0+w1*x+w2*x*x;
      const double error=values[i]-model;
      sse+=error*error;
   }

   const int dof=InpPeriod-MRC_COEFF_COUNT;
   if(dof<=0) return false;

   const double dx_per_bar=2.0/(double)(InpPeriod-1);
   result.trend=w0+w1+w2;
   result.sigma=MathSqrt(MathMax(0.0,sse/(double)dof));
   result.velocity=(w1+2.0*w2)*dx_per_bar;
   result.curvature=(2.0*w2)*dx_per_bar*dx_per_bar;
   result.valid=MathIsValidNumber(result.trend) &&
                MathIsValidNumber(result.sigma) &&
                MathIsValidNumber(result.velocity) &&
                MathIsValidNumber(result.curvature);
   return result.valid;
}

//+------------------------------------------------------------------+
//| Last fully closed HTF candle at the signal bar close time.       |
//| No forming HTF candle and no future close are ever consumed.     |
//+------------------------------------------------------------------+
bool GetClosedHTFContext(const datetime signal_bar_close_time,HTFContext &context)
{
   context.ready=false;
   context.source_time=0;
   context.velocity=0.0;
   context.curvature=0.0;
   context.direction="NOT_READY";
   context.reason="HTF_DATA_NOT_READY";

   if(!InpUseHTFFilter)
   {
      context.ready=true;
      context.direction="DISABLED";
      context.reason="HTF_FILTER_DISABLED";
      return true;
   }

   const int htf_seconds=PeriodSeconds(InpFilterTF);
   if(htf_seconds<=0)
   {
      context.reason="HTF_INVALID_SECONDS";
      return false;
   }

   const datetime probe_time=signal_bar_close_time-1;
   int containing_shift=iBarShift(_Symbol,InpFilterTF,probe_time,false);
   if(containing_shift<0)
   {
      context.reason="HTF_SHIFT_NOT_FOUND";
      return false;
   }

   datetime containing_open=iTime(_Symbol,InpFilterTF,containing_shift);
   if(containing_open<=0)
   {
      context.reason="HTF_OPEN_NOT_FOUND";
      return false;
   }

   int last_closed_shift=containing_shift;
   if(containing_open+htf_seconds>signal_bar_close_time)
      last_closed_shift++;

   const datetime source_time=iTime(_Symbol,InpFilterTF,last_closed_shift);
   if(source_time<=0)
   {
      context.reason="HTF_CLOSED_BAR_NOT_FOUND";
      return false;
   }

   if(g_htf_cache_valid && g_htf_cache_time==source_time)
   {
      context=g_htf_cache;
      return context.ready;
   }

   if(Bars(_Symbol,InpFilterTF)<last_closed_shift+InpPeriod)
   {
      context.reason="HTF_INSUFFICIENT_BARS";
      return false;
   }

   double htf_close[];
   ArrayResize(htf_close,InpPeriod);
   ResetLastError();
   const int copied=CopyClose(_Symbol,InpFilterTF,last_closed_shift,InpPeriod,htf_close);
   if(copied!=InpPeriod)
   {
      context.reason=StringFormat("HTF_COPY_CLOSE_FAILED_%d_ERR_%d",copied,GetLastError());
      return false;
   }

   RegressionResult regression;
   if(!RegressionFromArray(htf_close,regression) || !IsRegressionValid(regression))
   {
      context.reason="HTF_REGRESSION_INVALID";
      return false;
   }

   context.ready=true;
   context.source_time=source_time;
   context.velocity=regression.velocity;
   context.curvature=regression.curvature;
   context.direction=DirectionFromVelocity(regression.velocity);
   context.reason="HTF_CLOSED_BAR_OK";

   g_htf_cache_time=source_time;
   g_htf_cache=context;
   g_htf_cache_valid=true;
   return true;
}

//+------------------------------------------------------------------+
//| Price / risk helpers                                             |
//+------------------------------------------------------------------+
double NormalizeToTick(const double raw_price,const bool round_up)
{
   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_size<=0.0) tick_size=_Point;
   if(tick_size<=0.0) return NormalizeDouble(raw_price,_Digits);

   const double steps=raw_price/tick_size;
   double rounded_steps=round_up ? MathCeil(steps-1.0e-10) : MathFloor(steps+1.0e-10);
   return NormalizeDouble(rounded_steps*tick_size,_Digits);
}

void CalculateRiskGeometry(const string direction,
                           const double entry,
                           const double extreme,
                           const double trend_target,
                           const double opposite_target,
                           double &sl,double &tp1,double &tp2,double &rr1,double &rr2)
{
   const double indent=MathMax(0,InpStopIndentPoints)*_Point;
   const int stops_level=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   const double broker_min=MathMax(0,stops_level)*_Point;

   if(direction=="BUY")
   {
      sl=NormalizeToTick(MathMin(extreme-indent,entry-broker_min),false);
      tp1=NormalizeToTick(trend_target,true);
      tp2=NormalizeToTick(opposite_target,true);
      const double risk=entry-sl;
      rr1=(risk>0.0 ? (tp1-entry)/risk : -1.0);
      rr2=(risk>0.0 ? (tp2-entry)/risk : -1.0);
   }
   else
   {
      sl=NormalizeToTick(MathMax(extreme+indent,entry+broker_min),true);
      tp1=NormalizeToTick(trend_target,false);
      tp2=NormalizeToTick(opposite_target,false);
      const double risk=sl-entry;
      rr1=(risk>0.0 ? (entry-tp1)/risk : -1.0);
      rr2=(risk>0.0 ? (entry-tp2)/risk : -1.0);
   }
}

//+------------------------------------------------------------------+
//| Diagnostics                                                      |
//+------------------------------------------------------------------+
void WriteLogHeader()
{
   if(g_log_handle==INVALID_HANDLE) return;
   FileWrite(g_log_handle,
      "run_id","row_id","version","event","symbol","chart_tf","bar_index",
      "bar_time","bar_close_time","state_before","state_after","setup_id",
      "candidate","decision","reason",
      "open","high","low","close",
      "trend_prev","upper_prev","lower_prev","trend_curr","upper_curr","lower_curr",
      "sigma_curr","local_velocity","local_curvature","local_direction","channel_width",
      "phase_direction","phase_age","phase_origin_trend","phase_extension","phase_extension_ratio",
      "candidate_route","context_gate","context_reason",
      "candle_range","candle_body","close_location","boundary_penetration","boundary_penetration_sigma",
      "buy_excursion","sell_excursion","anchor_boundary","anchor_extreme","setup_age",
      "htf_tf","htf_ready","htf_source_time","htf_velocity","htf_curvature","htf_direction",
      "entry","stop_loss","tp1_trend","tp2_opposite","rr1","rr2","signal_emitted");
   FileFlush(g_log_handle);
}

bool CanWriteDiagnostic()
{
   if(!InpEnableDiagnostics || g_log_handle==INVALID_HANDLE) return false;
   if(g_log_row_id<InpDiagMaxRowsPerRun) return true;

   if(!g_log_limit_reported)
   {
      g_log_limit_reported=true;
      FileWrite(g_log_handle,g_run_id,g_log_row_id,MRC_VERSION,"DIAG_LIMIT_REACHED",_Symbol,
                EnumToString((ENUM_TIMEFRAMES)_Period),"","","","","","","","STOP",
                "DIAG_MAX_ROWS_REACHED");
      FileFlush(g_log_handle);
   }
   return false;
}

void FlushLogIfRequired(const bool force_flush=false)
{
   if(g_log_handle==INVALID_HANDLE) return;
   g_rows_since_flush++;
   if(force_flush || g_rows_since_flush>=MathMax(1,InpDiagFlushEveryRows))
   {
      FileFlush(g_log_handle);
      g_rows_since_flush=0;
   }
}

void WriteMetaEvent(const string event_name,const string reason)
{
   if(!CanWriteDiagnostic()) return;
   g_log_row_id++;
   FileWrite(g_log_handle,
      g_run_id,g_log_row_id,MRC_VERSION,event_name,_Symbol,EnumToString((ENUM_TIMEFRAMES)_Period),
      "","","","","","","","META",reason);
   FlushLogIfRequired(true);
}

void WriteDecision(const DecisionRecord &record)
{
   if(!CanWriteDiagnostic()) return;
   g_log_row_id++;
   FileWrite(g_log_handle,
      g_run_id,g_log_row_id,MRC_VERSION,record.event_name,_Symbol,EnumToString((ENUM_TIMEFRAMES)_Period),record.bar_index,
      SafeTime(record.bar_time),SafeTime(record.bar_close_time),record.state_before,record.state_after,record.setup_id,
      record.candidate,record.decision,record.reason,
      PriceToString(record.open_price),PriceToString(record.high_price),PriceToString(record.low_price),PriceToString(record.close_price),
      PriceToString(record.trend_prev),PriceToString(record.upper_prev),PriceToString(record.lower_prev),
      PriceToString(record.trend_curr),PriceToString(record.upper_curr),PriceToString(record.lower_curr),
      NumberToString(record.sigma_curr),NumberToString(record.local_velocity,8),NumberToString(record.local_curvature,10),record.local_direction,
      NumberToString(record.channel_width),
      record.phase_direction,record.phase_age,PriceToString(record.phase_origin_trend),
      NumberToString(record.phase_extension,6),NumberToString(record.phase_extension_ratio,4),
      record.candidate_route,record.context_gate,record.context_reason,
      NumberToString(record.candle_range,6),NumberToString(record.candle_body,6),NumberToString(record.close_location,4),
      NumberToString(record.boundary_penetration,6),NumberToString(record.boundary_penetration_sigma,4),
      (record.buy_excursion?1:0),(record.sell_excursion?1:0),PriceToString(record.anchor_boundary),PriceToString(record.anchor_extreme),record.setup_age,
      EnumToString(InpFilterTF),(record.htf_ready?1:0),SafeTime(record.htf_source_time),
      NumberToString(record.htf_velocity,8),NumberToString(record.htf_curvature,10),record.htf_direction,
      PriceToString(record.entry_price),PriceToString(record.stop_loss),PriceToString(record.tp1_trend),PriceToString(record.tp2_opposite),
      NumberToString(record.rr1,3),NumberToString(record.rr2,3),(record.signal_emitted?1:0));
   FlushLogIfRequired(record.signal_emitted || StringFind(record.decision,"BLOCK")>=0 || StringFind(record.decision,"LOW_EDGE")>=0);
}

bool OpenDiagnosticLog()
{
   if(!InpEnableDiagnostics) return true;

   string stamp=SanitizeFileToken(TimeToString(TimeLocal(),TIME_DATE|TIME_SECONDS));
   string symbol=SanitizeFileToken(_Symbol);
   string tf=SanitizeFileToken(EnumToString((ENUM_TIMEFRAMES)_Period));
   g_run_id=StringFormat("%s_%s_%s_%s",symbol,tf,MRC_VERSION,stamp);
   g_log_filename=StringFormat("MatrixRegression_%s.csv",g_run_id);

   ResetLastError();
   g_log_handle=FileOpen(g_log_filename,
                         FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,
                         ';',CP_UTF8);
   if(g_log_handle==INVALID_HANDLE)
   {
      PrintFormat("MRC FATAL: cannot open MQL5\\Files\\%s, error=%d",g_log_filename,GetLastError());
      return false;
   }

   WriteLogHeader();
   const string config=StringFormat(
      "PERIOD=%d;DEV=%.3f;HTF=%s;HTF_ENABLE=%d;SETUP_MAX=%d;MIN_RR2=%.3f;REV_PHASE_BARS=%d;REV_EXTENSION=%.3f;STOP_POINTS=%d;HISTORY=%d;MAX_ROWS=%d",
      InpPeriod,InpDev,EnumToString(InpFilterTF),(InpUseHTFFilter?1:0),InpSetupMaxBars,InpMinRR2,
      InpMinReversalPhaseBars,InpMinReversalExtension,InpStopIndentPoints,InpDiagHistoryBars,InpDiagMaxRowsPerRun);
   WriteMetaEvent("RUN_START",config);

   const string full_path=TerminalInfoString(TERMINAL_DATA_PATH)+"\\MQL5\\Files\\"+g_log_filename;
   PrintFormat("MRC QA log: %s",full_path);
   return true;
}

void CloseDiagnosticLog(const int reason)
{
   if(g_log_handle==INVALID_HANDLE) return;
   WriteMetaEvent("RUN_END",StringFormat("DEINIT_REASON=%d",reason));
   FileFlush(g_log_handle);
   FileClose(g_log_handle);
   g_log_handle=INVALID_HANDLE;
}

//+------------------------------------------------------------------+
//| Chart objects                                                    |
//+------------------------------------------------------------------+
int GetAdaptivePanelWidth()
{
   long chart_width=0;
   if(!ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0,chart_width) || chart_width<=0)
      chart_width=1000;

   int desired=560;
   const int available=(int)MathMax(180.0,(double)chart_width-16.0);
   if(desired>available) desired=available;
   return desired;
}

int GetAdaptivePanelFontSize(const int panel_width)
{
   if(panel_width<390) return 7;
   if(panel_width<500) return 8;
   return 9;
}

string CompactPanelText(const string value,const int max_chars)
{
   if(max_chars<4 || StringLen(value)<=max_chars) return value;
   return StringSubstr(value,0,max_chars-3)+"...";
}

void EnsurePanel()
{
   const int panel_width=GetAdaptivePanelWidth();
   const int font_size=GetAdaptivePanelFontSize(panel_width);
   const int line_height=font_size+8;
   const int panel_height=24+MRC_PANEL_LINES*line_height;

   const string bg=g_object_prefix+"PANEL_BG";
   if(ObjectFind(0,bg)<0)
      ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);

   ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bg,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,8);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,18);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,panel_width);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,panel_height);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,clrBlack);
   ObjectSetInteger(0,bg,OBJPROP_BORDER_COLOR,clrDimGray);
   ObjectSetInteger(0,bg,OBJPROP_BACK,false);
   ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);

   for(int i=0;i<MRC_PANEL_LINES;i++)
   {
      const string name=g_object_prefix+"PANEL_LINE_"+IntegerToString(i);
      if(ObjectFind(0,name)<0)
         ObjectCreate(0,name,OBJ_LABEL,0,0,0);

      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,18);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,26+i*line_height);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,font_size);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }
}

void SetPanelLine(const int index,const string text,const color text_color=clrWhite)
{
   if(index<0 || index>=MRC_PANEL_LINES) return;
   const string name=g_object_prefix+"PANEL_LINE_"+IntegerToString(index);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,text_color);
}

void UpdatePanel()
{
   EnsurePanel();
   SetPanelLine(0,StringFormat("MATRIX REGRESSION QA | %s",MRC_VERSION),clrAqua);
   SetPanelLine(1,StringFormat("СИМВОЛ/TF: %s / %s",_Symbol,EnumToString((ENUM_TIMEFRAMES)_Period)));
   SetPanelLine(2,StringFormat("МОДЕЛЬ: QUADRATIC N=%d DEV=%.2f",InpPeriod,InpDev));

   if(!g_have_last_record)
   {
      SetPanelLine(3,"СТАТУС: ОЖИДАНИЕ ДОСТАТОЧНОЙ ИСТОРИИ",clrYellow);
      for(int i=4;i<MRC_PANEL_LINES;i++) SetPanelLine(i,"");
      return;
   }

   const color decision_color=(g_last_record.decision=="ALLOW_BUY" ? clrLime :
                               g_last_record.decision=="ALLOW_SELL" ? clrRed :
                               StringFind(g_last_record.decision,"LOW_EDGE")>=0 ? clrOrange :
                               StringFind(g_last_record.decision,"BLOCK")>=0 ? clrTomato : clrWhite);

   SetPanelLine(3,StringFormat("ЗАКРЫТЫЙ БАР: %s",SafeTime(g_last_record.bar_time)));
   SetPanelLine(4,StringFormat("LOCAL: %s vel=%s curv=%s",
                g_last_record.local_direction,NumberToString(g_last_record.local_velocity,6),NumberToString(g_last_record.local_curvature,8)));
   SetPanelLine(5,StringFormat("PHASE: %s age=%d origin=%s ext=%sx",
                g_last_record.phase_direction,g_last_record.phase_age,PriceToString(g_last_record.phase_origin_trend),
                NumberToString(g_last_record.phase_extension_ratio,2)));
   SetPanelLine(6,StringFormat("ROUTE: %s gate=%s",
                g_last_record.candidate_route,g_last_record.context_gate));
   SetPanelLine(7,StringFormat("CONTEXT: %s",g_last_record.context_reason));
   SetPanelLine(8,StringFormat("HTF: %s %s source=%s",
                EnumToString(InpFilterTF),g_last_record.htf_direction,SafeTime(g_last_record.htf_source_time)));
   SetPanelLine(9,StringFormat("STATE: %s -> %s",g_last_record.state_before,g_last_record.state_after));
   SetPanelLine(10,StringFormat("SETUP: %s",(g_last_record.setup_id==""?"NONE":g_last_record.setup_id)));
   SetPanelLine(11,StringFormat("DECISION: %s",g_last_record.decision),decision_color);
   SetPanelLine(12,StringFormat("WHY: %s",g_last_record.reason),decision_color);
   SetPanelLine(13,StringFormat("CHANNEL: L=%s T=%s U=%s",
                PriceToString(g_last_record.lower_prev),PriceToString(g_last_record.trend_prev),PriceToString(g_last_record.upper_prev)));
   SetPanelLine(14,StringFormat("ENTRY: %s SL: %s",PriceToString(g_last_record.entry_price),PriceToString(g_last_record.stop_loss)));
   SetPanelLine(15,StringFormat("TP1: %s RR1=%s",PriceToString(g_last_record.tp1_trend),NumberToString(g_last_record.rr1,2)));
   SetPanelLine(16,StringFormat("TP2: %s RR2=%s",PriceToString(g_last_record.tp2_opposite),NumberToString(g_last_record.rr2,2)));
   SetPanelLine(17,StringFormat("CANDLE: body=%s close_loc=%s penetration=%ssigma",
                NumberToString(g_last_record.candle_body,4),NumberToString(g_last_record.close_location,2),
                NumberToString(g_last_record.boundary_penetration_sigma,2)));
   SetPanelLine(18,StringFormat("SIGMA=%s WIDTH=%s",NumberToString(g_last_record.sigma_curr),NumberToString(g_last_record.channel_width)));
   SetPanelLine(19,StringFormat("LOG: %s",(InpEnableDiagnostics?CompactPanelText(g_log_filename,68):"OFF")),clrSilver);
   SetPanelLine(20,StringFormat("ROWS: %I64d / %d",g_log_row_id,InpDiagMaxRowsPerRun),clrSilver);
}

void CreateSignalMarker(const DecisionRecord &record,const bool low_edge)
{
   if(record.candidate!="BUY" && record.candidate!="SELL") return;

   const string suffix=StringFormat("%s_%I64d",record.candidate,(long)record.bar_time);
   const string name=g_object_prefix+"SIG_"+suffix;
   if(ObjectFind(0,name)>=0) return;

   const bool is_buy=(record.candidate=="BUY");
   const double offset=MathMax(12.0*_Point,record.channel_width*0.10);
   const double price=is_buy ? record.low_price-offset : record.high_price+offset;
   if(!ObjectCreate(0,name,OBJ_TEXT,0,record.bar_time,price)) return;

   ObjectSetString(0,name,OBJPROP_TEXT,low_edge ? (is_buy?"B?":"S?") : (is_buy?"B":"S"));
   ObjectSetInteger(0,name,OBJPROP_COLOR,low_edge?clrOrange:(is_buy?clrLime:clrRed));
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,is_buy?ANCHOR_UPPER:ANCHOR_LOWER);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,
      StringFormat("%s\n%s\nRoute=%s Context=%s\nPhase=%s age=%d ext=%sx\nEntry=%s SL=%s TP1=%s TP2=%s RR2=%s\nHTF=%s %s",
                   record.setup_id,record.decision,record.candidate_route,record.context_reason,
                   record.phase_direction,record.phase_age,NumberToString(record.phase_extension_ratio,2),
                   PriceToString(record.entry_price),PriceToString(record.stop_loss),
                   PriceToString(record.tp1_trend),PriceToString(record.tp2_opposite),NumberToString(record.rr2,2),
                   record.htf_direction,SafeTime(record.htf_source_time)));
}

//+------------------------------------------------------------------+
//| Signal engine                                                    |
//+------------------------------------------------------------------+
void InitializeRecord(DecisionRecord &record,
                      const int bar,const datetime &time[],const double &open[],const double &high[],
                      const double &low[],const double &close[])
{
   record.bar_index=bar;
   record.bar_time=time[bar];
   record.bar_close_time=time[bar]+PeriodSeconds((ENUM_TIMEFRAMES)_Period);
   record.event_name="BAR_DECISION";
   record.state_before=StateToString(g_engine.state);
   record.state_after=record.state_before;
   record.setup_id=g_engine.setup_id;
   record.candidate="NONE";
   record.decision="WAIT";
   record.reason="NO_EXCURSION";

   record.open_price=open[bar];
   record.high_price=high[bar];
   record.low_price=low[bar];
   record.close_price=close[bar];

   record.trend_prev=BufferTrend[bar-1];
   record.upper_prev=BufferUpper[bar-1];
   record.lower_prev=BufferLower[bar-1];
   record.trend_curr=BufferTrend[bar];
   record.upper_curr=BufferUpper[bar];
   record.lower_curr=BufferLower[bar];
   record.sigma_curr=g_sigma[bar];
   record.local_velocity=g_velocity[bar];
   record.local_curvature=g_curvature[bar];
   record.local_direction=DirectionFromVelocity(g_velocity[bar]);
   record.channel_width=BufferUpper[bar-1]-BufferLower[bar-1];

   UpdateMarketPhase(record.local_direction,record.bar_time,record.trend_prev,record.channel_width);
   record.phase_direction=g_phase.direction;
   record.phase_age=g_phase.age_bars;
   record.phase_origin_trend=g_phase.origin_trend;
   record.phase_extension=g_phase.extension;
   record.phase_extension_ratio=g_phase.extension_ratio;
   record.candidate_route="NONE";
   record.context_gate="N_A";
   record.context_reason="NO_CANDIDATE";

   record.candle_range=MathMax(0.0,record.high_price-record.low_price);
   record.candle_body=record.close_price-record.open_price;
   record.close_location=(record.candle_range>0.0 ?
                          (record.close_price-record.low_price)/record.candle_range : 0.5);
   record.boundary_penetration=0.0;
   record.boundary_penetration_sigma=0.0;

   record.buy_excursion=(low[bar]<BufferLower[bar-1]);
   record.sell_excursion=(high[bar]>BufferUpper[bar-1]);
   record.anchor_boundary=g_engine.anchor_boundary;
   record.anchor_extreme=g_engine.anchor_extreme;
   record.setup_age=g_engine.age_bars;

   HTFContext htf;
   GetClosedHTFContext(record.bar_close_time,htf);
   record.htf_ready=htf.ready;
   record.htf_source_time=htf.source_time;
   record.htf_velocity=htf.velocity;
   record.htf_curvature=htf.curvature;
   record.htf_direction=htf.direction;

   record.entry_price=EMPTY_VALUE;
   record.stop_loss=EMPTY_VALUE;
   record.tp1_trend=EMPTY_VALUE;
   record.tp2_opposite=EMPTY_VALUE;
   record.rr1=EMPTY_VALUE;
   record.rr2=EMPTY_VALUE;
   record.signal_emitted=false;
}

void StartExcursion(const string direction,const int bar,const datetime &time[],const double &high[],const double &low[])
{
   g_engine.anchor_time=time[bar];
   g_engine.setup_id=StringFormat("%s_%I64d",direction,(long)time[bar]);
   g_engine.age_bars=1;

   if(direction=="BUY")
   {
      g_engine.state=MRC_BUY_EXCURSION;
      g_engine.anchor_boundary=BufferLower[bar-1];
      g_engine.anchor_extreme=low[bar];
   }
   else
   {
      g_engine.state=MRC_SELL_EXCURSION;
      g_engine.anchor_boundary=BufferUpper[bar-1];
      g_engine.anchor_extreme=high[bar];
   }
}

void ConfirmCandidate(const string direction,DecisionRecord &record)
{
   record.candidate=direction;
   record.setup_id=g_engine.setup_id;
   record.anchor_boundary=g_engine.anchor_boundary;
   record.anchor_extreme=g_engine.anchor_extreme;
   record.setup_age=g_engine.age_bars;

   g_engine.state=(direction=="BUY" ? MRC_BUY_LOCKED : MRC_SELL_LOCKED);
}

bool EvaluateContextGate(DecisionRecord &record)
{
   const bool is_buy=(record.candidate=="BUY");
   const bool continuation=(is_buy ? record.phase_direction=="UP" : record.phase_direction=="DOWN");
   const bool reversal=(is_buy ? record.phase_direction=="DOWN" : record.phase_direction=="UP");

   if(continuation)
   {
      record.candidate_route="CONTINUATION";
      record.context_gate="PASS";
      record.context_reason="LOCAL_TREND_CONTINUATION";
      return true;
   }

   if(reversal)
   {
      record.candidate_route="REVERSAL";
      if(record.phase_age<InpMinReversalPhaseBars)
      {
         record.context_gate="BLOCK";
         record.context_reason="FRESH_CONTINUATION_REVERSAL_UNPROVEN";
         return false;
      }
      if(record.phase_extension_ratio<InpMinReversalExtension)
      {
         record.context_gate="BLOCK";
         record.context_reason="REVERSAL_EXTENSION_BELOW_MINIMUM";
         return false;
      }

      record.context_gate="PASS";
      record.context_reason="MATURE_EXTENSION_REVERSAL";
      return true;
   }

   record.candidate_route="AMBIGUOUS";
   record.context_gate="BLOCK";
   record.context_reason="LOCAL_PHASE_NOT_DIRECTIONAL";
   return false;
}

void ApplyDecisionAndRisk(DecisionRecord &record)
{
   if(record.candidate!="BUY" && record.candidate!="SELL") return;

   const bool is_buy=(record.candidate=="BUY");
   record.entry_price=record.close_price;
   record.boundary_penetration=(is_buy ?
      MathMax(0.0,record.anchor_boundary-record.anchor_extreme) :
      MathMax(0.0,record.anchor_extreme-record.anchor_boundary));
   record.boundary_penetration_sigma=(record.sigma_curr>0.0 ?
      record.boundary_penetration/record.sigma_curr : 0.0);

   CalculateRiskGeometry(record.candidate,record.entry_price,record.anchor_extreme,
                         record.trend_prev,(is_buy?record.upper_prev:record.lower_prev),
                         record.stop_loss,record.tp1_trend,record.tp2_opposite,record.rr1,record.rr2);

   if(!EvaluateContextGate(record))
   {
      record.decision="BLOCK_"+record.candidate;
      record.reason=record.context_reason;
      return;
   }

   if(InpUseHTFFilter)
   {
      if(!record.htf_ready)
      {
         record.decision="BLOCK_"+record.candidate;
         record.reason="HTF_DATA_NOT_READY";
         return;
      }
      if(is_buy && record.htf_direction!="UP")
      {
         record.decision="BLOCK_BUY";
         record.reason="HTF_CLOSED_TREND_NOT_UP";
         return;
      }
      if(!is_buy && record.htf_direction!="DOWN")
      {
         record.decision="BLOCK_SELL";
         record.reason="HTF_CLOSED_TREND_NOT_DOWN";
         return;
      }
   }

   const bool invalid_geometry=(is_buy ?
      (record.stop_loss>=record.entry_price || record.tp2_opposite<=record.entry_price) :
      (record.stop_loss<=record.entry_price || record.tp2_opposite>=record.entry_price));

   if(invalid_geometry || !MathIsValidNumber(record.rr2) || record.rr2<=0.0)
   {
      record.decision="BLOCK_"+record.candidate;
      record.reason="INVALID_TARGET_GEOMETRY";
      return;
   }

   if(record.rr2<InpMinRR2)
   {
      record.decision="LOW_EDGE_"+record.candidate;
      record.reason="RR2_BELOW_MINIMUM";
      return;
   }

   record.decision="ALLOW_"+record.candidate;
   record.reason=(record.candidate_route=="REVERSAL" ?
                  "MATURE_REVERSAL_REENTRY_AND_HTF_CONFIRMED" :
                  "CONTINUATION_REENTRY_AND_HTF_CONFIRMED");
   record.signal_emitted=true;
}

void EvaluateSignalBar(const int bar,
                       const datetime &time[],const double &open[],const double &high[],
                       const double &low[],const double &close[],
                       DecisionRecord &record)
{
   InitializeRecord(record,bar,time,open,high,low,close);

   if(BufferTrend[bar-1]==EMPTY_VALUE || BufferTrend[bar]==EMPTY_VALUE)
   {
      record.decision="WAIT";
      record.reason="CHANNEL_NOT_READY";
      return;
   }

   switch(g_engine.state)
   {
      case MRC_WATCH:
      {
         if(record.buy_excursion && record.sell_excursion)
         {
            record.decision="WAIT";
            record.reason="DUAL_EXCURSION_AMBIGUOUS";
            break;
         }

         if(record.buy_excursion)
         {
            StartExcursion("BUY",bar,time,high,low);
            record.setup_id=g_engine.setup_id;
            record.anchor_boundary=g_engine.anchor_boundary;
            record.anchor_extreme=g_engine.anchor_extreme;
            record.setup_age=g_engine.age_bars;

            if(close[bar]>g_engine.anchor_boundary)
               ConfirmCandidate("BUY",record);
            else
            {
               record.decision="WAIT";
               record.reason="BUY_EXCURSION_OPEN";
            }
         }
         else if(record.sell_excursion)
         {
            StartExcursion("SELL",bar,time,high,low);
            record.setup_id=g_engine.setup_id;
            record.anchor_boundary=g_engine.anchor_boundary;
            record.anchor_extreme=g_engine.anchor_extreme;
            record.setup_age=g_engine.age_bars;

            if(close[bar]<g_engine.anchor_boundary)
               ConfirmCandidate("SELL",record);
            else
            {
               record.decision="WAIT";
               record.reason="SELL_EXCURSION_OPEN";
            }
         }
         break;
      }

      case MRC_BUY_EXCURSION:
      {
         g_engine.age_bars++;
         g_engine.anchor_extreme=MathMin(g_engine.anchor_extreme,low[bar]);
         record.setup_id=g_engine.setup_id;
         record.anchor_boundary=g_engine.anchor_boundary;
         record.anchor_extreme=g_engine.anchor_extreme;
         record.setup_age=g_engine.age_bars;

         if(close[bar]>g_engine.anchor_boundary)
            ConfirmCandidate("BUY",record);
         else if(g_engine.age_bars>InpSetupMaxBars)
         {
            record.decision="WAIT";
            record.reason="BUY_EXCURSION_EXPIRED";
            g_engine.state=MRC_WATCH;
            ClearEngineAnchor();
         }
         else
         {
            record.decision="WAIT";
            record.reason="BUY_REENTRY_NOT_CONFIRMED";
         }
         break;
      }

      case MRC_SELL_EXCURSION:
      {
         g_engine.age_bars++;
         g_engine.anchor_extreme=MathMax(g_engine.anchor_extreme,high[bar]);
         record.setup_id=g_engine.setup_id;
         record.anchor_boundary=g_engine.anchor_boundary;
         record.anchor_extreme=g_engine.anchor_extreme;
         record.setup_age=g_engine.age_bars;

         if(close[bar]<g_engine.anchor_boundary)
            ConfirmCandidate("SELL",record);
         else if(g_engine.age_bars>InpSetupMaxBars)
         {
            record.decision="WAIT";
            record.reason="SELL_EXCURSION_EXPIRED";
            g_engine.state=MRC_WATCH;
            ClearEngineAnchor();
         }
         else
         {
            record.decision="WAIT";
            record.reason="SELL_REENTRY_NOT_CONFIRMED";
         }
         break;
      }

      case MRC_BUY_LOCKED:
      {
         record.setup_id=g_engine.setup_id;
         record.anchor_boundary=g_engine.anchor_boundary;
         record.anchor_extreme=g_engine.anchor_extreme;
         record.setup_age=g_engine.age_bars;
         if(close[bar]>=BufferTrend[bar-1])
         {
            record.decision="WAIT";
            record.reason="BUY_REARM_AT_TREND";
            g_engine.state=MRC_WATCH;
            ClearEngineAnchor();
         }
         else
         {
            record.decision="WAIT";
            record.reason="BUY_LOCKED_WAIT_TREND";
         }
         break;
      }

      case MRC_SELL_LOCKED:
      {
         record.setup_id=g_engine.setup_id;
         record.anchor_boundary=g_engine.anchor_boundary;
         record.anchor_extreme=g_engine.anchor_extreme;
         record.setup_age=g_engine.age_bars;
         if(close[bar]<=BufferTrend[bar-1])
         {
            record.decision="WAIT";
            record.reason="SELL_REARM_AT_TREND";
            g_engine.state=MRC_WATCH;
            ClearEngineAnchor();
         }
         else
         {
            record.decision="WAIT";
            record.reason="SELL_LOCKED_WAIT_TREND";
         }
         break;
      }
   }

   ApplyDecisionAndRisk(record);
   record.state_after=StateToString(g_engine.state);
}

void CommitSignalVisualsAndAlert(const DecisionRecord &record,const bool allow_alert)
{
   if(record.signal_emitted)
   {
      const double arrow_offset=MathMax(10.0*_Point,record.channel_width*0.08);
      if(record.candidate=="BUY")
         BufferBuyArrows[record.bar_index]=record.low_price-arrow_offset;
      else
         BufferSellArrows[record.bar_index]=record.high_price+arrow_offset;

      CreateSignalMarker(record,false);

      if(allow_alert && InpUseAlerts)
      {
         const string message=StringFormat(
            "MATRIX %s %s | %s\nEntry=%s SL=%s TP1=%s TP2=%s RR2=%s\nHTF=%s %s",
            record.candidate,_Symbol,SafeTime(record.bar_time),PriceToString(record.entry_price),
            PriceToString(record.stop_loss),PriceToString(record.tp1_trend),PriceToString(record.tp2_opposite),
            NumberToString(record.rr2,2),record.htf_direction,SafeTime(record.htf_source_time));
         Alert(message);
         PlaySound("alert.wav");
      }
   }
   else if(StringFind(record.decision,"LOW_EDGE")>=0)
   {
      CreateSignalMarker(record,true);
   }
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPeriod<=MRC_COEFF_COUNT || InpPeriod<5 || InpDev<=0.0 ||
      InpSetupMaxBars<1 || InpMinRR2<0.0 || InpMinReversalPhaseBars<1 ||
      InpMinReversalExtension<0.0 || InpStopIndentPoints<0 ||
      InpDiagHistoryBars<0 || InpDiagMaxRowsPerRun<100 || InpDiagFlushEveryRows<1)
      return INIT_PARAMETERS_INCORRECT;

   if(InpUseHTFFilter && PeriodSeconds(InpFilterTF)<=PeriodSeconds((ENUM_TIMEFRAMES)_Period))
   {
      Print("MRC INIT ERROR: InpFilterTF must be strictly higher than chart timeframe.");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0,BufferTrend,INDICATOR_DATA);
   SetIndexBuffer(1,BufferUpper,INDICATOR_DATA);
   SetIndexBuffer(2,BufferLower,INDICATOR_DATA);
   SetIndexBuffer(3,BufferBuyArrows,INDICATOR_DATA);
   SetIndexBuffer(4,BufferSellArrows,INDICATOR_DATA);

   ArraySetAsSeries(BufferTrend,false);
   ArraySetAsSeries(BufferUpper,false);
   ArraySetAsSeries(BufferLower,false);
   ArraySetAsSeries(BufferBuyArrows,false);
   ArraySetAsSeries(BufferSellArrows,false);

   PlotIndexSetInteger(3,PLOT_ARROW,233);
   PlotIndexSetInteger(4,PLOT_ARROW,234);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(2,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(3,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(4,PLOT_EMPTY_VALUE,EMPTY_VALUE);

   const int draw_begin=InpPeriod-1;
   for(int plot=0;plot<5;plot++) PlotIndexSetInteger(plot,PLOT_DRAW_BEGIN,draw_begin);

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("Matrix Regression QA (%d, %.2f, %s)",InpPeriod,InpDev,MRC_VERSION));
   IndicatorSetInteger(INDICATOR_DIGITS,_Digits);

   if(!BuildProjectionMatrix())
   {
      Print("MRC INIT ERROR: normalized least-squares projection is invalid.");
      return INIT_FAILED;
   }

   g_object_prefix=StringFormat("MRC_%I64d_%u_",ChartID(),GetTickCount());
   ResetSignalEngine();
   ResetMarketPhase();
   g_htf_cache_valid=false;
   g_last_processed_bar=-1;
   g_last_processed_time=0;
   g_runtime_ready=false;
   g_have_last_record=false;

   if(!OpenDiagnosticLog())
      return INIT_FAILED;

   EnsurePanel();
   UpdatePanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   CloseDiagnosticLog(reason);
   ObjectsDeleteAll(0,g_object_prefix);
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_CHART_CHANGE)
   {
      EnsurePanel();
      UpdatePanel();
      ChartRedraw(0);
   }
}

//+------------------------------------------------------------------+
//| Main calculation                                                 |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   ArraySetAsSeries(time,false);
   ArraySetAsSeries(open,false);
   ArraySetAsSeries(high,false);
   ArraySetAsSeries(low,false);
   ArraySetAsSeries(close,false);

   const int first_valid=InpPeriod-1;
   if(rates_total<=first_valid+1)
   {
      UpdatePanel();
      return 0;
   }

   ArrayResize(g_sigma,rates_total);
   ArrayResize(g_velocity,rates_total);
   ArrayResize(g_curvature,rates_total);
   ArraySetAsSeries(g_sigma,false);
   ArraySetAsSeries(g_velocity,false);
   ArraySetAsSeries(g_curvature,false);

   const bool full_rebuild=(prev_calculated==0 || prev_calculated>rates_total ||
                            g_last_processed_bar>=rates_total);

   if(full_rebuild)
   {
      ArrayInitialize(BufferTrend,EMPTY_VALUE);
      ArrayInitialize(BufferUpper,EMPTY_VALUE);
      ArrayInitialize(BufferLower,EMPTY_VALUE);
      ArrayInitialize(BufferBuyArrows,EMPTY_VALUE);
      ArrayInitialize(BufferSellArrows,EMPTY_VALUE);
      ArrayInitialize(g_sigma,EMPTY_VALUE);
      ArrayInitialize(g_velocity,EMPTY_VALUE);
      ArrayInitialize(g_curvature,EMPTY_VALUE);
      ObjectsDeleteAll(0,g_object_prefix+"SIG_");
   }
   else
   {
      for(int i=MathMax(0,prev_calculated);i<rates_total;i++)
      {
         BufferBuyArrows[i]=EMPTY_VALUE;
         BufferSellArrows[i]=EMPTY_VALUE;
      }
   }

   const int calc_start=(full_rebuild ? first_valid : MathMax(first_valid,prev_calculated-1));
   for(int bar=calc_start;bar<rates_total;bar++)
   {
      RegressionResult regression;
      if(!RegressionFromSeries(close,bar-InpPeriod+1,regression) || !IsRegressionValid(regression))
      {
         BufferTrend[bar]=EMPTY_VALUE;
         BufferUpper[bar]=EMPTY_VALUE;
         BufferLower[bar]=EMPTY_VALUE;
         g_sigma[bar]=EMPTY_VALUE;
         g_velocity[bar]=EMPTY_VALUE;
         g_curvature[bar]=EMPTY_VALUE;
         continue;
      }

      BufferTrend[bar]=regression.trend;
      BufferUpper[bar]=regression.trend+InpDev*regression.sigma;
      BufferLower[bar]=regression.trend-InpDev*regression.sigma;
      g_sigma[bar]=regression.sigma;
      g_velocity[bar]=regression.velocity;
      g_curvature[bar]=regression.curvature;
   }

   const int last_closed=rates_total-2;
   if(full_rebuild)
   {
      ResetSignalEngine();
      ResetMarketPhase();
      g_htf_cache_valid=false;
      g_have_last_record=false;
      const int history_from=MathMax(first_valid+1,last_closed-MathMax(0,InpDiagHistoryBars)+1);

      for(int bar=first_valid+1;bar<=last_closed;bar++)
      {
         DecisionRecord record;
         EvaluateSignalBar(bar,time,open,high,low,close,record);
         CommitSignalVisualsAndAlert(record,false);
         if(bar>=history_from) WriteDecision(record);
         g_last_record=record;
         g_have_last_record=true;
      }

      g_last_processed_bar=last_closed;
      g_last_processed_time=time[last_closed];
      g_runtime_ready=true;
      WriteMetaEvent("RUNTIME_READY",StringFormat("LAST_CLOSED=%s;HISTORY_ROWS=%d",
                     SafeTime(g_last_processed_time),MathMax(0,last_closed-history_from+1)));
   }
   else if(last_closed>g_last_processed_bar)
   {
      for(int bar=g_last_processed_bar+1;bar<=last_closed;bar++)
      {
         DecisionRecord record;
         EvaluateSignalBar(bar,time,open,high,low,close,record);
         CommitSignalVisualsAndAlert(record,g_runtime_ready);
         WriteDecision(record);
         g_last_record=record;
         g_have_last_record=true;
         g_last_processed_bar=bar;
         g_last_processed_time=time[bar];
      }
   }

   UpdatePanel();
   ChartRedraw(0);
   return rates_total;
}
//+------------------------------------------------------------------+
