unit NES.Mapper.Rainbow;

interface

uses
  System.Math, NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked,
  NES.Mapper.VrcAudio;

type
  TRainbowFlash = record
    Step, Mode: Integer;
    SoftwareId, Bypass: Boolean;
  end;

  TRainbowSerialEsp = record
  private
    FRemaining, FCommand: Integer;
    FHead, FCount, FPosition: Integer;
    FLastRead: Byte;
    FReplies: array[0..19, 0..2] of Byte;
    procedure QueueReply(Command, Payload: Integer);
  public
    procedure Reset;
    procedure SerializeState(State: TNesStateArchive);
    procedure WriteByte(Value: Byte; LegacyOpcodes: Boolean);
    function ReadByte(Enabled: Boolean): Byte;
    function DataReady: Boolean;
  end;

  TMapperRainbowNrom = class(TMapperBanked)
  private
    FEspFlags: Byte;
    FSerialEsp: TRainbowSerialEsp;
    FPrgStep, FPrgMode, FChrStep, FChrMode: Integer;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function IrqPending: Boolean; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

  TMapperRainbow13 = class(TMapperVrcAudio)
  private
    FConfig, FFpgaBank, FWorkBank, FChrUpper, FEspConfig: Byte;
    FPrgSelect: array[0..2] of Byte;
    FChrSelect: array[0..7] of Word;
    FFpgaRam: array[0..$1FFF] of Byte;
    FChrRam: array[0..$7FFF] of Byte;
    FMultiply: array[0..1] of Byte;
    FFlashStep, FFlashMode: array[0..1] of Integer;
    FFlashId: array[0..1] of Boolean;
    FIrqLatch, FIrqCounter: Byte;
    FIrqReload, FIrqEnabled, FIrqPending, FHasChrRom, FLastA12High: Boolean;
    FA12LowSince: UInt64;
    function MappedPrgOffset(Address: UInt16; out IsRam: Boolean): Integer;
    function MappedChrOffset(Address: UInt16): Integer;
    function CartNameOffset(Address: UInt16): Integer;
    function FlashByte(const Image: TByteArray; Chip, Offset: Integer): Byte;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Board: Integer = MAPPER_RAINBOW13);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

  TMapperRainbowProto = class(TMapperRainbow13)
  private
    FSerialEsp: TRainbowSerialEsp;
    FLegacyOpcodes: Boolean;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure UseLegacyEspOpcodes;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function IrqPending: Boolean; override;
  end;

  TMapperRainbow = class(TMapperVrcAudio)
  private
    FRegs: array[0..$685] of Byte;
    FHigh: array[0..7] of Word;
    FLow: array[0..1] of Word;
    FChr: array[0..15] of Word;
    FFpga: array[0..$1FFF] of Byte;
    FNames: array[0..$7FF] of Byte;
    FChrRam: TByteArray;
    FFlash: array[0..1] of TRainbowFlash;
    FOamCode: array[0..$505] of Byte;
    FOamLocked: Boolean;
    FCounter, FReload, FFpgaAddr, FLine, FReads, FIdle, FJitter, FLastAddress: Integer;
    FSlEnabled, FSlPending, FCpuEnabled, FCpuPending, FParity, FInFrame, FInHblank: Boolean;
    FFetchSprite, FWindow, FOverride: Boolean;
    FFetchX, FFetchY, FSpriteIndex, FExt, FOamAddress, FSpriteHeight: Integer;
    function CpuOffset(Address: UInt16; out Source: Integer): Integer;
    function ReadChrData(Source, Offset: Integer): Byte;
    function ChrOffsetRainbow(Address: UInt16): Integer;
    procedure FlashWrite(Chip, Offset: Integer; Value: Byte);
    function FlashRead(Chip, Offset: Integer): Byte;
    procedure AckIrq;
    procedure GenerateOam(Extended: Boolean);
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    procedure ClockPpuRead; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); override;
    procedure SetPpuFetchKind(Sprite: Boolean; X, Y: Integer); override;
    procedure SetPpuSpriteIndex(Index: Integer); override;
    procedure CpuIoWrite(Address: UInt16; Value: UInt8); override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

implementation

uses
  NES.Mapper.Flash, NES.Mapper.Mmc3;

procedure TRainbowSerialEsp.Reset;
begin
  Self := Default(TRainbowSerialEsp);
end;

procedure TRainbowSerialEsp.SerializeState(State: TNesStateArchive);
begin
  State.Field(FRemaining, SizeOf(FRemaining));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FHead, SizeOf(FHead));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FLastRead, SizeOf(FLastRead));
  State.Field(FReplies, SizeOf(FReplies));
end;

procedure TRainbowSerialEsp.QueueReply(Command, Payload: Integer);
begin
  if FCount = Length(FReplies) then
    Exit;

  var Tail := (FHead + FCount) mod Length(FReplies);
  FReplies[Tail, 0] := 1;
  FReplies[Tail, 1] := Command;
  if Payload >= 0 then
  begin
    FReplies[Tail, 0] := 2;
    FReplies[Tail, 2] := Payload;
  end;
  Inc(FCount);
end;

procedure TRainbowSerialEsp.WriteByte(Value: Byte; LegacyOpcodes: Boolean);
begin
  if FRemaining = 0 then
  begin
    FRemaining := Value;
    FCommand := -1;
    Exit;
  end;
  if FCommand < 0 then
    FCommand := Value;
  Dec(FRemaining);
  if FRemaining <> 0 then
    Exit;

  // The early serial firmwares changed opcode numbers between releases.
  // The connection state of this local ESP model is always disconnected.
  if FCommand = 0 then
    QueueReply(0, -1)
  else if LegacyOpcodes then
    case FCommand of
      2:
        Reset;
      3:
        QueueReply(5, 6);
      8:
        QueueReply(6, 0);
    end
  else
    case FCommand of
      4:
        Reset;
      6:
        QueueReply(9, 6);
      11:
        QueueReply(10, 0);
    end;
end;

function TRainbowSerialEsp.DataReady: Boolean;
begin
  Result := FCount <> 0;
end;

function TRainbowSerialEsp.ReadByte(Enabled: Boolean): Byte;
begin
  if Enabled and DataReady then
  begin
    // The serial latch still contains the previous byte on the first read.
    if FPosition <> 0 then
      FLastRead := FReplies[FHead, FPosition - 1];
    if FPosition > FReplies[FHead, 0] then
    begin
      FPosition := 0;
      FHead := (FHead + 1) mod Length(FReplies);
      Dec(FCount);
    end
    else
      Inc(FPosition);
  end;
  Result := FLastRead;
end;

constructor TMapperRainbowNrom.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  if ((Length(Prg) <> $4000) and (Length(Prg) <> $8000)) or ((Length(Chr) <> 0) and (Length(Chr) <> $2000)) then
    raise ENesException.Create('Invalid Rainbow NROM memory layout');

  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  if Length(Prg) = $4000 then
    FPrgRom := FPrgRom + FPrgRom;
  Reset;
end;

procedure TMapperRainbowNrom.Reset;
begin
  inherited;
  FEspFlags := $41;
  FSerialEsp.Reset;
  FPrgStep := 0;
  FPrgMode := 0;
  FChrStep := 0;
  FChrMode := 0;
end;

procedure TMapperRainbowNrom.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FEspFlags, SizeOf(FEspFlags));
  FSerialEsp.SerializeState(State);
  State.Field(FPrgStep, SizeOf(FPrgStep));
  State.Field(FPrgMode, SizeOf(FPrgMode));
  State.Field(FChrStep, SizeOf(FChrStep));
  State.Field(FChrMode, SizeOf(FChrMode));
  State.Field(FPrgRom[0], Length(FPrgRom));
end;

function TMapperRainbowNrom.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  case Address of
    $5000:
      Value := FSerialEsp.ReadByte((FEspFlags and 1) <> 0);
    $5001:
      Value := FEspFlags or (Ord(((FEspFlags and 1) <> 0) and FSerialEsp.DataReady) shl 7);
  else
    Exit(inherited CpuRead(Address, Value));
  end;
  Result := True;
end;

function TMapperRainbowNrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $5000:
      if (FEspFlags and 1) <> 0 then
        FSerialEsp.WriteByte(Value, True);
    $5001:
      FEspFlags := Value and $41;
    $8000..$FFFF:
      begin
        var SoftwareId := False;
        WriteNorFlash(FPrgRom, PrgOffset(Address), $1000, Value, FPrgStep, FPrgMode, SoftwareId);
      end;
  else
    Exit(inherited CpuWrite(Address, Value));
  end;
  Result := True;
end;

function TMapperRainbowNrom.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $2000) or FHasChrRam then
    Exit(inherited PpuWrite(Address, Value));

  var SoftwareId := False;
  WriteNorFlash(FChrMemory, Address, $800, Value, FChrStep, FChrMode, SoftwareId, $1FFF);
  Result := True;
end;

function TMapperRainbowNrom.IrqPending: Boolean;
begin
  Result := ((FEspFlags and $41) = $41) and FSerialEsp.DataReady;
end;

function TMapperRainbowNrom.GetSaveMemory: TByteArray;
begin
  Result := FPrgRom + FPrgRam;
  if not FHasChrRam then
    Result := Result + FChrMemory;
end;

procedure TMapperRainbowNrom.SetSaveMemory(const Data: TByteArray);
begin
  var PrgSize := Length(FPrgRom);
  var ChrStart := PrgSize + Length(FPrgRam);
  var RequiredSize := ChrStart;
  if not FHasChrRam then
    Inc(RequiredSize, Length(FChrMemory));
  if Length(Data) <> RequiredSize then
    raise ENesException.Create('Invalid Rainbow NROM save size');
  Move(Data[0], FPrgRom[0], PrgSize);
  Move(Data[PrgSize], FPrgRam[0], Length(FPrgRam));
  if not FHasChrRam then
    Move(Data[ChrStart], FChrMemory[0], Length(FChrMemory));
end;

constructor TMapperRainbow13.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Board: Integer);
begin
  inherited Create(Board, Prg, Chr, HasChrRam, MirrorMode);
  FHasChrRom := Length(Chr) <> 0;
  SetLength(FPrgRam, $8000);
end;

procedure TMapperRainbow13.Reset;
begin
  inherited;
  FConfig := 0;
  FFpgaBank := 0;
  FWorkBank := 0;
  FChrUpper := 0;
  FEspConfig := 0;
  FillChar(FPrgSelect, SizeOf(FPrgSelect), 0);
  FillChar(FChrSelect, SizeOf(FChrSelect), 0);
  FillChar(FMultiply, SizeOf(FMultiply), 0);
  FillChar(FFlashStep, SizeOf(FFlashStep), 0);
  FillChar(FFlashMode, SizeOf(FFlashMode), 0);
  FillChar(FFlashId, SizeOf(FFlashId), 0);
  FIrqLatch := 0;
  FIrqCounter := 0;
  FIrqReload := False;
  FIrqEnabled := False;
  FIrqPending := False;
  FLastA12High := False;
  FA12LowSince := 0;
  FMirror := TMirrorMode.Vertical;
end;

procedure TMapperRainbow13.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FConfig, SizeOf(FConfig));
  State.Field(FFpgaBank, SizeOf(FFpgaBank));
  State.Field(FWorkBank, SizeOf(FWorkBank));
  State.Field(FChrUpper, SizeOf(FChrUpper));
  State.Field(FEspConfig, SizeOf(FEspConfig));
  State.Field(FPrgSelect, SizeOf(FPrgSelect));
  State.Field(FChrSelect, SizeOf(FChrSelect));
  State.Field(FFpgaRam, SizeOf(FFpgaRam));
  State.Field(FChrRam, SizeOf(FChrRam));
  State.Field(FMultiply, SizeOf(FMultiply));
  State.Field(FFlashStep, SizeOf(FFlashStep));
  State.Field(FFlashMode, SizeOf(FFlashMode));
  State.Field(FFlashId, SizeOf(FFlashId));
  State.Field(FIrqLatch, SizeOf(FIrqLatch));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  State.Field(FIrqReload, SizeOf(FIrqReload));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqPending, SizeOf(FIrqPending));
  State.Field(FLastA12High, SizeOf(FLastA12High));
  State.Field(FA12LowSince, SizeOf(FA12LowSince));
  State.Field(FPrgRom[0], Length(FPrgRom));
end;

function TMapperRainbow13.MappedPrgOffset(Address: UInt16; out IsRam: Boolean): Integer;
begin
  IsRam := False;
  var Slot := (Address - $8000) shr 13;
  if Slot = 3 then
    Exit(Length(FPrgRom) - $2000 + (Address and $1FFF));
  if (Slot < 2) and ((FConfig and 1) = 0) then
  begin
    var Bank := FPrgSelect[0];
    IsRam := (Bank and $80) <> 0;
    if IsRam then
      Exit(((Bank + Slot) and 3) * $2000 + (Address and $1FFF));
    Exit((Bank and $1F) * $4000 + (Address and $3FFF));
  end;
  var Bank := FPrgSelect[Slot];
  IsRam := (Bank and $80) <> 0;
  if IsRam then
    Exit((Bank and 3) * $2000 + (Address and $1FFF));
  Result := (Bank and $3F) * $2000 + (Address and $1FFF);
end;

function TMapperRainbow13.MappedChrOffset(Address: UInt16): Integer;
begin
  var BankShift := 10 + ((FConfig shr 1) and 3);
  var Bank := Integer(FChrSelect[Address shr BankShift]);
  if BankShift <> 10 then
    Bank := Bank and $FF;
  Result := (Bank shl BankShift) or (Address and ((1 shl BankShift) - 1));
end;

function TMapperRainbow13.CartNameOffset(Address: UInt16): Integer;
begin
  var Page := (FConfig shr 6) and 3;
  if (FConfig and $30) = $30 then
    Exit($4000 + ((3 - Page) shl 12) + (Address and $FFF));
  if ((FConfig and $30) = $20) and (Page >= 2) then
    Exit($7800 + ((Page - 2) shl 10) + (Address and $3FF));
  Result := -1;
end;

function TMapperRainbow13.FlashByte(const Image: TByteArray; Chip, Offset: Integer): Byte;
begin
  if not FFlashId[Chip] then
    Exit(Image[Offset mod Length(Image)]);
  case Offset and $1FF of
    0:
      Result := $BF;
    1:
      case Length(Image) of
        $20000:
          Result := $B5;
        $40000:
          Result := $B6;
        $80000:
          Result := $B7;
      else
        Result := $FF;
      end;
  else
    Result := $FF;
  end;
end;

function TMapperRainbow13.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  case Address of
    $4100:
      Value := FEspConfig;
    $4101:
      Value := 0;
    $4102:
      Value := $80; // TX ready. The offline ESP interface never raises RX-ready.
      $4110:
      Value := FConfig;
    $4113:
      Value := $21;
    $4160:
      Value := (Integer(FMultiply[0]) * FMultiply[1]) shr 8;
    $4161:
      Value := (Integer(FMultiply[0]) * FMultiply[1]) and $FF;
    $4800..$4FFF:
      Value := FFpgaRam[Address and $7FF];
    $5000..$5FFF:
      Value := FFpgaRam[FFpgaBank * $1000 + (Address and $FFF)];
    $6000..$7FFF:
      case FWorkBank shr 6 of
        0:
          Value := FPrgRam[(FWorkBank and 3) * $2000 + (Address and $1FFF)];
        1:
          Value := FFpgaRam[Address and $1FFF];
      else
        Value := FlashByte(FPrgRom, 0, (FWorkBank and $3F) * $2000 + (Address and $1FFF));
      end;
    $8000..$FFFF:
      begin
        var IsRam: Boolean;
        var Offset := MappedPrgOffset(Address, IsRam);
        if IsRam then
          Value := FPrgRam[Offset]
        else
          Value := FlashByte(FPrgRom, 0, Offset);
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperRainbow13.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $4100:
      FEspConfig := Value and 3;
    $4101..$4104:
      Exit(True);
    $4110:
      begin
        FConfig := Value;
        case (FConfig shr 4) and 3 of
          0:
            FMirror := TMirrorMode.Vertical;
          1:
            FMirror := TMirrorMode.Horizontal;
          2:
            if (FConfig and $40) <> 0 then
              FMirror := TMirrorMode.Single1
            else
              FMirror := TMirrorMode.Single0;
          3:
            FMirror := TMirrorMode.FourScreen;
        end;
      end;
    $4120:
      FPrgSelect[0] := Value;
    $4121..$4122:
      FPrgSelect[Address - $4120] := Value and $BF;
    $4123:
      FFpgaBank := Value and 1;
    $4124:
      FWorkBank := Value;
    $4130..$4137:
      begin
        var Slot := Address - $4130;
        var HighBit := FChrSelect[Slot] and $100;
        if (FConfig and 6) = 0 then
          HighBit := Word(FChrUpper) shl 8;
        FChrSelect[Slot] := HighBit or Value;
      end;
    $4138:
      FChrUpper := Value and 1;
    $4140:
      FIrqLatch := Value;
    $4141:
      FIrqReload := True;
    $4142:
      begin
        FIrqEnabled := False;
        FIrqPending := False;
      end;
    $4143:
      FIrqEnabled := True;
    $4150..$4158:
      begin
        var Reg := Address - $4150;
        FAudioRegs[Reg div 3, Reg mod 3] := Value;
      end;
    $4160..$4161:
      FMultiply[Address - $4160] := Value;
    $4800..$4FFF:
      FFpgaRam[Address and $7FF] := Value;
    $5000..$5FFF:
      FFpgaRam[FFpgaBank * $1000 + (Address and $FFF)] := Value;
    $6000..$7FFF:
      case FWorkBank shr 6 of
        0:
          FPrgRam[(FWorkBank and 3) * $2000 + (Address and $1FFF)] := Value;
        1:
          FFpgaRam[Address and $1FFF] := Value;
      end;
    $8000..$FFFF:
      begin
        var IsRam: Boolean;
        var Offset := MappedPrgOffset(Address, IsRam);
        if IsRam then
          FPrgRam[Offset] := Value
        else
          WriteNorFlash(FPrgRom, Offset, $1000, Value, FFlashStep[0], FFlashMode[0], FFlashId[0]);
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperRainbow13.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address < $2000 then
  begin
    var Offset := MappedChrOffset(Address);
    if (FConfig and 8) <> 0 then
      Value := FChrRam[Offset and $7FFF]
    else if FHasChrRom then
      Value := FlashByte(FChrMemory, 1, Offset)
    else
      Value := FCpuOpenBus;
    Exit(True);
  end;
  var Offset := CartNameOffset(Address);
  Result := (Address < $3F00) and (Offset >= 0);
  if Result then
    Value := FChrRam[Offset];
end;

function TMapperRainbow13.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $2000 then
  begin
    var Offset := MappedChrOffset(Address);
    if (FConfig and 8) <> 0 then
      FChrRam[Offset and $7FFF] := Value
    else if FHasChrRom then
      WriteNorFlash(FChrMemory, Offset, $1000, Value, FFlashStep[1], FFlashMode[1], FFlashId[1]);
    Exit(True);
  end;
  var Offset := CartNameOffset(Address);
  Result := (Address < $3F00) and (Offset >= 0);
  if Result then
    FChrRam[Offset] := Value;
end;

procedure TMapperRainbow13.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if not Mmc3A12RisingEdge((Address and $1000) <> 0, PpuCycle, FLastA12High, FA12LowSince) then
    Exit;
  if (FIrqCounter = 0) or FIrqReload then
  begin
    FIrqCounter := FIrqLatch;
    FIrqReload := False;
  end
  else
    Dec(FIrqCounter);
  if FIrqEnabled and (FIrqCounter = 0) then
    FIrqPending := True;
end;

function TMapperRainbow13.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

function TMapperRainbow13.GetSaveMemory: TByteArray;
begin
  Result := FPrgRom + FPrgRam;
  if FHasChrRom then
    Result := Result + FChrMemory;
end;

procedure TMapperRainbow13.SetSaveMemory(const Data: TByteArray);
begin
  var RamOffset := Length(FPrgRom);
  var ChrOffset := RamOffset + Length(FPrgRam);
  var Required := ChrOffset;
  if FHasChrRom then
    Inc(Required, Length(FChrMemory));
  if Length(Data) <> Required then
    raise ENesException.Create('Invalid Rainbow v1.3 save size');
  Move(Data[0], FPrgRom[0], Length(FPrgRom));
  Move(Data[RamOffset], FPrgRam[0], Length(FPrgRam));
  if FHasChrRom then
    Move(Data[ChrOffset], FChrMemory[0], Length(FChrMemory));
end;

constructor TMapperRainbowProto.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode, MAPPER_RAINBOW_PROTO);
end;

procedure TMapperRainbowProto.Reset;
begin
  inherited;
  FWorkBank := $80; // The prototype switches PRG flash into the low window at power-on.
  FSerialEsp.Reset;
end;

procedure TMapperRainbowProto.UseLegacyEspOpcodes;
begin
  FLegacyOpcodes := True;
end;

procedure TMapperRainbowProto.SerializeState(State: TNesStateArchive);
begin
  inherited;
  FSerialEsp.SerializeState(State);
end;

function TMapperRainbowProto.IrqPending: Boolean;
begin
  Result := inherited IrqPending or (((FEspConfig and $41) = $41) and FSerialEsp.DataReady);
end;

function TMapperRainbowProto.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $6000 then
    Exit(inherited CpuRead(Address, Value));
  case Address of
    $5000:
      Value := FSerialEsp.ReadByte((FEspConfig and 1) <> 0);
    $5001:
      Value := FEspConfig or (Ord(((FEspConfig and 1) <> 0) and FSerialEsp.DataReady) shl 7);
    $5006:
      Value := FConfig;
    $5C03:
      Value := $20;
    $5002..$5005, $5007..$5C02, $5C04..$5C07:
      Value := 0;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperRainbowProto.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $6000 then
    Exit(inherited CpuWrite(Address, Value));
  // The early board uses serial ESP I/O and a different register decoder.
  // Translate writes to the shared bank, sound, and IRQ registers.
  case Address of
    $5000:
      begin
        if (FEspConfig and 1) <> 0 then
          FSerialEsp.WriteByte(Value, FLegacyOpcodes);
        Exit(True);
      end;
    $5001:
      begin
        FEspConfig := Value and $41;
        Exit(True);
      end;
    $5002:
      Address := $4120;
    $5003..$5004:
      begin
        Address := $4121 + (Address - $5003);
        Value := Value and $3F;
      end;
    $5005:
      begin
        FWorkBank := (Value and $3F) or ((Value xor $80) and $80);
        Exit(True);
      end;
    $5006:
      Address := $4110;
    $5007:
      Address := $4138;
    $5400..$5407:
      Address := $4130 + (Address and 7);
    $5800..$5805:
      Address := $4150 + (Address and 7);
    $5C00..$5C02:
      Address := $4156 + (Address and 3);
    $5C04..$5C07:
      Address := $4140 + (Address and 3);
  else
    Exit(False);
  end;
  Result := inherited CpuWrite(Address, Value);
end;

// Register and memory behavior follows Rainbow mapper version $21.
// Raster IRQ offsets still need validation against a Rainbow hardware ROM;
// the ESP interface currently reports a disconnected device.

constructor TMapperRainbow.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(MAPPER_RAINBOW, Prg, Chr, HasChrRam, MirrorMode);
  SetLength(FChrRam, $40000);
  SetLength(FPrgRam, $8000);
  Reset;
end;

procedure TMapperRainbow.Reset;
begin
  inherited;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FHigh, SizeOf(FHigh), 0);
  FillChar(FLow, SizeOf(FLow), 0);
  FillChar(FChr, SizeOf(FChr), 0);
  FRegs[$28] := 1;
  FRegs[$29] := 1;
  FRegs[$2F] := $80;
  FRegs[$53] := $87;
  FRegs[$142] := 6;
  FRegs[$141] := 7;
  FRegs[$AA] := 15;
  FCounter := 0;
  FReload := 0;
  FFpgaAddr := 0;
  FLine := -1;
  FReads := 0;
  FIdle := 0;
  FJitter := 0;
  FLastAddress := 0;
  FSlEnabled := False;
  FSlPending := False;
  FCpuEnabled := False;
  FCpuPending := False;
  FParity := False;
  FInFrame := False;
  FInHblank := False;
  FFetchSprite := False;
  FFetchX := 0;
  FFetchY := 0;
  FSpriteIndex := 0;
  FWindow := False;
  FOverride := False;
  FExt := 0;
  FOamLocked := False;
  FOamAddress := 0;
  FSpriteHeight := 8;
end;

procedure TMapperRainbow.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FHigh, SizeOf(FHigh));
  State.Field(FLow, SizeOf(FLow));
  State.Field(FChr, SizeOf(FChr));
  State.Field(FFpga, SizeOf(FFpga));
  State.Field(FNames, SizeOf(FNames));
  State.Field(FChrRam[0], Length(FChrRam));
  State.Field(FPrgRom[0], Length(FPrgRom));
  State.Field(FFlash, SizeOf(FFlash));
  State.Field(FOamCode, SizeOf(FOamCode));
  State.Field(FOamLocked, SizeOf(FOamLocked));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FReload, SizeOf(FReload));
  State.Field(FFpgaAddr, SizeOf(FFpgaAddr));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FReads, SizeOf(FReads));
  State.Field(FIdle, SizeOf(FIdle));
  State.Field(FJitter, SizeOf(FJitter));
  State.Field(FLastAddress, SizeOf(FLastAddress));
  State.Field(FSlEnabled, SizeOf(FSlEnabled));
  State.Field(FSlPending, SizeOf(FSlPending));
  State.Field(FCpuEnabled, SizeOf(FCpuEnabled));
  State.Field(FCpuPending, SizeOf(FCpuPending));
  State.Field(FParity, SizeOf(FParity));
  State.Field(FInFrame, SizeOf(FInFrame));
  State.Field(FInHblank, SizeOf(FInHblank));
  State.Field(FFetchSprite, SizeOf(FFetchSprite));
  State.Field(FWindow, SizeOf(FWindow));
  State.Field(FOverride, SizeOf(FOverride));
  State.Field(FFetchX, SizeOf(FFetchX));
  State.Field(FFetchY, SizeOf(FFetchY));
  State.Field(FSpriteIndex, SizeOf(FSpriteIndex));
  State.Field(FExt, SizeOf(FExt));
  State.Field(FOamAddress, SizeOf(FOamAddress));
  State.Field(FSpriteHeight, SizeOf(FSpriteHeight));
end;

function TMapperRainbow.CpuOffset(Address: UInt16; out Source: Integer): Integer;
begin
  Source := 0;
  if Address < $8000 then
  begin
    var Size := $2000;
    var Slot := 0;
    if (FRegs[0] and $80) <> 0 then
    begin
      Size := $1000;
      Slot := (Address - $6000) shr 12
    end;
    var Bank := FLow[Slot];
    Source := Bank shr 14;
    if Source <= 1 then
      Source := 0;
    Result := (Bank and $3FFF) * Size + (Address and (Size - 1));
    Exit;
  end;

  var Size := $1000;
  var Slot := (Address - $8000) shr 12;
  case FRegs[0] and 7 of
    0:
      begin
        Size := $8000;
        Slot := 0
      end;
    1:
      begin
        Size := $4000;
        Slot := Slot and 4
      end;
    2:
      if Slot < 4 then
      begin
        Size := $4000;
        Slot := 0
      end
      else
      begin
        Size := $2000;
        Slot := Slot and 6
      end;
    3:
      begin
        Size := $2000;
        Slot := Slot and 6
      end;
  end;
  if (FHigh[Slot] and $8000) <> 0 then
    Source := 2;
  Result := (FHigh[Slot] and $7FFF) * Size + (Address and (Size - 1));
end;

procedure TMapperRainbow.AckIrq;
begin
  FCpuPending := False;
  FCpuEnabled := (FRegs[$5A] and 2) <> 0
end;

procedure TMapperRainbow.GenerateOam(Extended: Boolean);
begin
  if FOamLocked then
    Exit;

  FOamLocked := True;
  var Pos := 0;
  var Count := (FRegs[$143] and $3F) * 4 + 4;
  var Page := FRegs[$141] and 7;
  if Extended then
  begin
    Pos := 2;
    Count := (FRegs[$143] and $3F) + 1;
    Page := FRegs[$142] and 7
  end;
  for var i := 0 to Count - 1 do
  begin
    FOamCode[Pos] := $A9;
    FOamCode[Pos + 1] := FFpga[($1800 + Page * $100 + i * (1 + Ord(Extended) * 3)) and $1FFF];
    FOamCode[Pos + 2] := $8D;
    if Extended then
    begin
      FOamCode[Pos + 3] := i;
      FOamCode[Pos + 4] := $42
    end
    else
    begin
      FOamCode[Pos + 3] := 4;
      FOamCode[Pos + 4] := $20
    end;
    Inc(Pos, 5);
  end;
  FOamCode[Pos] := $60;
end;

function TMapperRainbow.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address = $4011 then
  begin
    if (FRegs[$5A] and 4) <> 0 then
      AckIrq;
    Value := (FOutputs[0] + FOutputs[1] + FOutputs[2]) * 2;
    Exit(True)
  end;

  if (Address >= $4800) and (Address < $5000) then
  begin
    Value := FFpga[$1800 + (Address and $7FF)];
    Exit(True)
  end;

  if (Address >= $5000) and (Address < $6000) then
  begin
    Value := FFpga[(FRegs[$15] and 1) * $1000 + (Address and $FFF)];
    Exit(True)
  end;

  if (Address >= $4100) and (Address < $4800) then
  begin
    case Address of
      $4100, $4120, $412A..$412D, $412F, $4190:
        Value := FRegs[Address - $4100];
      $4150:
        Value := FLine and $FF;
      $4151:
        begin
          Value := Ord(FInFrame) * $40 + Ord(FInHblank) * $80;
          FSlPending := False
        end;
      $4154:
        Value := FJitter;
      $4157:
        Value := Ord(FParity) * $80;
      $415F:
        begin
          Value := FFpga[FFpgaAddr];
          FFpgaAddr := (FFpgaAddr + FRegs[$5E]) and $1FFF
        end;
      $4160:
        Value := $21;
      $4161:
        Value := Ord(FCpuPending) * $40 + Ord(FSlPending) * $80;
      $4191, $4192:
        Value := 0;
    else
      if Address >= $4280 then
      begin
        if Address = $4280 then
          GenerateOam(False)
        else if Address = $4282 then
          GenerateOam(True);
        if Address - $4280 < Length(FOamCode) then
          Value := FOamCode[Address - $4280]
        else
          Value := FCpuOpenBus;
        if Address >= $4282 then
          FOamLocked := False;
      end
      else
        Value := FCpuOpenBus;
    end;
    Exit(True);
  end;

  if Address >= $6000 then
  begin
    if (Address = $FFFA) or (Address = $FFFB) then
    begin
      FInFrame := False;
      FLine := 0;
      FSlPending := False;
      if (FRegs[$6B] and 1) <> 0 then
      begin
        Value := FRegs[$6D - (Address and 1)];
        Exit(True)
      end
    end;
    if (Address >= $FFFE) and ((FRegs[$6B] and 2) <> 0) then
    begin
      Value := FRegs[$6F - (Address and 1)];
      Exit(True)
    end;

    var Source: Integer;
    var Offset := CpuOffset(Address, Source);
    case Source of
      0:
        Value := FlashRead(0, Offset);
      2:
        Value := FPrgRam[Offset mod Length(FPrgRam)];
      3:
        Value := FFpga[Offset and $1FFF]
    end;
    Exit(True);
  end;

  Result := False;
end;

function TMapperRainbow.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $4800) and (Address < $5000) then
  begin
    FFpga[$1800 + (Address and $7FF)] := Value;
    Exit(True)
  end;

  if (Address >= $5000) and (Address < $6000) then
  begin
    FFpga[(FRegs[$15] and 1) * $1000 + (Address and $FFF)] := Value;
    Exit(True)
  end;

  if Address >= $6000 then
  begin
    var Source: Integer;
    var Offset := CpuOffset(Address, Source);
    case Source of
      0:
        FlashWrite(0, Offset, Value);
      2:
        FPrgRam[Offset mod Length(FPrgRam)] := Value;
      3:
        FFpga[Offset and $1FFF] := Value
    end;
    Exit(True);
  end;

  if (Address < $4100) or (Address > $4785) then
    Exit(False);

  FRegs[Address - $4100] := Value;
  case Address of
    $4106..$4107:
      FLow[Address - $4106] := (FLow[Address - $4106] and $FF) or (Word(Value) shl 8);
    $4116..$4117:
      FLow[Address - $4116] := (FLow[Address - $4116] and $FF00) or Value;
    $4108..$410F:
      FHigh[Address - $4108] := (FHigh[Address - $4108] and $FF) or (Word(Value) shl 8);
    $4118..$411F:
      FHigh[Address - $4118] := (FHigh[Address - $4118] and $FF00) or Value;
    $4130..$413F:
      FChr[Address - $4130] := (FChr[Address - $4130] and $FF) or (Word(Value) shl 8);
    $4140..$414F:
      FChr[Address - $4140] := (FChr[Address - $4140] and $FF00) or Value;
    $4151:
      FSlEnabled := True;
    $4152:
      begin
        FSlEnabled := False;
        FSlPending := False
      end;
    $4153:
      FRegs[$53] := EnsureRange(Value, 1, 170);
    $4157:
      FParity := True;
    $4158:
      FReload := (FReload and $FF) or (Value shl 8);
    $4159:
      FReload := (FReload and $FF00) or Value;
    $415A:
      begin
        FCpuPending := False;
        FCpuEnabled := (Value and 1) <> 0;
        if FCpuEnabled then
          FCounter := FReload
      end;
    $415B:
      AckIrq;
    $415C:
      FFpgaAddr := (FFpgaAddr and $FF) or ((Value and $1F) shl 8);
    $415D:
      FFpgaAddr := (FFpgaAddr and $1F00) or Value;
    $415F:
      begin
        FFpga[FFpgaAddr] := Value;
        FFpgaAddr := (FFpgaAddr + FRegs[$5E]) and $1FFF
      end;
    $41A0..$41A8:
      inherited CpuWrite($9000 + ((Address - $41A0) div 3) * $1000 + ((Address - $41A0) mod 3), Value);
  end;
  Result := True;
end;

function TMapperRainbow.ChrOffsetRainbow(Address: UInt16): Integer;
begin
  var Mode := Min(FRegs[$20] and 7, 4);
  var Size := $2000 shr Mode;
  Result := FChr[Address div Size] * Size + (Address and (Size - 1));
end;

function TMapperRainbow.ReadChrData(Source, Offset: Integer): Byte;
begin
  case Source of
    0:
      Result := FlashRead(1, Offset);
    1:
      Result := FChrRam[Offset mod Length(FChrRam)];
    2:
      Result := FFpga[Offset and $1FFF];
  else
    Result := FNames[Offset and $7FF]
  end;
end;

function TMapperRainbow.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $3F00;
  if not Result then
    Exit;

  var Source := FRegs[$20] shr 6;
  if Address < $2000 then
  begin
    var Offset := ChrOffsetRainbow(Address);
    if Source = 2 then
      Offset := Address and $FFF
    else if Source = 3 then
      Offset := Address and $7FF;
    if FPpuRenderingRead and FInFrame and not FFetchSprite and FOverride then
    begin
      Offset := (Address and $FFF) or ((FExt and $3F) shl 12) or ((FRegs[$21] and $1F) shl 18);
      if FWindow then
        Offset := (Offset and not 7) or ((FFetchY + FRegs[$75]) mod 240 and 7)
    end
    else if FPpuRenderingRead and FFetchSprite and ((FRegs[$20] and $20) <> 0) then
      if FSpriteHeight = 16 then
        Offset := ((FRegs[$140] and 7) shl 21) or (FRegs[$100 + FSpriteIndex] shl 13) or (Address and $1FFF)
      else
        Offset := ((FRegs[$140] and 7) shl 20) or (FRegs[$100 + FSpriteIndex] shl 12) or (Address and $FFF);
    Value := ReadChrData(Source, Offset);
    Exit;
  end;

  var Nt := (Address shr 10) and 3;
  var Ctrl := FRegs[$2A + Nt];
  var Offset := Address and $3FF;
  var Bank := FRegs[$26 + Nt];
  var Attribute := Offset >= $3C0;
  if FPpuRenderingRead and FInFrame and not FFetchSprite then
  begin
    if not Attribute then
    begin
      FWindow := False;
      if (FRegs[$20] and $10) <> 0 then
      begin
        var Column := FFetchX shr 3;
        var Y := FFetchY;
        var XMatch := (Column >= (FRegs[$70] and 31)) and (Column <= (FRegs[$71] and 31));
        var YMatch := (Y >= FRegs[$72]) and (Y <= FRegs[$73]);
        if FRegs[$70] >= FRegs[$71] then
          XMatch := (Column <= FRegs[$71]) or (Column > FRegs[$70]);
        if FRegs[$72] >= FRegs[$73] then
          YMatch := (Y <= FRegs[$73]) or (Y > FRegs[$72]);
        FWindow := XMatch and YMatch;
      end;
    end;
    if FWindow then
    begin
      Ctrl := FRegs[$2F];
      Bank := FRegs[$2E];
      Source := 2;
      var Y := (FFetchY + FRegs[$75]) mod 240;
      var X := ((FFetchX shr 3) + FRegs[$74]) and 31;
      if Attribute then
        Offset := $3C0 + ((Y shr 5) * 8) + (X shr 2)
      else
        Offset := (Y shr 3) * 32 + X;
    end;
    if not Attribute then
    begin
      FOverride := (Ctrl and 2) <> 0;
      FExt := FFpga[((Ctrl and 12) shl 8) + Offset]
    end;
    if (Ctrl and $20) <> 0 then
    begin
      if Attribute then
        Value := (FRegs[$25] and 3) * $55
      else
        Value := FRegs[$24];
      Exit
    end;
    if Attribute and ((Ctrl and 1) <> 0) then
    begin
      Value := (FExt shr 6) * $55;
      Exit
    end;
  end;
  if not (FPpuRenderingRead and FWindow) then
    Source := Ctrl shr 6;
  case Source of
    0:
      Value := FNames[(Bank and 1) * $400 + Offset];
    1:
      Value := FChrRam[(Bank * $400 + Offset) mod Length(FChrRam)];
    2:
      Value := FFpga[(Bank and 3) * $400 + Offset];
    3:
      Value := FlashRead(1, Bank * $400 + Offset);
  end;
  if FPpuRenderingRead and FWindow and Attribute then
  begin
    var X := ((FFetchX shr 3) + FRegs[$74]) and 31;
    var Y := (FFetchY + FRegs[$75]) mod 240;
    Value := ((Value shr (((Y shr 2) and 4) or (X and 2))) and 3) * $55
  end;
end;

function TMapperRainbow.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address < $3F00;
  if not Result then
    Exit;

  if Address < $2000 then
  begin
    case FRegs[$20] shr 6 of
      0:
        FlashWrite(1, ChrOffsetRainbow(Address), Value);
      1:
        FChrRam[ChrOffsetRainbow(Address) mod Length(FChrRam)] := Value;
      2:
        FFpga[Address and $FFF] := Value;
      3:
        FNames[Address and $7FF] := Value;
    end;
    Exit;
  end;

  var Nt := (Address shr 10) and 3;
  var Bank := FRegs[$26 + Nt];
  var Offset := Address and $3FF;
  case FRegs[$2A + Nt] shr 6 of
    0:
      FNames[(Bank and 1) * $400 + Offset] := Value;
    1:
      FChrRam[(Bank * $400 + Offset) mod Length(FChrRam)] := Value;
    2:
      FFpga[(Bank and 3) * $400 + Offset] := Value;
  end;
end;

procedure TMapperRainbow.ClockCpu;
begin
  ClockPulseAudio;
  FParity := not FParity;
  FJitter := (FJitter + 1) and $FF;
  if FCpuEnabled and (FCounter > 0) then
  begin
    Dec(FCounter);
    if FCounter = 0 then
    begin
      FCounter := FReload;
      if not IrqPending then
        FJitter := 0;
      FCpuPending := True
    end
  end;
  if FIdle > 0 then
  begin
    Dec(FIdle);
    if FIdle = 0 then
    begin
      FInFrame := False;
      FInHblank := False;
      FLine := -1
    end
  end;
end;

procedure TMapperRainbow.ClockScanline(Line: Integer; Rendering: Boolean);
begin
  FLine := Line;
  FInFrame := Rendering and (Line < 240);
  FReads := 0;
  FInHblank := False
end;

procedure TMapperRainbow.ClockPpuRead;
begin
  Inc(FReads);
  FIdle := 3;
  FInHblank := FReads >= 128;
  if (FLine = FRegs[$50]) and (FReads = FRegs[$53]) then
    FSlPending := True;
end;

procedure TMapperRainbow.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  FLastAddress := Address
end;

procedure TMapperRainbow.SetPpuFetchKind(Sprite: Boolean; X, Y: Integer);
begin
  FFetchSprite := Sprite;
  FFetchX := X;
  FFetchY := Y
end;

procedure TMapperRainbow.SetPpuSpriteIndex(Index: Integer);
begin
  FSpriteIndex := Index and 63
end;

procedure TMapperRainbow.CpuIoWrite(Address: UInt16; Value: UInt8);
begin
  case Address and $2007 of
    $2000:
      FSpriteHeight := 8 + Ord((Value and $20) <> 0) * 8;
    $2003:
      FOamAddress := Value;
    $2004:
      FOamAddress := (FOamAddress + 1) and $FF
  end;
end;

function TMapperRainbow.IrqPending: Boolean;
begin
  Result := (FCpuEnabled and FCpuPending) or (FSlEnabled and FSlPending)
end;

function TMapperRainbow.ExpansionAudio: Double;
begin
  if (FRegs[$A9] and 3) <> 0 then
    Result := inherited ExpansionAudio * (FRegs[$AA] and 15) / 15.0
  else
    Result := 0
end;

function TMapperRainbow.GetSaveMemory: TByteArray;
begin
  SetLength(Result, Length(FPrgRom) + Length(FChrMemory) + Length(FPrgRam));
  Move(FPrgRom[0], Result[0], Length(FPrgRom));
  Move(FChrMemory[0], Result[Length(FPrgRom)], Length(FChrMemory));
  Move(FPrgRam[0], Result[Length(FPrgRom) + Length(FChrMemory)], Length(FPrgRam));
end;

procedure TMapperRainbow.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FPrgRom) + Length(FChrMemory) + Length(FPrgRam) then
    raise ENesException.Create('Invalid Rainbow save size');

  Move(Data[0], FPrgRom[0], Length(FPrgRom));
  Move(Data[Length(FPrgRom)], FChrMemory[0], Length(FChrMemory));
  Move(Data[Length(FPrgRom) + Length(FChrMemory)], FPrgRam[0], Length(FPrgRam));
end;

function TMapperRainbow.FlashRead(Chip, Offset: Integer): Byte;
begin
  var Data := FPrgRom;
  if Chip = 1 then
    Data := FChrMemory;
  if not FFlash[Chip].SoftwareId then
    Exit(Data[Offset mod Length(Data)]);

  case Offset and $1FF of
    0:
      Result := 1;
    2:
      case Length(Data) of
        $100000:
          Result := $5B;
        $200000:
          Result := $49;
      else
        Result := $7E
      end;
    $1C:
      if Length(Data) = $400000 then
        Result := $0A
      else if Length(Data) = $800000 then
        Result := $10
      else
        Result := $FF;
    $1E:
      if Length(Data) >= $400000 then
        Result := 0
      else
        Result := $FF;
  else
    Result := $FF
  end;
end;

procedure TMapperRainbow.FlashWrite(Chip, Offset: Integer; Value: Byte);
begin
  var Data := FPrgRom;
  if Chip = 1 then
    Data := FChrMemory;
  var S := FFlash[Chip];
  var Command := Offset and $FFF;
  if S.Mode = 1 then
  begin
    Data[Offset mod Length(Data)] := Data[Offset mod Length(Data)] and Value;
    S.Mode := 0;
    S.Step := 0
  end
  else if S.Bypass then
  begin
    if (S.Step = 1) and (Value = 0) then
    begin
      S.Bypass := False;
      S.Step := 0
    end
    else if Value = $A0 then
      S.Mode := 1
    else if Value = $90 then
      S.Step := 1
    else
      S.Step := 0;
  end
  else
    case S.Step of
      0:
        if (Command = $AAA) and (Value = $AA) then
          S.Step := 1
        else if Value = $F0 then
          S.SoftwareId := False;
      1:
        if (Command = $555) and (Value = $55) then
          S.Step := 2
        else
          S.Step := 0;
      2:
        begin
          S.Step := 0;
          if Command = $AAA then
            case Value of
              $20:
                S.Bypass := True;
              $80:
                S.Step := 3;
              $90:
                S.SoftwareId := True;
              $A0:
                S.Mode := 1;
              $F0:
                S.SoftwareId := False
            end;
        end;
      3:
        if (Command = $AAA) and (Value = $AA) then
          S.Step := 4
        else
          S.Step := 0;
      4:
        if (Command = $555) and (Value = $55) then
          S.Step := 5
        else
          S.Step := 0;
      5:
        begin
          if (Command = $AAA) and (Value = $10) then
            FillChar(Data[0], Length(Data), $FF)
          else if Value = $30 then
          begin
            var Base := (Offset mod Length(Data)) and not $FFFF;
            var Size := $10000;
            if Base = Length(Data) - $10000 then
              if Length(Data) >= $400000 then
              begin
                Base := (Offset mod Length(Data)) and not $1FFF;
                Size := $2000
              end
              else
                case Offset and $FFFF of
                  0..$7FFF:
                    Size := $8000;
                  $8000..$9FFF:
                    begin
                      Inc(Base, $8000);
                      Size := $2000
                    end;
                  $A000..$BFFF:
                    begin
                      Inc(Base, $A000);
                      Size := $2000
                    end;
                else
                  begin
                    Inc(Base, $C000);
                    Size := $4000
                  end
                end;
            Size := Min(Size, Length(Data) - Base);
            FillChar(Data[Base], Size, $FF);
          end;
          S.Step := 0;
        end;
    end;
  FFlash[Chip] := S;
end;

end.

