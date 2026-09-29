unit NES.Mapper.Jy;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperJy = class(TMapperBanked)
  private
    FBoard: Integer;
    FPrg: array[0..3] of Integer;
    FChr, FName: array[0..7] of Integer;
    FLatches: array[0..1] of Integer;
    FCiram: array[0..$7FF] of Byte;
    FMode, FMirrorRegister, FNameSelect, FChrControl: Byte;
    FIrqMode, FPrescaler, FCounter, FXor: Integer;
    FEnabled, FPending, FA12: Boolean;
    FMultiplyA, FMultiplyB, FScratch: Byte;
    FWorkBank: Integer;
    procedure UpdateBanks;
    procedure TickIrq;
    function NameRamOffset(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure ClockCpu; override;
    procedure ClockCpuWrite; override;
    procedure ClockPpuRead; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperJy.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBoard, SizeOf(FBoard));
  State.Field(FPrg, SizeOf(FPrg));
  State.Field(FChr, SizeOf(FChr));
  State.Field(FName, SizeOf(FName));
  State.Field(FLatches, SizeOf(FLatches));
  State.Field(FCiram, SizeOf(FCiram));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FMirrorRegister, SizeOf(FMirrorRegister));
  State.Field(FNameSelect, SizeOf(FNameSelect));
  State.Field(FChrControl, SizeOf(FChrControl));
  State.Field(FIrqMode, SizeOf(FIrqMode));
  State.Field(FPrescaler, SizeOf(FPrescaler));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FXor, SizeOf(FXor));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FA12, SizeOf(FA12));
  State.Field(FMultiplyA, SizeOf(FMultiplyA));
  State.Field(FMultiplyB, SizeOf(FMultiplyB));
  State.Field(FScratch, SizeOf(FScratch));
  State.Field(FWorkBank, SizeOf(FWorkBank));
end;

constructor TMapperJy.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  Reset;
end;

procedure TMapperJy.Reset;
begin
  inherited;
  FillChar(FPrg, SizeOf(FPrg), 0);
  FillChar(FChr, SizeOf(FChr), 0);
  FillChar(FName, SizeOf(FName), 0);
  FLatches[0] := 0;
  FLatches[1] := 4;
  FMode := 0;
  FMirrorRegister := 0;
  FNameSelect := 0;
  FChrControl := $20;
  FIrqMode := 0;
  FPrescaler := 0;
  FCounter := 0;
  FXor := 0;
  FEnabled := False;
  FPending := False;
  FA12 := False;
  FMultiplyA := 0;
  FMultiplyB := 0;
  FScratch := 0;
  FRamEnabled := False;
  UpdateBanks;
end;

procedure TMapperJy.UpdateBanks;
begin
  var Banks: array[0..3] of Integer;
  for var i := 0 to 3 do
  begin
    Banks[i] := FPrg[i];
    if (FMode and 3) = 3 then
    begin
      Banks[i] := 0;
      for var b := 0 to 6 do
        Banks[i] := Banks[i] or (((FPrg[i] shr b) and 1) shl (6 - b));
    end;
  end;
  case FMode and 3 of
    0:
      begin
        var Base := $3C;
        if (FMode and 4) <> 0 then
          Base := Banks[3];
        for var i := 0 to 3 do
          Prg8(i, Base + i);
        FWorkBank := Banks[3] * 4 + 3;
      end;
    1:
      begin
        Prg16(0, Banks[1]);
        var Base := $3E;
        if (FMode and 4) <> 0 then
          Base := Banks[3];
        Prg8(2, Base);
        Prg8(3, Base + 1);
        FWorkBank := Banks[3] * 2 + 1;
      end;
    2, 3:
      begin
        for var i := 0 to 2 do
          Prg8(i, Banks[i]);
        if (FMode and 4) <> 0 then
          Prg8(3, Banks[3])
        else
          Prg8(3, $3F);
        FWorkBank := Banks[3];
      end;
  end;
  var ChrMode := (FMode shr 3) and 3;
  var ChrBanks: array[0..7] of Integer;
  for var i := 0 to 7 do
  begin
    var Index := i;
    if (ChrMode >= 2) and ((FChrControl and $80) <> 0) and (i in [2, 3]) then
      Dec(Index, 2);
    ChrBanks[i] := FChr[Index];
    if (FChrControl and $20) = 0 then
      ChrBanks[i] := (ChrBanks[i] and ((1 shl (5 + ChrMode)) - 1)) or
        ((((FChrControl and $18) shr 2) or (FChrControl and 1)) shl (5 + ChrMode));
  end;
  case ChrMode of
    0:
      Chr8(ChrBanks[0]);
    1:
      begin
        Chr4(0, ChrBanks[FLatches[0]]);
        Chr4(1, ChrBanks[FLatches[1]]);
      end;
    2:
      for var i := 0 to 3 do
        Chr2(i, ChrBanks[i * 2]);
    3:
      for var i := 0 to 7 do
        Chr1(i, ChrBanks[i]);
  end;
  Mirror(FMirrorRegister);
end;

function TMapperJy.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $5000) and (Address < $6000) then
  begin
    Result := True;
    case Address and $F803 of
      $5000:
        Value := 0;
      $5800:
        Value := (Integer(FMultiplyA) * FMultiplyB) and $FF;
      $5801:
        Value := (Integer(FMultiplyA) * FMultiplyB) shr 8;
      $5803:
        Value := FScratch;
    else
      Result := False;
    end;
    Exit;
  end;
  if (Address >= $6000) and (Address < $8000) then
  begin
    Result := (FMode and $80) <> 0;
    if Result then
      Value := FPrgRom[(FWorkBank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit;
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperJy.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  if (Address >= $5000) and (Address < $6000) then
  begin
    case Address and $F803 of
      $5800:
        FMultiplyA := Value;
      $5801:
        FMultiplyB := Value;
      $5803:
        FScratch := Value;
    end;
    Exit;
  end;
  if Address < $8000 then
    Exit(False);
  var Index := Address and 7;
  case Address and $F000 of
    $8000:
      FPrg[Index and 3] := Value and $7F;
    $9000:
      FChr[Index] := (FChr[Index] and $FF00) or Value;
    $A000:
      FChr[Index] := (FChr[Index] and $FF) or (Integer(Value) shl 8);
    $B000:
      if Index < 4 then
        FName[Index] := (FName[Index] and $FF00) or Value
      else
        FName[Index and 3] := (FName[Index and 3] and $FF) or (Integer(Value) shl 8);
    $C000:
      case Index of
        0:
          begin
            FEnabled := (Value and 1) <> 0;
            if not FEnabled then
              FPending := False;
          end;
        1:
          FIrqMode := Value;
        2:
          begin
            FEnabled := False;
            FPending := False;
          end;
        3:
          FEnabled := True;
        4:
          FPrescaler := Value xor FXor;
        5:
          FCounter := Value xor FXor;
        6:
          FXor := Value;
      end;
    $D000:
      case Index of
        0:
          FMode := Value;
        1:
          FMirrorRegister := Value and 3;
        2:
          FNameSelect := Value and $80;
        3:
          FChrControl := Value;
      end;
  end;
  UpdateBanks;
end;

function TMapperJy.NameRamOffset(Address: UInt16): Integer;
begin
  var Slot := ((Address and $0FFF) shr 10);
  if (FBoard = 209) and ((FMode and $20) <> 0) then
    Slot := FName[Slot] and 1
  else
    case FMirrorRegister of
      0:
        Slot := Slot and 1;
      1:
        Slot := Slot shr 1;
      2:
        Slot := 0;
      3:
        Slot := 1;
    end;
  Result := Slot * $400 + (Address and $3FF);
end;

function TMapperJy.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
  begin
    var Bank := FName[(Address and $0FFF) shr 10];
    if (FBoard = 209) and ((FMode and $20) <> 0) and (((FMode and $40) <> 0) or ((Bank and $80) <> FNameSelect)) then
      Value := FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)]
    else
      Value := FCiram[NameRamOffset(Address)];
    Exit(True);
  end;
  Result := inherited PpuRead(Address, Value);
  if Result and (FBoard = 209) then
    if ((Address and $0FF8) = $0FD8) or ((Address and $0FF8) = $0FE8) then
    begin
      FLatches[Address shr 12] := (Address shr 4) and (((Address shr 10) and 4) or 2);
      UpdateBanks;
    end;
end;

function TMapperJy.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
  begin
    FCiram[NameRamOffset(Address)] := Value;
    Exit(True);
  end;
  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperJy.TickIrq;
begin
  var Direction := (FIrqMode shr 6) and 3;
  if not (Direction in [1, 2]) then
    Exit;
  var Mask := $FF;
  if (FIrqMode and 4) <> 0 then
    Mask := 7;
  var Value := FPrescaler and Mask;
  if Direction = 1 then
    Value := (Value + 1) and Mask
  else
    Value := (Value - 1) and Mask;
  FPrescaler := (FPrescaler and ($FF xor Mask)) or Value;
  if Value <> 0 then
    Exit;
  if Direction = 1 then
    FCounter := (FCounter + 1) and $FF
  else
    FCounter := (FCounter - 1) and $FF;
  if FEnabled and (((Direction = 1) and (FCounter = 0)) or ((Direction = 2) and (FCounter = $FF))) then
    FPending := True;
end;

procedure TMapperJy.ClockCpu;
begin
  if (FIrqMode and 3) = 0 then
    TickIrq;
end;

procedure TMapperJy.ClockCpuWrite;
begin
  if (FIrqMode and 3) = 3 then
    TickIrq;
end;

procedure TMapperJy.ClockPpuRead;
begin
  if (FIrqMode and 3) = 2 then
    TickIrq;
end;

procedure TMapperJy.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  var High := (Address and $1000) <> 0;
  if High and not FA12 and ((FIrqMode and 3) = 1) then
    TickIrq;
  FA12 := High;
end;

function TMapperJy.IrqPending: Boolean;
begin
  Result := FPending;
end;

end.

