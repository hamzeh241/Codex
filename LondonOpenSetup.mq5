#property strict
#property description "Marks London-open levels and manages breakout pending orders"

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M15; // Strategy timeframe
input int InpLondonOpenHour = 11;                // Broker hour for London open
input int InpLondonOpenMinute = 30;              // Broker minute for London open
input string InpAllowedSymbols = "XAUUSD,US30,USDJPY,AUDJPY"; // Comma separated symbol roots
input color InpHighLineColor = clrLimeGreen;     // High level color
input color InpLowLineColor = clrTomato;         // Low level color
input color InpVerticalColor = clrDodgerBlue;    // Candle time markers color
input ENUM_LINE_STYLE InpLineStyle = STYLE_SOLID;
input int InpLineWidth = 1;
input color InpBreakoutUpColor = clrLime;        // Breakout up arrow color
input color InpBreakoutDownColor = clrRed;       // Breakout down arrow color
input int InpBreakoutArrowSize = 1;              // Arrow line width
input double InpLots = 0.10;                     // Fixed lot size
input long InpMagicNumber = 30001;               // EA magic number
input double InpTPRangeMultiplier = 2.0;          // TP = multiplier * opening range
input double InpSLRangeMultiplier = 1.0;          // SL distance multiplier from entry to opposite range
input double InpCancelRangeMultiplier = 2.0;      // Block direction if close exceeds this * opening range
input double InpPendingOffsetPips = 0.0;          // Pending offset from reference line (pips)

string g_prefix;
datetime g_lastProcessedBar = 0;
int g_referenceDayOfYear = -1;
int g_rulesDayOfYear = -1;
double g_referenceHigh = 0.0;
double g_referenceLow = 0.0;
bool g_referenceReady = false;
bool g_buyStoppedToday = false;
bool g_sellStoppedToday = false;
bool g_buyBlockedByRangeToday = false;
bool g_sellBlockedByRangeToday = false;
string g_lastActionInfo = "";

CTrade g_trade;

void ProcessLondonOpenSetup();
void DrawLevels(const datetime refCandleTime, const double highPrice, const double lowPrice);
void DrawVerticalMarkers(const datetime refCandleTime);
void DrawBreakoutArrow(const datetime candleTime, const bool isUpBreakout);
void CheckBreakoutOnClosedBar(const datetime closedBarTime, const MqlDateTime &closedBarStruct);
void TryPlaceBreakoutPending(const bool isUpBreakout);
void UpdateDailyRules(const datetime closedBarTime, const MqlDateTime &closedBarStruct);
void ResetDailyRules(const int dayOfYear);
void UpdateStopFlagsFromHistory(const datetime dayStart);
void UpdateRangeBlocksByClose(const double closePrice);
void CancelAllPendingOnSymbol();
void CancelPendingByDirection(const bool isBuyDirection);
void DeleteAllStrategyObjects();
void UpdateStatusPanel(const datetime closedBarTime);
bool IsDirectionAvailable(const bool isUpBreakout);
bool HasOpenPositionOnSymbol(const string symbol);
bool HasPendingOrderOnSymbol(const string symbol);
bool CanPlaceNewOrder();
datetime GetDayStart(const datetime value);
bool IsSymbolAllowed(const string chartSymbol, const string allowedSymbols);
string NormalizeSymbolToken(const string value);
double GetPipSize();

int OnInit()
{
   g_prefix = StringFormat("LondonOpen_%s_%d", _Symbol, (int)InpTimeframe);
   g_trade.SetExpertMagicNumber(InpMagicNumber);
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

   UpdateDailyRules(closedBarTime, closedBarStruct);
   CheckBreakoutOnClosedBar(closedBarTime, closedBarStruct);

   if(closedBarStruct.hour != InpLondonOpenHour || closedBarStruct.min != InpLondonOpenMinute)
   {
      UpdateStatusPanel(closedBarTime);
      return;
   }

   if(closedBarStruct.day_of_year == g_referenceDayOfYear)
   {
      UpdateStatusPanel(closedBarTime);
      return;
   }

   const double refHigh = iHigh(_Symbol, InpTimeframe, 1);
   const double refLow = iLow(_Symbol, InpTimeframe, 1);
   if(refHigh <= 0 || refLow <= 0 || refHigh <= refLow)
   {
      g_lastActionInfo = "invalid opening candle range";
      UpdateStatusPanel(closedBarTime);
      return;
   }

   DrawLevels(closedBarTime, refHigh, refLow);
   DrawVerticalMarkers(closedBarTime);

   g_referenceHigh = refHigh;
   g_referenceLow = refLow;
   g_referenceReady = true;
   g_referenceDayOfYear = closedBarStruct.day_of_year;
   g_lastActionInfo = "opening candle captured";
   UpdateStatusPanel(closedBarTime);
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

void UpdateDailyRules(const datetime closedBarTime, const MqlDateTime &closedBarStruct)
{
   if(g_rulesDayOfYear != closedBarStruct.day_of_year)
      ResetDailyRules(closedBarStruct.day_of_year);

   datetime dayStart = GetDayStart(closedBarTime);
   if(dayStart > 0)
      UpdateStopFlagsFromHistory(dayStart);

   if(g_referenceReady && g_referenceDayOfYear == closedBarStruct.day_of_year)
   {
      double closePrice = iClose(_Symbol, InpTimeframe, 1);
      if(closePrice > 0)
         UpdateRangeBlocksByClose(closePrice);
   }
}

void ResetDailyRules(const int dayOfYear)
{
   g_rulesDayOfYear = dayOfYear;

   g_buyStoppedToday = false;
   g_sellStoppedToday = false;
   g_buyBlockedByRangeToday = false;
   g_sellBlockedByRangeToday = false;

   g_referenceReady = false;
   g_referenceDayOfYear = -1;
   g_referenceHigh = 0.0;
   g_referenceLow = 0.0;

   CancelAllPendingOnSymbol();
   DeleteAllStrategyObjects();
   g_lastActionInfo = "new day reset: pending/orders/lines cleaned";
}

void UpdateStopFlagsFromHistory(const datetime dayStart)
{
   if(!HistorySelect(dayStart, TimeCurrent()))
      return;

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;

      if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber)
         continue;

      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      if((ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON) != DEAL_REASON_SL)
         continue;

      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      if(dealType == DEAL_TYPE_SELL)
         g_buyStoppedToday = true;   // buy position stopped out
      else if(dealType == DEAL_TYPE_BUY)
         g_sellStoppedToday = true;  // sell position stopped out

      if(g_buyStoppedToday && g_sellStoppedToday)
         break;
   }
}

void UpdateRangeBlocksByClose(const double closePrice)
{
   double range = g_referenceHigh - g_referenceLow;
   if(range <= 0)
      return;

   double buyLimitClose = g_referenceHigh + (InpCancelRangeMultiplier * range);
   double sellLimitClose = g_referenceLow - (InpCancelRangeMultiplier * range);

   if(closePrice > buyLimitClose)
   {
      g_buyBlockedByRangeToday = true;
      CancelPendingByDirection(true);
      g_lastActionInfo = "buy blocked: close > green + cancel-mult range";
   }

   if(closePrice < sellLimitClose)
   {
      g_sellBlockedByRangeToday = true;
      CancelPendingByDirection(false);
      g_lastActionInfo = "sell blocked: close < red - cancel-mult range";
   }
}

void CheckBreakoutOnClosedBar(const datetime closedBarTime, const MqlDateTime &closedBarStruct)
{
   if(!g_referenceReady)
      return;

   if(closedBarStruct.day_of_year != g_referenceDayOfYear)
      return;

   double closePrice = iClose(_Symbol, InpTimeframe, 1);
   if(closePrice <= 0)
      return;

   if(closePrice > g_referenceHigh)
   {
      DrawBreakoutArrow(closedBarTime, true);
      TryPlaceBreakoutPending(true);
   }
   else if(closePrice < g_referenceLow)
   {
      DrawBreakoutArrow(closedBarTime, false);
      TryPlaceBreakoutPending(false);
   }
}

void TryPlaceBreakoutPending(const bool isUpBreakout)
{
   string side = isUpBreakout ? "BUY" : "SELL";

   if(HasOpenPositionOnSymbol(_Symbol))
   {
      g_lastActionInfo = side + " blocked: open position exists";
      return;
   }

   if(HasPendingOrderOnSymbol(_Symbol))
   {
      g_lastActionInfo = side + " blocked: pending order exists";
      return;
   }

   if(!IsDirectionAvailable(isUpBreakout))
   {
      g_lastActionInfo = side + " blocked by daily rules";
      return;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double range = g_referenceHigh - g_referenceLow;
   if(range <= 0)
   {
      g_lastActionInfo = side + " blocked: invalid range";
      return;
   }

   double pipSize = GetPipSize();
   double offset = InpPendingOffsetPips * pipSize;

   double entryPrice = isUpBreakout ? (g_referenceHigh + offset) : (g_referenceLow - offset);
   double slDistance = InpSLRangeMultiplier * range;
   double tpDistance = InpTPRangeMultiplier * range;

   double slPrice = isUpBreakout ? (entryPrice - slDistance) : (entryPrice + slDistance);
   double tpPrice = isUpBreakout ? (entryPrice + tpDistance) : (entryPrice - tpDistance);

   entryPrice = NormalizeDouble(entryPrice, digits);
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   bool placed = false;
   if(isUpBreakout)
      placed = g_trade.BuyLimit(InpLots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "LondonOpen_BUY");
   else
      placed = g_trade.SellLimit(InpLots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "LondonOpen_SELL");

   if(placed)
      g_lastActionInfo = side + " pending placed";
   else
      g_lastActionInfo = side + " order send failed";
}

void DrawBreakoutArrow(const datetime candleTime, const bool isUpBreakout)
{
   string side = isUpBreakout ? "UP" : "DOWN";
   string arrowName = g_prefix + "_BRK_" + side + "_" + IntegerToString((int)candleTime);

   if(ObjectFind(0, arrowName) >= 0)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0)
      point = 0.0001;

   double price = isUpBreakout ? iHigh(_Symbol, InpTimeframe, 1) + (point * 20.0)
                               : iLow(_Symbol, InpTimeframe, 1) - (point * 20.0);

   int arrowCode = isUpBreakout ? 233 : 234;
   color arrowColor = isUpBreakout ? InpBreakoutUpColor : InpBreakoutDownColor;

   ObjectCreate(0, arrowName, OBJ_ARROW, 0, candleTime, price);
   ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, arrowCode);
   ObjectSetInteger(0, arrowName, OBJPROP_COLOR, arrowColor);
   ObjectSetInteger(0, arrowName, OBJPROP_WIDTH, InpBreakoutArrowSize);
}

void CancelAllPendingOnSymbol()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_STOP_LIMIT || type == ORDER_TYPE_SELL_STOP_LIMIT)
      {
         g_trade.OrderDelete(ticket);
      }
   }
}

void CancelPendingByDirection(const bool isBuyDirection)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isBuyType = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool isSellType = (type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT);

      if((isBuyDirection && isBuyType) || (!isBuyDirection && isSellType))
         g_trade.OrderDelete(ticket);
   }
}


void DeleteAllStrategyObjects()
{
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, g_prefix) == 0)
         ObjectDelete(0, name);
   }
}

void UpdateStatusPanel(const datetime closedBarTime)
{
   string msg;
   msg += "LondonOpen EA status\n";
   msg += "Symbol: " + _Symbol + "\n";
   msg += "TF: " + EnumToString(InpTimeframe) + "\n";
   msg += "Day: " + IntegerToString(g_rulesDayOfYear) + "\n";
   msg += "Reference ready: " + (g_referenceReady ? "YES" : "NO") + "\n";
   msg += "Buy allowed: " + (IsDirectionAvailable(true) ? "YES" : "NO") + "\n";
   msg += "Sell allowed: " + (IsDirectionAvailable(false) ? "YES" : "NO") + "\n";
   msg += "Buy stop-hit today: " + (g_buyStoppedToday ? "YES" : "NO") + "\n";
   msg += "Sell stop-hit today: " + (g_sellStoppedToday ? "YES" : "NO") + "\n";
   msg += "Buy range-blocked: " + (g_buyBlockedByRangeToday ? "YES" : "NO") + "\n";
   msg += "Sell range-blocked: " + (g_sellBlockedByRangeToday ? "YES" : "NO") + "\n";
   msg += "Open position exists: " + (HasOpenPositionOnSymbol(_Symbol) ? "YES" : "NO") + "\n";
   msg += "Pending exists: " + (HasPendingOrderOnSymbol(_Symbol) ? "YES" : "NO") + "\n";
   msg += "TP/SL/Cancel mult: " + DoubleToString(InpTPRangeMultiplier,2) + "/" + DoubleToString(InpSLRangeMultiplier,2) + "/" + DoubleToString(InpCancelRangeMultiplier,2) + "\n";
   msg += "Pending offset pips: " + DoubleToString(InpPendingOffsetPips,1) + "\n";
   msg += "Last closed bar: " + TimeToString(closedBarTime, TIME_DATE|TIME_MINUTES) + "\n";
   msg += "Last action: " + g_lastActionInfo;

   Comment(msg);
}

bool IsDirectionAvailable(const bool isUpBreakout)
{
   if(g_buyStoppedToday && g_sellStoppedToday)
      return(false);

   if(g_buyBlockedByRangeToday && g_sellBlockedByRangeToday)
      return(false);

   if(isUpBreakout && (g_buyStoppedToday || g_buyBlockedByRangeToday))
      return(false);

   if(!isUpBreakout && (g_sellStoppedToday || g_sellBlockedByRangeToday))
      return(false);

   return(true);
}

bool HasOpenPositionOnSymbol(const string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == symbol)
         return(true);
   }

   return(false);
}

bool HasPendingOrderOnSymbol(const string symbol)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != symbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP  || type == ORDER_TYPE_SELL_STOP  ||
         type == ORDER_TYPE_BUY_STOP_LIMIT || type == ORDER_TYPE_SELL_STOP_LIMIT)
      {
         return(true);
      }
   }

   return(false);
}

bool CanPlaceNewOrder()
{
   if(HasOpenPositionOnSymbol(_Symbol))
      return(false);

   if(HasPendingOrderOnSymbol(_Symbol))
      return(false);

   return(true);
}

datetime GetDayStart(const datetime value)
{
   MqlDateTime dt;
   TimeToStruct(value, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return(StructToTime(dt));
}


double GetPipSize()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(digits == 3 || digits == 5)
      return(point * 10.0);

   return(point);
}

string NormalizeSymbolToken(const string value)
{
   string text = value;
   StringTrimLeft(text);
   StringTrimRight(text);
   StringToUpper(text);
   return(text);
}

bool IsSymbolAllowed(const string chartSymbol, const string allowedSymbols)
{
   string current = NormalizeSymbolToken(chartSymbol);
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
      string token = NormalizeSymbolToken(symbols[i]);
      if(token == "")
         continue;

      if(current == token)
         return(true);

      if(StringFind(current, token) == 0)
         return(true);
   }

   return(false);
}
