unit NES.Mapper.Vrc5;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  // Konami Q-Ta: internal 128 KiB PRG followed by the 512 KiB cartridge.
  TMapperVrc5 = class(TMapper)
  private
    FPrgRom, FChrRom: TByteArray;
    FPrgRam: array[0..$3FFF] of Byte;
    FChrRam: array[0..$1FFF] of Byte;
    FQtram: array[0..$7FF] of Byte;
    FRegisters: array[0..15] of Byte;
    FBankByte: Byte;
    FIrqLatch, FIrqCounter: Integer;
    FIrqEnabled, FIrqAfterAck, FIrqPending: Boolean;
    function RamOffset(Address: UInt16): Integer;
    function NameOffset(Address: UInt16): Integer;
    function TranslateCharacter(Address: UInt16): Byte;
  public
    constructor Create(const Prg, Chr: TByteArray);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

implementation

constructor TMapperVrc5.Create(const Prg, Chr: TByteArray);
begin
  inherited Create;
  ValidateMemory(Prg, Chr);
  if (Length(Prg) <> $A0000) or ((Length(Chr) <> $20000) and (Length(Chr) <> $40000)) then
    raise ENesException.Create('Q-Ta requires 640 KiB PRG and 128 or 256 KiB CHR ROM');

  FPrgRom := Copy(Prg);
  FChrRom := Copy(Chr);
  Reset;
end;

procedure TMapperVrc5.Reset;
begin
  // Reset the ASIC without erasing cartridge, adapter, or PPU RAM.
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FBankByte := 0;
  FIrqLatch := 0;
  FIrqCounter := 0;
  FIrqEnabled := False;
  FIrqAfterAck := False;
  FIrqPending := False;
end;

function TMapperVrc5.RamOffset(Address: UInt16): Integer;
begin
  var Reg := FRegisters[(Address - $6000) shr 12];
  // Banks 0/1 belong to the battery-backed cartridge; 2/3 to the adapter.
  Result := (((Reg and 8) shr 2) or (Reg and 1)) * $1000 + (Address and $FFF);
end;

function TMapperVrc5.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRam[RamOffset(Address)];
    Exit(True);
  end;

  if Address < $8000 then
    Exit(False);

  if (Address = $DC00) or (Address = $DD00) then
    Value := TranslateCharacter(Address)
  else
  begin
    var Bank := $4F;
    if Address < $E000 then
    begin
      var Reg := FRegisters[2 + ((Address - $8000) shr 13)];
      if (Reg and $40) <> 0 then
        Bank := $10 + (Reg and $3F)
      else
        Bank := Reg and $0F;
    end;
    Value := FPrgRom[Bank * $2000 + (Address and $1FFF)];
  end;
  Result := True;
end;

function TMapperVrc5.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    FPrgRam[RamOffset(Address)] := Value;
    Exit(True);
  end;

  if (Address and $F000) = $D000 then
  begin
    var Reg := (Address shr 8) and 15;
    FRegisters[Reg] := Value;
    case Reg of
      6:
        FIrqLatch := (FIrqLatch and $FF00) or Value;
      7:
        FIrqLatch := (FIrqLatch and $FF) or (Integer(Value) shl 8);
      8:
        begin
          FIrqEnabled := FIrqAfterAck;
          FIrqPending := False;
        end;
      9:
        begin
          FIrqAfterAck := (Value and 1) <> 0;
          FIrqEnabled := (Value and 2) <> 0;
          if FIrqEnabled then
            FIrqCounter := FIrqLatch;
          FIrqPending := False;
        end;
    end;
  end;
  Result := Address >= $8000;
end;

function TMapperVrc5.TranslateCharacter(Address: UInt16): Byte;
const
  // JIS pages alias into the 4096 glyphs physically present in the mask ROM.
  Pages: array[0..35] of Byte = (
    0, 0, 2, 2, 1, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 13, 13);
begin
  var Row := Integer(FRegisters[13]) - $20;
  var Col := Integer(FRegisters[12]) - $20;
  if (Row < 0) or (Row >= 96) or (Col < 0) or (Col >= 96) then
    Exit(0);

  var Code := (Col mod 32) + (Row mod 16) * 32 +
    (Col div 32) * 512 + (Row div 16) * 1536;
  var Tile := ((Code and $FF) or (Integer(Pages[Code shr 8]) shl 8)) * 4;
  if Address = $DC00 then
    Result := (Tile and $FF) or (FRegisters[11] and 3)
  else
    Result := (Tile shr 8) or $40 or ((FRegisters[11] and 4) shl 5);
end;

function TMapperVrc5.NameOffset(Address: UInt16): Integer;
begin
  if (FRegisters[10] and 2) <> 0 then
    Result := ((Address shr 11) and 1) * $400
  else
    Result := ((Address shr 10) and 1) * $400;
  Result := Result + (Address and $3FF);
end;

function TMapperVrc5.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
  begin
    if FPpuRenderingRead and not FPpuSpriteFetch and ((Address and $3FF) < $3C0) then
      FBankByte := FQtram[NameOffset(Address)];
    // Nametable tile and attribute bytes still come from the console's CIRAM.
    Exit(False);
  end;

  if Address >= $2000 then
    Exit(False);

  if FPpuRenderingRead and not FPpuSpriteFetch then
  begin
    if (FBankByte and $40) <> 0 then
    begin
      if (Address and 8) <> 0 then
        Value := Byte(Ord((FBankByte and $80) <> 0) * $FF)
      else
      begin
        var Offset := (Integer(FBankByte and $3F) shl 12) or (Address and $FFF);
        // Accept both raw 1bpp mask-ROM and older expanded 2bpp dumps.
        if Length(FChrRom) = $20000 then
          Offset := ((Offset and 7) shl 1) or ((Offset and $10) shr 4) or
            ((Offset and $3FFE0) shr 1);
        Value := FChrRom[Offset];
      end;
    end
    else
      Value := FChrRam[Integer(FBankByte and 1) * $1000 + (Address and $FFF)];
  end
  else
  begin
    var Bank := 1;
    if Address < $1000 then
      Bank := FRegisters[5] and 1;
    Value := FChrRam[Bank * $1000 + (Address and $FFF)];
  end;
  Result := True;
end;

function TMapperVrc5.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $2000 then
  begin
    var Bank := 1;
    if Address < $1000 then
      Bank := FRegisters[5] and 1;
    FChrRam[Bank * $1000 + (Address and $FFF)] := Value;
    Exit(True);
  end;
  Result := (Address < $3F00) and ((FRegisters[10] and 1) <> 0);
  if Result then
    FQtram[NameOffset(Address)] := Value;
end;

function TMapperVrc5.GetMirrorMode: TMirrorMode;
begin
  if (FRegisters[10] and 2) <> 0 then
    Result := TMirrorMode.Horizontal
  else
    Result := TMirrorMode.Vertical;
end;

procedure TMapperVrc5.ClockCpu;
begin
  if FIrqEnabled then
  begin
    FIrqCounter := (FIrqCounter + 1) and $FFFF;
    if FIrqCounter = 0 then
    begin
      FIrqCounter := FIrqLatch;
      FIrqPending := True;
    end;
  end;
end;

function TMapperVrc5.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

procedure TMapperVrc5.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgRam, SizeOf(FPrgRam));
  State.Field(FChrRam, SizeOf(FChrRam));
  State.Field(FQtram, SizeOf(FQtram));
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FBankByte, SizeOf(FBankByte));
  State.Field(FIrqLatch, SizeOf(FIrqLatch));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqAfterAck, SizeOf(FIrqAfterAck));
  State.Field(FIrqPending, SizeOf(FIrqPending));
end;

function TMapperVrc5.GetSaveMemory: TByteArray;
begin
  SetLength(Result, $2000);
  Move(FPrgRam[0], Result[0], Length(Result));
end;

procedure TMapperVrc5.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> $2000 then
    raise ENesException.Create('Invalid Q-Ta save size');

  Move(Data[0], FPrgRam[0], Length(Data));
end;

end.

