unit PSP.GE.Types;

// Graphics engine command numbers and the register file the command
// processor keeps: the last word of every command, the matrices (as the
// 24-bit words written, like the hardware returns them) and the addresses
// derived from BASE/OFFSET.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

const
  GE_NOP = $00;
  GE_VADDR = $01;
  GE_IADDR = $02;
  GE_PRIM = $04;
  GE_BEZIER = $05;
  GE_SPLINE = $06;
  GE_BBOX = $07;
  GE_JUMP = $08;
  GE_BJUMP = $09;
  GE_CALL = $0A;
  GE_RET = $0B;
  GE_END = $0C;
  GE_SIGNAL = $0E;
  GE_FINISH = $0F;
  GE_BASE = $10;
  GE_VTYPE = $12;
  GE_OFFSETADDR = $13;
  GE_ORIGIN = $14;
  GE_REGION1 = $15;
  GE_REGION2 = $16;
  GE_LIGHTINGENABLE = $17;
  GE_LIGHTENABLE0 = $18;
  GE_CLIPENABLE = $1C;
  GE_CULLENABLE = $1D;
  GE_TEXENABLE = $1E;
  GE_FOGENABLE = $1F;
  GE_DITHERENABLE = $20;
  GE_BLENDENABLE = $21;
  GE_ALPHATESTENABLE = $22;
  GE_ZTESTENABLE = $23;
  GE_STENCILTESTENABLE = $24;
  GE_ANTIALIASENABLE = $25;
  GE_PATCHCULLENABLE = $26;
  GE_COLORTESTENABLE = $27;
  GE_LOGICOPENABLE = $28;
  GE_BONEMATRIXNUMBER = $2A;
  GE_BONEMATRIXDATA = $2B;
  GE_MORPHWEIGHT0 = $2C;
  GE_PATCHDIVISION = $36;
  GE_PATCHPRIMITIVE = $37;
  GE_PATCHFACING = $38;
  GE_WORLDMATRIXNUMBER = $3A;
  GE_WORLDMATRIXDATA = $3B;
  GE_VIEWMATRIXNUMBER = $3C;
  GE_VIEWMATRIXDATA = $3D;
  GE_PROJMATRIXNUMBER = $3E;
  GE_PROJMATRIXDATA = $3F;
  GE_TGENMATRIXNUMBER = $40;
  GE_TGENMATRIXDATA = $41;
  GE_VIEWPORTXSCALE = $42;
  GE_VIEWPORTYSCALE = $43;
  GE_VIEWPORTZSCALE = $44;
  GE_VIEWPORTXCENTER = $45;
  GE_VIEWPORTYCENTER = $46;
  GE_VIEWPORTZCENTER = $47;
  GE_TEXSCALEU = $48;
  GE_TEXSCALEV = $49;
  GE_TEXOFFSETU = $4A;
  GE_TEXOFFSETV = $4B;
  GE_OFFSETX = $4C;
  GE_OFFSETY = $4D;
  GE_SHADEMODE = $50;
  GE_REVERSENORMAL = $51;
  GE_MATERIALUPDATE = $53;
  GE_MATERIALEMISSIVE = $54;
  GE_MATERIALAMBIENT = $55;
  GE_MATERIALDIFFUSE = $56;
  GE_MATERIALSPECULAR = $57;
  GE_MATERIALALPHA = $58;
  GE_MATERIALSPECULARCOEF = $5B;
  GE_AMBIENTCOLOR = $5C;
  GE_AMBIENTALPHA = $5D;
  GE_LIGHTMODE = $5E;
  GE_LIGHTTYPE0 = $5F;
  GE_LX0 = $63;
  GE_LDX0 = $6F;
  GE_LKA0 = $7B;
  GE_LKS0 = $87;
  GE_LKO0 = $8B;
  GE_LAC0 = $8F;
  GE_CULL = $9B;
  GE_FRAMEBUFPTR = $9C;
  GE_FRAMEBUFWIDTH = $9D;
  GE_ZBUFPTR = $9E;
  GE_ZBUFWIDTH = $9F;
  GE_TEXADDR0 = $A0;
  GE_TEXBUFWIDTH0 = $A8;
  GE_CLUTADDR = $B0;
  GE_CLUTADDRUPPER = $B1;
  GE_TRANSFERSRC = $B2;
  GE_TRANSFERSRCW = $B3;
  GE_TRANSFERDST = $B4;
  GE_TRANSFERDSTW = $B5;
  GE_TEXSIZE0 = $B8;
  GE_TEXMAPMODE = $C0;
  GE_TEXSHADELS = $C1;
  GE_TEXMODE = $C2;
  GE_TEXFORMAT = $C3;
  GE_LOADCLUT = $C4;
  GE_CLUTFORMAT = $C5;
  GE_TEXFILTER = $C6;
  GE_TEXWRAP = $C7;
  GE_TEXLEVEL = $C8;
  GE_TEXFUNC = $C9;
  GE_TEXENVCOLOR = $CA;
  GE_TEXFLUSH = $CB;
  GE_TEXSYNC = $CC;
  GE_FOG1 = $CD;
  GE_FOG2 = $CE;
  GE_FOGCOLOR = $CF;
  GE_TEXLODSLOPE = $D0;
  GE_FRAMEBUFPIXFORMAT = $D2;
  GE_CLEARMODE = $D3;
  GE_SCISSOR1 = $D4;
  GE_SCISSOR2 = $D5;
  GE_MINZ = $D6;
  GE_MAXZ = $D7;
  GE_COLORTEST = $D8;
  GE_COLORREF = $D9;
  GE_COLORTESTMASK = $DA;
  GE_ALPHATEST = $DB;
  GE_STENCILTEST = $DC;
  GE_STENCILOP = $DD;
  GE_ZTEST = $DE;
  GE_BLENDMODE = $DF;
  GE_BLENDFIXEDA = $E0;
  GE_BLENDFIXEDB = $E1;
  GE_DITH0 = $E2;
  GE_LOGICOP = $E6;
  GE_ZWRITEDISABLE = $E7;
  GE_MASKRGB = $E8;
  GE_MASKALPHA = $E9;
  GE_TRANSFERSTART = $EA;
  GE_TRANSFERSRCPOS = $EB;
  GE_TRANSFERDSTPOS = $EC;
  GE_TRANSFERSIZE = $EE;

  // Signal behaviours (SIGNAL bits 16-23).
  GE_SIG_SUSPEND = $01;
  GE_SIG_CONTINUE = $02;
  GE_SIG_PAUSE = $03;
  GE_SIG_SYNC = $08;
  GE_SIG_JUMP = $10;
  GE_SIG_CALL = $11;
  GE_SIG_RET = $12;
  GE_SIG_RJUMP = $13;
  GE_SIG_RCALL = $14;
  GE_SIG_OJUMP = $15;
  GE_SIG_OCALL = $16;
  GE_SIG_RTBP0 = $20;
  GE_SIG_OTBP0 = $28;
  GE_SIG_RCBP = $30;
  GE_SIG_OCBP = $38;
  GE_SIG_BREAK1 = $F0;
  GE_SIG_BREAK2 = $FF;

type
  TGECmds = array[0..255] of Cardinal;
  PGECmds = ^TGECmds;
  TGEMat12 = array[0..11] of Cardinal;
  PGEMat12 = ^TGEMat12;
  TGEMat16 = array[0..15] of Cardinal;
  PGEMat16 = ^TGEMat16;

  TPSPGERegs = record
    Cmd: TGECmds;
    Bone: array[0..95] of Cardinal;
    World, View, TGen: TGEMat12;
    Proj: TGEMat16;
    BoneNum, WorldNum, ViewNum, ProjNum, TGenNum: Cardinal;
    VAddr, IAddr, Offset: Cardinal;
  end;

// A 24-bit GE float (the top bits of an IEEE single).
function GEFloat(V: Cardinal): Single; inline;

implementation

function GEFloat(V: Cardinal): Single;
begin
  // The GE has no NaN: the top exponent is a signed infinity.
  var Bits: Cardinal := V shl 8;
  if (Bits and $7F800000) = $7F800000 then
    Bits := Bits and $FF800000;
  Result := PSingle(@Bits)^;
end;

end.
