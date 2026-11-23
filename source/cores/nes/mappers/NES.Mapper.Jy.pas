unit NES.Mapper.Jy;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked, NES.Mapper.Mmc3;

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
    FAccumulator: Byte;
    FOuterBanks, FHasWorkRam: Boolean;
    FWorkBank, FBoardPrgBase, FBoardChrBase: Integer;
    procedure UpdateBanks;
    procedure UpdateOuterBanks;
    function OuterChrBank(Bank: Integer): Integer;
    function ExtendedMirroring: Boolean;
    function ChrNametable(Bank: Integer): Boolean;
    procedure TickIrq;
    function NameRamOffset(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure ConfigureWorkRam(Enabled: Boolean);
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

  TMapperHsk007 = class(TMapperJy)
  private
    FMmc3: TMapperMmc3;
    FSubmapper: Integer;
    FBoardMode, FOuterBank: Byte;
    function JySelected: Boolean; inline;
    procedure UpdateBoardBanks;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
    destructor Destroy; override;
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockCpu; override;
    procedure ClockCpuWrite; override;
    procedure ClockPpuRead; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
  end;

implementation

type
  THsk007Mmc3 = class(TMapperMmc3)
  private
    FPrgStart, FPrgMask, FChrStart, FChrMask: Integer;
    FFixedPrg: Boolean;
  public
    procedure ApplyWiring(Mode, Outer: Byte; PrgBase, ChrBase: Integer);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
  end;

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
  if FOuterBanks then
    State.Field(FAccumulator, SizeOf(FAccumulator));
end;

constructor TMapperJy.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FOuterBanks := Board >= MAPPER_JY_281;
  Reset;
end;

procedure TMapperJy.ConfigureWorkRam(Enabled: Boolean);
begin
  if FOuterBanks then
  begin
    FHasWorkRam := Enabled;
    FRamEnabled := Enabled;
  end;
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
  if FOuterBanks then
    FChrControl := 0;
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
  FAccumulator := 0;
  FRamEnabled := FHasWorkRam;
  UpdateBanks;
end;

function TMapperJy.OuterChrBank(Bank: Integer): Integer;
begin
  case FBoard of
    MAPPER_HSK007:
      Exit((FBoardChrBase and not $FF) or (Bank and $FF));
    MAPPER_JY_SC871115C:
      Exit(((FChrControl and 3) shl 8) or (Bank and $1FF));
    MAPPER_JY_281:
      Exit((Bank and $FF) or (Integer(FChrControl) shl 8));
    MAPPER_JY_295:
      Exit((Bank and $7F) or ((FChrControl and 7) shl 7));
    MAPPER_JY_397:
      Exit((Bank and $7F) or (Integer(FChrControl) shl 7));
    MAPPER_JY_282:
      Result := (Integer(FChrControl) shl 6) and $600;
    MAPPER_JY_388:
      Result := (FChrControl and 2) shl 8;
  else
    Result := (Integer(FChrControl) shl 7) and $600;
  end;
  if (FChrControl and $20) <> 0 then
    Result := Result or (Bank and $1FF)
  else
    Result := Result or ((FChrControl and 1) shl 8) or (Bank and $FF);
end;

procedure TMapperJy.UpdateOuterBanks;
begin
  var PrgMask := $1F;
  var PrgBase := (Integer(FChrControl) shl 4) and not $1F;
  case FBoard of
    MAPPER_HSK007:
      PrgBase := FBoardPrgBase and not PrgMask;
    MAPPER_JY_SC871115C:
      begin
        if (FChrControl and 4) <> 0 then
          PrgMask := $3F;
        PrgBase := (Integer(FChrControl) shl 4) and not PrgMask;
      end;
    MAPPER_JY_281:
      PrgBase := Integer(FChrControl) shl 5;
    MAPPER_JY_295:
      begin
        PrgMask := $0F;
        PrgBase := (FChrControl and 7) shl 4;
      end;
    MAPPER_JY_386:
      PrgBase := ((FChrControl and 2) shl 4) or ((FChrControl and 8) shl 3);
    MAPPER_JY_387:
      begin
        PrgMask := $0F;
        PrgBase := ((FChrControl and 2) shl 3) or ((FChrControl and 8) shl 2);
      end;
    MAPPER_JY_388:
      PrgBase := (FChrControl and $0C) shl 3;
  end;

  var PrgMode := FMode and 3;
  var PrgShift := 0;
  if PrgMode < 2 then
    PrgShift := 2 - PrgMode;
  var Banks := FPrg;
  if PrgMode = 3 then
    for var Slot := 0 to 3 do
    begin
      Banks[Slot] := 0;
      for var BitIndex := 0 to 6 do
        Banks[Slot] := Banks[Slot] or (((FPrg[Slot] shr BitIndex) and 1) shl (6 - BitIndex));
    end;

  var LastBank := Banks[3];
  if (FMode and 4) = 0 then
    LastBank := PrgMask shr PrgShift;
  for var Slot := 0 to 3 do
  begin
    var RegisterIndex := ((Slot shr PrgShift) shl PrgShift) or ((1 shl PrgShift) - 1);
    var Bank := Banks[RegisterIndex];
    if RegisterIndex = 3 then
      Bank := LastBank;
    Bank := (Bank shl PrgShift) or (Slot and ((1 shl PrgShift) - 1));
    Prg8(Slot, PrgBase or (Bank and PrgMask));
  end;
  FWorkBank := PrgBase or (((Banks[3] shl PrgShift) or ((1 shl PrgShift) - 1)) and PrgMask);

  var ChrMode := (FMode shr 3) and 3;
  var ChrShift := 3 - ChrMode;
  for var Slot := 0 to 7 do
  begin
    var RegisterIndex := (Slot shr ChrShift) shl ChrShift;
    if (ChrMode = 1) and ((FChrControl and $80) <> 0) then
      RegisterIndex := FLatches[Slot shr 2];
    Chr1(Slot, OuterChrBank((FChr[RegisterIndex] shl ChrShift) or
        (Slot and ((1 shl ChrShift) - 1))));
  end;
  Mirror(FMirrorRegister and 3);
end;

procedure TMapperJy.UpdateBanks;
begin
  if FOuterBanks then
  begin
    UpdateOuterBanks;
    Exit;
  end;
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
      $5802:
        if FOuterBanks then
          Value := FAccumulator
        else
          Result := False;
      $5803:
        Value := FScratch;
    else
      Result := False;
    end;
    Exit;
  end;
  if (Address >= $6000) and (Address < $8000) then
  begin
    if (FMode and $80) <> 0 then
    begin
      Value := FPrgRom[(FWorkBank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
      Exit(True);
    end;
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperJy.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  if (Address >= $5000) and (Address < $6000) then
  begin
    if FOuterBanks then
      Address := $5800 or (Address and 3);
    case Address and $F803 of
      $5800:
        FMultiplyA := Value;
      $5801:
        FMultiplyB := Value;
      $5802:
        if FOuterBanks then
          FAccumulator := (Integer(FAccumulator) + Value) and $FF;
      $5803:
        begin
          FScratch := Value;
          FAccumulator := 0;
        end;
    end;
    Exit;
  end;

  if Address < $8000 then
    Exit(((FMode and $80) = 0) and inherited CpuWrite(Address, Value));

  if FOuterBanks and ((Address and $0800) <> 0) and ((Address and $F000) <> $C000) then
    Exit;

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
            begin
              FPending := False;
              if FOuterBanks then
                FPrescaler := 0;
            end;
          end;
        1:
          FIrqMode := Value;
        2:
          begin
            FEnabled := False;
            FPending := False;
            if FOuterBanks then
              FPrescaler := 0;
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
      begin
        if FOuterBanks then
          Index := Index and 3;
        case Index of
          0:
            FMode := Value;
          1:
            if FOuterBanks then
              FMirrorRegister := Value and $0B
            else
              FMirrorRegister := Value and 3;
          2:
            if FOuterBanks then
              FNameSelect := Value and $C0
            else
              FNameSelect := Value and $80;
          3:
            FChrControl := Value;
        end;
      end;
  end;
  UpdateBanks;
end;

function TMapperJy.ExtendedMirroring: Boolean;
begin
  if FOuterBanks then
    Exit((FBoard <> MAPPER_JY_388) and
      (((FMode and $20) <> 0) or ((FMirrorRegister and 8) <> 0)));
  Result := ((FBoard = MAPPER_JY_209) and ((FMode and $20) <> 0)) or
    (FBoard = MAPPER_JY_211);
end;

function TMapperJy.ChrNametable(Bank: Integer): Boolean;
begin
  Result := ExtendedMirroring and (not FOuterBanks or ((FMode and $20) <> 0)) and
    (((FMode and $40) <> 0) or ((Bank and $80) <> (FNameSelect and $80)));
end;

function TMapperJy.NameRamOffset(Address: UInt16): Integer;
begin
  var Slot := ((Address and $0FFF) shr 10);
  if ExtendedMirroring then
    Slot := FName[Slot] and 1
  else
    case FMirrorRegister and 3 of
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
    if ChrNametable(Bank) then
    begin
      if FOuterBanks then
        Bank := OuterChrBank(Bank);
      Value := FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)];
    end
    else
      Value := FCiram[NameRamOffset(Address)];
    Exit(True);
  end;
  Result := inherited PpuRead(Address, Value);
  if Result and ((FBoard = MAPPER_JY_209) or (FOuterBanks and ((FChrControl and $80) <> 0))) then
    if ((Address and $0FF8) = $0FD8) or ((Address and $0FF8) = $0FE8) then
    begin
      if FOuterBanks then
        FLatches[Address shr 12] := ((Address shr 10) and 4) or ((Address shr 4) and 2)
      else
        FLatches[Address shr 12] := (Address shr 4) and (((Address shr 10) and 4) or 2);
      UpdateBanks;
    end;
end;

function TMapperJy.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
  begin
    var Bank := FName[(Address and $0FFF) shr 10];
    // CHR ROM replaces nametable reads while PPU writes still reach CIRAM.
    if FOuterBanks and FHasChrRam and ((FNameSelect and $40) <> 0) and ChrNametable(Bank) then
      FChrMemory[(OuterChrBank(Bank) * $400 + (Address and $3FF)) mod Length(FChrMemory)] := Value
    else
      FCiram[NameRamOffset(Address)] := Value;
    Exit(True);
  end;
  if FOuterBanks and ((FNameSelect and $40) = 0) then
    Exit(Address < $2000);
  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperJy.TickIrq;
begin
  if FOuterBanks and not FEnabled then
    Exit;
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
  if FOuterBanks and (Direction = 2) then
  begin
    if Value <> Mask then
      Exit;
  end
  else if Value <> 0 then
    Exit;
  if not FOuterBanks or ((FIrqMode and 8) = 0) then
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

procedure THsk007Mmc3.ApplyWiring(Mode, Outer: Byte; PrgBase, ChrBase: Integer);
begin
  FFixedPrg := (Mode and 8) = 0;
  if FFixedPrg then
  begin
    FPrgMask := 3;
    PrgBase := PrgBase or ((Outer and 7) shl 1);
  end
  else
  begin
    FPrgMask := $0F;
    if (Outer and $10) <> 0 then
      FPrgMask := $1F;
  end;
  FPrgStart := PrgBase and not FPrgMask;
  FChrMask := $7F;
  if (Outer and $80) <> 0 then
    FChrMask := $FF;
  FChrStart := ChrBase and not FChrMask;
end;

function THsk007Mmc3.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(False);
  var Slot := (Address - $8000) shr 13;
  var Bank := Slot;
  if not FFixedPrg then
  begin
    if ((FBankSelect and $40) <> 0) and ((Slot and 1) = 0) then
      Slot := Slot xor 2;
    if Slot < 2 then
      Bank := FBankRegisters[6 + Slot]
    else
      Bank := $FC + Slot;
  end;
  Bank := FPrgStart or (Bank and FPrgMask);
  Value := FPrgRom[((Bank shl 13) or (Address and $1FFF)) mod Length(FPrgRom)];
  Result := True;
end;

function THsk007Mmc3.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $2000 then
    Exit(False);
  var Bank := FChrStart or ((GetChrOffset(Address) shr 10) and FChrMask);
  Value := FChrMemory[((Bank shl 10) or (Address and $3FF)) mod Length(FChrMemory)];
  Result := True;
end;

constructor TMapperHsk007.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(MAPPER_HSK007, Prg, Chr, HasChrRam, MirrorMode);
  FSubmapper := Submapper;
  FMmc3 := THsk007Mmc3.Create(Prg, Chr, HasChrRam, MirrorMode);
  Reset;
end;

destructor TMapperHsk007.Destroy;
begin
  FMmc3.Free;
  inherited;
end;

procedure TMapperHsk007.UpdateBoardBanks;
begin
  FBoardPrgBase := ((FOuterBank and 8) shl 1) or ((FBoardMode and 3) shl 5);
  FBoardChrBase := ((FOuterBank and $40) shl 1) or ((FBoardMode and 2) shl 8);
  if FSubmapper = 1 then
    FBoardChrBase := FBoardChrBase or ((FBoardMode and 4) shl 6)
  else
    FBoardChrBase := FBoardChrBase or ((FBoardMode and 1) shl 8);
  UpdateBanks;
  if FMmc3 <> nil then
    THsk007Mmc3(FMmc3).ApplyWiring(FBoardMode, FOuterBank, FBoardPrgBase, FBoardChrBase);
end;

function TMapperHsk007.JySelected: Boolean;
begin
  Result := (FBoardMode and $10) <> 0;
end;

procedure TMapperHsk007.Reset;
begin
  FBoardMode := $0F;
  FOuterBank := $90;
  inherited;
  if FMmc3 <> nil then
    FMmc3.Reset;
  UpdateBoardBanks;
end;

procedure TMapperHsk007.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBoardMode, SizeOf(FBoardMode));
  State.Field(FOuterBank, SizeOf(FOuterBank));
  FMmc3.SerializeState(State);
  if State.Loading then
    UpdateBoardBanks;
end;

function TMapperHsk007.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if JySelected then
    Result := inherited CpuRead(Address, Value)
  else
    Result := FMmc3.CpuRead(Address, Value);
end;

function TMapperHsk007.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address and $F00B of
    $5009:
      begin
        FBoardMode := Value;
        UpdateBoardBanks;
        Exit(True);
      end;
    $500B:
      begin
        FOuterBank := Value;
        UpdateBoardBanks;
        Exit(True);
      end;
  end;
  if JySelected then
    Result := inherited CpuWrite(Address, Value)
  else
    Result := (Address >= $8000) and FMmc3.CpuWrite(Address, Value);
end;

function TMapperHsk007.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if JySelected then
    Exit(inherited PpuRead(Address, Value));
  if (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FCiram[FMmc3.NameTableOffset(Address) and $7FF];
    Exit(True);
  end;
  Result := FMmc3.PpuRead(Address, Value);
end;

function TMapperHsk007.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if JySelected then
    Exit(inherited PpuWrite(Address, Value));
  if (Address >= $2000) and (Address < $3F00) then
  begin
    FCiram[FMmc3.NameTableOffset(Address) and $7FF] := Value;
    Exit(True);
  end;
  Result := Address < $2000;
end;

function TMapperHsk007.GetMirrorMode: TMirrorMode;
begin
  if JySelected or (FMmc3 = nil) then
    Result := inherited
  else
    Result := FMmc3.GetMirrorMode;
end;

procedure TMapperHsk007.ClockCpu;
begin
  if JySelected then
    inherited;
end;

procedure TMapperHsk007.ClockCpuWrite;
begin
  if JySelected then
    inherited;
end;

procedure TMapperHsk007.ClockPpuRead;
begin
  if JySelected then
    inherited;
end;

procedure TMapperHsk007.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if JySelected then
    inherited
  else
    FMmc3.ClockPpuAddress(Address, PpuCycle);
end;

function TMapperHsk007.IrqPending: Boolean;
begin
  if JySelected then
    Result := inherited
  else
    Result := FMmc3.IrqPending;
end;

end.

