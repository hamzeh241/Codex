#property strict
#property description "Marks the London-open reference candle high/low after close"

input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M15; // Strategy timeframe
input int InpLondonOpenHour = 11;                // Broker hour for London open
input int InpLondonOpenMinute = 30;              // Broker minute for London open
input string InpAllowedSymbols = "XAUUSD,US30,USDJPY,AUDJPY"; // Comma separated symbol roots
input color InpHighLineColor = clrLimeGreen;     // High level color
input color InpLowLineColor = clrTomato;         // Low level color
input color InpVerticalColor = clrDodgerBlue;    // Candle time markers color
input ENUM_LINE_STYLE InpLineStyle = STYLE_SOLID;
input int InpLineWidth = 1;

string g_prefix;
datetime g_lastProcessedBar = 0;
int g_lastProcessedDayOfYear = -1;

int OnInit()
{
   g_prefix = StringFormat("LondonOpen_%s_%d", _Symbol, (int)InpTimeframe);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   ProcessLondonOpenSetup();
}

void OnTick()
{
   ProcessLondonOpenSetup();
}

void ProcessLondonOpenSetup()
{
   if(!IsSymbolAllowed(_Symbol, InpAllowedSymbols))
      return;

   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime <= 0)
      return;

   if(currentBarTime == g_lastProcessedBar)
      return;

   g_lastProcessedBar = currentBarTime;

   datetime closedBarTime = iTime(_Symbol, InpTimeframe, 1);
   if(closedBarTime <= 0)
      return;

   MqlDateTime closedBarStruct;
   TimeToStruct(closedBarTime, closedBarStruct);

   if(closedBarStruct.hour != InpLondonOpenHour || closedBarStruct.min != InpLondonOpenMinute)
      return;

   if(closedBarStruct.day_of_year == g_lastProcessedDayOfYear)
      return;

   const double refHigh = iHigh(_Symbol, InpTimeframe, 1);
   const double refLow = iLow(_Symbol, InpTimeframe, 1);
   if(refHigh <= 0 || refLow <= 0)
      return;

   DrawLevels(closedBarTime, refHigh, refLow);
   DrawVerticalMarkers(closedBarTime);

   g_lastProcessedDayOfYear = closedBarStruct.day_of_year;
}

void DrawLevels(const datetime refCandleTime, const double highPrice, const double lowPrice)
{
   string dayKey = TimeToString(refCandleTime, TIME_DATE);

   string highName = g_prefix + "_HIGH_" + dayKey;
   string lowName = g_prefix + "_LOW_" + dayKey;

   ObjectDelete(0, highName);
   ObjectDelete(0, lowName);

   ObjectCreate(0, highName, OBJ_HLINE, 0, 0, highPrice);
   ObjectSetInteger(0, highName, OBJPROP_COLOR, InpHighLineColor);
   ObjectSetInteger(0, highName, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, highName, OBJPROP_WIDTH, InpLineWidth);

   ObjectCreate(0, lowName, OBJ_HLINE, 0, 0, lowPrice);
   ObjectSetInteger(0, lowName, OBJPROP_COLOR, InpLowLineColor);
   ObjectSetInteger(0, lowName, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, lowName, OBJPROP_WIDTH, InpLineWidth);
}

void DrawVerticalMarkers(const datetime refCandleTime)
{
   datetime candleEndTime = refCandleTime + PeriodSeconds(InpTimeframe);
   string dayKey = TimeToString(refCandleTime, TIME_DATE);

   string openMark = g_prefix + "_OPEN_" + dayKey;
   string closeMark = g_prefix + "_CLOSE_" + dayKey;

   ObjectDelete(0, openMark);
   ObjectDelete(0, closeMark);

   ObjectCreate(0, openMark, OBJ_VLINE, 0, refCandleTime, 0);
   ObjectSetInteger(0, openMark, OBJPROP_COLOR, InpVerticalColor);
   ObjectSetInteger(0, openMark, OBJPROP_STYLE, STYLE_DOT);

   ObjectCreate(0, closeMark, OBJ_VLINE, 0, candleEndTime, 0);
   ObjectSetInteger(0, closeMark, OBJPROP_COLOR, InpVerticalColor);
   ObjectSetInteger(0, closeMark, OBJPROP_STYLE, STYLE_DOT);
}

bool IsSymbolAllowed(const string chartSymbol, const string allowedSymbols)
{
   string current = StringUpper(StringTrim(chartSymbol));
   if(current == "")
      return(false);

   string normalizedList = allowedSymbols;
   StringReplace(normalizedList, ";", ",");

   string symbols[];
   int count = StringSplit(normalizedList, ',', symbols);
   if(count <= 0)
      return(true);

   for(int i = 0; i < count; i++)
   {
      string token = StringUpper(StringTrim(symbols[i]));
      if(token == "")
         continue;

      if(current == token)
         return(true);

      if(StringFind(current, token) == 0)
         return(true);
   }

   return(false);
}
