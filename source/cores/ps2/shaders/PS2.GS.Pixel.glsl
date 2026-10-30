// Shared integer GS pixel/texture pipeline. The including shader provides
// ram[], draws[], and a private drawIndex for the current invocation.
#define p draws[drawIndex].p

const uint blocks[32] = uint[32](0,1,4,5,16,17,20,21,
  2,3,6,7,18,19,22,23,8,9,12,13,24,25,28,29,10,11,14,15,26,27,30,31);
uint address(uint bp,uint bw,uint x,uint y,bool depth) {
  uint page=(x>>6)+(y>>5)*bw;
  uint block=blocks[((y>>3)&3)*8+((x>>3)&7)] ^ (depth?24u:0u);
  uint word=(x&1)+((y&1)<<1)+(((x>>1)&3)<<2)+(((y>>1)&3)<<4);
  return ((bp<<6)+(page<<11)+(block<<6)+word)&0xfffff;
}
ivec3 selectColor(uint which,ivec3 src,ivec3 dst) {
  return which==0 ? src : (which==1 ? dst : ivec3(0));
}
int clampCoordinate(int c,uint size,uint mode,uint low,uint high) {
  if(mode==0) return c&int(size-1);
  if(mode==1) return c<0 ? 0 : (c>=int(size) ? int(size)-1 : c);
  if(mode==2) return c<int(low) ? int(low) : (c>int(high) ? int(high) : c);
  return (c&int(low))|int(high);
}
uint rawTexel(uint bp,uint bw,uint x,uint y,uint psm) {
  if(psm==2 || psm==10 || psm==0x32 || psm==0x3a) {
    uint page=(x>>6)+(y>>6)*bw;
    uint block=(psm==10 || psm==0x3a) ? gsBlock16S[((y>>3)&7)*4+((x>>4)&3)] :
      gsBlock16[((y>>3)&7)*4+((x>>4)&3)];
    if(psm>=0x30) block^=24;
    uint a=((bp<<7)+(page<<12)+(block<<7)+gsColumn16[(y&7)*16+(x&15)])&0x1fffff;
    return (ram[a>>1]>>((a&1)*16))&0xffff;
  }
  if(psm==0x13) {
    uint page=(x>>7)+(y>>6)*((bw+1)>>1);
    uint block=blocks[((y>>4)&3)*8+((x>>4)&7)];
    uint a=((bp<<8)+(page<<13)+(block<<8)+gsColumn8[(y&15)*16+(x&15)])&0x3fffff;
    return (ram[a>>2]>>((a&3)*8))&255;
  }
  if(psm==0x14) {
    uint page=(x>>7)+(y>>7)*((bw+1)>>1);
    uint block=gsBlock16[((y>>4)&7)*4+((x>>5)&3)];
    uint a=((bp<<9)+(page<<14)+(block<<9)+gsColumn4[(y&15)*32+(x&31)])&0x7fffff;
    return (ram[a>>3]>>((a&7)*4))&15;
  }
  uint t=ram[address(bp,bw,x,y,psm==0x30 || psm==0x31)];
  if(psm==0x1b) return t>>24;
  if(psm==0x24) return (t>>24)&15;
  if(psm==0x2c) return t>>28;
  return t;
}
uint clutWord(uint index) { return (p[128+(index>>1)]>>((index&1)*16))&0xffff; }
uint expand16(uint t) {
  uint a=(t&0x8000)!=0 ? p[51] : ((p[46]!=0 && (t&0x7fff)==0) ? 0 : p[45]);
  return ((t&31)<<3)|(((t>>5)&31)<<11)|(((t>>10)&31)<<19)|(a<<24);
}
uvec4 readTexel(int u,int v,uint level) {
  uint w=max(1u,p[35]>>level),h=max(1u,p[36]>>level);
  uint minu=p[37]==3 ? p[39] : p[39]>>level;
  uint maxu=p[37]==3 ? p[40] : p[40]>>level;
  uint minv=p[38]==3 ? p[41] : p[41]>>level;
  uint maxv=p[38]==3 ? p[42] : p[42]>>level;
  u=clampCoordinate(u,w,p[37],minu,maxu);
  v=clampCoordinate(v,h,p[38],minv,maxv);
  uint psm=p[34];
  uint t=rawTexel(p[64+level],p[71+level],uint(u),uint(v),psm);
  if(psm==1 || psm==0x31) {
    uint a=p[46]!=0 && (t&0xffffff)==0 ? 0 : p[45];
    t=(t&0xffffff)|(a<<24);
  } else if(psm==2 || psm==10 || psm==0x32 || psm==0x3a) {
    t=expand16(t);
  } else if(psm==0x13 || psm==0x14 || psm==0x1b || psm==0x24 || psm==0x2c) {
    uint index=t+p[50];
    if(p[49]!=0) { index&=255; t=clutWord(index)|(clutWord(index+256)<<16); }
    else t=expand16(clutWord(index&511));
  }
  return uvec4(t&255,(t>>8)&255,(t>>16)&255,t>>24);
}
uvec4 sampleLevel(int u,int v,uint level,bool linear) {
  u>>=level; v>>=level;
  if(!linear) return readTexel(u>>4,v>>4,level);
  u-=8; v-=8;
  uint fu=uint(u&15),fv=uint(v&15);
  int u0=u>>4,v0=v>>4;
  uvec4 top=readTexel(u0,v0,level)*(16-fu)+readTexel(u0+1,v0,level)*fu;
  uvec4 bottom=readTexel(u0,v0+1,level)*(16-fu)+readTexel(u0+1,v0+1,level)*fu;
  return (top*(16-fv)+bottom*fv)>>8;
}
bool depthPass(ivec2 xy,uint sourceZ) {
  if(p[12]==1) return true;
  if(p[12]==0) return false;
  uint za=address(p[4],p[1],uint(xy.x),uint(xy.y),true);
  uint mask=p[5]==0x31 ? 0xffffff : 0xffffffff;
  uint z=min(sourceZ,mask),old=ram[za]&mask;
  return !((p[12]==2 && z<old)||(p[12]==3 && z<=old));
}
void shadePixel(ivec2 xy,uint sourceZ,ivec3 c,int a,int f,int u,int v,uint mip) {
  uint x=uint(xy.x),y=uint(xy.y);
  if(!depthPass(xy,sourceZ)) return;
  if(p[47]!=0) {
    uint l0=mip&7,l1=(mip>>3)&7,weight=(mip>>6)&31;
    bool linear=(mip&2048)!=0;
    uvec4 tex=sampleLevel(u,v,l0,linear);
    if(weight!=0) tex=(tex*(16-weight)+sampleLevel(u,v,l1,linear)*weight)>>4;
    ivec4 t=ivec4(tex);
    switch(p[43]) {
      case 0: c=(c*t.rgb)>>7; if(p[44]!=0) a=(a*t.a)>>7; break;
      case 1: c=t.rgb; if(p[44]!=0) a=t.a; break;
      default:
        c=((c*t.rgb)>>7)+a;
        if(p[44]!=0) a=p[43]==2 ? t.a+a : t.a;
        break;
    }
    c=min(c,ivec3(255)); a=min(a,255);
  }
  if(p[22]!=0) c=(f*c+(255-f)*ivec3(p[23],p[24],p[25]))>>8;
  bool writeFB=true,writeZ=p[6]==0,writeAlpha=true;
  bool pass=false;
  switch(p[7]) {
    case 0: break;
    case 1: pass=true; break;
    case 2: pass=a<int(p[8]); break;
    case 3: pass=a<=int(p[8]); break;
    case 4: pass=a==int(p[8]); break;
    case 5: pass=a>=int(p[8]); break;
    case 6: pass=a>int(p[8]); break;
    default: pass=a!=int(p[8]); break;
  }
  if(!pass) {
    switch(p[9]) {
      case 0: return;
      case 1: writeZ=false; break;
      case 2: writeFB=false; break;
      default: writeZ=false; writeAlpha=false; break;
    }
  }
  uint za=address(p[4],p[1],x,y,true);
  uint zmask=p[5]==0x31 ? 0xffffff : 0xffffffff;
  uint z=min(sourceZ,zmask);
  uint fa=address(p[0],p[1],x,y,false);
  uint raw=ram[fa];
  uint dst=p[2]==1 ? (raw&0xffffff)|0x80000000 : raw;
  if(p[10]!=0 && ((dst>>31)!=p[11])) return;
  if(p[21]!=0 && (p[18]==0 || a>=128)) {
    ivec3 d=ivec3(dst&255,(dst>>8)&255,(dst>>16)&255);
    ivec3 ca=selectColor(p[13],c,d),cb=selectColor(p[14],c,d),cd=selectColor(p[16],c,d);
    int cc=p[15]==0 ? a : (p[15]==1 ? int(dst>>24) : int(p[17]));
    c=(((ca-cb)*cc)>>7)+cd;
  }
  c=p[20]!=0 ? clamp(c,ivec3(0),ivec3(255)) : c&ivec3(255);
  if(p[19]!=0) a|=128;
  if(writeFB) {
    uint color=uint(c.r)|(uint(c.g)<<8)|(uint(c.b)<<16)|(uint(a&255)<<24);
    uint mask=p[3]|(writeAlpha?0u:0xff000000u);
    color=(color&~mask)|(dst&mask);
    ram[fa]=p[2]==1 ? (raw&0xff000000)|(color&0xffffff) : color;
  }
  if(writeZ && (writeFB || p[9]==2)) ram[za]=(ram[za]&~zmask)|(z&zmask);
}
