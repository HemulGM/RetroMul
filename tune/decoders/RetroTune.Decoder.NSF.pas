unit RetroTune.Decoder.NSF;

interface

uses
  System.SysUtils, RetroTune.Decoder, NES.CPU, NES.APU, NES.Types, NES.Mapper,
  RetroTune.Chip.FDS;

type
  TNSFDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FData, FBankData: TBytes;
    FMemory: array[0..65535] of Byte;
    FBanks, FInitialBanks: array[0..7] of Byte;
    FBanked, FActive, FInitialized: Boolean;
    FLoad, FInit, FPlay, FCallAddress: Word;
    FRegion: TNesRegion;
    FCPU: TCPU6502;
    FAPU: TApu;
    FVRC6, FVRC7, FNamco: TMapper;
    FFds: TFdsAudio;
    FCycle, FCallStart: Int64;
    FPeriod, FNextPlay: Double;
    FDmaCycles, FCpuHz: Integer;
    FFlags: Byte;
    FBackground, FInPlayNMI, FTimerActive, FTimerIRQ, FPlayPending: Boolean;
    FTimerReload: Word;
    FTimerCounter: Integer;
    FIRQVector: Word;
    function ReadMemory(Address: UInt16): UInt8;
    procedure WriteMemory(Address: UInt16; Value: UInt8);
    procedure BeginCall(Address: Word);
    procedure MapFdsBank(Address: Word; Bank: Byte);
    procedure Clock;
    function HeaderWord(Offset: Integer): Word;
    function HeaderText(Offset: Integer): string;
  public
    constructor Create(const Data: TBytes; ForceBanked: Boolean = False);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

implementation

uses
  System.Math, NES.Consts, NES.Mapper.VrcAudio, NES.Mapper.Namco,
  RetroTune.Decoder.NSFe;

function TNSFDecoder.HeaderWord(Offset: Integer): Word;
begin
  Result := FData[Offset] or (Word(FData[Offset + 1]) shl 8);
end;

function TNSFDecoder.HeaderText(Offset: Integer): string;
var
  Count: Integer;
begin
  Count := 0;
  while (Count < 32) and (FData[Offset + Count] <> 0) do
    Inc(Count);
  Result := TEncoding.UTF8.GetString(FData, Offset, Count);
end;

constructor TNSFDecoder.Create(const Data: TBytes; ForceBanked: Boolean);
var
  I, Padding, Speed, Chips: Integer;
  Dummy: TByteArray;
begin
  inherited Create;
  if (Length(Data) <= $80) or (Data[0] <> Ord('N')) or
    (Data[1] <> Ord('E')) or (Data[2] <> Ord('S')) or
    (Data[3] <> Ord('M')) or (Data[4] <> $1A) then
    raise EArgumentException.Create('Invalid or truncated NSF file');
  if not (Data[5] in [1, 2]) then
    raise EArgumentException.Create('Unsupported NSF version');
  if Data[5] = 2 then
  begin
    FFlags := Data[$7C];
    if (FFlags and $0F) <> 0 then
      raise EArgumentException.Create('Reserved NSF2 feature flags are set');
  end;
  if (Data[6] = 0) or (Data[7] = 0) or (Data[7] > Data[6]) then
    raise EArgumentException.Create('Invalid NSF track count or starting track');
  Chips := Data[$7B];
  if (Chips and not $17) <> 0 then
    raise EArgumentException.CreateFmt('Unsupported NSF expansion chips ($%.2x). Supported: NES APU, VRC6, VRC7, FDS, Namco 163.', [Chips]);
  FData := Copy(Data);
  FLoad := HeaderWord($08);
  FInit := HeaderWord($0A);
  FPlay := HeaderWord($0C);
  if ((FLoad < $8000) and (((Chips and 4) = 0) or (FLoad < $6000))) or
    (FInit < $6000) or ((FPlay < $6000) and ((FFlags and $40) = 0)) then
    raise EArgumentException.Create('Invalid NSF load, INIT or PLAY address');
  FInfo.Title := HeaderText($0E);
  FInfo.Artist := HeaderText($2E);
  FInfo.CopyrightText := HeaderText($4E);
  FInfo.FormatName := 'NSF';
  if Data[5] = 2 then
    FInfo.FormatName := 'NSF2';
  FInfo.TrackCount := Data[6];
  FInfo.DefaultTrack := Data[7] - 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 1;
  // Dual-region NSF defaults to NTSC. PAL-only tunes use the PAL APU tables.
  if (Data[$7A] and 3) = 1 then
  begin
    FRegion := TNesRegion.PAL;
    Speed := HeaderWord($78);
    if Speed = 0 then
      Speed := 19997;
    FInfo.Details := 'PAL';
  end
  else
  begin
    FRegion := TNesRegion.NTSC;
    Speed := HeaderWord($6E);
    if Speed = 0 then
      Speed := 16639;
    FInfo.Details := 'NTSC';
  end;
  FCpuHz := CpuFrequency(FRegion);
  FPeriod := Speed * (FCpuHz / 1000000.0);
  Move(Data[$70], FInitialBanks[0], 8);
  FBanked := ForceBanked;
  for I := 0 to 7 do
    FBanked := FBanked or (FInitialBanks[I] <> 0);
  if FBanked then
  begin
    Padding := FLoad and $FFF;
    if Length(Data) - $80 + Padding > $100000 then
      raise EArgumentException.Create('NSF bank data exceeds 256 banks');
    SetLength(FBankData, ((Length(Data) - $80 + Padding + $FFF) div $1000) * $1000);
    Move(Data[$80], FBankData[Padding], Length(Data) - $80);
  end
  else if Length(Data) - $80 > $10000 - FLoad then
    raise EArgumentException.Create('Unbanked NSF data exceeds the address space');
  FCPU := TCPU6502.Create;
  FCPU.Connect(ReadMemory, WriteMemory);
  FAPU := TApu.Create;
  if (Chips and 4) <> 0 then
  begin
    FFds := TFdsAudio.Create;
    FInfo.Details := FInfo.Details + ' / FDS';
  end;
  SetLength(Dummy, $8000);
  if (Chips and 1) <> 0 then
  begin
    FVRC6 := TMapperVrcAudio.Create(MAPPER_VRC6A, Dummy, nil, True, TMirrorMode.Horizontal);
    FInfo.Details := FInfo.Details + ' / VRC6';
  end;
  if (Chips and 2) <> 0 then
  begin
    FVRC7 := TMapperVrcAudio.Create(MAPPER_VRC7, Dummy, nil, True, TMirrorMode.Horizontal);
    FInfo.Details := FInfo.Details + ' / VRC7';
  end;
  if (Chips and $10) <> 0 then
  begin
    FNamco := TMapperNamco.Create(MAPPER_NAMCO_163, Dummy, nil, True,
      TMirrorMode.Horizontal, 0, False);
    FInfo.Details := FInfo.Details + ' / Namco 163';
  end;
end;

destructor TNSFDecoder.Destroy;
begin
  FFds.Free;
  FNamco.Free;
  FVRC7.Free;
  FVRC6.Free;
  FAPU.Free;
  FCPU.Free;
  inherited;
end;

function TNSFDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

function TNSFDecoder.ReadMemory(Address: UInt16): UInt8;
var
  Offset: Integer;
begin
  if Address < $2000 then
    Exit(FMemory[Address and $7FF]);
  if (FFlags and $10) <> 0 then
    case Address of
      $401B:
        Exit(FTimerReload and $FF);
      $401C:
        Exit(FTimerReload shr 8);
      $401D:
        begin
          Result := Ord(FTimerActive) or (Ord(FTimerIRQ) shl 7);
          FTimerIRQ := False;
          Exit;
        end;
      $FFFE:
        Exit(FIRQVector and $FF);
      $FFFF:
        Exit(FIRQVector shr 8);
    end;
  if (FFlags and $20) <> 0 then
  begin
    if Address = $FFFA then
      Exit($10);
    if Address = $FFFB then
      Exit($41);
    // NMI saves registers, calls PLAY with SEI, restores registers and RTI.
    case Address of
      $4110:
        Exit($48);
      $4111:
        Exit($8A);
      $4112:
        Exit($48);
      $4113:
        Exit($98);
      $4114:
        Exit($48);
      $4115:
        Exit($78);
      $4116:
        Exit($20);
      $4117:
        Exit(FPlay and $FF);
      $4118:
        Exit(FPlay shr 8);
      $4119:
        Exit($68);
      $411A:
        Exit($A8);
      $411B:
        Exit($68);
      $411C:
        Exit($AA);
      $411D:
        Exit($68);
      $411E:
        Exit($40);
    end;
  end;
  if Address = $4015 then
    Exit(FAPU.CpuReadStatus);
  if (FFds <> nil) and (Address >= $4040) and (Address <= $4092) then
    Exit(FFds.Read(Address));
  if (Address >= $4800) and (Address <= $4FFF) and (FNamco <> nil) then
  begin
    FNamco.CpuRead($4800, Result);
    Exit;
  end;
  // A tiny JSR trampoline provides a real stack frame, including nested calls.
  case Address of
    $4100:
      Exit($20);
    $4101:
      Exit(FCallAddress and $FF);
    $4102:
      Exit(FCallAddress shr 8);
    $4103:
      Exit($4C);
    $4104:
      Exit($03);
    $4105:
      Exit($41);
  end;
  if FBanked and (FFds = nil) and (Address >= $8000) then
  begin
    Offset := Integer(FBanks[(Address - $8000) shr 12]) * $1000 + (Address and $FFF);
    if Offset < Length(FBankData) then
      Exit(FBankData[Offset]);
    Exit(0);
  end;
  if Address >= $6000 then
    Exit(FMemory[Address]);
  Result := 0;
end;

procedure TNSFDecoder.WriteMemory(Address: UInt16; Value: UInt8);
begin
  if (FFlags and $10) <> 0 then
    case Address of
      $401B:
        begin
          FTimerReload := (FTimerReload and $FF00) or Value;
          Exit;
        end;
      $401C:
        begin
          FTimerReload := (FTimerReload and $FF) or (Word(Value) shl 8);
          Exit;
        end;
      $401D:
        begin
          FTimerActive := (Value and 1) <> 0;
          Exit;
        end;
      $FFFE:
        begin
          FIRQVector := (FIRQVector and $FF00) or Value;
          Exit;
        end;
      $FFFF:
        begin
          FIRQVector := (FIRQVector and $FF) or (Word(Value) shl 8);
          Exit;
        end;
    end;
  if (FFds <> nil) and ((Address = $4023) or
    ((Address >= $4040) and (Address <= $408A))) then
    FFds.Write(Address, Value);
  if Address < $2000 then
    FMemory[Address and $7FF] := Value
  else if ((Address >= $4000) and (Address <= $4013)) or
    (Address = $4015) or (Address = $4017) then
    FAPU.CpuWrite(Address, Value)
  else if FBanked and (FFds <> nil) and (Address >= $5FF6) and (Address <= $5FFF) then
    MapFdsBank((Address - $5FF0) shl 12, Value)
  else if FBanked and (Address >= $5FF8) and (Address <= $5FFF) then
    FBanks[Address - $5FF8] := Value
  else if (Address >= $6000) and ((Address < $8000) or
    ((FFds <> nil) and (Address < $E000))) then
    FMemory[Address] := Value;
  if (FVRC6 <> nil) and (((Address >= $9000) and (Address <= $9003)) or
    ((Address >= $A000) and (Address <= $A002)) or
    ((Address >= $B000) and (Address <= $B002))) then
    FVRC6.CpuWrite(Address, Value);
  if (FVRC7 <> nil) and ((Address = $9010) or (Address = $9030)) then
    FVRC7.CpuWrite(Address, Value);
  if FNamco <> nil then
    if (Address >= $4800) and (Address <= $4FFF) then
      FNamco.CpuWrite($4800, Value)
    else if Address >= $F800 then
      FNamco.CpuWrite($F800, Value);
end;

procedure TNSFDecoder.MapFdsBank(Address: Word; Bank: Byte);
var
  Offset: Integer;
begin
  // FDS banks are copied into writable RAM; subsequent bank loads replace it.
  Offset := Integer(Bank) * $1000;
  if Offset < Length(FBankData) then
    Move(FBankData[Offset], FMemory[Address], $1000)
  else
    FillChar(FMemory[Address], $1000, 0);
end;

procedure TNSFDecoder.BeginCall(Address: Word);
begin
  FCallAddress := Address;
  FCPU.Pc := $4100;
  FActive := True;
  FCallStart := FCycle;
end;

procedure TNSFDecoder.Clock;
var
  Expansion: Double;
begin
  Expansion := 0;
  if FFds <> nil then
  begin
    FFds.Clock;
    Expansion := FFds.Output;
  end;
  if FVRC6 <> nil then
  begin
    FVRC6.ClockCpu;
    Expansion := Expansion + FVRC6.ExpansionAudio;
  end;
  if FVRC7 <> nil then
  begin
    FVRC7.ClockCpu;
    Expansion := Expansion + FVRC7.ExpansionAudio;
  end;
  if FNamco <> nil then
  begin
    FNamco.ClockCpu;
    Expansion := Expansion + FNamco.ExpansionAudio;
  end;
  FAPU.SetExpansionAudio(Expansion);
  FAPU.Clock;
  if (FFlags and $10) <> 0 then
  begin
    if FTimerActive then
    begin
      Dec(FTimerCounter);
      if FTimerCounter < 0 then
      begin
        FTimerCounter := FTimerReload;
        FTimerIRQ := True;
      end;
    end
    else
      FTimerCounter := FTimerReload;
    FCPU.SetIrqLine(FTimerIRQ or FAPU.IrqPending);
  end;
  if FAPU.ConsumeDmcAbort and (FDmaCycles <> 1) then
    FDmaCycles := 0;
  if (FDmaCycles = 0) and FAPU.DmcDmaRequested and
    (not FActive or not FCPU.NextCycleIsWrite) then
  begin
    if FActive then
      FCPU.NotifyDmaHalt;
    FDmaCycles := 4 - Integer(Odd(FCycle));
  end;
  if FDmaCycles > 0 then
  begin
    Dec(FDmaCycles);
    if FDmaCycles = 0 then
      FAPU.CompleteDmcDma(ReadMemory(FAPU.DmcDmaAddress));
  end
  else if FActive or ((FFlags and $10) <> 0) then
  begin
    FCPU.Clock;
    if FCPU.Jammed then
      raise EInvalidOpException.CreateFmt('NSF CPU halted at $%.4x', [FCPU.JamPc]);
    if (FCPU.Pc = $4103) and (FCPU.CyclesRemaining = 0) and not FBackground then
      FActive := False;
    if (FCPU.Pc = $411E) and (FCPU.CyclesRemaining = 0) then
      FInPlayNMI := False;
  end;
  Inc(FCycle);
  if FActive and not FBackground and (FCycle - FCallStart > FCpuHz * 2) then
    raise EInvalidOpException.Create('NSF INIT/PLAY routine did not return within two seconds');
end;

procedure TNSFDecoder.SelectTrack(Index: Integer);
var
  I: Integer;
  Discard: array[0..1023] of SmallInt;
begin
  if (Index < 0) or (Index >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('Invalid NSF track');
  FInitialized := False;
  FBackground := False;
  FInPlayNMI := False;
  FPlayPending := False;
  FTimerActive := False;
  FTimerIRQ := False;
  FTimerCounter := 0;
  FTimerReload := 0;
  FIRQVector := 0;
  FillChar(FMemory, SizeOf(FMemory), 0);
  FBanks := FInitialBanks;
  if not FBanked then
    Move(FData[$80], FMemory[FLoad], Length(FData) - $80);
  if (FFds <> nil) and FBanked then
  begin
    for I := 0 to 7 do
      MapFdsBank($8000 + I * $1000, FInitialBanks[I]);
    MapFdsBank($6000, FInitialBanks[6]);
    MapFdsBank($7000, FInitialBanks[7]);
  end;
  if FFds <> nil then
    FFds.Reset;
  FAPU.SetRegion(FRegion);
  FAPU.SetSampleRate(FInfo.SampleRate);
  if FVRC6 <> nil then
    FVRC6.Reset;
  if FVRC7 <> nil then
    FVRC7.Reset;
  if FNamco <> nil then
  begin
    FNamco.Reset;
    // The mapper's soft reset preserves audio RAM; a new tune must clear it.
    FNamco.CpuWrite($F800, $80);
    for I := 0 to 127 do
      FNamco.CpuWrite($4800, 0);
    FNamco.CpuWrite($F800, 0);
  end;
  for I := $4000 to $4013 do
    FAPU.CpuWrite(I, 0);
  FAPU.CpuWrite($4015, 0);
  FAPU.CpuWrite($4015, $0F);
  FAPU.CpuWrite($4017, $40);
  FCPU.Reset;
  FCPU.CyclesRemaining := 0;
  FCPU.Sp := $FF;
  FCPU.A := Index;
  FCPU.X := Ord(FRegion = TNesRegion.PAL);
  FCPU.Y := 0;
  if (FFlags and $20) <> 0 then
    FCPU.Y := $80;
  FCycle := 0;
  FDmaCycles := 0;
  BeginCall(FInit);
  repeat
    Clock;
    if (FCycle and $3FF) = 0 then
      FAPU.PopSamples(Discard);
  until not FActive;
  while FAPU.PopSamples(Discard) > 0 do
    ;
  if (FFlags and $20) <> 0 then
  begin
    FCPU.A := Index;
    FCPU.X := Ord(FRegion = TNesRegion.PAL);
    FCPU.Y := $81;
    BeginCall(FInit);
    FBackground := True;
  end;
  FNextPlay := FCycle;
  FInitialized := True;
end;

function TNSFDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
var
  Scratch: TArray<SmallInt>;
  I, N, Cycles: Integer;
begin
  if not FInitialized then
    raise EInvalidOpException.Create('Select a track before rendering');
  if (Frames < 0) or (Frames > Length(Samples)) or (Frames > 4096) then
    raise EArgumentOutOfRangeException.Create('Invalid NSF PCM frame count (maximum 4096)');
  Result := 0;
  while Result < Frames do
  begin
    SetLength(Scratch, Frames - Result);
    N := FAPU.PopSamples(Scratch);
    if N > 0 then
    begin
      Move(Scratch[0], Samples[Result], N * SizeOf(SmallInt));
      Inc(Result, N);
      Continue;
    end;
    Cycles := Ceil((Frames - Result) * (FCpuHz / FInfo.SampleRate));
    for I := 1 to Cycles do
    begin
      if FCycle >= FNextPlay then
      begin
        if (FFlags and $40) = 0 then
          if FBackground then
          begin
            if not FInPlayNMI then
            begin
              FCPU.TriggerNmi;
              FInPlayNMI := True;
            end;
          end
          else if (FFlags and $10) <> 0 then
            FPlayPending := True
          else if not FActive then
            BeginCall(FPlay);
        // Do not nest PLAY if a slow driver overruns its declared period.
        FNextPlay := FNextPlay + FPeriod;
      end;
      if FPlayPending and not FActive and (FCPU.Pc = $4103) and
        (FCPU.CyclesRemaining = 0) then
      begin
        BeginCall(FPlay);
        FPlayPending := False;
      end;
      Clock;
    end;
  end;
end;

function CreateNSF(const Data: TBytes): ITuneDecoder;
begin
  Result := OpenNESMusic(Data, False);
end;

initialization
  TTuneDecoders.RegisterFormat('.nsf', 'Nintendo Sound Format', CreateNSF);
  TTuneDecoders.RegisterFormat('.nsf2', 'Nintendo Sound Format 2', CreateNSF);

end.

