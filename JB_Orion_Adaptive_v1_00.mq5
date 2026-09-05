//+------------------------------------------------------------------+
//|                                     JB_Orion_Adaptive_v1_00.mq5  |
//|        Adaptive Multi-Setup Mean Reversion - EURUSD H1           |
//|                                                     Version 1.00 |
//+------------------------------------------------------------------+
//
// DESIGN (built from the 2023-2026 EURUSD pattern study)
//
// SETUPS (all validated on H1 2023-2026 data):
//   S0 BUY  FADE   : close under lower Bollinger band + low RSI.
//                    Works in BOTH regimes on EURUSD (dips get
//                    bought even in downtrends), strongest in LOW
//                    volatility (72% win in the study).
//   S1 SELL FADE   : close over upper band + high RSI, ONLY while
//                    D1 close < D1 EMA50. Fading rallies in a bull
//                    regime lost -0.15R/trade in the study and is
//                    hard-blocked. Strongest in HIGH volatility.
//   S2 SELL STREAK : 5+ consecutive up H1 bars while in the bear
//                    regime (55.7% win in the study).
//
// LEARN-FROM-MISTAKES (context ledger):
//   Every closed trade is recorded into a persistent ledger keyed
//   by context = setup x regime-alignment x volatility state x
//   session. The EA computes a shrunk expectancy per context:
//   contexts that keep losing get their risk cut and are finally
//   BLOCKED; contexts that keep winning get more risk. The ledger
//   decays monthly so the EA can re-learn if the market changes.
//   Ledger is seeded with priors measured from the 2023-2026 study
//   and persists across restarts (live) via a file.
//   Additionally each setup carries its own loss-streak pause:
//   3 straight losses on one setup pause only that setup for 48h.
//
// SELF-IMPROVEMENT (shadow parameter sets + self-throttle):
//   Three parameter variants (band deviation / RSI band / TP mult)
//   trade VIRTUALLY on every closed bar, in parallel with the real
//   EA. Rolling virtual expectancy is compared weekly and the EA
//   switches its live parameters to the best variant when it is
//   clearly ahead. An equity-curve throttle cuts risk when the
//   EA's own recent trades sum negative, restoring it when the
//   curve recovers.
//
// RISK: fixed-fraction sizing from SL distance, one SL max loss
//   per position, daily loss limit, total-DD guard from the equity
//   high-water mark, spread/rollover/late-Friday filters.
//
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Adaptive multi-setup H1 mean reversion with a"
#property description "learn-from-mistakes context ledger and self-"
#property description "tuning shadow parameter sets."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//====================================================================
// INPUTS
//====================================================================

input string Set_Entry = "===== ENTRY =====";

input ENUM_TIMEFRAMES InpTimeframe = PERIOD_H1;

input int  InpBandPeriod   = 20;
input int  InpRSIPeriod    = 14;
input int  InpATRPeriod    = 14;
input int  InpD1EMAPeriod  = 50;

// Consecutive up bars required for the S2 streak-fade sell.
input int  InpStreakBars   = 5;
input bool InpEnableStreakSell = true;

// S3: deep M15 buy fade (z < -2.5 sigma, RSI < 25), London/NY only.
// Validated on 2023-2026 M15 data: 58% win, +0.09R after costs.
input bool   InpEnableM15Fade   = true;
input double InpM15BandDev      = 2.5;
input double InpM15RSIBuyMax    = 25.0;
input int    InpM15HourStart    = 8;
input int    InpM15HourEnd      = 20;
input double InpM15BracketATRH1 = 0.65;  // TP/SL as a fraction of H1 ATR
input double InpM15RiskFrac     = 0.50;  // of InpRiskPercent
input int    InpM15MaxBars      = 12;    // H1 bars before time stop

input string Set_Exit = "===== EXIT =====";

input double InpATRMultSL          = 1.3;
input double InpBreakevenFrac      = 0.60;
input double InpBreakevenLockPoints= 15;
input int    InpMaxBarsInTrade     = 36;

input string Set_Learning = "===== LEARN FROM MISTAKES =====";

// Ledger: shrunk expectancy per context. Block when enough samples
// show a losing context; scale risk by context quality.
input bool   InpUseContextLedger   = true;
input int    InpCtxMinSamples      = 10;     // samples before a block
input double InpCtxBlockExpR       = -0.08; // block below this expR
input double InpCtxShrinkK         = 4.0;   // shrink toward 0
input double InpCtxRiskScale       = 1.5;   // riskMult = 1+E*scale
input double InpCtxRiskMultMin     = 0.50;
input double InpCtxRiskMultMax     = 1.60;
input double InpCtxDecayFactor     = 0.70;  // monthly ledger decay
input bool   InpSeedPriors         = true;  // seed from 2023-26 study

// Per-setup loss streak pause.
input int    InpSetupLossStreak    = 3;
input int    InpSetupPauseHours    = 48;

input string Set_SelfTune = "===== SELF-IMPROVEMENT =====";

// Shadow variants (bandDev, rsiBuyMax [sell=100-buy], tpMult).
input bool   InpUseSelfTune  = true;
input double InpVarA_Dev = 1.8;  input double InpVarA_RSI = 35;  input double InpVarA_TP = 1.3;
input double InpVarB_Dev = 2.0;  input double InpVarB_RSI = 32;  input double InpVarB_TP = 1.3;
input double InpVarC_Dev = 1.6;  input double InpVarC_RSI = 38;  input double InpVarC_TP = 1.1;
input int    InpStartVariant     = 0;     // 0=A 1=B 2=C
input int    InpVirtualWindow    = 40;    // rolling virtual trades
input int    InpVirtualMinTrades = 25;    // before a switch allowed
input double InpSwitchMargin     = 0.06;  // expR lead needed
input int    InpTuneEveryBars    = 120;   // ~1 week of H1 bars

// Equity-curve self-throttle over the last N real trades.
input bool   InpUseEquityThrottle = true;
input int    InpThrottleWindow    = 15;
input double InpThrottleSoftSumR  = -1.5; // below: risk x 0.6
input double InpThrottleHardSumR  = -3.0; // below: risk x 0.4

input string Set_Risk = "===== RISK =====";

input double InpRiskPercent           = 0.48;
input int    InpMaxPositions          = 2;
input int    InpMaxTradesPerDay       = 5;
input double InpDailyLossLimitPercent = 2.0;
input double InpTotalDDGuardPercent   = 4.8;
input int    InpGuardHaltDays         = 3;
input int    InpCooldownWinMinutes    = 15;
input int    InpCooldownLossMinutes   = 45;

// Proportional drawdown brake: risk scales down smoothly as the
// equity drawdown from peak approaches the total-DD guard, so deep
// drawdowns become progressively harder to extend.
input bool   InpUseDDBrake  = true;
input double InpDDBrakeFloor = 0.25;

input string Set_Filters = "===== FILTERS =====";

input double InpMaxSpreadPoints    = 25;
input double InpMaxSpreadFracOfATR = 0.15;
input bool   InpAvoidRollover      = true;
input int    InpRolloverStartHour  = 23;
input int    InpRolloverEndHour    = 1;
input bool   InpSkipLateFriday     = true;
input int    InpFridayCutoffHour   = 20;

input string Set_Execution = "===== EXECUTION =====";

input long InpMagicNumber     = 123600;
input int  InpDeviationPoints = 20;

//====================================================================
// CONSTANTS AND STRUCTS
//====================================================================

#define N_SETUPS   4
#define N_CTX      48     // setup(4) x aligned(2) x volLow(2) x session(3)
#define N_VARIANTS 3

struct ContextStats
{
   double n;
   double wins;
   double sumR;
};

struct OpenTradeRec
{
   long     posId;
   int      setup;
   int      ctx;
   int      dir;
   double   riskMoney;
   double   entry;
   double   slDist;
   double   tpDist;
   datetime openTime;
   bool     beDone;
   int      maxBars;
};

struct VirtualTrade
{
   bool     open;
   int      dir;
   double   entry;
   double   tp;
   double   sl;
   int      barsOpen;
};

struct Variant
{
   double dev;
   double rsiBuy;    // sell threshold = 100 - rsiBuy
   double tpMult;
   int    handle;    // iBands handle at this deviation
};

//====================================================================
// GLOBALS
//====================================================================

CTrade        trade;
CPositionInfo pos;

int RSIHandle   = INVALID_HANDLE;
int ATRHandle   = INVALID_HANDLE;
int D1EMAHandle = INVALID_HANDLE;
int M15BandsHandle = INVALID_HANDLE;
int M15RSIHandle   = INVALID_HANDLE;
datetime LastM15Bar = 0;

Variant      Variants[N_VARIANTS];
int          ActiveVariant = 0;
int          VariantSwitches = 0;
VirtualTrade VTrades[N_VARIANTS];
double       VResults[N_VARIANTS][80];   // ring buffers of virtual R
int          VCount[N_VARIANTS];
int          VHead[N_VARIANTS];

ContextStats Ctx[N_CTX];

OpenTradeRec OpenTrades[8];
int          OpenCount = 0;

double   RealR[64];            // ring buffer of real trade R results
int      RealRCount = 0;
int      RealRHead  = 0;

int      SetupStreak[N_SETUPS];
datetime SetupPausedUntil[N_SETUPS];

datetime CooldownUntil = 0;
datetime HaltUntil     = 0;
double   PeakEquity    = 0.0;

datetime LastSignalBar = 0;
datetime LastDecayTime = 0;
int      BarsSinceTune = 0;

bool     IsTester = false;
datetime LastWarningTime = 0;

datetime DayCacheDate  = 0;
double   DayNet        = 0.0;
int      DayTradesOpen = 0;

int      TotalClosed = 0;
int      TotalWins   = 0;
int      CtxBlockedTrades = 0;

//====================================================================
// GENERAL HELPERS
//====================================================================

bool ThrottleWarning(int seconds)
{
   datetime now = TimeCurrent();
   if(now - LastWarningTime < seconds)
      return false;
   LastWarningTime = now;
   return true;
}

bool TradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   return false;
   return true;
}

bool TradeResultSuccessful()
{
   uint rc = trade.ResultRetcode();
   return rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL ||
          rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_NO_CHANGES;
}

int VolumeDigits()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int digits = 0;
   while(step < 1.0 && digits < 8) { step *= 10.0; digits++; }
   return digits;
}

double NormalizeVolume(double requested)
{
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0 || requested <= 0.0) return 0.0;
   double volume = MathFloor((requested + 1e-12) / step) * step;
   if(volume < minimum) return 0.0;
   volume = MathMin(volume, maximum);
   return NormalizeDouble(volume, VolumeDigits());
}

datetime DayStartTime(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

int ServerHour()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour;
}

bool InHourWindow(int hour, int startHour, int endHour)
{
   int s = ((startHour % 24) + 24) % 24;
   int e = ((endHour % 24) + 24) % 24;
   if(s == e) return false;
   if(s < e)  return hour >= s && hour < e;
   return hour >= s || hour < e;
}

bool RolloverOK()
{
   if(!InpAvoidRollover) return true;
   return !InHourWindow(ServerHour(), InpRolloverStartHour, InpRolloverEndHour);
}

bool FridayOK()
{
   if(!InpSkipLateFriday) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour) return false;
   return true;
}

bool ReadBuffer(int handle, int bufferIndex, int shift, double &value)
{
   double buffer[1];
   if(handle == INVALID_HANDLE) return false;
   if(CopyBuffer(handle, bufferIndex, shift, 1, buffer) != 1) return false;
   value = buffer[0];
   if(!MathIsValidNumber(value)) return false;
   if(value == EMPTY_VALUE) return false;
   return true;
}

bool ReadClose(ENUM_TIMEFRAMES timeframe, int shift, double &value)
{
   double buffer[1];
   if(CopyClose(_Symbol, timeframe, shift, 1, buffer) != 1) return false;
   value = buffer[0];
   return value > 0.0;
}

//====================================================================
// CONTEXT LEDGER  (learn from mistakes)
//====================================================================

// session: 0 = Asia (0-7), 1 = London (8-15), 2 = NY (16-23)
int SessionBucket(int hour) { return MathMin(2, hour / 8); }

int CtxIndex(int setup, int aligned, int volLow, int session)
{
   return setup * 12 + aligned * 6 + volLow * 3 + session;
}

double CtxExpectancy(int ci)
{
   if(ci < 0 || ci >= N_CTX) return 0.0;
   return Ctx[ci].sumR / (Ctx[ci].n + InpCtxShrinkK);
}

bool CtxBlocked(int ci)
{
   if(!InpUseContextLedger) return false;
   if(ci < 0 || ci >= N_CTX) return false;
   if(Ctx[ci].n < InpCtxMinSamples) return false;
   return CtxExpectancy(ci) < InpCtxBlockExpR;
}

double CtxRiskMult(int ci)
{
   if(!InpUseContextLedger) return 1.0;
   if(ci < 0 || ci >= N_CTX) return 1.0;
   if(Ctx[ci].n < 6.0) return 1.0;
   double m = 1.0 + CtxExpectancy(ci) * InpCtxRiskScale;
   return MathMax(InpCtxRiskMultMin, MathMin(InpCtxRiskMultMax, m));
}

void CtxRecord(int ci, double r)
{
   if(ci < 0 || ci >= N_CTX) return;
   Ctx[ci].n    += 1.0;
   Ctx[ci].sumR += r;
   if(r > 0.02) Ctx[ci].wins += 1.0;
}

// Monthly recency decay so old lessons fade and the EA can re-learn.
void MaybeDecayLedger()
{
   datetime now = TimeCurrent();
   if(LastDecayTime == 0) { LastDecayTime = now; return; }
   if(now - LastDecayTime < 30 * 86400) return;
   LastDecayTime = now;
   for(int i = 0; i < N_CTX; i++)
   {
      Ctx[i].n    *= InpCtxDecayFactor;
      Ctx[i].wins *= InpCtxDecayFactor;
      Ctx[i].sumR *= InpCtxDecayFactor;
   }
   Print("JB ADPT ledger decayed (factor ",
         DoubleToString(InpCtxDecayFactor, 2), ")");
}

// Priors measured in the 2023-2026 pattern study. Pseudo-counts are
// deliberately small so live results dominate within a few months.
void SeedPriors()
{
   if(!InpSeedPriors) return;
   for(int session = 0; session < 3; session++)
   {
      // S0 buy fade: strong in low vol, flat in high vol.
      Ctx[CtxIndex(0, 1, 1, session)].n    = 6;  // aligned, low vol
      Ctx[CtxIndex(0, 1, 1, session)].sumR = 1.8;
      Ctx[CtxIndex(0, 1, 0, session)].n    = 6;  // aligned, high vol
      Ctx[CtxIndex(0, 1, 0, session)].sumR = -0.1;
      Ctx[CtxIndex(0, 0, 1, session)].n    = 6;  // counter, low vol
      Ctx[CtxIndex(0, 0, 1, session)].sumR = 0.8;
      Ctx[CtxIndex(0, 0, 0, session)].n    = 6;  // counter, high vol
      Ctx[CtxIndex(0, 0, 0, session)].sumR = 0.2;
      // S1 sell fade (always regime-aligned): needs high vol.
      Ctx[CtxIndex(1, 1, 0, session)].n    = 6;
      Ctx[CtxIndex(1, 1, 0, session)].sumR = 1.1;
      Ctx[CtxIndex(1, 1, 1, session)].n    = 6;
      Ctx[CtxIndex(1, 1, 1, session)].sumR = -0.2;
      // S2 streak sell: mild positive prior.
      Ctx[CtxIndex(2, 1, 0, session)].n    = 4;
      Ctx[CtxIndex(2, 1, 0, session)].sumR = 0.5;
      Ctx[CtxIndex(2, 1, 1, session)].n    = 4;
      Ctx[CtxIndex(2, 1, 1, session)].sumR = 0.3;
      // S3 deep M15 buy fade: mild positive prior (both regimes).
      for(int al = 0; al < 2; al++)
         for(int vl = 0; vl < 2; vl++)
         {
            Ctx[CtxIndex(3, al, vl, session)].n    = 4;
            Ctx[CtxIndex(3, al, vl, session)].sumR = 0.4;
         }
   }
}

//====================================================================
// BRAIN PERSISTENCE (live only; tester runs start fresh)
//====================================================================

string BrainFile()
{
   return "JB_ADPT_" + _Symbol + "_" +
          IntegerToString((int)InpMagicNumber) + "_brain.csv";
}

void SaveBrain()
{
   if(IsTester) return;
   int fh = FileOpen(BrainFile(), FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) return;
   FileWrite(fh, "meta", ActiveVariant, TotalClosed, TotalWins,
             (long)LastDecayTime, (long)HaltUntil, PeakEquity);
   for(int i = 0; i < N_CTX; i++)
      FileWrite(fh, "ctx", i, Ctx[i].n, Ctx[i].wins, Ctx[i].sumR);
   for(int s = 0; s < N_SETUPS; s++)
      FileWrite(fh, "setup", s, SetupStreak[s], (long)SetupPausedUntil[s]);
   FileClose(fh);
}

void LoadBrain()
{
   if(IsTester) return;
   if(!FileIsExist(BrainFile())) return;
   int fh = FileOpen(BrainFile(), FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) return;
   while(!FileIsEnding(fh))
   {
      string tag = FileReadString(fh);
      if(tag == "meta")
      {
         ActiveVariant = (int)FileReadNumber(fh);
         TotalClosed   = (int)FileReadNumber(fh);
         TotalWins     = (int)FileReadNumber(fh);
         LastDecayTime = (datetime)(long)FileReadNumber(fh);
         HaltUntil     = (datetime)(long)FileReadNumber(fh);
         PeakEquity    = FileReadNumber(fh);
      }
      else if(tag == "ctx")
      {
         int i = (int)FileReadNumber(fh);
         if(i >= 0 && i < N_CTX)
         {
            Ctx[i].n    = FileReadNumber(fh);
            Ctx[i].wins = FileReadNumber(fh);
            Ctx[i].sumR = FileReadNumber(fh);
         }
      }
      else if(tag == "setup")
      {
         int s = (int)FileReadNumber(fh);
         if(s >= 0 && s < N_SETUPS)
         {
            SetupStreak[s]      = (int)FileReadNumber(fh);
            SetupPausedUntil[s] = (datetime)(long)FileReadNumber(fh);
         }
      }
   }
   FileClose(fh);
   ActiveVariant = MathMax(0, MathMin(N_VARIANTS - 1, ActiveVariant));
   Print("JB ADPT brain loaded: ", TotalClosed, " trades of history, ",
         "active variant ", ActiveVariant);
}

//====================================================================
// SHADOW VARIANTS  (self-improvement)
//====================================================================

void VPush(int v, double r)
{
   VResults[v][VHead[v]] = r;
   VHead[v] = (VHead[v] + 1) % InpVirtualWindow;
   if(VCount[v] < InpVirtualWindow) VCount[v]++;
}

double VExpectancy(int v)
{
   if(VCount[v] == 0) return 0.0;
   double s = 0.0;
   for(int i = 0; i < VCount[v]; i++) s += VResults[v][i];
   return s / VCount[v];
}

// Walk virtual trades one closed bar forward, then look for fresh
// virtual signals, for every variant in parallel.
void UpdateVirtualTrades(double close1, double high1, double low1,
                         double rsi1, double atr1, bool bull)
{
   for(int v = 0; v < N_VARIANTS; v++)
   {
      // 1) advance an open virtual trade
      if(VTrades[v].open)
      {
         VTrades[v].barsOpen++;
         double res = 0.0;
         bool   done = false;
         double slDist = MathAbs(VTrades[v].entry - VTrades[v].sl);
         if(slDist <= 0.0) { VTrades[v].open = false; continue; }
         bool hitTP, hitSL;
         if(VTrades[v].dir > 0)
         {
            hitTP = high1 >= VTrades[v].tp;
            hitSL = low1  <= VTrades[v].sl;
         }
         else
         {
            hitTP = low1  <= VTrades[v].tp;
            hitSL = high1 >= VTrades[v].sl;
         }
         if(hitSL)              { res = -1.0; done = true; }   // SL first: conservative
         else if(hitTP)
         {
            res = MathAbs(VTrades[v].tp - VTrades[v].entry) / slDist;
            done = true;
         }
         else if(VTrades[v].barsOpen >= InpMaxBarsInTrade)
         {
            res = (close1 - VTrades[v].entry) / slDist * VTrades[v].dir;
            done = true;
         }
         if(done)
         {
            VTrades[v].open = false;
            VPush(v, res);
         }
      }

      // 2) fresh virtual signal on this closed bar
      if(VTrades[v].open) continue;

      double upper = 0.0, lower = 0.0;
      if(!ReadBuffer(Variants[v].handle, 1, 1, upper)) continue;
      if(!ReadBuffer(Variants[v].handle, 2, 1, lower)) continue;

      int dir = 0;
      if(close1 <= lower && rsi1 <= Variants[v].rsiBuy)
         dir = 1;
      else if(close1 >= upper && rsi1 >= 100.0 - Variants[v].rsiBuy && !bull)
         dir = -1;   // same hard rule as live: no bull-regime sell fades
      if(dir == 0) continue;

      VTrades[v].open     = true;
      VTrades[v].dir      = dir;
      VTrades[v].entry    = close1;
      VTrades[v].barsOpen = 0;
      double slDist = atr1 * InpATRMultSL;
      double tpDist = atr1 * Variants[v].tpMult;
      VTrades[v].sl = close1 - dir * slDist;
      VTrades[v].tp = close1 + dir * tpDist;
   }
}

void MaybeSelfTune()
{
   if(!InpUseSelfTune) return;
   BarsSinceTune++;
   if(BarsSinceTune < InpTuneEveryBars) return;
   BarsSinceTune = 0;

   int    best  = ActiveVariant;
   double bestE = VExpectancy(ActiveVariant);
   for(int v = 0; v < N_VARIANTS; v++)
   {
      if(v == ActiveVariant) continue;
      if(VCount[v] < InpVirtualMinTrades) continue;
      double e = VExpectancy(v);
      if(e > bestE + InpSwitchMargin) { best = v; bestE = e; }
   }
   if(best != ActiveVariant)
   {
      Print("JB ADPT SELF-TUNE: variant ", ActiveVariant,
            " (expR ", DoubleToString(VExpectancy(ActiveVariant), 3),
            ") -> variant ", best,
            " (expR ", DoubleToString(bestE, 3),
            ") after ", VCount[best], " virtual trades");
      ActiveVariant = best;
      VariantSwitches++;
      SaveBrain();
   }
}

//====================================================================
// EQUITY-CURVE SELF-THROTTLE
//====================================================================

void RealRPush(double r)
{
   RealR[RealRHead] = r;
   RealRHead = (RealRHead + 1) % InpThrottleWindow;
   if(RealRCount < InpThrottleWindow) RealRCount++;
}

double RealRSum()
{
   double s = 0.0;
   for(int i = 0; i < RealRCount; i++) s += RealR[i];
   return s;
}

double EquityThrottleMult()
{
   if(!InpUseEquityThrottle) return 1.0;
   if(RealRCount < 8) return 1.0;
   double s = RealRSum();
   if(s <= InpThrottleHardSumR) return 0.4;
   if(s <= InpThrottleSoftSumR) return 0.6;
   return 1.0;
}

double DDBrakeMult()
{
   if(!InpUseDDBrake) return 1.0;
   if(PeakEquity <= 0.0 || InpTotalDDGuardPercent <= 0.0) return 1.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (PeakEquity - equity) / PeakEquity * 100.0;
   if(dd <= 0.0) return 1.0;
   double m = 1.0 - (dd / InpTotalDDGuardPercent);
   return MathMax(InpDDBrakeFloor, MathMin(1.0, m));
}

//====================================================================
// DAILY STATISTICS AND GUARDS
//====================================================================

void RefreshDayStats(bool force = false)
{
   datetime dayStart = DayStartTime(TimeCurrent());
   if(!force && dayStart == DayCacheDate) return;
   DayCacheDate  = dayStart;
   DayNet        = 0.0;
   DayTradesOpen = 0;
   if(!HistorySelect(dayStart, TimeCurrent() + 60)) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;
      ENUM_DEAL_ENTRY entry =
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      DayNet += HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                HistoryDealGetDouble(ticket, DEAL_SWAP) +
                HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(entry == DEAL_ENTRY_IN) DayTradesOpen++;
   }
}

bool DailyLossLimitHit()
{
   if(InpDailyLossLimitPercent <= 0.0) return false;
   RefreshDayStats();
   double dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - DayNet;
   if(dayStartBalance <= 0.0) return false;
   return DayNet <= -dayStartBalance * InpDailyLossLimitPercent / 100.0;
}

bool DailyTradeBudgetUsed()
{
   if(InpMaxTradesPerDay <= 0) return false;
   RefreshDayStats();
   return DayTradesOpen >= InpMaxTradesPerDay;
}

void UpdatePeakEquity()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > PeakEquity) PeakEquity = equity;
}

bool TotalDDGuardHit()
{
   if(InpTotalDDGuardPercent <= 0.0 || PeakEquity <= 0.0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return equity <= PeakEquity * (1.0 - InpTotalDDGuardPercent / 100.0);
}

int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol) continue;
      if(pos.Magic() == InpMagicNumber) count++;
   }
   return count;
}

void TriggerTotalDDHalt()
{
   Print("JB ADPT TOTAL DD GUARD: equity ",
         DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
         " fell ", DoubleToString(InpTotalDDGuardPercent, 2),
         "% below peak ", DoubleToString(PeakEquity, 2),
         ". Flattening; halting until next day.");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol) continue;
      if(pos.Magic() != InpMagicNumber) continue;
      if(!trade.PositionClose(pos.Ticket()) || !TradeResultSuccessful())
         Print("Guard close failed | ", trade.ResultRetcode(), " ",
               trade.ResultRetcodeDescription());
   }
   HaltUntil  = (datetime)((long)DayStartTime(TimeCurrent()) +
                (long)MathMax(1, InpGuardHaltDays) * 86400);
   PeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   SaveBrain();
}

//====================================================================
// OPEN-TRADE TRACKING
//====================================================================

int FindOpenBySetup(int setup)
{
   for(int i = 0; i < OpenCount; i++)
      if(OpenTrades[i].setup == setup) return i;
   return -1;
}

int FindOpenByPosId(long posId)
{
   for(int i = 0; i < OpenCount; i++)
      if(OpenTrades[i].posId == posId) return i;
   return -1;
}

void RemoveOpenAt(int index)
{
   for(int i = index; i < OpenCount - 1; i++)
      OpenTrades[i] = OpenTrades[i + 1];
   OpenCount--;
}

//====================================================================
// TRADE CLOSE HANDLING  (feeds the learning systems)
//====================================================================

void HandleClosedTrade(int recIndex, double net)
{
   OpenTradeRec rec = OpenTrades[recIndex];
   RemoveOpenAt(recIndex);

   double r = (rec.riskMoney > 0.0) ? net / rec.riskMoney : 0.0;
   r = MathMax(-2.0, MathMin(3.0, r));

   TotalClosed++;
   if(net > 0.0) TotalWins++;

   CtxRecord(rec.ctx, r);
   RealRPush(r);

   // Per-setup loss streak -> pause only that setup.
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double scratchAt = balance * 0.05 / 100.0;
   if(net < -scratchAt)
   {
      SetupStreak[rec.setup]++;
      if(InpSetupLossStreak > 0 &&
         SetupStreak[rec.setup] >= InpSetupLossStreak)
      {
         SetupPausedUntil[rec.setup] = (datetime)((long)TimeCurrent() +
                                       (long)InpSetupPauseHours * 3600);
         SetupStreak[rec.setup] = 0;
         Print("JB ADPT setup S", rec.setup, " paused until ",
               TimeToString(SetupPausedUntil[rec.setup],
                            TIME_DATE | TIME_MINUTES),
               " after a loss streak (lesson recorded)");
      }
   }
   else if(net > scratchAt)
      SetupStreak[rec.setup] = 0;

   int minutes = (net < 0.0) ? InpCooldownLossMinutes
                             : InpCooldownWinMinutes;
   CooldownUntil = TimeCurrent() + minutes * 60;

   SaveBrain();
   RefreshDayStats(true);

   Print("JB ADPT closed S", rec.setup,
         " | net=", DoubleToString(net, 2),
         " | R=", DoubleToString(r, 2),
         " | ctx ", rec.ctx,
         " expR now ", DoubleToString(CtxExpectancy(rec.ctx), 3),
         " | curve sumR ", DoubleToString(RealRSum(), 2));
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   long posId = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   int  index = FindOpenByPosId(posId);
   if(index < 0) return;

   // Sum every OUT deal of this position (partial closes included).
   double net = 0.0;
   if(HistorySelect(OpenTrades[index].openTime - 60, TimeCurrent() + 60))
   {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0) continue;
         if(HistoryDealGetInteger(dt, DEAL_POSITION_ID) != posId) continue;
         ENUM_DEAL_ENTRY de =
            (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_OUT_BY) continue;
         net += HistoryDealGetDouble(dt, DEAL_PROFIT) +
                HistoryDealGetDouble(dt, DEAL_SWAP) +
                HistoryDealGetDouble(dt, DEAL_COMMISSION);
      }
   }

   // Only finalize when the position is fully gone.
   bool stillOpen = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if((long)pos.Identifier() == posId) { stillOpen = true; break; }
   }
   if(stillOpen) return;

   HandleClosedTrade(index, net);
}

//====================================================================
// POSITION MANAGEMENT
//====================================================================

void ManageOpenPositions()
{
   for(int i = OpenCount - 1; i >= 0; i--)
   {
      bool found = false;
      for(int p = PositionsTotal() - 1; p >= 0; p--)
      {
         if(!pos.SelectByIndex(p)) continue;
         if((long)pos.Identifier() != OpenTrades[i].posId) continue;
         found = true;
         break;
      }
      if(!found) continue;   // close handled by OnTradeTransaction

      // Time stop (per-trade bar budget).
      if(OpenTrades[i].maxBars > 0 && OpenTrades[i].openTime > 0)
      {
         long ageBars = (TimeCurrent() - OpenTrades[i].openTime) /
                        MathMax(1, PeriodSeconds(InpTimeframe));
         if(ageBars >= OpenTrades[i].maxBars)
         {
            if(!trade.PositionClose(pos.Ticket()) ||
               !TradeResultSuccessful())
               Print("Time-stop close failed | ", trade.ResultRetcode(),
                     " ", trade.ResultRetcodeDescription());
            continue;
         }
      }

      // Breakeven lock.
      if(InpBreakevenFrac <= 0.0 || OpenTrades[i].beDone) continue;
      if(OpenTrades[i].entry <= 0.0 || OpenTrades[i].slDist <= 0.0) continue;

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) continue;

      double lockDist = InpBreakevenLockPoints * _Point;
      double trigger  = OpenTrades[i].tpDist * InpBreakevenFrac;
      long stopsLevel =
         SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDistance = (double)stopsLevel * _Point;

      double newSL = 0.0;
      bool   fire  = false;

      if(OpenTrades[i].dir > 0)
      {
         if(tick.bid - OpenTrades[i].entry >= trigger)
         {
            newSL = NormalizeDouble(OpenTrades[i].entry + lockDist, _Digits);
            if(minDistance > 0.0 && newSL > tick.bid - minDistance)
               newSL = NormalizeDouble(tick.bid - minDistance, _Digits);
            if(newSL > pos.StopLoss() + _Point) fire = true;
         }
      }
      else
      {
         if(OpenTrades[i].entry - tick.ask >= trigger)
         {
            newSL = NormalizeDouble(OpenTrades[i].entry - lockDist, _Digits);
            if(minDistance > 0.0 && newSL < tick.ask + minDistance)
               newSL = NormalizeDouble(tick.ask + minDistance, _Digits);
            if(pos.StopLoss() <= 0.0 || newSL < pos.StopLoss() - _Point)
               fire = true;
         }
      }

      if(!fire) continue;

      if(trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit()) &&
         TradeResultSuccessful())
         OpenTrades[i].beDone = true;
   }
}

//====================================================================
// ENTRY
//====================================================================

bool SpreadOK(double atr1, double &spreadOut)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   double spread = tick.ask - tick.bid;
   spreadOut = spread;
   if(spread < 0.0) return false;
   if(InpMaxSpreadPoints > 0.0 && spread > InpMaxSpreadPoints * _Point)
      return false;
   if(InpMaxSpreadFracOfATR > 0.0 && spread > atr1 * InpMaxSpreadFracOfATR)
      return false;
   return true;
}

void OpenSetupTrade(int setup, int dir, int ctx, double atr1,
                    double tpMult, double riskMult,
                    double riskFrac = 1.0, int maxBars = 0)
{
   if(maxBars <= 0) maxBars = InpMaxBarsInTrade;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double spread = tick.ask - tick.bid;
   double slDist = atr1 * InpATRMultSL;
   double tpDist = atr1 * tpMult;

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = (double)stopsLevel * _Point * 1.5;
   if(slDist < minDistance || tpDist < minDistance) return;

   double tickValue =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return;

   double riskPct   = InpRiskPercent * riskFrac * riskMult *
                      EquityThrottleMult() * DDBrakeMult();
   double riskMoney = balance * riskPct / 100.0;
   double lossPerLot = (slDist + spread) * (tickValue / tickSize);
   if(lossPerLot <= 0.0) return;

   double volume = NormalizeVolume(riskMoney / lossPerLot);
   if(volume <= 0.0)
   {
      if(ThrottleWarning(600))
         Print("JB ADPT: balance too small for the minimum lot.");
      return;
   }

   ENUM_ORDER_TYPE orderType = dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double orderPrice = dir > 0 ? tick.ask : tick.bid;
   double requiredMargin = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, volume, orderPrice,
                       requiredMargin))
      return;
   if(requiredMargin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.95)
   {
      if(ThrottleWarning(300))
         Print("JB ADPT: insufficient free margin.");
      return;
   }

   double slPrice, tpPrice;
   if(dir > 0)
   {
      slPrice = NormalizeDouble(tick.ask - slDist, _Digits);
      tpPrice = NormalizeDouble(tick.ask + tpDist, _Digits);
   }
   else
   {
      slPrice = NormalizeDouble(tick.bid + slDist, _Digits);
      tpPrice = NormalizeDouble(tick.bid - tpDist, _Digits);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   string comment = "JB_ADPT_S" + IntegerToString(setup);
   bool sent;
   if(dir > 0)
      sent = trade.Buy(volume, _Symbol, 0.0, slPrice, tpPrice, comment);
   else
      sent = trade.Sell(volume, _Symbol, 0.0, slPrice, tpPrice, comment);

   if(!sent || !TradeResultSuccessful())
   {
      Print("JB ADPT entry failed | ", trade.ResultRetcode(), " ",
            trade.ResultRetcodeDescription());
      return;
   }

   double fill = trade.ResultPrice();
   if(fill <= 0.0) fill = orderPrice;

   long posId = (long)trade.ResultDeal();
   if(HistoryDealSelect(trade.ResultDeal()))
      posId = HistoryDealGetInteger(trade.ResultDeal(), DEAL_POSITION_ID);

   if(OpenCount < 8)
   {
      OpenTrades[OpenCount].posId     = posId;
      OpenTrades[OpenCount].setup     = setup;
      OpenTrades[OpenCount].ctx       = ctx;
      OpenTrades[OpenCount].dir       = dir;
      OpenTrades[OpenCount].riskMoney = riskMoney;
      OpenTrades[OpenCount].entry     = fill;
      OpenTrades[OpenCount].slDist    = slDist;
      OpenTrades[OpenCount].tpDist    = tpDist;
      OpenTrades[OpenCount].openTime  = TimeCurrent();
      OpenTrades[OpenCount].beDone    = false;
      OpenTrades[OpenCount].maxBars   = maxBars;
      OpenCount++;
   }

   RefreshDayStats(true);

   Print("JB ADPT ", dir > 0 ? "BUY" : "SELL", " S", setup,
         " | lot=", DoubleToString(volume, VolumeDigits()),
         " | entry=", DoubleToString(fill, _Digits),
         " | ctx ", ctx,
         " riskMult=", DoubleToString(riskMult, 2),
         " throttle=", DoubleToString(EquityThrottleMult(), 2),
         " | variant ", ActiveVariant);
}

// S3: deep M15 buy fade, evaluated on each closed M15 bar.
void TryEnterM15()
{
   if(!InpEnableM15Fade) return;

   datetime bar = iTime(_Symbol, PERIOD_M15, 0);
   if(bar == 0 || bar == LastM15Bar) return;
   LastM15Bar = bar;

   datetime now = TimeCurrent();
   if(now < HaltUntil || now < CooldownUntil) return;
   if(now < SetupPausedUntil[3]) return;
   if(FindOpenBySetup(3) >= 0) return;
   if(CountMyPositions() >= InpMaxPositions + 1) return; // S3 rides on top
   if(DailyLossLimitHit() || DailyTradeBudgetUsed()) return;
   if(!RolloverOK() || !FridayOK()) return;

   int hour = ServerHour();
   if(hour < InpM15HourStart || hour >= InpM15HourEnd) return;

   double close1 = 0.0, lower = 0.0, rsi1 = 0.0, atrH1 = 0.0;
   if(!ReadClose(PERIOD_M15, 1, close1)) return;
   if(!ReadBuffer(M15BandsHandle, 2, 1, lower)) return;
   if(!ReadBuffer(M15RSIHandle, 0, 1, rsi1)) return;
   if(!ReadBuffer(ATRHandle, 0, 1, atrH1)) return;
   if(atrH1 <= 0.0) return;

   if(close1 > lower || rsi1 > InpM15RSIBuyMax) return;

   bool bull = true;
   double d1Close = 0.0, d1EMA = 0.0;
   if(ReadClose(PERIOD_D1, 1, d1Close) &&
      ReadBuffer(D1EMAHandle, 0, 1, d1EMA))
      bull = d1Close >= d1EMA;

   double atrArr[400];
   double atrAvg = atrH1;
   int copied = CopyBuffer(ATRHandle, 0, 1, 400, atrArr);
   if(copied > 50)
   {
      double s = 0.0;
      for(int i = 0; i < copied; i++) s += atrArr[i];
      atrAvg = s / copied;
   }
   bool volLow = atrH1 < atrAvg;

   double spread = 0.0;
   double bracketATR = atrH1 * InpM15BracketATRH1;
   if(!SpreadOK(bracketATR, spread)) return;

   int ctx = CtxIndex(3, bull ? 1 : 0, volLow ? 1 : 0,
                      SessionBucket(hour));
   if(CtxBlocked(ctx))
   {
      CtxBlockedTrades++;
      Print("JB ADPT ctx ", ctx, " BLOCKED (learned expR ",
            DoubleToString(CtxExpectancy(ctx), 3), ") - S3 skipped");
      return;
   }

   // Bracket in H1-ATR units so InpATRMultSL/tpMult scale as usual.
   OpenSetupTrade(3, 1, ctx, bracketATR, InpATRMultSL, CtxRiskMult(ctx),
                  InpM15RiskFrac, InpM15MaxBars);
}

void TryEnter()
{
   datetime bar = iTime(_Symbol, InpTimeframe, 0);
   if(bar == 0 || bar == LastSignalBar) return;
   LastSignalBar = bar;

   // --- shared bar-1 data ---
   double close1 = 0.0, rsi1 = 0.0, atr1 = 0.0;
   if(!ReadClose(InpTimeframe, 1, close1)) return;
   if(!ReadBuffer(RSIHandle, 0, 1, rsi1))  return;
   if(!ReadBuffer(ATRHandle, 0, 1, atr1))  return;
   if(atr1 <= 0.0) return;

   double high1 = 0.0, low1 = 0.0;
   double hbuf[1], lbuf[1];
   if(CopyHigh(_Symbol, InpTimeframe, 1, 1, hbuf) != 1) return;
   if(CopyLow(_Symbol, InpTimeframe, 1, 1, lbuf) != 1)  return;
   high1 = hbuf[0]; low1 = lbuf[0];

   // Regime.
   bool bull = true;
   double d1Close = 0.0, d1EMA = 0.0;
   if(ReadClose(PERIOD_D1, 1, d1Close) &&
      ReadBuffer(D1EMAHandle, 0, 1, d1EMA))
      bull = d1Close >= d1EMA;

   // Volatility state: current ATR vs its own long average.
   double atrArr[400];
   double atrAvg = atr1;
   int copied = CopyBuffer(ATRHandle, 0, 1, 400, atrArr);
   if(copied > 50)
   {
      double s = 0.0;
      for(int i = 0; i < copied; i++) s += atrArr[i];
      atrAvg = s / copied;
   }
   bool volLow = atr1 < atrAvg;

   // --- learning systems tick (also drives virtual trades) ---
   MaybeDecayLedger();
   UpdateVirtualTrades(close1, high1, low1, rsi1, atr1, bull);
   MaybeSelfTune();

   // --- can we take a real trade? ---
   if(CountMyPositions() >= InpMaxPositions) return;
   datetime now = TimeCurrent();
   if(now < HaltUntil || now < CooldownUntil) return;
   if(DailyLossLimitHit() || DailyTradeBudgetUsed()) return;
   if(!RolloverOK() || !FridayOK()) return;

   double spread = 0.0;
   if(!SpreadOK(atr1, spread)) return;

   int session = SessionBucket(ServerHour());

   // Active variant thresholds for the fade setups.
   double dev     = Variants[ActiveVariant].dev;
   double rsiBuy  = Variants[ActiveVariant].rsiBuy;
   double rsiSell = 100.0 - rsiBuy;
   double tpMult  = Variants[ActiveVariant].tpMult;

   double upper = 0.0, lower = 0.0;
   if(!ReadBuffer(Variants[ActiveVariant].handle, 1, 1, upper)) return;
   if(!ReadBuffer(Variants[ActiveVariant].handle, 2, 1, lower)) return;

   // ---- S0: BUY fade (any regime; ledger prices the difference) ----
   if(close1 <= lower && rsi1 <= rsiBuy &&
      FindOpenBySetup(0) < 0 && now >= SetupPausedUntil[0])
   {
      int aligned = bull ? 1 : 0;
      int ctx = CtxIndex(0, aligned, volLow ? 1 : 0, session);
      if(CtxBlocked(ctx))
      {
         CtxBlockedTrades++;
         Print("JB ADPT ctx ", ctx, " BLOCKED (learned expR ",
               DoubleToString(CtxExpectancy(ctx), 3), ") - S0 skipped");
      }
      else
      {
         OpenSetupTrade(0, 1, ctx, atr1, tpMult, CtxRiskMult(ctx));
         return;
      }
   }

   // ---- S1: SELL fade (bear regime ONLY - hard rule) ----
   // S1 and S2 are both shorts and correlate; allow only one at a time.
   if(!bull && close1 >= upper && rsi1 >= rsiSell &&
      FindOpenBySetup(1) < 0 && FindOpenBySetup(2) < 0 &&
      now >= SetupPausedUntil[1])
   {
      int ctx = CtxIndex(1, 1, volLow ? 1 : 0, session);
      if(CtxBlocked(ctx))
      {
         CtxBlockedTrades++;
         Print("JB ADPT ctx ", ctx, " BLOCKED (learned expR ",
               DoubleToString(CtxExpectancy(ctx), 3), ") - S1 skipped");
      }
      else
      {
         OpenSetupTrade(1, -1, ctx, atr1, tpMult, CtxRiskMult(ctx));
         return;
      }
   }

   // ---- S2: SELL after an up-bar streak in the bear regime ----
   if(InpEnableStreakSell && !bull &&
      FindOpenBySetup(2) < 0 && FindOpenBySetup(1) < 0 &&
      now >= SetupPausedUntil[2])
   {
      int need = MathMin(8, InpStreakBars);
      bool streak = true;
      double obuf[8], cbuf[8];
      if(CopyOpen(_Symbol, InpTimeframe, 1, need, obuf) == need &&
         CopyClose(_Symbol, InpTimeframe, 1, need, cbuf) == need)
      {
         for(int i = 0; i < need; i++)
            if(cbuf[i] <= obuf[i]) { streak = false; break; }
      }
      else
         streak = false;

      if(streak)
      {
         int ctx = CtxIndex(2, 1, volLow ? 1 : 0, session);
         if(CtxBlocked(ctx))
         {
            CtxBlockedTrades++;
            Print("JB ADPT ctx ", ctx, " BLOCKED (learned expR ",
                  DoubleToString(CtxExpectancy(ctx), 3), ") - S2 skipped");
         }
         else
            OpenSetupTrade(2, -1, ctx, atr1, 1.3, CtxRiskMult(ctx));
      }
   }
}

//====================================================================
// DISPLAY
//====================================================================

void DisplayStatus()
{
   if(IsTester && !MQLInfoInteger(MQL_VISUAL_MODE)) return;

   RefreshDayStats();

   string text = "JB ORION ADAPTIVE v1.00 | " + _Symbol + "\n";
   text += "Variant " + IntegerToString(ActiveVariant) +
           " (dev " + DoubleToString(Variants[ActiveVariant].dev, 1) +
           " rsi " + DoubleToString(Variants[ActiveVariant].rsiBuy, 0) +
           ") | switches " + IntegerToString(VariantSwitches) + "\n";
   text += "Open " + IntegerToString(CountMyPositions()) + "/" +
           IntegerToString(InpMaxPositions) +
           " | closed " + IntegerToString(TotalClosed);
   if(TotalClosed > 0)
      text += " | win " + DoubleToString(
              100.0 * TotalWins / TotalClosed, 1) + "%";
   text += "\n";
   text += "Curve sumR " + DoubleToString(RealRSum(), 2) +
           " | throttle x" +
           DoubleToString(EquityThrottleMult(), 2) + "\n";
   text += "Ledger blocks so far: " +
           IntegerToString(CtxBlockedTrades) + "\n";

   datetime now = TimeCurrent();
   if(now < HaltUntil)
      text += "HALTED until " +
              TimeToString(HaltUntil, TIME_DATE | TIME_MINUTES);
   else if(now < CooldownUntil)
      text += "COOLDOWN until " +
              TimeToString(CooldownUntil, TIME_MINUTES);
   else
      text += "READY";

   Comment(text);
}

//====================================================================
// LIFECYCLE
//====================================================================

int OnInit()
{
   IsTester = (bool)MQLInfoInteger(MQL_TESTER);

   if(InpBandPeriod < 2 || InpRSIPeriod < 2 || InpATRPeriod < 2 ||
      InpD1EMAPeriod < 2)
      return INIT_PARAMETERS_INCORRECT;

   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
   {
      Print("InpRiskPercent must be between 0 and 5.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpATRMultSL <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpMaxPositions < 1 || InpMaxPositions > 8)
      return INIT_PARAMETERS_INCORRECT;

   if(InpVirtualWindow < 5 || InpVirtualWindow > 80)
   {
      Print("InpVirtualWindow must be 5..80.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpThrottleWindow < 5 || InpThrottleWindow > 64)
   {
      Print("InpThrottleWindow must be 5..64.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Variants[0].dev = InpVarA_Dev; Variants[0].rsiBuy = InpVarA_RSI;
   Variants[0].tpMult = InpVarA_TP;
   Variants[1].dev = InpVarB_Dev; Variants[1].rsiBuy = InpVarB_RSI;
   Variants[1].tpMult = InpVarB_TP;
   Variants[2].dev = InpVarC_Dev; Variants[2].rsiBuy = InpVarC_RSI;
   Variants[2].tpMult = InpVarC_TP;

   for(int v = 0; v < N_VARIANTS; v++)
   {
      if(Variants[v].dev <= 0.0 || Variants[v].tpMult <= 0.0 ||
         Variants[v].rsiBuy <= 0.0 || Variants[v].rsiBuy >= 50.0)
      {
         Print("Variant ", v, " parameters invalid.");
         return INIT_PARAMETERS_INCORRECT;
      }
      Variants[v].handle = iBands(_Symbol, InpTimeframe, InpBandPeriod,
                                  0, Variants[v].dev, PRICE_CLOSE);
      if(Variants[v].handle == INVALID_HANDLE)
      {
         Print("Band handle creation failed for variant ", v);
         return INIT_FAILED;
      }
      VTrades[v].open = false;
      VCount[v] = 0;
      VHead[v]  = 0;
   }

   ActiveVariant = MathMax(0, MathMin(N_VARIANTS - 1, InpStartVariant));

   RSIHandle   = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   ATRHandle   = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   D1EMAHandle = iMA(_Symbol, PERIOD_D1, InpD1EMAPeriod, 0,
                     MODE_EMA, PRICE_CLOSE);

   if(RSIHandle == INVALID_HANDLE || ATRHandle == INVALID_HANDLE ||
      D1EMAHandle == INVALID_HANDLE)
   {
      Print("Indicator handle creation failed.");
      return INIT_FAILED;
   }

   if(InpEnableM15Fade)
   {
      M15BandsHandle = iBands(_Symbol, PERIOD_M15, InpBandPeriod, 0,
                              InpM15BandDev, PRICE_CLOSE);
      M15RSIHandle   = iRSI(_Symbol, PERIOD_M15, InpRSIPeriod,
                            PRICE_CLOSE);
      if(M15BandsHandle == INVALID_HANDLE ||
         M15RSIHandle == INVALID_HANDLE)
      {
         Print("M15 indicator handle creation failed.");
         return INIT_FAILED;
      }
   }

   trade.SetAsyncMode(false);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   for(int s = 0; s < N_SETUPS; s++)
   {
      SetupStreak[s]      = 0;
      SetupPausedUntil[s] = 0;
   }
   for(int i = 0; i < N_CTX; i++)
   {
      Ctx[i].n = 0.0; Ctx[i].wins = 0.0; Ctx[i].sumR = 0.0;
   }

   SeedPriors();
   LoadBrain();

   PeakEquity = MathMax(PeakEquity, AccountInfoDouble(ACCOUNT_EQUITY));
   RefreshDayStats(true);

   Print("==============================================");
   Print("JB ORION ADAPTIVE v1.00 LOADED | ", _Symbol);
   Print("Setups = S0 buy fade (both regimes) | S1 sell fade",
         " (bear only) | S2 streak sell x", InpStreakBars);
   Print("Learning = ledger ", InpUseContextLedger ? "ON" : "off",
         " (block<", DoubleToString(InpCtxBlockExpR, 2),
         "R after ", InpCtxMinSamples, ") | self-tune ",
         InpUseSelfTune ? "ON" : "off",
         " | throttle ", InpUseEquityThrottle ? "ON" : "off");
   Print("Risk   = ", DoubleToString(InpRiskPercent, 2),
         "%/trade x ctx x throttle | maxPos ", InpMaxPositions,
         " | daily ", DoubleToString(InpDailyLossLimitPercent, 1),
         "% | total DD ",
         DoubleToString(InpTotalDDGuardPercent, 1), "%");
   Print("==============================================");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SaveBrain();

   for(int v = 0; v < N_VARIANTS; v++)
      if(Variants[v].handle != INVALID_HANDLE)
         IndicatorRelease(Variants[v].handle);

   if(RSIHandle != INVALID_HANDLE)   IndicatorRelease(RSIHandle);
   if(ATRHandle != INVALID_HANDLE)   IndicatorRelease(ATRHandle);
   if(D1EMAHandle != INVALID_HANDLE) IndicatorRelease(D1EMAHandle);
   if(M15BandsHandle != INVALID_HANDLE) IndicatorRelease(M15BandsHandle);
   if(M15RSIHandle != INVALID_HANDLE)   IndicatorRelease(M15RSIHandle);

   Comment("");

   if(TotalClosed > 0)
      Print("JB ADPT session summary: ", TotalClosed, " trades, win ",
            DoubleToString(100.0 * TotalWins / TotalClosed, 1),
            "%, ledger blocks ", CtxBlockedTrades,
            ", variant switches ", VariantSwitches);
}

void OnTick()
{
   UpdatePeakEquity();

   if(!TradingAllowed())
   {
      DisplayStatus();
      return;
   }

   if(CountMyPositions() > 0 && TotalDDGuardHit())
   {
      TriggerTotalDDHalt();
      DisplayStatus();
      return;
   }

   ManageOpenPositions();
   TryEnter();
   TryEnterM15();
   DisplayStatus();
}

//+------------------------------------------------------------------+
//| Optimization criterion: maximise profit inside the DD budget.     |
//| Rejects configs that breach ~7% equity DD or trade too rarely,    |
//| so the optimiser cannot "win" by simply taking more leverage.     |
//+------------------------------------------------------------------+
double OnTester()
{
   double profit = TesterStatistics(STAT_PROFIT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double trades = TesterStatistics(STAT_TRADES);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);

   if(trades < 300)  return -1000.0 + trades;   // must stay active (~7/mo over 44 months)
   if(dd     > 7.0)  return -500.0  - dd;       // hard drawdown budget
   if(profit <= 0)   return profit / 1000.0;

   return profit * MathMin(pf, 2.5) / (1.0 + dd) / 100.0;
}
//+------------------------------------------------------------------+
