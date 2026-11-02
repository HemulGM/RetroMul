unit PSP.Crypto.ECDSA;

// Verification only, on KIRK command 1's published 160-bit curve.
// Affine group arithmetic and binary modular inversion: no signing, RNG,
// private device keys or external libraries.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils;

function PSPVerifyKirkSignature(const Hash, Signature: TBytes): Boolean;

implementation

uses
  PSP.Crypto.Keys;

type
  TNumber = array[0..4] of Cardinal;
  TPoint = record
    X, Y: TNumber;
    Infinity: Boolean;
  end;

var
  Field, Order: TNumber;
  Generator, PublicKey: TPoint;

function Number(const Bytes: TBytes; Offset: Integer): TNumber;
begin
  for var I := 0 to 4 do
  begin
    var P := Offset + (4 - I) * 4;
    Result[I] := (Cardinal(Bytes[P]) shl 24) or (Cardinal(Bytes[P + 1]) shl 16) or (Cardinal(Bytes[P + 2]) shl 8) or
      Bytes[P + 3];
  end;
end;

function Compare(const A, B: TNumber): Integer; inline;
begin
  for var I := 4 downto 0 do
  begin
    if A[I] < B[I] then
      Exit(-1);
    if A[I] > B[I] then
      Exit(1);
  end;
  Result := 0;
end;

function IsZero(const A: TNumber): Boolean; inline;
begin
  Result := (A[0] or A[1] or A[2] or A[3] or A[4]) = 0;
end;

function IsOne(const A: TNumber): Boolean; inline;
begin
  Result := (A[0] = 1) and ((A[1] or A[2] or A[3] or A[4]) = 0);
end;

function Minus(const A, B: TNumber): TNumber;
begin
  var Borrow: Int64 := 0;
  for var I := 0 to 4 do
  begin
    var V := Int64(A[I]) - B[I] - Borrow;
    Result[I] := Cardinal(V and $FFFFFFFF);
    Borrow := Ord(V < 0);
  end;
end;

function PlusMod(const A, B, M: TNumber): TNumber;
begin
  var Carry: UInt64 := 0;
  for var I := 0 to 4 do
  begin
    var V := UInt64(A[I]) + B[I] + Carry;
    Result[I] := Cardinal(V and $FFFFFFFF);
    Carry := V shr 32;
  end;
  if (Carry <> 0) or (Compare(Result, M) >= 0) then
    Result := Minus(Result, M);
end;

function MinusMod(const A, B, M: TNumber): TNumber;
begin
  if Compare(A, B) >= 0 then
    Result := Minus(A, B)
  else
    Result := Minus(M, Minus(B, A));
end;

function TimesMod(const A, B, M: TNumber): TNumber;
begin
  Result := Default(TNumber);
  var V := A;
  for var I := 0 to 159 do
  begin
    if (B[I shr 5] and (Cardinal(1) shl (I and 31))) <> 0 then
      Result := PlusMod(Result, V, M);
    V := PlusMod(V, V, M);
  end;
end;

procedure Half(var A: TNumber; High: Cardinal = 0);
begin
  for var I := 4 downto 0 do
  begin
    var Low := A[I] and 1;
    A[I] := (A[I] shr 1) or (High shl 31);
    High := Low;
  end;
end;

procedure HalfMod(var A: TNumber; const M: TNumber);
begin
  var Carry: UInt64 := 0;
  if A[0] and 1 <> 0 then
    for var I := 0 to 4 do
    begin
      var V := UInt64(A[I]) + M[I] + Carry;
      A[I] := Cardinal(V and $FFFFFFFF);
      Carry := V shr 32;
    end;
  Half(A, Cardinal(Carry));
end;

function Inverse(const A, M: TNumber): TNumber;
begin
  var U := A;
  var V := M;
  var X := Default(TNumber);
  X[0] := 1;
  var Y := Default(TNumber);
  while not IsOne(U) and not IsOne(V) do
  begin
    if IsZero(U) or IsZero(V) then
      raise EArgumentException.Create('ECDSA inverse of zero');
    while U[0] and 1 = 0 do
    begin
      Half(U);
      HalfMod(X, M);
    end;
    while V[0] and 1 = 0 do
    begin
      Half(V);
      HalfMod(Y, M);
    end;
    if Compare(U, V) >= 0 then
    begin
      U := Minus(U, V);
      X := MinusMod(X, Y, M);
    end
    else
    begin
      V := Minus(V, U);
      Y := MinusMod(Y, X, M);
    end;
  end;
  if IsOne(U) then
    Result := X
  else
    Result := Y;
end;

function AddPoint(const A, B: TPoint): TPoint;
var
  Top, Bottom: TNumber;
begin
  if A.Infinity then
    Exit(B);
  if B.Infinity then
    Exit(A);
  Result := Default(TPoint);
  if Compare(A.X, B.X) = 0 then
  begin
    if (Compare(A.Y, B.Y) <> 0) or IsZero(A.Y) then
    begin
      Result.Infinity := True;
      Exit;
    end;
    var XX := TimesMod(A.X, A.X, Field);
    var Three := Default(TNumber);
    Three[0] := 3;
    Top := MinusMod(PlusMod(PlusMod(XX, XX, Field), XX, Field), Three, Field);
    Bottom := PlusMod(A.Y, A.Y, Field);
  end
  else
  begin
    Top := MinusMod(B.Y, A.Y, Field);
    Bottom := MinusMod(B.X, A.X, Field);
  end;
  var Slope := TimesMod(Top, Inverse(Bottom, Field), Field);
  Result.X := MinusMod(MinusMod(TimesMod(Slope, Slope, Field), A.X, Field), B.X, Field);
  Result.Y := MinusMod(TimesMod(Slope, MinusMod(A.X, Result.X, Field), Field), A.Y, Field);
end;

function Scale(const P: TPoint; const K: TNumber): TPoint;
begin
  Result := Default(TPoint);
  Result.Infinity := True;
  for var I := 159 downto 0 do
  begin
    Result := AddPoint(Result, Result);
    if (K[I shr 5] and (Cardinal(1) shl (I and 31))) <> 0 then
      Result := AddPoint(Result, P);
  end;
end;

function PSPVerifyKirkSignature(const Hash, Signature: TBytes): Boolean;
begin
  Result := False;
  if (Length(Hash) <> 20) or (Length(Signature) <> 40) then
    Exit;
  var R := Number(Signature, 0);
  var S := Number(Signature, 20);
  if IsZero(R) or IsZero(S) or (Compare(R, Order) >= 0) or (Compare(S, Order) >= 0) then
    Exit;
  var Z := Number(Hash, 0);
  if Compare(Z, Order) >= 0 then
    Z := Minus(Z, Order);
  var W := Inverse(S, Order);
  var P := AddPoint(Scale(Generator, TimesMod(Z, W, Order)), Scale(PublicKey, TimesMod(R, W, Order)));
  if P.Infinity then
    Exit;
  if Compare(P.X, Order) >= 0 then
    P.X := Minus(P.X, Order);
  Result := Compare(P.X, R) = 0;
end;

initialization
  // Field/order verified independently: G and Q lie on the curve and Q=dG
  // for the published test scalar. The wiki's prose swaps p/n; its executable
  // example and the curve equation agree with these values.
  Field := Number(PSPHex('FFFFFFFFFFFFFFFF00000001FFFFFFFFFFFFFFFF'), 0);
  Order := Number(PSPHex('FFFFFFFFFFFFFFFF0001B5C617F290EAE1DBAD8F'), 0);
  Generator.X := Number(PSPHex('2259ACEE15489CB096A882F0AE1CF9FD8EE5F8FA'), 0);
  Generator.Y := Number(PSPHex('604358456D0A1CB2908DE90F27D75C82BEC108C0'), 0);
  PublicKey.X := Number(PSPHex('ED9CE58234E61A53C685D64D51D0236BC3B5D4B9'), 0);
  PublicKey.Y := Number(PSPHex('049DF1A075C0E04FB344858B61B79B69A63D2C39'), 0);
end.
