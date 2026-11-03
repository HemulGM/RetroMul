unit PSP.AES;

// AES-128 (FIPS 197), CBC without padding (SP 800-38A) and CMAC
// (SP 800-38B). Tables are derived from GF(2^8), not imported code/data.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils;

type
  TPSPAESBlock = array[0..15] of Byte;

  TPSPAES = record
  private
    FSchedule: array[0..175] of Byte;
  public
    procedure Init(const Key: TBytes);
    procedure Encrypt(var Block: TPSPAESBlock);
    procedure Decrypt(var Block: TPSPAESBlock);
    function CBC(const Data: TBytes; Decrypting: Boolean): TBytes;
    function CMAC(const Data: TBytes): TBytes;
  end;

function PSPAESDecrypt(const Data, Key: TBytes): TBytes;

implementation

var
  Sub, Unsub: array[0..255] of Byte;
  // Multiples needed by the inverse MixColumns matrix.
  M9, M11, M13, M14: array[0..255] of Byte;

function Times2(X: Byte): Byte; inline;
begin
  Result := Byte((Cardinal(X) shl 1) and $FF);
  if X and $80 <> 0 then
    Result := Result xor $1B;
end;

function Product(A, B: Byte): Byte;
begin
  Result := 0;
  for var I := 0 to 7 do
  begin
    if B and 1 <> 0 then
      Result := Result xor A;
    B := B shr 1;
    A := Times2(A);
  end;
end;

function Rotate(X: Byte; Bits: Integer): Byte; inline;
begin
  Result := Byte(((Cardinal(X) shl Bits) or (Cardinal(X) shr (8 - Bits))) and $FF);
end;

procedure MakeTables;
begin
  for var X := 0 to 255 do
  begin
    // Multiplicative inverse x^254 (zero maps to zero).
    var V: Byte := 1;
    var Base := Byte(X);
    var Power := 254;
    while Power > 0 do
    begin
      if Power and 1 <> 0 then
        V := Product(V, Base);
      Base := Product(Base, Base);
      Power := Power shr 1;
    end;
    var S := V xor Rotate(V, 1) xor Rotate(V, 2) xor Rotate(V, 3) xor Rotate(V, 4) xor $63;
    Sub[X] := S;
    Unsub[S] := X;
    M9[X] := Product(X, 9);
    M11[X] := Product(X, 11);
    M13[X] := Product(X, 13);
    M14[X] := Product(X, 14);
  end;
end;

procedure TPSPAES.Init(const Key: TBytes);
begin
  if Length(Key) <> 16 then
    raise EArgumentException.Create('AES-128 requires a 16-byte key');
  Move(Key[0], FSchedule[0], 16);
  var Rcon: Byte := 1;
  for var WordIndex := 4 to 43 do
  begin
    var T: array[0..3] of Byte;
    Move(FSchedule[(WordIndex - 1) * 4], T[0], 4);
    if WordIndex and 3 = 0 then
    begin
      var First := T[0];
      T[0] := Sub[T[1]] xor Rcon;
      T[1] := Sub[T[2]];
      T[2] := Sub[T[3]];
      T[3] := Sub[First];
      Rcon := Times2(Rcon);
    end;
    for var I := 0 to 3 do
      FSchedule[WordIndex * 4 + I] := FSchedule[(WordIndex - 4) * 4 + I] xor T[I];
  end;
end;

procedure TPSPAES.Encrypt(var Block: TPSPAESBlock);
var
  Next: TPSPAESBlock;
begin
  for var I := 0 to 15 do
    Block[I] := Block[I] xor FSchedule[I];
  for var Round := 1 to 10 do
  begin
    for var C := 0 to 3 do
    begin
      // Column-major state: SubBytes and ShiftRows combined.
      var A := Sub[Block[C * 4]];
      var B := Sub[Block[((C + 1) and 3) * 4 + 1]];
      var D := Sub[Block[((C + 2) and 3) * 4 + 2]];
      var E := Sub[Block[((C + 3) and 3) * 4 + 3]];
      var P := C * 4;
      if Round <> 10 then
      begin
        var All := A xor B xor D xor E;
        Next[P] := A xor All xor Times2(A xor B);
        Next[P + 1] := B xor All xor Times2(B xor D);
        Next[P + 2] := D xor All xor Times2(D xor E);
        Next[P + 3] := E xor All xor Times2(E xor A);
      end
      else
      begin
        Next[P] := A;
        Next[P + 1] := B;
        Next[P + 2] := D;
        Next[P + 3] := E;
      end;
    end;
    for var I := 0 to 15 do
      Block[I] := Next[I] xor FSchedule[Round * 16 + I];
  end;
end;

procedure TPSPAES.Decrypt(var Block: TPSPAESBlock);
var
  Next: TPSPAESBlock;
begin
  for var I := 0 to 15 do
    Block[I] := Block[I] xor FSchedule[160 + I];
  for var Round := 9 downto 0 do
  begin
    for var C := 0 to 3 do
      for var R := 0 to 3 do
        Next[C * 4 + R] := Unsub[Block[((C - R + 4) and 3) * 4 + R]] xor FSchedule[Round * 16 + C * 4 + R];
    if Round = 0 then
      Block := Next
    else
      for var C := 0 to 3 do
      begin
        var P := C * 4;
        var A := Next[P];
        var B := Next[P + 1];
        var D := Next[P + 2];
        var E := Next[P + 3];
        Block[P] := M14[A] xor M11[B] xor M13[D] xor M9[E];
        Block[P + 1] := M9[A] xor M14[B] xor M11[D] xor M13[E];
        Block[P + 2] := M13[A] xor M9[B] xor M14[D] xor M11[E];
        Block[P + 3] := M11[A] xor M13[B] xor M9[D] xor M14[E];
      end;
  end;
end;

function TPSPAES.CBC(const Data: TBytes; Decrypting: Boolean): TBytes;
var
  Chain, Block, Cipher: TPSPAESBlock;
begin
  if Length(Data) and 15 <> 0 then
    raise EArgumentException.Create('AES-CBC data is not block aligned');
  SetLength(Result, Length(Data));
  FillChar(Chain, SizeOf(Chain), 0);
  for var N := 0 to Length(Data) div 16 - 1 do
  begin
    Move(Data[N * 16], Block, 16);
    if Decrypting then
    begin
      Cipher := Block;
      Decrypt(Block);
      for var I := 0 to 15 do
        Block[I] := Block[I] xor Chain[I];
      Chain := Cipher;
    end
    else
    begin
      for var I := 0 to 15 do
        Block[I] := Block[I] xor Chain[I];
      Encrypt(Block);
      Chain := Block;
    end;
    Move(Block, Result[N * 16], 16);
  end;
end;

procedure DoubleKey(var K: TPSPAESBlock);
begin
  var Carry := K[0] and $80;
  for var I := 0 to 14 do
    K[I] := Byte(((Cardinal(K[I]) shl 1) or (K[I + 1] shr 7)) and $FF);
  K[15] := Byte((Cardinal(K[15]) shl 1) and $FF);
  if Carry <> 0 then
    K[15] := K[15] xor $87;
end;

function TPSPAES.CMAC(const Data: TBytes): TBytes;
var
  SubKey, State: TPSPAESBlock;
begin
  FillChar(SubKey, 16, 0);
  Encrypt(SubKey);
  DoubleKey(SubKey);
  var Full := (Length(Data) > 0) and (Length(Data) and 15 = 0);
  if not Full then
    DoubleKey(SubKey);
  FillChar(State, 16, 0);
  var Blocks := (Length(Data) + 15) div 16;
  if Blocks = 0 then
    Blocks := 1;
  for var N := 0 to Blocks - 1 do
  begin
    for var I := 0 to 15 do
    begin
      var Pos := N * 16 + I;
      if Pos < Length(Data) then
        State[I] := State[I] xor Data[Pos]
      else if Pos = Length(Data) then
        State[I] := State[I] xor $80;
      if N = Blocks - 1 then
        State[I] := State[I] xor SubKey[I];
    end;
    Encrypt(State);
  end;
  SetLength(Result, 16);
  Move(State, Result[0], 16);
end;

function PSPAESDecrypt(const Data, Key: TBytes): TBytes;
begin
  var AES: TPSPAES;
  AES.Init(Key);
  Result := AES.CBC(Data, True);
end;

initialization
  MakeTables;

end.

