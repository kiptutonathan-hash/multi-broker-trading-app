
//+------------------------------------------------------------------+
//|                  NATHAN FOREX BOT V1.0                           |
//|             Supply & Demand + MSS Confirmation                   |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "Nathan Forex Bot - Demo testing version"

#include <Trade/Trade.mqh>

CTrade trade;

//---- Trading settings
input double RiskPercent       = 0.5;
input double RewardRiskRatio   = 2.0;
input int    LookbackBars      = 40;
input int    SwingBars         = 5;
input int    ATRPeriod         = 14;
input double ATRBuffer         = 0.20;
input int    MaxSpreadPoints   = 50;
input ulong  MagicNumber       = 20261031;

//---- Internal variables
int atrHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   atrHandle = iATR(_Symbol, PERIOD_M15, ATRPeriod);

   if(atrHandle == INVALID_HANDLE)
   {
      Print("ATR initialization failed.");
      return INIT_FAILED;
   }

   Print("Nathan Forex Bot initialized. Demo testing only.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Only evaluate once per new M15 candle
   datetime currentBar = iTime(_Symbol, PERIOD_M15, 0);

   if(currentBar == 0 || currentBar == lastBarTime)
      return;

   lastBarTime = currentBar;

   // Avoid opening multiple positions on this symbol
   if(PositionSelect(_Symbol))
   {
      if((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double spread = (tick.ask - tick.bid) / _Point;

   if(spread > MaxSpreadPoints)
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int needed = LookbackBars + SwingBars + 10;

   if(CopyRates(_Symbol, PERIOD_M15, 0, needed, rates) < needed)
      return;

   double atr[];
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(atrHandle, 0, 1, 1, atr) < 1)
      return;

   if(atr[0] <= 0)
      return;

   double zoneLow = 0;
   double zoneHigh = 0;

   bool buySignal = false;
   bool sellSignal = false;

   // Find demand zone with bullish MSS and retest
   buySignal = FindDemandSetup(rates, needed, zoneLow, zoneHigh);

   // Find supply zone with bearish MSS and retest
   if(!buySignal)
      sellSignal = FindSupplySetup(rates, needed, zoneLow, zoneHigh);

   if(buySignal)
      OpenTrade(ORDER_TYPE_BUY, zoneLow, zoneHigh, atr[0]);

   else if(sellSignal)
      OpenTrade(ORDER_TYPE_SELL, zoneLow, zoneHigh, atr[0]);
}

//+------------------------------------------------------------------+
//| Find demand zone + bullish structure break + retest              |
//+------------------------------------------------------------------+
bool FindDemandSetup(MqlRates &r[], int total,
                     double &zLow, double &zHigh)
{
   for(int i = 3; i < LookbackBars; i++)
   {
      if(i + SwingBars >= total)
         break;

      // Demand zone: last bearish candle
      if(r[i].close >= r[i].open)
         continue;

      double previousHigh = r[i+1].high;

      for(int k = i+2; k <= i+SwingBars; k++)
         previousHigh = MathMax(previousHigh, r[k].high);

      bool structureBreak = false;

      // A newer candle must close above the previous swing high
      for(int j = 2; j < i; j++)
      {
         if(r[j].close > previousHigh)
         {
            structureBreak = true;
            break;
         }
      }

      if(!structureBreak)
         continue;

      // Latest closed candle must retest and reject the zone
      bool touched = (r[1].low <= r[i].high &&
                      r[1].high >= r[i].low);

      bool bullishConfirmation =
         (r[1].close > r[1].open &&
          r[1].close > r[i].high);

      if(touched && bullishConfirmation)
      {
         zLow = r[i].low;
         zHigh = r[i].high;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Find supply zone + bearish structure break + retest              |
//+------------------------------------------------------------------+
bool FindSupplySetup(MqlRates &r[], int total,
                     double &zLow, double &zHigh)
{
   for(int i = 3; i < LookbackBars; i++)
   {
      if(i + SwingBars >= total)
         break;

      // Supply zone: last bullish candle
      if(r[i].close <= r[i].open)
         continue;

      double previousLow = r[i+1].low;

      for(int k = i+2; k <= i+SwingBars; k++)
         previousLow = MathMin(previousLow, r[k].low);

      bool structureBreak = false;

      // A newer candle must close below the previous swing low
      for(int j = 2; j < i; j++)
      {
         if(r[j].close < previousLow)
         {
            structureBreak = true;
            break;
         }
      }

      if(!structureBreak)
         continue;

      // Latest closed candle must retest and reject the zone
      bool touched = (r[1].high >= r[i].low &&
                      r[1].low <= r[i].high);

      bool bearishConfirmation =
         (r[1].close < r[1].open &&
          r[1].close < r[i].low);

      if(touched && bearishConfirmation)
      {
         zLow = r[i].low;
         zHigh = r[i].high;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Calculate volume using account risk                              |
//+------------------------------------------------------------------+
double CalculateVolume(double entry, double stopLoss)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * RiskPercent / 100.0;

   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double tickValue =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   double minLot =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double maxLot =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lotStep =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double distance = MathAbs(entry - stopLoss);

   if(tickSize <= 0 || tickValue <= 0 ||
      distance <= 0 || lotStep <= 0)
      return 0;

   double riskPerLot = (distance / tickSize) * tickValue;

   if(riskPerLot <= 0)
      return 0;

   double volume = riskMoney / riskPerLot;

   // Never round volume up beyond the risk budget
   volume = MathFloor(volume / lotStep) * lotStep;

   if(volume < minLot)
      return 0;

   volume = MathMin(volume, maxLot);

   int digits = 0;
   double step = lotStep;

   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }

   return NormalizeDouble(volume, digits);
}

//+------------------------------------------------------------------+
//| Open a trade with automatic SL and TP                            |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE orderType,
               double zoneLow,
               double zoneHigh,
               double atrValue)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double entry, sl, tp;

   if(orderType == ORDER_TYPE_BUY)
   {
      entry = tick.ask;
      sl = zoneLow - (atrValue * ATRBuffer);

      if(sl >= entry)
         return;

      tp = entry + ((entry - sl) * RewardRiskRatio);
   }
   else
   {
      entry = tick.bid;
      sl = zoneHigh + (atrValue * ATRBuffer);

      if(sl <= entry)
         return;

      tp = entry - ((sl - entry) * RewardRiskRatio);
   }

   int digits = (int)SymbolInfoInteger(_Symbol,
                                       SYMBOL_DIGITS);

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double volume = CalculateVolume(entry, sl);

   if(volume <= 0)
   {
      Print("Trade skipped: minimum lot exceeds risk budget.");
      return;
   }

   bool result = false;

   if(orderType == ORDER_TYPE_BUY)
   {
      result = trade.Buy(volume, _Symbol, 0, sl, tp,
                         "Nathan Forex Bot BUY");
   }
   else
   {
      result = trade.Sell(volume, _Symbol, 0, sl, tp,
                          "Nathan Forex Bot SELL");
   }

   if(result)
      Print("Nathan Forex Bot: trade request sent. ",
            trade.ResultRetcodeDescription());
   else
      Print("Trade failed: ", trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
