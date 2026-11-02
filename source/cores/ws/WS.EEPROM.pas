unit WS.EEPROM;

interface

uses
  System.SysUtils, System.Classes, System.Math, HW.EEPROM93Cxx, Core.Snapshots;

const
  // WS bridge sends a full 16-bit command even for the 9/13-bit chips.
  // CPU/4 serial clock is a conservative controller profile, not a measured
  // SoC divider. CPU/4 stays below the legacy 1 MHz limit; CPU/8 exceeded
  // Kurupara's fixed read wait. ST's 2003 F/M-process devices specify tW <= 10 ms.
  WS_EEPROM_BIT_CLOCKS = 4;
  WS_EEPROM_PROGRAM_CLOCKS = 30720; // 3.072 MHz * 10 ms (worst-case profile)

type
  // Parallel WS bridge to RetroMul's shared Microwire engine. Register
  // writes remain live while an in-flight transaction uses latched values.
  TWSEEPROM = class
  private
    FChip: TSerialEEPROM93Cxx;
    FSize, FAddressBits: Integer;
    FWriteData, FReadData, FCommand: Word;
    FStatus: Byte;
    FInternal, FProtected: Boolean;
    FBusyClocks, FProgramClocks: Integer;
    FWriteEnabled, FProgramming: Boolean;
    FPendingCommand: Cardinal;
    FPendingData: Word;
    FPendingControl: Byte;
    procedure ClockBit(Value: Boolean);
    procedure Transfer(Command: Cardinal; Data: Word; Control: Byte);
    procedure Complete;
  public
    constructor Create(Size: Integer; Internal: Boolean = False);
    destructor Destroy; override;
    procedure Reset;
    procedure InitializeAfterBoot(WriteProtected: Boolean);
    procedure Tick(Clocks: Integer);
    function ReadPort(Offset: Integer): Byte;
    procedure WritePort(Offset: Integer; Value: Byte; ColorMode: Boolean);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    function Dirty: Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TWSEEPROM.Create(Size: Integer; Internal: Boolean);
begin
  inherited Create;
  FSize := Size;
  FInternal := Internal;
  FChip := TSerialEEPROM93Cxx.Create(Size);
  var N := Size div 2;
  while N > 1 do
  begin
    Inc(FAddressBits);
    N := N shr 1;
  end;
  Reset;
end;

destructor TWSEEPROM.Destroy;
begin
  FChip.Free;
  inherited;
end;

procedure TWSEEPROM.Reset;
begin
  FChip.Reset;
  FWriteData := 0;
  FReadData := 0;
  FCommand := 0;
  FStatus := 2;
  FProtected := False;
  FBusyClocks := 0;
  FProgramClocks := 0;
  FWriteEnabled := False;
  FProgramming := False;
  FPendingCommand := 0;
  FPendingData := 0;
  FPendingControl := 0;
end;

procedure TWSEEPROM.InitializeAfterBoot(WriteProtected: Boolean);
begin
  // The boot ROM enables Microwire writes before locking the owner's data.
  Transfer((Cardinal(1) shl (FAddressBits + 2)) or
    (Cardinal(3) shl (FAddressBits - 2)), 0, $40);
  FWriteEnabled := True;
  FCommand := $0130;
  FStatus := 3;
  FProtected := WriteProtected;
end;

procedure TWSEEPROM.ClockBit(Value: Boolean);
begin
  FChip.Lines(True, False, Value);
  FChip.Lines(True, True, Value);
end;

procedure TWSEEPROM.Transfer(Command: Cardinal; Data: Word; Control: Byte);
begin
  FChip.Lines(False, False, False);
  FChip.Lines(True, False, False);
  for var I := FAddressBits + 2 downto 0 do
    ClockBit(Command and (Cardinal(1) shl I) <> 0);
  if Control = $10 then
  begin
    FReadData := 0;
    for var I := 15 downto 0 do
    begin
      ClockBit(False);
      if FChip.Output then
        FReadData := FReadData or (1 shl I);
    end;
  end
  else if Control = $20 then
    for var I := 15 downto 0 do
      ClockBit(Data and (1 shl I) <> 0);
  FChip.Lines(False, False, False);
end;

procedure TWSEEPROM.Complete;
begin
  var Operation := (FPendingCommand shr FAddressBits) and 3;
  var SubOperation := (FPendingCommand shr (FAddressBits - 2)) and 3;
  if FInternal and FProtected and (Operation = 0) and
    ((SubOperation = 1) or (SubOperation = 2)) then
  begin
    // Protection also applies to WRAL/ERAL: never alter the owner profile.
    var Opcode := 1;
    var Control: Byte := $20;
    if SubOperation = 2 then
    begin
      Opcode := 3;
      Control := $40;
    end;
    for var Address := 0 to $2F do
      Transfer((Cardinal(1) shl (FAddressBits + 2)) or
        (Cardinal(Opcode) shl FAddressBits) or Cardinal(Address),
        FPendingData, Control);
  end
  else
    Transfer(FPendingCommand, FPendingData, FPendingControl);
  if Operation = 0 then
    case SubOperation of
      0:
        FWriteEnabled := False;
      3:
        FWriteEnabled := True;
    end;
  FProgramming := False;
  FStatus := FStatus or 2;
  if FPendingControl = $10 then
    FStatus := FStatus or 1;
  FPendingControl := 0;
end;

procedure TWSEEPROM.Tick(Clocks: Integer);
begin
  while (FBusyClocks > 0) and (Clocks > 0) do
  begin
    var Count := Min(FBusyClocks, Clocks);
    Dec(FBusyClocks, Count);
    Dec(Clocks, Count);
    if FBusyClocks = 0 then
      if FProgramClocks > 0 then
      begin
        // Programming is self-timed after the serial command/data transfer.
        FBusyClocks := FProgramClocks;
        FProgramClocks := 0;
        FProgramming := True;
      end
      else
        Complete;
  end;
end;

function TWSEEPROM.ReadPort(Offset: Integer): Byte;
begin
  case Offset of
    0:
      Result := Byte(FReadData);
    1:
      Result := FReadData shr 8;
    2:
      Result := Byte(FCommand);
    3:
      Result := FCommand shr 8;
    4:
      Result := FStatus or (Ord(FProtected) shl 7);
  else
    Result := 0; // The high byte of control/status is not another status port.
  end;
end;

procedure TWSEEPROM.WritePort(Offset: Integer; Value: Byte; ColorMode: Boolean);
var
  Command: Cardinal;
  Pattern: Word;
  Operation, Address, SubOperation: Integer;
begin
  case Offset of
    0:
      FWriteData := (FWriteData and $FF00) or Value;
    1:
      FWriteData := (FWriteData and $FF) or (Word(Value) shl 8);
    2:
      FCommand := (FCommand and $FF00) or Value;
    3:
      FCommand := (FCommand and $FF) or (Word(Value) shl 8);
    4:
      begin
        Value := Value and $F0;
        // Multiple operation bits are invalid, including protect+read.
        if (Value = 0) or ((Integer(Value) and (Integer(Value) - 1)) <> 0) then
          Exit;
        if Value = $80 then
        begin
          if FInternal then
            FProtected := True
          else if not FProgramming then
          begin
            // The 2001 aborts the serial controller, not a cell's self-timed
            // programming pulse. Preserve the mapper's sticky DONE flag.
            FBusyClocks := 0;
            FProgramClocks := 0;
            FPendingControl := 0;
            FStatus := FStatus or 2;
          end;
          Exit;
        end;
        if FBusyClocks <> 0 then
          Exit;
        Pattern := FCommand;
        if (FSize <> 128) and not (FInternal and not ColorMode) then
          Pattern := Pattern shr 4;
        // Reject absent start bits and unsupported command patterns rather
        // than silently reducing every register value to a valid opcode.
        case Pattern and $FFC0 of
          $0100, $0140, $0180, $01C0:
            ;
        else
          Exit;
        end;
        Operation := (Pattern shr 6) and 3;
        SubOperation := (Pattern shr 4) and 3;
        if ((Value = $10) and (Operation <> 2)) or
          ((Value = $20) and not ((Operation = 1) or
          ((Operation = 0) and (SubOperation = 1)))) or
          ((Value = $40) and not ((Operation = 2) or (Operation = 3) or
          ((Operation = 0) and (SubOperation <> 1)))) then
          Exit;
        Command := FCommand;
        if FInternal and (FSize > 128) and not ColorMode then
          if Command and $C0 <> 0 then
            Command := ((Command and $FFC0) shl 4) or (Command and $3F)
          else
            Command := Command shl 4;
        if FSize = 1024 then
          if Command and $C00 = 0 then
            Command := ((Command and $FC00) shr 1) or ((Command and $300) shr 1)
          else
            Command := ((Command and $FC00) shr 1) or (Command and $1FF);
        Address := Command and ((1 shl FAddressBits) - 1);
        if FInternal and FProtected and (Address >= $30) and
          ((Operation = 1) or (Operation = 3)) then
          Exit;
        FPendingCommand := Command;
        FPendingData := FWriteData;
        FPendingControl := Value;
        FStatus := FStatus and not 2;
        if ((Value = $10) and FInternal) or
          ((Value <> $10) and not FInternal) then
          FStatus := FStatus and not 1;
        FProgramming := False;
        FProgramClocks := 0;
        FBusyClocks := 16 * WS_EEPROM_BIT_CLOCKS;
        if (Value = $10) or (Value = $20) then
          Inc(FBusyClocks, 16 * WS_EEPROM_BIT_CLOCKS);
        // WEN/WDS and read do not program cells. Disabled writes do not
        // start a programming cycle. Timing does not depend on data changes.
        if FWriteEnabled and ((Operation = 1) or (Operation = 3) or
          ((Operation = 0) and ((SubOperation = 1) or (SubOperation = 2)))) then
          FProgramClocks := WS_EEPROM_PROGRAM_CLOCKS;
      end;
  end;
end;

function TWSEEPROM.Battery: TBytes;
begin
  Result := FChip.Battery;
end;

procedure TWSEEPROM.LoadBattery(const Data: TBytes);
begin
  FChip.LoadBattery(Data);
end;

function TWSEEPROM.Dirty: Boolean;
begin
  Result := FChip.Dirty;
end;

procedure TWSEEPROM.SerializeState(State: TStateArchive);
begin
  FChip.SerializeState(State);
  State.Field(FWriteData, SizeOf(FWriteData));
  State.Field(FReadData, SizeOf(FReadData));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FProtected, SizeOf(FProtected));
  State.Field(FBusyClocks, SizeOf(FBusyClocks));
  State.Field(FProgramClocks, SizeOf(FProgramClocks));
  State.Field(FWriteEnabled, SizeOf(FWriteEnabled));
  State.Field(FProgramming, SizeOf(FProgramming));
  State.Field(FPendingCommand, SizeOf(FPendingCommand));
  State.Field(FPendingData, SizeOf(FPendingData));
  State.Field(FPendingControl, SizeOf(FPendingControl));
  if State.Loading then
    if (FBusyClocks < 0) or (FBusyClocks > WS_EEPROM_PROGRAM_CLOCKS) or
      ((FProgramClocks <> 0) and (FProgramClocks <> WS_EEPROM_PROGRAM_CLOCKS)) or
      (FProgramming and ((FProgramClocks <> 0) or (FBusyClocks = 0))) or
      ((FPendingControl <> 0) and (FPendingControl <> $10) and
      (FPendingControl <> $20) and (FPendingControl <> $40)) or
      ((FBusyClocks = 0) <> (FPendingControl = 0)) then
      raise EReadError.Create('Invalid WonderSwan EEPROM transaction');
end;

end.

