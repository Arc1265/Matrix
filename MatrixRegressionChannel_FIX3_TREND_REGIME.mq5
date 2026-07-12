//+------------------------------------------------------------------+
//| MatrixRegressionChannel_FIX3_TREND_REGIME.mq5                     |
//| FIX3: режимный движок поверх квадратичного МНК-ядра FIX2.        |
//|                                                                  |
//| Что добавлено относительно FIX2:                                 |
//|  1. t-статистика наклона w1/SE(w1) из матрицы (X^T*X)^-1 —       |
//|     статистически честное разделение ФЛЭТ / ТРЕНД.               |
//|  2. Kaufman Efficiency Ratio — второй голос против «пилы».       |
//|  3. Гистерезис режима: порог входа в тренд выше порога выхода,   |
//|     плюс подтверждение InpConfirmBars подряд закрытых баров.     |
//|  4. Быстрое окно (второе МНК-ядро) для раннего тайминга входа    |
//|     и детекции затухания тренда на выходе.                       |
//|                                                                  |
//| Визуализация:                                                    |
//|  - центральная линия и канал раскрашены по режиму:               |
//|    серый = ФЛЭТ, зелёный = ТРЕНД ВВЕРХ, красный = ТРЕНД ВНИЗ;    |
//|  - стрелка вверх/вниз = вход в начале тренда;                    |
//|  - крестик = выход (фиксация профита).                           |
//|                                                                  |
//| Все решения принимаются ТОЛЬКО по закрытому бару.                |
//| Стрелки и крестики не перерисовываются. Цвет текущего            |
//| (формирующегося) бара наследуется от последнего закрытого.       |
//+------------------------------------------------------------------+
#property copyright "AI Quantum Trader / ArNi QA"
#property version   "3.00"
#property indicator_chart_window
#property indicator_buffers 10
#property indicator_plots   7

#property indicator_label1  "Regression Trend (regime)"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrSilver,clrLimeGreen,clrTomato
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "Upper Channel"
#property indicator_type2   DRAW_COLOR_LINE
#property indicator_color2  clrDarkGray,clrGreen,clrFireBrick
#property indicator_style2  STYLE_DOT
#property indicator_width2  1

#property indicator_label3  "Lower Channel"
#property indicator_type3   DRAW_COLOR_LINE
#property indicator_color3  clrDarkGray,clrGreen,clrFireBrick
#property indicator_style3  STYLE_DOT
#property indicator_width3  1

#property indicator_label4  "BUY: trend start"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrLime
#property indicator_width4  3

#property indicator_label5  "SELL: trend start"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrRed
#property indicator_width5  3

#property indicator_label6  "EXIT long (fix profit)"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrOrange
#property indicator_width6  2

#property indicator_label7  "EXIT short (fix profit)"
#property indicator_type7   DRAW_ARROW
#property indicator_color7  clrDeepSkyBlue
#property indicator_width7  2

#define MRC3_VERSION      "FIX3_TREND_REGIME"
#define MRC3_COEFF_COUNT  3

//--- режимы рынка
#define REGIME_FLAT   0
#define REGIME_UP     1
#define REGIME_DOWN  -1

input group "--- Медленное окно: режим рынка ---"
input int    InpPeriodSlow      = 60;    // Окно квадратичной регрессии (режим), баров
input double InpDev             = 2.0;   // Полуширина канала в остаточных sigma
input double InpTrendEnterT     = 4.0;   // |t|-статистика наклона для входа в ТРЕНД
input double InpTrendExitT      = 1.5;   // |t|-статистика для возврата во ФЛЭТ
input int    InpConfirmBars     = 2;     // Подтверждение режима, закрытых баров подряд

input group "--- Efficiency Ratio (фильтр пилы) ---"
input int    InpERPeriod        = 30;    // Окно Kaufman ER, баров
input double InpEREnter         = 0.30;  // Минимальный ER для признания тренда

input group "--- Быстрое окно: тайминг входа/выхода ---"
input int    InpPeriodFast      = 20;    // Быстрое окно регрессии, баров
input double InpFastEnterT      = 2.5;   // |t| быстрого окна для подтверждения входа
input double InpFastExitT       = 1.0;   // |t| быстрого окна ниже которого тренд "затух"
input int    InpEntryGraceBars  = 6;     // Сколько баров ждать подтверждения входа после смены режима

input group "--- Вход ---"
input bool   InpRequireBreakout   = true; // Требовать пробой экстремума перед входом
input int    InpBreakoutLookback  = 10;   // Глубина экстремума для пробоя, баров

input group "--- Выход (фиксация профита) ---"
input bool   InpExitOnTrendlineCross = true; // Выход при закрытии за центральной линией
input bool   InpExitOnFastDecay      = true; // Выход при затухании быстрого окна
input int    InpExitDecelBars        = 2;    // Баров замедления подряд для выхода

input group "--- Оповещения, панель, диагностика ---"
input bool   InpUseAlerts           = true;  // Алерты по закрытому бару
input bool   InpShowPanel           = true;  // HUD-панель состояния
input bool   InpEnableDiagnostics   = true;  // CSV-журнал в MQL5\Files
input int    InpDiagMaxRowsPerRun   = 20000; // Защита от бесконечного файла
input int    InpDiagFlushEveryRows  = 20;    // FileFlush каждые N строк

//--- буферы отрисовки
double BufTrend[];
double BufTrendClr[];
double BufUpper[];
double BufUpperClr[];
double BufLower[];
double BufLowerClr[];
double BufBuy[];
double BufSell[];
double BufExitLong[];
double BufExitShort[];

//--- расчётные серии (не рисуются)
double g_tslow[];      // t-статистика наклона, медленное окно
double g_tfast[];      // t-статистика наклона, быстрое окно
double g_er[];         // Kaufman ER (со знаком направления)
double g_curv_fast[];  // кривизна быстрого окна

//--- проекционные матрицы МНК и стандартные ошибки наклона
matrix g_proj_slow;
matrix g_proj_fast;
double g_se1_slow = 0.0;   // sqrt( [(X^T X)^-1]_11 ), медленное окно
double g_se1_fast = 0.0;   // то же, быстрое окно

struct RegimeReg
{
   bool   valid;
   double trend;
   double sigma;
   double curvature;
   double w1;
   double tstat;
};

//--- состояние режимного движка (обновляется только по закрытым барам)
int      g_regime            = REGIME_FLAT;
int      g_regime_age        = 0;
int      g_pending_dir       = 0;
int      g_pending_cnt       = 0;
bool     g_entry_pending     = false;
int      g_entry_grace       = 0;
int      g_open_dir          = 0;      // виртуальная позиция: 0 нет, +1 long, -1 short
double   g_open_price        = 0.0;
datetime g_open_time         = 0;
int      g_decel_cnt         = 0;
string   g_last_event        = "INIT";
datetime g_last_event_time   = 0;

//--- контроль обработки
int      g_last_processed_bar  = -1;
datetime g_last_processed_time = 0;
bool     g_runtime_ready       = false;

//--- диагностика
int    g_log_handle = INVALID_HANDLE;
string g_log_filename = "";
long   g_log_rows = 0;
int    g_rows_since_flush = 0;
bool   g_log_limit_reported = false;

//--- панель
string g_obj_prefix = "";
#define MRC3_PANEL_LINES 9

//+------------------------------------------------------------------+
//| Утилиты                                                          |
//+------------------------------------------------------------------+
string RegimeToString(const int regime)
{
   if(regime == REGIME_UP)   return "TREND_UP";
   if(regime == REGIME_DOWN) return "TREND_DOWN";
   return "FLAT";
}

int RegimeToColorIndex(const int regime)
{
   if(regime == REGIME_UP)   return 1;
   if(regime == REGIME_DOWN) return 2;
   return 0;
}

string SafeTime(const datetime value)
{
   if(value <= 0) return "";
   return TimeToString(value, TIME_DATE | TIME_MINUTES);
}

string SanitizeFileToken(string value)
{
   StringReplace(value, ".", "_");
   StringReplace(value, ":", "_");
   StringReplace(value, " ", "_");
   StringReplace(value, "/", "_");
   StringReplace(value, "\\", "_");
   return value;
}

//+------------------------------------------------------------------+
//| Проекция МНК: нормированная ось x в [-1;+1] (обусловленность)    |
//| Дополнительно возвращает sqrt([(X^T X)^-1]_11) для SE наклона.   |
//+------------------------------------------------------------------+
bool BuildProjection(const int period, matrix &proj, double &se1_sqrt)
{
   if(period <= MRC3_COEFF_COUNT) return false;

   matrix design;
   design.Init(period, MRC3_COEFF_COUNT);
   for(int i = 0; i < period; i++)
   {
      const double x = -1.0 + (2.0 * (double)i / (double)(period - 1));
      design[i, 0] = 1.0;
      design[i, 1] = x;
      design[i, 2] = x * x;
   }

   matrix xt  = design.Transpose();
   matrix xtx = xt.MatMul(design);
   matrix xtx_inv = xtx.Inv();
   if(xtx_inv.Rows() != MRC3_COEFF_COUNT || xtx_inv.Cols() != MRC3_COEFF_COUNT)
      return false;

   proj = xtx_inv.MatMul(xt);
   if(proj.Rows() != MRC3_COEFF_COUNT || proj.Cols() != period)
      return false;

   for(int r = 0; r < MRC3_COEFF_COUNT; r++)
      for(int c = 0; c < period; c++)
         if(!MathIsValidNumber(proj[r, c]))
            return false;

   const double inv11 = xtx_inv[1, 1];
   if(!MathIsValidNumber(inv11) || inv11 <= 0.0)
      return false;
   se1_sqrt = MathSqrt(inv11);
   return true;
}

//+------------------------------------------------------------------+
//| Квадратичная регрессия окна, заканчивающегося на bar             |
//+------------------------------------------------------------------+
bool RegressionAt(const double &close[], const int bar, const int period,
                  const matrix &proj, const double se1_sqrt, RegimeReg &out)
{
   out.valid = false;
   const int start = bar - period + 1;
   if(start < 0) return false;

   double w0 = 0.0, w1 = 0.0, w2 = 0.0;
   for(int i = 0; i < period; i++)
   {
      const double y = close[start + i];
      if(!MathIsValidNumber(y)) return false;
      w0 += proj[0, i] * y;
      w1 += proj[1, i] * y;
      w2 += proj[2, i] * y;
   }

   double sse = 0.0;
   for(int i = 0; i < period; i++)
   {
      const double x = -1.0 + (2.0 * (double)i / (double)(period - 1));
      const double model = w0 + w1 * x + w2 * x * x;
      const double err = close[start + i] - model;
      sse += err * err;
   }

   const int dof = period - MRC3_COEFF_COUNT;
   if(dof <= 0) return false;

   const double dx = 2.0 / (double)(period - 1);
   out.trend     = w0 + w1 + w2;                 // значение кривой на последнем баре (x=+1)
   out.sigma     = MathSqrt(MathMax(0.0, sse / (double)dof));
   out.curvature = (2.0 * w2) * dx * dx;
   out.w1        = w1;

   // t-статистика среднего наклона окна: w1 / (sigma * sqrt(inv11)).
   // При sigma->0 (идеальная прямая) ограничиваем сверху, а не делим на ноль.
   const double denom = out.sigma * se1_sqrt;
   if(denom > 1.0e-12)
      out.tstat = w1 / denom;
   else
      out.tstat = (w1 > 0.0 ? 999.0 : (w1 < 0.0 ? -999.0 : 0.0));

   out.valid = MathIsValidNumber(out.trend) && MathIsValidNumber(out.sigma) &&
               MathIsValidNumber(out.curvature) && MathIsValidNumber(out.tstat);
   return out.valid;
}

//+------------------------------------------------------------------+
//| Kaufman Efficiency Ratio со знаком чистого движения              |
//+------------------------------------------------------------------+
double SignedERAt(const double &close[], const int bar, const int period)
{
   const int start = bar - period;
   if(start < 0) return 0.0;

   const double net = close[bar] - close[start];
   double path = 0.0;
   for(int i = start + 1; i <= bar; i++)
      path += MathAbs(close[i] - close[i - 1]);

   if(path <= 0.0) return 0.0;
   return net / path;   // в [-1;+1], знак = направление чистого движения
}

//+------------------------------------------------------------------+
//| Диагностика CSV                                                  |
//+------------------------------------------------------------------+
bool OpenDiagnosticLog()
{
   if(!InpEnableDiagnostics) return true;

   g_log_filename = StringFormat("MatrixRegime_%s_%s_%s.csv",
                                 SanitizeFileToken(_Symbol),
                                 SanitizeFileToken(EnumToString((ENUM_TIMEFRAMES)_Period)),
                                 MRC3_VERSION);
   g_log_handle = FileOpen(g_log_filename, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(g_log_handle == INVALID_HANDLE)
   {
      Print("MRC3: не удалось открыть журнал ", g_log_filename, " err=", GetLastError());
      return false;
   }
   FileWriteString(g_log_handle,
      "row;bar_time;close;t_slow;t_fast;er;curv_fast;regime;regime_age;open_dir;event;reason\n");
   g_log_rows = 0;
   g_rows_since_flush = 0;
   g_log_limit_reported = false;
   return true;
}

void WriteDiagRow(const datetime bar_time, const double close_price,
                  const double t_slow, const double t_fast, const double er,
                  const double curv_fast, const string event_name, const string reason)
{
   if(g_log_handle == INVALID_HANDLE) return;
   if(g_log_rows >= InpDiagMaxRowsPerRun)
   {
      if(!g_log_limit_reported)
      {
         g_log_limit_reported = true;
         FileWriteString(g_log_handle, "LIMIT;rows_limit_reached\n");
         FileFlush(g_log_handle);
      }
      return;
   }

   g_log_rows++;
   FileWriteString(g_log_handle, StringFormat("%I64d;%s;%s;%.4f;%.4f;%.4f;%.8f;%s;%d;%d;%s;%s\n",
                   g_log_rows, SafeTime(bar_time), DoubleToString(close_price, _Digits),
                   t_slow, t_fast, er, curv_fast,
                   RegimeToString(g_regime), g_regime_age, g_open_dir, event_name, reason));
   g_rows_since_flush++;
   if(g_rows_since_flush >= InpDiagFlushEveryRows)
   {
      FileFlush(g_log_handle);
      g_rows_since_flush = 0;
   }
}

void CloseDiagnosticLog()
{
   if(g_log_handle != INVALID_HANDLE)
   {
      FileFlush(g_log_handle);
      FileClose(g_log_handle);
      g_log_handle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| HUD-панель                                                       |
//+------------------------------------------------------------------+
void EnsurePanel()
{
   if(!InpShowPanel) return;

   const string bg = g_obj_prefix + "PANEL_BG";
   if(ObjectFind(0, bg) < 0)
   {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 360);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 16 * MRC3_PANEL_LINES + 10);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'12,12,12');
      ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
   }

   for(int i = 0; i < MRC3_PANEL_LINES; i++)
   {
      const string name = g_obj_prefix + "PANEL_L" + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 14);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 25 + 16 * i);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      }
   }
}

void SetPanelLine(const int index, const string text, const color clr = clrWhite)
{
   if(!InpShowPanel) return;
   const string name = g_obj_prefix + "PANEL_L" + IntegerToString(index);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void UpdatePanel(const int last_closed)
{
   if(!InpShowPanel) return;

   color regime_clr = clrSilver;
   if(g_regime == REGIME_UP)   regime_clr = clrLimeGreen;
   if(g_regime == REGIME_DOWN) regime_clr = clrTomato;

   const double ts = (last_closed >= 0 && last_closed < ArraySize(g_tslow) ? g_tslow[last_closed] : 0.0);
   const double tf = (last_closed >= 0 && last_closed < ArraySize(g_tfast) ? g_tfast[last_closed] : 0.0);
   const double er = (last_closed >= 0 && last_closed < ArraySize(g_er)    ? g_er[last_closed]    : 0.0);

   SetPanelLine(0, "MATRIX REGIME QA | " + MRC3_VERSION, clrAqua);
   SetPanelLine(1, StringFormat("SYMBOL/TF: %s / %s   N=%d/%d ER=%d",
                _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                InpPeriodSlow, InpPeriodFast, InpERPeriod));
   SetPanelLine(2, StringFormat("REGIME: %s  age=%d", RegimeToString(g_regime), g_regime_age), regime_clr);
   SetPanelLine(3, StringFormat("T_SLOW=%.2f (in>%.1f out<%.1f)", ts, InpTrendEnterT, InpTrendExitT));
   SetPanelLine(4, StringFormat("T_FAST=%.2f  ER=%.3f (min %.2f)", tf, er, InpEREnter));
   SetPanelLine(5, StringFormat("VIRTUAL POS: %s %s",
                (g_open_dir > 0 ? "LONG" : (g_open_dir < 0 ? "SHORT" : "NONE")),
                (g_open_dir != 0 ? "from " + DoubleToString(g_open_price, _Digits) : "")),
                (g_open_dir > 0 ? clrLimeGreen : (g_open_dir < 0 ? clrTomato : clrSilver)));
   SetPanelLine(6, StringFormat("LAST EVENT: %s %s", g_last_event, SafeTime(g_last_event_time)), clrGold);
   SetPanelLine(7, StringFormat("CLOSED BAR: %s", SafeTime(g_last_processed_time)));
   SetPanelLine(8, (InpEnableDiagnostics ?
                StringFormat("LOG: %s rows=%I64d", g_log_filename, g_log_rows) : "LOG: OFF"), clrDarkGray);
}

//+------------------------------------------------------------------+
//| Регистрация события: маркер, алерт, журнал                       |
//+------------------------------------------------------------------+
void EmitEvent(const int bar, const datetime &time[], const double &high[],
               const double &low[], const double &close[],
               const string event_name, const string reason, const bool allow_alert)
{
   const double width = ((BufUpper[bar] != EMPTY_VALUE && BufLower[bar] != EMPTY_VALUE) ?
                         BufUpper[bar] - BufLower[bar] : 0.0);
   const double offset = MathMax(10.0 * _Point, width * 0.08);

   if(event_name == "ENTRY_BUY")        BufBuy[bar]       = low[bar]  - offset;
   else if(event_name == "ENTRY_SELL")  BufSell[bar]      = high[bar] + offset;
   else if(event_name == "EXIT_LONG")   BufExitLong[bar]  = high[bar] + offset;
   else if(event_name == "EXIT_SHORT")  BufExitShort[bar] = low[bar]  - offset;

   g_last_event = event_name + " (" + reason + ")";
   g_last_event_time = time[bar];

   WriteDiagRow(time[bar], close[bar], g_tslow[bar], g_tfast[bar], g_er[bar],
                g_curv_fast[bar], event_name, reason);

   if(allow_alert && InpUseAlerts)
      Alert(StringFormat("MRC3 %s %s: %s @ %s | %s",
            _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
            event_name, DoubleToString(close[bar], _Digits), reason));
}

//+------------------------------------------------------------------+
//| Пробой экстремума предыдущих баров (подтверждение импульса)      |
//+------------------------------------------------------------------+
bool BreakoutOK(const int dir, const int bar, const double &high[],
                const double &low[], const double &close[])
{
   if(!InpRequireBreakout) return true;
   const int from = bar - InpBreakoutLookback;
   if(from < 0) return false;

   if(dir > 0)
   {
      double hh = high[from];
      for(int i = from + 1; i < bar; i++) hh = MathMax(hh, high[i]);
      return (close[bar] > hh);
   }
   double ll = low[from];
   for(int i = from + 1; i < bar; i++) ll = MathMin(ll, low[i]);
   return (close[bar] < ll);
}

//+------------------------------------------------------------------+
//| Обработка одного ЗАКРЫТОГО бара режимным движком                 |
//+------------------------------------------------------------------+
void ProcessClosedBar(const int bar, const datetime &time[], const double &high[],
                      const double &low[], const double &close[], const bool allow_alert)
{
   if(g_tslow[bar] == EMPTY_VALUE || g_tfast[bar] == EMPTY_VALUE ||
      BufTrend[bar] == EMPTY_VALUE)
   {
      g_last_processed_time = time[bar];
      return;
   }

   const double ts = g_tslow[bar];
   const double tf = g_tfast[bar];
   const double er = g_er[bar];

   //--- 1) сырое направление этого бара (кандидат в тренд)
   int raw = 0;
   if(ts >= InpTrendEnterT && er >= InpEREnter)        raw = REGIME_UP;
   else if(ts <= -InpTrendEnterT && er <= -InpEREnter) raw = REGIME_DOWN;

   if(raw != 0 && raw == g_pending_dir) g_pending_cnt++;
   else if(raw != 0) { g_pending_dir = raw; g_pending_cnt = 1; }
   else              { g_pending_dir = 0;   g_pending_cnt = 0; }

   //--- 2) выход из текущего трендового режима (гистерезис)
   const int prev_regime = g_regime;
   if(g_regime == REGIME_UP && ts < InpTrendExitT)    g_regime = REGIME_FLAT;
   if(g_regime == REGIME_DOWN && ts > -InpTrendExitT) g_regime = REGIME_FLAT;

   //--- 3) вход в новый трендовый режим (после подтверждения)
   if(g_pending_cnt >= InpConfirmBars && g_pending_dir != 0 && g_regime != g_pending_dir)
      g_regime = g_pending_dir;

   if(g_regime == prev_regime) g_regime_age++;
   else                        g_regime_age = 1;

   //--- 4) смена режима: закрытие виртуальной позиции и постановка входа в очередь
   if(g_regime != prev_regime)
   {
      if(g_open_dir != 0 &&
         (g_regime == REGIME_FLAT || g_regime != g_open_dir))
      {
         EmitEvent(bar, time, high, low, close,
                   (g_open_dir > 0 ? "EXIT_LONG" : "EXIT_SHORT"), "REGIME_END", allow_alert);
         g_open_dir = 0;
         g_decel_cnt = 0;
      }

      if(g_regime != REGIME_FLAT)
      {
         g_entry_pending = true;
         g_entry_grace = InpEntryGraceBars;
      }
      else
         g_entry_pending = false;
   }

   //--- 5) вход в начале тренда: быстрое окно + пробой, окно ожидания grace
   if(g_regime != REGIME_FLAT && g_entry_pending && g_open_dir == 0)
   {
      const bool fast_ok = (g_regime == REGIME_UP ? tf >= InpFastEnterT : tf <= -InpFastEnterT);
      const bool brk_ok  = BreakoutOK(g_regime, bar, high, low, close);

      if(fast_ok && brk_ok)
      {
         g_open_dir = g_regime;
         g_open_price = close[bar];
         g_open_time = time[bar];
         g_decel_cnt = 0;
         g_entry_pending = false;
         EmitEvent(bar, time, high, low, close,
                   (g_regime == REGIME_UP ? "ENTRY_BUY" : "ENTRY_SELL"),
                   StringFormat("T%.1f/%.1f_ER%.2f", ts, tf, er), allow_alert);
      }
      else
      {
         g_entry_grace--;
         if(g_entry_grace <= 0) g_entry_pending = false;
      }
   }

   //--- 6) выход для фиксации профита (пока режим ещё жив)
   if(g_open_dir != 0 && g_regime == g_open_dir)
   {
      string exit_reason = "";

      if(InpExitOnTrendlineCross)
      {
         if(g_open_dir > 0 && close[bar] < BufTrend[bar]) exit_reason = "TRENDLINE_CROSS";
         if(g_open_dir < 0 && close[bar] > BufTrend[bar]) exit_reason = "TRENDLINE_CROSS";
      }

      if(exit_reason == "" && InpExitOnFastDecay)
      {
         const bool decel = (g_open_dir > 0 ?
                             (tf < InpFastExitT && g_curv_fast[bar] < 0.0) :
                             (tf > -InpFastExitT && g_curv_fast[bar] > 0.0));
         if(decel) g_decel_cnt++;
         else      g_decel_cnt = 0;

         if(g_decel_cnt >= InpExitDecelBars) exit_reason = "FAST_DECAY";
      }

      if(exit_reason != "")
      {
         EmitEvent(bar, time, high, low, close,
                   (g_open_dir > 0 ? "EXIT_LONG" : "EXIT_SHORT"), exit_reason, allow_alert);
         g_open_dir = 0;
         g_decel_cnt = 0;
      }
   }

   //--- 7) цвет зоны и журнал состояния
   const int clr_index = RegimeToColorIndex(g_regime);
   BufTrendClr[bar] = clr_index;
   BufUpperClr[bar] = clr_index;
   BufLowerClr[bar] = clr_index;

   WriteDiagRow(time[bar], close[bar], ts, tf, er, g_curv_fast[bar], "", RegimeToString(g_regime));
   g_last_processed_time = time[bar];
}

void ResetEngine()
{
   g_regime = REGIME_FLAT;
   g_regime_age = 0;
   g_pending_dir = 0;
   g_pending_cnt = 0;
   g_entry_pending = false;
   g_entry_grace = 0;
   g_open_dir = 0;
   g_open_price = 0.0;
   g_open_time = 0;
   g_decel_cnt = 0;
   g_last_event = "RESET";
   g_last_event_time = 0;
}

//+------------------------------------------------------------------+
//| Жизненный цикл индикатора                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPeriodSlow < 10 || InpPeriodFast < 6 || InpERPeriod < 5 ||
      InpPeriodFast >= InpPeriodSlow ||
      InpDev <= 0.0 || InpTrendEnterT <= InpTrendExitT || InpTrendExitT < 0.0 ||
      InpFastEnterT <= InpFastExitT || InpFastExitT < 0.0 ||
      InpConfirmBars < 1 || InpEntryGraceBars < 1 ||
      InpBreakoutLookback < 2 || InpExitDecelBars < 1 ||
      InpDiagMaxRowsPerRun < 100 || InpDiagFlushEveryRows < 1)
   {
      Print("MRC3 INIT ERROR: некорректные входные параметры (проверьте пороги и окна).");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, BufTrend,     INDICATOR_DATA);
   SetIndexBuffer(1, BufTrendClr,  INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BufUpper,     INDICATOR_DATA);
   SetIndexBuffer(3, BufUpperClr,  INDICATOR_COLOR_INDEX);
   SetIndexBuffer(4, BufLower,     INDICATOR_DATA);
   SetIndexBuffer(5, BufLowerClr,  INDICATOR_COLOR_INDEX);
   SetIndexBuffer(6, BufBuy,       INDICATOR_DATA);
   SetIndexBuffer(7, BufSell,      INDICATOR_DATA);
   SetIndexBuffer(8, BufExitLong,  INDICATOR_DATA);
   SetIndexBuffer(9, BufExitShort, INDICATOR_DATA);

   ArraySetAsSeries(BufTrend, false);
   ArraySetAsSeries(BufTrendClr, false);
   ArraySetAsSeries(BufUpper, false);
   ArraySetAsSeries(BufUpperClr, false);
   ArraySetAsSeries(BufLower, false);
   ArraySetAsSeries(BufLowerClr, false);
   ArraySetAsSeries(BufBuy, false);
   ArraySetAsSeries(BufSell, false);
   ArraySetAsSeries(BufExitLong, false);
   ArraySetAsSeries(BufExitShort, false);

   PlotIndexSetInteger(3, PLOT_ARROW, 233);   // вход BUY
   PlotIndexSetInteger(4, PLOT_ARROW, 234);   // вход SELL
   PlotIndexSetInteger(5, PLOT_ARROW, 251);   // выход из long (X)
   PlotIndexSetInteger(6, PLOT_ARROW, 251);   // выход из short (X)

   for(int plot = 0; plot < 7; plot++)
      PlotIndexSetDouble(plot, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   const int draw_begin = MathMax(InpPeriodSlow, MathMax(InpPeriodFast, InpERPeriod + 1));
   for(int plot = 0; plot < 7; plot++)
      PlotIndexSetInteger(plot, PLOT_DRAW_BEGIN, draw_begin);

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("Matrix Regime (%d/%d, %.1f/%.1f, %s)",
                   InpPeriodSlow, InpPeriodFast, InpTrendEnterT, InpTrendExitT, MRC3_VERSION));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   if(!BuildProjection(InpPeriodSlow, g_proj_slow, g_se1_slow) ||
      !BuildProjection(InpPeriodFast, g_proj_fast, g_se1_fast))
   {
      Print("MRC3 INIT ERROR: проекционная матрица МНК невалидна.");
      return INIT_FAILED;
   }

   g_obj_prefix = StringFormat("MRC3_%I64d_", ChartID());
   ResetEngine();
   g_last_processed_bar = -1;
   g_last_processed_time = 0;
   g_runtime_ready = false;

   if(!OpenDiagnosticLog())
      return INIT_FAILED;

   EnsurePanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   CloseDiagnosticLog();
   ObjectsDeleteAll(0, g_obj_prefix);
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      EnsurePanel();
      ChartRedraw(0);
   }
}

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
   ArraySetAsSeries(time, false);
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);

   const int first_valid = MathMax(InpPeriodSlow - 1, MathMax(InpPeriodFast - 1, InpERPeriod));
   if(rates_total <= first_valid + 2)
      return 0;

   ArrayResize(g_tslow, rates_total);
   ArrayResize(g_tfast, rates_total);
   ArrayResize(g_er, rates_total);
   ArrayResize(g_curv_fast, rates_total);
   ArraySetAsSeries(g_tslow, false);
   ArraySetAsSeries(g_tfast, false);
   ArraySetAsSeries(g_er, false);
   ArraySetAsSeries(g_curv_fast, false);

   const bool full_rebuild = (prev_calculated == 0 || prev_calculated > rates_total ||
                              g_last_processed_bar >= rates_total);

   if(full_rebuild)
   {
      ArrayInitialize(BufTrend, EMPTY_VALUE);
      ArrayInitialize(BufTrendClr, 0);
      ArrayInitialize(BufUpper, EMPTY_VALUE);
      ArrayInitialize(BufUpperClr, 0);
      ArrayInitialize(BufLower, EMPTY_VALUE);
      ArrayInitialize(BufLowerClr, 0);
      ArrayInitialize(BufBuy, EMPTY_VALUE);
      ArrayInitialize(BufSell, EMPTY_VALUE);
      ArrayInitialize(BufExitLong, EMPTY_VALUE);
      ArrayInitialize(BufExitShort, EMPTY_VALUE);
      ArrayInitialize(g_tslow, EMPTY_VALUE);
      ArrayInitialize(g_tfast, EMPTY_VALUE);
      ArrayInitialize(g_er, EMPTY_VALUE);
      ArrayInitialize(g_curv_fast, EMPTY_VALUE);
   }
   else
   {
      // подчистка возможных значений на формирующемся баре
      for(int i = MathMax(0, prev_calculated - 1); i < rates_total; i++)
      {
         BufBuy[i] = EMPTY_VALUE;
         BufSell[i] = EMPTY_VALUE;
         BufExitLong[i] = EMPTY_VALUE;
         BufExitShort[i] = EMPTY_VALUE;
      }
   }

   //--- 1) расчёт линий и метрик (включая формирующийся бар — линии обновляются интрабарно)
   const int calc_start = (full_rebuild ? first_valid : MathMax(first_valid, prev_calculated - 1));
   for(int bar = calc_start; bar < rates_total; bar++)
   {
      RegimeReg slow, fast;
      const bool ok_slow = RegressionAt(close, bar, InpPeriodSlow, g_proj_slow, g_se1_slow, slow);
      const bool ok_fast = RegressionAt(close, bar, InpPeriodFast, g_proj_fast, g_se1_fast, fast);

      if(!ok_slow || !ok_fast)
      {
         BufTrend[bar] = EMPTY_VALUE;
         BufUpper[bar] = EMPTY_VALUE;
         BufLower[bar] = EMPTY_VALUE;
         g_tslow[bar] = EMPTY_VALUE;
         g_tfast[bar] = EMPTY_VALUE;
         g_er[bar] = EMPTY_VALUE;
         g_curv_fast[bar] = EMPTY_VALUE;
         continue;
      }

      BufTrend[bar] = slow.trend;
      BufUpper[bar] = slow.trend + InpDev * slow.sigma;
      BufLower[bar] = slow.trend - InpDev * slow.sigma;
      g_tslow[bar] = slow.tstat;
      g_tfast[bar] = fast.tstat;
      g_er[bar] = SignedERAt(close, bar, InpERPeriod);
      g_curv_fast[bar] = fast.curvature;
   }

   //--- 2) режимный движок: только закрытые бары, детерминированное воспроизведение
   const int last_closed = rates_total - 2;
   if(full_rebuild)
   {
      ResetEngine();
      for(int bar = first_valid + 1; bar <= last_closed; bar++)
         ProcessClosedBar(bar, time, high, low, close, false);

      g_last_processed_bar = last_closed;
      g_runtime_ready = true;
   }
   else if(last_closed > g_last_processed_bar)
   {
      for(int bar = g_last_processed_bar + 1; bar <= last_closed; bar++)
      {
         ProcessClosedBar(bar, time, high, low, close, g_runtime_ready);
         g_last_processed_bar = bar;
      }
   }

   //--- 3) формирующийся бар наследует цвет последнего закрытого режима
   const int last = rates_total - 1;
   const int inherited = (last_closed >= 0 ? (int)BufTrendClr[last_closed] : 0);
   BufTrendClr[last] = inherited;
   BufUpperClr[last] = inherited;
   BufLowerClr[last] = inherited;

   UpdatePanel(last_closed);
   ChartRedraw(0);
   return rates_total;
}
//+------------------------------------------------------------------+
