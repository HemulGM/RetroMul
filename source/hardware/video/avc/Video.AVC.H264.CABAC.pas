unit Video.AVC.H264.CABAC;

// Scalar CABAC arithmetic decoder; FFmpeg n7.1 cabac.c/h264_cabac.c.
// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.

interface

uses Video.AVC.Bitstream, Video.AVC.H264.DSP;

type
  TH264CABAC = record
  private
    FBits:^TBitReader;
    FRange,FOffset: Integer;
    FState: array[0..1023] of Integer;
    procedure Normalize; inline;
    procedure Refill;
    procedure RefillNormalized;
    function Coefficients(Category,MaxCoeff,CBFContext:Integer; var Block:array of Integer):Integer;
  public
    procedure Init(var Bits:TBitReader; QP,InitID:Integer; Intra:Boolean);
    function Decode(Context:Integer):Integer;inline;
    function Bypass:Integer; inline;
    function Terminate:Boolean;
    function Residual(Category,MaxCoeff,CBFContext:Integer; out Block:TCoeffBlock):Integer;
    function Residual8(out Block:TCoeffBlock8):Integer;
    function MotionDifference(Base,NeighborSum:Integer):Integer;
  end;

implementation

uses System.SysUtils, System.Math, Video.AVC.Types, Video.AVC.H264.Tables;

procedure TH264CABAC.Init(var Bits:TBitReader; QP,InitID:Integer; Intra:Boolean);
var I,M,N,Pre:Integer;
begin
  if (QP<0) or (QP>51) or (InitID<0) or (InitID>2) then raise EPlayerFormat.Create('Invalid CABAC initialization');
  FBits:=@Bits;FRange:=510;
  // FFmpeg's 16-bit low register carries a sentinel instead of fetching a
  // new input bit for every arithmetic bin. Fetches remain bounds checked.
  FOffset:=(Integer(Bits.ReadBits(16)) shl 10)+512;
  if FOffset>=FRange shl 17 then raise EPlayerFormat.Create('Invalid CABAC initial offset');
  for I:=0 to 1023 do
  begin
    if Intra then begin M:=cabac_context_init_I[I][0]; N:=cabac_context_init_I[I][1] end
    else begin M:=cabac_context_init_PB[InitID][I][0]; N:=cabac_context_init_PB[InitID][I][1] end;
    Pre:=2*(ASR(M*QP,4)+N)-127;
    if Pre<0 then Pre:=not Pre;
    if Pre>124 then Pre:=124+(Pre and 1);
    FState[I]:=Pre;
  end;
end;

procedure TH264CABAC.Refill;
begin
  Inc(FOffset,(Integer(FBits^.ReadBits(16)) shl 1)-65535);
end;

procedure TH264CABAC.RefillNormalized;
var Shift,V:Integer;X:Cardinal;
begin
  X:=Cardinal(FOffset) xor Cardinal(FOffset-1);
  Shift:=7-ff_h264_cabac_tables[X shr 15];
  V:=(Integer(FBits^.ReadBits(16)) shl 1)-65535;
  Inc(FOffset,V shl Shift);
end;

procedure TH264CABAC.Normalize;
var Shift:Integer;
begin
  Shift:=ff_h264_cabac_tables[FRange];
  FRange:=FRange shl Shift;FOffset:=FOffset shl Shift;
  if FOffset and $FFFF=0 then RefillNormalized;
end;

function TH264CABAC.Decode(Context:Integer):Integer;
var State,LPS:Integer;
begin
  if (Context<0) or (Context>1023) then raise EPlayerError.Create('CABAC context out of bounds');
  State:=FState[Context];
  LPS:=ff_h264_cabac_tables[512+2*(FRange and $C0)+State] and 255;
  Dec(FRange,LPS); Result:=State and 1;
  if FOffset>=FRange shl 17 then
  begin
    Dec(FOffset,FRange shl 17); FRange:=LPS; Result:=1-Result;
    FState[Context]:=ff_h264_cabac_tables[1024+127-State];
  end
  else FState[Context]:=ff_h264_cabac_tables[1024+128+State];
  Normalize;
end;

function TH264CABAC.Bypass:Integer;
begin
  FOffset:=FOffset shl 1;
  if FOffset and $FFFF=0 then Refill;
  Result:=Ord(FOffset>=FRange shl 17);
  if Result<>0 then Dec(FOffset,FRange shl 17);
end;

function TH264CABAC.Terminate:Boolean;
begin
  Dec(FRange,2); Result:=FOffset>=FRange shl 17;
  if not Result then Normalize;
end;

function TH264CABAC.MotionDifference(Base,NeighborSum:Integer):Integer;
var Context,K:Integer;
begin
  Result:=0;
  if Decode(Base+Ord(NeighborSum>2)+Ord(NeighborSum>32))=0 then Exit;
  Result:=1; Context:=Base+3;
  while (Result<9) and (Decode(Context)<>0) do
  begin if Result<4 then Inc(Context); Inc(Result) end;
  if Result>=9 then
  begin
    K:=3;
    while Bypass<>0 do
    begin
      Inc(Result,1 shl K); Inc(K);
      if K>15 then raise EPlayerFormat.Create('CABAC motion difference overflow');
    end;
    Dec(K);
    while K>=0 do begin Inc(Result,Bypass shl K); Dec(K) end;
  end;
  if Bypass<>0 then Result:=-Result;
end;

function TH264CABAC.Residual(Category,MaxCoeff,CBFContext:Integer; out Block:TCoeffBlock):Integer;
begin Result:=Coefficients(Category,MaxCoeff,CBFContext,Block) end;

function TH264CABAC.Residual8(out Block:TCoeffBlock8):Integer;
begin Result:=Coefficients(5,64,-1,Block) end;

function TH264CABAC.Coefficients(Category,MaxCoeff,CBFContext:Integer; var Block:array of Integer):Integer;
const
  Significant:array[0..5] of Integer=(105,120,134,149,152,402);
  Last:array[0..5] of Integer=(166,181,195,210,213,417);
  AbsBase:array[0..5] of Integer=(227,237,247,257,266,426);
  Level1:array[0..7] of Integer=(1,2,3,4,0,0,0,0);
  LevelGT1:array[0..7] of Integer=(5,5,5,5,6,7,8,9);
  Next1:array[0..7] of Integer=(1,2,3,3,4,5,6,7);
  NextGT1:array[0..7] of Integer=(4,4,4,4,5,6,7,7);
  Scan:array[0..15] of Integer=(0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15);
var Index:array[0..63] of Integer; I,Node,Value,K,Position,SigOffset,LastOffset:Integer; FoundLast:Boolean;
begin
  for I:=0 to High(Block) do Block[I]:=0;
  Result:=0;
  // For 4:2:0 luma8x8, coded_block_pattern implies the coded block flag.
  if CBFContext>=0 then if Decode(CBFContext)=0 then Exit;
  FoundLast:=False;
  for I:=0 to MaxCoeff-2 do
  begin
    SigOffset:=I; LastOffset:=I;
    if Category=5 then
    begin
      SigOffset:=significant_coeff_flag_offset_8x8[0][I];
      LastOffset:=ff_h264_cabac_tables[1280+I];
    end;
    if Decode(Significant[Category]+SigOffset)<>0 then
    begin
      Index[Result]:=I; Inc(Result);
      if Decode(Last[Category]+LastOffset)<>0 then begin FoundLast:=True; Break end;
    end;
  end;
  if not FoundLast then begin Index[Result]:=MaxCoeff-1; Inc(Result) end;
  Node:=0;
  for I:=Result-1 downto 0 do
  begin
    Value:=1;
    if Decode(AbsBase[Category]+Level1[Node])=0 then Node:=Next1[Node]
    else
    begin
      Value:=2; Position:=AbsBase[Category]+LevelGT1[Node]; Node:=NextGT1[Node];
      while (Value<15) and (Decode(Position)<>0) do Inc(Value);
      if Value=15 then
      begin
        K:=0;
        while Bypass<>0 do begin Inc(K); if K>14 then raise EPlayerFormat.Create('CABAC coefficient overflow') end;
        Value:=1;
        while K>0 do begin Value:=Value*2+Bypass; Dec(K) end;
        Inc(Value,14);
      end;
    end;
    if Bypass<>0 then Value:=-Value;
    Position:=Index[I];
    if Abs(Value)>32767 then raise EPlayerFormat.Create('CABAC coefficient exceeds 8-bit decoder range');
    if MaxCoeff=64 then Block[Scan8[Position]]:=Value
    else if MaxCoeff=4 then Block[Position]:=Value
    else if MaxCoeff=15 then Block[Scan[Position+1]]:=Value else Block[Scan[Position]]:=Value;
  end;
end;

end.
