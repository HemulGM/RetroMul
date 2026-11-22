unit NES.Mapper.Um6578;

interface

uses
  NES.Mapper, NES.State, NES.Types, MD.EEPROM, NES.Mapper.Yuxing,
  NES.Mapper.Mmc3, NES.Controller, HW.Sound.TSP50C04;

type
  TMapperUm6578 = class(TMapper)
  private
    type
      TRegisters = packed record
        Bank: array[0..7] of Byte;
        Port4016, Port4020, Port4022, Port4023, Port4024, Port4026, Dac: Byte;
        IrqMask, IrqStatus, TimerControl, TimerPreset, TimerCount, TimerDivider: Byte;
        DmaControl, DmaPage: Byte;
        DmaSource, DmaDestination, DmaLength: Word;
        DmaIndex, DmaRemaining: Integer;
        DmaFast, DmaPhase: Boolean;
        DmaActiveControl, DmaActivePage: Byte;
        DmaActiveSource, DmaActiveDestination: Word;
        GunDelay, GunShift: Cardinal;
      end;
  private
    FBoard, FExpansion: Integer;
    FRom, FExternalVram, FWorkRam: TByteArray;
    FInternalVram: array[0..$27FF] of Byte;
    FInternalRam2: array[0..$7FF] of Byte;
    FBankOffset: array[0..7] of Integer;
    FBatteryRam: Boolean;
    FEeprom: TMDEEPROM;
    FRegs: TRegisters;
    function OuterBank: Integer; inline;
    procedure UpdateBank(Slot, Outer: Integer); inline;
    procedure UpdateBanks;
    procedure ClockTimer;
    function EffectiveDmaPage: Byte;
  protected
    function ReadDmaProgram(Page: Byte; Offset: Word): Byte; virtual;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray);
    destructor Destroy; override;
    procedure ConfigureMemory(PrgRam, PrgNvRam: UInt64; Expansion: Byte);
    procedure PowerOn; override;
    procedure Reset; override;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuPeek(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    function AllowsDirectPpuRead: Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockCpu; override;
    procedure ClockVideoTimer;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    function DmaTransfer(VramAvailable: Boolean; out Source, Destination: Word; out ToCpu: Boolean; out Data: Byte): Boolean;
    function GunStrobeDue: Boolean;
    procedure LatchGun(X, Y: Integer; Trigger, Reload: Boolean);
    function ReadGun: Byte;
    function ReadBandaiPad(Pad: Byte; out Value: Byte): Boolean;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    property Expansion: Integer read FExpansion;
  end;

  TSuborRamMmc3 = class(TMapperMmc3)
  private
    FRam, FVram: NES.Types.TByteArray;
    FBase: Integer;
    function VideoOffset(Address: Word): Integer;
  public
    constructor Create(const Rom, ProgramRam, VideoRam: NES.Types.TByteArray);
    procedure SelectOuterBank(Bank: Byte);
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
  end;

  TMapperSuborSb2000 = class(TMapperUm6578)
  private
    type
      TSuborRegisters = packed record
        EnhancedVideo, Unlock, RamBoot, BootResetPending, FloppyReset: Boolean;
        VideoBank, Outer: Byte;
        KeyInput, KeyOutput, KeyNext, KeyOption, KeyScanSet: Byte;
        KeyReply: array[0..1] of Byte;
        KeyReplyIndex, KeyReplyLength: Byte;
        KeyDelay, KeyInterval, KeySentDelay, KeyReport: Integer;
        KeyEnabled: Boolean;
        PreviousKeys: TSuborKeys;
        MouseReply: array[0..29] of Byte;
        MouseInput, MouseIndex, MouseLength: Byte;
        MouseDelay, MouseReport, MouseX, MouseY: Integer;
        MouseEnabled, MouseLeft: Boolean;
      end;
  private
    FSubor: TSuborRegisters;
    FProgramRam: NES.Types.TByteArray;
    FFloppy: TYuxingFloppy;
    FSpeech: TTsp50C04;
    FMmc3: TSuborRamMmc3;
    FKeyboard: TSuborKeyboard;
    FPointer: TZapper;
    procedure StartKeyboardReply(Value: Byte);
    procedure StartMouse;
    procedure SetInputIrq(Mask: Byte);
    procedure ClockKeyboard;
    procedure QueueKeyChange;
    procedure ClockMouse;
    function GetEnhancedVideo: Boolean; inline;
    function GetRamBoot: Boolean; inline;
  protected
    function ReadDmaProgram(Page: Byte; Offset: Word): Byte; override;
  public
    constructor Create(const Prg, Chr: NES.Types.TByteArray; Submapper: Integer); reintroduce;
    destructor Destroy; override;
    procedure Reset; override;
    procedure PowerOn; override;
    procedure ConnectInput(Keyboard: TSuborKeyboard; Pointer: TZapper);
    procedure SetRegion(Region: TNesRegion); override;
    function ExpansionAudio: Double; override;
    function CpuPeek(Address: Word; out Value: Byte): Boolean; override;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockPpuAddress(Address: Word; PpuCycle: UInt64); override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function ConsumeBootReset: Boolean;
    property EnhancedVideo: Boolean read GetEnhancedVideo;
    property RamBoot: Boolean read GetRamBoot;
    property Floppy: TYuxingFloppy read FFloppy;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math, NES.Consts;

const
  TimerIrq = $80;
  ExpansionCityPatrolman = $2F;
  ExpansionBandaiPad = $38;

constructor TMapperUm6578.Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray);
begin
  inherited Create;
  if (Length(Prg) < $8000) or (Length(Prg) > $200000) or
    (Length(Prg) mod $1000 <> 0) or (Length(Chr) <> 0) then
    raise ENesException.Create('Invalid UM6578 program ROM or CHR ROM');
  FBoard := Board;
  FRom := Prg;
  SetLength(FExternalVram, $8000);
  Reset;
end;

destructor TMapperUm6578.Destroy;
begin
  FEeprom.Free;
  inherited;
end;

procedure TMapperUm6578.ConfigureMemory(PrgRam, PrgNvRam: UInt64; Expansion: Byte);
begin
  FExpansion := Expansion;
  if (PrgRam > $2000) or ((PrgNvRam <> 0) and (PrgNvRam <> $100) and
    ((PrgNvRam <> $2000) or (PrgRam <> 0))) then
    raise ENesException.Create('Unsupported UM6578 PRG memory layout');
  FBatteryRam := PrgNvRam = $2000;
  if FBatteryRam then
    PrgRam := PrgNvRam;
  SetLength(FWorkRam, Integer(PrgRam));
  if PrgNvRam = $100 then
  begin
    var Config := Default(TMDEEPROMConfig);
    Config.Mode := TMDEEPROMMode.Address8;
    Config.Size := $100;
    Config.PageSize := 8;
    Config.PageAlignment := 8;
    Config.SDAInAddress := $4027;
    Config.SDAOutAddress := $4027;
    Config.SCLAddress := $4027;
    Config.SDAInMask := 1;
    Config.SDAOutMask := 1;
    Config.SCLMask := 2;
    FEeprom := TMDEEPROM.Create(Config);
  end;
end;

procedure TMapperUm6578.PowerOn;
begin
  FillChar(FInternalRam2, SizeOf(FInternalRam2), 0);
  FillChar(FInternalVram, SizeOf(FInternalVram), 0);
  FillChar(FExternalVram[0], Length(FExternalVram), 0);
  if not FBatteryRam and (Length(FWorkRam) <> 0) then
    FillChar(FWorkRam[0], Length(FWorkRam), 0);
  Reset;
end;

procedure TMapperUm6578.Reset;
begin
  FRegs := Default(TRegisters);
  for var Slot := 0 to 7 do
    FRegs.Bank[Slot] := Slot;
  FRegs.IrqMask := $FF;
  FRegs.Port4026 := $80;
  FRegs.GunDelay := 8192;
  if FEeprom <> nil then
    FEeprom.Reset;
  UpdateBanks;
end;

function TMapperUm6578.OuterBank: Integer;
begin
  Result := 0;
  case FBoard of
    MAPPER_UM6578_ABL:
      Result := (FRegs.Port4016 and 2) shl 7;
    MAPPER_UM6578_JUNGLETAC:
      Result := (FRegs.Port4026 and $80) shl 1;
  end;
end;

procedure TMapperUm6578.UpdateBank(Slot, Outer: Integer);
begin
  FBankOffset[Slot] := ((Outer or FRegs.Bank[Slot]) mod (Length(FRom) shr 12)) shl 12;
end;

procedure TMapperUm6578.UpdateBanks;
begin
  var Outer := OuterBank;
  for var Slot := 0 to 7 do
    UpdateBank(Slot, Outer);
end;

function TMapperUm6578.EffectiveDmaPage: Byte;
begin
  Result := FRegs.DmaPage;
  case FBoard of
    MAPPER_UM6578_ABL:
      Result := Result or ((FRegs.Port4016 and 2) shl 4);
    MAPPER_UM6578_JUNGLETAC:
      Result := Result or ((FRegs.Port4026 and $80) shr 2);
  end;
end;

function TMapperUm6578.CpuPeek(Address: Word; out Value: Byte): Boolean;
begin
  Result := True;
  case Address of
    $4020:
      Value := FRegs.Port4020;
    $4022:
      Value := FRegs.Port4022 and $85;
    $4023:
      Value := FRegs.Port4023;
    $4024:
      Value := FRegs.Port4024;
    $4026:
      if (FEeprom <> nil) and ((FRegs.Port4026 and $80) = 0) then
        Value := FEeprom.ReadBus($4026, 0) and 1
      else if FExpansion = ExpansionCityPatrolman then
        Value := FRegs.Port4026 and $EF
      else
        Value := FRegs.Port4026;
    $4027:
      Value := FRegs.Dac;
    $4032:
      Value := FRegs.IrqMask;
    $4033:
      Value := FRegs.IrqStatus;
    $4034:
      Value := FRegs.TimerControl;
    $4035:
      Value := FRegs.TimerPreset;
    $4036:
      Value := FRegs.TimerCount;
    $4040..$4047:
      Value := FRegs.Bank[Address and 7];
    $4048:
      Value := FRegs.DmaControl or (Ord(FRegs.DmaRemaining <> 0) shl 7);
    $4049:
      Value := EffectiveDmaPage;
    $404A:
      Value := FRegs.DmaSource and $FF;
    $404B:
      Value := FRegs.DmaSource shr 8;
    $404C:
      Value := FRegs.DmaDestination and $FF;
    $404D:
      Value := FRegs.DmaDestination shr 8;
    $404E:
      Value := FRegs.DmaLength and $FF;
    $404F:
      Value := FRegs.DmaLength shr 8;
    $5000..$57FF:
      Value := FInternalRam2[Address and $7FF];
    $5800..$5FFF:
      Value := $FF;
    $6000..$7FFF:
      if Length(FWorkRam) <> 0 then
        Value := FWorkRam[(Address and $1FFF) mod Length(FWorkRam)]
      else
        Result := False;
    $8000..$FFFF:
      Value := FRom[FBankOffset[(Address shr 12) and 7] + (Address and $FFF)];
  else
    Result := False;
  end;
end;

function TMapperUm6578.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := CpuPeek(Address, Value);
end;

function TMapperUm6578.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := True;
  case Address of
    $4016:
      begin
        var Previous := FRegs.Port4016;
        FRegs.Port4016 := Value;
        if (FBoard = MAPPER_UM6578_ABL) and (((Previous xor Value) and 2) <> 0) then
          UpdateBanks;
      end;
    $4020:
      FRegs.Port4020 := Value;
    $4022:
      FRegs.Port4022 := Value;
    $4023:
      FRegs.Port4023 := Value;
    $4024:
      FRegs.Port4024 := Value;
    $4026:
      begin
        var Previous := FRegs.Port4026;
        FRegs.Port4026 := Value;
        if (FBoard = MAPPER_UM6578_JUNGLETAC) and (((Previous xor Value) and $80) <> 0) then
          UpdateBanks;
        // The EEPROM data and clock are driven through the external I/O port.
        if (FEeprom <> nil) and ((Value and $80) = 0) then
          FEeprom.WriteBus($4026, Value, False, True);
      end;
    $4027:
      FRegs.Dac := Value;
    $4032:
      begin
        FRegs.IrqMask := Value;
        FRegs.IrqStatus := FRegs.IrqStatus and not Value;
      end;
    $4034:
      begin
        FRegs.TimerControl := Value;
        FRegs.TimerDivider := 0;
        if (Value and $80) = 0 then
          FRegs.IrqStatus := FRegs.IrqStatus and not TimerIrq;
      end;
    $4035:
      begin
        FRegs.TimerPreset := Value;
        FRegs.TimerCount := Value;
        FRegs.TimerDivider := 0;
        FRegs.IrqStatus := FRegs.IrqStatus and not TimerIrq;
      end;
    $4040..$4047:
      begin
        var Slot := Address and 7;
        FRegs.Bank[Slot] := Value;
        UpdateBank(Slot, OuterBank);
      end;
    $4048:
      begin
        FRegs.DmaControl := Value and $60;
        if (Value and $80) <> 0 then
        begin
          FRegs.DmaActiveControl := FRegs.DmaControl;
          FRegs.DmaActivePage := EffectiveDmaPage;
          FRegs.DmaActiveSource := FRegs.DmaSource;
          FRegs.DmaActiveDestination := FRegs.DmaDestination;
          FRegs.DmaIndex := 0;
          if FBoard = MAPPER_SUBOR_SB2000 then
            // The SB-2000 BIOS writes $8000 for a complete 32 KiB video bank.
            FRegs.DmaRemaining := Min((Integer(FRegs.DmaLength) + 1) and not 1, $8000)
          else
            FRegs.DmaRemaining := FRegs.DmaLength + 1;
          FRegs.DmaFast := (Value and $40) <> 0;
          FRegs.DmaPhase := True;
        end;
      end;
    $4049:
      FRegs.DmaPage := Value and $1F;
    $404A:
      FRegs.DmaSource := (FRegs.DmaSource and $FF00) or Value;
    $404B:
      FRegs.DmaSource := (FRegs.DmaSource and $FF) or (Word(Value) shl 8);
    $404C:
      FRegs.DmaDestination := (FRegs.DmaDestination and $FF00) or Value;
    $404D:
      FRegs.DmaDestination := (FRegs.DmaDestination and $FF) or (Word(Value) shl 8);
    $404E:
      FRegs.DmaLength := (FRegs.DmaLength and $FF00) or Value;
    $404F:
      begin
        if FBoard <> MAPPER_SUBOR_SB2000 then
          Value := Value and $7F;
        FRegs.DmaLength := (FRegs.DmaLength and $FF) or (Word(Value) shl 8);
      end;
    $5000..$57FF:
      FInternalRam2[Address and $7FF] := Value;
    $6000..$7FFF:
      if Length(FWorkRam) <> 0 then
        FWorkRam[(Address and $1FFF) mod Length(FWorkRam)] := Value;
  else
    Result := False;
  end;
end;

function TMapperUm6578.DmaTransfer(VramAvailable: Boolean; out Source, Destination: Word; out ToCpu: Boolean; out Data: Byte): Boolean;
begin
  Result := False;
  if FRegs.DmaRemaining = 0 then
    Exit;
  ToCpu := (FRegs.DmaActiveControl and $20) <> 0;
  if not ToCpu and not VramAvailable then
    Exit;
  if not FRegs.DmaFast then
  begin
    FRegs.DmaPhase := not FRegs.DmaPhase;
    if FRegs.DmaPhase then
      Exit;
  end;
  Source := (FRegs.DmaActiveSource and $8000) or
    ((Integer(FRegs.DmaActiveSource) + FRegs.DmaIndex) and $7FFF);
  Destination := (Integer(FRegs.DmaActiveDestination) + FRegs.DmaIndex) and $FFFF;
  Data := 0;
  if (Source and $8000) <> 0 then
    Data := ReadDmaProgram(FRegs.DmaActivePage, Source and $7FFF);
  Dec(FRegs.DmaRemaining);
  Inc(FRegs.DmaIndex);
  Result := True;
end;

function TMapperUm6578.ReadDmaProgram(Page: Byte; Offset: Word): Byte;
begin
  Result := FRom[((Integer(Page) shl 15) or Offset) mod Length(FRom)];
end;

function TMapperUm6578.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if Address < $2800 then
    Value := FInternalVram[Address]
  else if Address >= $8000 then
    Value := FExternalVram[Address and $7FFF]
  else
    Value := $FF;
  Result := True;
end;

function TMapperUm6578.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  if Address < $2800 then
    FInternalVram[Address] := Value
  else if Address >= $8000 then
    FExternalVram[Address and $7FFF] := Value;
  Result := True;
end;

function TMapperUm6578.AllowsDirectPpuRead: Boolean;
begin
  Result := True;
end;

function TMapperUm6578.GetMirrorMode: TMirrorMode;
begin
  Result := TMirrorMode.FourScreen;
end;

procedure TMapperUm6578.ClockTimer;
begin
  if (FRegs.TimerControl and $80) = 0 then
    Exit;
  if FRegs.TimerDivider < (FRegs.TimerControl and 7) then
  begin
    Inc(FRegs.TimerDivider);
    Exit;
  end;
  FRegs.TimerDivider := 0;
  if FRegs.TimerCount <> 0 then
    Dec(FRegs.TimerCount)
  else
  begin
    if (FRegs.IrqMask and TimerIrq) = 0 then
      FRegs.IrqStatus := FRegs.IrqStatus or TimerIrq;
    if (FRegs.TimerControl and $40) <> 0 then
      FRegs.TimerCount := FRegs.TimerPreset
    else
      FRegs.TimerControl := FRegs.TimerControl and $7F;
  end;
end;

procedure TMapperUm6578.ClockCpu;
begin
  if (FRegs.TimerControl and $20) = 0 then
    ClockTimer;
  if (FExpansion = ExpansionCityPatrolman) and (FRegs.GunDelay < 8192) then
    Inc(FRegs.GunDelay);
end;

procedure TMapperUm6578.ClockVideoTimer;
begin
  if (FRegs.TimerControl and $20) <> 0 then
    ClockTimer;
end;

function TMapperUm6578.IrqPending: Boolean;
begin
  Result := (FRegs.IrqStatus and not FRegs.IrqMask) <> 0;
end;

function TMapperUm6578.ExpansionAudio: Double;
begin
  Result := FRegs.Dac * (1.0 / 2048.0);
end;

function TMapperUm6578.GunStrobeDue: Boolean;
begin
  Result := (FExpansion = ExpansionCityPatrolman) and (FRegs.GunDelay >= 8192);
end;

procedure TMapperUm6578.LatchGun(X, Y: Integer; Trigger, Reload: Boolean);
begin
  if not GunStrobeDue then
    Exit;
  FRegs.GunDelay := 0;
  var InBounds := (X >= 0) and (X < 256) and (Y >= 8) and (Y < 240);
  if InBounds then
    Dec(Y, 8)
  else
  begin
    X := $FF;
    Y := $FF;
  end;
  var Data := (Ord(Trigger) shl 16) or (Ord(Reload) shl 17) or (Ord(InBounds) shl 18);
  for var Bit := 0 to 7 do
  begin
    Data := Data or (((X shr Bit) and 1) shl (Bit * 2));
    Data := Data or (((Y shr Bit) and 1) shl (Bit * 2 + 1));
  end;
  FRegs.GunShift := Data;
end;

function TMapperUm6578.ReadGun: Byte;
begin
  Result := 0;
  if (FRegs.Port4016 and 2) <> 0 then
  begin
    Result := FRegs.GunShift and 3;
    FRegs.GunShift := FRegs.GunShift shr 2;
  end;
end;

function TMapperUm6578.ReadBandaiPad(Pad: Byte; out Value: Byte): Boolean;
begin
  Result := (FExpansion = ExpansionBandaiPad) and (FRegs.Port4026 = $FF) and
    ((FRegs.Port4016 = $F9) or (FRegs.Port4016 = $FE));
  if not Result then
    Exit;
  if FRegs.Port4016 = $F9 then
    Value := ((Pad and 8) shr 1) xor $FF
  else
    Value := (((Pad and 2) shl 1) or ((Pad and 1) shl 3) or
      ((Pad and $80) shr 3) or (Pad and $60) or ((Pad and $10) shl 3)) xor $FF;
end;

procedure TMapperUm6578.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FInternalRam2, SizeOf(FInternalRam2));
  State.Field(FInternalVram, SizeOf(FInternalVram));
  State.Field(FExternalVram[0], Length(FExternalVram));
  if Length(FWorkRam) <> 0 then
    State.Field(FWorkRam[0], Length(FWorkRam));
  if FEeprom <> nil then
    State.SharedFields(FEeprom.SerializeState);
  if State.Loading then
  begin
    if (Cardinal(FRegs.DmaRemaining) > $8000) or (Cardinal(FRegs.DmaIndex) > $8000) or
      ((FBoard <> MAPPER_SUBOR_SB2000) and (FRegs.DmaLength > $7FFF)) or (FRegs.DmaPage > $1F) or
      (FRegs.DmaActivePage > $3F) or (FRegs.TimerDivider > 7) then
      raise EReadError.Create('Invalid UM6578 device state');
    UpdateBanks;
  end;
end;

function TMapperUm6578.GetSaveMemory: NES.Types.TByteArray;
begin
  if FEeprom <> nil then
    Result := NES.Types.TByteArray(FEeprom.BatteryData)
  else if FBatteryRam then
    Result := Copy(FWorkRam)
  else
    Result := nil;
end;

procedure TMapperUm6578.SetSaveMemory(const Data: NES.Types.TByteArray);
begin
  if FEeprom <> nil then
    FEeprom.LoadBattery(TBytes(Data))
  else if FBatteryRam and (Length(Data) = Length(FWorkRam)) then
    Move(Data[0], FWorkRam[0], Length(Data))
  else
    raise ENesException.Create('Invalid UM6578 save size');
end;

constructor TSuborRamMmc3.Create(const Rom, ProgramRam, VideoRam: NES.Types.TByteArray);
begin
  inherited Create(Copy(Rom, 0, $4000), nil, True, TMirrorMode.Horizontal);
  FRam := ProgramRam;
  FVram := VideoRam;
  // Bank registers, mirroring and IRQ are shared with MMC3. Both arrays belong to the board.
  FPrgRom := nil;
  FChrMemory := nil;
end;

procedure TSuborRamMmc3.SelectOuterBank(Bank: Byte);
begin
  FBase := Integer(Bank) shl 17;
  CpuWrite($E000, 0);
end;

function TSuborRamMmc3.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := Address >= $8000;
  if Result then
    Value := FRam[FBase + ((PrgRegisterBank((Address shr 13) and 3) and $0F) shl 13) +
      (Address and $1FFF)];
end;

function TSuborRamMmc3.VideoOffset(Address: Word): Integer;
begin
  var Slot := Address shr 10;
  if (FBankSelect and $80) <> 0 then
    Slot := Slot xor 4;
  Result := FBase + ((ChrRegisterBank(Slot) and $7F) shl 10) + (Address and $3FF);
end;

function TSuborRamMmc3.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FVram[VideoOffset(Address)];
end;

function TSuborRamMmc3.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := Address < $2000;
  if Result then
    FVram[VideoOffset(Address)] := Value;
end;

constructor TMapperSuborSb2000.Create(const Prg, Chr: NES.Types.TByteArray; Submapper: Integer);
begin
  if (Submapper <> 0) and (Submapper <> 3) then
    raise ENesException.Create('Unsupported Subor SB-2000 board');
  if Length(Prg) <> $80000 then
    raise ENesException.Create('Subor SB-2000 requires 512 KiB of firmware');
  inherited Create(MAPPER_SUBOR_SB2000, Prg, Chr);
  SetLength(FProgramRam, $80000);
  SetLength(FExternalVram, $80000);
  FMmc3 := TSuborRamMmc3.Create(Prg, FProgramRam, FExternalVram);
  FFloppy := TYuxingFloppy.Create('Subor SB-2000 floppy drive', True);
  FSpeech := TTsp50C04.Create;
  FSpeech.SetClock(CpuFrequency(TNesRegion.Dendy));
  Reset;
end;

destructor TMapperSuborSb2000.Destroy;
begin
  FSpeech.Free;
  FFloppy.Free;
  FMmc3.Free;
  inherited;
end;

procedure TMapperSuborSb2000.ConnectInput(Keyboard: TSuborKeyboard; Pointer: TZapper);
begin
  FKeyboard := Keyboard;
  FPointer := Pointer;
end;

procedure TMapperSuborSb2000.SetRegion(Region: TNesRegion);
begin
  inherited;
  FSpeech.SetClock(CpuFrequency(Region));
end;

function TMapperSuborSb2000.ExpansionAudio: Double;
begin
  Result := inherited ExpansionAudio + FSpeech.Output;
end;

procedure TMapperSuborSb2000.PowerOn;
begin
  FillChar(FProgramRam[0], Length(FProgramRam), 0);
  inherited;
end;

procedure TMapperSuborSb2000.Reset;
begin
  inherited;
  if FMmc3 = nil then
    Exit;
  FMmc3.Reset;
  FMmc3.SelectOuterBank(0);
  // The SB-2000 BIOS sends commands to drive A without setting the PC DOR.
  FFloppy.WriteDigitalOutput($1C);
  FFloppy.Reset;
  FSpeech.Reset;
  FSubor := Default(TSuborRegisters);
  FSubor.KeyInput := $FF;
  FSubor.KeyScanSet := 2;
  FSubor.MouseX := -1;
  FSubor.MouseY := -1;
  FRegs.Port4026 := 0;
end;

function TMapperSuborSb2000.CpuPeek(Address: Word; out Value: Byte): Boolean;
begin
  Result := True;
  case Address of
    $4020:
      Value := FSubor.KeyInput;
    $4024:
      Value := FSubor.MouseInput;
    $4026:
      Value := FRegs.Port4026 and $47;
    $4200, $4201:
      Value := FFloppy.PeekData;
    $4202:
      Value := Ord((FFloppy.ReadStatus and $A0) = $A0) shl 6;
    $4203:
      Value := Ord(FFloppy.IrqPending) shl 6;
    $4206:
      Value := 0;
    $4204:
      Value := FFloppy.ReadStatus;
    $4205:
      Value := FFloppy.PeekData;
    $4207:
      Value := FFloppy.ReadDigitalInput;
    $4300:
      Value := FSubor.VideoBank;
    $4302:
      Value := FSpeech.ReadStatus;
    $5800..$5FFF:
      Result := inherited CpuPeek(Address - $800, Value);
    $8000..$FFFF:
      if FSubor.RamBoot then
        Result := FMmc3.CpuRead(Address, Value)
      else
      begin
        var Bank := FRegs.Bank[(Address shr 12) and 7];
        if (Bank and $80) <> 0 then
          Value := FProgramRam[((Bank and $7F) shl 12) or (Address and $FFF)]
        else
          Result := inherited;
      end;
  else
    Result := inherited;
  end;
end;

function TMapperSuborSb2000.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if ((Address >= $4200) and (Address <= $4201)) or (Address = $4205) then
  begin
    Value := FFloppy.ReadData;
    Exit(True);
  end;
  Result := CpuPeek(Address, Value);
end;

procedure TMapperSuborSb2000.StartKeyboardReply(Value: Byte);
begin
  FSubor.KeyDelay := 3326;
  FSubor.KeyNext := $FA;
  FSubor.KeyReplyLength := 0;
  FSubor.KeyReplyIndex := 0;
  FSubor.KeyInterval := 1663;
  if FSubor.KeyOption <> 0 then
  begin
    if FSubor.KeyOption = $F0 then
      if Value = 0 then
      begin
        FSubor.KeyReply[0] := FSubor.KeyScanSet;
        FSubor.KeyReplyLength := 1;
      end
      else if Value in [1, 2, 3] then
      begin
        FSubor.KeyScanSet := Value;
        FSubor.KeyEnabled := True;
      end;
    FSubor.KeyOption := 0;
    Exit;
  end;
  case Value of
    $ED, $F0, $F3, $FB..$FD:
      FSubor.KeyOption := Value;
    $F2:
      begin
        FSubor.KeyReply[0] := $12;
        FSubor.KeyReply[1] := $34;
        FSubor.KeyReplyLength := 2;
      end;
    $F4:
      FSubor.KeyEnabled := True;
    $F5:
      FSubor.KeyEnabled := False;
    $FF:
      begin
        FSubor.KeyEnabled := False;
        FSubor.KeyScanSet := 2;
        FSubor.KeyReply[0] := $AA;
        FSubor.KeyReplyLength := 1;
      end;
  end;
  if Value = $FF then
    FSubor.KeyInterval := 166300;
end;

procedure TMapperSuborSb2000.StartMouse;
const
  // Identification bytes from the HT6513B mouse on RTS.
  Identification: array[0..29] of Byte = (
    $4D, $33, $08, $01, $24, $28, $34, $2B, $10, $10, $10, $11, $3C,
    $3C, $2D, $2F, $35, $33, $25, $3C, $30, $2E, $30, $10, $26, $10, $23, $19, $12, $09);
begin
  Move(Identification[0], FSubor.MouseReply[0], SizeOf(Identification));
  FSubor.MouseLength := Length(Identification);
  FSubor.MouseIndex := 0;
  FSubor.MouseDelay := 24945;
  FSubor.MouseEnabled := True;
end;

function TMapperSuborSb2000.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := True;
  case Address of
    $4021:
      FSubor.KeyOutput := Value;
    $4022:
      begin
        if ((FRegs.Port4022 and $80) = 0) and ((Value and $81) = $81) then
        begin
          StartKeyboardReply(FSubor.KeyOutput);
          if (Value and 4) <> 0 then
            FSubor.KeySentDelay := 1663;
        end;
        inherited CpuWrite(Address, Value);
      end;
    $4026:
      begin
        if ((FRegs.Port4026 and 2) = 0) and ((Value and 2) <> 0) then
          StartMouse;
        if ((FRegs.Port4026 and $40) = 0) and ((Value and $40) <> 0) then
          FSpeech.Reset;
        inherited CpuWrite(Address, Value);
      end;
    $4031:
      if not FSubor.EnhancedVideo then
      begin
        if FSubor.Unlock and (Value = $76) then
        begin
          FSubor.EnhancedVideo := True;
          FSubor.RamBoot := False;
        end;
        FSubor.Unlock := Value = $65;
      end;
    $4200, $4201, $4205:
      FFloppy.WriteData(Value);
    $4202:
      FFloppy.WriteDigitalOutput(Value);
    $4203, $4206:
      ;
    $4204:
      begin
        if FSubor.FloppyReset and ((Value and $40) = 0) then
        begin
          FFloppy.WriteDigitalOutput($1C);
          FFloppy.Reset;
        end;
        FSubor.FloppyReset := (Value and $40) <> 0;
      end;
    $4207:
      FFloppy.WriteControl(Value);
    $4300:
      FSubor.VideoBank := Value and $0F;
    $4301:
      if Value = $55 then
      begin
        FSubor.EnhancedVideo := False;
        FSubor.RamBoot := True;
        FSubor.BootResetPending := True;
        FSubor.Unlock := False;
        FRegs.TimerControl := 0;
        FRegs.IrqMask := $FF;
        FRegs.IrqStatus := 0;
        FRegs.DmaRemaining := 0;
        FRegs.Dac := 0;
      end;
    $4302:
      FSpeech.Write(Value);
    $5006:
      begin
        FSubor.Outer := ((Value shr 2) and 2) or ((Value shr 1) and 1);
        FMmc3.SelectOuterBank(FSubor.Outer);
        Result := inherited;
      end;
    $5800..$5FFF:
      Result := inherited CpuWrite(Address - $800, Value);
    $8000..$FFFF:
      if FSubor.RamBoot then
        Result := FMmc3.CpuWrite(Address, Value)
      else
      begin
        var Bank := FRegs.Bank[(Address shr 12) and 7];
        if (Bank and $80) <> 0 then
          FProgramRam[((Bank and $7F) shl 12) or (Address and $FFF)] := Value;
      end;
  else
    Result := inherited;
  end;
end;

function TMapperSuborSb2000.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if not FSubor.EnhancedVideo then
    if FSubor.RamBoot then
      Exit(FMmc3.PpuRead(Address, Value))
    else if Address >= $2000 then
      Exit(False);
  if Address >= $8000 then
  begin
    Value := FExternalVram[(Integer(FSubor.VideoBank) shl 15) or (Address and $7FFF)];
    Exit(True);
  end;
  Result := inherited;
end;

function TMapperSuborSb2000.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  if not FSubor.EnhancedVideo then
    if FSubor.RamBoot then
      Exit(FMmc3.PpuWrite(Address, Value))
    else if Address >= $2000 then
      Exit(False);
  if Address >= $8000 then
  begin
    FExternalVram[(Integer(FSubor.VideoBank) shl 15) or (Address and $7FFF)] := Value;
    Exit(True);
  end;
  Result := inherited;
end;

function TMapperSuborSb2000.GetMirrorMode: TMirrorMode;
begin
  if FSubor.EnhancedVideo then
    Exit(TMirrorMode.FourScreen);
  Result := FMmc3.GetMirrorMode;
end;

procedure TMapperSuborSb2000.ClockPpuAddress(Address: Word; PpuCycle: UInt64);
begin
  if FSubor.RamBoot then
    FMmc3.ClockPpuAddress(Address, PpuCycle);
end;

function TMapperSuborSb2000.ReadDmaProgram(Page: Byte; Offset: Word): Byte;
begin
  if (Page and $10) <> 0 then
    Result := FProgramRam[((Integer(Page) and $0F) shl 15) or Offset]
  else
    Result := FRom[(Integer(Page) shl 15) or Offset];
end;

procedure TMapperSuborSb2000.SetInputIrq(Mask: Byte);
begin
  if (FRegs.IrqMask and Mask) = 0 then
    FRegs.IrqStatus := FRegs.IrqStatus or Mask;
end;

procedure TMapperSuborSb2000.ClockKeyboard;
begin
  if FSubor.KeySentDelay > 0 then
  begin
    Dec(FSubor.KeySentDelay);
    if FSubor.KeySentDelay = 0 then
      SetInputIrq($20);
  end;
  if (FRegs.IrqStatus and $20) <> 0 then
    Exit;
  if FSubor.KeyDelay > 0 then
  begin
    Dec(FSubor.KeyDelay);
    if FSubor.KeyDelay = 0 then
    begin
      FSubor.KeyInput := FSubor.KeyNext;
      SetInputIrq($20);
      if FSubor.KeyReplyIndex < FSubor.KeyReplyLength then
      begin
        FSubor.KeyNext := FSubor.KeyReply[FSubor.KeyReplyIndex];
        Inc(FSubor.KeyReplyIndex);
        FSubor.KeyDelay := FSubor.KeyInterval;
      end;
    end;
    Exit;
  end;
  if (FKeyboard = nil) or not FSubor.KeyEnabled then
    Exit;
  if FSubor.KeyReport > 0 then
    Dec(FSubor.KeyReport)
  else
  begin
    FSubor.KeyReport := 1663;
    QueueKeyChange;
  end;
end;

procedure TMapperSuborSb2000.QueueKeyChange;
const
  // IBM PC set 1. The BIOS explicitly selects this set.
  Scan: array[TSuborKey] of Byte = (
    $1E, $30, $2E, $20, $12, $21, $22, $23, $17, $24, $25, $26, $32, $31, $18, $19, $10,
    $13, $1F, $14, $16, $2F, $11, $2D, $15, $2C,
    $0B, $02, $03, $04, $05, $06, $07, $08, $09, $0A,
    $3B, $3C, $3D, $3E, $3F, $40, $41, $42, $43, $44, $57, $58,
    $52, $4F, $50, $51, $4B, $4C, $4D, $47, $48, $49, $9C, $53, $4E, $37, $B5, $4A,
    $45, $33, $34, $27, $28, $35, $2B, $0D, $0C, $29, $1A, $1B, $3A, 0, $1D, $2A, $38,
    $39, $0E, $0F, $01, $1C, $CF, $C7, $D2, $D3, $C9, $D1, $C8, $D0, $CB, $CD, 0, 0, 0, 0, 0, 0);
begin
  var Keys := FKeyboard.GetPressedKeys;
  if Keys = FSubor.PreviousKeys then
    Exit;
  for var Key := Low(TSuborKey) to High(TSuborKey) do
    if (Key in Keys) <> (Key in FSubor.PreviousKeys) then
    begin
      var Code := Scan[Key];
      if Key in Keys then
        Include(FSubor.PreviousKeys, Key)
      else
        Exclude(FSubor.PreviousKeys, Key);
      if Code = 0 then
        Continue;
      var Data := (Code and $7F) or (Ord(not (Key in Keys)) shl 7);
      if (Code and $80) <> 0 then
      begin
        FSubor.KeyNext := $E0;
        FSubor.KeyReply[0] := Data;
        FSubor.KeyReplyLength := 1;
      end
      else
      begin
        FSubor.KeyNext := Data;
        FSubor.KeyReplyLength := 0;
      end;
      FSubor.KeyReplyIndex := 0;
      FSubor.KeyInterval := 1663;
      FSubor.KeyDelay := 1;
      Exit;
    end;
end;

procedure TMapperSuborSb2000.ClockMouse;
begin
  if not FSubor.MouseEnabled or ((FRegs.IrqStatus and $40) <> 0) then
    Exit;
  if FSubor.MouseDelay > 0 then
  begin
    Dec(FSubor.MouseDelay);
    if FSubor.MouseDelay <> 0 then
      Exit;
    FSubor.MouseInput := FSubor.MouseReply[FSubor.MouseIndex];
    Inc(FSubor.MouseIndex);
    if (FRegs.Port4023 and 1) <> 0 then
      SetInputIrq($40);
    if FSubor.MouseIndex < FSubor.MouseLength then
      FSubor.MouseDelay := 8315;
    Exit;
  end;
  if (FPointer = nil) or not Assigned(FPointer.OnReadPosition) then
    Exit;
  if FSubor.MouseReport > 0 then
  begin
    Dec(FSubor.MouseReport);
    Exit;
  end;
  FSubor.MouseReport := 24945;
  var Point := FPointer.OnReadPosition();
  if (Point.X < 0) or (Point.Y < 0) then
    Exit;
  var DX := 0;
  var DY := 0;
  if FSubor.MouseX >= 0 then
  begin
    DX := EnsureRange(Point.X - FSubor.MouseX, -128, 127);
    DY := EnsureRange(Point.Y - FSubor.MouseY, -128, 127);
    Inc(FSubor.MouseX, DX);
    Inc(FSubor.MouseY, DY);
  end
  else
  begin
    FSubor.MouseX := Point.X;
    FSubor.MouseY := Point.Y;
  end;
  var Left := FPointer.TriggerPressed;
  if (DX = 0) and (DY = 0) and (Left = FSubor.MouseLeft) then
    Exit;
  FSubor.MouseLeft := Left;
  FSubor.MouseReply[0] := $40 or (Ord(Left) shl 5) or ((DX and $C0) shr 6) or ((DY and $C0) shr 4);
  FSubor.MouseReply[1] := DX and $3F;
  FSubor.MouseReply[2] := DY and $3F;
  FSubor.MouseIndex := 0;
  FSubor.MouseLength := 3;
  FSubor.MouseDelay := 1;
end;

procedure TMapperSuborSb2000.ClockCpu;
begin
  inherited;
  FFloppy.ClockCpu;
  FSpeech.Clock;
  if FFloppy.IrqPending then
    SetInputIrq(8);
  if FSubor.EnhancedVideo then
  begin
    ClockKeyboard;
    ClockMouse;
  end;
end;

function TMapperSuborSb2000.IrqPending: Boolean;
begin
  Result := inherited IrqPending or (FSubor.RamBoot and FMmc3.IrqPending);
end;

function TMapperSuborSb2000.GetEnhancedVideo: Boolean;
begin
  Result := FSubor.EnhancedVideo;
end;

function TMapperSuborSb2000.ConsumeBootReset: Boolean;
begin
  Result := FSubor.BootResetPending;
  FSubor.BootResetPending := False;
end;

function TMapperSuborSb2000.GetRamBoot: Boolean;
begin
  Result := FSubor.RamBoot;
end;

procedure TMapperSuborSb2000.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FProgramRam[0], Length(FProgramRam));
  State.Field(FSubor, SizeOf(FSubor));
  if State.Loading then
  begin
    if (FSubor.Outer > 3) or (FSubor.VideoBank > 15) or
      (FSubor.KeyReplyLength > Length(FSubor.KeyReply)) or
      (FSubor.KeyReplyIndex > FSubor.KeyReplyLength) or (FSubor.MouseLength > Length(FSubor.MouseReply)) or
      (FSubor.MouseIndex > FSubor.MouseLength) or ((FSubor.MouseDelay > 0) and (FSubor.MouseIndex >= FSubor.MouseLength)) then
      raise EReadError.Create('Invalid Subor SB-2000 state');
    FMmc3.SelectOuterBank(FSubor.Outer);
  end;
  FMmc3.SerializeState(State);
  FFloppy.Serialize(State);
  State.SharedFields(FSpeech.SerializeState);
end;

end.

