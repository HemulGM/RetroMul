unit PSP.AES;

interface

uses
  System.SysUtils;

type
  TPSPAESBlock = array[0..15] of Byte;

  TPSPAES = record
  private
    FKeys: array[0..175] of Byte;
    procedure AddKey(var State: TPSPAESBlock; Round: Integer);
  public
    procedure Init(const Key: TBytes);
    procedure Encrypt(var State: TPSPAESBlock);
    procedure Decrypt(var State: TPSPAESBlock);
    function CBC(const Data: TBytes; Decrypting: Boolean): TBytes;
    function CMAC(const Data: TBytes): TBytes;
  end;

function PSPAESDecrypt(const Data, Key: TBytes): TBytes;

implementation

var
  SBox, InvSBox: array[0..255] of Byte;
  Products: array[0..15, 0..255] of Byte;

function GFMultiply(A, B: Byte): Byte;
begin
  Result := 0;
  for var I := 0 to 7 do
  begin
    if B and 1 <> 0 then
      Result := Result xor A;
    var HighBit := A and $80 <> 0;
    A := Byte((Cardinal(A) shl 1) and $FF);
    if HighBit then
      A := A xor $1B;
    B := B shr 1;
  end;
end;

function RotateByte(Value: Byte; Shift: Integer): Byte;
begin
  Result := Byte(((Cardinal(Value) shl Shift) or (Value shr (8 - Shift))) and $FF);
end;

procedure InitTables;
begin
  for var I := 0 to 255 do
  begin
    var Inverse: Byte := 0;
    if I <> 0 then
    begin
      Inverse := 1;
      // x^-1 = x^254 in GF(2^8).
      for var J := 1 to 254 do
        Inverse := GFMultiply(Inverse, Byte(I));
    end;
    var Value := Inverse xor RotateByte(Inverse, 1) xor RotateByte(Inverse, 2) xor
      RotateByte(Inverse, 3) xor RotateByte(Inverse, 4) xor $63;
    SBox[I] := Value;
    InvSBox[Value] := I;
    for var Factor := 0 to 15 do
      Products[Factor, I] := GFMultiply(Factor, Byte(I));
  end;
end;

procedure TPSPAES.Init(const Key: TBytes);
begin
  if Length(Key) <> 16 then
    raise EArgumentException.Create('AES128 key must contain 16 bytes');
  Move(Key[0], FKeys[0], 16);
  var RCon: Byte := 1;
  var Pos := 16;
  while Pos < Length(FKeys) do
  begin
    var T: array[0..3] of Byte;
    Move(FKeys[Pos - 4], T[0], 4);
    if Pos mod 16 = 0 then
    begin
      var First := T[0];
      T[0] := SBox[T[1]] xor RCon;
      T[1] := SBox[T[2]];
      T[2] := SBox[T[3]];
      T[3] := SBox[First];
      RCon := GFMultiply(RCon, 2);
    end;
    for var I := 0 to 3 do
    begin
      FKeys[Pos] := FKeys[Pos - 16] xor T[I];
      Inc(Pos);
    end;
  end;
end;

procedure TPSPAES.AddKey(var State: TPSPAESBlock; Round: Integer);
begin
  for var I := 0 to 15 do
    State[I] := State[I] xor FKeys[Round * 16 + I];
end;

procedure ShiftRows(var State: TPSPAESBlock; Inverse: Boolean);
begin
  var Original := State;
  for var Row := 0 to 3 do
    for var Column := 0 to 3 do
    begin
      var Source := Column + Row;
      if Inverse then
        Source := Column + 4 - Row;
      State[Column * 4 + Row] := Original[(Source mod 4) * 4 + Row];
    end;
end;

procedure MixColumns(var State: TPSPAESBlock; Inverse: Boolean);
begin
  for var C := 0 to 3 do
  begin
    var A := State[C * 4];
    var B := State[C * 4 + 1];
    var D := State[C * 4 + 2];
    var E := State[C * 4 + 3];
    if not Inverse then
    begin
      State[C * 4] := Products[2, A] xor Products[3, B] xor D xor E;
      State[C * 4 + 1] := A xor Products[2, B] xor Products[3, D] xor E;
      State[C * 4 + 2] := A xor B xor Products[2, D] xor Products[3, E];
      State[C * 4 + 3] := Products[3, A] xor B xor D xor Products[2, E];
    end
    else
    begin
      State[C * 4] := Products[14, A] xor Products[11, B] xor Products[13, D] xor Products[9, E];
      State[C * 4 + 1] := Products[9, A] xor Products[14, B] xor Products[11, D] xor Products[13, E];
      State[C * 4 + 2] := Products[13, A] xor Products[9, B] xor Products[14, D] xor Products[11, E];
      State[C * 4 + 3] := Products[11, A] xor Products[13, B] xor Products[9, D] xor Products[14, E];
    end;
  end;
end;

procedure TPSPAES.Encrypt(var State: TPSPAESBlock);
begin
  AddKey(State, 0);
  for var Round := 1 to 10 do
  begin
    for var I := 0 to 15 do
      State[I] := SBox[State[I]];
    ShiftRows(State, False);
    if Round <> 10 then
      MixColumns(State, False);
    AddKey(State, Round);
  end;
end;

procedure TPSPAES.Decrypt(var State: TPSPAESBlock);
begin
  AddKey(State, 10);
  for var Round := 9 downto 0 do
  begin
    ShiftRows(State, True);
    for var I := 0 to 15 do
      State[I] := InvSBox[State[I]];
    AddKey(State, Round);
    if Round <> 0 then
      MixColumns(State, True);
  end;
end;

function TPSPAES.CBC(const Data: TBytes; Decrypting: Boolean): TBytes;
begin
  if Length(Data) mod 16 <> 0 then
    raise EArgumentException.Create('AES CBC data must be block aligned');
  SetLength(Result, Length(Data));
  var Previous: TPSPAESBlock;
  FillChar(Previous, SizeOf(Previous), 0);
  for var Block := 0 to Length(Data) div 16 - 1 do
  begin
    var State: TPSPAESBlock;
    Move(Data[Block * 16], State[0], 16);
    if Decrypting then
    begin
      var Saved := State;
      Decrypt(State);
      for var I := 0 to 15 do
        State[I] := State[I] xor Previous[I];
      Previous := Saved;
    end
    else
    begin
      for var I := 0 to 15 do
        State[I] := State[I] xor Previous[I];
      Encrypt(State);
      Previous := State;
    end;
    Move(State[0], Result[Block * 16], 16);
  end;
end;

procedure DoubleBlock(var State: TPSPAESBlock);
begin
  var Carry: Byte := 0;
  for var I := 15 downto 0 do
  begin
    var Next := State[I] shr 7;
    State[I] := Byte(((Cardinal(State[I]) shl 1) and $FF) or Carry);
    Carry := Next;
  end;
  if Carry <> 0 then
    State[15] := State[15] xor $87;
end;

function TPSPAES.CMAC(const Data: TBytes): TBytes;
begin
  var SubKey: TPSPAESBlock;
  FillChar(SubKey, SizeOf(SubKey), 0);
  Encrypt(SubKey);
  DoubleBlock(SubKey);
  var Complete := (Length(Data) <> 0) and (Length(Data) mod 16 = 0);
  if not Complete then
    DoubleBlock(SubKey);
  var Blocks := (Length(Data) + 15) div 16;
  if Blocks = 0 then
    Blocks := 1;
  var State: TPSPAESBlock;
  FillChar(State, SizeOf(State), 0);
  for var Block := 0 to Blocks - 1 do
  begin
    for var I := 0 to 15 do
    begin
      var Offset := Block * 16 + I;
      var Value: Byte := 0;
      if Offset < Length(Data) then
        Value := Data[Offset]
      else if Offset = Length(Data) then
        Value := $80;
      if Block = Blocks - 1 then
        Value := Value xor SubKey[I];
      State[I] := State[I] xor Value;
    end;
    Encrypt(State);
  end;
  SetLength(Result, 16);
  Move(State[0], Result[0], 16);
end;

function PSPAESDecrypt(const Data, Key: TBytes): TBytes;
begin
  var AES: TPSPAES;
  AES.Init(Key);
  Result := AES.CBC(Data, True);
end;

initialization
  InitTables;

end.

