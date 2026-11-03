unit WS.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.Math, HW.V30MZ,
  WS.Types, WS.Cartridge, WS.EEPROM, WS.Video, WS.Sound, Core.Emulation.Types,
  Core.Snapshots;

type
  TWSConsole = class
  private
    FCPU: TV30MZ;
    FCartridge: TWSCartridge;
    FSystemEEPROM: TWSEEPROM;
    FVideo: TWSVideo;
    FSound: TWSSound;
    FRAM: TWSRAM;
    FIO: TWSIO;
    FBIOS: TBytes;
    FColor: Boolean;
    FLine, FLineClock, FDMACycles, FSoundDMAClock, FSoundDMARate, FSerialClock: Integer;
    FSoundSource, FSoundLength: Cardinal;
    FFrames: UInt64;
    FTime: Int64;
    FButtons: Word;
    FLastPolledKeys: Byte;
    FBootDisabled: Boolean;
    function ColorMode: Boolean;
    function CPUBus(Address: Cardinal): Integer;
    function PortBus(Address: Cardinal): Integer;
    function OpenBus: Byte;
    function PortMapped(Address: Cardinal): Boolean;
    function ReadPortAccess(Address: Cardinal; WordAccess: Boolean): Byte;
    procedure WritePortAccess(Address: Cardinal; Value: Byte; WordAccess: Boolean);
    procedure Advance(Cycles: Integer);
    procedure CPUClock(Cycles: Integer);
    procedure EndLine;
    procedure RaiseIRQ(Mask: Byte);
    procedure PollIRQ;
    procedure GeneralDMA;
    procedure SoundDMA;
    procedure Timer(Vertical: Boolean);
    function GetPixels: TArray<TAlphaColor>;
    function GetSamples: TArray<SmallInt>;
    function GetSampleFrames: Integer;
    function Keypad: Byte;
  public
    constructor Create(const ROM, BIOS: TBytes; Color: Boolean);
    destructor Destroy; override;
    procedure Reset;
    procedure PowerOff;
    procedure RunFrame;
    function Step: Integer;
    function ReadByte(Address: Cardinal): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    function ReadPort(Address: Cardinal): Byte;
    procedure WritePort(Address: Cardinal; Value: Byte);
    procedure SetInput(const Buttons: TEmulatorButtons);
    procedure Configure(Orientation, Palette: Integer; Headphones: Boolean);
    procedure SerializeState(State: TStateArchive);
    procedure LoadBackup(const Data: TBytes);
    procedure LoadSystemBackup(const Data: TBytes);
    function SystemBackup: TBytes;
    function Backup: TBytes;
    function BackupDirty: Boolean;
    function FramesPerSecond: Double;
    function FrameWidth: Integer;
    function FrameHeight: Integer;
    property CPU: TV30MZ read FCPU;
    property Cartridge: TWSCartridge read FCartridge;
    property Video: TWSVideo read FVideo;
    property Pixels: TArray<TAlphaColor> read GetPixels;
    property FrameNumber: UInt64 read FFrames;
    property SampleFrames: Integer read GetSampleFrames;
    property Samples: TArray<SmallInt> read GetSamples;
    property Clock: Int64 read FTime;
    property Scanline: Integer read FLine;
    property ScanlineClock: Integer read FLineClock;
  end;

implementation

{$Q-}{$R-}

constructor TWSConsole.Create(const ROM, BIOS: TBytes; Color: Boolean);
begin
  inherited Create;
  FCartridge := TWSCartridge.Create(ROM);
  FColor := Color;
  if (Length(BIOS) <> 0) and (Length(BIOS) <> $1000) and (Length(BIOS) <> $2000) then
    raise EReadError.Create('WonderSwan boot ROM must contain 4 KiB or 8 KiB');
  if (Length(BIOS) <> 0) and ((not FColor and (Length(BIOS) <> $1000)) or
    (FColor and (Length(BIOS) <> $2000))) then
    raise EReadError.Create('WonderSwan boot ROM does not match console model');
  FBIOS := Copy(BIOS);
  if FColor then
    FSystemEEPROM := TWSEEPROM.Create(2048, True)
  else
    FSystemEEPROM := TWSEEPROM.Create(128, True);
  var Profile := FSystemEEPROM.Battery;
  FillChar(Profile[0], Length(Profile), 0);
  var Name := 'RETROMUL';
  for var I := 1 to Length(Name) do
    Profile[$5F + I] := Ord(Name[I]) - $36;
  Profile[$70] := $00;
  Profile[$71] := $20;
  Profile[$72] := 1;
  Profile[$73] := 1;
  Profile[$76] := 1;
  Profile[$77] := Ord(FColor);
  Profile[$78] := $27;
  Profile[$7C] := 1;
  if FColor then
  begin
    Profile[$80] := 1;
    Profile[$81] := 1;
    Profile[$82] := $27;
    Profile[$83] := 3;
  end;
  FSystemEEPROM.LoadBattery(Profile);
  FCPU := TV30MZ.Create(ReadByte, WriteByte, ReadPort, WritePort);
  FCPU.HardwareColor := FColor;
  FCPU.BusInfo := CPUBus;
  FCPU.PortBusInfo := PortBus;
  FCPU.PortReadEvent := ReadPortAccess;
  FCPU.PortWriteEvent := WritePortAccess;
  FCPU.ClockEvent := CPUClock;
  FVideo := TWSVideo.Create(@FRAM, @FIO, FColor, FCartridge.Vertical);
  FSound := TWSSound.Create(@FRAM, @FIO);
  Reset;
end;

destructor TWSConsole.Destroy;
begin
  FCPU.Free;
  FSound.Free;
  FVideo.Free;
  FSystemEEPROM.Free;
  FCartridge.Free;
  inherited;
end;

procedure TWSConsole.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FIO, SizeOf(FIO), 0);
  if FColor then
    FillChar(FRAM[$FE00], $200, $FF);
  FIO[$16] := 158;
  FIO[$17] := 155;
  FIO[$A0] := $80 or (Ord(FColor) shl 1);
  FIO[$91] := $80;
  FIO[$94] := $F;
  FIO[$9E] := 3;
  FLine := 0;
  FLineClock := 0;
  FDMACycles := 0;
  FSoundDMAClock := 0;
  FSoundDMARate := 0;
  FSerialClock := 0;
  FSoundSource := 0;
  FSoundLength := 0;
  FFrames := 0;
  FTime := 0;
  FButtons := 0;
  FLastPolledKeys := 0;
  FCartridge.Reset;
  FSystemEEPROM.Reset;
  FCPU.Reset;
  FSound.Reset;
  FVideo.Reset;
  FBootDisabled := Length(FBIOS) = 0;
  if FBootDisabled then
  begin
    var ROM := FCartridge.ROM;
    FIO[$A0] := FIO[$A0] or 1 or (ROM[Length(ROM) - 4] and $C);
    FIO[$14] := 1;
    FIO[$B5] := $40;
    FIO[$1C] := $20;
    FIO[$1D] := $64;
    FIO[$1E] := $A8;
    FIO[$1F] := $FC;
    FIO[$20] := $00;
    FIO[$21] := $70;
    FIO[$22] := $00;
    FIO[$23] := $50;
    FIO[$24] := $00;
    FIO[$25] := $40;
    FIO[$26] := $00;
    FIO[$27] := $30;
    FIO[$28] := $00;
    FIO[$29] := $20;
    FIO[$2A] := $00;
    FIO[$2B] := $10;
    FIO[$30] := $30;
    FIO[$31] := $75;
    // Registers left by the boot ROM, rather than the CPU's power-on values.
    FillChar(FCPU.State.R, SizeOf(FCPU.State.R), 0);
    FillChar(FCPU.State.S, SizeOf(FCPU.State.S), 0);
    FCPU.State.S[1] := $FFFF;
    FCPU.State.R[4] := $2000;
    if FColor then
    begin
      FCPU.State.R[0] := $FF87;
      FCPU.State.R[3] := $43;
      FCPU.State.R[2] := 1;
      FCPU.State.R[6] := $435;
      FCPU.State.R[7] := $40B;
      FCPU.State.S[3] := $FE00;
      FCPU.State.Flags := $F086;
    end
    else
    begin
      FCPU.State.R[0] := $FF85;
      FCPU.State.R[3] := $40;
      FCPU.State.R[2] := 5;
      FCPU.State.R[6] := $23D;
      FCPU.State.R[7] := $40D;
      FCPU.State.S[3] := $FF00;
      FCPU.State.Flags := $F082;
      FIO[$80] := $E6;
      FIO[$81] := 7;
      FIO[$82] := $E6;
      FIO[$83] := 7;
    end;
    var Profile := FSystemEEPROM.Battery;
    for var I := 0 to 2 do
    begin
      Profile[$76 + I] := ROM[Length(ROM) - 10 + I];
      if FColor and FCartridge.Color then
        Profile[$80 + I] := Profile[$76 + I];
    end;
    FSystemEEPROM.LoadBattery(Profile);
    FSystemEEPROM.InitializeAfterBoot(ROM[Length(ROM) - 7] and $80 = 0);
    if FColor then
    begin
      FIO[$60] := $0A;
      FIO[$94] := 0;
      FLine := 127;
      FLineClock := 232;
    end
    else
    begin
      FLine := 26;
      FLineClock := 53;
    end;
    // Deterministic HLE phase, as captured by Mesen's boot-ROM handoff.
    FSoundDMAClock := FLineClock and 127;
    FVideo.BeginLine(True);
  end;
end;

procedure TWSConsole.PowerOff;
begin
end;

function TWSConsole.ColorMode: Boolean;
begin
  Result := FColor and (FIO[$60] and $80 <> 0);
end;

function TWSConsole.CPUBus(Address: Cardinal): Integer;
begin
  case Address shr 16 of
    0:
      Result := $101;
    1:
      if FColor and (FIO[$60] and 2 = 0) then
        Result := 1
      else
        Result := 2;
  else
    begin
      Result := 1 + Ord(FIO[$A0] and 8 <> 0);
      if FIO[$A0] and 4 <> 0 then
        Result := Result or $100;
    end;
  end;
end;

function TWSConsole.PortBus(Address: Cardinal): Integer;
begin
  Result := 1;
  if Address < $C0 then
    Result := Result or $100
  else if Address <= $FF then
    if not FColor or (FIO[$60] and 8 <> 0) then
      Result := 2;
end;

function TWSConsole.OpenBus: Byte;
begin
  if ColorMode then
    Result := 0
  else
    Result := $90;
end;

function TWSConsole.PortMapped(Address: Cardinal): Boolean;
begin
  // Only the SoC block is mirrored. EEPROM and cartridge use all 16 bits.
  Result := (Address <= $FF) or ((Address and $1FF) <= $B7);
end;

function TWSConsole.ReadByte(Address: Cardinal): Byte;
begin
  Address := Address and $FFFFF;
  if not FBootDisabled and (Length(FBIOS) > 0) and (Address >= $100000 - Cardinal(Length(FBIOS))) then
    Exit(FBIOS[Address - ($100000 - Cardinal(Length(FBIOS)))]);
  if Address < $10000 then
  begin
    if (Address < $4000) or ColorMode then
      Result := FRAM[Address]
    else
      Result := $FF;
  end
  else
    Result := FCartridge.ReadByte(Address);
end;

procedure TWSConsole.WriteByte(Address: Cardinal; Value: Byte);
begin
  Address := Address and $FFFFF;
  if Address < $10000 then
  begin
    if (Address < $4000) or ColorMode then
      FRAM[Address] := Value;
  end
  else
    FCartridge.WriteByte(Address, Value);
end;

function TWSConsole.Keypad: Byte;
begin
  Result := FIO[$B5] and $70;
  if Result and $10 <> 0 then
    Result := Result or ((FButtons shr 4) and 15);
  if Result and $20 <> 0 then
    Result := Result or (FButtons and 15);
  if Result and $40 <> 0 then
    Result := Result or ((FButtons shr 8) and 14);
end;

function TWSConsole.ReadPort(Address: Cardinal): Byte;
begin
  Result := ReadPortAccess(Address, False);
end;

function TWSConsole.ReadPortAccess(Address: Cardinal; WordAccess: Boolean): Byte;
begin
  Address := Address and $FFFF;
  if not PortMapped(Address) then
    Exit(OpenBus);
  var Port := Byte(Address);
  if not FColor and (Port in [$60..$7F, $9E..$9F]) then
    Exit($90);
  if (Port in [$40..$5F]) and not ColorMode then
    if FColor then
      Exit(0)
    else
      Exit($90);
  if Port >= $C0 then
    Exit(FCartridge.ReadPort(Port));
  if Port in [$B8..$BF] then
  begin
    if (Port < $BA) or (not FColor and Odd(Port) and not WordAccess) then
      Exit(OpenBus);
    Exit(FSystemEEPROM.ReadPort(Port - $BA));
  end;
  if Port = $B4 then
  begin
    if (FSerialClock = 0) and (FIO[$B3] and $80 <> 0) then
      RaiseIRQ(1);
    if FCartridge.IRQ then
      RaiseIRQ(4);
  end;
  Result := FIO[Port];
  case Port of
    0:
      Result := Result and $3F;
    1:
      if not ColorMode then
        Result := Result and 7;
    2:
      Result := FLine;
    $18:
      Result := OpenBus;
    4:
      if not ColorMode then
        Result := Result and $1F;
    5:
      Result := Result and $7F;
    7:
      if not ColorMode then
        Result := Result and $77;
    $15:
      Result := Result and $3F;
    $19:
      if FColor then
        Result := 0
      else
        Result := $90;
    $1B, $43, $49, $4D, $51, $53..$5F, $61, $63..$69, $6C..$7F, $9F:
      Result := 0;
    $60, $62:
      if not FColor then
        Result := $90;
    $91:
      Result := FIO[$91];
    $A0:
      Result := FIO[$A0] or Byte(Ord(FBootDisabled));
    $B0:
      begin
        Result := FIO[$B0] and $F8;
        for var I := 7 downto 0 do
          if FIO[$B4] and (1 shl I) <> 0 then
          begin
            Result := Result or I;
            Break;
          end;
      end;
    $1A:
      Result := (FIO[$1A] and 1) or ((FIO[$91] shr 6) and 2) or ((FIO[$9E] and 3) shl 2) or ((FIO[$91] and 1) shl 4);
    $B1:
      Result := 0; // disconnected UART receive buffer
      $B3:
      Result := (FIO[$B3] and $C0) or (Ord((FSerialClock = 0) and (FIO[$B3] and $80 <> 0)) shl 2);
    $B5:
      Result := Keypad;
    $B6:
      Result := 0;
    $8E:
      Result := Result and not 8;
    $9E:
      if not FColor then
        Result := $90;
    $A1, $AC..$AF:
      if not FColor then
        Result := $90
      else
        Result := 0;
  end;
end;

procedure TWSConsole.WritePort(Address: Cardinal; Value: Byte);
begin
  WritePortAccess(Address, Value, False);
end;

procedure TWSConsole.WritePortAccess(Address: Cardinal; Value: Byte; WordAccess: Boolean);
var
  Old: Byte;
begin
  Address := Address and $FFFF;
  if not PortMapped(Address) then
    Exit;
  var Port := Byte(Address);
  if Port >= $C0 then
  begin
    FCartridge.WritePort(Port, Value, ColorMode);
    Exit;
  end;
  if Port in [$B8..$BF] then
  begin
    if (Port >= $BA) and (FColor or not Odd(Port) or WordAccess) then
      FSystemEEPROM.WritePort(Port - $BA, Value, ColorMode);
    Exit;
  end;
  if Port = $18 then
  begin
    FLine := Value;
    FVideo.BeginLine(False);
    Exit;
  end;
  // System test is a byte register, not the high byte of timer control.
  if (Port = $A3) and WordAccess then
    Exit;
  if (Port in [$40..$5F]) and not ColorMode then
    Exit;
  if (Port in [$60..$7F]) and not FColor then
    Exit;
  if (Port = $9E) and not FColor then
    Exit;
  if Port in [2, $19, $1B, $43, $49, $4D, $51, $53..$5F, $61, $63, $68, $6C..$7F, $92..$93, $96..$9B, $9F, $A1, $A8..$AB, $AD..$AF, $B4] then
    Exit;
  Old := FIO[Port];
  var BusValue := Value;
  case Port of
    0:
      Value := Value and $3F;
    4:
      Value := Value and $3F;
    5:
      Value := Value and $7F;
    $15:
      Value := Value and $3F;
    $20..$3F:
      if (Port in [$28, $2A, $2C, $2E, $38, $3A, $3C, $3E]) then
        Value := Value and $70
      else
        Value := Value and $77;
    $48:
      Value := Value and $C0;
    $52:
      begin
        Value := Value and $DF;
        if (FIO[$4E] or FIO[$4F] or FIO[$50]) = 0 then
          Value := Value and $7F;
      end;
    $4C, $50:
      Value := Value and $F;
    $6B:
      Value := Value and $6F;
    $81, $83, $85, $87:
      Value := Value and 7;
    $8D:
      Value := Value and $1F;
    $8E:
      Value := Value and $1F;
    $90:
      Value := Value and $EF;
    $94:
      Value := Value and $F;
    $A2, $A3:
      Value := Value and $F;
    $B3:
      Value := Value and $C0;
    $B7:
      Value := Value and $10;
    $14:
      if FColor then
        Value := Value and $F3
      else
        Value := Value and $F1;
    $1A:
      Value := Value and 1;
    $60:
      Value := Value and $EF;
    $91:
      Value := (Value and $F) or (Old and $80);
    $9E:
      Value := Value and 3;
    $A0:
      begin
        FBootDisabled := FBootDisabled or (Value and 1 <> 0);
        Value := (Value and $C) or $80 or (Ord(FColor) shl 1) or Ord(FBootDisabled);
      end;
    $B0:
      Value := Value and $F8;
    $B2:
      ;
    $B5:
      Value := Value and $70;
    $B6:
      begin
        FIO[$B4] := FIO[$B4] and not Value;
        Exit;
      end;
  end;
  FIO[Port] := Value;
  case Port of
    $40, $44, $46:
      FIO[Port] := Value and $FE;
    $42:
      FIO[Port] := Value and $F;
    $48:
      if Value and $80 <> 0 then
        GeneralDMA;
    $4A..$4C:
      begin
        var Shift := (Port - $4A) * 8;
        FSoundSource := (FSoundSource and not (Cardinal($FF) shl Shift)) or (Cardinal(Value) shl Shift);
      end;
    $4E..$50:
      begin
        var Shift := (Port - $4E) * 8;
        FSoundLength := (FSoundLength and not (Cardinal($FF) shl Shift)) or (Cardinal(Value) shl Shift);
      end;
    $52:
      if (Old and $80 = 0) and (Value and $80 <> 0) then
        FSoundDMARate := 0;
    $A4, $A5:
      begin
        FIO[$A8] := FIO[$A4];
        FIO[$A9] := FIO[$A5];
      end;
    $A6, $A7:
      begin
        FIO[$AA] := FIO[$A6];
        FIO[$AB] := FIO[$A7];
      end;
    $B1:
      if FIO[$B3] and $40 <> 0 then
        FSerialClock := 800
      else
        FSerialClock := 3200;
  end;
  if (Port in [$80..$9F, $64..$6B]) then
    if Port = $6B then
      FSound.WritePort(Port, BusValue)
    else
      FSound.WritePort(Port, Value);
end;

procedure TWSConsole.RaiseIRQ(Mask: Byte);
begin
  FIO[$B4] := FIO[$B4] or (FIO[$B2] and Mask);
end;

procedure TWSConsole.PollIRQ;
begin
  if (FSerialClock = 0) and (FIO[$B3] and $80 <> 0) then
    RaiseIRQ(1);
  if FCartridge.IRQ then
    RaiseIRQ(4);
  var Pending := FIO[$B4];
  for var I := 7 downto 0 do
    if Pending and (1 shl I) <> 0 then
    begin
      FCPU.Interrupt((FIO[$B0] and $F8) + I);
      Break;
    end;
end;

procedure TWSConsole.GeneralDMA;
var
  Source: Cardinal;
  Target, Count: Word;
  Delta: Integer;
begin
  Source := FIO[$40] or (Cardinal(FIO[$41]) shl 8) or (Cardinal(FIO[$42]) shl 16);
  Target := FIO[$44] or (Word(FIO[$45]) shl 8);
  Count := (FIO[$46] or (Word(FIO[$47]) shl 8)) and $FFFE;
  if (Count = 0) or (Source shr 16 = 1) or ((Source >= $20000) and (FIO[$A0] and $C <> 4)) then
  begin
    FIO[$48] := FIO[$48] and $7F;
    Exit;
  end;
  Delta := 2;
  if FIO[$48] and $40 <> 0 then
    Delta := -2;
  Inc(FDMACycles, 5);
  while Count <> 0 do
  begin
    WriteByte(Target, ReadByte(Source));
    WriteByte(Word(Target + 1), ReadByte((Source + 1) and $FFFFF));
    Source := Cardinal((Integer(Source) + Delta) and $FFFFF);
    Inc(Target, Delta);
    Dec(Count, 2);
    Inc(FDMACycles, 2);
  end;
  FIO[$40] := Byte(Source);
  FIO[$41] := Byte(Source shr 8);
  FIO[$42] := Source shr 16;
  FIO[$44] := Byte(Target);
  FIO[$45] := Target shr 8;
  FIO[$46] := 0;
  FIO[$47] := 0;
  FIO[$48] := FIO[$48] and $7F;
end;

procedure TWSConsole.SoundDMA;
const
  Divisors: array[0..3] of Integer = (6, 4, 2, 1);
begin
  if not ColorMode or (FIO[$52] and $80 = 0) then
    Exit;
  Inc(FSoundDMARate);
  if FSoundDMARate < Divisors[FIO[$52] and 3] then
    Exit;
  FSoundDMARate := 0;
  var Source := FIO[$4A] or (Cardinal(FIO[$4B]) shl 8) or (Cardinal(FIO[$4C] and 15) shl 16);
  var Count := FIO[$4E] or (Cardinal(FIO[$4F]) shl 8) or (Cardinal(FIO[$50]) shl 16);
  var Value: Byte := 0;
  if FIO[$52] and 4 = 0 then
  begin
    Value := ReadByte(Source);
    if FIO[$52] and $40 = 0 then
      Source := (Source + 1) and $FFFFF
    else
      Source := (Source - 1) and $FFFFF;
    Count := (Count - 1) and $FFFFFF;
  end;
  if FIO[$52] and $10 = 0 then
    FIO[$89] := Value
  else
    FSound.HyperDMA(Value);
  if Count = 0 then
    if FIO[$52] and 8 <> 0 then
    begin
      Source := FSoundSource;
      Count := FSoundLength;
    end
    else
      FIO[$52] := FIO[$52] and $7F;
  FIO[$4A] := Byte(Source);
  FIO[$4B] := Byte(Source shr 8);
  FIO[$4C] := Source shr 16;
  FIO[$4E] := Byte(Count);
  FIO[$4F] := Byte(Count shr 8);
  FIO[$50] := Count shr 16;
  Inc(FDMACycles, 6 + (CPUBus(Source) and $FF));
end;

procedure TWSConsole.Timer(Vertical: Boolean);
begin
  var Base := $A8;
  var Mask := 1;
  var IRQ := $80;
  if Vertical then
  begin
    Base := $AA;
    Mask := 4;
    IRQ := $20;
  end;
  var Counter: Word := FIO[Base] or (Word(FIO[Base + 1]) shl 8);
  if Counter = 1 then
    RaiseIRQ(IRQ);
  if (FIO[$A2] and Mask = 0) or (Counter = 0) then
    Exit;
  Dec(Counter);
  if (Counter = 0) and (FIO[$A2] and (Mask shl 1) <> 0) then
    Counter := FIO[Base - 4] or (Word(FIO[Base - 3]) shl 8);
  FIO[Base] := Byte(Counter);
  FIO[Base + 1] := Counter shr 8;
end;

procedure TWSConsole.EndLine;
begin
  var LastLine := FLine;
  FLine := (FLine + 1) and $FF;
  var FrameStart := LastLine = FIO[$16];
  if FrameStart then
    FLine := 0;
  FVideo.BeginLine(FrameStart);
  if FLine = WS_HEIGHT then
  begin
    RaiseIRQ($40);
    Timer(True);
    var Keys := Keypad and 7;
    if Keys and not FLastPolledKeys <> 0 then
      RaiseIRQ(2);
    FLastPolledKeys := Keys;
  end;
  if FrameStart then
  begin
    FLine := 0;
    Inc(FFrames);
    FVideo.EndFrame;
  end;
  if FLine = FIO[3] then
    RaiseIRQ($10);
end;

procedure TWSConsole.Advance(Cycles: Integer);
begin
  while Cycles > 0 do
  begin
    var Chunk := Min(Cycles, Min(256 - FLineClock, 128 - FSoundDMAClock));
    // Stop at HBlank so its timer edge is visible before end-of-line.
    if FLineClock < 224 then
      Chunk := Min(Chunk, 224 - FLineClock);
    FVideo.Tick(FLine, FLineClock, Chunk);
    FSound.Tick(Chunk);
    FSystemEEPROM.Tick(Chunk);
    FCartridge.Tick(Chunk);
    Inc(FTime, Chunk);
    Inc(FLineClock, Chunk);
    Inc(FSoundDMAClock, Chunk);
    Dec(Cycles, Chunk);
    if FSerialClock > 0 then
      FSerialClock := Max(0, FSerialClock - Chunk);
    if FSoundDMAClock = 128 then
    begin
      FSoundDMAClock := 0;
      SoundDMA;
    end;
    if FLineClock = 224 then
    begin
      Timer(False);
    end;
    if FLineClock = 256 then
    begin
      FLineClock := 0;
      EndLine;
    end;
  end;
end;

procedure TWSConsole.CPUClock(Cycles: Integer);
begin
  Advance(Cycles);
  while FDMACycles > 0 do
  begin
    var DMA := FDMACycles;
    FDMACycles := 0;
    Advance(DMA);
    Inc(FCPU.State.Cycles, Cardinal(DMA));
  end;
end;

function TWSConsole.Step: Integer;
begin
  var Before := FTime;
  PollIRQ;
  FCPU.Step;
  Result := FTime - Before;
end;

procedure TWSConsole.RunFrame;
begin
  FSound.BeginFrame;
  var Frame := FFrames;
  repeat
    Step
  until FFrames <> Frame;
end;

procedure TWSConsole.Configure(Orientation, Palette: Integer; Headphones: Boolean);
begin
  FVideo.Configure(Orientation, Palette);
  FIO[$91] := (FIO[$91] and $7F) or (Ord(Headphones) shl 7);
end;

procedure TWSConsole.SetInput(const Buttons: TEmulatorButtons);
const
  Dirs: array[0..3] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Right, TEmulatorButton.Down, TEmulatorButton.Left);
  YDirs: array[0..3] of TEmulatorButton = (TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.C);
begin
  FButtons := 0;
  for var I := 0 to 3 do
    if not FVideo.Vertical then
    begin
      if Dirs[I] in Buttons then
        FButtons := FButtons or (1 shl I);
      if YDirs[I] in Buttons then
        FButtons := FButtons or (1 shl (I + 4));
    end
    else
    begin
      if Dirs[I] in Buttons then
        FButtons := FButtons or (1 shl (((I + 3) and 3) + 4));
      if YDirs[I] in Buttons then
        FButtons := FButtons or (1 shl ((I + 3) and 3));
    end;
  if TEmulatorButton.Start in Buttons then
    FButtons := FButtons or $200;
  if TEmulatorButton.A in Buttons then
    FButtons := FButtons or $400;
  if TEmulatorButton.B in Buttons then
    FButtons := FButtons or $800;
end;

function TWSConsole.GetPixels: TArray<TAlphaColor>;
begin
  Result := FVideo.Pixels;
end;

function TWSConsole.GetSamples: TArray<SmallInt>;
begin
  Result := FSound.Samples;
end;

function TWSConsole.GetSampleFrames: Integer;
begin
  Result := FSound.SampleFrames;
end;

function TWSConsole.FrameWidth: Integer;
begin
  Result := FVideo.FrameWidth;
end;

function TWSConsole.FrameHeight: Integer;
begin
  Result := FVideo.FrameHeight;
end;

function TWSConsole.FramesPerSecond: Double;
begin
  Result := WS_CLOCK / (256.0 * (Integer(FIO[$16]) + 1));
end;

function TWSConsole.SystemBackup: TBytes;
begin
  Result := FSystemEEPROM.Battery;
end;

function TWSConsole.Backup: TBytes;
begin
  Result := FCartridge.Backup;
end;

function TWSConsole.BackupDirty: Boolean;
begin
  Result := FCartridge.BackupDirty;
end;

procedure TWSConsole.LoadBackup(const Data: TBytes);
begin
  FCartridge.LoadBackup(Data);
end;

procedure TWSConsole.LoadSystemBackup(const Data: TBytes);
begin
  FSystemEEPROM.LoadBattery(Data);
  if FBootDisabled then
  begin
    var Profile := FSystemEEPROM.Battery;
    var ROM := FCartridge.ROM;
    for var I := 0 to 2 do
    begin
      Profile[$76 + I] := ROM[Length(ROM) - 10 + I];
      if FColor and FCartridge.Color then
        Profile[$80 + I] := Profile[$76 + I];
    end;
    FSystemEEPROM.LoadBattery(Profile);
  end;
end;

procedure TWSConsole.SerializeState(State: TStateArchive);
begin
  FCPU.SerializeState(State);
  FCartridge.SerializeState(State);
  FSystemEEPROM.SerializeState(State);
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FIO, SizeOf(FIO));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineClock, SizeOf(FLineClock));
  State.Field(FDMACycles, SizeOf(FDMACycles));
  State.Field(FSoundDMAClock, SizeOf(FSoundDMAClock));
  State.Field(FSoundDMARate, SizeOf(FSoundDMARate));
  State.Field(FSerialClock, SizeOf(FSerialClock));
  State.Field(FSoundSource, SizeOf(FSoundSource));
  State.Field(FSoundLength, SizeOf(FSoundLength));
  State.Field(FFrames, SizeOf(FFrames));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FLastPolledKeys, SizeOf(FLastPolledKeys));
  State.Field(FButtons, SizeOf(FButtons));
  State.Field(FBootDisabled, SizeOf(FBootDisabled));
  FSound.SerializeState(State);
  FVideo.SerializeState(State);
  if State.Loading then
    if (FLine < 0) or (FLine > 255) or (FLineClock < 0) or (FLineClock > 255) or
      (FSoundDMAClock < 0) or (FSoundDMAClock > 127) or (FDMACycles < 0) or
      (FDMACycles > $20000) then
      raise EReadError.Create('Invalid WonderSwan timing state');
end;

end.

