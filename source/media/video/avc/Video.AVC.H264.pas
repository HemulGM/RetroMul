unit Video.AVC.H264;

// Software H.264 CAVLC implementation, adapted from FFmpeg n7.1 algorithms.
// LGPL-2.1-or-later; Copyright (c) 2003 Michael Niedermayer.
// Scalar paths deliberately avoid architecture-specific SIMD/assembly.

interface

uses
  Core.Bitstream, System.SysUtils, System.Generics.Collections, Video.AVC.Types,
  Video.AVC.Bitstream, Video.AVC.H264.Syntax, Video.AVC.H264.DSP,
  Video.AVC.H264.CABAC;

type
  TH264Decoder = class(TInterfacedObject, IVideoDecoder)
  private
    type
      TMotion = record
        X, Y, Ref: Integer;
        RefIdentity: NativeUInt
      end;

      TMotionBlock = array[0..15] of TMotion;

      TPicture = class
        Pixels: array[0..2] of TBytes;
        Half: array[0..2] of TBytes;
        HalfStride, HalfHeight: Integer;
        HalfReady: TBytes;
        FrameNum, POC: Integer;
        LongIndex: Integer;
        LongTerm: Boolean;
        Identity: NativeUInt;
        Motion: array[0..1] of TArray<TMotion>;
        Intra: TArray<Boolean>;
      end;

      TWeight = record
        Value, Offset: Integer
      end;
  private
    FSPS: array[0..31] of TH264SPS;
    FPPS: array[0..255] of TH264PPS;
    FS: TH264SPS;
    FP: TH264PPS;
    FRefs: TObjectList<TPicture>;
    FRemoveRefs: TList<TPicture>;
    FPromoteRefs: TList<TPicture>;
    FPromoteIndexes: TList<Integer>;
    FCurrentLongIndex, FMaxLongIndex: Integer;
    FClearRefs: Boolean;
    FRefList: TArray<TPicture>;
    FCurrent: TPicture;
    FOutput: TQueue<TVideoFrame>;
    FDelayed: TList<TVideoFrame>;
    FDelayedPOC: TList<Integer>;
    FOrderByPOC: Boolean;
    FPictureID: NativeUInt;
    FPOC, FPOCLSB, FPOCMSB, FPrevPOCLSB, FPrevPOCMSB, FPrevFrameNum, FFrameOffset, FPrevFrameOffset: Integer;
    FSliceType: Integer;
    FDirectSpatial: Boolean;
    FHasBiPrediction: Boolean;
    FUseRegionCache: Boolean;
    FRefList1: TArray<TPicture>;
    FActiveRefs1: Integer;
    FLengths, FWidth, FHeight, FGridWidth, FFrameNum, FSliceID, FMB, FQP: Integer;
    FDeblock, FAlpha, FBeta, FActiveRefs: Integer;
    FRefNAL, FIDR: Boolean;
    FBits: TBitReader;
    FCABAC: TH264CABAC;
    FUseCABAC: Boolean;
    FLastQPDelta: Integer;
    FSkipped, FIs16, FTransform8: TArray<Boolean>;
    FPattern, FChromaMode, FCABACRefs: TArray<Integer>;
    FDifference: TArray<TMotion>;
    FWeights: array[0..15, 0..2] of TWeight;
    FWeights1: array[0..15, 0..2] of TWeight;
    FWeightDenom: array[0..2] of Integer;
    FMotion: TArray<TMotion>;
    FMotion1, FDifference1: TArray<TMotion>;
    FCABACRefs1: TArray<Integer>;
    FDirect, FDirectBlocks: TArray<Boolean>;
    FMode: TArray<Integer>;
    FNonZero: array[0..2] of TArray<Integer>;
    FIntra: TArray<Boolean>;
    FSlice, FQuant, FFilter, FFilterAlpha, FFilterBeta: TArray<Integer>;
    procedure NAL(const Data: TBytes; const Packet: TMediaPacket);
    procedure Slice(const Data: TBytes; const Packet: TMediaPacket);
    procedure StartPicture;
    procedure FinishPicture(const Packet: TMediaPacket);
    function Available(MB: Integer; IntraOnly: Boolean = False): Boolean;
    function NeighborCount(Plane, X, Y: Integer): Integer;
    function MotionAt(X, Y: Integer; List: Integer = 0): TMotion;
    function PredictMotion(X, Y, W, H, Ref, Partition: Integer; List: Integer = 0): TMotion;
    procedure StoreMotion(X, Y, W, H: Integer; const Motion: TMotion; List: Integer = 0);
    procedure Compensate(X, Y, W, H: Integer; const Motion: TMotion);
    procedure CompensateBi(X, Y, W, H: Integer; const M0, M1: TMotion);
    procedure PrepareHalfPixels(Picture: TPicture);
    procedure PrepareHalfRegion(Picture: TPicture; X, Y, W, H, DX, DY: Integer);
    procedure BMotion(TypeCode, X, Y: Integer; out DCT8Allowed: Boolean);
    procedure DirectMotion(out M0, M1: TMotionBlock; PartitionMask: Integer = 15);
    function ReadBRef(X, Y, List: Integer): Integer;
    function CABACBType: Integer;
    function CABACBSubType: Integer;
    procedure OutputDelayed(All: Boolean);
    procedure Macroblock(SliceType: Integer; Skip: Boolean);
    procedure Residual(Intra16: Boolean; CBP, Mode16, ModeChroma: Integer);
    procedure Residual8(CBP: Integer);
    function ReadTransform8: Boolean;
    function ChromaOffset(Plane: Integer): Integer;
    procedure DeblockPicture;
    function CABACIntraType(Base: Integer; IntraSlice: Boolean): Integer;
    function CABACPattern: Integer;
    function ReadBlock(Plane, X, Y, Category, MaxCoeff: Integer; out Block: TCoeffBlock): Integer;
  public
    constructor Create(UseRegionCache: Boolean = False);
    destructor Destroy; override;
    procedure Configure(const Track: TTrackInfo);
    procedure ConfigureAnnexB(PictureOrder: Boolean = False);
    procedure SendAnnexB(const Packet: TMediaPacket);
    procedure Send(const Packet: TMediaPacket);
    function Receive(out Frame: TVideoFrame): Boolean;
    procedure Flush;
    procedure Reset;
    function Kind: TDecoderKind;
  end;

{$IFDEF PLAYER_TEST_STATS}
// Development-only coverage counters; absent from application builds.
var
  H264Test8Modes: array[0..8] of Integer;
  H264Test8Inter, H264Test4Blocks: Integer;
  H264TestBTypes: array[0..22] of Integer;
  H264TestBSubTypes: array[0..12] of Integer;
  H264TestDirectModes: array[0..1] of Integer;
{$ENDIF}

{$IFDEF PLAYER_PROFILE}

var
  H264HalfTicks, H264MotionTicks, H264DeblockTicks: Int64;
{$ENDIF}

implementation

uses
  System.Math, System.Classes, System.Threading, Video.AVC.H264.Tables
{$IFDEF PLAYER_PROFILE}
    , System.Diagnostics
{$ENDIF}
;

const
  BlockX: array[0..15] of Integer = (0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3);
  BlockY: array[0..15] of Integer = (0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3);

constructor TH264Decoder.Create(UseRegionCache: Boolean);
begin
  inherited Create;
  FUseRegionCache := UseRegionCache;
  FRefs := TObjectList<TPicture>.Create(True);
  FRemoveRefs := TList<TPicture>.Create;
  FPromoteRefs := TList<TPicture>.Create;
  FPromoteIndexes := TList<Integer>.Create;
  FOutput := TQueue<TVideoFrame>.Create;
  FDelayed := TList<TVideoFrame>.Create;
  FDelayedPOC := TList<Integer>.Create;
end;

destructor TH264Decoder.Destroy;
begin
  FCurrent.Free;
  FRefs.Free;
  FRemoveRefs.Free;
  FPromoteRefs.Free;
  FPromoteIndexes.Free;
  FOutput.Free;
  FDelayed.Free;
  FDelayedPOC.Free;
  inherited;
end;

function TH264Decoder.Kind: TDecoderKind;
begin
  Result := TDecoderKind.Software
end;

procedure TH264Decoder.Configure(const Track: TTrackInfo);
var
  UnitData: TBytes;
  Packet: TMediaPacket;
  I: Integer;
begin
  if not ((Track.Codec = 'avc1') or (Track.Codec = 'avc3')) then
    raise EPlayerUnsupported.Create('H.264 decoder requires AVC');
  Reset;
  FOrderByPOC := False;
  for I := 0 to High(FSPS) do
    FSPS[I] := Default(TH264SPS);
  for I := 0 to High(FPPS) do
    FPPS[I] := Default(TH264PPS);
  Packet := Default(TMediaPacket);
  for UnitData in ParseAVCC(Track.CodecConfig, FLengths) do
    NAL(UnitData, Packet);
end;

procedure TH264Decoder.ConfigureAnnexB(PictureOrder: Boolean);
begin
  Reset;
  FOrderByPOC := PictureOrder;
  for var I := 0 to High(FSPS) do
    FSPS[I] := Default(TH264SPS);
  for var I := 0 to High(FPPS) do
    FPPS[I] := Default(TH264PPS);
end;

procedure TH264Decoder.SendAnnexB(const Packet: TMediaPacket);
var
  Start, P, Last: Integer;
begin
  if FOutput.Count > 16 then
    raise EPlayerError.Create('Drain H.264 output before sending more packets');
  Start := -1;
  P := 0;
  while P + 3 <= Length(Packet.Data) do
  begin
    if (Packet.Data[P] = 0) and (Packet.Data[P + 1] = 0) and (Packet.Data[P + 2] = 1) then
    begin
      if Start >= 0 then
      begin
        Last := P;
        while (Last > Start) and (Packet.Data[Last - 1] = 0) do
          Dec(Last);
        if Last > Start then
          NAL(Copy(Packet.Data, Start, Last - Start), Packet);
      end;
      Start := P + 3;
      Inc(P, 3);
    end
    else
      Inc(P);
  end;
  if (Start >= 0) and (Start < Length(Packet.Data)) then
    NAL(Copy(Packet.Data, Start, Length(Packet.Data) - Start), Packet);
  if FCurrent <> nil then
    FinishPicture(Packet);
end;

procedure TH264Decoder.Reset;
begin
  FreeAndNil(FCurrent);
  FRefs.Clear;
  FRemoveRefs.Clear;
  FClearRefs := False;
  FPromoteRefs.Clear;
  FPromoteIndexes.Clear;
  FCurrentLongIndex := -1;
  FMaxLongIndex := -1;
  FOutput.Clear;
  FRefList := nil;
  FRefList1 := nil;
  FDelayed.Clear;
  FDelayedPOC.Clear;
  FPrevPOCMSB := 0;
  FPrevPOCLSB := 0;
  FPrevFrameNum := 0;
  FPrevFrameOffset := 0;
  FSliceID := 0;
end;

procedure TH264Decoder.Flush;
begin
  if FCurrent <> nil then
    raise EPlayerFormat.Create('Incomplete H.264 picture at end of stream');
  OutputDelayed(True);
end;

function TH264Decoder.Receive(out Frame: TVideoFrame): Boolean;
begin
  Result := FOutput.Count <> 0;
  if Result then
    Frame := FOutput.Dequeue
  else
    Frame := Default(TVideoFrame);
end;

procedure TH264Decoder.Send(const Packet: TMediaPacket);
var
  UnitData: TBytes;
begin
  if FOutput.Count > 16 then
    raise EPlayerError.Create('Drain H.264 output before sending more packets');
  for UnitData in SplitAVCPacket(Packet.Data, FLengths) do
    NAL(UnitData, Packet);
  if FCurrent <> nil then
    FinishPicture(Packet);
end;

procedure TH264Decoder.NAL(const Data: TBytes; const Packet: TMediaPacket);
var
  RBSP: TBytes;
  S: TH264SPS;
  P: TH264PPS;
  T: Integer;
begin
  if (Length(Data) = 0) or (Data[0] and $80 <> 0) then
    raise EPlayerFormat.Create('Invalid H.264 NAL header');
  T := Data[0] and 31;
  RBSP := UnescapeNAL(Copy(Data, 1, Length(Data) - 1));
  case T of
    7:
      begin
        ParseSPS(RBSP, S);
        FSPS[S.ID] := S
      end;
    8:
      begin
        ParsePPS(RBSP, P, FSPS);
        FPPS[P.ID] := P
      end;
    1, 5:
      begin
        FRefNAL := Data[0] and $60 <> 0;
        FIDR := T = 5;
        Slice(RBSP, Packet)
      end;
    6, 9, 10, 11, 12:
      ; // SEI, AUD, end sequence/stream and filler have no pixel payload.
  else
    raise EPlayerUnsupported.CreateFmt('H.264 NAL type %d is not supported', [T]);
  end;
end;

procedure TH264Decoder.StartPicture;
var
  I, P, N: Integer;
begin
  FWidth := FS.MBWidth * 16;
  FHeight := FS.MBHeight * 16;
  FGridWidth := FS.MBWidth * 4;
  FCurrent := TPicture.Create;
  FHasBiPrediction := False;
  FCurrent.FrameNum := FFrameNum;
  FCurrent.LongTerm := FCurrentLongIndex >= 0;
  FCurrent.LongIndex := FCurrentLongIndex;
  FCurrent.POC := FPOC;
  Inc(FPictureID);
  FCurrent.Identity := FPictureID;
  for P := 0 to 2 do
  begin
    N := FWidth * FHeight;
    if P > 0 then
      N := N div 4;
    SetLength(FCurrent.Pixels[P], N);
    FillChar(FCurrent.Pixels[P][0], N, 128);
    SetLength(FNonZero[P], N div 16);
    for I := 0 to High(FNonZero[P]) do
      FNonZero[P][I] := -1;
  end;
  N := FS.MBWidth * FS.MBHeight;
  SetLength(FIntra, N);
  SetLength(FSlice, N);
  SetLength(FQuant, N);
  SetLength(FSkipped, N);
  SetLength(FIs16, N);
  SetLength(FTransform8, N);
  SetLength(FPattern, N);
  SetLength(FChromaMode, N);
  SetLength(FFilter, N);
  SetLength(FFilterAlpha, N);
  SetLength(FFilterBeta, N);
  for I := 0 to N - 1 do
  begin
    FIntra[I] := False;
    FSlice[I] := -1;
    FSkipped[I] := False;
    FIs16[I] := False;
    FTransform8[I] := False;
    FPattern[I] := 0;
    FChromaMode[I] := 0
  end;
  SetLength(FMotion, N * 16);
  SetLength(FMode, N * 16);
  SetLength(FMotion1, N * 16);
  SetLength(FDifference1, N * 16);
  SetLength(FCABACRefs1, N * 16);
  SetLength(FDirect, N);
  SetLength(FDirectBlocks, N * 16);
  for I := 0 to N - 1 do
    FDirect[I] := False;
  SetLength(FDifference, N * 16);
  SetLength(FCABACRefs, N * 16);
  for I := 0 to High(FMode) do
  begin
    FMode[I] := -1;
    FMotion[I].X := 0;
    FMotion[I].Y := 0;
    FMotion[I].Ref := -2;
    FDifference[I] := Default(TMotion);
    FCABACRefs[I] := -2;
    FMotion1[I] := Default(TMotion);
    FMotion1[I].Ref := -2;
    FDifference1[I] := Default(TMotion);
    FCABACRefs1[I] := -2;
    FDirectBlocks[I] := False
  end;
end;

procedure TH264Decoder.FinishPicture(const Packet: TMediaPacket);
var
  Frame: TVideoFrame;
  P, Y, W, H, X0, Y0, Stride, Oldest: Integer;
  Cleared: Boolean;
begin
  for P := 0 to High(FSlice) do
    if FSlice[P] < 0 then
      raise EPlayerFormat.Create('Incomplete H.264 access unit');
  DeblockPicture;
  Cleared := FClearRefs;
  if FClearRefs then
    FRefs.Clear
  else
    for P := 0 to FRemoveRefs.Count - 1 do
      FRefs.Remove(FRemoveRefs[P]);
  if not Cleared then
    for P := 0 to FPromoteRefs.Count - 1 do
      if FRefs.Contains(FPromoteRefs[P]) then
      begin
        FPromoteRefs[P].LongTerm := True;
        FPromoteRefs[P].LongIndex := FPromoteIndexes[P]
      end;
  FPromoteRefs.Clear;
  FPromoteIndexes.Clear;
  FRemoveRefs.Clear;
  FClearRefs := False;
  Frame := Default(TVideoFrame);
  Frame.Width := FS.Width;
  Frame.Height := FS.Height;
  Frame.PTS := Packet.PTS;
  Frame.Duration := Packet.Duration;
  Frame.Format := TPixelFormat.YUV420P;
  Frame.Matrix := FS.Matrix;
  Frame.FullRange := FS.FullRange;
  for P := 0 to 2 do
  begin
    W := FS.Width;
    H := FS.Height;
    X0 := FS.CropLeft;
    Y0 := FS.CropTop;
    Stride := FWidth;
    if P > 0 then
    begin
      W := W div 2;
      H := H div 2;
      X0 := X0 div 2;
      Y0 := Y0 div 2;
      Stride := Stride div 2
    end;
    Frame.Strides[P] := W;
    SetLength(Frame.Planes[P], W * H);
    for Y := 0 to H - 1 do
      Move(FCurrent.Pixels[P][(Y + Y0) * Stride + X0], Frame.Planes[P][Y * W], W);
  end;
  FDelayed.Add(Frame);
  FDelayedPOC.Add(FPOC);
  OutputDelayed(False);
  if FRefNAL then
  begin
    FPrevPOCMSB := FPOCMSB;
    FPrevPOCLSB := FPOCLSB;
  end;
  FPrevFrameNum := FFrameNum;
  FPrevFrameOffset := FFrameOffset;
  if Cleared then
  begin
    FPrevPOCMSB := 0;
    FPrevPOCLSB := FPOCMSB + FPOCLSB - FPOC;
    FPrevFrameNum := 0;
    FPrevFrameOffset := 0;
    FCurrent.FrameNum := 0;
    FCurrent.POC := 0;
    FMaxLongIndex := -1;
  end;
  if FRefNAL then
  begin
    FCurrent.Motion[0] := Copy(FMotion);
    FCurrent.Motion[1] := Copy(FMotion1);
    FCurrent.Intra := Copy(FIntra);
    FRefs.Insert(0, FCurrent);
    FCurrent := nil;
    while FRefs.Count > Max(FS.MaxRefs, 1) do
    begin
      Oldest := -1;
      for P := FRefs.Count - 1 downto 0 do
        if not FRefs[P].LongTerm then
        begin
          Oldest := P;
          Break
        end;
      if Oldest < 0 then
        raise EPlayerFormat.Create('Too many long-term reference pictures');
      FRefs.Delete(Oldest);
    end;
  end
  else
    FreeAndNil(FCurrent);
end;

procedure TH264Decoder.OutputDelayed(All: Boolean);
var
  I, Smallest: Integer;
begin
  while (FDelayed.Count > 0) and (All or (FDelayed.Count > FS.MaxReorder)) do
  begin
    Smallest := 0;
    for I := 1 to FDelayed.Count - 1 do
      if FOrderByPOC then
      begin
        if FDelayedPOC[I] < FDelayedPOC[Smallest] then
          Smallest := I;
      end
      else if FDelayed[I].PTS < FDelayed[Smallest].PTS then
        Smallest := I;
    FOutput.Enqueue(FDelayed[Smallest]);
    FDelayed.Delete(Smallest);
    FDelayedPOC.Delete(Smallest);
  end;
end;

procedure TH264Decoder.Slice(const Data: TBytes; const Packet: TMediaPacket);
var
  First, SliceType, PPSID, RefCount, RefCount1, I, ID, PicNum, Diff, SkipRun, Q, InitID, Context, Plane: Integer;
  BottomDelta, Delta0, Delta1, AbsFrame, Cycle, InCycle, Expected, MaxPOC: Integer;
  Skipped: Boolean;
  P: TPicture;
  MMCO: Cardinal;
  LongIndex: Integer;

  function Before(A, B: TPicture; ListIndex: Integer): Boolean;
  var
    AN, BN: Integer;
    AP, BP: Boolean;
  begin
    if A.LongTerm <> B.LongTerm then
      Exit(not A.LongTerm);
    if A.LongTerm then
      Exit(A.LongIndex < B.LongIndex);
    if SliceType = 0 then
    begin
      AN := A.FrameNum;
      BN := B.FrameNum;
      if AN > FFrameNum then
        Dec(AN, 1 shl FS.LogFrameNum);
      if BN > FFrameNum then
        Dec(BN, 1 shl FS.LogFrameNum);
      Exit(AN > BN);
    end;
    AP := A.POC < FPOC;
    BP := B.POC < FPOC;
    if AP <> BP then
      Exit(AP = (ListIndex = 0));
    if AP then
      Result := A.POC > B.POC
    else
      Result := A.POC < B.POC;
  end;

  function DefaultList(ListIndex: Integer): TArray<TPicture>;
  var
    A, B: Integer;
    Temp: TPicture;
  begin
    Result := FRefs.ToArray;
    for A := 1 to High(Result) do
    begin
      B := A;
      while (B > 0) and Before(Result[B], Result[B - 1], ListIndex) do
      begin
        Temp := Result[B];
        Result[B] := Result[B - 1];
        Result[B - 1] := Temp;
        Dec(B)
      end;
    end;
  end;

  function EffectiveLong(Picture: TPicture): Integer;
  var
    Index: Integer;
  begin
    Result := -1;
    if Picture.LongTerm then
      Result := Picture.LongIndex;
    Index := FPromoteRefs.IndexOf(Picture);
    if Index >= 0 then
      Result := FPromoteIndexes[Index];
    if FRemoveRefs.Contains(Picture) then
      Result := -2;
  end;

  procedure ModifyList(var Items: TArray<TPicture>; Active: Integer);
  var
    List: TList<TPicture>;
    Index, Q: Integer;
  begin
    if not FBits.ReadBit then
      Exit;
    List := TList<TPicture>.Create;
    try
      for var Item in Items do
        List.Add(Item);
      PicNum := FFrameNum;
      Index := 0;
      repeat
        ID := FBits.ReadUE;
        if ID = 3 then
          Break;
        if not (ID in [0, 1, 2]) then
          raise EPlayerFormat.Create('Invalid reference-list modification');
        if ID = 2 then
          LongIndex := FBits.ReadUE
        else
        begin
          Diff := FBits.ReadUE + 1;
          if ID = 0 then
            PicNum := (PicNum - Diff) and ((1 shl FS.LogFrameNum) - 1)
          else
            PicNum := (PicNum + Diff) and ((1 shl FS.LogFrameNum) - 1);
        end;
        P := nil;
        for Q := 0 to FRefs.Count - 1 do
          if ((ID = 2) and FRefs[Q].LongTerm and (FRefs[Q].LongIndex = LongIndex)) or
            ((ID <> 2) and not FRefs[Q].LongTerm and (FRefs[Q].FrameNum = PicNum)) then
            P := FRefs[Q];
        if (P = nil) or (Index >= Active) or (Index > List.Count) then
          raise EPlayerFormat.Create('Invalid reference list modification');
        List.Insert(Index, P);
        for Q := List.Count - 1 downto Index + 1 do
          if List[Q] = P then
            List.Delete(Q);
        Inc(Index);
      until False;
      Items := List.ToArray;
    finally
      List.Free
    end;
  end;

  procedure ReadWeights(ListIndex, Active: Integer);
  var
    R, C: Integer;
    W: array[0..2] of TWeight;
  begin
    for R := 0 to Active - 1 do
    begin
      for C := 0 to 2 do
      begin
        W[C].Value := 1 shl FWeightDenom[C];
        W[C].Offset := 0
      end;
      if FBits.ReadBit then
      begin
        W[0].Value := FBits.ReadSE;
        W[0].Offset := FBits.ReadSE
      end;
      if FBits.ReadBit then
        for C := 1 to 2 do
        begin
          W[C].Value := FBits.ReadSE;
          W[C].Offset := FBits.ReadSE
        end;
      for C := 0 to 2 do
      begin
        if (W[C].Value < -128) or (W[C].Value > 128) or (W[C].Offset < -128) or (W[C].Offset > 127) then
          raise EPlayerFormat.Create('Invalid H.264 prediction weight');
        if ListIndex = 0 then
          FWeights[R, C] := W[C]
        else
          FWeights1[R, C] := W[C];
      end;
    end;
  end;

begin
  FBits.Init(Data);
  First := FBits.ReadUE;
  SliceType := FBits.ReadUE;
  if SliceType > 9 then
    raise EPlayerFormat.Create('Invalid H.264 slice type');
  SliceType := SliceType mod 5;
  FSliceType := SliceType;
  PPSID := FBits.ReadUE;
  if (PPSID > 255) or not FPPS[PPSID].Valid then
    raise EPlayerFormat.Create('Missing H.264 PPS');
  FP := FPPS[PPSID];
  if not FSPS[FP.SPSID].Valid then
    raise EPlayerFormat.Create('Missing H.264 SPS');
  FS := FSPS[FP.SPSID];
  FUseCABAC := FP.CABAC;
  // The 9-bit CABAC reservoir may read zero look-ahead beyond the last
  // arithmetic byte. Annex B remuxing can strip trailing cabac_zero_word.
  if FUseCABAC then
    FBits.AppendZeroPadding(2);
  if not (SliceType in [0, 1, 2]) then
    raise EPlayerUnsupported.Create('H.264 SP/SI slices are not supported');
  FFrameNum := FBits.ReadBits(FS.LogFrameNum);
  FCurrentLongIndex := -1;
  if FIDR then
  begin
    FBits.ReadUE;
    if FCurrent = nil then
      OutputDelayed(True);
  end;
  FFrameOffset := FPrevFrameOffset;
  if FIDR then
    FFrameOffset := 0
  else if FFrameNum < FPrevFrameNum then
    Inc(FFrameOffset, 1 shl FS.LogFrameNum);
  FPOCMSB := 0;
  FPOCLSB := 0;
  BottomDelta := 0;
  Delta0 := 0;
  Delta1 := 0;
  if FS.POCType = 0 then
  begin
    FPOCLSB := FBits.ReadBits(FS.LogPOC);
    if FP.BottomPOC then
      BottomDelta := FBits.ReadSE;
    MaxPOC := 1 shl FS.LogPOC;
    if not FIDR then
    begin
      FPOCMSB := FPrevPOCMSB;
      if (FPOCLSB < FPrevPOCLSB) and (FPrevPOCLSB - FPOCLSB >= MaxPOC div 2) then
        Inc(FPOCMSB, MaxPOC)
      else if (FPOCLSB > FPrevPOCLSB) and (FPOCLSB - FPrevPOCLSB > MaxPOC div 2) then
        Dec(FPOCMSB, MaxPOC);
    end;
    FPOC := FPOCMSB + FPOCLSB + Min(BottomDelta, 0);
  end
  else if FS.POCType = 1 then
  begin
    if not FS.DeltaPOCAlwaysZero then
    begin
      Delta0 := FBits.ReadSE;
      if FP.BottomPOC then
        Delta1 := FBits.ReadSE
    end;
    AbsFrame := 0;
    if FS.POCCycleCount > 0 then
      AbsFrame := FFrameOffset + FFrameNum;
    if not FRefNAL and (AbsFrame > 0) then
      Dec(AbsFrame);
    Expected := 0;
    if AbsFrame > 0 then
    begin
      Cycle := (AbsFrame - 1) div FS.POCCycleCount;
      InCycle := (AbsFrame - 1) mod FS.POCCycleCount;
      for I := 0 to FS.POCCycleCount - 1 do
        Inc(Expected, FS.POCCycle[I]);
      Expected := Expected * Cycle;
      for I := 0 to InCycle do
        Inc(Expected, FS.POCCycle[I]);
    end;
    if not FRefNAL then
      Inc(Expected, FS.OffsetNonRef);
    FPOC := Expected + Delta0 + Min(FS.OffsetTopBottom + Delta1, 0);
  end
  else if FIDR then
    FPOC := 0
  else
    FPOC := 2 * (FFrameOffset + FFrameNum) - Ord(not FRefNAL);
  if FP.Redundant then
    if FBits.ReadUE <> 0 then
      raise EPlayerUnsupported.Create('Redundant H.264 slices');
  FDirectSpatial := False;
  if SliceType = 1 then
    FDirectSpatial := FBits.ReadBit;
  RefCount := FP.RefCount0;
  RefCount1 := FP.RefCount1;
  if SliceType in [0, 1] then
    if FBits.ReadBit then
    begin
      RefCount := FBits.ReadUE + 1;
      if SliceType = 1 then
        RefCount1 := FBits.ReadUE + 1
    end;
  if (RefCount < 1) or (RefCount > 16) or (RefCount1 < 1) or (RefCount1 > 16) then
    raise EPlayerFormat.Create('Invalid active reference count');
  FActiveRefs := RefCount;
  FActiveRefs1 := RefCount1;
  FRefList := DefaultList(0);
  FRefList1 := nil;
  if SliceType = 1 then
  begin
    FRefList1 := DefaultList(1);
    Skipped := Length(FRefList) > 1;
    for I := 0 to High(FRefList) do
      if FRefList[I] <> FRefList1[I] then
        Skipped := False;
    if Skipped then
    begin
      P := FRefList1[0];
      FRefList1[0] := FRefList1[1];
      FRefList1[1] := P
    end;
  end;
  if SliceType in [0, 1] then
    ModifyList(FRefList, RefCount);
  if SliceType = 1 then
    ModifyList(FRefList1, RefCount1);
  FillChar(FWeightDenom, SizeOf(FWeightDenom), 0);
  for I := 0 to 15 do
    for Plane := 0 to 2 do
    begin
      FWeights[I, Plane].Value := 1;
      FWeights[I, Plane].Offset := 0;
      FWeights1[I, Plane].Value := 1;
      FWeights1[I, Plane].Offset := 0;
    end;
  if (FP.WeightedPred and (SliceType = 0)) or ((SliceType = 1) and (FP.WeightedBiPred = 1)) then
  begin
    FWeightDenom[0] := FBits.ReadUE;
    FWeightDenom[1] := FBits.ReadUE;
    FWeightDenom[2] := FWeightDenom[1];
    if (FWeightDenom[0] > 7) or (FWeightDenom[1] > 7) then
      raise EPlayerFormat.Create('Invalid prediction weight denominator');
    ReadWeights(0, RefCount);
    if SliceType = 1 then
      ReadWeights(1, RefCount1);
  end;
  if FRefNAL then
  begin
    if FIDR then
    begin
      FBits.Skip(1);
      if FBits.ReadBit then
      begin
        FCurrentLongIndex := 0;
        FMaxLongIndex := 0
      end
      else
        FMaxLongIndex := -1;
      FRefs.Clear;
    end
    else if FBits.ReadBit then
    begin
      repeat
        MMCO := FBits.ReadUE;
        // Marking is signaled in every slice but applied once per picture.
        if (FCurrent <> nil) and (MMCO <> 0) then
        begin
          case MMCO of
            1, 2, 4, 6:
              FBits.ReadUE;
            3:
              begin
                FBits.ReadUE;
                FBits.ReadUE
              end;
            5:
              ;
          else
            raise EPlayerFormat.Create('Invalid repeated reference management operation');
          end;
          Continue;
        end;
        case MMCO of
          0:
            Break;
          1, 3:
            begin
              PicNum := (FFrameNum - Integer(FBits.ReadUE) - 1) and ((1 shl FS.LogFrameNum) - 1);
              P := nil;
              for Q := 0 to FRefs.Count - 1 do
                if (EffectiveLong(FRefs[Q]) = -1) and (FRefs[Q].FrameNum = PicNum) then
                  P := FRefs[Q];
              if P = nil then
                raise EPlayerFormat.Create('Missing picture in reference removal');
              if MMCO = 1 then
              begin
                if not FRemoveRefs.Contains(P) then
                  FRemoveRefs.Add(P)
              end
              else
              begin
                LongIndex := FBits.ReadUE;
                if LongIndex > FMaxLongIndex then
                  raise EPlayerFormat.Create('Long-term reference index exceeds MMCO limit');
                for Q := 0 to FRefs.Count - 1 do
                  if EffectiveLong(FRefs[Q]) = LongIndex then
                    FRemoveRefs.Add(FRefs[Q]);
                if not FPromoteRefs.Contains(P) then
                begin
                  FPromoteRefs.Add(P);
                  FPromoteIndexes.Add(LongIndex)
                end;
              end;
            end;
          2:
            begin
              LongIndex := FBits.ReadUE;
              P := nil;
              for Q := 0 to FRefs.Count - 1 do
                if EffectiveLong(FRefs[Q]) = LongIndex then
                  P := FRefs[Q];
              if P = nil then
                raise EPlayerFormat.Create('Missing long-term picture in MMCO removal');
              if not FRemoveRefs.Contains(P) then
                FRemoveRefs.Add(P);
            end;
          4:
            begin
              FMaxLongIndex := Integer(FBits.ReadUE) - 1;
              if FMaxLongIndex > 15 then
                raise EPlayerFormat.Create('Invalid maximum long-term reference index');
              for Q := 0 to FRefs.Count - 1 do
                if EffectiveLong(FRefs[Q]) > FMaxLongIndex then
                  FRemoveRefs.Add(FRefs[Q]);
            end;
          5:
            FClearRefs := True;
          6:
            begin
              FCurrentLongIndex := FBits.ReadUE;
              if FCurrentLongIndex > FMaxLongIndex then
                raise EPlayerFormat.Create('Current long-term reference index exceeds MMCO limit');
              for Q := 0 to FRefs.Count - 1 do
                if EffectiveLong(FRefs[Q]) = FCurrentLongIndex then
                  FRemoveRefs.Add(FRefs[Q]);
            end;
        else
          raise EPlayerFormat.Create('Invalid H.264 reference management operation');
        end;
      until False;
    end;
  end;
  InitID := 0;
  if FUseCABAC and (SliceType <> 2) then
    InitID := FBits.ReadUE;
  FQP := FP.InitQP + FBits.ReadSE;
  if (FQP < 0) or (FQP > 51) then
    raise EPlayerFormat.Create('Invalid slice QP');
  FDeblock := 0;
  FAlpha := 0;
  FBeta := 0;
  if FP.DeblockPresent then
  begin
    FDeblock := FBits.ReadUE;
    if FDeblock > 2 then
      raise EPlayerFormat.Create('Invalid deblocking mode');
    if FDeblock <> 1 then
    begin
      FAlpha := FBits.ReadSE * 2;
      FBeta := FBits.ReadSE * 2
    end;
  end;
  if First >= FS.MBWidth * FS.MBHeight then
    raise EPlayerFormat.Create('Invalid first macroblock');
  if FCurrent = nil then
    StartPicture
  else if FCurrent.FrameNum <> FFrameNum then
    raise EPlayerFormat.Create('Multiple pictures in one AVC sample');
  if (FWidth <> FS.MBWidth * 16) or (FHeight <> FS.MBHeight * 16) then
    raise EPlayerFormat.Create('SPS dimensions changed within a picture');
  if SliceType = 1 then
    FHasBiPrediction := True;
  Inc(FSliceID);
  FMB := First;
  FLastQPDelta := 0;
  if FUseCABAC then
  begin
    while FBits.Position and 7 <> 0 do
      if not FBits.ReadBit then
        raise EPlayerFormat.Create('Invalid CABAC alignment bit');
    FCABAC.Init(FBits, FQP, InitID, SliceType = 2);
    repeat
      Skipped := False;
      if SliceType in [0, 1] then
      begin
        Context := 0;
        if (FMB mod FS.MBWidth > 0) and Available(FMB - 1) and not FSkipped[FMB - 1] then
          Inc(Context);
        if Available(FMB - FS.MBWidth) and not FSkipped[FMB - FS.MBWidth] then
          Inc(Context);
        if SliceType = 1 then
          Skipped := FCABAC.Decode(24 + Context) <> 0
        else
          Skipped := FCABAC.Decode(11 + Context) <> 0;
      end;
      Macroblock(SliceType, Skipped);
      Inc(FMB);
      if FCABAC.Terminate then
        Break;
      if FMB >= FS.MBWidth * FS.MBHeight then
        raise EPlayerFormat.Create('CABAC picture has no termination bin');
    until False;
    Exit;
  end;
  while FBits.MoreRBSP do
  begin
    if SliceType in [0, 1] then
    begin
      SkipRun := FBits.ReadUE;
      if SkipRun > FS.MBWidth * FS.MBHeight - FMB then
        raise EPlayerFormat.Create('Invalid skipped macroblocks');
      for I := 1 to SkipRun do
      begin
        Macroblock(SliceType, True);
        Inc(FMB)
      end;
      if not FBits.MoreRBSP then
        Break;
    end;
    if FMB >= FS.MBWidth * FS.MBHeight then
      raise EPlayerFormat.Create('Too many H.264 macroblocks');
    Macroblock(SliceType, False);
    Inc(FMB);
  end;
end;

function TH264Decoder.Available(MB: Integer; IntraOnly: Boolean): Boolean;
begin
  Result := (MB >= 0) and (MB < Length(FSlice)) and (FSlice[MB] = FSliceID);
  if Result and IntraOnly and FP.ConstrainedIntra then
    Result := FIntra[MB];
end;

function TH264Decoder.NeighborCount(Plane, X, Y: Integer): Integer;
var
  W, A, B, MB: Integer;
begin
  W := FGridWidth;
  if Plane > 0 then
    W := W div 2;
  A := -1;
  B := -1;
  if X > 0 then
  begin
    if Plane = 0 then
      MB := (Y div 4) * FS.MBWidth + (X - 1) div 4
    else
      MB := (Y div 2) * FS.MBWidth + (X - 1) div 2;
    if (MB = FMB) or Available(MB) then
      A := FNonZero[Plane][Y * W + X - 1];
  end;
  if Y > 0 then
  begin
    if Plane = 0 then
      MB := ((Y - 1) div 4) * FS.MBWidth + X div 4
    else
      MB := ((Y - 1) div 2) * FS.MBWidth + X div 2;
    if (MB = FMB) or Available(MB) then
      B := FNonZero[Plane][(Y - 1) * W + X];
  end;
  if A < 0 then
    Result := Max(B, 0)
  else if B < 0 then
    Result := A
  else
    Result := (A + B + 1) div 2;
end;

function TH264Decoder.MotionAt(X, Y: Integer; List: Integer): TMotion;
var
  MB: Integer;
begin
  Result := Default(TMotion);
  Result.Ref := -2;
  if (X < 0) or (Y < 0) or (X >= FGridWidth) or (Y >= FS.MBHeight * 4) then
    Exit;
  MB := (Y div 4) * FS.MBWidth + X div 4;
  if (MB <> FMB) and not Available(MB) then
    Exit;
  if List = 0 then
    Result := FMotion[Y * FGridWidth + X]
  else
    Result := FMotion1[Y * FGridWidth + X];
end;

function TH264Decoder.PredictMotion(X, Y, W, H, Ref, Partition: Integer; List: Integer): TMotion;
var
  A, B, C: TMotion;
  Matches: Integer;

  function Median(A, B, C: Integer): Integer;
  begin
    Result := A + B + C - Min(A, Min(B, C)) - Max(A, Max(B, C))
  end;

begin
  A := MotionAt(X - 1, Y, List);
  B := MotionAt(X, Y - 1, List);
  C := MotionAt(X + W div 4, Y - 1, List);
  if C.Ref = -2 then
    C := MotionAt(X - 1, Y - 1, List);
  Result := Default(TMotion);
  Result.Ref := Ref;
  if (W = 16) and (H = 8) then
  begin
    if (Partition = 0) and (B.Ref = Ref) then
      Exit(B);
    if (Partition = 1) and (A.Ref = Ref) then
      Exit(A);
  end;
  if (W = 8) and (H = 16) then
  begin
    if (Partition = 0) and (A.Ref = Ref) then
      Exit(A);
    if (Partition = 1) and (C.Ref = Ref) then
      Exit(C);
  end;
  if (B.Ref = -2) and (C.Ref = -2) and (A.Ref <> -2) then
  begin
    B := A;
    C := A
  end;
  Matches := Ord(A.Ref = Ref) + Ord(B.Ref = Ref) + Ord(C.Ref = Ref);
  if Matches = 1 then
  begin
    if A.Ref = Ref then
      Exit(A);
    if B.Ref = Ref then
      Exit(B);
    Exit(C);
  end;
  Result.X := Median(A.X, B.X, C.X);
  Result.Y := Median(A.Y, B.Y, C.Y);
end;

procedure TH264Decoder.StoreMotion(X, Y, W, H: Integer; const Motion: TMotion; List: Integer);
var
  I, J: Integer;
  Stored: TMotion;
begin
  Stored := Motion;
  Stored.RefIdentity := 0;
  if Stored.Ref >= 0 then
  begin
    if List = 0 then
    begin
      if Stored.Ref >= Length(FRefList) then
        raise EPlayerFormat.Create('Missing list0 reference');
      Stored.RefIdentity := FRefList[Stored.Ref].Identity;
    end
    else
    begin
      if Stored.Ref >= Length(FRefList1) then
        raise EPlayerFormat.Create('Missing list1 reference');
      Stored.RefIdentity := FRefList1[Stored.Ref].Identity;
    end;
  end;
  for J := Y div 4 to (Y + H) div 4 - 1 do
    for I := X div 4 to (X + W) div 4 - 1 do
      if List = 0 then
        FMotion[J * FGridWidth + I] := Stored
      else
        FMotion1[J * FGridWidth + I] := Stored;
end;

procedure TH264Decoder.PrepareHalfPixels(Picture: TPicture);
{$IFDEF PLAYER_PROFILE}
var
  ProfileStart: Int64;
{$ENDIF}
var
  Raw: TArray<SmallInt>;
  W, H, Stride, Rows, Jobs, I: Integer;
  Horizontal, Vertical: TProc<Integer, Integer>;
begin
  if Length(Picture.Half[0]) <> 0 then
    Exit;
{$IFDEF PLAYER_PROFILE}
  ProfileStart := TStopwatch.GetTimeStamp;
{$ENDIF}
  W := FWidth;
  H := FHeight;
  Stride := W + 6;
  Rows := H + 6;
  Picture.HalfStride := Stride;
  Picture.HalfHeight := Rows;
  SetLength(Raw, Stride * Rows);
  for I := 0 to 2 do
    SetLength(Picture.Half[I], Stride * Rows);
  Jobs := 1;
  if (W * H >= 262144) and (TThread.ProcessorCount > 2) then
    Jobs := Min(4, TThread.ProcessorCount - 1);
  Horizontal :=
    procedure(First, Last: Integer)
    var
      X, Y, SX, Row, Index, V: Integer;

      function Clamp(Value, Maximum: Integer): Integer; inline;
      begin
        if Value < 0 then
          Result := 0
        else if Value > Maximum then
          Result := Maximum
        else
          Result := Value
      end;

    begin
      for Y := First to Last do
      begin
        Row := Clamp(Y - 3, H - 1) * W;
        Index := Y * Stride;
        for X := 0 to Stride - 1 do
        begin
          SX := X - 3;
          if (SX >= 2) and (SX < W - 3) then
            V := Picture.Pixels[0][Row + SX - 2] - 5 * Picture.Pixels[0][Row + SX - 1] +
              20 * Picture.Pixels[0][Row + SX] + 20 * Picture.Pixels[0][Row + SX + 1] -
              5 * Picture.Pixels[0][Row + SX + 2] + Picture.Pixels[0][Row + SX + 3]
          else
            V := Picture.Pixels[0][Row + Clamp(SX - 2, W - 1)] - 5 * Picture.Pixels[0][Row + Clamp(SX - 1, W - 1)] +
              20 * Picture.Pixels[0][Row + Clamp(SX, W - 1)] + 20 * Picture.Pixels[0][Row + Clamp(SX + 1, W - 1)] -
              5 * Picture.Pixels[0][Row + Clamp(SX + 2, W - 1)] + Picture.Pixels[0][Row + Clamp(SX + 3, W - 1)];
          Raw[Index + X] := V; // Six-tap sum fits signed 16 bits for 8-bit input.
          Picture.Half[0][Index + X] := ClipByte(ASR(V + 16, 5));
        end;
      end;
    end;
  Vertical :=
    procedure(First, Last: Integer)
    var
      X, Y, SY, CX, Index, V, R0, R1, R2, R3, R4, R5, T0, T1, T2, T3, T4, T5: Integer;

      function Clamp(Value, Maximum: Integer): Integer; inline;
      begin
        if Value < 0 then
          Result := 0
        else if Value > Maximum then
          Result := Maximum
        else
          Result := Value
      end;

    begin
      for Y := First to Last do
      begin
        SY := Y - 3;
        Index := Y * Stride;
        R0 := Clamp(SY - 2, H - 1) * W;
        R1 := Clamp(SY - 1, H - 1) * W;
        R2 := Clamp(SY, H - 1) * W;
        R3 := Clamp(SY + 1, H - 1) * W;
        R4 := Clamp(SY + 2, H - 1) * W;
        R5 := Clamp(SY + 3, H - 1) * W;
        T0 := Clamp(Y - 2, Rows - 1) * Stride;
        T1 := Clamp(Y - 1, Rows - 1) * Stride;
        T2 := Index;
        T3 := Clamp(Y + 1, Rows - 1) * Stride;
        T4 := Clamp(Y + 2, Rows - 1) * Stride;
        T5 := Clamp(Y + 3, Rows - 1) * Stride;
        for X := 0 to Stride - 1 do
        begin
          CX := Clamp(X - 3, W - 1);
          V := Picture.Pixels[0][R0 + CX] - 5 * Picture.Pixels[0][R1 + CX] + 20 * Picture.Pixels[0][R2 + CX] +
            20 * Picture.Pixels[0][R3 + CX] - 5 * Picture.Pixels[0][R4 + CX] + Picture.Pixels[0][R5 + CX];
          Picture.Half[1][Index + X] := ClipByte(ASR(V + 16, 5));
          V := Raw[T0 + X] - 5 * Raw[T1 + X] + 20 * Raw[T2 + X] + 20 * Raw[T3 + X] - 5 * Raw[T4 + X] + Raw[T5 + X];
          Picture.Half[2][Index + X] := ClipByte(ASR(V + 512, 10));
        end;
      end;
    end;
  try
    if Jobs = 1 then
    begin
      Horizontal(0, Rows - 1);
      Vertical(0, Rows - 1)
    end
    else
    begin
    // Each task owns disjoint output rows. Both passes complete before use.
      TParallel.for (0, Jobs - 1,
        procedure(Index: Integer)
        begin
          Horizontal(Rows * Index div Jobs, Rows * (Index + 1) div Jobs - 1)
        end);
      TParallel.for (0, Jobs - 1,
        procedure(Index: Integer)
        begin
          Vertical(Rows * Index div Jobs, Rows * (Index + 1) div Jobs - 1)
        end);
    end;
  finally
    Horizontal := nil;
    Vertical := nil
  end;
{$IFDEF PLAYER_PROFILE}
  Inc(H264HalfTicks, TStopwatch.GetTimeStamp - ProfileStart);
{$ENDIF}
end;

procedure TH264Decoder.Compensate(X, Y, W, H: Integer; const Motion: TMotion);
var
  Unused: TMotion;
begin
  Unused := Default(TMotion);
  Unused.Ref := -1;
  CompensateBi(X, Y, W, H, Motion, Unused);
end;

procedure TH264Decoder.PrepareHalfRegion(Picture: TPicture; X, Y, W, H, DX, DY: Integer);
const
  TileW = 32;
  TileH = 32;
var
  Mask, FX, FY, Stride, Rows, Cols, TX, TY, X0, X1, Y0, Y1, PX, PY, SX, SY, Row, Index, V, K, Missing: Integer;
  Raw: array[0..TileW * (TileH + 5) - 1] of SmallInt;

  function Clamp(Value, Last: Integer): Integer; inline;
  begin
    if Value < 0 then
      Result := 0
    else if Value > Last then
      Result := Last
    else
      Result := Value
  end;

  function Horizontal(AX, AY: Integer): Integer;
  var
    Base: Integer;
  begin
    Base := Clamp(AY, FHeight - 1) * FWidth;
    if (AX >= 2) and (AX < FWidth - 3) then
      Result := Picture.Pixels[0][Base + AX - 2] - 5 * Picture.Pixels[0][Base + AX - 1] + 20 * Picture.Pixels[0][Base + AX] +
        20 * Picture.Pixels[0][Base + AX + 1] - 5 * Picture.Pixels[0][Base + AX + 2] + Picture.Pixels[0][Base + AX + 3]
    else
      Result := Picture.Pixels[0][Base + Clamp(AX - 2, FWidth - 1)] - 5 * Picture.Pixels[0][Base + Clamp(AX - 1, FWidth - 1)] +
        20 * Picture.Pixels[0][Base + Clamp(AX, FWidth - 1)] + 20 * Picture.Pixels[0][Base + Clamp(AX + 1, FWidth - 1)] -
        5 * Picture.Pixels[0][Base + Clamp(AX + 2, FWidth - 1)] + Picture.Pixels[0][Base + Clamp(AX + 3, FWidth - 1)];
  end;
{$IFDEF PLAYER_PROFILE}

var
  Started: Int64;
{$ENDIF}
begin
  FX := DX and 3;
  FY := DY and 3;
  if (FX or FY) = 0 then
    Exit;
{$IFDEF PLAYER_PROFILE}
  Started := TStopwatch.GetTimeStamp;
{$ENDIF}
  if FY = 0 then
    Mask := 1
  else if FX = 0 then
    Mask := 2
  else if (FX = 2) and (FY = 2) then
    Mask := 4
  else if FX = 2 then
    Mask := 5
  else if FY = 2 then
    Mask := 6
  else
    Mask := 3;
  Stride := FWidth + 6;
  Rows := FHeight + 6;
  Cols := (Stride + TileW - 1) div TileW;
  if Length(Picture.HalfReady) = 0 then
  begin
    Picture.HalfStride := Stride;
    Picture.HalfHeight := Rows;
    SetLength(Picture.HalfReady, Cols * ((Rows + TileH - 1) div TileH));
    for K := 0 to 2 do
      SetLength(Picture.Half[K], Stride * Rows);
  end;
  SX := X + ASR(DX, 2) + 3;
  SY := Y + ASR(DY, 2) + 3;
  // Include the adjacent half sample used by the quarter-pixel average.
  X0 := Clamp(SX, Stride - 1) div TileW;
  X1 := Clamp(SX + W, Stride - 1) div TileW;
  Y0 := Clamp(SY, Rows - 1) div TileH;
  Y1 := Clamp(SY + H, Rows - 1) div TileH;
  for TY := Y0 to Y1 do
    for TX := X0 to X1 do
    begin
      Index := TY * Cols + TX;
      Missing := Mask and not Picture.HalfReady[Index];
      if Missing = 0 then
        Continue;
      if Missing and 4 <> 0 then
      begin
        for PY := 0 to Min(TileH, Rows - TY * TileH) + 4 do
          for PX := 0 to Min(TileW, Stride - TX * TileW) - 1 do
            Raw[PY * TileW + PX] := Horizontal(TX * TileW + PX - 3, TY * TileH + PY - 5);
      end;
      for PY := TY * TileH to Min(Rows, (TY + 1) * TileH) - 1 do
      begin
        Row := PY * Stride;
        SY := PY - 3;
        for PX := TX * TileW to Min(Stride, (TX + 1) * TileW) - 1 do
        begin
          SX := PX - 3;
          if Missing and 1 <> 0 then
          begin
            if Missing and 4 <> 0 then
              V := Raw[(PY - TY * TileH + 2) * TileW + PX - TX * TileW]
            else
              V := Horizontal(SX, SY);
            Picture.Half[0][Row + PX] := ClipByte(ASR(V + 16, 5));
          end;
          if Missing and 2 <> 0 then
          begin
            SX := Clamp(SX, FWidth - 1);
            V := Picture.Pixels[0][Clamp(SY - 2, FHeight - 1) * FWidth + SX] - 5 * Picture.Pixels[0][Clamp(SY - 1, FHeight - 1) * FWidth + SX] +
              20 * Picture.Pixels[0][Clamp(SY, FHeight - 1) * FWidth + SX] + 20 * Picture.Pixels[0][Clamp(SY + 1, FHeight - 1) * FWidth + SX] -
              5 * Picture.Pixels[0][Clamp(SY + 2, FHeight - 1) * FWidth + SX] + Picture.Pixels[0][Clamp(SY + 3, FHeight - 1) * FWidth + SX];
            Picture.Half[1][Row + PX] := ClipByte(ASR(V + 16, 5));
          end;
          if Missing and 4 <> 0 then
          begin
            K := (PY - TY * TileH) * TileW + PX - TX * TileW;
            V := Raw[K] - 5 * Raw[K + TileW] + 20 * Raw[K + 2 * TileW] + 20 * Raw[K + 3 * TileW] - 5 * Raw[K + 4 * TileW] + Raw[K + 5 * TileW];
            Picture.Half[2][Row + PX] := ClipByte(ASR(V + 512, 10));
          end;
        end;
      end;
      Picture.HalfReady[Index] := Picture.HalfReady[Index] or Missing;
    end;
{$IFDEF PLAYER_PROFILE}
  Inc(H264HalfTicks, TStopwatch.GetTimeStamp - Started);
{$ENDIF}
end;

procedure TH264Decoder.CompensateBi(X, Y, W, H: Integer; const M0, M1: TMotion);
type
  TPrediction = array[0..255] of Byte;
{$IFDEF PLAYER_PROFILE}
var
  ProfileStart: Int64;
{$ENDIF}
var
  P, I, J, PX, PY, V, Stride, Height, CW, CH: Integer;
  Raw0, Raw1, Weight0, Weight1, Denom, Rounding, TD, TB, TX, Scale: Integer;
  Ref0, Ref1: TPicture;
  Prediction0, Prediction1: TPrediction;
  // Select interpolation sources once per partition, not once per pixel.

  procedure Predict(const Motion: TMotion; Reference: TPicture; out Dest: TPrediction);
  var
    FX, FY, SX, SY, APlane, BPlane, AX, AY, BX, BY, AStride, BStride, AW, AH, BW, BH: Integer;
    RowA, RowB, X0, X1, Y0, Y1, K, L, N, WA, WB, WC, WD: Integer;
    AData, BData: TBytes;
    Average: Boolean;

    function Clamp(Value, Limit: Integer): Integer; inline;
    begin
      if Value < 0 then
        Result := 0
      else if Value >= Limit then
        Result := Limit - 1
      else
        Result := Value
    end;

  begin
    if P = 0 then
    begin
      SX := PX + ASR(Motion.X, 2);
      SY := PY + ASR(Motion.Y, 2);
      FX := Motion.X and 3;
      FY := Motion.Y and 3;
      APlane := -1;
      BPlane := -1;
      AX := SX;
      AY := SY;
      BX := SX;
      BY := SY;
      Average := False;
      if FY = 0 then
      begin
        if FX <> 0 then
        begin
          APlane := 0;
          Average := FX <> 2;
          Inc(BX, Ord(FX = 3))
        end;
      end
      else if FX = 0 then
      begin
        APlane := 1;
        Average := FY <> 2;
        Inc(BY, Ord(FY = 3))
      end
      else if (FX = 2) and (FY = 2) then
        APlane := 2
      else if FX = 2 then
      begin
        APlane := 2;
        BPlane := 0;
        Inc(BY, Ord(FY = 3));
        Average := True
      end
      else if FY = 2 then
      begin
        APlane := 2;
        BPlane := 1;
        Inc(BX, Ord(FX = 3));
        Average := True
      end
      else
      begin
        APlane := 0;
        BPlane := 1;
        Inc(AY, Ord(FY = 3));
        Inc(BX, Ord(FX = 3));
        Average := True
      end;
      AStride := Stride;
      AW := Stride;
      AH := Height;
      if APlane < 0 then
        AData := Reference.Pixels[0]
      else
      begin
        AData := Reference.Half[APlane];
        AStride := Reference.HalfStride;
        AW := AStride;
        AH := Reference.HalfHeight;
        Inc(AX, 3);
        Inc(AY, 3);
      end;
      BStride := Stride;
      BW := Stride;
      BH := Height;
      if BPlane < 0 then
        BData := Reference.Pixels[0]
      else
      begin
        BData := Reference.Half[BPlane];
        BStride := Reference.HalfStride;
        BW := BStride;
        BH := Reference.HalfHeight;
        Inc(BX, 3);
        Inc(BY, 3);
      end;
      N := 0;
      for L := 0 to CH - 1 do
      begin
        RowA := Clamp(AY + L, AH) * AStride;
        RowB := Clamp(BY + L, BH) * BStride;
        if (AX >= 0) and (AX + CW <= AW) and (not Average or ((BX >= 0) and (BX + CW <= BW))) then
        begin
          Inc(RowA, AX);
          Inc(RowB, BX);
          if Average then
            for K := 0 to CW - 1 do
            begin
              Dest[N] := (Integer(AData[RowA + K]) + BData[RowB + K] + 1) shr 1;
              Inc(N)
            end
          else
          begin
            Move(AData[RowA], Dest[N], CW);
            Inc(N, CW)
          end;
        end
        else
          for K := 0 to CW - 1 do
          begin
            if Average then
              Dest[N] := (Integer(AData[RowA + Clamp(AX + K, AW)]) + BData[RowB + Clamp(BX + K, BW)] + 1) shr 1
            else
              Dest[N] := AData[RowA + Clamp(AX + K, AW)];
            Inc(N);
          end;
      end;
    end
    else
    begin
      SX := PX + ASR(Motion.X, 3);
      SY := PY + ASR(Motion.Y, 3);
      FX := Motion.X and 7;
      FY := Motion.Y and 7;
      WA := (8 - FX) * (8 - FY);
      WB := FX * (8 - FY);
      WC := (8 - FX) * FY;
      WD := FX * FY;
      AData := Reference.Pixels[P];
      N := 0;
      for L := 0 to CH - 1 do
      begin
        Y0 := Clamp(SY + L, Height) * Stride;
        Y1 := Clamp(SY + L + 1, Height) * Stride;
        if (SX >= 0) and (SX + CW < Stride) then
        begin
          Inc(Y0, SX);
          Inc(Y1, SX);
          for K := 0 to CW - 1 do
          begin
            Dest[N] := (WA * AData[Y0 + K] + WB * AData[Y0 + K + 1] + WC * AData[Y1 + K] + WD * AData[Y1 + K + 1] + 32) shr 6;
            Inc(N);
          end;
        end
        else
          for K := 0 to CW - 1 do
          begin
            X0 := Clamp(SX + K, Stride);
            X1 := Clamp(SX + K + 1, Stride);
            Dest[N] := (WA * AData[Y0 + X0] + WB * AData[Y0 + X1] + WC * AData[Y1 + X0] + WD * AData[Y1 + X1] + 32) shr 6;
            Inc(N);
          end;
      end;
    end;
  end;

begin
{$IFDEF PLAYER_PROFILE}
  ProfileStart := TStopwatch.GetTimeStamp;
{$ENDIF}
  Ref0 := nil;
  Ref1 := nil;
  if M0.Ref >= 0 then
  begin
    if M0.Ref >= Length(FRefList) then
      raise EPlayerFormat.Create('Missing list0 reference picture');
    Ref0 := FRefList[M0.Ref];
  end;
  if M1.Ref >= 0 then
  begin
    if M1.Ref >= Length(FRefList1) then
      raise EPlayerFormat.Create('Missing list1 reference picture');
    Ref1 := FRefList1[M1.Ref];
  end;
  if (Ref0 = nil) and (Ref1 = nil) then
    raise EPlayerFormat.Create('Inter block uses no reference');
  if (Ref0 <> nil) and ((M0.X or M0.Y) and 3 <> 0) then
    if FUseRegionCache then
      PrepareHalfRegion(Ref0, X, Y, W, H, M0.X, M0.Y)
    else
      PrepareHalfPixels(Ref0);
  if (Ref1 <> nil) and ((M1.X or M1.Y) and 3 <> 0) then
    if FUseRegionCache then
      PrepareHalfRegion(Ref1, X, Y, W, H, M1.X, M1.Y)
    else
      PrepareHalfPixels(Ref1);
  Weight0 := 32;
  Weight1 := 32;
  if (Ref0 <> nil) and (Ref1 <> nil) and not Ref0.LongTerm and not Ref1.LongTerm and (FP.WeightedBiPred = 2) then
  begin
    TD := EnsureRange(Ref1.POC - Ref0.POC, -128, 127);
    if TD <> 0 then
    begin
      TB := EnsureRange(FPOC - Ref0.POC, -128, 127);
      TX := (16384 + Abs(TD) div 2) div TD;
      Scale := ASR(TB * TX + 32, 8);
      if (Scale >= -64) and (Scale <= 128) then
      begin
        Weight1 := Scale;
        Weight0 := 64 - Scale
      end;
    end;
  end;
  for P := 0 to 2 do
  begin
    Stride := FWidth;
    Height := FHeight;
    PX := X;
    PY := Y;
    CW := W;
    CH := H;
    if P > 0 then
    begin
      Stride := Stride div 2;
      Height := Height div 2;
      PX := PX div 2;
      PY := PY div 2;
      CW := CW div 2;
      CH := CH div 2
    end;
    if Ref0 <> nil then
      Predict(M0, Ref0, Prediction0);
    if Ref1 <> nil then
      Predict(M1, Ref1, Prediction1);
    Denom := FWeightDenom[P];
    Rounding := 0;
    if Denom > 0 then
      Rounding := 1 shl (Denom - 1);
    if (Ref1 = nil) and (FWeights[M0.Ref, P].Value = 1 shl Denom) and (FWeights[M0.Ref, P].Offset = 0) then
    begin
      for J := 0 to CH - 1 do
        Move(Prediction0[J * CW], FCurrent.Pixels[P][(PY + J) * Stride + PX], CW);
      Continue;
    end;
    if (Ref0 = nil) and (FWeights1[M1.Ref, P].Value = 1 shl Denom) and (FWeights1[M1.Ref, P].Offset = 0) then
    begin
      for J := 0 to CH - 1 do
        Move(Prediction1[J * CW], FCurrent.Pixels[P][(PY + J) * Stride + PX], CW);
      Continue;
    end;
    if (Ref0 <> nil) and (Ref1 <> nil) and ((FP.WeightedBiPred = 0) or
      ((FP.WeightedBiPred = 2) and (Weight0 = 32) and (Weight1 = 32))) then
    begin
      for J := 0 to CH - 1 do
        for I := 0 to CW - 1 do
          FCurrent.Pixels[P][(PY + J) * Stride + PX + I] := (Integer(Prediction0[J * CW + I]) + Prediction1[J * CW + I] + 1) shr 1;
      Continue;
    end;
    for J := 0 to CH - 1 do
      for I := 0 to CW - 1 do
      begin
        Raw0 := 0;
        Raw1 := 0;
        if Ref0 <> nil then
          Raw0 := Prediction0[J * CW + I];
        if Ref1 <> nil then
          Raw1 := Prediction1[J * CW + I];
        if (Ref0 <> nil) and (Ref1 <> nil) then
        begin
          if FP.WeightedBiPred = 1 then
            V := ASR(Raw0 * FWeights[M0.Ref, P].Value + Raw1 * FWeights1[M1.Ref, P].Value + (1 shl Denom), Denom + 1) +
              ASR(FWeights[M0.Ref, P].Offset + FWeights1[M1.Ref, P].Offset + 1, 1)
          else if FP.WeightedBiPred = 2 then
            V := ASR(Raw0 * Weight0 + Raw1 * Weight1 + 32, 6)
          else
            V := (Raw0 + Raw1 + 1) div 2;
        end
        else if Ref0 <> nil then
          V := ASR(Raw0 * FWeights[M0.Ref, P].Value + Rounding, Denom) + FWeights[M0.Ref, P].Offset
        else
          V := ASR(Raw1 * FWeights1[M1.Ref, P].Value + Rounding, Denom) + FWeights1[M1.Ref, P].Offset;
        FCurrent.Pixels[P][(PY + J) * Stride + PX + I] := ClipByte(V);
      end;
  end;
{$IFDEF PLAYER_PROFILE}
  Inc(H264MotionTicks, TStopwatch.GetTimeStamp - ProfileStart);
{$ENDIF}
end;

function TH264Decoder.CABACBType: Integer;
var
  Context, Bits: Integer;
begin
  Context := 0;
  if (FMB mod FS.MBWidth > 0) and Available(FMB - 1) and not FDirect[FMB - 1] then
    Inc(Context);
  if Available(FMB - FS.MBWidth) and not FDirect[FMB - FS.MBWidth] then
    Inc(Context);
  if FCABAC.Decode(27 + Context) = 0 then
    Exit(0);
  if FCABAC.Decode(30) = 0 then
    Exit(1 + FCABAC.Decode(32));
  Bits := 8 * FCABAC.Decode(31);
  Inc(Bits, 4 * FCABAC.Decode(32));
  Inc(Bits, 2 * FCABAC.Decode(32));
  Inc(Bits, FCABAC.Decode(32));
  if Bits < 8 then
    Result := Bits + 3
  else if Bits = 13 then
    Result := 23 + CABACIntraType(32, False)
  else if Bits = 14 then
    Result := 11
  else if Bits = 15 then
    Result := 22
  else
    Result := 2 * Bits + FCABAC.Decode(32) - 4;
end;

function TH264Decoder.CABACBSubType: Integer;
begin
  if FCABAC.Decode(36) = 0 then
    Exit(0);
  if FCABAC.Decode(37) = 0 then
    Exit(1 + FCABAC.Decode(39));
  Result := 3;
  if FCABAC.Decode(38) <> 0 then
  begin
    if FCABAC.Decode(39) <> 0 then
      Exit(11 + FCABAC.Decode(39));
    Inc(Result, 4);
  end;
  Inc(Result, 2 * FCABAC.Decode(39));
  Inc(Result, FCABAC.Decode(39));
end;

function TH264Decoder.ReadBRef(X, Y, List: Integer): Integer;
var
  Active, C, RA, RB, MB, Index: Integer;

  function Neighbor(Index: Integer): Integer;
  begin
    if List = 0 then
      Result := FCABACRefs[Index]
    else
      Result := FCABACRefs1[Index];
    if FDirectBlocks[Index] then
      Result := -1;
  end;

begin
  Active := FActiveRefs;
  if List = 1 then
    Active := FActiveRefs1;
  Result := 0;
  if Active > 1 then
    if FUseCABAC then
    begin
      RA := 0;
      RB := 0;
      X := X div 4;
      Y := Y div 4;
      if X > 0 then
      begin
        MB := (Y div 4) * FS.MBWidth + (X - 1) div 4;
        Index := Y * FGridWidth + X - 1;
        if (MB = FMB) or Available(MB) then
          RA := Neighbor(Index);
      end;
      if Y > 0 then
      begin
        MB := ((Y - 1) div 4) * FS.MBWidth + X div 4;
        Index := (Y - 1) * FGridWidth + X;
        if (MB = FMB) or Available(MB) then
          RB := Neighbor(Index);
      end;
      C := Ord(RA > 0) + 2 * Ord(RB > 0);
      while FCABAC.Decode(54 + C) <> 0 do
      begin
        Inc(Result);
        C := (C shr 2) + 4;
        if Result >= Active then
          raise EPlayerFormat.Create('Invalid B reference index')
      end;
    end
    else if Active = 2 then
      Result := Ord(not FBits.ReadBit)
    else
      Result := FBits.ReadUE;
  if (Result >= Active) or ((List = 0) and (Result >= Length(FRefList))) or
    ((List = 1) and (Result >= Length(FRefList1))) then
    raise EPlayerFormat.Create('Missing B reference');
end;

procedure TH264Decoder.DirectMotion(out M0, M1: TMotionBlock; PartitionMask: Integer);
var
  X, Y, L, I, CX, CY, ColIndex, R, TD, TB, TX, Scale: Integer;
  Base: array[0..1] of TMotion;
  A, B, C, Col, V0, V1: TMotion;
  RefPic: TPicture;
  Zero: Boolean;

  function Median(A, B, C: Integer): Integer;
  begin
    Result := A + B + C - Min(A, Min(B, C)) - Max(A, Max(B, C))
  end;

begin
  {$IFDEF PLAYER_TEST_STATS}
  Inc(H264TestDirectModes[Ord(FDirectSpatial)]); {$ENDIF}
  if Length(FRefList1) = 0 then
    raise EPlayerFormat.Create('Direct prediction has no collocated picture');
  RefPic := FRefList1[0];
  X := (FMB mod FS.MBWidth) * 4;
  Y := (FMB div FS.MBWidth) * 4;
  for L := 0 to 1 do
  begin
    Base[L] := Default(TMotion);
    Base[L].Ref := -1;
    if not FDirectSpatial then
      Continue;
    A := MotionAt(X - 1, Y, L);
    B := MotionAt(X, Y - 1, L);
    C := MotionAt(X + 4, Y - 1, L);
    if C.Ref = -2 then
      C := MotionAt(X - 1, Y - 1, L);
    R := MaxInt;
    if A.Ref >= 0 then
      R := Min(R, A.Ref);
    if B.Ref >= 0 then
      R := Min(R, B.Ref);
    if C.Ref >= 0 then
      R := Min(R, C.Ref);
    if R = MaxInt then
      Continue;
    Base[L].Ref := R;
    if Ord(A.Ref = R) + Ord(B.Ref = R) + Ord(C.Ref = R) > 1 then
    begin
      Base[L].X := Median(A.X, B.X, C.X);
      Base[L].Y := Median(A.Y, B.Y, C.Y)
    end
    else if A.Ref = R then
      Base[L] := A
    else if B.Ref = R then
      Base[L] := B
    else
      Base[L] := C;
  end;
  if FDirectSpatial and (Base[0].Ref < 0) and (Base[1].Ref < 0) then
  begin
    Base[0].Ref := 0;
    Base[1].Ref := 0
  end;
  for I := 0 to 15 do
  begin
    // Mixed B_8x8 macroblocks use direct inference only in selected 8x8s.
    // Other collocated blocks may legally reference pictures outside list0.
    if PartitionMask and (1 shl (I div 4)) = 0 then
      Continue;
    CX := BlockX[I];
    CY := BlockY[I];
    if FS.Direct8Inference then
    begin
      CX := (CX div 2) * 3;
      CY := (CY div 2) * 3
    end;
    ColIndex := (Y + CY) * FGridWidth + X + CX;
    V0 := Default(TMotion);
    V1 := Default(TMotion);
    V0.Ref := 0;
    V1.Ref := 0;
    if FDirectSpatial then
    begin
      V0 := Base[0];
      V1 := Base[1];
      Zero := False;
      if not RefPic.Intra[FMB] and not RefPic.LongTerm then
      begin
        Col := RefPic.Motion[0][ColIndex];
        if Col.Ref < 0 then
          Col := RefPic.Motion[1][ColIndex];
        Zero := (Col.Ref = 0) and (Abs(Col.X) <= 1) and (Abs(Col.Y) <= 1);
      end;
      if Zero then
      begin
        if V0.Ref = 0 then
        begin
          V0.X := 0;
          V0.Y := 0
        end;
        if V1.Ref = 0 then
        begin
          V1.X := 0;
          V1.Y := 0
        end;
      end;
    end
    else if not RefPic.Intra[FMB] then
    begin
      Col := RefPic.Motion[0][ColIndex];
      if Col.Ref < 0 then
        Col := RefPic.Motion[1][ColIndex];
      R := -1;
      for L := 0 to Min(FActiveRefs, Length(FRefList)) - 1 do
        if FRefList[L].Identity = Col.RefIdentity then
        begin
          R := L;
          Break
        end;
      if R < 0 then
        raise EPlayerFormat.Create('Collocated reference is missing from list0');
      V0.Ref := R;
      TD := EnsureRange(RefPic.POC - FRefList[R].POC, -128, 127);
      Scale := 256;
      if (TD <> 0) and not FRefList[R].LongTerm then
      begin
        TB := EnsureRange(FPOC - FRefList[R].POC, -128, 127);
        TX := (16384 + Abs(TD) div 2) div TD;
        Scale := EnsureRange(ASR(TB * TX + 32, 6), -1024, 1023);
      end;
      V0.X := ASR(Scale * Col.X + 128, 8);
      V0.Y := ASR(Scale * Col.Y + 128, 8);
      V1.X := V0.X - Col.X;
      V1.Y := V0.Y - Col.Y;
    end;
    M0[I] := V0;
    M1[I] := V1;
  end;
end;

procedure TH264Decoder.BMotion(TypeCode, X, Y: Integer; out DCT8Allowed: Boolean);
const
  PairMasks: array[0..8, 0..1] of Integer = ((1, 1), (2, 2), (1, 2), (2, 1), (1, 3), (2, 3), (3, 1), (3, 2), (3, 3));
  SubMasks: array[0..12] of Integer = (3, 1, 2, 3, 1, 1, 2, 2, 3, 3, 1, 2, 3);
type
  TPart = record
    X, Y, W, H, Mask, Group, Partition: Integer;
    Direct: Boolean
  end;
var
  Parts: array[0..15] of TPart;
  Count, I, J, L, R, BX, BY, CX, CY, Index, MB, AX, AY, DX, DY, G, W, H, Mask: Integer;
  Groups: array[0..3] of TPart;
  GroupCount: Integer;
  Refs: array[0..1, 0..3] of Integer;
  Sub: array[0..3] of Integer;
  Direct0, Direct1: TMotionBlock;
  M, D: TMotion;
  HaveDirect: Boolean;

  procedure Add(PX, PY, PW, PH, Dir, Group, Partition: Integer; Direct: Boolean);
  begin
    if Count >= 16 then
      raise EPlayerFormat.Create('Too many B partitions');
    Parts[Count].X := PX;
    Parts[Count].Y := PY;
    Parts[Count].W := PW;
    Parts[Count].H := PH;
    Parts[Count].Mask := Dir;
    Parts[Count].Group := Group;
    Parts[Count].Partition := Partition;
    Parts[Count].Direct := Direct;
    if (PW < 8) or (PH < 8) then
      DCT8Allowed := False;
    HaveDirect := HaveDirect or Direct;
    Inc(Count);
  end;

  procedure CacheRef(PX, PY, PW, PH, List, RefIndex: Integer);
  begin
    for var YY := PY div 4 to (PY + PH) div 4 - 1 do
      for var XX := PX div 4 to (PX + PW) div 4 - 1 do
        if List = 0 then
          FCABACRefs[YY * FGridWidth + XX] := RefIndex
        else
          FCABACRefs1[YY * FGridWidth + XX] := RefIndex;
  end;

  function Difference(Index, List: Integer): TMotion;
  begin
    if List = 0 then
      Result := FDifference[Index]
    else
      Result := FDifference1[Index];
  end;

begin
  Count := 0;
  GroupCount := 0;
  HaveDirect := False;
  DCT8Allowed := FP.Transform8x8Mode;
  {$IFDEF PLAYER_TEST_STATS}   Inc(H264TestBTypes[TypeCode]); {$ENDIF}
  FDirect[FMB] := TypeCode = 0;
  if TypeCode = 0 then
  begin
    if not FS.Direct8Inference then
      DCT8Allowed := False;
    DirectMotion(Direct0, Direct1);
    HaveDirect := True;
    if FS.Direct8Inference then
      for I := 0 to 3 do
        Add(X + (I and 1) * 8, Y + (I div 2) * 8, 8, 8, 3, 0, I, True)
    else
      for I := 0 to 15 do
        Add(X + BlockX[I] * 4, Y + BlockY[I] * 4, 4, 4, 3, 0, I, True);
    // Direct 4x4 processing is only an implementation detail when inference
    // supplies one motion vector for each 8x8 partition.
    DCT8Allowed := FP.Transform8x8Mode and FS.Direct8Inference;
  end
  else if TypeCode in [1, 2, 3] then
  begin
    Add(X, Y, 16, 16, TypeCode, 0, 0, False);
    GroupCount := 1;
    Groups[0] := Parts[0];
  end
  else if TypeCode < 22 then
  begin
    G := (TypeCode - 4) div 2;
    if (G < 0) or (G > 8) then
      raise EPlayerFormat.Create('Invalid B macroblock');
    W := 16;
    H := 8;
    if Odd(TypeCode) then
    begin
      W := 8;
      H := 16
    end;
    Add(X, Y, W, H, PairMasks[G, 0], 0, 0, False);
    Add(X + Ord(W = 8) * 8, Y + Ord(H = 8) * 8, W, H, PairMasks[G, 1], 1, 1, False);
    GroupCount := 2;
    Groups[0] := Parts[0];
    Groups[1] := Parts[1];
  end
  else if TypeCode = 22 then
  begin
    for I := 0 to 3 do
    begin
      if FUseCABAC then
        Sub[I] := CABACBSubType
      else
        Sub[I] := FBits.ReadUE;
      if Sub[I] > 12 then
        raise EPlayerFormat.Create('Invalid B subpartition');
      {$IFDEF PLAYER_TEST_STATS}       Inc(H264TestBSubTypes[Sub[I]]); {$ENDIF}
    end;
    GroupCount := 4;
    for I := 0 to 3 do
    begin
      BX := X + (I and 1) * 8;
      BY := Y + (I div 2) * 8;
      Mask := SubMasks[Sub[I]];
      Groups[I].X := BX;
      Groups[I].Y := BY;
      Groups[I].W := 8;
      Groups[I].H := 8;
      Groups[I].Mask := Mask;
      Groups[I].Direct := Sub[I] = 0;
      if Sub[I] = 0 then
      begin
        if FS.Direct8Inference then
          Add(BX, BY, 8, 8, 3, I, 0, True)
        else
          for J := 0 to 3 do
            Add(BX + BlockX[J] * 4, BY + BlockY[J] * 4, 4, 4, 3, I, J, True);
      end
      else if Sub[I] <= 3 then
        Add(BX, BY, 8, 8, Mask, I, 0, False)
      else if Sub[I] in [4, 6, 8] then
      begin
        Add(BX, BY, 8, 4, Mask, I, 0, False);
        Add(BX, BY + 4, 8, 4, Mask, I, 1, False)
      end
      else if Sub[I] in [5, 7, 9] then
      begin
        Add(BX, BY, 4, 8, Mask, I, 0, False);
        Add(BX + 4, BY, 4, 8, Mask, I, 1, False)
      end
      else
        for J := 0 to 3 do
          Add(BX + BlockX[J] * 4, BY + BlockY[J] * 4, 4, 4, Mask, I, J, False);
    end;
    // Enable 8x8 transform only when every sub-MB is 8x8 or inferred direct8.
    DCT8Allowed := FP.Transform8x8Mode;
    for I := 0 to 3 do
      if (Sub[I] > 3) or ((Sub[I] = 0) and not FS.Direct8Inference) then
        DCT8Allowed := False;
  end
  else
    raise EPlayerFormat.Create('Invalid B macroblock type');
  if HaveDirect and (TypeCode <> 0) then
  begin
    Mask := 0;
    for I := 0 to 3 do
      if Sub[I] = 0 then
        Mask := Mask or (1 shl I);
    DirectMotion(Direct0, Direct1, Mask);
  end;
  for I := 0 to Count - 1 do
    for CY := Parts[I].Y div 4 to (Parts[I].Y + Parts[I].H) div 4 - 1 do
      for CX := Parts[I].X div 4 to (Parts[I].X + Parts[I].W) div 4 - 1 do
        FDirectBlocks[CY * FGridWidth + CX] := Parts[I].Direct;
  for L := 0 to 1 do
    for I := 0 to GroupCount - 1 do
    begin
      R := -1;
      if not Groups[I].Direct and (Groups[I].Mask and (1 shl L) <> 0) then
        R := ReadBRef(Groups[I].X, Groups[I].Y, L);
      Refs[L, I] := R;
      CacheRef(Groups[I].X, Groups[I].Y, Groups[I].W, Groups[I].H, L, R);
    end;
  for L := 0 to 1 do
    for I := 0 to Count - 1 do
    begin
      BX := Parts[I].X div 4;
      BY := Parts[I].Y div 4;
      if Parts[I].Direct then
      begin
        J := ((BY mod 4) div 2) * 8 + ((BX mod 4) div 2) * 4 + (BY mod 2) * 2 + BX mod 2;
        if L = 0 then
          M := Direct0[J]
        else
          M := Direct1[J];
        CacheRef(Parts[I].X, Parts[I].Y, Parts[I].W, Parts[I].H, L, M.Ref);
      end
      else if Parts[I].Mask and (1 shl L) <> 0 then
      begin
        R := Refs[L, Parts[I].Group];
        M := PredictMotion(BX, BY, Parts[I].W, Parts[I].H, R, Parts[I].Partition, L);
        if FUseCABAC then
        begin
          AX := 0;
          AY := 0;
          if BX > 0 then
          begin
            MB := (BY div 4) * FS.MBWidth + (BX - 1) div 4;
            if (MB = FMB) or Available(MB) then
            begin
              D := Difference(BY * FGridWidth + BX - 1, L);
              Inc(AX, D.X);
              Inc(AY, D.Y)
            end;
          end;
          if BY > 0 then
          begin
            MB := ((BY - 1) div 4) * FS.MBWidth + BX div 4;
            if (MB = FMB) or Available(MB) then
            begin
              D := Difference((BY - 1) * FGridWidth + BX, L);
              Inc(AX, D.X);
              Inc(AY, D.Y)
            end;
          end;
          DX := FCABAC.MotionDifference(40, AX);
          DY := FCABAC.MotionDifference(47, AY);
        end
        else
        begin
          DX := FBits.ReadSE;
          DY := FBits.ReadSE
        end;
        for CY := BY to BY + Parts[I].H div 4 - 1 do
          for CX := BX to BX + Parts[I].W div 4 - 1 do
          begin
            Index := CY * FGridWidth + CX;
            if L = 0 then
            begin
              FDifference[Index].X := Min(Abs(DX), 70);
              FDifference[Index].Y := Min(Abs(DY), 70)
            end
            else
            begin
              FDifference1[Index].X := Min(Abs(DX), 70);
              FDifference1[Index].Y := Min(Abs(DY), 70)
            end;
          end;
        Inc(M.X, DX);
        Inc(M.Y, DY);
        if (Abs(M.X) > 32767) or (Abs(M.Y) > 32767) then
          raise EPlayerFormat.Create('Invalid B motion vector');
      end
      else
      begin
        M := Default(TMotion);
        M.Ref := -1
      end;
      StoreMotion(Parts[I].X, Parts[I].Y, Parts[I].W, Parts[I].H, M, L);
    end;
  for I := 0 to Count - 1 do
  begin
    Index := (Parts[I].Y div 4) * FGridWidth + Parts[I].X div 4;
    CompensateBi(Parts[I].X, Parts[I].Y, Parts[I].W, Parts[I].H, FMotion[Index], FMotion1[Index]);
  end;
end;

procedure TH264Decoder.Macroblock(SliceType: Integer; Skip: Boolean);
var
  TypeCode, IntraType, CBP, Mode16, ModeChroma, X, Y, I, J, BX, BY, Pred, Rem, R, Count: Integer;
  DX, DY, AX, AY, Context, K: Integer;
  A, B, M: TMotion;
  Is16, Intra, DCT8Allowed: Boolean;
  PartX, PartY, PartW, PartH, PartRef: array[0..15] of Integer;
  Sub: array[0..3] of Integer;

  procedure AddPart(PX, PY, PW, PH, Ref: Integer);
  begin
    if (PW < 8) or (PH < 8) then
      DCT8Allowed := False;
    if Count >= 16 then
      raise EPlayerFormat.Create('Too many motion partitions');
    PartX[Count] := PX;
    PartY[Count] := PY;
    PartW[Count] := PW;
    PartH[Count] := PH;
    PartRef[Count] := Ref;
    for var CY := PY div 4 to (PY + PH) div 4 - 1 do
      for var CX := PX div 4 to (PX + PW) div 4 - 1 do
        FCABACRefs[CY * FGridWidth + CX] := Ref;
    Inc(Count);
  end;

  function ReadRef(PX, PY: Integer): Integer;
  var
    C, RefA, RefB, MB: Integer;
  begin
    Result := 0;
    if FUseCABAC and (FActiveRefs > 1) then
    begin
      RefA := 0;
      RefB := 0;
      PX := PX div 4;
      PY := PY div 4;
      if PX > 0 then
      begin
        MB := (PY div 4) * FS.MBWidth + (PX - 1) div 4;
        if (MB = FMB) or Available(MB) then
          RefA := FCABACRefs[PY * FGridWidth + PX - 1];
      end;
      if PY > 0 then
      begin
        MB := ((PY - 1) div 4) * FS.MBWidth + PX div 4;
        if (MB = FMB) or Available(MB) then
          RefB := FCABACRefs[(PY - 1) * FGridWidth + PX];
      end;
      C := Ord(RefA > 0) + 2 * Ord(RefB > 0);
      while FCABAC.Decode(54 + C) <> 0 do
      begin
        Inc(Result);
        C := (C shr 2) + 4;
        if Result >= FActiveRefs then
          raise EPlayerFormat.Create('Invalid CABAC reference')
      end;
    end
    else if not FUseCABAC and (FActiveRefs = 2) then
      Result := Ord(not FBits.ReadBit)
    else if FActiveRefs > 2 then
      Result := FBits.ReadUE;
    if Result >= FActiveRefs then
      raise EPlayerFormat.Create('Invalid active reference index');
    if Result >= Length(FRefList) then
      raise EPlayerFormat.Create('Invalid H.264 reference index');
  end;

begin
  if FSlice[FMB] >= 0 then
    raise EPlayerFormat.Create('Overlapping H.264 slices');
  X := (FMB mod FS.MBWidth) * 16;
  Y := (FMB div FS.MBWidth) * 16;
  Mode16 := 0;
  ModeChroma := 0;
  CBP := 0;
  Intra := False;
  Is16 := False;
  DCT8Allowed := FP.Transform8x8Mode;
  FTransform8[FMB] := False;
  FSkipped[FMB] := Skip;
  if SliceType <> 1 then
  begin
    M := Default(TMotion);
    M.Ref := -1;
    StoreMotion(X, Y, 16, 16, M, 1)
  end;
  if Skip then
  begin
    if SliceType = 1 then
      BMotion(0, X, Y, DCT8Allowed)
    else
    begin
      A := MotionAt(X div 4 - 1, Y div 4);
      B := MotionAt(X div 4, Y div 4 - 1);
      M.X := 0;
      M.Y := 0;
      M.Ref := 0;
      if (A.Ref <> -2) and (B.Ref <> -2) and not ((A.Ref = 0) and (A.X = 0) and (A.Y = 0)) and
        not ((B.Ref = 0) and (B.X = 0) and (B.Y = 0)) then
        M := PredictMotion(X div 4, Y div 4, 16, 16, 0, 0);
      StoreMotion(X, Y, 16, 16, M);
      Compensate(X, Y, 16, 16, M);
    end;
  end
  else
  begin
    if FUseCABAC then
    begin
      if SliceType = 2 then
        TypeCode := CABACIntraType(3, True)
      else if SliceType = 1 then
        TypeCode := CABACBType
      else if FCABAC.Decode(14) <> 0 then
        TypeCode := 5 + CABACIntraType(17, False)
      else if FCABAC.Decode(15) = 0 then
        TypeCode := 3 * FCABAC.Decode(16)
      else
        TypeCode := 2 - FCABAC.Decode(17);
    end
    else
      TypeCode := FBits.ReadUE;
    {$IFDEF PLAYER_TRACE}
    Writeln('frame=', FFrameNum, ' mb=', FMB, ' type=', TypeCode, ' qp=', FQP);
    {$ENDIF}
    IntraType := TypeCode;
    if SliceType = 0 then
      Dec(IntraType, 5);
    if SliceType = 1 then
      Dec(IntraType, 23);
    Intra := IntraType >= 0;
    if Intra then
    begin
      if IntraType > 25 then
        raise EPlayerFormat.Create('Invalid intra macroblock');
      if IntraType = 25 then
      begin
        if FUseCABAC then
          raise EPlayerUnsupported.Create('CABAC I_PCM is not implemented yet');
        FBits.Align;
        for J := 0 to 15 do
          for I := 0 to 15 do
            FCurrent.Pixels[0][(Y + J) * FWidth + X + I] := FBits.ReadBits(8);
        for R := 1 to 2 do
          for J := 0 to 7 do
            for I := 0 to 7 do
              FCurrent.Pixels[R][(Y div 2 + J) * (FWidth div 2) + X div 2 + I] := FBits.ReadBits(8);
        FIntra[FMB] := True;
        FSlice[FMB] := FSliceID;
        FQuant[FMB] := 0;
        FFilter[FMB] := FDeblock;
        FFilterAlpha[FMB] := FAlpha;
        FFilterBeta[FMB] := FBeta;
        M.X := 0;
        M.Y := 0;
        M.Ref := -1;
        StoreMotion(X, Y, 16, 16, M);
        StoreMotion(X, Y, 16, 16, M, 1);
        for I := 0 to 15 do
        begin
          BX := X div 4 + BlockX[I];
          BY := Y div 4 + BlockY[I];
          FNonZero[0][BY * FGridWidth + BX] := 16;
          FMode[BY * FGridWidth + BX] := 2
        end;
        for R := 1 to 2 do
          for J := 0 to 1 do
            for I := 0 to 1 do
              FNonZero[R][(Y div 8 + J) * (FGridWidth div 2) + X div 8 + I] := 16;
        Exit;
      end;
      Is16 := IntraType <> 0;
      M.X := 0;
      M.Y := 0;
      M.Ref := -1;
      StoreMotion(X, Y, 16, 16, M);
      StoreMotion(X, Y, 16, 16, M, 1);
      if Is16 then
      begin
        Mode16 := (IntraType - 1) and 3;
        CBP := (((IntraType - 1) div 4) mod 3) * 16;
        if IntraType >= 13 then
          Inc(CBP, 15);
        for I := 0 to 15 do
          FMode[(Y div 4 + BlockY[I]) * FGridWidth + X div 4 + BlockX[I]] := 2;
      end
      else
      begin
        if DCT8Allowed then
          FTransform8[FMB] := ReadTransform8;
        for I := 0 to 15 do
        begin
          if FTransform8[FMB] and (I and 3 <> 0) then
            Continue;
          BX := X div 4 + BlockX[I];
          BY := Y div 4 + BlockY[I];
          A.Ref := -1;
          B.Ref := -1;
          if BX > 0 then
            if (BlockX[I] > 0) or Available(FMB - 1, True) then
              A.Ref := FMode[BY * FGridWidth + BX - 1];
          if BY > 0 then
            if (BlockY[I] > 0) or Available(FMB - FS.MBWidth, True) then
              B.Ref := FMode[(BY - 1) * FGridWidth + BX];
          if (A.Ref < 0) or (B.Ref < 0) then
            Pred := 2
          else
            Pred := Min(A.Ref, B.Ref);
          if FUseCABAC then
          begin
            if FCABAC.Decode(68) <> 0 then
              R := Pred
            else
            begin
              Rem := FCABAC.Decode(69);
              Inc(Rem, 2 * FCABAC.Decode(69));
              Inc(Rem, 4 * FCABAC.Decode(69));
              R := Rem + Ord(Rem >= Pred)
            end;
          end
          else if FBits.ReadBit then
            R := Pred
          else
          begin
            Rem := FBits.ReadBits(3);
            R := Rem + Ord(Rem >= Pred)
          end;
          FMode[BY * FGridWidth + BX] := R;
          if FTransform8[FMB] then
            for J := 1 to 3 do
              FMode[(BY + BlockY[J]) * FGridWidth + BX + BlockX[J]] := R;
        end;
      end;
      if FUseCABAC then
      begin
        Context := 0;
        if (X > 0) and Available(FMB - 1) and (FChromaMode[FMB - 1] <> 0) then
          Inc(Context);
        if Available(FMB - FS.MBWidth) and (FChromaMode[FMB - FS.MBWidth] <> 0) then
          Inc(Context);
        if FCABAC.Decode(64 + Context) = 0 then
          ModeChroma := 0
        else if FCABAC.Decode(67) = 0 then
          ModeChroma := 1
        else if FCABAC.Decode(67) = 0 then
          ModeChroma := 2
        else
          ModeChroma := 3;
      end
      else
        ModeChroma := FBits.ReadUE;
      if ModeChroma > 3 then
        raise EPlayerFormat.Create('Invalid chroma prediction mode');
    end
    else if SliceType = 1 then
      BMotion(TypeCode, X, Y, DCT8Allowed)
    else
    begin
      Count := 0;
      case TypeCode of
        0:
          AddPart(X, Y, 16, 16, ReadRef(X, Y));
        1:
          begin
            R := ReadRef(X, Y);
            AddPart(X, Y, 16, 8, R);
            R := ReadRef(X, Y + 8);
            AddPart(X, Y + 8, 16, 8, R)
          end;
        2:
          begin
            R := ReadRef(X, Y);
            AddPart(X, Y, 8, 16, R);
            R := ReadRef(X + 8, Y);
            AddPart(X + 8, Y, 8, 16, R)
          end;
        3, 4:
          begin
            for I := 0 to 3 do
            begin
              if FUseCABAC then
              begin
                if FCABAC.Decode(21) <> 0 then
                  Sub[I] := 0
                else if FCABAC.Decode(22) = 0 then
                  Sub[I] := 1
                else if FCABAC.Decode(23) <> 0 then
                  Sub[I] := 2
                else
                  Sub[I] := 3;
              end
              else
                Sub[I] := FBits.ReadUE;
              if Sub[I] > 3 then
                raise EPlayerFormat.Create('Invalid P subpartition');
            end;
            for I := 0 to 3 do
            begin
              BX := X + (I and 1) * 8;
              BY := Y + (I div 2) * 8;
              if TypeCode = 4 then
                R := 0
              else
                R := ReadRef(BX, BY);
              case Sub[I] of
                0:
                  AddPart(BX, BY, 8, 8, R);
                1:
                  begin
                    AddPart(BX, BY, 8, 4, R);
                    AddPart(BX, BY + 4, 8, 4, R)
                  end;
                2:
                  begin
                    AddPart(BX, BY, 4, 8, R);
                    AddPart(BX + 4, BY, 4, 8, R)
                  end;
                3:
                  begin
                    AddPart(BX, BY, 4, 4, R);
                    AddPart(BX + 4, BY, 4, 4, R);
                    AddPart(BX, BY + 4, 4, 4, R);
                    AddPart(BX + 4, BY + 4, 4, 4, R)
                  end;
              end;
            end;
          end;
      else
        raise EPlayerFormat.Create('Invalid P macroblock type');
      end;
      for I := 0 to Count - 1 do
      begin
        M := PredictMotion(PartX[I] div 4, PartY[I] div 4, PartW[I], PartH[I], PartRef[I], I);
        if FUseCABAC then
        begin
          BX := PartX[I] div 4;
          BY := PartY[I] div 4;
          AX := 0;
          AY := 0;
          if BX > 0 then
          begin
            K := (BY div 4) * FS.MBWidth + (BX - 1) div 4;
            if (K = FMB) or Available(K) then
            begin
              Inc(AX, FDifference[BY * FGridWidth + BX - 1].X);
              Inc(AY, FDifference[BY * FGridWidth + BX - 1].Y)
            end;
          end;
          if BY > 0 then
          begin
            K := ((BY - 1) div 4) * FS.MBWidth + BX div 4;
            if (K = FMB) or Available(K) then
            begin
              Inc(AX, FDifference[(BY - 1) * FGridWidth + BX].X);
              Inc(AY, FDifference[(BY - 1) * FGridWidth + BX].Y)
            end;
          end;
          DX := FCABAC.MotionDifference(40, AX);
          DY := FCABAC.MotionDifference(47, AY);
          for var CY := BY to BY + PartH[I] div 4 - 1 do
            for var CX := BX to BX + PartW[I] div 4 - 1 do
            begin
              FDifference[CY * FGridWidth + CX].X := Min(Abs(DX), 70);
              FDifference[CY * FGridWidth + CX].Y := Min(Abs(DY), 70)
            end;
        end
        else
        begin
          DX := FBits.ReadSE;
          DY := FBits.ReadSE
        end;
        Inc(M.X, DX);
        Inc(M.Y, DY);
        if (Abs(M.X) > 32767) or (Abs(M.Y) > 32767) then
          raise EPlayerFormat.Create('Invalid motion vector');
        StoreMotion(PartX[I], PartY[I], PartW[I], PartH[I], M);
        Compensate(PartX[I], PartY[I], PartW[I], PartH[I], M);
      end;
    end;
    if not Is16 then
    begin
      if FUseCABAC then
        CBP := CABACPattern
      else
      begin
        R := FBits.ReadUE;
        if R > 47 then
          raise EPlayerFormat.Create('Invalid coded block pattern');
        if Intra then
          CBP := ff_h264_golomb_to_intra4x4_cbp[R]
        else
          CBP := ff_h264_golomb_to_inter_cbp[R];
      end;
    end;
    if DCT8Allowed and not Intra and (CBP and 15 <> 0) then
      FTransform8[FMB] := ReadTransform8;
    if (CBP <> 0) or Is16 then
    begin
      if FUseCABAC then
      begin
        R := 0;
        if FCABAC.Decode(60 + Ord(FLastQPDelta <> 0)) <> 0 then
        begin
          R := 1;
          Context := 62;
          while FCABAC.Decode(Context) <> 0 do
          begin
            Inc(R);
            Context := 63;
            if R > 102 then
              raise EPlayerFormat.Create('CABAC QP delta overflow')
          end;
          if Odd(R) then
            R := (R + 1) div 2
          else
            R := -(R + 1) div 2;
        end;
        FLastQPDelta := R;
      end
      else
      begin
        R := FBits.ReadSE;
        if (R < -26) or (R > 25) then
          raise EPlayerFormat.Create('Invalid macroblock QP delta');
      end;
      FQP := (FQP + R + 52) mod 52;
    end
    else
      FLastQPDelta := 0;
  end;
  FIntra[FMB] := Intra;
  if Skip then
    FLastQPDelta := 0;
  FIs16[FMB] := Is16;
  FPattern[FMB] := CBP;
  FChromaMode[FMB] := ModeChroma;
  Residual(Is16, CBP, Mode16, ModeChroma);
  if not Intra then
    for I := 0 to 15 do
      FMode[(Y div 4 + BlockY[I]) * FGridWidth + X div 4 + BlockX[I]] := 2;
  FSlice[FMB] := FSliceID;
  FQuant[FMB] := FQP;
  FFilter[FMB] := FDeblock;
  FFilterAlpha[FMB] := FAlpha;
  FFilterBeta[FMB] := FBeta;
end;

procedure TH264Decoder.Residual(Intra16: Boolean; CBP, Mode16, ModeChroma: Integer);
var
  X, Y, I, P, BX, BY, N, QP: Integer;
  B, DC: TCoeffBlock;
  ChromaDC: array[1..2] of TCoeffBlock;
  Top, Left, TL, TR: Boolean;
begin
  X := (FMB mod FS.MBWidth) * 16;
  Y := (FMB div FS.MBWidth) * 16;
  Top := (Y > 0) and Available(FMB - FS.MBWidth, True);
  Left := (X > 0) and Available(FMB - 1, True);
  FillChar(DC, SizeOf(DC), 0);
  if Intra16 then
  begin
    PredictLarge(FCurrent.Pixels[0], FWidth, X, Y, 16, Mode16, Top, Left, False);
    ReadBlock(0, X div 4, Y div 4, 0, 16, DC);
    InverseLumaDC(DC, FQP, FP.Scaling.Lists4[0][0]);
  end;
  if FTransform8[FMB] then
    Residual8(CBP)
  else
    for I := 0 to 15 do
    begin
    {$IFDEF PLAYER_TEST_STATS}
      Inc(H264Test4Blocks); {$ENDIF}
      BX := X + BlockX[I] * 4;
      BY := Y + BlockY[I] * 4;
      if FIntra[FMB] and not Intra16 then
      begin
        Top := (BlockY[I] > 0) or ((Y > 0) and Available(FMB - FS.MBWidth, True));
        Left := (BlockX[I] > 0) or ((X > 0) and Available(FMB - 1, True));
        TL := ((BlockX[I] > 0) and (BlockY[I] > 0)) or
          ((BlockX[I] > 0) and Top) or ((BlockY[I] > 0) and Left) or
          ((X > 0) and (Y > 0) and Available(FMB - FS.MBWidth - 1, True));
        TR := False;
        if BY > 0 then
        begin
          if (BX + 4 < FWidth) then
          begin
            N := ((BY - 1) div 16) * FS.MBWidth + (BX + 4) div 16;
            if N = FMB then
              TR := (FNonZero[0][(BY div 4 - 1) * FGridWidth + BX div 4 + 1] >= 0)
            else
              TR := Available(N, True);
          end;
        end;
        Predict4(FCurrent.Pixels[0], FWidth, BX, BY, FMode[(BY div 4) * FGridWidth + BX div 4], Top, Left, TL, TR);
      {$IFDEF PLAYER_TRACE}
        if (FFrameNum = 9) and (FMB = 11) then
          Writeln('block=', I, ' mode=', FMode[(BY div 4) * FGridWidth + BX div 4], ' TR=', TR);
      {$ENDIF}
      end;
      FillChar(B, SizeOf(B), 0);
      N := 0;
      if CBP and (1 shl (I div 4)) <> 0 then
        N := ReadBlock(0, BX div 4, BY div 4, 2 - Ord(Intra16), 16 - Ord(Intra16), B);
      FNonZero[0][(BY div 4) * FGridWidth + BX div 4] := N;
      if Intra16 then
        B[0] := DC[BlockY[I] * 4 + BlockX[I]];
      if (N <> 0) or (Intra16 and (B[0] <> 0)) then
      begin
        Dequantize(B, FQP, Intra16, FP.Scaling.Lists4[3 * Ord(not FIntra[FMB])]);
        Inverse4x4Add(FCurrent.Pixels[0], FWidth, BX, BY, B)
      end;
    end;
  for P := 1 to 2 do
  begin
    Top := (Y > 0) and Available(FMB - FS.MBWidth, True);
    Left := (X > 0) and Available(FMB - 1, True);
    if FIntra[FMB] then
      PredictLarge(FCurrent.Pixels[P], FWidth div 2, X div 2, Y div 2, 8, ModeChroma, Top, Left, True);
    FillChar(ChromaDC[P], SizeOf(TCoeffBlock), 0);
    if CBP shr 4 <> 0 then
    begin
      ReadBlock(P, X div 8, Y div 8, 3, 4, ChromaDC[P]);
      InverseChromaDC(ChromaDC[P], ChromaQP(FQP + ChromaOffset(P)), FP.Scaling.Lists4[P + 3 * Ord(not FIntra[FMB])][0]);
    end;
  end;
  for P := 1 to 2 do
  begin
    QP := ChromaQP(FQP + ChromaOffset(P));
    for I := 0 to 3 do
    begin
      BX := X div 2 + (I and 1) * 4;
      BY := Y div 2 + (I div 2) * 4;
      FillChar(B, SizeOf(B), 0);
      N := 0;
      if CBP shr 4 = 2 then
        N := ReadBlock(P, BX div 4, BY div 4, 4, 15, B);
      FNonZero[P][(BY div 4) * (FGridWidth div 2) + BX div 4] := N;
      B[0] := ChromaDC[P][I];
      if (N <> 0) or (B[0] <> 0) then
      begin
        Dequantize(B, QP, True, FP.Scaling.Lists4[P + 3 * Ord(not FIntra[FMB])]);
        Inverse4x4Add(FCurrent.Pixels[P], FWidth div 2, BX, BY, B);
      end;
    end;
  end;
end;

function TH264Decoder.ChromaOffset(Plane: Integer): Integer;
begin
  if Plane = 2 then
    Result := FP.ChromaQP2
  else
    Result := FP.ChromaQP;
end;

function TH264Decoder.ReadTransform8: Boolean;
var
  Context: Integer;
begin
  if not FUseCABAC then
    Exit(FBits.ReadBit);
  Context := 0;
  if (FMB mod FS.MBWidth > 0) and Available(FMB - 1) and FTransform8[FMB - 1] then
    Inc(Context);
  if Available(FMB - FS.MBWidth) and FTransform8[FMB - FS.MBWidth] then
    Inc(Context);
  Result := FCABAC.Decode(399 + Context) <> 0;
end;

procedure TH264Decoder.Residual8(CBP: Integer);
var
  X, Y, I, J, K, BX, BY, CX, CY, N, MB, Total: Integer;
  B: TCoeffBlock;
  B8: TCoeffBlock8;
  Top, Left, TL, TR: Boolean;
begin
  X := (FMB mod FS.MBWidth) * 16;
  Y := (FMB div FS.MBWidth) * 16;
  for I := 0 to 3 do
  begin
    BX := X + (I and 1) * 8;
    BY := Y + (I div 2) * 8;
    if FIntra[FMB] then
    begin
      {$IFDEF PLAYER_TEST_STATS}
      Inc(H264Test8Modes[FMode[(BY div 4) * FGridWidth + BX div 4]]);
      {$ENDIF}
      Top := (BY > Y) or ((Y > 0) and Available(FMB - FS.MBWidth, True));
      Left := (BX > X) or ((X > 0) and Available(FMB - 1, True));
      TL := ((BX > X) and (BY > Y)) or ((BX > X) and Top) or ((BY > Y) and Left) or
        ((X > 0) and (Y > 0) and Available(FMB - FS.MBWidth - 1, True));
      TR := False;
      if (BY > 0) and (BX + 8 < FWidth) then
      begin
        MB := ((BY - 1) div 16) * FS.MBWidth + (BX + 8) div 16;
        if MB = FMB then
          TR := FNonZero[0][(BY div 4 - 1) * FGridWidth + BX div 4 + 2] >= 0
        else
          TR := Available(MB, True);
      end;
      Predict8(FCurrent.Pixels[0], FWidth, BX, BY, FMode[(BY div 4) * FGridWidth + BX div 4], Top, Left, TL, TR);
    end
    {$IFDEF PLAYER_TEST_STATS}
    else
      Inc(H264Test8Inter) {$ENDIF};
    FillChar(B8, SizeOf(B8), 0);
    N := 0;
    Total := 0;
    if FUseCABAC then
    begin
      if CBP and (1 shl I) <> 0 then
        N := FCABAC.Residual8(B8);
      Total := N;
      for J := 0 to 3 do
        FNonZero[0][(BY div 4 + BlockY[J]) * FGridWidth + BX div 4 + BlockX[J]] := N;
    end
    else
      for J := 0 to 3 do
      begin
        CX := BX div 4 + BlockX[J];
        CY := BY div 4 + BlockY[J];
        N := 0;
        if CBP and (1 shl I) <> 0 then
        begin
          N := DecodeResidual(FBits, NeighborCount(0, CX, CY), 16, B);
          // Four CAVLC streams interleave every fourth position of the 8x8
          // zigzag. Their individual counts remain available for nC.
          for K := 0 to 15 do
            B8[Scan8[4 * K + J]] := B[Scan4[K]];
        end;
        FNonZero[0][CY * FGridWidth + CX] := N;
        Inc(Total, N);
      end;
    if Total <> 0 then
    begin
      Dequantize8(B8, FQP, FP.Scaling.Lists8[Ord(not FIntra[FMB])]);
      Inverse8x8Add(FCurrent.Pixels[0], FWidth, BX, BY, B8)
    end;
  end;
end;

function TH264Decoder.CABACIntraType(Base: Integer; IntraSlice: Boolean): Integer;
var
  Context, Extra: Integer;
begin
  Extra := Ord(IntraSlice);
  Context := 0;
  if IntraSlice then
  begin
    if (FMB mod FS.MBWidth > 0) and Available(FMB - 1) and FIs16[FMB - 1] then
      Inc(Context);
    if Available(FMB - FS.MBWidth) and FIs16[FMB - FS.MBWidth] then
      Inc(Context);
  end;
  if FCABAC.Decode(Base + Context) = 0 then
    Exit(0);
  if IntraSlice then
    Inc(Base, 2);
  if FCABAC.Terminate then
    Exit(25);
  Result := 1 + 12 * FCABAC.Decode(Base + 1);
  if FCABAC.Decode(Base + 2) <> 0 then
    Inc(Result, 4 + 4 * FCABAC.Decode(Base + 2 + Extra));
  Inc(Result, 2 * FCABAC.Decode(Base + 3 + Extra));
  Inc(Result, FCABAC.Decode(Base + 3 + 2 * Extra));
end;

function TH264Decoder.CABACPattern: Integer;
var
  A, B, Context, Chroma: Integer;
begin
  A := 15;
  B := 15;
  if (FMB mod FS.MBWidth > 0) and Available(FMB - 1) then
    A := FPattern[FMB - 1];
  if Available(FMB - FS.MBWidth) then
    B := FPattern[FMB - FS.MBWidth];
  Context := Ord(A and 2 = 0) + 2 * Ord(B and 4 = 0);
  Result := FCABAC.Decode(73 + Context);
  Context := Ord(Result and 1 = 0) + 2 * Ord(B and 8 = 0);
  Inc(Result, 2 * FCABAC.Decode(73 + Context));
  Context := Ord(A and 8 = 0) + 2 * Ord(Result and 1 = 0);
  Inc(Result, 4 * FCABAC.Decode(73 + Context));
  Context := Ord(Result and 4 = 0) + 2 * Ord(Result and 2 = 0);
  Inc(Result, 8 * FCABAC.Decode(73 + Context));
  A := (A shr 4) and 3;
  B := (B shr 4) and 3;
  Context := Ord(A > 0) + 2 * Ord(B > 0);
  Chroma := 0;
  if FCABAC.Decode(77 + Context) <> 0 then
    Chroma := 1 + FCABAC.Decode(81 + Ord(A = 2) + 2 * Ord(B = 2));
  Inc(Result, Chroma * 16);
end;

function TH264Decoder.ReadBlock(Plane, X, Y, Category, MaxCoeff: Integer; out Block: TCoeffBlock): Integer;
const
  CBFBase: array[0..4] of Integer = (85, 89, 93, 97, 101);
var
  A, B, W, MB, Mask: Integer;
begin
  if not FUseCABAC then
    Exit(DecodeResidual(FBits, NeighborCount(Plane, X, Y), MaxCoeff, Block));
  A := Ord(FIntra[FMB]);
  B := A;
  Mask := 0;
  if Category in [0, 3] then
  begin
    if Category = 0 then
      Mask := $100
    else
      Mask := $40 shl (Plane - 1);
    if (FMB mod FS.MBWidth > 0) and Available(FMB - 1) then
      A := Ord(FPattern[FMB - 1] and Mask <> 0);
    if Available(FMB - FS.MBWidth) then
      B := Ord(FPattern[FMB - FS.MBWidth] and Mask <> 0);
  end
  else
  begin
    W := FGridWidth;
    if Plane > 0 then
      W := W div 2;
    if X > 0 then
    begin
      if Plane = 0 then
        MB := (Y div 4) * FS.MBWidth + (X - 1) div 4
      else
        MB := (Y div 2) * FS.MBWidth + (X - 1) div 2;
      if (MB = FMB) or Available(MB) then
        A := Ord(FNonZero[Plane][Y * W + X - 1] > 0);
    end;
    if Y > 0 then
    begin
      if Plane = 0 then
        MB := ((Y - 1) div 4) * FS.MBWidth + X div 4
      else
        MB := ((Y - 1) div 2) * FS.MBWidth + X div 2;
      if (MB = FMB) or Available(MB) then
        B := Ord(FNonZero[Plane][(Y - 1) * W + X] > 0);
    end;
  end;
  Result := FCABAC.Residual(Category, MaxCoeff, CBFBase[Category] + A + 2 * B, Block);
  if (Result > 0) and (Mask <> 0) then
    FPattern[FMB] := FPattern[FMB] or Mask;
end;

procedure TH264Decoder.DeblockPicture;
{$IFDEF PLAYER_PROFILE}
var
  ProfileStart: Int64;
{$ENDIF}
var
  MB, MX, MY, Direction, Edge, Segment, Plane, Neighbor, QP, A, B, Strength: Integer;
  GX, GY, OtherX, OtherY, IndexP, IndexQ, Position, Stride, Step, LineStep, J, TC: Integer;
  IntraEdge: Boolean;
  AlphaIndex, Alphas, Betas: array[0..2] of Integer;

  function SameMotion(const A, B: TMotion): Boolean;
  begin
    Result := (A.RefIdentity = B.RefIdentity) and ((A.RefIdentity = 0) or
      ((Abs(A.X - B.X) < 4) and (Abs(A.Y - B.Y) < 4)));
  end;

  function MotionBoundary(P, Q: Integer): Boolean;
  begin
    if not FHasBiPrediction then
      Exit(not SameMotion(FMotion[P], FMotion[Q]));
    Result := not ((SameMotion(FMotion[P], FMotion[Q]) and SameMotion(FMotion1[P], FMotion1[Q])) or
      (SameMotion(FMotion[P], FMotion1[Q]) and SameMotion(FMotion1[P], FMotion[Q])));
  end;

  procedure Filter(var Pixels: TBytes; Pos, Step, BS, Alpha, Beta, TC0: Integer; Chroma: Boolean);
  var
    P0, P1, P2, P3, Q0, Q1, Q2, Q3, D, T, AP, AQ: Integer;
  begin
    P0 := Pixels[Pos - Step];
    P1 := Pixels[Pos - 2 * Step];
    P2 := Pixels[Pos - 3 * Step];
    Q0 := Pixels[Pos];
    Q1 := Pixels[Pos + Step];
    Q2 := Pixels[Pos + 2 * Step];
    if (Abs(P0 - Q0) >= Alpha) or (Abs(P1 - P0) >= Beta) or (Abs(Q1 - Q0) >= Beta) then
      Exit;
    if BS = 4 then
    begin
      if Chroma then
      begin
        Pixels[Pos - Step] := (2 * P1 + P0 + Q1 + 2) div 4;
        Pixels[Pos] := (2 * Q1 + Q0 + P1 + 2) div 4;
      end
      else
      begin
        AP := Ord((Abs(P0 - Q0) < Alpha div 4 + 2) and (Abs(P2 - P0) < Beta));
        AQ := Ord((Abs(P0 - Q0) < Alpha div 4 + 2) and (Abs(Q2 - Q0) < Beta));
        if AP <> 0 then
        begin
          P3 := Pixels[Pos - 4 * Step];
          Pixels[Pos - Step] := (P2 + 2 * P1 + 2 * P0 + 2 * Q0 + Q1 + 4) div 8;
          Pixels[Pos - 2 * Step] := (P2 + P1 + P0 + Q0 + 2) div 4;
          Pixels[Pos - 3 * Step] := (2 * P3 + 3 * P2 + P1 + P0 + Q0 + 4) div 8;
        end
        else
          Pixels[Pos - Step] := (2 * P1 + P0 + Q1 + 2) div 4;
        if AQ <> 0 then
        begin
          Q3 := Pixels[Pos + 3 * Step];
          Pixels[Pos] := (P1 + 2 * P0 + 2 * Q0 + 2 * Q1 + Q2 + 4) div 8;
          Pixels[Pos + Step] := (P0 + Q0 + Q1 + Q2 + 2) div 4;
          Pixels[Pos + 2 * Step] := (2 * Q3 + 3 * Q2 + Q1 + Q0 + P0 + 4) div 8;
        end
        else
          Pixels[Pos] := (2 * Q1 + Q0 + P1 + 2) div 4;
      end;
    end
    else
    begin
      AP := Ord(not Chroma and (Abs(P2 - P0) < Beta));
      AQ := Ord(not Chroma and (Abs(Q2 - Q0) < Beta));
      T := TC0 + AP + AQ + Ord(Chroma);
      D := EnsureRange(ASR(4 * (Q0 - P0) + P1 - Q1 + 4, 3), -T, T);
      Pixels[Pos - Step] := ClipByte(P0 + D);
      Pixels[Pos] := ClipByte(Q0 - D);
      if AP <> 0 then
        Pixels[Pos - 2 * Step] := ClipByte(P1 + EnsureRange(ASR(P2 + (P0 + Q0 + 1) div 2 - 2 * P1, 1), -TC0, TC0));
      if AQ <> 0 then
        Pixels[Pos + Step] := ClipByte(Q1 + EnsureRange(ASR(Q2 + (P0 + Q0 + 1) div 2 - 2 * Q1, 1), -TC0, TC0));
    end;
  end;

begin
{$IFDEF PLAYER_PROFILE}
  ProfileStart := TStopwatch.GetTimeStamp;
{$ENDIF}
  // CAVLC nC needs the four individual counts until all slices are decoded.
  // Deblocking instead tests whether any coefficient in the 8x8 is nonzero.
  for MB := 0 to Length(FSlice) - 1 do
    if FTransform8[MB] then
      for Edge := 0 to 3 do
      begin
        GX := (MB mod FS.MBWidth) * 4 + (Edge and 1) * 2;
        GY := (MB div FS.MBWidth) * 4 + (Edge div 2) * 2;
        IndexQ := GY * FGridWidth + GX;
        Strength := FNonZero[0][IndexQ] + FNonZero[0][IndexQ + 1] +
          FNonZero[0][IndexQ + FGridWidth] + FNonZero[0][IndexQ + FGridWidth + 1];
        FNonZero[0][IndexQ] := Strength;
        FNonZero[0][IndexQ + 1] := Strength;
        FNonZero[0][IndexQ + FGridWidth] := Strength;
        FNonZero[0][IndexQ + FGridWidth + 1] := Strength;
      end;
  for MB := 0 to Length(FSlice) - 1 do
  begin
    if FFilter[MB] = 1 then
      Continue;
    MX := MB mod FS.MBWidth;
    MY := MB div FS.MBWidth;
    for Direction := 0 to 1 do
      for Edge := 0 to 3 do
      begin
        if FTransform8[MB] and Odd(Edge) then
          Continue;
        Neighbor := MB;
        if Edge = 0 then
        begin
          if Direction = 0 then
          begin
            if MX = 0 then
              Continue;
            Neighbor := MB - 1
          end
          else
          begin
            if MY = 0 then
              Continue;
            Neighbor := MB - FS.MBWidth
          end;
          if (FFilter[MB] = 2) and (FSlice[Neighbor] <> FSlice[MB]) then
            Continue;
        end;
        IntraEdge := FIntra[MB] or FIntra[Neighbor];
        // Thresholds are identical for all four segments of this edge.
        for Plane := 0 to 2 do
        begin
          QP := FQuant[MB];
          J := FQuant[Neighbor];
          if Plane > 0 then
          begin
            QP := ChromaQP(QP + ChromaOffset(Plane));
            J := ChromaQP(J + ChromaOffset(Plane))
          end;
          QP := (QP + J + 1) div 2;
          AlphaIndex[Plane] := EnsureRange(QP + FFilterAlpha[MB], 0, 51) + 52;
          Alphas[Plane] := alpha_table[AlphaIndex[Plane]];
          Betas[Plane] := beta_table[EnsureRange(QP + FFilterBeta[MB], 0, 51) + 52];
        end;
        for Segment := 0 to 3 do
        begin
          if Direction = 0 then
          begin
            GX := MX * 4 + Edge;
            GY := MY * 4 + Segment;
            OtherX := GX - 1;
            OtherY := GY
          end
          else
          begin
            GX := MX * 4 + Segment;
            GY := MY * 4 + Edge;
            OtherX := GX;
            OtherY := GY - 1
          end;
          IndexP := OtherY * FGridWidth + OtherX;
          IndexQ := GY * FGridWidth + GX;
          Strength := 0;
          if IntraEdge then
            Strength := 3 + Ord(Edge = 0)
          else if (FNonZero[0][IndexP] > 0) or (FNonZero[0][IndexQ] > 0) then
            Strength := 2
          else
          begin
            if MotionBoundary(IndexP, IndexQ) then
              Strength := 1;
          end;
          if Strength = 0 then
            Continue;
          for Plane := 0 to 2 do
          begin
            if (Plane > 0) and Odd(Edge) then
              Continue;
            A := Alphas[Plane];
            B := Betas[Plane];
            if (A = 0) or (B = 0) then
              Continue;
            TC := 0;
            if Strength < 4 then
              TC := tc0_table[AlphaIndex[Plane]][Strength];
            Stride := FWidth;
            Position := GY * 4 * Stride + GX * 4;
            if Plane > 0 then
            begin
              Stride := Stride div 2;
              Position := GY * 2 * Stride + GX * 2
            end;
            if Direction = 0 then
            begin
              Step := 1;
              LineStep := Stride
            end
            else
            begin
              Step := Stride;
              LineStep := 1
            end;
            for J := 0 to (4 shr Ord(Plane > 0)) - 1 do
              Filter(FCurrent.Pixels[Plane], Position + J * LineStep, Step, Strength, A, B, TC, Plane > 0);
          end;
        end;
      end;
  end;
{$IFDEF PLAYER_PROFILE}
  Inc(H264DeblockTicks, TStopwatch.GetTimeStamp - ProfileStart);
{$ENDIF}
end;

end.

