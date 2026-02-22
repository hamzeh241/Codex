#property strict
#property description "V2: dynamic breakout lines and optional TP1-retest risk-free"

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
input double InpTPRangeMultiplier = 2.0;         // TP = multiplier * opening range
input double InpSLRangeMultiplier = 1.0;         // SL = multiplier * opening range
input double InpCancelRangeMultiplier = 2.0;     // Block direction if close exceeds this * opening range
input double InpPendingOffsetPips = 0.0;         // Pending offset from reference line (pips)
input bool InpUseNormalDirection = true;         // true=normal, false=swap buy/sell actions
input bool InpEnableSecondChanceRiskFree = false; // Enable TP1->entry->TP0.5 risk-free logic
input double InpTP1RangeMultiplier = 1.0;          // TP1 virtual target in opening-range multiples
input double InpTPHalfRangeMultiplier = 0.5;       // TP half virtual target in opening-range multiples
input bool InpEnableDirectRiskFree = false;       // Move SL to entry when price reaches custom TP multiplier
input double InpDirectRiskFreeTPMultiplier = 1.7; // Custom TP multiplier for direct risk-free

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
bool g_buyTradedToday = false;
bool g_sellTradedToday = false;
bool g_tpHitToday = false;
string g_lastActionInfo = "";
double g_dynamicBreakHigh = 0.0;
double g_dynamicBreakLow = 0.0;
string g_activeHighLineName = "";
string g_activeLowLineName = "";
ulong g_managedPositionTicket = 0;
bool g_tp1Reached = false;
bool g_entryRetested = false;
bool g_directRiskFreeDone = false;

CTrade g_trade;

void ProcessLondonOpenSetup();
void ManageOpenPositionRiskFree();
void UpdateDynamicLevelLines();
void NotifyDynamicShift(const datetime candleTime, const bool isHighShift, const double oldValue, const double newValue);
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
bool IsDirectionAvailable(const bool isBuyOrder);
bool IsBuyOrderForBreakout(const bool isUpBreakout);
string OrderSideLabel(const bool isBuyOrder);
bool HasOpenPositionOnSymbol(const string symbol);
bool HasPendingOrderOnSymbol(const string symbol);
datetime GetDayStart(const datetime value);
double GetPipSize();
bool IsSymbolAllowed(const string chartSymbol, const string allowedSymbols);
string NormalizeSymbolToken(const string value);
bool PlacePendingBySideAndPrice(const bool isBuyOrder, const double entryPrice, const double slPrice, const double tpPrice);

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

   ManageOpenPositionRiskFree();

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
   g_dynamicBreakHigh = refHigh;
   g_dynamicBreakLow = refLow;
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
   g_activeHighLineName = highName;
   g_activeLowLineName = lowName;

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
   g_buyTradedToday = false;
   g_sellTradedToday = false;
   g_tpHitToday = false;

   g_referenceReady = false;
   g_dynamicBreakHigh = 0.0;
   g_dynamicBreakLow = 0.0;
   g_activeHighLineName = "";
   g_activeLowLineName = "";
   g_managedPositionTicket = 0;
   g_tp1Reached = false;
   g_entryRetested = false;
   g_directRiskFreeDone = false;
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

   g_buyStoppedToday = false;
   g_sellStoppedToday = false;
   g_buyTradedToday = false;
   g_sellTradedToday = false;
   g_tpHitToday = false;

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

      ENUM_DEAL_ENTRY entryType = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);

      if(entryType == DEAL_ENTRY_IN)
      {
         if(dealType == DEAL_TYPE_BUY)
            g_buyTradedToday = true;
         else if(dealType == DEAL_TYPE_SELL)
            g_sellTradedToday = true;

         continue;
      }

      if(entryType != DEAL_ENTRY_OUT)
         continue;

      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
      if(reason == DEAL_REASON_SL)
      {
         if(dealType == DEAL_TYPE_SELL)
            g_buyStoppedToday = true;
         else if(dealType == DEAL_TYPE_BUY)
            g_sellStoppedToday = true;
      }
      else if(reason == DEAL_REASON_TP)
      {
         g_tpHitToday = true;
      }
   }

   if(g_tpHitToday)
   {
      CancelAllPendingOnSymbol();
      g_lastActionInfo = "tp hit today: trading blocked until next day";
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
   double barHigh = iHigh(_Symbol, InpTimeframe, 1);
   double barLow = iLow(_Symbol, InpTimeframe, 1);
   if(closePrice <= 0 || barHigh <= 0 || barLow <= 0)
      return;

   double prevHigh = g_dynamicBreakHigh;
   double prevLow = g_dynamicBreakLow;

   bool allowShiftUpdates = (!g_buyTradedToday && !g_sellTradedToday && !HasOpenPositionOnSymbol(_Symbol));

   if(allowShiftUpdates && barHigh > prevHigh && closePrice < prevHigh)
   {
      g_dynamicBreakHigh = barHigh;
      UpdateDynamicLevelLines();
      NotifyDynamicShift(closedBarTime, true, prevHigh, g_dynamicBreakHigh);
      g_lastActionInfo = "dynamic high moved up after false break";
   }

   if(allowShiftUpdates && barLow < prevLow && closePrice > prevLow)
   {
      g_dynamicBreakLow = barLow;
      UpdateDynamicLevelLines();
      NotifyDynamicShift(closedBarTime, false, prevLow, g_dynamicBreakLow);
      g_lastActionInfo = "dynamic low moved down after false break";
   }

   if(closePrice > g_dynamicBreakHigh)
   {
      DrawBreakoutArrow(closedBarTime, true);
      TryPlaceBreakoutPending(true);
   }
   else if(closePrice < g_dynamicBreakLow)
   {
      DrawBreakoutArrow(closedBarTime, false);
      TryPlaceBreakoutPending(false);
   }
}

void TryPlaceBreakoutPending(const bool isUpBreakout)
{
   bool isBuyOrder = IsBuyOrderForBreakout(isUpBreakout);
   string side = OrderSideLabel(isBuyOrder);

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

   if(!IsDirectionAvailable(isBuyOrder))
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

   double slPrice = isBuyOrder ? (entryPrice - slDistance) : (entryPrice + slDistance);
   double tpPrice = isBuyOrder ? (entryPrice + tpDistance) : (entryPrice - tpDistance);

   entryPrice = NormalizeDouble(entryPrice, digits);
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   bool placed = PlacePendingBySideAndPrice(isBuyOrder, entryPrice, slPrice, tpPrice);

   if(placed)
      g_lastActionInfo = side + " pending placed";
   else
      g_lastActionInfo = side + " order send failed";
}

bool PlacePendingBySideAndPrice(const bool isBuyOrder, const double entryPrice, const double slPrice, const double tpPrice)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return(false);

   if(isBuyOrder)
   {
      if(entryPrice <= bid)
         return(g_trade.BuyLimit(InpLots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "LondonOpen_BUY_LIMIT"));

      return(g_trade.BuyStop(InpLots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "LondonOpen_BUY_STOP"));
   }

   if(entryPrice >= ask)
      return(g_trade.SellLimit(InpLots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "LondonOpen_SELL_LIMIT"));

   return(g_trade.SellStop(InpLots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "LondonOpen_SELL_STOP"));
}

void UpdateDynamicLevelLines()
{
   if(g_activeHighLineName != "" && ObjectFind(0, g_activeHighLineName) >= 0)
      ObjectSetDouble(0, g_activeHighLineName, OBJPROP_PRICE, g_dynamicBreakHigh);

   if(g_activeLowLineName != "" && ObjectFind(0, g_activeLowLineName) >= 0)
      ObjectSetDouble(0, g_activeLowLineName, OBJPROP_PRICE, g_dynamicBreakLow);
}

void NotifyDynamicShift(const datetime candleTime, const bool isHighShift, const double oldValue, const double newValue)
{
   string side = isHighShift ? "HIGH" : "LOW";
   string name = g_prefix + "_SHIFT_" + side;

   ObjectDelete(0, name);

   string text = isHighShift ? "GREEN MOVED" : "RED MOVED";
   text += "\nOld: " + DoubleToString(oldValue, _Digits);
   text += "\nNew: " + DoubleToString(newValue, _Digits);
   text += "\nAt: " + TimeToString(candleTime, TIME_MINUTES);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0)
      point = 0.0001;

   double y = isHighShift ? (newValue + (20.0 * point)) : (newValue - (20.0 * point));

   ObjectCreate(0, name, OBJ_TEXT, 0, candleTime, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isHighShift ? InpHighLineColor : InpLowLineColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
}

void ManageOpenPositionRiskFree()
{
   if(!InpEnableSecondChanceRiskFree && !InpEnableDirectRiskFree)
      return;

   if(!PositionSelect(_Symbol))
   {
      g_managedPositionTicket = 0;
      g_tp1Reached = false;
      g_entryRetested = false;
      g_directRiskFreeDone = false;
      return;
   }

   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   if(ticket == 0)
      return;

   if(ticket != g_managedPositionTicket)
   {
      g_managedPositionTicket = ticket;
      g_tp1Reached = false;
      g_entryRetested = false;
      g_directRiskFreeDone = false;
   }

   double range = g_referenceHigh - g_referenceLow;
   if(range <= 0)
      return;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp1Distance = InpTP1RangeMultiplier * range;
   double tpHalfDistance = InpTPHalfRangeMultiplier * range;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(posType == POSITION_TYPE_BUY)
   {
      if(InpEnableDirectRiskFree && !g_directRiskFreeDone && bid >= (entry + (InpDirectRiskFreeTPMultiplier * range)))
      {
         if(sl < entry)
            g_trade.PositionModify(_Symbol, entry, PositionGetDouble(POSITION_TP));

         g_directRiskFreeDone = true;
         g_lastActionInfo = "direct risk-free set on BUY";
      }

      if(!g_tp1Reached && bid >= (entry + tp1Distance))
         g_tp1Reached = true;

      if(g_tp1Reached && !g_entryRetested && bid <= entry)
         g_entryRetested = true;

      if(g_tp1Reached && g_entryRetested && bid >= (entry + tpHalfDistance))
      {
         if(sl < entry)
            g_trade.PositionModify(_Symbol, entry, PositionGetDouble(POSITION_TP));

         g_lastActionInfo = "risk-free set on BUY after TP1->entry->TP0.5";
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      if(InpEnableDirectRiskFree && !g_directRiskFreeDone && ask <= (entry - (InpDirectRiskFreeTPMultiplier * range)))
      {
         if(sl > entry || sl == 0.0)
            g_trade.PositionModify(_Symbol, entry, PositionGetDouble(POSITION_TP));

         g_directRiskFreeDone = true;
         g_lastActionInfo = "direct risk-free set on SELL";
      }

      if(!g_tp1Reached && ask <= (entry - tp1Distance))
         g_tp1Reached = true;

      if(g_tp1Reached && !g_entryRetested && ask >= entry)
         g_entryRetested = true;

      if(g_tp1Reached && g_entryRetested && ask <= (entry - tpHalfDistance))
      {
         if(sl > entry || sl == 0.0)
            g_trade.PositionModify(_Symbol, entry, PositionGetDouble(POSITION_TP));

         g_lastActionInfo = "risk-free set on SELL after TP1->entry->TP0.5";
      }
   }
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
   msg += "Mode: " + (InpUseNormalDirection ? "NORMAL" : "REVERSED") + "\n";
   msg += "Day: " + IntegerToString(g_rulesDayOfYear) + "\n";
   msg += "Reference ready: " + (g_referenceReady ? "YES" : "NO") + "\n";
   msg += "Dynamic H/L: " + DoubleToString(g_dynamicBreakHigh, _Digits) + " / " + DoubleToString(g_dynamicBreakLow, _Digits) + "\n";
   msg += "Buy allowed: " + (IsDirectionAvailable(true) ? "YES" : "NO") + "\n";
   msg += "Sell allowed: " + (IsDirectionAvailable(false) ? "YES" : "NO") + "\n";
   msg += "Buy stop-hit today: " + (g_buyStoppedToday ? "YES" : "NO") + "\n";
   msg += "Sell stop-hit today: " + (g_sellStoppedToday ? "YES" : "NO") + "\n";
   msg += "Buy range-blocked: " + (g_buyBlockedByRangeToday ? "YES" : "NO") + "\n";
   msg += "Sell range-blocked: " + (g_sellBlockedByRangeToday ? "YES" : "NO") + "\n";
   msg += "Buy traded today: " + (g_buyTradedToday ? "YES" : "NO") + "\n";
   msg += "Sell traded today: " + (g_sellTradedToday ? "YES" : "NO") + "\n";
   msg += "TP hit today: " + (g_tpHitToday ? "YES" : "NO") + "\n";
   msg += "Open position exists: " + (HasOpenPositionOnSymbol(_Symbol) ? "YES" : "NO") + "\n";
   msg += "Pending exists: " + (HasPendingOrderOnSymbol(_Symbol) ? "YES" : "NO") + "\n";
   msg += "TP/SL/Cancel mult: " + DoubleToString(InpTPRangeMultiplier,2) + "/" + DoubleToString(InpSLRangeMultiplier,2) + "/" + DoubleToString(InpCancelRangeMultiplier,2) + "\n";
   msg += "Pending offset pips: " + DoubleToString(InpPendingOffsetPips,1) + "\n";
   msg += "RiskFree v2: " + (InpEnableSecondChanceRiskFree ? "ON" : "OFF") + ", TP1=" + DoubleToString(InpTP1RangeMultiplier,2) + ", TP0.5=" + DoubleToString(InpTPHalfRangeMultiplier,2) + "\n";
   msg += "Direct RF: " + (InpEnableDirectRiskFree ? "ON" : "OFF") + ", TP=" + DoubleToString(InpDirectRiskFreeTPMultiplier,2) + "\n";
   msg += "Last closed bar: " + TimeToString(closedBarTime, TIME_DATE|TIME_MINUTES) + "\n";
   msg += "Last action: " + g_lastActionInfo;

   Comment(msg);
}

bool IsBuyOrderForBreakout(const bool isUpBreakout)
{
   if(InpUseNormalDirection)
      return(isUpBreakout);

   return(!isUpBreakout);
}

string OrderSideLabel(const bool isBuyOrder)
{
   return(isBuyOrder ? "BUY" : "SELL");
}

bool IsDirectionAvailable(const bool isBuyOrder)
{
   if(g_tpHitToday)
      return(false);

   if(g_buyStoppedToday && g_sellStoppedToday)
      return(false);

   if(g_buyBlockedByRangeToday && g_sellBlockedByRangeToday)
      return(false);

   if(isBuyOrder && (g_buyStoppedToday || g_buyBlockedByRangeToday || g_buyTradedToday))
      return(false);

   if(!isBuyOrder && (g_sellStoppedToday || g_sellBlockedByRangeToday || g_sellTradedToday))
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
