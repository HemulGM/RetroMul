unit NGP.Console;

interface

uses
  System.Classes, System.SysUtils, System.UITypes, System.DateUtils, HW.TLCS900H,
  HW.Z80, NGP.Cartridge, NGP.Video, NGP.Sound, Core.Emulation.Types,
  Core.Snapshots;

const
  NGP_CLOCK = 6144000;
  NGP_LINE_CYCLES = 515;

type
  TNGPWriteObserver = reference to procedure(Address: Cardinal; Value: Byte);

  TNGPConsole = class
  private
    FCartridge: TNGPCartridge;
    FBIOS: TBytes;
    FCPU: TTLCS900H;
    FZ80: TZ80State;
    FZBus: TZ80ReadAndWriteCallbacks;
    FVideo: TNGPVideo;
    FSound: TNGPSound;
    FRAM: array[$4000..$7FFF] of Byte;
    FIO: array[0..$FF] of Byte;
    FTimers: array[0..3] of Byte;
    FPrescaler, FRTCPhase, FSamplePhase: Int64;
    FTime, FZTime, FNextLine: Int64;
    FFrames: UInt64;
    FLine: Integer;
    FLineStart: Int64;
    FADCycles: Integer;
    FZEnabled, FTimerFF3, FPowerPending, FZSignal: Boolean;
    FButtons: Byte;
    FRTC: TDateTime;
    FSamples: TArray<SmallInt>;
    FSampleFrames: Integer;
    FWriteObserver: TNGPWriteObserver;
    function GetPixels: TArray<TAlphaColor>;
    procedure Advance(Cycles: Integer);
    procedure TickTimer(Index, Count: Integer);
    procedure CheckInterrupts;
    procedure SetRequest(Vector: Integer);
    procedure WriteRTC(Address: Cardinal; Value: Byte);
    class function ZRead(User: Pointer; Address: Cardinal): Cardinal; static;
    class procedure ZWrite(User: Pointer; Address, Value: Cardinal); static;
    class function ZPortRead(User: Pointer; Address: Cardinal): Cardinal; static;
    class procedure ZPortWrite(User: Pointer; Address, Value: Cardinal); static;
  public
    constructor Create(const ROM, BIOS: TBytes; Color: Boolean);
    destructor Destroy; override;
    procedure Reset;
    procedure PowerOff;
    procedure RunFrame;
    function ReadByte(Address: Cardinal): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    procedure SetInput(const Buttons: TEmulatorButtons);
    procedure SerializeState(State: TStateArchive);
    procedure LoadBackup(const Data: TBytes);
    procedure LoadSystemBackup(const Data: TBytes);
    function SystemBackup: TBytes;
    function Backup: TBytes;
    function BackupDirty: Boolean;
    function FramesPerSecond: Double;
    function FrameWidth: Integer;
    function FrameHeight: Integer;
    property CPU: TTLCS900H read FCPU;
    property Z80State: TZ80State read FZ80;
    property Cartridge: TNGPCartridge read FCartridge;
    property Video: TNGPVideo read FVideo;
    property Sound: TNGPSound read FSound;
    property Pixels: TArray<TAlphaColor> read GetPixels;
    property FrameNumber: UInt64 read FFrames;
    property SampleFrames: Integer read FSampleFrames;
    property Samples: TArray<SmallInt> read FSamples;
    property WriteObserver: TNGPWriteObserver read FWriteObserver write FWriteObserver;
  end;

implementation

const
  IRQRegisters: array[0..21] of Byte = ($70, $71, $71, $72, $72, $73, $73, $74, $74, $75, $75, $76, $76, $77, $77, $78, $78, $70, $79, $79, $7A, $7A);
  IRQVectors: array[0..21] of Byte = ($28, $2C, $30, $34, $38, $40, $44, $48, $4C, $50, $54, $58, $5C, $60, $64, $68, $6C, $70, $74, $78, $7C, $80);
  IRQMasks: array[0..21] of Byte = (8, 8, $80, 8, $80, 8, $80, 8, $80, 8, $80, 8, $80, 8, $80, 8, $80, $80, 8, $80, 8, $80);

constructor TNGPConsole.Create(const ROM, BIOS: TBytes; Color: Boolean);
begin
  inherited Create;
  FCartridge := TNGPCartridge.Create(ROM);
  if Length(BIOS) <> $10000 then
    raise EReadError.Create('Neo Geo Pocket BIOS must contain exactly 64 KiB');

  FBIOS := Copy(BIOS);
  var Vector := Cardinal(BIOS[$FF00]) or (Cardinal(BIOS[$FF01]) shl 8) or (Cardinal(BIOS[$FF02]) shl 16);
  if Vector < $FF0000 then
    raise EReadError.Create('Invalid Neo Geo Pocket BIOS reset vector');

  FCPU := TTLCS900H.Create(ReadByte, WriteByte);
  FVideo := TNGPVideo.Create(Color);
  FSound := TNGPSound.Create;
  FZBus.ReadCallback := ZRead;
  FZBus.WriteCallback := ZWrite;
  FZBus.PortReadCallback := ZPortRead;
  FZBus.PortWriteCallback := ZPortWrite;
  FZBus.UserData := Self;
  FRTC := Now;
  SetLength(FSamples, 2048);
  Reset;
end;

destructor TNGPConsole.Destroy;
begin
  FCPU.Free;
  FVideo.Free;
  FSound.Free;
  FCartridge.Free;
  inherited;
end;

procedure TNGPConsole.Reset;
begin
  if FCPU <> nil then
    PowerOff;
  var SystemRAM := SystemBackup;
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FIO, SizeOf(FIO), 0);
  FillChar(FTimers, SizeOf(FTimers), 0);
  FIO[6] := $FF;
  FIO[$0D] := $3D;
  FIO[$12] := $3B;
  FIO[$13] := $FF;
  FIO[$18] := $3F;
  FIO[$19] := $0F;
  FIO[$1C] := $FF;
  FIO[$25] := $CC;
  FIO[$6E] := $80;
  FIO[$B8] := $AA;
  FIO[$B9] := $AA;
  FIO[$B1] := 2;
  FTime := 0;
  FZTime := 0;
  FNextLine := NGP_LINE_CYCLES;
  FPrescaler := 0;
  FRTCPhase := 0;
  FSamplePhase := 0;
  FLine := 0;
  FLineStart := 0;
  FFrames := 0;
  FADCycles := 0;
  FZEnabled := False;
  FTimerFF3 := False;
  FSampleFrames := 0;
  FPowerPending := True;
  FZSignal := False;
  FVideo.Reset;
  FSound.Reset;
  FCartridge.Reset;
  Z80StateInitialise(FZ80);
  Z80Reset(FZ80);
  FCPU.Reset;
  FVideo.BeginLine(0);
  if Length(SystemRAM) > 0 then
    LoadSystemBackup(SystemRAM);
end;

function BCD(Value: Integer): Byte;
begin
  Result := (Value div 10) * 16 + Value mod 10;
end;

function TNGPConsole.ReadByte(Address: Cardinal): Byte;
begin
  Address := Address and $FFFFFF;
  Result := $FF;
  case Address of
    $0000..$00FF:
      begin
        Result := FIO[Address];
        case Address of
          $60..$67:
            begin
              Result := $FF;
              FIO[$6D] := FIO[$6D] and $7F;
              if not Odd(Address) then
                FIO[$70] := FIO[$70] and $7F;
            end;
          $91:
            Result := BCD(YearOf(FRTC) mod 100);
          $92:
            Result := BCD(MonthOf(FRTC));
          $93:
            Result := BCD(DayOf(FRTC));
          $94:
            Result := BCD(HourOf(FRTC));
          $95:
            Result := BCD(MinuteOf(FRTC));
          $96:
            Result := BCD(SecondOf(FRTC));
          $97:
            Result := ((YearOf(FRTC) mod 4) shl 4) or (DayOfTheWeek(FRTC) mod 7);
          $B0:
            Result := FButtons;
          $B1:
            Result := 2;
        end;
      end;
    $4000..$7FFF:
      Result := FRAM[Address];
    $8000..$BFFF:
      Result := FVideo.ReadByte(Address - $8000, FLine, Integer(FTime - FLineStart));
    $200000..$3FFFFF:
      Result := FCartridge.ReadByte(Address - $200000);
    $800000..$9FFFFF:
      Result := FCartridge.ReadByte(Address - $800000 + $200000);
    $FF0000..$FFFFFF:
      Result := FBIOS[Address and $FFFF];
  end;
end;

procedure TNGPConsole.WriteByte(Address: Cardinal; Value: Byte);
begin
  Address := Address and $FFFFFF;
  if Assigned(FWriteObserver) then
    FWriteObserver(Address, Value);
  case Address of
    $0000..$00FF:
      begin
        case Address of
          $1E:
            if (Value and 8 <> 0) and (FIO[$1E] and 8 = 0) then
              Z80Interrupt(FZ80, 1);
          $20:
            for var i := 0 to 3 do
              if Value and (1 shl i) = 0 then
                FTimers[i] := 0;
          $25:
            begin
              var OldFF := FTimerFF3;
              case Value and $C0 of
                0:
                  FTimerFF3 := not FTimerFF3;
                $40:
                  FTimerFF3 := True;
                $80:
                  FTimerFF3 := False;
              end;
              if FTimerFF3 and not OldFF then
                Z80Interrupt(FZ80, 1);
              Value := Value or $CC;
            end;
          $6D:
            begin
              Value := (FIO[$6D] and $C0) or (Value and $3F);
              if Value and 4 <> 0 then
              begin
                Value := (Value and $FB) or $40;
                if Value and 8 <> 0 then
                  FADCycles := 320
                else
                  FADCycles := 160;
              end;
            end;
          $70..$7A:
            begin
              // Pending flip-flops are cleared by writing zero; one preserves.
              Value := (Value and $77) or (Value and FIO[Address] and $88);
            end;
          $91..$96:
            WriteRTC(Address, Value);
          $A0, $A1:
            if (FIO[$B8] = $55) and (FIO[$B9] = $AA) then
              FSound.Write(Address and 1, Value);
          $A2:
            FSound.DACRight := Value;
          $A3:
            FSound.DACLeft := Value;
          $B8:
            if Value = $55 then
              FSound.Enabled := True
            else if Value = $AA then
              FSound.Enabled := False;
          $B9:
            begin
              if Value = $55 then
              begin
                FZEnabled := True;
                Z80Reset(FZ80);
                FZTime := FTime;
              end
              else if Value = $AA then
                FZEnabled := False;
            end;
          $BA:
            Z80NonMaskableInterrupt(FZ80);
        end;
        FIO[Address] := Value;
      end;
    $4000..$7FFF:
      FRAM[Address] := Value;
    $8000..$BFFF:
      FVideo.WriteByte(Address - $8000, Value);
    $200000..$3FFFFF:
      FCartridge.WriteByte(Address - $200000, Value);
    $800000..$9FFFFF:
      FCartridge.WriteByte(Address - $800000 + $200000, Value);
  end;
end;

class function TNGPConsole.ZRead(User: Pointer; Address: Cardinal): Cardinal;
begin
  var C := TNGPConsole(User);
  case Address and $FFFF of
    $0000..$0FFF:
      Result := C.FRAM[$7000 + (Address and $FFF)];
    $8000:
      Result := C.FIO[$BC];
  else
    Result := $FF;
  end;
end;

class procedure TNGPConsole.ZWrite(User: Pointer; Address, Value: Cardinal);
begin
  var C := TNGPConsole(User);
  case Address and $FFFF of
    $0000..$0FFF:
      C.FRAM[$7000 + (Address and $FFF)] := Byte(Value);
    $4000, $4001:
      C.FSound.Write(Address and 1, Byte(Value));
    $8000:
      C.FIO[$BC] := Byte(Value);
    $C000:
      if not C.FZSignal then
      begin
        C.FZSignal := True;
        C.SetRequest($30);
      end;
  end;
end;

class function TNGPConsole.ZPortRead(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := $FF;
end;

class procedure TNGPConsole.ZPortWrite(User: Pointer; Address, Value: Cardinal);
begin
  var C := TNGPConsole(User);
  Z80Interrupt(C.FZ80, 0);
  C.FZSignal := False;
end;

procedure TNGPConsole.SetRequest(Vector: Integer);
begin
  for var i := 0 to High(IRQVectors) do
    if IRQVectors[i] = Vector then
    begin
      FIO[IRQRegisters[i]] := FIO[IRQRegisters[i]] or IRQMasks[i];
      Break;
    end;
end;

procedure TNGPConsole.CheckInterrupts;
begin
  // Opening a game powers the handheld on. The original BIOS first arms
  // the power NMI and enters standby; deliver a power-button release then.
  if FPowerPending and (FTime >= NGP_CLOCK div 4) and (FIO[$B3] and 4 <> 0) then
  begin
    FPowerPending := False;
    FCPU.NonMaskableInterrupt;
    Advance(18);
    Exit;
  end;

  var Best := -1;
  var BestLevel := 0;
  for var i := 0 to High(IRQVectors) do
  begin
    var Control := FIO[IRQRegisters[i]];
    if Control and IRQMasks[i] = 0 then
      Continue;

    var Level: Integer;
    if IRQMasks[i] = 8 then
      Level := Control and 7
    else
      Level := (Control shr 4) and 7;
    // A configured micro-DMA consumes its request without a CPU exception.
    var DMAOwned := False;
    if FCPU.SR and $7000 <> $7000 then
      for var Ch := 0 to 3 do
        if ((FIO[$7C + Ch] and $1F) * 4 = IRQVectors[i]) and (FIO[$7C + Ch] <> 0) then
        begin
          var Finished: Boolean;
          var Cycles := FCPU.MicroDMA(Ch, Finished);
          if Cycles > 0 then
          begin
            FIO[IRQRegisters[i]] := FIO[IRQRegisters[i]] and not IRQMasks[i];
            if Finished then
            begin
              FIO[$7C + Ch] := 0;
              SetRequest($74 + Ch * 4);
            end;
            Advance(Cycles);
            DMAOwned := True;
          end;
          Break;
        end;

    if DMAOwned then
      Continue;

    if (Level > 0) and (Level < 7) and (Level >= BestLevel) then
    begin
      Best := i;
      BestLevel := Level;
    end;
  end;
  if (Best >= 0) and FCPU.Interrupt(IRQVectors[Best], BestLevel) then
  begin
    FIO[IRQRegisters[Best]] := FIO[IRQRegisters[Best]] and not IRQMasks[Best];
    Advance(18);
  end;
end;

procedure TNGPConsole.TickTimer(Index, Count: Integer);
begin
  if FIO[$20] and (1 shl Index) = 0 then
    Exit;

  var Mode := FIO[$24 + (Index div 2) * 4];
  while Count > 0 do
  begin
    Dec(Count);
    FTimers[Index] := Byte((Integer(FTimers[Index]) + 1) and 255);
    if FTimers[Index] <> FIO[$22 + (Index div 2) * 4 + (Index and 1)] then
      Continue;

    if not Odd(Index) then
    begin
      if Mode and $0C = 0 then
        TickTimer(Index + 1, 1);
      if Mode and $C0 = $40 then
        Continue;
    end
    else if Mode and $C0 = $40 then
      FTimers[Index - 1] := 0;

    FTimers[Index] := 0;
    SetRequest($40 + Index * 4);
    if (Index = 3) and (FIO[$25] and $20 <> 0) then
    begin
      FTimerFF3 := not FTimerFF3;
      if FTimerFF3 then
        Z80Interrupt(FZ80, 1);
    end;
  end;
end;

procedure TNGPConsole.Advance(Cycles: Integer);
const
  EvenShift: array[0..3] of Integer = (0, 7, 9, 11);
  OddShift: array[0..3] of Integer = (0, 7, 11, 15);
begin
  var OldPre := FPrescaler;
  if FIO[$20] and $80 <> 0 then
    Inc(FPrescaler, Cycles);
  for var i := 0 to 3 do
  begin
    var Mode := (FIO[$24 + (i div 2) * 4] shr ((i and 1) * 2)) and 3;
    var Shift: Integer;
    if Odd(i) then
      Shift := OddShift[Mode]
    else
      Shift := EvenShift[Mode];
    if (i = 2) and (Mode = 0) then
      Shift := 7;
    if Shift > 0 then
      TickTimer(i, Integer((FPrescaler shr Shift) - (OldPre shr Shift)));
  end;
  if FADCycles > 0 then
  begin
    Dec(FADCycles, Cycles);
    if FADCycles <= 0 then
    begin
      FIO[$6D] := (FIO[$6D] and $BF) or $80;
      SetRequest($70);
      if FIO[$6D] and $20 <> 0 then
        if FIO[$6D] and 8 <> 0 then
          FADCycles := 320
        else
          FADCycles := 160;
    end;
  end;
  Inc(FTime, Cycles);
  Inc(FRTCPhase, Cycles);
  if FRTCPhase >= NGP_CLOCK then
  begin
    Dec(FRTCPhase, NGP_CLOCK);
    FRTC := IncSecond(FRTC);
  end;
  FSound.Advance(Cycles);
  Inc(FSamplePhase, Int64(Cycles) * 44100);
  while FSamplePhase >= NGP_CLOCK do
  begin
    Dec(FSamplePhase, NGP_CLOCK);
    if FSampleFrames * 2 + 1 >= Length(FSamples) then
      SetLength(FSamples, Length(FSamples) + 2048);
    FSound.Sample(FSamples[FSampleFrames * 2], FSamples[FSampleFrames * 2 + 1]);
    Inc(FSampleFrames);
  end;
  if FZEnabled then
    while FZTime < FTime do
      Inc(FZTime, Int64(Z80DoInstruction(FZ80, FZBus)) * 2)
  else
    FZTime := FTime;
  while FTime >= FNextLine do
  begin
    FVideo.DrawLine(FLine);
    FLine := (FLine + 1) mod NGP_LINES;
    if FLine = 0 then
      Inc(FFrames);
    FLineStart := FNextLine;
    Inc(FNextLine, NGP_LINE_CYCLES);
    FVideo.BeginLine(FLine);
    if (FLine = 152) and FVideo.VBlankEnabled then
      SetRequest($2C);
    if ((FLine < 151) or (FLine = 198)) and FVideo.HBlankEnabled and (FIO[$24] and 3 = 0) then
      TickTimer(0, 1);
  end;
end;

procedure TNGPConsole.RunFrame;
begin
  FSampleFrames := 0;
  var Target := FFrames + 1;
  while FFrames < Target do
  begin
    CheckInterrupts;
    Advance(FCPU.Step);
  end;
end;

procedure TNGPConsole.SetInput(const Buttons: TEmulatorButtons);
const
  Map: array[0..6] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start);
begin
  FButtons := 0;
  for var i := 0 to 6 do
    if Map[i] in Buttons then
      FButtons := FButtons or (1 shl i);
  if TEmulatorButton.Select in Buttons then
    FButtons := FButtons or $40;
end;

function TNGPConsole.GetPixels: TArray<TAlphaColor>;
begin
  Result := FVideo.Pixels;
end;

function TNGPConsole.FramesPerSecond: Double;
begin
  Result := NGP_CLOCK / (NGP_LINE_CYCLES * NGP_LINES);
end;

function TNGPConsole.FrameWidth: Integer;
begin
  Result := NGP_WIDTH;
end;

function TNGPConsole.FrameHeight: Integer;
begin
  Result := NGP_HEIGHT;
end;

procedure TNGPConsole.LoadBackup(const Data: TBytes);
begin
  FCartridge.LoadBackup(Data);
end;

function TNGPConsole.Backup: TBytes;
begin
  Result := FCartridge.Backup;
end;

function TNGPConsole.BackupDirty: Boolean;
begin
  Result := FCartridge.Dirty;
end;

procedure TNGPConsole.WriteRTC(Address: Cardinal; Value: Byte);
begin
  var N := (Value shr 4) * 10 + (Value and 15);
  var Y, M, D, H, Min, S, MS: Word;
  DecodeDateTime(FRTC, Y, M, D, H, Min, S, MS);
  case Address of
    $91:
      if N >= 90 then
        Y := 1900 + N
      else
        Y := 2000 + N;
    $92:
      M := N;
    $93:
      D := N;
    $94:
      H := N;
    $95:
      Min := N;
    $96:
      S := N;
  end;
  var Date: TDateTime;
  if TryEncodeDateTime(Y, M, D, H, Min, S, 0, Date) then
    FRTC := Date;
end;

procedure TNGPConsole.PowerOff;
begin
  if (FIO[$B6] <> $05) or (FIO[$B3] and 4 = 0) then
    Exit;

  FCPU.NonMaskableInterrupt;

  // The firmware and game finish the power-off callback, flush cartridge
  // data and checksum system settings before the battery-backed RAM is saved.
  for var i := 1 to 120 do
  begin
    RunFrame;
    if FIO[$B6] = $50 then
      Break;
  end;
end;

function TNGPConsole.SystemBackup: TBytes;
begin
  Result := nil;
  if (FRAM[$6C7A] <> $A5) or (FRAM[$6C7B] <> $A5) then
    Exit;

  SetLength(Result, $3020);
  Move(FRAM[$4000], Result[0], $3000);
  Move(FIO[$80], Result[$3000], $20);
end;

procedure TNGPConsole.LoadSystemBackup(const Data: TBytes);
begin
  if (Length(Data) <> $3020) or (Data[$2C7A] <> $A5) or (Data[$2C7B] <> $A5) then
    raise EReadError.Create('Invalid Pocket system RAM save');

  Move(Data[0], FRAM[$4000], $3000);
  Move(Data[$3000], FIO[$80], $20);

  // The original firmware has a separate battery-backed warm-start vector.
  FCPU.Reset;
  FCPU.PC := $FF1800;
  FPowerPending := False;
end;

procedure TNGPConsole.SerializeState(State: TStateArchive);
begin
  FCPU.SerializeState(State);
  FCartridge.SerializeState(State);
  FVideo.SerializeState(State);
  FSound.SerializeState(State);
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FIO, SizeOf(FIO));
  State.Field(FTimers, SizeOf(FTimers));
  State.Field(FZ80, SizeOf(FZ80));
  State.Field(FPrescaler, SizeOf(FPrescaler));
  State.Field(FRTCPhase, SizeOf(FRTCPhase));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FZTime, SizeOf(FZTime));
  State.Field(FNextLine, SizeOf(FNextLine));
  State.Field(FFrames, SizeOf(FFrames));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineStart, SizeOf(FLineStart));
  State.Field(FADCycles, SizeOf(FADCycles));
  State.Field(FZEnabled, SizeOf(FZEnabled));
  State.Field(FTimerFF3, SizeOf(FTimerFF3));
  State.Field(FPowerPending, SizeOf(FPowerPending));
  State.Field(FZSignal, SizeOf(FZSignal));
  State.Field(FButtons, SizeOf(FButtons));
  State.Field(FRTC, SizeOf(FRTC));

  if State.Loading then
  begin
    if (FLine < 0) or (FLine >= NGP_LINES) or (FNextLine <= FTime) or (FNextLine - FTime > NGP_LINE_CYCLES) then
      raise EReadError.Create('Invalid Pocket scheduler state');

    FSampleFrames := 0;
  end;
end;

initialization
  HW.Z80.ConstantInitialise;

end.

