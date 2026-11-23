unit A8.Media;

interface

uses
  System.SysUtils, Core.Snapshots, Core.Storage;

type
  TA8MediaKind = (Cartridge, Disk, Executable, BasicProgram, Cassette);

  TA8Segment = record
    Address: Word;
    Offset, Size: Integer;
  end;

  TA8ProtectedSector = record
    Offset, Angle, WeakOffset: Integer;
    Number, Status: Byte;
  end;

  TA8TapeBlock = record
    Offset, Count, GapMS, Baud: Integer;
  end;

  TA8Media = class
  private
    FData, FBasicData: TBytes;
    FProtectedTracks: TArray<TArray<TA8ProtectedSector>>;
    FTape: TArray<TA8TapeBlock>;
    FTapeBlock, FTapePulse: Integer;
    FTapeElapsed, FTapePulseEnd: Int64;
    FTapeBasic, FTapeBootBasic, FTapeBasicRevA, FTapeShortGaps, FTapeOSB: Boolean;
    FTapeBasicStatements: Integer;
    FTapeOriginalXLOS: Boolean;
    FDiskPhase, FReplyDelay: Integer;
    FDriveStatus: Byte;
    FSegments: TArray<TA8Segment>;
    FKind: TA8MediaKind;
    FMapper, FBank, FBank2, FFixedBank, FSectorSize, FDiskOffset, FSectorCount: Integer;
    FAutomaticRawMapper: Integer;
    FFullBootSectors: Boolean;
    FDisabled, FCommandLine, FWriteProtected, FDiskDirty: Boolean;
    FDiskCopy: string;
    FStorage: IStorage;
    FWriteOffset, FWriteSize: Integer;
    FCommand, FReply: array[0..1027] of Byte;
    FCommandCount, FReplyCount, FReplyIndex, FReplyCycles: Integer;
    procedure ParseExecutable;
    procedure ParseBasic(const ProgramBytes: TBytes);
    procedure ParseCassette;
    procedure IdentifyTapeStartup;
    procedure ParseProtectedDisk;
    function ReadProtectedSector(Number: Integer; out Count, Delay: Integer): Boolean;
    procedure ParseDisk(const Extension: string);
    procedure ParseCartridge(Mapper: Integer);
    procedure ReplyToCommand;
    procedure FinishWrite;
    function SectorLocation(Sector: Integer; out Offset, Size: Integer): Boolean;
  public
    constructor Create(const Data: TBytes; const Extension: string; Mapper: Integer = 0);
    procedure AttachDisk(const Storage: IStorage; const DiskCopy: string; WriteProtected: Boolean);
    procedure Flush;
    procedure Reset;
    function BootsKFile: Boolean;
    function RequiresOriginalXLOS: Boolean;
    property AutomaticRawMapper: Integer read FAutomaticRawMapper;
    function CartHigh: Boolean;
    function ReadCart(Address: Word; out Value: Byte): Boolean;
    procedure CartControl(Address: Word; Value: Byte; Writing: Boolean);
    procedure SetCommandLine(Asserted: Boolean);
    procedure Transmit(Value: Byte);
    function Clock(out Value: Byte): Boolean;
    function ClockTape(Motor: Boolean; ClockHz: Integer): Boolean;
    property TapeBasic: Boolean read FTapeBasic;
    property TapeBootBasic: Boolean read FTapeBootBasic;
    property TapeBasicRevA: Boolean read FTapeBasicRevA;
    property TapeOSB: Boolean read FTapeOSB;
    property TapeShortGaps: Boolean read FTapeShortGaps;
    property TapeBasicStatements: Integer read FTapeBasicStatements;
    procedure SerializeState(State: TStateArchive);
    property Data: TBytes read FData;
    property BasicData: TBytes read FBasicData;
    property Segments: TArray<TA8Segment> read FSegments;
    property Kind: TA8MediaKind read FKind;
  end;

const
  A8MediaLimit = 16 * 1024 * 1024;
  A8SerialByteCycles = 932;
  A8XexBootAddress = $0700;
  A8XexEntry = A8XexBootAddress + 6;
  A8XexContinue = A8XexEntry + 1;

function A8ComputerCartType(Mapper: Integer): Boolean;

implementation

uses
  System.Classes, System.Generics.Collections, System.Math, System.ZLib;

const
  // D1: boot sector with no resident loader. The machine services the
  // executable entries at the two instruction addresses after disk boot.
  XexBootSector: array[0..7] of Byte = (0, 1, $00, $07, $06, $07, $60, $60);

function A8ComputerCartType(Mapper: Integer): Boolean;
begin
  Result := (Mapper > 0) and (Mapper <= 255) and not (Mapper in [4, 6, 7, 16, 19, 20, 71, 72, 73, 74]);
end;

function ReadWordLE(const Data: TBytes; Index: Integer): Word;
begin
  Result := Data[Index] or (Word(Data[Index + 1]) shl 8);
end;

function ReadLongLE(const Data: TBytes; Index: Integer): Cardinal;
begin
  Result := ReadWordLE(Data, Index) or (Cardinal(ReadWordLE(Data, Index + 2)) shl 16);
end;

function MatchesBytes(const Data: TBytes; Offset: Integer; const Signature: array of Byte): Boolean;
begin
  Result := (Offset >= 0) and (Offset <= Length(Data) - Length(Signature)) and
    CompareMem(@Data[Offset], @Signature[0], Length(Signature));
end;

function HasCompleteKFilePayload(const Data: TBytes; Offset: Integer): Boolean;
const
  BootSize = 3 * 128;
  BootHeader: array[0..8] of Byte = ($00, $03, $00, $07, $14, $07, $4C, $14, $07);
  LoaderCode: array[0..17] of Byte = ($A9, $46, $8D, $C6, $02, $D0, $FE, $A0, $00,
    $A9, $6B, $91, $58, $20, $D9, $07, $B0, $EE);
begin
  Result := False;
  var PayloadSize := Length(Data) - Offset;
  if (PayloadSize <= BootSize) or not MatchesBytes(Data, Offset, BootHeader) or
    not MatchesBytes(Data, Offset + 13, LoaderCode) then
    Exit;
  // At $0709 the loader stores the number of bytes it reads from sector 4 onward.
  var PackedSize := ReadWordLE(Data, Offset + 9) or (Integer(Data[Offset + 11]) shl 16);
  Result := (PackedSize > 0) and (PayloadSize = BootSize + ((PackedSize + 127) div 128) * 128);
end;

function SIOChecksum(const Bytes: array of Byte; Count: Integer; Start: Integer = 0): Byte;
begin
  var Sum := 0;
  for var I := Start to Start + Count - 1 do
  begin
    Inc(Sum, Bytes[I]);
    Sum := (Sum and $FF) + (Sum shr 8);
  end;
  Result := Sum;
end;

constructor TA8Media.Create(const Data: TBytes; const Extension: string; Mapper: Integer);
begin
  inherited Create;
  if (Length(Data) = 0) or (Length(Data) > A8MediaLimit) then
    raise EReadError.Create('Invalid Atari 8-bit image size');
  FData := Copy(Data);
  if SameText(Extension, '.xex') or SameText(Extension, '.com') then
  begin
    FKind := TA8MediaKind.Executable;
    ParseExecutable;
    FSectorSize := 128;
    FSectorCount := 1;
  end
  else if SameText(Extension, '.bas') then
    ParseBasic(FData)
  else if SameText(Extension, '.cas') then
    ParseCassette
  else if SameText(Extension, '.atx') then
  begin
    FKind := TA8MediaKind.Disk;
    ParseProtectedDisk;
  end
  else if SameText(Extension, '.atr') or SameText(Extension, '.xfd') then
  begin
    FKind := TA8MediaKind.Disk;
    ParseDisk(Extension);
  end
  else
  begin
    FKind := TA8MediaKind.Cartridge;
    ParseCartridge(Mapper);
  end;
  Reset;
end;

function BasicHeader(const Bytes: TBytes; Offset: Integer; out DataSize, StatementSize: Integer): Boolean;
begin
  Result := False;
  if Offset > Length(Bytes) - 14 then
    Exit;
  var NameTable := ReadWordLE(Bytes, Offset + 2);
  var NameEnd := ReadWordLE(Bytes, Offset + 4);
  var Values := ReadWordLE(Bytes, Offset + 6);
  var Statements := ReadWordLE(Bytes, Offset + 8);
  var Current := ReadWordLE(Bytes, Offset + 10);
  var ProgramEnd := ReadWordLE(Bytes, Offset + 12);
  DataSize := ProgramEnd - NameTable;
  StatementSize := ProgramEnd - Statements;
  Result := (ReadWordLE(Bytes, Offset) = 0) and (NameTable >= $100) and
    (NameEnd >= NameTable) and (Values = NameEnd + 1) and (Statements >= Values) and
    ((Statements - Values) mod 8 = 0) and (Current >= Statements) and (ProgramEnd >= Current);
end;

procedure TA8Media.ParseBasic(const ProgramBytes: TBytes);
begin
  if Length(ProgramBytes) < 14 then
    raise EReadError.Create('Truncated Atari BASIC program');
  var DataSize, StatementSize: Integer;
  if not BasicHeader(ProgramBytes, 0, DataSize, StatementSize) or (DataSize > Length(ProgramBytes) - 14) then
    raise EReadError.Create('Invalid Atari BASIC SAVE header');
  FBasicData := ProgramBytes;
  FKind := TA8MediaKind.BasicProgram;
end;

procedure TA8Media.ParseCassette;
const
  FujiTag = $494A5546;
  BaudTag = $64756162;
  DataTag = $61746164;
  FskTag = $206B7366;
var
  Block: TA8TapeBlock;
begin
  if (Length(FData) < 8) or (ReadLongLE(FData, 0) <> FujiTag) then
    raise EReadError.Create('Invalid Atari CAS cassette header');

  FKind := TA8MediaKind.Cassette;
  var Blocks := TList<TA8TapeBlock>.Create;
  try
    var Position := 0;
    var Baud := 600;
    while Position < Length(FData) do
    begin
      if Position > Length(FData) - 8 then
        raise EReadError.Create('Truncated Atari CAS chunk');
      var Tag := ReadLongLE(FData, Position);
      var Count := ReadWordLE(FData, Position + 4);
      var Aux := ReadWordLE(FData, Position + 6);
      Inc(Position, 8);
      if Count > Length(FData) - Position then
        raise EReadError.Create('Truncated Atari CAS chunk data');
      case Tag of
        FujiTag:
          ;
        BaudTag:
          begin
            if (Count <> 0) or (Aux = 0) then
              raise EReadError.Create('Invalid Atari CAS baud chunk');
            Baud := Aux;
          end;
        DataTag, FskTag:
          begin
            Block.Offset := Position;
            Block.Count := Count;
            Block.GapMS := Aux;
            Block.Baud := Baud;
            if Tag = FskTag then
            begin
              if Count and 1 <> 0 then
                raise EReadError.Create('Invalid Atari CAS FSK pulse list');
              Block.Baud := 0;
            end;
            if (Count <> 0) or (Aux <> 0) then
              Blocks.Add(Block);
          end;
      else
        raise EReadError.CreateFmt('Unsupported Atari CAS chunk: %s', [TEncoding.ASCII.GetString(FData, Position - 8, 4)]);
      end;
      Inc(Position, Count);
    end;
    if Blocks.Count = 0 then
      raise EReadError.Create('Empty Atari CAS cassette');
    FTape := Blocks.ToArray;
  finally
    Blocks.Free;
  end;

  IdentifyTapeStartup;
  if not FTapeBasic then
    Exit;

  // Keep direct startup for complete Atari BASIC SAVE recordings. A checksum
  // error in an on-tape record still belongs to the tape and reaches POKEY.
  var Output := TMemoryStream.Create;
  try
    for Block in FTape do
    begin
      var Offset := Block.Offset;
      if (Block.Baud = 0) or (Block.Count <> 132) or (ReadWordLE(FData, Offset) <> $5555) then
        Break;
      if SIOChecksum(FData, 131, Offset) <> FData[Offset + 131] then
        Break;
      case FData[Offset + 2] of
        $FC:
          Output.WriteBuffer(FData[Offset + 3], 128);
        $FA:
          begin
            var Count := FData[Offset + 130];
            if Count > 127 then
              Break;
            Output.WriteBuffer(FData[Offset + 3], Count);
          end;
        $FE:
          begin
            var Bytes: TBytes;
            SetLength(Bytes, Output.Size);
            Output.Position := 0;
            if Length(Bytes) > 0 then
              Output.ReadBuffer(Bytes[0], Length(Bytes));
            try
              ParseBasic(Bytes);
            except
              on E: EReadError do
                ; // Let BASIC read this image through the real tape path.
            end;
            Break;
          end;
      else
        Break;
      end;
    end;
  finally
    Output.Free;
  end;
end;

procedure TA8Media.IdentifyTapeStartup;
const
  OriginalBasicLoader: array[0..15] of Byte = ($A9, $B7, $48, $A9, $54, $48,
    $A9, $04, $20, $B6, $BB, $A9, $FF, $4C, $04, $BB);
begin
  var First := FTape[0];
  var DataSize, StatementSize: Integer;
  if (First.Baud <> 0) and (First.Count = 132) and MatchesBytes(FData, First.Offset, [$55, $55, $FC]) then
  begin
    FTapeBasic := BasicHeader(FData, First.Offset + 3, DataSize, FTapeBasicStatements);
    if FTapeBasic and (Length(FTape) > 1) then
      FTapeShortGaps := (FTape[1].GapMS < 1000) and (FTape[1].Baud <> 0) and
        (FTape[1].Count >= 3) and MatchesBytes(FData, FTape[1].Offset, [$55, $55]);
    // These loaders call internal BASIC entry points whose locations changed
    // after the original cartridge release.
    var FigureFun := MatchesBytes(FData, First.Offset + 3, [$00, $05, $00, $06, $4F, $07]) and
      MatchesBytes(FData, First.Offset + 11, [$A2, $FD, $9A, $A9, $04, $20, $B6, $BB, $A9, $FF, $20, $04, $BB]);
    var SquarePairs := MatchesBytes(FData, First.Offset + 3, [$00, $60, $00, $07, $74, $E4]) and
      MatchesBytes(FData, First.Offset + $3E, [$A2, $FF, $9A, $A9, $A9, $48, $A9, $61, $48, $4C, $4D, $B7]);
    // The Milliken and steam simulator bootstraps also use the 400/800 OS-B environment.
    var Milliken := MatchesBytes(FData, First.Offset + 3,
      [$00, $19, $F0, $2F, $00, $34, $A9, $3C, $8D, $02, $D3, $60]) and
      MatchesBytes(FData, First.Offset + 28, [$18, $18, $18, $18, $00, $18, $00, $00, $66, $66, $66]);
    var SteamSimulator := MatchesBytes(FData, First.Offset + 3,
      [$00, $6C, $00, $07, $19, $07, $A9, $3C, $8D, $02, $D3, $A9, $00, $85, $0C,
        $A9, $30, $85, $0D, $A9, $00, $8D, $44, $02, $18, $60]);
    // The two-record editor hook feeds its CLOAD and RUN commands into
    // the original OS-B editor handler.
    var EditorBoot := MatchesBytes(FData, First.Offset + 3,
      [$00, $02, $F8, $05, $00, $06, $18, $60, $A2, $00, $BD, $1A, $03, $C9,
        $45, $F0, $05, $E8, $E8, $E8, $D0, $F4, $E8, $8E, $69, $06]);
    FTapeOSB := FigureFun or Milliken or SteamSimulator or EditorBoot;
    FTapeBasicRevA := FTapeOSB or SquarePairs;
    // These bootstraps call internal OS addresses or rely on the original
    // editor layout. Only the BASIC launchers expect BASIC to stay mapped.
    var LunarLoader := MatchesBytes(FData, First.Offset + 3, [$00, $25, $60, $27, $72, $27]) and
      MatchesBytes(FData, First.Offset + $41, [$20, $AC, $27, $20, $E0, $27, $A9, $0C, $8D, $FC, $02, $4C, $80, $C6]);
    var ShortEditorLoader := MatchesBytes(FData, First.Offset + 3, [$00, $01, $80, $06, $8D, $06]) and
      MatchesBytes(FData, First.Offset + $10, [$AE, $40, $03, $BD, $1B, $03, $85, $D4, $8D, $D5, $06,
          $BD, $1C, $03, $85, $D5, $8D, $DA, $06]);
    // Geometria copies the XL ROM to RAM and later calls its NMI handler at $C0E2.
    var GeometryLoader := MatchesBytes(FData, First.Offset + 3,
      [$00, $01, $00, $07, $50, $E4, $A2, $00, $BD, $00, $04, $9D, $80, $07, $E8,
        $10, $F7, $86, $3D, $AD, $0F, $D2, $29, $10]);
    FTapeOriginalXLOS := LunarLoader or ShortEditorLoader or GeometryLoader;
    if not FTapeBasic and (FData[First.Offset + 3] = 0) then
    begin
      // The boot header gives the record count. An EOF followed by a BASIC SAVE
      // identifies the BASIC payload expected by the machine-language loader.
      var BootRecords := Integer(FData[First.Offset + 4]);
      var LoadAddress := Integer(ReadWordLE(FData, First.Offset + 5));
      if (BootRecords > 0) and (BootRecords + 1 < Length(FTape)) and
        (LoadAddress >= $200) and (LoadAddress + BootRecords * 128 <= $A000) then
      begin
        var EofRecord := FTape[BootRecords];
        var ProgramRecord := FTape[BootRecords + 1];
        FTapeBootBasic := (EofRecord.Baud <> 0) and (EofRecord.Count >= 4) and
          MatchesBytes(FData, EofRecord.Offset, [$55, $55, $FE]) and
          (ProgramRecord.Baud <> 0) and (ProgramRecord.Count = 132) and
          MatchesBytes(FData, ProgramRecord.Offset, [$55, $55, $FC]) and
          (SIOChecksum(FData, 131, ProgramRecord.Offset) = FData[ProgramRecord.Offset + 131]) and
          BasicHeader(FData, ProgramRecord.Offset + 3, DataSize, StatementSize);
      end;
    end;
    FTapeBootBasic := FTapeBootBasic or FTapeBasicRevA or LunarLoader or ShortEditorLoader;
  end;
  if not FTapeBasic then
    Exit;

  // Some BASIC files contain a USR routine that jumps into the original
  // interpreter's private routines to load and run the next file.
  for var Block in FTape do
  begin
    if (Block.Baud = 0) or (Block.Count <> 132) or
      not MatchesBytes(FData, Block.Offset, [$55, $55]) or (FData[Block.Offset + 2] = $FE) or
      (SIOChecksum(FData, 131, Block.Offset) <> FData[Block.Offset + 131]) then
      Break;
    for var Offset := Block.Offset + 3 to Block.Offset + 131 - Length(OriginalBasicLoader) do
      if MatchesBytes(FData, Offset, OriginalBasicLoader) then
      begin
        FTapeBootBasic := True;
        Exit;
      end;
  end;
end;

function TA8Media.ClockTape(Motor: Boolean; ClockHz: Integer): Boolean;
begin
  Result := True;
  if not Motor then
    Exit;
  while FTapeBlock < Length(FTape) do
  begin
    var Block := FTape[FTapeBlock];
    var Gap := Int64(Block.GapMS) * ClockHz div 1000;
    if FTapeElapsed < Gap then
    begin
      Inc(FTapeElapsed);
      Exit;
    end;

    if Block.Baud <> 0 then
    begin
      var Position := (FTapeElapsed - Gap) * Block.Baud div ClockHz;
      if Position < Block.Count * 10 then
      begin
        var Bit := Integer(Position mod 10);
        if Bit <> 9 then
          Result := (Bit <> 0) and (FData[Block.Offset + Position div 10] and (1 shl Max(Bit - 1, 0)) <> 0);
        Inc(FTapeElapsed);
        Exit;
      end;
    end
    else
    begin
      while (FTapeElapsed - Gap) * 10000 >= FTapePulseEnd * ClockHz do
      begin
        if FTapePulse >= Block.Count then
          Break;
        Inc(FTapePulseEnd, ReadWordLE(FData, Block.Offset + FTapePulse));
        Inc(FTapePulse, 2);
      end;
      if (FTapeElapsed - Gap) * 10000 < FTapePulseEnd * ClockHz then
      begin
        Result := (FTapePulse and 2 = 0);
        Inc(FTapeElapsed);
        Exit;
      end;
    end;
    Inc(FTapeBlock);
    FTapeElapsed := 0;
    FTapePulse := 0;
    FTapePulseEnd := 0;
  end;
end;

procedure TA8Media.ParseProtectedDisk;
const
  FileHeaderSize = 48;
  TrackHeaderSize = 32;
  SectorHeaderSize = 8;
  TrackCount = 40;
  SectorsPerTrack = 18;
begin
  if (Length(FData) < FileHeaderSize) or (ReadLongLE(FData, 0) <> $58385441) or
    (ReadWordLE(FData, 4) <> 1) or (ReadWordLE(FData, 6) <> 1) then
    raise EReadError.Create('Invalid Atari ATX header');
  if FData[18] <> 0 then
    raise EReadError.Create('Unsupported Atari ATX disk density');
  var Position := ReadLongLE(FData, 28);
  var Finish := ReadLongLE(FData, 32);
  if (Position < FileHeaderSize) or (Position >= Finish) or (Finish > Cardinal(Length(FData))) then
    raise EReadError.Create('Invalid Atari ATX track range');
  SetLength(FProtectedTracks, TrackCount);
  FSectorSize := 128;
  FSectorCount := TrackCount * SectorsPerTrack;
  FWriteProtected := True;
  var Loaded: array[0..TrackCount - 1] of Boolean;
  FillChar(Loaded, SizeOf(Loaded), 0);
  while Position < Finish do
  begin
    if Finish - Position < TrackHeaderSize then
      raise EReadError.Create('Truncated Atari ATX track');
    var TrackSize := ReadLongLE(FData, Position);
    var TrackHeader := ReadLongLE(FData, Position + 20);
    var Track := FData[Position + 8];
    var Count := ReadWordLE(FData, Position + 10);
    if (Track >= TrackCount) or (TrackSize < TrackHeaderSize) or (TrackSize > Finish - Position) or
      (TrackHeader < TrackHeaderSize) or (TrackHeader > TrackSize) or (ReadWordLE(FData, Position + 4) <> 0) then
      raise EReadError.Create('Invalid Atari ATX track');
    if Loaded[Track] then
      raise EReadError.Create('Duplicate Atari ATX track');
    Loaded[Track] := True;
    var Chunk := TrackHeader;
    var HasList := False;
    while TrackSize - Chunk >= SectorHeaderSize do
    begin
      var ChunkSize := ReadLongLE(FData, Position + Chunk);
      if ChunkSize = 0 then
        Break;
      if (ChunkSize < SectorHeaderSize) or (ChunkSize > TrackSize - Chunk) then
        raise EReadError.Create('Invalid Atari ATX track chunk');
      var ChunkType := FData[Position + Chunk + 4];
      if (Chunk = TrackHeader) and (ChunkType = 1) then
      begin
        if Cardinal((Count + 1) * SectorHeaderSize) > ChunkSize then
          raise EReadError.Create('Truncated Atari ATX sector list');
        HasList := True;
        SetLength(FProtectedTracks[Track], Count);
        for var I := 0 to Count - 1 do
        begin
          var Entry := Position + Chunk + Cardinal(I + 1) * SectorHeaderSize;
          var Sector := Default(TA8ProtectedSector);
          Sector.Number := FData[Entry];
          Sector.Status := FData[Entry + 1];
          Sector.Angle := ReadWordLE(FData, Entry + 2);
          Sector.WeakOffset := -1;
          if Sector.Status and $10 = 0 then
          begin
            var Offset := ReadLongLE(FData, Entry + 4);
            if (TrackSize < 128) or (Offset < TrackHeader + ChunkSize) or (Offset > TrackSize - 128) then
              raise EReadError.Create('Invalid Atari ATX sector data');
            Sector.Offset := Position + Offset;
          end;
          FProtectedTracks[Track][I] := Sector;
        end;
      end
      else if ChunkType = $10 then
      begin
        var Index := FData[Position + Chunk + 5];
        var WeakOffset := ReadWordLE(FData, Position + Chunk + 6);
        if not HasList or (Index >= Count) or (WeakOffset >= 128) then
          raise EReadError.Create('Invalid Atari ATX weak sector');
        FProtectedTracks[Track][Index].WeakOffset := WeakOffset;
      end;
      Inc(Chunk, ChunkSize);
    end;
    if (Count <> 0) and not HasList then
      raise EReadError.Create('Missing Atari ATX sector list');
    Inc(Position, TrackSize);
  end;
end;

function TA8Media.ReadProtectedSector(Number: Integer; out Count, Delay: Integer): Boolean;
const
  SectorsPerTrack = 18;
  RotationUnits = 26042;
  CyclePerUnit = 14;
begin
  Result := False;
  Count := 0;
  Delay := 0;
  FDriveStatus := $EF;
  if (Number < 1) or (Number > FSectorCount) then
    Exit;
  var Track := (Number - 1) div SectorsPerTrack;
  var SectorNumber := (Number - 1) mod SectorsPerTrack + 1;
  var Best := -1;
  var BestDistance := RotationUnits;
  for var Index := 0 to High(FProtectedTracks[Track]) do
  begin
    var Sector := FProtectedTracks[Track][Index];
    if (Sector.Number <> SectorNumber) or (Sector.Status and $10 <> 0) then
      Continue;
    var Distance := (Sector.Angle + RotationUnits - (FDiskPhase div CyclePerUnit)) mod RotationUnits;
    if Distance < BestDistance then
    begin
      Best := Index;
      BestDistance := Distance;
    end;
  end;
  if Best < 0 then
    Exit;
  var Sector := FProtectedTracks[Track][Best];
  FDriveStatus := not (Sector.Status and $3C);
  Count := FSectorSize;
  Move(FData[Sector.Offset], FReply[2], Count);
  if Sector.WeakOffset >= 0 then
  begin
    var Noise := Cardinal(FDiskPhase + Sector.Offset + 1);
    for var I := Sector.WeakOffset to Count - 1 do
    begin
      Noise := Noise xor (Noise shl 13);
      Noise := Noise xor (Noise shr 17);
      Noise := Noise xor (Noise shl 5);
      FReply[I + 2] := Byte(Noise);
    end;
  end;
  Delay := BestDistance * CyclePerUnit;
  Result := (Sector.Status and $1C = 0);
end;

procedure TA8Media.ParseExecutable;
begin
  if (Length(FData) < 6) or (ReadWordLE(FData, 0) <> $FFFF) then
    raise EReadError.Create('Invalid Atari executable header');
  var Segments := TList<TA8Segment>.Create;
  try
    var Offset := 0;
    while Offset < Length(FData) do
    begin
      if Offset + 2 > Length(FData) then
        raise EReadError.Create('Truncated Atari executable header');
      var Start := ReadWordLE(FData, Offset);
      Inc(Offset, 2);
      if Start = $FFFF then
        Continue;
      if Offset + 2 > Length(FData) then
        raise EReadError.Create('Truncated Atari executable segment');
      var Last := ReadWordLE(FData, Offset);
      Inc(Offset, 2);
      var Count := Integer(Last) - Start + 1;
      if (Count <= 0) or (Count > Length(FData) - Offset) then
        raise EReadError.Create('Invalid Atari executable segment size');
      var Segment: TA8Segment;
      Segment.Address := Start;
      Segment.Offset := Offset;
      Segment.Size := Count;
      Segments.Add(Segment);
      Inc(Offset, Count);
    end;
    if Segments.Count = 0 then
      raise EReadError.Create('Atari executable has no segments');
    FSegments := Segments.ToArray;
  finally
    Segments.Free;
  end;
end;

procedure TA8Media.ParseDisk(const Extension: string);
begin
  var ImageSize := Length(FData);
  FSectorSize := 128;
  if SameText(Extension, '.atr') then
  begin
    if (ImageSize < 16) or (ReadWordLE(FData, 0) <> $0296) then
      raise EReadError.Create('Invalid Atari ATR header');
    FDiskOffset := 16;
    FSectorSize := ReadWordLE(FData, 4);
    var PayloadSize := Length(FData) - FDiskOffset;
    var Paragraphs := UInt64(ReadWordLE(FData, 2)) or (UInt64(ReadWordLE(FData, 6)) shl 16);
    var DeclaredSize := Paragraphs * 16;
    if (DeclaredSize > 0) and (DeclaredSize <= UInt64(PayloadSize)) then
      ImageSize := Integer(DeclaredSize)
    else if (FSectorSize = 128) and (DeclaredSize = UInt64(PayloadSize) * 2) and
      HasCompleteKFilePayload(FData, FDiskOffset) then
      // Some K-file images have a doubled length field. Keep the original bytes
      // so disk copies and snapshots retain the same media identity.
      ImageSize := PayloadSize
    else
      raise EReadError.Create('Truncated Atari ATR disk');
  end
  else if (ImageSize = 3 * 128 + 717 * 256) or (ImageSize = 720 * 256) then
    FSectorSize := 256;
  if (FSectorSize <> 128) and (FSectorSize <> 256) then
    raise EReadError.CreateFmt('Unsupported Atari disk sector size (%d)', [FSectorSize]);
  if (FSectorSize = 128) or (ImageSize <= 384) then
  begin
    if ImageSize mod 128 <> 0 then
      raise EReadError.Create('Invalid Atari disk size');
    FSectorCount := ImageSize div 128;
  end
  else if (ImageSize - 384) mod FSectorSize = 0 then
    FSectorCount := 3 + (ImageSize - 384) div FSectorSize
  else if ImageSize mod FSectorSize = 0 then
  begin
    FFullBootSectors := True;
    FSectorCount := ImageSize div FSectorSize;
  end
  else
    raise EReadError.Create('Invalid Atari double-density disk size');
end;

function TA8Media.BootsKFile: Boolean;
begin
  Result := (FKind = TA8MediaKind.Disk) and (FSectorSize = 128) and
    (Length(FProtectedTracks) = 0) and HasCompleteKFilePayload(FData, FDiskOffset);
end;

function TA8Media.RequiresOriginalXLOS: Boolean;
const
  // BAS2BOOT calls the internal XL screen routines at $C642 and $C63E.
  BasicBootHeader: array[0..7] of Byte = ($00, $02, $00, $07, $0A, $07, $18, $60);
  BasicBootCode: array[0..13] of Byte = ($A2, $BC, $A0, $07, $20, $42, $C6,
    $A2, $D8, $A0, $07, $20, $42, $C6);
  // The packed executable builds a return address and jumps into XL ROM at $EF94.
  PackedExecutableCode: array[0..16] of Byte = ($A9, $B7, $48, $A9, $54, $48,
    $A5, $6A, $10, $02, $A9, $A0, $85, $6A, $4C, $94, $EF);
begin
  if FKind = TA8MediaKind.Cassette then
    Exit(FTapeOriginalXLOS);
  if FKind = TA8MediaKind.Disk then
    Exit(MatchesBytes(FData, FDiskOffset, BasicBootHeader) and
      MatchesBytes(FData, FDiskOffset + 10, BasicBootCode));
  if FKind = TA8MediaKind.Executable then
    for var Segment in FSegments do
    begin
      var Limit := Min(Segment.Offset + Segment.Size, 256) - Length(PackedExecutableCode);
      for var Offset := Segment.Offset to Limit do
        if MatchesBytes(FData, Offset, PackedExecutableCode) then
          Exit(True);
    end;
  Result := False;
end;

function DetectRawMapper(const Data: TBytes): Integer;
begin
  case Length(Data) of
    $0800:
      Exit(57);
    $1000:
      Exit(58);
    $2000:
      Exit(1);
    $4000:
      Exit(2);
    $A000:
      Exit(18);
    $8000, $10000, $20000:
      // Known XEGS dumps from the MAME xegs software list (CC0-1.0).
      case crc32(0, @Data[0], Length(Data)) of
        $F31321C2: // Into the Eagle's Nest
          Exit(12);
        $A8F9324D, $B15CCEF2: // Desert Falcon, Thunderfox
          Exit(13);
        $28288DF4, $AB06A3F5, $95E6932D: // Commando, GATO, Summer Games
          Exit(14);
      end;
  end;
  Result := 0;
end;

procedure TA8Media.ParseCartridge(Mapper: Integer);
begin
  if (Length(FData) >= 16) and (FData[0] = Ord('C')) and
    (FData[1] = Ord('A')) and (FData[2] = Ord('R')) and (FData[3] = Ord('T')) then
  begin
    if (FData[4] <> 0) or (FData[5] <> 0) or (FData[6] <> 0) then
      raise EReadError.Create('Unknown Atari cartridge type');
    FMapper := FData[7];
    var Expected := Cardinal(FData[8]) shl 24 or Cardinal(FData[9]) shl 16 or
      Cardinal(FData[10]) shl 8 or FData[11];
    var Sum: Cardinal := 0;
    for var I := 16 to High(FData) do
      Inc(Sum, FData[I]);
    if (Expected <> 0) and (Sum <> Expected) then
      raise EReadError.Create('Atari cartridge checksum mismatch');
    FData := Copy(FData, 16, MaxInt);
  end
  else
  begin
    FAutomaticRawMapper := DetectRawMapper(FData);
    FMapper := Mapper;
    if FMapper = 0 then
      FMapper := FAutomaticRawMapper;
    if FMapper = 0 then
      raise EReadError.Create('Select a cartridge type for this raw Atari ROM');
  end;
  var Banks: Integer;
  case FMapper of
    3, 15, 45:
      Banks := 2;
    18:
      Banks := 5;
    26..32:
      Banks := 2 shl (FMapper - 26);
    1, 21, 39, 44, 53:
      Banks := 1;
    2, 40, 76:
      Banks := 2;
    5, 12, 22, 33, 52, 60:
      Banks := 4;
    8..10, 13, 34, 67:
      Banks := 8;
    14, 17, 35, 41:
      Banks := 16;
    23, 36:
      Banks := 32;
    24, 37:
      Banks := 64;
    25, 38, 42, 75:
      Banks := 128;
    46, 57..59:
      Banks := 0;
  else
    raise EReadError.CreateFmt('Unsupported Atari cartridge type (%d)', [FMapper]);
  end;
  var ExpectedSize := Banks * $2000;
  case FMapper of
    57:
      ExpectedSize := $0800;
    46, 58, 59:
      ExpectedSize := $1000;
  end;
  if Length(FData) <> ExpectedSize then
    raise EReadError.CreateFmt('Invalid size for Atari cartridge type %d', [FMapper]);
  FFixedBank := Banks - 1;
  if FMapper in [26..32] then
    FFixedBank := (Banks div 2) - 1;
end;

procedure TA8Media.Reset;
begin
  FBank := 0;
  FBank2 := 0;
  case FMapper of
    15, 44:
      FBank := 1;
    42:
      FBank := FFixedBank;
  end;
  FDisabled := False;
  FCommandLine := False;
  FCommandCount := 0;
  FReplyIndex := 0;
  FReplyCount := 0;
  FReplyCycles := 0;
  FWriteOffset := 0;
  FWriteSize := 0;
  FDiskPhase := 0;
  FReplyDelay := 0;
  FDriveStatus := $FF;
  FTapeBlock := 0;
  FTapeElapsed := 0;
  FTapePulse := 0;
  FTapePulseEnd := 0;
end;

procedure TA8Media.AttachDisk(const Storage: IStorage; const DiskCopy: string; WriteProtected: Boolean);
begin
  FWriteProtected := WriteProtected or (Length(FProtectedTracks) <> 0) or (FKind <> TA8MediaKind.Disk) or
    ((FDiskOffset = 16) and (FData[15] and 1 <> 0));
  if (FKind <> TA8MediaKind.Disk) or (Length(FProtectedTracks) <> 0) or (Storage = nil) or (DiskCopy = '') then
    Exit;
  FStorage := Storage;
  FDiskCopy := DiskCopy;
  if not Storage.Exists(DiskCopy) then
    Exit;
  var Image := Storage.OpenRead(DiskCopy);
  try
    if Image.Size <> Length(FData) then
      raise EReadError.Create('Atari saved disk size does not match its original image');
    var Saved: TBytes;
    SetLength(Saved, Length(FData));
    Image.ReadBuffer(Saved[0], Length(Saved));
    if (FDiskOffset > 0) and not CompareMem(@Saved[0], @FData[0], FDiskOffset) then
      raise EReadError.Create('Atari saved disk header does not match its original image');
    FData := Saved;
  finally
    Image.Free;
  end;
end;

procedure TA8Media.Flush;
begin
  if not FDiskDirty or (FStorage = nil) then
    Exit;
  FStorage.WriteBytes(FDiskCopy, FData);
  FDiskDirty := False;
end;

function TA8Media.CartHigh: Boolean;
begin
  Result := (FKind = TA8MediaKind.Cartridge) and not FDisabled and not (FMapper in [21, 53, 59]);
end;

function TA8Media.ReadCart(Address: Word; out Value: Byte): Boolean;
begin
  Result := False;
  if (FKind <> TA8MediaKind.Cartridge) or FDisabled or (Address < $8000) or
    (Address >= $C000) then
    Exit;
  var Offset: Integer := Address and $1FFF;
  case FMapper of
    21, 53, 59:
      begin
        if Address >= $A000 then
          Exit;
        if FMapper = 59 then
        begin
          if Address < $9000 then
          begin
            Value := $FF;
            Exit(True);
          end;
          Offset := Address and $FFF;
        end;
      end;
    3, 15, 44, 45:
      begin
        if Address < $A000 then
          Exit;
        var Bank := FBank;
        if Address >= $B000 then
        begin
          Bank := 0;
          if FMapper in [3, 45] then
            Bank := 3;
        end;
        Offset := Address and $FFF;
        if Bank = -1 then
          Value := $FF
        else if Bank < -1 then
        begin
          var Left := 0;
          var Right := 1;
          if Bank = -3 then
            Left := 2;
          if (Bank = -3) or (FMapper = 45) then
            Right := 2 - Ord(Bank = -3);
          Value := FData[Left * $1000 + Offset] and FData[Right * $1000 + Offset];
        end
        else
          Value := FData[Bank * $1000 + Offset];
        Exit(True);
      end;
    18:
      if Address < $9000 then
      begin
        if (Address >= $8FF6) and (Address <= $8FF9) then
          FBank := Address - $8FF6;
        Offset := (Address and $FFF) + FBank * $1000;
      end
      else if Address < $A000 then
      begin
        if (Address >= $9FF6) and (Address <= $9FF9) then
          FBank2 := Address - $9FF6;
        Offset := (Address and $FFF) + (4 + FBank2) * $1000;
      end
      else
        Inc(Offset, $8000);
    2, 40:
      Offset := Address - $8000;
    26..32:
      Offset := Address - $8000 + FBank * $4000;
    5, 12..14, 23..25, 33..38, 67:
      if Address >= $A000 then
        Inc(Offset, FFixedBank * $2000)
      else
      begin
        // The 8–15 board leaves the lower cartridge window undriven until D3 is set.
        if (FMapper = 67) and (FBank and 8 = 0) then
        begin
          Value := $FF;
          Exit(True);
        end;
        Inc(Offset, (FBank and FFixedBank) * $2000);
      end;
  else
    if Address < $A000 then
      Exit;
    case FMapper of
      46:
        Offset := Offset and $FFF;
      57, 58:
        begin
          Offset := $2000 - Length(FData);
          if (Address and $1FFF) < Offset then
          begin
            Value := $FF;
            Exit(True);
          end;
          Offset := (Address and $1FFF) - Offset;
        end;
      8..10, 17, 22, 41, 42, 52, 60, 75, 76:
        Inc(Offset, FBank * $2000);
    end;
  end;
  Value := FData[Offset];
  Result := True;
end;

procedure TA8Media.CartControl(Address: Word; Value: Byte; Writing: Boolean);
begin
  if FKind <> TA8MediaKind.Cartridge then
    Exit;
  case FMapper of
    3, 45:
      begin
        FDisabled := Address and 8 <> 0;
        case Address and 7 of
          0:
            FBank := 0;
          1:
            FBank := -2;
          2, 6:
            FBank := -1;
          3, 7:
            FBank := 1 + Ord(FMapper = 45);
          4:
            FBank := 2 - Ord(FMapper = 45);
          5:
            FBank := -3;
        end;
      end;
    5:
      FBank := Address and FFixedBank;
    67:
      if Writing then
        FBank := Value and $0F;
    12..14, 17, 23..38:
      if Writing then
      begin
        FBank := Value and FFixedBank;
        FDisabled := ((FMapper = 17) or (FMapper >= 26)) and (Value and $80 <> 0);
      end;
    15, 44:
      begin
        FDisabled := Address and 9 = 8;
        case Address and 9 of
          0:
            FBank := 1;
          1:
            FBank := 1 + 2 * Ord(FMapper = 15);
          9:
            FBank := 2 * Ord(FMapper = 15);
        end;
      end;
    8, 22, 76:
      if Address and $F0 = 0 then
      begin
        FBank := Address and FFixedBank;
        FDisabled := Address and 8 <> 0;
      end;
    9, 10:
      if Address and $F0 = ($D0 - (FMapper - 9) * $10) then
      begin
        FBank := (not Address) and 7;
        FDisabled := Address and 8 <> 0;
      end;
    39, 40, 46:
      FDisabled := True;
    52, 60:
      if not FDisabled then
        if FBank < FFixedBank then
          Inc(FBank)
        else
          FDisabled := True;
    42, 75:
      begin
        FBank := Address and FFixedBank;
        FDisabled := Address and $80 <> 0;
      end;
    41:
      if Address and $E0 = 0 then
      begin
        FBank := Address and FFixedBank;
        FDisabled := Address and $10 <> 0;
      end;
  end;
end;

function TA8Media.SectorLocation(Sector: Integer; out Offset, Size: Integer): Boolean;
begin
  Result := (Sector >= 1) and (Sector <= FSectorCount);
  if not Result then
    Exit;
  Size := 128;
  if FFullBootSectors then
    Offset := FDiskOffset + (Sector - 1) * FSectorSize
  else
    Offset := FDiskOffset + (Sector - 1) * 128;
  if Sector > 3 then
  begin
    Size := FSectorSize;
    if not FFullBootSectors then
      Offset := FDiskOffset + 384 + (Sector - 4) * Size;
  end;
end;

procedure TA8Media.ReplyToCommand;
begin
  if (FCommandCount <> 5) or (FCommand[0] <> $31) or
    (SIOChecksum(FCommand, 4) <> FCommand[4]) then
    Exit;
  FReply[0] := Ord('A');
  FReply[1] := Ord('C');
  var Count := 0;
  var ReadDelay := 0;
  case FCommand[1] of
    Ord('S'):
      begin
        FReply[2] := 0;
        if FWriteProtected or (FKind <> TA8MediaKind.Disk) then
          FReply[2] := $08;
        if FSectorSize = 256 then
          FReply[2] := FReply[2] or $20
        else if FSectorCount = 1040 then
          FReply[2] := FReply[2] or $80;
        FReply[3] := FDriveStatus;
        FReply[4] := $E0;
        FReply[5] := 0;
        Count := 4;
      end;
    Ord('N'):
      begin
        FillChar(FReply[2], 12, 0);
        FReply[2] := 40;
        FReply[5] := 18;
        if FSectorCount = 1040 then
          FReply[5] := 26;
        if FSectorSize = 256 then
          FReply[7] := 4;
        FReply[8] := FSectorSize shr 8;
        FReply[9] := FSectorSize and $FF;
        FReply[10] := $FF;
        Count := 12;
      end;
    Ord('P'), Ord('W'):
      begin
        var Sector := FCommand[2] or (Integer(FCommand[3]) shl 8);
        var Offset, Size: Integer;
        if (FKind = TA8MediaKind.Disk) and (Length(FProtectedTracks) = 0) and SectorLocation(Sector, Offset, Size) then
        begin
          FWriteOffset := Offset;
          FWriteSize := Size;
          FCommandCount := 0;
          FReplyCount := 1;
          FReplyIndex := 0;
          FReplyCycles := A8SerialByteCycles * 3;
          Exit;
        end;
      end;
    Ord('R'):
      begin
        var Offset: Integer;
        var Sector := FCommand[2] or (Integer(FCommand[3]) shl 8);
        if Length(FProtectedTracks) <> 0 then
        begin
          if not ReadProtectedSector(Sector, Count, ReadDelay) then
          begin
            FReply[1] := Ord('E');
            if Count = 0 then
            begin
              FReplyCount := 2;
              FReplyIndex := 0;
              FReplyCycles := A8SerialByteCycles * 3;
              Exit;
            end;
          end;
        end
        else if SectorLocation(Sector, Offset, Count) then
        begin
          if FKind = TA8MediaKind.Executable then
          begin
            FillChar(FReply[2], Count, 0);
            Move(XexBootSector, FReply[2], SizeOf(XexBootSector));
          end
          else
            Move(FData[Offset], FReply[2], Count);
        end;
      end;
  end;
  if Count > 0 then
  begin
    FReply[Count + 2] := SIOChecksum(FReply, Count, 2);
    FReplyCount := Count + 3;
  end
  else
  begin
    FReply[0] := Ord('N');
    FReplyCount := 1;
  end;
  FReplyIndex := 0;
  FReplyCycles := A8SerialByteCycles * 3;
  // ACK is sent promptly. The completion byte follows the sector's rotation.
  FReplyDelay := ReadDelay;
end;

procedure TA8Media.SetCommandLine(Asserted: Boolean);
begin
  if not (FKind in [TA8MediaKind.Disk, TA8MediaKind.Executable]) or (FCommandLine = Asserted) then
    Exit;
  FCommandLine := Asserted;
  if Asserted then
  begin
    FCommandCount := 0;
    FWriteSize := 0;
    FReplyCount := 0;
    FReplyIndex := 0;
    FReplyDelay := 0;
  end
  else
    ReplyToCommand;
end;

procedure TA8Media.Transmit(Value: Byte);
begin
  if (FCommandLine and (FCommandCount >= 6)) or
    (not FCommandLine and (FWriteSize = 0)) then
    Exit;
  FCommand[FCommandCount] := Value;
  Inc(FCommandCount);
  if not FCommandLine and (FCommandCount = FWriteSize + 1) then
    FinishWrite;
end;

procedure TA8Media.FinishWrite;
begin
  FReplyCount := 1;
  FReply[0] := Ord('N');
  if SIOChecksum(FCommand, FWriteSize) = FCommand[FWriteSize] then
  begin
    FReplyCount := 2;
    FReply[0] := Ord('A');
    FReply[1] := Ord('E');
    if not FWriteProtected then
    begin
      Move(FCommand[0], FData[FWriteOffset], FWriteSize);
      FDiskDirty := True;
      FReply[1] := Ord('C');
    end;
  end;
  FWriteSize := 0;
  FReplyIndex := 0;
  FReplyCycles := A8SerialByteCycles * 3;
end;

function TA8Media.Clock(out Value: Byte): Boolean;
begin
  Result := False;
  if Length(FProtectedTracks) <> 0 then
  begin
    Inc(FDiskPhase);
    if FDiskPhase = 26042 * 14 then
      FDiskPhase := 0;
  end;
  if FReplyIndex >= FReplyCount then
    Exit;
  Dec(FReplyCycles);
  if FReplyCycles > 0 then
    Exit;
  Value := FReply[FReplyIndex];
  Inc(FReplyIndex);
  FReplyCycles := A8SerialByteCycles;
  if FReplyIndex = 1 then
    Inc(FReplyCycles, A8SerialByteCycles + FReplyDelay);
  Result := True;
end;

procedure TA8Media.SerializeState(State: TStateArchive);
begin
  State.Field(FBank, SizeOf(FBank));
  State.Field(FBank2, SizeOf(FBank2));
  State.Field(FDisabled, SizeOf(FDisabled));
  State.Field(FCommandLine, SizeOf(FCommandLine));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FReply, SizeOf(FReply));
  State.Field(FCommandCount, SizeOf(FCommandCount));
  State.Field(FReplyCount, SizeOf(FReplyCount));
  State.Field(FReplyIndex, SizeOf(FReplyIndex));
  State.Field(FReplyCycles, SizeOf(FReplyCycles));
  State.Field(FWriteOffset, SizeOf(FWriteOffset));
  State.Field(FWriteSize, SizeOf(FWriteSize));
  if FKind = TA8MediaKind.Cassette then
  begin
    State.Field(FTapeBlock, SizeOf(FTapeBlock));
    State.Field(FTapeElapsed, SizeOf(FTapeElapsed));
    State.Field(FTapePulse, SizeOf(FTapePulse));
    State.Field(FTapePulseEnd, SizeOf(FTapePulseEnd));
    if State.Loading and ((FTapeBlock < 0) or (FTapeBlock > Length(FTape)) or
      (FTapeElapsed < 0) or (FTapeElapsed > Int64($20000000000)) or
      (FTapePulse < 0) or (FTapePulse and 1 <> 0) or (FTapePulseEnd < 0) or (FTapePulseEnd > High(Integer)) or
      ((FTapeBlock < Length(FTape)) and (FTapePulse > FTape[FTapeBlock].Count))) then
      raise EReadError.Create('Invalid Atari CAS playback state');
  end
  else if Length(FProtectedTracks) <> 0 then
  begin
    State.Field(FDiskPhase, SizeOf(FDiskPhase));
    State.Field(FReplyDelay, SizeOf(FReplyDelay));
    State.Field(FDriveStatus, SizeOf(FDriveStatus));
    if State.Loading and ((FDiskPhase < 0) or (FDiskPhase >= 26042 * 14)) then
      raise EReadError.Create('Invalid Atari ATX rotational state');
  end
  else if FKind = TA8MediaKind.Disk then
  begin
    if State.Loading then
      Flush;
    State.Field(FData[0], Length(FData));
  end;
end;

end.

