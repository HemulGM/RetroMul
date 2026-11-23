unit SWF.Geometry;

interface

uses
  SWF.Reader;

type
  TSWFBounds = record
    Rect: TSWFRect;
    Valid: Boolean;
    class function Empty: TSWFBounds; static;
    class function FromRect(const Value: TSWFRect): TSWFBounds; static;
    class function Line(X0, Y0, X1, Y1: Double): TSWFBounds; static;
    class function Quadratic(X0, Y0, CX, CY, X1, Y1: Double): TSWFBounds; static;
    procedure Include(const Other: TSWFBounds);
    function Expanded(Amount: Double): TSWFBounds;
    function Transformed(const Matrix: TSWFMatrix): TSWFBounds;
  end;

function SWFInverseMatrix(const Value: TSWFMatrix; out Inverse: TSWFMatrix): Boolean;

procedure SWFTransformPoint(const Matrix: TSWFMatrix; X, Y: Integer; out OutX, OutY: Integer);

implementation

uses
  System.Math;

class function TSWFBounds.Empty: TSWFBounds;
begin
  Result := Default(TSWFBounds);
  Result.Rect.Left := $7FFFFFF;
  Result.Rect.Right := $7FFFFFF;
  Result.Rect.Top := $7FFFFFF;
  Result.Rect.Bottom := $7FFFFFF;
end;

class function TSWFBounds.FromRect(const Value: TSWFRect): TSWFBounds;
begin
  Result.Rect := Value;
  Result.Valid := Value.Left <> $7FFFFFF;
end;

function FloorCoordinate(Value: Double): Integer;
begin
  if IsNan(Value) then
    Exit(0);
  if Value <= Low(Integer) then
    Exit(Low(Integer));
  if Value >= High(Integer) then
    Exit(High(Integer));
  Result := Trunc(Value);
  if Value < Result then
    Dec(Result);
end;

function CeilCoordinate(Value: Double): Integer;
begin
  if IsNan(Value) then
    Exit(0);
  if Value <= Low(Integer) then
    Exit(Low(Integer));
  if Value >= High(Integer) then
    Exit(High(Integer));
  Result := Trunc(Value);
  if Value > Result then
    Inc(Result);
end;

class function TSWFBounds.Line(X0, Y0, X1, Y1: Double): TSWFBounds;
begin
  Result.Valid := True;
  Result.Rect.Left := FloorCoordinate(Min(X0, X1));
  Result.Rect.Right := CeilCoordinate(Max(X0, X1));
  Result.Rect.Top := FloorCoordinate(Min(Y0, Y1));
  Result.Rect.Bottom := CeilCoordinate(Max(Y0, Y1));
end;

class function TSWFBounds.Quadratic(X0, Y0, CX, CY, X1, Y1: Double): TSWFBounds;
var
  T, U, Denominator, X, Y: Double;

  procedure At(Value: Double);
  begin
    T := Value;
    if (T <= 0) or (T >= 1) then
      Exit;
    U := 1 - T;
    X := U * U * X0 + 2 * U * T * CX + T * T * X1;
    Y := U * U * Y0 + 2 * U * T * CY + T * T * Y1;
    Result.Include(TSWFBounds.Line(X, Y, X, Y));
  end;

begin
  Result := Line(X0, Y0, X1, Y1);
  Denominator := X0 - 2 * CX + X1;
  if Denominator <> 0 then
    At((X0 - CX) / Denominator);
  Denominator := Y0 - 2 * CY + Y1;
  if Denominator <> 0 then
    At((Y0 - CY) / Denominator);
end;

procedure TSWFBounds.Include(const Other: TSWFBounds);
begin
  if not Other.Valid then
    Exit;
  if not Valid then
  begin
    Self := Other;
    Exit;
  end;
  Rect.Left := Min(Rect.Left, Other.Rect.Left);
  Rect.Right := Max(Rect.Right, Other.Rect.Right);
  Rect.Top := Min(Rect.Top, Other.Rect.Top);
  Rect.Bottom := Max(Rect.Bottom, Other.Rect.Bottom);
end;

function TSWFBounds.Expanded(Amount: Double): TSWFBounds;
begin
  Result := Self;
  if not Valid then
    Exit;
  Result.Rect.Left := FloorCoordinate(Rect.Left - Amount);
  Result.Rect.Right := CeilCoordinate(Rect.Right + Amount);
  Result.Rect.Top := FloorCoordinate(Rect.Top - Amount);
  Result.Rect.Bottom := CeilCoordinate(Rect.Bottom + Amount);
end;

procedure SWFTransformPoint(const Matrix: TSWFMatrix; X, Y: Integer; out OutX, OutY: Integer);
begin
  OutX := SWFAddCoordinate(SWFRoundCoordinate(SWFMatrixProduct(Matrix.A, SWFFloat32(X), Matrix.C, SWFFloat32(Y))), Trunc(Matrix.TX));
  OutY := SWFAddCoordinate(SWFRoundCoordinate(SWFMatrixProduct(Matrix.B, SWFFloat32(X), Matrix.D, SWFFloat32(Y))), Trunc(Matrix.TY));
end;

function TSWFBounds.Transformed(const Matrix: TSWFMatrix): TSWFBounds;
var
  I, X, Y, PX, PY: Integer;
  Corner: TSWFBounds;
begin
  Result := Empty;
  if not Valid then
    Exit;
  for I := 0 to 3 do
  begin
    if (I and 1) = 0 then
      X := Rect.Left
    else
      X := Rect.Right;
    if (I and 2) = 0 then
      Y := Rect.Top
    else
      Y := Rect.Bottom;
    SWFTransformPoint(Matrix, X, Y, PX, PY);
    Corner.Valid := True;
    Corner.Rect.Left := PX;
    Corner.Rect.Right := PX;
    Corner.Rect.Top := PY;
    Corner.Rect.Bottom := PY;
    Result.Include(Corner);
  end;
end;

function SWFInverseMatrix(const Value: TSWFMatrix; out Inverse: TSWFMatrix): Boolean;
var
  Det, X, Y, Numerator: Double;
  Mask: TArithmeticExceptionMask;
begin
  Inverse := TSWFMatrix.Identity;
  Mask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    Det := SWFMatrixProduct(Value.A, Value.D, -Value.B, Value.C);
    Result := Abs(Det) > 1.1920928955078125e-7;
    if not Result then
      Exit;
    Inverse.A := SWFFloat32(Value.D / Det);
    Inverse.B := SWFFloat32(Value.B /  - Det);
    Inverse.C := SWFFloat32(Value.C /  - Det);
    Inverse.D := SWFFloat32(Value.A / Det);
    X := SWFFloat32(Value.TX);
    Y := SWFFloat32(Value.TY);
    Numerator := SWFMatrixProduct(Value.D, X, -Value.C, Y);
    Inverse.TX := SWFRoundCoordinate(SWFFloat32(Numerator /  - Det));
    Numerator := SWFMatrixProduct(Value.B, X, -Value.A, Y);
    Inverse.TY := SWFRoundCoordinate(SWFFloat32(Numerator / Det));
  finally
    ClearExceptions;
    SetExceptionMask(Mask);
  end;
end;

end.

