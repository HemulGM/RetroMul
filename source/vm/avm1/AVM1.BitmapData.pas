unit AVM1.BitmapData;

interface

uses
  AVM1.Runtime, Media.Image.PixelBuffer;

procedure RegisterAVMBitmapData(VM: TAVM1; out PrototypeObject: TAVMObject);

function AVMBitmapReference(VM: TAVM1; const Buffer: IImagePixelBuffer): TAVMValue;

function AVMBitmapDataCall(VM: TAVM1; const Name: string; Instance: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;

implementation

uses
  System.Math, AVM1.Coercion, AVM1.BitmapOps, AVM1.Transforms, AVM1.Filters,
  SWF.Reader;

procedure RegisterAVMBitmapData(VM: TAVM1; out PrototypeObject: TAVMObject);
const
  ChannelNames: array[0..3] of string = ('RED_CHANNEL', 'GREEN_CHANNEL',
    'BLUE_CHANNEL', 'ALPHA_CHANNEL');
var
  FlashPackage, DisplayPackage: TAVMObject;
  ConstructorValue: TAVMValue;
  Name: string;
  Index: Integer;
begin
  FlashPackage := VM.GetData(VM.Global, 'flash').Obj;
  DisplayPackage := VM.NewObject;
  VM.Put(FlashPackage, 'display', TAVMValue.Ref(DisplayPackage));
  FlashPackage.Attributes.AddOrSetValue('display', $1000);

  ConstructorValue := VM.NativeFunction('BitmapData');
  PrototypeObject := VM.NewObject;
  VM.Put(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(PrototypeObject));
  VM.Put(PrototypeObject, 'constructor', ConstructorValue);
  PrototypeObject.Attributes.AddOrSetValue('constructor', 1);
  VM.Put(DisplayPackage, 'BitmapData', ConstructorValue);

  for Name in ['width', 'height', 'rectangle', 'transparent'] do
    VM.AddProperty(PrototypeObject, Name, VM.NativeFunction('BitmapData.' + Name).Obj, nil);
  for Name in ['getPixel', 'setPixel', 'fillRect', 'copyPixels', 'scroll', 'getPixel32', 'setPixel32', 'colorTransform', 'copyChannel', 'clone', 'dispose', 'draw', 'applyFilter', 'generateFilterRect'] do
    VM.Put(PrototypeObject, Name, VM.NativeFunction('BitmapData.' + Name));
  for Index := Low(ChannelNames) to High(ChannelNames) do
    VM.Put(ConstructorValue.Obj, ChannelNames[Index], TAVMValue.Num(1 shl Index));
  VM.Put(ConstructorValue.Obj, 'loadBitmap', VM.NativeFunction('BitmapData.loadBitmap'));
end;

function BitmapInteger(VM: TAVM1; const Value: TAVMValue): Integer;
begin
  Result := AVMToInt32(VM.CoerceNumber(Value));
end;

function ValidBitmapSize(Version: Byte; Width, Height: Integer): Boolean;
begin
  if (Width < 1) or (Height < 1) then
    Exit(False);
  if Version <= 9 then
    Exit((Width <= 2880) and (Height <= 2880));
  if Version <= 12 then
    Exit((Width < $2000) and (Height < $2000) and (Int64(Width) * Height < $1000000));
  Result := (Width <= $6666666) and (Height <= $6666666) and
    (Int64(Width) * Height < $20000000);
end;

function ConstructBitmapData(VM: TAVM1; Instance: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  Width, Height: Integer;
  Transparent: Boolean;
  Color: Cardinal;
  Buffer: IImagePixelBuffer;
begin
  Result := Default(TAVMValue);
  if (Instance = nil) or (Length(Args) < 2) then
    Exit;
  Width := BitmapInteger(VM, Args[0]);
  Height := BitmapInteger(VM, Args[1]);
  Transparent := (Length(Args) < 3) or Args[2].AsBoolean(VM.SWFVersion);
  Color := $FFFFFFFF;
  if Length(Args) >= 4 then
    Color := Cardinal(BitmapInteger(VM, Args[3]));
  if not ValidBitmapSize(VM.SWFVersion, Width, Height) then
    Exit;
  Buffer := VM.CreatePixelBuffer(Width, Height, Transparent, Color);
  if Buffer <> nil then
  begin
    Instance.BitmapData := Buffer;
    Result := TAVMValue.Ref(Instance);
  end;
end;

function NewBitmapObject(VM: TAVM1; const Buffer: IImagePixelBuffer; Instance: TAVMObject; const PrototypeKey: string): TAVMValue;
var
  NewInstance: TAVMObject;
begin
  NewInstance := VM.NewObject('BitmapData');
  if VM.HasOwnProperty(Instance, PrototypeKey) then
    VM.PutData(NewInstance, '__proto__', VM.GetData(Instance, PrototypeKey))
  else
    NewInstance.RemoveData('__proto__');
  NewInstance.BitmapData := Buffer;
  Result := TAVMValue.Ref(NewInstance);
end;

function AVMBitmapReference(VM: TAVM1; const Buffer: IImagePixelBuffer): TAVMValue;
var
  Display, BitmapClass: TAVMObject;
begin
  Result := Default(TAVMValue);
  if Buffer = nil then
    Exit;
  Display := VM.GetData(VM.GetData(VM.Global, 'flash').Obj, 'display').Obj;
  BitmapClass := VM.GetData(Display, 'BitmapData').Obj;
  Result := NewBitmapObject(VM, Buffer, BitmapClass, 'prototype');
end;

function CloneBitmapData(VM: TAVM1; Instance: TAVMObject; const Buffer: IImagePixelBuffer): TAVMValue;
var
  CopyBuffer: IImagePixelBuffer;
  X, Y: Integer;
begin
  VM.ChargeWork(1 + (Buffer.Width * Buffer.Height - 1) div 32);
  CopyBuffer := VM.CreatePixelBuffer(Buffer.Width, Buffer.Height, Buffer.Transparent, 0);
  if CopyBuffer = nil then
    Exit(TAVMValue.Num(-1));
  for Y := 0 to Buffer.Height - 1 do
    for X := 0 to Buffer.Width - 1 do
      CopyBuffer.SetPixelPremultiplied(X, Y, Buffer.PixelPremultiplied(X, Y));
  Result := NewBitmapObject(VM, CopyBuffer, Instance, '__proto__');
end;

function BitmapRectangle(VM: TAVM1; const Buffer: IImagePixelBuffer): TAVMValue;
var
  FlashPackage, GeomPackage, ConstructorValue: TAVMValue;
begin
  FlashPackage := VM.GetData(VM.Global, 'flash');
  GeomPackage := VM.GetData(FlashPackage.Obj, 'geom');
  ConstructorValue := VM.GetData(GeomPackage.Obj, 'Rectangle');
  if ConstructorValue.Obj = nil then
    Exit(TAVMValue.Num(-1));
  Result := VM.Construct(ConstructorValue, [TAVMValue.Num(0), TAVMValue.Num(0),
      TAVMValue.Num(Buffer.Width), TAVMValue.Num(Buffer.Height)]);
end;

procedure FillBitmapRect(VM: TAVM1; const Buffer: IImagePixelBuffer; X, Y, Width, Height: Integer; Color: Cardinal);
var
  Left, Top, Right, Bottom: Integer;
  EndX, EndY: Int64;
begin
  EndX := Int64(X) + Width;
  EndY := Int64(Y) + Height;
  Left := Integer(Max(Int64(0), Min(Int64(X), EndX)));
  Top := Integer(Max(Int64(0), Min(Int64(Y), EndY)));
  Right := Integer(Min(Int64(Buffer.Width), Max(Int64(X), EndX)));
  Bottom := Integer(Min(Int64(Buffer.Height), Max(Int64(Y), EndY)));
  if (Right <= Left) or (Bottom <= Top) then
    Exit;
  VM.ChargeWork(1 + ((Right - Left) * (Bottom - Top) - 1) div 32);
  Color := PremultiplyBitmapColor(Color, Buffer.Transparent);
  for Y := Top to Bottom - 1 do
    for X := Left to Right - 1 do
      Buffer.SetPixelPremultiplied(X, Y, Color);
end;

function DrawBitmapData(VM: TAVM1; const Buffer: IImagePixelBuffer; const Args: TArray<TAVMValue>): Integer;
var
  Options: TAVMBitmapDrawOptions;
  Source: TAVMValue;
  Obj: TAVMObject;
  X, Y, Width, Height: Double;

  function ReadNumber(const Name: string): Double;
  begin
    Result := VM.CoerceNumber(VM.Get(Obj, Name));
  end;

begin
  Options := Default(TAVMBitmapDrawOptions);
  Options.Matrix := TSWFMatrix.Identity;
  Options.ColorTransform := TSWFColorTransform.Identity;
  if Length(Args) > 1 then
  begin
    Obj := Args[1].Obj;
    if Obj <> nil then
    begin
      Options.Matrix.A := SWFFloat32(ReadNumber('a'));
      Options.Matrix.B := SWFFloat32(ReadNumber('b'));
      Options.Matrix.C := SWFFloat32(ReadNumber('c'));
      Options.Matrix.D := SWFFloat32(ReadNumber('d'));
      Options.Matrix.TX := SWFTwipsFromPixels(ReadNumber('tx'));
      Options.Matrix.TY := SWFTwipsFromPixels(ReadNumber('ty'));
    end;
  end;
  if (Length(Args) > 2) and (Args[2].Obj <> nil) and (Args[2].Obj.ColorData <> nil) then
    Options.ColorTransform := AVMColorTransform(Args[2].Obj.ColorData);
  if Length(Args) > 3 then
    TryAVMBlend(Args[3], Options.Blend);
  if (Length(Args) > 4) and (Args[4].Obj <> nil) then
  begin
    Obj := Args[4].Obj;
    if VM.HasProperty(Obj, 'x') and VM.HasProperty(Obj, 'y') and
      VM.HasProperty(Obj, 'width') and VM.HasProperty(Obj, 'height') then
    begin
      X := ReadNumber('x');
      Y := ReadNumber('y');
      Width := ReadNumber('width');
      Height := ReadNumber('height');
      Options.HasClip := True;
      Options.ClipRect.Left := SWFTwipsFromPixels(X);
      Options.ClipRect.Top := SWFTwipsFromPixels(Y);
      Options.ClipRect.Right := SWFTwipsFromPixels(X + Width);
      Options.ClipRect.Bottom := SWFTwipsFromPixels(Y + Height);
    end;
  end;
  if Length(Args) > 5 then
    Options.Smooth := Args[5].AsBoolean(VM.SWFVersion);
  if Buffer.Disposed then
    Exit(-1);
  Source := Default(TAVMValue);
  if Length(Args) > 0 then
    Source := Args[0];
  Result := VM.DrawBitmapData(Buffer, Source, Options);
end;

function ReadFilterRect(VM: TAVM1; const Value: TAVMValue; out Rect: TSWFRect): Boolean;
var
  X, Y, Width, Height: Integer;
begin
  Rect := Default(TSWFRect);
  Result := TryGetBitmapRect(VM, Value, X, Y, Width, Height);
  if not Result then
    Exit;
  Rect.Left := X;
  Rect.Top := Y;
  Rect.Right := Min(Int64(High(Integer)), Int64(X) + Max(0, Width));
  Rect.Bottom := Min(Int64(High(Integer)), Int64(Y) + Max(0, Height));
end;

function ApplyFilter(VM: TAVM1; const Dest: IImagePixelBuffer; const Args: TArray<TAVMValue>): Integer;
var
  Source: IImagePixelBuffer;
  Rect: TSWFRect;
  PointObject: TAVMObject;
  X, Y: Integer;
  Filter: TSWFFilter;
begin
  if (Length(Args) = 0) or (Args[0].Obj = nil) then
    Exit(-2);
  Source := Args[0].Obj.BitmapData;
  if Source = nil then
    Exit(-2);
  if Source.Disposed then
    Exit(-3);
  if Length(Args) < 4 then
    Exit(-1);
  ReadFilterRect(VM, Args[1], Rect);
  PointObject := Args[2].Obj;
  X := BitmapInteger(VM, VM.Get(PointObject, 'x'));
  Y := BitmapInteger(VM, VM.Get(PointObject, 'y'));
  if not ReadAVMFilter(Args[3].Obj, Filter) or Dest.Disposed then
    Exit(-1);
  if Source.Disposed then
    Exit(-3);
  if not Dest.Transparent and (Filter.Kind in [sfDropShadow, sfGlow, sfBevel]) then
    Exit(-6);
  VM.ApplyBitmapFilter(Dest, Source, Rect, X, Y, Filter);
  Result := 0;
end;

function GenerateFilterRect(VM: TAVM1; const Args: TArray<TAVMValue>): TAVMValue;
var
  Rect: TSWFRect;
  Filter: TSWFFilter;
begin
  Result := Default(TAVMValue);
  if (Length(Args) < 2) or not ReadFilterRect(VM, Args[0], Rect) or
    not ReadAVMFilter(Args[1].Obj, Filter) then
    Exit;
  Rect := VM.BitmapFilterRect(Rect, Filter);
  Result := AVMNewGeometry(VM, 'Rectangle', [TAVMValue.Num(Rect.Left), TAVMValue.Num(Rect.Top),
      TAVMValue.Num(Int64(Rect.Right) - Rect.Left), TAVMValue.Num(Int64(Rect.Bottom) - Rect.Top)]);
end;

function AVMBitmapDataCall(VM: TAVM1; const Name: string; Instance: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;
var
  Buffer: IImagePixelBuffer;
  LinkageName: TAVMValue;
  X, Y, Width, Height: Integer;
  Color: Cardinal;
begin
  Result := Default(TAVMValue);
  if Name = 'BitmapData' then
  begin
    if ConstructorCall then
      Result := ConstructBitmapData(VM, Instance, Args);
    Exit;
  end;
  if Name = 'BitmapData.loadBitmap' then
  begin
    if Length(Args) > 0 then
      LinkageName := Args[0];
    Buffer := VM.ReadLibraryBitmap(VM.CoerceString(LinkageName));
    if Buffer <> nil then
      Result := NewBitmapObject(VM, Buffer, Instance, 'prototype');
    Exit;
  end;
  if AVMBitmapDataOpsCall(VM, Name, Instance, Args, Result) then
    Exit;

  Result := TAVMValue.Num(-1);
  if Instance = nil then
    Exit;
  Buffer := Instance.BitmapData;
  if (Buffer = nil) or Buffer.Disposed then
    Exit;

  if Name = 'BitmapData.width' then
    Exit(TAVMValue.Num(Buffer.Width));
  if Name = 'BitmapData.height' then
    Exit(TAVMValue.Num(Buffer.Height));
  if Name = 'BitmapData.transparent' then
    Exit(TAVMValue.Bool(Buffer.Transparent));
  if Name = 'BitmapData.rectangle' then
    Exit(BitmapRectangle(VM, Buffer));
  if Name = 'BitmapData.draw' then
    Exit(TAVMValue.Num(DrawBitmapData(VM, Buffer, Args)));
  if Name = 'BitmapData.applyFilter' then
    Exit(TAVMValue.Num(ApplyFilter(VM, Buffer, Args)));
  if Name = 'BitmapData.generateFilterRect' then
    Exit(GenerateFilterRect(VM, Args));
  if Name = 'BitmapData.clone' then
    Exit(CloneBitmapData(VM, Instance, Buffer));
  if Name = 'BitmapData.dispose' then
  begin
    Buffer.Dispose;
    Exit(Default(TAVMValue));
  end;
  if Name = 'BitmapData.fillRect' then
  begin
    if (Length(Args) < 2) or not TryGetBitmapRect(VM, Args[0], X, Y, Width, Height) then
      Exit;
    Color := Cardinal(BitmapInteger(VM, Args[1]));
    FillBitmapRect(VM, Buffer, X, Y, Width, Height, Color);
    Exit(TAVMValue.Num(0));
  end;
  if (Name = 'BitmapData.getPixel') or (Name = 'BitmapData.getPixel32') then
  begin
    if Length(Args) < 2 then
      Exit;
    X := BitmapInteger(VM, Args[0]);
    Y := BitmapInteger(VM, Args[1]);
    Color := Buffer.Pixel(X, Y);
    if Name = 'BitmapData.getPixel' then
      Color := Color and $FFFFFF;
    Exit(TAVMValue.Num(Integer(Color)));
  end;
  if (Name = 'BitmapData.setPixel') or (Name = 'BitmapData.setPixel32') then
  begin
    if Length(Args) < 3 then
      Exit;
    X := BitmapInteger(VM, Args[0]);
    Y := BitmapInteger(VM, Args[1]);
    Color := Cardinal(BitmapInteger(VM, Args[2]));
    if Name = 'BitmapData.setPixel' then
      Color := (Color and $FFFFFF) or (Buffer.Pixel(X, Y) and $FF000000);
    Buffer.SetPixel(X, Y, Color);
    Exit(TAVMValue.Num(0));
  end;
  Result := Default(TAVMValue);
end;

end.

