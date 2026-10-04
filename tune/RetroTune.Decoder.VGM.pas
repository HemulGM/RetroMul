unit RetroTune.Decoder.VGM;

interface

uses
  System.SysUtils, RetroTune.Decoder, MD.Sound, NES.APU, GB.Sound, GB.GPU,
  GB.Timer, GB.InterruptManager, GB.Joypad, RetroTune.Decoder.GBS,
  Core.AudioFilter, PC.Sound.OPL, PC.Sound.OPL2, PC.Sound.OPL3, ZX.Sound.YM2149;

type
  TVGMDataBank = record
    Data: TBytes;
    Blocks: TArray<Integer>;
    Sizes: TArray<Integer>;
  end;

  TVGMStream = record
    Chip, Port, RegisterID, Bank, Step, Base: Byte;
    Frequency: Cardinal;
    Position, Start, Remaining, Count: Integer;
    Phase: Double;
    Active, Looping: Boolean;
  end;

  PVGMStream = ^TVGMStream;

  TVGMDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FData: TBytes;
    FStart, FOffset, FEnd, FWait, FDACPosition, FWait60, FWait50: Integer;
    FEnded, FReady: Boolean;
    FPSG: TPSG;
    FFM: TFM;
    FOPL: array[0..1, 0..1] of TOPLSound;
    FOPLClocks: array[0..1] of Integer;
    FOPLDual: array[0..1] of Boolean;
    FYM: array[0..1] of TYM2149F;
    FYMClock: Integer;
    FYMDual, FYMSelectHigh: Boolean;
    FYMStereo: Boolean;
    FNES: TApu;
    FMemory: TGBSMemory;
    FGB: TGBSound;
    FGPU: TGBGPU;
    FTimer: TGBTimer;
    FIRQ: TGBInterruptManager;
    FJoy: TGBJoypad;
    FNESRAM: array[0..65535] of Byte;
    FBanks: array[0..63] of TVGMDataBank;
    FStreams: array[0..255] of TVGMStream;
    FStreamIDs: TBytes;
    FClocks: array[0..3] of Integer;
    FPhase: array[0..3] of Double;
    FFMPCM, FGBPCM: array[0..1] of SmallInt;
    FFMFiltered, FPSGFiltered: array[0..1] of Double;
    FFMFilter, FPSGFilter: array[0..1] of TPCMLowPass;
    FNESPCM: SmallInt;
    FStereo: Byte;
    FDC: array[0..1] of TPCMDCBlocker;
    procedure ReadCommand(Validate: Boolean);
    procedure StreamWrite(var Stream: TVGMStream; Value: Byte);
    procedure ReceiveGB(PCM: TArray<SmallInt>; Frames: Integer);
    procedure Sample(out Left, Right: SmallInt);
    function HeaderClock(Offset: Integer): Cardinal;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

implementation

uses
  System.Classes, System.ZLib, System.Math, NES.Types, RetroTune.Binary;

function UnpackVGM(const Data: TBytes): TBytes;
begin
  if (Length(Data) < 2) or (Data[0] <> $1F) or (Data[1] <> $8B) then
    Exit(Copy(Data));
  RequireBytes(Data, 0, 18);
  var Source := TBytesStream.Create(Data);
  try
    var Inflate := TZDecompressionStream.Create(Source, 31);
    try
      var Output := TMemoryStream.Create;
      try
        var Buffer: array[0..8191] of Byte;
        repeat
          var N := Inflate.Read(Buffer, SizeOf(Buffer));
          if N = 0 then
            Break;
          if Output.Size + N > 16 * 1024 * 1024 then
            raise EArgumentException.Create('Decompressed VGZ exceeds 16 MiB');
          Output.WriteBuffer(Buffer, N);
        until False;
        SetLength(Result, Output.Size);
        if Length(Result) > 0 then
          Move(Output.Memory^, Result[0], Length(Result));
        if LE32(Data, Length(Data) - 4) <> Cardinal(Length(Result)) then
          raise EArgumentException.Create('Invalid or truncated VGZ size trailer');
        if Length(Result) > 0 then
          if crc32(0, @Result[0], Length(Result)) <> LE32(Data, Length(Data) - 8) then
            raise EArgumentException.Create('Invalid or truncated VGZ checksum');
      finally
        Output.Free;
      end;
    finally
      Inflate.Free;
    end;
  finally
    Source.Free;
  end;
end;

function TVGMDecoder.HeaderClock(Offset: Integer): Cardinal;
begin
  Result := 0;
  if Offset + 4 <= FStart then
    Result := LE32(FData, Offset);
end;

constructor TVGMDecoder.Create(const Data: TBytes);
const
  UnsupportedOffsets: array[0..32] of Integer =
    ($10, $30, $38, $40, $44, $48, $4C, $54, $58, $60, $64, $68, $6C, $70,
    $7C, $88, $8C, $90, $98, $9C, $A0, $A4, $A8, $AC, $B0, $B4, $B8, $BC, $C0, $C4, $C8, $CC, $D0);
  ClockOffsets: array[0..3] of Integer = ($C, $2C, $84, $80);
begin
  inherited Create;
  FData := UnpackVGM(Data);
  RequireBytes(FData, 0, $40);
  if TEncoding.ASCII.GetString(FData, 0, 4) <> 'Vgm ' then
    raise EArgumentException.Create('Invalid VGM signature');
  var Version := LE32(FData, 8);
  if (Version < $100) or (Version > $171) then
    raise ENotSupportedException.CreateFmt('Unsupported VGM version $%x', [Version]);
  FStart := $40;
  if (Version >= $150) and (LE32(FData, $34) <> 0) then
  begin
    if LE32(FData, $34) > Cardinal(Length(FData) - $34) then
      raise EArgumentException.Create('Invalid VGM data offset');
    FStart := $34 + Integer(LE32(FData, $34));
  end;
  if (FStart < $40) or (FStart >= Length(FData)) then
    raise EArgumentException.Create('Invalid VGM data offset');
  FEnd := Length(FData);
  if LE32(FData, 4) <> 0 then
  begin
    if (LE32(FData, 4) > Cardinal(Length(FData) - 4)) or (LE32(FData, 4) < Cardinal(FStart - 4)) then
      raise EArgumentException.Create('Invalid VGM EOF offset');
    FEnd := Integer(LE32(FData, 4)) + 4;
  end;
  // In older versions some of these bytes are reserved, not chip clocks.
  for var Offset in UnsupportedOffsets do
    if ((Offset = $10) or ((Version >= $110) and (Offset = $30)) or
      ((Version >= $151) and (Offset >= $38) and (Offset <= $74)) or
      ((Version >= $161) and (Offset >= $7C) and (Offset <= $B4)) or
      ((Version >= $171) and (Offset >= $B8))) and (HeaderClock(Offset) <> 0) then
      raise ENotSupportedException.CreateFmt('VGM chip at header $%x is unsupported', [Offset]);
  if Version >= $151 then
  begin
    var RawClock := HeaderClock($74);
    FYMClock := RawClock and $3FFFFFFF;
    FYMDual := (RawClock and $40000000) <> 0;
    if FYMClock <> 0 then
    begin
      RequireBytes(FData, $78, 2);
      if (FStart <= $79) or (FData[$78] <> $10) or ((RawClock and $80000000) <> 0) then
        raise ENotSupportedException.Create('Unsupported AY chip variant; YM2149 is supported');
      if (FYMClock < 100000) or (FYMClock > 8000000) then
        raise EArgumentException.Create('Invalid YM2149 clock');
      if (FData[$79] and $60) <> 0 then
        raise EArgumentException.Create('Invalid AY flags');
      FYMSelectHigh := (FData[$79] and $10) = 0;
      FYMStereo := (FData[$79] and $80) <> 0;
    end;
  end;
  for var J := 0 to 3 do
    if (J = 0) or ((J = 1) and (Version >= $110)) or ((J >= 2) and (Version >= $161)) then
    begin
      var RawClock := HeaderClock(ClockOffsets[J]);
      if (RawClock and $C0000000) <> 0 then
        raise ENotSupportedException.Create('Dual-chip / variant VGM clocks are unsupported');
      if RawClock > 16000000 then
        raise EArgumentException.Create('Invalid VGM chip clock');
      FClocks[J] := RawClock;
    end;
  if Version >= $151 then
    for var J := 0 to 1 do
    begin
      var Offset := $50;
      if J = 1 then
        Offset := $5C;
      var RawClock := HeaderClock(Offset);
      if (RawClock and $80000000) <> 0 then
        raise ENotSupportedException.Create('Unsupported OPL chip variant');
      FOPLDual[J] := (RawClock and $40000000) <> 0;
      FOPLClocks[J] := RawClock and $3FFFFFFF;
      if (FOPLClocks[J] <> 0) and ((FOPLClocks[J] < 1000000) or (FOPLClocks[J] > 32000000)) then
        raise EArgumentException.Create('Invalid VGM OPL clock');
    end;
  FInfo.FormatName := 'VGM';
  if (Length(Data) > 1) and (Data[0] = $1F) and (Data[1] = $8B) then
    FInfo.FormatName := 'VGZ';
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.TrackCount := 1;
  for var J := 0 to 3 do
  begin
    if FClocks[J] <> 0 then
    begin
      if FInfo.Details <> '' then
        FInfo.Details := FInfo.Details + ' / ';
      case J of
        0:
          FInfo.Details := FInfo.Details + 'SN76489';
        1:
          FInfo.Details := FInfo.Details + 'YM2612';
        2:
          FInfo.Details := FInfo.Details + 'NES APU';
        3:
          FInfo.Details := FInfo.Details + 'Game Boy';
      end;
    end;
  end;
  for var J := 0 to 1 do
    if FOPLClocks[J] <> 0 then
    begin
      if FInfo.Details <> '' then
        FInfo.Details := FInfo.Details + ' / ';
      if FOPLDual[J] then
        FInfo.Details := FInfo.Details + '2 x ';
      if J = 0 then
        FInfo.Details := FInfo.Details + 'YM3812 (OPL2)'
      else
        FInfo.Details := FInfo.Details + 'YMF262 (OPL3)';
    end;
  if FInfo.Details = '' then
    if FYMClock <> 0 then
      FInfo.Details := 'YM2149F';
  if (FYMClock <> 0) and (FInfo.Details <> 'YM2149F') then
    FInfo.Details := FInfo.Details + ' / YM2149F';
  if FYMDual then
    FInfo.Details := FInfo.Details + ' (dual YM2149F)';
  if FInfo.Details = '' then
    raise ENotSupportedException.Create('VGM has no supported audio chip');
  if (FClocks[0] <> 0) and (Version >= $110) then
  begin
    if not (LE16(FData, $28) in [0, 9]) or not (FData[$2A] in [0, 16]) then
      raise ENotSupportedException.Create('This SN76489 feedback / shift-register variant is unsupported');
    if FData[$2B] <> 0 then
      raise ENotSupportedException.Create('SN76489 variant flags are unsupported');
  end;
  if (FClocks[2] <> 0) and (FClocks[2] <> 1789773) and (FClocks[2] <> 1662607) then
    raise ENotSupportedException.Create('Unsupported NES APU clock');
  if (FClocks[3] <> 0) and (FClocks[3] <> 4194304) then
    raise ENotSupportedException.Create('Unsupported Game Boy APU clock');
  var GD3 := LE32(FData, $14);
  if GD3 <> 0 then
  begin
    if GD3 > Cardinal(FEnd - $14) then
      raise EArgumentException.Create('Invalid GD3 offset');
    var P := Integer(GD3) + $14;
    if P > FEnd - 12 then
      raise EArgumentException.Create('Truncated GD3 header');
    RequireBytes(FData, P, 12);
    if TEncoding.ASCII.GetString(FData, P, 4) <> 'Gd3 ' then
      raise EArgumentException.Create('Invalid GD3 signature');
    var Bytes := LE32(FData, P + 8);
    if (Bytes > Cardinal(FEnd - P - 12)) or (Bytes mod 2 <> 0) then
      raise EArgumentException.Create('Invalid GD3 size');
    var Fields := TEncoding.Unicode.GetString(FData, P + 12, Bytes).Split([#0]);
    if Length(Fields) > 0 then
      FInfo.Title := Fields[0];
    if Length(Fields) > 6 then
      FInfo.Artist := Fields[6];
    if Length(Fields) > 8 then
      FInfo.CopyrightText := Fields[8];
  end;
  FOffset := FStart;
  FWait60 := 735;
  FWait50 := 882;
  var TotalFrames: Int64 := 0;
  while not FEnded do
  begin
    FWait := 0;
    ReadCommand(True);
    Inc(TotalFrames, FWait);
  end;
  FInfo.TrackDurations := [TotalFrames / 44100.0];
  if FYMClock <> 0 then
    for var Chip := 0 to Ord(FYMDual) do
    begin
      FYM[Chip] := TYM2149F.Create(FYMClock, 44100, FYMSelectHigh);
      if not FYMStereo then
        for var Channel := 0 to 2 do
          FYM[Chip].SetPan(Channel, 1, 1);
    end;
  for var J := 0 to 1 do
    if FOPLClocks[J] <> 0 then
      for var K := 0 to Ord(FOPLDual[J]) do
        if J = 0 then
          FOPL[J, K] := TOPL2.Create(FOPLClocks[J], 44100)
        else
          FOPL[J, K] := TOPL3.Create(FOPLClocks[J], 44100);
  if FClocks[2] <> 0 then
    FNES := TApu.Create;
  if FClocks[3] <> 0 then
  begin
    FIRQ := TGBInterruptManager.Create;
    FTimer := TGBTimer.Create(FIRQ);
    FJoy := TGBJoypad.Create(FIRQ);
    FGPU := TGBGPU.Create(nil);
    FMemory := TGBSMemory.Create(nil, FGPU, FTimer, FIRQ, FJoy);
    FGB := TGBSound.Create(FMemory, False);
    FGB.OnPCM := ReceiveGB;
  end;
end;

destructor TVGMDecoder.Destroy;
begin
  for var Chip := 0 to 1 do
    FYM[Chip].Free;
  for var J := 0 to 1 do
    for var K := 0 to 1 do
      FOPL[J, K].Free;
  FNES.Free;
  FGB.Free;
  FMemory.Free;
  FGPU.Free;
  FTimer.Free;
  FJoy.Free;
  FIRQ.Free;
  inherited;
end;

function TVGMDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TVGMDecoder.ReceiveGB(PCM: TArray<SmallInt>; Frames: Integer);
begin
  if Frames > 0 then
  begin
    FGBPCM[0] := PCM[(Frames - 1) * 2];
    FGBPCM[1] := PCM[(Frames - 1) * 2 + 1];
  end;
end;

procedure TVGMDecoder.StreamWrite(var Stream: TVGMStream; Value: Byte);
begin
  if Stream.Chip = 2 then
  begin
    FMDoAddress(FFM, Stream.Port, Stream.RegisterID);
    FMDoData(FFM, Value);
  end
  else
    PSGDoCommand(FPSG, Value);
end;

procedure TVGMDecoder.ReadCommand(Validate: Boolean);
var
  Size, Bank, Block, Start, Count: Integer;
begin
  if FOffset >= FEnd then
    raise EArgumentException.Create('VGM has no end command');
  var Command := FData[FOffset];
  Inc(FOffset);
  Size := 0;
  case Command of
    $4F, $50:
      Size := 1;
    $52, $53, $5A, $5E, $5F, $AA, $AE, $AF, $A0, $61, $B3, $B4:
      Size := 2;
    $64:
      Size := 3;
    $90, $91, $E0:
      Size := 4;
    $92:
      Size := 5;
    $93:
      Size := 10;
    $94:
      Size := 1;
    $95:
      Size := 4;
    $62, $63, $66, $70..$8F:
      ;
    $67:
      Size := 6;
  else
    raise ENotSupportedException.CreateFmt('Unsupported VGM command $%.2x at $%x', [Command, FOffset - 1]);
  end;
  if Size > FEnd - FOffset then
    raise EArgumentException.Create('Truncated VGM command');
  var P := FOffset;
  Inc(FOffset, Size);
  case Command of
    $A0:
      begin
        var Chip := FData[P] shr 7;
        var Reg := FData[P] and $7F;
        if (FYMClock = 0) or ((Chip = 1) and not FYMDual) or (Reg > 15) then
          raise EArgumentException.Create('Invalid VGM YM2149 write');
        if not Validate then
          FYM[Chip].WriteRegister(Reg, FData[P + 1]);
      end;
    $4F:
      begin
        if FClocks[0] = 0 then
          raise EArgumentException.Create('VGM PSG command has no clock');
        if not Validate then
          FStereo := FData[P];
      end;
    $50:
      begin
        if FClocks[0] = 0 then
          raise EArgumentException.Create('VGM PSG command has no clock');
        if not Validate then
          PSGDoCommand(FPSG, FData[P]);
      end;
    $52, $53:
      begin
        if FClocks[1] = 0 then
          raise EArgumentException.Create('VGM YM2612 command has no clock');
        if not Validate then
        begin
          FMDoAddress(FFM, Command - $52, FData[P]);
          FMDoData(FFM, FData[P + 1]);
        end;
      end;
    $5A, $5E, $5F, $AA, $AE, $AF:
      begin
        var ChipIndex := Ord(not (Command in [$5A, $AA]));
        var Instance := Ord(Command >= $A0);
        if (FOPLClocks[ChipIndex] = 0) or ((Instance = 1) and not FOPLDual[ChipIndex]) then
          raise EArgumentException.Create('VGM OPL write has no corresponding chip clock');
        var RegisterID := Word(FData[P]);
        if Command in [$5F, $AF] then
          Inc(RegisterID, $100);
        if not Validate then
          FOPL[ChipIndex, Instance].WriteRegister(RegisterID, FData[P + 1]);
      end;
    $B3:
      begin
        if (FClocks[3] = 0) or (FData[P] > $2F) then
          raise EArgumentException.Create('Invalid VGM Game Boy write');
        if not Validate then
          FMemory.WriteByte($FF10 + FData[P], FData[P + 1]);
      end;
    $B4:
      begin
        if (FClocks[2] = 0) or (FData[P] > $1F) then
          raise EArgumentException.Create('Invalid VGM NES write');
        if not Validate then
          FNES.CpuWrite($4000 + FData[P], FData[P + 1]);
      end;
    $61:
      FWait := LE16(FData, P);
    $62:
      FWait := FWait60;
    $63:
      FWait := FWait50;
    $64:
      begin
        if FData[P] = $62 then
          FWait60 := LE16(FData, P + 1)
        else if FData[P] = $63 then
          FWait50 := LE16(FData, P + 1)
        else
          raise EArgumentException.Create('Invalid VGM wait override');
      end;
    $66:
      FEnded := True;
    $70..$7F:
      FWait := (Command and 15) + 1;
    $80..$8F:
      begin
        if FClocks[1] = 0 then
          raise EArgumentException.Create('VGM DAC has no YM2612 clock');
        if FDACPosition >= Length(FBanks[0].Data) then
          raise EArgumentException.Create('VGM DAC read outside data bank');
        if not Validate then
        begin
          FMDoAddress(FFM, 0, $2A);
          FMDoData(FFM, FBanks[0].Data[FDACPosition]);
        end;
        Inc(FDACPosition);
        FWait := Command and 15;
      end;
    $E0:
      begin
        if LE32(FData, P) > $FFFFFF then
          raise EArgumentException.Create('Invalid VGM DAC seek');
        FDACPosition := LE32(FData, P);
      end;
    $67:
      begin
        if FData[P] <> $66 then
          raise EArgumentException.Create('Invalid VGM data block');
        var BlockSize := LE32(FData, P + 2);
        if BlockSize > Cardinal(FEnd - FOffset) then
          raise EArgumentException.Create('Truncated VGM data block');
        Size := BlockSize;
        Bank := FData[P + 1];
        if Bank < $40 then
        begin
          if Validate then
          begin
            Start := Length(FBanks[Bank].Data);
            FBanks[Bank].Blocks := FBanks[Bank].Blocks + [Start];
            FBanks[Bank].Sizes := FBanks[Bank].Sizes + [Size];
            FBanks[Bank].Data := FBanks[Bank].Data + Copy(FData, FOffset, Size);
          end;
        end
        else if Bank = $C2 then
        begin
          if (FClocks[2] = 0) or (Size < 2) then
            raise EArgumentException.Create('Invalid NES RAM block');
          Start := LE16(FData, FOffset);
          if Size - 2 > $10000 - Start then
            raise EArgumentException.Create('NES RAM block exceeds memory');
          if not Validate and (Size > 2) then
            Move(FData[FOffset + 2], FNESRAM[Start], Size - 2);
        end
        else
          raise ENotSupportedException.CreateFmt('Unsupported VGM data block $%.2x', [Bank]);
        Inc(FOffset, Size);
      end;
    $90:
      begin
        if Validate then
        begin
          var Known := False;
          for var ID in FStreamIDs do
            Known := Known or (ID = FData[P]);
          if not Known then
            FStreamIDs := FStreamIDs + [FData[P]];
        end;
        var Stream: PVGMStream := @FStreams[FData[P]];
        Stream.Chip := FData[P + 1];
        Stream.Port := FData[P + 2];
        Stream.RegisterID := FData[P + 3];
        if not (((Stream.Chip = 2) and (FClocks[1] <> 0) and (Stream.Port <= 1)) or
          ((Stream.Chip = 0) and (FClocks[0] <> 0))) then
          raise ENotSupportedException.Create('Unsupported VGM stream device');
      end;
    $91:
      begin
        var Stream: PVGMStream := @FStreams[FData[P]];
        Stream.Bank := FData[P + 1];
        Stream.Step := FData[P + 2];
        Stream.Base := FData[P + 3];
        if (Stream.Bank >= $40) or (Stream.Step = 0) then
          raise EArgumentException.Create('Invalid VGM stream bank/step');
      end;
    $92:
      begin
        if LE32(FData, P + 1) > 1000000 then
          raise EArgumentException.Create('VGM stream frequency exceeds 1 MHz');
        FStreams[FData[P]].Frequency := LE32(FData, P + 1);
      end;
    $93, $95:
      begin
        var Stream: PVGMStream := @FStreams[FData[P]];
        if Stream.Step = 0 then
          raise EArgumentException.Create('VGM stream has no data setup');
        Bank := Stream.Bank;
        if Command = $95 then
        begin
          Block := LE16(FData, P + 1);
          if Block >= Length(FBanks[Bank].Blocks) then
            raise EArgumentException.Create('Invalid VGM stream block');
          Start := FBanks[Bank].Blocks[Block];
          Count := FBanks[Bank].Sizes[Block] div Stream.Step;
          Stream.Looping := (FData[P + 3] and 1) <> 0;
        end
        else
        begin
          if (LE32(FData, P + 1) > $FFFFFF) or (LE32(FData, P + 6) > $FFFFFF) then
            raise EArgumentException.Create('Invalid VGM stream range');
          Start := LE32(FData, P + 1);
          Count := LE32(FData, P + 6);
          Stream.Looping := (FData[P + 5] and $80) <> 0;
          case FData[P + 5] and $7F of
            1:
              ;
            2:
              Count := Int64(Count) * Stream.Frequency div 1000;
            3:
              Count := Max(0, (Length(FBanks[Bank].Data) - Start - Stream.Base) div Stream.Step);
            15:
              Count := Count div Stream.Step;
          else
            raise ENotSupportedException.Create('Unsupported VGM stream length mode');
          end;
        end;
        if (Start < 0) or (Int64(Start) + Stream.Base + Int64(Max(0, Count - 1)) * Stream.Step >= Length(FBanks[Bank].Data)) then
          raise EArgumentException.Create('VGM stream exceeds data bank');
        Stream.Start := Start + Stream.Base;
        Stream.Position := Stream.Start;
        Stream.Count := Count;
        Stream.Remaining := Count;
        Stream.Phase := 44100;
        Stream.Active := Count > 0;
      end;
    $94:
      begin
        if FData[P] = $FF then
          for var J := 0 to 255 do
            FStreams[J].Active := False
        else
          FStreams[FData[P]].Active := False;
      end;
  end;
end;

procedure TVGMDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('Invalid VGM track');
  FOffset := FStart;
  FWait := 0;
  FEnded := False;
  FReady := True;
  FDACPosition := 0;
  FWait60 := 735;
  FWait50 := 882;
  FStereo := $FF;
  FillChar(FStreams, SizeOf(FStreams), 0);
  FillChar(FPhase, SizeOf(FPhase), 0);
  FillChar(FNESRAM, SizeOf(FNESRAM), 0);
  FPSG := Default(TPSG);
  FFM := Default(TFM);
  PSGInitialise(FPSG);
  FMInitialise(FFM);
  FillChar(FFMPCM, SizeOf(FFMPCM), 0);
  FillChar(FGBPCM, SizeOf(FGBPCM), 0);
  FillChar(FFMFiltered, SizeOf(FFMFiltered), 0);
  FillChar(FPSGFiltered, SizeOf(FPSGFiltered), 0);
  FNESPCM := 0;
  for var J := 0 to 1 do
    for var K := 0 to 1 do
      if FOPL[J, K] <> nil then
        FOPL[J, K].Reset;
  for var Chip := 0 to 1 do
    if FYM[Chip] <> nil then
      FYM[Chip].Reset;
  if FNES <> nil then
  begin
    FNES.Reset;
    if FClocks[2] = 1662607 then
      FNES.SetRegion(TNesRegion.PAL)
    else
      FNES.SetRegion(TNesRegion.NTSC);
    FNES.SetSampleRate(44100);
  end;
  if FGB <> nil then
  begin
    FMemory.InitializeMemory;
    FGB.StartAudio;
  end;
  for var J := 0 to 1 do
  begin
    FDC[J].Configure(44100, 20);
    FDC[J].Reset;
    if FClocks[0] <> 0 then
      FPSGFilter[J].Configure(FClocks[0] / 16.0, 14000);
    if FClocks[1] <> 0 then
      FFMFilter[J].Configure(FClocks[1] / 144.0, 14000);
    FPSGFilter[J].Reset;
    FFMFilter[J].Reset;
  end;
end;

procedure TVGMDecoder.Sample(out Left, Right: SmallInt);
begin
  for var J in FStreamIDs do
    if FStreams[J].Active then
    begin
      var Stream: PVGMStream := @FStreams[J];
      Stream.Phase := Stream.Phase + Stream.Frequency;
      while Stream.Phase >= 44100 do
      begin
        Stream.Phase := Stream.Phase - 44100;
        StreamWrite(Stream^, FBanks[Stream.Bank].Data[Stream.Position]);
        Inc(Stream.Position, Stream.Step);
        Dec(Stream.Remaining);
        if Stream.Remaining = 0 then
          if Stream.Looping then
          begin
            Stream.Position := Stream.Start;
            Stream.Remaining := Stream.Count;
          end
          else
          begin
            Stream.Active := False;
            Break;
          end;
      end;
    end;
  FPhase[0] := FPhase[0] + FClocks[0] / (16.0 * 44100);
  while FPhase[0] >= 1 do
  begin
    FPhase[0] := FPhase[0] - 1;
    var PCM: array[0..0] of SmallInt;
    PCM[0] := 0;
    PSGUpdate(FPSG, PCM);
    var PSGLeft: Integer := 0;
    var PSGRight: Integer := 0;
    for var J := 0 to 3 do
    begin
      var Value: Integer;
      if J < 3 then
        Value := PSG_VOLUMES[FPSG.State.Tones[J].Attenuation][FPSG.State.Tones[J].OutputBit]
      else
        Value := PSG_VOLUMES[FPSG.State.Noise.Attenuation][FPSG.State.Noise.RealOutputBit];
      if (FStereo and (1 shl J)) <> 0 then
        Inc(PSGRight, Value div 8);
      if (FStereo and (16 shl J)) <> 0 then
        Inc(PSGLeft, Value div 8);
    end;
    FPSGFiltered[0] := FPSGFilter[0].Process(PSGLeft);
    FPSGFiltered[1] := FPSGFilter[1].Process(PSGRight);
  end;
  FPhase[1] := FPhase[1] + FClocks[1] / (144.0 * 44100);
  while FPhase[1] >= 1 do
  begin
    FPhase[1] := FPhase[1] - 1;
    FFMPCM[0] := 0;
    FFMPCM[1] := 0;
    FMOutputSamples(FFM, FFMPCM);
    for var J := 0 to 1 do
      FFMFiltered[J] := FFMFilter[J].Process(FFMPCM[J]);
  end;
  if FNES <> nil then
  begin
    FPhase[2] := FPhase[2] + FClocks[2] / 44100.0;
    while FPhase[2] >= 1 do
    begin
      FPhase[2] := FPhase[2] - 1;
      FNES.Clock;
      if FNES.DmcDmaRequested then
        FNES.CompleteDmcDma(FNESRAM[FNES.DmcDmaAddress]);
    end;
    var PCM: array[0..0] of SmallInt;
    if FNES.PopSamples(PCM) > 0 then
      FNESPCM := PCM[0];
  end;
  if FGB <> nil then
  begin
    FPhase[3] := FPhase[3] + FClocks[3] / 44100.0;
    var Cycles := Trunc(FPhase[3]);
    FPhase[3] := FPhase[3] - Cycles;
    FGB.UpdateSound(Cycles);
    FGB.FlushPCM;
  end;
  var OPLLeft, OPLRight: Integer;
  OPLLeft := 0;
  OPLRight := 0;
  for var Chip := 0 to 1 do
    if FYM[Chip] <> nil then
    begin
      var L, R: SmallInt;
      FYM[Chip].Sample(L, R);
      Inc(OPLLeft, L);
      Inc(OPLRight, R);
    end;
  for var J := 0 to 1 do
    for var K := 0 to 1 do
      if FOPL[J, K] <> nil then
      begin
        var L, R: SmallInt;
        FOPL[J, K].Sample(L, R);
        Inc(OPLLeft, L);
        Inc(OPLRight, R);
      end;
  Left := EnsureRange(Round(FDC[0].Process(FPSGFiltered[0] + FFMFiltered[0] + FNESPCM + FGBPCM[0] + OPLLeft)), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(FPSGFiltered[1] + FFMFiltered[1] + FNESPCM + FGBPCM[1] + OPLRight)), -32768, 32767);
end;

function TVGMDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  if not FReady then
    raise EInvalidOpException.Create('Select a track before rendering');
  Result := 0;
  while Result < Frames do
  begin
    while (FWait = 0) and not FEnded do
      ReadCommand(False);
    if FEnded then
      Break;
    Sample(Samples[Result * 2], Samples[Result * 2 + 1]);
    Inc(Result);
    Dec(FWait);
  end;
end;

function CreateVGM(const Data: TBytes): ITuneDecoder;
begin
  Result := TVGMDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.vgm', 'Video Game Music', CreateVGM);
  TTuneDecoders.RegisterFormat('.vgz', 'Compressed Video Game Music', CreateVGM);

end.

