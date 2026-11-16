unit JVM.StateIO;

interface

uses
  System.SysUtils, System.Classes, JVM.Types;

type
  // Portable, bounded state fields; never stores pointers or record padding.
  TJVMStateIO = class
  private
    FStream: TStream;
    FLoading: Boolean;
    procedure Raw(var Value; Size: Integer);
  public
    constructor Create(Stream: TStream; Loading: Boolean);
    procedure Int(var Value: Integer);
    procedure Int64Value(var Value: Int64);
    procedure UInt64Value(var Value: UInt64);
    procedure RealValue(var Value: Double);
    procedure Bool(var Value: Boolean);
    procedure Text(var Value: string);
    procedure Bytes(var Value: TBytes; Limit: Integer = 67108864);
    procedure Value(var Item: TJVMValue);
    procedure Values(var Items: TArray<TJVMValue>);
    procedure Pixels(var Items: TArray<UInt32>);
    procedure PCM(var Items: TArray<SmallInt>);
    procedure Count(var Value: Integer; Limit: Integer = 1048576); overload;
    {$IFDEF CPU64BITS}
    procedure Count(var Value: NativeInt; Limit: Integer = 1048576); overload;
    {$ENDIF}
    procedure Tag(const Expected: string);
    procedure Finish;
    property Loading: Boolean read FLoading;
  end;

implementation

constructor TJVMStateIO.Create(Stream: TStream; Loading: Boolean);
begin
  inherited Create;
  FStream := Stream;
  FLoading := Loading;
end;

procedure TJVMStateIO.Raw(var Value; Size: Integer);
begin
  if (Size < 0) or (FLoading and (Size > FStream.Size - FStream.Position)) then
    raise EReadError.Create('Invalid or truncated Java ME snapshot');
  if Size = 0 then
    Exit;
  if FLoading then
    FStream.ReadBuffer(Value, Size)
  else
    FStream.WriteBuffer(Value, Size);
end;

procedure TJVMStateIO.Int(var Value: Integer);
begin
  Raw(Value, 4);
end;

procedure TJVMStateIO.Int64Value(var Value: Int64);
begin
  Raw(Value, 8);
end;

procedure TJVMStateIO.UInt64Value(var Value: UInt64);
begin
  Raw(Value, 8);
end;

procedure TJVMStateIO.RealValue(var Value: Double);
begin
  Raw(Value, 8);
end;

procedure TJVMStateIO.Bool(var Value: Boolean);
begin
  var B: Integer := Ord(Value);
  Int(B);
  if not (B in [0, 1]) then
    raise EReadError.Create('Invalid snapshot Boolean');
  if FLoading then
    Value := B <> 0;
end;

procedure TJVMStateIO.Count(var Value: Integer; Limit: Integer);
begin
  Int(Value);
  if (Value < 0) or (Value > Limit) then
    raise EReadError.Create('Java ME snapshot count limit');
end;
{$IFDEF CPU64BITS}

procedure TJVMStateIO.Count(var Value: NativeInt; Limit: Integer);
begin
  if (Value < 0) or (Value > Limit) then
    raise EReadError.Create('Java ME snapshot count limit');
  var N := Integer(Value);
  Count(N, Limit);
  Value := N;
end;
{$ENDIF}

procedure TJVMStateIO.Text(var Value: string);
begin
  // UTF-16 code units preserve all Java strings, including unpaired surrogates.
  var N: Integer := Length(Value);
  Count(N, 16777216);
  if FLoading then
    SetLength(Value, N);
  if N > 0 then
    Raw(Value[1], N * 2);
end;

procedure TJVMStateIO.Bytes(var Value: TBytes; Limit: Integer);
begin
  var N: Integer := Length(Value);
  Count(N, Limit);
  if FLoading then
    SetLength(Value, N);
  if N > 0 then
    Raw(Value[0], N);
end;

procedure TJVMStateIO.Value(var Item: TJVMValue);
begin
  var K: Integer := Ord(Item.Kind);
  Int(K);
  if (K < Ord(Low(TJVMKind))) or (K > Ord(High(TJVMKind))) then
    raise EReadError.Create('Invalid snapshot JVM value');
  if FLoading then
    Item.Kind := TJVMKind(K);
  Int64Value(Item.Bits);
end;

procedure TJVMStateIO.Values(var Items: TArray<TJVMValue>);
begin
  var N: Integer := Length(Items);
  Count(N);
  if FLoading then
    SetLength(Items, N);
  for var I := 0 to N - 1 do
    Value(Items[I]);
end;

procedure TJVMStateIO.Pixels(var Items: TArray<UInt32>);
begin
  var N: Integer := Length(Items);
  Count(N);
  if FLoading then
    SetLength(Items, N);
  if N > 0 then
    Raw(Items[0], N * 4);
end;

procedure TJVMStateIO.PCM(var Items: TArray<SmallInt>);
begin
  var N: Integer := Length(Items);
  Count(N, 33554432);
  if FLoading then
    SetLength(Items, N);
  if N > 0 then
    Raw(Items[0], N * 2);
end;

procedure TJVMStateIO.Tag(const Expected: string);
begin
  var Actual := Expected;
  Text(Actual);
  if Actual <> Expected then
    raise EReadError.Create('Incompatible Java ME snapshot: ' + Expected);
end;

procedure TJVMStateIO.Finish;
begin
  if FLoading and (FStream.Position <> FStream.Size) then
    raise EReadError.Create('Trailing Java ME snapshot data');
end;

end.

