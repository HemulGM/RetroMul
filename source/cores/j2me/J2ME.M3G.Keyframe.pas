unit J2ME.M3G.Keyframe;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallM3GKeyframe(VM: TJVM);

function M3GKeyframeHandles(const Name: string): Boolean;

function InvokeM3GKeyframe(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

procedure M3GValidateSequence(VM: TJVM; Ref: Integer);

function M3GSampleSequence(VM: TJVM; Ref: Integer; Time: Double): TArray<Double>;

implementation

uses
  System.SysUtils, System.Math, Java.Classes;

const
  Name = 'javax/microedition/m3g/KeyframeSequence';
  P = '$m3g.';

function I(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsInt;
end;

function R(O: TJVMObject; const Key: string): Integer;
begin
  Result := O.Fields[P + Key].AsRef;
end;

procedure PI(O: TJVMObject; const Key: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Int(Value));
end;

function M3GKeyframeHandles(const Name: string): Boolean;
begin
  Result := Name = 'javax/microedition/m3g/KeyframeSequence';
end;

procedure InstallM3GKeyframe(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(Name, 'javax/microedition/m3g/Object3D');
  try
    B.JavaClass.AddNative('<init>', '(III)V');
    B.JavaClass.AddNative('setKeyframe', '(II[F)V');
    B.JavaClass.AddNative('getKeyframe', '(I[F)I');
    B.JavaClass.AddNative('setValidRange', '(II)V');
    B.JavaClass.AddNative('setDuration', '(I)V');
    B.JavaClass.AddNative('setRepeatMode', '(I)V');
    for var N in ['ComponentCount', 'KeyframeCount', 'InterpolationType', 'Duration', 'RepeatMode', 'ValidRangeFirst', 'ValidRangeLast'] do
      B.JavaClass.AddNative('get' + N, '()I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeM3GKeyframe(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if N = '<init>' then
  begin
    var Count := Args[1].AsInt;
    var Components := Args[2].AsInt;
    var Mode := Args[3].AsInt;
    if (Count < 1) or (Components < 1) or not (Mode in [176..180]) or
      ((Mode in [177, 179]) and (Components <> 4)) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G keyframe dimensions/interpolation');
    if (Count > VM.MaxArrayLength) or (Int64(Count) * Components > VM.MaxArrayLength) then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'M3G keyframe array limit');
    // Store both arrays in the guest heap: references survive GC and snapshots.
    O.Fields.AddOrSetValue(P + 'keyTimes', TJVMValue.Ref(VM.NewArray('[I', Count)));
    // Normalize quaternion inputs once, retaining enough internal precision
    // that sampling need not normalize a second time. Public vectors are float.
    O.Fields.AddOrSetValue(P + 'keyValues', TJVMValue.Ref(VM.NewArray('[D', Count * Components)));
    PI(O, 'keyCount', Count);
    PI(O, 'keyComponents', Components);
    PI(O, 'keyMode', Mode);
    PI(O, 'keyRepeat', 192);
    PI(O, 'keyDuration', 0);
    PI(O, 'keyFirst', 0);
    PI(O, 'keyLast', Count - 1);
    Exit;
  end;
  if N = 'getComponentCount' then
    Exit(TJVMValue.Int(I(O, 'keyComponents')));
  if N = 'getKeyframeCount' then
    Exit(TJVMValue.Int(I(O, 'keyCount')));
  if N = 'getInterpolationType' then
    Exit(TJVMValue.Int(I(O, 'keyMode')));
  if N = 'getDuration' then
    Exit(TJVMValue.Int(I(O, 'keyDuration')));
  if N = 'getRepeatMode' then
    Exit(TJVMValue.Int(I(O, 'keyRepeat')));
  if N = 'getValidRangeFirst' then
    Exit(TJVMValue.Int(I(O, 'keyFirst')));
  if N = 'getValidRangeLast' then
    Exit(TJVMValue.Int(I(O, 'keyLast')));
  if N = 'setDuration' then
  begin
    if Args[1].AsInt <= 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G keyframe duration');
    PI(O, 'keyDuration', Args[1].AsInt);
    Exit;
  end;
  if N = 'setRepeatMode' then
  begin
    if (Args[1].AsInt <> 192) and (Args[1].AsInt <> 193) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G keyframe repeat mode');
    PI(O, 'keyRepeat', Args[1].AsInt);
    Exit;
  end;
  if N = 'setValidRange' then
  begin
    for var K := 1 to 2 do
      if (Args[K].AsInt < 0) or (Args[K].AsInt >= I(O, 'keyCount')) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G keyframe valid range');
    PI(O, 'keyFirst', Args[1].AsInt);
    PI(O, 'keyLast', Args[2].AsInt);
    Exit;
  end;
  if (N = 'getKeyframe') or (N = 'setKeyframe') then
  begin
    var Index := Args[1].AsInt;
    var Components := I(O, 'keyComponents');
    if (Index < 0) or (Index >= I(O, 'keyCount')) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G keyframe index');
    var Setting := N = 'setKeyframe';
    var A := 2;
    if Setting then
      A := 3;
    var Output: TJVMObject := nil;
    if Setting or (Args[A].AsRef <> 0) then
    begin
      Output := VM.GetObject(Args[A].AsRef);
      if (Output.ClassName <> '[F') or (Length(Output.Elements) < Components) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G keyframe vector length');
    end;
    var Times := VM.GetObject(R(O, 'keyTimes'));
    var Values := VM.GetObject(R(O, 'keyValues'));
    if Setting then
    begin
      if Args[2].AsInt < 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G negative keyframe time');
      var Scale: Double := 1;
      if I(O, 'keyMode') in [177, 179] then
      begin
        var Norm: Double := 0;
        for var K := 0 to 3 do
          Norm := Norm + Sqr(Double(Output.Elements[K].AsFloat));
        // Zero quaternion interpolation is undefined; keep its stored value.
        if Norm > 0 then
          Scale := 1 / Sqrt(Norm);
      end;
      for var K := 0 to Components - 1 do
        if Values.ClassName = '[D' then
          Values.Elements[Index * Components + K] := TJVMValue.Double(Output.Elements[K].AsFloat * Scale)
        else
          Values.Elements[Index * Components + K] := TJVMValue.Float(Output.Elements[K].AsFloat * Scale);
      Times.Elements[Index] := Args[2];
    end
    else
    begin
      if Output <> nil then
        for var K := 0 to Components - 1 do
          if Values.ClassName = '[D' then
            Output.Elements[K] := TJVMValue.Float(Values.Elements[Index * Components + K].AsDouble)
          else
            Output.Elements[K] := Values.Elements[Index * Components + K];
      Result := Times.Elements[Index];
    end;
    Exit;
  end;
  raise EJVMUnsupported.Create(Name + '.' + N + Method.Descriptor);
end;

procedure M3GValidateSequence(VM: TJVM; Ref: Integer);
begin
  var O := VM.GetObject(Ref);
  var Count := I(O, 'keyCount');
  var Duration := I(O, 'keyDuration');
  if Duration <= 0 then
    VM.RaiseJava('java/lang/IllegalStateException', 'M3G keyframe duration is unset');
  var Times := VM.GetObject(R(O, 'keyTimes'));
  var At := I(O, 'keyFirst');
  var Previous := -1;
  while True do
  begin
    if VM.StopRequested then
      raise EJVMError.Create('M3G keyframe validation cancelled');
    var Time := Times.Elements[At].AsInt;
    if (Time < Previous) or (Time > Duration) then
      VM.RaiseJava('java/lang/IllegalStateException', 'M3G keyframe times/duration');
    Previous := Time;
    if At = I(O, 'keyLast') then
      Break;
    At := (At + 1) mod Count;
  end;
end;

type
  TQuat = array[0..3] of Double;

function QMul(const A, B: TQuat): TQuat;
begin
  Result[0] := A[3] * B[0] + A[0] * B[3] + A[1] * B[2] - A[2] * B[1];
  Result[1] := A[3] * B[1] - A[0] * B[2] + A[1] * B[3] + A[2] * B[0];
  Result[2] := A[3] * B[2] + A[0] * B[1] - A[1] * B[0] + A[2] * B[3];
  Result[3] := A[3] * B[3] - A[0] * B[0] - A[1] * B[1] - A[2] * B[2];
end;

function QLogDelta(const A, B: TQuat): TQuat;
begin
  var Inverse := A;
  for var K := 0 to 2 do
    Inverse[K] := -Inverse[K];
  var Q := QMul(Inverse, B);
  var Norm := Sqrt(Sqr(Q[0]) + Sqr(Q[1]) + Sqr(Q[2]));
  Result := Default(TQuat);
  if Norm > 0 then
    for var K := 0 to 2 do
      Result[K] := Q[K] * ArcTan2(Norm, Q[3]) / Norm;
end;

function QExp(const Q: TQuat): TQuat;
begin
  var Norm := Sqrt(Sqr(Q[0]) + Sqr(Q[1]) + Sqr(Q[2]));
  var Scale: Double := 1;
  if Norm > 0 then
    Scale := Sin(Norm) / Norm;
  for var K := 0 to 2 do
    Result[K] := Q[K] * Scale;
  Result[3] := Cos(Norm);
end;

function QSlerp(const A, B: TQuat; S: Double): TQuat;
begin
  var Dot: Double := 0;
  for var K := 0 to 3 do
    Dot := Dot + A[K] * B[K];
  Dot := EnsureRange(Dot, -1.0, 1.0);
  var Perpendicular: TQuat;
  var Norm: Double := 0;
  for var K := 0 to 3 do
  begin
    Perpendicular[K] := B[K] - Dot * A[K];
    Norm := Norm + Sqr(Perpendicular[K]);
  end;
  Norm := Sqrt(Norm);
  if Norm > 1E-15 then
  begin
    // atan2 plus the perpendicular direction stays stable near opposed keys.
    // acos(dot)/sin(acos(dot)) amplifies single-precision storage roundoff.
    var Angle := ArcTan2(Norm, Dot);
    for var K := 0 to 3 do
      Result[K] := Cos(S * Angle) * A[K] + Sin(S * Angle) * Perpendicular[K] / Norm;
  end
  else
    for var K := 0 to 3 do
      Result[K] := (1 - S) * A[K] + S * B[K];
  // Do not negate a negative-dot endpoint: M3G permits rotations above 180deg.
  // Exactly opposed quaternions are undefined by the API.
end;

function SequenceRemainder(Time: Double; Duration: Integer): Double;
begin
  // Delphi FMod uses Trunc/Int64, which overflows for large sequence times.
  // Binary long division keeps the representable remainder without that cast.
  Result := Abs(Time);
  var Divisor: Double := Duration;
  while Divisor <= Result / 2 do
    Divisor := Divisor * 2;
  while Divisor >= Duration do
  begin
    if Result >= Divisor then
      Result := Result - Divisor;
    Divisor := Divisor / 2;
  end;
  if (Time < 0) and (Result <> 0) then
    Result := Duration - Result;
end;

function M3GSampleSequence(VM: TJVM; Ref: Integer; Time: Double): TArray<Double>;
var
  O, Times, Values: TJVMObject;
  Count, First, Valid, Components, Mode, Duration: Integer;
  Looping: Boolean;

  function Index(N: Integer): Integer;
  begin
    Result := (First + (N mod Valid + Valid) mod Valid) mod Count;
  end;

  function Stamp(N: Integer): Double;
  begin
    Result := Times.Elements[Index(N)].AsInt;
    if N < 0 then
      Result := Result - Duration
    else if N >= Valid then
      Result := Result + Duration;
  end;

  function Value(N, K: Integer): Double;
  begin
    // [F] is retained for snapshots written by the original keyframe module.
    var V := Values.Elements[Index(N) * Components + K];
    if V.Kind = TJVMKind.Double then
      Result := V.AsDouble
    else
      Result := V.AsFloat;
  end;

  function Quat(N: Integer): TQuat;
  begin
    for var K := 0 to 3 do
      Result[K] := Value(N, K);
  end;

  function TangentFactor(N: Integer; Outgoing: Boolean): Double;
  begin
    Result := 0;
    if not Looping and ((N = 0) or (N = Valid - 1)) then
      Exit;
    var Span := Stamp(N + 1) - Stamp(N - 1);
    if Span = 0 then
      Exit;
    if Outgoing then
      Result := 2 * (Stamp(N + 1) - Stamp(N)) / Span
    else
      Result := 2 * (Stamp(N) - Stamp(N - 1)) / Span;
  end;

  function Control(N: Integer; Outgoing: Boolean): TQuat;
  begin
    var Q := Quat(N);
    var Before := QLogDelta(Quat(N - 1), Q);
    var After := QLogDelta(Q, Quat(N + 1));
    var F := TangentFactor(N, Outgoing);
    var T := Default(TQuat);
    for var K := 0 to 2 do
      if Outgoing then
        T[K] := ((Before[K] + After[K]) * F / 2 - After[K]) / 2
      else
        T[K] := (Before[K] - (Before[K] + After[K]) * F / 2) / 2;
    Result := QMul(Q, QExp(T));
  end;

begin
  M3GValidateSequence(VM, Ref);
  if IsNan(Time) or IsInfinite(Time) then
    VM.RaiseJava('java/lang/IllegalStateException', 'M3G non-finite sequence time');
  O := VM.GetObject(Ref);
  Times := VM.GetObject(R(O, 'keyTimes'));
  Values := VM.GetObject(R(O, 'keyValues'));
  Count := I(O, 'keyCount');
  First := I(O, 'keyFirst');
  Components := I(O, 'keyComponents');
  Valid := (I(O, 'keyLast') - First + Count) mod Count + 1;
  Duration := I(O, 'keyDuration');
  Mode := I(O, 'keyMode');
  Looping := I(O, 'keyRepeat') = 193;
  SetLength(Result, Components);
  var Left := 0;
  var Right: Integer;
  if Looping then
  begin
    Time := SequenceRemainder(Time, Duration);
    if Time < Stamp(0) then
      Left := -1
    else
      while (Left + 1 < Valid) and (Stamp(Left + 1) <= Time) do
        Inc(Left);
    Right := Left + 1;
  end
  else
  begin
    if Time >= Stamp(0) then
      while (Left + 1 < Valid) and (Stamp(Left + 1) <= Time) do
        Inc(Left);
    Right := Left;
    if (Time >= Stamp(0)) and (Left < Valid - 1) then
      Inc(Right);
  end;
  var Span := Stamp(Right) - Stamp(Left);
  var S: Double := 0;
  if Span > 0 then
    S := (Time - Stamp(Left)) / Span;
  if (Left = Right) or (Mode = 180) or (S = 0) then
  begin
    for var K := 0 to Components - 1 do
      Result[K] := Value(Left, K);
    Exit;
  end;
  if Mode in [177, 179] then
  begin
    var Q := QSlerp(Quat(Left), Quat(Right), S);
    if Mode = 179 then
      Q := QSlerp(Q, QSlerp(Control(Left, True), Control(Right, False), S), 2 * S * (1 - S));
    for var K := 0 to 3 do
      Result[K] := Q[K];
    Exit;
  end;
  for var K := 0 to Components - 1 do
  begin
    if (K and 255) = 0 then
      if VM.StopRequested then
        raise EJVMError.Create('M3G keyframe sampling cancelled');
    var A := Value(Left, K);
    var B := Value(Right, K);
    if Mode = 176 then
      Result[K] := (1 - S) * A + S * B
    else
    begin
      var T0: Double := 0;
      var T1: Double := 0;
      if Looping or (Left <> 0) then
        T0 := (Value(Left + 1, K) - Value(Left - 1, K)) * TangentFactor(Left, True) / 2;
      if Looping or (Right <> Valid - 1) then
        T1 := (Value(Right + 1, K) - Value(Right - 1, K)) * TangentFactor(Right, False) / 2;
      Result[K] := (2 * S * S * S - 3 * S * S + 1) * A + (-2 * S * S * S + 3 * S * S) * B + (S * S * S - 2 * S * S + S) * T0 + (S * S * S - S * S) * T1;
    end;
  end;
end;

end.

