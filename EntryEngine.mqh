#pragma once
#ifndef __ENTRY_ENGINE_MQH__
#define __ENTRY_ENGINE_MQH__

// MultiEngineEA - XAUUSD M1/H1 signal engine
// Signal score: HTF trend 3 + liquidity rejection 4 + volume 2 + RSI cross 1 = 10.

struct SignalResult
{
   int    score;
   int    direction; // 1 = BUY, -1 = SELL, 0 = none
   string reason;
};

class CEntryEngine
{
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_htf;
   ENUM_TIMEFRAMES m_ltf;
   int             m_fast_period;
   int             m_slow_period;
   int             m_rsi_period;
   double          m_rsi_upper;
   double          m_rsi_lower;

   int m_htf_fast_handle;
   int m_htf_slow_handle;
   int m_ltf_rsi_handle;

   bool GetMA(const int handle,const int shift,double &value)
   {
      double buf[1];
      if(handle==INVALID_HANDLE || CopyBuffer(handle,0,shift,1,buf)!=1)
         return false;
      value=buf[0];
      return true;
   }

   bool GetRSI(const int shift,double &value)
   {
      double buf[1];
      if(m_ltf_rsi_handle==INVALID_HANDLE || CopyBuffer(m_ltf_rsi_handle,0,shift,1,buf)!=1)
         return false;
      value=buf[0];
      return true;
   }

   bool GetHTFTrend(int &direction,string &reason)
   {
      MqlRates r[2];
      ArraySetAsSeries(r,true);
      if(CopyRates(m_symbol,m_htf,0,2,r)!=2)
         return false;

      double fast=0.0,slow=0.0;
      if(!GetMA(m_htf_fast_handle,1,fast) || !GetMA(m_htf_slow_handle,1,slow))
         return false;

      const double close1=r[1].close;
      if(close1>fast && fast>slow)
      {
         direction=1;
         reason="HTF bullish trend";
         return true;
      }
      if(close1<fast && fast<slow)
      {
         direction=-1;
         reason="HTF bearish trend";
         return true;
      }

      direction=0;
      reason="HTF counter-trend/neutral: rejected";
      return true;
   }

   bool GetLiquidityRejection(const int direction,bool &ok,string &reason)
   {
      ok=false;
      // Need bar 1 plus bars 2..20 for the previous liquidity pool.
      MqlRates r[22];
      ArraySetAsSeries(r,true);
      if(CopyRates(m_symbol,m_ltf,0,22,r)<22)
         return false;

      double prior_low=r[2].low;
      double prior_high=r[2].high;
      for(int i=2;i<=20;i++)
      {
         if(r[i].low<prior_low) prior_low=r[i].low;
         if(r[i].high>prior_high) prior_high=r[i].high;
      }

      const double o=r[1].open;
      const double h=r[1].high;
      const double l=r[1].low;
      const double c=r[1].close;
      const double body=MathAbs(c-o);
      if(body<=0.0)
      {
         reason="No rejection: zero body";
         return true;
      }

      const double lower_wick=MathMin(o,c)-l;
      const double upper_wick=h-MathMax(o,c);

      if(direction==1 && l<prior_low && c>o && lower_wick >= body*0.60)
      {
         ok=true;
         reason="Bullish liquidity sweep + rejection";
      }
      else if(direction==-1 && h>prior_high && c<o && upper_wick >= body*0.60)
      {
         ok=true;
         reason="Bearish liquidity sweep + rejection";
      }
      else
         reason="No qualifying liquidity rejection";

      return true;
   }

   bool GetVolumeConfirmation(bool &ok,string &reason)
   {
      ok=false;
      MqlRates r[22];
      ArraySetAsSeries(r,true);
      if(CopyRates(m_symbol,m_ltf,0,22,r)<22)
         return false;

      double sum=0.0;
      for(int i=2;i<=21;i++)
         sum+=(double)r[i].tick_volume;
      const double sma=sum/20.0;

      if((double)r[1].tick_volume>sma)
      {
         ok=true;
         reason="M1 tick volume above 20-bar SMA";
      }
      else
         reason="M1 volume below threshold";
      return true;
   }

   bool GetRSIConfirmation(const int direction,bool &ok,string &reason)
   {
      ok=false;
      double rsi1=0.0,rsi2=0.0;
      if(!GetRSI(1,rsi1) || !GetRSI(2,rsi2))
         return false;

      if(direction==1 && rsi2<=m_rsi_lower && rsi1>m_rsi_lower)
      {
         ok=true;
         reason="RSI crossed above lower threshold";
      }
      else if(direction==-1 && rsi2>=m_rsi_upper && rsi1<m_rsi_upper)
      {
         ok=true;
         reason="RSI crossed below upper threshold";
      }
      else
         reason="No qualifying RSI cross";
      return true;
   }

public:
   CEntryEngine()
   {
      m_symbol="";
      m_htf=PERIOD_H1;
      m_ltf=PERIOD_M1;
      m_fast_period=50;
      m_slow_period=200;
      m_rsi_period=14;
      m_rsi_upper=65.0;
      m_rsi_lower=35.0;
      m_htf_fast_handle=INVALID_HANDLE;
      m_htf_slow_handle=INVALID_HANDLE;
      m_ltf_rsi_handle=INVALID_HANDLE;
   }

   bool Init(const string symbol,ENUM_TIMEFRAMES htf,ENUM_TIMEFRAMES ltf,
             int fast_period,int slow_period,int rsi_period,
             double rsi_upper,double rsi_lower)
   {
      m_symbol=symbol;
      m_htf=htf;
      m_ltf=ltf;
      m_fast_period=fast_period;
      m_slow_period=slow_period;
      m_rsi_period=rsi_period;
      m_rsi_upper=rsi_upper;
      m_rsi_lower=rsi_lower;

      m_htf_fast_handle=iMA(m_symbol,m_htf,m_fast_period,0,MODE_EMA,PRICE_CLOSE);
      m_htf_slow_handle=iMA(m_symbol,m_htf,m_slow_period,0,MODE_EMA,PRICE_CLOSE);
      m_ltf_rsi_handle=iRSI(m_symbol,m_ltf,m_rsi_period,PRICE_CLOSE);

      if(m_htf_fast_handle==INVALID_HANDLE || m_htf_slow_handle==INVALID_HANDLE || m_ltf_rsi_handle==INVALID_HANDLE)
         return false;
      return true;
   }

   void Release()
   {
      if(m_htf_fast_handle!=INVALID_HANDLE) IndicatorRelease(m_htf_fast_handle);
      if(m_htf_slow_handle!=INVALID_HANDLE) IndicatorRelease(m_htf_slow_handle);
      if(m_ltf_rsi_handle!=INVALID_HANDLE) IndicatorRelease(m_ltf_rsi_handle);
      m_htf_fast_handle=INVALID_HANDLE;
      m_htf_slow_handle=INVALID_HANDLE;
      m_ltf_rsi_handle=INVALID_HANDLE;
   }

   SignalResult CalculateSignalScore()
   {
      SignalResult out;
      out.score=0;
      out.direction=0;
      out.reason="";

      int trend=0;
      string trend_reason="";
      if(!GetHTFTrend(trend,trend_reason))
      {
         out.reason="HTF data unavailable";
         return out;
      }
      // Strict counter-trend rejection.
      if(trend==0)
      {
         out.reason=trend_reason;
         return out;
      }

      out.direction=trend;
      out.score=3;
      out.reason=trend_reason;

      bool sweep=false,volume=false,rsi=false;
      string s1="",s2="",s3="";
      if(!GetLiquidityRejection(trend,sweep,s1) || !GetVolumeConfirmation(volume,s2) || !GetRSIConfirmation(trend,rsi,s3))
      {
         out.reason+=" | indicator/data unavailable";
         return out;
      }

      if(sweep)  out.score+=4;
      if(volume) out.score+=2;
      if(rsi)    out.score+=1;

      out.reason+=" | "+s1+" | "+s2+" | "+s3;
      return out;
   }
};

#endif
