//+------------------------------------------------------------------+
//| FIX3_3_MatrixRegressionChannel_TREND_REGIME.mq5                   |
//| FIX3_3: режимный движок поверх квадратичного МНК-ядра FIX2.      |
//| Правило нумерации: небольшие правки = FIX3_1, FIX3_2, ...,       |
//| крупные изменения = FIX4; префикс версии в начале имени файла.   |
//|                                                                  |
//| FIX3_3 (калибровка по CSV тестера, XAUUSD H1 2022-2025,           |
//| 18966 баров, полная резимуляция движка + сетка параметров):      |
//|  - минимальное удержание режима InpMinHoldBars: пока зона        |
//|    моложе N баров, обычные выходы (гистерезис, гашение) не       |
//|    работают - только разворот/импульс могут перебить режим.      |
//|    Дёрганость упала с 49% коротких эпизодов до 6%.               |
//|  - импульсный детектор по умолчанию ВЫКЛЮЧЕН: на 3 годах         |
//|    XAUUSD H1 он породил большинство эпизодов-однодневок и        |
//|    ухудшал profit factor (1.08 против 1.22 без него). Развороты  |
//|    после трендов ловит дорожка разворота, вход из флэта -        |
//|    медленный путь. Пороги на случай включения: 6.5 / 0.45.       |
//|  - пороги по сетке: ExitS 1.5->2.0, EREnter 0.25->0.30,          |
//|    ReversalS 2.5->3.5, ReversalERF 0.25->0.30, Fade 3->6.        |
//|  Итог на истории: эпизодов 1084->410, медианная длина зоны       |
//|  4->9 баров, PF виртуальных сделок 1.08->1.22.                   |
//|                                                                  |
//| FIX3_2 (устранение запаздывания на развороте, XAUUSD H1):         |
//|  - быстрая дорожка разворота (reversal fast-track): после        |
//|    зрелого тренда встречное движение признаётся новым трендом    |
//|    по быстрому окну со смягчённым порогом, если цена уже         |
//|    закрылась по ту сторону центральной линии. Устраняет          |
//|    асимметрию: медленное окно "помнит" старый тренд и без        |
//|    этого перекрашивается на разворот на полокна позже.           |
//|  - ускоренное гашение: если бар закрылся за центральной линией   |
//|    против режима, счётчик гашения растёт вдвое быстрее.          |
//|                                                                  |
//| FIX3_1 (калибровка по ETHUSD M5):                                 |
//|  - безразмерная сила тренда S = (ход регрессии за окно) / sigma  |
//|    вместо t-статистики (та взлетала из-за автокорреляции);       |
//|  - импульсный детектор коротких резких движений;                 |
//|  - гашение зоны при потере подтверждения быстрым окном;          |
//|  - окна: slow 40, fast 14, ER = медленное окно.                  |
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
#property version   "3.30"
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

#define MRC3_VERSION      "FIX3_3_TREND_REGIME"
#define MRC3_COEFF_COUNT  3

//--- режимы рынка
#define REGIME_FLAT   0
#define REGIME_UP     1
#define REGIME_DOWN  -1

input group "--- Медленное окно: режим рынка ---"
input int    InpPeriodSlow      = 40;    // Окно квадратичной регрессии (режим), баров
input double InpDev             = 2.0;   // Полуширина канала в остаточных sigma
input double InpTrendEnterS     = 3.0;   // Сила S=ход/sigma для входа в ТРЕНД
input double InpTrendExitS      = 2.0;   // Сила S для возврата во ФЛЭТ
input int    InpConfirmBars     = 2;     // Подтверждение режима, закрытых баров подряд

input group "--- Efficiency Ratio (фильтр пилы) ---"
input int    InpERPeriod        = 0;     // Окно ER, баров (0 = как медленное окно)
input double InpEREnter         = 0.30;  // Минимальный |ER| для признания тренда

input group "--- Быстрое окно: тайминг и импульс ---"
input int    InpPeriodFast      = 14;    // Быстрое окно регрессии, баров
input double InpFastEnterS      = 2.0;   // |S| быстрого окна для подтверждения входа
input double InpFastExitS       = 0.8;   // |S| быстрого окна ниже которого тренд "затух"
input int    InpEntryGraceBars  = 6;     // Сколько баров ждать подтверждения входа после смены режима
input bool   InpImpulseEnable   = false; // Импульсный детектор (OFF: на XAUUSD H1 давал мельтешение)
input double InpImpulseS        = 6.5;   // |S| быстрого окна для мгновенного признания тренда
input double InpImpulseER       = 0.45;  // Минимальный |ER| быстрого окна для импульса

input group "--- Быстрая дорожка разворота (FIX3_2) ---"
input bool   InpReversalFastTrack   = true;  // Ранний разворот после зрелого тренда
input double InpReversalS           = 3.5;   // |S| быстрого окна для разворота
input double InpReversalERF         = 0.30;  // Минимальный |ER| быстрого окна для разворота
input int    InpReversalWindowBars  = 12;    // Сколько баров после конца тренда действует дорожка

input group "--- Стабильность зоны тренда (FIX3_3) ---"
input int    InpMinHoldBars     = 4;     // Мин. возраст зоны до обычных выходов, баров
input int    InpFadeExitBars    = 6;     // Баров без подтверждения быстрым окном до выхода во флэт

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
double g_sslow[];      // сила тренда S медленного окна (ход за окно / sigma)
double g_sfast[];      // сила тренда S быстрого окна
double g_er[];         // Kaufman ER медленного масштаба (со знаком)
double g_erfast[];     // Kaufman ER быстрого окна (со знаком)
double g_curv_fast[];  // кривизна быстрого окна

//--- проекционные матрицы МНК
matrix g_proj_slow;
matrix g_proj_fast;
int    g_er_period = 0;   // фактическое окно ER (0 на входе = как медленное)

struct RegimeReg
{
   bool   valid;
   double trend;
   double sigma;
   double curvature;
   double smove;     // (f(+1)-f(-1))/sigma = чистый ход регрессии за окно в сигмах
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
int      g_fade_cnt          = 0;
int      g_last_trend_dir    = 0;      // направление последнего завершившегося тренда
int      g_bars_since_trend  = 999999; // баров с конца последнего тренда
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
//+------------------------------------------------------------------+
bool BuildProjection(const int period, matrix &proj)
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
   return true;
}

//+------------------------------------------------------------------+
//| Квадратичная регрессия окна, заканчивающегося на bar             |
//+------------------------------------------------------------------+
bool RegressionAt(const double &close[], const int bar, const int period,
                  const matrix &proj, RegimeReg &out)
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

   // Сила тренда: чистый ход регрессии за окно f(+1)-f(-1)=2*w1,
   // отнесённый к шуму канала. Безразмерна и сопоставима между окнами.
   if(out.sigma > 1.0e-12)
      out.smove = (2.0 * w1) / out.sigma;
   else
      out.smove = (w1 > 0.0 ? 999.0 : (w1 < 0.0 ? -999.0 : 0.0));

   out.valid = MathIsValidNumber(out.trend) && MathIsValidNumber(out.sigma) &&
               MathIsValidNumber(out.curvature) && MathIsValidNumber(out.smove);
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
      "row;bar_time;close;s_slow;s_fast;er;er_fast;curv_fast;regime;regime_age;open_dir;event;reason\n");
   g_log_rows = 0;
   g_rows_since_flush = 0;
   g_log_limit_reported = false;
   return true;
}

void WriteDiagRow(const datetime bar_time, const double close_price,
                  const double s_slow, const double s_fast, const double er,
                  const double er_fast, const double curv_fast,
                  const string event_name, const string reason)
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
   FileWriteString(g_log_handle, StringFormat("%I64d;%s;%s;%.4f;%.4f;%.4f;%.4f;%.8f;%s;%d;%d;%s;%s\n",
                   g_log_rows, SafeTime(bar_time), DoubleToString(close_price, _Digits),
                   s_slow, s_fast, er, er_fast, curv_fast,
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
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 380);
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

   double ss = 0.0, sf = 0.0, er = 0.0, erf = 0.0;
   if(last_closed >= 0 && last_closed < ArraySize(g_sslow) && g_sslow[last_closed] != EMPTY_VALUE)
   {
      ss  = g_sslow[last_closed];
      sf  = g_sfast[last_closed];
      er  = g_er[last_closed];
      erf = g_erfast[last_closed];
   }

   SetPanelLine(0, "MATRIX REGIME QA | " + MRC3_VERSION, clrAqua);
   SetPanelLine(1, StringFormat("SYMBOL/TF: %s / %s   N=%d/%d ER=%d",
                _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                InpPeriodSlow, InpPeriodFast, g_er_period));
   SetPanelLine(2, StringFormat("REGIME: %s  age=%d", RegimeToString(g_regime), g_regime_age), regime_clr);
   SetPanelLine(3, StringFormat("S_SLOW=%.2f (in>%.1f out<%.1f)", ss, InpTrendEnterS, InpTrendExitS));
   SetPanelLine(4, StringFormat("S_FAST=%.2f  ER=%.3f ER_F=%.3f (min %.2f)", sf, er, erf, InpEREnter));
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

   WriteDiagRow(time[bar], close[bar], g_sslow[bar], g_sfast[bar], g_er[bar],
                g_erfast[bar], g_curv_fast[bar], event_name, reason);

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
   if(g_sslow[bar] == EMPTY_VALUE || g_sfast[bar] == EMPTY_VALUE ||
      BufTrend[bar] == EMPTY_VALUE)
   {
      g_last_processed_time = time[bar];
      return;
   }

   const double ss  = g_sslow[bar];
   const double sf  = g_sfast[bar];
   const double er  = g_er[bar];
   const double erf = g_erfast[bar];

   //--- 1) сырое направление по медленному окну (кандидат в тренд)
   int raw = 0;
   if(ss >= InpTrendEnterS && er >= InpEREnter)        raw = REGIME_UP;
   else if(ss <= -InpTrendEnterS && er <= -InpEREnter) raw = REGIME_DOWN;

   if(raw != 0 && raw == g_pending_dir) g_pending_cnt++;
   else if(raw != 0) { g_pending_dir = raw; g_pending_cnt = 1; }
   else              { g_pending_dir = 0;   g_pending_cnt = 0; }

   //--- 1а) импульс: короткое резкое движение признаётся трендом сразу
   int impulse = 0;
   if(InpImpulseEnable)
   {
      if(sf >= InpImpulseS && erf >= InpImpulseER)        impulse = REGIME_UP;
      else if(sf <= -InpImpulseS && erf <= -InpImpulseER) impulse = REGIME_DOWN;
   }

   //--- 1б) FIX3_2: быстрая дорожка разворота после зрелого тренда.
   // Медленное окно "помнит" старый тренд и разворот на нём опаздывает
   // на полокна. Если недавно был тренд (или мы ещё в нём), встречное
   // движение с ценой по ту сторону центральной линии признаётся
   // новым трендом по смягчённым порогам быстрого окна.
   int fasttrack = 0;
   if(InpReversalFastTrack)
   {
      const bool ctx_up = (g_regime == REGIME_UP ||
                           (g_last_trend_dir == REGIME_UP && g_bars_since_trend <= InpReversalWindowBars));
      const bool ctx_dn = (g_regime == REGIME_DOWN ||
                           (g_last_trend_dir == REGIME_DOWN && g_bars_since_trend <= InpReversalWindowBars));

      if(ctx_up && sf <= -InpReversalS && erf <= -InpReversalERF && close[bar] < BufTrend[bar])
         fasttrack = REGIME_DOWN;
      else if(ctx_dn && sf >= InpReversalS && erf >= InpReversalERF && close[bar] > BufTrend[bar])
         fasttrack = REGIME_UP;
   }

   //--- 2) выход из текущего трендового режима
   const int prev_regime = g_regime;

   // FIX3_3: пока зона моложе InpMinHoldBars, обычные выходы не работают -
   // перебить режим могут только дорожка разворота или импульс.
   const bool exits_armed = (g_regime_age >= InpMinHoldBars);

   // 2а: медленное окно потеряло значимость (гистерезис)
   if(exits_armed)
   {
      if(g_regime == REGIME_UP && ss < InpTrendExitS)    g_regime = REGIME_FLAT;
      if(g_regime == REGIME_DOWN && ss > -InpTrendExitS) g_regime = REGIME_FLAT;
   }

   // 2б: гашение - быстрое окно перестало подтверждать направление.
   // FIX3_2: закрытие за центральной линией против режима ускоряет гашение вдвое.
   if(exits_armed && g_regime != REGIME_FLAT)
   {
      const bool fast_supports = (g_regime == REGIME_UP ? sf > 0.0 : sf < 0.0);
      const bool price_against = (g_regime == REGIME_UP ? close[bar] < BufTrend[bar]
                                                        : close[bar] > BufTrend[bar]);
      if(!fast_supports) g_fade_cnt += (price_against ? 2 : 1);
      else               g_fade_cnt = 0;

      if(g_fade_cnt >= InpFadeExitBars)
         g_regime = REGIME_FLAT;
   }

   //--- 3) вход в новый трендовый режим
   // 3а: обычный путь через подтверждение медленным окном
   if(g_pending_cnt >= InpConfirmBars && g_pending_dir != 0 && g_regime != g_pending_dir)
      g_regime = g_pending_dir;

   // 3б: импульсный путь - без ожидания подтверждения
   if(impulse != 0 && g_regime != impulse)
      g_regime = impulse;

   // 3в: FIX3_2 - дорожка разворота (приоритет выше медленного пути,
   // так как срабатывает в контексте только что закончившегося тренда)
   if(fasttrack != 0 && g_regime != fasttrack)
      g_regime = fasttrack;

   if(g_regime == prev_regime) g_regime_age++;
   else                        { g_regime_age = 1; g_fade_cnt = 0; }

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

   //--- 4а) FIX3_2: память о последнем тренде для дорожки разворота
   if(g_regime != REGIME_FLAT)
   {
      g_last_trend_dir = g_regime;
      g_bars_since_trend = 0;
   }
   else if(g_bars_since_trend < 999999)
      g_bars_since_trend++;

   //--- 5) вход в начале тренда: быстрое окно + пробой, окно ожидания grace
   if(g_regime != REGIME_FLAT && g_entry_pending && g_open_dir == 0)
   {
      const bool fast_ok = (g_regime == REGIME_UP ? sf >= InpFastEnterS : sf <= -InpFastEnterS);
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
                   StringFormat("S%.1f/%.1f_ER%.2f", ss, sf, er), allow_alert);
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
                             (sf < InpFastExitS && g_curv_fast[bar] < 0.0) :
                             (sf > -InpFastExitS && g_curv_fast[bar] > 0.0));
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

   WriteDiagRow(time[bar], close[bar], ss, sf, er, erf, g_curv_fast[bar], "", RegimeToString(g_regime));
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
   g_fade_cnt = 0;
   g_last_trend_dir = 0;
   g_bars_since_trend = 999999;
   g_last_event = "RESET";
   g_last_event_time = 0;
}

//+------------------------------------------------------------------+
//| Жизненный цикл индикатора                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPeriodSlow < 10 || InpPeriodFast < 6 ||
      InpPeriodFast >= InpPeriodSlow ||
      (InpERPeriod != 0 && InpERPeriod < 5) ||
      InpDev <= 0.0 || InpTrendEnterS <= InpTrendExitS || InpTrendExitS < 0.0 ||
      InpFastEnterS <= InpFastExitS || InpFastExitS < 0.0 ||
      InpImpulseS < InpFastEnterS || InpImpulseER < 0.0 || InpImpulseER > 1.0 ||
      InpReversalS < InpFastExitS || InpReversalERF < 0.0 || InpReversalERF > 1.0 ||
      InpReversalWindowBars < 1 ||
      InpFadeExitBars < 1 || InpMinHoldBars < 1 ||
      InpConfirmBars < 1 || InpEntryGraceBars < 1 ||
      InpBreakoutLookback < 2 || InpExitDecelBars < 1 ||
      InpDiagMaxRowsPerRun < 100 || InpDiagFlushEveryRows < 1)
   {
      Print("MRC3 INIT ERROR: некорректные входные параметры (проверьте пороги и окна).");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_er_period = (InpERPeriod > 0 ? InpERPeriod : InpPeriodSlow);

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

   const int draw_begin = MathMax(InpPeriodSlow, MathMax(InpPeriodFast, g_er_period + 1));
   for(int plot = 0; plot < 7; plot++)
      PlotIndexSetInteger(plot, PLOT_DRAW_BEGIN, draw_begin);

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("Matrix Regime (%d/%d, S %.1f/%.1f, %s)",
                   InpPeriodSlow, InpPeriodFast, InpTrendEnterS, InpTrendExitS, MRC3_VERSION));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   if(!BuildProjection(InpPeriodSlow, g_proj_slow) ||
      !BuildProjection(InpPeriodFast, g_proj_fast))
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

   const int first_valid = MathMax(InpPeriodSlow - 1, MathMax(InpPeriodFast - 1, g_er_period));
   if(rates_total <= first_valid + 2)
      return 0;

   ArrayResize(g_sslow, rates_total);
   ArrayResize(g_sfast, rates_total);
   ArrayResize(g_er, rates_total);
   ArrayResize(g_erfast, rates_total);
   ArrayResize(g_curv_fast, rates_total);
   ArraySetAsSeries(g_sslow, false);
   ArraySetAsSeries(g_sfast, false);
   ArraySetAsSeries(g_er, false);
   ArraySetAsSeries(g_erfast, false);
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
      ArrayInitialize(g_sslow, EMPTY_VALUE);
      ArrayInitialize(g_sfast, EMPTY_VALUE);
      ArrayInitialize(g_er, EMPTY_VALUE);
      ArrayInitialize(g_erfast, EMPTY_VALUE);
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
      const bool ok_slow = RegressionAt(close, bar, InpPeriodSlow, g_proj_slow, slow);
      const bool ok_fast = RegressionAt(close, bar, InpPeriodFast, g_proj_fast, fast);

      if(!ok_slow || !ok_fast)
      {
         BufTrend[bar] = EMPTY_VALUE;
         BufUpper[bar] = EMPTY_VALUE;
         BufLower[bar] = EMPTY_VALUE;
         g_sslow[bar] = EMPTY_VALUE;
         g_sfast[bar] = EMPTY_VALUE;
         g_er[bar] = EMPTY_VALUE;
         g_erfast[bar] = EMPTY_VALUE;
         g_curv_fast[bar] = EMPTY_VALUE;
         continue;
      }

      BufTrend[bar] = slow.trend;
      BufUpper[bar] = slow.trend + InpDev * slow.sigma;
      BufLower[bar] = slow.trend - InpDev * slow.sigma;
      g_sslow[bar] = slow.smove;
      g_sfast[bar] = fast.smove;
      g_er[bar] = SignedERAt(close, bar, g_er_period);
      g_erfast[bar] = SignedERAt(close, bar, InpPeriodFast);
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
