unit NES.Mapper.SuperGameMega;

interface

uses
  NES.APU, NES.Mapper, NES.Mapper.Banked, NES.Mapper.Mmc1, NES.Mapper.Mmc3,
  NES.State, NES.Types;

type
  TMapperSuperGameMega = class(TMapperBanked)
  private
    const
      ControlRomOffset = $380000;
  private
    FMmc1: TMapperMmc1;
    FMmc3: TMapperMmc3;
    FApu: TApu;
    FPatternRam: array[0..$1FFF] of Byte;
    FPrgControl, FChrControl, FLatch, FDipInputs: Byte;
    FPrgRamFitted, FSoundEnabled, FCoinActive: Boolean;
    procedure SyncBanks;
    procedure SyncSpeaker;
    function ReadControlRom(Address: Word): Byte; inline;
  protected
    function ShareProgramRom: Boolean; override;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
    destructor Destroy; override;
    procedure ConnectAudio(Apu: TApu);
    procedure ConfigureRam(Present: Boolean);
    procedure SetCoinInput(Active: Boolean);
    property DipInputs: Byte read FDipInputs write FDipInputs;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function CpuWriteTimed(Address: Word; Value: Byte; CpuCycle: UInt64): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    procedure ClockPpuAddress(Address: Word; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
  end;

implementation

type
  TMmc3View = class(TMapperMmc3);

  TMmc1View = class(TMapperMmc1)
  public
    function PrgBank16(Slot: Integer): Integer;
    function ChrBank4(Slot: Integer): Integer;
  end;

function TMmc1View.PrgBank16(Slot: Integer): Integer;
begin
  var Bank := FPrgBank and $0F;
  case (FControl shr 2) and 3 of
    0, 1:
      Result := (Bank and $0E) or Slot;
    2:
      Result := Bank * Slot;
  else
    if Slot = 0 then
      Result := Bank
    else
      Result := $0F;
  end;
end;

function TMmc1View.ChrBank4(Slot: Integer): Integer;
begin
  if (FControl and $10) = 0 then
    Result := (FChrBank0 and $1E) or Slot
  else if Slot = 0 then
    Result := FChrBank0
  else
    Result := FChrBank1;
end;

constructor TMapperSuperGameMega.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, False, MirrorMode);
  if (Length(Prg) < ControlRomOffset + $10000) or (Length(Chr) = 0) then
    raise ENesException.Create('Missing Super Game Mega Type III program, control or graphics ROM');
  FPrgRamFitted := True;
  var ControllerPrg: TByteArray;
  SetLength(ControllerPrg, $4000);
  FMmc1 := TMapperMmc1.Create(ControllerPrg, nil, False, TMirrorMode.Vertical, True, MAPPER_MMC1A);
  FMmc3 := TMapperMmc3.Create(ControllerPrg, nil, False, TMirrorMode.Vertical);
  TMmc3View(FMmc3).FIrqRequiresCounterTransition := True;
  PowerOn;
end;

destructor TMapperSuperGameMega.Destroy;
begin
  FMmc3.Free;
  FMmc1.Free;
  inherited;
end;

function TMapperSuperGameMega.ShareProgramRom: Boolean;
begin
  Result := True;
end;

procedure TMapperSuperGameMega.ConnectAudio(Apu: TApu);
begin
  FApu := Apu;
  SyncSpeaker;
end;

procedure TMapperSuperGameMega.ConfigureRam(Present: Boolean);
begin
  FPrgRamFitted := Present;
  SyncBanks;
end;

procedure TMapperSuperGameMega.SetCoinInput(Active: Boolean);
begin
  FCoinActive := Active;
end;

procedure TMapperSuperGameMega.SyncSpeaker;
begin
  if FApu <> nil then
    FApu.InternalAudioMuted := not FSoundEnabled;
end;

function TMapperSuperGameMega.ReadControlRom(Address: Word): Byte;
begin
  Result := FPrgRom[ControlRomOffset + Address];
end;

procedure TMapperSuperGameMega.SyncBanks;
begin
  var Mode := (FChrControl shr 4) and 3;
  var Mmc3 := TMmc3View(FMmc3);
  var Mmc1 := TMmc1View(FMmc1);
  var PrgBase := (FPrgControl and $1E) shl 4;
  var ChrBase := (FChrControl and $0E) shl 7;

  case Mode of
    0:
      FMirror := TMirrorMode.Vertical;
    1:
      Mirror(2 + ((FLatch shr 4) and 1));
    2:
      FMirror := FMmc1.GetMirrorMode;
    3:
      FMirror := FMmc3.GetMirrorMode;
  end;

  for var Slot := 0 to 3 do
  begin
    var Mmc3Bank := Mmc3.PrgRegisterBank(Slot);
    var PrgA17 := Mmc3Bank and $10;
    if (FPrgControl and $20) <> 0 then
      if Mode = 1 then
        PrgA17 := (FLatch and 4) shl 2
      else
        PrgA17 := (FPrgControl and 1) shl 4;

    var Inner: Integer;
    case Mode of
      0:
        begin
          Inner := FLatch and 7;
          if Slot >= 2 then
            Inner := 7;
          Inner := (Inner shl 1) or (Slot and 1);
        end;
      1:
        Inner := ((FLatch and 3) shl 2) or Slot;
      2:
        Inner := ((Mmc1.PrgBank16(Slot shr 1) and 7) shl 1) or (Slot and 1);
    else
      Inner := Mmc3Bank and $0F;
    end;
    Prg8(Slot, PrgBase or PrgA17 or Inner);
  end;

  for var Slot := 0 to 7 do
  begin
    var Mmc3Bank := Mmc3.ChrRegisterBank(Slot xor ((Mmc3.FBankSelect shr 5) and 4));
    var ChrA17 := Mmc3Bank and $80;
    if (FChrControl and $40) <> 0 then
      ChrA17 := (FChrControl and 1) shl 7;
    var Inner := Mmc3Bank and $7F;
    if (Mode and 1) = 0 then
      Inner := ((Mmc1.ChrBank4(Slot shr 2) and $1F) shl 2) or (Slot and 3);
    Chr1(Slot, ChrBase or ChrA17 or Inner);
  end;

  FRamEnabled := FPrgRamFitted and ((Mmc3.FPrgRamControl and $80) <> 0);
  FRamWritable := (Mmc3.FPrgRamControl and $40) = 0;
end;

function TMapperSuperGameMega.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if (Address and $FF0F) = $4F0F then
  begin
    // The control EPROM counts a credit on release of the active-low line.
    Value := (FDipInputs and $7F) or (Ord(not FCoinActive) shl 7);
    Exit(True);
  end;

  if ((Address >= $5000) and (Address < $6000)) or
    ((Address >= $6000) and (Address < $8000) and ((FPrgControl and $20) <> 0)) or
    ((Address >= $8000) and ((FPrgControl and $80) = 0)) then
  begin
    Value := ReadControlRom(Address);
    Exit(True);
  end;

  Result := inherited CpuRead(Address, Value);
end;

function TMapperSuperGameMega.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := CpuWriteTimed(Address, Value, High(UInt64));
end;

function TMapperSuperGameMega.CpuWriteTimed(Address: Word; Value: Byte; CpuCycle: UInt64): Boolean;
begin
  case Address and $FF0F of
    $5000:
      begin
        FSoundEnabled := (Value and 1) <> 0;
        SyncSpeaker;
        Exit(True);
      end;
    $5001:
      begin
        FPrgControl := Value;
        SyncBanks;
        Exit(True);
      end;
    $5002:
      begin
        FChrControl := Value and $7F;
        SyncBanks;
        Exit(True);
      end;
  end;

  if Address < $8000 then
  begin
    if (Address >= $6000) and ((FPrgControl and $20) <> 0) then
      Exit(True);
    Exit(inherited CpuWrite(Address, Value));
  end;

  var Mode := (FChrControl shr 4) and 3;
  if Mode < 2 then
  begin
    var RomByte: Byte;
    CpuRead(Address, RomByte);
    FLatch := Value and RomByte;
  end;
  // The mapper selection multiplexes the outputs. Both ASICs still see
  // register writes and retain their state when another mode drives the bus.
  if CpuCycle = High(UInt64) then
    FMmc1.CpuWrite(Address, Value)
  else
    FMmc1.CpuWriteTimed(Address, Value, CpuCycle);
  FMmc3.CpuWrite(Address, Value);
  SyncBanks;
  Result := True;
end;

function TMapperSuperGameMega.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if (Address < $2000) and ((FPrgControl and $40) = 0) then
  begin
    Value := FPatternRam[Address];
    Exit(True);
  end;
  Result := inherited PpuRead(Address, Value);
end;

function TMapperSuperGameMega.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := Address < $2000;
  if Result and ((FPrgControl and $40) = 0) then
    FPatternRam[Address] := Value;
end;

procedure TMapperSuperGameMega.ClockPpuAddress(Address: Word; PpuCycle: UInt64);
begin
  FMmc3.ClockPpuAddress(Address, PpuCycle);
end;

function TMapperSuperGameMega.IrqPending: Boolean;
begin
  Result := ((FChrControl and $30) = $30) and FMmc3.IrqPending;
end;

procedure TMapperSuperGameMega.PowerOn;
begin
  FLatch := 0;
  FMmc1.PowerOn;
  FMmc3.PowerOn;
  Reset;
end;

procedure TMapperSuperGameMega.Reset;
begin
  FPrgControl := 0;
  FChrControl := 0;
  FSoundEnabled := False;
  FCoinActive := False;
  FMmc3.CpuWrite($E000, 0);
  SyncBanks;
  SyncSpeaker;
end;

procedure TMapperSuperGameMega.SerializeState(State: TNesStateArchive);
begin
  // The control and game ROMs are immutable. Serialize the two writable RAMs
  // and the controller state, then rebuild the external address muxes.
  State.Field(FPrgRam[0], Length(FPrgRam));
  State.Field(FPatternRam, SizeOf(FPatternRam));
  State.Field(FPrgControl, SizeOf(FPrgControl));
  State.Field(FChrControl, SizeOf(FChrControl));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FSoundEnabled, SizeOf(FSoundEnabled));
  FMmc1.SerializeState(State);
  FMmc3.SerializeState(State);
  if State.Loading then
  begin
    SyncBanks;
    SyncSpeaker;
  end;
end;

end.

