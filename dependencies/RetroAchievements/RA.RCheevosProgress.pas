unit RA.RCheevosProgress;

interface

{$SCOPEDENUMS ON}

uses
  System.SysUtils;

const
  RCProgressMinimumSize = 4 + 8 + 16;
  RCProgressMagic = $0A504152; // RAP + LF
  RCProgressMemrefs = $4645524D; // MREF
  RCProgressVariables = $53524156; // VARS
  RCProgressAchievement = $56484341; // ACHV
  RCProgressLeaderboard = $4452424C; // LBRD
  RCProgressRichPresence = $48434952; // RICH

type
  TRAProgressReadStatus = (Success, InsufficientBuffer, InvalidData);

  TRAProgressDigest = array[0..15] of Byte;

  TRAProgressChunk = record
    Kind: Cardinal;
    Data: TBytes;
    class function Create(AKind: Cardinal; const AData: TBytes): TRAProgressChunk; static;
  end;

function RAProgressDigest(const Definition: string): TRAProgressDigest;

function IsRCProgress(const Data: TBytes): Boolean;

function RCProgressEncodedSize(const Chunks: array of TRAProgressChunk): NativeUInt;

function EncodeRCProgress(const Chunks: array of TRAProgressChunk): TBytes; overload;

function EncodeRCProgress(const Chunks: array of TRAProgressChunk; Buffer: PByte; BufferSize: NativeUInt): Boolean; overload;

function DecodeRCProgress(const Data: TBytes; out Chunks: TArray<TRAProgressChunk>): TRAProgressReadStatus; overload;

function DecodeRCProgress(Buffer: PByte; BufferSize: NativeUInt; out Chunks: TArray<TRAProgressChunk>): TRAProgressReadStatus; overload;

function TryDecodeRCProgress(const Data: TBytes; out Chunks: TArray<TRAProgressChunk>): Boolean;

implementation

uses
  System.Generics.Collections, System.Hash, RA.Progress;

const
  RCProgressDone = $454E4F44; // DONE
  RCProgressChunkHeaderSize = 2 * SizeOf(Cardinal);

function DigestBytes(Buffer: PByte; Count: NativeUInt): TRAProgressDigest;
var
  Hash: THashMD5;
  Bytes: TBytes;
  BlockSize: Integer;
begin
  Hash := THashMD5.Create;
  while Count <> 0 do
  begin
    if Count > NativeUInt(High(Integer)) then
      BlockSize := High(Integer)
    else
      BlockSize := Integer(Count);
    Hash.Update(Buffer^, BlockSize);
    Inc(Buffer, BlockSize);
    Dec(Count, BlockSize);
  end;
  Bytes := Hash.HashAsBytes;
  Move(Bytes[0], Result, SizeOf(Result));
end;

function RAProgressDigest(const Definition: string): TRAProgressDigest;
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Definition);
  Result := DigestBytes(PByte(Bytes), Length(Bytes));
end;

class function TRAProgressChunk.Create(AKind: Cardinal; const AData: TBytes): TRAProgressChunk;
begin
  Result.Kind := AKind;
  Result.Data := AData;
end;

function IsRCProgress(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 4) and (Data[0] = Ord('R')) and (Data[1] = Ord('A')) and
    (Data[2] = Ord('P')) and (Data[3] = 10);
end;

function RCProgressEncodedSize(const Chunks: array of TRAProgressChunk): NativeUInt;
var
  Size: UInt64;
begin
  Size := RCProgressMinimumSize;
  for var Chunk in Chunks do
  begin
    if Chunk.Kind = RCProgressDone then
      raise ERAProgressError.Create('The DONE chunk belongs to the progress envelope');
    {$IFDEF CPU64BITS}
    if Length(Chunk.Data) > High(Integer) then
      raise ERAProgressError.Create('RetroAchievements progress section is too large');
    {$ENDIF}
    Inc(Size, RCProgressChunkHeaderSize + UInt64(Length(Chunk.Data)));
    if Size > High(Cardinal) then
      raise ERAProgressError.Create('RetroAchievements progress is too large');
  end;
  Result := NativeUInt(Size);
end;

procedure WriteProgressUInt(var Buffer: PByte; Value: Cardinal);
begin
  for var Index := 0 to SizeOf(Value) - 1 do
  begin
    Buffer^ := Byte(Value and $FF);
    Inc(Buffer);
    Value := Value shr 8;
  end;
end;

procedure WriteRCProgress(const Chunks: array of TRAProgressChunk; Buffer: PByte);
var
  Cursor: PByte;
  PayloadSize: Integer;
  Digest: TRAProgressDigest;
begin
  Cursor := Buffer;
  WriteProgressUInt(Cursor, RCProgressMagic);
  for var Chunk in Chunks do
  begin
    PayloadSize := Length(Chunk.Data);
    WriteProgressUInt(Cursor, Chunk.Kind);
    WriteProgressUInt(Cursor, PayloadSize);
    if PayloadSize <> 0 then
    begin
      Move(Chunk.Data[0], Cursor^, PayloadSize);
      Inc(Cursor, PayloadSize);
    end;
  end;
  WriteProgressUInt(Cursor, RCProgressDone);
  WriteProgressUInt(Cursor, SizeOf(Digest));
  Digest := DigestBytes(Buffer, NativeUInt(Cursor) - NativeUInt(Buffer));
  Move(Digest, Cursor^, SizeOf(Digest));
end;

function EncodeRCProgress(const Chunks: array of TRAProgressChunk): TBytes;
var
  Size: NativeUInt;
begin
  Size := RCProgressEncodedSize(Chunks);
  if Size > NativeUInt(High(NativeInt)) then
    raise ERAProgressError.Create('RetroAchievements progress is too large');
  SetLength(Result, NativeInt(Size));
  WriteRCProgress(Chunks, PByte(Result));
end;

function EncodeRCProgress(const Chunks: array of TRAProgressChunk; Buffer: PByte; BufferSize: NativeUInt): Boolean;
begin
  Result := (Buffer <> nil) and (BufferSize >= RCProgressEncodedSize(Chunks));
  if Result then
    WriteRCProgress(Chunks, Buffer);
end;

function DecodeRCProgress(const Data: TBytes; out Chunks: TArray<TRAProgressChunk>): TRAProgressReadStatus;
begin
  Result := DecodeRCProgress(PByte(Data), Length(Data), Chunks);
end;

function ReadProgressUInt(Buffer: PByte): Cardinal;
begin
  Result := Cardinal(Buffer[0]) or (Cardinal(Buffer[1]) shl 8) or
    (Cardinal(Buffer[2]) shl 16) or (Cardinal(Buffer[3]) shl 24);
end;

function DecodeRCProgress(Buffer: PByte; BufferSize: NativeUInt; out Chunks: TArray<TRAProgressChunk>): TRAProgressReadStatus;
var
  Offset: NativeUInt;
  Kind, PayloadSize: Cardinal;
  Payload: TBytes;
  Digest: TRAProgressDigest;
  Parsed: TList<TRAProgressChunk>;
begin
  Chunks := nil;
  if (Buffer = nil) or (BufferSize < RCProgressMinimumSize) then
    Exit(TRAProgressReadStatus.InsufficientBuffer);
  if ReadProgressUInt(Buffer) <> RCProgressMagic then
    Exit(TRAProgressReadStatus.InvalidData);

  Offset := SizeOf(Cardinal);
  Parsed := TList<TRAProgressChunk>.Create;
  try
    while BufferSize - Offset >= RCProgressChunkHeaderSize do
    begin
      Kind := ReadProgressUInt(Buffer + Offset);
      PayloadSize := ReadProgressUInt(Buffer + Offset + SizeOf(Cardinal));
      Inc(Offset, RCProgressChunkHeaderSize);
      if PayloadSize > BufferSize - Offset then
        Exit(TRAProgressReadStatus.InsufficientBuffer);
      case Kind of
        RCProgressDone:
          begin
            // rcheevos reads the digest at the start of DONE and skips any remaining payload.
            if PayloadSize < SizeOf(Digest) then
              Exit(TRAProgressReadStatus.InvalidData);
            Digest := DigestBytes(Buffer, Offset);
            if not CompareMem(Buffer + Offset, @Digest, SizeOf(Digest)) then
              Exit(TRAProgressReadStatus.InvalidData);
            Chunks := Parsed.ToArray;
            Exit(TRAProgressReadStatus.Success);
          end;
        RCProgressMemrefs, RCProgressVariables, RCProgressAchievement, RCProgressLeaderboard, RCProgressRichPresence:
          begin
            if PayloadSize > Cardinal(High(Integer)) then
              Exit(TRAProgressReadStatus.InvalidData);
            SetLength(Payload, PayloadSize);
            if PayloadSize <> 0 then
              Move((Buffer + Offset)^, Payload[0], PayloadSize);
            Parsed.Add(TRAProgressChunk.Create(Kind, Payload));
            Payload := nil;
          end;
      else
        if PayloadSize >= $10000 then
          Exit(TRAProgressReadStatus.InvalidData);
      end;
      Inc(Offset, PayloadSize);
    end;
  finally
    Parsed.Free;
  end;
  Result := TRAProgressReadStatus.InsufficientBuffer;
end;

function TryDecodeRCProgress(const Data: TBytes; out Chunks: TArray<TRAProgressChunk>): Boolean;
begin
  Result := DecodeRCProgress(Data, Chunks) = TRAProgressReadStatus.Success;
end;

end.

