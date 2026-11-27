unit RA.Streams;

interface

uses
  System.Classes;

// Fills the requested buffer, returning any available bytes on end of stream.
function ReadRAStream(Stream: TStream; var Buffer; Count: Integer): Integer;

// Copies a zero-terminated prefix and returns the full UTF-8 length, excluding the terminator.
function CopyRAUTF8Text(const Value: string; Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;

implementation

function ReadRAStream(Stream: TStream; var Buffer; Count: Integer): Integer;
var
  Received: Integer;
begin
  Result := 0;
  while Result < Count do
  begin
    Received := Stream.Read((PByte(@Buffer) + Result)^, Count - Result);
    if Received <= 0 then
      Break;
    Inc(Result, Received);
  end;
end;

function CopyRAUTF8Text(const Value: string; Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
var
  Encoded: UTF8String;
  Count: NativeUInt;
begin
  if (Buffer = nil) or (BufferSize = 0) then
    Exit(0);
  Encoded := UTF8String(Value);
  Result := Length(Encoded);
  Count := Result;
  if Count >= BufferSize then
    Count := BufferSize - 1;
  if Count <> 0 then
    Move(PAnsiChar(Encoded)^, Buffer^, Count);
  Buffer[Count] := #0;
end;

end.

