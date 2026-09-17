#include "Vvrtop.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <map>
// clk_w = core clock 40 MHz with ce_w at the core pixel rate; clk_r = 48 MHz.
// Approximated as: 5 clk_r per 4 clk_w (48/40 = 1.2), ce_w every 5 clk_w (8 MHz).
int main(int argc,char**argv){
  Verilated::commandArgs(argc,argv);
  bool m1 = getenv("M1")!=nullptr;
  Vvrtop* t=new Vvrtop; t->mode1=m1; t->hq2x=1; t->reset_w=1;
  int HT = m1?384:512, VT=264;
  int hcw=0, vcw=0, wdiv=0;
  long acc=0; int de_run=0; std::map<int,int> w;
  for(long i=0;i<60000000L;i++){
    // clk_r domain (48 MHz) every iteration
    // clk_w domain (40 MHz) advanced on 5-of-6 iterations to approximate 40/48
    acc += 40;
    bool wtick = false;
    if (acc >= 48) { acc -= 48; wtick = true; }
    if (wtick) {
      t->reset_w = (i < 1000);
      int ce = (wdiv==0);
      t->ce_w = ce;
      if (ce) { t->hcount_w=hcw; t->vcount_w=vcw; t->rgb_w=((hcw&0xFF)<<16)|((vcw&0xFF)<<8)|0x40;
                if(++hcw>=HT){hcw=0; if(++vcw>=VT) vcw=0;} }
      wdiv = (wdiv+1) % (m1?8:6);
      t->clk_w=0; t->eval(); t->clk_w=1; t->eval();
    }
    t->clk_r=0; t->eval(); t->clk_r=1; t->eval();
    if(t->CE_PIXEL){ if(t->VGA_DE) de_run++; else if(de_run){ w[de_run]++; de_run=0; } }
  }
  printf("mode=%s via video_retime -> video_mixer, HQ2X\n", m1?"M1(256)":"M0(384)");
  int n=0; for(auto it=w.rbegin(); it!=w.rend() && n<6; ++it,++n) printf("   %5d : %d\n", it->first, it->second);
  return 0;
}
