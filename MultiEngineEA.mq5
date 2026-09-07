#property strict
#property version   "1.00"
#property description "XAUUSD M1/H1 institutional-style scoring scalper"

#include <Trade/Trade.mqh>
#include "EntryEngine.mqh"

// -------------------- Inputs --------------------
input group "Money Management"
input double InpBaseCapital       = 5.0;    // USD base for lot scaling
input double InpBaseLot           = 0.01;   // lot per base capital
input double InpTargetProfitPerLot= 200.0;  // USD target per 1.00 lot
input int    InpMaxLayers          = 1;      // max open positions for this EA/symbol

input group "Entry & Strategy"
input ENUM_TIMEFRAMES InpHTF       = PERIOD_H1;
input ENUM_TIMEFRAMES InpLTF       = PERIOD_M1;
input int    InpEMAPeriodFast      = 50;
input int    InpEMAPeriodSlow      = 200;
input int    InpRSIPeriod          = 14;
input double InpRSIUpper           = 65.0;
input double InpRSILower           = 35.0;
input int    InpMinSignalScore     = 7;

input group "Risk & Dynamic Exit"
input int    InpATRPeriod          = 14;
input double InpATRSafetyMultiplier= 1.5;
input int    InpBreakEvenPoints    = 50;
input int    InpMaxSpreadPoints    = 30;

input group "Execution"
input ulong  InpMagic              = 20260907;
input int    InpDeviationPoints    = 20;
input bool   InpRequireNewBar      = true;

CTrade trade;
CEntryEngine EntryEngine;
int g_atr_handle=INVALID_HANDLE;
datetime g_last_ltf_bar=0;

// -------------------- Helpers --------------------
double NormalizeVolume(double volume)
{
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0) return 0.0;
   volume=MathMax(vmin,MathMin(vmax,volume));
   volume=MathFloor(volume/step+1e-9)*step;
   if(volume<vmin) volume=vmin;
   return NormalizeDouble(volume,8);
}

double CalculateDynamicLot()
{
   if(InpBaseCapital<=0.0 || InpBaseLot<=0.0) return 0.0;
   double calculatedLot=(AccountInfoDouble(ACCOUNT_BALANCE)/InpBaseCapital)*InpBaseLot;
   return NormalizeVolume(calculatedLot);
}

double GetTargetProfitMoney(double currentLots)
{
   return MathMax(0.0,currentLots)*InpTargetProfitPerLot;
}

int CountOurPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      count++;
   }
   return count;
}

bool GetOurFloatingTotals(double &profit,double &lots)
{
   profit=0.0; lots=0.0;
   bool found=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      profit += PositionGetDouble(POSITION_PROFIT);
      profit += PositionGetDouble(POSITION_SWAP);
      // Commission is not exposed as POSITION_COMMISSION on all MT5 builds.
      // Deal-history commission is therefore not double-counted here.
      lots += PositionGetDouble(POSITION_VOLUME);
      found=true;
   }
   return found;
}

bool CloseAllPositions()
{
   bool all_ok=true;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      ResetLastError();
      if(!trade.PositionClose(ticket))
      {
         all_ok=false;
         PrintFormat("Close failed ticket=%I64u retcode=%u desc=%s lastError=%d",
                     ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription(),GetLastError());
      }
   }
   return all_ok;
}

bool CheckAndCloseByProfitTarget()
{
   double profit=0.0,lots=0.0;
   if(!GetOurFloatingTotals(profit,lots) || lots<=0.0) return false;
   double target=GetTargetProfitMoney(lots);
   if(target>0.0 && profit>=target)
   {
      PrintFormat("Profit target reached: profit=%.2f target=%.2f lots=%.2f",profit,target,lots);
      CloseAllPositions();
      return true;
   }
   return false;
}

bool GetATR(double &atr)
{
   atr=0.0;
   if(g_atr_handle==INVALID_HANDLE) return false;
   double buf[1];
   if(CopyBuffer(g_atr_handle,0,1,1,buf)!=1) return false;
   atr=buf[0];
   return atr>0.0;
}

bool IsNewLTFBar()
{
   datetime current=iTime(_Symbol,InpLTF,0);
   if(current<=0) return false;
   if(current!=g_last_ltf_bar)
   {
      g_last_ltf_bar=current;
      return true;
   }
   return false;
}

bool SpreadOK()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   double spread_points=(tick.ask-tick.bid)/_Point;
   return spread_points<=InpMaxSpreadPoints;
}

bool StopsAreValid(ENUM_ORDER_TYPE type,double entry,double sl)
{
   long stops_level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double min_dist=MathMax((double)stops_level,(double)freeze_level)*_Point;
   if(type==ORDER_TYPE_BUY) return (entry-sl)>=min_dist;
   return (sl-entry)>=min_dist;
}

bool OpenTrade(const int direction,const double volume)
{
   if(volume<=0.0) return false;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;

   double atr=0.0;
   if(!GetATR(atr))
   {
      Print("ATR unavailable; entry aborted.");
      return false;
   }

   ENUM_ORDER_TYPE type=(direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double entry=(direction>0 ? tick.ask : tick.bid);
   double sl=(direction>0 ? entry-atr*InpATRSafetyMultiplier : entry+atr*InpATRSafetyMultiplier);
   sl=NormalizeDouble(sl,_Digits);

   if(!StopsAreValid(type,entry,sl))
   {
      PrintFormat("SL rejected by broker stop/freeze level. entry=%.*f sl=%.*f",_Digits,entry,_Digits,sl);
      return false;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   ResetLastError();
   bool ok=false;
   string comment=(direction>0 ? "MultiEngineEA BUY" : "MultiEngineEA SELL");
   if(direction>0) ok=trade.Buy(volume,_Symbol,0.0,sl,0.0,comment);
   else            ok=trade.Sell(volume,_Symbol,0.0,sl,0.0,comment);

   uint rc=trade.ResultRetcode();
   if(!ok || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_PLACED && rc!=TRADE_RETCODE_DONE_PARTIAL))
   {
      PrintFormat("Order failed: ok=%s retcode=%u desc=%s lastError=%d",
                  ok?"true":"false",rc,trade.ResultRetcodeDescription(),GetLastError());
      if(rc==TRADE_RETCODE_INVALID_STOPS)
         Print("Broker rejected stops (10016 INVALID_STOPS): increase ATR multiplier or respect symbol stop level.");
      return false;
   }

   PrintFormat("Order accepted: %s volume=%.2f price=%.*f SL=%.*f retcode=%u",
               direction>0?"BUY":"SELL",volume,_Digits,trade.ResultPrice(),_Digits,sl,rc);
   return true;
}

void ManageBreakEven()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double points_profit=(type==POSITION_TYPE_BUY ? (tick.bid-open) : (open-tick.ask))/_Point;
      if(points_profit<InpBreakEvenPoints) continue;

      double new_sl=(type==POSITION_TYPE_BUY ? open+5.0*_Point : open-5.0*_Point);
      new_sl=NormalizeDouble(new_sl,_Digits);

      bool improve=(type==POSITION_TYPE_BUY ? (sl==0.0 || new_sl>sl) : (sl==0.0 || new_sl<sl));
      if(!improve) continue;

      // Broker minimum stop distance can make a BE+5 request invalid near market.
      long stops_level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
      double min_dist=stops_level*_Point;
      if(type==POSITION_TYPE_BUY && (tick.bid-new_sl)<min_dist) continue;
      if(type==POSITION_TYPE_SELL && (new_sl-tick.ask)<min_dist) continue;

      ResetLastError();
      if(!trade.PositionModify(ticket,new_sl,0.0))
         PrintFormat("Break-even modify failed ticket=%I64u retcode=%u desc=%s error=%d",
                     ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription(),GetLastError());
   }
}

int OnInit()
{
   if(InpBaseCapital<=0 || InpBaseLot<=0 || InpMaxLayers<1 || InpMinSignalScore<1 || InpMinSignalScore>10)
   {
      Print("Invalid input configuration.");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(!EntryEngine.Init(_Symbol,InpHTF,InpLTF,InpEMAPeriodFast,InpEMAPeriodSlow,
                        InpRSIPeriod,InpRSIUpper,InpRSILower))
   {
      Print("EntryEngine initialization failed.");
      return INIT_FAILED;
   }

   g_atr_handle=iATR(_Symbol,InpLTF,InpATRPeriod);
   if(g_atr_handle==INVALID_HANDLE)
   {
      Print("ATR initialization failed.");
      EntryEngine.Release();
      return INIT_FAILED;
   }

   g_last_ltf_bar=iTime(_Symbol,InpLTF,0);
   PrintFormat("MultiEngineEA initialized on %s. Balance=%.2f dynamicLot=%.2f",
               _Symbol,AccountInfoDouble(ACCOUNT_BALANCE),CalculateDynamicLot());
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EntryEngine.Release();
   if(g_atr_handle!=INVALID_HANDLE) IndicatorRelease(g_atr_handle);
}

void OnTick()
{
   // 1) Hard spread gate.
   if(!SpreadOK()) return;

   // 2) Exit management runs every tick.
   if(CheckAndCloseByProfitTarget()) return;
   ManageBreakEven();

   // 3) Avoid duplicate entries on every tick of the same M1 bar.
   if(InpRequireNewBar && !IsNewLTFBar()) return;

   // 4) Strict one-layer / max-layer enforcement.
   if(CountOurPositions()>=InpMaxLayers) return;

   // 5) Calculate 10-point score.
   SignalResult signal=EntryEngine.CalculateSignalScore();
   PrintFormat("Signal: score=%d direction=%d reason=%s",signal.score,signal.direction,signal.reason);
   if(signal.direction==0 || signal.score<InpMinSignalScore) return;

   // 6) Dynamic lot + ATR stop, no fixed TP.
   double lot=CalculateDynamicLot();
   if(lot<=0.0) return;
   OpenTrade(signal.direction,lot);
}
