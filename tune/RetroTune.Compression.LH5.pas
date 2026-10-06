unit RetroTune.Compression.LH5;

interface

uses
  System.SysUtils;

function UnpackLH5(const Data: TBytes; OutputSize: Integer): TBytes;

implementation

type
  THuffman = record
    Lengths: TArray<Integer>;
    First, Count: array[0..16] of Integer;
    Single: Integer;
  end;

  TLH5 = class
    Data: TBytes;
    BitPosition: Integer;
    function Bits(Count: Integer): Integer;
    procedure Build(var Table: THuffman; const Lengths: TArray<Integer>);
    function Symbol(const Table: THuffman): Integer;
    procedure ReadLengths(var Table: THuffman; Symbols, CountBits, Special: Integer);
    procedure ReadCharacters(var Table: THuffman; const LengthTable: THuffman);
  end;

procedure Invalid;
begin
  raise EArgumentException.Create('Invalid or truncated LH5 stream');
end;

function TLH5.Bits(Count: Integer): Integer;
begin
  Result := 0;
  for var I := 1 to Count do
  begin
    if BitPosition div 8 >= Length(Data) then
      Invalid;
    Result := Result * 2 + ((Data[BitPosition div 8] shr (7 - BitPosition mod 8)) and 1);
    Inc(BitPosition);
  end;
end;

procedure TLH5.Build(var Table: THuffman; const Lengths: TArray<Integer>);
begin
  Table.Lengths := Copy(Lengths);
  Table.Single := -1;
  FillChar(Table.Count, SizeOf(Table.Count), 0);
  FillChar(Table.First, SizeOf(Table.First), 0);
  for var L in Lengths do
  begin
    if (L < 0) or (L > 16) then
      Invalid;
    if L > 0 then
      Inc(Table.Count[L]);
  end;
  var Code := 0;
  for var L := 1 to 16 do
  begin
    Code := (Code + Table.Count[L - 1]) * 2;
    Table.First[L] := Code;
    if Code + Table.Count[L] > 1 shl L then
      Invalid;
  end;
  if Code + Table.Count[16] <> 65536 then
    Invalid;
end;

function TLH5.Symbol(const Table: THuffman): Integer;
begin
  if Table.Single >= 0 then
    Exit(Table.Single);
  var Code := 0;
  for var L := 1 to 16 do
  begin
    Code := Code * 2 + Bits(1);
    var Index := Code - Table.First[L];
    if (Index >= 0) and (Index < Table.Count[L]) then
      for var I := 0 to High(Table.Lengths) do
        if Table.Lengths[I] = L then
        begin
          if Index = 0 then
            Exit(I);
          Dec(Index);
        end;
  end;
  Invalid;
  Result := 0;
end;

procedure TLH5.ReadLengths(var Table: THuffman; Symbols, CountBits, Special: Integer);
begin
  var N := Bits(CountBits);
  if N = 0 then
  begin
    Table.Single := Bits(CountBits);
    if Table.Single >= Symbols then
      Invalid;
    Exit;
  end;
  if N > Symbols then
    Invalid;
  var Lengths: TArray<Integer>;
  SetLength(Lengths, Symbols);
  var I := 0;
  while I < N do
  begin
    var L := Bits(3);
    if L = 7 then
      while Bits(1) <> 0 do
      begin
        Inc(L);
        if L > 16 then
          Invalid;
      end;
    Lengths[I] := L;
    Inc(I);
    if I = Special then
    begin
      Inc(I, Bits(2));
      if I > Symbols then
        Invalid;
    end;
  end;
  Build(Table, Lengths);
end;

procedure TLH5.ReadCharacters(var Table: THuffman; const LengthTable: THuffman);
begin
  var N := Bits(9);
  if N = 0 then
  begin
    Table.Single := Bits(9);
    if Table.Single >= 510 then
      Invalid;
    Exit;
  end;
  if N > 510 then
    Invalid;
  var Lengths: TArray<Integer>;
  SetLength(Lengths, 510);
  var I := 0;
  while I < N do
  begin
    var C := Symbol(LengthTable);
    if C <= 2 then
    begin
      var Run := 1;
      if C = 1 then
        Run := Bits(4) + 3
      else if C = 2 then
        Run := Bits(9) + 20;
      Inc(I, Run);
      if I > N then
        Invalid;
    end
    else
    begin
      Lengths[I] := C - 2;
      Inc(I);
    end;
  end;
  Build(Table, Lengths);
end;

function UnpackLH5(const Data: TBytes; OutputSize: Integer): TBytes;
begin
  if (OutputSize < 1) or (OutputSize > 16 * 1024 * 1024) then
    Invalid;
  var Reader := TLH5.Create;
  try
    Reader.Data := Data;
    SetLength(Result, OutputSize);
    var Characters, Positions, Lengths: THuffman;
    var Block := 0;
    var OutPosition := 0;
    while OutPosition < OutputSize do
    begin
      if Block = 0 then
      begin
        Block := Reader.Bits(16);
        if Block = 0 then
          Invalid;
        Reader.ReadLengths(Lengths, 19, 5, 3);
        Reader.ReadCharacters(Characters, Lengths);
        Reader.ReadLengths(Positions, 14, 4, -1);
      end;
      Dec(Block);
      var C := Reader.Symbol(Characters);
      if C < 256 then
      begin
        Result[OutPosition] := C;
        Inc(OutPosition);
      end
      else
      begin
        var P := Reader.Symbol(Positions);
        var Distance := 0;
        if P > 0 then
          Distance := (1 shl (P - 1)) + Reader.Bits(P - 1);
        Inc(Distance);
        var Run := C - 253;
        if (Distance > OutPosition) or (Run > OutputSize - OutPosition) then
          Invalid;
        for var I := 1 to Run do
        begin
          Result[OutPosition] := Result[OutPosition - Distance];
          Inc(OutPosition);
        end;
      end;
    end;
  finally
    Reader.Free;
  end;
end;

end.

