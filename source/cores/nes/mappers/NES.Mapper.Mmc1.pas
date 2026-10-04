unit NES.Mapper.Mmc1;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMapperMmc1 = class(TMapper)
  private
    FPrgRom: TByteArray;
    FChrMemory: TByteArray;
    FPrgRam: array[0..$1FFF] of UInt8;
    FHasChrRam: Boolean;
    FForceRamEnabled: Boolean;
    FBoardMirrorMode: TMirrorMode;
    FShiftRegister: UInt8;
    FWriteCount: Integer;
    FControl: UInt8;
    FChrBank0: UInt8;
    FChrBank1: UInt8;
    FPrgBank: UInt8;
    FLastWriteCycle: UInt64;
    FHasLastWrite: Boolean;
    FBoard, FOuter, FInit: Integer;
    FLocked, FIrqEnabled, FPending: Boolean;
    FIrqCounter: UInt32;
    procedure UpdateEvent;
    function GetPrgBankCount: Integer;
    function GetChrBankCount4K: Integer;
    function MapPrgBank(Bank: Integer): Integer;
    function MapChrBank4K(Bank: Integer): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; ForceRamEnabled: Boolean = False; Board: Integer = MAPPER_MMC1);
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    function AllowsPpuReadCaching: Boolean; override;
    procedure Reset; override;
  end;

implementation

function TMapperMmc1.AllowsPpuReadCaching: Boolean;
begin
  // CHR mapping changes only on CPU writes, outside synchronous scanline rendering.
  Result := ClassType = TMapperMmc1;
end;

procedure TMapperMmc1.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FPrgRam, SizeOf(FPrgRam));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FBoardMirrorMode, SizeOf(FBoardMirrorMode));
  State.Field(FShiftRegister, SizeOf(FShiftRegister));
  State.Field(FWriteCount, SizeOf(FWriteCount));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FChrBank0, SizeOf(FChrBank0));
  State.Field(FChrBank1, SizeOf(FChrBank1));
  State.Field(FPrgBank, SizeOf(FPrgBank));
  State.Field(FLastWriteCycle, SizeOf(FLastWriteCycle));
  State.Field(FHasLastWrite, SizeOf(FHasLastWrite));
  if FBoard <> MAPPER_MMC1 then
  begin
    State.Field(FOuter, SizeOf(FOuter));
    State.Field(FInit, SizeOf(FInit));
    State.Field(FLocked, SizeOf(FLocked));
    State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
    State.Field(FPending, SizeOf(FPending));
    State.Field(FIrqCounter, SizeOf(FIrqCounter));
  end;
end;

function TMapperMmc1.GetSaveMemory: TByteArray;
begin
  SetLength(Result, SizeOf(FPrgRam));
  Move(FPrgRam[0], Result[0], Length(Result));
end;

procedure TMapperMmc1.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> SizeOf(FPrgRam) then
    raise ENesException.Create('Invalid cartridge save size');

  Move(Data[0], FPrgRam[0], Length(Data));
end;

constructor TMapperMmc1.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; ForceRamEnabled: Boolean; Board: Integer);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FChrMemory := Copy(AChrData);
  FHasChrRam := AHasChrRam;
  FForceRamEnabled := ForceRamEnabled;
  FBoard := Board;
  FBoardMirrorMode := AMirrorMode;
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  Reset;
end;

function TMapperMmc1.GetPrgBankCount: Integer;
begin
  Result := Length(FPrgRom) div $4000;
  if Result <= 0 then
    Result := 1;
end;

function TMapperMmc1.GetChrBankCount4K: Integer;
begin
  Result := Length(FChrMemory) div $1000;
  if Result <= 0 then
    Result := 1;
end;

function TMapperMmc1.MapPrgBank(Bank: Integer): Integer;
begin
  if FBoard = MAPPER_FARID_SLROM then
    Bank := FOuter or (Bank and 7);
  Result := Bank mod GetPrgBankCount;
  if Result < 0 then
    Inc(Result, GetPrgBankCount);
end;

function TMapperMmc1.MapChrBank4K(Bank: Integer): Integer;
begin
  if FBoard = MAPPER_FARID_SLROM then
    Bank := (FOuter shl 2) or (Bank and 31);
  Result := Bank mod GetChrBankCount4K;
  if Result < 0 then
    Inc(Result, GetChrBankCount4K);
end;

function TMapperMmc1.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  var Bank16K: Integer;
  var Offset: Integer;
  if (Address >= $6000) and (Address < $8000) then
  begin
    if not FForceRamEnabled and ((FPrgBank and $10) <> 0) then
      Exit(False); // Unmapped PRG RAM leaves the CPU's open bus intact.
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;

  Result := Address >= $8000;
  if not Result then
    Exit;

  var PrgMode: Integer := (FControl shr 2) and 3;
  if FBoard = MAPPER_MMC1_105 then
  begin
    if FInit <> 2 then
      Bank16K := (Address - $8000) div $4000
    else if (FChrBank0 and 8) = 0 then
      Bank16K := (FChrBank0 and 6) + ((Address - $8000) div $4000)
    else if PrgMode < 2 then
      Bank16K := (FPrgBank and 6) + 8 + ((Address - $8000) div $4000)
    else if PrgMode = 2 then
      if Address < $C000 then
        Bank16K := 8
      else
        Bank16K := (FPrgBank and 7) or 8
    else if Address < $C000 then
      Bank16K := (FPrgBank and 7) or 8
    else
      Bank16K := 15;
    Value := FPrgRom[(MapPrgBank(Bank16K) * $4000 + (Address and $3FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;
  var OuterBank := 0;
  // SUROM connects CHR A16 to PRG A18, including the fixed bank.
  if FHasChrRam and (Length(FPrgRom) >= $80000) then
    OuterBank := FChrBank0 and $10;
  case PrgMode of
    0, 1:
      begin
        Bank16K := MapPrgBank(OuterBank or ((FPrgBank and $0E) + ((Address - $8000) div $4000)));
        Offset := Bank16K * $4000 + ((Address - $8000) and $3FFF);
      end;
    2:
      begin
        if Address < $C000 then
          Bank16K := MapPrgBank(OuterBank)
        else
          Bank16K := MapPrgBank(OuterBank or (FPrgBank and $0F));
        Offset := Bank16K * $4000 + (Address and $3FFF);
      end;
  else
    begin
      if Address < $C000 then
        Bank16K := MapPrgBank(OuterBank or (FPrgBank and $0F))
      else if FHasChrRam and (GetPrgBankCount > 16) then
        Bank16K := MapPrgBank(OuterBank or $0F)
      else if FBoard = MAPPER_FARID_SLROM then
        Bank16K := MapPrgBank(7)
      else
        Bank16K := GetPrgBankCount - 1;
      Offset := Bank16K * $4000 + (Address and $3FFF);
    end;
  end;

  Value := FPrgRom[Offset mod Length(FPrgRom)];
end;

function TMapperMmc1.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    if FBoard = MAPPER_FARID_SLROM then
    begin
      if not FLocked and ((FPrgBank and $10) = 0) then
      begin
        FOuter := (Value and $70) shr 1;
        FLocked := (Value and 8) <> 0
      end;
      Exit(True);
    end;
    if FForceRamEnabled or ((FPrgBank and $10) = 0) then
      FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;

  Result := Address >= $8000;
  if not Result then
    Exit;

  if (Value and $80) <> 0 then
  begin
    FShiftRegister := $10;
    FWriteCount := 0;
    FControl := FControl or $0C;
    UpdateEvent;
    Exit;
  end;

  FShiftRegister := (FShiftRegister shr 1) or ((Value and 1) shl 4);
  Inc(FWriteCount);
  if FWriteCount < 5 then
    Exit;

  var RegisterValue: UInt8 := FShiftRegister and $1F;
  case (Address shr 13) and 3 of
    0:
      FControl := RegisterValue;
    1:
      FChrBank0 := RegisterValue;
    2:
      FChrBank1 := RegisterValue;
    3:
      FPrgBank := RegisterValue;
  end;

  FShiftRegister := $10;
  FWriteCount := 0;
  UpdateEvent;
end;

procedure TMapperMmc1.UpdateEvent;
begin
  if FBoard <> MAPPER_MMC1_105 then
    Exit;
  if (FInit = 0) and ((FChrBank0 and $10) = 0) then
    FInit := 1
  else if (FInit = 1) and ((FChrBank0 and $10) <> 0) then
    FInit := 2;
  FIrqEnabled := (FChrBank0 and $10) = 0;
  if not FIrqEnabled then
  begin
    FIrqCounter := 0;
    FPending := False
  end;
end;

procedure TMapperMmc1.ClockCpu;
begin
  if FIrqEnabled then
  begin
    Inc(FIrqCounter);
    if FIrqCounter >= $20000000 then
    begin
      FPending := True;
      FIrqEnabled := False
    end
  end;
end;

function TMapperMmc1.IrqPending: Boolean;
begin
  Result := FPending
end;

function TMapperMmc1.CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean;
begin
  if Address >= $8000 then
  begin
    // MMC1 ignores the second consecutive write of a CPU RMW instruction.
    if FHasLastWrite and (CpuCycle > FLastWriteCycle) and (CpuCycle - FLastWriteCycle = 1) then
      Exit(True);
    FHasLastWrite := True;
    FLastWriteCycle := CpuCycle;
  end;
  Result := CpuWrite(Address, Value);
end;

function TMapperMmc1.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_MMC1_105) and (Address < $2000) then
  begin
    Value := FChrMemory[Address];
    Exit(True)
  end;
  var Bank4K: Integer;
  var Offset: Integer;
  Result := Address < $2000;
  if not Result then
    Exit;

  var ChrMode: Integer := (FControl shr 4) and 1;
  if ChrMode = 0 then
  begin
    Bank4K := MapChrBank4K((FChrBank0 and $1E) + (Address div $1000));
    Offset := Bank4K * $1000 + (Address and $0FFF);
  end
  else
  begin
    if Address < $1000 then
      Bank4K := MapChrBank4K(FChrBank0)
    else
      Bank4K := MapChrBank4K(FChrBank1);
    Offset := Bank4K * $1000 + (Address and $0FFF);
  end;

  Value := FChrMemory[Offset mod Length(FChrMemory)];
end;

function TMapperMmc1.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_MMC1_105) and (Address < $2000) and FHasChrRam then
  begin
    FChrMemory[Address] := Value;
    Exit(True)
  end;
  var Bank4K: Integer;
  var Offset: Integer;
  Result := (Address < $2000) and FHasChrRam;
  if not Result then
    Exit;

  var ChrMode: Integer := (FControl shr 4) and 1;
  if ChrMode = 0 then
  begin
    Bank4K := MapChrBank4K((FChrBank0 and $1E) + (Address div $1000));
    Offset := Bank4K * $1000 + (Address and $0FFF);
  end
  else
  begin
    if Address < $1000 then
      Bank4K := MapChrBank4K(FChrBank0)
    else
      Bank4K := MapChrBank4K(FChrBank1);
    Offset := Bank4K * $1000 + (Address and $0FFF);
  end;

  FChrMemory[Offset mod Length(FChrMemory)] := Value;
end;

function TMapperMmc1.GetMirrorMode: TMirrorMode;
begin
  if FBoardMirrorMode = TMirrorMode.FourScreen then
    Exit(TMirrorMode.FourScreen);

  case FControl and 3 of
    0:
      Result := TMirrorMode.Single0;
    1:
      Result := TMirrorMode.Single1;
    2:
      Result := TMirrorMode.Vertical;
  else
    Result := TMirrorMode.Horizontal;
  end;
end;

procedure TMapperMmc1.Reset;
begin
  FShiftRegister := $10;
  FWriteCount := 0;
  FControl := $0C;
  FChrBank0 := 0;
  FChrBank1 := 0;
  FPrgBank := 0;
  FHasLastWrite := False;
  FLastWriteCycle := 0;
  FOuter := 0;
  FLocked := False;
  FInit := 0;
  FIrqCounter := 0;
  FIrqEnabled := False;
  FPending := False;
  if FBoard = MAPPER_MMC1_105 then
    FChrBank0 := $10;
end;

end.

