unit J2ME.M3G.Math;

interface

type
  TM3GMatrix = array[0..15] of Single; // Row-major, column vectors.

  TM3GVector = array[0..3] of Single;

  TM3GDoubleVector = array[0..3] of Double;

function M3GDoubleTransform(const M: TM3GMatrix; const V: TM3GDoubleVector): TM3GDoubleVector;

function M3GIdentity: TM3GMatrix;

function M3GMultiply(const A, B: TM3GMatrix): TM3GMatrix;

function M3GTranspose(const A: TM3GMatrix): TM3GMatrix;

function M3GInverse(const A: TM3GMatrix; out Inverse: TM3GMatrix): Boolean;

function M3GTranslation(X, Y, Z: Single): TM3GMatrix;

function M3GScale(X, Y, Z: Single): TM3GMatrix;

function M3GRotation(Angle, X, Y, Z: Single; out Rotation: TM3GMatrix): Boolean;

function M3GQuaternion(X, Y, Z, W: Single; out Rotation: TM3GMatrix): Boolean;

function M3GTransformVector(const M: TM3GMatrix; const V: TM3GVector): TM3GVector;

implementation

uses
  System.Math;

function M3GDoubleTransform(const M: TM3GMatrix; const V: TM3GDoubleVector): TM3GDoubleVector;
begin
  for var K := 0 to 3 do
  begin
    Result[K] := 0;
    for var J := 0 to 3 do
      Result[K] := Result[K] + M[K * 4 + J] * V[J];
  end;
end;

function M3GIdentity: TM3GMatrix;
begin
  Result := Default(TM3GMatrix);
  for var I := 0 to 3 do
    Result[I * 4 + I] := 1;
end;

function M3GMultiply(const A, B: TM3GMatrix): TM3GMatrix;
begin
  for var R := 0 to 3 do
    for var C := 0 to 3 do
    begin
      var Sum: Double := 0;
      for var K := 0 to 3 do
        Sum := Sum + Double(A[R * 4 + K]) * Double(B[K * 4 + C]);
      Result[R * 4 + C] := Sum;
    end;
end;

function M3GTranspose(const A: TM3GMatrix): TM3GMatrix;
begin
  for var R := 0 to 3 do
    for var C := 0 to 3 do
      Result[R * 4 + C] := A[C * 4 + R];
end;

function M3GInverse(const A: TM3GMatrix; out Inverse: TM3GMatrix): Boolean;
var
  Work: array[0..3, 0..7] of Double;
begin
  Result := False;
  Inverse := Default(TM3GMatrix);
  for var R := 0 to 3 do
    for var C := 0 to 7 do
    begin
      Work[R, C] := 0;
      if C < 4 then
      begin
        if IsNan(A[R * 4 + C]) or IsInfinite(A[R * 4 + C]) then
          Exit;
        Work[R, C] := A[R * 4 + C];
      end
      else if C = R + 4 then
        Work[R, C] := 1;
    end;
  for var R := 0 to 3 do
  begin
    var RowScale: Double := 0;
    for var C := 0 to 3 do
      RowScale := Max(RowScale, Abs(Work[R, C]));
    if RowScale = 0 then
      Exit;
    for var C := 0 to 7 do
      Work[R, C] := Work[R, C] / RowScale;
  end;
  // Partial-pivot Gauss-Jordan elimination also handles projective matrices.
  // Normalize rows first: small but representable scales must remain invertible.
  for var C := 0 to 3 do
  begin
    var Pivot := C;
    for var R := C + 1 to 3 do
      if Abs(Work[R, C]) > Abs(Work[Pivot, C]) then
        Pivot := R;
    if Abs(Work[Pivot, C]) <= 1.4210854715202004E-14 then
      Exit;
    if Pivot <> C then
      for var K := 0 to 7 do
      begin
        var Swap := Work[C, K];
        Work[C, K] := Work[Pivot, K];
        Work[Pivot, K] := Swap;
      end;
    var Divisor := Work[C, C];
    for var K := 0 to 7 do
      Work[C, K] := Work[C, K] / Divisor;
    for var R := 0 to 3 do
      if R <> C then
      begin
        var Factor := Work[R, C];
        for var K := 0 to 7 do
          Work[R, K] := Work[R, K] - Factor * Work[C, K];
      end;
  end;
  for var R := 0 to 3 do
    for var C := 0 to 3 do
    begin
      Inverse[R * 4 + C] := Work[R, C + 4];
      if IsNan(Inverse[R * 4 + C]) or IsInfinite(Inverse[R * 4 + C]) then
        Exit;
    end;
  Result := True;
end;

function M3GTranslation(X, Y, Z: Single): TM3GMatrix;
begin
  Result := M3GIdentity;
  Result[3] := X;
  Result[7] := Y;
  Result[11] := Z;
end;

function M3GScale(X, Y, Z: Single): TM3GMatrix;
begin
  Result := M3GIdentity;
  Result[0] := X;
  Result[5] := Y;
  Result[10] := Z;
end;

function ReducedDegrees(Angle: Single): Double;
var
  Magnitude, Power: Double;
begin
  Magnitude := Abs(Double(Angle));
  Power := 360;
  if IsNan(Magnitude) or IsInfinite(Magnitude) then
    Exit(NaN);

  // Binary long division keeps the exact remainder of even the largest binary32
  // angle. Dividing by360 and taking Frac loses that remainder at large exponents.
  while Power <= Magnitude / 2 do
    Power := Power * 2;
  while Magnitude >= 360 do
  begin
    if Magnitude >= Power then
      Magnitude := Magnitude - Power;
    Power := Power / 2;
  end;
  if Angle < 0 then
    Magnitude := -Magnitude;
  Result := Magnitude;
end;

function M3GRotation(Angle, X, Y, Z: Single; out Rotation: TM3GMatrix): Boolean;
var
  NX, NY, NZ, Length, S, C, T: Double;
begin
  Rotation := M3GIdentity;
  if Angle = 0 then
    Exit(True);
  Length := Sqrt(Double(X) * X + Double(Y) * Y + Double(Z) * Z);
  Result := Length <> 0;
  if not Result then
    Exit;
  NX := X / Length;
  NY := Y / Length;
  NZ := Z / Length;
  SinCos(ReducedDegrees(Angle) * (Pi / 180), S, C);
  T := 1 - C;
  Rotation[0] := NX * NX * T + C;
  Rotation[1] := NX * NY * T - NZ * S;
  Rotation[2] := NX * NZ * T + NY * S;
  Rotation[4] := NY * NX * T + NZ * S;
  Rotation[5] := NY * NY * T + C;
  Rotation[6] := NY * NZ * T - NX * S;
  Rotation[8] := NZ * NX * T - NY * S;
  Rotation[9] := NZ * NY * T + NX * S;
  Rotation[10] := NZ * NZ * T + C;
end;

function M3GQuaternion(X, Y, Z, W: Single; out Rotation: TM3GMatrix): Boolean;
var
  NX, NY, NZ, NW, Length: Double;
begin
  Rotation := M3GIdentity;
  Length := Sqrt(Double(X) * X + Double(Y) * Y + Double(Z) * Z + Double(W) * W);
  Result := Length <> 0;
  if not Result then
    Exit;
  NX := X / Length;
  NY := Y / Length;
  NZ := Z / Length;
  NW := W / Length;
  Rotation[0] := 1 - 2 * (NY * NY + NZ * NZ);
  Rotation[1] := 2 * (NX * NY - NZ * NW);
  Rotation[2] := 2 * (NX * NZ + NY * NW);
  Rotation[4] := 2 * (NX * NY + NZ * NW);
  Rotation[5] := 1 - 2 * (NX * NX + NZ * NZ);
  Rotation[6] := 2 * (NY * NZ - NX * NW);
  Rotation[8] := 2 * (NX * NZ - NY * NW);
  Rotation[9] := 2 * (NY * NZ + NX * NW);
  Rotation[10] := 1 - 2 * (NX * NX + NY * NY);
end;

function M3GTransformVector(const M: TM3GMatrix; const V: TM3GVector): TM3GVector;
begin
  for var R := 0 to 3 do
  begin
    var Sum: Double := 0;
    for var C := 0 to 3 do
      Sum := Sum + Double(M[R * 4 + C]) * V[C];
    Result[R] := Sum;
  end;
end;

end.

