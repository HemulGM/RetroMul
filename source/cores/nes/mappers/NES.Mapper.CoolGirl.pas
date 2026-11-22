unit NES.Mapper.CoolGirl;

interface

uses
  NES.Mapper, NES.State, NES.Types;

type
  TMapperCoolGirl = class(TMapper)
  private
    const
      FlashSize = $8000000;
      SaveFlashSize = $800000;
      SaveFlashBase = FlashSize - SaveFlashSize;
      FlashSectorSize = $20000;
      ChrSize = $80000;
      WorkRamSize = $8000;
      ResetCombination = $1D2;
  private
    type
      TCounter = packed record
        Value, Latch: Word;
        Control: Byte;
        Irq: Boolean;
      end;

      TRegisters = packed record
        PrgBase, ControllerBits: Word;
        Prg: array[0..3] of Byte;
        Chr: array[0..7] of Word;
        PrgMask, ChrMask, PrgMode, ChrMode, PrgAt6000, Mapper, Flags, RamPage, Control: Byte;
        Mirror, Mmc1Shift, Mmc3Select, Mmc3Latch, Mmc3Counter, A12LowClocks: Byte;
        ResetRead, FlashStep, FlashMode, MulA, MulB: Byte;
        RomAt6000, A12, Mmc3Enable, Mmc3Reload, Mmc3Armed, Mmc3Irq, Latch0, Latch1: Boolean;
        Vrc4, Vrc3, Irem65, Sunsoft7, Jaleco18, Sunsoft3, FdsConversion, Cony: TCounter;
        Vrc4Prescaler, Vrc4Phase, Select112, Select69, JyXor: Byte;
        Mmc5Enabled, Mmc5Irq, InFrame: Boolean;
        PpuAddress: Word;
        PpuIdle, PpuNametableReads, PpuScanline, Mmc5Line: Byte;
        Nanjing: array[0..4] of Byte;
        NanjingStrobe: Boolean;
        LastWriteCycle: UInt64;
        HasLastWrite: Boolean;
      end;
  private
    FImage, FChr, FWorkRam, FSaveFlash: TByteArray;
    FRegs: TRegisters;
    FPrgOffset: array[0..4] of Integer;
    FChrOffset: array[0..7] of Integer;
    FLogicalChr: array[0..7] of Word;
    procedure UpdatePrg;
    procedure UpdateChr;
    function MapPrg(Bank: Byte): Integer; inline;
    function MapChr(Page: Integer): Word;
    function ReadFlash(Offset: Integer; out Value: Byte): Boolean;
    procedure WriteFlash(Offset: Integer; Value: Byte);
    procedure WriteOuter(Index, Value: Byte);
    procedure WriteLow(Mode: Byte; Address: Word; Value: Byte);
    procedure WriteHigh(Address: Word; Value: Byte);
    procedure WriteMmc1(Address: Word; Value: Byte);
    procedure WriteMmc3(Address: Word; Value: Byte);
    procedure WriteVrc4(Address: Word; Value: Byte);
    procedure WriteJaleco(Address: Word; Value: Byte);
    procedure WriteIrem65(Address: Word; Value: Byte);
    procedure WriteSunsoft7(Address: Word; Value: Byte);
    procedure WriteCony(Address: Word; Value: Byte);
    procedure AcknowledgeMmc3;
    procedure ClockCpuIrqs;
    procedure HandlePatternLatch(Address: Word);
  public
    constructor Create(const Prg: TByteArray);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure ObserveController(Value: Byte);
    function ReadResetInstruction(out Value: Byte): Boolean;
    function CpuPeek(Address: Word; out Value: Byte): Boolean; override;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function CpuWriteTimed(Address: Word; Value: Byte; CpuCycle: UInt64): Boolean; override;
    function PpuPeek(Address: Word; Rendering: Boolean; out Value: Byte; Sprite: Boolean): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    function AllowsDirectPpuRead: Boolean; override;
    function NameTableOffset(Address: Word): Word; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: Word; PpuCycle: UInt64); override;
    procedure ClockPpuRead; override;
    function IrqPending: Boolean; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

implementation

uses
  System.Classes, System.SysUtils;

const
  Mmc3ChrRegister: array[0..5] of Byte = (0, 2, 4, 5, 6, 7);

procedure WriteBits(var Target: Byte; Mask, Bits: Byte); overload; inline;
begin
  Target := (Target and not Mask) or (Bits and Mask);
end;

procedure WriteBits(var Target: Word; Mask, Bits: Word); overload; inline;
begin
  Target := (Target and not Mask) or (Bits and Mask);
end;

constructor TMapperCoolGirl.Create(const Prg: NES.Types.TByteArray);
begin
  inherited Create;
  if (Length(Prg) < $4000) or (Length(Prg) > FlashSize) or (Length(Prg) mod $4000 <> 0) then
    raise ENesException.Create('Invalid COOLGIRL flash image size');
  FImage := Prg;
  SetLength(FChr, ChrSize);
  SetLength(FWorkRam, WorkRamSize);
  SetLength(FSaveFlash, SaveFlashSize);
  FillChar(FSaveFlash[0], SaveFlashSize, $FF);
  if Length(Prg) > SaveFlashBase then
    Move(Prg[SaveFlashBase], FSaveFlash[0], Length(Prg) - SaveFlashBase);
  Reset;
end;

procedure TMapperCoolGirl.PowerOn;
begin
  FillChar(FChr[0], Length(FChr), 0);
  FillChar(FWorkRam[0], Length(FWorkRam), 0);
  Reset;
end;

procedure TMapperCoolGirl.Reset;
begin
  FRegs := Default(TRegisters);
  FRegs.PrgMask := $78;
  FRegs.Prg[1] := 1;
  FRegs.Prg[2] := $FE;
  FRegs.Prg[3] := $FF;
  FRegs.Mmc1Shift := $20;
  for var Slot := 0 to High(FRegs.Chr) do
    FRegs.Chr[Slot] := Slot;
  UpdatePrg;
  UpdateChr;
end;

function TMapperCoolGirl.MapPrg(Bank: Byte): Integer;
begin
  Result := (Integer(FRegs.PrgBase) shl 14) or
    ((Integer(Bank) and ($FF xor (Integer(FRegs.PrgMask) shl 1))) shl 13);
end;

procedure TMapperCoolGirl.UpdatePrg;
const
  Bank16K: array[0..1, 0..1] of Byte = ((0, 2), (2, 0));
  Bank8K: array[0..1, 0..3] of Byte = ((0, 1, 2, 3), (2, 1, 0, 3));
begin
  for var Slot := 0 to 3 do
  begin
    var Bank: Byte;
    case FRegs.PrgMode of
      0..3:
        Bank := (FRegs.Prg[Bank16K[FRegs.PrgMode and 1, Slot shr 1]] and $FE) or (Slot and 1);
      4..5:
        Bank := FRegs.Prg[Bank8K[FRegs.PrgMode and 1, Slot]];
    else
      Bank := (FRegs.Prg[1 xor (FRegs.PrgMode and 1)] and $FC) or Slot;
    end;
    FPrgOffset[Slot] := MapPrg(Bank);
  end;
  FPrgOffset[4] := MapPrg(FRegs.PrgAt6000);
end;

function TMapperCoolGirl.MapChr(Page: Integer): Word;
begin
  case FRegs.ChrMode of
    1:
      if (FRegs.PpuScanline >= 129) then
        Result := 4 or (Page and 3)
      else
        Result := Page and 3;
    2, 3:
      if ((Page shr 2) xor (FRegs.ChrMode and 1)) = 0 then
        Result := (FRegs.Chr[Page and 2] and $1FE) or (Page and 1)
      else
        Result := FRegs.Chr[4 + (Page and 3)];
    4, 5:
      begin
        var Bank := Page and 4;
        if (FRegs.ChrMode = 5) and (((Bank = 0) and FRegs.Latch0) or
          ((Bank <> 0) and FRegs.Latch1)) then
          Inc(Bank);
        Result := (FRegs.Chr[Bank] and $1FC) or (Page and 3);
      end;
    6:
      Result := (FRegs.Chr[Page and 6] and $1FE) or (Page and 1);
    7:
      Result := FRegs.Chr[Page];
  else
    Result := (FRegs.Chr[0] and $1F8) or Page;
  end;
  if (FRegs.Mapper = 24) and ((FRegs.Flags and 2) <> 0) then
    Result := Result shr 1;
end;

procedure TMapperCoolGirl.UpdateChr;
begin
  for var Slot := 0 to 7 do
  begin
    var Bank := MapChr(Slot);
    FLogicalChr[Slot] := Bank;
    // A18 is inverted on the PCB. External nametables share the same RAM.
    FChrOffset[Slot] := (((Bank and ($1FF xor (Word(FRegs.ChrMask) shl 3))) xor $100) shl 10);
  end;
end;

function TMapperCoolGirl.ReadFlash(Offset: Integer; out Value: Byte): Boolean;
begin
  case FRegs.FlashMode of
    1:
      begin
        // Common Flash Interface on the x8 connection, where each word is mirrored.
        case (Offset and $FF) shr 1 of
          $10:
            Value := Ord('Q');
          $11:
            Value := Ord('R');
          $12:
            Value := Ord('Y');
          $13:
            Value := 2;
          $15:
            Value := $40;
          $27:
            Value := 27;
          $28, $2C:
            Value := 1;
          $2A:
            Value := 9;
          $2D:
            Value := $FF;
          $2E:
            Value := 3;
          $30:
            Value := 2;
        else
          Value := 0;
        end;
        Exit(True);
      end;
    2:
      begin
        case Offset and $FF of
          0, 1:
            Value := $01;
          2, 3:
            Value := $7E;
          $1C, $1D:
            Value := $28;
          $1E, $1F:
            Value := $01;
        else
          Value := 0;
        end;
        Exit(True);
      end;
  end;

  if Offset >= SaveFlashBase then
    Value := FSaveFlash[Offset - SaveFlashBase]
  else if Offset < Length(FImage) then
    Value := FImage[Offset]
  else
    Value := $FF;
  Result := True;
end;

procedure TMapperCoolGirl.WriteFlash(Offset: Integer; Value: Byte);
begin
  if FRegs.FlashStep = 3 then
  begin
    if Offset >= SaveFlashBase then
      FSaveFlash[Offset - SaveFlashBase] := FSaveFlash[Offset - SaveFlashBase] and Value;
    FRegs.FlashStep := 0;
    Exit;
  end;
  if Value = $F0 then
  begin
    FRegs.FlashMode := 0;
    FRegs.FlashStep := 0;
    Exit;
  end;

  var Key := Offset and $FFF;
  case FRegs.FlashStep of
    0:
      if Key = $AAA then
        case Value of
          $98:
            FRegs.FlashMode := 1;
          $AA:
            FRegs.FlashStep := 1;
        end;
    1:
      if (Key = $555) and (Value = $55) then
        FRegs.FlashStep := 2
      else
        FRegs.FlashStep := 0;
    2:
      begin
        FRegs.FlashStep := 0;
        if Key = $AAA then
          case Value of
            $80:
              FRegs.FlashStep := 4;
            $90:
              FRegs.FlashMode := 2;
            $A0:
              FRegs.FlashStep := 3;
          end;
      end;
    4:
      if (Key = $AAA) and (Value = $AA) then
        FRegs.FlashStep := 5
      else
        FRegs.FlashStep := 0;
    5:
      if (Key = $555) and (Value = $55) then
        FRegs.FlashStep := 6
      else
        FRegs.FlashStep := 0;
    6:
      begin
        if (Value = $30) and (Offset >= SaveFlashBase) then
          FillChar(FSaveFlash[(Offset - SaveFlashBase) and not (FlashSectorSize - 1)], FlashSectorSize, $FF);
        FRegs.FlashStep := 0;
      end;
  end;
end;

procedure TMapperCoolGirl.WriteOuter(Index, Value: Byte);
begin
  case Index of
    0:
      WriteBits(FRegs.PrgBase, $1F00, Word(Value) shl 8);
    1:
      WriteBits(FRegs.PrgBase, $00FF, Value);
    2:
      begin
        FRegs.PrgMask := Value and $7F;
        WriteBits(FRegs.ChrMask, $20, Value shr 2);
      end;
    3:
      begin
        FRegs.PrgMode := Value shr 5;
        WriteBits(FRegs.Chr[0], $F8, Word(Value) shl 3);
      end;
    4:
      begin
        FRegs.ChrMode := Value shr 5;
        WriteBits(FRegs.ChrMask, $1F, Value);
      end;
    5:
      begin
        WriteBits(FRegs.Chr[0], $100, Word(Value and $80) shl 1);
        WriteBits(FRegs.Prg[0], $3E, Value shr 1);
        FRegs.RamPage := Value and 3;
      end;
    6:
      begin
        WriteBits(FRegs.Mapper, $1F, Value);
        FRegs.Flags := Value shr 5;
      end;
    7:
      begin
        FRegs.Control := Value;
        WriteBits(FRegs.Mapper, $20, Value shr 1);
        FRegs.Mirror := (Value shr 3) and 3;
        case FRegs.Mapper of
          14:
            FRegs.Prg[1] := 1;
          17:
            FRegs.Prg[1] := $FD;
          23:
            FRegs.RomAt6000 := True;
        end;
      end;
  end;
end;

procedure TMapperCoolGirl.WriteMmc1(Address: Word; Value: Byte);
begin
  if (Value and $80) <> 0 then
  begin
    FRegs.Mmc1Shift := $20;
    FRegs.PrgMode := 0;
    WriteBits(FRegs.Prg[2], $1F, $1E);
    Exit;
  end;
  FRegs.Mmc1Shift := ((Value and 1) shl 5) or (FRegs.Mmc1Shift shr 1);
  if (FRegs.Mmc1Shift and 1) = 0 then
    Exit;
  Value := FRegs.Mmc1Shift shr 1;
  FRegs.Mmc1Shift := $20;
  case (Address shr 13) and 3 of
    0:
      begin
        case (Value shr 2) and 3 of
          0, 1:
            FRegs.PrgMode := 7;
          2:
            begin
              FRegs.PrgMode := 1;
              WriteBits(FRegs.Prg[2], $1E, 0);
            end;
          3:
            begin
              FRegs.PrgMode := 0;
              WriteBits(FRegs.Prg[2], $1E, $1E);
            end;
        end;
        FRegs.ChrMode := (Value and $10) shr 2;
        FRegs.Mirror := (Value and 3) xor 2;
      end;
    1:
      begin
        WriteBits(FRegs.Chr[0], $7C, Word(Value) shl 2);
        if (FRegs.Flags and 1) <> 0 then
          FRegs.RamPage := 3 xor ((Value shr 3) and 1);
        WriteBits(FRegs.Prg[0], $20, Value shl 1);
        WriteBits(FRegs.Prg[2], $20, Value shl 1);
      end;
    2:
      WriteBits(FRegs.Chr[4], $7C, Word(Value) shl 2);
    3:
      begin
        WriteBits(FRegs.Prg[0], $1E, Value shl 1);
        WriteBits(FRegs.Control, 1, Ord((Value and $10) = 0));
      end;
  end;
end;

procedure TMapperCoolGirl.AcknowledgeMmc3;
begin
  FRegs.Mmc3Enable := False;
  FRegs.Mmc3Armed := False;
  FRegs.Mmc3Irq := False;
end;

procedure TMapperCoolGirl.WriteMmc3(Address: Word; Value: Byte);
begin
  var Is189 := (FRegs.Flags and 2) <> 0;
  var Is206 := (FRegs.Flags and 4) <> 0;
  case Address and $E001 of
    $8000:
      begin
        FRegs.Mmc3Select := Value and 7;
        if not Is189 and not Is206 then
          FRegs.PrgMode := 4 or ((Value shr 6) and 1);
        if not Is206 then
          FRegs.ChrMode := 2 or (Value shr 7);
      end;
    $8001:
      if FRegs.Mmc3Select < 6 then
        WriteBits(FRegs.Chr[Mmc3ChrRegister[FRegs.Mmc3Select]], $FF, Value)
      else if not Is189 then
        FRegs.Prg[FRegs.Mmc3Select - 6] := Value;
    $A000:
      if not Is206 then
        FRegs.Mirror := Value and 1;
    $C000:
      FRegs.Mmc3Latch := Value;
    $C001:
      FRegs.Mmc3Reload := True;
    $E000:
      AcknowledgeMmc3;
    $E001:
      if not Is206 then
        FRegs.Mmc3Enable := True;
  end;
end;

procedure TMapperCoolGirl.WriteVrc4(Address: Word; Value: Byte);
const
  HighLine: array[0..3] of Word = ($84, $01, $2A, $05);
  LowLine: array[0..3] of Word = ($42, $02, $15, $0A);
begin
  var Wiring := (FRegs.Flags and 1) or ((FRegs.Flags and 4) shr 1);
  var Index := (Ord((Address and HighLine[Wiring]) <> 0) shl 1) or
    Ord((Address and LowLine[Wiring]) <> 0);
  case Address shr 12 of
    $8:
      WriteBits(FRegs.Prg[0], $1F, Value);
    $9:
      if Index >= 2 then
        WriteBits(FRegs.PrgMode, 1, (Value shr 1) and 1)
      else if Value <> $FF then
        FRegs.Mirror := Value and 3;
    $A:
      WriteBits(FRegs.Prg[1], $1F, Value);
    $B..$E:
      begin
        var Bank := ((Address shr 12) - $B) * 2 + (Index shr 1);
        var Shift := (Index and 1) * 4;
        WriteBits(FRegs.Chr[Bank], $F shl Shift, Word(Value and $F) shl Shift);
      end;
    $F:
      case Index of
        0, 1:
          WriteBits(FRegs.Vrc4.Latch, $F shl (Index * 4), Word(Value and $F) shl (Index * 4));
        2:
          begin
            FRegs.Vrc4.Irq := False;
            FRegs.Vrc4.Control := Value and 7;
            if (Value and 2) <> 0 then
            begin
              FRegs.Vrc4.Value := FRegs.Vrc4.Latch;
              FRegs.Vrc4Prescaler := 0;
              FRegs.Vrc4Phase := 0;
            end;
          end;
        3:
          begin
            FRegs.Vrc4.Irq := False;
            WriteBits(FRegs.Vrc4.Control, 2, (FRegs.Vrc4.Control and 1) shl 1);
          end;
      end;
  end;
end;

procedure TMapperCoolGirl.WriteJaleco(Address: Word; Value: Byte);
begin
  var Index := ((Address shr 10) and $1C) or (Address and 3);
  var Shift := (Index and 1) * 4;
  var Nibble := Value and $0F;
  case Index of
    0..5:
      WriteBits(FRegs.Prg[Index shr 1], $F shl Shift, Nibble shl Shift);
    8..23:
      WriteBits(FRegs.Chr[(Index - 8) shr 1], $F shl Shift, Word(Nibble) shl Shift);
    24..27:
      begin
        Shift := (Index - 24) * 4;
        WriteBits(FRegs.Jaleco18.Latch, $F shl Shift, Word(Nibble) shl Shift);
      end;
    28:
      begin
        FRegs.Jaleco18.Value := FRegs.Jaleco18.Latch;
        FRegs.Jaleco18.Irq := False;
      end;
    29:
      begin
        FRegs.Jaleco18.Control := Nibble;
        FRegs.Jaleco18.Irq := False;
      end;
    30:
      begin
        FRegs.Mirror := Value and 3;
        if FRegs.Mirror < 2 then
          FRegs.Mirror := FRegs.Mirror xor 1;
      end;
  end;
end;

procedure TMapperCoolGirl.WriteIrem65(Address: Word; Value: Byte);
begin
  case Address and $F007 of
    $8000:
      WriteBits(FRegs.Prg[0], $3F, Value);
    $9001:
      FRegs.Mirror := Value shr 7;
    $9003:
      begin
        FRegs.Irem65.Control := Value shr 7;
        FRegs.Irem65.Irq := False;
      end;
    $9004:
      begin
        FRegs.Irem65.Value := FRegs.Irem65.Latch;
        FRegs.Irem65.Irq := False;
      end;
    $9005:
      WriteBits(FRegs.Irem65.Latch, $FF00, Word(Value) shl 8);
    $9006:
      WriteBits(FRegs.Irem65.Latch, $00FF, Value);
    $A000:
      WriteBits(FRegs.Prg[1], $3F, Value);
    $B000..$B007:
      WriteBits(FRegs.Chr[Address and 7], $FF, Value);
    $C000:
      WriteBits(FRegs.Prg[2], $3F, Value);
  end;
end;

procedure TMapperCoolGirl.WriteSunsoft7(Address: Word; Value: Byte);
begin
  case Address and $E000 of
    $8000:
      FRegs.Select69 := Value and $F;
    $A000:
      case FRegs.Select69 of
        0..7:
          WriteBits(FRegs.Chr[FRegs.Select69], $FF, Value);
        8:
          begin
            FRegs.PrgAt6000 := Value and $3F;
            FRegs.RomAt6000 := (Value and $40) = 0;
            WriteBits(FRegs.Control, 1, Value shr 7);
          end;
        9..11:
          WriteBits(FRegs.Prg[FRegs.Select69 - 9], $3F, Value);
        12:
          FRegs.Mirror := Value and 3;
        13:
          begin
            FRegs.Sunsoft7.Irq := False;
            FRegs.Sunsoft7.Control := Value and $81;
          end;
        14:
          WriteBits(FRegs.Sunsoft7.Value, $00FF, Value);
        15:
          WriteBits(FRegs.Sunsoft7.Value, $FF00, Word(Value) shl 8);
      end;
  end;
end;

procedure TMapperCoolGirl.WriteCony(Address: Word; Value: Byte);
const
  Chr2KRegister: array[0..7] of Byte = (0, 2, 4, 4, 4, 4, 4, 6);
begin
  case (Address shr 8) and 3 of
    0:
      WriteBits(FRegs.Prg[0], $1E, (Value and $F) shl 1);
    1:
      begin
        FRegs.Mirror := Value and 3;
        WriteBits(FRegs.PrgMode, 4, Value shr 2);
        FRegs.RomAt6000 := (Value and $20) <> 0;
        WriteBits(FRegs.Cony.Control, $80, Value);
      end;
    2:
      if (Address and 1) = 0 then
      begin
        FRegs.Cony.Irq := False;
        WriteBits(FRegs.Cony.Value, $FF, Value);
      end
      else
      begin
        WriteBits(FRegs.Cony.Value, $FF00, Word(Value) shl 8);
        WriteBits(FRegs.Cony.Control, 1, FRegs.Cony.Control shr 7);
      end;
    3:
      if (Address and $10) = 0 then
      begin
        if (Address and 3) = 3 then
          FRegs.PrgAt6000 := Value
        else
          FRegs.Prg[Address and 3] := Value;
      end
      else if (FRegs.Flags and 4) <> 0 then
        WriteBits(FRegs.Chr[Chr2KRegister[Address and 7]], $1FE, Word(Value) shl 1)
      else
        WriteBits(FRegs.Chr[Address and 7], $FF, Value);
  end;
end;

procedure TMapperCoolGirl.WriteLow(Mode: Byte; Address: Word; Value: Byte);
begin
  case Mode of
    6:
      if Address = $5101 then
      begin
        if (FRegs.Nanjing[4] <> 0) and (Value = 0) then
          FRegs.NanjingStrobe := not FRegs.NanjingStrobe;
        FRegs.Nanjing[4] := Value;
      end
      else if (Address = $5100) and (Value = 6) then
      begin
        WriteBits(FRegs.PrgMode, 1, 0);
        FRegs.Prg[1] := 12;
      end
      else if (Address and $F000) = $5000 then
        case (Address shr 8) and 3 of
          0:
            begin
              WriteBits(FRegs.PrgMode, 1, 1);
              WriteBits(FRegs.Prg[0], $3C, (Value and $F) shl 2);
              WriteBits(FRegs.ChrMode, 1, Value shr 7);
              FRegs.Nanjing[1] := Value;
            end;
          1:
            FRegs.Nanjing[3] := Value;
          2:
            begin
              WriteBits(FRegs.PrgMode, 1, 1);
              WriteBits(FRegs.Prg[0], $C0, (Value and 3) shl 6);
              FRegs.Nanjing[0] := Value;
            end;
          3:
            FRegs.Nanjing[2] := Value;
        end;
    12:
      if Address >= $6000 then
        WriteBits(FRegs.Chr[0], $18, Word(((Value and 1) shl 1) or ((Value shr 1) and 1)) shl 3);
    13:
      case Address of
        $5800:
          FRegs.MulA := Value;
        $5801:
          FRegs.MulB := Value;
      end;
    15:
      case Address of
        $5105:
          if Value = $FF then
            WriteBits(FRegs.Control, $20, $20)
          else
          begin
            WriteBits(FRegs.Control, $20, 0);
            case Value and $14 of
              0:
                FRegs.Mirror := 2;
              4:
                FRegs.Mirror := 0;
              $10:
                FRegs.Mirror := 1;
              $14:
                FRegs.Mirror := 3;
            end;
          end;
        $5115:
          begin
            WriteBits(FRegs.Prg[0], $1F, Value and $1E);
            WriteBits(FRegs.Prg[1], $1F, (Value and $1E) or 1);
          end;
        $5116, $5117:
          WriteBits(FRegs.Prg[Address - $5114], $1F, Value);
        $5120..$5123:
          WriteBits(FRegs.Chr[Address and 3], $FF, Value);
        $5128..$512B:
          WriteBits(FRegs.Chr[4 + (Address and 3)], $FF, Value);
        $5203:
          begin
            FRegs.Mmc5Line := Value;
            FRegs.Mmc5Irq := False;
          end;
        $5204:
          begin
            FRegs.Mmc5Enabled := (Value and $80) <> 0;
            FRegs.Mmc5Irq := False;
          end;
      end;
    20:
      if (Address >= $4120) and ((FRegs.Flags and 2) <> 0) then
        WriteBits(FRegs.Prg[0], $3C, ((Value and $0F) or (Value shr 4)) shl 2);
    27, 28:
      if (Address and $E100) = $4100 then
      begin
        if Mode = 27 then
        begin
          WriteBits(FRegs.Chr[0], $38, Word(Value) shl 3);
          WriteBits(FRegs.Prg[0], 4, Value shr 1);
        end
        else
        begin
          WriteBits(FRegs.Chr[0], $18, Word(Value) shl 3);
          WriteBits(FRegs.Prg[0], 4, Value);
        end;
      end;
    31:
      if Address >= $6000 then
      begin
        WriteBits(FRegs.Chr[0], $1C, Word(Value) shl 2);
        WriteBits(FRegs.Chr[4], $1C, Word(4 or ((Value shr 4) and 3)) shl 2);
      end;
    32:
      if (Address and $F000) = $7000 then
      begin
        WriteBits(FRegs.Prg[0], $0C, (Value and 3) shl 2);
        WriteBits(FRegs.Chr[0], $18, Word(Value and $0C) shl 1);
      end;
  end;
end;

procedure TMapperCoolGirl.WriteHigh(Address: Word; Value: Byte);
begin
  case FRegs.Mapper of
    1:
      if ((FRegs.Flags and 1) <> 0) and ((Address and $F000) = $9000) then
        FRegs.Mirror := 2 or ((Value shr 4) and 1)
      else
      begin
        WriteBits(FRegs.Prg[0], $3E, (Value and $1F) shl 1);
        if (FRegs.Flags and 2) <> 0 then
        begin
          FRegs.Mirror := 2 or (Value shr 7);
          WriteBits(FRegs.Chr[0], $18, Word(Value and $60) shr 2);
        end;
      end;
    2:
      WriteBits(FRegs.Chr[0], $F8, Word(Value) shl 3);
    3:
      begin
        WriteBits(FRegs.Prg[0], $0E, (Value and 7) shl 1);
        WriteBits(FRegs.Chr[0], $78, Word(Value shr 4) shl 3);
        if (FRegs.Flags and 1) <> 0 then
          FRegs.Mirror := 2 or ((Value shr 3) and 1)
        else
          FRegs.Mirror := 1 xor ((Value shr 3) and 1);
      end;
    4:
      begin
        WriteBits(FRegs.Prg[0], $3E, (Value and $1F) shl 1);
        FRegs.Mirror := 1 xor (Value shr 7);
      end;
    5:
      begin
        WriteBits(FRegs.Prg[0], $0E, (Value shr 3) and $0E);
        WriteBits(FRegs.Control, 2, (Value and 1) shl 1);
      end;
    7:
      WriteJaleco(Address, Value);
    8:
      begin
        WriteBits(FRegs.Prg[0], $3C, (Value and $0F) shl 2);
        if (FRegs.Flags and 1) = 0 then
          FRegs.Mirror := 2 or ((Value shr 4) and 1);
      end;
    9:
      begin
        WriteBits(FRegs.Prg[0], $3C, (Address shr 5) and $3C);
        WriteBits(FRegs.Chr[0], $F8, Word((Address and 7) shl 2 or (Value and 3)) shl 3);
        FRegs.Mirror := (Address shr 13) and 1;
      end;
    10:
      begin
        WriteBits(FRegs.Prg[0], $0C, (Value and 3) shl 2);
        WriteBits(FRegs.Chr[0], $78, Word(Value shr 4) shl 3);
      end;
    11:
      begin
        WriteBits(FRegs.Prg[0], $0C, (Value shr 2) and $0C);
        WriteBits(FRegs.Chr[0], $18, Word(Value and 3) shl 3);
      end;
    13:
      case Address shr 12 of
        $8:
          WriteBits(FRegs.Prg[Address and 3], $3F, Value);
        $9:
          WriteBits(FRegs.Chr[Address and 7], $FF, Value);
        $C:
          case Address and 7 of
            0:
              if (Value and 1) <> 0 then
                FRegs.Mmc3Enable := True
              else
                AcknowledgeMmc3;
            2:
              AcknowledgeMmc3;
            3:
              FRegs.Mmc3Enable := True;
            5:
              begin
                FRegs.Mmc3Latch := Value xor FRegs.JyXor;
                FRegs.Mmc3Reload := True;
              end;
            6:
              FRegs.JyXor := Value;
          end;
        $D:
          if (Address and 3) = 1 then
            FRegs.Mirror := Value and 3;
      end;
    14:
      WriteIrem65(Address, Value);
    16:
      WriteMmc1(Address, Value);
    17:
      case Address shr 12 of
        $A:
          if (FRegs.Flags and 1) = 0 then
            WriteBits(FRegs.Prg[0], $0F, Value)
          else
            WriteBits(FRegs.Prg[0], $1E, (Value and $0F) shl 1);
        $B:
          WriteBits(FRegs.Chr[0], $7C, Word(Value) shl 2);
        $C:
          WriteBits(FRegs.Chr[1], $7C, Word(Value) shl 2);
        $D:
          WriteBits(FRegs.Chr[4], $7C, Word(Value) shl 2);
        $E:
          WriteBits(FRegs.Chr[5], $7C, Word(Value) shl 2);
        $F:
          FRegs.Mirror := Value and 1;
      end;
    18:
      begin
        WriteBits(FRegs.Chr[0], $78, Word(Value and $0F) shl 3);
        WriteBits(FRegs.Prg[0], $0E, (Value shr 3) and $0E);
        if (FRegs.Flags and 1) <> 0 then
          FRegs.Mirror := 2 or (Value shr 7)
        else
          WriteBits(FRegs.Prg[0], $10, (Value shr 3) and $10);
      end;
    19:
      case Address shr 12 of
        $8..$B:
          begin
            var Shift := ((Address shr 12) and 3) * 4;
            WriteBits(FRegs.Vrc3.Latch, $F shl Shift, Word(Value and $F) shl Shift);
          end;
        $C:
          begin
            FRegs.Vrc3.Irq := False;
            FRegs.Vrc3.Control := Value and 7;
            if (Value and 2) <> 0 then
              FRegs.Vrc3.Value := FRegs.Vrc3.Latch;
          end;
        $D:
          begin
            FRegs.Vrc3.Irq := False;
            WriteBits(FRegs.Vrc3.Control, 2, (FRegs.Vrc3.Control and 1) shl 1);
          end;
        $F:
          WriteBits(FRegs.Prg[0], $E, (Value and 7) shl 1);
      end;
    20:
      WriteMmc3(Address, Value);
    21:
      case Address and $E000 of
        $8000:
          FRegs.Select112 := Value and 7;
        $A000:
          if FRegs.Select112 < 2 then
            WriteBits(FRegs.Prg[FRegs.Select112], $3F, Value)
          else
            WriteBits(FRegs.Chr[Mmc3ChrRegister[FRegs.Select112 - 2]], $FF, Value);
        $E000:
          FRegs.Mirror := Value and 1;
      end;
    22:
      case Address and $E003 of
        $8000:
          begin
            WriteBits(FRegs.Prg[0], $3F, Value);
            if (FRegs.Flags and 1) = 0 then
              FRegs.Mirror := (Value shr 6) and 1;
          end;
        $8001:
          WriteBits(FRegs.Prg[1], $3F, Value);
        $8002, $8003:
          WriteBits(FRegs.Chr[(Address and 1) * 2], $FE, Word(Value) shl 1);
        $A000..$A003:
          WriteBits(FRegs.Chr[4 + (Address and 3)], $FF, Value);
      else
        if (FRegs.Flags and 1) <> 0 then
          case Address and $E003 of
            $C000:
              FRegs.Mmc3Latch := Value xor $FF;
            $C001:
              FRegs.Mmc3Reload := True;
            $C002:
              FRegs.Mmc3Enable := True;
            $C003:
              AcknowledgeMmc3;
            $E000:
              FRegs.Mirror := (Value shr 6) and 1;
          end;
      end;
    23:
      case Address and $C003 of
        $8000:
          WriteBits(FRegs.Chr[0], $F8, Word(Value) shl 3);
        $C000:
          WriteBits(FRegs.PrgAt6000, $0F, Value);
        $C001:
          FRegs.Mirror := (Value shr 3) and 1;
        $C002:
          begin
            FRegs.FdsConversion.Control := (Value shr 1) and 1;
            if FRegs.FdsConversion.Control = 0 then
              FRegs.FdsConversion.Value := 0;
          end;
      end;
    24:
      WriteVrc4(Address, Value);
    25:
      WriteSunsoft7(Address, Value);
    26:
      case Address shr 12 of
        $8:
          WriteBits(FRegs.Prg[0], $3F, Value);
        $9:
          begin
            WriteBits(FRegs.PrgMode, 1, (Value shr 1) and 1);
            FRegs.Mirror := Value and 1;
          end;
        $A:
          WriteBits(FRegs.Prg[1], $3F, Value);
        $B:
          WriteBits(FRegs.Chr[Address and 7], $FF, Value);
      end;
    29:
      if (Address and $FFFE) <> $FFFE then
      begin
        WriteBits(FRegs.Prg[0], $3C, (Value shr 2) and $3C);
        WriteBits(FRegs.Chr[0], $78, Word(Value and $F) shl 3);
      end;
    34:
      case Address shr 12 of
        $8:
          WriteBits(FRegs.Prg[0], $0F, Value);
        $9:
          begin
            FRegs.Mirror := Value and 1;
            WriteBits(FRegs.Chr[0], $40, Word(Value and 2) shl 5);
            WriteBits(FRegs.Chr[4], $40, Word(Value and 4) shl 4);
          end;
        $A:
          WriteBits(FRegs.Prg[1], $0F, Value);
        $C:
          WriteBits(FRegs.Prg[2], $0F, Value);
        $E:
          WriteBits(FRegs.Chr[0], $3C, Word(Value and $F) shl 2);
        $F:
          WriteBits(FRegs.Chr[4], $3C, Word(Value and $F) shl 2);
      end;
    35:
      WriteCony(Address, Value);
    36:
      if (Address and $800) = 0 then
        FRegs.Sunsoft3.Irq := False
      else
        case Address shr 12 of
          $8..$B:
            WriteBits(FRegs.Chr[((Address shr 12) and 3) * 2], $7E, Word(Value) shl 1);
          $C:
            begin
              FRegs.Sunsoft3.Latch := FRegs.Sunsoft3.Latch xor 1;
              var Shift := FRegs.Sunsoft3.Latch * 8;
              WriteBits(FRegs.Sunsoft3.Value, $FF shl Shift, Word(Value) shl Shift);
            end;
          $D:
            begin
              FRegs.Sunsoft3.Latch := 0;
              FRegs.Sunsoft3.Control := (Value shr 4) and 1;
            end;
          $E:
            FRegs.Mirror := Value and 3;
          $F:
            WriteBits(FRegs.Prg[0], $1E, Value shl 1 and $1E);
        end;
    37:
      begin
        WriteBits(FRegs.Prg[0], $0E, (Value shr 3) and $0E);
        WriteBits(FRegs.Chr[0], $78, Word((Value shr 4) and 8 or (Value and 7)) shl 3);
        FRegs.Mirror := 2 or ((Value shr 3) and 1);
      end;
  end;
end;

function TMapperCoolGirl.CpuPeek(Address: Word; out Value: Byte): Boolean;
begin
  if Address >= $8000 then
    Exit(ReadFlash(FPrgOffset[(Address shr 13) and 3] + (Address and $1FFF), Value));
  if Address >= $6000 then
  begin
    if FRegs.RomAt6000 then
      Exit(ReadFlash(FPrgOffset[4] + (Address and $1FFF), Value));
    if (FRegs.Control and 1) <> 0 then
    begin
      Value := FWorkRam[Integer(FRegs.RamPage) * $2000 + (Address and $1FFF)];
      Exit(True);
    end;
  end;
  if (Address >= $5000) and (Address < $6000) then
    case FRegs.Mapper of
      0:
        begin
          Value := 0;
          Exit(True);
        end;
      6:
        case Address and $7700 of
          $5100:
            begin
              Value := FRegs.Nanjing[0] or FRegs.Nanjing[1] or FRegs.Nanjing[2] or
                (FRegs.Nanjing[3] xor $FF);
              Exit(True);
            end;
          $5500:
            begin
              Value := FRegs.Nanjing[1 + Ord(FRegs.NanjingStrobe)];
              Exit(True);
            end;
        end;
      15:
        if Address = $5204 then
        begin
          Value := (Ord(FRegs.Mmc5Irq) shl 7) or (Ord(FRegs.InFrame) shl 6);
          Exit(True);
        end;
      35:
        begin
          Value := FRegs.Flags and 3;
          Exit(True);
        end;
    end;
  if (FRegs.Mapper = 29) and ((Address and $E100) = $4100) then
  begin
    Value := (FRegs.Prg[0] and $0C) shl 2;
    Exit(True);
  end;
  if (FRegs.Mapper = 13) and ((Address and $FFFE) = $5800) then
  begin
    Value := (Integer(FRegs.MulA) * FRegs.MulB shr ((Address and 1) * 8)) and $FF;
    Exit(True);
  end;
  Result := False;
end;

function TMapperCoolGirl.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := CpuPeek(Address, Value);
  if (FRegs.Mapper = 15) and (Address = $5204) then
    FRegs.Mmc5Irq := False;
end;

procedure TMapperCoolGirl.ObserveController(Value: Byte);
begin
  if (FRegs.Control and $80) = 0 then
    Exit;
  FRegs.ControllerBits := ((FRegs.ControllerBits shl 1) or (Value and 1)) and $1FF;
  if FRegs.ControllerBits = ResetCombination then
  begin
    Reset;
    FRegs.ResetRead := 1;
  end;
end;

function TMapperCoolGirl.ReadResetInstruction(out Value: Byte): Boolean;
begin
  Result := FRegs.ResetRead <> 0;
  case FRegs.ResetRead of
    1:
      Value := $6C;
    2:
      Value := $FC;
    3:
      Value := $FF;
  else
    Exit;
  end;
  FRegs.ResetRead := (FRegs.ResetRead + 1) and 3;
end;

function TMapperCoolGirl.CpuWriteTimed(Address: Word; Value: Byte; CpuCycle: UInt64): Boolean;
begin
  var Consecutive := FRegs.HasLastWrite and (CpuCycle > FRegs.LastWriteCycle) and
    (CpuCycle - FRegs.LastWriteCycle = 1);
  FRegs.HasLastWrite := True;
  FRegs.LastWriteCycle := CpuCycle;
  if Consecutive and (Address <> $4016) then
  begin
    // The CPLD ignores the final write of a 6502 RMW pair. RAM and flash are
    // wired directly to the bus and still receive it.
    if (Address >= $6000) and (Address < $8000) and not FRegs.RomAt6000 and ((FRegs.Control and 1) <> 0) then
      FWorkRam[Integer(FRegs.RamPage) * $2000 + (Address and $1FFF)] := Value;
    if ((FRegs.Control and 4) <> 0) and (Address >= $6000) then
      if Address >= $8000 then
        WriteFlash(FPrgOffset[(Address shr 13) and 3] + (Address and $1FFF), Value)
      else if FRegs.RomAt6000 then
        WriteFlash(FPrgOffset[4] + (Address and $1FFF), Value);
    Exit(True);
  end;
  Result := CpuWrite(Address, Value);
end;

function TMapperCoolGirl.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  if Address = $4016 then
  begin
    FRegs.ControllerBits := 1;
    Exit(True);
  end;
  Result := Address >= $4020;
  if not Result then
    Exit;
  if Address >= $8000 then
  begin
    if (FRegs.Control and 4) <> 0 then
      WriteFlash(FPrgOffset[(Address shr 13) and 3] + (Address and $1FFF), Value);
    if FRegs.Mapper = 0 then
      Exit;
    WriteHigh(Address, Value);
  end
  else
  begin
    var Mode := FRegs.Mapper;
    if (Address >= $5000) and (Address < $6000) and ((FRegs.Control and $80) = 0) then
      WriteOuter(Address and 7, Value);
    if Address >= $6000 then
    begin
      if FRegs.RomAt6000 then
      begin
        if (FRegs.Control and 4) <> 0 then
          WriteFlash(FPrgOffset[4] + (Address and $1FFF), Value);
      end
      else if (FRegs.Control and 1) <> 0 then
        FWorkRam[Integer(FRegs.RamPage) * $2000 + (Address and $1FFF)] := Value;
    end;
    WriteLow(Mode, Address, Value);
  end;
  UpdatePrg;
  UpdateChr;
end;

function TMapperCoolGirl.PpuPeek(Address: Word; Rendering: Boolean; out Value: Byte; Sprite: Boolean): Boolean;
begin
  if Address < $2000 then
  begin
    Value := FChr[FChrOffset[Address shr 10] + (Address and $3FF)];
    Exit(True);
  end;
  Result := (Address < $3000) and ((FRegs.Control and $20) <> 0);
  if Result then
    Value := FChr[$7F000 + (Address and $FFF)];
end;

procedure TMapperCoolGirl.HandlePatternLatch(Address: Word);
begin
  case Address and $3FF8 of
    $0FD8:
      if FRegs.Latch0 then
      begin
        FRegs.Latch0 := False;
        UpdateChr;
      end;
    $0FE8:
      if not FRegs.Latch0 then
      begin
        FRegs.Latch0 := True;
        UpdateChr;
      end;
    $1FD8:
      if FRegs.Latch1 then
      begin
        FRegs.Latch1 := False;
        UpdateChr;
      end;
    $1FE8:
      if not FRegs.Latch1 then
      begin
        FRegs.Latch1 := True;
        UpdateChr;
      end;
  end;
end;

function TMapperCoolGirl.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := PpuPeek(Address, False, Value, False);
  if FRegs.ChrMode = 5 then
    HandlePatternLatch(Address);
end;

function TMapperCoolGirl.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := Address < $2000;
  if Result then
  begin
    if (FRegs.Control and 2) <> 0 then
      FChr[FChrOffset[Address shr 10] + (Address and $3FF)] := Value;
  end
  else if (Address < $3000) and ((FRegs.Control and $20) <> 0) then
  begin
    FChr[$7F000 + (Address and $FFF)] := Value;
    Result := True;
  end;
end;

function TMapperCoolGirl.AllowsDirectPpuRead: Boolean;
begin
  Result := True;
end;

function TMapperCoolGirl.GetMirrorMode: TMirrorMode;
begin
  if (FRegs.Control and $20) <> 0 then
    Result := TMirrorMode.FourScreen
  else
    case FRegs.Mirror of
      0:
        Result := TMirrorMode.Vertical;
      1:
        Result := TMirrorMode.Horizontal;
      2:
        Result := TMirrorMode.Single0;
    else
      Result := TMirrorMode.Single1;
    end;
end;

function TMapperCoolGirl.NameTableOffset(Address: Word): Word;
begin
  if (FRegs.Mapper = 20) and ((FRegs.Flags and 1) <> 0) and
    ((FRegs.Control and $20) = 0) then
    Exit((Address and $3FF) or ((FLogicalChr[(Address shr 10) and 7] and $80) shl 3));
  Result := inherited NameTableOffset(Address);
end;

procedure TMapperCoolGirl.ClockCpu;
begin
  if not FRegs.A12 and (FRegs.A12LowClocks < 3) then
    Inc(FRegs.A12LowClocks);
  if FRegs.Mmc3Enable then
    if FRegs.Mmc3Counter <> 0 then
      FRegs.Mmc3Armed := True
    else if FRegs.Mmc3Armed then
      FRegs.Mmc3Irq := True;
  if (FRegs.Mapper = 6) or (FRegs.Mapper = 15) then
  begin
    if FRegs.PpuIdle < 15 then
      Inc(FRegs.PpuIdle)
    else
      FRegs.InFrame := False;
  end;
  ClockCpuIrqs;
end;

procedure TMapperCoolGirl.ClockCpuIrqs;
begin
  if (FRegs.Vrc4.Control and 2) <> 0 then
  begin
    Inc(FRegs.Vrc4Prescaler);
    var Period := 114 - Ord(FRegs.Vrc4Phase = 2);
    if FRegs.Vrc4Prescaler = Period then
    begin
      FRegs.Vrc4Prescaler := 0;
      FRegs.Vrc4Phase := (FRegs.Vrc4Phase + 1) mod 3;
      if FRegs.Vrc4.Value = $FF then
      begin
        FRegs.Vrc4.Value := FRegs.Vrc4.Latch;
        FRegs.Vrc4.Irq := True;
      end
      else
        Inc(FRegs.Vrc4.Value);
    end;
  end;
  if (FRegs.Vrc3.Control and 2) <> 0 then
  begin
    var Mask: Word := $FFFF;
    if (FRegs.Vrc3.Control and 4) <> 0 then
      Mask := $FF;
    if (FRegs.Vrc3.Value and Mask) = Mask then
    begin
      WriteBits(FRegs.Vrc3.Value, Mask, FRegs.Vrc3.Latch);
      FRegs.Vrc3.Irq := True;
    end
    else
      Inc(FRegs.Vrc3.Value);
  end;
  if ((FRegs.Sunsoft7.Control and $80) <> 0) then
  begin
    if (FRegs.Sunsoft7.Value = 0) and ((FRegs.Sunsoft7.Control and 1) <> 0) then
      FRegs.Sunsoft7.Irq := True;
    FRegs.Sunsoft7.Value := (Integer(FRegs.Sunsoft7.Value) - 1) and $FFFF;
  end;
  if (FRegs.Irem65.Control <> 0) and (FRegs.Irem65.Value <> 0) then
  begin
    Dec(FRegs.Irem65.Value);
    if FRegs.Irem65.Value = 0 then
      FRegs.Irem65.Irq := True;
  end;
  if (FRegs.Jaleco18.Control and 1) <> 0 then
  begin
    var Mask: Word := $FFFF;
    if (FRegs.Jaleco18.Control and 8) <> 0 then
      Mask := $F
    else if (FRegs.Jaleco18.Control and 4) <> 0 then
      Mask := $FF
    else if (FRegs.Jaleco18.Control and 2) <> 0 then
      Mask := $FFF;
    if (FRegs.Jaleco18.Value and Mask) = 0 then
      FRegs.Jaleco18.Irq := True;
    WriteBits(FRegs.Jaleco18.Value, Mask, (Integer(FRegs.Jaleco18.Value) - 1) and Mask);
  end;
  if FRegs.FdsConversion.Control <> 0 then
    FRegs.FdsConversion.Value := (FRegs.FdsConversion.Value + 1) and $7FFF;
  if (FRegs.Cony.Control and 1) <> 0 then
  begin
    if FRegs.Cony.Value = 0 then
      FRegs.Cony.Irq := True;
    FRegs.Cony.Value := (Integer(FRegs.Cony.Value) - 1) and $FFFF;
  end;
  if FRegs.Sunsoft3.Control <> 0 then
  begin
    if FRegs.Sunsoft3.Value = 0 then
    begin
      FRegs.Sunsoft3.Irq := True;
      FRegs.Sunsoft3.Control := 0;
    end;
    FRegs.Sunsoft3.Value := (Integer(FRegs.Sunsoft3.Value) - 1) and $FFFF;
  end;
end;

procedure TMapperCoolGirl.ClockPpuAddress(Address: Word; PpuCycle: UInt64);
begin
  FRegs.PpuAddress := Address;
  var High := (Address and $1000) <> 0;
  if High and not FRegs.A12 then
  begin
    if FRegs.A12LowClocks = 3 then
    begin
      if FRegs.Mmc3Reload or (FRegs.Mmc3Counter = 0) then
        FRegs.Mmc3Counter := FRegs.Mmc3Latch
      else
        Dec(FRegs.Mmc3Counter);
      FRegs.Mmc3Reload := False;
    end;
    FRegs.A12LowClocks := 0;
  end;
  FRegs.A12 := High;
end;

procedure TMapperCoolGirl.ClockPpuRead;
begin
  if (FRegs.Mapper <> 6) and (FRegs.Mapper <> 15) then
    Exit;
  FRegs.PpuIdle := 0;
  if not FRegs.InFrame then
  begin
    FRegs.InFrame := True;
    FRegs.PpuScanline := 0;
    FRegs.PpuNametableReads := 0;
    if FRegs.ChrMode = 1 then
      UpdateChr;
  end
  else if (FRegs.PpuAddress and $3000) = $2000 then
  begin
    if FRegs.PpuNametableReads < 3 then
      Inc(FRegs.PpuNametableReads)
    else
    begin
      FRegs.PpuScanline := (FRegs.PpuScanline + 1) and $FF;
      if FRegs.Mmc5Enabled and (Integer(FRegs.PpuScanline) = Integer(FRegs.Mmc5Line) + 1) then
        FRegs.Mmc5Irq := True;
      if (FRegs.PpuScanline = 129) and (FRegs.ChrMode = 1) then
        UpdateChr;
    end;
  end
  else
    FRegs.PpuNametableReads := 0;
end;

function TMapperCoolGirl.IrqPending: Boolean;
begin
  Result := FRegs.Mmc3Irq or FRegs.Mmc5Irq or FRegs.Vrc4.Irq or FRegs.Vrc3.Irq or
    FRegs.Irem65.Irq or FRegs.Sunsoft7.Irq or FRegs.Jaleco18.Irq or FRegs.Sunsoft3.Irq or
    FRegs.Cony.Irq or ((FRegs.FdsConversion.Value and $6000) = $6000);
end;

procedure TMapperCoolGirl.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FChr[0], Length(FChr));
  State.Field(FWorkRam[0], Length(FWorkRam));
  State.Field(FSaveFlash[0], Length(FSaveFlash));
  if State.Loading then
  begin
    if (FRegs.PrgBase > $1FFF) or (FRegs.PrgMode > 7) or (FRegs.ChrMode > 7) or
      (FRegs.PrgMask > $7F) or (FRegs.ChrMask > $3F) or (FRegs.RamPage > 3) or
      (FRegs.Mmc3Select > 7) or (FRegs.Mirror > 3) or (FRegs.ResetRead > 3) or
      (FRegs.FlashMode > 2) or (FRegs.FlashStep > 6) or (FRegs.Vrc4.Value > $FF) or
      (FRegs.Vrc4Prescaler > 114) or (FRegs.Vrc4Phase > 2) or
      (FRegs.Sunsoft3.Latch > 1) or (FRegs.Select112 > 7) or (FRegs.Select69 > 15) then
      raise EReadError.Create('Invalid COOLGIRL state');
    for var Bank in FRegs.Chr do
      if Bank > $1FF then
        raise EReadError.Create('Invalid COOLGIRL CHR bank');
    UpdatePrg;
    UpdateChr;
  end;
end;

function TMapperCoolGirl.GetSaveMemory: NES.Types.TByteArray;
begin
  Result := Copy(FSaveFlash);
end;

procedure TMapperCoolGirl.SetSaveMemory(const Data: NES.Types.TByteArray);
begin
  if Length(Data) <> SaveFlashSize then
    raise ENesException.Create('Invalid COOLGIRL flash save size');
  Move(Data[0], FSaveFlash[0], SaveFlashSize);
end;

end.

