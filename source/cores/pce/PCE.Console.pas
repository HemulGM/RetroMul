unit PCE.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Emulation.Types,
  Core.Snapshots, Core.InputConfig, PCE.Cartridge, PCE.CPU, PCE.Sound.HuC6280,
  PCE.Video, PCE.CDROM, PCE.ArcadeCard, Core.CD.Disc;

const
  PCE_CPU_CLOCK = 7159090.909090909;
  PCE_LINE_CYCLES = 455;

type
  TPCEConsole = class
  private
    FCartridge: TPCECartridge;
    FModel: TPCEModel;
    FCPU: THuC6280;
    FVideo: TPCEVideo;
    FPSG: THuC6280PSG;
    FCD: TPCECDROM;
    FArcade: TPCEArcadeCard;
    FRAM: array[0..32767] of Byte;
    FCDRAM: array[0..65535] of Byte;
    FCardRAM: TBytes;
    FTimerLoad, FTimerValue, FTimerCycles, FIRQMask, FWaitCycles, FLine, FLineCycles: Integer;
    FTimerEnabled, FTimerPending: Boolean;
    FIOBuffer, FPadPort, FPadControl: Byte;
    FPadExtra: array[0..4] of Boolean;
    FInput: TEmulatorInput;
    FFrame: TEmulatorFrame;
    FSamples: TArray<SmallInt>;
    FAudioPhase: Double;
    FOptions: TPCEOptions;
    FInputPorts: TCoreInputPorts;
    procedure StoreVDC(Address: Word; Value: Byte);
    procedure Advance(Cycles: Integer);
    function PadRead: Byte;
    procedure PadWrite(Value: Byte);
  public
    constructor Create(Cartridge: TPCECartridge; Model: TPCEModel; Disc: TCDDisc = nil; const SavedData: TBytes = nil);
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    function ReadPhysical(Address: Cardinal): Byte;
    procedure WritePhysical(Address: Cardinal; Value: Byte);
    procedure SetInput(const Input: TEmulatorInput);
    procedure RunFrame;
    procedure SerializeState(State: TStateArchive);
    function SavePersistent: TBytes;
    property Frame: TEmulatorFrame read FFrame;
    property Samples: TArray<SmallInt> read FSamples;
    property CPU: THuC6280 read FCPU;
    property Options: TPCEOptions read FOptions write FOptions;
    procedure ConfigureInputPorts(const Ports: TCoreInputPorts);
    property InputPorts: TCoreInputPorts read FInputPorts write ConfigureInputPorts;
  end;

implementation

uses
  System.Math;

procedure TPCEConsole.ConfigureInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPorts := Ports;
  FOptions.Multitap := Ports.Multitap[0];
end;

constructor TPCEConsole.Create(Cartridge: TPCECartridge; Model: TPCEModel; Disc: TCDDisc; const SavedData: TBytes);
begin
  inherited Create;
  FCartridge := Cartridge;
  FModel := Model;
  if Cartridge = nil then
    raise EArgumentNilException.Create('HuCard/System Card');
  FOptions := TPCEOptions.Defaults;
  FVideo := TPCEVideo.Create(PCESuperGrafx(Model));
  FPSG := THuC6280PSG.Create;
  FCPU := THuC6280.Create(Read, Write, StoreVDC);
  if PCEHasCD(Model) then
  begin
    FCD := TPCECDROM.Create(Disc, PCEIsSuperCD(Model));
    FCD.LoadPersistent(SavedData);
    if PCEIsSuperCD(Model) then
      SetLength(FCardRAM, $30000);
  end
  else
    FCartridge.LoadPersistent(SavedData);
  if Model in [TPCEModel.ArcadeDuo, TPCEModel.ArcadePro, TPCEModel.SuperGrafxArcade] then
    FArcade := TPCEArcadeCard.Create;
  Reset;
end;

destructor TPCEConsole.Destroy;
begin
  FCPU.Free;
  FPSG.Free;
  FVideo.Free;
  FCD.Free;
  FArcade.Free;
  inherited;
end;

procedure TPCEConsole.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FCDRAM, SizeOf(FCDRAM), 0);
  if Length(FCardRAM) > 0 then
    FillChar(FCardRAM[0], Length(FCardRAM), 0);
  FCartridge.Reset;
  FVideo.Reset;
  FPSG.Reset;
  if FCD <> nil then
    FCD.Reset;
  if FArcade <> nil then
    FArcade.Reset;
  FillChar(FCPU.MPR, SizeOf(FCPU.MPR), 0);
  FCPU.Reset(Integer(FCartridge.Read(0, $1FFE)) or (Integer(FCartridge.Read(0, $1FFF)) shl 8), 0);
  FCPU.LowSpeed := True;
  FTimerLoad := 0;
  FTimerValue := 0;
  FTimerCycles := 0;
  FIRQMask := 0;
  FTimerEnabled := False;
  FTimerPending := False;
  FWaitCycles := 0;
  FIOBuffer := 0;
  FPadPort := 5;
  FPadControl := 0;
  FillChar(FPadExtra, SizeOf(FPadExtra), 0);
  FLine := 0;
  FLineCycles := 0;
  FAudioPhase := 0;
  FFrame := Default(TEmulatorFrame);
  FFrame.Width := FVideo.Width;
  FFrame.Height := FVideo.Height;
  FFrame.FramesPerSecond := PCE_CPU_CLOCK / (PCE_LINE_CYCLES * FVideo.Lines);
  SetLength(FFrame.Pixels, FFrame.Width * FFrame.Height);
  FSamples := nil;
end;

function TPCEConsole.Read(Address: Word): Byte;
begin
  Result := ReadPhysical(Cardinal(FCPU.MPR[Address shr 13]) * $2000 + (Address and $1FFF));
end;

procedure TPCEConsole.Write(Address: Word; Value: Byte);
begin
  WritePhysical(Cardinal(FCPU.MPR[Address shr 13]) * $2000 + (Address and $1FFF), Value);
end;

function TPCEConsole.ReadPhysical(Address: Cardinal): Byte;
begin
  var Bank := (Address shr 13) and 255;
  var Offset := Word(Address and $1FFF);
  if Bank in [$F8..$FB] then
  begin
    var Mask := $1FFF;
    if PCESuperGrafx(FModel) then
      Mask := $7FFF;
    Exit(FRAM[((Bank - $F8) * $2000 + Offset) and Cardinal(Mask)]);
  end;
  if FCD <> nil then
  begin
    if Bank = $F7 then
      Exit(FCD.ReadBRAM(Offset));
    if Bank in [$80..$87] then
      Exit(FCDRAM[(Bank - $80) * $2000 + Offset]);
    if (Bank in [$68..$7F]) and (Length(FCardRAM) > 0) then
      Exit(FCardRAM[(Bank - $68) * $2000 + Offset]);
  end;
  if (FArcade <> nil) and (Bank in [$40..$43]) then
    Exit(FArcade.Read((Bank - $40) * 16));
  if Bank <> $FF then
    Exit(FCartridge.Read(Bank, Offset));
  case Offset of
    $000..$7FF:
      begin
        Inc(FWaitCycles);
        Result := FVideo.Read(Offset);
      end;
    $800..$BFF:
      Result := FIOBuffer;
    $C00..$FFF:
      begin
        var Value := FTimerValue;
      // The down-counter briefly exposes its underflow value before reload.
      // Retain this narrow window for software which polls timer expiration.
        if FTimerEnabled and (Value = 0) and (FTimerCycles >= 1019) then
          Value := 127;
        FIOBuffer := (FIOBuffer and $80) or Byte(Value);
        Result := FIOBuffer;
      end;
    $1000..$13FF:
      begin
        FIOBuffer := PadRead;
        Result := FIOBuffer;
      end;
    $1400..$17FF:
      begin
        case Offset and 3 of
          2:
            FIOBuffer := (FIOBuffer and $F8) or Byte(FIRQMask);
          3:
            FIOBuffer := (FIOBuffer and $F8) or (Ord(FTimerPending) * 4) or
              (Ord(FVideo.IRQ) * 2) or Ord((FCD <> nil) and FCD.IRQ);
        end;
        Result := FIOBuffer;
      end;
    $1800..$19FF:
      begin
        Result := $FF;
        if FCD <> nil then
          Result := FCD.Read(Offset);
      end;
    $1A00..$1BFF:
      begin
        Result := $FF;
        if FArcade <> nil then
          Result := FArcade.Read(Offset);
      end;
  else
    Result := $FF;
  end;
end;

procedure TPCEConsole.WritePhysical(Address: Cardinal; Value: Byte);
begin
  var Bank := (Address shr 13) and 255;
  var Offset := Word(Address and $1FFF);
  if Bank in [$F8..$FB] then
  begin
    var Mask := $1FFF;
    if PCESuperGrafx(FModel) then
      Mask := $7FFF;
    FRAM[((Bank - $F8) * $2000 + Offset) and Cardinal(Mask)] := Value;
    Exit;
  end;
  if FCD <> nil then
  begin
    if Bank = $F7 then
    begin
      FCD.WriteBRAM(Offset, Value);
      Exit;
    end;
    if Bank in [$80..$87] then
    begin
      FCDRAM[(Bank - $80) * $2000 + Offset] := Value;
      Exit;
    end;
    if (Bank in [$68..$7F]) and (Length(FCardRAM) > 0) then
    begin
      FCardRAM[(Bank - $68) * $2000 + Offset] := Value;
      Exit;
    end;
  end;
  if (FArcade <> nil) and (Bank in [$40..$43]) then
  begin
    FArcade.Write((Bank - $40) * 16, Value);
    Exit;
  end;
  if Bank <> $FF then
  begin
    FCartridge.Write(Bank, Offset, Value);
    Exit;
  end;
  if Offset < $800 then
  begin
    Inc(FWaitCycles);
    FVideo.Write(Offset, Value);
    Exit;
  end;
  FIOBuffer := Value;
  case Offset of
    $800..$BFF:
      FPSG.WriteRegister(Offset and 15, Value);
    $C00..$FFF:
      if Offset and 1 = 0 then
        FTimerLoad := Value and 127
      else
      begin
        if (Value and 1 <> 0) and not FTimerEnabled then
        begin
          FTimerValue := FTimerLoad;
          FTimerCycles := 0;
        end;
        FTimerEnabled := Value and 1 <> 0;
      end;
    $1000..$13FF:
      PadWrite(Value);
    $1400..$17FF:
      case Offset and 3 of
        2:
          FIRQMask := Value and 7;
        3:
          FTimerPending := False;
      end;
    $1800..$19FF:
      if FCD <> nil then
        FCD.Write(Offset, Value);
    $1A00..$1BFF:
      if FArcade <> nil then
        FArcade.Write(Offset, Value);
  end;
end;

procedure TPCEConsole.StoreVDC(Address: Word; Value: Byte);
begin
  Inc(FWaitCycles);
  FVideo.StoreVDC(Address, Value);
end;

procedure TPCEConsole.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

procedure TPCEConsole.PadWrite(Value: Byte);
begin
  if (Value and 2 <> 0) and (FPadControl and 2 = 0) then
    for var I := 0 to 4 do
      FPadExtra[I] := not FPadExtra[I];
  if (Value and 1 <> 0) and (Value and 2 <> 0) and (FPadControl and 2 = 0) then
    FPadPort := 0;
  if (Value and 2 = 0) and (Value and 1 <> 0) and (FPadControl and 1 = 0) and (FPadPort < 5) then
    Inc(FPadPort);
  FPadControl := Value and 3;
end;

function TPCEConsole.PadRead: Byte;
begin
  var Port := 0;
  if FOptions.Multitap then
    Port := FPadPort;
  var B: TEmulatorButtons := [];
  case Port of
    0:
      B := FInput.Buttons;
    1:
      B := FInput.Buttons2;
    2:
      B := FInput.Buttons3;
    3:
      B := FInput.Buttons4;
    4:
      B := FInput.Buttons5;
  end;
  var N := 15;
  if (Port < 5) and (FInputPorts.Devices[Port] <> 'none') then
  begin
    var Six := FOptions.SixButton or (FInputPorts.Devices[Port] = 'pad6');
    if FPadControl and 2 <> 0 then
    begin
      if not Six then
        N := 0;
    end
    else if Six and FPadExtra[Port] then
    begin
      if FPadControl and 1 <> 0 then
        N := 0
      else
        N := N and not (Ord(TEmulatorButton.X in B) or (Ord(TEmulatorButton.Y in B) shl 1) or
          (Ord(TEmulatorButton.C in B) shl 2) or (Ord(TEmulatorButton.Z in B) shl 3));
    end
    else if FPadControl and 1 <> 0 then
      N := N and not (Ord(TEmulatorButton.Up in B) or (Ord(TEmulatorButton.Right in B) shl 1) or
        (Ord(TEmulatorButton.Down in B) shl 2) or (Ord(TEmulatorButton.Left in B) shl 3))
    else
      N := N and not (Ord(TEmulatorButton.A in B) or (Ord(TEmulatorButton.B in B) shl 1) or
        (Ord(TEmulatorButton.Select in B) shl 2) or (Ord(TEmulatorButton.Start in B) shl 3));
  end;
  Result := Byte(N) or $30 or (Ord(FCD = nil) * $80);
  if not (FModel in [TPCEModel.TurboGrafx16, TPCEModel.TurboDuo, TPCEModel.TurboGrafxCD]) then
    Result := Result or $40;
end;

procedure TPCEConsole.Advance(Cycles: Integer);
begin
  if FTimerEnabled then
  begin
    Inc(FTimerCycles, Cycles);
    while FTimerCycles >= 1024 do
    begin
      Dec(FTimerCycles, 1024);
      Dec(FTimerValue);
      if FTimerValue < 0 then
      begin
        FTimerValue := FTimerLoad;
        FTimerPending := True;
      end;
    end;
  end;
  if FCD <> nil then
    FCD.Advance(Cycles);
  FVideo.Advance(Cycles, FLine);
  FAudioPhase := FAudioPhase + Cycles * 44100 / PCE_CPU_CLOCK;
  while FAudioPhase >= 1 do
  begin
    FAudioPhase := FAudioPhase - 1;
    var L, R: SmallInt;
    FPSG.Sample(L, R);
    var CL, CR: SmallInt;
    if FCD <> nil then
    begin
      FCD.Sample(CL, CR);
      L := EnsureRange(Integer(L) + CL, -32768, 32767);
      R := EnsureRange(Integer(R) + CR, -32768, 32767);
    end;
    var I := Length(FSamples);
    SetLength(FSamples, I + 2);
    FSamples[I] := L;
    FSamples[I + 1] := R;
  end;
  Inc(FLineCycles, Cycles);
  while FLineCycles >= PCE_LINE_CYCLES do
  begin
    Dec(FLineCycles, PCE_LINE_CYCLES);
    FVideo.Scanline(FLine, FFrame.Pixels, FOptions, FFrame.Width, FFrame.Height);
    Inc(FLine);
    if FLine >= FVideo.Lines then
    begin
      FLine := 0;
      Inc(FFrame.FrameNumber);
    end;
  end;
end;

procedure TPCEConsole.RunFrame;
begin
  FSamples := nil;
  FFrame.Pixels := Copy(FFrame.Pixels); // Published arrays belong to the frontend.
  FFrame.Width := FVideo.Width;
  FFrame.Height := FVideo.Height;
  SetLength(FFrame.Pixels, FFrame.Width * FFrame.Height);
  var Target := FFrame.FrameNumber + 1;
  while FFrame.FrameNumber < Target do
  begin
    var OldLowSpeed := FCPU.LowSpeed;
    var C := 0;
    if FTimerPending and (FIRQMask and 4 = 0) then
      C := FCPU.Interrupt($FFFA)
    else if FVideo.IRQ and (FIRQMask and 2 = 0) then
      C := FCPU.Interrupt($FFF8)
    else if (FCD <> nil) and FCD.IRQ and (FIRQMask and 1 = 0) then
      C := FCPU.Interrupt($FFF6);
    if C = 0 then
      C := FCPU.Step;
    Inc(C, FWaitCycles);
    FWaitCycles := 0;
    if OldLowSpeed <> FCPU.LowSpeed then
      C := (C - 1) * (1 + 3 * Ord(OldLowSpeed)) + 1 + 3 * Ord(FCPU.LowSpeed)
    else if FCPU.LowSpeed then
      C := C * 4;
    Advance(C);
  end;
  FFrame.FramesPerSecond := PCE_CPU_CLOCK / (PCE_LINE_CYCLES * FVideo.Lines);
end;

function TPCEConsole.SavePersistent: TBytes;
begin
  if FCD <> nil then
    Result := FCD.SavePersistent
  else
    Result := FCartridge.SavePersistent;
end;

procedure TPCEConsole.SerializeState(State: TStateArchive);
begin
  var Model := FModel;
  State.Field(Model, SizeOf(Model));
  if Model <> FModel then
    raise EReadError.Create('Snapshot uses a different PC Engine model');
  FCPU.SerializeState(State);
  FPSG.SerializeState(State);
  FVideo.SerializeState(State);
  FCartridge.SerializeState(State);
  if FCD <> nil then
    FCD.SerializeState(State);
  if FArcade <> nil then
    FArcade.SerializeState(State);
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FCDRAM, SizeOf(FCDRAM));
  if Length(FCardRAM) > 0 then
    State.Field(FCardRAM[0], Length(FCardRAM));
  State.Field(FTimerLoad, SizeOf(FTimerLoad));
  State.Field(FTimerValue, SizeOf(FTimerValue));
  State.Field(FTimerCycles, SizeOf(FTimerCycles));
  State.Field(FTimerEnabled, SizeOf(FTimerEnabled));
  State.Field(FTimerPending, SizeOf(FTimerPending));
  State.Field(FIRQMask, SizeOf(FIRQMask));
  State.Field(FWaitCycles, SizeOf(FWaitCycles));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineCycles, SizeOf(FLineCycles));
  State.Field(FIOBuffer, SizeOf(FIOBuffer));
  State.Field(FPadPort, SizeOf(FPadPort));
  State.Field(FPadControl, SizeOf(FPadControl));
  State.Field(FPadExtra, SizeOf(FPadExtra));
  State.Field(FAudioPhase, SizeOf(FAudioPhase));
  State.Field(FFrame.FrameNumber, SizeOf(FFrame.FrameNumber));
  State.Field(FFrame.Width, SizeOf(FFrame.Width));
  State.Field(FFrame.Height, SizeOf(FFrame.Height));
  if (FFrame.Width < 1) or (FFrame.Width > 1024) or (FFrame.Height < 1) or (FFrame.Height > 242) then
    raise EReadError.Create('Invalid PC Engine frame state');
  if State.Loading then
  begin
    SetLength(FFrame.Pixels, FFrame.Width * FFrame.Height);
    FSamples := nil;
  end;
  State.Field(FFrame.Pixels[0], Length(FFrame.Pixels) * SizeOf(TAlphaColor));
  if State.Loading and ((FLine < 0) or (FLine >= FVideo.Lines) or (FPadPort > 5) or
    (FTimerValue < 0) or (FTimerValue > 127)) then
    raise EReadError.Create('Invalid PC Engine timing state');
end;

end.

