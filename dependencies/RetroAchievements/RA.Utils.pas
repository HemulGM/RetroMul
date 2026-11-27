unit RA.Utils;

interface

type
  // Owns stable byte storage until destruction. Reservations are committed by Consume.
  TRABuffer = class
  private
    type
      PChunk = ^TChunk;

      TChunk = record
        WritePosition: PByte;
        Limit: PByte;
        Start: PByte;
        Next: PChunk;
      end;
  private
    FChunk: TChunk;
    FData: array[0..255] of Byte;
  public
    constructor Create;
    destructor Destroy; override;
    function Reserve(Amount: NativeUInt): PByte;
    procedure Consume(First, Last: PByte);
    function Allocate(Amount: NativeUInt): Pointer;
    function CopyString(const Source: UTF8String): PAnsiChar; overload;
    function CopyString(Source: PAnsiChar; Count: NativeUInt): PAnsiChar; overload;
  end;

// Uses signed UTF-8 bytes and stops at the first zero byte, as in the reference build.
function RADJB2(const Value: UTF8String): Cardinal;

function FormatRAMD5(const Digest: array of Byte): string;

function TruncateRAUTF8(const Text: string; MaxBytes: Integer): string;

implementation

uses
  System.SysUtils;

constructor TRABuffer.Create;
begin
  inherited Create;
  FChunk.Start := @FData[0];
  FChunk.WritePosition := FChunk.Start;
  FChunk.Limit := PByte(NativeUInt(FChunk.Start) + SizeOf(FData));
  FChunk.Next := nil;
end;

destructor TRABuffer.Destroy;
var
  Chunk, Next: PChunk;
begin
  Chunk := FChunk.Next;
  while Chunk <> nil do
  begin
    Next := Chunk.Next;
    FreeMem(Chunk);
    Chunk := Next;
  end;
  inherited;
end;

function TRABuffer.Reserve(Amount: NativeUInt): PByte;
var
  Chunk: PChunk;
  AllocationSize: NativeUInt;
begin
  // Matches rc_buffer_reserve's limit and prevents rounding overflow.
  if Amount >= $40000000 then
    Exit(nil);
  Chunk := @FChunk;
  while Chunk <> nil do
  begin
    if NativeUInt(Chunk.Limit) - NativeUInt(Chunk.WritePosition) >= Amount then
      Exit(Chunk.WritePosition);
    if Chunk.Next = nil then
    begin
      AllocationSize := (SizeOf(TChunk) + Amount + $FF) and not NativeUInt($FF);
      try
        GetMem(Chunk.Next, AllocationSize);
      except
        on EOutOfMemory do
          Exit(nil);
      end;
      Chunk.Next.Start := PByte(NativeUInt(Chunk.Next) + SizeOf(TChunk));
      Chunk.Next.WritePosition := Chunk.Next.Start;
      Chunk.Next.Limit := PByte(NativeUInt(Chunk.Next) + AllocationSize);
      Chunk.Next.Next := nil;
    end;
    Chunk := Chunk.Next;
  end;
  Result := nil;
end;

procedure TRABuffer.Consume(First, Last: PByte);
var
  Chunk: PChunk;
  Offset: NativeUInt;
begin
  Chunk := @FChunk;
  while Chunk <> nil do
  begin
    if Chunk.WritePosition = First then
    begin
      Offset := (NativeUInt(Last) - NativeUInt(Chunk.Start) + 7) and not NativeUInt(7);
      if Offset > NativeUInt(Chunk.Limit) - NativeUInt(Chunk.Start) then
        Chunk.WritePosition := Chunk.Limit
      else
        Chunk.WritePosition := PByte(NativeUInt(Chunk.Start) + Offset);
      Exit;
    end;
    Chunk := Chunk.Next;
  end;
end;

function TRABuffer.Allocate(Amount: NativeUInt): Pointer;
begin
  Result := Reserve(Amount);
  if Result <> nil then
    Consume(Result, PByte(NativeUInt(Result) + Amount));
end;

function TRABuffer.CopyString(Source: PAnsiChar; Count: NativeUInt): PAnsiChar;
begin
  // Check before Count + 1 so an oversized length cannot wrap to zero.
  if Count >= $3FFFFFFF then
    Exit(nil);
  Result := PAnsiChar(Reserve(Count + 1));
  if Result <> nil then
  begin
    if Count <> 0 then
      Move(Source^, Result^, Count);
    PAnsiChar(NativeUInt(Result) + Count)^ := #0;
    Consume(PByte(Result), PByte(NativeUInt(Result) + Count + 1));
  end;
end;

function TRABuffer.CopyString(const Source: UTF8String): PAnsiChar;
var
  Count: NativeUInt;
begin
  Count := 0;
  while Count < NativeUInt(Length(Source)) do
  begin
    if Source[Count + 1] = #0 then
      Break;
    Inc(Count);
  end;
  Result := CopyString(PAnsiChar(Source), Count);
end;

function RADJB2(const Value: UTF8String): Cardinal;
begin
  Result := 5381;
  for var Ch in Value do
  begin
    if Ch = #0 then
      Break;
    Result := Cardinal((Int64(Result) * 33 + ShortInt(Byte(Ch))) and High(Cardinal));
  end;
end;

function FormatRAMD5(const Digest: array of Byte): string;
const
  DigestSize = 16;
  HexDigits: array[0..15] of Char = '0123456789abcdef';
begin
  if Length(Digest) <> DigestSize then
    raise EArgumentException.Create('An MD5 digest must contain 16 bytes');
  SetLength(Result, DigestSize * 2);
  for var Index := 0 to High(Digest) do
  begin
    Result[Index * 2 + 1] := HexDigits[Digest[Index] shr 4];
    Result[Index * 2 + 2] := HexDigits[Digest[Index] and $0F];
  end;
end;

function TruncateRAUTF8(const Text: string; MaxBytes: Integer): string;
var
  Encoded: UTF8String;
begin
  Encoded := UTF8String(Text);
  if Length(Encoded) <= MaxBytes then
    Exit(Text);

  // Keep the byte limit of the C record and preserve complete UTF-8 characters.
  while (MaxBytes > 0) and ((Ord(Encoded[MaxBytes + 1]) and $C0) = $80) do
    Dec(MaxBytes);
  SetLength(Encoded, MaxBytes);
  Result := string(Encoded);
end;

end.

