unit J2ME.M3G.Animation;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallM3GAnimation(VM: TJVM);

function M3GAnimationHandles(const Name: string): Boolean;

function InvokeM3GAnimation(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function InvokeM3GAnimationObject(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GAnimationReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, Java.Classes,
  J2ME.M3G, J2ME.M3G.Math, J2ME.M3G.Keyframe, J2ME.M3G.Sprite, J2ME.M3G.Morph;

const
  Base = 'javax/microedition/m3g/';
  P = '$m3g.';
  ControllerName = Base + 'AnimationController';
  TrackName = Base + 'AnimationTrack';

function I(O: TJVMObject; const Key: string; Fallback: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsInt;
end;

function F(O: TJVMObject; const Key: string; Fallback: Double = 0): Double;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Key, V) then
    if V.Kind = TJVMKind.Double then
      Result := V.AsDouble
    else
      Result := V.AsFloat;
end;

function R(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsRef;
end;

procedure PI(O: TJVMObject; const Key: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Int(Value));
end;

procedure PF(O: TJVMObject; const Key: string; Value: Double);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Float(Value));
end;

function M3GAnimationHandles(const Name: string): Boolean;
begin
  Result := (Name = ControllerName) or (Name = TrackName);
end;

procedure InstallM3GAnimation(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(ControllerName, Base + 'Object3D');
  try
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('setActiveInterval', '(II)V');
    B.JavaClass.AddNative('setSpeed', '(FI)V');
    B.JavaClass.AddNative('setPosition', '(FI)V');
    B.JavaClass.AddNative('setWeight', '(F)V');
    B.JavaClass.AddNative('getPosition', '(I)F');
    for var N in ['ActiveIntervalStart', 'ActiveIntervalEnd', 'RefWorldTime'] do
      B.JavaClass.AddNative('get' + N, '()I');
    for var N in ['Speed', 'Weight'] do
      B.JavaClass.AddNative('get' + N, '()F');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(TrackName, Base + 'Object3D');
  try
    var Properties: TArray<string> := ['ALPHA', 'AMBIENT_COLOR', 'COLOR', 'CROP', 'DENSITY', 'DIFFUSE_COLOR', 'EMISSIVE_COLOR', 'FAR_DISTANCE', 'FIELD_OF_VIEW', 'INTENSITY', 'MORPH_WEIGHTS', 'NEAR_DISTANCE', 'ORIENTATION', 'PICKABILITY', 'SCALE', 'SHININESS', 'SPECULAR_COLOR', 'SPOT_ANGLE', 'SPOT_EXPONENT', 'TRANSLATION', 'VISIBILITY'];
    for var K := 0 to High(Properties) do
    begin
      B.Field(Properties[K], 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(256 + K);
    end;
    B.JavaClass.AddNative('<init>', '(Ljavax/microedition/m3g/KeyframeSequence;I)V');
    B.JavaClass.AddNative('getTargetProperty', '()I');
    B.JavaClass.AddNative('getKeyframeSequence', '()Ljavax/microedition/m3g/KeyframeSequence;');
    B.JavaClass.AddNative('getController', '()Ljavax/microedition/m3g/AnimationController;');
    B.JavaClass.AddNative('setController', '(Ljavax/microedition/m3g/AnimationController;)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function Position(O: TJVMObject; WorldTime: Integer): Double;
begin
  Result := F(O, 'animPosition') + F(O, 'animSpeed', 1) * (Double(WorldTime) - I(O, 'animWorld'));
end;

function CompatibleSize(PropertyID, Size: Integer): Boolean;
begin
  case PropertyID of
    256, 260, 263..265, 267, 269, 271, 273, 274, 276:
      Result := Size = 1;
    257, 258, 261, 262, 272, 275:
      Result := Size = 3;
    259:
      Result := (Size = 2) or (Size = 4);
    268:
      Result := Size = 4;
    270:
      Result := (Size = 1) or (Size = 3);
    266:
      Result := Size > 0;
  else
    Result := False;
  end;
end;

function InvokeM3GAnimation(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if Method.Owner.Name = ControllerName then
  begin
    if N = '<init>' then
    begin
      PI(O, 'animStart', 0);
      PI(O, 'animEnd', 0);
      PI(O, 'animWorld', 0);
      PF(O, 'animPosition', 0);
      PF(O, 'animSpeed', 1);
      PF(O, 'animWeight', 1);
      Exit;
    end;
    if N = 'getActiveIntervalStart' then
      Exit(TJVMValue.Int(I(O, 'animStart')));
    if N = 'getActiveIntervalEnd' then
      Exit(TJVMValue.Int(I(O, 'animEnd')));
    if N = 'getRefWorldTime' then
      Exit(TJVMValue.Int(I(O, 'animWorld')));
    if N = 'getSpeed' then
      Exit(TJVMValue.Float(F(O, 'animSpeed', 1)));
    if N = 'getWeight' then
      Exit(TJVMValue.Float(F(O, 'animWeight', 1)));
    if N = 'getPosition' then
      Exit(TJVMValue.Float(Position(O, Args[1].AsInt)));
    if N = 'setActiveInterval' then
    begin
      if Args[1].AsInt > Args[2].AsInt then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G animation active interval');
      PI(O, 'animStart', Args[1].AsInt);
      PI(O, 'animEnd', Args[2].AsInt);
      Exit;
    end;
    if N = 'setWeight' then
    begin
      if Args[1].AsFloat < 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G animation weight');
      O.Fields.AddOrSetValue(P + 'animWeight', Args[1]);
      Exit;
    end;
    if N = 'setPosition' then
    begin
      O.Fields.AddOrSetValue(P + 'animPosition', Args[1]);
      PI(O, 'animWorld', Args[2].AsInt);
      Exit;
    end;
    if N = 'setSpeed' then
    begin
      // Preserve the reference point before changing speed; no int subtraction.
      O.Fields.AddOrSetValue(P + 'animPosition', TJVMValue.Double(Position(O, Args[2].AsInt)));
      PI(O, 'animWorld', Args[2].AsInt);
      O.Fields.AddOrSetValue(P + 'animSpeed', Args[1]);
      Exit;
    end;
  end
  else
  begin
    if N = '<init>' then
    begin
      var Sequence := VM.GetObject(Args[1].AsRef);
      var PropertyID := Args[2].AsInt;
      if not CompatibleSize(PropertyID, I(Sequence, 'keyComponents')) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G animation track property/keyframe size');
      O.Fields.AddOrSetValue(P + 'animSequence', Args[1]);
      PI(O, 'animProperty', PropertyID);
      O.Fields.AddOrSetValue(P + 'animController', TJVMValue.Ref(0));
      Exit;
    end;
    if N = 'getKeyframeSequence' then
      Exit(TJVMValue.Ref(R(O, 'animSequence')));
    if N = 'getController' then
      Exit(TJVMValue.Ref(R(O, 'animController')));
    if N = 'getTargetProperty' then
      Exit(TJVMValue.Int(I(O, 'animProperty')));
    if N = 'setController' then
    begin
      O.Fields.AddOrSetValue(P + 'animController', Args[1]);
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create(Method.Owner.Name + '.' + N + Method.Descriptor);
end;

function TrackRefs(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  var Ref := R(O, 'animTracks');
  if Ref = 0 then
    Exit;
  var Tracks := VM.GetObject(Ref);
  SetLength(Result, Length(Tracks.Elements));
  for var K := 0 to High(Result) do
    Result[K] := Tracks.Elements[K].AsRef;
end;

function M3GAnimationReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := TrackRefs(VM, O);
  if VM.IsAssignable(O.ClassName, TrackName) then
    for var Key in ['animSequence', 'animController'] do
      if R(O, Key) <> 0 then
        Result := Result + [R(O, Key)];
end;

function CompatibleTarget(VM: TJVM; O: TJVMObject; PropertyID: Integer): Boolean;

  function IsA(const Name: string): Boolean;
  begin
    Result := VM.IsAssignable(O.ClassName, Base + Name);
  end;

begin
  case PropertyID of
    256:
      Result := IsA('Node') or IsA('Background') or IsA('Material') or IsA('VertexBuffer');
    257, 261, 262, 271, 272:
      Result := IsA('Material');
    258:
      Result := IsA('Light') or IsA('Background') or IsA('Fog') or IsA('Texture2D') or IsA('VertexBuffer');
    259:
      Result := IsA('Sprite3D') or IsA('Background');
    260:
      Result := IsA('Fog');
    263, 267:
      Result := IsA('Camera') or IsA('Fog');
    264:
      Result := IsA('Camera');
    265, 273, 274:
      Result := IsA('Light');
    266:
      Result := IsA('MorphingMesh');
    268, 270, 275:
      Result := IsA('Transformable');
    269, 276:
      Result := IsA('Node');
  else
    Result := False;
  end;
end;

function Clamp(Value, Low, High: Double): Double;
begin
  if IsNan(Value) then
    Result := Low
  else if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;

function Rounded(Value: Double; Minimum: Integer = Low(Integer); Maximum: Integer = High(Integer)): Integer;
begin
  Value := Clamp(Value, Minimum, Maximum);
  Result := Integer(Floor(Value + 0.5));
end;

procedure Apply(VM: TJVM; O: TJVMObject; PropertyID: Integer; const Values: TArray<Double>);

  function IsA(const Name: string): Boolean;
  begin
    Result := VM.IsAssignable(O.ClassName, Base + Name);
  end;

  procedure RealValue(const Key: string; V: Double; Minimum: Double = -3.4028234663852886E38; Maximum: Double = 3.4028234663852886E38);
  begin
    PF(O, Key, Clamp(V, Minimum, Maximum));
  end;

  function Channel(V: Double): Integer;
  begin
    Result := Rounded(255 * Clamp(V, 0, 1), 0, 255);
  end;

  function ColorKey: string;
  begin
    if IsA('Material') then
      Result := 'color2048'
    else if IsA('Light') then
      Result := 'lightColor'
    else if IsA('Texture2D') then
      Result := 'BlendColor'
    else
      Result := 'color';
  end;

  function ColorDefault: Integer;
  begin
    if IsA('Material') then
      Result := Integer($FFCCCCCC)
    else if IsA('VertexBuffer') then
      Result := -1
    else if IsA('Light') then
      Result := $FFFFFF
    else
      Result := 0;
  end;

begin
  case PropertyID of
    256:
      if IsA('Node') then
        RealValue('alpha', Values[0], 0, 1)
      else
        PI(O, ColorKey, Integer((UInt32(I(O, ColorKey, ColorDefault)) and $FFFFFF) or (UInt32(Channel(Values[0])) shl 24)));
    257, 258, 261, 262, 272:
      begin
        var Key := ColorKey;
        case PropertyID of
          257:
            Key := 'color1024';
          261:
            Key := 'color2048';
          262:
            Key := 'color4096';
          272:
            Key := 'color8192';
        end;
        var Alpha: UInt32 := 0;
        if (Key = 'color2048') or IsA('Background') or IsA('VertexBuffer') then
          Alpha := UInt32(I(O, Key, ColorDefault)) and $FF000000;
        PI(O, Key, Integer(Alpha or (UInt32(Channel(Values[0])) shl 16) or (UInt32(Channel(Values[1])) shl 8) or UInt32(Channel(Values[2]))));
      end;
    259:
      begin
        PI(O, 'cropX', Rounded(Values[0]));
        PI(O, 'cropY', Rounded(Values[1]));
        if Length(Values) = 4 then
          if IsA('Sprite3D') then
          begin
            PI(O, 'cropWidth', Rounded(Values[2], -M3GMaxSpriteCrop, M3GMaxSpriteCrop));
            PI(O, 'cropHeight', Rounded(Values[3], -M3GMaxSpriteCrop, M3GMaxSpriteCrop));
          end
          else
          begin
            PI(O, 'cropWidth', Rounded(Values[2], 0));
            PI(O, 'cropHeight', Rounded(Values[3], 0));
          end;
      end;
    260:
      RealValue('density', Values[0], 0);
    263, 264, 267:
      if IsA('Fog') then
      begin
        if PropertyID = 263 then
          RealValue('far', Values[0])
        else
          RealValue('near', Values[0]);
      end
      else
      begin
        var Mode := I(O, 'projectionType', 48);
        if Mode = 48 then
          Exit;
        var Key := 'projectionParam3';
        if PropertyID = 263 then
          Key := 'projectionParam4'
        else if PropertyID = 264 then
          Key := 'projectionParam1';
        var Smallest: Single;
        var Bits: UInt32 := 1;
        Move(Bits, Smallest, 4);
        if (Mode = 50) and (PropertyID = 264) then
          RealValue(Key, Values[0], Smallest, 179.9999847412109375)
        else if (Mode = 50) or (PropertyID = 264) then
          RealValue(Key, Values[0], Smallest)
        else
          RealValue(Key, Values[0]);
      end;
    265:
      RealValue('Intensity', Values[0]);
    266:
      M3GSetAnimatedMorphWeights(VM, O, Values);
    268:
      begin
        var Q: array[0..3] of Double;
        var Norm: Double := 0;
        var Magnitude: Double := 0;
        for var K := 0 to 3 do
        begin
          Q[K] := Values[K];
          if IsNan(Q[K]) then
            Q[K] := 0;
          Magnitude := Max(Magnitude, Abs(Q[K]));
        end;
        if Magnitude > 0 then
          for var K := 0 to 3 do
            if IsInfinite(Magnitude) then
            begin
              if IsInfinite(Q[K]) then
                Q[K] := Sign(Q[K])
              else
                Q[K] := 0;
            end
            else
              Q[K] := Q[K] / Magnitude;
        for var K := 0 to 3 do
          Norm := Norm + Sqr(Q[K]);
        if Norm > 0 then
          for var K := 0 to 3 do
            Q[K] := Q[K] / Sqrt(Norm);
        var Rotation: TM3GMatrix;
        M3GQuaternion(Q[0], Q[1], Q[2], Q[3], Rotation);
        for var K := 0 to 15 do
          PF(O, 'orientation' + IntToStr(K), Rotation[K]);
      end;
    269:
      PI(O, 'pick', Ord(Values[0] >= 0.5));
    270:
      for var K := 0 to 2 do
      begin
        var J := K;
        if Length(Values) = 1 then
          J := 0;
        RealValue('s' + Copy('xyz', K + 1, 1), Values[J]);
      end;
    271:
      RealValue('shininess', Values[0], 0, 128);
    273:
      RealValue('SpotAngle', Values[0], 0, 90);
    274:
      RealValue('SpotExponent', Values[0], 0, 128);
    275:
      for var K := 0 to 2 do
        RealValue('t' + Copy('xyz', K + 1, 1), Values[K]);
    276:
      PI(O, 'render', Ord(Values[0] >= 0.5));
  end;
end;

function Animate(VM: TJVM; Root, Time: Integer): Integer;
begin
  Result := High(Integer);
  var Pending := TList<Integer>.Create;
  var Seen := TDictionary<Integer, Boolean>.Create;
  try
    Pending.Add(Root);
    while Pending.Count <> 0 do
    begin
      if VM.StopRequested then
        raise EJVMError.Create('M3G animation cancelled');
      var Ref := Pending.Last;
      Pending.Delete(Pending.Count - 1);
      if Seen.ContainsKey(Ref) then
        Continue;
      Seen.Add(Ref, True);
      var O := VM.GetObject(Ref);
      var Refs := M3GObjectReferences(VM, O);
      for var K := High(Refs) downto 0 do
        Pending.Add(Refs[K]);
      var Blends := TDictionary<Integer, TArray<Double>>.Create;
      try
        for var TrackRef in TrackRefs(VM, O) do
        begin
          var Track := VM.GetObject(TrackRef);
          var ControllerRef := R(Track, 'animController');
          if ControllerRef = 0 then
            Continue;
          var Controller := VM.GetObject(ControllerRef);
          var Weight := F(Controller, 'animWeight', 1);
          if not (Weight > 0) then
            Continue;
          var Start := I(Controller, 'animStart');
          var Finish := I(Controller, 'animEnd');
          if Start <> Finish then
          begin
            if Time < Start then
            begin
              Result := Min(Int64(Result), Int64(Start) - Time);
              Continue;
            end;
            if Time >= Finish then
              Continue;
            Result := Min(Int64(Result), Int64(Finish) - Time);
          end;
          // A frozen controller contributes a constant value. Variable tracks
          // use a conservative zero validity; inactive/frozen graphs can sleep.
          if F(Controller, 'animSpeed', 1) <> 0 then
            Result := 0;
          var Values := M3GSampleSequence(VM, R(Track, 'animSequence'), Position(Controller, Time));
          var PropertyID := I(Track, 'animProperty');
          var Sum: TArray<Double>;
          if not Blends.TryGetValue(PropertyID, Sum) then
          begin
            Sum := nil;
            SetLength(Sum, Length(Values));
          end;
          for var K := 0 to High(Values) do
            Sum[K] := Sum[K] + Weight * Values[K];
          Blends.AddOrSetValue(PropertyID, Sum);
        end;
        for var Pair in Blends do
          Apply(VM, O, Pair.Key, Pair.Value);
      finally
        Blends.Free;
      end;
    end;
  finally
    Seen.Free;
    Pending.Free;
  end;
end;

function InvokeM3GAnimationObject(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if N = 'animate' then
    Exit(TJVMValue.Int(Animate(VM, Args[0].AsRef, Args[1].AsInt)));
  var Tracks := TrackRefs(VM, O);
  if N = 'getAnimationTrackCount' then
    Exit(TJVMValue.Int(Length(Tracks)));
  if N = 'getAnimationTrack' then
  begin
    var Index := Args[1].AsInt;
    if (Index < 0) or (Index >= Length(Tracks)) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G animation track index');
    Exit(TJVMValue.Ref(Tracks[Index]));
  end;
  var Ref := Args[1].AsRef;
  var Index := -1;
  for var K := 0 to High(Tracks) do
    if Tracks[K] = Ref then
      Index := K;
  if N = 'addAnimationTrack' then
  begin
    var Track := VM.GetObject(Ref);
    var PropertyID := I(Track, 'animProperty');
    if (Index >= 0) or not CompatibleTarget(VM, O, PropertyID) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G incompatible/duplicate animation track');
    for var Existing in Tracks do
    begin
      var Other := VM.GetObject(Existing);
      if (I(Other, 'animProperty') = PropertyID) and
        (I(VM.GetObject(R(Other, 'animSequence')), 'keyComponents') <> I(VM.GetObject(R(Track, 'animSequence')), 'keyComponents')) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G animation track component mismatch');
    end;
    Tracks := Tracks + [Ref];
  end
  else if N = 'removeAnimationTrack' then
  begin
    if Index < 0 then
      Exit;
    for var K := Index to High(Tracks) - 1 do
      Tracks[K] := Tracks[K + 1];
    SetLength(Tracks, Length(Tracks) - 1);
  end
  else
    raise EJVMUnsupported.Create('M3G Object3D.' + N);
  // Copy-on-write internal arrays let duplicate objects share tracks while
  // retaining independent lists of bindings, including duplicated Nodes.
  var DataRef := VM.NewArray('[Ljavax/microedition/m3g/AnimationTrack;', Length(Tracks));
  O.Fields.AddOrSetValue(P + 'animTracks', TJVMValue.Ref(DataRef));
  var Data := VM.GetObject(DataRef);
  for var K := 0 to High(Tracks) do
    Data.Elements[K] := TJVMValue.Ref(Tracks[K]);
end;

end.

