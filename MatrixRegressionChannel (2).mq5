//+------------------------------------------------------------------+
//|                                      MatrixRegressionChannel.mq5 |
//|                               |
//+------------------------------------------------------------------+
#property copyright "AI Quantum Trader"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3

// Настройка отображения линий на графике
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

// Входные параметры индикатора
input int    InpPeriod = 60;      // Период расчета матрицы (N баров)
input double InpDev     = 2.0;     // Ширина канала (Коэффициент Сигма)

// Буферы индикатора для отрисовки графиков
double BufferTrend[];
double BufferUpper[];
double BufferLower[];

// Глобальные матрицы для предварительного расчета математического ядра
matrix matX;
matrix matXTX_inv_XT;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // Привязка массивов-буферов к графику
   SetIndexBuffer(0, BufferTrend, INDICATOR_DATA);
   SetIndexBuffer(1, BufferUpper, INDICATOR_DATA);
   SetIndexBuffer(2, BufferLower, INDICATOR_DATA);
   
   // Базовая проверка входящих настроек
   if(InpPeriod < 5)
   {
      Print("Ошибка: Период расчета слишком мал!");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // ПРЕДВЫЧИСЛЕНИЕ МАТРИЦЫ ПЛАНА (Оптимизация скорости вычислений)
   // Заполняем матрицу Вандермонда для параболы: y = w0 + w1*t + w2*t^2
   matX.Init(InpPeriod, 3);
   for(int i = 0; i < InpPeriod; i++)
   {
      double t = (double)i;
      matX[i, 0] = 1.0;       // Свободный член (t^0)
      matX[i, 1] = t;         // Линейный член (t^1)
      matX[i, 2] = t * t;     // Квадратичный член (t^2)
   }
   
   // Вычисляем компоненты псевдообратной матрицы
   matrix matXT = matX.Transpose();
   matrix matXTX = matXT.MatMul(matX);
   
   // Получаем инвертированную матрицу
   matrix matXTX_inv = matXTX.Inv();
   
   // Проверяем матрицу на вырожденность (проверка успешности инвертирования)
   if(matXTX_inv.Rows() == 0)
   {
      Print("Критическая ошибка: Матрица вырождена и не может быть инвертирована!");
      return(INIT_FAILED);
   }
   
   // Финальный оператор весов, который мы будем перемножать на вектор цен
   matXTX_inv_XT = matXTX_inv.MatMul(matXT);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
   // Проверяем, достаточно ли баров в истории для расчета матрицы
   if(rates_total < InpPeriod) return(0);

   // Оптимизация: пересчитываем только новые или изменившиеся бары
   int start = prev_calculated - 1;
   if(start < InpPeriod) start = InpPeriod;

   // Главный цикл расчета по историческим барам
   for(int bar = start; bar < rates_total; bar++)
   {
      // 1. Создаем и заполняем вектор цен закрытия Y для текущего окна истории
      vector vecY;
      vecY.Init(InpPeriod);
      
      int start_idx = bar - InpPeriod + 1;
      for(int i = 0; i < InpPeriod; i++)
      {
         vecY[i] = close[start_idx + i];
      }
      
      // 2. Рассчитываем веса полинома через матричное умножение: W = ((X^T*X)^-1 * X^T) * Y
      vector vecW = matXTX_inv_XT.MatMul(vecY);
      
      // 3. Вычисляем значение тренда для текущей крайней точки (конец скользящего окна)
      double t_curr = (double)(InpPeriod - 1);
      double trend_val = vecW[0] + vecW[1] * t_curr + vecW[2] * t_curr * t_curr;
      BufferTrend[bar] = trend_val;
      
      // 4. Расчет среднеквадратичного отклонения (сигмы) внутри текущего окна матрицы
      double sum_sq_error = 0;
      for(int i = 0; i < InpPeriod; i++)
      {
         double t = (double)i;
         double model_val = vecW[0] + vecW[1] * t + vecW[2] * t * t;
         double error = vecY[i] - model_val;
         sum_sq_error += error * error;
      }
      double sigma = MathSqrt(sum_sq_error / InpPeriod);
      
      // 5. Динамически выставляем верхнюю и нижнюю границы канала регрессии
      BufferUpper[bar] = trend_val + (InpDev * sigma);
      BufferLower[bar] = trend_val - (InpDev * sigma);
   }

   // Возвращаем количество обработанных баров для оптимизации следующего тика
   return(rates_total);
}
//+------------------------------------------------------------------+
