unit PSP.SFO;

// PARAM.SFO: a key table and a data table behind a 20-byte header; keys are
// kept sorted, values are UTF-8 strings (0x0204), raw bytes (0x0004) or
// 32-bit integers (0x0404).
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults;

const
  SFO_BINARY = $0004;
  SFO_STRING = $0204;
  SFO_INT = $0404;

type
  TPSPSFOEntry = record
    Key: string;
    Format: Word;
    Data: TBytes;
    MaxLength: Cardinal;
  end;

  TPSPSFO = class
  private
    FEntries: TList<TPSPSFOEntry>;
    function IndexOf(const Key: string): Integer;
    procedure Put(const Key: string; Format: Word; const Data: TBytes; MaxLength: Cardinal);
  public
    constructor Create;
    destructor Destroy; override;
    function Load(const Data: TBytes): Boolean;
    function Save: TBytes;
    function Has(const Key: string): Boolean;
    function GetString(const Key: string): string;
    function GetInt(const Key: string; Default: Integer = 0): Integer;
    function GetBytes(const Key: string): TBytes;
    procedure SetString(const Key, Value: string; MaxLength: Cardinal);
    procedure SetInt(const Key: string; Value: Integer);
    procedure SetBytes(const Key: string; const Value: TBytes; MaxLength: Cardinal);
    procedure Remove(const Key: string);
    property Entries: TList<TPSPSFOEntry> read FEntries;
  end;

implementation

constructor TPSPSFO.Create;
begin
  inherited Create;
  FEntries := TList<TPSPSFOEntry>.Create;
end;

destructor TPSPSFO.Destroy;
begin
  FEntries.Free;
  inherited;
end;

function TPSPSFO.IndexOf(const Key: string): Integer;
begin
  for var I := 0 to FEntries.Count - 1 do
    if FEntries[I].Key = Key then
      Exit(I);
  Result := -1;
end;

function TPSPSFO.Load(const Data: TBytes): Boolean;

  function U16(P: Integer): Cardinal;
  begin
    Result := Data[P] or (Cardinal(Data[P + 1]) shl 8);
  end;

  function U32(P: Integer): Cardinal;
  begin
    Result := Data[P] or (Cardinal(Data[P + 1]) shl 8) or (Cardinal(Data[P + 2]) shl 16) or
      (Cardinal(Data[P + 3]) shl 24);
  end;

begin
  FEntries.Clear;
  Result := False;
  if (Length(Data) < 20) or (U32(0) <> $46535000) then
    Exit;
  var KeyTable := U32(8);
  var DataTable := U32(12);
  var Count := U32(16);
  if (Int64(20) + Int64(Count) * 16 > Length(Data)) or (KeyTable > Cardinal(Length(Data))) or
    (DataTable > Cardinal(Length(Data))) then
    Exit;
  for var I := 0 to Integer(Count) - 1 do
  begin
    var P := 20 + I * 16;
    var E := Default(TPSPSFOEntry);
    var K := Integer(KeyTable + U16(P));
    var KeyEnd := K;
    while (KeyEnd < Length(Data)) and (Data[KeyEnd] <> 0) do
      Inc(KeyEnd);
    E.Key := TEncoding.ASCII.GetString(Data, K, KeyEnd - K);
    E.Format := U16(P + 2);
    var Len := U32(P + 4);
    E.MaxLength := U32(P + 8);
    var Off := Int64(DataTable) + U32(P + 12);
    if Off + Len > Length(Data) then
      Exit;
    SetLength(E.Data, Len);
    if Len > 0 then
      Move(Data[Off], E.Data[0], Len);
    FEntries.Add(E);
  end;
  Result := True;
end;

function TPSPSFO.Save: TBytes;
var
  Buf: TBytes;

  procedure W16(P: Integer; V: Cardinal);
  begin
    Buf[P] := Byte(V);
    Buf[P + 1] := Byte(V shr 8);
  end;

  procedure W32(P: Integer; V: Cardinal);
  begin
    Buf[P] := Byte(V);
    Buf[P + 1] := Byte(V shr 8);
    Buf[P + 2] := Byte(V shr 16);
    Buf[P + 3] := Byte(V shr 24);
  end;

begin
  FEntries.Sort(TComparer<TPSPSFOEntry>.Construct(function(const A,
    B: TPSPSFOEntry): Integer begin Result := CompareStr(A.Key, B.Key); end));
  var KeyBytes := 0;
  for var E in FEntries do
    Inc(KeyBytes, Length(E.Key) + 1);
  var KeyTable := 20 + FEntries.Count * 16;
  var DataTable := (KeyTable + KeyBytes + 3) and not 3;
  var DataBytes: Cardinal := 0;
  for var E in FEntries do
    Inc(DataBytes, (E.MaxLength + 3) and not 3);
  SetLength(Buf, DataTable + Integer(DataBytes));
  FillChar(Buf[0], Length(Buf), 0);
  W32(0, $46535000);
  W32(4, $00000101);
  W32(8, KeyTable);
  W32(12, DataTable);
  W32(16, FEntries.Count);
  var KeyPos := 0;
  var DataPos: Cardinal := 0;
  for var I := 0 to FEntries.Count - 1 do
  begin
    var E := FEntries[I];
    var P := 20 + I * 16;
    W16(P, KeyPos);
    W16(P + 2, E.Format);
    W32(P + 4, Length(E.Data));
    W32(P + 8, E.MaxLength);
    W32(P + 12, DataPos);
    var K := TEncoding.ASCII.GetBytes(E.Key);
    if Length(K) > 0 then
      Move(K[0], Buf[KeyTable + KeyPos], Length(K));
    Inc(KeyPos, Length(K) + 1);
    if Length(E.Data) > 0 then
      Move(E.Data[0], Buf[DataTable + Integer(DataPos)], Length(E.Data));
    Inc(DataPos, (E.MaxLength + 3) and not 3);
  end;
  Result := Buf;
end;

function TPSPSFO.Has(const Key: string): Boolean;
begin
  Result := IndexOf(Key) >= 0;
end;

function TPSPSFO.GetBytes(const Key: string): TBytes;
begin
  var I := IndexOf(Key);
  if I < 0 then
    Exit(nil);
  Result := FEntries[I].Data;
end;

function TPSPSFO.GetString(const Key: string): string;
begin
  var B := GetBytes(Key);
  var N := 0;
  while (N < Length(B)) and (B[N] <> 0) do
    Inc(N);
  Result := TEncoding.UTF8.GetString(B, 0, N);
end;

function TPSPSFO.GetInt(const Key: string; Default: Integer): Integer;
begin
  var B := GetBytes(Key);
  if Length(B) < 4 then
    Exit(Default);
  Result := Integer(B[0] or (Cardinal(B[1]) shl 8) or (Cardinal(B[2]) shl 16) or (Cardinal(B[3]) shl 24));
end;

procedure TPSPSFO.Put(const Key: string; Format: Word; const Data: TBytes; MaxLength: Cardinal);
begin
  var E := Default(TPSPSFOEntry);
  E.Key := Key;
  E.Format := Format;
  E.Data := Data;
  if Cardinal(Length(Data)) > MaxLength then
    MaxLength := Length(Data);
  E.MaxLength := MaxLength;
  var I := IndexOf(Key);
  if I >= 0 then
    FEntries[I] := E
  else
    FEntries.Add(E);
end;

procedure TPSPSFO.SetString(const Key, Value: string; MaxLength: Cardinal);
begin
  var B := TEncoding.UTF8.GetBytes(Value);
  if Cardinal(Length(B)) >= MaxLength then
    SetLength(B, MaxLength - 1);
  SetLength(B, Length(B) + 1);
  B[High(B)] := 0;
  Put(Key, SFO_STRING, B, MaxLength);
end;

procedure TPSPSFO.SetInt(const Key: string; Value: Integer);
begin
  var B: TBytes;
  SetLength(B, 4);
  B[0] := Byte(Value);
  B[1] := Byte(Value shr 8);
  B[2] := Byte(Value shr 16);
  B[3] := Byte(Value shr 24);
  Put(Key, SFO_INT, B, 4);
end;

procedure TPSPSFO.SetBytes(const Key: string; const Value: TBytes; MaxLength: Cardinal);
begin
  Put(Key, SFO_BINARY, Value, MaxLength);
end;

procedure TPSPSFO.Remove(const Key: string);
begin
  var I := IndexOf(Key);
  if I >= 0 then
    FEntries.Delete(I);
end;

end.
