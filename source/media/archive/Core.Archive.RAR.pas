unit Core.Archive.RAR;

interface

uses
  System.Classes, System.SysUtils, Core.Storage, Core.Archive.Container;

function IsRarArchive(Input: TStream): Boolean;

function OpenRar(Input: TStream; const Storage: IStorage): IArchiveContainer;

implementation

uses
  System.Generics.Collections, System.Generics.Defaults, Core.RAR.Types,
  Core.RAR.Unpack, Core.RAR.Blake2;

const
  MaxUnpacked = Int64(4) * 1024 * 1024 * 1024;
  MaxDictionary = UInt64(256) * 1024 * 1024;
  MaxEntries = 4096;
  MaxHeader = 2 * 1024 * 1024;

type
  TRarHeader = record
    Data: TBytes;
    Position: Integer;
    function ByteValue: Byte;
    function WordValue: Word;
    function DWordValue: Cardinal;
    function VarUInt: UInt64;
    function Bytes(Count: Int64): TBytes;
  end;

  TRarEntry = record
    Name: string;
    Offset, PackedSize, Size: Int64;
    Dictionary: UInt64;
    CRC: Cardinal;
    HasCRC, Solid: Boolean;
    Hash: TBytes;
    Method, Version: Integer;
  end;

  TRarIO = class(TComprDataIO)
  public
    Input, Output: TStream;
    PackedEnd, Expected, Written: Int64;
    CRC: Cardinal;
    Hash: TRarBlake2sp;
    destructor Destroy; override;
    function UnpRead(Addr: PByte; Count: Integer): Integer; override;
    procedure UnpWrite(Addr: PByte; Count: NativeUInt); override;
  end;

  TRarReader = class(TArchiveContainer)
  private
    FInput: TStream;
    FEntries: TList<TRarEntry>;
    FNames: TDictionary<string, Boolean>;
    FLimit, FTotal, FNameBytes: Int64;
    FStart: Int64;
    procedure Parse4;
    procedure Parse5;
    procedure Add(const Entry: TRarEntry);
    procedure UnpackEntries;
  public
    constructor Create(Input: TStream; Limit: Int64; const Storage: IStorage);
    destructor Destroy; override;
  end;

var
  CRCTable: array[0..255] of Cardinal;

procedure Invalid(const Text: string);
begin
  raise EReadError.Create('RAR: ' + Text);
end;

procedure Unsupported(const Text: string);
begin
  raise ENotSupportedException.Create('RAR: ' + Text);
end;

function CRCUpdate(CRC: Cardinal; Data: PByte; Count: NativeUInt): Cardinal;
begin
  Result := CRC;
  while Count > 0 do
  begin
    Result := (Result shr 8) xor CRCTable[(Result xor Data^) and $FF];
    Inc(Data);
    Dec(Count);
  end;
end;

function CRCBytes(const Data: TBytes; Offset, Count: Integer): Cardinal;
begin
  Result := $FFFFFFFF;
  if Count > 0 then
    Result := CRCUpdate(Result, @Data[Offset], Count);
  Result := not Result;
end;

function TRarHeader.Bytes(Count: Int64): TBytes;
begin
  if (Count < 0) or (Count > Length(Data) - Position) then
    Invalid('truncated header');
  Result := Copy(Data, Position, Count);
  Inc(Position, Count);
end;

function TRarHeader.ByteValue: Byte;
begin
  if Position >= Length(Data) then
    Invalid('truncated header');
  Result := Data[Position];
  Inc(Position);
end;

function TRarHeader.WordValue: Word;
begin
  Result := ByteValue;
  Result := Result or (Word(ByteValue) shl 8);
end;

function TRarHeader.DWordValue: Cardinal;
begin
  Result := WordValue;
  Result := Result or (Cardinal(WordValue) shl 16);
end;

function TRarHeader.VarUInt: UInt64;
begin
  Result := 0;
  for var I := 0 to 9 do
  begin
    var B := ByteValue;
    if (I = 9) and (B > 1) then
      Invalid('integer overflow');
    Result := Result or (UInt64(B and $7F) shl (I * 7));
    if B and $80 = 0 then
      Exit;
  end;
  Invalid('invalid variable integer');
end;

function StreamVarUInt(Input: TStream): UInt64;
begin
  Result := 0;
  for var I := 0 to 9 do
  begin
    var B: Byte;
    ReadArchiveBuffer(Input, B, 1);
    if (I = 9) and (B > 1) then
      Invalid('integer overflow');
    Result := Result or (UInt64(B and $7F) shl (I * 7));
    if B and $80 = 0 then
      Exit;
  end;
  Invalid('invalid variable integer');
end;

function Bounded(Value: UInt64; Limit: Int64; const What: string): Int64;
begin
  if Value > UInt64(Limit) then
    Invalid(What + ' exceeds its limit');
  Result := Value;
end;

function DecodeName4(const Data: TBytes; Unicode: Boolean; Host: Byte): string;
begin
  var Split := 0;
  while (Split < Length(Data)) and (Data[Split] <> 0) do
    Inc(Split);
  if not Unicode then
  begin
    if Host = 3 then
    begin
      if Length(Data) = 0 then
        Exit('');
      if TEncoding.UTF8.IsBufferValid(@Data[0], Length(Data)) then
        Exit(TEncoding.UTF8.GetString(Data));
    end;
    Exit(TEncoding.Default.GetString(Data));
  end;
  if Split = Length(Data) then
    Exit(TEncoding.UTF8.GetString(Data));
  var Encoded: TRarHeader;
  Encoded.Data := Copy(Data, Split + 1, Length(Data) - Split - 1);
  Encoded.Position := 0;
  if Length(Encoded.Data) = 0 then
    Invalid('empty Unicode name');
  var HighByte := Word(Encoded.ByteValue) shl 8;
  var Flags, Left: Integer;
  Flags := 0;
  Left := 0;
  Result := '';
  while Encoded.Position < Length(Encoded.Data) do
  begin
    if Left = 0 then
    begin
      Flags := Encoded.ByteValue;
      Left := 4;
    end;
    var Ch: Word;
    case (Flags shr 6) and 3 of
      0:
        Result := Result + Char(Encoded.ByteValue);
      1:
        Result := Result + Char(HighByte or Encoded.ByteValue);
      2:
        Result := Result + Char(Encoded.WordValue);
      3:
        begin
          var Count := Integer(Encoded.ByteValue);
          var Correction := 0;
          if Count and $80 <> 0 then
            Correction := Encoded.ByteValue;
          var Corrected := Count and $80 <> 0;
          Count := (Count and $7F) + 2;
          for var I := 1 to Count do
          begin
            if Length(Result) >= Split then
              Invalid('invalid Unicode name run');
            Ch := Data[Length(Result)];
            if Corrected then
              Ch := HighByte or ((Ch + Correction) and $FF);
            Result := Result + Char(Ch);
          end;
        end;
    end;
    Flags := (Flags shl 2) and $FF;
    Dec(Left);
  end;
end;

constructor TRarReader.Create(Input: TStream; Limit: Int64; const Storage: IStorage);
begin
  inherited Create(Storage);
  FInput := Input;
  FLimit := Limit;
  FEntries := TList<TRarEntry>.Create;
  FNames := TDictionary<string, Boolean>.Create(TIStringComparer.Ordinal);
  if (Input = nil) or (Input.Size < 7) or (Input.Size > MaxUnpacked) then
    Invalid('invalid container size');
  var Signature: TBytes;
  var PrefixSize := Input.Size;
  if PrefixSize > 1024 * 1024 + 8 then
    PrefixSize := 1024 * 1024 + 8;
  SetLength(Signature, PrefixSize);
  Input.Position := 0;
  ReadArchiveBuffer(Input, Signature[0], Length(Signature));
  // SFX signatures are metadata too; no executable is ever started.
  for var I := 0 to Length(Signature) - 7 do
  begin
    if I and $FFF = 0 then
      TStorage.CheckReadCancelled;
    if (Signature[I] = $52) and (Signature[I + 1] = $61) and (Signature[I + 2] = $72) and
      (Signature[I + 3] = $21) and (Signature[I + 4] = $1A) and (Signature[I + 5] = $07) then
    begin
      FStart := I;
      if Signature[I + 6] = 0 then
      begin
        Parse4;
        Exit;
      end;
      if (I + 7 < Length(Signature)) and (Signature[I + 6] = 1) and (Signature[I + 7] = 0) then
      begin
        Parse5;
        Exit;
      end;
    end;
  end;
  Invalid('invalid signature');
end;

destructor TRarReader.Destroy;
begin
  FNames.Free;
  FEntries.Free;
  inherited;
end;

procedure TRarReader.Add(const Entry: TRarEntry);
begin
  if (Entry.Name = '') or Entry.Name.Contains(#0) then
    Invalid('invalid entry name');
  if (FEntries.Count >= MaxEntries) or (Entry.Size < 0) or
    (Entry.Size > FLimit - FTotal) then
    Invalid('unpacked data or entry count exceeds limit');
  if (Entry.Offset < 0) or (Entry.Offset > FInput.Size) or (Entry.PackedSize < 0) or
    (Entry.PackedSize > FInput.Size - Entry.Offset) then
    Invalid('truncated file data');
  if Entry.Dictionary > MaxDictionary then
    Unsupported('dictionary exceeds 256 MiB');
  if (Entry.Method = 0) and (Entry.PackedSize <> Entry.Size) then
    Invalid('stored size mismatch');
  if FNames.ContainsKey(Entry.Name) then
    Invalid('duplicate entry name');
  Inc(FNameBytes, Int64(Length(Entry.Name)) * SizeOf(Char));
  if FNameBytes > 16 * 1024 * 1024 then
    Invalid('archive metadata exceeds 16 MiB');
  FNames.Add(Entry.Name, True);
  FEntries.Add(Entry);
  Inc(FTotal, Entry.Size);
end;

procedure TRarReader.Parse4;
begin
  FInput.Position := FStart + 7;
  var MainSeen := False;
  while FInput.Position < FInput.Size do
  begin
    TStorage.CheckReadCancelled;
    var Start := FInput.Position;
    var Base: array[0..6] of Byte;
    ReadArchiveBuffer(FInput, Base, SizeOf(Base));
    var HeaderSize := Integer(Base[5]) or (Integer(Base[6]) shl 8);
    if (HeaderSize < 7) or (HeaderSize > FInput.Size - Start) then
      Invalid('invalid header size');
    var H: TRarHeader;
    SetLength(H.Data, HeaderSize);
    H.Position := 0;
    FInput.Position := Start;
    ReadArchiveBuffer(FInput, H.Data[0], HeaderSize);
    var ExpectedCRC := H.WordValue;
    var Kind := H.ByteValue;
    var Flags := H.WordValue;
    H.WordValue;
    var CRCSize := HeaderSize;
    // Old embedded comment subheaders have their own CRC.
    if (Kind = $73) and (Flags and 2 <> 0) then
      CRCSize := 13;
    if (Kind = $74) and (Flags and 8 <> 0) and (HeaderSize >= 32) then
    begin
      CRCSize := 32 + (Integer(H.Data[26]) or (Integer(H.Data[27]) shl 8));
      if Flags and $100 <> 0 then
        Inc(CRCSize, 8);
    end;
    if (CRCSize > HeaderSize) or (CRCSize < 7) then
      Invalid('invalid header CRC span');
    var HeaderCRC := not CRCUpdate($FFFFFFFF, @H.Data[2], CRCSize - 2);
    if (Kind = $77) and (Flags and $8000 <> 0) then
    begin
      // RAR 2.x subblocks include their short data area in the header CRC.
      var Sub: TRarHeader;
      Sub.Data := H.Data;
      Sub.Position := 7;
      var Count := Sub.DWordValue;
      if (Count > MaxHeader) or (Count > FInput.Size - FInput.Position) then
        Invalid('truncated subblock');
      var Data: TBytes;
      SetLength(Data, Count);
      if Count > 0 then
        ReadArchiveBuffer(FInput, Data[0], Count);
      var Running := not HeaderCRC;
      if Count > 0 then
        Running := CRCUpdate(Running, @Data[0], Count);
      HeaderCRC := not Running;
    end;
    if HeaderCRC and $FFFF <> ExpectedCRC then
      Invalid('header CRC mismatch');
    var DataSize: Int64 := 0;
    case Kind of
      $73:
        begin
          if MainSeen or (HeaderSize < 13) then
            Invalid('invalid main header');
          MainSeen := True;
          if Flags and 1 <> 0 then
            Unsupported('multi-volume archives are not supported');
          if Flags and $80 <> 0 then
            Unsupported('encrypted archives are not supported');
        end;
      $74:
        begin
          if not MainSeen then
            Invalid('file precedes main header');
          var E := Default(TRarEntry);
          E.PackedSize := H.DWordValue;
          E.Size := H.DWordValue;
          var Host := H.ByteValue;
          E.CRC := H.DWordValue;
          E.HasCRC := True;
          H.DWordValue;
          E.Version := H.ByteValue;
          E.Method := H.ByteValue - $30;
          var NameSize := H.WordValue;
          var Attributes := H.DWordValue;
          if Flags and $100 <> 0 then
          begin
            E.PackedSize := E.PackedSize or (Int64(H.DWordValue) shl 32);
            E.Size := E.Size or (Int64(H.DWordValue) shl 32);
          end;
          E.Name := DecodeName4(H.Bytes(NameSize), Flags and $200 <> 0, Host).Replace('\', '/');
          E.Offset := Start + HeaderSize;
          E.Solid := Flags and $10 <> 0;
          E.Dictionary := UInt64($10000) shl ((Flags shr 5) and 7);
          DataSize := E.PackedSize;
          if Flags and 3 <> 0 then
            Unsupported('split files are not supported');
          if Flags and 4 <> 0 then
            Unsupported('encrypted files are not supported');
          if (E.Method < 0) or (E.Method > 5) or
            ((E.Method <> 0) and not (E.Version in [15, 20, 26, 29, 36])) then
            Unsupported('compression method or version is not supported');
          if E.Version = 36 then
            E.Version := 29;
          var Directory := Flags and $E0 = $E0;
          if Host = 3 then
            Directory := Directory or (Attributes and $F000 = $4000)
          else
            Directory := Directory or (Attributes and $10 <> 0);
          // Links are not regular ROM data and are never followed or created.
          if not Directory and not ((Host = 3) and (Attributes and $F000 = $A000)) then
            Add(E);
        end;
      $7B:
        begin
          if Flags and 1 <> 0 then
            Unsupported('multi-volume archives are not supported');
          if not MainSeen then
            Invalid('end precedes main header');
          Exit;
        end;
    else
      if Flags and $8000 <> 0 then
        DataSize := H.DWordValue;
    end;
    if (DataSize < 0) or (DataSize > FInput.Size - Start - HeaderSize) then
      Invalid('truncated data block');
    FInput.Position := Start + HeaderSize + DataSize;
  end;
  // RAR 1.5/2.x archives may have no explicit ENDARC block.
  if not MainSeen then
    Invalid('missing main header');
end;

procedure TRarReader.Parse5;
begin
  FInput.Position := FStart + 8;
  var MainSeen := False;
  while FInput.Position < FInput.Size do
  begin
    TStorage.CheckReadCancelled;
    var ExpectedCRC: Cardinal;
    ReadArchiveBuffer(FInput, ExpectedCRC, 4);
    var CRCStart := FInput.Position;
    var HeaderSize := Bounded(StreamVarUInt(FInput), MaxHeader, 'header');
    var SizeBytes := FInput.Position - CRCStart;
    if (HeaderSize < 2) or (HeaderSize > FInput.Size - FInput.Position) then
      Invalid('truncated header');
    var H: TRarHeader;
    SetLength(H.Data, SizeBytes + HeaderSize);
    H.Position := 0;
    FInput.Position := CRCStart;
    ReadArchiveBuffer(FInput, H.Data[0], Length(H.Data));
    if CRCBytes(H.Data, 0, Length(H.Data)) <> ExpectedCRC then
      Invalid('header CRC mismatch');
    H.VarUInt;
    var Kind := H.VarUInt;
    var Flags := H.VarUInt;
    var ExtraSize: Int64 := 0;
    if Flags and 1 <> 0 then
      ExtraSize := Bounded(H.VarUInt, HeaderSize, 'extra header');
    var DataSize: Int64 := 0;
    if Flags and 2 <> 0 then
      DataSize := Bounded(H.VarUInt, MaxUnpacked, 'packed data');
    if Flags and $18 <> 0 then
      Unsupported('split files are not supported');
    var DataStart := FInput.Position;
    if DataSize > FInput.Size - DataStart then
      Invalid('truncated data block');
    var ExtraStart := Length(H.Data) - ExtraSize;
    case Kind of
      1:
        begin
          if MainSeen then
            Invalid('duplicate main header');
          MainSeen := True;
          if H.VarUInt and 1 <> 0 then
            Unsupported('multi-volume archives are not supported');
        end;
      2:
        begin
          if not MainSeen then
            Invalid('file precedes main header');
          var E := Default(TRarEntry);
          var FileFlags := H.VarUInt;
          if FileFlags and 8 <> 0 then
            Unsupported('unknown unpacked size is not supported');
          E.Size := Bounded(H.VarUInt, FLimit, 'file');
          var Attributes := H.VarUInt;
          if FileFlags and 2 <> 0 then
            H.DWordValue;
          E.HasCRC := FileFlags and 4 <> 0;
          if E.HasCRC then
            E.CRC := H.DWordValue;
          var Compression := H.VarUInt;
          var Host := H.VarUInt;
          var NameSize := Bounded(H.VarUInt, 65535, 'filename');
          E.Name := TEncoding.UTF8.GetString(H.Bytes(NameSize)).Replace('\', '/');
          if H.Position > ExtraStart then
            Invalid('file fields overlap extra area');
          E.Offset := DataStart;
          E.PackedSize := DataSize;
          E.Method := (Compression shr 7) and 7;
          E.Solid := Compression and $40 <> 0;
          E.Version := 50;
          if Compression and $3F > 1 then
            Unsupported('compression version is not supported');
          if (Compression and $3F = 1) and (Compression and $100000 = 0) then
            E.Version := 70;
          var DictBits := Integer((Compression shr 10) and $1F);
          if DictBits > 11 then
            Unsupported('dictionary exceeds 256 MiB');
          E.Dictionary := UInt64($20000) shl DictBits;
          if Compression and $3F = 1 then
            Inc(E.Dictionary, (E.Dictionary div 32) * ((Compression shr 15) and $1F));
          if E.Method > 5 then
            Unsupported('compression method is not supported');
          var IsLink := (Host = 1) and (Attributes and $F000 = $A000);
          H.Position := ExtraStart;
          while H.Position < Length(H.Data) do
          begin
            var Size := Bounded(H.VarUInt, Length(H.Data) - H.Position, 'extra record');
            if Size = 0 then
              Invalid('empty extra record');
            var Last := H.Position + Size;
            if Last > Length(H.Data) then
              Invalid('truncated extra record');
            var RecordKind := H.VarUInt;
            case RecordKind of
              1:
                Unsupported('encrypted files are not supported');
              2:
                begin
                  if H.VarUInt <> 0 then
                    Unsupported('file hash algorithm is not supported');
                  E.Hash := H.Bytes(32);
                end;
              4:
                begin
                  H.VarUInt; // version flags
                  var Version := H.VarUInt;
                  if Version > 0 then
                    E.Name := E.Name + ';' + UIntToStr(Version);
                end;
              5:
                IsLink := True;
            end;
            if H.Position > Last then
              Invalid('truncated extra record');
            H.Position := Last;
          end;
          if (FileFlags and 1 <> 0) and ((E.Size <> 0) or (DataSize <> 0)) then
            Invalid('directory has file data');
          if (FileFlags and 1 = 0) and not IsLink then
            Add(E);
        end;
      4:
        Unsupported('encrypted archives are not supported');
      5:
        begin
          if not MainSeen then
            Invalid('end precedes main header');
          if H.VarUInt and 1 <> 0 then
            Unsupported('multi-volume archives are not supported');
          Exit;
        end;
    else
      // Service blocks (comments, recovery records, quick-open indexes) do
      // not alter the solid dictionary. Unknown mandatory blocks are rejected.
      if (Kind <> 3) and (Flags and 4 = 0) then
        Unsupported('unknown mandatory block');
    end;
    FInput.Position := DataStart + DataSize;
  end;
  Invalid('missing end of archive');
end;

destructor TRarIO.Destroy;
begin
  Hash.Free;
  inherited;
end;

function TRarIO.UnpRead(Addr: PByte; Count: Integer): Integer;
begin
  TStorage.CheckReadCancelled;
  if Count < 0 then
    Invalid('invalid read count');
  var Remaining := PackedEnd - Input.Position;
  if Remaining < 0 then
    Invalid('read beyond packed data');
  if Remaining < Count then
    Count := Remaining;
  Result := Input.Read(Addr^, Count);
  if (Result < 0) or (Result > Count) then
    Invalid('invalid read result');
end;

procedure TRarIO.UnpWrite(Addr: PByte; Count: NativeUInt);
begin
  TStorage.CheckReadCancelled;
  if UInt64(Count) > UInt64(Expected - Written) then
    Invalid('unpacked size exceeds header');
  if Count = 0 then
    Exit;
  CRC := CRCUpdate(CRC, Addr, Count);
  if Hash <> nil then
    Hash.Update(Addr, Count);
  Output.WriteBuffer(Addr^, Count);
  Inc(Written, Int64(Count));
end;

procedure TRarReader.UnpackEntries;
begin
  var IO := TRarIO.Create;
  var Unpacker := TUnpack.Create(IO);
  try
    IO.Input := FInput;
    for var Index := 0 to FEntries.Count - 1 do
    begin
      TStorage.CheckReadCancelled;
      var E := FEntries[Index];
      var Info := Default(TArchiveEntry);
      Info.Name := E.Name;
      Info.Size := E.Size;
      Info.HasCRC := E.HasCRC;
      Info.CRC32 := E.CRC;
      AddEntry(Info);
      var Item := BeginEntry(Index);
      try
        FInput.Position := E.Offset;
        IO.Output := Item;
        IO.PackedEnd := E.Offset + E.PackedSize;
        IO.Expected := E.Size;
        IO.Written := 0;
        IO.CRC := $FFFFFFFF;
        FreeAndNil(IO.Hash);
        if Length(E.Hash) > 0 then
          IO.Hash := TRarBlake2sp.Create;
        if E.Method = 0 then
        begin
          var Buffer: array[0..65535] of Byte;
          while IO.Written < E.Size do
          begin
            var Count := IO.UnpRead(@Buffer[0], SizeOf(Buffer));
            if Count = 0 then
              Invalid('truncated stored data');
            IO.UnpWrite(@Buffer[0], Count);
          end;
        end
        else
        begin
          Unpacker.Init(E.Dictionary, E.Solid);
          Unpacker.SetDestSize(E.Size);
          Unpacker.DoUnpack(E.Version, E.Solid);
        end;
        if IO.Written <> E.Size then
          Invalid(Format('unpacked size mismatch (%d of %d): %s', [IO.Written, E.Size, E.Name]));
        if E.HasCRC and ((not IO.CRC) <> E.CRC) then
          Invalid('file CRC mismatch: ' + E.Name);
        if IO.Hash <> nil then
        begin
          var Hash := IO.Hash.Digest;
          if not CompareMem(@Hash[0], @E.Hash[0], 32) then
            Invalid('file BLAKE2sp mismatch');
        end;
      finally
        IO.Output := nil;
        Item.Free;
      end;
      CompleteEntry(Index, not IO.CRC);
    end;
  finally
    Unpacker.Free;
    IO.Free;
  end;
end;

function IsRarArchive(Input: TStream): Boolean;
begin
  if Input = nil then raise EArgumentNilException.Create('Input');
  var Saved := Input.Position;
  try
    Input.Position := 0;
    var Prefix: array[0..3] of Byte;
    if Input.Size < 7 then Exit(False);
    ReadArchiveBuffer(Input, Prefix, SizeOf(Prefix));
    var Executable := ((Prefix[0] = $4D) and (Prefix[1] = $5A)) or
      ((Prefix[0] = $7F) and (Prefix[1] = $45) and (Prefix[2] = $4C) and (Prefix[3] = $46));
    Input.Position := 0;
    var N := Input.Size;
    if not Executable and (N > 8) then N := 8;
    if N > 1024 * 1024 + 8 then N := 1024 * 1024 + 8;
    var Data: TBytes;
    SetLength(Data, N);
    if N <> 0 then ReadArchiveBuffer(Input, Data[0], Length(Data));
    for var I := 0 to Length(Data) - 7 do
    begin
      if I and $FFF = 0 then TStorage.CheckReadCancelled;
      if (Data[I] = $52) and (Data[I + 1] = $61) and (Data[I + 2] = $72) and
        (Data[I + 3] = $21) and (Data[I + 4] = $1A) and (Data[I + 5] = $07) and
        ((Data[I + 6] = 0) or ((I + 7 < Length(Data)) and (Data[I + 6] = 1) and (Data[I + 7] = 0))) then Exit(True);
    end;
    Result := False;
  finally Input.Position := Saved; end;
end;

function OpenRar(Input: TStream; const Storage: IStorage): IArchiveContainer;
begin
  if Input = nil then raise EArgumentNilException.Create('Input');
  var Saved := Input.Position;
  try
    var Reader := TRarReader.Create(Input, MaxUnpacked, Storage);
    try
      Reader.UnpackEntries;
      Reader.FInput := nil;
    except
      Reader.Free;
      raise;
    end;
    Result := Reader;
  finally
    Input.Position := Saved;
  end;
end;

initialization
  for var I := 0 to 255 do
  begin
    var V := Cardinal(I);
    for var J := 0 to 7 do
      if V and 1 <> 0 then
        V := (V shr 1) xor $EDB88320
      else
        V := V shr 1;
    CRCTable[I] := V;
  end;

end.

