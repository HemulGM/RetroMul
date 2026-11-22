unit NES.Mapper.OneBus;

interface

uses
  NES.APU, NES.State, NES.Types, NES.Consts, NES.Mapper, NES.Mapper.Banked,
  NES.OneBus.Vt32, NES.OneBus.Vt369Audio, NES.OneBus.Vt369Io, NES.OneBus.Senario,
  NES.Controller;

type
  TOneBusFetch = (CpuPort, Background, Sprite);

  TVt369TileRow = array[0..7] of Byte;

  TMapperOneBus = class(TMapperBanked)
  private
    type
      TAdpcm = record
        Frames: array[0..11] of UInt64;
        Phase: UInt64;
        Period: Word;
        Count, Head, SamplesInFrame: Byte;
        Latch, PreviousByte, Command, DataIndex: Byte;
        PeriodLow: Byte;
        ClockHigh: Boolean;
        Step, Predictor: SmallInt;
        Output: SmallInt;
        procedure Reset;
        procedure Transfer(Nibble: Byte; High: Boolean);
        procedure Receive(Value: Byte);
        procedure Clock(CpuFrequency: Cardinal);
        function Status: Byte;
      end;
  private
    FBoard, FSubmapper, FModel: Integer;
    FSharedRom, FOpcodeEncrypted, FHasScrambledRegisters, FH12Pro: Boolean;
    FProgramWindows: array[0..3] of Integer;
    FChrWindowMask, FChrWindowBase: Integer;
    FAdpcm: TAdpcm;
    FVt32: TVt32;
    FVt369Audio: TVt369Audio;
    FVt369Io: TVt369Io;
    FSenario: TSenarioIo;
    FRelative8K, FVt369Rom6000: Integer;
    FIrqDelay: Byte;
    FVt369DmaLow: Byte;
    FRegion: TNesRegion;
    FMmc1Registers: array[0..3] of Byte;
    FMmc1Shift, FLegacyLatch: Byte;
    FMmc1WriteCount: Integer;
    FMmc1LastWrite: UInt64;
    FMmc1HasPreviousWrite: Boolean;
    FCpuFrequency: Cardinal;
    FMainApu, FSecondApu: TApu;
    FSystem: array[0..$FF] of Byte;
    FVideo: array[0..$50] of Byte;
    FSoundControl, FChrRamControl, FA12Filter, FIrqCounter, FDmaControl: Byte;
    FIrqEnabled, FIrqPending: Boolean;
    FChrRam: array[0..$1FFF] of Byte;
    procedure UpdateProgramBanks;
    procedure SetProgramBank(Slot, Bank: Integer);
    function LegacyMode: Byte;
    procedure UpdateLegacyProgramBanks(Mask, Outer: Integer);
    function ChrBankForSlot(Slot: Integer): Integer;
    function BoardHasChrRam: Boolean;
    function ReadSharedStorage(Offset: Integer; OpenBus: Byte): Byte;
    function MappedRamIndex(Offset: Integer): Integer;
    procedure DecodeExternalBanks(out PrgMask, PrgOuter, ChrMask, ChrOuter: Integer);
    function ExternalBank: Integer;
    procedure WriteSystemRegister(Index: Byte; Value: Byte);
    procedure TickTimer(Rendering: Boolean);
    function ScanlineTimer: Boolean;
    function Vt369PackedBase(Kind: TOneBusFetch): Integer;
    function PatternIndex(Address: Word; Kind: TOneBusFetch; ExtendedAddress: Byte; HighPlanes: Boolean): Integer;
  protected
    function ShareProgramRom: Boolean; override;
  public
    constructor Create(Board, Submapper: Integer; const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
    destructor Destroy; override;
    procedure ConfigureHardware(ConsoleType: Integer; HasWorkRam: Boolean; const MiscRom: TArray<Byte> = nil; SerialEepromSize: Integer = 0; H12Pro: Boolean = False);
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    procedure ConnectAudio(Apu: TApu);
    procedure ConnectPanel(Controller: TController; Pointer: TZapper);
    property DmaControl: Byte read FDmaControl;
    property Senario: TSenarioIo read FSenario;
    function Has4KiBRam: Boolean;
    function HasVt32: Boolean; inline;
    function HasVt369: Boolean; inline;
    function HasVt369PhoneLcd: Boolean; inline;
    function HasVt389: Boolean; inline;
    function SupportsWideVideo(StateVersion: Integer = MaxInt): Boolean; inline;
    function WideVideoEnabled: Boolean; inline;
    procedure ReadVt389BackgroundRow(Tile, Attribute, Row: Integer; RightTable: Boolean; out Pixels: TVt389TileRow);
    function Vt389SpritePixel(Tile, Width, Height, Row, Column, Palette: Integer; Packed4: Boolean): Byte;
    function FirmwareMapped(Address: Word; out Value: Byte): Boolean;
    function FastCpu: Boolean; inline;
    function HalfVideoClock: Boolean; inline;
    function Vt369WidePalette: Boolean; inline;
    function Vt369VideoControl(Index: Integer): Byte; inline;
    procedure ReadVt369BackgroundRow(Tile, Attribute, Row: Integer; RightTable: Boolean; out Pixels: TVt369TileRow);
    function Vt369SpritePixel(Tile, Row, Column, Palette: Integer; RightTable: Boolean): Byte;
    function DmaSourceLow: Byte;
    procedure CommitOpcodeMode;
    function HasEnhancedVideo: Boolean;
    procedure Reset; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean; override;
    function DecodeOpcode(Value: UInt8): UInt8;
    function IsVideoRegister(Address: Word): Boolean;
    procedure WriteVideoRegister(Address: Word; Value: Byte);
    function BackgroundExtended: Boolean;
    function SpriteExtended: Boolean;
    function Background4Bpp: Boolean;
    function Sprite4Bpp: Boolean;
    function WideSprites: Boolean;
    function ExtendedPalette: Boolean;
    function BackgroundPage: Byte;
    function ReadPattern(Address: Word; Kind: TOneBusFetch; ExtendedAddress: Byte; HighPlanes: Boolean = False): Byte;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure WriteHighPattern(Address: Word; Value: Byte);
    function Controller2Input(Value: Byte): Byte;
    procedure ClockCpu; override;
    procedure ObserveVideoTimer(Address: UInt16; Rendering: Boolean);
    procedure ClockHsync(Line: Integer; Rendering: Boolean; Dot: Integer = 256);
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
  end;

implementation

uses
  NES.Mapper.Mmc1;

const
  ChrRegisterForMmc3: array[0..5] of Byte = ($16, $17, $12, $13, $14, $15);
  ChrFieldShift: array[0..7] of Byte = (0, 1, 2, 0, 3, 4, 5, 1);

procedure TMapperOneBus.TAdpcm.Reset;
begin
  Self := Default(TAdpcm);
  Period := 512;
end;

procedure TMapperOneBus.TAdpcm.Transfer(Nibble: Byte; High: Boolean);
begin
  if High = ClockHigh then
    Exit;
  ClockHigh := High;
  if High then
    Latch := Nibble shl 4
  else
    Receive(Latch or Nibble);
end;

procedure TMapperOneBus.TAdpcm.Receive(Value: Byte);
begin
  if (PreviousByte = $55) and (Value = $AA) then
  begin
    Reset;
    Exit;
  end;
  PreviousByte := Value;
  case Command of
    $03:
      begin
        if DataIndex = 0 then
        begin
          PeriodLow := Value;
          DataIndex := 1;
        end
        else
        begin
          Period := PeriodLow or (Word(Value) shl 8);
          Phase := 0;
          Command := 0;
        end;
        Exit;
      end;
    $04, $06:
      begin
        var Tail := (Head + Count) mod Length(Frames);
        var ByteIndex := DataIndex and 7;
        if ByteIndex = 0 then
          Frames[Tail] := 0;
        Frames[Tail] := Frames[Tail] or (UInt64(Value) shl (ByteIndex * 8));
        Inc(DataIndex);
        if ByteIndex = 7 then
          Inc(Count);
        if (Command = $04) and (DataIndex = 96) then
          Command := 0
        else if Command = $06 then
        begin
          DataIndex := DataIndex and 7;
          if Count = Length(Frames) then
            Command := 0;
        end;
        Exit;
      end;
  end;
  case Value of
    $03:
      begin
        DataIndex := 0;
        Command := Value;
      end;
    $04, $07:
      begin
        Count := 0;
        Head := 0;
        SamplesInFrame := 0;
        DataIndex := 0;
        Predictor := 0;
        Step := 0;
        Output := 0;
        Phase := 0;
        if Value = $04 then
          Command := Value;
      end;
    $06:
      if Count < Length(Frames) then
      begin
        DataIndex := 0;
        Command := Value;
      end;
  end;
end;

procedure TMapperOneBus.TAdpcm.Clock(CpuFrequency: Cardinal);
const
  StepAdjustment: array[0..3] of Integer = (-1, -1, 2, 4);
  StepMagnitude: array[0..3, 0..20] of Byte = (
    (0, 1, 1, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5, 5, 6, 7, 8, 10, 11, 13, 15),
    (1, 3, 3, 3, 4, 4, 6, 6, 7, 9, 10, 12, 15, 16, 19, 22, 25, 30, 34, 40, 46),
    (3, 5, 5, 6, 7, 8, 10, 11, 13, 16, 18, 21, 25, 28, 32, 38, 43, 51, 58, 68, 78),
    (4, 7, 7, 8, 10, 11, 14, 15, 18, 22, 25, 29, 35, 39, 45, 53, 60, 71, 81, 95, 109));
begin
  if (Count = 0) or (Period = 0) then
    Exit;
  // NTSC CPU and decoder clocks have the exact ratio 7:16.
  // For other timings the decoder still runs from its own 45/11 MHz oscillator.
  var SamplePeriod: UInt64;
  if CpuFrequency = NES_CPU_HZ then
  begin
    Inc(Phase, 16);
    SamplePeriod := Period * 7;
  end
  else
  begin
    Inc(Phase, 45000000);
    SamplePeriod := UInt64(Period) * CpuFrequency * 11;
  end;
  while (Phase >= SamplePeriod) and (Count <> 0) do
  begin
    Dec(Phase, SamplePeriod);
    var Frame := Frames[Head];
    if (Frame shr 63) <> 0 then
      Output := 0
    else
    begin
      var Code := Integer((Frame shr (SamplesInFrame * 3)) and 7);
      var Next := Predictor + StepMagnitude[Code and 3, Step] * (1 - 2 * (Code shr 2));
      if Next > 127 then
        Next := 127
      else if Next < -128 then
        Next := -128;
      Predictor := Next;
      Output := Next;
      Next := Step + StepAdjustment[Code and 3];
      if Next < 0 then
        Next := 0
      else if Next > 20 then
        Next := 20;
      Step := Next;
    end;
    Inc(SamplesInFrame);
    if SamplesInFrame = 21 then
    begin
      SamplesInFrame := 0;
      Head := (Head + 1) mod Length(Frames);
      Dec(Count);
    end;
  end;
end;

function TMapperOneBus.TAdpcm.Status: Byte;
begin
  Result := (Ord(not ClockHigh) shl 3) or (Ord(Count < Length(Frames)) shl 4);
end;

constructor TMapperOneBus.Create(Board, Submapper: Integer; const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, False, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  FSharedRom := Length(Chr) = 0;
  FHasScrambledRegisters := (Board = MAPPER_ONEBUS) or (Board = MAPPER_TAIKEE_ADPCM);
  if FBoard = MAPPER_WIN_LOSE_OR_DRAW then
  begin
    SetLength(FPrgRam, $10000);
    FSenario := TSenarioIo.Create;
    FSenario.SetCpuFrequency(NES_CPU_HZ);
  end;
  FModel := 7;
  if FBoard = MAPPER_VT32 then
    FModel := 9;
  FCpuFrequency := NES_CPU_HZ;
  FSecondApu := TApu.Create;
  Reset;
end;

function TMapperOneBus.ShareProgramRom: Boolean;
begin
  // OneBus maps writes to separate RAM, never the loaded ROM array.
  Result := True;
end;

destructor TMapperOneBus.Destroy;
begin
  FSenario.Free;
  FVt369Io.Free;
  FVt369Audio.Free;
  FSecondApu.Free;
  inherited;
end;

procedure TMapperOneBus.ConfigureHardware(ConsoleType: Integer; HasWorkRam: Boolean; const MiscRom: TArray<Byte>; SerialEepromSize: Integer; H12Pro: Boolean);
begin
  FH12Pro := H12Pro;
  // NES 2.0 type 0 is used by earlier dumps with no SoC identifier.
  if ConsoleType <> 0 then
    FModel := ConsoleType;
  if HasVt369 and (FVt369Audio = nil) then
  begin
    var FirmwareSize := 0;
    if Length(MiscRom) >= $1000 then
      FirmwareSize := $1000;
    FVt369Audio := TVt369Audio.Create(FPrgRom, Copy(MiscRom, 0, FirmwareSize));
    case FBoard of
      MAPPER_VT369_SERIAL_ROM:
        begin
          var Parameters, SerialRom: TArray<Byte>;
          var SerialSize := Length(MiscRom) - FirmwareSize;
          if (SerialSize = $100) or (SerialSize = $200) then
            SerialRom := Copy(MiscRom, FirmwareSize, $100);
          // The 426.3 image appends the parameter table after the serial code.
          if SerialSize = $200 then
            Parameters := Copy(MiscRom, FirmwareSize + $100, $100);
          FVt369Io := TVt369Io.Create(SerialRom, Parameters, -1, 0, FSubmapper = 3);
        end;
      MAPPER_VT369_INVERTER_ROM:
        FVt369Io := TVt369Io.Create(nil, nil, FSubmapper, SerialEepromSize);
      MAPPER_VT389:
        begin
          FVt369Io := TVt369Io.Create(nil, nil, -1, 0, False, True);
          FVt369Audio.ConnectPanelIo(FVt369Io);
        end;
    end;
  end;
  if not HasWorkRam and (FBoard <> MAPPER_WIN_LOSE_OR_DRAW) then
    SetLength(FPrgRam, 0);
end;

function TMapperOneBus.GetSaveMemory: TByteArray;
begin
  if (FVt369Io <> nil) and FVt369Io.HasSave then
    Exit(FVt369Io.GetSaveMemory);
  Result := inherited GetSaveMemory;
end;

procedure TMapperOneBus.SetSaveMemory(const Data: TByteArray);
begin
  if (FVt369Io <> nil) and FVt369Io.HasSave then
    FVt369Io.SetSaveMemory(Data)
  else
    inherited SetSaveMemory(Data);
end;

procedure TMapperOneBus.ConnectAudio(Apu: TApu);
begin
  FMainApu := Apu;
  FMainApu.SetOneBusDmcMode(FSoundControl);
end;

procedure TMapperOneBus.ConnectPanel(Controller: TController; Pointer: TZapper);
begin
  if FSenario <> nil then
    FSenario.ConnectPointer(Pointer);
  if (FBoard = MAPPER_VT389) and (FVt369Io <> nil) then
    FVt369Io.ConnectPanel(Controller, Pointer);
end;

function TMapperOneBus.Has4KiBRam: Boolean;
begin
  Result := FModel in [8..10];
end;

function TMapperOneBus.HasVt32: Boolean;
begin
  Result := FModel = 9;
end;

function TMapperOneBus.HasVt369: Boolean;
begin
  Result := FModel = 10;
end;

function TMapperOneBus.HasVt369PhoneLcd: Boolean;
begin
  Result := HasVt369 and (FBoard = MAPPER_VT369_SERIAL_ROM) and (FSubmapper = 3);
end;

function TMapperOneBus.HasVt389: Boolean;
begin
  Result := FBoard = MAPPER_VT389;
end;

function TMapperOneBus.SupportsWideVideo(StateVersion: Integer): Boolean;
begin
  case FBoard of
    MAPPER_VT389:
      Result := True;
    MAPPER_VT369_411E:
      Result := StateVersion >= 29;
    MAPPER_VT369_4150:
      Result := StateVersion >= 30;
  else
    Result := False;
  end;
end;

function TMapperOneBus.WideVideoEnabled: Boolean;
begin
  Result := Vt369WidePalette and ((FVideo[$1C] and 4) <> 0);
end;

function TMapperOneBus.FirmwareMapped(Address: Word; out Value: Byte): Boolean;
begin
  Result := (FVt369Audio <> nil) and (Address >= $1000) and (Address < $2000) and
    FVt369Audio.ReadFirmware(Address, Value);
end;

function TMapperOneBus.FastCpu: Boolean;
begin
  Result := (FSystem[$1C] and $80) <> 0;
end;

function TMapperOneBus.HalfVideoClock: Boolean;
begin
  Result := (FSystem[$1F] and 1) <> 0;
end;

function TMapperOneBus.Vt369WidePalette: Boolean;
begin
  Result := HasVt369 and ((FVideo[$1E] and 8) <> 0);
end;

function TMapperOneBus.Vt369VideoControl(Index: Integer): Byte;
begin
  Result := FVideo[Index];
end;

function TMapperOneBus.Vt369PackedBase(Kind: TOneBusFetch): Integer;
begin
  var Reg := $20 + 2 * Ord(Kind = TOneBusFetch.Sprite);
  Result := ((((Integer(FVideo[Reg + 1]) shl 8) or FVideo[Reg]) + FRelative8K) and
    (FChrWindowMask shr 3)) or (FChrWindowBase shr 3);
  Result := Result shl 13;
end;

procedure TMapperOneBus.ReadVt369BackgroundRow(Tile, Attribute, Row: Integer; RightTable: Boolean; out Pixels: TVt369TileRow);
begin
  var Mode := FVideo[$1C] and 3;
  var SmallBanks := (FVideo[$1C] and 8) <> 0;
  var Offset := (Tile shl 4) or (Row shl 1);
  if not SmallBanks then
    Offset := Offset or (Attribute shl 12);
  Offset := Offset shl Mode;
  if (FVideo[$1E] and 1) <> 0 then
    Inc(Offset, Vt369PackedBase(TOneBusFetch.Background))
  else
  begin
    var Bank := Attribute shr 1;
    var Reg := $16 - 4 * Ord(RightTable) + Bank;
    Inc(Offset, Integer(FVt369Audio.RelativeBase) + ((Integer(FVideo[Reg and $1F]) - Bank) shl
      (13 - 3 * Ord(SmallBanks) + Mode)));
  end;
  var Size := Length(FPrgRom);
  var ByteCount := 4 shl Ord(Mode = 2);
  var First := Integer(Cardinal(Offset) mod Cardinal(Size));
  if (Offset >= 0) and (First <= Size - ByteCount) and (FBoard <> MAPPER_WIN_LOSE_OR_DRAW) then
    Move(FPrgRom[First], Pixels[0], ByteCount)
  else
    for var Index := 0 to ByteCount - 1 do
      Pixels[Index] := ReadSharedStorage(Cardinal(Offset + Index) mod Cardinal(Size), 0);

  if Mode <> 2 then
    for var Pair := 3 downto 0 do
    begin
      var PackedPixels := Pixels[Pair];
      Pixels[2 * Pair] := PackedPixels and $0F;
      Pixels[2 * Pair + 1] := PackedPixels shr 4;
    end;
end;

function TMapperOneBus.Vt369SpritePixel(Tile, Row, Column, Palette: Integer; RightTable: Boolean): Byte;
begin
  var Tall := (FVideo[$1D] and 4) <> 0;
  var Wide := (FVideo[$1D] and 2) <> 0;
  var Packed4 := Wide or (not Tall and ((FVideo[$1C] and $20) = 0));
  var Offset := (Tile shl (6 + Ord(Tall))) + (Row shl 3);
  if Packed4 and not Wide then
    Offset := Offset shr 1;
  if (FVideo[$1E] and 1) <> 0 then
    Inc(Offset, Vt369PackedBase(TOneBusFetch.Sprite))
  else
    Inc(Offset, Integer(FVt369Audio.RelativeBase) + (Integer(FVideo[$16 - 4 * Ord(RightTable)]) shl
      (13 - 3 * Ord((FVideo[$1C] and $80) <> 0) + ((FVideo[$1C] shr 4) and 3))));
  if not Packed4 then
    Exit(ReadSharedStorage(Offset + Column, 0));
  Result := (ReadSharedStorage(Offset + (Column shr 1), 0) shr ((Column and 1) * 4)) and 15;
  if Result <> 0 then
    Result := Result or Palette;
end;

procedure TMapperOneBus.ReadVt389BackgroundRow(Tile, Attribute, Row: Integer; RightTable: Boolean; out Pixels: TVt389TileRow);
begin
  var Mode := FVideo[$1C] and 3;
  var SmallBanks := (FVideo[$1C] and 8) <> 0;
  var Interleaved := (FVideo[$50] and 1) <> 0;
  var Offset := (Tile shl 4) or (Row shl 1);
  if Interleaved then
    Offset := Offset or ((Attribute and $0F) shl 12)
  else if not SmallBanks then
    Offset := Offset or (Attribute shl 12);
  Offset := Offset shl (Mode + 2);
  if (FVideo[$1E] and 1) <> 0 then
    Inc(Offset, Vt369PackedBase(TOneBusFetch.Background))
  else
    Inc(Offset, Integer(FVt369Audio.RelativeBase) + (Integer(FVideo[$16 - 4 * Ord(RightTable)]) shl
      (13 - 3 * Ord(SmallBanks) + Mode)));
  var Size := Length(FPrgRom);
  Offset := Offset mod Size;
  if (Mode = 2) or Interleaved then
  begin
    if Offset <= Size - SizeOf(Pixels) then
      Move(FPrgRom[Offset], Pixels, SizeOf(Pixels))
    else
      for var X := 0 to High(Pixels) do
        Pixels[X] := FPrgRom[(Offset + X) mod Size];
  end
  else
    for var Pair := 0 to (Length(Pixels) div 2) - 1 do
    begin
      var PackedPixels := FPrgRom[(Offset + Pair) mod Size];
      Pixels[2 * Pair] := PackedPixels and $0F;
      Pixels[2 * Pair + 1] := PackedPixels shr 4;
    end;
end;

function TMapperOneBus.Vt389SpritePixel(Tile, Width, Height, Row, Column, Palette: Integer; Packed4: Boolean): Byte;
begin
  var Index := (Tile * Height + Row) * Width + Column;
  var Offset := Vt369PackedBase(TOneBusFetch.Sprite) + (Index shr Ord(Packed4));
  Result := ReadSharedStorage(Offset, 0);
  if Packed4 then
  begin
    Result := (Result shr ((Index and 1) * 4)) and $0F;
    if Result <> 0 then
      Result := Result or Palette;
  end;
end;

function TMapperOneBus.DmaSourceLow: Byte;
begin
  if HasVt369 then
    Result := FVt369DmaLow
  else
    Result := FDmaControl and $F0;
end;

procedure TMapperOneBus.CommitOpcodeMode;
begin
  FVt32.CommitOpcodeMode;
end;

function TMapperOneBus.HasEnhancedVideo: Boolean;
begin
  Result := FModel >= 7;
end;

procedure TMapperOneBus.SetRegion(Region: TNesRegion);
begin
  FSecondApu.SetRegion(Region);
  FCpuFrequency := CpuFrequency(Region);
  if FVt369Io <> nil then
    FVt369Io.SetCpuFrequency(FCpuFrequency);
  if FSenario <> nil then
    FSenario.SetCpuFrequency(FCpuFrequency);
  FRegion := Region;
end;

procedure TMapperOneBus.Reset;
begin
  inherited;
  FRamEnabled := (Length(FPrgRam) <> 0) and (FBoard <> MAPPER_WIN_LOSE_OR_DRAW);
  FillChar(FSystem, SizeOf(FSystem), 0);
  FillChar(FVideo, SizeOf(FVideo), 0);
  FSystem[$08] := 1;
  FSystem[$09] := $FE;
  FSystem[$0F] := $FF;
  FVideo[$12] := 4;
  FVideo[$13] := 5;
  FVideo[$14] := 6;
  FVideo[$15] := 7;
  FVideo[$17] := 2;
  FChrRamControl := 0;
  FSoundControl := 0;
  FDmaControl := 0;
  FIrqCounter := 0;
  FA12Filter := 0;
  FIrqEnabled := False;
  FIrqPending := False;
  FIrqDelay := 0;
  FVt369DmaLow := 0;
  FRelative8K := 0;
  if FVt369Audio <> nil then
    FVt369Audio.Reset;
  if FVt369Io <> nil then
    FVt369Io.Reset;
  if FSenario <> nil then
    FSenario.Reset;
  FOpcodeEncrypted := ((FBoard = MAPPER_ONEBUS) or (FBoard = MAPPER_WIN_LOSE_OR_DRAW) or
    (FBoard = MAPPER_ARCADE_ADVANCED) or (FBoard = MAPPER_TAIKEE_ADPCM) or HasVt369) and (FSubmapper >= 10);
  if FBoard = MAPPER_TAIKEE_ADPCM then
    FAdpcm.Reset;
  if FOpcodeEncrypted and (FSubmapper = 11) then
    FSystem[$1C] := 2;
  FSecondApu.Reset;
  FVt32.Reset;
  FillChar(FMmc1Registers, SizeOf(FMmc1Registers), 0);
  FMmc1Registers[0] := $0C;
  FMmc1Shift := $10;
  FMmc1WriteCount := 0;
  FMmc1LastWrite := 0;
  FMmc1HasPreviousWrite := False;
  FLegacyLatch := 0;
  UpdateProgramBanks;
end;

procedure TMapperOneBus.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FSystem, SizeOf(FSystem));
  State.Field(FVideo, $20);
  if HasVt369 then
    State.Field(FVideo[$20], SizeOf(FVideo) - $20);
  State.Field(FOpcodeEncrypted, SizeOf(FOpcodeEncrypted));
  State.Field(FSoundControl, SizeOf(FSoundControl));
  State.Field(FDmaControl, SizeOf(FDmaControl));
  if FMainApu <> nil then
  begin
    FMainApu.SerializeOneBusPcm(State);
    if State.Loading then
      FMainApu.SetOneBusDmcMode(FSoundControl);
  end
  else
  begin
    var Pcm: Byte := $80;
    State.Field(Pcm, SizeOf(Pcm));
  end;
  State.Field(FChrRamControl, SizeOf(FChrRamControl));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  State.Field(FA12Filter, SizeOf(FA12Filter));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqPending, SizeOf(FIrqPending));
  if (FBoard = MAPPER_VT42XX) or (FBoard = MAPPER_ARCADE_ADVANCED) then
    State.Field(FChrRam, SizeOf(FChrRam));
  if FBoard = MAPPER_TAIKEE_ADPCM then
  begin
    State.Field(FAdpcm, SizeOf(FAdpcm));
    if State.Loading and ((FAdpcm.Count > Length(FAdpcm.Frames)) or
      (FAdpcm.Head > High(FAdpcm.Frames)) or (FAdpcm.SamplesInFrame >= 21) or
      (FAdpcm.Step < 0) or (FAdpcm.Step > 20)) then
      raise ENesException.Create('Invalid OneBus ADPCM state');
  end;
  if HasVt32 then
    FVt32.SerializeState(State)
  else if HasVt369 then
  begin
    FVt369Audio.SerializeState(State);
    FVt32.SerializeState(State);
    State.Field(FIrqDelay, SizeOf(FIrqDelay));
    State.Field(FVt369DmaLow, SizeOf(FVt369DmaLow));
    if FVt369Io <> nil then
      FVt369Io.SerializeState(State);
  end
  else
    FSecondApu.SerializeState(State);
  if FSenario <> nil then
    if State.Version >= 28 then
      FSenario.SerializeState(State)
    else if State.Loading then
      FSenario.Reset;
  if FBoard = MAPPER_VT32 then
  begin
    State.Field(FChrRam, SizeOf(FChrRam));
    State.Field(FMmc1Registers, SizeOf(FMmc1Registers));
    State.Field(FMmc1Shift, SizeOf(FMmc1Shift));
    State.Field(FMmc1WriteCount, SizeOf(FMmc1WriteCount));
    State.Field(FMmc1LastWrite, SizeOf(FMmc1LastWrite));
    State.Field(FMmc1HasPreviousWrite, SizeOf(FMmc1HasPreviousWrite));
    State.Field(FLegacyLatch, SizeOf(FLegacyLatch));
    if State.Loading and ((FMmc1WriteCount < 0) or (FMmc1WriteCount > 4)) then
      raise ENesException.Create('Invalid VT32 serial mapper state');
  end;
  if State.Loading then
    UpdateProgramBanks;
end;

function TMapperOneBus.ExternalBank: Integer;
begin
  Result := 0;
  if FBoard <> MAPPER_VT42XX then
    Exit;
  var Control := FSystem[$2C];
  case FSubmapper of
    1:
      Result := $800 * Ord((Control and 2) <> 0);
    2:
      Result := $800 * Ord((Control and 2) <> 0) or ((Control and 1) shl 12);
    3:
      Result := $800 * Ord((Control and 4) <> 0);
  else
    Result := $800 * Ord((Control and 6) <> 0) or ((Control and 1) shl 12);
  end;
end;

procedure TMapperOneBus.DecodeExternalBanks(out PrgMask, PrgOuter, ChrMask, ChrOuter: Integer);
begin
  PrgMask := $FFF;
  PrgOuter := 0;
  ChrMask := $7FFF;
  ChrOuter := 0;
  case FBoard of
    MAPPER_VT389:
      begin
        PrgMask := $7FF;
        ChrMask := $3FFF;
        PrgOuter := Integer(FSystem[$42]) shl 11;
        ChrOuter := PrgOuter shl 3;
      end;
    MAPPER_VT369_4150:
      PrgOuter := Integer(FSystem[$50] and 7) shl 12;
    MAPPER_VT369_411E:
      PrgOuter := Integer(FSystem[$1E] and 7) shl 12;
    MAPPER_VT369_41E6:
      PrgOuter := Integer(FSystem[$E6] and 3) shl 12;
    MAPPER_ARCADE_ADVANCED:
      if FH12Pro then
      begin
        // GPIO bit 1 drives A24 of the common PRG and CHR ROM.
        PrgMask := $7FF;
        ChrMask := $3FFF;
        PrgOuter := Integer(FSystem[$38] and FSystem[$39] and 2) shl 10;
        ChrOuter := PrgOuter shl 3;
      end;
    MAPPER_VT42XX:
      begin
        PrgMask := $7FF;
        PrgOuter := ExternalBank;
        ChrMask := $3FFF;
        ChrOuter := PrgOuter shl 3;
      end;
    MAPPER_VT32:
      begin
        PrgOuter := ((FSystem[$2C] and 1) shl 12) or ((FSystem[$2C] and 4) shl 11) or
          ((FSystem[$2E] and 1) shl 14);
        ChrOuter := ((FSystem[$2C] and 2) shl 14) or ((FSystem[$2C] and 8) shl 13) or
          ((FSystem[$2E] and 1) shl 17);
      end;
    MAPPER_ZLX08:
      begin
        if FSubmapper = 1 then
        begin
          PrgMask := $F7FF;
          PrgOuter := Ord((FSystem[$1C] and 5) = 1) shl 11;
          ChrMask := $BFFF;
        end
        else
        begin
          PrgMask := $F3FF;
          PrgOuter := ((FSystem[$0F] and $20) shl 5) or ((FSystem[0] and $40) shl 5);
          ChrMask := $9FFF;
        end;
        ChrOuter := PrgOuter shl 3;
      end;
  end;
  case FBoard of
    MAPPER_VT369_4150, MAPPER_VT369_411E, MAPPER_VT369_41E6:
      ChrOuter := PrgOuter shl 3;
  end;
end;

procedure TMapperOneBus.SetProgramBank(Slot, Bank: Integer);
begin
  FProgramWindows[Slot] := Bank shl 13;
  Prg8(Slot, Bank);
end;

function TMapperOneBus.LegacyMode: Byte;
begin
  if FBoard = MAPPER_VT32 then
    Result := FSystem[$1D] and 3
  else
    Result := 0;
end;

procedure TMapperOneBus.UpdateLegacyProgramBanks(Mask, Outer: Integer);
begin
  var Bank0, Bank1: Integer;
  if LegacyMode = 2 then
  begin
    Bank0 := FLegacyLatch;
    Bank1 := $FF;
    Mirror(FSystem[6] and 1);
  end
  else
  begin
    var Control := FMmc1Registers[0];
    var Bank := FMmc1Registers[3];
    case (Control shr 2) and 3 of
      0, 1:
        begin
          Bank0 := Bank and $0E;
          Bank1 := Bank0 + 1;
        end;
      2:
        begin
          Bank0 := 0;
          Bank1 := Bank and $0F;
        end;
    else
      Bank0 := Bank and $0F;
      Bank1 := $0F;
    end;
    if (Bank and $10) <> 0 then
    begin
      // MMC1A fixes bit 3 to the PRG register when its high bit is set.
      Bank0 := (Bank0 and 7) or (Bank and 8);
      Bank1 := (Bank1 and 7) or (Bank and 8);
    end;
    Mirror((Control and 3) xor 2);
  end;
  for var Index := 0 to 1 do
  begin
    SetProgramBank(Index, ((Bank0 * 2 + Index) and Mask) or Outer);
    SetProgramBank(Index + 2, ((Bank1 * 2 + Index) and Mask) or Outer);
  end;
end;

procedure TMapperOneBus.UpdateProgramBanks;
begin
  var Mask := $3F shr (FSystem[$0B] and 7);
  if (FSystem[$0B] and 7) = 7 then
    Mask := $FF;
  var Outer := ((Integer(FSystem[0] and $F0) shl 4) or FSystem[$0A]) and not Mask;
  var WindowMask, external: Integer;
  DecodeExternalBanks(WindowMask, external, FChrWindowMask, FChrWindowBase);
  if LegacyMode in [1, 2] then
  begin
    UpdateLegacyProgramBanks(Mask and WindowMask, (Outer and WindowMask) or external);
    Exit;
  end;
  var Swap := (FSystem[5] and $40) shr 5;
  var ThirdBank := $FE;
  if (FSystem[$0B] and $40) <> 0 then
    ThirdBank := FSystem[9];
  if FVt369Audio <> nil then
  begin
    FRelative8K := FSystem[$60] or ((FSystem[$61] and 15) shl 8);
    FVt369Audio.RelativeBase := Cardinal((FRelative8K and WindowMask) or external) shl 13;
    FVt369Rom6000 := ((((Outer or (FSystem[$12] and Mask)) + FRelative8K) and WindowMask) or external) shl 13;
  end;
  SetProgramBank(Swap, (((Outer or (FSystem[7] and Mask)) + FRelative8K) and WindowMask) or external);
  SetProgramBank(1, (((Outer or (FSystem[8] and Mask)) + FRelative8K) and WindowMask) or external);
  SetProgramBank(Swap xor 2, (((Outer or (ThirdBank and Mask)) + FRelative8K) and WindowMask) or external);
  SetProgramBank(3, (((Outer or Mask) + FRelative8K) and WindowMask) or external);
  Mirror(FSystem[6] and 1);
end;

procedure TMapperOneBus.WriteSystemRegister(Index: Byte; Value: Byte);
begin
  FSystem[Index] := Value;
  if HasVt32 or (HasVt369 and (Index in [$19, $30..$3D])) then
    FVt32.WriteRegister($4100 or Index, Value, 0);
  if (Index = $62) and (FVt369Audio <> nil) then
    FVt369Audio.Control(Value);
  case Index of
    2:
      FIrqCounter := 0;
    3:
      begin
        FIrqEnabled := False;
        FIrqPending := False;
        FIrqDelay := 0;
      end;
    4:
      FIrqEnabled := True;
    $1C:
      if FOpcodeEncrypted or (FBoard = MAPPER_ONEBUS) or (FBoard = MAPPER_ARCADE_ADVANCED) or
        (FBoard = MAPPER_TAIKEE_ADPCM) then
        case FSubmapper of
          10:
            FOpcodeEncrypted := (Value and 2) <> 0;
          12, 14:
            FOpcodeEncrypted := (Value and $40) <> 0;
        end;
    $69:
      if (FSubmapper in [13, 15]) and ((FBoard = MAPPER_ONEBUS) or (FBoard = MAPPER_WIN_LOSE_OR_DRAW) or
        (FBoard = MAPPER_ARCADE_ADVANCED) or (FBoard = MAPPER_TAIKEE_ADPCM) or HasVt369) then
        FOpcodeEncrypted := (Value and 1) = 0;
  end;
  if (Index in [0, 5..$0B]) or (HasVt369 and (Index in [$12, $1C, $1E, $50, $60, $61, $E6])) or ((Index = $2C) and (FBoard = MAPPER_VT42XX)) or
    (FH12Pro and (Index in [$38, $39])) or
    ((Index in [$0F, $1C]) and (FBoard = MAPPER_ZLX08)) or
    ((Index in [$1D, $2C, $2E]) and (FBoard = MAPPER_VT32)) then
    UpdateProgramBanks;
end;

function TMapperOneBus.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FVt369Io <> nil) and FVt369Io.Read(Address, Value) then
    Exit(True);
  if (HasVt32 or (HasVt369 and (Address >= $4130) and (Address <= $413D))) and
    FVt32.ReadRegister(Address, Value) then
    Exit(True);
  if FVt369Audio <> nil then
  begin
    if FirmwareMapped(Address, Value) then
      Exit(True);
    case Address of
      $4800..$4FFF:
        begin
          Value := FVt369Audio.ReadShared(Address);
          Exit(True);
        end;
      $6000..$7FFF:
        if (FSystem[$1C] and $40) <> 0 then
        begin
          Value := ReadSharedStorage(FVt369Rom6000 or (Address and $1FFF), FCpuOpenBus);
          Exit(True);
        end;
    end;
  end;
  if (FBoard = MAPPER_WIN_LOSE_OR_DRAW) and (Address >= $8000) then
  begin
    var Offset := FProgramWindows[(Address - $8000) shr 13] or (Address and $1FFF);
    Value := ReadSharedStorage(Offset, FCpuOpenBus);
    Exit(True);
  end;
  case Address of
    $412D:
      if FBoard = MAPPER_VT32 then
        Value := 3
      else
        Exit(inherited CpuRead(Address, Value));
    $4035:
      if HasVt32 or HasVt369 then
        Exit(False)
      else
        Value := FSecondApu.DebugStatus and $0F;
    $415C:
      // Power-up input level on boards without an attached serial peripheral.
      if HasVt369 then
        Value := $10
      else
        Exit(inherited CpuRead(Address, Value));
    $418A, $4199, $41B7, $41B9:
      if HasVt369 then
        case Address of
          $418A, $41B7:
            Value := 4;
          $4199:
            Value := 2;
        else
          Value := $80;
        end
      else
        Value := FSystem[Address and $FF];
    $4119:
      if HasVt369 then
        Value := $80 or Byte(Ord(FRegion = TNesRegion.PAL))
      else
        Exit(inherited CpuRead(Address, Value));
    $411F, $4144..$415B:
      if HasVt369 then
        Value := FSystem[Address and $FF]
      else
        Exit(inherited CpuRead(Address, Value));
    $410E, $410F:
      if FSenario <> nil then
        Exit(FSenario.Read(Address, Value))
      else
        Exit(inherited CpuRead(Address, Value));
    $4100..$410D, $4160..$4189, $418B..$4198, $419A..$41B6, $41B8, $41BA..$41FF:
      Value := FSystem[Address and $FF];
    $4138, $4139:
      if not FH12Pro then
        Exit(inherited CpuRead(Address, Value))
      else if Address = $4138 then
        Value := FSystem[$38]
      else
        Value := (FSystem[$39] and FSystem[$38]) or (FSystem[$38] xor $FF);
    $412C:
      if FBoard = MAPPER_VT42XX then
        Value := 0
      else
        Value := FCpuOpenBus;
  else
    Exit(inherited CpuRead(Address, Value));
  end;
  Result := True;
end;

function TMapperOneBus.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := CpuRead(Address, Value);
end;

function TMapperOneBus.CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean;
begin
  if (Address >= $8000) and (LegacyMode = 1) then
  begin
    if FMmc1HasPreviousWrite and (CpuCycle > FMmc1LastWrite) and (CpuCycle - FMmc1LastWrite = 1) then
      Exit(True);
    FMmc1HasPreviousWrite := True;
    FMmc1LastWrite := CpuCycle;
  end;
  Result := CpuWrite(Address, Value);
end;

function TMapperOneBus.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FVt369Io <> nil) and FVt369Io.Write(Address, Value) then
  begin
    if (FBoard = MAPPER_VT389) and (Address = $4142) then
    begin
      FSystem[$42] := Value;
      UpdateProgramBanks;
    end;
    Exit(True);
  end;
  if FVt369Audio <> nil then
    case Address of
      $4010..$4013:
        Exit(Vt369WidePalette);
      $4015:
        if Vt369WidePalette and (FMainApu <> nil) then
        begin
          FMainApu.CpuWrite(Address, Value and $EF);
          Exit(True);
        end;
      $4020..$4033, $4035..$403F:
        begin
          if Address = $4024 then
            FVt369DmaLow := Value;
          Exit(True);
        end;
      $4800..$4FFF:
        begin
          FVt369Audio.WriteShared(Address, Value);
          Exit(True);
        end;
      $6000..$7FFF:
        if (FSystem[$1C] and $40) <> 0 then
          Exit(True);
    end;
  if HasVt32 and (Address < $4100) then
  begin
    var AudioBank: Cardinal := 0;
    if FBoard = MAPPER_VT32 then
      AudioBank := Cardinal(FSystem[$2C] and 1) shl 25;
    if FVt32.WriteRegister(Address, Value, AudioBank) then
      Exit(True);
    if (Address >= $4020) and (Address <= $4039) and (Address <> $4034) then
      Exit(False);
  end;
  if Address >= $8000 then
    case LegacyMode of
      1:
        begin
          if (Value and $80) <> 0 then
          begin
            FMmc1Registers[0] := FMmc1Registers[0] or $0C;
            FMmc1WriteCount := 0;
            FMmc1Shift := $10;
            UpdateProgramBanks;
          end
          else if ShiftMmc1Register(Value, FMmc1Shift, FMmc1WriteCount) then
          begin
            FMmc1Registers[(Address shr 13) and 3] := FMmc1Shift and $1F;
            FMmc1WriteCount := 0;
            FMmc1Shift := $10;
            UpdateProgramBanks;
          end;
          Exit(True);
        end;
      2, 3:
        begin
          FLegacyLatch := Value;
          UpdateProgramBanks;
          Exit(True);
        end;
    end;
  if (FBoard = MAPPER_WIN_LOSE_OR_DRAW) and (Address >= $8000) then
  begin
    var Index := MappedRamIndex(FProgramWindows[(Address - $8000) shr 13] or (Address and $1FFF));
    if Index >= 0 then
      FPrgRam[Index] := Value;
  end;
  case Address of
    $4016:
      begin
        if FSenario <> nil then
          Exit(FSenario.Write(Address, Value));
        if FBoard <> MAPPER_TAIKEE_ADPCM then
          Exit(inherited CpuWrite(Address, Value));
        if (FSystem[$0D] and $30) = $30 then
          FAdpcm.Transfer(FSystem[$0F] and $0F, (Value and 4) <> 0);
      end;
    $4020..$402F:
      begin
        FSecondApu.CpuWrite(Address - $20, Value);
        FSoundControl := FSoundControl or 8;
      end;
    $4030:
      begin
        FSoundControl := Value;
        if FMainApu <> nil then
          FMainApu.SetOneBusDmcMode(Value);
      end;
    $4031:
      if FMainApu <> nil then
        FMainApu.WriteOneBusPcm(Value);
    $4034:
      FDmaControl := Value;
    $4035:
      FSecondApu.CpuWrite($4015, Value and $0F);
    $4100..$41FF:
      begin
        if (Address >= $410D) and (Address <= $410F) and (FSenario <> nil) then
          Exit(FSenario.Write(Address, Value));
        var Index := Address and $FF;
        if FHasScrambledRegisters and (FSubmapper = 2) and (Index in [7, 8]) then
          Index := 15 - Index;
        WriteSystemRegister(Index, Value);
      end;
    $4242:
      if FBoard = MAPPER_VT42XX then
        FChrRamControl := Value;
    $8000..$FFFF:
      if (FSystem[$0B] and 8) = 0 then
        case Address and $E001 of
          $8000:
            begin
              var RegisterIndex := Value and 7;
              if FHasScrambledRegisters then
                case FSubmapper of
                  1:
                    if RegisterIndex < 6 then
                      RegisterIndex := 5 - RegisterIndex;
                  2:
                    if RegisterIndex >= 6 then
                      RegisterIndex := RegisterIndex xor 1;
                end;
              WriteSystemRegister(5, (Value and $D8) or RegisterIndex);
            end;
          $8001:
            begin
              var RegisterIndex := FSystem[5] and 7;
              if RegisterIndex < 6 then
                FVideo[ChrRegisterForMmc3[RegisterIndex]] := Value
              else
                WriteSystemRegister(RegisterIndex + 1, Value);
            end;
          $A000:
            WriteSystemRegister(6, Value and 1);
          $C000:
            WriteSystemRegister(1, Value);
          $C001:
            WriteSystemRegister(2, Value);
          $E000:
            WriteSystemRegister(3, Value);
          $E001:
            WriteSystemRegister(4, Value);
        end;
  else
    Exit(inherited CpuWrite(Address, Value));
  end;
  Result := True;
end;

function SwapBits(Value: Byte; First, Second: Integer): Byte; inline;
begin
  var Change := ((Value shr First) xor (Value shr Second)) and 1;
  Result := Value xor ((Change shl First) or (Change shl Second));
end;

function TMapperOneBus.DecodeOpcode(Value: UInt8): UInt8;
begin
  if HasVt32 then
    Exit(FVt32.DecodeOpcode(Value));
  Result := Value;
  if not FOpcodeEncrypted then
    Exit;
  case FSubmapper of
    10:
      Result := SwapBits(SwapBits(Value, 1, 2), 4, 5);
    11:
      begin
        if (FSystem[$1C] and 2) <> 0 then
          Result := SwapBits(Result, 4, 5);
        if (FSystem[$1C] and $40) <> 0 then
          Result := SwapBits(SwapBits(Result, 6, 7), 1, 2);
      end;
    12:
      Result := SwapBits(SwapBits(Value, 6, 7), 1, 2);
    13:
      Result := SwapBits(Value, 1, 4);
    14:
      Result := SwapBits(Value, 6, 7);
    15:
      Result := SwapBits(Value, 5, 6);
  end;
end;

function TMapperOneBus.IsVideoRegister(Address: Word): Boolean;
begin
  if HasVt369 then
    Exit(((Address >= $2010) and (Address <= $2024)) or
      ((Address >= $2040) and (Address <= $2049)) or (Address = $2050));
  // The early VT chips mirror the $2000 page at $2040.
  Result := (Address and $FFB0) = $2010;
end;

procedure TMapperOneBus.WriteVideoRegister(Address: Word; Value: Byte);
const
  Waixing: array[0..5] of Byte = (1, 0, 5, 4, 3, 2);
  Zechess: array[0..5] of Byte = (5, 4, 3, 2, 0, 1);
  Qishenglong: array[0..5] of Byte = (2, 5, 0, 4, 3, 1);
begin
  var Index := Address and $1F;
  if HasVt369 then
    Index := Address and $FF;
  if FHasScrambledRegisters and (Index in [$12..$17]) then
    case FSubmapper of
      1, 5:
        Index := $12 + Waixing[Index - $12];
      3:
        Index := $12 + Zechess[Index - $12];
      4:
        Index := $12 + Qishenglong[Index - $12];
    end;
  FVideo[Index] := Value;
end;

function TMapperOneBus.BackgroundExtended: Boolean;
begin
  Result := (FModel >= 7) and ((FVideo[$10] and $10) <> 0);
end;

function TMapperOneBus.SpriteExtended: Boolean;
begin
  Result := (FModel >= 7) and ((FVideo[$10] and 8) <> 0);
end;

function TMapperOneBus.Background4Bpp: Boolean;
begin
  Result := (FModel >= 7) and ((FVideo[$10] and 2) <> 0);
end;

function TMapperOneBus.Sprite4Bpp: Boolean;
begin
  Result := (FModel >= 7) and ((FVideo[$10] and 4) <> 0);
end;

function TMapperOneBus.WideSprites: Boolean;
begin
  Result := Sprite4Bpp and ((FVideo[$10] and 1) <> 0);
end;

function TMapperOneBus.ExtendedPalette: Boolean;
begin
  Result := (FModel >= 7) and ((FVideo[$10] and $80) <> 0);
end;

function TMapperOneBus.BackgroundPage: Byte;
begin
  if (FVideo[$11] and 1) <> 0 then
    Result := (FSystem[6] and 1) shl 2
  else
    Result := (FVideo[$18] and 8) shr 1;
end;

function TMapperOneBus.ChrBankForSlot(Slot: Integer): Integer;
begin
  case LegacyMode of
    1:
      begin
        var Half := Slot shr 2;
        var Bank := Integer(FMmc1Registers[1 + Half]);
        if (FMmc1Registers[0] and $10) = 0 then
          Bank := (FMmc1Registers[1] and $1E) or Half;
        Exit(Bank * 4 + (Slot and 3));
      end;
    3:
      Exit(((FLegacyLatch shl 3) or Slot) and $FF);
  end;
  if Slot < 4 then
    Result := (FVideo[$16 + (Slot shr 1)] and $FE) or (Slot and 1)
  else
    Result := FVideo[$12 + Slot - 4];
end;

function TMapperOneBus.PatternIndex(Address: Word; Kind: TOneBusFetch; ExtendedAddress: Byte; HighPlanes: Boolean): Integer;
var
  Extended, FourPlanes: Boolean;
begin
  case Kind of
    TOneBusFetch.Background:
      begin
        Extended := BackgroundExtended;
        FourPlanes := Background4Bpp or ExtendedPalette;
        ExtendedAddress := ExtendedAddress or BackgroundPage;
      end;
    TOneBusFetch.Sprite:
      begin
        Extended := SpriteExtended;
        FourPlanes := Sprite4Bpp;
      end;
  else
    Extended := BackgroundExtended or SpriteExtended;
    FourPlanes := Background4Bpp or Sprite4Bpp or ExtendedPalette;
    ExtendedAddress := FVideo[$18] and 7;
  end;

  var Slot := ((Address shr 10) and 7) xor ((FSystem[5] and $80) shr 5);
  var Bank := ChrBankForSlot(Slot);
  var Mask := $FF shr ChrFieldShift[FVideo[$1A] and 7];
  Bank := (Bank and Mask) or ((FVideo[$1A] and $F8) and not Mask);
  if Extended then
    Bank := (Bank shl 3) or (ExtendedAddress and 7)
  else
    Bank := Bank or ((FVideo[$18] and $70) shl 4);
  Bank := Bank or ((FSystem[0] and $0F) shl 11);

  var WindowMask := FChrWindowMask;
  var external := FChrWindowBase;
  if FourPlanes then
  begin
    WindowMask := WindowMask shr 1;
    external := external shr 1;
  end;
  var Relative := FRelative8K shl 3;
  if FourPlanes then
    Relative := Relative shr 1;
  var Logical := ((((Bank and WindowMask) or external) + Relative) shl 10) or (Address and $3FF);
  if not FourPlanes then
    Exit(Logical);
  if (FModel >= 8) and ((FVideo[$10] and $40) <> 0) then
    Result := (Logical shl 1) or Ord(HighPlanes)
  else
    Result := ((Logical and not $0F) shl 1) or (Logical and $0F) or (Ord(HighPlanes) shl 4);
end;

function TMapperOneBus.ReadPattern(Address: Word; Kind: TOneBusFetch; ExtendedAddress: Byte; HighPlanes: Boolean): Byte;
begin
  if BoardHasChrRam then
  begin
    if HighPlanes then
      Exit(0);
    Exit(FChrRam[Address and $1FFF]);
  end;
  var Offset := PatternIndex(Address, Kind, ExtendedAddress, HighPlanes);
  if FSharedRom then
    Result := ReadSharedStorage(Offset, 0)
  else
    Result := FChrMemory[Offset mod Length(FChrMemory)];
  if HasVt32 and ((FSystem[$1E] and $C0) = $C0) then
    Result := ((Result and $09) shl 4) or ((Result and $90) shr 4) or
      ((Result and $22) shl 1) or ((Result and $44) shr 1);
end;

function TMapperOneBus.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := ReadPattern(Address, TOneBusFetch.CpuPort, 0);
end;

function TMapperOneBus.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $2000 then
    Exit(False);
  if BoardHasChrRam then
  begin
    FChrRam[Address] := Value;
    Exit(True);
  end;
  Result := False;
  if FBoard = MAPPER_WIN_LOSE_OR_DRAW then
  begin
    var Index := MappedRamIndex(PatternIndex(Address, TOneBusFetch.CpuPort, 0, False));
    Result := Index >= 0;
    if Result then
      FPrgRam[Index] := Value;
  end;
end;

procedure TMapperOneBus.WriteHighPattern(Address: Word; Value: Byte);
begin
  if FBoard <> MAPPER_WIN_LOSE_OR_DRAW then
    Exit;
  var Index := MappedRamIndex(PatternIndex(Address, TOneBusFetch.CpuPort, 0, True));
  if Index >= 0 then
    FPrgRam[Index] := Value;
end;

function TMapperOneBus.Controller2Input(Value: Byte): Byte;
begin
  Result := Value;
  if FBoard = MAPPER_TAIKEE_ADPCM then
    Result := (Value and not $18) or FAdpcm.Status;
end;

function TMapperOneBus.BoardHasChrRam: Boolean;
begin
  case FBoard of
    MAPPER_VT42XX:
      Result := (FChrRamControl and 1) <> 0;
    MAPPER_VT32:
      Result := (FSystem[$1D] and 4) <> 0;
    MAPPER_ARCADE_ADVANCED:
      Result := FSystem[0] = $6A;
  else
    Result := False;
  end;
end;

function TMapperOneBus.MappedRamIndex(Offset: Integer): Integer;
begin
  Offset := Offset and $1FFFFF;
  if (Offset >= $100000) and (Offset < $110000) then
    Exit(Offset - $100000);
  Result := -1;
end;

function TMapperOneBus.ReadSharedStorage(Offset: Integer; OpenBus: Byte): Byte;
begin
  if FBoard <> MAPPER_WIN_LOSE_OR_DRAW then
    Exit(FPrgRom[Offset mod Length(FPrgRom)]);
  var Index := MappedRamIndex(Offset);
  if Index >= 0 then
    Exit(FPrgRam[Index]);
  Offset := Offset and $1FFFFF;
  if (Offset < $080000) or (Offset >= $180000) then
    Exit(FPrgRom[(Offset and $7FFFF) mod Length(FPrgRom)]);
  Result := OpenBus;
end;

function TMapperOneBus.ScanlineTimer: Boolean;
begin
  Result := (((FSystem[$0B] and $80) <> 0) and (FBoard <> MAPPER_ARCADE_ADVANCED)) or Background4Bpp;
end;

procedure TMapperOneBus.TickTimer(Rendering: Boolean);
begin
  if FIrqCounter = 0 then
    FIrqCounter := FSystem[1]
  else
    Dec(FIrqCounter);
  if (FIrqCounter = 0) and FIrqEnabled and Rendering then
    if HasVt369 and ((FSystem[$1C] and $20) <> 0) then
      FIrqDelay := 24
    else
      FIrqPending := True;
end;

procedure TMapperOneBus.ClockCpu;
begin
  if FA12Filter <> 0 then
    Dec(FA12Filter);
  if HasVt32 then
    FVt32.Clock(FPrgRom, FRegion)
  else if FVt369Audio <> nil then
  begin
    FVt32.Clock(FPrgRom, FRegion);
    if FVt369Io <> nil then
    begin
      if FBoard = MAPPER_VT389 then
        FVt369Io.ClockPanel
      else
        FVt369Io.ClockEeprom(3 - 2 * Ord(FastCpu));
    end;
    FVt369Audio.Clock((6 - 4 * Ord(FastCpu)) div (1 + Ord(HalfVideoClock)));
    if FIrqDelay <> 0 then
    begin
      Dec(FIrqDelay);
      if FIrqDelay = 0 then
        FIrqPending := True;
    end;
  end
  else
    FSecondApu.Clock;
  case FBoard of
    MAPPER_TAIKEE_ADPCM:
      FAdpcm.Clock(FCpuFrequency);
    MAPPER_WIN_LOSE_OR_DRAW:
      FSenario.Clock;
  end;
  if FMainApu <> nil then
    FMainApu.InternalAudioMuted := (FSoundControl and 4) <> 0;
end;

procedure TMapperOneBus.ObserveVideoTimer(Address: UInt16; Rendering: Boolean);
begin
  if (LegacyMode = 0) and not ScanlineTimer and ((Address and $1000) <> 0) then
  begin
    if FA12Filter = 0 then
      TickTimer(Rendering);
    FA12Filter := 3;
  end;
end;

procedure TMapperOneBus.ClockHsync(Line: Integer; Rendering: Boolean; Dot: Integer);
begin
  if HasVt369 then
  begin
    if (Dot <> 240) or (FastCpu and (Line <= 0)) or
      (((FSystem[$1C] and $20) <> 0) and (Line = 0)) then
      Exit;
  end
  else if Dot <> 256 then
    Exit;
  if (LegacyMode = 0) and ScanlineTimer and (Line < 242) then
    TickTimer(Rendering);
end;

function TMapperOneBus.IrqPending: Boolean;
begin
  Result := FIrqPending and (LegacyMode = 0);
end;

function TMapperOneBus.ExpansionAudio: Double;
begin
  if HasVt32 then
    Exit(FVt32.Audio);
  if FVt369Audio <> nil then
    Exit(FVt369Audio.Sample);
  Result := 0;
  if (FSoundControl and 8) <> 0 then
    Result := FSecondApu.CurrentChannelOutput;
  if ((FSoundControl and $10) <> 0) and (FMainApu <> nil) then
    Result := Result + FMainApu.OneBusPcmOutput;
  if FBoard = MAPPER_TAIKEE_ADPCM then
    Result := Result + FAdpcm.Output / 128.0;
end;

end.

