unit AVM1.Geometry;

interface

uses
  AVM1.Runtime;

procedure RegisterAVMGeometry(VM: TAVM1; out Roots: TArray<TAVMObject>);

function AVMGeometryCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;

implementation

uses
  System.SysUtils, System.Math, AVM1.Numeric, AVM1.Coercion, SWF.Reader;

const
  ColorNames: array[0..7] of string = ('redMultiplier', 'greenMultiplier', 'blueMultiplier', 'alphaMultiplier',
    'redOffset', 'greenOffset', 'blueOffset', 'alphaOffset');
  ColorOrder: array[0..7] of Integer = (3, 0, 1, 2, 7, 4, 5, 6);

function GeometryClass(VM: TAVM1; const Name: string): TAVMValue;
var
  NamespaceValue: TAVMValue;
begin
  NamespaceValue := VM.Get(VM.Global, 'flash');
  NamespaceValue := VM.Get(NamespaceValue.Obj, 'geom');
  Result := VM.Get(NamespaceValue.Obj, Name);
end;

function NewGeometry(VM: TAVM1; const Name: string; const Args: TArray<TAVMValue>): TAVMValue;
var
  ConstructorValue: TAVMValue;
begin
  ConstructorValue := GeometryClass(VM, Name);
  Result := VM.Construct(ConstructorValue, Args);
end;

function Arithmetic(VM: TAVM1; Op: Byte; const A, B: TAVMValue): TAVMValue;
var
  X, Y: Double;
begin
  if Op = $47 then
    Exit(VM.AddValues(A, B));
  X := VM.CoerceNumber(A);
  Y := VM.CoerceNumber(B);
  Result := TAVMValue.Num(AVMBinaryNumber(Op, X, Y));
end;

function Invoke(VM: TAVM1; O: TAVMObject; const Name: string; const Args: TArray<TAVMValue>): TAVMValue;
var
  Fn: TAVMValue;
begin
  Fn := VM.Get(O, Name);
  Result := VM.Call(Fn, O, Args);
end;

function MathCall(VM: TAVM1; const Name: string; const Args: TArray<TAVMValue>): TAVMValue;
var
  MathValue: TAVMValue;
begin
  MathValue := VM.Get(VM.Global, 'Math');
  Result := Invoke(VM, MathValue.Obj, Name, Args);
end;

function PointCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  A, B, C, X, Y, Scale, OtherValue: TAVMValue;
  Other: TAVMObject;
  S: string;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

  function Get(const Key: string): TAVMValue;
  begin
    Result := VM.Get(O, Key);
  end;

begin
  Result := Default(TAVMValue);
  OtherValue := Arg(0);
  Other := OtherValue.Obj;
  if Name = 'Point' then
  begin
    if Length(Args) = 0 then
    begin
      VM.Put(O, 'y', TAVMValue.Num(0));
      VM.Put(O, 'x', TAVMValue.Num(0));
    end
    else
    begin
      VM.Put(O, 'x', Arg(0));
      VM.Put(O, 'y', Arg(1));
    end;
    Exit;
  end;
  if Name = 'Point.distance' then
  begin
    A := Invoke(VM, Other, 'subtract', [Arg(1)]);
    Exit(VM.Get(A.Obj, 'length'));
  end;
  if Name = 'Point.polar' then
  begin
    A := MathCall(VM, 'sin', [Arg(1)]);
    Y := Arithmetic(VM, $0C, Arg(0), A);
    A := MathCall(VM, 'cos', [Arg(1)]);
    X := Arithmetic(VM, $0C, Arg(0), A);
    Exit(NewGeometry(VM, 'Point', [X, Y]));
  end;
  if Name = 'Point.interpolate' then
  begin
    O := Arg(1).Obj;
    A := Get('y');
    B := VM.Get(Other, 'y');
    C := Get('y');
    B := Arithmetic(VM, $0B, B, C);
    B := Arithmetic(VM, $0C, B, Arg(2));
    Y := Arithmetic(VM, $47, A, B);
    A := Get('x');
    B := VM.Get(Other, 'x');
    C := Get('x');
    B := Arithmetic(VM, $0B, B, C);
    B := Arithmetic(VM, $0C, B, Arg(2));
    X := Arithmetic(VM, $47, A, B);
    Exit(NewGeometry(VM, 'Point', [X, Y]));
  end;
  if Name = 'Point.length' then
  begin
    A := Get('x');
    B := Get('x');
    X := Arithmetic(VM, $0C, A, B);
    A := Get('y');
    B := Get('y');
    Y := Arithmetic(VM, $0C, A, B);
    A := Arithmetic(VM, $47, X, Y);
    Exit(MathCall(VM, 'sqrt', [A]));
  end;
  if Name = 'Point.setLength' then
    Exit;
  if Name = 'Point.clone' then
  begin
    Y := Get('y');
    X := Get('x');
    Exit(NewGeometry(VM, 'Point', [X, Y]));
  end;
  if (Name = 'Point.add') or (Name = 'Point.subtract') then
  begin
    A := Get('y');
    B := VM.Get(Other, 'y');
    if Name = 'Point.add' then
      Y := Arithmetic(VM, $47, A, B)
    else
      Y := Arithmetic(VM, $0B, A, B);
    A := Get('x');
    B := VM.Get(Other, 'x');
    if Name = 'Point.add' then
      X := Arithmetic(VM, $47, A, B)
    else
      X := Arithmetic(VM, $0B, A, B);
    Exit(NewGeometry(VM, 'Point', [X, Y]));
  end;
  if Name = 'Point.offset' then
  begin
    A := Get('x');
    A := Arithmetic(VM, $47, A, Arg(0));
    VM.Put(O, 'x', A);
    A := Get('y');
    A := Arithmetic(VM, $47, A, Arg(1));
    VM.Put(O, 'y', A);
    Exit;
  end;
  if Name = 'Point.equals' then
  begin
    A := GeometryClass(VM, 'Point');
    if not VM.InstanceOf(OtherValue, A) then
      Exit(TAVMValue.Bool(False));
    A := VM.Get(Other, 'x');
    B := Get('x');
    if not VM.EqualValues(A, B, False) then
      Exit(TAVMValue.Bool(False));
    A := VM.Get(Other, 'y');
    B := Get('y');
    Exit(TAVMValue.Bool(VM.EqualValues(A, B, False)));
  end;
  if Name = 'Point.normalize' then
  begin
    A := Get('length');
    B := VM.LessThan(TAVMValue.Num(0), A);
    if not B.AsBoolean then
      Exit;
    Scale := Arithmetic(VM, $0D, Arg(0), A);
    A := Get('x');
    A := Arithmetic(VM, $0C, A, Scale);
    VM.Put(O, 'x', A);
    A := Get('y');
    A := Arithmetic(VM, $0C, A, Scale);
    VM.Put(O, 'y', A);
    Exit;
  end;
  if Name = 'Point.toString' then
  begin
    A := Get('x');
    B := VM.AddValues(TAVMValue.Str('(x='), A);
    S := B.Text;
    A := Get('y');
    B := VM.AddValues(TAVMValue.Str(S + ', y='), A);
    S := B.Text + ')';
    Exit(TAVMValue.Str(S));
  end;
  raise ESWFError.Create('Unsupported AVM1 geometry ' + Name);
end;

function MatrixCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
const
  Keys: array[0..5] of string = ('a', 'b', 'c', 'd', 'tx', 'ty');
var
  Values: TArray<TAVMValue>;
  A, B, C, D, TX, TY, L, R, T, U, Det, CosValue, SinValue: TAVMValue;
  Other: TAVMObject;
  I: Integer;
  Skewed: Boolean;
  S: string;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

  function Get(const Key: string): TAVMValue;
  begin
    Result := VM.Get(O, Key);
  end;

  function Product(const LeftKey, RightKey: string; RightObject: TAVMObject): TAVMValue;
  var
    LeftValue, RightValue: TAVMValue;
  begin
    LeftValue := Get(LeftKey);
    RightValue := VM.Get(RightObject, RightKey);
    Result := Arithmetic(VM, $0C, LeftValue, RightValue);
  end;

  function Zero(const V: TAVMValue): Boolean;
  begin
    Result := VM.EqualValues(V, TAVMValue.Num(0), False);
  end;

begin
  Result := Default(TAVMValue);
  Other := Arg(0).Obj;
  if Name = 'Matrix' then
  begin
    if Length(Args) = 0 then
      Invoke(VM, O, 'identity', [])
    else
      for I := 0 to 5 do
        VM.Put(O, Keys[I], Arg(I));
    Exit;
  end;
  if Name = 'Matrix.identity' then
  begin
    VM.Put(O, 'd', TAVMValue.Num(1));
    VM.Put(O, 'a', TAVMValue.Num(1));
    VM.Put(O, 'c', TAVMValue.Num(0));
    VM.Put(O, 'b', TAVMValue.Num(0));
    VM.Put(O, 'ty', TAVMValue.Num(0));
    VM.Put(O, 'tx', TAVMValue.Num(0));
    Exit;
  end;
  if Name = 'Matrix.clone' then
  begin
    SetLength(Values, 6);
    for I := 5 downto 0 do
      Values[I] := Get(Keys[I]);
    Exit(NewGeometry(VM, 'Matrix', Values));
  end;
  if Name = 'Matrix.concat' then
  begin
    A := Product('a', 'a', Other);
    D := Product('d', 'd', Other);
    B := TAVMValue.Num(0);
    C := B;
    L := Product('tx', 'a', Other);
    R := VM.Get(Other, 'tx');
    TX := Arithmetic(VM, $47, L, R);
    L := Product('ty', 'd', Other);
    R := VM.Get(Other, 'ty');
    TY := Arithmetic(VM, $47, L, R);
    Skewed := not Zero(Get('b'));
    if not Skewed then
      Skewed := not Zero(Get('c'));
    if not Skewed then
      Skewed := not Zero(VM.Get(Other, 'b'));
    if not Skewed then
      Skewed := not Zero(VM.Get(Other, 'c'));
    if Skewed then
    begin
      T := Product('b', 'c', Other);
      A := Arithmetic(VM, $47, A, T);
      T := Product('c', 'b', Other);
      D := Arithmetic(VM, $47, D, T);
      L := Product('a', 'b', Other);
      R := Product('b', 'd', Other);
      T := Arithmetic(VM, $47, L, R);
      B := Arithmetic(VM, $47, B, T);
      L := Product('c', 'a', Other);
      R := Product('d', 'c', Other);
      T := Arithmetic(VM, $47, L, R);
      C := Arithmetic(VM, $47, C, T);
      T := Product('ty', 'c', Other);
      TX := Arithmetic(VM, $47, TX, T);
      T := Product('tx', 'b', Other);
      TY := Arithmetic(VM, $47, TY, T);
    end;
    VM.Put(O, 'a', A);
    VM.Put(O, 'b', B);
    VM.Put(O, 'c', C);
    VM.Put(O, 'd', D);
    VM.Put(O, 'tx', TX);
    VM.Put(O, 'ty', TY);
    Exit;
  end;
  if Name = 'Matrix.invert' then
  begin
    if Zero(Get('b')) then
    begin
      if Zero(Get('c')) then
      begin
        A := Get('a');
        A := Arithmetic(VM, $0D, TAVMValue.Num(1), A);
        VM.Put(O, 'a', A);
        D := Get('d');
        D := Arithmetic(VM, $0D, TAVMValue.Num(1), D);
        VM.Put(O, 'd', D);
        VM.Put(O, 'c', TAVMValue.Num(0));
        VM.Put(O, 'b', TAVMValue.Num(0));
        A := Get('a');
        A := TAVMValue.Num(-VM.CoerceNumber(A));
        TX := Get('tx');
        TX := Arithmetic(VM, $0C, A, TX);
        VM.Put(O, 'tx', TX);
        D := Get('d');
        D := TAVMValue.Num(-VM.CoerceNumber(D));
        TY := Get('ty');
        TY := Arithmetic(VM, $0C, D, TY);
        VM.Put(O, 'ty', TY);
        Exit;
      end;
    end;
    A := Get('a');
    B := Get('b');
    C := Get('c');
    D := Get('d');
    L := Arithmetic(VM, $0C, A, D);
    R := Arithmetic(VM, $0C, B, C);
    Det := Arithmetic(VM, $0B, L, R);
    if Det.Number = 0 then
    begin
      Invoke(VM, O, 'identity', []);
      Exit;
    end;
    Det := Arithmetic(VM, $0D, TAVMValue.Num(1), Det);
    T := Arithmetic(VM, $0C, D, Det);
    VM.Put(O, 'a', T);
    T := TAVMValue.Num(-VM.CoerceNumber(B));
    T := Arithmetic(VM, $0C, T, Det);
    VM.Put(O, 'b', T);
    T := TAVMValue.Num(-VM.CoerceNumber(C));
    T := Arithmetic(VM, $0C, T, Det);
    VM.Put(O, 'c', T);
    T := Arithmetic(VM, $0C, A, Det);
    VM.Put(O, 'd', T);
    TY := Get('ty');
    TX := Get('tx');
    T := NewGeometry(VM, 'Point', [TX, TY]);
    T := Invoke(VM, O, 'deltaTransformPoint', [T]);
    U := VM.Get(T.Obj, 'x');
    VM.Put(O, 'tx', TAVMValue.Num(-VM.CoerceNumber(U)));
    U := VM.Get(T.Obj, 'y');
    VM.Put(O, 'ty', TAVMValue.Num(-VM.CoerceNumber(U)));
    Exit;
  end;
  if Name = 'Matrix.createBox' then
  begin
    TX := Arg(3);
    TY := Arg(4);
    if Length(Args) < 4 then
      TX := TAVMValue.Num(0);
    if Length(Args) < 5 then
      TY := TAVMValue.Num(0);
    Invoke(VM, O, 'identity', []);
    Invoke(VM, O, 'rotate', [Arg(2)]);
    Invoke(VM, O, 'scale', [Arg(0), Arg(1)]);
    VM.Put(O, 'tx', TX);
    VM.Put(O, 'ty', TY);
    Exit;
  end;
  if Name = 'Matrix.createGradientBox' then
  begin
    T := Arg(2);
    TX := Arg(3);
    TY := Arg(4);
    if Length(Args) < 3 then
      T := TAVMValue.Num(0);
    if Length(Args) < 4 then
      TX := TAVMValue.Num(0);
    if Length(Args) < 5 then
      TY := TAVMValue.Num(0);
    U := Arithmetic(VM, $0D, Arg(1), TAVMValue.Num(2));
    TY := Arithmetic(VM, $47, TY, U);
    U := Arithmetic(VM, $0D, Arg(0), TAVMValue.Num(2));
    TX := Arithmetic(VM, $47, TX, U);
    D := Arithmetic(VM, $0D, Arg(1), TAVMValue.Num(1638.4));
    A := Arithmetic(VM, $0D, Arg(0), TAVMValue.Num(1638.4));
    Invoke(VM, O, 'createBox', [A, D, T, TX, TY]);
    Exit;
  end;
  if (Name = 'Matrix.scale') or (Name = 'Matrix.rotate') then
  begin
    if Name = 'Matrix.rotate' then
    begin
      CosValue := MathCall(VM, 'cos', [Arg(0)]);
      SinValue := MathCall(VM, 'sin', [Arg(0)]);
      U := TAVMValue.Num(-VM.CoerceNumber(SinValue));
      T := NewGeometry(VM, 'Matrix', [CosValue, SinValue, U, CosValue, TAVMValue.Num(0), TAVMValue.Num(0)]);
    end
    else
      T := NewGeometry(VM, 'Matrix', [Arg(0), TAVMValue.Num(0), TAVMValue.Num(0), Arg(1), TAVMValue.Num(0), TAVMValue.Num(0)]);
    Invoke(VM, O, 'concat', [T]);
    Exit;
  end;
  if Name = 'Matrix.translate' then
  begin
    T := Get('tx');
    T := Arithmetic(VM, $47, T, Arg(0));
    VM.Put(O, 'tx', T);
    T := Get('ty');
    T := Arithmetic(VM, $47, T, Arg(1));
    VM.Put(O, 'ty', T);
    Exit;
  end;
  if (Name = 'Matrix.transformPoint') or (Name = 'Matrix.deltaTransformPoint') then
  begin
    L := Product('d', 'y', Other);
    R := Product('b', 'x', Other);
    TY := Arithmetic(VM, $47, L, R);
    if Name = 'Matrix.transformPoint' then
    begin
      T := Get('ty');
      TY := Arithmetic(VM, $47, TY, T);
    end;
    L := Product('a', 'x', Other);
    R := Product('c', 'y', Other);
    TX := Arithmetic(VM, $47, L, R);
    if Name = 'Matrix.transformPoint' then
    begin
      T := Get('tx');
      TX := Arithmetic(VM, $47, TX, T);
    end;
    Exit(NewGeometry(VM, 'Point', [TX, TY]));
  end;
  if Name = 'Matrix.toString' then
  begin
    S := '(';
    for I := 0 to 5 do
    begin
      T := Get(Keys[I]);
      if I > 0 then
        S := S + ', ';
      U := VM.AddValues(TAVMValue.Str(S + Keys[I] + '='), T);
      S := U.Text;
    end;
    Exit(TAVMValue.Str(S + ')'));
  end;
  raise ESWFError.Create('Unsupported AVM1 geometry ' + Name);
end;

function RectangleCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
const
  Keys: array[0..3] of string = ('x', 'y', 'width', 'height');
var
  A, B, X, Y, W, H, Right, Bottom, OtherRight, OtherBottom, V: TAVMValue;
  Other, Output: TAVMObject;
  Values: TArray<TAVMValue>;
  I: Integer;
  S, MethodName: string;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

  function Get(const Key: string): TAVMValue;
  begin
    Result := VM.Get(O, Key);
  end;

  function OtherGet(const Key: string): TAVMValue;
  begin
    Result := VM.Get(Other, Key);
  end;

  function Edge(ObjectValue: TAVMObject; const Position, Size: string): TAVMValue;
  var
    L, R: TAVMValue;
  begin
    L := VM.Get(ObjectValue, Position);
    R := VM.Get(ObjectValue, Size);
    Result := Arithmetic(VM, $47, L, R);
  end;

  function Compare(const L, R: TAVMValue; Op: Integer): TAVMValue;
  begin
    case Op of
      0:
        Result := VM.LessThan(L, R);
      1:
        Result := VM.LessThan(R, L);
      2:
        begin
          Result := VM.LessThan(L, R);
          Result := TAVMValue.Bool(not Result.AsBoolean);
        end;
    else
      Result := VM.LessThan(R, L);
      Result := TAVMValue.Bool(not Result.AsBoolean);
    end;
  end;

begin
  Result := Default(TAVMValue);
  Other := Arg(0).Obj;
  if Name = 'Rectangle' then
  begin
    if Length(Args) = 0 then
      Invoke(VM, O, 'setEmpty', [])
    else
      for I := 0 to 3 do
        VM.Put(O, Keys[I], Arg(I));
    Exit;
  end;
  if Name = 'Rectangle.setEmpty' then
  begin
    for I := 3 downto 0 do
      VM.Put(O, Keys[I], TAVMValue.Num(0));
    Exit;
  end;
  if Name = 'Rectangle.clone' then
  begin
    SetLength(Values, 4);
    for I := 3 downto 0 do
      Values[I] := Get(Keys[I]);
    Exit(NewGeometry(VM, 'Rectangle', Values));
  end;
  if Name = 'Rectangle.isEmpty' then
  begin
    A := Get('width');
    V := Compare(A, TAVMValue.Num(0), 3);
    if V.AsBoolean then
      Exit(V);
    A := Get('height');
    Exit(Compare(A, TAVMValue.Num(0), 3));
  end;
  if Name.StartsWith('Rectangle.get.') then
  begin
    MethodName := Copy(Name, 15, MaxInt);
    if MethodName = 'left' then
      Exit(Get('x'));
    if MethodName = 'top' then
      Exit(Get('y'));
    if MethodName = 'right' then
      Exit(Edge(O, 'x', 'width'));
    if MethodName = 'bottom' then
      Exit(Edge(O, 'y', 'height'));
    if MethodName = 'topLeft' then
    begin
      Y := Get('y');
      X := Get('x');
    end
    else if MethodName = 'bottomRight' then
    begin
      Y := Edge(O, 'y', 'height');
      X := Edge(O, 'x', 'width');
    end
    else
    begin
      Y := Get('height');
      X := Get('width');
    end;
    Exit(NewGeometry(VM, 'Point', [X, Y]));
  end;
  if Name.StartsWith('Rectangle.set.') then
  begin
    MethodName := Copy(Name, 15, MaxInt);
    if MethodName = 'left' then
    begin
      W := Get('width');
      X := Get('x');
      V := Arithmetic(VM, $0B, X, Arg(0));
      W := Arithmetic(VM, $47, W, V);
      VM.Put(O, 'width', W);
      VM.Put(O, 'x', Arg(0));
    end
    else if MethodName = 'top' then
    begin
      H := Get('height');
      Y := Get('y');
      V := Arithmetic(VM, $0B, Y, Arg(0));
      H := Arithmetic(VM, $47, H, V);
      VM.Put(O, 'height', H);
      VM.Put(O, 'y', Arg(0));
    end
    else if MethodName = 'right' then
    begin
      X := Get('x');
      W := Arithmetic(VM, $0B, Arg(0), X);
      VM.Put(O, 'width', W);
    end
    else if MethodName = 'bottom' then
    begin
      Y := Get('y');
      H := Arithmetic(VM, $0B, Arg(0), Y);
      VM.Put(O, 'height', H);
    end
    else if MethodName = 'size' then
    begin
      X := OtherGet('x');
      VM.Put(O, 'width', X);
      Y := OtherGet('y');
      VM.Put(O, 'height', Y);
    end
    else if MethodName = 'bottomRight' then
    begin
      A := OtherGet('x');
      X := Get('x');
      W := Arithmetic(VM, $0B, A, X);
      VM.Put(O, 'width', W);
      A := OtherGet('y');
      Y := Get('y');
      H := Arithmetic(VM, $0B, A, Y);
      VM.Put(O, 'height', H);
    end
    else if MethodName = 'topLeft' then
    begin
      W := Get('width');
      X := Get('x');
      A := OtherGet('x');
      V := Arithmetic(VM, $0B, X, A);
      W := Arithmetic(VM, $47, W, V);
      VM.Put(O, 'width', W);
      H := Get('height');
      Y := Get('y');
      A := OtherGet('y');
      V := Arithmetic(VM, $0B, Y, A);
      H := Arithmetic(VM, $47, H, V);
      VM.Put(O, 'height', H);
      X := OtherGet('x');
      VM.Put(O, 'x', X);
      Y := OtherGet('y');
      VM.Put(O, 'y', Y);
    end;
    Exit;
  end;
  if (Name = 'Rectangle.offset') or (Name = 'Rectangle.offsetPoint') then
  begin
    X := Get('x');
    if Name = 'Rectangle.offset' then
      A := Arg(0)
    else
      A := OtherGet('x');
    X := Arithmetic(VM, $47, X, A);
    VM.Put(O, 'x', X);
    Y := Get('y');
    if Name = 'Rectangle.offset' then
      A := Arg(1)
    else
      A := OtherGet('y');
    Y := Arithmetic(VM, $47, Y, A);
    VM.Put(O, 'y', Y);
    Exit;
  end;
  if (Name = 'Rectangle.inflate') or (Name = 'Rectangle.inflatePoint') then
  begin
    X := Get('x');
    if Name = 'Rectangle.inflate' then
      A := Arg(0)
    else
      A := OtherGet('x');
    X := Arithmetic(VM, $0B, X, A);
    VM.Put(O, 'x', X);
    W := Get('width');
    if Name = 'Rectangle.inflate' then
      A := Arg(0)
    else
      A := OtherGet('x');
    A := Arithmetic(VM, $0C, A, TAVMValue.Num(2));
    W := Arithmetic(VM, $47, W, A);
    VM.Put(O, 'width', W);
    Y := Get('y');
    if Name = 'Rectangle.inflate' then
      A := Arg(1)
    else
      A := OtherGet('y');
    Y := Arithmetic(VM, $0B, Y, A);
    VM.Put(O, 'y', Y);
    H := Get('height');
    if Name = 'Rectangle.inflate' then
      A := Arg(1)
    else
      A := OtherGet('y');
    A := Arithmetic(VM, $0C, A, TAVMValue.Num(2));
    H := Arithmetic(VM, $47, H, A);
    VM.Put(O, 'height', H);
    Exit;
  end;
  if (Name = 'Rectangle.contains') or (Name = 'Rectangle.containsPoint') then
  begin
    if Name = 'Rectangle.contains' then
      A := Arg(0)
    else
      A := OtherGet('x');
    X := Get('x');
    Result := Compare(A, X, 2);
    if not Result.AsBoolean then
      Exit;
    if Name = 'Rectangle.contains' then
      A := Arg(0)
    else
      A := OtherGet('x');
    Right := Edge(O, 'x', 'width');
    Result := Compare(A, Right, 0);
    if not Result.AsBoolean then
      Exit;
    if Name = 'Rectangle.contains' then
      A := Arg(1)
    else
      A := OtherGet('y');
    Y := Get('y');
    Result := Compare(A, Y, 2);
    if not Result.AsBoolean then
      Exit;
    if Name = 'Rectangle.contains' then
      A := Arg(1)
    else
      A := OtherGet('y');
    Bottom := Edge(O, 'y', 'height');
    Result := Compare(A, Bottom, 0);
    Exit;
  end;
  if Name = 'Rectangle.containsRectangle' then
  begin
    OtherRight := Edge(Other, 'x', 'width');
    OtherBottom := Edge(Other, 'y', 'height');
    Right := Edge(O, 'x', 'width');
    Bottom := Edge(O, 'y', 'height');
    A := OtherGet('x');
    X := Get('x');
    Result := Compare(A, X, 2);
    if not Result.AsBoolean then
      Exit;
    A := OtherGet('x');
    Result := Compare(A, Right, 0);
    if not Result.AsBoolean then
      Exit;
    A := OtherGet('y');
    Y := Get('y');
    Result := Compare(A, Y, 2);
    if not Result.AsBoolean then
      Exit;
    A := OtherGet('y');
    Result := Compare(A, Bottom, 0);
    if not Result.AsBoolean then
      Exit;
    X := Get('x');
    Result := Compare(OtherRight, X, 1);
    if not Result.AsBoolean then
      Exit;
    Result := Compare(OtherRight, Right, 3);
    if not Result.AsBoolean then
      Exit;
    Y := Get('y');
    Result := Compare(OtherBottom, Y, 1);
    if not Result.AsBoolean then
      Exit;
    Result := Compare(OtherBottom, Bottom, 3);
    Exit;
  end;
  if (Name = 'Rectangle.intersection') or (Name = 'Rectangle.union') then
  begin
    if Name = 'Rectangle.union' then
    begin
      V := Invoke(VM, O, 'isEmpty', []);
      if V.AsBoolean then
        Exit(Invoke(VM, Other, 'clone', []));
      V := Invoke(VM, Other, 'isEmpty', []);
      if V.AsBoolean then
        Exit(Invoke(VM, O, 'clone', []));
      MethodName := 'min';
    end
    else
      MethodName := 'max';
    Result := NewGeometry(VM, 'Rectangle', []);
    Output := Result.Obj;
    if Name = 'Rectangle.intersection' then
    begin
      V := Invoke(VM, O, 'isEmpty', []);
      if not V.AsBoolean then
        V := Invoke(VM, Other, 'isEmpty', []);
      if V.AsBoolean then
      begin
        Invoke(VM, Output, 'setEmpty', []);
        Exit;
      end;
    end;
    B := OtherGet('x');
    A := Get('x');
    X := MathCall(VM, MethodName, [A, B]);
    VM.Put(Output, 'x', X);
    B := OtherGet('y');
    A := Get('y');
    Y := MathCall(VM, MethodName, [A, B]);
    VM.Put(Output, 'y', Y);
    if Name = 'Rectangle.union' then
      MethodName := 'max'
    else
      MethodName := 'min';
    OtherRight := Edge(Other, 'x', 'width');
    Right := Edge(O, 'x', 'width');
    A := MathCall(VM, MethodName, [Right, OtherRight]);
    X := VM.Get(Output, 'x');
    W := Arithmetic(VM, $0B, A, X);
    VM.Put(Output, 'width', W);
    OtherBottom := Edge(Other, 'y', 'height');
    Bottom := Edge(O, 'y', 'height');
    A := MathCall(VM, MethodName, [Bottom, OtherBottom]);
    Y := VM.Get(Output, 'y');
    H := Arithmetic(VM, $0B, A, Y);
    VM.Put(Output, 'height', H);
    if Name = 'Rectangle.intersection' then
    begin
      W := VM.Get(Output, 'width');
      V := Compare(W, TAVMValue.Num(0), 3);
      if not V.AsBoolean then
      begin
        H := VM.Get(Output, 'height');
        V := Compare(H, TAVMValue.Num(0), 3);
      end;
      if V.AsBoolean then
        Invoke(VM, Output, 'setEmpty', []);
    end;
    Exit;
  end;
  if Name = 'Rectangle.intersects' then
  begin
    A := Invoke(VM, O, 'intersection', [Arg(0)]);
    V := Invoke(VM, A.Obj, 'isEmpty', []);
    Exit(TAVMValue.Bool(not V.AsBoolean));
  end;
  if Name = 'Rectangle.equals' then
  begin
    V := GeometryClass(VM, 'Rectangle');
    if not VM.InstanceOf(Arg(0), V) then
      Exit(TAVMValue.Bool(False));
    for I := 0 to 3 do
    begin
      A := OtherGet(Keys[I]);
      B := Get(Keys[I]);
      if not VM.EqualValues(A, B, False) then
        Exit(TAVMValue.Bool(False));
    end;
    Exit(TAVMValue.Bool(True));
  end;
  if Name = 'Rectangle.toString' then
  begin
    S := '(';
    for I := 0 to 3 do
    begin
      A := Get(Keys[I]);
      if I > 0 then
        S := S + ', ';
      if I < 2 then
        S := S + Keys[I]
      else
        S := S + Keys[I][1];
      B := VM.AddValues(TAVMValue.Str(S + '='), A);
      S := B.Text;
    end;
    Exit(TAVMValue.Str(S + ')'));
  end;
  raise ESWFError.Create('Unsupported AVM1 geometry ' + Name);
end;

function ColorTransformCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  Data, Other: IAVMColorData;
  Values: array[0..7] of Double;
  V: TAVMValue;
  I, Index: Integer;
  RGB: Cardinal;
  Sum: UInt64;
  S: string;
  X, Y: Double;
begin
  Result := Default(TAVMValue);
  if Name = 'ColorTransform' then
  begin
    if O = nil then
      Exit;
    for I := 0 to 7 do
      if I < 4 then
        Values[I] := 1
      else
        Values[I] := 0;
    if Length(Args) >= 8 then
      for I := 0 to 7 do
        Values[I] := VM.CoerceNumber(Args[I])
    else if (Length(Args) = 1) and (Args[0].Obj <> nil) and (Args[0].Obj.ColorData <> nil) then
      for I := 0 to 7 do
        Values[I] := Args[0].Obj.ColorData[I];
    Data := TAVMColorData.Create;
    for I := 0 to 7 do
      Data[I] := Values[I];
    O.ColorData := Data;
    O.IsDate := False;
    O.IsBoxed := False;
    O.PrimitiveValue := Default(TAVMValue);
    O.IsTransform := False;
    O.TransformTarget := nil;
    O.TransformPath := '';
    Exit(TAVMValue.Ref(O));
  end;
  if Name = 'ColorTransform.toString' then
  begin
    S := '(';
    for I := 0 to 7 do
    begin
      V := VM.Get(O, ColorNames[I]);
      if I > 0 then
        S := S + ', ';
      S := S + ColorNames[I] + '=' + VM.CoerceString(V);
    end;
    Exit(TAVMValue.Str(S + ')'));
  end;
  if O = nil then
    Exit;
  Data := O.ColorData;
  if Data = nil then
    Exit;
  if Name.StartsWith('ColorTransform.get.') then
  begin
    Index := StrToInt(Copy(Name, 20, MaxInt));
    Exit(TAVMValue.Num(Data[Index]));
  end;
  if Name.StartsWith('ColorTransform.set.') then
  begin
    if Length(Args) > 0 then
    begin
      Index := StrToInt(Copy(Name, 20, MaxInt));
      X := VM.CoerceNumber(Args[0]);
      Data[Index] := X;
    end;
    Exit;
  end;
  if Name = 'ColorTransform.getRGB' then
  begin
    RGB := Cardinal(AVMToInt32(Data[4]));
    Sum := UInt64(RGB shl 16);
    RGB := Cardinal(AVMToInt32(Data[5]));
    Sum := Sum + (RGB shl 8);
    RGB := Cardinal(AVMToInt32(Data[6]));
    Sum := Sum + RGB;
    Exit(TAVMValue.Num(Cardinal(Sum and $FFFFFFFF)));
  end;
  if Name = 'ColorTransform.setRGB' then
  begin
    if Length(Args) > 0 then
    begin
      RGB := Cardinal(AVMToInt32(VM.CoerceNumber(Args[0])));
      for I := 0 to 2 do
      begin
        Data[I] := 0;
        Data[4 + I] := (RGB shr ((2 - I) * 8)) and 255;
      end;
    end;
    Exit;
  end;
  if Name = 'ColorTransform.concat' then
  begin
    if (Length(Args) = 0) or (Args[0].Obj = nil) then
      Exit;
    Other := Args[0].Obj.ColorData;
    if Other = nil then
      Exit;
    for I := 0 to 3 do
    begin
      X := AVMBinaryNumber($0C, Other[4 + I], Data[I]);
      Y := Data[4 + I];
      Data[4 + I] := AVMBinaryNumber($0A, X, Y);
    end;
    for I := 0 to 3 do
      Data[I] := AVMBinaryNumber($0C, Other[I], Data[I]);
    Exit;
  end;
  raise ESWFError.Create('Unsupported AVM1 geometry ' + Name);
end;

procedure RegisterAVMGeometry(VM: TAVM1; out Roots: TArray<TAVMObject>);
var
  FlashObject, GeomObject, PrototypeObject: TAVMObject;
  ConstructorValue: TAVMValue;
  ClassName, Name: string;
  I, Index, ClassIndex: Integer;

  procedure Method(const Key: string);
  begin
    VM.Put(PrototypeObject, Key, VM.NativeFunction('Geom.' + ClassName + '.' + Key));
  end;

begin
  FlashObject := VM.NewObject;
  GeomObject := VM.NewObject;
  VM.Put(VM.Global, 'flash', TAVMValue.Ref(FlashObject));
  VM.Put(FlashObject, 'geom', TAVMValue.Ref(GeomObject));
  SetLength(Roots, 4);
  ClassIndex := 0;
  for ClassName in ['Point', 'Matrix', 'Rectangle', 'ColorTransform'] do
  begin
    ConstructorValue := VM.NativeFunction('Geom.' + ClassName);
    PrototypeObject := VM.NewObject;
    VM.Put(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(PrototypeObject));
    VM.Put(PrototypeObject, 'constructor', ConstructorValue);
    PrototypeObject.Attributes.AddOrSetValue('constructor', 1);
    VM.Put(GeomObject, ClassName, ConstructorValue);
    Roots[ClassIndex] := PrototypeObject;
    Inc(ClassIndex);
    if ClassName = 'Point' then
    begin
      for Name in ['distance', 'polar', 'interpolate'] do
        VM.Put(ConstructorValue.Obj, Name, VM.NativeFunction('Geom.Point.' + Name));
      VM.AddProperty(PrototypeObject, 'length', VM.NativeFunction('Geom.Point.length').Obj, VM.NativeFunction('Geom.Point.setLength').Obj);
      for Name in ['clone', 'offset', 'equals', 'subtract', 'add', 'normalize', 'toString'] do
        Method(Name);
    end
    else if ClassName = 'Matrix' then
    begin
      for Name in ['concat', 'invert', 'createBox', 'createGradientBox', 'clone', 'identity', 'rotate', 'translate', 'scale', 'deltaTransformPoint', 'transformPoint', 'toString'] do
        Method(Name);
    end
    else if ClassName = 'Rectangle' then
    begin
      for Name in ['clone', 'setEmpty', 'isEmpty'] do
        Method(Name);
      for Name in ['left', 'right', 'top', 'bottom', 'topLeft', 'bottomRight', 'size'] do
        VM.AddProperty(PrototypeObject, Name, VM.NativeFunction('Geom.Rectangle.get.' + Name).Obj,
          VM.NativeFunction('Geom.Rectangle.set.' + Name).Obj);
      for Name in ['inflate', 'inflatePoint', 'offset', 'offsetPoint', 'contains', 'containsPoint', 'containsRectangle', 'intersection', 'intersects', 'union', 'equals', 'toString'] do
        Method(Name);
    end
    else
    begin
      for I := 0 to 7 do
      begin
        Index := ColorOrder[I];
        VM.AddProperty(PrototypeObject, ColorNames[Index], VM.NativeFunction('Geom.ColorTransform.get.' + IntToStr(Index)).Obj,
          VM.NativeFunction('Geom.ColorTransform.set.' + IntToStr(Index)).Obj);
      end;
      VM.AddProperty(PrototypeObject, 'rgb', VM.NativeFunction('Geom.ColorTransform.getRGB').Obj, VM.NativeFunction('Geom.ColorTransform.setRGB').Obj);
      Method('concat');
      Method('toString');
    end;
  end;
end;

function AVMGeometryCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  MethodName: string;
begin
  MethodName := Copy(Name, 6, MaxInt);
  if MethodName.StartsWith('Point') then
    Exit(PointCall(VM, MethodName, O, Args));
  if MethodName.StartsWith('Matrix') then
    Exit(MatrixCall(VM, MethodName, O, Args));
  if MethodName.StartsWith('Rectangle') then
    Exit(RectangleCall(VM, MethodName, O, Args));
  if MethodName.StartsWith('ColorTransform') then
    Exit(ColorTransformCall(VM, MethodName, O, Args));
  raise ESWFError.Create('Unsupported AVM1 geometry ' + Name);
end;

end.

