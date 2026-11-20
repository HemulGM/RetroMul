unit A8.Media;

interface

uses
  System.SysUtils, Core.Snapshots, Core.Storage;

type
  TA8MediaKind = (Cartridge, Disk, Executable);

  TA8Segment = record
    Address: Word;
    Offset, Size: Integer;
  end;

  TA8Media = class
  private
    FData: TBytes;
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
    property AutomaticRawMapper: Integer read FAutomaticRawMapper;
    function CartHigh: Boolean;
    function ReadCart(Address: Word; out Value: Byte): Boolean;
    procedure CartControl(Address: Word; Value: Byte; Writing: Boolean);
    procedure SetCommandLine(Asserted: Boolean);
    procedure Transmit(Value: Byte);
    function Clock(out Value: Byte): Boolean;
    procedure SerializeState(State: TStateArchive);
    property Data: TBytes read FData;
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
  System.Classes, System.Generics.Collections, System.ZLib;

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
    ImageSize := (ReadWordLE(FData, 2) + (Integer(FData[6]) shl 16)) * 16;
    if (ImageSize <= 0) or (ImageSize > Length(FData) - FDiskOffset) then
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
    $10000, $20000:
      // Known XEGS dumps from the MAME xegs software list (CC0-1.0).
      case crc32(0, @Data[0], Length(Data)) of
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
end;

procedure TA8Media.AttachDisk(const Storage: IStorage; const DiskCopy: string; WriteProtected: Boolean);
begin
  FWriteProtected := WriteProtected or (FKind <> TA8MediaKind.Disk) or
    ((FDiskOffset = 16) and (FData[15] and 1 <> 0));
  if (FKind <> TA8MediaKind.Disk) or (Storage = nil) or (DiskCopy = '') then
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
        FReply[3] := $FF;
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
        if (FKind = TA8MediaKind.Disk) and SectorLocation(Sector, Offset, Size) then
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
        if SectorLocation(Sector, Offset, Count) then
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
end;

procedure TA8Media.SetCommandLine(Asserted: Boolean);
begin
  if (FKind = TA8MediaKind.Cartridge) or (FCommandLine = Asserted) then
    Exit;
  FCommandLine := Asserted;
  if Asserted then
  begin
    FCommandCount := 0;
    FWriteSize := 0;
    FReplyCount := 0;
    FReplyIndex := 0;
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
  if FReplyIndex >= FReplyCount then
    Exit;
  Dec(FReplyCycles);
  if FReplyCycles > 0 then
    Exit;
  Value := FReply[FReplyIndex];
  Inc(FReplyIndex);
  FReplyCycles := A8SerialByteCycles;
  if FReplyIndex = 1 then
    Inc(FReplyCycles, A8SerialByteCycles);
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
  if FKind = TA8MediaKind.Disk then
  begin
    if State.Loading then
      Flush;
    State.Field(FData[0], Length(FData));
  end;
end;

end.

