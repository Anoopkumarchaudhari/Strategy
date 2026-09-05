//+------------------------------------------------------------------+
//|                                                  ASCRR_Desk8.mq5 |
//|  ASCRR Desk: EURUSD dual-residual reversion  +  XAUUSD H1        |
//|  long-momentum sleeve, in one EA under one risk constitution.    |
//|                                                                  |
//|  Research EA. Fades EURUSD moves that are abnormal RELATIVE TO   |
//|  a cross-market fair value estimated from six USD pairs (and an  |
//|  optional rates-differential symbol). Dual engines:              |
//|    F = fast residual shock (trailing 15-minute window, M5 bars)  |
//|    S = session fair-value gap (cumulative from session open)     |
//|  Confirmation modes, dynamic percentile thresholds, structural   |
//|  stops, residual-gap profit taking, statistical re-arm, and a    |
//|  full risk constitution per the ASCRR-EU specification.          |
//|                                                                  |
//|  This EA mirrors the Python research backtester ascrr_core.py    |
//|  one-to-one. Default inputs = the research-improved configuration|
//|  (see accompanying report); spec-literal values are given in     |
//|  comments beside each input.                                     |
//|                                                                  |
//|  IMPORTANT: research strategy. Not proven profitable. Use the    |
//|  Strategy Tester and demo first. All 7 symbols must be in        |
//|  Market Watch with M5 history downloaded.                        |
//+------------------------------------------------------------------+
#property copyright "ASCRR-EU research build"
#property version   "2.80"

#include <Trade/Trade.mqh>

//--- enums -----------------------------------------------------------
enum ENUM_CONF_MODE
  {
   CONF_FULL  = 0,   // Full spec confirmation (z-drop + momentum flip + stall)
   CONF_LIGHT = 1,   // Light: stall only (1 bar without new extreme)
   CONF_NONE  = 2    // None: enter on threshold-crossing bar close
  };

enum ENUM_COHER_MODE
  {
   COHER_MIN = 0,    // Spec: require >= CoherMin pairs agreeing with factor
   COHER_MAX = 1,    // Inverted: fade only idiosyncratic moves (<= CoherMax agree)
   COHER_OFF = 2     // Disabled
  };

enum ENUM_REARM_MODE
  {
   REARM_BAND    = 0,  // Spec: wait for |z| < band after every exit
   REARM_RECROSS = 1,  // Frequency mode: fresh threshold crossings re-arm
  };

enum ENUM_TZ_MODE
  {
   TZ_AUTO    = 0,   // Live: TimeGMT-based. Tester: falls back to EET rule
   TZ_EET_DST = 1,   // Server = GMT+2, GMT+3 during US DST (Pepperstone-style)
   TZ_FIXED   = 2    // Fixed offset (InpFixedOffsetMin)
  };

//--- inputs ----------------------------------------------------------
input group "=== Symbols ==="
input string InpComparisonSymbols = "EURUSD,GBPUSD,AUDUSD,NZDUSD,USDJPY,USDCHF,USDCAD"; // symbol universe (chart symbol auto-excluded)
input string InpInvertList        = "USDJPY,USDCHF,USDCAD"; // pairs inverted so + = USD weakness
input string InpRatesSymbol       = "";       // optional EUR-US 2y rate-diff symbol ("" = off)
input bool   InpRatesInvert       = false;    // invert rates symbol sign

input group "=== Engines / sessions ==="
input bool   InpUseFast     = true;           // fast residual-shock engine
input bool   InpUseSess     = false;          // session fair-value-gap engine (spec: true)
input bool   InpUseLdnFast  = false;          // London fast window          (spec: true)
input bool   InpUseNyFast   = true;           // New York fast window
input bool   InpUseLdnSess  = false;          // London session window       (spec: true)
input bool   InpUseNySess   = false;          // New York session window     (spec: true)
input int    InpLdnFastA    = 435;            // London fast from, min of day (07:15)
input int    InpLdnFastB    = 630;            // London fast to   (10:30)
input int    InpLdnSessA    = 450;            // London sess from (07:30)
input int    InpLdnSessB    = 690;            // London sess to   (11:30)
input int    InpNyFastA     = 525;            // NY fast from     (08:45)
input int    InpNyFastB     = 690;            // NY fast to       (11:30)
input int    InpNySessA     = 540;            // NY sess from     (09:00)
input int    InpNySessB     = 720;            // NY sess to       (12:00)

input group "=== Factor model ==="
input int    InpHlVolBars   = 1152;           // EWMA halflife: per-pair 15m vol (bars)
input int    InpHlBetaBars  = 2880;           // EWMA halflife: beta cov/var (bars)
input double InpClipX       = 5.0;            // standardized-move clip
input double InpBetaLo      = 0.0;            // beta clip low
input double InpBetaHi      = 2.5;            // beta clip high
input int    InpWarmupBars  = 4000;           // min bars before trading

input group "=== Z-scoring ==="
input int    InpZbWindow    = 900;            // fast z: obs per (session,hour) bucket
input int    InpZbMin       = 150;            // fast z: min obs
input int    InpSessBinBars = 6;              // session z: elapsed bin size (bars)
input int    InpZsWindow    = 360;            // session z: obs per (session,bin)
input int    InpZsMin       = 90;             // session z: min obs

input group "=== Dynamic thresholds ==="
input int    InpThrDays     = 90;             // trailing days for percentile
input double InpFastPctl    = 90.0;           // fast threshold percentile (spec: 95)
input double InpFastLo      = 1.70;           // fast threshold clamp lo
input double InpFastHi      = 2.30;           // fast threshold clamp hi
input double InpSessPctl    = 97.5;           // session threshold percentile
input double InpSessLo      = 1.90;           // session threshold clamp lo
input double InpSessHi      = 2.60;           // session threshold clamp hi

input group "=== Confirmation ==="
input ENUM_CONF_MODE InpConfMode = CONF_NONE; // confirmation mode (spec: CONF_FULL)
input double InpConfMinDrop = 0.30;           // min z-drop from peak (full mode)
input double InpConfDropFrac= 0.175;          // fraction-of-peak drop (full mode)
input double InpCancelZ     = 1.00;           // setup cancels below this |z|
input int    InpSetupMaxF   = 24;             // fast setup expiry (bars)
input int    InpSetupMaxS   = 72;             // session setup expiry (bars)

input group "=== Trend filter ==="
input bool   InpUseTrend    = true;
input int    InpEffBars     = 6;              // residual efficiency window (~30m)
input double InpTauHard     = 2.5;            // 4h-trend hard block
input double InpTauSoft     = 1.5;            // soft block with eff+persist
input double InpEffHi       = 0.75;
input double InpPersistHi   = 0.70;
input double InpTauExit     = 2.8;            // 4h trend confirms continuation -> exit
input double InpRedirectEff = 0.80;           // residual re-directional -> exit

input group "=== Volatility filter ==="
input bool   InpUseVol      = true;
input int    InpVolDays     = 90;             // trailing days for percentile
input double InpVolNoneLo   = 15.0;           // below: no trade        (spec: 15)
input double InpVolSessOnly = 20.0;           // 15-20: session only    (spec: 20)
input double InpVolFastOnly = 75.0;           // 75-85: fast only       (spec: 75)
input double InpVolNoneHi   = 75.0;           // above: no new trades   (spec: 85)
input double InpVolCrisis   = 99.5;           // emergency regime -> exit
input double InpFastHiVolSize = 0.5;          // size mult in 75-85 band

input group "=== Coherence filter ==="
input ENUM_COHER_MODE InpCoherMode = COHER_MAX; // (spec: COHER_MIN)
input int    InpCoherMin    = 4;              // >= pairs agreeing (COHER_MIN mode)
input int    InpCoherMax    = 3;              // <= pairs agreeing (COHER_MAX mode)
input double InpCoherEps    = 0.10;           // |x| above this counts as a vote

input group "=== News / time blocks ==="
input bool   InpUseNews       = true;
input bool   InpNewsForceFlat = true;         // force-flat around tier-1 releases
input int    InpNewsPreMin    = 30;           // calendar block: minutes before
input int    InpNewsPostMin   = 45;           // calendar block: minutes after
input bool   InpBlock0830ET   = true;         // daily 08:00ET data block
input int    InpBlock0830EndMin = 555;        // block end, NY minutes (555=09:15; freq mode: 540)
input int    InpFixBlockA     = 945;          // London-fix block from (15:45 London)
input int    InpFixBlockB     = 975;          // London-fix block to   (16:15 London)
input int    InpLateNyMin     = 960;          // no entries after (16:00 NY)
input int    InpFlatNyMin     = 1005;         // force flat daily (16:45 NY)

input group "=== Spread / data quality ==="
input bool   InpUseSpread     = true;
input double InpSpreadMultCap = 2.0;          // vs 20-day median
input double InpSpreadAbsCapP = 1.2;          // absolute cap (pips)
input int    InpFreshMaxLag   = 3;            // max comparison-bar age (bars)

input group "=== Position / risk (per $100k) ==="
input double InpLotsPer100k   = 3.0;          // reference lots per $100k equity
input double InpRiskCapUsd    = 500.0;        // absolute planned risk ceiling
input double InpMaxStopPips   = 16.7;         // reject wider structural stops
input double InpBufMinPips    = 1.5;          // stop buffer floor
input double InpBufRngFrac    = 0.20;         // buffer = frac of normal 15m range
input int    InpRngDays       = 20;           // 'normal range' lookback days

input group "=== Profit taking / exits ==="
input double InpTp1GapFrac    = 0.50;         // TP1 at this gap-closure (spec: 0.60)
input double InpTp2GapFrac    = 0.85;         // TP2 at this gap-closure
input double InpTp1CloseFrac  = 0.667;        // fraction closed at TP1
input double InpGapExpandStop = 1.35;         // exit if gap >= x * setup extreme
input double InpFrozenZStop   = 3.25;         // exit at frozen |z|
input int    InpTimeStopFmin  = 120;          // fast engine time stop (min)
input int    InpTimeStopSmin  = 360;          // session engine time stop (min)
input int    InpProgFmin      = 30;           // fast progress test at (min)
input int    InpProgSmin      = 90;           // session progress test at (min)
input double InpProgMinClosed = 0.10;         // min gap-closure at progress test
input double InpRearmBand     = 0.75;         // |z| must re-enter band to re-arm
input ENUM_REARM_MODE InpRearmMode = REARM_BAND; // re-arm rule (RECROSS = frequency mode)

input group "=== Risk constitution (per $100k) ==="
input double InpRUsd          = 500.0;        // 1R
input double InpDailyStopR    = 2.0;
input double InpWeeklyStopR   = 4.0;
input double InpMonthlyStopR  = 6.0;
input bool   InpUseRiskLadder = true;         // consecutive-loss ladder
input double InpConsec4Mult   = 0.5;          // halve size after 4 losses
input bool   InpConsec6Halt   = true;         // halt to month-end after 6
input bool   InpConsec8Susp   = true;         // suspend after 8

input group "=== Desk caps (built-in PortfolioGuard mirror - works in tester) ==="
input bool   InpDeskCapsOn      = true;       // enforce desk-level loss caps inside this EA
input double InpDeskDailyR      = 8.0;        // desk daily loss cap (R of InpRUsd, 0 = off)
input double InpDeskWeeklyR     = 12.0;       // desk weekly loss cap (R, 0 = off)
input double InpDeskMonthlyR    = 18.0;       // desk monthly loss cap (R, 0 = off)
input double InpDeskFloorPct    = 8.0;        // flatten all below month-start equity - X% (0 = off)
input bool   InpDeskUseFloating = true;       // caps use realized + floating (guard parity)
input bool   InpDeskFlatten     = true;       // close all desk positions on breach (else suppress only)

datetime g_dc_next = 0;
int      g_dc_month = -1;
int      g_dc_sup_day = -1, g_dc_sup_week = -1, g_dc_sup_month = -1;
double   g_dc_m_equity0 = 0.0;
double   g_dc_real_d = 0, g_dc_real_w = 0, g_dc_real_m = 0, g_dc_float = 0;

input group "=== Execution ==="
input long   InpMagic         = 26082901;
input bool   InpRespectGuard   = true;        // obey PortfolioGuard PG_SUP_*/PG_SCALE_* flags
input string InpComment       = "ASCRR-EU";
input int    InpDeviationPts  = 20;           // max deviation (points)
input double InpExtraSlipPips = 0.20;         // modeled extra stop slippage (reporting only)
input ENUM_TZ_MODE InpTzMode  = TZ_EET_DST;   // server-to-UTC mode
input int    InpFixedOffsetMin= 120;          // fixed server-UTC offset (TZ_FIXED)
input bool   InpVerboseLog    = true;

//--- constants -------------------------------------------------------
#define NCOMP_MAX 8
#define W15 3
#define PIPPT 0.0001
#define BAR_SEC 300

//--- globals ---------------------------------------------------------
CTrade   g_trade;
string   g_sym;                        // traded symbol (EURUSD)
string   g_comp[NCOMP_MAX];
bool     g_inv[NCOMP_MAX];
int      g_ncomp = 0;
bool     g_use_rates = false;
datetime g_last_bar = 0;
bool     g_ready = false;
int      g_bars_seen = 0;
double   g_pip = PIPPT;
double   g_point = 0.00001;
double   g_sign_t = 1.0;               // -1 when chart symbol is USD-base (synthetic inversion)

// per-bar aligned series (chronological ring buffer)
#define HIST 8192                       // power of two ring
int      g_h = 0;                       // number of bars stored
datetime g_t[HIST];
double   g_o[HIST], g_hi[HIST], g_lo[HIST], g_c[HIST];
double   g_spreadPts[HIST];
double   g_resid[HIST];                 // per-bar 15m residual (NaN-able)
double   g_cumR[HIST];                  // global cumulative residual
double   g_zF[HIST];
double   g_tau[HIST];
bool     g_fresh[HIST];

#define IDX(k) (((k) % HIST + HIST) % HIST)

// EWMA state per input series (comparisons + EUR + rates)
struct EwmaSt { double m, v; long n; };
EwmaSt   g_vol[NCOMP_MAX + 2];          // 15m-return mean/var per pair (idx ncomp=EUR, ncomp+1=rates)
EwmaSt   g_mF, g_mY, g_mP;              // factor mean, eur mean, product mean (univariate beta)
EwmaSt   g_mR, g_mPR, g_mFR;            // rates factor moments (bivariate extension)
EwmaSt   g_r4;                          // 4h return mean/var
double   g_lam_vol, g_lam_beta;

// close history per comparison symbol for 15m returns (small ring)
double   g_prevLog[NCOMP_MAX + 2][4];   // last 4 log-closes per series
int      g_prevN[NCOMP_MAX + 2];

// z buckets: fast (session,hour) -> ring of residuals
#define ZB_CAP 1024
struct Bucket { double v[ZB_CAP]; int n; int w; double sum, sum2; };
Bucket   g_zbF[48];                     // 0-23 London hours (sess1), 24-47 NY hours (sess2)
Bucket   g_zbS[32];                     // session bins: 0-15 LDN, 16-31 NY

// threshold pools: |z| observations with day stamp
#define TH_CAP 16384
struct DayPool
  {
   double v[TH_CAP];
   int    day[TH_CAP];
   int    n, w;
  };
DayPool  g_poolF, g_poolS, g_poolVol1, g_poolVol2, g_poolRng, g_poolSp;
double   g_TF, g_TS;                    // current thresholds
double   g_volPct;                      // today's cached percentile inputs
double   g_normRng, g_medSp;
int      g_lastStatDay = -1;
double   g_volSorted1[TH_CAP], g_volSorted2[TH_CAP];
int      g_volSortedN1 = 0, g_volSortedN2 = 0;

// session anchors
int      g_ldnAnchor = -1, g_nyAnchor = -1;   // absolute bar index of session start
int      g_lastLdnDay = -1, g_lastNyDay = -1;

// setup state
struct Setup
  {
   bool   active;
   int    dir;            // -1 sell, +1 buy (actual trade side)
   int    d_synth;        // synthetic-space direction (z sign)
   int    start;          // absolute bar index
   double peak_z;
   double ext_px;
   int    last_ext_i;
   int    anchor;         // absolute bar index for gap measure
   double extreme_gap;
  };
Setup    g_setF, g_setS;
bool     g_rearm_wait = false;

// open-position bookkeeping (mirror of broker state)
struct PosBook
  {
   bool   open;
   long   dir;
   long   d_synth;
   string engine;
   datetime t_entry;
   int    i_entry;        // absolute bar index
   double entry_px, sl;
   double vol0, vol;
   int    anchor;
   double entry_gap, extreme_gap, fr_sd;
   bool   tp1_done;
   double stop_pips;
  };
PosBook  g_pos;

// risk governor
double   g_pnl_day = 0, g_pnl_week = 0, g_pnl_month = 0;
int      g_cur_day = -1, g_cur_week = -1, g_cur_month = -1;
int      g_consec_losses = 0;
double   g_size_mult = 1.0;
int      g_halt_month = -1;
bool     g_suspended = false;

// news
datetime g_cal_from = 0;
datetime g_news_block_until = 0;

// embedded tier-1 decision days (FOMC 14:00 ET; ECB 14:15 CET) - tester fallback
string   g_fomc[] = {
  "2022.11.02","2022.12.14","2023.02.01","2023.03.22","2023.05.03","2023.06.14",
  "2023.07.26","2023.09.20","2023.11.01","2023.12.13","2024.01.31","2024.03.20",
  "2024.05.01","2024.06.12","2024.07.31","2024.09.18","2024.11.07","2024.12.18",
  "2025.01.29","2025.03.19","2025.05.07","2025.06.18","2025.07.30","2025.09.17",
  "2025.10.29","2025.12.10","2026.01.28","2026.03.18","2026.04.29","2026.06.17",
  "2026.07.29","2026.09.16"};
string   g_ecb[] = {
  "2022.10.27","2022.12.15","2023.02.02","2023.03.16","2023.05.04","2023.06.15",
  "2023.07.27","2023.09.14","2023.10.26","2023.12.14","2024.01.25","2024.03.07",
  "2024.04.11","2024.06.06","2024.07.18","2024.09.12","2024.10.17","2024.12.12",
  "2025.01.30","2025.03.06","2025.04.17","2025.06.05","2025.07.24","2025.09.11",
  "2025.10.30","2025.12.18","2026.02.05","2026.03.19","2026.04.30","2026.06.11",
  "2026.07.23","2026.09.10","2026.10.29","2026.12.17"};

//+------------------------------------------------------------------+
//| Math / small helpers                                             |
//+------------------------------------------------------------------+
double NaN() { static double x = MathLog(-1.0); return x; }
bool   IsNaN(double v) { return MathIsValidNumber(v) == false; }

double Lam(int halflife) { return MathPow(0.5, 1.0 / MathMax(1, halflife)); }

void EwmaInit(EwmaSt &e) { e.m = 0; e.v = 0; e.n = 0; }

// returns previous (pre-update) mean/var through out params  -> strictly causal
void EwmaUse(EwmaSt &e, double lam, double x, double &prev_m, double &prev_v)
  {
   prev_m = (e.n > 0 ? e.m : NaN());
   prev_v = (e.n > 1 ? e.v : NaN());
   if(!IsNaN(x))
     {
      if(e.n == 0) { e.m = x; e.v = 0; }
      else
        {
         double d = x - e.m;
         e.m += (1.0 - lam) * d;
         e.v = lam * (e.v + (1.0 - lam) * d * d);
        }
      e.n++;
     }
  }

void BucketInit(Bucket &b) { b.n = 0; b.w = 0; b.sum = 0; b.sum2 = 0; }

void BucketStats(Bucket &b, int minN, double &mu, double &sd)
  {
   if(b.n < minN) { mu = NaN(); sd = NaN(); return; }
   mu = b.sum / b.n;
   double var = (b.sum2 - b.n * mu * mu) / MathMax(1, b.n - 1);
   sd = (var > 1e-12 ? MathSqrt(var) : NaN());
  }

void BucketPush(Bucket &b, double v, int cap)
  {
   if(cap > ZB_CAP) cap = ZB_CAP;
   if(b.n >= cap)
     {
      double old = b.v[b.w];
      b.sum -= old; b.sum2 -= old * old;
     }
   else b.n++;
   b.v[b.w] = v; b.sum += v; b.sum2 += v * v;
   b.w = (b.w + 1) % cap;
  }

void PoolInit(DayPool &pl) { pl.n = 0; pl.w = 0; }

void PoolPush(DayPool &pl, double v, int dayk)
  {
   if(pl.n >= TH_CAP) { /* overwrite oldest */ }
   else pl.n++;
   pl.v[pl.w] = v; pl.day[pl.w] = dayk;
   pl.w = (pl.w + 1) % TH_CAP;
  }

// percentile of pool values from the last `days` day-keys, excluding today
double PoolPercentile(DayPool &pl, int today, int days, double pct, int minObs, double dflt)
  {
   static double tmp[];
   ArrayResize(tmp, pl.n);
   int m = 0;
   for(int k = 0; k < pl.n; k++)
     {
      int dk = pl.day[k];
      if(dk < today && dk >= today - days * 2)   // *2: day keys skip weekends
         tmp[m++] = pl.v[k];
     }
   if(m < minObs) return dflt;
   ArrayResize(tmp, m);
   ArraySort(tmp);
   int pos = (int)MathFloor(pct / 100.0 * (m - 1));
   if(pos < 0) pos = 0;
   if(pos >= m) pos = m - 1;
   return tmp[pos];
  }

int PoolExtractSorted(DayPool &pl, int today, int days, double &dst[])
  {
   int m = 0;
   for(int k = 0; k < pl.n; k++)
     {
      int dk = pl.day[k];
      if(dk < today && dk >= today - days * 2)
         dst[m++] = pl.v[k];
     }
   if(m > 1)
     {
      static double tmp[];
      ArrayResize(tmp, m);
      for(int k = 0; k < m; k++) tmp[k] = dst[k];
      ArraySort(tmp);
      for(int k = 0; k < m; k++) dst[k] = tmp[k];
     }
   return m;
  }

double SortedRankPct(double &arr[], int n, double v)
  {
   if(n < 100) return 50.0;
   int lo = 0, hi = n;
   while(lo < hi) { int mid = (lo + hi) / 2; if(arr[mid] < v) lo = mid + 1; else hi = mid; }
   return 100.0 * lo / n;
  }

double PoolMedianRecent(DayPool &pl, int today, int days, double dflt, int minObs)
  {
   static double tmp[];
   ArrayResize(tmp, pl.n);
   int m = 0;
   for(int k = 0; k < pl.n; k++)
      if(pl.day[k] < today && pl.day[k] >= today - days * 2)
         tmp[m++] = pl.v[k];
   if(m < minObs) return dflt;
   ArrayResize(tmp, m);
   ArraySort(tmp);
   return tmp[m / 2];
  }

//+------------------------------------------------------------------+
//| Time zone machinery                                              |
//+------------------------------------------------------------------+
// day-of-week for a civil date (0=Sun..6=Sat)
int DowOf(int y, int m, int d)
  {
   static int tt[12] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
   if(m < 3) y -= 1;
   return (y + y / 4 - y / 100 + y / 400 + tt[m - 1] + d) % 7;
  }

datetime MkUtc(int y, int m, int d, int hh, int mm)
  {
   MqlDateTime s; s.year = y; s.mon = m; s.day = d; s.hour = hh; s.min = mm; s.sec = 0;
   return StructToTime(s);   // struct assembled as if UTC; used consistently
  }

// US DST bounds for a year, as UTC datetimes
void UsDstBounds(int y, datetime &dst_on, datetime &dst_off)
  {
   int w = DowOf(y, 3, 1);                 // 0=Sun
   int firstSun = 1 + (7 - w) % 7;
   dst_on  = MkUtc(y, 3, firstSun + 7, 7, 0);   // 2nd Sun Mar 02:00 EST = 07:00 UTC
   w = DowOf(y, 11, 1);
   firstSun = 1 + (7 - w) % 7;
   dst_off = MkUtc(y, 11, firstSun, 6, 0);      // 1st Sun Nov 02:00 EDT = 06:00 UTC
  }

// EU (London) DST bounds for a year, as UTC datetimes
void EuDstBounds(int y, datetime &dst_on, datetime &dst_off)
  {
   int w = DowOf(y, 3, 31);
   int lastSun = 31 - (w % 7);
   dst_on = MkUtc(y, 3, lastSun, 1, 0);         // last Sun Mar 01:00 UTC
   w = DowOf(y, 10, 31);
   lastSun = 31 - (w % 7);
   dst_off = MkUtc(y, 10, lastSun, 1, 0);       // last Sun Oct 01:00 UTC
  }

bool InUsDst(datetime utc)
  {
   MqlDateTime s; TimeToStruct(utc, s);
   datetime a, b; UsDstBounds(s.year, a, b);
   return (utc >= a && utc < b);
  }

bool InEuDst(datetime utc)
  {
   MqlDateTime s; TimeToStruct(utc, s);
   datetime a, b; EuDstBounds(s.year, a, b);
   return (utc >= a && utc < b);
  }

// broker/server time -> UTC
datetime ServerToUtc(datetime srv)
  {
   if(InpTzMode == TZ_FIXED)
      return srv - InpFixedOffsetMin * 60;
   if(InpTzMode == TZ_AUTO && !MQLInfoInteger(MQL_TESTER))
     {
      // live: measure current offset, assume constant intraday
      long off = (long)TimeTradeServer() - (long)TimeGMT();
      // round to nearest half hour
      off = (long)MathRound(off / 1800.0) * 1800;
      return srv - (datetime)off;
     }
   // EET-with-US-DST rule (GMT+2 winter, GMT+3 during US DST)
   datetime approx = srv - 7200;
   int offs = (InUsDst(approx) ? 10800 : 7200);
   return srv - offs;
  }

int LondonMinOfDay(datetime utc) { datetime lt = utc + (InEuDst(utc) ? 3600 : 0); MqlDateTime s; TimeToStruct(lt, s); return s.hour * 60 + s.min; }
int NyMinOfDay(datetime utc)     { datetime lt = utc - (InUsDst(utc) ? 14400 : 18000); MqlDateTime s; TimeToStruct(lt, s); return s.hour * 60 + s.min; }
int CetMinOfDay(datetime utc)    { datetime lt = utc + (InEuDst(utc) ? 7200 : 3600); MqlDateTime s; TimeToStruct(lt, s); return s.hour * 60 + s.min; }
int LondonHour(datetime utc)     { return LondonMinOfDay(utc) / 60; }
int NyHour(datetime utc)         { return NyMinOfDay(utc) / 60; }

int NyDow(datetime utc)
  {
   datetime lt = utc - (InUsDst(utc) ? 14400 : 18000);
   MqlDateTime s; TimeToStruct(lt, s);
   return s.day_of_week;                        // 0=Sun..6=Sat
  }

int NyDayKey(datetime utc)   { datetime lt = utc - (InUsDst(utc) ? 14400 : 18000); return (int)(lt / 86400); }
int NyDomOfMonth(datetime utc){ datetime lt = utc - (InUsDst(utc) ? 14400 : 18000); MqlDateTime s; TimeToStruct(lt, s); return s.day; }
int NyMonthKey(datetime utc) { datetime lt = utc - (InUsDst(utc) ? 14400 : 18000); MqlDateTime s; TimeToStruct(lt, s); return s.year * 100 + s.mon; }
int NyWeekKey(datetime utc)  { datetime lt = utc - (InUsDst(utc) ? 14400 : 18000); return (int)((lt / 86400 + 4) / 7); } // epoch-week, Thu-anchored
int UtcDayKey(datetime utc)  { return (int)(utc / 86400); }

string NyDateString(datetime utc)
  {
   datetime lt = utc - (InUsDst(utc) ? 14400 : 18000);
   MqlDateTime s; TimeToStruct(lt, s);
   return StringFormat("%04d.%02d.%02d", s.year, s.mon, s.day);
  }

//+------------------------------------------------------------------+
//| Session windows / calendar flags for a bar (UTC)                 |
//+------------------------------------------------------------------+
bool InLdnFast(datetime u) { int m = LondonMinOfDay(u); return m >= InpLdnFastA && m < InpLdnFastB; }
bool InLdnSess(datetime u) { int m = LondonMinOfDay(u); return m >= InpLdnSessA && m < InpLdnSessB; }
bool InNyFast(datetime u)  { int m = NyMinOfDay(u);     return m >= InpNyFastA  && m < InpNyFastB; }
bool InNySess(datetime u)  { int m = NyMinOfDay(u);     return m >= InpNySessA  && m < InpNySessB; }
bool InFixWin(datetime u)  { int m = LondonMinOfDay(u); return m >= InpFixBlockA && m < InpFixBlockB; }
bool LateNy(datetime u)    { return NyMinOfDay(u) >= InpLateNyMin; }
bool FlatEod(datetime u)   { return NyMinOfDay(u) >= InpFlatNyMin; }

// session id for z-conditioning: 0 none, 1 London, 2 NY  (widest window per venue)
int SessOf(datetime u)
  {
   int lm = LondonMinOfDay(u);
   int nm = NyMinOfDay(u);
   int la = MathMin(InpLdnFastA, InpLdnSessA), lb = MathMax(InpLdnFastB, InpLdnSessB);
   int na = MathMin(InpNyFastA, InpNySessA),  nb = MathMax(InpNyFastB, InpNySessB);
   if(lm >= la && lm < lb) return 1;
   if(nm >= na && nm < nb) return 2;
   return 0;
  }

bool IsDateIn(string d, string &arr[])
  {
   for(int k = 0; k < ArraySize(arr); k++)
      if(arr[k] == d) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| News blocks. Returns via refs: block new entries / force flat    |
//+------------------------------------------------------------------+
void NewsState(datetime u, bool &block, bool &flat)
  {
   block = false; flat = false;
   int nyM = NyMinOfDay(u);
   int cetM = CetMinOfDay(u);
   int dow = NyDow(u);

   // rule floor (works in tester where the economic calendar is unavailable)
   if(InpBlock0830ET && dow >= 1 && dow <= 5 && nyM >= 480 && nyM < InpBlock0830EndMin)
      block = true;                                          // 08:00 ET data block
   int dom = NyDomOfMonth(u);
   bool nfp = (dow == 5 && dom <= 7);
   if(nfp && nyM >= 465 && nyM < 585) block = true;          // 07:45-09:45 ET
   if(nfp && InpNewsForceFlat && nyM >= 500 && nyM < 555) flat = true; // 08:20-09:15

   string ds = NyDateString(u);
   if(IsDateIn(ds, g_fomc))
     {
      if(nyM >= 810 && nyM < 990) block = true;              // 13:30-16:30 ET
      if(InpNewsForceFlat && nyM >= 830 && nyM < 960) flat = true;
     }
   if(IsDateIn(ds, g_ecb))
     {
      if(cetM >= 825 && cetM < 960) block = true;            // 13:45-16:00 CET
      if(InpNewsForceFlat && cetM >= 845 && cetM < 945) flat = true;
     }
   // thin-holiday dates
   int md;
     {
      MqlDateTime s; TimeToStruct(u - (InUsDst(u) ? 14400 : 18000), s);
      md = s.mon * 100 + s.day;
     }
   if(md == 1224 || md == 1225 || md == 1226 || md == 1231 || md == 101 || md == 102 || md == 704)
      block = true;

   if(InFixWin(u)) block = true;
   if(LateNy(u)) block = true;
   if(FlatEod(u)) flat = true;

   // live economic calendar (skipped in tester where it is unavailable)
   if(!MQLInfoInteger(MQL_TESTER) && InpUseNews)
     {
      MqlCalendarValue vals[];
      datetime t0 = u - InpNewsPostMin * 60 - 3600;
      datetime t1 = u + InpNewsPreMin * 60 + 3600;
      if(CalendarValueHistory(vals, t0, t1, NULL, NULL) && ArraySize(vals) > 0)
        {
         for(int k = 0; k < ArraySize(vals); k++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(vals[k].event_id, ev)) continue;
            if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
            MqlCalendarCountry cn;
            if(!CalendarCountryById(ev.country_id, cn)) continue;
            if(cn.currency != "USD" && cn.currency != "EUR") continue;
            datetime evt = vals[k].time;
            // note: calendar times are TC (server) based; convert
            datetime evu = ServerToUtc(evt);
            if(u >= evu - InpNewsPreMin * 60 && u <= evu + InpNewsPostMin * 60)
               block = true;
            if(InpNewsForceFlat && u >= evu - 600 && u <= evu + InpNewsPostMin * 60)
               flat = true;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Data plumbing                                                    |
//+------------------------------------------------------------------+
double CompCloseAt(string sym, datetime t, bool &fresh)
  {
   fresh = false;
   int sh = iBarShift(sym, PERIOD_M5, t, false);
   if(sh < 0) return NaN();
   datetime bt = iTime(sym, PERIOD_M5, sh);
   if(bt > t)
     {
      sh++;                                   // iBarShift can return a newer bar
      bt = iTime(sym, PERIOD_M5, sh);
      if(sh < 0 || bt == 0) return NaN();
     }
   if(t - bt <= InpFreshMaxLag * BAR_SEC) fresh = true;
   double cl = iClose(sym, PERIOD_M5, sh);
   return (cl > 0 ? cl : NaN());
  }

// per-series 15-minute log return using pushed log-close history
double Ret15Of(int s, double logc)
  {
   double r = NaN();
   if(g_prevN[s] >= W15)
     {
      int idx = (g_prevN[s] - W15) % 4;       // value pushed W15 bars ago
      r = logc - g_prevLog[s][idx];
     }
   g_prevLog[s][g_prevN[s] % 4] = logc;
   g_prevN[s]++;
   return r;
  }

double MedianOf(double &a[], int n)
  {
   static double tmp[];
   ArrayResize(tmp, n);
   for(int k = 0; k < n; k++) tmp[k] = a[k];
   ArraySort(tmp);
   if(n == 0) return NaN();
   if(n % 2 == 1) return tmp[n / 2];
   return 0.5 * (tmp[n / 2 - 1] + tmp[n / 2]);
  }

//+------------------------------------------------------------------+
//| Per-bar feature state (globals filled by UpdateFeatures)         |
//+------------------------------------------------------------------+
int      g_abs = -1;                    // absolute bar counter (index into rings via IDX)
double   g_F[HIST];
double   g_zS_cur = 0;  bool g_zS_valid = false;
double   g_zF_cur = 0;  bool g_zF_valid = false;
double   g_coher = 0;
double   g_eff = 0, g_persistF = 0;
double   g_vol_pct_cur = 50.0;
double   g_sd15_pips = 0;
bool     g_block_new = false, g_force_flat = false;
int      g_sess_cur = 0;
double   g_beta_cur = 1.0;

double At(double &arr[], int absIdx) { return arr[IDX(absIdx)]; }
datetime AtT(datetime &arr[], int absIdx) { return arr[IDX(absIdx)]; }

//+------------------------------------------------------------------+
//| UpdateFeatures: ingest one closed EURUSD M5 bar                  |
//| bt = bar OPEN time (server); all z/threshold pushes are causal   |
//+------------------------------------------------------------------+
bool UpdateFeatures(datetime bt_srv, double o, double h, double l, double c, double sp_pts)
  {
   datetime u = ServerToUtc(bt_srv);
   g_abs++;
   int ix = IDX(g_abs);
   g_t[ix] = u; g_o[ix] = o; g_hi[ix] = h; g_lo[ix] = l; g_c[ix] = c;
   g_spreadPts[ix] = sp_pts;
   g_bars_seen++;

   int today = UtcDayKey(u);
   int sess = SessOf(u);
   g_sess_cur = sess;

   // ---- daily stat refresh (thresholds, vol pools, medians) ----
   if(today != g_lastStatDay)
     {
      g_TF = PoolPercentile(g_poolF, today, InpThrDays, InpFastPctl, 500, (InpFastLo + InpFastHi) / 2);
      if(g_TF < InpFastLo) g_TF = InpFastLo;
      if(g_TF > InpFastHi) g_TF = InpFastHi;
      g_TS = PoolPercentile(g_poolS, today, InpThrDays, InpSessPctl, 500, (InpSessLo + InpSessHi) / 2);
      if(g_TS < InpSessLo) g_TS = InpSessLo;
      if(g_TS > InpSessHi) g_TS = InpSessHi;
      g_volSortedN1 = PoolExtractSorted(g_poolVol1, today, InpVolDays, g_volSorted1);
      g_volSortedN2 = PoolExtractSorted(g_poolVol2, today, InpVolDays, g_volSorted2);
      g_normRng = PoolMedianRecent(g_poolRng, today, InpRngDays, 8.0, 200);
      g_medSp = PoolMedianRecent(g_poolSp, today, 20, 10.0, 200);
      g_lastStatDay = today;
     }

   // ---- news flags ----
   bool blk, flt;
   NewsState(u, blk, flt);
   g_block_new = blk; g_force_flat = flt;

   // ---- comparison closes + freshness ----
   double x[NCOMP_MAX];
   int nx = 0;
   bool freshAll = true;
   double lam_v = g_lam_vol;
   for(int s = 0; s < g_ncomp; s++)
     {
      bool fr;
      double cc = CompCloseAt(g_comp[s], bt_srv, fr);
      if(IsNaN(cc)) { freshAll = false; cc = (g_prevN[s] > 0 ? MathExp(g_prevLog[s][(g_prevN[s]-1)%4]) : 1.0); }
      if(!fr) freshAll = false;
      double r = Ret15Of(s, MathLog(cc));
      if(g_inv[s] && !IsNaN(r)) r = -r;
      double pm, pv;
      EwmaUse(g_vol[s], lam_v, r, pm, pv);
      double xs = NaN();
      if(!IsNaN(r) && !IsNaN(pm) && !IsNaN(pv) && pv > 1e-18)
        {
         xs = (r - pm) / MathSqrt(pv);
         if(xs > InpClipX) xs = InpClipX;
         if(xs < -InpClipX) xs = -InpClipX;
        }
      x[s] = xs;
      if(!IsNaN(xs)) nx++;
     }

   // ---- EURUSD standardized move ----
   double logc = MathLog(c);
   double rE = Ret15Of(g_ncomp, logc);
   if(g_sign_t < 0 && !IsNaN(rE)) rE = -rE;   // synthetic (+ = USD weakness) convention
   double pmE, pvE;
   EwmaUse(g_vol[g_ncomp], lam_v, rE, pmE, pvE);
   double y = NaN();
   if(!IsNaN(rE) && !IsNaN(pmE) && !IsNaN(pvE) && pvE > 1e-18)
     {
      y = (rE - pmE) / MathSqrt(pvE);
      if(y > InpClipX) y = InpClipX;
      if(y < -InpClipX) y = -InpClipX;
      g_sd15_pips = MathSqrt(pvE) * c / g_pip;
     }

   // ---- optional rates factor ----
   double xR = NaN();
   if(g_use_rates)
     {
      bool frR;
      double cr = CompCloseAt(InpRatesSymbol, bt_srv, frR);
      if(!IsNaN(cr) && cr > 0)
        {
         double rr = Ret15Of(g_ncomp + 1, MathLog(cr));
         if(InpRatesInvert && !IsNaN(rr)) rr = -rr;
         double pmR, pvR;
         EwmaUse(g_vol[g_ncomp + 1], lam_v, rr, pmR, pvR);
         if(!IsNaN(rr) && !IsNaN(pmR) && !IsNaN(pvR) && pvR > 1e-18)
           {
            xR = (rr - pmR) / MathSqrt(pvR);
            if(xR > InpClipX) xR = InpClipX;
            if(xR < -InpClipX) xR = -InpClipX;
           }
        }
     }

   // ---- broad USD factor: median of standardized comparisons ----
   double F = NaN();
   if(nx >= 4)
     {
      double tmp[NCOMP_MAX]; int m = 0;
      for(int s = 0; s < g_ncomp; s++) if(!IsNaN(x[s])) tmp[m++] = x[s];
      F = MedianOf(tmp, m);
     }
   g_F[ix] = (IsNaN(F) ? 0.0 : F);

   // coherence votes
   double coh = 0;
   if(!IsNaN(F))
     {
      double sgn = (F >= 0 ? 1.0 : -1.0);
      for(int s = 0; s < g_ncomp; s++)
         if(!IsNaN(x[s]) && MathAbs(x[s]) > InpCoherEps && x[s] * sgn > 0) coh += 1;
     }
   g_coher = coh;

   // ---- causal EWMA regression ----
   double lam_b = g_lam_beta;
   double mF_p, vF_p, mY_p, vY_p, mP_p, dumm;
   EwmaUse(g_mF, lam_b, F, mF_p, vF_p);
   EwmaUse(g_mY, lam_b, y, mY_p, vY_p);
   EwmaUse(g_mP, lam_b, (IsNaN(y) || IsNaN(F)) ? NaN() : y * F, mP_p, dumm);
   double resid = NaN();
   double beta = g_beta_cur;
   if(!IsNaN(y) && !IsNaN(F) && !IsNaN(mF_p) && !IsNaN(mY_p) && !IsNaN(mP_p) && !IsNaN(vF_p) && vF_p > 1e-12)
     {
      double cov = mP_p - mY_p * mF_p;
      beta = cov / vF_p;
      if(g_use_rates && !IsNaN(xR))
        {
         // bivariate extension
         double mR_p, vR_p, mPR_p, mFR_p;
         EwmaUse(g_mR, lam_b, xR, mR_p, vR_p);
         EwmaUse(g_mPR, lam_b, (IsNaN(y) ? NaN() : y * xR), mPR_p, dumm);
         EwmaUse(g_mFR, lam_b, (IsNaN(F) ? NaN() : F * xR), mFR_p, dumm);
         if(!IsNaN(mR_p) && !IsNaN(vR_p) && vR_p > 1e-12 && !IsNaN(mPR_p) && !IsNaN(mFR_p))
           {
            double cYF = cov;
            double cYR = mPR_p - mY_p * mR_p;
            double cFR = mFR_p - mF_p * mR_p;
            double det = vF_p * vR_p - cFR * cFR;
            if(MathAbs(det) > 1e-12)
              {
               double b1 = (cYF * vR_p - cYR * cFR) / det;
               double b2 = (cYR * vF_p - cYF * cFR) / det;
               if(b1 < InpBetaLo) b1 = InpBetaLo;
               if(b1 > InpBetaHi) b1 = InpBetaHi;
               resid = (y - mY_p) - b1 * (F - mF_p) - b2 * (xR - mR_p);
               beta = b1;
              }
           }
        }
      if(IsNaN(resid))
        {
         if(beta < InpBetaLo) beta = InpBetaLo;
         if(beta > InpBetaHi) beta = InpBetaHi;
         resid = (y - mY_p) - beta * (F - mF_p);
        }
     }
   else
     {
      // keep EWMA rates moments ticking even when unused this bar
      if(g_use_rates)
        {
         double d1, d2;
         EwmaUse(g_mR, lam_b, xR, d1, d2);
         EwmaUse(g_mPR, lam_b, NaN(), d1, d2);
         EwmaUse(g_mFR, lam_b, NaN(), d1, d2);
        }
     }
   g_beta_cur = beta;
   if(!freshAll) resid = NaN();
   g_resid[ix] = resid;
   g_fresh[ix] = freshAll;
   double rf = (IsNaN(resid) ? 0.0 : resid);
   g_cumR[ix] = (g_abs > 0 ? At(g_cumR, g_abs - 1) : 0.0) + rf;

   // ---- 4h trend tau ----
   double tau = NaN();
   if(g_abs >= 48)
     {
      double r4 = logc - MathLog(At(g_c, g_abs - 48));
      double m4p, v4p;
      EwmaUse(g_r4, lam_b, r4, m4p, v4p);
      if(!IsNaN(m4p) && !IsNaN(v4p) && v4p > 1e-18)
        {
         tau = (r4 - m4p) / MathSqrt(v4p);
         if(tau > 6) tau = 6;
         if(tau < -6) tau = -6;
        }
     }
   else { double d1, d2; EwmaUse(g_r4, lam_b, NaN(), d1, d2); }
   g_tau[ix] = tau;

   // ---- residual efficiency / factor persistence over EffBars ----
   double rsum = 0, rabs = 0, fsum = 0, fabs_ = 0;
   int nEff = 0;
   for(int k = 0; k < InpEffBars && g_abs - k >= 0; k++)
     {
      double rv = At(g_resid, g_abs - k);
      if(!IsNaN(rv)) { rsum += rv; rabs += MathAbs(rv); }
      double fv = At(g_F, g_abs - k);
      fsum += fv; fabs_ += MathAbs(fv);
      nEff++;
     }
   g_eff = (rabs > 1e-9 ? rsum / rabs : 0.0);
   g_persistF = (fabs_ > 1e-9 ? MathAbs(fsum) / fabs_ : 0.0);

   // ---- fast z from (session,hour) bucket ----
   g_zF_valid = false;
   double zF = NaN();
   if(sess > 0 && !IsNaN(resid))
     {
      int hb = (sess == 1 ? LondonHour(u) : 24 + NyHour(u));
      if(hb >= 0 && hb < 48)
        {
         double mu, sd;
         BucketStats(g_zbF[hb], InpZbMin, mu, sd);
         if(!IsNaN(mu) && !IsNaN(sd))
           {
            zF = (resid - mu) / sd;
            if(zF > 8) zF = 8;
            if(zF < -8) zF = -8;
            g_zF_valid = true;
           }
         BucketPush(g_zbF[hb], resid, InpZbWindow);
        }
     }
   g_zF[ix] = zF;
   g_zF_cur = zF;

   // ---- session anchors + session z ----
   int ldn_day = -1, ny_day = -1;
   if(InLdnSess(u)) ldn_day = today;
   if(InNySess(u)) ny_day = today;
   if(ldn_day >= 0 && g_lastLdnDay != today) { g_ldnAnchor = g_abs; g_lastLdnDay = today; }
   if(ny_day >= 0 && g_lastNyDay != today) { g_nyAnchor = g_abs; g_lastNyDay = today; }

   g_zS_valid = false;
   double zS = NaN();
   int anchor = -1, sbin = -1, sb = -1;
   if(InLdnSess(u) && g_ldnAnchor >= 0) { anchor = g_ldnAnchor; sbin = (g_abs - anchor) / InpSessBinBars; sb = sbin; }
   else if(InNySess(u) && g_nyAnchor >= 0) { anchor = g_nyAnchor; sbin = (g_abs - anchor) / InpSessBinBars; sb = 16 + sbin; }
   if(anchor >= 0 && sb >= 0 && sb < 32 && sbin < 16 && g_abs - anchor < HIST - 2)
     {
      double gap = At(g_cumR, g_abs) - At(g_cumR, anchor);
      double mu, sd;
      BucketStats(g_zbS[sb], InpZsMin, mu, sd);
      if(!IsNaN(mu) && !IsNaN(sd))
        {
         zS = (gap - mu) / sd;
         if(zS > 8) zS = 8;
         if(zS < -8) zS = -8;
         g_zS_valid = true;
        }
      BucketPush(g_zbS[sb], gap, InpZsWindow);
     }
   g_zS_cur = zS;

   // ---- percentile pools (causal: today's values enter tomorrow's stats) ----
   bool inF = (InLdnFast(u) || InNyFast(u));
   bool inS = (InLdnSess(u) || InNySess(u));
   if(inF && g_zF_valid) PoolPush(g_poolF, MathAbs(zF), today);
   if(inS && g_zS_valid) PoolPush(g_poolS, MathAbs(zS), today);
   if(sess == 1 && g_sd15_pips > 0) PoolPush(g_poolVol1, g_sd15_pips, today);
   if(sess == 2 && g_sd15_pips > 0) PoolPush(g_poolVol2, g_sd15_pips, today);
   if((inF || inS) && g_abs >= 2)
     {
      double h3 = MathMax(h, MathMax(At(g_hi, g_abs - 1), At(g_hi, g_abs - 2)));
      double l3 = MathMin(l, MathMin(At(g_lo, g_abs - 1), At(g_lo, g_abs - 2)));
      PoolPush(g_poolRng, (h3 - l3) / g_pip, today);
     }
   PoolPush(g_poolSp, sp_pts, today);

   // ---- vol percentile of current bar ----
   g_vol_pct_cur = 50.0;
   if(sess == 1 && g_volSortedN1 >= 500) g_vol_pct_cur = SortedRankPct(g_volSorted1, g_volSortedN1, g_sd15_pips);
   if(sess == 2 && g_volSortedN2 >= 500) g_vol_pct_cur = SortedRankPct(g_volSorted2, g_volSortedN2, g_sd15_pips);

   return true;
  }

//+------------------------------------------------------------------+
//| Broker position helpers                                          |
//+------------------------------------------------------------------+
bool FindMyPosition(ulong &ticket, double &vol, double &open_px, long &ptype, double &sl)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym) continue;
      ticket = tk;
      vol = PositionGetDouble(POSITION_VOLUME);
      open_px = PositionGetDouble(POSITION_PRICE_OPEN);
      ptype = PositionGetInteger(POSITION_TYPE);
      sl = PositionGetDouble(POSITION_SL);
      return true;
     }
   return false;
  }

string GvKey(string field) { return StringFormat("ASCRR_%I64d_%s", InpMagic, field); }

void PersistPos()
  {
   GlobalVariableSet(GvKey("open"), g_pos.open ? 1 : 0);
   if(!g_pos.open) return;
   GlobalVariableSet(GvKey("dir"), (double)g_pos.dir);
   GlobalVariableSet(GvKey("dsyn"), (double)g_pos.d_synth);
   GlobalVariableSet(GvKey("eng"), g_pos.engine == "F" ? 0 : 1);
   GlobalVariableSet(GvKey("tent"), (double)(long)g_pos.t_entry);
   GlobalVariableSet(GvKey("anchor_t"), (double)(long)(g_pos.anchor >= 0 ? AtT(g_t, g_pos.anchor) : 0));
   GlobalVariableSet(GvKey("egap"), g_pos.entry_gap);
   GlobalVariableSet(GvKey("xgap"), g_pos.extreme_gap);
   GlobalVariableSet(GvKey("frsd"), g_pos.fr_sd);
   GlobalVariableSet(GvKey("tp1"), g_pos.tp1_done ? 1 : 0);
   GlobalVariableSet(GvKey("entpx"), g_pos.entry_px);
   GlobalVariableSet(GvKey("vol0"), g_pos.vol0);
   GlobalVariableSet(GvKey("stoppips"), g_pos.stop_pips);
  }

void ClearPersist()
  {
   GlobalVariableSet(GvKey("open"), 0);
  }

int AbsIndexOfTime(datetime u)
  {
   for(int k = 0; k < MathMin(g_abs + 1, HIST) ; k++)
     {
      int a = g_abs - k;
      if(a < 0) break;
      if(AtT(g_t, a) <= u) return a;
     }
   return -1;
  }

void RestorePosBook()
  {
   ulong tk; double vol, opx, sl; long ptype;
   if(!FindMyPosition(tk, vol, opx, ptype, sl))
     { g_pos.open = false; ClearPersist(); return; }
   g_pos.open = true;
   g_pos.dir = (ptype == POSITION_TYPE_SELL ? -1 : 1);
   g_pos.vol = vol;
   g_pos.entry_px = opx;
   g_pos.sl = sl;
   if(GlobalVariableCheck(GvKey("open")) && GlobalVariableGet(GvKey("open")) > 0.5)
     {
      g_pos.d_synth = (long)(GlobalVariableCheck(GvKey("dsyn")) ? GlobalVariableGet(GvKey("dsyn")) : g_pos.dir * (long)g_sign_t);
      g_pos.engine = (GlobalVariableGet(GvKey("eng")) < 0.5 ? "F" : "S");
      g_pos.t_entry = (datetime)(long)GlobalVariableGet(GvKey("tent"));
      datetime at = (datetime)(long)GlobalVariableGet(GvKey("anchor_t"));
      g_pos.anchor = AbsIndexOfTime(at);
      g_pos.entry_gap = GlobalVariableGet(GvKey("egap"));
      g_pos.extreme_gap = GlobalVariableGet(GvKey("xgap"));
      g_pos.fr_sd = GlobalVariableGet(GvKey("frsd"));
      g_pos.tp1_done = GlobalVariableGet(GvKey("tp1")) > 0.5;
      g_pos.vol0 = GlobalVariableGet(GvKey("vol0"));
      g_pos.stop_pips = GlobalVariableGet(GvKey("stoppips"));
     }
   else
     {
      // degraded restore: unknown research context
      g_pos.d_synth = g_pos.dir * (long)g_sign_t;
      g_pos.engine = "F";
      g_pos.t_entry = (datetime)PositionGetInteger(POSITION_TIME);
      g_pos.anchor = -1;
      g_pos.entry_gap = 0; g_pos.extreme_gap = 0; g_pos.fr_sd = 0;
      g_pos.tp1_done = false;
      g_pos.vol0 = vol;
      g_pos.stop_pips = MathAbs(opx - sl) / g_pip;
      Print("ASCRR: degraded position restore (context lost) - time/trend/SL exits only");
     }
  }

//+------------------------------------------------------------------+
//| Risk governor                                                    |
//+------------------------------------------------------------------+
void RollRiskPeriods(datetime u)
  {
   int d = NyDayKey(u), w = NyWeekKey(u), m = NyMonthKey(u);
   if(d != g_cur_day) { g_cur_day = d; g_pnl_day = 0; }
   if(w != g_cur_week) { g_cur_week = w; g_pnl_week = 0; }
   if(m != g_cur_month) { g_cur_month = m; g_pnl_month = 0; }
  }

double Units()
  {
   double u = AccountInfoDouble(ACCOUNT_BALANCE) / 100000.0;
   if(u < 0.05) u = 0.05;
   if(u > 5.0) u = 5.0;
   return u;
  }

bool RiskGovOk(datetime u)
  {
   double un = Units();
   if(InpUseRiskLadder)
     {
      if(g_suspended) return false;
      if(g_halt_month >= 0 && NyMonthKey(u) <= g_halt_month) return false;
     }
   if(g_pnl_day <= -InpDailyStopR * InpRUsd * un) return false;
   if(g_pnl_week <= -InpWeeklyStopR * InpRUsd * un) return false;
   if(g_pnl_month <= -InpMonthlyStopR * InpRUsd * un) return false;
   return true;
  }

void BookTradeResult(double net_usd, datetime u)
  {
   RollRiskPeriods(u);
   g_pnl_day += net_usd;
   g_pnl_week += net_usd;
   g_pnl_month += net_usd;
   if(InpUseRiskLadder)
     {
      if(net_usd < 0) g_consec_losses++;
      else { g_consec_losses = 0; g_size_mult = 1.0; }
      if(g_consec_losses >= 4) g_size_mult = InpConsec4Mult;
      if(g_consec_losses >= 6 && InpConsec6Halt)
        {
         g_halt_month = NyMonthKey(u);
         Print("ASCRR risk: 6 consecutive losses - halted for month ", g_halt_month);
        }
      if(g_consec_losses >= 8 && InpConsec8Susp)
        {
         g_suspended = true;
         Print("ASCRR risk: 8 consecutive losses - MODEL SUSPENDED (re-enable manually)");
        }
     }
   GlobalVariableSet(GvKey("consec"), g_consec_losses);
   GlobalVariableSet(GvKey("sizemult"), g_size_mult);
   GlobalVariableSet(GvKey("susp"), g_suspended ? 1 : 0);
   GlobalVariableSet(GvKey("haltm"), g_halt_month);
  }

// realized net of a closed position from deal history
double PositionNetFromHistory(ulong pos_ticket)
  {
   if(!HistorySelectByPosition(pos_ticket)) return 0.0;
   double net = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong dk = HistoryDealGetTicket(i);
      if(dk == 0) continue;
      net += HistoryDealGetDouble(dk, DEAL_PROFIT)
           + HistoryDealGetDouble(dk, DEAL_COMMISSION)
           + HistoryDealGetDouble(dk, DEAL_SWAP);
     }
   return net;
  }

void RebuildRiskFromHistory()
  {
   g_pnl_day = 0; g_pnl_week = 0; g_pnl_month = 0;
   g_consec_losses = (int)(GlobalVariableCheck(GvKey("consec")) ? GlobalVariableGet(GvKey("consec")) : 0);
   g_size_mult = (GlobalVariableCheck(GvKey("sizemult")) ? GlobalVariableGet(GvKey("sizemult")) : 1.0);
   g_suspended = (GlobalVariableCheck(GvKey("susp")) ? GlobalVariableGet(GvKey("susp")) > 0.5 : false);
   g_halt_month = (int)(GlobalVariableCheck(GvKey("haltm")) ? GlobalVariableGet(GvKey("haltm")) : -1);

   datetime now = TimeCurrent();
   datetime u = ServerToUtc(now);
   g_cur_day = NyDayKey(u); g_cur_week = NyWeekKey(u); g_cur_month = NyMonthKey(u);
   if(!HistorySelect(now - 45 * 86400, now + 3600)) return;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong dk = HistoryDealGetTicket(i);
      if(dk == 0) continue;
      long dmg = HistoryDealGetInteger(dk, DEAL_MAGIC);
      if(dmg < InpMagic || dmg > InpMagic + 9) continue;
      long entry = HistoryDealGetInteger(dk, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;
      double net = HistoryDealGetDouble(dk, DEAL_PROFIT)
                 + HistoryDealGetDouble(dk, DEAL_COMMISSION)
                 + HistoryDealGetDouble(dk, DEAL_SWAP);
      datetime du = ServerToUtc((datetime)HistoryDealGetInteger(dk, DEAL_TIME));
      if(NyDayKey(du) == g_cur_day) g_pnl_day += net;
      if(NyWeekKey(du) == g_cur_week) g_pnl_week += net;
      if(NyMonthKey(du) == g_cur_month) g_pnl_month += net;
     }
   PrintFormat("ASCRR risk restored: day=%.0f week=%.0f month=%.0f consec=%d mult=%.2f susp=%d",
               g_pnl_day, g_pnl_week, g_pnl_month, g_consec_losses, g_size_mult, (int)g_suspended);
  }

//+------------------------------------------------------------------+
//| Filters (entry-time)                                             |
//+------------------------------------------------------------------+
bool TrendBlocksEntry(int dir)
  {
   double tau = At(g_tau, g_abs);
   if(IsNaN(tau)) return true;
   double against = -dir;                 // sign of the move being faded
   double tau_a = tau * against;
   double eff_a = g_eff * against;
   if(tau_a >= InpTauHard) return true;
   if(tau_a >= InpTauSoft && eff_a >= InpEffHi && g_persistF >= InpPersistHi) return true;
   return false;
  }

// returns size multiplier, or -1 if blocked; reason via ref
double FiltersPass(string engine, int dir, datetime u, string &why)
  {
   int ix = IDX(g_abs);
   if(!g_fresh[ix] || IsNaN(g_resid[ix])) { why = "dq"; return -1; }
   if(InpUseNews && g_block_new) { why = "news"; return -1; }
   if(InpUseSpread)
     {
      double sp = (double)SymbolInfoInteger(g_sym, SYMBOL_SPREAD) * g_point / g_pip; // pips
      double med_pips = g_medSp * g_point / g_pip;
      if((med_pips > 0 && sp > InpSpreadMultCap * med_pips) || sp > InpSpreadAbsCapP)
        { why = "spread"; return -1; }
     }
   if(InpCoherMode == COHER_MIN && g_coher < InpCoherMin) { why = "coher"; return -1; }
   if(InpCoherMode == COHER_MAX && g_coher > InpCoherMax) { why = "coher"; return -1; }
   double vb = 1.0;
   if(InpUseVol)
     {
      double v = g_vol_pct_cur;
      if(v < InpVolNoneLo || v >= InpVolNoneHi) { why = "vol"; return -1; }
      if(v < InpVolSessOnly && engine == "F") { why = "vol"; return -1; }
      if(v >= InpVolFastOnly)
        {
         if(engine != "F") { why = "vol"; return -1; }
         vb = InpFastHiVolSize;
        }
     }
   if(InpUseTrend && TrendBlocksEntry(dir)) { why = "trend"; return -1; }
   if(!RiskGovOk(u)) { why = "risk_gov"; return -1; }
   if(!DeskOk(u)) { why = "desk_caps"; return -1; }
   if(InpRespectGuard && !MQLInfoInteger(MQL_TESTER))
     {
      if(GlobalVariableCheck("PG_SUP_ALL") && GlobalVariableGet("PG_SUP_ALL") > 0.5)
        { why = "guard"; return -1; }
      string gk = "PG_SUP_" + IntegerToString(InpMagic);
      if(GlobalVariableCheck(gk) && GlobalVariableGet(gk) > 0.5)
        { why = "guard"; return -1; }
      string sk = "PG_SCALE_" + IntegerToString(InpMagic);
      if(GlobalVariableCheck(sk))
        {
         double sc = GlobalVariableGet(sk);
         if(sc >= 0.0 && sc < 1.0) vb *= MathMax(0.0, sc);
         if(vb <= 0.0) { why = "guard"; return -1; }
        }
     }
   why = "";
   return vb;
  }

bool InWindowOf(string engine, datetime u)
  {
   if(engine == "F")
      return InpUseFast && ((InpUseLdnFast && InLdnFast(u)) || (InpUseNyFast && InNyFast(u)));
   return InpUseSess && ((InpUseLdnSess && InLdnSess(u)) || (InpUseNySess && InNySess(u)));
  }

input group "=== Cost model (for BE / profit checks) ==="
input double InpCostEstPips = 0.90;           // est. all-in round-trip cost (pips)

ulong g_pos_ticket = 0;

//+------------------------------------------------------------------+
//| Close helpers                                                    |
//+------------------------------------------------------------------+
double NormLots(double lots)
  {
   double step = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < vmin) lots = 0;
   if(lots > vmax) lots = vmax;
   return NormalizeDouble(lots, 2);
  }

void FinalizeClosedPosition(datetime u, string reason)
  {
   double net = PositionNetFromHistory(g_pos_ticket);
   BookTradeResult(net, u);
   if(InpVerboseLog)
      PrintFormat("ASCRR exit [%s] pos=%I64u net=%.2f USD  (day %.0f / wk %.0f / mo %.0f)",
                  reason, g_pos_ticket, net, g_pnl_day, g_pnl_week, g_pnl_month);
   g_pos.open = false;
   g_pos_ticket = 0;
   if(InpRearmMode == REARM_BAND)
     {
      g_rearm_wait = true;
      g_setF.active = false;
      g_setS.active = false;
     }
   ClearPersist();
  }

bool CloseAll(string reason, datetime u)
  {
   ulong tk; double vol, opx, sl; long pt;
   if(!FindMyPosition(tk, vol, opx, pt, sl))
     { FinalizeClosedPosition(u, reason + "(gone)"); return true; }
   for(int tries = 0; tries < 3; tries++)
     {
      if(g_trade.PositionClose(tk))
        { FinalizeClosedPosition(u, reason); return true; }
      Sleep(300);
     }
   Print("ASCRR: PositionClose FAILED ret=", g_trade.ResultRetcode());
   return false;
  }

//+------------------------------------------------------------------+
//| Position management on each closed bar                           |
//+------------------------------------------------------------------+
void ManagePosition(datetime u)
  {
   if(!g_pos.open) return;

   ulong tk; double vol, opx, slb; long pt;
   if(!FindMyPosition(tk, vol, opx, pt, slb))
     {
      // closed externally (broker SL or manual)
      FinalizeClosedPosition(u, "SL/ext");
      return;
     }
   g_pos_ticket = tk;
   g_pos.vol = vol;

   int d = (int)g_pos.dir;
   double c = At(g_c, g_abs);
   double sgn = -(double)g_pos.d_synth;
   double g_now = 0, closed_frac = 0, zfroz = 0;
   bool ctx = (g_pos.anchor >= 0 && g_abs - g_pos.anchor < HIST - 2);
   if(ctx)
     {
      g_now = (At(g_cumR, g_abs) - At(g_cumR, g_pos.anchor)) * sgn;
      closed_frac = (g_pos.entry_gap > 1e-9 ? 1.0 - g_now / g_pos.entry_gap : 0.0);
      zfroz = (g_pos.fr_sd > 1e-9 ? g_now / g_pos.fr_sd : 0.0);
     }
   double held_min = (double)((long)u - (long)g_pos.t_entry) / 60.0;

   string reason = "";
   double tau = At(g_tau, g_abs);
   if(g_force_flat) reason = "NEWS_FLAT";
   else if(!g_fresh[IDX(g_abs)]) reason = "DQ";
   else if(ctx && g_now >= InpGapExpandStop * g_pos.extreme_gap) reason = "GAP_EXPAND";
   else if(ctx && zfroz >= InpFrozenZStop) reason = "FROZEN_Z";
   else if(g_eff * sgn >= InpRedirectEff) reason = "REDIRECT";
   else if(!IsNaN(tau) && tau * (-(double)d) >= InpTauExit) reason = "TREND_EXIT";
   else if(InpUseVol && g_vol_pct_cur >= InpVolCrisis) reason = "VOL_CRISIS";
   else if(g_pos.engine == "F" && held_min >= InpTimeStopFmin) reason = "TIME";
   else if(g_pos.engine == "S" && held_min >= InpTimeStopSmin) reason = "TIME";
   else if(ctx && g_pos.engine == "F" && held_min >= InpProgFmin && closed_frac < InpProgMinClosed) reason = "PROGRESS";
   else if(ctx && g_pos.engine == "S" && held_min >= InpProgSmin && closed_frac < InpProgMinClosed) reason = "PROGRESS";

   if(reason != "")
     {
      CloseAll(reason, u);
      return;
     }

   // ---- profit taking on the residual gap ----
   if(ctx && !g_pos.tp1_done && closed_frac >= InpTp1GapFrac)
     {
      double pips_open = (c - g_pos.entry_px) / g_pip * d;
      if(pips_open - InpCostEstPips > 0)
        {
         double vol1 = NormLots(vol * InpTp1CloseFrac);
         if(vol1 > 0 && vol1 < vol)
           {
            if(g_trade.PositionClosePartial(tk, vol1))
              {
               g_pos.tp1_done = true;
               g_pos.vol = vol - vol1;
               double be = g_pos.entry_px + d * InpCostEstPips * g_pip;
               if(g_trade.PositionModify(tk, NormalizeDouble(be, (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS)), 0.0))
                  g_pos.sl = be;
               PersistPos();
               if(InpVerboseLog)
                  PrintFormat("ASCRR TP1: closed %.2f, SL -> BE %.5f (closed_frac=%.2f)", vol1, be, closed_frac);
              }
           }
        }
     }
   if(ctx && g_pos.open)
     {
      bool crossed = (g_now <= 0);
      if(closed_frac >= InpTp2GapFrac || crossed)
         CloseAll(crossed ? "TP2_CROSS" : "TP2_GAP", u);
     }
  }

//+------------------------------------------------------------------+
//| Setup / confirmation state machine (one engine)                  |
//+------------------------------------------------------------------+
void ResetSetup(Setup &st) { st.active = false; }

double ZOf(string engine) { return (engine == "F" ? g_zF_cur : g_zS_cur); }
bool   ZValid(string engine) { return (engine == "F" ? g_zF_valid : g_zS_valid); }
double ThrOf(string engine) { return (engine == "F" ? g_TF : g_TS); }

int AnchorOf(string engine, datetime u)
  {
   if(engine == "F") return g_abs - 1;
   if(InLdnSess(u)) return g_ldnAnchor;
   if(InNySess(u)) return g_nyAnchor;
   return -1;
  }

// returns true if an entry was made
bool RunEngine(string engine, Setup &st, datetime u)
  {
   double zi = ZOf(engine);
   bool zok = ZValid(engine);
   double h = At(g_hi, g_abs), l = At(g_lo, g_abs);

   if(!st.active)
     {
      if(!InWindowOf(engine, u) || !zok) return false;
      double T = ThrOf(engine);
      if(!(zi >= T || zi <= -T)) return false;
      int d_s = (zi > 0 ? -1 : 1);          // synthetic side (sell rich / buy cheap)
      int d = (int)(d_s * g_sign_t);        // actual trade side on the chart symbol
      int anchor = AnchorOf(engine, u);
      if(anchor < 0) return false;
      st.active = true;
      st.dir = d;
      st.d_synth = d_s;
      st.start = g_abs;
      st.peak_z = MathAbs(zi);
      int j0 = (engine == "F" ? MathMax(0, g_abs - (W15 - 1)) : MathMax(0, anchor));
      double ext = (d < 0 ? -DBL_MAX : DBL_MAX);
      for(int a = j0; a <= g_abs; a++)
         ext = (d < 0 ? MathMax(ext, At(g_hi, a)) : MathMin(ext, At(g_lo, a)));
      st.ext_px = ext;
      st.last_ext_i = g_abs;
      st.anchor = anchor;
      st.extreme_gap = MathAbs(At(g_cumR, g_abs) - At(g_cumR, anchor));
      if(InpConfMode != CONF_NONE) return false;
      // CONF_NONE falls through to immediate confirmation this bar
     }

   int d = st.dir;
   int d_s = st.d_synth;
   if(!zok) { ResetSetup(st); return false; }
   double za = zi * (-d_s);
   st.peak_z = MathMax(st.peak_z, za);
   double gap_abs = MathAbs(At(g_cumR, g_abs) - At(g_cumR, st.anchor));
   st.extreme_gap = MathMax(st.extreme_gap, gap_abs);
   if(d < 0 && h > st.ext_px) { st.ext_px = h; st.last_ext_i = g_abs; }
   if(d > 0 && l < st.ext_px) { st.ext_px = l; st.last_ext_i = g_abs; }

   int max_bars = (engine == "F" ? InpSetupMaxF : InpSetupMaxS);
   bool conf;
   double resid = At(g_resid, g_abs);
   if(InpConfMode == CONF_FULL)
     {
      double need = MathMax(InpConfMinDrop, InpConfDropFrac * st.peak_z);
      conf = ((g_abs - st.last_ext_i) >= 1 &&
              za <= st.peak_z - need &&
              !IsNaN(resid) && resid * (-d_s) < 0 &&
              ((d < 0 && h <= st.ext_px) || (d > 0 && l >= st.ext_px)));
     }
   else if(InpConfMode == CONF_LIGHT)
     {
      conf = ((g_abs - st.last_ext_i) >= 1 && za >= InpCancelZ &&
              ((d < 0 && h <= st.ext_px) || (d > 0 && l >= st.ext_px)));
     }
   else
      conf = (za >= InpCancelZ);

   if(!conf)
     {
      if(za < InpCancelZ || (g_abs - st.start) > max_bars || g_force_flat)
         ResetSetup(st);
      return false;
     }
   if(!InWindowOf(engine, u)) { ResetSetup(st); return false; }

   string why;
   double vb = FiltersPass(engine, d, u, why);
   if(vb < 0)
     {
      if(InpVerboseLog && why != "risk_gov")
         PrintFormat("ASCRR %s setup blocked: %s (z=%.2f)", engine, why, zi);
      return false;                       // setup stays alive; may clear later
     }

   // ------------------ ENTRY ------------------
   double normRng = g_normRng;
   double buf = MathMax(InpBufMinPips, InpBufRngFrac * normRng) * g_pip;
   double sl = (d < 0 ? st.ext_px + buf : st.ext_px - buf);
   double px = (d < 0 ? SymbolInfoDouble(g_sym, SYMBOL_BID) : SymbolInfoDouble(g_sym, SYMBOL_ASK));
   double stop_pips = MathAbs(sl - px) / g_pip;
   if(stop_pips > InpMaxStopPips || stop_pips < 1.0)
     {
      if(InpVerboseLog) PrintFormat("ASCRR %s entry rejected: stop %.1f pips", engine, stop_pips);
      ResetSetup(st);
      return false;
     }
   long stopsLevel = SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel > 0 && MathAbs(sl - px) < stopsLevel * g_point)
      sl = (d < 0 ? px + stopsLevel * g_point : px - stopsLevel * g_point);

   double un = Units();
   double tick_v = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE);
   double tick_s = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   double pip_value = (tick_s > 0 && tick_v > 0 ? tick_v * (g_pip / tick_s) : 10.0);
   double lots = InpLotsPer100k * un * g_size_mult * vb;
   double risk = stop_pips * pip_value * lots;
   double cap = InpRiskCapUsd * un * g_size_mult * vb;
   if(risk > cap && stop_pips > 0)
      lots = cap / (stop_pips * pip_value);
   lots = NormLots(lots);
   if(lots <= 0) { ResetSetup(st); return false; }

   int digits = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   bool ok = (d < 0)
             ? g_trade.Sell(lots, g_sym, 0.0, sl, 0.0, InpComment + "-" + engine)
             : g_trade.Buy(lots, g_sym, 0.0, sl, 0.0, InpComment + "-" + engine);
   if(!ok || (g_trade.ResultRetcode() != TRADE_RETCODE_DONE &&
              g_trade.ResultRetcode() != TRADE_RETCODE_PLACED &&
              g_trade.ResultRetcode() != TRADE_RETCODE_DONE_PARTIAL))
     {
      Print("ASCRR: order FAILED ret=", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      ResetSetup(st);
      return false;
     }

   ulong tk; double vol, opx, slx; long ptx;
   if(FindMyPosition(tk, vol, opx, ptx, slx)) g_pos_ticket = tk;

   double g_entry = MathAbs(At(g_cumR, g_abs) - At(g_cumR, st.anchor));
   double ext_g = MathMax(st.extreme_gap, MathMax(g_entry, 1e-9));
   g_pos.open = true;
   g_pos.dir = d;
   g_pos.d_synth = d_s;
   g_pos.engine = engine;
   g_pos.t_entry = u + BAR_SEC;           // entering just after bar close
   g_pos.i_entry = g_abs + 1;
   g_pos.entry_px = (FindMyPosition(tk, vol, opx, ptx, slx) ? opx : px);
   g_pos.sl = sl;
   g_pos.vol0 = lots; g_pos.vol = lots;
   g_pos.anchor = st.anchor;
   g_pos.entry_gap = g_entry;
   g_pos.extreme_gap = ext_g;
   g_pos.fr_sd = g_entry / MathMax(0.8, za);
   g_pos.tp1_done = false;
   g_pos.stop_pips = stop_pips;
   PersistPos();
   if(InpVerboseLog)
      PrintFormat("ASCRR ENTRY %s %s %.2f lots @%.5f sl=%.5f (%.1fp) z=%.2f T=%.2f gap=%.3f",
                  engine, d < 0 ? "SELL" : "BUY", lots, g_pos.entry_px, sl, stop_pips, zi, ThrOf(engine));
   g_setF.active = false;
   g_setS.active = false;
   return true;
  }

//+------------------------------------------------------------------+
//| One closed bar: features + trading                               |
//+------------------------------------------------------------------+
void ProcessOneBar(const MqlRates &r, bool replay)
  {
   if(!UpdateFeatures(r.time, r.open, r.high, r.low, r.close, (double)r.spread))
      return;
   if(replay) return;

   datetime u = AtT(g_t, g_abs);
   RollRiskPeriods(u);

   ManagePosition(u);
   if(g_pos.open) return;                 // one position max

   if(g_bars_seen < InpWarmupBars) return;

   if(g_rearm_wait)
     {
      bool okF = (!g_zF_valid) || MathAbs(g_zF_cur) < InpRearmBand;
      bool okS = (!g_zS_valid) || MathAbs(g_zS_cur) < InpRearmBand;
      if(g_zF_valid && okF && okS)
         g_rearm_wait = false;
      else
         return;
     }

   if(RunEngine("F", g_setF, u)) return;
   RunEngine("S", g_setS, u);
  }

//+------------------------------------------------------------------+
//| Bar pump                                                         |
//+------------------------------------------------------------------+
bool g_warm_done = false;

void WarmupReplay()
  {
   MqlRates hist[];
   int want = 45000;
   int got = CopyRates(g_sym, PERIOD_M5, 1, want, hist);
   if(got < InpWarmupBars + 500)
     {
      static int warn = 0;
      if(warn++ % 12 == 0)
         PrintFormat("ASCRR: warmup pending, have %d bars (need %d)...", got, InpWarmupBars + 500);
      if(got <= 0) return;
     }
   // prime comparison symbol histories
   for(int s = 0; s < g_ncomp; s++)
     {
      double dummy[];
      CopyClose(g_comp[s], PERIOD_M5, 0, 10, dummy);
     }
   if(got <= 0) return;
   for(int k = 0; k < got; k++)
      ProcessOneBar(hist[k], true);
   g_last_bar = hist[got - 1].time;
   g_warm_done = true;
   PrintFormat("ASCRR: warmup replay done: %d bars, features at %s, TF=%.2f TS=%.2f",
               got, TimeToString(g_last_bar), g_TF, g_TS);
   RestorePosBook();
  }

void PumpBars()
  {
   if(!g_warm_done)
     {
      WarmupReplay();
      if(!g_warm_done) return;
     }
   datetime t1 = iTime(g_sym, PERIOD_M5, 1);
   if(t1 == 0 || t1 <= g_last_bar) return;
   int back = 0;
   while(back < 500 && iTime(g_sym, PERIOD_M5, 1 + back) > g_last_bar) back++;
   MqlRates rr[];
   for(int s = back; s >= 1; s--)
     {
      if(CopyRates(g_sym, PERIOD_M5, s, 1, rr) == 1)
         ProcessOneBar(rr[0], false);
     }
   g_last_bar = t1;
  }

//+------------------------------------------------------------------+
//| Standard event handlers                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_sym = Symbol();
   if(StringFind(g_sym, "EURUSD") < 0)
      Print("ASCRR note: research validated EURUSD only; per-pair backtests of the other ",
            "majors were NEGATIVE with this configuration (see report). Chart: ", g_sym);
   g_sign_t = (StringFind(InpInvertList, g_sym) >= 0 ? -1.0 : 1.0);
   g_point = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   g_pip = (SymbolInfoInteger(g_sym, SYMBOL_DIGITS) >= 5 ? g_point * 10 : g_point);

   // parse comparison symbols
   string parts[];
   int np = StringSplit(InpComparisonSymbols, ',', parts);
   g_ncomp = 0;
   for(int k = 0; k < np && g_ncomp < NCOMP_MAX; k++)
     {
      string s = parts[k];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) == 0) continue;
      if(s == g_sym || StringFind(g_sym, s) == 0) continue;   // exclude chart symbol
      if(!SymbolSelect(s, true))
        {
         Print("ASCRR ERROR: cannot select comparison symbol ", s);
         return INIT_FAILED;
        }
      g_comp[g_ncomp] = s;
      g_inv[g_ncomp] = (StringFind(InpInvertList, s) >= 0);
      g_ncomp++;
     }
   if(g_ncomp < 4)
     {
      Print("ASCRR ERROR: need at least 4 comparison symbols");
      return INIT_FAILED;
     }
   g_use_rates = (StringLen(InpRatesSymbol) > 0);
   if(g_use_rates && !SymbolSelect(InpRatesSymbol, true))
     {
      Print("ASCRR warning: rates symbol unavailable, disabling: ", InpRatesSymbol);
      g_use_rates = false;
     }

   // init state
   g_lam_vol = Lam(InpHlVolBars);
   g_lam_beta = Lam(InpHlBetaBars);
   for(int k = 0; k < NCOMP_MAX + 2; k++) { EwmaInit(g_vol[k]); g_prevN[k] = 0; }
   EwmaInit(g_mF); EwmaInit(g_mY); EwmaInit(g_mP);
   EwmaInit(g_mR); EwmaInit(g_mPR); EwmaInit(g_mFR);
   EwmaInit(g_r4);
   for(int k = 0; k < 48; k++) BucketInit(g_zbF[k]);
   for(int k = 0; k < 32; k++) BucketInit(g_zbS[k]);
   PoolInit(g_poolF); PoolInit(g_poolS);
   PoolInit(g_poolVol1); PoolInit(g_poolVol2);
   PoolInit(g_poolRng); PoolInit(g_poolSp);
   g_TF = (InpFastLo + InpFastHi) / 2;
   g_TS = (InpSessLo + InpSessHi) / 2;
   g_normRng = 8.0; g_medSp = 10.0;
   g_abs = -1; g_bars_seen = 0; g_h = 0;
   g_setF.active = false; g_setS.active = false;
   g_pos.open = false;
   g_rearm_wait = false;
   g_warm_done = false;
   g_last_bar = 0;
   g_ldnAnchor = -1; g_nyAnchor = -1; g_lastLdnDay = -1; g_lastNyDay = -1;
   g_lastStatDay = -1;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPts);
   g_trade.SetTypeFillingBySymbol(g_sym);
   g_trade.SetAsyncMode(false);

   RebuildRiskFromHistory();
   GoldInit();

   EventSetTimer(5);
   PrintFormat("ASCRR-Desk v2.80 init: %s pip=%.5f comps=%d rates=%s tz=%d",
               g_sym, g_pip, g_ncomp, g_use_rates ? InpRatesSymbol : "off", (int)InpTzMode);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_pos.open) PersistPos();
  }

void OnTimer() { DeskCapsPump(); PumpBars(); GoldPump(); }
void OnTick()  { DeskCapsPump(); PumpBars(); GoldPump(); }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|  MOMENTUM SLEEVES (magics InpMagic+1 .. InpMagic+N)              |
//|  H1 channel breakout, 4h-trend aligned, ATR chandelier trail,    |
//|  72h time stop, Friday flat, broker-verified risk sizing.        |
//|                                                                  |
//|  VALIDATED SYMBOLS: XAUUSD only (IS +26.7 / OOS +53.8 net pips,  |
//|  PF ~1.5 both halves, ~9 trades/mo).                             |
//|  DO NOT add a symbol to InpMomSymbols until it has passed the    |
//|  same IS/OOS validation. An unvalidated sleeve is not a feature, |
//|  it is a bet. The 30-60 trades/month capacity of this file fills |
//|  one validated sleeve at a time.                                 |
//+------------------------------------------------------------------+
input group "=== Momentum sleeves ==="
input bool   InpGoldEnable      = true;       // master enable for momentum sleeves
input string InpMomSymbols      = "XAUUSD:12,XAUUSD:16,XAUUSD:24,XAUUSD:48"; // SYMBOL:CHAN list - validated entries only
input int    InpGoldChan        = 24;         // H1 channel length
input double InpGoldAtrMult     = 2.5;        // chandelier ATR multiple (validated 2.5)
input double InpGoldTauMin      = 0.5;        // 4h-trend alignment minimum
input int    InpGoldMaxHoldH    = 72;         // time stop (hours)
input bool   InpGoldLongOnly    = true;       // research: short side negative
input double InpGoldStopLoPips  = 20;         // reject stops narrower (pips = 10*point)
input double InpGoldStopHiPips  = 2000;       // reject stops wider
input double InpGoldRiskPer100k = 250.0;      // $ risk per trade per $100k PER SLEEVE
input double InpGoldLotsCap100k = 0.50;       // lots cap per $100k per sleeve (hard ceiling)
input bool   InpPyramid         = true;       // one add-on per trend leg (validated IS +28% / OOS +16%)
input double InpAddTrigAtrMult  = 1.0;        // add when profit >= this x ATR
input double InpAddSizeFrac     = 0.5;        // add-on risk as fraction of sleeve risk
input bool   InpBlockRollover   = false;      // skip entries during server hour 0 (live-spread safety)
input double InpEffGate         = 0.20;       // 48h path-efficiency entry gate (0 = off; validated 0.20)
input double InpTp1R            = 0.0;        // partial TP: bank at +this x initial risk (0 = OFF. Battery: raises win% but COSTS profit)
input double InpTp1Frac         = 0.33;       // fraction of base position banked at TP1

input group "=== Chop dip-buyer sleeve (MR complement - ON PROBATION, default OFF) ==="
// Buys touches of the H1 channel LOW when 48h path efficiency is BELOW the
// momentum gate (confirmed chop) and no strong trend (|tau| <= cap); target =
// channel mid, stop = atr_stop x ATR below entry, 24h time stop, long-only.
// 44-month evidence: IS +$9.8k PF 1.43 / OOS +$5.9k PF 1.50 at $500 risk;
// positive in Apr-Sep23 (+$6.0k), 2024 (+$3.3k), Feb-May26 (+$1.2k). BUT its
// most recent 8 months (2026) are its worst stretch ever (-$4.0k at $500,
// bleed spread over Apr/Jun/Jul/Aug), and no tested filter removes that bleed
// without killing the engine (tau floor leaves 15 trades - dips at the low
// only exist when recent drift is down; vol caps miss). Status: validated on
// 44 months, on probation on the last 8. Default OFF so Desk7 >= Desk6 out of
// the box. Turn ON (small size) if gold enters a multi-month range like 2024,
// or to run it on forward demo where its regime insurance is cheap.
input bool   InpMrEnable        = false;      // enable chop dip-buyer sleeve (XAUUSD)
input int    InpMrChan          = 24;         // H1 channel length
input double InpMrEffMax        = 0.20;       // trade only when eff48 BELOW this (chop)
input double InpMrTauCap        = 1.0;        // skip if |tau| above this (real trend underway)
input double InpMrAtrStop       = 1.0;        // stop = this x ATR below entry
input int    InpMrMaxHoldH      = 24;         // time stop (hours)
input double InpMrRiskPer100k   = 250.0;      // $ risk per trade per $100k
input double InpMrLotsCap100k   = 0.50;       // lots cap per $100k

EwmaSt   g_mr_tau;
double   g_mr_atr = 0;  long g_mr_atrn = 0;
double   g_mr_c5[5];    int  g_mr_cn = 0;
bool     g_mr_warm = false;
datetime g_mr_last = 0;
double   g_mr_tp = 0.0;
double   g_mr_pip = 0.0, g_mr_point = 0.0;
string   g_mr_sym = "XAUUSD";

long MrMagic() { return InpMagic + 9; }

#define MAX_MOM 8

CTrade   g_gtrade;
int      g_nm = 0;
string   g_m_sym[MAX_MOM];
int      g_m_chan[MAX_MOM];
double   g_m_pip[MAX_MOM];
double   g_m_point[MAX_MOM];
datetime g_m_last[MAX_MOM];
bool     g_m_warm[MAX_MOM];
EwmaSt   g_m_tau[MAX_MOM];
double   g_m_atr[MAX_MOM];
long     g_m_atrn[MAX_MOM];
double   g_m_c5[MAX_MOM][5];
int      g_m_cn[MAX_MOM];
bool     g_m_added[MAX_MOM];
bool     g_m_tp1[MAX_MOM];              // partial TP taken this position cycle
double   g_m_lasttau[MAX_MOM];          // latest tau value (for the regime display)
double   g_m_r0[MAX_MOM];               // initial risk distance (price units) at entry

long MomMagic(int k) { return InpMagic + 1 + k; }

bool FindMomPosition(int k, ulong &ticket, double &vol, double &opx, long &ptype,
                     double &sl, datetime &topen)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MomMagic(k)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_m_sym[k]) continue;
      ticket = tk;
      vol = PositionGetDouble(POSITION_VOLUME);
      opx = PositionGetDouble(POSITION_PRICE_OPEN);
      ptype = PositionGetInteger(POSITION_TYPE);
      sl = PositionGetDouble(POSITION_SL);
      topen = (datetime)PositionGetInteger(POSITION_TIME);
      return true;
     }
   return false;
  }

// update causal stats with a just-closed H1 bar; returns tau, gives prior ATR
double MomStatsUpdate(int k, double high, double low, double close, double &atr_prev)
  {
   atr_prev = (g_m_atrn[k] >= g_m_chan[k] ? g_m_atr[k] : 0.0);
   double rng = high - low;
   double alpha = 1.0 / MathMax(2, g_m_chan[k]);
   if(g_m_atrn[k] == 0) g_m_atr[k] = rng;
   else g_m_atr[k] = (1 - alpha) * g_m_atr[k] + alpha * rng;
   g_m_atrn[k]++;

   double tau = NaN();
   double logc = MathLog(close);
   if(g_m_cn[k] >= 4)
     {
      double r4 = logc - g_m_c5[k][(g_m_cn[k] - 4) % 5];
      double pm, pv;
      EwmaUse(g_m_tau[k], Lam(240), r4, pm, pv);   // halflife 240 H1 bars (~10d)
      if(!IsNaN(pm) && !IsNaN(pv) && pv > 1e-18)
         tau = (r4 - pm) / MathSqrt(pv);
     }
   else { double d1, d2; EwmaUse(g_m_tau[k], Lam(240), NaN(), d1, d2); }
   g_m_c5[k][g_m_cn[k] % 5] = logc;
   g_m_cn[k]++;
   g_m_lasttau[k] = tau;
   return tau;
  }

void GoldInit()
  {
   g_nm = 0;
   if(!InpGoldEnable) return;
   string parts[];
   int np = StringSplit(InpMomSymbols, ',', parts);
   for(int i = 0; i < np && g_nm < MAX_MOM; i++)
     {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) == 0) continue;
      int chan = InpGoldChan;
      int cpos = StringFind(s, ":");
      if(cpos > 0)
        {
         chan = (int)StringToInteger(StringSubstr(s, cpos + 1));
         s = StringSubstr(s, 0, cpos);
         if(chan < 4 || chan > 400) chan = InpGoldChan;
        }
      if(!SymbolSelect(s, true))
        {
         Print("ASCRR-Desk: momentum symbol unavailable, skipped: ", s);
         continue;
        }
      int k = g_nm;
      g_m_sym[k] = s;
      g_m_chan[k] = chan;
      g_m_point[k] = SymbolInfoDouble(s, SYMBOL_POINT);
      g_m_pip[k] = g_m_point[k] * 10.0;
      EwmaInit(g_m_tau[k]);
      g_m_atr[k] = 0; g_m_atrn[k] = 0; g_m_cn[k] = 0;
      g_m_warm[k] = false; g_m_last[k] = 0; g_m_added[k] = false;
      g_m_tp1[k] = false; g_m_r0[k] = 0.0;
      g_nm++;
      PrintFormat("ASCRR-Desk momentum sleeve %d: %s chan=%d magic %I64d", k, s, chan, MomMagic(k));
     }
   if(InpMrEnable)
     {
      if(g_nm > 0) g_mr_sym = g_m_sym[0];      // same instrument as the momentum book
      if(SymbolSelect(g_mr_sym, true))
        {
         g_mr_point = SymbolInfoDouble(g_mr_sym, SYMBOL_POINT);
         g_mr_pip = g_mr_point * 10.0;
         EwmaInit(g_mr_tau);
         g_mr_atr = 0; g_mr_atrn = 0; g_mr_cn = 0;
         g_mr_warm = false; g_mr_last = 0; g_mr_tp = 0.0;
         PrintFormat("ASCRR-Desk chop dip-buyer sleeve: %s chan=%d magic %I64d",
                     g_mr_sym, InpMrChan, MrMagic());
        }
      else Print("ASCRR-Desk: dip-buyer symbol unavailable: ", g_mr_sym);
     }
   g_gtrade.SetDeviationInPoints(100);
   g_gtrade.SetAsyncMode(false);
  }

void MomWarmup(int k)
  {
   MqlRates rr[];
   int got = CopyRates(g_m_sym[k], PERIOD_H1, 1, 3000, rr);
   if(got < g_m_chan[k] + 300)
     {
      if(got <= 0) return;
     }
   if(got <= 0) return;
   double ap;
   for(int i = 0; i < got; i++)
      MomStatsUpdate(k, rr[i].high, rr[i].low, rr[i].close, ap);
   g_m_last[k] = rr[got - 1].time;
   g_m_warm[k] = true;
   PrintFormat("ASCRR-Desk %s: warmup done, %d H1 bars, ATR=%.2f", g_m_sym[k], got, g_m_atr[k]);
  }

void MomProcessBar(int k)
  {
   string sym = g_m_sym[k];
   int chan = g_m_chan[k];
   int need = MathMax(chan, 49) + 2;
   MqlRates rr[];
   int got = CopyRates(sym, PERIOD_H1, 1, need, rr);
   if(got < need) return;
   double close = rr[got - 1].close;
   double ch_hi = -DBL_MAX, ch_lo = DBL_MAX;
   for(int i = got - 1 - chan; i < got - 1; i++)
     {
      ch_hi = MathMax(ch_hi, rr[i].high);
      ch_lo = MathMin(ch_lo, rr[i].low);
     }
   double atr_prev;
   double tau = MomStatsUpdate(k, rr[got - 1].high, rr[got - 1].low, close, atr_prev);

   datetime u = ServerToUtc(rr[got - 1].time + 3600);
   int nyMin = NyMinOfDay(u);
   int nyDow = NyDow(u);

   g_gtrade.SetExpertMagicNumber(MomMagic(k));
   g_gtrade.SetTypeFillingBySymbol(sym);

   // collect this sleeve's tickets (base + optional add-on)
   ulong  tks[4];  double opxs[4];  long ptys[4];  datetime topens[4];  double sls[4];
   int npos = 0;
   for(int i = PositionsTotal() - 1; i >= 0 && npos < 4; i--)
     {
      ulong ptk = PositionGetTicket(i);
      if(ptk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MomMagic(k)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      tks[npos] = ptk;
      opxs[npos] = PositionGetDouble(POSITION_PRICE_OPEN);
      ptys[npos] = PositionGetInteger(POSITION_TYPE);
      topens[npos] = (datetime)PositionGetInteger(POSITION_TIME);
      sls[npos] = PositionGetDouble(POSITION_SL);
      npos++;
     }

   if(npos > 0)
     {
      int d = (ptys[0] == POSITION_TYPE_SELL ? -1 : 1);
      double held_max = 0;
      for(int i = 0; i < npos; i++)
         held_max = MathMax(held_max, (double)((long)rr[got - 1].time + 3600 - (long)topens[i]) / 3600.0);
      bool fri_flat = (nyDow == 5 && nyMin >= 990);
      if(held_max >= InpGoldMaxHoldH || fri_flat)
        {
         for(int i = 0; i < npos; i++)
            g_gtrade.PositionClose(tks[i]);
         PrintFormat("ASCRR-Desk %s exit [%s] held %.0fh (%d tickets)",
                     sym, fri_flat ? "FRI" : "TIME", held_max, npos);
         g_m_added[k] = false; g_m_tp1[k] = false; g_m_r0[k] = 0.0;
         return;
        }
      if(atr_prev > 0)
        {
         double trail = (d > 0 ? close - InpGoldAtrMult * atr_prev
                               : close + InpGoldAtrMult * atr_prev);
         int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         trail = NormalizeDouble(trail, dg);
         double px = SymbolInfoDouble(sym, d > 0 ? SYMBOL_BID : SYMBOL_ASK);
         long stopsLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
         bool valid = (d > 0 ? trail < px - stopsLvl * g_m_point[k]
                             : trail > px + stopsLvl * g_m_point[k]);
         if(valid)
            for(int i = 0; i < npos; i++)
              {
               bool improves = (d > 0 ? (sls[i] == 0 || trail > sls[i])
                                      : (sls[i] == 0 || trail < sls[i]));
               if(improves) g_gtrade.PositionModify(tks[i], trail, 0.0);
              }
         // ---- partial TP: bank InpTp1Frac of the BASE ticket at +InpTp1R x initial risk ----
         if(InpTp1R > 0 && !g_m_tp1[k])
           {
            // base ticket = earliest-opened of this sleeve's tickets
            int ib = 0;
            for(int i = 1; i < npos; i++)
               if(topens[i] < topens[ib]) ib = i;
            double r0 = g_m_r0[k];
            if(r0 <= 0) r0 = InpGoldAtrMult * atr_prev;   // restart fallback
            double gain0 = (close - opxs[ib]) * d;
            if(gain0 >= InpTp1R * r0)
              {
               double vol0 = 0.0;
               if(PositionSelectByTicket(tks[ib]))
                  vol0 = PositionGetDouble(POSITION_VOLUME);
               double stp = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
               double vmn = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
               if(stp <= 0) stp = 0.01;
               double part = MathFloor(vol0 * InpTp1Frac / stp + 1e-9) * stp;
               if(part >= vmn && vol0 - part >= vmn)
                 {
                  if(g_gtrade.PositionClosePartial(tks[ib], part))
                    {
                     g_m_tp1[k] = true;
                     PrintFormat("ASCRR-Desk %s TP1 bank %.2f of %.2f lots at +%.1fR",
                                 sym, part, vol0, gain0 / r0);
                    }
                 }
               else
                  g_m_tp1[k] = true;   // volume too small to split - mark done
              }
           }
         // ---- pyramid: one add-on per trend leg ----
         if(InpPyramid && npos == 1 && !g_m_added[k] && DeskOk(u))
           {
            double gain = (close - opxs[0]) * d;
            if(gain >= InpAddTrigAtrMult * atr_prev)
              {
               double stop_px2 = close - d * InpGoldAtrMult * atr_prev;
               double stop_pips2 = MathAbs(close - stop_px2) / g_m_pip[k];
               if(stop_pips2 >= InpGoldStopLoPips && stop_pips2 <= InpGoldStopHiPips)
                 {
                  double un2 = Units();
                  double tgt2 = InpGoldRiskPer100k * un2 * g_size_mult * InpAddSizeFrac;
                  double l1 = 0.0;
                  double pxn = SymbolInfoDouble(sym, d > 0 ? SYMBOL_ASK : SYMBOL_BID);
                  if(pxn <= 0) pxn = close;
                  if(!OrderCalcProfit(d > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym,
                                      1.0, pxn, stop_px2, l1) || l1 >= 0)
                     l1 = -stop_pips2 * 10.0;
                  double rpl = -l1;
                  if(rpl >= 1.0)
                    {
                     double lots2 = MathMin(InpGoldLotsCap100k * un2 * InpAddSizeFrac, tgt2 / rpl);
                     double step2 = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
                     double vmin2 = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
                     if(step2 <= 0) step2 = 0.01;
                     lots2 = MathFloor(lots2 / step2 + 1e-9) * step2;
                     if(lots2 >= vmin2 && lots2 * rpl <= 1.2 * tgt2)
                       {
                        stop_px2 = NormalizeDouble(stop_px2, dg);
                        bool ok2 = (d > 0)
                                   ? g_gtrade.Buy(lots2, sym, 0.0, stop_px2, 0.0, "ASCRR-ADD")
                                   : g_gtrade.Sell(lots2, sym, 0.0, stop_px2, 0.0, "ASCRR-ADD");
                        if(ok2)
                          {
                           g_m_added[k] = true;
                           PrintFormat("ASCRR-Desk %s PYRAMID ADD %.2f lots @~%.2f (gain %.1f x ATR)",
                                       sym, lots2, close, gain / atr_prev);
                          }
                       }
                    }
                 }
              }
           }
        }
      return;
     }
   g_m_added[k] = false; g_m_tp1[k] = false; g_m_r0[k] = 0.0;

   // ---- entry ----
   if(!g_m_warm[k] || atr_prev <= 0 || IsNaN(tau)) return;
   if(nyDow == 5 && nyMin >= 900) return;
   if(InpBlockRollover)
     {
      MqlDateTime sst; TimeToStruct(rr[got - 1].time + 3600, sst);
      if(sst.hour == 0) return;
     }
   if(InpEffGate > 0 && got >= 51)
     {
      // 48h path efficiency: only enter when price is actually going somewhere
      double netm = MathAbs(rr[got - 1].close - rr[got - 49].close);
      double path = 0;
      for(int j = got - 48; j <= got - 1; j++)
         path += MathAbs(rr[j].close - rr[j - 1].close);
      if(path > 1e-9 && netm / path < InpEffGate) return;
     }
   int dirn = 0;
   if(close > ch_hi && tau >= InpGoldTauMin) dirn = 1;
   else if(!InpGoldLongOnly && close < ch_lo && tau <= -InpGoldTauMin) dirn = -1;
   if(dirn == 0) return;

   if(InpRespectGuard && !MQLInfoInteger(MQL_TESTER))
     {
      if(GlobalVariableCheck("PG_SUP_ALL") && GlobalVariableGet("PG_SUP_ALL") > 0.5) return;
      string gk = "PG_SUP_" + IntegerToString(InpMagic);
      if(GlobalVariableCheck(gk) && GlobalVariableGet(gk) > 0.5) return;
     }
   if(!RiskGovOk(u)) return;
   if(!DeskOk(u)) return;

   double stop_px = close - dirn * InpGoldAtrMult * atr_prev;
   double stop_pips = MathAbs(close - stop_px) / g_m_pip[k];
   if(stop_pips < InpGoldStopLoPips || stop_pips > InpGoldStopHiPips) return;

   double un = Units();
   double target_risk = InpGoldRiskPer100k * un * g_size_mult;
   double loss_1lot = 0.0;
   double px_now = SymbolInfoDouble(sym, dirn > 0 ? SYMBOL_ASK : SYMBOL_BID);
   if(px_now <= 0) px_now = close;
   if(!OrderCalcProfit(dirn > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym,
                       1.0, px_now, stop_px, loss_1lot) || loss_1lot >= 0)
     {
      double tick_v = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double tick_s = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double pipval = (tick_s > 0 && tick_v > 0 ? tick_v * (g_m_pip[k] / tick_s) : 10.0);
      loss_1lot = -stop_pips * pipval;
     }
   double risk_per_lot = -loss_1lot;
   if(risk_per_lot < 1.0)
     {
      Print("ASCRR-Desk ", sym, ": degenerate risk calc - trade skipped");
      return;
     }
   double lots = MathMin(InpGoldLotsCap100k * un, target_risk / risk_per_lot);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < vmin) return;
   double est_risk = lots * risk_per_lot;
   if(est_risk > 1.2 * target_risk)
     {
      Print("ASCRR-Desk ", sym, ": risk check failed (est $", DoubleToString(est_risk, 0),
            " vs target $", DoubleToString(target_risk, 0), ") - trade skipped");
      return;
     }
   PrintFormat("ASCRR-Desk %s sizing: lots=%.2f risk/lot=$%.0f est_risk=$%.0f target=$%.0f stop=%.0f pips",
               sym, lots, risk_per_lot, est_risk, target_risk, stop_pips);

   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   stop_px = NormalizeDouble(stop_px, dg);
   bool ok = (dirn > 0)
             ? g_gtrade.Buy(lots, sym, 0.0, stop_px, 0.0, "ASCRR-MOM")
             : g_gtrade.Sell(lots, sym, 0.0, stop_px, 0.0, "ASCRR-MOM");
   if(ok && (g_gtrade.ResultRetcode() == TRADE_RETCODE_DONE ||
             g_gtrade.ResultRetcode() == TRADE_RETCODE_PLACED ||
             g_gtrade.ResultRetcode() == TRADE_RETCODE_DONE_PARTIAL))
     {
      g_m_r0[k] = InpGoldAtrMult * atr_prev;
      g_m_tp1[k] = false;
      PrintFormat("ASCRR-Desk MOM ENTRY %s %s %.2f lots @~%.2f sl=%.2f tau=%.2f",
                  sym, dirn > 0 ? "BUY" : "SELL", lots, close, stop_px, tau);
     }
   else if(!ok)
      Print("ASCRR-Desk ", sym, " order failed: ", g_gtrade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Chop dip-buyer sleeve (magic InpMagic+9)                         |
//+------------------------------------------------------------------+
double MrStatsUpdate(double high, double low, double close, double &atr_prev)
  {
   atr_prev = (g_mr_atrn >= InpMrChan ? g_mr_atr : 0.0);
   double rng = high - low;
   double alpha = 1.0 / MathMax(2, InpMrChan);
   if(g_mr_atrn == 0) g_mr_atr = rng;
   else g_mr_atr = (1 - alpha) * g_mr_atr + alpha * rng;
   g_mr_atrn++;
   double tau = NaN();
   double logc = MathLog(close);
   if(g_mr_cn >= 4)
     {
      double r4 = logc - g_mr_c5[(g_mr_cn - 4) % 5];
      double pm, pv;
      EwmaUse(g_mr_tau, Lam(240), r4, pm, pv);
      if(!IsNaN(pm) && !IsNaN(pv) && pv > 1e-18)
         tau = (r4 - pm) / MathSqrt(pv);
     }
   else { double d1, d2; EwmaUse(g_mr_tau, Lam(240), NaN(), d1, d2); }
   g_mr_c5[g_mr_cn % 5] = logc;
   g_mr_cn++;
   return tau;
  }

void MrWarmup()
  {
   MqlRates rr[];
   int got = CopyRates(g_mr_sym, PERIOD_H1, 1, 3000, rr);
   if(got < InpMrChan + 300 || got <= 0) { if(got <= 0) return; }
   if(got <= 0) return;
   double ap;
   for(int i = 0; i < got; i++)
      MrStatsUpdate(rr[i].high, rr[i].low, rr[i].close, ap);
   g_mr_last = rr[got - 1].time;
   g_mr_warm = true;
   PrintFormat("ASCRR-Desk dip-buyer: warmup done, %d H1 bars, ATR=%.2f", got, g_mr_atr);
  }

bool FindMrPosition(ulong &ticket, double &opx, datetime &topen)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MrMagic()) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_mr_sym) continue;
      ticket = tk;
      opx = PositionGetDouble(POSITION_PRICE_OPEN);
      topen = (datetime)PositionGetInteger(POSITION_TIME);
      return true;
     }
   return false;
  }

void MrProcessBar()
  {
   int chan = InpMrChan;
   int need = MathMax(chan, 49) + 2;
   MqlRates rr[];
   int got = CopyRates(g_mr_sym, PERIOD_H1, 1, need, rr);
   if(got < need) return;
   double close = rr[got - 1].close;
   double ch_hi = -DBL_MAX, ch_lo = DBL_MAX;
   for(int i = got - 1 - chan; i < got - 1; i++)
     {
      ch_hi = MathMax(ch_hi, rr[i].high);
      ch_lo = MathMin(ch_lo, rr[i].low);
     }
   double atr_prev;
   double tau = MrStatsUpdate(rr[got - 1].high, rr[got - 1].low, close, atr_prev);

   datetime u = ServerToUtc(rr[got - 1].time + 3600);
   int nyMin = NyMinOfDay(u);
   int nyDow = NyDow(u);
   g_gtrade.SetExpertMagicNumber(MrMagic());
   g_gtrade.SetTypeFillingBySymbol(g_mr_sym);

   ulong tk; double opx; datetime topen;
   if(FindMrPosition(tk, opx, topen))
     {
      double held = (double)((long)rr[got - 1].time + 3600 - (long)topen) / 3600.0;
      double tp = g_mr_tp;
      if(tp <= 0) tp = (ch_hi + ch_lo) / 2.0;      // restart fallback
      bool fri = (nyDow == 5 && nyMin >= 990);
      if(close >= tp || held >= InpMrMaxHoldH || fri)
        {
         if(g_gtrade.PositionClose(tk))
            PrintFormat("ASCRR-Desk dip-buyer exit [%s] held %.0fh",
                        close >= tp ? "TP" : (fri ? "FRI" : "TIME"), held);
         g_mr_tp = 0.0;
        }
      return;
     }
   g_mr_tp = 0.0;

   // ---- entry ----
   if(!g_mr_warm || atr_prev <= 0 || IsNaN(tau)) return;
   if(nyDow == 5 && nyMin >= 900) return;
   if(close > ch_lo) return;                       // long-only, at/below channel low
   if(MathAbs(tau) > InpMrTauCap) return;
   if(got >= 51)
     {
      double netm = MathAbs(rr[got - 1].close - rr[got - 49].close);
      double path = 0;
      for(int j = got - 48; j <= got - 1; j++)
         path += MathAbs(rr[j].close - rr[j - 1].close);
      if(path <= 1e-9) return;
      if(netm / path >= InpMrEffMax) return;       // needs CONFIRMED chop
     }
   else return;
   double mid = (ch_hi + ch_lo) / 2.0;
   if((mid - close) / g_mr_pip < 4.5) return;      // target must clear ~1.5x costs

   if(InpRespectGuard && !MQLInfoInteger(MQL_TESTER))
     {
      if(GlobalVariableCheck("PG_SUP_ALL") && GlobalVariableGet("PG_SUP_ALL") > 0.5) return;
      string gk = "PG_SUP_" + IntegerToString(InpMagic);
      if(GlobalVariableCheck(gk) && GlobalVariableGet(gk) > 0.5) return;
     }
   if(!RiskGovOk(u)) return;
   if(!DeskOk(u)) return;

   double stop_px = close - InpMrAtrStop * atr_prev;
   double stop_pips = MathAbs(close - stop_px) / g_mr_pip;
   if(stop_pips < InpGoldStopLoPips || stop_pips > InpGoldStopHiPips) return;
   double un = Units();
   double target_risk = InpMrRiskPer100k * un * g_size_mult;
   double loss_1lot = 0.0;
   double px_now = SymbolInfoDouble(g_mr_sym, SYMBOL_ASK);
   if(px_now <= 0) px_now = close;
   if(!OrderCalcProfit(ORDER_TYPE_BUY, g_mr_sym, 1.0, px_now, stop_px, loss_1lot) || loss_1lot >= 0)
     {
      double tick_v = SymbolInfoDouble(g_mr_sym, SYMBOL_TRADE_TICK_VALUE);
      double tick_s = SymbolInfoDouble(g_mr_sym, SYMBOL_TRADE_TICK_SIZE);
      double pipval = (tick_s > 0 && tick_v > 0 ? tick_v * (g_mr_pip / tick_s) : 10.0);
      loss_1lot = -stop_pips * pipval;
     }
   double risk_per_lot = -loss_1lot;
   if(risk_per_lot < 1.0) return;
   double lots = MathMin(InpMrLotsCap100k * un, target_risk / risk_per_lot);
   double step = SymbolInfoDouble(g_mr_sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(g_mr_sym, SYMBOL_VOLUME_MIN);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < vmin) return;
   if(lots * risk_per_lot > 1.2 * target_risk) return;
   int dg = (int)SymbolInfoInteger(g_mr_sym, SYMBOL_DIGITS);
   stop_px = NormalizeDouble(stop_px, dg);
   if(g_gtrade.Buy(lots, g_mr_sym, 0.0, stop_px, 0.0, "ASCRR-DIP"))
     {
      g_mr_tp = mid;
      PrintFormat("ASCRR-Desk DIP ENTRY %s BUY %.2f lots @~%.2f sl=%.2f tp=%.2f eff-chop tau=%.2f",
                  g_mr_sym, lots, close, stop_px, mid, tau);
     }
  }

//+------------------------------------------------------------------+
//| Desk caps: PortfolioGuard v1.10 enforcement embedded in the EA   |
//| so the SAME caps run in the Strategy Tester (which loads only    |
//| one EA per run). Caps calibrated 2026-08-31 to the gold book     |
//| distribution; they fired 0x in 44 months of backtest data.       |
//+------------------------------------------------------------------+
void DeskFlattenAll(string tag)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg < InpMagic || mg > InpMagic + 9) continue;
      g_gtrade.PositionClose(tk);
     }
   Print("ASCRR desk caps BREACH [", tag, "] - desk flattened, entries suppressed for the period");
  }

void DeskCapsPump()
  {
   if(!InpDeskCapsOn) return;
   datetime now = TimeCurrent();
   if(now < g_dc_next) return;
   g_dc_next = now + 300;
   datetime u = ServerToUtc(now);
   int dk = NyDayKey(u), wk = NyWeekKey(u), mk = NyMonthKey(u);
   if(mk != g_dc_month)
     {
      g_dc_month = mk;
      g_dc_m_equity0 = AccountInfoDouble(ACCOUNT_EQUITY);
     }
   g_dc_real_d = 0; g_dc_real_w = 0; g_dc_real_m = 0;
   if(HistorySelect(now - 35 * 86400, now + 3600))
     {
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong dl = HistoryDealGetTicket(i);
         if(dl == 0) continue;
         long mg = HistoryDealGetInteger(dl, DEAL_MAGIC);
         if(mg < InpMagic || mg > InpMagic + 9) continue;
         long de = HistoryDealGetInteger(dl, DEAL_ENTRY);
         if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_OUT_BY && de != DEAL_ENTRY_INOUT) continue;
         double net = HistoryDealGetDouble(dl, DEAL_PROFIT)
                    + HistoryDealGetDouble(dl, DEAL_COMMISSION)
                    + HistoryDealGetDouble(dl, DEAL_SWAP);
         datetime du = ServerToUtc((datetime)HistoryDealGetInteger(dl, DEAL_TIME));
         if(NyMonthKey(du) == mk) g_dc_real_m += net;
         if(NyWeekKey(du) == wk)  g_dc_real_w += net;
         if(NyDayKey(du) == dk)   g_dc_real_d += net;
        }
     }
   g_dc_float = 0;
   if(InpDeskUseFloating)
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         long mg = PositionGetInteger(POSITION_MAGIC);
         if(mg < InpMagic || mg > InpMagic + 9) continue;
         g_dc_float += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
   double base = InpRUsd * Units();
   bool breach = false; string tag = "";
   if(InpDeskFloorPct > 0 && g_dc_m_equity0 > 0 && g_dc_sup_month != mk &&
      AccountInfoDouble(ACCOUNT_EQUITY) <= g_dc_m_equity0 * (1.0 - InpDeskFloorPct / 100.0))
     { g_dc_sup_month = mk; breach = true; tag = "EQUITY FLOOR"; }
   if(InpDeskMonthlyR > 0 && g_dc_sup_month != mk &&
      g_dc_real_m + g_dc_float <= -InpDeskMonthlyR * base)
     { g_dc_sup_month = mk; breach = true; tag = "MONTH CAP"; }
   if(InpDeskWeeklyR > 0 && g_dc_sup_week != wk &&
      g_dc_real_w + g_dc_float <= -InpDeskWeeklyR * base)
     { g_dc_sup_week = wk; breach = true; tag = "WEEK CAP"; }
   if(InpDeskDailyR > 0 && g_dc_sup_day != dk &&
      g_dc_real_d + g_dc_float <= -InpDeskDailyR * base)
     { g_dc_sup_day = dk; breach = true; tag = "DAY CAP"; }
   if(breach)
     {
      PrintFormat("ASCRR desk caps [%s]: day %.0f / week %.0f / month %.0f / float %.0f (base R=%.0f)",
                  tag, g_dc_real_d, g_dc_real_w, g_dc_real_m, g_dc_float, base);
      if(InpDeskFlatten) DeskFlattenAll(tag);
     }
  }

bool DeskOk(datetime u)
  {
   if(!InpDeskCapsOn) return true;
   if(g_dc_sup_month == NyMonthKey(u)) return false;
   if(g_dc_sup_week == NyWeekKey(u)) return false;
   if(g_dc_sup_day == NyDayKey(u)) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Regime classifier (display / journal only - trades unchanged)    |
//| Measured on XAUUSD H1, Mar-2023..Aug-2026 (fwd 48h from state):  |
//|   TREND-UP  11% of hours, +72 pips median, 57% up -> momentum    |
//|   RANGE     50% of hours, +51 median            -> dip-buyer     |
//|   TREND-DN   8% of hours, +61 median (STILL UP) -> stand aside   |
//|     (short side measured: IS PF 0.93 / OOS 0.91 - rejected)      |
//|   UNSTABLE  31% of hours, mean ~ +13 = noise    -> stand aside   |
//| The entry gates (tau, eff48) already enforce this map; this      |
//| block only makes the current state visible.                      |
//+------------------------------------------------------------------+
input group "=== Regime display ==="
input bool InpRegimeDisplay = true;           // show current market state on chart + journal state changes

int g_regime = 0;                             // 0 unknown 1 up 2 down 3 range 4 unstable

string RegimeName(int r)
  {
   if(r == 1) return "TREND-UP (momentum sleeves eligible)";
   if(r == 2) return "TREND-DOWN (standing aside - no validated sell edge)";
   if(r == 3) return "RANGE (dip-buyer eligible if enabled; momentum gated out)";
   if(r == 4) return "UNSTABLE (standing aside)";
   return "warming up";
  }

void RegimeUpdate()
  {
   if(!InpRegimeDisplay || g_nm == 0 || !g_m_warm[0]) return;
   MqlRates rr[];
   int got = CopyRates(g_m_sym[0], PERIOD_H1, 1, 51, rr);
   if(got < 51) return;
   double netm = MathAbs(rr[got - 1].close - rr[got - 49].close);
   double path = 0;
   for(int j = got - 48; j <= got - 1; j++)
      path += MathAbs(rr[j].close - rr[j - 1].close);
   if(path <= 1e-9) return;
   double eff = netm / path;
   double tz = g_m_lasttau[0];
   if(IsNaN(tz)) return;
   int r;
   if(eff >= 0.20 && tz >= 0.5) r = 1;
   else if(eff >= 0.20 && tz <= -0.5) r = 2;
   else if(eff < 0.20 && MathAbs(tz) <= 1.0) r = 3;
   else r = 4;
   if(r != g_regime)
     {
      g_regime = r;
      PrintFormat("ASCRR regime -> %s  (eff48=%.2f tau=%.2f)", RegimeName(r), eff, tz);
     }
   Comment(StringFormat("ASCRR-Desk v2.80\n%s: %s\neff48=%.2f  tau=%+.2f",
           g_m_sym[0], RegimeName(g_regime), eff, tz));
  }

void GoldPump()
  {
   for(int k = 0; k < g_nm; k++)
     {
      if(!g_m_warm[k])
        {
         MomWarmup(k);
         if(!g_m_warm[k]) continue;
        }
      datetime t1 = iTime(g_m_sym[k], PERIOD_H1, 1);
      if(t1 == 0 || t1 <= g_m_last[k]) continue;
      int back = 0;
      while(back < 200 && iTime(g_m_sym[k], PERIOD_H1, 1 + back) > g_m_last[k]) back++;
      for(int s = back; s >= 1; s--)
        {
         datetime bt = iTime(g_m_sym[k], PERIOD_H1, s);
         if(bt <= g_m_last[k]) continue;
         g_m_last[k] = bt;
         if(s == 1) MomProcessBar(k);
         else
           {
            MqlRates one[];
            if(CopyRates(g_m_sym[k], PERIOD_H1, s, 1, one) == 1)
              { double ap; MomStatsUpdate(k, one[0].high, one[0].low, one[0].close, ap); }
           }
        }
     }
   if(InpMrEnable && StringLen(g_mr_sym) > 0)
     {
      if(!g_mr_warm)
         MrWarmup();
      if(g_mr_warm)
        {
         datetime t1 = iTime(g_mr_sym, PERIOD_H1, 1);
         if(t1 > 0 && t1 > g_mr_last)
           {
            int back = 0;
            while(back < 200 && iTime(g_mr_sym, PERIOD_H1, 1 + back) > g_mr_last) back++;
            for(int s = back; s >= 1; s--)
              {
               datetime bt = iTime(g_mr_sym, PERIOD_H1, s);
               if(bt <= g_mr_last) continue;
               g_mr_last = bt;
               if(s == 1) MrProcessBar();
               else
                 {
                  MqlRates one[];
                  if(CopyRates(g_mr_sym, PERIOD_H1, s, 1, one) == 1)
                    { double ap; MrStatsUpdate(one[0].high, one[0].low, one[0].close, ap); }
                 }
              }
           }
        }
     }
   RegimeUpdate();
  }
