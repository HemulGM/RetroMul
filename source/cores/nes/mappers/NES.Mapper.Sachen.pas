unit NES.Mapper.Sachen;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperSachen = class(TMapperBanked)
  private
    FBoard, FSelect: Integer;
    FRegs: array[0..7] of Byte;
    FAccumulator, FInverter, FStaging, FOutput, FChr: Byte;
    FIncrease, FInvert, FY, FChrEnabled: Boolean;
    FNameRam: array[0..$7FF] of Byte;
    FNames: array[0..3] of Byte;
    procedure UpdateBanks;
    function Convert(Value: Byte): Byte;
    function ChipRead: Byte;
    procedure ChipWrite(Address: Word; Value: Byte);
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

constructor TMapperSachen.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  Reset
end;

procedure TMapperSachen.Reset;
begin
  inherited;
  FRamEnabled := False;
  FSelect := 0;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FAccumulator := 0;
  FInverter := 0;
  FStaging := 0;
  FOutput := 0;
  FChr := 0;
  FIncrease := False;
  FInvert := FBoard in [
      MAPPER_SACHEN_136,
      MAPPER_SACHEN_147,
      MAPPER_TXC_22211B];
  FY := False;
  FChrEnabled := True;
  Prg32(0);
  UpdateBanks;
end;

procedure TMapperSachen.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FAccumulator, SizeOf(FAccumulator));
  State.Field(FInverter, SizeOf(FInverter));
  State.Field(FStaging, SizeOf(FStaging));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FChr, SizeOf(FChr));
  State.Field(FIncrease, SizeOf(FIncrease));
  State.Field(FInvert, SizeOf(FInvert));
  State.Field(FY, SizeOf(FY));
  State.Field(FChrEnabled, SizeOf(FChrEnabled));
  State.Field(FNameRam, SizeOf(FNameRam));
  State.Field(FNames, SizeOf(FNames));
end;

function TMapperSachen.Convert(Value: Byte): Byte;
begin
  Result := Value;
  if FBoard = MAPPER_TXC_22000 then
    Result := (Value shr 4) and 3;
  if FBoard = MAPPER_SACHEN_136 then
    Result := Value and $3F;
  if FBoard = MAPPER_SACHEN_147 then
    Result := (Value shr 2) or ((Value and 3) shl 6);
  if FBoard = MAPPER_TXC_22211B then
  begin
    Result := 0;
    for var i := 0 to 5 do
      Result := Result or (((Value shr i) and 1) shl (5 - i))
  end;
end;

function TMapperSachen.ChipRead: Byte;
begin
  var Mask := 7;
  if FBoard in [MAPPER_SACHEN_136, MAPPER_SACHEN_147, MAPPER_TXC_22211B] then
    Mask := 15;
  var Inv := 0;
  if FInvert then
    Inv := $FF;
  Result := (FAccumulator and Mask) or ((FInverter xor Inv) and (not Mask));
  FY := not FInvert or ((Result and $10) <> 0);
end;

procedure TMapperSachen.ChipWrite(Address: Word; Value: Byte);
begin
  var Mask := 7;
  if FBoard in [MAPPER_SACHEN_136, MAPPER_SACHEN_147, MAPPER_TXC_22211B] then
    Mask := 15;
  if Address < $8000 then
    case Address and $E103 of
      $4100:
        if FIncrease then
          FAccumulator := (Integer(FAccumulator) + 1) and $FF
        else
        begin
          var Inv := 0;
          if FInvert then
            Inv := $FF;
          FAccumulator := ((FAccumulator and (not Mask)) or (FStaging and Mask)) xor Inv
        end;
      $4101:
        FInvert := (Value and 1) <> 0;
      $4102:
        begin
          FStaging := Value and Mask;
          FInverter := Value and (not Mask)
        end;
      $4103:
        FIncrease := (Value and 1) <> 0;
    end
  else if FBoard in [
      MAPPER_SACHEN_136,
      MAPPER_SACHEN_147,
      MAPPER_TXC_22211B] then
    FOutput := (FAccumulator and 15) or (FInverter and $F0)
  else
    FOutput := (FAccumulator and 15) or ((FInverter and 8) shl 1);
  FY := not FInvert or ((Value and $10) <> 0);
end;

procedure TMapperSachen.UpdateBanks;
begin
  case FBoard of
    MAPPER_TXC_22000:
      begin
        Prg32(FOutput and 3);
        Chr8(FChr)
      end;
    MAPPER_TXC_22211A:
      begin
        Prg32((FOutput shr 2) and 1);
        Chr8(FOutput and 3)
      end;
    MAPPER_SACHEN_136, MAPPER_TXC_22211B:
      begin
        Chr8(FOutput);
        if FBoard = MAPPER_TXC_22211B then
          Mirror(Ord(not FInvert))
      end;
    MAPPER_SACHEN_147:
      begin
        Prg32(((FOutput and $20) shr 4) or (FOutput and 1));
        Chr8((FOutput and $1E) shr 1)
      end;
    MAPPER_TXC_22211C:
      if Length(FChrMemory) > $2000 then
        Chr8((FOutput and 1) or (Ord(FY) shl 1) or ((FOutput and 2) shl 1))
      else
        FChrEnabled := FY;
    MAPPER_SACHEN_8259D,        //
    MAPPER_SACHEN_8259B,        //
    MAPPER_SACHEN_8259C,        //
    MAPPER_SACHEN_8259A,        //
    MAPPER_SACHEN_74LS374N_150, //
    MAPPER_SACHEN_74LS374N_243:
      begin
        var Mode := (FRegs[7] shr 1) and 3;
        if (FBoard in [
            MAPPER_SACHEN_8259D,
            MAPPER_SACHEN_8259B,
            MAPPER_SACHEN_8259C,
            MAPPER_SACHEN_8259A]) and ((FRegs[7] and 1) <> 0) then
          Mode := 0;
        case Mode of
          0:
            if FBoard in [MAPPER_SACHEN_74LS374N_150, MAPPER_SACHEN_74LS374N_243] then
            begin
              FNames[0] := 0;
              FNames[1] := 0;
              FNames[2] := 0;
              FNames[3] := 1
            end
            else if FBoard = MAPPER_SACHEN_8259D then
            begin
              FNames[0] := 0;
              FNames[1] := 0;
              FNames[2] := 1;
              FNames[3] := 1;
              Mirror(1)
            end
            else
            begin
              FNames[0] := 0;
              FNames[1] := 1;
              FNames[2] := 0;
              FNames[3] := 1;
              Mirror(0)
            end;
          1:
            if FBoard = MAPPER_SACHEN_8259D then
            begin
              FNames[0] := 0;
              FNames[1] := 1;
              FNames[2] := 0;
              FNames[3] := 1;
              Mirror(0)
            end
            else
            begin
              FNames[0] := 0;
              FNames[1] := 0;
              FNames[2] := 1;
              FNames[3] := 1;
              Mirror(1)
            end;
          2:
            if FBoard in [MAPPER_SACHEN_74LS374N_150, MAPPER_SACHEN_74LS374N_243] then
            begin
              FNames[0] := 0;
              FNames[1] := 1;
              FNames[2] := 0;
              FNames[3] := 1;
              Mirror(0)
            end
            else
            begin
              FNames[0] := 0;
              FNames[1] := 1;
              FNames[2] := 1;
              FNames[3] := 1
            end;
          3:
            begin
              FillChar(FNames, SizeOf(FNames), 0);
              Mirror(2)
            end;
        end;
        Prg32(FRegs[5]);
        if FBoard = MAPPER_SACHEN_74LS374N_150 then
        begin
          Prg32(FRegs[5] and 3);
          Chr8(((FRegs[4] and 1) shl 2) or (FRegs[6] and 3))
        end
        else if FBoard = MAPPER_SACHEN_74LS374N_243 then
        begin
          Prg32(FRegs[5] and 3);
          Chr8((FRegs[2] and 1) or ((FRegs[4] and 1) shl 1) or ((FRegs[6] and 3) shl 2))
        end
        else if FBoard = MAPPER_SACHEN_8259D then
        begin
          Chr1(0, FRegs[0]);
          for var i := 1 to 3 do
          begin
            var Reg := i;
            if (FRegs[7] and 1) <> 0 then
              Reg := 0;
            var Bank := FRegs[Reg] or (((FRegs[4] shr (i - 1)) and 1) shl 4);
            if i = 3 then
              Bank := Bank or ((FRegs[6] and 1) shl 3);
            Chr1(i, Bank);
          end;
          Chr4(1, (Length(FChrMemory) div $1000) - 1);
        end
        else if not FHasChrRam then
        begin
          var Shift := 0;
          if FBoard = MAPPER_SACHEN_8259A then
            Shift := 1;
          if FBoard = MAPPER_SACHEN_8259C then
            Shift := 2;
          for var i := 0 to 3 do
          begin
            var Reg := i;
            if (FRegs[7] and 1) <> 0 then
              Reg := 0;
            var Bank := ((Integer(FRegs[4]) shl 3) or FRegs[Reg]) shl Shift;
            if FBoard = MAPPER_SACHEN_8259A then
              Bank := Bank or (i and 1);
            if FBoard = MAPPER_SACHEN_8259C then
              Bank := Bank or i;
            Chr2(i, Bank);
          end;
        end;
      end;
  end;
end;

function TMapperSachen.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FBoard in [
      MAPPER_SACHEN_8259D,
      MAPPER_SACHEN_8259B,
      MAPPER_SACHEN_8259C,
      MAPPER_SACHEN_8259A] then
    Exit(inherited CpuRead(Address, Value));

  if FBoard in [MAPPER_SACHEN_74LS374N_150, MAPPER_SACHEN_74LS374N_243] then
  begin
    if (Address >= $4100) and (Address < $8000) then
    begin
      Value := FCpuOpenBus;
      if (Address and $C101) = $4101 then
        Value := (FCpuOpenBus and $F8) or (FRegs[FSelect] and 7);
      Exit(True);
    end;
    Exit(inherited CpuRead(Address, Value));
  end;

  if (Address >= $4020) and (Address < $6000) then
  begin
    Value := FCpuOpenBus;
    if (FBoard in [MAPPER_TXC_22211A, MAPPER_TXC_22211C]) and ((Address and $100) <> 0) then
      Value := (FCpuOpenBus and $F0) or (ChipRead and 15)
    else if (Address and $103) = $100 then
      case FBoard of
        MAPPER_TXC_22000:
          Value := (FCpuOpenBus and $CF) or ((ChipRead shl 4) and $30);
        MAPPER_SACHEN_136:
          Value := (FCpuOpenBus and $C0) or (ChipRead and $3F);
        MAPPER_SACHEN_147:
          begin
            var V := ChipRead;
            Value := ((V shl 2) or (V shr 6)) and $FF
          end;
        MAPPER_TXC_22211B:
          Value := (FCpuOpenBus and $C0) or Convert(ChipRead);
      end;
    UpdateBanks;
    Exit(True);
  end;

  Result := inherited CpuRead(Address, Value);
end;

function TMapperSachen.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if FBoard in [
      MAPPER_SACHEN_8259D,
      MAPPER_SACHEN_8259B,
      MAPPER_SACHEN_8259C,
      MAPPER_SACHEN_8259A,
      MAPPER_SACHEN_74LS374N_150,
      MAPPER_SACHEN_74LS374N_243] then
  begin
    Result := (Address >= $4100) and (Address < $8000);
    if Result then
      case Address and $C101 of
        $4100:
          FSelect := Value and 7;
        $4101:
          begin
            FRegs[FSelect] := Value and 7;
            UpdateBanks
          end;
      end;
    Exit;
  end;

  Result := ((Address >= $4020) and (Address < $6000)) or (Address >= $8000);
  if not Result then
    Exit;

  if (FBoard = MAPPER_TXC_22000) and ((Address and $F200) = $4200) then
    FChr := Value;
  var Converted := Convert(Value);
  if FBoard in [MAPPER_TXC_22211A, MAPPER_TXC_22211C] then
    Converted := Value and 15;
  ChipWrite(Address, Converted);
  if not (FBoard in [MAPPER_SACHEN_147, MAPPER_TXC_22211B]) or (Address >= $8000) then
    UpdateBanks;
end;

function TMapperSachen.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard in [
      MAPPER_SACHEN_8259D,
      MAPPER_SACHEN_8259B,
      MAPPER_SACHEN_8259C,
      MAPPER_SACHEN_8259A,
      MAPPER_SACHEN_74LS374N_150,
      MAPPER_SACHEN_74LS374N_243]) and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[FNames[(Address shr 10) and 3] * $400 + (Address and $3FF)];
    Exit(True)
  end;

  if not FChrEnabled then
    Exit(False);

  Result := inherited PpuRead(Address, Value);
end;

function TMapperSachen.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard in [
      MAPPER_SACHEN_8259D,
      MAPPER_SACHEN_8259B,
      MAPPER_SACHEN_8259C,
      MAPPER_SACHEN_8259A,
      MAPPER_SACHEN_74LS374N_150,
      MAPPER_SACHEN_74LS374N_243]) and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[FNames[(Address shr 10) and 3] * $400 + (Address and $3FF)] := Value;
    Exit(True)
  end;

  if not FChrEnabled then
    Exit(False);

  Result := inherited PpuWrite(Address, Value);
end;

end.

