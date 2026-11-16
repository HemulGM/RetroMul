unit J2ME.M3G.Format;

interface

uses
  System.SysUtils;

type
  EM3GFormat = class(Exception);

  TM3GDataReader = class
  private
    FData: TBytes;
    FPosition: Integer;
    function GetRemaining: Integer;
    procedure Need(Count: Integer);
  public
    constructor Create(const Data: TBytes);
    function U8: Byte;
    function U16: Word;
    function I16: SmallInt;
    function U32: UInt32;
    function I32: Integer;
    function Float32: Single;
    function Bool: Boolean;
    function UTF8: string;
    function Bytes(Count: Integer): TBytes;
    function Count(MinimumBytes: Integer = 1; Limit: Integer = 1048576): Integer;
    procedure Finish;
    property Position: Integer read FPosition;
    property Remaining: Integer read GetRemaining;
  end;

  TM3GSerializedObject = record
    // File indices are one-based and include the header and external references.
    Kind: Byte;
    Data: TBytes;
    Section: Integer;
  end;

  TM3GDocument = record
    Objects: TArray<TM3GSerializedObject>;
    HasExternalReferences: Boolean;
    FileSize, ApproximateContentSize: UInt32;
    Authoring: string;
    Sections, CompressedSections, DecodedBytes: Integer;
  end;

function ReadM3GDocument(const Data: TBytes; Offset: Integer = 0; MaxDecodedBytes: Integer = 64 * 1024 * 1024): TM3GDocument;

implementation

uses
  System.Generics.Collections, System.ZLib;

procedure Bad(const Why: string);
begin
  raise EM3GFormat.Create(Why);
end;

constructor TM3GDataReader.Create(const Data: TBytes);
begin
  inherited Create;
  FData := Data;
end;

function TM3GDataReader.GetRemaining: Integer;
begin
  Result := Length(FData) - FPosition;
end;

procedure TM3GDataReader.Need(Count: Integer);
begin
  if (Count < 0) or (Count > Remaining) then
    Bad('Truncated M3G data');
end;

function TM3GDataReader.U8: Byte;
begin
  Need(1);
  Result := FData[FPosition];
  Inc(FPosition);
end;

function TM3GDataReader.U16: Word;
begin
  Need(2);
  Result := Word(FData[FPosition]) or (Word(FData[FPosition + 1]) shl 8);
  Inc(FPosition, 2);
end;

function TM3GDataReader.I16: SmallInt;
begin
  Result := SmallInt(U16);
end;

function TM3GDataReader.U32: UInt32;
begin
  Need(4);
  Result := UInt32(FData[FPosition]) or (UInt32(FData[FPosition + 1]) shl 8) or
    (UInt32(FData[FPosition + 2]) shl 16) or (UInt32(FData[FPosition + 3]) shl 24);
  Inc(FPosition, 4);
end;

function TM3GDataReader.I32: Integer;
begin
  Result := Integer(U32);
end;

function TM3GDataReader.Float32: Single;
begin
  var Bits := U32;
  var Exponent := Bits and $7F800000;
  if (Exponent = $7F800000) or (Bits = $80000000) or
    ((Exponent = 0) and ((Bits and $7FFFFF) <> 0)) then
    Bad('Invalid M3G Float32');
  Move(Bits, Result, SizeOf(Result));
end;

function TM3GDataReader.Bool: Boolean;
begin
  var V := U8;
  if V > 1 then
    Bad('Invalid M3G Boolean');
  Result := V <> 0;
end;

function TM3GDataReader.UTF8: string;
begin
  var Start := FPosition;
  while (FPosition < Length(FData)) and (FData[FPosition] <> 0) do
    Inc(FPosition);
  if FPosition = Length(FData) then
    Bad('Unterminated M3G string');
  var At := Start;
  while At < FPosition do
  begin
    var Lead := FData[At];
    Inc(At);
    if Lead < $80 then
      Continue;
    var Extra := 0;
    var Low: Byte := $80;
    var High: Byte := $BF;
    if (Lead >= $C2) and (Lead <= $DF) then
      Extra := 1
    else if (Lead >= $E0) and (Lead <= $EF) then
    begin
      Extra := 2;
      if Lead = $E0 then
        Low := $A0
      else if Lead = $ED then
        High := $9F;
    end
    else if (Lead >= $F0) and (Lead <= $F4) then
    begin
      Extra := 3;
      if Lead = $F0 then
        Low := $90
      else if Lead = $F4 then
        High := $8F;
    end
    else
      Bad('Invalid M3G UTF-8 lead byte');
    if Extra > FPosition - At then
      Bad('Truncated M3G UTF-8');
    if (FData[At] < Low) or (FData[At] > High) then
      Bad('Invalid M3G UTF-8 scalar');
    Inc(At);
    for var I := 2 to Extra do
    begin
      if (FData[At] < $80) or (FData[At] > $BF) then
        Bad('Invalid M3G UTF-8 continuation');
      Inc(At);
    end;
  end;
  Result := TEncoding.UTF8.GetString(FData, Start, FPosition - Start);
  Inc(FPosition);
end;

function TM3GDataReader.Bytes(Count: Integer): TBytes;
begin
  Need(Count);
  Result := Copy(FData, FPosition, Count);
  Inc(FPosition, Count);
end;

function TM3GDataReader.Count(MinimumBytes, Limit: Integer): Integer;
begin
  var V := U32;
  if (MinimumBytes < 1) or (Limit < 0) then
    Bad('Invalid M3G reader bound');
  if (V > UInt32(Limit)) or (V > UInt32(Remaining div MinimumBytes)) then
    Bad('M3G array exceeds its object');
  Result := Integer(V);
end;

procedure TM3GDataReader.Finish;
begin
  if Remaining <> 0 then
    Bad('Extra M3G object data');
end;

function LE32(const Data: TBytes; Position: Integer): UInt32;
begin
  if (Position < 0) or (Position > Length(Data) - 4) then
    Bad('Truncated M3G section integer');
  Result := UInt32(Data[Position]) or (UInt32(Data[Position + 1]) shl 8) or
    (UInt32(Data[Position + 2]) shl 16) or (UInt32(Data[Position + 3]) shl 24);
end;

function Adler(const Data: TBytes; Position, Count: Integer): UInt32;
begin
  var A: UInt32 := 1;
  var B: UInt32 := 0;
  for var I := Position to Position + Count - 1 do
  begin
    A := (A + Data[I]) mod 65521;
    B := (B + A) mod 65521;
  end;
  Result := (B shl 16) or A;
end;

function InflateSection(const Data: TBytes; Position, Count, Expected: Integer): TBytes;
begin
  SetLength(Result, Expected + 1);
  var Z := Default(z_stream);
  if inflateInit(Z) <> Z_OK then
    Bad('Cannot initialize M3G inflater');
  try
    Z.next_in := @Data[Position];
    Z.avail_in := Count;
    Z.next_out := @Result[0];
    Z.avail_out := Length(Result);
    var Status := inflate(Z, Z_FINISH);
    if (Status <> Z_STREAM_END) or (Z.total_out <> UInt64(Expected)) or (Z.avail_in <> 0) then
      Bad('M3G zlib stream/decoded length');
  finally
    inflateEnd(Z);
  end;
  SetLength(Result, Expected);
end;

function ReadM3GDocument(const Data: TBytes; Offset, MaxDecodedBytes: Integer): TM3GDocument;
const
  Signature: array[0..11] of Byte = ($AB, $4A, $53, $52, $31, $38, $34, $BB, $0D, $0A, $1A, $0A);
begin
  Result := Default(TM3GDocument);
  if (Offset < 0) or (Offset > Length(Data) - Length(Signature)) then
    Bad('Truncated M3G signature');
  if (MaxDecodedBytes < 1) or (MaxDecodedBytes >= MaxInt) then
    Bad('Invalid M3G size limit');
  for var I := 0 to High(Signature) do
    if Data[Offset + I] <> Signature[I] then
      Bad('M3G signature');
  var Objects := TList<TM3GSerializedObject>.Create;
  try
    var Position := Offset + Length(Signature);
    var EndPosition := Length(Data);
    while Position < EndPosition do
    begin
      if EndPosition - Position < 13 then
        Bad('Truncated M3G section');
      var Scheme := Data[Position];
      var Total := LE32(Data, Position + 1);
      var Decoded := LE32(Data, Position + 5);
      if (Scheme > 1) or ((Result.Sections = 0) and (Scheme <> 0)) then
        Bad('M3G compression scheme');
      if (Total < 13) or (Total > UInt32(EndPosition - Position)) then
        Bad('M3G section length');
      if Decoded > UInt32(MaxDecodedBytes - Result.DecodedBytes) then
        Bad('M3G decoded size limit');
      if Adler(Data, Position, Integer(Total) - 4) <> LE32(Data, Position + Integer(Total) - 4) then
        Bad('M3G section checksum');
      var Raw: TBytes;
      if Scheme = 0 then
      begin
        if Decoded <> Total - 13 then
          Bad('M3G uncompressed section length');
        Raw := Copy(Data, Position + 9, Integer(Decoded));
      end
      else
      begin
        Raw := InflateSection(Data, Position + 9, Integer(Total) - 13, Integer(Decoded));
        Inc(Result.CompressedSections);
      end;
      Inc(Result.DecodedBytes, Integer(Decoded));
      var Reader := TM3GDataReader.Create(Raw);
      try
        var Before := Objects.Count;
        while Reader.Remaining > 0 do
        begin
          var Item: TM3GSerializedObject;
          Item.Kind := Reader.U8;
          var Size := Reader.U32;
          if Size > UInt32(Reader.Remaining) then
            Bad('M3G object length');
          if (Item.Kind > 22) and (Item.Kind <> 255) then
            Bad('Reserved M3G object type');
          if (Result.Sections = 0) <> (Item.Kind = 0) then
            Bad('M3G header object position');
          if Result.Sections > 0 then
          begin
            var ExternalSection := Result.HasExternalReferences and (Result.Sections = 1);
            if ExternalSection <> (Item.Kind = 255) then
              Bad('M3G external-reference section position');
          end;
          Item.Data := Reader.Bytes(Integer(Size));
          Item.Section := Result.Sections;
          if Objects.Count >= 65536 then
            Bad('M3G object count limit');
          Objects.Add(Item);
        end;
        if Result.Sections = 0 then
        begin
          if Objects.Count <> 1 then
            Bad('M3G header section must contain exactly one object');
          var Header := TM3GDataReader.Create(Objects[0].Data);
          try
            if (Header.U8 <> 1) or (Header.U8 <> 0) then
              Bad('Unsupported M3G file version');
            Result.HasExternalReferences := Header.Bool;
            Result.FileSize := Header.U32;
            Result.ApproximateContentSize := Header.U32;
            Result.Authoring := Header.UTF8;
            Header.Finish;
          finally
            Header.Free;
          end;
          if (Result.FileSize > UInt32(Length(Data) - Offset)) or
            (Result.FileSize < UInt32(Position - Offset + Integer(Total))) then
            Bad('M3G total file size');
          EndPosition := Offset + Integer(Result.FileSize);
        end
        else if (Result.Sections = 1) and Result.HasExternalReferences and (Objects.Count = Before) then
          Bad('Missing M3G external-reference objects');
      finally
        Reader.Free;
      end;
      Inc(Result.Sections);
      Inc(Position, Integer(Total));
    end;
    if (Result.Sections < 2) or (Objects.Count < 2) then
      Bad('Empty M3G file');
    Result.Objects := Objects.ToArray;
  finally
    Objects.Free;
  end;
end;

end.

