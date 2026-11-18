unit AVM1.Filters;

interface

uses
  AVM1.Runtime, SWF.Reader;

procedure RegisterAVMFilters(VM: TAVM1);

function AVMFilterCall(VM: TAVM1; const Name: string; Instance: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;

function ReadAVMFilter(Instance: TAVMObject; out Filter: TSWFFilter): Boolean;

function ReadAVMFilters(VM: TAVM1; const Value: TAVMValue): TSWFFilters;

function WriteAVMFilters(VM: TAVM1; const Filters: TSWFFilters): TAVMValue;

implementation

uses
  System.SysUtils, System.Math, AVM1.Coercion, AVM1.Numeric, AVM1.BitmapData,
  AVM1.Transforms;

type
  TFilterProperty = (fpDistance, fpAngle, fpColor, fpAlpha, fpBlurX, fpBlurY, fpStrength,
    fpQuality, fpInner, fpKnockout, fpHideObject, fpHighlightColor, fpHighlightAlpha,
    fpShadowColor, fpShadowAlpha, fpType, fpMatrix, fpMatrixX, fpMatrixY, fpDivisor,
    fpBias, fpPreserveAlpha, fpClamp, fpColors, fpAlphas, fpRatios, fpMapBitmap, fpMapPoint,
    fpComponentX, fpComponentY, fpScaleX, fpScaleY, fpMode);

  TFilterProperties = TArray<TFilterProperty>;

  TAVMFilterData = class
    Value: TSWFFilter;
  end;

const
  FilterNames: array[TSWFFilterKind] of string = ('DropShadowFilter', 'BlurFilter',
    'GlowFilter', 'BevelFilter', 'GradientGlowFilter', 'ConvolutionFilter', 'ColorMatrixFilter',
    'GradientBevelFilter', 'DisplacementMapFilter');
  PropertyNames: array[TFilterProperty] of string = ('distance', 'angle', 'color', 'alpha',
    'blurX', 'blurY', 'strength', 'quality', 'inner', 'knockout', 'hideObject',
    'highlightColor', 'highlightAlpha', 'shadowColor', 'shadowAlpha', 'type', 'matrix',
    'matrixX', 'matrixY', 'divisor', 'bias', 'preserveAlpha', 'clamp', 'colors', 'alphas', 'ratios',
    'mapBitmap', 'mapPoint', 'componentX', 'componentY', 'scaleX', 'scaleY', 'mode');
  MaxGradientStops = 16;
  DisplacementModes: array[TSWFDisplacementMode] of string = ('wrap', 'clamp', 'ignore', 'color');

function PublishedProperties(Kind: TSWFFilterKind): TFilterProperties;
begin
  case Kind of
    sfBlur:
      Result := [fpBlurX, fpBlurY, fpQuality];
    sfGlow:
      Result := [fpColor, fpAlpha, fpQuality, fpInner, fpKnockout, fpBlurX, fpBlurY, fpStrength];
    sfDropShadow:
      Result := [fpDistance, fpAngle, fpColor, fpAlpha, fpQuality, fpInner, fpKnockout,
          fpBlurX, fpBlurY, fpStrength, fpHideObject];
    sfBevel:
      Result := [fpDistance, fpAngle, fpHighlightColor, fpHighlightAlpha, fpShadowColor,
          fpShadowAlpha, fpQuality, fpStrength, fpKnockout, fpBlurX, fpBlurY, fpType];
    sfColorMatrix:
      Result := [fpMatrix];
    sfConvolution:
      Result := [fpMatrixX, fpMatrixY, fpMatrix, fpDivisor, fpBias,
          fpPreserveAlpha, fpClamp, fpColor, fpAlpha];
    sfGradientGlow, sfGradientBevel:
      Result := [fpDistance, fpAngle, fpColors, fpAlphas,
          fpRatios, fpBlurX, fpBlurY, fpQuality, fpStrength, fpKnockout, fpType];
    sfDisplacementMap:
      Result := [fpMapBitmap, fpMapPoint, fpComponentX, fpComponentY,
          fpScaleX, fpScaleY, fpMode, fpColor, fpAlpha];
  else
    Result := nil;
  end;
end;

function ConstructorProperties(Kind: TSWFFilterKind): TFilterProperties;
begin
  case Kind of
    sfGlow:
      Result := [fpColor, fpAlpha, fpBlurX, fpBlurY, fpStrength, fpQuality, fpInner, fpKnockout];
    sfDropShadow:
      Result := [fpDistance, fpAngle, fpColor, fpAlpha, fpBlurX, fpBlurY,
          fpStrength, fpQuality, fpInner, fpKnockout, fpHideObject];
    sfBevel:
      Result := [fpDistance, fpAngle, fpHighlightColor, fpHighlightAlpha,
          fpShadowColor, fpShadowAlpha, fpBlurX, fpBlurY, fpStrength, fpQuality, fpType, fpKnockout];
    sfGradientGlow, sfGradientBevel:
      Result := [fpDistance, fpAngle, fpColors, fpAlphas,
          fpRatios, fpBlurX, fpBlurY, fpStrength, fpQuality, fpType, fpKnockout];
  else
    Result := PublishedProperties(Kind);
  end;
end;

function FilterPackage(VM: TAVM1): TAVMObject;
begin
  Result := VM.GetData(VM.GetData(VM.Global, 'flash').Obj, 'filters').Obj;
end;

procedure RegisterAVMFilters(VM: TAVM1);
var
  FlashPackage, PackageObject, Base, PrototypeObject: TAVMObject;
  Kind: TSWFFilterKind;
  Prop: TFilterProperty;
  NativeName, Field: string;

  function RegisterClass(const ClassName: string; Parent: TAVMObject): TAVMObject;
  var
    ConstructorValue: TAVMValue;
  begin
    ConstructorValue := VM.NativeFunction('Filter.' + ClassName);
    Result := VM.NewObject;
    if Parent <> nil then
      VM.PutData(Result, '__proto__', TAVMValue.Ref(Parent));
    VM.PutData(Result, 'constructor', ConstructorValue);
    Result.Attributes.AddOrSetValue('constructor', 1);
    VM.PutData(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(Result));
    VM.PutData(PackageObject, ClassName, ConstructorValue);
  end;

begin
  FlashPackage := VM.GetData(VM.Global, 'flash').Obj;
  PackageObject := VM.NewObject;
  VM.PutData(FlashPackage, 'filters', TAVMValue.Ref(PackageObject));
  FlashPackage.Attributes.AddOrSetValue('filters', $1000);
  Base := RegisterClass('BitmapFilter', nil);
  VM.PutData(Base, 'clone', VM.NativeFunction('Filter.clone'));
  for Kind := Low(TSWFFilterKind) to High(TSWFFilterKind) do
  begin
    if FilterNames[Kind] = '' then
      Continue;
    PrototypeObject := RegisterClass(FilterNames[Kind], Base);
    for Prop in PublishedProperties(Kind) do
    begin
      Field := PropertyNames[Prop];
      NativeName := 'Filter.' + FilterNames[Kind] + '.' + IntToStr(Ord(Prop));
      VM.AddProperty(PrototypeObject, Field, VM.NativeFunction(NativeName + '.get').Obj,
        VM.NativeFunction(NativeName + '.set').Obj);
      PrototypeObject.Attributes.AddOrSetValue(Field, $1000);
    end;
  end;
end;

function DefaultFilter(Kind: TSWFFilterKind): TSWFFilter;
var
  I: Integer;
begin
  Result := Default(TSWFFilter);
  Result.Kind := Kind;
  Result.BlurX := 4;
  Result.BlurY := 4;
  Result.Strength := 1;
  Result.Passes := 1;
  Result.Color := $FF000000;
  Result.HighlightColor := $FFFFFFFF;
  Result.CompositeSource := True;
  case Kind of
    sfGlow:
      begin
        Result.BlurX := 6;
        Result.BlurY := 6;
        Result.Color := $FFFF0000;
        Result.Strength := 2;
      end;
    sfDropShadow, sfBevel, sfGradientGlow, sfGradientBevel:
      begin
        Result.Distance := 4;
        Result.Angle := 0.785398163;
        Result.Inner := Kind <> sfDropShadow;
      end;
    sfColorMatrix:
      for I := 0 to 3 do
        Result.Matrix[I * 6] := 1;
    sfDisplacementMap:
      Result.Color := 0;
    sfConvolution:
      begin
        Result.Color := 0;
        Result.Divisor := 1;
        Result.PreserveAlpha := True;
        Result.ClampEdges := True;
      end;
  end;
end;

function FilterData(Instance: TAVMObject): TAVMFilterData;
begin
  Result := nil;
  if (Instance <> nil) and (Instance.OwnedNativeData is TAVMFilterData) then
    Result := TAVMFilterData(Instance.OwnedNativeData);
end;

procedure StoreFilter(Instance: TAVMObject; const Filter: TSWFFilter);
var
  Data: TAVMFilterData;
begin
  Data := TAVMFilterData.Create;
  Data.Value := Filter;
  Instance.OwnedNativeData.Free;
  Instance.OwnedNativeData := Data;
end;

function FilterValue(VM: TAVM1; const Filter: TSWFFilter; const Prototype: TAVMValue): TAVMValue;
var
  O: TAVMObject;
begin
  O := VM.NewObject;
  VM.PutData(O, '__proto__', Prototype);
  StoreFilter(O, Filter);
  Result := TAVMValue.Ref(O);
end;

function ClampNumber(Value, Lower, Upper: Double): Double;
begin
  if IsNan(Value) then
    Exit(0);
  if Value < Lower then
    Exit(Lower);
  if Value > Upper then
    Exit(Upper);
  Result := Value;
end;

procedure GrowConvolutionMatrix(var Filter: TSWFFilter);
var
  Count: Integer;
begin
  Count := Integer(Filter.MatrixX) * Filter.MatrixY;
  if Count > Length(Filter.Kernel) then
    SetLength(Filter.Kernel, Count);
end;

procedure SetGradientProperty(VM: TAVM1; var Filter: TSWFFilter; Prop: TFilterProperty; const Value: TAVMValue);
var
  Count, I, Alpha: Integer;
  Numeric: Double;
  RGB: Cardinal;
  Stops: TArray<TSWFGradientStop>;
begin
  Count := 0;
  if Value.Obj <> nil then
    Count := Max(0, AVMToInt32(VM.CoerceNumber(VM.Get(Value.Obj, 'length'))))
  else
  begin
    if Prop <> fpColors then
      Exit;
    if Value.Kind = avString then
      Count := Length(Value.Text);
  end;
  // Preserve slots hidden by a shorter colors or ratios array. Copies share
  // read-only arrays until a script writes a property.
  Stops := Copy(Filter.GradientStops);
  case Prop of
    fpColors:
      begin
        Filter.GradientCount := Min(Count, MaxGradientStops);
        if Length(Stops) < Filter.GradientCount then
          SetLength(Stops, Filter.GradientCount);
        for I := 0 to Filter.GradientCount - 1 do
        begin
          RGB := Cardinal(AVMToInt32(VM.CoerceNumber(VM.Get(Value.Obj, IntToStr(I))))) and $FFFFFF;
          Stops[I].Color := (Stops[I].Color and $FF000000) or RGB;
        end;
      end;
    fpAlphas:
      for I := 0 to Filter.GradientCount - 1 do
      begin
        Alpha := 255;
        if I < Count then
        begin
          Numeric := VM.CoerceNumber(VM.Get(Value.Obj, IntToStr(I)));
          if not (IsNan(Numeric) or IsInfinite(Numeric)) then
            Alpha := Trunc(ClampNumber(Numeric, 0, 1) * 255 + 0.5);
        end;
        Stops[I].Color := (Stops[I].Color and $FFFFFF) or (Cardinal(Alpha) shl 24);
      end;
    fpRatios:
      begin
        Filter.GradientCount := Min(Count, Filter.GradientCount);
        for I := 0 to Filter.GradientCount - 1 do
          Stops[I].Ratio := EnsureRange(AVMToInt32(VM.CoerceNumber(VM.Get(Value.Obj, IntToStr(I)))), 0, 255);
      end;
  end;
  Filter.GradientStops := Stops;
end;

procedure SetDisplacementPoint(VM: TAVM1; var Filter: TSWFFilter; Point: TAVMObject);
var
  X, Y: Integer;
  HasX, HasY, Thrown: Boolean;
  ErrorValue: TAVMValue;
  ErrorMessage: string;

  function ReadCoordinate(const Name: string; out Coordinate: Integer): Boolean;
  var
    Value: TAVMValue;
    Number: Double;
  begin
    Result := VM.TryGetOwnStored(Point, Name, Value);
    if not Result then
      Exit;
    Coordinate := Low(Integer);
    try
      Number := VM.CoerceNumber(Value);
      if not IsNan(Number) and (Number >= Low(Integer)) and (Number <= High(Integer)) then
        Coordinate := Trunc(Number);
    except
      on E: EAVMThrown do
        if not Thrown then
        begin
          Thrown := True;
          ErrorValue := E.Value;
          ErrorMessage := E.Message;
        end;
    end;
  end;

begin
  Thrown := False;
  HasX := ReadCoordinate('x', X);
  HasY := ReadCoordinate('y', Y);
  Filter.MapX := 0;
  Filter.MapY := 0;
  if HasX and HasY then
  begin
    Filter.MapX := X;
    Filter.MapY := Y;
  end;
  if Thrown then
    raise EAVMThrown.CreateValue(ErrorValue, ErrorMessage);
end;

procedure SetFilterProperty(VM: TAVM1; var Filter: TSWFFilter; Prop: TFilterProperty; const Value: TAVMValue);
var
  I, Count: Integer;
  Numeric: Double;
  Text: string;
  Mode: TSWFDisplacementMode;

  function WithAlpha(Color: Cardinal): Cardinal;
  begin
    Result := (Color and $FFFFFF) or (Cardinal(Trunc(ClampNumber(VM.CoerceNumber(Value), 0, 1) * 255)) shl 24);
  end;

  function WithRGB(Color: Cardinal): Cardinal;
  begin
    Result := (Color and $FF000000) or (Cardinal(AVMToInt32(VM.CoerceNumber(Value))) and $FFFFFF);
  end;

  function BlurValue: Double;
  begin
    Result := VM.CoerceNumber(Value);
    if (Filter.Kind in [sfGradientGlow, sfGradientBevel]) or not IsNan(Result) then
      Result := ClampNumber(Result, 0, 255);
  end;

begin
  case Prop of
    fpDistance:
      Filter.Distance := VM.CoerceNumber(Value);
    fpAngle:
      Filter.Angle := AVMBinaryNumber($3F, VM.CoerceNumber(Value), 360) * Pi / 180;
    fpColor, fpShadowColor:
      Filter.Color := WithRGB(Filter.Color);
    fpAlpha, fpShadowAlpha:
      Filter.Color := WithAlpha(Filter.Color);
    fpHighlightColor:
      Filter.HighlightColor := WithRGB(Filter.HighlightColor);
    fpHighlightAlpha:
      Filter.HighlightColor := WithAlpha(Filter.HighlightColor);
    fpBlurX:
      Filter.BlurX := BlurValue;
    fpBlurY:
      Filter.BlurY := BlurValue;
    fpStrength:
      Filter.Strength := Trunc(ClampNumber(VM.CoerceNumber(Value), 0, 255) * 256) / 256.0;
    fpQuality:
      Filter.Passes := EnsureRange(AVMToInt32(VM.CoerceNumber(Value)), 0, 15);
    fpInner:
      Filter.Inner := Value.AsBoolean(VM.SWFVersion);
    fpKnockout:
      Filter.Knockout := Value.AsBoolean(VM.SWFVersion);
    fpHideObject:
      Filter.CompositeSource := not Value.AsBoolean(VM.SWFVersion);
    fpType:
      begin
        Text := VM.CoerceString(Value);
        Filter.Inner := Text = 'inner';
        Filter.OnTop := not Filter.Inner and (Text <> 'outer');
      end;
    fpMatrixX, fpMatrixY:
      begin
        Count := EnsureRange(AVMToInt32(VM.CoerceNumber(Value)), 0, 15);
        if Prop = fpMatrixX then
          Filter.MatrixX := Count
        else
          Filter.MatrixY := Count;
        GrowConvolutionMatrix(Filter);
      end;
    fpDivisor:
      Filter.Divisor := SWFFloat32(VM.CoerceNumber(Value));
    fpBias:
      Filter.Bias := SWFFloat32(VM.CoerceNumber(Value));
    fpPreserveAlpha:
      Filter.PreserveAlpha := Value.AsBoolean(VM.SWFVersion);
    fpClamp:
      Filter.ClampEdges := Value.AsBoolean(VM.SWFVersion);
    fpColors, fpAlphas, fpRatios:
      SetGradientProperty(VM, Filter, Prop, Value);
    fpMapBitmap:
      if (Value.Obj <> nil) and (Value.Obj.BitmapData <> nil) then
        Filter.MapBitmap := Value.Obj.BitmapData;
    fpMapPoint:
      SetDisplacementPoint(VM, Filter, Value.Obj);
    fpComponentX:
      Filter.ComponentX := AVMToInt32(VM.CoerceNumber(Value));
    fpComponentY:
      Filter.ComponentY := AVMToInt32(VM.CoerceNumber(Value));
    fpScaleX, fpScaleY:
      begin
        Numeric := VM.CoerceNumber(Value);
        if IsNan(Numeric) then
          Numeric := -65535;
        Numeric := EnsureRange(Numeric, -65535.0, 65535.0);
        if Prop = fpScaleX then
          Filter.MapScaleX := Numeric
        else
          Filter.MapScaleY := Numeric;
      end;
    fpMode:
      begin
        Text := VM.CoerceString(Value);
        Filter.MapMode := dmWrap;
        for Mode := Low(TSWFDisplacementMode) to High(TSWFDisplacementMode) do
          if Text = DisplacementModes[Mode] then
          begin
            Filter.MapMode := Mode;
            Break;
          end;
      end;
    fpMatrix:
      begin
        if Filter.Kind = sfConvolution then
        begin
          Count := 0;
          if Value.Obj <> nil then
            Count := AVMToInt32(VM.CoerceNumber(VM.Get(Value.Obj, 'length')))
          else if Value.Kind = avString then
            Count := Length(Value.Text);
          Count := Max(0, Count);
          VM.ChargeWork(Count);
          Filter.Kernel := nil;
          SetLength(Filter.Kernel, Count);
          for I := 0 to Count - 1 do
            Filter.Kernel[I] := SWFFloat32(VM.CoerceNumber(VM.Get(Value.Obj, IntToStr(I))));
          GrowConvolutionMatrix(Filter);
          Exit;
        end;
        if Value.Kind in [avNull, avUndefined] then
          Exit;
        Count := 0;
        if Value.Obj <> nil then
          Count := AVMToInt32(VM.CoerceNumber(VM.Get(Value.Obj, 'length')));
        for I := 0 to High(Filter.Matrix) do
        begin
          Numeric := NaN;
          if I < Count then
            Numeric := VM.CoerceNumber(VM.Get(Value.Obj, IntToStr(I)));
          Filter.Matrix[I] := SWFFloat32(Numeric);
        end;
      end;
  end;
end;

function GetFilterProperty(VM: TAVM1; const Filter: TSWFFilter; Prop: TFilterProperty): TAVMValue;
var
  Values: TArray<TAVMValue>;
  I: Integer;
begin
  case Prop of
    fpDistance:
      Result := TAVMValue.Num(Filter.Distance);
    fpAngle:
      Result := TAVMValue.Num(Filter.Angle * 180 / Pi);
    fpColor, fpShadowColor:
      Result := TAVMValue.Num(Filter.Color and $FFFFFF);
    fpAlpha, fpShadowAlpha:
      Result := TAVMValue.Num((Filter.Color shr 24) / 255.0);
    fpHighlightColor:
      Result := TAVMValue.Num(Filter.HighlightColor and $FFFFFF);
    fpHighlightAlpha:
      Result := TAVMValue.Num((Filter.HighlightColor shr 24) / 255.0);
    fpBlurX:
      Result := TAVMValue.Num(Filter.BlurX);
    fpBlurY:
      Result := TAVMValue.Num(Filter.BlurY);
    fpStrength:
      Result := TAVMValue.Num(Filter.Strength);
    fpQuality:
      Result := TAVMValue.Num(Filter.Passes);
    fpInner:
      Result := TAVMValue.Bool(Filter.Inner);
    fpKnockout:
      Result := TAVMValue.Bool(Filter.Knockout);
    fpHideObject:
      Result := TAVMValue.Bool(not Filter.CompositeSource);
    fpType:
      begin
        if Filter.OnTop then
          Result := TAVMValue.Str('full')
        else if Filter.Inner then
          Result := TAVMValue.Str('inner')
        else
          Result := TAVMValue.Str('outer');
      end;
    fpMatrixX:
      Result := TAVMValue.Num(Filter.MatrixX);
    fpMatrixY:
      Result := TAVMValue.Num(Filter.MatrixY);
    fpDivisor:
      Result := TAVMValue.Num(Filter.Divisor);
    fpBias:
      Result := TAVMValue.Num(Filter.Bias);
    fpPreserveAlpha:
      Result := TAVMValue.Bool(Filter.PreserveAlpha);
    fpClamp:
      Result := TAVMValue.Bool(Filter.ClampEdges);
    fpMapBitmap:
      Result := AVMBitmapReference(VM, Filter.MapBitmap);
    fpMapPoint:
      Result := AVMNewGeometry(VM, 'Point', [TAVMValue.Num(Filter.MapX), TAVMValue.Num(Filter.MapY)]);
    fpComponentX:
      Result := TAVMValue.Num(Filter.ComponentX);
    fpComponentY:
      Result := TAVMValue.Num(Filter.ComponentY);
    fpScaleX:
      Result := TAVMValue.Num(Filter.MapScaleX);
    fpScaleY:
      Result := TAVMValue.Num(Filter.MapScaleY);
    fpMode:
      Result := TAVMValue.Str(DisplacementModes[Filter.MapMode]);
    fpColors, fpAlphas, fpRatios:
      begin
        SetLength(Values, Filter.GradientCount);
        for I := 0 to High(Values) do
          case Prop of
            fpColors:
              Values[I] := TAVMValue.Num(Filter.GradientStops[I].Color and $FFFFFF);
            fpAlphas:
              Values[I] := TAVMValue.Num((Filter.GradientStops[I].Color shr 24) / 255.0);
            fpRatios:
              Values[I] := TAVMValue.Num(Filter.GradientStops[I].Ratio);
          end;
        Result := TAVMValue.Ref(VM.CreateArray(Values));
      end;
    fpMatrix:
      begin
        if Filter.Kind = sfConvolution then
        begin
          VM.ChargeWork(Length(Filter.Kernel));
          SetLength(Values, Length(Filter.Kernel));
          for I := 0 to High(Values) do
            Values[I] := TAVMValue.Num(Filter.Kernel[I]);
        end
        else
        begin
          SetLength(Values, Length(Filter.Matrix));
          for I := 0 to High(Values) do
            Values[I] := TAVMValue.Num(Filter.Matrix[I]);
        end;
        Result := TAVMValue.Ref(VM.CreateArray(Values));
      end;
  end;
end;

function ReadAVMFilter(Instance: TAVMObject; out Filter: TSWFFilter): Boolean;
var
  Data: TAVMFilterData;

  function Fixed16(Value: Double): Double;
  begin
    Result := Trunc(ClampNumber(Value, -32768, 32767.9999847412109375) * 65536) / 65536.0;
  end;

begin
  Data := FilterData(Instance);
  Result := Data <> nil;
  if not Result then
    Exit;
  Filter := Data.Value;
  if Filter.Kind = sfDisplacementMap then
  begin
    Filter.ComponentX := Filter.ComponentX and $FF;
    Filter.ComponentY := Filter.ComponentY and $FF;
    Exit;
  end;
  Filter.BlurX := Fixed16(Filter.BlurX);
  Filter.BlurY := Fixed16(Filter.BlurY);
  Filter.Angle := Fixed16(Filter.Angle);
  Filter.Distance := Fixed16(Filter.Distance);
  if Filter.Kind = sfGlow then
    Filter.CompositeSource := True;
  if Filter.Kind in [sfGradientGlow, sfGradientBevel] then
  begin
    Filter.CompositeSource := True;
    Filter.Strength := Min(Filter.Strength, 32767 / 256.0);
    SetLength(Filter.GradientStops, Filter.GradientCount);
  end;
end;

function ReadAVMFilters(VM: TAVM1; const Value: TAVMValue): TSWFFilters;
var
  Keys: TArray<string>;
  I, N: Integer;
  Current: TAVMValue;
  Filter: TSWFFilter;
begin
  Result := nil;
  if Value.Obj = nil then
    Exit;
  Keys := VM.Enumerate(Value.Obj);
  SetLength(Result, Length(Keys));
  N := 0;
  for I := High(Keys) downto 0 do
  begin
    if not VM.HasOwnProperty(Value.Obj, Keys[I]) then
      Continue;
    Current := VM.Get(Value.Obj, Keys[I]);
    if not ReadAVMFilter(Current.Obj, Filter) then
      Continue;
    Result[N] := Filter;
    Inc(N);
  end;
  SetLength(Result, N);
end;

function WriteAVMFilters(VM: TAVM1; const Filters: TSWFFilters): TAVMValue;
var
  Values: TArray<TAVMValue>;
  Filter, ClipFilter: TSWFFilter;
  ConstructorValue, Prototype: TAVMValue;
  PackageObject: TAVMObject;
  N: Integer;
begin
  PackageObject := FilterPackage(VM);
  SetLength(Values, Length(Filters));
  N := 0;
  for Filter in Filters do
  begin
    if FilterNames[Filter.Kind] = '' then
      Continue;
    ConstructorValue := VM.GetData(PackageObject, FilterNames[Filter.Kind]);
    Prototype := VM.GetData(ConstructorValue.Obj, 'prototype');
    ClipFilter := Filter;
    if ClipFilter.Kind in [sfGradientGlow, sfGradientBevel] then
    begin
      ClipFilter.GradientCount := Min(MaxGradientStops, ClipFilter.GradientCount);
      ClipFilter.GradientStops := Copy(ClipFilter.GradientStops, 0, ClipFilter.GradientCount);
      ClipFilter.Strength := Max(0, ClipFilter.Strength);
    end;
    Values[N] := FilterValue(VM, ClipFilter, Prototype);
    Inc(N);
  end;
  SetLength(Values, N);
  Result := TAVMValue.Ref(VM.CreateArray(Values));
end;

function AVMFilterCall(VM: TAVM1; const Name: string; Instance: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  Parts: TArray<string>;
  Data: TAVMFilterData;
  Kind: TSWFFilterKind;
  Filter: TSWFFilter;
  Prop: TFilterProperty;
  I, Code: Integer;
  Order: TFilterProperties;
begin
  Result := Default(TAVMValue);
  if Instance = nil then
    Exit;
  Data := FilterData(Instance);
  if Name = 'Filter.clone' then
  begin
    if Data <> nil then
      Result := FilterValue(VM, Data.Value, VM.GetOwnStored(Instance, '__proto__'));
    Exit;
  end;
  if Name = 'Filter.BitmapFilter' then
    Exit(TAVMValue.Ref(Instance));
  Parts := Name.Split(['.']);
  if Length(Parts) = 2 then
  begin
    for Kind := Low(TSWFFilterKind) to High(TSWFFilterKind) do
      if Parts[1] = FilterNames[Kind] then
      begin
        Filter := DefaultFilter(Kind);
        Order := ConstructorProperties(Kind);
        for I := 0 to Min(High(Args), High(Order)) do
        begin
          SetFilterProperty(VM, Filter, Order[I], Args[I]);
          if (Kind = sfConvolution) and (Order[I] = fpColor) then
            Filter.Color := Filter.Color or $FF000000;
        end;
        if (Kind = sfConvolution) and (Length(Args) in [1..3]) then
        begin
          Filter.Divisor := 0;
          for I := 0 to High(Filter.Kernel) do
            Filter.Divisor := SWFFloat32(AVMBinaryNumber($0A, Filter.Divisor, Filter.Kernel[I]));
        end;
        StoreFilter(Instance, Filter);
        Exit(TAVMValue.Ref(Instance));
      end;
    Exit;
  end;
  if (Length(Parts) <> 4) or (Data = nil) or (Parts[1] <> FilterNames[Data.Value.Kind]) or
    not TryStrToInt(Parts[2], Code) then
    Exit;
  Prop := TFilterProperty(Code);
  if Parts[3] = 'get' then
    Exit(GetFilterProperty(VM, Data.Value, Prop));
  if Length(Args) > 0 then
  begin
    // Coercion can run ActionScript and replace the receiver's native data.
    Filter := Data.Value;
    try
      SetFilterProperty(VM, Filter, Prop, Args[0]);
    except
      on E: EAVMThrown do
      begin
        if (Prop = fpMapPoint) and (FilterData(Instance) = Data) then
        begin
          Data.Value.MapX := Filter.MapX;
          Data.Value.MapY := Filter.MapY;
        end;
        raise;
      end;
    end;
    if FilterData(Instance) = Data then
      Data.Value := Filter;
  end;
end;

end.

