unit Video.AVC.H264.Syntax;

// H.264 syntax adapted with FFmpeg n7.1 h264_ps.c as reference.
// LGPL-2.1-or-later; see NOTICE.txt and reference originals.

interface

uses Core.Bitstream, System.SysUtils, Video.AVC.Types, Video.AVC.Bitstream;

type
  TH264Scaling = record
    Lists4:array[0..5,0..15] of Byte;
    Lists8:array[0..1,0..63] of Byte;
  end;
  TH264SPS = record
    Valid: Boolean;
    ID, Profile, Level, LogFrameNum, POCType, LogPOC, MaxRefs: Integer;
    MBWidth, MBHeight, Width, Height, CropLeft, CropTop: Integer;
    MaxReorder, OffsetNonRef, OffsetTopBottom, POCCycleCount: Integer;
    POCCycle: array[0..254] of Integer;
    FrameOnly, DeltaPOCAlwaysZero, FullRange, Direct8Inference: Boolean;
    Matrix: TColorMatrix;
    ScalingPresent:Boolean;
    Scaling:TH264Scaling;
  end;
  TH264PPS = record
    Valid, CABAC, BottomPOC, WeightedPred, DeblockPresent, ConstrainedIntra, Redundant, Transform8x8Mode: Boolean;
    ID, SPSID, RefCount0, RefCount1, WeightedBiPred, InitQP, ChromaQP, ChromaQP2: Integer;
    Scaling:TH264Scaling;
  end;

procedure ParseSPS(const RBSP: TBytes; out SPS: TH264SPS);
procedure ParsePPS(const RBSP: TBytes; out PPS: TH264PPS); overload;
procedure ParsePPS(const RBSP: TBytes; out PPS: TH264PPS; const Sequences:array of TH264SPS); overload;
function ParseAVCC(const Config: TBytes; out NALLength: Integer): TArray<TBytes>;
function SplitAVCPacket(const Data: TBytes; NALLength: Integer): TArray<TBytes>;

implementation

uses System.Generics.Collections, Video.AVC.H264.Tables, Video.AVC.H264.DSP;

procedure ScalingMatrices(var Bits:TBitReader; var Scaling:TH264Scaling;
  const Sequence:TH264Scaling; UseSequence,Has8:Boolean);
  procedure List(var Values:array of Byte; const Defaults,Fallback:array of Byte; const Scan:array of Integer);
  var I,Last,Next,Delta:Integer;
  begin
    if not Bits.ReadBit then
    begin for I:=0 to High(Values) do Values[I]:=Fallback[I]; Exit end;
    Last:=8; Next:=8;
    for I:=0 to High(Values) do
    begin
      if Next<>0 then
      begin
        Delta:=Bits.ReadSE;
        if (Delta< -128) or (Delta>127) then raise EPlayerFormat.Create('Invalid scaling-list delta');
        Next:=(Last+Delta) and 255;
      end;
      if (I=0) and (Next=0) then
      begin for var J:=0 to High(Values) do Values[J]:=Defaults[J]; Exit end;
      if Next<>0 then Last:=Next;
      Values[Scan[I]]:=Last;
    end;
  end;
var I:Integer;
begin
  for I:=0 to 5 do
    if I mod 3=0 then
    begin
      if UseSequence then List(Scaling.Lists4[I],default_scaling4[I div 3],Sequence.Lists4[I],Scan4)
      else List(Scaling.Lists4[I],default_scaling4[I div 3],default_scaling4[I div 3],Scan4);
    end
    else List(Scaling.Lists4[I],default_scaling4[I div 3],Scaling.Lists4[I-1],Scan4);
  if Has8 then for I:=0 to 1 do
    if UseSequence then List(Scaling.Lists8[I],default_scaling8[I],Sequence.Lists8[I],Scan8)
    else List(Scaling.Lists8[I],default_scaling8[I],default_scaling8[I],Scan8);
end;

procedure ParseSPS(const RBSP: TBytes; out SPS: TH264SPS);
var B: TBitReader; I, N, Chroma, L, R, T, D, BitDepth: Integer;
  procedure HRD;
  var J, Count: Integer;
  begin
    Count := B.ReadUE + 1;
    if Count > 32 then raise EPlayerFormat.Create('Invalid H.264 HRD');
    B.Skip(8);
    for J := 1 to Count do begin B.ReadUE; B.ReadUE; B.Skip(1) end;
    B.Skip(20);
  end;
  procedure VUI;
  var Aspect, J: Integer; A, C: Boolean;
  begin
    if B.ReadBit then
    begin
      Aspect := B.ReadBits(8);
      if Aspect = 255 then B.Skip(32);
    end;
    if B.ReadBit then B.Skip(1);
    if B.ReadBit then
    begin
      B.Skip(3); SPS.FullRange := B.ReadBit;
      if B.ReadBit then
      begin
        B.Skip(16); I := B.ReadBits(8);
        if I = 1 then SPS.Matrix := TColorMatrix.BT709;
      end;
    end;
    if B.ReadBit then begin B.ReadUE; B.ReadUE end;
    if B.ReadBit then B.Skip(65);
    A := B.ReadBit; if A then HRD;
    C := B.ReadBit; if C then HRD;
    if A or C then B.Skip(1);
    B.Skip(1);
    if B.ReadBit then
    begin
      B.Skip(1); for J := 1 to 4 do B.ReadUE;
      SPS.MaxReorder:=B.ReadUE;
      if (SPS.MaxReorder>16) or (B.ReadUE>16) then
        raise EPlayerFormat.Create('Invalid H.264 decoded picture buffer restriction');
    end;
  end;
begin
  SPS := Default(TH264SPS);
  FillChar(SPS.Scaling,SizeOf(SPS.Scaling),16);
  SPS.MaxReorder:=16;
  SPS.Matrix := TColorMatrix.BT601;
  B.Init(RBSP);
  SPS.Profile := B.ReadBits(8); B.Skip(8); SPS.Level := B.ReadBits(8);
  SPS.ID := B.ReadUE;
  if SPS.ID > 31 then raise EPlayerFormat.Create('Invalid SPS id');
  if SPS.Profile in [100,110,122,244,44,83,86,118,128,138,139,134,135] then
  begin
    Chroma := B.ReadUE;
    if Chroma <> 1 then raise EPlayerUnsupported.Create('Only H.264 YUV 4:2:0 is supported');
    BitDepth := B.ReadUE;
    if (BitDepth <> 0) or (B.ReadUE <> 0) then raise EPlayerUnsupported.Create('Only 8-bit H.264 is supported');
    if B.ReadBit then raise EPlayerUnsupported.Create('H.264 transform bypass is not supported');
    SPS.ScalingPresent:=B.ReadBit;
    if SPS.ScalingPresent then ScalingMatrices(B,SPS.Scaling,Default(TH264Scaling),False,True);
  end;
  SPS.LogFrameNum := B.ReadUE + 4;
  if SPS.LogFrameNum > 16 then raise EPlayerFormat.Create('Invalid H.264 frame number size');
  SPS.POCType := B.ReadUE;
  if SPS.POCType = 0 then
  begin
    SPS.LogPOC := B.ReadUE + 4;
    if SPS.LogPOC > 16 then raise EPlayerFormat.Create('Invalid H.264 POC size');
  end
  else if SPS.POCType = 1 then
  begin
    SPS.DeltaPOCAlwaysZero := B.ReadBit;
    SPS.OffsetNonRef:=B.ReadSE; SPS.OffsetTopBottom:=B.ReadSE;
    N := B.ReadUE;
    if N > 255 then raise EPlayerFormat.Create('Invalid POC cycle');
    SPS.POCCycleCount:=N;
    for I := 0 to N-1 do SPS.POCCycle[I]:=B.ReadSE;
  end
  else if SPS.POCType <> 2 then raise EPlayerFormat.Create('Invalid H.264 POC type');
  SPS.MaxRefs := B.ReadUE;
  if SPS.MaxRefs > 16 then raise EPlayerFormat.Create('Too many H.264 reference pictures');
  B.Skip(1);
  SPS.MBWidth := B.ReadUE + 1; SPS.MBHeight := B.ReadUE + 1;
  if (SPS.MBWidth > 512) or (SPS.MBHeight > 512) then raise EPlayerUnsupported.Create('H.264 dimensions exceed 8192');
  SPS.FrameOnly := B.ReadBit;
  if not SPS.FrameOnly then raise EPlayerUnsupported.Create('Interlaced H.264 is not supported yet');
  SPS.Direct8Inference:=B.ReadBit;
  L := 0; R := 0; T := 0; D := 0;
  if B.ReadBit then begin L := B.ReadUE; R := B.ReadUE; T := B.ReadUE; D := B.ReadUE end;
  if (Int64(L)+R>=SPS.MBWidth*8) or (Int64(T)+D>=SPS.MBHeight*8) then
    raise EPlayerFormat.Create('Invalid H.264 crop bounds');
  SPS.Width := SPS.MBWidth * 16 - (L + R) * 2;
  SPS.Height := SPS.MBHeight * 16 - (T + D) * 2;
  SPS.CropLeft := L * 2; SPS.CropTop := T * 2;
  if (SPS.Width <= 0) or (SPS.Height <= 0) then raise EPlayerFormat.Create('Invalid H.264 crop');
  if B.ReadBit then VUI;
  SPS.Valid := True;
end;

procedure ParsePPS(const RBSP: TBytes; out PPS: TH264PPS);
begin ParsePPS(RBSP,PPS,[]) end;

procedure ParsePPS(const RBSP: TBytes; out PPS: TH264PPS; const Sequences:array of TH264SPS);
var B: TBitReader; S:TH264SPS;
begin
  PPS := Default(TH264PPS);
  B.Init(RBSP);
  PPS.ID := B.ReadUE; PPS.SPSID := B.ReadUE;
  if (PPS.ID > 255) or (PPS.SPSID > 31) then raise EPlayerFormat.Create('Invalid PPS id');
  S:=Default(TH264SPS); FillChar(S.Scaling,SizeOf(S.Scaling),16);
  if PPS.SPSID<Length(Sequences) then
    if Sequences[PPS.SPSID].Valid then S:=Sequences[PPS.SPSID];
  PPS.Scaling:=S.Scaling;
  PPS.CABAC := B.ReadBit; PPS.BottomPOC := B.ReadBit;
  if B.ReadUE <> 0 then raise EPlayerUnsupported.Create('H.264 slice groups are not supported');
  PPS.RefCount0 := B.ReadUE + 1; PPS.RefCount1 := B.ReadUE + 1;
  if (PPS.RefCount0 > 32) or (PPS.RefCount1 > 32) then raise EPlayerFormat.Create('Invalid reference count');
  PPS.WeightedPred := B.ReadBit; PPS.WeightedBiPred := B.ReadBits(2);
  PPS.InitQP := 26 + B.ReadSE; B.ReadSE; PPS.ChromaQP := B.ReadSE;
  if (PPS.InitQP < 0) or (PPS.InitQP > 51) or (Abs(PPS.ChromaQP) > 12) then
    raise EPlayerFormat.Create('Invalid H.264 quantizer');
  PPS.DeblockPresent := B.ReadBit; PPS.ConstrainedIntra := B.ReadBit; PPS.Redundant := B.ReadBit;
  PPS.ChromaQP2:=PPS.ChromaQP;
  if B.MoreRBSP then
  begin
    PPS.Transform8x8Mode := B.ReadBit;
    if B.ReadBit then ScalingMatrices(B,PPS.Scaling,S.Scaling,S.ScalingPresent,PPS.Transform8x8Mode);
    PPS.ChromaQP2:=B.ReadSE;
    if Abs(PPS.ChromaQP2)>12 then raise EPlayerFormat.Create('Invalid second chroma quantizer');
  end;
  PPS.Valid := True;
end;

function ParseAVCC(const Config: TBytes; out NALLength: Integer): TArray<TBytes>;
var P, I, Pass, Count, N: Integer; List: TList<TBytes>;
begin
  if (Length(Config) < 7) or (Config[0] <> 1) then raise EPlayerFormat.Create('Invalid AVCDecoderConfigurationRecord');
  NALLength := (Config[4] and 3) + 1;
  if NALLength = 3 then raise EPlayerFormat.Create('Reserved AVC NAL length size');
  List := TList<TBytes>.Create;
  try
    P := 5;
    for Pass := 0 to 1 do
    begin
      if P >= Length(Config) then raise EPlayerFormat.Create('Truncated avcC');
      Count := Config[P]; Inc(P);
      if Pass = 0 then Count := Count and 31;
      for I := 1 to Count do
      begin
        if P + 2 > Length(Config) then raise EPlayerFormat.Create('Truncated avcC NAL length');
        N := (Config[P] shl 8) or Config[P + 1]; Inc(P, 2);
        if (N = 0) or (N > Length(Config) - P) then raise EPlayerFormat.Create('Invalid avcC NAL');
        List.Add(Copy(Config, P, N)); Inc(P, N);
      end;
    end;
    Result := List.ToArray;
  finally List.Free end;
end;

function SplitAVCPacket(const Data: TBytes; NALLength: Integer): TArray<TBytes>;
var List: TList<TBytes>; P, I: Integer; N: Cardinal;
begin
  if not (NALLength in [1,2,4]) then raise EPlayerFormat.Create('Invalid AVC NAL length size');
  List := TList<TBytes>.Create;
  try
    P := 0;
    while P < Length(Data) do
    begin
      if NALLength > Length(Data) - P then raise EPlayerFormat.Create('Truncated AVC packet');
      N := 0;
      for I := 1 to NALLength do begin N := (N shl 8) or Data[P]; Inc(P) end;
      if (N = 0) or (N > Cardinal(Length(Data) - P)) then raise EPlayerFormat.Create('Invalid AVC NAL size');
      if List.Count >= 65536 then raise EPlayerFormat.Create('Too many NAL units');
      List.Add(Copy(Data, P, N)); Inc(P, N);
    end;
    Result := List.ToArray;
  finally List.Free end;
end;

end.
