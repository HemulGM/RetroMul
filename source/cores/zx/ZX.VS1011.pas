unit ZX.VS1011;

interface

uses
  System.SysUtils, Core.Snapshots, Audio.MP3.Types, Audio.MP3.Layer3;

type
  TVS1011Sample = record
    L, R: SmallInt;
    Rate: Integer;
  end;
  // VS1011e MPEG Layer III/SCI profile. No host media API or binary codec.

  TZXVS1011 = class
  private
    FDecoder: TMP3Layer3Decoder;
    FRegs: array[0..15] of Word;
    FRAM: array[0..65535] of Word;
    FInput: array[0..2047] of Byte;
    FInputCount, FNeeded: Integer;
    FReservoir: TBytes;
    FPCM: array[0..4095] of TVS1011Sample;
    FRead, FCount, FRate: Integer;
    FPhase, FTimePhase: UInt64;
    FReset, FSelected, FMemoryTest: Boolean;
    FBusy, FSciPosition: Integer;
    FSciCommand, FSciRegister, FSciHigh: Byte;
    FSciRead: Word;
    FOutL, FOutR: Double;
    FLowL, FLowR, FHighL, FHighR: Double;
    FGain: array[0..255] of Double;
    FTest: array[0..7] of Byte;
    FTestCount, FSine, FSinePhase: Integer;
    FLastHeader: array[0..3] of Byte;
    function DSPClocks(Cycles: Integer; Crystal: Boolean = False): Integer;
    procedure ResetStream;
    procedure TryDecode;
    procedure ConsumeInput(Count: Integer);
    procedure WriteRegister(Index: Byte; Value: Word);
    function ReadRegister(Index: Byte): Word;
    procedure TestByte(Value: Byte);
    procedure OutputSample(L, R: Double; Rate: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure SetReset(Released: Boolean);
    procedure Select(Active: Boolean);
    function Control(Value: Byte): Byte;
    procedure Data(Value: Byte);
    procedure Advance(Osc24: Integer);
    function DREQ: Boolean;
    procedure Levels(out Left, Right: Double);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes, System.Math, Audio.MP3.Frame, Audio.MP3.BitStream;

constructor TZXVS1011.Create;
begin
  inherited;
  for var I := 0 to 253 do
    FGain[I] := Power(10, -I / 40.0);
  FGain[254] := 0;
  FGain[255] := 0;
  FDecoder := TMP3Layer3Decoder.Create;
  Reset;
end;

destructor TZXVS1011.Destroy;
begin
  FDecoder.Free;
  inherited;
end;

function TZXVS1011.DSPClocks(Cycles: Integer; Crystal: Boolean): Integer;
begin
  var Frequency := 12288000;
  if not Crystal and ((FRegs[3] and $8000) <> 0) then
    Frequency := Frequency * 2;
  Result := (Int64(Cycles) * 24000000 + Frequency - 1) div Frequency;
end;

procedure TZXVS1011.ResetStream;
begin
  FDecoder.Free;
  FDecoder := TMP3Layer3Decoder.Create;
  FReservoir := nil;
  FInputCount := 0;
  FNeeded := 4;
  FRead := 0;
  FCount := 0;
  FRate := 0;
  FPhase := 0;
  FOutL := 0;
  FOutR := 0;
  FLowL := 0;
  FLowR := 0;
  FHighL := 0;
  FHighR := 0;
  FMemoryTest := False;
  FTestCount := 0;
  FSine := -1;
  FSinePhase := 0;
  FillChar(FLastHeader, SizeOf(FLastHeader), 0);
end;

procedure TZXVS1011.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FRegs[1] := $20;
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FInput, SizeOf(FInput), 0);
  FillChar(FPCM, SizeOf(FPCM), 0);
  FillChar(FTest, SizeOf(FTest), 0);
  FReset := True;
  FSelected := False;
  FBusy := 0;
  FSciPosition := 0;
  FSciCommand := 0;
  FSciRegister := 0;
  FSciHigh := 0;
  FSciRead := 0;
  FTimePhase := 0;
  ResetStream;
end;

procedure TZXVS1011.SetReset(Released: Boolean);
begin
  if not Released then
  begin
    if not FReset then
      Reset;
    FReset := True;
  end
  else if FReset then
  begin
    FReset := False;
    FBusy := DSPClocks(9600, True);
  end;
end;

procedure TZXVS1011.Select(Active: Boolean);
begin
  if Active <> FSelected then
    FSciPosition := 0;
  FSelected := Active;
end;

function TZXVS1011.DREQ: Boolean;
begin
  Result := not FReset and (FBusy = 0) and (FInputCount <= Length(FInput) - 32);
end;

function TZXVS1011.ReadRegister(Index: Byte): Word;
begin
  Result := FRegs[Index];
  if Index = 6 then
  begin
    Result := FRAM[FRegs[7]];
    FRegs[7] := (Integer(FRegs[7]) + 1) and $FFFF;
  end;
end;

procedure TZXVS1011.WriteRegister(Index: Byte; Value: Word);
const
  BusyTimes: array[0..15] of Integer = (70, 40, 2100, 80, 40, 3200, 80, 80, 0, 0, 3200, 2100, 50, 50, 50, 50);
begin
  if Index in [8, 9] then
    Exit;
  if (Index = 0) and ((Value and 4) <> 0) then
  begin
    ResetStream;
    FRegs[4] := 0;
    FTimePhase := 0;
    FRegs[8] := 0;
    FRegs[9] := 0;
    FRegs[5] := 0;
    FRegs[0] := Value and $FFFB;
    FBusy := DSPClocks(9600, True);
    Exit;
  end;
  if Index = 1 then
    Value := (Value and $F) or $20;
  FRegs[Index] := Value;
  if Index = 4 then
    FTimePhase := 0;
  if Index = 6 then
  begin
    FRAM[FRegs[7]] := Value;
    FRegs[7] := (Integer(FRegs[7]) + 1) and $FFFF;
  end;
  FBusy := DSPClocks(BusyTimes[Index], Index = 3);
end;

function TZXVS1011.Control(Value: Byte): Byte;
begin
  Result := $FF;
  if FReset or not FSelected then
    Exit;
  case FSciPosition of
    0:
      FSciCommand := Value;
    1:
      begin
        FSciRegister := Value and 15;
        if (Value > 15) or not (FSciCommand in [2, 3]) then
        begin
          FSciPosition := 0;
          Exit;
        end;
        if FSciCommand = 3 then
          FSciRead := ReadRegister(FSciRegister);
      end;
    2:
      begin
        if FSciCommand = 3 then
          Result := FSciRead shr 8
        else
          FSciHigh := Value;
      end;
    3:
      begin
        if FSciCommand = 3 then
        begin
          Result := FSciRead and 255;
          FBusy := DSPClocks(40);
        end
        else if FSciCommand = 2 then
          WriteRegister(FSciRegister, (Word(FSciHigh) shl 8) or Value);
      end;
  end;
  FSciPosition := (FSciPosition + 1) and 3;
end;

procedure TZXVS1011.ConsumeInput(Count: Integer);
begin
  Dec(FInputCount, Count);
  if FInputCount > 0 then
    Move(FInput[Count], FInput[0], FInputCount);
  FNeeded := 4;
end;

procedure TZXVS1011.TryDecode;
begin
  while (FInputCount >= FNeeded) and (FCount <= Length(FPCM) - 1152) do
  begin
    if not hdr_valid(@FInput[0]) or ((FInput[1] and $18) = $08) or ((FInput[1] and 6) <> 2) then
    begin
      ConsumeInput(1);
      Continue;
    end;
    var FrameSize := hdr_frame_bytes(@FInput[0], 0) + hdr_padding(@FInput[0]);
    if (FrameSize < 24) or (FrameSize > Length(FInput)) then
    begin
      ConsumeInput(1);
      Continue;
    end;
    FNeeded := FrameSize;
    if FInputCount < FrameSize then
      Exit;
    var Bytes: TBytes;
    SetLength(Bytes, FrameSize);
    Move(FInput[0], Bytes[0], FrameSize);
    var Stream := TBytesStream.Create(Bytes);
    var Header: TMP3FrameHeader;
    try
      if not TMP3FrameParser.ParseHeader(Stream, Header) then
      begin
        ConsumeInput(1);
        Continue;
      end;
      if HDR_IS_CRC(Header.hdr) then
        Stream.Position := Stream.Position + 2;
      var SideSize := TMP3FrameParser.SideInfoSize(Header);
      var SideBytes: TBytes;
      SetLength(SideBytes, SideSize);
      Stream.ReadBuffer(SideBytes[0], SideSize);
      var Side: TMP3SideInfo;
      var Bits := TMP3BitStream.Create(SideBytes);
      var Valid: Boolean;
      try
        Valid := TMP3FrameParser.ParseSideInfo(Bits, Header, Side);
      finally
        Bits.Free;
      end;
      if not Valid then
      begin
        ConsumeInput(FrameSize);
        Continue;
      end;
      if (FLastHeader[0] <> 0) and (((FLastHeader[1] xor Header.hdr[1]) and $FE <> 0) or
        ((FLastHeader[2] xor Header.hdr[2]) and $0C <> 0)) then
      begin
        FReservoir := nil;
        FDecoder.Free;
        FDecoder := TMP3Layer3Decoder.Create;
      end;
      Move(Header.hdr, FLastHeader, 4);
      var Main := Copy(Bytes, Integer(Stream.Position), FrameSize - Integer(Stream.Position));
      var Sum := 0;
      for var G := 0 to Ord(HDR_TEST_MPEG1(Header.hdr)) do
        for var Ch := 0 to Header.Channels - 1 do
          Inc(Sum, Side.Granules[G, Ch].Part2_3_Length);
      if (Side.MainDataBegin <= Length(FReservoir)) and (Sum <= (Side.MainDataBegin + Length(Main)) * 8) then
      begin
        var Input := Copy(FReservoir, Length(FReservoir) - Side.MainDataBegin, Side.MainDataBegin) + Main;
    // Huffman lookahead has guard bytes; side-info bit lengths are validated above.
        SetLength(Input, Length(Input) + 16);
        var L, R: TArray<Single>;
        try
          FDecoder.DecodeFrame(Header, Side, Input, 0, L, R);
          for var I := 0 to High(L) do
          begin
            var Index := (FRead + FCount) mod Length(FPCM);
            FPCM[Index].L := EnsureRange(Round(L[I] * 32768), -32768, 32767);
            FPCM[Index].R := EnsureRange(Round(R[I] * 32768), -32768, 32767);
            FPCM[Index].Rate := Header.SampleRate;
            Inc(FCount);
          end;
          FRegs[8] := (Word(Header.hdr[2]) shl 8) or Header.hdr[3];
          FRegs[9] := (Word(Header.hdr[0]) shl 8) or Header.hdr[1];
          FRegs[5] := (Header.SampleRate and $FFFE) or Ord(Header.Channels = 2);
        except
          on E: EReadError do
          begin
            FDecoder.Free;
            FDecoder := TMP3Layer3Decoder.Create;
          end;
          on E: EMathError do
          begin
            FDecoder.Free;
            FDecoder := TMP3Layer3Decoder.Create;
          end;
          on E: ERangeError do
          begin
            FDecoder.Free;
            FDecoder := TMP3Layer3Decoder.Create;
          end;
          on E: EIntError do
          begin
            FDecoder.Free;
            FDecoder := TMP3Layer3Decoder.Create;
          end;
        end;
      end;
      FReservoir := FReservoir + Main;
      if Length(FReservoir) > 511 then
        FReservoir := Copy(FReservoir, Length(FReservoir) - 511, 511);
    finally
      Stream.Free;
    end;
    ConsumeInput(FrameSize);
  end;
end;

procedure TZXVS1011.TestByte(Value: Byte);
const
  Rates: array[0..7] of Integer = (44100, 48000, 32000, 22050, 24000, 16000, 11025, 12000);
begin
  FTest[FTestCount] := Value;
  Inc(FTestCount);
  if FTestCount <> 8 then
    Exit;
  FTestCount := 0;
  if (FTest[0] = $53) and (FTest[1] = $EF) and (FTest[2] = $6E) then
  begin
    FSine := FTest[3] and 31;
    FRate := Rates[FTest[3] shr 5];
    FSinePhase := 0;
  end
  else if (FTest[0] = $45) and (FTest[1] = $78) and (FTest[2] = $69) and (FTest[3] = $74) then
  begin
    FSine := -1;
    FOutL := 0;
    FOutR := 0;
  end
  else if (FTest[0] = $4D) and (FTest[1] = $EA) and (FTest[2] = $6D) and (FTest[3] = $54) then
  begin
    FillChar(FRAM, SizeOf(FRAM), 0);
    FRegs[8] := 0;
    FMemoryTest := True;
    FBusy := DSPClocks(200000);
  end
  else if (FTest[0] = $53) and (FTest[1] = $70) and (FTest[2] = $EE) then
  begin
    var N := FTest[3] and 15;
    if N = 8 then
      FRegs[9] := FRegs[N]
    else
      FRegs[8] := FRegs[N];
  end;
end;

procedure TZXVS1011.Data(Value: Byte);
begin
  if FReset then
    Exit;
  if (FRegs[0] and $200) <> 0 then
  begin
    var R: Byte := 0;
    for var I := 0 to 7 do
    begin
      R := (Integer(R) shl 1) or (Value and 1);
      Value := Value shr 1;
    end;
    Value := R;
  end;
  if (FRegs[0] and $20) <> 0 then
  begin
    TestByte(Value);
    Exit;
  end;
  if FInputCount = Length(FInput) then
    Exit;
  FInput[FInputCount] := Value;
  Inc(FInputCount);
  if FInputCount >= FNeeded then
    TryDecode;
end;

procedure TZXVS1011.OutputSample(L, R: Double; Rate: Integer);
begin
  var Bass := FRegs[2];
  var BGain := Power(10, ((Bass shr 4) and 15) / 20.0) - 1;
  var Treble := Integer(Bass shr 12);
  if Treble >= 8 then
    Dec(Treble, 16);
  var TGain := Power(10, Treble * 1.5 / 20.0) - 1;
  var A := 1 - Exp(-2 * Pi * Max(20, Byte(Bass and 15) * 10) / Rate);
  var B := 1 - Exp(-2 * Pi * Min(Rate * 0.45, Max(1000, ((Bass shr 8) and 15) * 1000)) / Rate);
  FLowL := FLowL + A * (L - FLowL);
  FLowR := FLowR + A * (R - FLowR);
  FHighL := FHighL + B * (L - FHighL);
  FHighR := FHighR + B * (R - FHighR);
  FOutL := EnsureRange(L + FLowL * BGain + (L - FHighL) * TGain, -1.0, 1.0);
  FOutR := EnsureRange(R + FLowR * BGain + (R - FHighR) * TGain, -1.0, 1.0);
end;

procedure TZXVS1011.Advance(Osc24: Integer);
begin
  if FReset then
    Exit;
  if FBusy > 0 then
    FBusy := Max(0, FBusy - Osc24);
  if FMemoryTest and (FBusy = 0) then
  begin
    FMemoryTest := False;
    FRegs[8] := $807F;
  end;
  if (FCount = 0) and (FSine < 0) then
  begin
    FOutL := 0;
    FOutR := 0;
    FPhase := 0;
    Exit;
  end;
  var Rate := FRate;
  if FCount > 0 then
    Rate := FPCM[FRead].Rate;
  if Rate = 0 then
    Exit;
  var Declared := Integer(FRegs[3] and $7FFF) * 2000;
  if Declared = 0 then
    Declared := 24576000;
  Rate := EnsureRange(Integer(Int64(Rate) * 12288000 div Declared), 1, 96000);
  Inc(FPhase, UInt64(Osc24) * Cardinal(Rate));
  while FPhase >= 24000000 do
  begin
    Dec(FPhase, 24000000);
    if FSine >= 0 then
    begin
      FSinePhase := (FSinePhase + FSine) and 127;
      var V := Sin(FSinePhase * 2 * Pi / 128) * 0.5;
      OutputSample(V, V, Rate);
    end
    else if FCount > 0 then
    begin
      OutputSample(FPCM[FRead].L / 32768.0, FPCM[FRead].R / 32768.0, Rate);
      FRead := (FRead + 1) mod Length(FPCM);
      Dec(FCount);
    end
    else
    begin
      FOutL := 0;
      FOutR := 0;
      FPhase := 0;
      Break;
    end;
  end;
  Inc(FTimePhase, Cardinal(Osc24));
  while FTimePhase >= 24000000 do
  begin
    Dec(FTimePhase, 24000000);
    FRegs[4] := (Integer(FRegs[4]) + 1) and $FFFF;
  end;
  if (FInputCount >= FNeeded) and (FCount <= Length(FPCM) - 1152) then
    TryDecode;
end;

procedure TZXVS1011.Levels(out Left, Right: Double);
begin
  Left := 0;
  Right := 0;
  if FReset or ((FRegs[1] and $C) <> 0) then
    Exit;
  var AnalogGain := 1.0;
  if (FRegs[1] and 3) = 1 then
    AnalogGain := 0.5
  else if (FRegs[1] and 3) = 3 then
    AnalogGain := 0.25;
  Left := FOutL * FGain[FRegs[11] shr 8] * AnalogGain * 0.25;
  Right := FOutR * FGain[FRegs[11] and 255] * AnalogGain * 0.25;
  if (FRegs[0] and 1) <> 0 then
    Left := -Left;
end;

procedure TZXVS1011.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FInput, SizeOf(FInput));
  State.Field(FInputCount, 4);
  State.Field(FNeeded, 4);
  var N := Length(FReservoir);
  State.Field(N, 4);
  if (N < 0) or (N > 511) then
    raise EReadError.Create('Invalid MP3 reservoir');
  if State.Loading then
    SetLength(FReservoir, N);
  if N > 0 then
    State.Field(FReservoir[0], N);
  State.Field(FPCM, SizeOf(FPCM));
  State.Field(FRead, 4);
  State.Field(FCount, 4);
  State.Field(FRate, 4);
  State.Field(FPhase, 8);
  State.Field(FTimePhase, 8);
  State.Field(FReset, SizeOf(FReset));
  State.Field(FSelected, SizeOf(FSelected));
  State.Field(FMemoryTest, SizeOf(FMemoryTest));
  State.Field(FBusy, 4);
  State.Field(FSciPosition, 4);
  State.Field(FSciCommand, 1);
  State.Field(FSciRegister, 1);
  State.Field(FSciHigh, 1);
  State.Field(FSciRead, 2);
  State.Field(FOutL, 8);
  State.Field(FOutR, 8);
  State.Field(FLowL, 8);
  State.Field(FLowR, 8);
  State.Field(FHighL, 8);
  State.Field(FHighR, 8);
  State.Field(FTest, SizeOf(FTest));
  State.Field(FTestCount, 4);
  State.Field(FSine, 4);
  State.Field(FSinePhase, 4);
  State.Field(FLastHeader, 4);
  FDecoder.SerializeState(State);
  if (FInputCount < 0) or (FInputCount > 2048) or (FNeeded < 4) or (FNeeded > 2048) or (FRead < 0) or (FRead > 4095) or
    (FCount < 0) or (FCount > 4096) or (FRate < 0) or (FRate > 48000) or (FPhase >= 24000000) or (FTimePhase >= 24000000) or
    (FBusy < 0) or (FBusy > 400000) or (FSciPosition < 0) or (FSciPosition > 3) or (FSciRegister > 15) or
    (FTestCount < 0) or (FTestCount > 7) or (FSine < -1) or (FSine > 31) or (FSinePhase < 0) or (FSinePhase > 127) or
    IsNan(FOutL) or IsInfinite(FOutL) or IsNan(FOutR) or IsInfinite(FOutR) or
    IsNan(FLowL) or IsInfinite(FLowL) or IsNan(FLowR) or IsInfinite(FLowR) or
    IsNan(FHighL) or IsInfinite(FHighL) or IsNan(FHighR) or IsInfinite(FHighR) then
    raise EReadError.Create('Invalid VS1011e state');
  for var I := 0 to FCount - 1 do
    if (FPCM[(FRead + I) mod 4096].Rate < 8000) or (FPCM[(FRead + I) mod 4096].Rate > 48000) then
      raise EReadError.Create('Invalid MP3 sample rate');
end;

end.

