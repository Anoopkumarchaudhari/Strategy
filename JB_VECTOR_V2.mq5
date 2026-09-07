// JB VECTOR V2 - EURO. Intraday systematic EA, exactly one EURUSD entry campaign per UTC weekday.
// Research implementation of the 2026-09-06 v2.0 specification. Not a validated trading edge.
// Data package (Terminal\Common\Files\<InpDataFolder>\): timezone.csv, news_v2.csv, models\vector_v2_*.json (+.sha256), runs\, locks\
#property strict
#property version "2.00"
#property description "One mandatory EURUSD entry per UTC weekday; 0.30% all-in risk; 1:1 executable brackets; factor-residual multinomial model."

input string InpSymbol="EURUSD";
input string InpAux1="GBPUSD";                  // prices only, never orders
input string InpAux2="AUDUSD";
input string InpAux3="USDJPY";
input string InpDataFolder="JB_VECTOR_V2";      // Terminal/Common/Files
input ulong  InpMagic=26090601;
input bool   InpAllowRealAccount=false;
input bool   InpConfirmDedicatedAccount=false;
input double InpCommissionRoundTrip=7.0;        // USD per lot round trip (estimate; tester charges none)
input double InpExitSlippagePips=0.20;
input double InpMaximumSpreadPips=0.80;         // spec 0.80; change ONLY for a labelled research sensitivity
input string InpTestRunID="v2test";
input string InpRiskEpisode="MAIN";             // never change to evade a kill latch
input bool   InpShadowContinueAfterKill=false;  // TESTER ONLY: continuous shadow path beyond the 5% kill (spec 17); never live

#define V2_VERSION "JB_VECTOR_V2_2.0R"
#define V2_POLICY "JBV2|S=08:00London|Dn=11:30NY|R=16:00NY|FC=16:30NY|THR=0.10->0.04linear|ATR14mean|STRUCT6|BUF0.25|MINSTOP8+0.2|MAXSTOP40|HOLD30-180|FACTOR20d|ROWS2000|ROLL200|RIDGE0.10|BETA0-2|RES12|CHG3|COM6|H1x6|EFF0.25-0.60|CLIP4|STDCLIP5|L2=0.01|TL2=0.10|TEMP0.5-2|TRAIN756=693+63|RISK0.30|RR1|LEV5"
#define NF 12
#define DAYS_BACK 45
#define NSLOT (DAYS_BACK*288)
const double PIP=0.0001, RISK=0.003, MAX_LEVERAGE=5.0, MAX_LOTS_ABS=5.0;
const double MIN_STOP=0.0008, MAX_STOP=0.0040, ENTRY_ALLOW=0.00002, ATR_BUF=0.25;
const double THR0=0.10, THR1=0.04;
const int    MAX_HOLD=180*60, MIN_HOLD=30*60;

struct TZRow { datetime first,last; int london,ny,server; };
struct NewsRow { datetime published,start,end; };
struct Block { datetime start,end; };
struct Model {
   bool valid; string id,file,hash,reason; datetime effective,expires,trained,calibrated;
   bool active[NF]; double mean[NF],scale[NF],tp[NF+1],tm[NF+1],ur[NF+1],temperature;
};
struct Daily {
   bool valid,valid_e; datetime date; string reason;
   double vE,vG,vA,vJ,beta,alpha,Se12,Se3,Sf6,vEo,alphaE,SE12,SE3,SY6; int rows,rowsE,n12,n3,n6;
};
struct Feat { bool ok,prim,eur; string why; datetime t; double Z,U,F,ZE,UE,FE,T,G,a,low6,high6,c1,c2; };
struct Cand {
   bool elig; string reason,mode; int side; datetime t,exit;
   double w,D,H,tau,N,ref,sl,tp,A,K,pTP,pSL,pTM,u,EV,lots,rb,q,loss,lev,margin,x[NF]; bool floor_bind;
};
struct State {
   datetime day,pending_time,exit_time,close_time,entry_time,cand_t,cash_epoch;
   int count,kill,failed,protected_ok,side,preferred,opex,any_ok,shadow_killed;
   ulong pending_order,position_id,close_order,last_cash,closed_position;
   double budget,distance,sl_orig,units,peak,entry_equity,planned_lots,quality,best_q,loss_planned,ref_price;
   string mode,model_id,best_desc,reason_hist;
};

string syms[4]; TZRow tz[]; NewsRow news[]; Model factorModels[],eurModels[]; Model mFactor,mEur; Daily dly; State st;
double gC[4][NSLOT]; bool gH[4][NSLOT];
string root,prefix,reason="INITIALIZING",policy_hash="";
int lock_handle=INVALID_HANDLE;
bool tester=false,busy=false,ready=false,disk_failed=false,history_ready=false,mandate_alerted=false,daily_tried=false;
datetime last_clock=0,last_reconcile=0,last_news_load=0,last_health=0,close_alert=0,last_try=0,feat_t=0,day_S=0,day_Dn=0,day_R=0,day_FC=0,day_C=0;
int attempts=0,dd_level=0; double observed_max_dd=0; Feat feat; Cand cbuy,csell; datetime decision_logged_t=0;
string daily_reason_logged="",bars_diag="";

// ------------------------------------------------------------------------------------------------ utilities
double Clip(double x,double lo,double hi) { return MathMin(MathMax(x,lo),hi); }
datetime Day(datetime t) { return (datetime)(((long)t/86400)*86400); }
datetime Grid(datetime t) { return (datetime)(((long)t/300)*300); }
string U64(ulong x) { return StringFormat("%I64u",x); }
string I64(long x) { return StringFormat("%I64d",x); }
string Dbl(double x) { return StringFormat("%.17g",x); }
string Esc(string x) { StringReplace(x,"\\","\\\\"); StringReplace(x,"\"","\\\""); StringReplace(x,"\r"," "); StringReplace(x,"\n"," "); return x; }
string Hex(const uchar &digest[]) { string h=""; for(int i=0;i<ArraySize(digest);i++) h+=StringFormat("%02x",digest[i]); return h; }
string SHABytes(const uchar &bytes[]) { uchar key[],digest[]; if(CryptEncode(CRYPT_HASH_SHA256,bytes,key,digest)!=32) return ""; return Hex(digest); }
string SHA(string s) {
   uchar bytes[]; int n=StringToCharArray(s,bytes,0,WHOLE_ARRAY,CP_UTF8); if(n<1) return "";
   ArrayResize(bytes,n-1); return SHABytes(bytes);
}
bool ReadBytes(string name,uchar &bytes[]) {
   int h=FileOpen(name,FILE_READ|FILE_BIN|FILE_COMMON|FILE_SHARE_READ); if(h==INVALID_HANDLE) return false;
   ulong size=FileSize(h); if(size>100000000) { FileClose(h); return false; }
   ArrayResize(bytes,(int)size); uint got=FileReadArray(h,bytes,0,(int)size); FileClose(h); return got==size;
}
bool ReadText(string name,string &out) {
   uchar bytes[]; if(!ReadBytes(name,bytes)) return false;
   out=CharArrayToString(bytes,0,ArraySize(bytes),CP_UTF8); StringReplace(out,"\r",""); return true;
}
bool WriteBytes(string name,const uchar &bytes[]) {
   int h=FileOpen(name,FILE_WRITE|FILE_BIN|FILE_COMMON); if(h==INVALID_HANDLE) return false;
   uint n=FileWriteArray(h,bytes,0,WHOLE_ARRAY); FileFlush(h); FileClose(h); return n==(uint)ArraySize(bytes);
}
void Append(string name,string line) {
   int h=FileOpen(name,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ,0,CP_UTF8);
   if(h==INVALID_HANDLE) { disk_failed=true; Print("JV2 LOG WRITE FAILURE ",GetLastError()); return; }
   FileSeek(h,0,SEEK_END); if(FileWriteString(h,line+"\n")==0) disk_failed=true; FileFlush(h); FileClose(h);
}
void Log(string event,string detail="",string extra="") {
   if(prefix=="") { Print(event,": ",detail); return; }
   string line="{\"version\":\""+V2_VERSION+"\",\"policy_hash\":\""+policy_hash+"\",\"utc\":"+I64(last_clock)+",\"server\":"+I64(TimeTradeServer())+
       ",\"day\":"+I64(st.day)+",\"event\":\""+Esc(event)+"\",\"detail\":\""+Esc(detail)+"\",\"count\":"+IntegerToString(st.count)+
       ",\"kill\":"+IntegerToString(st.kill);
   if(extra!="") line+=","+extra;
   Append(prefix+"_events.jsonl",line+"}");
}
void Status(string message) {
   if(reason!=message) { reason=message; Log("STATUS",message); }
   if(tester) return;
   Comment("JB VECTOR V2 | UTC ",TimeToString(last_clock)," | entries ",st.count,"/1\n",reason,"\nmodel ",st.model_id,"\n5% kill: ",st.kill!=0?"LATCHED":"clear");
}

// ------------------------------------------------------------------------------------------------ durable state
bool SaveState() {
   string body=V2_VERSION+"\n"+I64(st.day)+","+IntegerToString(st.count)+","+IntegerToString(st.kill)+","+IntegerToString(st.failed)+","+
       U64(st.pending_order)+","+I64(st.pending_time)+","+U64(st.position_id)+","+Dbl(st.budget)+","+Dbl(st.distance)+","+
       I64(st.exit_time)+","+IntegerToString(st.protected_ok)+","+Dbl(st.units)+","+Dbl(st.peak)+","+U64(st.last_cash)+","+
       U64(st.close_order)+","+I64(st.close_time)+","+Dbl(st.entry_equity)+","+Dbl(st.planned_lots)+","+IntegerToString(st.side)+","+
       Dbl(st.sl_orig)+","+I64(st.entry_time)+","+IntegerToString(st.preferred)+","+Dbl(st.quality)+","+st.mode+","+st.model_id+","+
       I64(st.cash_epoch)+","+IntegerToString(st.opex)+","+Dbl(st.best_q)+"\n";
   string hash=SHA(body); if(StringLen(hash)!=64) { disk_failed=true; return false; }
   uchar bytes[]; int len=StringToCharArray(hash+"\n"+body,bytes,0,WHOLE_ARRAY,CP_UTF8); if(len<1) { disk_failed=true; return false; }
   ArrayResize(bytes,len-1);
   string temp=prefix+"_state.tmp",dest=prefix+"_state.jvm";
   if(!WriteBytes(temp,bytes)) { disk_failed=true; return false; }
   if(!FileMove(temp,FILE_COMMON,dest,FILE_COMMON|FILE_REWRITE)) { if(!WriteBytes(dest,bytes)) { disk_failed=true; return false; } FileDelete(temp,FILE_COMMON); }
   return true;
}
bool LoadState() {
   if(!FileIsExist(prefix+"_state.jvm",FILE_COMMON)) return true;
   string all,lines[],v[]; if(!ReadText(prefix+"_state.jvm",all)) return false;
   int pos=StringFind(all,"\n"); if(pos!=64) return false;
   string hash=StringSubstr(all,0,pos),body=StringSubstr(all,pos+1); if(SHA(body)!=hash) return false;
   if(StringSplit(body,'\n',lines)<2 || lines[0]!=V2_VERSION) return false;
   if(StringSplit(lines[1],',',v)!=33) return false;
   st.day=(datetime)StringToInteger(v[0]); st.count=(int)StringToInteger(v[1]); st.kill=(int)StringToInteger(v[2]); st.failed=(int)StringToInteger(v[3]);
   st.pending_order=(ulong)StringToInteger(v[4]); st.pending_time=(datetime)StringToInteger(v[5]); st.position_id=(ulong)StringToInteger(v[6]);
   st.budget=StringToDouble(v[7]); st.distance=StringToDouble(v[8]); st.exit_time=(datetime)StringToInteger(v[9]); st.protected_ok=(int)StringToInteger(v[10]);
   st.units=StringToDouble(v[11]); st.peak=StringToDouble(v[12]); st.last_cash=(ulong)StringToInteger(v[13]); st.close_order=(ulong)StringToInteger(v[14]);
   st.close_time=(datetime)StringToInteger(v[15]); st.entry_equity=StringToDouble(v[16]); st.planned_lots=StringToDouble(v[17]); st.side=(int)StringToInteger(v[18]);
   st.sl_orig=StringToDouble(v[19]); st.entry_time=(datetime)StringToInteger(v[20]); st.preferred=(int)StringToInteger(v[21]); st.quality=StringToDouble(v[22]);
   st.mode=v[23]; st.model_id=v[24]; st.cash_epoch=(datetime)StringToInteger(v[25]); st.opex=(int)StringToInteger(v[26]); st.best_q=StringToDouble(v[27]); st.loss_planned=StringToDouble(v[28]); st.ref_price=StringToDouble(v[29]); st.closed_position=(ulong)StringToInteger(v[30]); st.any_ok=(int)StringToInteger(v[31]); st.shadow_killed=(int)StringToInteger(v[32]);
   return st.count>=0 && st.count<=1 && st.units>0 && st.peak>0 && MathIsValidNumber(st.units) && MathIsValidNumber(st.peak);
}

// ------------------------------------------------------------------------------------------------ clocks
bool LoadTZ() {
   ArrayResize(tz,0); string all,lines[]; if(!ReadText(root+"timezone.csv",all)) return false;
   int n=StringSplit(all,'\n',lines);
   for(int i=0;i<n;i++) {
       if(lines[i]=="" || StringGetCharacter(lines[i],0)=='#') continue;
       string c[]; if(StringSplit(lines[i],',',c)!=5) return false;
       TZRow row; row.first=(datetime)StringToInteger(c[0]); row.last=(datetime)StringToInteger(c[1]);
       row.london=(int)StringToInteger(c[2]); row.ny=(int)StringToInteger(c[3]); row.server=(int)StringToInteger(c[4]);
       int j=ArraySize(tz); if(row.last<=row.first || (j>0 && row.first!=tz[j-1].last)) return false;
       ArrayResize(tz,j+1); tz[j]=row;
   }
   return ArraySize(tz)>0;
}
bool Offsets(datetime utc,int &lo,int &ny,int &server) {
   int low=0,high=ArraySize(tz)-1;
   while(low<=high) { int mid=(low+high)/2;
       if(utc<tz[mid].first) high=mid-1; else if(utc>=tz[mid].last) low=mid+1;
       else { lo=tz[mid].london; ny=tz[mid].ny; server=tz[mid].server; return true; } }
   return false;
}
bool ToUTC(datetime server,datetime &utc) {
   int found=0;
   for(int i=0;i<ArraySize(tz);i++) { datetime c=server-tz[i].server*60; if(c>=tz[i].first && c<tz[i].last) { utc=c; found++; } }
   return found==1;
}
bool ToServer(datetime utc,datetime &server) { int lo,ny,b; if(!Offsets(utc,lo,ny,b)) return false; server=utc+b*60; return true; }
datetime BrokerClose(datetime utc) {
   datetime srv; if(!ToServer(utc,srv)) return 0;
   MqlDateTime x; TimeToStruct(srv,x); datetime begin,end; int seconds=x.hour*3600+x.min*60+x.sec;
   for(uint i=0;i<20;i++) {
       if(!SymbolInfoSessionTrade(InpSymbol,(ENUM_DAY_OF_WEEK)x.day_of_week,i,begin,end)) break;
       int a=(int)((long)begin%86400),b=(int)((long)end%86400); if(b==0 || b<=a) b+=86400;
       if(seconds>=a && seconds<b) { datetime c; if(ToUTC(Day(srv)+b,c)) return c; }
   }
   return 0;
}
bool DayTimes(datetime day) {
   int lo,ny,b; if(!Offsets(day+12*3600,lo,ny,b)) return false;
   day_S=day+8*3600-lo*60; day_Dn=day+11*3600+1800-ny*60; day_R=day+16*3600-ny*60; day_FC=day+16*3600+1800-ny*60;
   datetime bc=BrokerClose(day_S>0?day_S+3600:day+12*3600);
   day_C=day_FC; if(bc>0) day_C=MathMin(day_FC,bc-1800);
   datetime cut=Grid(day_C-1800);
   day_Dn=MathMin(day_Dn,cut); day_R=MathMin(day_R,cut);
   return true;
}

// ------------------------------------------------------------------------------------------------ news
bool LoadNews() {
   string all,lines[]; if(!ReadText(root+"news_v2.csv",all)) return false;
   NewsRow fresh[]; int count=0,n=StringSplit(all,'\n',lines);
   for(int i=1;i<n;i++) {
       if(lines[i]=="") continue;
       string c[]; int k=StringSplit(lines[i],',',c); if(k<8) return false;
       NewsRow row; row.published=(datetime)StringToInteger(c[0]); row.start=(datetime)StringToInteger(c[k-2]); row.end=(datetime)StringToInteger(c[k-1]);
       if(row.end<=row.start || row.published<=0) return false;
       ArrayResize(fresh,count+1,5000); fresh[count++]=row;
   }
   if(count==0) return false;
   ArrayResize(news,count); for(int i=0;i<count;i++) news[i]=fresh[i];
   return true;
}
Block newsCache[]; datetime newsCacheAt=0; bool newsCacheOk=false;
bool NewsKnownRaw(datetime now,Block &blocks[]);
bool NewsKnown(datetime now,Block &blocks[]) {
   if(newsCacheAt==0 || now<newsCacheAt || now-newsCacheAt>=60) { newsCacheOk=NewsKnownRaw(now,newsCache); newsCacheAt=now; }
   ArrayResize(blocks,ArraySize(newsCache)); for(int i=0;i<ArraySize(newsCache);i++) blocks[i]=newsCache[i];
   return newsCacheOk;
}
bool NewsKnownRaw(datetime now,Block &blocks[]) {
   ArrayResize(blocks,0); if(ArraySize(news)==0) return false;
   for(int i=0;i<ArraySize(news);i++) if(news[i].published<=now) { int n=ArraySize(blocks); ArrayResize(blocks,n+1,5000); blocks[n].start=news[i].start; blocks[n].end=news[i].end; }
   for(int i=1;i<ArraySize(blocks);i++) { Block v=blocks[i]; int j=i-1; while(j>=0 && blocks[j].start>v.start) { blocks[j+1]=blocks[j]; j--; } blocks[j+1]=v; }
   int out=0;
   for(int i=0;i<ArraySize(blocks);i++) { if(out>0 && blocks[i].start<=blocks[out-1].end) blocks[out-1].end=MathMax(blocks[out-1].end,blocks[i].end); else blocks[out++]=blocks[i]; }
   ArrayResize(blocks,out); return true;
}
// in-blackout flag, next blackout start >= t, last blackout end <= t (0 if none)
bool NewsState(datetime now,datetime t,bool &inb,datetime &next_start,datetime &last_end) {
   Block b[]; if(!NewsKnown(now,b)) return false;
   inb=false; next_start=D'2100.01.01'; last_end=0;
   for(int i=0;i<ArraySize(b);i++) {
       if(t>=b[i].start && t<b[i].end) inb=true;
       if(b[i].start>=t) next_start=MathMin(next_start,b[i].start);
       if(b[i].end<=t) last_end=MathMax(last_end,b[i].end);
   }
   return true;
}

// ------------------------------------------------------------------------------------------------ model files
bool JFind(const string &txt,string key,int &pos) {
   pos=StringFind(txt,"\""+key+"\""); if(pos<0) return false; pos=StringFind(txt,":",pos); if(pos<0) return false; pos++; return true;
}
string JToken(const string &txt,int pos) {
   int n=StringLen(txt); while(pos<n && (StringGetCharacter(txt,pos)==' ' || StringGetCharacter(txt,pos)=='\n' || StringGetCharacter(txt,pos)=='\t')) pos++;
   int e=pos; while(e<n) { ushort ch=StringGetCharacter(txt,e); if(ch==',' || ch=='}' || ch==']' || ch=='\n' || ch==' ') break; e++; }
   return StringSubstr(txt,pos,e-pos);
}
bool JNum(const string &txt,string key,double &v) {
   int pos; if(!JFind(txt,key,pos)) return false; string tok=JToken(txt,pos); if(tok=="") return false;
   v=StringToDouble(tok); return MathIsValidNumber(v);
}
bool JStr(const string &txt,string key,string &v) {
   int pos; if(!JFind(txt,key,pos)) return false; int a=StringFind(txt,"\"",pos); if(a<0) return false;
   int b=StringFind(txt,"\"",a+1); if(b<0) return false; v=StringSubstr(txt,a+1,b-a-1); return true;
}
bool JList(const string &txt,string key,string &items[]) {
   int pos; if(!JFind(txt,key,pos)) return false; int a=StringFind(txt,"[",pos); if(a<0) return false;
   int b=StringFind(txt,"]",a); if(b<0) return false; string body=StringSubstr(txt,a+1,b-a-1);
   StringReplace(body,"\n",""); StringReplace(body,"\r",""); StringReplace(body," ",""); StringReplace(body,"\t","");
   return StringSplit(body,',',items)>0;
}
bool JNumArr(const string &txt,string key,double &out[],int n) {
   string it[]; if(!JList(txt,key,it) || ArraySize(it)!=n) return false;
   for(int i=0;i<n;i++) { out[i]=StringToDouble(it[i]); if(!MathIsValidNumber(out[i])) return false; }
   return true;
}
bool ParseModel(string file,Model &m) {
   ZeroMemory(m); m.valid=false; m.file=file;
   uchar bytes[]; if(!ReadBytes(file,bytes)) { m.reason="UNREADABLE"; return false; }
   string checksum; if(!ReadText(file+".sha256",checksum)) { m.reason="CHECKSUM_FILE_MISSING"; return false; }
   StringReplace(checksum,"\n",""); StringTrimLeft(checksum); StringTrimRight(checksum);
   m.hash=SHABytes(bytes); if(m.hash!=checksum) { m.reason="CHECKSUM_MISMATCH"; return false; }
   string txt=CharArrayToString(bytes,0,ArraySize(bytes),CP_UTF8);
   double sv,tmp; string ph,names[];
   if(!JNum(txt,"schema_version",sv) || sv!=2) { m.reason="SCHEMA"; return false; }
   if(!JStr(txt,"model_id",m.id) || !JStr(txt,"policy_hash",ph) || ph!=policy_hash) { m.reason="POLICY_HASH"; return false; }
   if(!JList(txt,"feature_names",names) || ArraySize(names)!=NF) { m.reason="FEATURE_NAMES"; return false; }
   string expect[NF]={"\"sZ\"","\"sU\"","\"sF\"","\"sT\"","\"sZG\"","\"sFG\"","\"G\"","\"w_over_D\"","\"D_over_a\"","\"H_over_180\"","\"tau\"","\"N\""};
   for(int i=0;i<NF;i++) if(names[i]!=expect[i]) { m.reason="FEATURE_ORDER"; return false; }
   string act[]; if(!JList(txt,"active_features",act) || ArraySize(act)!=NF) { m.reason="ACTIVE"; return false; }
   for(int i=0;i<NF;i++) { if(act[i]!="true" && act[i]!="false") { m.reason="ACTIVE"; return false; } m.active[i]=(act[i]=="true"); }
   double coef[NF];
   if(!JNumArr(txt,"mean",m.mean,NF) || !JNumArr(txt,"scale",m.scale,NF)) { m.reason="MEAN_SCALE"; return false; }
   if(!JNum(txt,"tp_intercept",m.tp[0]) || !JNumArr(txt,"tp_coef",coef,NF)) { m.reason="TP"; return false; } for(int i=0;i<NF;i++) m.tp[i+1]=coef[i];
   if(!JNum(txt,"time_intercept",m.tm[0]) || !JNumArr(txt,"time_coef",coef,NF)) { m.reason="TIME"; return false; } for(int i=0;i<NF;i++) m.tm[i+1]=coef[i];
   if(!JNum(txt,"time_return_intercept",m.ur[0]) || !JNumArr(txt,"time_return_coef",coef,NF)) { m.reason="TIME_RETURN"; return false; } for(int i=0;i<NF;i++) m.ur[i+1]=coef[i];
   if(!JNum(txt,"temperature",m.temperature) || m.temperature<0.5 || m.temperature>2.0) { m.reason="TEMPERATURE"; return false; }
   if(!JNum(txt,"trained_through_utc",tmp)) { m.reason="DATES"; return false; } m.trained=(datetime)tmp;
   if(!JNum(txt,"calibration_through_utc",tmp)) { m.reason="DATES"; return false; } m.calibrated=(datetime)tmp;
   if(!JNum(txt,"effective_from_utc",tmp)) { m.reason="DATES"; return false; } m.effective=(datetime)tmp;
   if(!JNum(txt,"expires_utc",tmp)) { m.reason="DATES"; return false; } m.expires=(datetime)tmp;
   if(m.effective<m.calibrated || m.expires!=m.effective+35*86400) { m.reason="EFFECTIVE_EXPIRY"; return false; }
   for(int i=0;i<NF;i++) if(m.active[i] && m.scale[i]<=0) { m.reason="SCALE"; return false; }
   m.valid=true; return true;
}
bool LoadModelFolder(string pattern,Model &list[]) {
   ArrayResize(list,0); string name; long h=FileFindFirst(root+"models\\"+pattern,name,FILE_COMMON); if(h==INVALID_HANDLE) return false;
   do { if(StringFind(name,".json")==StringLen(name)-5) { Model m; ParseModel(root+"models\\"+name,m); int n=ArraySize(list); ArrayResize(list,n+1); list[n]=m;
            if(!m.valid) Log("MODEL_FILE_INVALID",name+" "+m.reason); } } while(FileFindNext(h,name));
   FileFindClose(h); return ArraySize(list)>0;
}
bool SelectModel(const Model &list[],datetime day,Model &out) {
   ZeroMemory(out); out.valid=false; bool found=false;
   for(int i=0;i<ArraySize(list);i++) if(list[i].valid && list[i].effective<=day && day<list[i].expires && (!found || list[i].effective>out.effective)) { out=list[i]; found=true; }
   return found;
}

// ------------------------------------------------------------------------------------------------ daily factor estimation
double PopStd(const double &x[],int n,double &mean) {
   mean=0; for(int i=0;i<n;i++) mean+=x[i]; mean/=n; double s=0; for(int i=0;i<n;i++) s+=(x[i]-mean)*(x[i]-mean); return MathSqrt(s/n);
}
// rolling sums of length L over a window with validity flags; appends valid sums
void RollAppend(const double &v[],const bool &ok[],int n,int L,double &out[],int &cnt) {
   for(int p=L-1;p<n;p++) { bool all=true; double s=0; for(int q=p-L+1;q<=p;q++) { if(!ok[q]) { all=false; break; } s+=v[q]; } if(all) { ArrayResize(out,cnt+1,4000); out[cnt++]=s; } }
}
bool LoadGrid(datetime day) {
   datetime g0=day-DAYS_BACK*86400;
   for(int s=0;s<4;s++) {
       for(int i=0;i<NSLOT;i++) gH[s][i]=false;
       datetime from,to; if(!ToServer(g0,from) || !ToServer(day-300,to)) return false;
       MqlRates r[]; ResetLastError(); int n=CopyRates(syms[s],PERIOD_M5,from,to,r);
       if(n<=0) return false;
       for(int i=0;i<n;i++) { datetime u; if(!ToUTC(r[i].time,u) || u<g0 || u>=day) continue; int k=(int)((u-g0)/300); gC[s][k]=r[i].close; gH[s][k]=true; }
   }
   return true;
}
bool BuildDaily(datetime day) {
   ZeroMemory(dly); dly.date=day; dly.valid=false; dly.valid_e=false;
   if(!LoadGrid(day)) { dly.reason="HISTORY_UNAVAILABLE"; return false; }
   datetime g0=day-DAYS_BACK*86400; int hist[]; int nh=0;
   for(int d=DAYS_BACK-1;d>=0 && nh<20;d--) {
       MqlDateTime x; TimeToStruct(g0+d*86400,x); if(x.day_of_week==0 || x.day_of_week==6) continue;
       int cnt=0; for(int k=72;k<216;k++) if(gH[0][d*288+k]) cnt++;
       if(cnt>=100) { ArrayResize(hist,nh+1); hist[nh++]=d; }
   }
   if(nh<20) { dly.reason="INSUFFICIENT_FACTOR_HISTORY"; return false; }
   // aligned rows and EUR-only rows, with (date,position) for rolling sums
   double rE[],rG[],rA[],rJ[]; int rd[],rp[]; int n=0; double eE[]; int ed[],ep[]; int nE=0;
   for(int hIdx=0;hIdx<nh;hIdx++) { int d=hist[hIdx];
       for(int k=73;k<216;k++) { int g=d*288+k;
           bool okE=gH[0][g] && gH[0][g-1]; if(!okE) continue;
           double re=MathLog(gC[0][g]/gC[0][g-1]);
           ArrayResize(eE,nE+1,4000); ArrayResize(ed,nE+1,4000); ArrayResize(ep,nE+1,4000); eE[nE]=re; ed[nE]=hIdx; ep[nE]=k-73; nE++;
           bool ok=true; for(int s=1;s<4;s++) if(!gH[s][g] || !gH[s][g-1]) ok=false; if(!ok) continue;
           ArrayResize(rE,n+1,4000); ArrayResize(rG,n+1,4000); ArrayResize(rA,n+1,4000); ArrayResize(rJ,n+1,4000); ArrayResize(rd,n+1,4000); ArrayResize(rp,n+1,4000);
           rE[n]=re; rG[n]=MathLog(gC[1][g]/gC[1][g-1]); rA[n]=MathLog(gC[2][g]/gC[2][g-1]); rJ[n]=MathLog(gC[3][g]/gC[3][g-1]); rd[n]=hIdx; rp[n]=k-73; n++;
       }
   }
   double win[143]; bool wok[143];
   // EUR-only backup
   dly.rowsE=nE;
   if(nE>=2000) { double mE; double vEo=PopStd(eE,nE,mE);
       if(vEo>=1e-8) { double yE[]; ArrayResize(yE,nE); double my=0; for(int i=0;i<nE;i++) { yE[i]=eE[i]/vEo; my+=yE[i]; } my/=nE;
           double s12[],s3[],s6[]; int c12=0,c3=0,c6=0;
           for(int hIdx=0;hIdx<nh;hIdx++) { for(int p=0;p<143;p++) { wok[p]=false; win[p]=0; }
               for(int i=0;i<nE;i++) if(ed[i]==hIdx) { wok[ep[i]]=true; win[ep[i]]=yE[i]-my; }
               RollAppend(win,wok,143,12,s12,c12); RollAppend(win,wok,143,3,s3,c3);
           }
           // recompute y-sums (6) separately
           double y6[]; int c6b=0;
           for(int hIdx=0;hIdx<nh;hIdx++) { for(int p=0;p<143;p++) { wok[p]=false; win[p]=0; }
               for(int i=0;i<nE;i++) if(ed[i]==hIdx) { wok[ep[i]]=true; win[ep[i]]=yE[i]; }
               RollAppend(win,wok,143,6,y6,c6b); }
           if(c12>=200 && c3>=200 && c6b>=200) { double m1,m2,m3; double S12=PopStd(s12,c12,m1),S3=PopStd(s3,c3,m2),S6=PopStd(y6,c6b,m3);
               if(S12>1e-8 && S3>1e-8 && S6>1e-8) { dly.valid_e=true; dly.vEo=vEo; dly.alphaE=my; dly.SE12=S12; dly.SE3=S3; dly.SY6=S6; } }
       } }
   dly.rows=n;
   if(n<2000) { dly.reason="INSUFFICIENT_ALIGNED_ROWS"; return dly.valid_e; }
   double mE,mG,mA,mJ; double vE=PopStd(rE,n,mE),vG=PopStd(rG,n,mG),vA=PopStd(rA,n,mA),vJ=PopStd(rJ,n,mJ);
   if(vE<1e-8 || vG<1e-8 || vA<1e-8 || vJ<1e-8) { dly.reason="ZERO_VARIANCE"; return dly.valid_e; }
   double y[],f[]; ArrayResize(y,n); ArrayResize(f,n); double my=0,mf=0;
   for(int i=0;i<n;i++) { y[i]=rE[i]/vE; f[i]=(rG[i]/vG+rA[i]/vA-rJ[i]/vJ)/3.0; my+=y[i]; mf+=f[i]; } my/=n; mf/=n;
   double cov=0,var=0; for(int i=0;i<n;i++) { cov+=(f[i]-mf)*(y[i]-my); var+=(f[i]-mf)*(f[i]-mf); } cov/=n; var/=n;
   double beta=Clip(cov/(var+0.10),0,2),alpha=my-beta*mf;
   double e12[],e3[],f6[]; int c12=0,c3=0,c6=0;
   for(int hIdx=0;hIdx<nh;hIdx++) {
       for(int p=0;p<143;p++) { wok[p]=false; win[p]=0; }
       for(int i=0;i<n;i++) if(rd[i]==hIdx) { wok[rp[i]]=true; win[rp[i]]=y[i]-alpha-beta*f[i]; }
       RollAppend(win,wok,143,12,e12,c12); RollAppend(win,wok,143,3,e3,c3);
       for(int i=0;i<n;i++) if(rd[i]==hIdx) win[rp[i]]=f[i];
       RollAppend(win,wok,143,6,f6,c6);
   }
   if(c12<200 || c3<200 || c6<200) { dly.reason="INSUFFICIENT_ROLLING"; return dly.valid_e; }
   double m1,m2,m3; double S12=PopStd(e12,c12,m1),S3=PopStd(e3,c3,m2),S6=PopStd(f6,c6,m3);
   if(S12<=1e-8 || S3<=1e-8 || S6<=1e-8) { dly.reason="ZERO_ROLLING_SCALE"; return dly.valid_e; }
   dly.valid=true; dly.vE=vE; dly.vG=vG; dly.vA=vA; dly.vJ=vJ; dly.beta=beta; dly.alpha=alpha; dly.Se12=S12; dly.Se3=S3; dly.Sf6=S6; dly.n12=c12; dly.n3=c3; dly.n6=c6;
   return true;
}

// ------------------------------------------------------------------------------------------------ boundary features
bool Bars(string sym,datetime t,int need,double &C[],double &H[],double &L[]) {
   datetime from,to; if(!ToServer(t-need*300,from) || !ToServer(t-300,to)) return false;
   MqlRates r[]; ResetLastError(); int n=CopyRates(sym,PERIOD_M5,from,to,r); bars_diag=sym+" n="+IntegerToString(n)+" err="+IntegerToString(GetLastError()); if(n<=0) return false;
   bool have[20]; for(int i=0;i<20;i++) have[i]=false;
   for(int i=0;i<n;i++) { datetime u; if(!ToUTC(r[i].time,u)) continue; long k=((long)t-(long)u)/300; if((long)t-(long)u!=k*300 || k<1 || k>need) continue; C[k]=r[i].close; H[k]=r[i].high; L[k]=r[i].low; have[k]=true; }
   for(int k=1;k<=need;k++) if(!have[k]) { bars_diag+=" missing_k="+IntegerToString(k)+" first_bar="+TimeToString(r[0].time)+" last_bar="+TimeToString(r[n-1].time); return false; }
   return true;
}
bool BuildFeatures(datetime t,Feat &f) {
   ZeroMemory(f); f.t=t; f.ok=false; f.prim=false; f.eur=false;
   double C[4][20],H[4][20],L[4][20]; double c1[20],h1[20],l1[20];
   if(!Bars(syms[0],t,15,c1,h1,l1)) { f.why="EURUSD_BARS_UNAVAILABLE "+bars_diag; return false; }
   for(int k=0;k<20;k++) { C[0][k]=c1[k]; H[0][k]=h1[k]; L[0][k]=l1[k]; }
   bool aux=true;
   for(int s=1;s<4;s++) { if(!Bars(syms[s],t,13,c1,h1,l1)) { aux=false; break; } for(int k=0;k<20;k++) C[s][k]=c1[k]; }
   // ATR / structure
   double tr=0; for(int i=1;i<=14;i++) tr+=MathMax(H[0][i]-L[0][i],MathMax(MathAbs(H[0][i]-C[0][i+1]),MathAbs(L[0][i]-C[0][i+1])));
   f.a=tr/14.0; f.low6=L[0][1]; f.high6=H[0][1]; for(int i=2;i<=6;i++) { f.low6=MathMin(f.low6,L[0][i]); f.high6=MathMax(f.high6,H[0][i]); }
   f.c1=C[0][1]; f.c2=C[0][2];
   if(f.a<=0 || !MathIsValidNumber(f.a)) { f.why="INVALID_ATR"; return false; }
   // H1 efficiency
   datetime hb=(datetime)(((long)t/3600)*3600-3600); datetime from,to; if(!ToServer(hb-6*3600,from) || !ToServer(hb,to)) { f.why="TZ"; return false; }
   MqlRates r[]; int n=CopyRates(syms[0],PERIOD_H1,from,to,r); if(n<=0) { f.why="H1_UNAVAILABLE"; return false; }
   double h[7]; bool hv[7]; for(int i=0;i<7;i++) hv[i]=false;
   for(int i=0;i<n;i++) { datetime u; if(!ToUTC(r[i].time,u)) continue; long k=((long)hb-(long)u)/3600; if((long)hb-(long)u!=k*3600 || k<0 || k>6) continue; h[k]=MathLog(r[i].close); hv[k]=true; }
   for(int i=0;i<7;i++) if(!hv[i]) { f.why="H1_GAP n="+IntegerToString(n)+" k="+IntegerToString(i)+(n>0?" first="+TimeToString(r[0].time)+" last="+TimeToString(r[n-1].time):""); return false; }
   double den=0; for(int i=1;i<=6;i++) den+=MathAbs(h[i-1]-h[i]);
   f.T=(den==0)?0.0:(h[0]-h[6])/den; f.G=Clip((MathAbs(f.T)-0.25)/0.35,0,1);
   f.ok=true;
   // returns
   double rr[4][13];
   for(int s=0;s<4;s++) for(int i=1;i<=12;i++) rr[s][i]=(s==0 || aux)?MathLog(C[s][i]/C[s][i+1]):0;
   if(dly.valid && aux) {
       double sz=0,su=0,sf=0;
       for(int i=1;i<=12;i++) { double yy=rr[0][i]/dly.vE,ff=(rr[1][i]/dly.vG+rr[2][i]/dly.vA-rr[3][i]/dly.vJ)/3.0,ee=yy-dly.alpha-dly.beta*ff;
           sz+=ee; if(i<=3) su+=ee; if(i<=6) sf+=ff; }
       f.Z=Clip(sz/dly.Se12,-4,4); f.U=Clip(su/dly.Se3,-4,4); f.F=Clip(sf/dly.Sf6,-4,4); f.prim=true;
   }
   if(dly.valid_e) {
       double sz=0,su=0,sf=0;
       for(int i=1;i<=12;i++) { double yy=rr[0][i]/dly.vEo,ee=yy-dly.alphaE; sz+=ee; if(i<=3) su+=ee; if(i<=6) sf+=yy; }
       f.ZE=Clip(sz/dly.SE12,-4,4); f.UE=Clip(su/dly.SE3,-4,4); f.FE=Clip(sf/dly.SY6,-4,4); f.eur=true;
   }
   if(!f.prim && !f.eur) f.why=aux?"DAILY_ESTIMATES_INVALID":"AUX_BARS_UNAVAILABLE";
   return true;
}

// ------------------------------------------------------------------------------------------------ sizing and scoring
double CeilTick(double x,double q) { return MathCeil((x-1e-12)/q)*q; }
bool Preflight(int side,double ref,double sl,double equity,Cand &c,string &why) {
   ENUM_ORDER_TYPE type=side==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double contract=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_CONTRACT_SIZE),step=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN),vmax=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX),vlim=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_LIMIT);
   if(equity<=0 || contract<=0 || step<=0 || vmin<=0) { why="INVALID_BROKER_PROPERTIES"; return false; }
   c.rb=RISK*equity; double pg=ref+side*0.2*PIP,sg=sl-side*0.2*PIP,loss1;
   if(!OrderCalcProfit(type,InpSymbol,1.0,pg,sg,loss1) || loss1>=0) { why="PROFIT_CALC_FAILED"; return false; }
   double tickLoss=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_VALUE_LOSS); if(tickLoss<=0) tickLoss=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickLoss<=0 || ts<=0 || MathAbs(MathAbs(loss1)-(pg-sg)*side/ts*tickLoss)/MathAbs(loss1)>0.02) { why="TICK_VALUE_MISMATCH"; return false; }
   double lossPerLot=MathAbs(loss1)+InpCommissionRoundTrip;
   double raw=c.rb/lossPerLot,capLev=MAX_LEVERAGE*equity/(contract*pg),capBroker=vmax; if(vlim>0) capBroker=MathMin(capBroker,vlim);
   double lots=MathFloor((MathMin(MathMin(raw,capLev),MathMin(MAX_LOTS_ABS,capBroker))+1e-9)/step)*step;
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   while(lots>=vmin-1e-9) {
       double loss,margin; if(!OrderCalcProfit(type,InpSymbol,lots,pg,sg,loss)) { why="PROFIT_CALC_FAILED"; return false; }
       c.loss=MathAbs(loss)+InpCommissionRoundTrip*lots; c.lev=lots*contract*pg/equity;
       if(!OrderCalcMargin(type,InpSymbol,lots,pg,margin)) { why="MARGIN_CALC_FAILED"; return false; } c.margin=margin;
       if(c.loss<=c.rb+1e-9 && c.lev<=MAX_LEVERAGE+1e-9 && margin<=0.8*freeMargin) break;
       lots-=step;
   }
   lots=NormalizeDouble(lots,8);
   if(lots<vmin-1e-9) { why="LOTS_BELOW_MINIMUM"; return false; }
   c.lots=lots; return true;
}
void Standardize(const Model &m,const double &raw[],double &x[]) {
   for(int j=0;j<NF;j++) x[j]=m.active[j]?Clip((raw[j]-m.mean[j])/m.scale[j],-5,5):0.0;
}
bool Predict(const Model &m,const double &x[],double &pTP,double &pSL,double &pTM,double &u) {
   double zt=m.tp[0],zm=m.tm[0],zu=m.ur[0];
   for(int j=0;j<NF;j++) { zt+=m.tp[j+1]*x[j]; zm+=m.tm[j+1]*x[j]; zu+=m.ur[j+1]*x[j]; }
   zt/=m.temperature; zm/=m.temperature; double mx=MathMax(0,MathMax(zt,zm));
   double e0=MathExp(-mx),e1=MathExp(zt-mx),e2=MathExp(zm-mx),s=e0+e1+e2;
   pSL=e0/s; pTP=e1/s; pTM=e2/s; u=Clip(zu,-1,1);
   return MathIsValidNumber(pSL) && MathIsValidNumber(pTP) && MathIsValidNumber(pTM) && MathIsValidNumber(u);
}
// Build one side's candidate from frozen bar features + current quote. Returns eligibility in c.elig with c.reason.
void Score(int side,const Feat &f,const MqlTick &tick,datetime t,Cand &c) {
   ZeroMemory(c); c.side=side; c.t=t; c.elig=false; c.mode="NONE";
   double w=tick.ask-tick.bid,q=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE),point=SymbolInfoDouble(InpSymbol,SYMBOL_POINT);
   c.w=w; c.ref=side==1?tick.ask:tick.bid;
   if(!f.ok) { c.reason=f.why; return; }
   double rawSL=side==1?f.low6-ATR_BUF*f.a:f.high6+w+ATR_BUF*f.a;
   double Draw=side==1?tick.ask-rawSL:rawSL-tick.bid;
   double floorB=SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_STOPS_LEVEL)*point+w+2*q;
   c.floor_bind=Draw<MIN_STOP+ENTRY_ALLOW;
   c.D=CeilTick(MathMax(MathMax(Draw,MIN_STOP+ENTRY_ALLOW),floorB),q);
   c.sl=NormalizeDouble(c.ref-side*c.D,_Digits); c.tp=NormalizeDouble(c.ref+side*c.D,_Digits);
   if(c.D+ENTRY_ALLOW>MAX_STOP+1e-12) { c.reason="STOP_TOO_WIDE"; return; }
   if(w>MathMin(InpMaximumSpreadPips*PIP,0.08*c.D)+1e-12) { c.reason="SPREAD"; return; }
   bool inb; datetime nxt,lastEnd;
   if(!NewsState(last_clock,t,inb,nxt,lastEnd)) { c.reason="CALENDAR_MISSING"; return; }
   if(inb) { c.reason="NEWS_BLACKOUT"; return; }
   c.exit=MathMin(MathMin(t+MAX_HOLD,day_C),nxt); c.H=((double)((long)c.exit-(long)t))/60.0;
   if(c.H<30-1e-9) { c.reason="HOLD_TOO_SHORT"; return; }
   c.tau=Clip((double)((long)t-(long)day_S)/MathMax(1.0,(double)((long)day_Dn-(long)day_S)),0,1);
   c.N=(lastEnd>0 && t>=lastEnd && t-lastEnd<3600)?1.0:0.0;
   double Z,U,F; Model m;
   if(f.prim && mFactor.valid) { Z=f.Z; U=f.U; F=f.F; m=mFactor; c.mode="FACTOR"; }
   else if(f.eur && mEur.valid) { Z=f.ZE; U=f.UE; F=f.FE; m=mEur; c.mode="EUR_ONLY"; }
   else { c.reason=(f.prim||f.eur)?"MODEL_UNAVAILABLE":f.why; return; }
   double raw[NF]; double s=side;
   raw[0]=s*Z; raw[1]=s*U; raw[2]=s*F; raw[3]=s*f.T; raw[4]=s*Z*f.G; raw[5]=s*F*f.G; raw[6]=f.G; raw[7]=w/c.D; raw[8]=c.D/f.a; raw[9]=c.H/180.0; raw[10]=c.tau; raw[11]=c.N;
   for(int j=0;j<NF;j++) if(!MathIsValidNumber(raw[j])) { c.reason="FEATURE_NOT_FINITE"; return; }
   Standardize(m,raw,c.x);
   if(!Predict(m,c.x,c.pTP,c.pSL,c.pTM,c.u)) { c.reason="MODEL_NUMERIC_FAILURE"; return; }
   double a1; if(!OrderCalcProfit(side==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL,InpSymbol,1.0,c.ref,c.sl,a1)) { c.reason="PROFIT_CALC_FAILED"; return; }
   c.A=MathAbs(a1); c.K=InpCommissionRoundTrip+SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_CONTRACT_SIZE)*InpExitSlippagePips*PIP;
   c.EV=c.A*(c.pTP-c.pSL+c.pTM*c.u)-c.K;
   string why; if(!Preflight(side,c.ref,c.sl,AccountInfoDouble(ACCOUNT_EQUITY),c,why)) { c.reason=why; return; }
   c.q=c.lots*c.EV/c.rb; c.elig=true; c.reason="ELIGIBLE";
}
string CandJSON(const Cand &c) {
   string xs="["; for(int j=0;j<NF;j++) { if(j>0) xs+=","; xs+=Dbl(c.x[j]); } xs+="]";
   return "{\"side\":"+IntegerToString(c.side)+",\"elig\":"+(c.elig?"true":"false")+",\"reason\":\""+Esc(c.reason)+"\",\"mode\":\""+c.mode+"\",\"q\":"+Dbl(c.q)+
       ",\"pTP\":"+Dbl(c.pTP)+",\"pSL\":"+Dbl(c.pSL)+",\"pTM\":"+Dbl(c.pTM)+",\"u\":"+Dbl(c.u)+",\"EV\":"+Dbl(c.EV)+",\"ref\":"+Dbl(c.ref)+",\"sl\":"+Dbl(c.sl)+",\"tp\":"+Dbl(c.tp)+
       ",\"D_pips\":"+Dbl(c.D/PIP)+",\"w_pips\":"+Dbl(c.w/PIP)+",\"H\":"+Dbl(c.H)+",\"tau\":"+Dbl(c.tau)+",\"N\":"+Dbl(c.N)+",\"lots\":"+Dbl(c.lots)+",\"rb\":"+Dbl(c.rb)+
       ",\"loss\":"+Dbl(c.loss)+",\"lev\":"+Dbl(c.lev)+",\"exit\":"+I64(c.exit)+",\"floor_bind\":"+(c.floor_bind?"true":"false")+",\"x\":"+xs+"}";
}
bool StableSpread(datetime now,double d,string &why) {
   datetime from,to; if(!ToServer(now-8,from) || !ToServer(now,to)) { why="TZ"; return false; }
   MqlTick ticks[]; ResetLastError(); int n=CopyTicksRange(InpSymbol,ticks,COPY_TICKS_INFO,(ulong)from*1000,(ulong)to*1000+999);
   if(n<=0) { why="SPREAD_HISTORY_MISSING"; return false; }
   int cursor=-1; double limit=MathMin(InpMaximumSpreadPips*PIP,0.08*d);
   for(int i=4;i>=0;i--) {
       long sample=(long)(to-i)*1000;   // tick stamps are server time
       while(cursor+1<n && ticks[cursor+1].time_msc<=sample) cursor++;
       if(cursor<0 || sample-ticks[cursor].time_msc>2000 || ticks[cursor].bid<=0 || ticks[cursor].ask<ticks[cursor].bid || ticks[cursor].ask-ticks[cursor].bid>limit+1e-12) { why="SPREAD_UNSTABLE"; return false; }
   }
   return true;
}

// ------------------------------------------------------------------------------------------------ broker state
int OwnPositions(ulong &ticket) {
   int count=0; ticket=0;
   for(int i=0;i<PositionsTotal();i++) { ulong k=PositionGetTicket(i);
       if(k>0 && PositionGetString(POSITION_SYMBOL)==InpSymbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic) { ticket=k; count++; } }
   return count;
}
bool SelectDayHistory() { datetime from,to; if(!ToServer(st.day-86400,from) || !ToServer(last_clock+60,to)) return false; return HistorySelect(from,to); }
void Consume(ulong order) {
   if(st.pending_order!=0 && order!=st.pending_order && st.count>=1) { st.kill=2; st.failed=1; Log("INVARIANT_VIOLATION_EXTRA_ENTRY",U64(order)); SaveState(); return; }
   if(st.count==0) { st.count=1; Log("ENTRY_CONFIRMED","","\"order\":"+U64(order)); SaveState(); }
}
bool Reconcile() {
   history_ready=false;
   if(!SelectDayHistory()) { Status("HISTORY_RECONCILIATION_FAILED"); return false; }
   int n=HistoryDealsTotal(); int entries=0; ulong seen=0;
   for(int i=0;i<n;i++) {
       ulong deal=HistoryDealGetTicket(i);
       if(HistoryDealGetString(deal,DEAL_SYMBOL)!=InpSymbol) continue;
       ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
       ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);
       if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
       datetime utc; if(!ToUTC((datetime)HistoryDealGetInteger(deal,DEAL_TIME),utc)) return false;
       if(Day(utc)!=st.day) continue;
       if(entry==DEAL_ENTRY_INOUT) { st.failed=1; st.kill=2; Log("REVERSAL_DEAL_DETECTED",U64(deal)); SaveState(); continue; }
       if(entry!=DEAL_ENTRY_IN) continue;
       ulong order=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
       if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) { st.failed=1; st.kill=2; Log("FOREIGN_ENTRY_ON_DEDICATED_SYMBOL",U64(deal)); SaveState(); continue; }
       if(order!=seen) { seen=order; entries++; }
       Consume(order);
       ulong pid=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
       if(st.position_id==0 && pid!=st.closed_position && st.kill==0) { st.position_id=pid; SaveState(); }
   }
   if(entries>1) { st.failed=1; st.kill=2; Log("INVARIANT_VIOLATION_EXTRA_ENTRY","distinct parent orders "+IntegerToString(entries)); SaveState(); }
   if(st.pending_time>0 && st.count>=1) { st.pending_time=0; SaveState(); }
   if(st.pending_time>0 && st.pending_order!=0 && HistoryOrderSelect(st.pending_order)) {
       ENUM_ORDER_STATE state=(ENUM_ORDER_STATE)HistoryOrderGetInteger(st.pending_order,ORDER_STATE);
       double initial=HistoryOrderGetDouble(st.pending_order,ORDER_VOLUME_INITIAL),remaining=HistoryOrderGetDouble(st.pending_order,ORDER_VOLUME_CURRENT);
       if((state==ORDER_STATE_CANCELED || state==ORDER_STATE_REJECTED || state==ORDER_STATE_EXPIRED) && initial-remaining<1e-8 && last_clock-st.pending_time>=5) {
           Log("ZERO_FILL_ORDER_FINAL",U64(st.pending_order)); st.pending_order=0; st.pending_time=0; SaveState(); }
   }
   if(st.pending_time>0 && last_clock-st.pending_time>=30) {
       if(reason!="ENTRY_PENDING_RECONCILIATION_NO_RESUBMIT") Alert("JB VECTOR V2: entry status uncertain. Check broker; no resubmission.");
       Status("ENTRY_PENDING_RECONCILIATION_NO_RESUBMIT");
   }
   history_ready=true; return true;
}
bool DefinitiveZero(uint rc) {
   return rc==TRADE_RETCODE_REQUOTE || rc==TRADE_RETCODE_REJECT || rc==TRADE_RETCODE_INVALID || rc==TRADE_RETCODE_INVALID_VOLUME || rc==TRADE_RETCODE_INVALID_PRICE ||
       rc==TRADE_RETCODE_INVALID_STOPS || rc==TRADE_RETCODE_TRADE_DISABLED || rc==TRADE_RETCODE_MARKET_CLOSED || rc==TRADE_RETCODE_NO_MONEY || rc==TRADE_RETCODE_PRICE_CHANGED ||
       rc==TRADE_RETCODE_PRICE_OFF || rc==TRADE_RETCODE_TOO_MANY_REQUESTS || rc==TRADE_RETCODE_INVALID_FILL;
}
void CancelEntries() {
   for(int i=OrdersTotal()-1;i>=0;i--) { ulong ticket=OrderGetTicket(i);
       if(ticket==0 || (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagic || OrderGetString(ORDER_SYMBOL)!=InpSymbol || ticket==st.close_order) continue;
       MqlTradeRequest q; MqlTradeResult r; ZeroMemory(q); ZeroMemory(r); q.action=TRADE_ACTION_REMOVE; q.order=ticket; bool sent=OrderSend(q,r); Log("CANCEL_REQUEST",IntegerToString((int)r.retcode)); }
}
void ClosePosition(ulong ticket,string cause) {
   if(!PositionSelectByTicket(ticket)) return;
   if(st.close_time>0) {
       if(st.close_order>0 && HistoryOrderSelect(st.close_order)) { ENUM_ORDER_STATE os=(ENUM_ORDER_STATE)HistoryOrderGetInteger(st.close_order,ORDER_STATE);
           if(os==ORDER_STATE_FILLED || os==ORDER_STATE_CANCELED || os==ORDER_STATE_REJECTED || os==ORDER_STATE_EXPIRED) { st.close_time=0; st.close_order=0; SaveState(); } }
       if(st.close_time>0) { if(last_clock-st.close_time>=10 && last_clock-close_alert>=10) { close_alert=last_clock; Log("CLOSE_STATUS_UNCERTAIN",cause); Alert("JB VECTOR V2: close status uncertain; check broker."); }
           if(last_clock-st.close_time<2) return; st.close_time=0; st.close_order=0; }
   }
   if(!PositionSelectByTicket(ticket)) return;
   MqlTick tick; if(!SymbolInfoTick(InpSymbol,tick)) return;
   MqlTradeRequest q; MqlTradeResult r; ZeroMemory(q); ZeroMemory(r);
   q.action=TRADE_ACTION_DEAL; q.symbol=InpSymbol; q.position=ticket; q.magic=InpMagic; q.volume=PositionGetDouble(POSITION_VOLUME);
   q.type=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?ORDER_TYPE_SELL:ORDER_TYPE_BUY; q.price=q.type==ORDER_TYPE_BUY?tick.ask:tick.bid;
   q.type_filling=ORDER_FILLING_FOK; q.deviation=100; q.comment="JV2 EXIT";
   st.close_time=last_clock; st.close_order=0; SaveState();
   bool sent=OrderSend(q,r); st.close_order=r.order;
   Log("CLOSE_REQUEST",cause,"\"retcode\":"+IntegerToString((int)r.retcode)+",\"order\":"+U64(r.order)+",\"position_id\":"+U64(st.position_id)+",\"price\":"+Dbl(r.price));
   if(DefinitiveZero(r.retcode)) { st.close_time=0; st.close_order=0; }
   SaveState();
}
void TradeClosedReport() {
   if(st.position_id==0 || !HistorySelectByPosition(st.position_id)) return;
   double inVol=0,outVol=0,pnl=0,commission=0,swap=0,exitPrice=0,fill=0; datetime exitUTC=0,inUTC=0; long exitReason=-1; int n=HistoryDealsTotal();
   for(int i=0;i<n;i++) { ulong d=HistoryDealGetTicket(i); long type=HistoryDealGetInteger(d,DEAL_ENTRY);
       if(type==DEAL_ENTRY_IN) { inVol+=HistoryDealGetDouble(d,DEAL_VOLUME); fill=HistoryDealGetDouble(d,DEAL_PRICE); ToUTC((datetime)HistoryDealGetInteger(d,DEAL_TIME),inUTC); }
       if(type==DEAL_ENTRY_OUT || type==DEAL_ENTRY_OUT_BY) { outVol+=HistoryDealGetDouble(d,DEAL_VOLUME); datetime u;
           if(ToUTC((datetime)HistoryDealGetInteger(d,DEAL_TIME),u) && u>=exitUTC) { exitUTC=u; exitReason=HistoryDealGetInteger(d,DEAL_REASON); exitPrice=HistoryDealGetDouble(d,DEAL_PRICE); } }
       pnl+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_FEE);
       commission+=HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE); swap+=HistoryDealGetDouble(d,DEAL_SWAP); }
   if(inVol<=0 || outVol<inVol-1e-8) return;
   double est=(commission==0)?InpCommissionRoundTrip*inVol:0; double net=pnl-est;
   string exitName=EnumToString((ENUM_DEAL_REASON)exitReason);
   string why="TIME_OR_FORCED"; if(exitReason==DEAL_REASON_SL) why="SL"; else if(exitReason==DEAL_REASON_TP) why="TP";
   double grossR=(st.distance>0 && st.side!=0)?st.side*(exitPrice-fill)/st.distance:0;
   Log("TRADE_CLOSED",why,"\"position_id\":"+U64(st.position_id)+",\"side\":"+IntegerToString(st.side)+",\"mode\":\""+st.mode+"\",\"model_id\":\""+st.model_id+"\",\"preferred\":"+IntegerToString(st.preferred)+
       ",\"entry_utc\":"+I64(inUTC)+",\"exit_utc\":"+I64(exitUTC)+",\"fill\":"+Dbl(fill)+",\"exit_price\":"+Dbl(exitPrice)+",\"lots\":"+Dbl(inVol)+",\"pnl\":"+Dbl(pnl)+
       ",\"broker_commission\":"+Dbl(commission)+",\"estimated_commission\":"+Dbl(est)+",\"net_pnl\":"+Dbl(net)+",\"swap\":"+Dbl(swap)+",\"risk_budget\":"+Dbl(st.budget)+
       ",\"R_budget\":"+Dbl(st.budget>0?net/st.budget:0)+",\"R_used\":"+Dbl(st.loss_planned>0?net/st.loss_planned:0)+",\"gross_R\":"+Dbl(grossR)+",\"stop_pips\":"+Dbl(st.distance/PIP)+
       ",\"quality\":"+Dbl(st.quality)+",\"exit_reason\":\""+exitName+"\",\"deal_reason\":"+I64(exitReason)+",\"hold_min\":"+Dbl(((double)((long)exitUTC-(long)inUTC))/60.0)+
       ",\"planned_exit\":"+I64(st.exit_time)+",\"equity_after\":"+Dbl(AccountInfoDouble(ACCOUNT_EQUITY)));
   if(!FileIsExist(prefix+"_trades.csv",FILE_COMMON)) Append(prefix+"_trades.csv","day,side,mode,model_id,preferred,entry_utc,exit_utc,fill,exit_price,lots,stop_pips,risk_budget,pnl_gross,commission_est,pnl_net,R_budget,gross_R,exit,quality,hold_min");
   Append(prefix+"_trades.csv",TimeToString(st.day,TIME_DATE)+","+IntegerToString(st.side)+","+st.mode+","+st.model_id+","+IntegerToString(st.preferred)+","+TimeToString(inUTC,TIME_DATE|TIME_SECONDS)+","+
       TimeToString(exitUTC,TIME_DATE|TIME_SECONDS)+","+DoubleToString(fill,5)+","+DoubleToString(exitPrice,5)+","+DoubleToString(inVol,2)+","+DoubleToString(st.distance/PIP,1)+","+DoubleToString(st.budget,2)+","+
       DoubleToString(pnl,2)+","+DoubleToString(est,2)+","+DoubleToString(net,2)+","+DoubleToString(st.budget>0?net/st.budget:0,3)+","+DoubleToString(grossR,3)+","+why+","+DoubleToString(st.quality,4)+","+
       DoubleToString(((double)((long)exitUTC-(long)inUTC))/60.0,1));
   st.closed_position=st.position_id; st.position_id=0; st.protected_ok=0; st.close_time=0; st.close_order=0; SaveState();
}
void ManagePosition() {
   ulong ticket; int count=OwnPositions(ticket);
   if(count>1) { st.kill=2; st.failed=1; SaveState(); CancelEntries(); Log("MULTIPLE_STRATEGY_POSITIONS"); }
   if(count==0) { if(st.position_id!=0) TradeClosedReport(); return; }
   if(!PositionSelectByTicket(ticket)) return;
   ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   if(st.position_id==0) { st.position_id=pid; SaveState(); }
   if(st.position_id!=pid || st.budget<=0 || st.distance<=0 || st.exit_time<=0) { st.failed=1; st.kill=2; SaveState(); ClosePosition(ticket,"UNRECOVERABLE_POSITION_STATE"); return; }
   if(st.kill!=0 || count>1 || disk_failed) { ClosePosition(ticket,"RISK_OR_OPERATIONAL_SHUTDOWN"); return; }
   double fill=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP),volume=PositionGetDouble(POSITION_VOLUME);
   int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1; double ts=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
   if(st.protected_ok==0) {
       // Keep the ORIGINAL structural SL fixed; correct only the provisional TP to the actual fill distance.
       double desired=st.sl_orig; if(sl>0 && side*(fill-sl)<side*(fill-desired)) desired=sl;   // never widen; tolerate a tighter broker level
       double distance=side*(fill-desired);
       if(distance<=0) { st.failed=1; SaveState(); ClosePosition(ticket,"INVALID_INITIAL_BRACKET"); return; }
       double target=NormalizeDouble(fill+side*distance,_Digits); double loss;
       if(!OrderCalcProfit(side==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL,InpSymbol,volume,fill,desired,loss)) { ClosePosition(ticket,"INITIAL_RISK_CALC_FAILED"); return; }
       double allin=MathAbs(loss)+volume*(InpCommissionRoundTrip+SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_CONTRACT_SIZE)*PIP*InpExitSlippagePips);
       double lev=volume*SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_CONTRACT_SIZE)*fill/st.entry_equity;
       if(allin>st.budget+0.05 || lev>MAX_LEVERAGE+1e-8 || volume>st.planned_lots+1e-8 || distance<MIN_STOP-ts*1.5 || distance>MAX_STOP+ts*1.5) {
           st.failed=1; SaveState(); Log("POST_FILL_RISK_VIOLATION","","\"allin\":"+Dbl(allin)+",\"budget\":"+Dbl(st.budget)+",\"lev\":"+Dbl(lev)+",\"distance_pips\":"+Dbl(distance/PIP));
           ClosePosition(ticket,"POST_FILL_RISK_VIOLATION"); return; }
       if(MathAbs(sl-desired)>ts*.1 || MathAbs(tp-target)>ts*.1) {
           MqlTradeRequest q; MqlTradeResult r; ZeroMemory(q); ZeroMemory(r); q.action=TRADE_ACTION_SLTP; q.symbol=InpSymbol; q.position=ticket;
           q.sl=NormalizeDouble(desired,_Digits); q.tp=target; bool sent=OrderSend(q,r); Log("TP_CORRECTION",IntegerToString((int)r.retcode),"\"sl\":"+Dbl(q.sl)+",\"tp\":"+Dbl(q.tp)); }
       PositionSelectByTicket(ticket); sl=PositionGetDouble(POSITION_SL); tp=PositionGetDouble(POSITION_TP);
       if(sl>0 && tp>0 && MathAbs(sl-desired)<ts*.1 && MathAbs(tp-target)<ts*.1) {
           st.protected_ok=1; st.distance=distance; st.loss_planned=allin; SaveState();
           Log("BRACKET_CONFIRMED","","\"position_id\":"+U64(pid)+",\"fill\":"+Dbl(fill)+",\"sl\":"+Dbl(sl)+",\"tp\":"+Dbl(tp)+",\"lots\":"+Dbl(volume)+",\"budget\":"+Dbl(st.budget)+
               ",\"allin_risk\":"+Dbl(allin)+",\"leverage\":"+Dbl(lev)+",\"side\":"+IntegerToString(side)+",\"stop_pips\":"+Dbl(distance/PIP)+",\"planned_exit\":"+I64(st.exit_time)+
               ",\"entry_slippage_pips\":"+Dbl(side*(fill-st.ref_price)/PIP));
       } else { datetime opened; ToUTC((datetime)PositionGetInteger(POSITION_TIME),opened); if(last_clock-opened>=5) { st.failed=1; SaveState(); ClosePosition(ticket,"PROTECTION_INSTALL_TIMEOUT"); } }
   } else if(sl<=0 || tp<=0 || MathAbs(side*(fill-sl)-st.distance)>ts*.1 || MathAbs(side*(tp-fill)-st.distance)>ts*.1) {
       st.failed=1; SaveState(); ClosePosition(ticket,"PROTECTION_CHANGED_OR_REMOVED"); return; }
   // exits: planned cutoff, later-known news (earlier only), force close, broker close
   datetime old=st.exit_time; Block b[];
   if(NewsKnown(last_clock,b)) { for(int i=0;i<ArraySize(b);i++) { if(b[i].start>last_clock) st.exit_time=MathMin(st.exit_time,b[i].start); else if(last_clock<b[i].end && b[i].start>st.entry_time) st.exit_time=MathMin(st.exit_time,last_clock); } }
   else { st.exit_time=MathMin(st.exit_time,last_clock); Log("CALENDAR_LOST_WHILE_OPEN"); }
   st.exit_time=MathMin(st.exit_time,day_C);
   if(st.exit_time!=old) { SaveState(); Log("EXIT_ADVANCED","","\"from\":"+I64(old)+",\"to\":"+I64(st.exit_time)); }
   if(last_clock>=st.exit_time) ClosePosition(ticket,last_clock>=day_C?"FORCE_CLOSE":"TIME_OR_NEWS_EXIT");
}
void RiskMonitor() {
   double equity=AccountInfoDouble(ACCOUNT_EQUITY); ulong ticket; int own=OwnPositions(ticket); double closeCommission=0;
   if(own>0 && PositionSelectByTicket(ticket)) closeCommission=PositionGetDouble(POSITION_VOLUME)*InpCommissionRoundTrip;
   double nav=(equity-closeCommission)/st.units;
   if(nav<=0 || !MathIsValidNumber(nav)) { st.kill=1; SaveState(); return; }
   if(nav>st.peak) { st.peak=nav; SaveState(); }
   double dd=1-nav/st.peak;
   if(dd>observed_max_dd) { observed_max_dd=dd; Log("NEW_MAX_DRAWDOWN","","\"drawdown\":"+Dbl(dd)); }
   if(last_clock-last_health>=300) { last_health=last_clock; Log("NAV","","\"equity\":"+Dbl(equity)+",\"unit_nav\":"+Dbl(nav)+",\"unit_peak\":"+Dbl(st.peak)+",\"drawdown\":"+Dbl(dd)); }
   int level=(int)MathFloor((dd+1e-12)*100);
   if(level>dd_level) { dd_level=level; Log("DRAWDOWN_ALERT","Level "+IntegerToString(level),"\"drawdown\":"+Dbl(dd)); }
   if(dd>=.05 && st.kill==0) {
       if(tester && InpShadowContinueAfterKill) { if(st.shadow_killed==0) { st.shadow_killed=1; SaveState(); Log("RISK_SHUTDOWN_SHADOW_ONLY","5% drawdown reached; SHADOW run continues (research)","\"drawdown\":"+Dbl(dd)); } }
       else { st.kill=1; SaveState(); CancelEntries(); Log("RISK_SHUTDOWN","5% high-water NAV drawdown","\"drawdown\":"+Dbl(dd)); Alert("JB VECTOR V2: 5% drawdown kill. Formal revalidation required."); } }
}

// ------------------------------------------------------------------------------------------------ day cycle
void DayReport(string cause) {
   string klass="NORMAL_ONE_ENTRY";
   if(st.kill!=0 && st.count==0) klass="KILLED_NO_ENTRY";
   else if(st.count==0) klass=st.opex!=0?"ZERO_ENTRY_OPERATIONAL_EXCEPTION":"ZERO_ENTRY_MANDATE_FAILURE_CONSTRAINTS_UNSATISFIED";
   else if(st.count>1) klass="EXTRA_ENTRY_VIOLATION";
   Log("DAY_COVERAGE",cause,"\"entries\":"+IntegerToString(st.count)+",\"class\":\""+klass+"\",\"failed\":"+IntegerToString(st.failed)+",\"opex\":"+IntegerToString(st.opex)+
       ",\"best_quality\":"+Dbl(st.best_q)+",\"best\":\""+Esc(st.best_desc)+"\",\"reasons\":\""+Esc(st.reason_hist)+"\",\"daily_valid\":"+(dly.valid?"true":"false")+",\"daily_valid_e\":"+(dly.valid_e?"true":"false")+
       ",\"model\":\""+(mFactor.valid?mFactor.id:"NONE")+"\",\"S\":"+I64(day_S)+",\"Dn\":"+I64(day_Dn)+",\"R\":"+I64(day_R)+",\"C\":"+I64(day_C));
}
bool NewDay(datetime day) {
   if(st.day==day) return true;
   if(st.day>0) DayReport("UTC_DAY_END");
   ulong ticket;
   if(OwnPositions(ticket)>0 || st.position_id!=0 || st.pending_time>0 || st.close_time>0) { Status("OLD_DAY_EXPOSURE_OR_UNCERTAIN_REQUEST"); return false; }
   if(st.day>0) { datetime old=st.day; for(datetime missing=old+86400;missing<day;missing+=86400) { MqlDateTime x; TimeToStruct(missing,x); if(x.day_of_week==0 || x.day_of_week==6) continue; st.day=missing; st.count=0; st.opex=1; st.reason_hist="EA_OFFLINE"; DayReport(st.kill!=0?"DISABLED_GAP":"OFFLINE_UNAUDITED_DAY"); } }
   st.day=day; st.count=0; st.failed=0; st.budget=0; st.distance=0; st.exit_time=0; st.side=0; st.preferred=0; st.quality=0; st.best_q=-1e9; st.best_desc=""; st.reason_hist=""; st.opex=0; st.any_ok=0; st.mode=""; st.cand_t=0;
   attempts=0; last_try=0; feat_t=0; mandate_alerted=false; daily_tried=false; daily_reason_logged="";
   if(!DayTimes(day)) { st.opex=1; Log("DAY_TIMES_UNAVAILABLE"); }
   // models are selected once per strategy day and held fixed
   LoadModelFolder("vector_v2_factor_*.json",factorModels); LoadModelFolder("vector_v2_eur_only_*.json",eurModels);
   SelectModel(factorModels,day,mFactor); SelectModel(eurModels,day,mEur);
   st.model_id=mFactor.valid?mFactor.id:"NONE";
   SaveState();
   Log("NEW_DAY",st.kill!=0?"DISABLED":"ACTIVE","\"factor_model\":\""+(mFactor.valid?mFactor.id:"NONE")+"\",\"eur_model\":\""+(mEur.valid?mEur.id:"NONE")+"\",\"S\":"+I64(day_S)+",\"Dn\":"+I64(day_Dn)+",\"R\":"+I64(day_R)+",\"FC\":"+I64(day_FC)+",\"C\":"+I64(day_C));
   return true;
}
void EnsureDaily() {
   if(daily_tried && (dly.valid || dly.valid_e)) return;
   if(daily_tried && last_clock<day_S-60 && (last_clock%60)!=0) return;   // retry once a minute before the window, every second inside it
   bool ok=BuildDaily(st.day); daily_tried=true;
   if(ok || dly.valid_e) Log("DAILY_ESTIMATES",dly.valid?"PRIMARY":"EUR_ONLY_BACKUP","\"valid\":"+(dly.valid?"true":"false")+",\"valid_e\":"+(dly.valid_e?"true":"false")+",\"rows\":"+IntegerToString(dly.rows)+",\"rowsE\":"+IntegerToString(dly.rowsE)+
       ",\"vE\":"+Dbl(dly.vE)+",\"vG\":"+Dbl(dly.vG)+",\"vA\":"+Dbl(dly.vA)+",\"vJ\":"+Dbl(dly.vJ)+",\"beta\":"+Dbl(dly.beta)+",\"alpha\":"+Dbl(dly.alpha)+",\"Se12\":"+Dbl(dly.Se12)+",\"Se3\":"+Dbl(dly.Se3)+",\"Sf6\":"+Dbl(dly.Sf6)+
       ",\"vEo\":"+Dbl(dly.vEo)+",\"alphaE\":"+Dbl(dly.alphaE)+",\"SE12\":"+Dbl(dly.SE12)+",\"SE3\":"+Dbl(dly.SE3)+",\"SY6\":"+Dbl(dly.SY6)+",\"n12\":"+IntegerToString(dly.n12)+",\"reason\":\""+dly.reason+"\"");
   else if(daily_reason_logged!=dly.reason) { daily_reason_logged=dly.reason; Log("DAILY_ESTIMATES_UNAVAILABLE",dly.reason); }
}
void Hist(string r) { if(StringFind(st.reason_hist,r)<0) st.reason_hist+=(st.reason_hist==""?"":"|")+r; }

// One candidate evaluation inside the 30-second slot after boundary t.
void TryEntry(datetime t) {
   if(st.kill!=0 || st.count>=1 || st.pending_time>0 || st.position_id!=0 || disk_failed || !history_ready) return;
   if(PositionsTotal()!=0 || OrdersTotal()!=0 || st.close_time>0) { Status("ONE_POSITION_OR_ORDER_LOCK"); Hist("POSITION_LOCK"); return; }
   if(feat_t!=t) { if(!BuildFeatures(t,feat)) { Status(feat.why); Hist(feat.why); if(st.any_ok==0) st.opex=1; return; } feat_t=t;
       if(!feat.prim && !feat.eur) { Status(feat.why); Hist(feat.why); } else { st.any_ok=1; st.opex=0; }
       Log("FEATURES","","\"t\":"+I64(t)+",\"prim\":"+(feat.prim?"true":"false")+",\"eur\":"+(feat.eur?"true":"false")+",\"Z\":"+Dbl(feat.Z)+",\"U\":"+Dbl(feat.U)+",\"F\":"+Dbl(feat.F)+
           ",\"ZE\":"+Dbl(feat.ZE)+",\"UE\":"+Dbl(feat.UE)+",\"FE\":"+Dbl(feat.FE)+",\"T\":"+Dbl(feat.T)+",\"G\":"+Dbl(feat.G)+",\"atr_pips\":"+Dbl(feat.a/PIP)+",\"low6\":"+Dbl(feat.low6)+",\"high6\":"+Dbl(feat.high6)+",\"why\":\""+feat.why+"\""); }
   if(!mFactor.valid && !mEur.valid) { Status("NO_VALID_MODEL_FOR_DATE"); Hist("NO_MODEL"); if(st.any_ok==0) st.opex=1; return; }
   MqlTick tick; if(!SymbolInfoTick(InpSymbol,tick)) { Status("NO_QUOTE"); Hist("NO_QUOTE"); return; }
   datetime quoteUTC; if(!ToUTC(tick.time,quoteUTC) || last_clock-quoteUTC>2 || quoteUTC>last_clock+1 || tick.bid<=0 || tick.ask<tick.bid) { Status("STALE_OR_INVALID_QUOTE"); Hist("STALE_QUOTE"); return; }
   Score(1,feat,tick,t,cbuy); Score(-1,feat,tick,t,csell);
   int side=0; Cand pick; bool tie=false;
   if(cbuy.elig && csell.elig) {
       if(cbuy.q>csell.q+1e-10) side=1; else if(csell.q>cbuy.q+1e-10) side=-1;
       else { tie=true; if(cbuy.pTP!=csell.pTP) side=cbuy.pTP>csell.pTP?1:-1; else if(cbuy.K/cbuy.A!=csell.K/csell.A) side=cbuy.K/cbuy.A<csell.K/csell.A?1:-1; else side=(feat.c1>=feat.c2)?1:-1; }
   } else if(cbuy.elig) side=1; else if(csell.elig) side=-1;
   double thr=THR0-(THR0-THR1)*Clip((double)((long)t-(long)day_S)/MathMax(1.0,(double)((long)day_Dn-(long)day_S)),0,1);
   bool fallback=t>=day_Dn; string decision="NO_ELIGIBLE_SIDE";
   if(side!=0) { pick=side==1?cbuy:csell;
       if(pick.q>st.best_q) { st.best_q=pick.q; st.best_desc=TimeToString(t,TIME_MINUTES)+" side "+IntegerToString(side)+" q "+DoubleToString(pick.q,4)+" "+pick.mode; }
       decision=fallback?"FALLBACK_SELECTION":(pick.q>=thr?"PREFERRED_ENTRY":"BELOW_THRESHOLD"); }
   else { Hist(cbuy.reason); Hist(csell.reason); }
   if(decision_logged_t!=t) { decision_logged_t=t; Log("DECISION",decision,"\"t\":"+I64(t)+",\"attempt\":"+IntegerToString(attempts)+",\"threshold\":"+Dbl(thr)+",\"fallback\":"+(fallback?"true":"false")+",\"tie\":"+(tie?"true":"false")+
       ",\"side\":"+IntegerToString(side)+",\"spread_pips\":"+Dbl((tick.ask-tick.bid)/PIP)+",\"equity\":"+Dbl(AccountInfoDouble(ACCOUNT_EQUITY))+",\"buy\":"+CandJSON(cbuy)+",\"sell\":"+CandJSON(csell)); }
   if(side==0) { Status("NO_ELIGIBLE_SIDE_"+cbuy.reason); return; }
   if(!fallback && pick.q<thr) { Status("BELOW_THRESHOLD"); Hist("BELOW_THRESHOLD"); return; }
   if(last_clock-last_try<5 && attempts>0) return;
   string why; if(!StableSpread(last_clock,pick.D,why)) { Status(why); Hist(why); return; }
   MqlTick fresh; if(!SymbolInfoTick(InpSymbol,fresh)) return;
   if(!ToUTC(fresh.time,quoteUTC) || last_clock-quoteUTC>2 || fresh.bid<=0 || fresh.ask<fresh.bid) { Status("FINAL_QUOTE_INVALID"); return; }
   double before=pick.ref,after=side==1?fresh.ask:fresh.bid;
   if(MathAbs(after-before)>1e-9 || fresh.ask-fresh.bid>MathMin(InpMaximumSpreadPips*PIP,0.08*pick.D)+1e-12) { Status("QUOTE_CHANGED_RECOMPUTE"); return; }  // next second recomputes both sides
   if(last_clock-t>30) return;
   if(pick.exit-last_clock<MIN_HOLD-30) { Status("HOLD_CAPACITY_LOST"); Hist("HOLD_CAPACITY_LOST"); return; }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   MqlTradeRequest q; MqlTradeResult r; MqlTradeCheckResult check; ZeroMemory(q); ZeroMemory(r); ZeroMemory(check);
   q.action=TRADE_ACTION_DEAL; q.symbol=InpSymbol; q.magic=InpMagic; q.volume=pick.lots; q.type=side==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL; q.price=after;
   q.sl=pick.sl; q.tp=pick.tp; q.deviation=(ulong)MathMax(1,MathFloor(0.2*PIP/SymbolInfoDouble(InpSymbol,SYMBOL_POINT)+1e-9)); q.type_filling=ORDER_FILLING_FOK;
   q.comment="JV2|"+I64(st.day);
   if(!OrderCheck(q,check)) { Status("ORDER_CHECK_"+IntegerToString((int)check.retcode)); Hist("ORDER_CHECK"); return; }
   attempts++; last_try=last_clock;
   st.pending_time=last_clock; st.pending_order=0; st.budget=pick.rb; st.entry_equity=eq; st.distance=pick.D; st.exit_time=pick.exit; st.protected_ok=0; st.planned_lots=pick.lots;
   st.side=side; st.sl_orig=pick.sl; st.entry_time=last_clock; st.preferred=fallback?0:1; st.quality=pick.q; st.mode=pick.mode; st.model_id=pick.mode=="FACTOR"?mFactor.id:mEur.id; st.cand_t=t; st.ref_price=pick.ref; st.loss_planned=pick.loss;
   if(!SaveState()) { st.pending_time=0; Status("DURABLE_INTENT_WRITE_FAILED"); return; }
   if(PositionsTotal()!=0 || OrdersTotal()!=0 || st.count>=1 || st.kill!=0) { st.pending_time=0; SaveState(); return; }
   bool sent=OrderSend(q,r); st.pending_order=r.order;
   Log("ENTRY_REQUEST",IntegerToString((int)r.retcode),"\"t\":"+I64(t)+",\"attempt\":"+IntegerToString(attempts)+",\"order\":"+U64(r.order)+",\"deal\":"+U64(r.deal)+",\"side\":"+IntegerToString(side)+",\"lots\":"+Dbl(pick.lots)+
       ",\"price\":"+Dbl(q.price)+",\"returned_price\":"+Dbl(r.price)+",\"sl\":"+Dbl(q.sl)+",\"tp\":"+Dbl(q.tp)+",\"risk_budget\":"+Dbl(pick.rb)+",\"preflight_loss\":"+Dbl(pick.loss)+",\"lev\":"+Dbl(pick.lev)+
       ",\"margin\":"+Dbl(pick.margin)+",\"equity\":"+Dbl(eq)+",\"quality\":"+Dbl(pick.q)+",\"threshold\":"+Dbl(thr)+",\"preferred\":"+IntegerToString(st.preferred)+",\"mode\":\""+pick.mode+"\"");
   if(DefinitiveZero(r.retcode)) { st.pending_time=0; st.pending_order=0; }
   SaveState(); Reconcile(); ManagePosition();
}
void Process() {
   if(!ready || busy) return; busy=true;
   datetime now; if(!ToUTC(TimeTradeServer(),now)) { Status("UTC_MAPPING_UNAVAILABLE"); ulong tk; if(OwnPositions(tk)>0) ClosePosition(tk,"CLOCK_MAPPING_LOST"); busy=false; return; }
   last_clock=now;
   if(!tester && now-last_news_load>=300) { LoadNews(); last_news_load=now; newsCacheAt=0; }
   bool idle=tester && st.pending_time==0 && st.position_id==0 && st.close_time==0 && PositionsTotal()==0 && OrdersTotal()==0;
   if(!history_ready || now-last_reconcile>=(idle?60:1)) { Reconcile(); last_reconcile=now; }
   ManagePosition(); RiskMonitor();
   if(!NewDay(Day(now))) { busy=false; return; }
   if(st.kill!=0) { CancelEntries(); ManagePosition(); Status(st.kill==1?"RISK_SHUTDOWN_LATCHED":"OPERATIONAL_SHUTDOWN_LATCHED"); busy=false; return; }
   MqlDateTime cal; TimeToStruct(now,cal);
   if(cal.day_of_week==0 || cal.day_of_week==6) { Status("WEEKEND"); busy=false; return; }
   if(!tester && AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_REAL && !InpAllowRealAccount) { Status("REAL_ACCOUNT_NOT_ENABLED"); busy=false; return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) { Status("ALGO_TRADING_DISABLED"); busy=false; return; }
   if(st.count>=1) { Status("DAY_LOCKED_ONE_ENTRY"); busy=false; return; }
   if(disk_failed) { Status("JOURNAL_OR_LOG_FAILURE"); busy=false; return; }
   if(now>=day_S-1800 && now<=day_R+30) EnsureDaily();
   datetime t=Grid(now);
   if(now>day_R+30) {
       if(!mandate_alerted) { mandate_alerted=true;
           string msg=st.opex!=0?"MISSED MANDATORY DAILY TRADE — OPERATIONAL EXCEPTION":"MISSED MANDATORY DAILY TRADE — MANDATE_FAILURE_CONSTRAINTS_UNSATISFIED";
           Log("MANDATE_FAILURE",msg,"\"reasons\":\""+Esc(st.reason_hist)+"\",\"best_quality\":"+Dbl(st.best_q)); Alert("JB VECTOR V2: ",msg," (",st.reason_hist,")");
           if(st.failed==0) { st.failed=1; SaveState(); } }
       Status("MANDATE_FAILED"); busy=false; return;
   }
   if(t<day_S) { Status("AWAITING_WINDOW"); busy=false; return; }
   if(t>day_R) { busy=false; return; }
   if(t!=st.cand_t && feat_t!=t) { attempts=0; last_try=0; }
   if(now-t<=30) TryEntry(t); else Status("AWAITING_NEXT_M5_BOUNDARY");
   busy=false;
}

int OnInit() {
   tester=(bool)MQLInfoInteger(MQL_TESTER);
   if(MQLInfoInteger(MQL_OPTIMIZATION)) { Print("Run single tests; shared files require isolated run IDs."); return INIT_PARAMETERS_INCORRECT; }
   if(!tester && !InpConfirmDedicatedAccount) { Print("Dedicated account confirmation is required."); return INIT_PARAMETERS_INCORRECT; }
   if(_Symbol!=InpSymbol || !SymbolSelect(InpSymbol,true)) { Print("Attach to the exact configured EURUSD symbol."); return INIT_PARAMETERS_INCORRECT; }
   syms[0]=InpSymbol; syms[1]=InpAux1; syms[2]=InpAux2; syms[3]=InpAux3;
   for(int s=1;s<4;s++) if(!SymbolSelect(syms[s],true)) { Print("Auxiliary symbol unavailable: ",syms[s]); return INIT_PARAMETERS_INCORRECT; }
   if(SymbolInfoString(InpSymbol,SYMBOL_CURRENCY_BASE)!="EUR" || SymbolInfoString(InpSymbol,SYMBOL_CURRENCY_PROFIT)!="USD" || AccountInfoString(ACCOUNT_CURRENCY)!="USD") { Print("EUR/USD contract with USD account required."); return INIT_PARAMETERS_INCORRECT; }
   if(InpCommissionRoundTrip<0 || InpExitSlippagePips<0 || InpMaximumSpreadPips<=0 || AccountInfoDouble(ACCOUNT_EQUITY)<=0) return INIT_PARAMETERS_INCORRECT;
   if((SymbolInfoInteger(InpSymbol,SYMBOL_FILLING_MODE)&SYMBOL_FILLING_FOK)==0) { Print("Venue must support FOK."); return INIT_PARAMETERS_INCORRECT; }
   if(InpShadowContinueAfterKill && !tester) { Print("Shadow-after-kill is a tester-only research switch."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaximumSpreadPips!=0.80) Print("WARNING: InpMaximumSpreadPips=",InpMaximumSpreadPips," differs from the 0.80 specification; research sensitivity only.");
   policy_hash=SHA(V2_POLICY);
   root=InpDataFolder+"\\";
   prefix=root+"runs\\"+(tester?"TEST_"+InpTestRunID:U64((ulong)AccountInfoInteger(ACCOUNT_LOGIN))+"_"+InpSymbol+"_"+InpRiskEpisode);
   string lock=root+"locks\\"+U64((ulong)AccountInfoInteger(ACCOUNT_LOGIN))+"_"+InpSymbol+(tester?"_TEST_"+InpTestRunID:"")+".lock";
   lock_handle=FileOpen(lock,FILE_READ|FILE_WRITE|FILE_BIN|FILE_COMMON);
   if(lock_handle==INVALID_HANDLE) { Print("Another EA instance holds the account/symbol lock."); return INIT_FAILED; }
   ZeroMemory(st); st.units=AccountInfoDouble(ACCOUNT_EQUITY); st.peak=1; st.best_q=-1e9;
   if(tester) { FileDelete(prefix+"_state.jvm",FILE_COMMON); FileDelete(prefix+"_events.jsonl",FILE_COMMON); FileDelete(prefix+"_trades.csv",FILE_COMMON); }
   if(!LoadTZ()) { Print("Missing/invalid timezone.csv."); return INIT_FAILED; }
   if(!ToUTC(TimeTradeServer(),last_clock)) { Print("Timezone table does not cover the broker clock."); return INIT_FAILED; }
   if(!LoadState()) { Print("State checksum/format failure; do not delete live state to bypass it."); return INIT_FAILED; }
   if(st.day==0) st.day=Day(last_clock);
   if(!LoadNews()) Print("news_v2.csv unavailable; entries remain blocked (CALENDAR_MISSING) until restored.");
   last_news_load=last_clock;
   if(!LoadModelFolder("vector_v2_factor_*.json",factorModels)) Print("No factor model files found.");
   if(!LoadModelFolder("vector_v2_eur_only_*.json",eurModels)) Print("No EUR-only model files found.");
   if(!SaveState()) return INIT_FAILED;
   ready=true; EventSetTimer(1);
   Log("START",tester?"Strategy Tester":"Terminal","\"commission_per_lot\":"+Dbl(InpCommissionRoundTrip)+",\"exit_slippage_pips\":"+Dbl(InpExitSlippagePips)+",\"max_spread_pips\":"+Dbl(InpMaximumSpreadPips)+
       ",\"factor_models\":"+IntegerToString(ArraySize(factorModels))+",\"eur_models\":"+IntegerToString(ArraySize(eurModels))+",\"news_rows\":"+IntegerToString(ArraySize(news)));
   Reconcile(); ManagePosition(); return INIT_SUCCEEDED;
}
void OnDeinit(const int cause) { if(ready) { DayReport("DETACH_PARTIAL_DAY"); SaveState(); } EventKillTimer(); Comment(""); if(lock_handle!=INVALID_HANDLE) FileClose(lock_handle); }
datetime last_tick_second=0;
void OnTick() { datetime s=TimeTradeServer(); if(tester && s==last_tick_second) return; last_tick_second=s; Process(); }
void OnTimer() { Process(); }
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result) {
   if(!ready || trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0 || !HistoryDealSelect(trans.deal)) return;
   ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   if((type==DEAL_TYPE_BALANCE || type==DEAL_TYPE_CREDIT) && trans.deal>st.last_cash) {
       // unitise cash flows at pre-flow NAV so deposits/withdrawals do not move the drawdown measure
       double flow=HistoryDealGetDouble(trans.deal,DEAL_PROFIT),equity=AccountInfoDouble(ACCOUNT_EQUITY),pre=equity-flow;
       if(pre>0 && st.units>0) { double nav=pre/st.units; st.units=equity/nav; }
       st.last_cash=trans.deal; SaveState(); Log("CASH_FLOW","","\"flow\":"+Dbl(flow)+",\"units\":"+Dbl(st.units));
   }
}
