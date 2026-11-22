unit NES.Mapper.Fcns;

interface

uses
  System.SysUtils, System.UITypes, NES.Mapper, NES.Mapper.Mmc1, NES.State,
  NES.Types, HW.W65C02;

const
  FCNS_CONSOLE_TYPE = $0C;
  FCNS_EXPANSION_CONTROLLER = $3B;
  FCNS_HOST_KEYS: set of Byte = [vk0..vk9, vkNumpad0..vkNumpad9, vkMultiply, vkAdd, vkPeriod, vkDecimal, vkDelete, vkEnd];
  FCNS_KANJI_SIZE = $40000;
  FCNS_CPU2_ROM_SIZE = $2000;
  FCNS_KANJI_DUMP_SHA1 = 'f145c87fcee0001521ab24f33ef172cd3053fdfb';
  FCNS_KANJI_LINEAR_SHA1 = '34759eda336f497d372694b44db44f93b047b61e';
  FCNS_CPU2_ROM_SHA1 = '1fbba4480e8354cb55f53b1444d15b340388e782';

type
  TRf5a18Timer = packed record
    Period: Word;
    Counter: Integer;
    Repeating, Pending: Boolean;
    procedure Restart(Value: Byte; Prescaler: Integer);
    function Clock(Prescaler: Integer): Boolean;
  end;

  // The later FCNS adapter connects the card to the CPU and owns the PPU bus.
  TMapperFcns = class(TMapperMmc1TwoMe)
  private
    FKanji, FCpu2Rom: TBytes;
    FCpu2: TW65C02;
    FCpu2Ram, FAdapterRam: array[0..$1FFF] of Byte;
    FChrRam: array[0..$3FFF] of Byte;
    FToCpu2, FToFamicom: array[0..3] of Byte;
    FCpu2Bus, FCardBus, FCpu2Mask, FExpansion, FUartMode: Byte;
    FCpu2Running, FCpu2Nmi: Boolean;
    FCpu2NmiTimer, FCpu2IrqTimer: TRf5a18Timer;
    FCpuClockHz, FCpu2Phase, FCpu2CyclesLeft: Integer;
    FKanjiBank, FKanjiPosition, FRamControl, FModemControl: Byte;
    FTimer, FTimerReload: Word;
    FTimerPending, FIrqEnabled, FIrqRepeat, FRamGate: Boolean;
    FLastPpuAddress: Word;
    FMirror: TMirrorMode;
    FPadShift: Cardinal;
    FPadStrobe: Boolean;
    FKeypad, FAlternateKeys: Word;
    function ReadAdapter(Address: UInt16; Peek: Boolean; out Value: Byte): Boolean;
    function ReadKanji(Address: UInt16): Byte; inline;
    function Cpu2Read(Address: Word): Byte;
    procedure Cpu2Write(Address: Word; Value: Byte);
    procedure ClockCpu2;
    function AdapterRamEnabled: Boolean; inline;
    procedure ResetAdapter;
    procedure ResetCpu2;
  public
    constructor Create(const Prg: TByteArray; const Kanji, Cpu2Rom: TBytes; ArchivedKanji: Boolean);
    destructor Destroy; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ObserveCpuRead(Value: Byte);
    procedure ObserveCpuWrite(Address: UInt16; Value: Byte);
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    procedure WriteExpansionPad(Value, Joypad: Byte);
    function ReadExpansionPad(A: Boolean): Byte;
    function SetHostKey(Code: UInt32; Pressed: Boolean): Boolean;
    procedure ClearInput;
    procedure Reset; override;
  end;

implementation

uses
  NES.Consts;

const
  FCNS_STATE_VERSION = 33;
  CPU2_FREQUENCY = 2457600;
  CPU2_NMI_PRESCALER = 2048;

procedure TRf5a18Timer.Restart(Value: Byte; Prescaler: Integer);
begin
  Repeating := (Value and 1) <> 0;
  if (Value and 2) <> 0 then
    Counter := Integer(Period) * Prescaler;
end;

function TRf5a18Timer.Clock(Prescaler: Integer): Boolean;
begin
  if Counter = 0 then
    Exit(False);
  Dec(Counter);
  Result := Counter = 0;
  if Result then
  begin
    Pending := True;
    if Repeating then
      Counter := Integer(Period) * Prescaler;
  end;
end;

constructor TMapperFcns.Create(const Prg: TByteArray; const Kanji, Cpu2Rom: TBytes; ArchivedKanji: Boolean);
begin
  inherited Create(Prg);
  if (Length(Kanji) <> FCNS_KANJI_SIZE) or (Length(Cpu2Rom) <> FCNS_CPU2_ROM_SIZE) then
    raise ENesException.Create('Invalid FCNS firmware size');

  if ArchivedKanji then
  begin
    // The original dump input A0-A11 came from CPU A0-A11, A12 from the bank
    // latch and A13-A17 from counter lines 4 down to 0. Store each glyph together.
    SetLength(FKanji, FCNS_KANJI_SIZE);
    for var Counter := 0 to 31 do
    begin
      var CounterAddress := ((Counter and $01) shl 17) or ((Counter and $02) shl 15) or
        ((Counter and $04) shl 13) or ((Counter and $08) shl 11) or ((Counter and $10) shl 9);
      for var Bank := 0 to 1 do
        for var Glyph := 0 to $FFF do
          FKanji[(Bank shl 17) or (Glyph shl 5) or Counter] :=
            Kanji[CounterAddress or (Bank shl 12) or Glyph];
    end;
  end
  else
    FKanji := Kanji;

  FCpu2Rom := Cpu2Rom;
  FCpu2 := TW65C02.Create(Cpu2Read, Cpu2Write);
end;

destructor TMapperFcns.Destroy;
begin
  FCpu2.Free;
  inherited;
end;

function TMapperFcns.AdapterRamEnabled: Boolean;
begin
  Result := FRamGate and ((FRamControl and 1) <> 0);
end;

function TMapperFcns.ReadKanji(Address: UInt16): Byte;
begin
  Result := FKanji[(Integer(FKanjiBank) shl 17) or ((Integer(Address) and $0FFF) shl 5) or
    Integer(FKanjiPosition)];
end;

function TMapperFcns.ReadAdapter(Address: UInt16; Peek: Boolean; out Value: Byte): Boolean;
begin
  if Address >= $8000 then
    Exit(inherited CpuRead(Address, Value));
  if Address >= $6000 then
  begin
    Value := FCardBus;
    var ConsoleBus := FCpuOpenBus;
    FCpuOpenBus := FCardBus;
    var CardDrives := inherited CpuRead(Address, Value);
    FCpuOpenBus := ConsoleBus;
    if AdapterRamEnabled then
    begin
      var Ram := FAdapterRam[Address and $1FFF];
      if CardDrives then
      begin
        if (FChrBank0 and $10) <> 0 then
          Value := Value or $FE; // The EEPROM drives only D0.
        Value := Value and Ram;
      end
      else
        Value := Ram;
    end;
    Exit(True);
  end;
  if Address >= $5000 then
  begin
    Value := ReadKanji(Address);
    if not Peek then
      FKanjiPosition := (FKanjiPosition + 1) and $1F;
    Exit(True);
  end;
  if (Address and $F0FF) < $40A0 then
    Exit(False);
  case Address and $FF of
    $A1:
      Value := $FF;
    $A2:
      begin
        Value := $20 or (FCpuOpenBus and $0C) or Byte(Ord(FTimerPending));
        if not Peek then
          FTimerPending := False;
      end;
    $A5:
      Value := FCpuOpenBus and $78;
    $A6:
      Value := Byte(FTimer and $FF);
    $A7:
      Value := Byte(FTimer shr 8);
    $A9, $AA:
      Value := 0;
    $AD:
      begin
        var BitIndex := 10 + Ord(FMirror = TMirrorMode.Horizontal);
        Value := (FCpuOpenBus and $7F) or Byte(((FLastPpuAddress shr BitIndex) and 1) shl 7);
      end;
    $B0:
      begin
        if not Peek then
          FKanjiPosition := 0;
        Value := FCpuOpenBus;
      end;
    $C0:
      Value := $80 or (FCpuOpenBus and $70) or (FRamControl and 8) or
        Byte(Ord((FModemControl and 8) = 0) shl 2);
    $D0..$DF:
      case Address and 7 of
        0..2:
          Value := FToFamicom[Address and 7];
        3:
          Value := FToFamicom[3] or (FCardBus and $1F);
        4:
          Value := FExpansion; // No tone decoder or external equipment attached.
          6:
          Value := (FCardBus and $C0) or $02 or
            Byte(Ord((FUartMode and $06) = 0) shl 3) or
            Byte(Ord((FUartMode and $80) = 0) shl 4) or
            Byte(Ord((FUartMode and $40) = 0) shl 5);
      else
        Value := FCardBus;
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperFcns.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := ReadAdapter(Address, False, Value);
end;

function TMapperFcns.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := ReadAdapter(Address, True, Value);
end;

procedure TMapperFcns.ObserveCpuRead(Value: Byte);
begin
  // The direction of the buffer changes with the address. Undriven card
  // reads use the retained card value, while driven reads update both sides.
  FCardBus := Value;
end;

procedure TMapperFcns.ObserveCpuWrite(Address: UInt16; Value: Byte);
begin
  if (Address >= $5000) and (Address < $6000) then
    Value := Value and ReadKanji(Address);
  FCardBus := Value;
end;

function TMapperFcns.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $6000 then
  begin
    if (Address < $8000) and AdapterRamEnabled then
    begin
      FAdapterRam[Address and $1FFF] := Value;
      inherited CpuWrite(Address, Value);
      Exit(True);
    end;
    Exit(inherited CpuWrite(Address, Value));
  end;
  if Address >= $5000 then
  begin
    FKanjiPosition := (FKanjiPosition + 1) and $1F;
    Exit(True);
  end;
  if (Address and $F0FF) < $40A0 then
    Exit(False);
  case Address and $FF of
    $A6:
      FTimerReload := (FTimerReload and $FF00) or Value;
    $A7:
      FTimerReload := (FTimerReload and $00FF) or (Word(Value) shl 8);
    $A8:
      begin
        FIrqRepeat := (Value and 1) <> 0;
        FIrqEnabled := (Value and 2) <> 0;
        FTimer := FTimerReload;
      end;
    $AD:
      if (Value and $80) <> 0 then
        FMirror := TMirrorMode.Horizontal
      else
        FMirror := TMirrorMode.Vertical;
    $AE:
      FRamGate := (Value and 1) <> 0;
    $B0:
      FKanjiBank := Value and 1;
    $B1:
      FModemControl := Value;
    $C0:
      FRamControl := Value and $0F;
    $D0..$DF:
      case Address and 7 of
        0..2:
          FToCpu2[Address and 7] := Value;
        3:
          FToCpu2[3] := Value and $E0;
        4:
          FExpansion := Value and 7;
      else
        Exit(False);
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperFcns.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrRam[Address or ((Integer(FRamControl) and 8) shl 10)];
end;

function TMapperFcns.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    FChrRam[Address or ((Integer(FRamControl) and 8) shl 10)] := Value;
end;

function TMapperFcns.GetMirrorMode: TMirrorMode;
begin
  Result := FMirror;
end;

procedure TMapperFcns.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  FLastPpuAddress := Address;
end;

procedure TMapperFcns.SetRegion(Region: TNesRegion);
begin
  inherited;
  FCpuClockHz := CpuFrequency(Region);
end;

function TMapperFcns.Cpu2Read(Address: Word): Byte;
begin
  Result := FCpu2Bus;
  if Address >= $E000 then
    Result := FCpu2Rom[Address - $E000]
  else if Address < $2000 then
    Result := FCpu2Ram[Address]
  else
    case Address of
      $4103:
        begin
          Result := (Result and $FE) or Byte(Ord(FCpu2NmiTimer.Pending));
          FCpu2NmiTimer.Pending := False;
        end;
      $4107:
        begin
          Result := (Result and $FD) or Byte(Ord(FCpu2IrqTimer.Pending) shl 1);
          FCpu2IrqTimer.Pending := False;
        end;
      $4112:
        Result := 6; // UART transmitter idle and ready, no inbound data.
        $4122:
        Result := (Result and $1F) or FToCpu2[3];
      $4123..$4125:
        Result := FToCpu2[Address - $4123];
    end;
  FCpu2Bus := Result;
end;

procedure TMapperFcns.Cpu2Write(Address: Word; Value: Byte);
begin
  FCpu2Bus := Value;
  if Address < $2000 then
  begin
    FCpu2Ram[Address] := Value;
    Exit;
  end;
  case Address of
    $4100:
      FCpu2NmiTimer.Period := (FCpu2NmiTimer.Period and $FF00) or Value;
    $4101:
      FCpu2NmiTimer.Period := (FCpu2NmiTimer.Period and $00FF) or (Word(Value) shl 8);
    $4102:
      FCpu2NmiTimer.Restart(Value, CPU2_NMI_PRESCALER);
    $4104:
      FCpu2IrqTimer.Period := (FCpu2IrqTimer.Period and $FF00) or Value;
    $4105:
      FCpu2IrqTimer.Period := (FCpu2IrqTimer.Period and $00FF) or (Word(Value) shl 8);
    $4106:
      FCpu2IrqTimer.Restart(Value, 1);
    $4113:
      FUartMode := Value;
    $4122:
      FToFamicom[3] := Value and $E0;
    $4123..$4125:
      FToFamicom[Address - $4123] := Value;
    $412F:
      FCpu2Mask := Value;
  end;
end;

procedure TMapperFcns.ClockCpu2;
begin
  if (FModemControl and 8) <> 0 then
  begin
    if FCpu2Running then
      ResetCpu2;
    Exit;
  end;
  if not FCpu2Running then
  begin
    FCpu2.Reset;
    FCpu2Running := True;
    FCpu2CyclesLeft := 7;
  end;

  Inc(FCpu2Phase, CPU2_FREQUENCY);
  while FCpu2Phase >= FCpuClockHz do
  begin
    Dec(FCpu2Phase, FCpuClockHz);
    if FCpu2NmiTimer.Clock(CPU2_NMI_PRESCALER) and ((FCpu2Mask and 1) <> 0) then
      FCpu2Nmi := True;
    FCpu2IrqTimer.Clock(1);
    if FCpu2CyclesLeft = 0 then
    begin
      if FCpu2Nmi then
      begin
        FCpu2Nmi := False;
        FCpu2CyclesLeft := FCpu2.Interrupt($FFFA, True);
      end
      else if FCpu2IrqTimer.Pending and ((FCpu2Mask and $40) <> 0) then
        FCpu2CyclesLeft := FCpu2.Interrupt;
      if FCpu2CyclesLeft = 0 then
        FCpu2CyclesLeft := FCpu2.Step;
    end;
    Dec(FCpu2CyclesLeft);
  end;
end;

procedure TMapperFcns.ClockCpu;
begin
  inherited;
  ClockCpu2;
  if FTimer = 0 then
  begin
    FTimerPending := True;
    if FIrqRepeat then
      FTimer := FTimerReload
    else
      FTimer := $FFFF;
  end
  else
    Dec(FTimer);
end;

function TMapperFcns.IrqPending: Boolean;
begin
  Result := FIrqEnabled and FTimerPending;
end;

procedure TMapperFcns.WriteExpansionPad(Value, Joypad: Byte);
begin
  if FPadStrobe or ((Value and 1) <> 0) then
    FPadShift := (Cardinal(FKeypad or FAlternateKeys) shl 8) or Cardinal(Joypad);
  FPadStrobe := (Value and 1) <> 0;
end;

function TMapperFcns.ReadExpansionPad(A: Boolean): Byte;
begin
  if FPadStrobe then
    Exit(Byte(Ord(A) shl 1));
  Result := Byte((FPadShift and 1) shl 1);
  FPadShift := (FPadShift shr 1) or $800000;
end;

function TMapperFcns.SetHostKey(Code: UInt32; Pressed: Boolean): Boolean;
var
  BitIndex: Integer;
  Keys: ^Word;
begin
  Keys := @FKeypad;
  if (Code >= vk0) and (Code <= vk9) then
    BitIndex := Integer(Code - vk0)
  else if (Code >= vkNumpad0) and (Code <= vkNumpad9) then
  begin
    Keys := @FAlternateKeys;
    BitIndex := Integer(Code - vkNumpad0);
  end
  else
    case Code of
      vkMultiply:
        BitIndex := 10;
      vkAdd:
        BitIndex := 11;
      vkPeriod:
        BitIndex := 12;
      vkDecimal:
        begin
          Keys := @FAlternateKeys;
          BitIndex := 12;
        end;
      vkDelete:
        BitIndex := 13;
      vkEnd:
        BitIndex := 15;
    else
      Exit(False);
    end;

  var Mask := Word(1 shl BitIndex);
  if Pressed then
    Keys^ := Keys^ or Mask
  else
    Keys^ := Keys^ and not Mask;
  Result := True;
end;

procedure TMapperFcns.ClearInput;
begin
  FKeypad := 0;
  FAlternateKeys := 0;
end;

procedure TMapperFcns.ResetCpu2;
begin
  FCpu2Running := False;
  FCpu2Phase := 0;
  FCpu2CyclesLeft := 0;
  FCpu2NmiTimer := Default(TRf5a18Timer);
  FCpu2IrqTimer := Default(TRf5a18Timer);
  FCpu2Nmi := False;
  FCpu2Bus := 0;
  FCpu2Mask := 0;
  FUartMode := 0;
  FillChar(FToFamicom, SizeOf(FToFamicom), 0);
end;

procedure TMapperFcns.ResetAdapter;
begin
  ResetCpu2;
  FKanjiBank := 0;
  FKanjiPosition := 0;
  FRamControl := 0;
  FModemControl := $FF;
  FExpansion := 0;
  FCardBus := 0;
  FRamGate := True;
  FTimer := 0;
  FTimerReload := 0;
  FTimerPending := False;
  FIrqEnabled := False;
  FIrqRepeat := False;
  FLastPpuAddress := 0;
  FMirror := TMirrorMode.Vertical;
  FPadShift := 0;
  FPadStrobe := False;
  FillChar(FToCpu2, SizeOf(FToCpu2), 0);
end;

procedure TMapperFcns.Reset;
begin
  inherited;
  ResetAdapter;
end;

procedure TMapperFcns.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version < FCNS_STATE_VERSION then
  begin
    if State.Loading then
      ResetAdapter;
    Exit;
  end;
  State.Field(FChrRam, SizeOf(FChrRam));
  State.Field(FAdapterRam, SizeOf(FAdapterRam));
  State.Field(FCpu2Ram, SizeOf(FCpu2Ram));
  State.Field(FToCpu2, SizeOf(FToCpu2));
  State.Field(FToFamicom, SizeOf(FToFamicom));
  State.Field(FCpu2Bus, SizeOf(FCpu2Bus));
  State.Field(FCardBus, SizeOf(FCardBus));
  State.Field(FCpu2Mask, SizeOf(FCpu2Mask));
  State.Field(FExpansion, SizeOf(FExpansion));
  State.Field(FUartMode, SizeOf(FUartMode));
  State.Field(FCpu2Running, SizeOf(FCpu2Running));
  State.Field(FCpu2Nmi, SizeOf(FCpu2Nmi));
  State.Field(FCpu2NmiTimer, SizeOf(FCpu2NmiTimer));
  State.Field(FCpu2IrqTimer, SizeOf(FCpu2IrqTimer));
  State.Field(FCpu2Phase, SizeOf(FCpu2Phase));
  State.Field(FCpu2CyclesLeft, SizeOf(FCpu2CyclesLeft));
  State.Field(FKanjiBank, SizeOf(FKanjiBank));
  State.Field(FKanjiPosition, SizeOf(FKanjiPosition));
  State.Field(FRamControl, SizeOf(FRamControl));
  State.Field(FModemControl, SizeOf(FModemControl));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FTimerReload, SizeOf(FTimerReload));
  State.Field(FTimerPending, SizeOf(FTimerPending));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqRepeat, SizeOf(FIrqRepeat));
  State.Field(FRamGate, SizeOf(FRamGate));
  State.Field(FLastPpuAddress, SizeOf(FLastPpuAddress));
  State.Field(FMirror, SizeOf(FMirror));
  State.Field(FPadShift, SizeOf(FPadShift));
  State.Field(FPadStrobe, SizeOf(FPadStrobe));
  State.SharedFields(FCpu2.SerializeState);
  if State.Loading and ((FKanjiBank > 1) or (FKanjiPosition > 31) or (FRamControl > 15) or
    (FPadShift > $FFFFFF) or (FCpu2Phase < 0) or (FCpu2Phase >= FCpuClockHz) or
    (FCpu2CyclesLeft < 0) or (FCpu2CyclesLeft > 8) or
    (FCpu2NmiTimer.Counter < 0) or (FCpu2IrqTimer.Counter < 0) or
    not (FMirror in [TMirrorMode.Vertical, TMirrorMode.Horizontal])) then
    raise ENesException.Create('Invalid FCNS adapter snapshot');
end;

end.

