unit RA.Progress;

interface

uses
  System.Classes, System.SysUtils;

type
  ERAProgressError = class(Exception);

  TRAProgressIO = record
  private
    FStream: TStream;
    FWriteCount: PUInt64;
    procedure RequireBytes(Count: Int64);
  public
    constructor Create(Stream: TStream);
    constructor CreateCounter(var WriteCount: UInt64);
    procedure WriteRaw(const Buffer; Count: Integer);
    procedure ReadRaw(var Buffer; Count: Integer);
    procedure WriteUInt(Value: Cardinal);
    function ReadUInt: Cardinal;
    procedure WriteFlag(Value: Boolean);
    function ReadFlag: Boolean;
    procedure WriteBytes(const Value: TBytes);
    function ReadBytes: TBytes;
    procedure WriteString(const Value: string);
    function ReadString: string;
    procedure ExpectUInt(Expected: Cardinal);
    procedure ExpectEnd;
    function Remaining: Int64;
  end;

implementation

constructor TRAProgressIO.Create(Stream: TStream);
begin
  FStream := Stream;
  FWriteCount := nil;
end;

constructor TRAProgressIO.CreateCounter(var WriteCount: UInt64);
begin
  FStream := nil;
  FWriteCount := @WriteCount;
  WriteCount := 0;
end;

function TRAProgressIO.Remaining: Int64;
begin
  Result := FStream.Size - FStream.Position;
end;

procedure TRAProgressIO.RequireBytes(Count: Int64);
begin
  if (Count < 0) or (Count > Remaining) then
    raise ERAProgressError.Create('Truncated RetroAchievements progress');
end;

procedure TRAProgressIO.WriteRaw(const Buffer; Count: Integer);
begin
  if FWriteCount = nil then
    FStream.WriteBuffer(Buffer, Count)
  else
  begin
    if Count < 0 then
      raise ERAProgressError.Create('Invalid RetroAchievements progress length');
    Inc(FWriteCount^, UInt64(Count));
  end;
end;

procedure TRAProgressIO.ReadRaw(var Buffer; Count: Integer);
begin
  RequireBytes(Count);
  FStream.ReadBuffer(Buffer, Count);
end;

procedure TRAProgressIO.WriteUInt(Value: Cardinal);
var
  Bytes: array[0..3] of Byte;
begin
  for var Index := 0 to High(Bytes) do
    Bytes[Index] := Byte((Value shr (Index * 8)) and $FF);
  WriteRaw(Bytes, SizeOf(Bytes));
end;

function TRAProgressIO.ReadUInt: Cardinal;
var
  Bytes: array[0..3] of Byte;
begin
  RequireBytes(SizeOf(Bytes));
  FStream.ReadBuffer(Bytes, SizeOf(Bytes));
  Result := 0;
  for var Index := 0 to High(Bytes) do
    Result := Result or (Cardinal(Bytes[Index]) shl (Index * 8));
end;

procedure TRAProgressIO.WriteFlag(Value: Boolean);
var
  B: Byte;
begin
  B := Ord(Value);
  WriteRaw(B, SizeOf(B));
end;

function TRAProgressIO.ReadFlag: Boolean;
var
  B: Byte;
begin
  RequireBytes(SizeOf(B));
  FStream.ReadBuffer(B, SizeOf(B));
  if B > 1 then
    raise ERAProgressError.Create('Invalid flag in RetroAchievements progress');
  Result := B <> 0;
end;

procedure TRAProgressIO.WriteBytes(const Value: TBytes);
begin
  {$IFDEF CPU64BITS}
  if Length(Value) > High(Integer) then
    raise ERAProgressError.Create('RetroAchievements progress section is too large');
  {$ENDIF}
  WriteUInt(Length(Value));
  if Length(Value) <> 0 then
    WriteRaw(Value[0], Length(Value));
end;

function TRAProgressIO.ReadBytes: TBytes;
var
  Count: Cardinal;
begin
  Count := ReadUInt;
  if Count > Cardinal(High(Integer)) then
    raise ERAProgressError.Create('RetroAchievements progress section is too large');
  RequireBytes(Count);
  SetLength(Result, Count);
  if Count <> 0 then
    FStream.ReadBuffer(Result[0], Count);
end;

procedure TRAProgressIO.WriteString(const Value: string);
begin
  WriteBytes(TEncoding.UTF8.GetBytes(Value));
end;

function TRAProgressIO.ReadString: string;
begin
  Result := TEncoding.UTF8.GetString(ReadBytes);
end;

procedure TRAProgressIO.ExpectUInt(Expected: Cardinal);
begin
  if ReadUInt <> Expected then
    raise ERAProgressError.Create('Incompatible RetroAchievements progress');
end;

procedure TRAProgressIO.ExpectEnd;
begin
  if Remaining <> 0 then
    raise ERAProgressError.Create('Unexpected data in RetroAchievements progress');
end;

end.
