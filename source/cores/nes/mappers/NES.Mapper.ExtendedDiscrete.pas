unit NES.Mapper.ExtendedDiscrete;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperExtendedDiscrete = class(TMapperBanked)
  private
    FBoard, FSubmapper: Integer;
    FRegs: array[0..31] of Integer;
    FResetBank: Integer;
    FStarted: Boolean;
    FExtraRam: array[0..$1FFF] of Byte;
    FNameRam: array[0..$7FF] of Byte;
    procedure UpdateNamco;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer = 0);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
  end;

implementation

constructor TMapperExtendedDiscrete.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  if Board = MAPPER_OEKA_KIDS then
  begin
    SetLength(FChrMemory, $8000);
    FHasChrRam := True
  end;
  if Board = MAPPER_EDU2000 then
    SetLength(FPrgRam, $8000);
  if Board = MAPPER_WAIXING178 then
    SetLength(FPrgRam, $8000);
  Reset;
end;

procedure TMapperExtendedDiscrete.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FResetBank, SizeOf(FResetBank));
  State.Field(FStarted, SizeOf(FStarted));
  State.Field(FExtraRam, SizeOf(FExtraRam));
  State.Field(FNameRam, SizeOf(FNameRam));
end;

procedure TMapperExtendedDiscrete.Reset;
begin
  inherited;
  // Mapper 171 retains its CHR registers on a console reset.
  if (FBoard <> MAPPER_KAISER7058) or not FStarted then
    FillChar(FRegs, SizeOf(FRegs), 0);
  FRamEnabled := FBoard = MAPPER_SEALIE_COMPUTING;
  if FBoard = MAPPER_EDU2000 then
    FRamEnabled := True;
  if (FBoard = MAPPER_WAIXING178) or (FBoard = MAPPER_DISCRETE_246) then
    FRamEnabled := True;
  if FStarted and (FBoard = MAPPER_DISCRETE_233) then
    FResetBank := FResetBank xor 1;
  FStarted := True;
  case FBoard of
    MAPPER_SEALIE_COMPUTING:
      begin
        Prg16(1, 7);
        SetLength(FChrMemory, $8000);
        FHasChrRam := True
      end;
    MAPPER_JALECO_JF17, MAPPER_SUNSOFT_89:
      ;
    MAPPER_NAMCO_108_76, MAPPER_NAMCO_108_95:
      begin
        Prg8(0, 0);
        Prg8(1, 0);
        Prg8(2, -2);
        Prg8(3, -1);
        UpdateNamco
      end;
    MAPPER_IREM_LROG017:
      begin
        Prg32(0);
        FMirror := TMirrorMode.FourScreen
      end;
    MAPPER_KAISER7058:
      begin
        Prg32(0);
        Chr4(0, FRegs[0]);
        Chr4(1, FRegs[1])
      end;
    MAPPER_OEKA_KIDS:
      begin
        Prg32(0);
        Chr4(0, 0);
        Chr4(1, 3);
        FMirror := TMirrorMode.Single0
      end;
    MAPPER_JALECO_JF19:
      Prg16(1, 0);
    MAPPER_IREM_TAM_S1:
      begin
        Prg16(0, -1);
        Prg16(1, 0)
      end;
    MAPPER_GOLDEN_FIVE:
      Prg16(1, 15);
    MAPPER_DISCRETE_120:
      Prg32(2);
    MAPPER_LH32:
      Prg32(-1);
    MAPPER_CNROM_PROTECT:
      begin
        FRegs[0] := 1;
        Prg32(0)
      end;
    MAPPER_DAOU_INFOSYS:
      Mirror(2);
    MAPPER_SUBOR166:
      begin
        Prg16(0, 0);
        Prg16(1, 7);
        FHasChrRam := True
      end;
    MAPPER_WAIXING178:
      begin
        Prg32(0);
        Mirror(0)
      end;
    MAPPER_DISCRETE_246:
      Prg8(3, $FF);
    MAPPER_SACHEN_143:
      Prg32(0);
    MAPPER_NTDEC_TC112:
      begin
        Prg8(0, 0);
        Prg8(1, -3);
        Prg8(2, -2);
        Prg8(3, -1)
      end;
    MAPPER_DISCRETE_203, MAPPER_DISCRETE_214, MAPPER_DISCRETE_231:
      begin
        Prg16(0, 0);
        Prg16(1, 0)
      end;
    MAPPER_DISCRETE_225, MAPPER_DISCRETE_226:
      Prg32(0);
    MAPPER_DISCRETE_227, MAPPER_DISCRETE_229:
      CpuWrite($8000, 0);
    MAPPER_DISCRETE_233:
      begin
        Prg16(0, FResetBank shl 5);
        Prg16(1, (FResetBank shl 5) or 1)
      end;
    MAPPER_GS2004:
      Prg32(7);
    MAPPER_A65_AS, MAPPER_BMC11160, MAPPER_BMC190IN1, MAPPER_BMC8157:
      CpuWrite($8000, 0);
    MAPPER_KAISER7016:
      begin
        Prg32(3);
        FRegs[0] := 8
      end;
    MAPPER_LH51:
      begin
        Prg8(0, 0);
        Prg8(1, 13);
        Prg8(2, 14);
        Prg8(3, 15)
      end;
    MAPPER_KAISER7013_B:
      Mirror(0);
    MAPPER_HP898F:
      begin
        Prg16(0, 0);
        Prg16(1, 0);
        Mirror(1)
      end;
    MAPPER_RT01:
      begin
        Prg16(0, 0);
        Prg16(1, 0);
        for var i := 0 to 3 do
          Chr2(i, 0)
      end;
    MAPPER_BMC_K3046:
      Prg16(1, 7);
    MAPPER_KAISER7012:
      Prg32(1);
    MAPPER_DREAM_TECH01:
      Prg16(1, 8);
  else
    Prg32(0);
  end;
end;

function TMapperExtendedDiscrete.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_LH32) and (Address >= $C000) and (Address < $E000) then
  begin
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;

  if (FBoard = MAPPER_LH32) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[(FRegs[0] * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if ((FBoard = MAPPER_GS2004) or (FBoard = MAPPER_KAISER7016)) and (Address >= $6000) and (Address < $8000) then
  begin
    var Bank := FRegs[0];
    if FBoard = MAPPER_GS2004 then
      Bank := $20;
    Value := FPrgRom[(Bank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if ((FBoard = MAPPER_EDU2000) or (FBoard = MAPPER_WAIXING178)) and (Address >= $6000) and (Address < $8000) then
  begin
    var Bank := (FRegs[0] shr 6) and 3;
    if FBoard = MAPPER_WAIXING178 then
      Bank := FRegs[3] and 3;
    Value := FPrgRam[Bank * $2000 + (Address and $1FFF)];
    Exit(True);
  end;

  if (FBoard = MAPPER_RT01) and (((Address >= $CE80) and (Address < $CF00)) or ((Address >= $FE80) and (Address < $FF00))) then
  begin
    Value := $FF;
    Exit(True)
  end;

  if (FBoard = MAPPER_DISCRETE_120) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[(FRegs[0] * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if (FBoard = MAPPER_SACHEN_143) and (Address >= $4100) and (Address <= $5FFF) then
  begin
    Value := ((not Address) and $3F) or $40;
    Exit(True);
  end;

  if (FBoard = MAPPER_DISCRETE_170) and ((Address = $7001) or (Address = $7777)) then
  begin
    Value := FRegs[0] or ((Address shr 8) and $7F);
    Exit(True);
  end;

  if (FBoard = MAPPER_DISCRETE_216) and (Address = $5000) then
  begin
    Value := 0;
    Exit(True);
  end;

  Result := inherited CpuRead(Address, Value);
end;

function TMapperExtendedDiscrete.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
const
  PrgPerm: array[0..3, 0..3] of Byte = ((0, 1, 2, 3), (3, 2, 1, 0), (0, 2, 1, 3), (3, 1, 2, 0));
  ChrPerm: array[0..7, 0..7] of Byte = (
    (0, 1, 2, 3, 4, 5, 6, 7),
    (0, 2, 1, 3, 4, 6, 5, 7),
    (0, 1, 4, 5, 2, 3, 6, 7),
    (0, 4, 1, 5, 2, 6, 3, 7),
    (0, 4, 2, 6, 1, 5, 3, 7),
    (0, 2, 4, 6, 1, 3, 5, 7),
    (7, 6, 5, 4, 3, 2, 1, 0),
    (7, 6, 5, 4, 3, 2, 1, 0));
var
  Bank, High: Integer;
  Bus: Byte;
begin
  Result := True;

  // Low-address register decoders are handled before the common ROM decoder.
  case FBoard of
    MAPPER_WAIXING178:
      begin
        if (Address >= $6000) and (Address < $8000) then
        begin
          FPrgRam[(FRegs[3] and 3) * $2000 + (Address and $1FFF)] := Value;
          Exit
        end;

        if (Address >= $4800) and (Address <= $4FFF) then
        begin
          FRegs[Address and 3] := Value;
          Bank := (FRegs[2] shl 3) or (FRegs[1] and 7);
          if (FRegs[0] and 2) <> 0 then
          begin
            Prg16(0, Bank);
            if (FRegs[0] and 4) <> 0 then
              Prg16(1, (FRegs[2] shl 3) or 6 or (FRegs[1] and 1))
            else
              Prg16(1, (FRegs[2] shl 3) or 7)
          end
          else if (FRegs[0] and 4) <> 0 then
          begin
            Prg16(0, Bank);
            Prg16(1, Bank)
          end
          else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank + 1)
          end;
          Mirror(FRegs[0] and 1);
          Exit;
        end;
      end;
    MAPPER_DISCRETE_246:
      if (Address >= $6000) and (Address <= $67FF) then
      begin
        if (Address and 7) < 4 then
          Prg8(Address and 3, Value)
        else
          Chr2(Address and 3, Value);
        Exit
      end;
    MAPPER_LH32:
      if Address = $6000 then
      begin
        FRegs[0] := Value;
        Exit
      end
      else if (Address >= $C000) and (Address < $E000) then
      begin
        FPrgRam[Address and $1FFF] := Value;
        Exit
      end;
    MAPPER_KAISER7013_B:
      if (Address >= $6000) and (Address < $8000) then
      begin
        Prg16(0, Value);
        Exit
      end;
    MAPPER_EDU2000:
      if (Address >= $6000) and (Address < $8000) then
      begin
        FPrgRam[((FRegs[0] shr 6) and 3) * $2000 + (Address and $1FFF)] := Value;
        Exit
      end;
    MAPPER_HP898F:
      if (Address and $6000) = $6000 then
      begin
        FRegs[(Address shr 2) and 1] := Value;
        Bank := (FRegs[1] shr 3) and 7;
        High := (FRegs[1] shr 4) and 4;
        Prg16(0, Bank and (not High));
        Prg16(1, Bank or High);
        Chr8(((FRegs[0] shr 4) and 7) and (not (((FRegs[0] and 1) shl 2) or (FRegs[0] and 2))));
        Mirror(1 - ((FRegs[1] shr 7) and 1));
        Exit;
      end;
    MAPPER_UNL_PCI556:
      if (Address >= $7000) and (Address < $8000) then
      begin
        Prg32(Value and 3);
        Chr8((Value shr 2) and 3);
        Exit
      end;
    MAPPER_COLOR_DREAMS_46:
      if Address >= $6000 then
      begin
        if Address < $8000 then
          FRegs[0] := Value
        else
          FRegs[1] := Value;
        Prg32(((FRegs[0] and 15) shl 1) or (FRegs[1] and 1));
        Chr8(((FRegs[0] and $F0) shr 1) or ((FRegs[1] shr 4) and 7));
        Exit;
      end;
    MAPPER_JALECO_JF13:
      if (Address >= $6000) and (Address < $8000) then
      begin
        if Address < $7000 then
        begin
          Prg32((Value shr 4) and 3);
          Chr8((Value and 3) or ((Value shr 4) and 4))
        end;
        Exit;
      end;
    MAPPER_DISCRETE_120:
      if Address = $41FF then
      begin
        FRegs[0] := Value;
        Exit
      end;
    MAPPER_DISCRETE_170:
      if (Address = $6502) or (Address = $7000) then
      begin
        FRegs[0] := (Integer(Value) shl 1) and $80;
        Exit
      end;
    MAPPER_HENGGEDIANZI179:
      if (Address >= $5000) and (Address < $6000) then
      begin
        Prg32(Value shr 1);
        Exit
      end;
    MAPPER_NTDEC_TC112:
      if (Address >= $6000) and (Address < $8000) then
      begin
        case Address and 3 of
          0:
            begin
              Chr2(0, Value shr 1);
              Chr2(1, (Value shr 1) + 1)
            end;
          1:
            Chr2(2, Value shr 1);
          2:
            Chr2(3, Value shr 1);
          3:
            Prg8(0, Value);
        end;
        Exit;
      end;
    MAPPER_DISCRETE_216:
      if Address = $5000 then
      begin
        Prg32(0);
        Chr8(0);
        Exit
      end;
    MAPPER_DREAM_TECH01:
      if Address = $5020 then
      begin
        Prg16(0, Value and 7);
        Exit
      end;
  end;

  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));

  case FBoard of
    MAPPER_SEALIE_COMPUTING:
      begin
        Prg16(0, (Value shr 2) and 7);
        Chr8(Value and 3)
      end;
    MAPPER_DISCRETE_39, MAPPER_DISCRETE_241:
      Prg32(Value);
    MAPPER_NOVEL_DIAMOND_54, MAPPER_NOVEL_DIAMOND_201:
      begin
        Prg32(Address and 3);
        Chr8(Address and 7)
      end;
    MAPPER_JALECO_JF17, MAPPER_JALECO_JF19:
      begin
        // JF-17/19 clock bank latches on rising data-bit edges, after bus conflicts.
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        if ((FRegs[0] and $80) = 0) and ((Value and $80) <> 0) then
          if FBoard = MAPPER_JALECO_JF17 then
            Prg16(0, Value and 7)
          else
            Prg16(1, Value and 15);
        if ((FRegs[0] and $40) = 0) and ((Value and $40) <> 0) then
          Chr8(Value and 15);
        FRegs[0] := Value;
      end;
    MAPPER_NAMCO_108_76, MAPPER_NAMCO_108_95:
      begin
        if (Address and 1) = 0 then
          FRegs[8] := Value and 7
        else
          FRegs[FRegs[8]] := Value;
        UpdateNamco;
      end;
    MAPPER_IREM_LROG017:
      begin
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        Prg32(Value and 15);
        Chr2(0, Value shr 4)
      end;
    MAPPER_OEKA_KIDS:
      begin
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        Prg32(Value and 3);
        FRegs[0] := Value and 4;
        Chr4(0, FRegs[0] or FRegs[1]);
        Chr4(1, FRegs[0] or 3);
      end;
    MAPPER_SUNSOFT_89:
      begin
        Prg16(0, (Value shr 4) and 7);
        Chr8((Value and 7) or ((Value shr 4) and 8));
        Mirror(2 + ((Value shr 3) and 1))
      end;
    MAPPER_IREM_TAM_S1:
      begin
        Prg16(1, Value and 15);
        Mirror(1 - ((Value shr 7) and 1))
      end;
    MAPPER_GOLDEN_FIVE:
      begin
        if Address >= $C000 then
        begin
          FRegs[0] := (FRegs[0] and $F0) or (Value and 15);
          Prg16(0, FRegs[0])
        end
        else if (Address < $A000) and ((Value and 8) <> 0) then
        begin
          FRegs[0] := (FRegs[0] and 15) or ((Integer(Value) shl 4) and $70);
          Prg16(0, FRegs[0]);
          Prg16(1, ((Integer(Value) shl 4) and $70) or 15)
        end;
      end;
    MAPPER_DISCRETE_107:
      begin
        Prg32(Value shr 1);
        Chr8(Value)
      end;
    MAPPER_SACHEN_149:
      Chr8(Value shr 7);
    MAPPER_DAOU_INFOSYS:
      if (Address >= $C000) and (Address <= $C014) then
      begin
        if Address <= $C00F then
        begin
          Bank := (Address and 3) + Ord(Address >= $C008) * 4;
          if (Address and 4) <> 0 then
            FRegs[Bank + 8] := Value
          else
            FRegs[Bank] := Value;
          for var i := 0 to 7 do
            Chr1(i, (FRegs[i + 8] shl 8) or FRegs[i]);
        end
        else if Address = $C010 then
          Prg16(0, Value)
        else if Address = $C014 then
          Mirror(Value and 1);
      end;
    MAPPER_SUBOR166:
      begin
        FRegs[(Address shr 13) and 3] := Value;
        High := ((FRegs[0] xor FRegs[1]) and $10) shl 1;
        Bank := (FRegs[2] xor FRegs[3]) and 31;
        if (FRegs[1] and 8) <> 0 then
          Prg32((High or Bank) shr 1)
        else if (FRegs[1] and 4) <> 0 then
        begin
          Prg16(0, 31);
          Prg16(1, High or Bank)
        end
        else
        begin
          Prg16(0, High or Bank);
          Prg16(1, 7)
        end;
      end;
    MAPPER_KAISER7058:
      begin
        // CPU A0 selects the independent 4 KiB CHR window throughout $8000-$FFFF.
        FRegs[Address and 1] := Value;
        Chr4(Address and 1, Value)
      end;
    MAPPER_HENGGEDIANZI177:
      begin
        Prg32(Value);
        Mirror((Value shr 5) and 1)
      end;
    MAPPER_CNROM_PROTECT:
      begin
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        if FSubmapper = 0 then
          FRegs[0] := Ord(((Value and 15) <> 0) and (Value <> $13))
        else
          FRegs[0] := Ord((Value and 3) = (FSubmapper - 4));
      end;
    MAPPER_HENGGEDIANZI179:
      Mirror(Value and 1);
    MAPPER_DISCRETE_203:
      begin
        Prg16(0, Value shr 2);
        Prg16(1, Value shr 2);
        Chr8(Value and 3)
      end;
    MAPPER_DISCRETE_214:
      begin
        Prg16(0, (Address shr 2) and 3);
        Prg16(1, (Address shr 2) and 3);
        Chr8(Address and 3)
      end;
    MAPPER_DISCRETE_216:
      begin
        Prg32(Address and 1);
        Chr8((Address shr 1) and 7)
      end;
    MAPPER_DISCRETE_225:
      begin
        High := (Address shr 8) and $40;
        Bank := ((Address shr 6) and $3F) or High;
        if (Address and $1000) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Chr8((Address and $3F) or High);
        Mirror((Address shr 13) and 1);
      end;
    MAPPER_DISCRETE_226, MAPPER_DISCRETE_233:
      begin
        FRegs[Address and 1] := Value;
        Bank := (FRegs[0] and $1F) or ((FRegs[1] and 1) shl 6);
        if FBoard = MAPPER_DISCRETE_233 then
          Bank := Bank or (FResetBank shl 5)
        else
          Bank := Bank or ((FRegs[0] and $80) shr 2);
        if (FRegs[0] and $20) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Mirror(1 - ((FRegs[0] shr 6) and 1));
      end;
    MAPPER_DISCRETE_227:
      begin
        Bank := ((Address shr 2) and $1F) or ((Address and $100) shr 3);
        if (Address and $80) <> 0 then
          if (Address and 1) <> 0 then
            Prg32(Bank shr 1)
          else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank)
          end
        else
        begin
          Prg16(0, Bank and ($3F - (Address and 1)));
          if (Address and $200) <> 0 then
            Prg16(1, Bank or 7)
          else
            Prg16(1, Bank and $38);
        end;
        Mirror((Address shr 1) and 1);
      end;
    MAPPER_DISCRETE_229:
      begin
        Chr8(Address and $FF);
        if (Address and $1E) = 0 then
          Prg32(0)
        else
        begin
          Prg16(0, Address and $1F);
          Prg16(1, Address and $1F)
        end;
        Mirror((Address shr 5) and 1);
      end;
    MAPPER_DISCRETE_231:
      begin
        Bank := ((Address shr 5) and 1) or (Address and $1E);
        Prg16(0, Bank and $1E);
        Prg16(1, Bank);
        Mirror((Address shr 7) and 1)
      end;
    MAPPER_DISCRETE_244:
      if (Value and 8) <> 0 then
        Chr8(ChrPerm[(Value shr 4) and 7, Value and 7])
      else
        Prg32(PrgPerm[(Value shr 4) and 3, Value and 3]);
    MAPPER_GS2004:
      Prg32(Value and 7);
    MAPPER_A65_AS:
      begin
        if (Value and $40) <> 0 then
          Prg32((Value and $1E) shr 1)
        else
        begin
          Prg16(0, ((Value and $30) shr 1) or (Value and 7));
          Prg16(1, ((Value and $30) shr 1) or 7)
        end;
        if (Value and $80) <> 0 then
          Mirror(2 + ((Value shr 5) and 1))
        else
          Mirror((Value shr 3) and 1);
      end;
    MAPPER_BMC11160:
      begin
        Bank := (Value shr 4) and 7;
        Prg32(Bank);
        Chr8((Bank shl 2) or (Value and 3));
        Mirror(1 - (Value shr 7))
      end;
    MAPPER_BMC190IN1:
      begin
        Bank := (Value shr 2) and 7;
        Prg16(0, Bank);
        Prg16(1, Bank);
        Chr8(Bank);
        Mirror(Value and 1)
      end;
    MAPPER_BMC8157:
      begin
        Bank := ((Address shr 5) and 3) * 8 + ((Address shr 8) and 1) * 64;
        High := ((Address shr 7) and 1) or ((Address shr 8) and 2);
        var Inner := (Address shr 2) and 7;
        Prg16(0, Bank or Inner);
        if High = 0 then
          Prg16(1, Bank)
        else if High = 1 then
          Prg16(1, Bank or Inner)
        else
          Prg16(1, Bank or 7);
        Mirror((Address shr 1) and 1);
      end;
    MAPPER_KAISER7016:
      case Address and $D943 of
        $D943:
          if (Address and $30) = $30 then
            FRegs[0] := 11
          else
            FRegs[0] := (Address shr 2) and 15;
        $D903:
          if (Address and $30) = $30 then
            FRegs[0] := 8 or ((Address shr 2) and 3)
          else
            FRegs[0] := 11;
      end;
    MAPPER_LH51:
      case Address and $E000 of
        $8000:
          Prg8(0, Value and 15);
        $E000:
          Mirror((Value shr 3) and 1)
      end;
    MAPPER_KAISER7013_B:
      Mirror(Value and 1);
    MAPPER_EDU2000:
      begin
        FRegs[0] := Value;
        Prg32(Value and 31)
      end;
    MAPPER_BMC_K3046:
      begin
        Prg16(0, Value and $3F);
        Prg16(1, (Value and $38) or 7)
      end;
    MAPPER_KAISER7012:
      case Address of
        $E0A0:
          Prg32(0);
        $EE36:
          Prg32(1)
      end;
  else
    Exit(False);
  end;
end;

procedure TMapperExtendedDiscrete.UpdateNamco;
begin
  Prg8(0, FRegs[6] and $3F);
  Prg8(1, FRegs[7] and $3F);
  if FBoard = MAPPER_NAMCO_108_76 then
    for var i := 0 to 3 do
      Chr2(i, FRegs[i + 2] and $3F)
  else
  begin
    Chr2(0, (FRegs[0] and $3F) shr 1);
    Chr2(1, (FRegs[1] and $3F) shr 1);
    for var i := 4 to 7 do
      Chr1(i, FRegs[i - 2] and $3F);
  end;
end;

function TMapperExtendedDiscrete.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_NAMCO_108_95) and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[((FRegs[(Address shr 11) and 1] shr 5) and 1) * $400 + (Address and $3FF)];
    Exit(True)
  end;

  if (FBoard = MAPPER_IREM_LROG017) and (Address >= $800) and (Address < $2000) then
  begin
    Value := FExtraRam[Address - $800];
    Exit(True)
  end;

  if (FBoard = MAPPER_CNROM_PROTECT) and (FRegs[0] = 0) and (Address < $2000) then
  begin
    Value := 1;
    Exit(True)
  end;

  Result := inherited PpuRead(Address, Value);
end;

function TMapperExtendedDiscrete.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_NAMCO_108_95) and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[((FRegs[(Address shr 11) and 1] shr 5) and 1) * $400 + (Address and $3FF)] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_IREM_LROG017) and (Address >= $800) and (Address < $2000) then
  begin
    FExtraRam[Address - $800] := Value;
    Exit(True)
  end;

  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperExtendedDiscrete.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if FBoard <> MAPPER_OEKA_KIDS then
    Exit;

  if ((FRegs[2] and $3000) <> $2000) and ((Address and $3000) = $2000) then
  begin
    FRegs[1] := (Address shr 8) and 3;
    Chr4(0, FRegs[0] or FRegs[1]);
    Chr4(1, FRegs[0] or 3)
  end;
  FRegs[2] := Address;
end;

end.

