unit J2ME.Display;

interface

uses
  System.JSON, J2ME.Device, J2ME.Screen, J2ME.Suite;

type
  // Presentation only: neither the VM's Canvas geometry nor guest coordinates
  // change when its completed raster is fitted to the emulated display.
  TJ2MEDisplayPlan = record
    Size: TJ2MEScreenSize;
    Scaling: Boolean;
    Source: string;
    function ToJSON: TJSONObject;
  end;

function J2MEDisplayPlan(Suite: TJ2MESuite; const Screen: TJ2MEScreenDecision; const PhoneSize: TJ2MEScreenSize; Automatic: Boolean): TJ2MEDisplayPlan;

function J2MEFitDisplay(const Pixels: TArray<UInt32>; const Canvas, Display: TJ2MEScreenSize): TArray<UInt32>;

// Clockwise presentation rotation. VM geometry and guest coordinates stay intact.
function J2MERotateDisplay(const Pixels: TArray<UInt32>; Width, Height, QuarterTurns: Integer): TArray<UInt32>;

implementation

uses
  System.SysUtils, System.Math;

function J2MERotateDisplay(const Pixels: TArray<UInt32>; Width, Height, QuarterTurns: Integer): TArray<UInt32>;
begin
  TJ2MEScreenSize.Create(Width, Height);
  if Length(Pixels) <> Width * Height then
    raise EArgumentException.Create('Java ME display raster size');
  QuarterTurns := ((QuarterTurns mod 4) + 4) mod 4;
  if QuarterTurns = 0 then
    Exit(Pixels);
  SetLength(Result, Length(Pixels));
  for var Y := 0 to Height - 1 do
    for var X := 0 to Width - 1 do
      case QuarterTurns of
        1:
          Result[X * Height + Height - 1 - Y] := Pixels[Y * Width + X];
        2:
          Result[(Height - 1 - Y) * Width + Width - 1 - X] := Pixels[Y * Width + X];
        3:
          Result[(Width - 1 - X) * Height + Y] := Pixels[Y * Width + X];
      end;
end;

function DisplayAttribute(const Text: string; out Size: TJ2MEScreenSize): Boolean;
begin
  var S := Text.Trim.Replace(',', 'x').Replace(Char($00D7), 'x').Replace('X', 'x');
  var Parts := S.Split(['x']);
  Result := (Length(Parts) = 2) and TJ2MEScreenSize.TryParse(Parts[0].Trim + 'x' + Parts[1].Trim, Size);
end;

function J2MEDisplayPlan(Suite: TJ2MESuite; const Screen: TJ2MEScreenDecision; const PhoneSize: TJ2MEScreenSize; Automatic: Boolean): TJ2MEDisplayPlan;
begin
  Result := Default(TJ2MEDisplayPlan);
  Result.Size := Screen.Size;
  Result.Source := 'canvas';
  if not Automatic then
  begin
    Result.Source := 'manual';
    Exit;
  end;
  var Original: TJ2MEScreenSize;
  if not DisplayAttribute(Suite.GetProperty('Nokia-MIDlet-Original-Display-Size'), Original) then
    Exit;
  // A higher-priority explicit viewport (for example RetroMul-Screen-Size in
  // the JAD) must not accidentally acquire an unrelated manifest's scaling.
  var NokiaSelected := False;
  for var Evidence in Screen.Evidence do
    if Evidence.StartsWith('Nokia-MIDlet-Original-Display-Size=') then
      NokiaSelected := True;
  if not NokiaSelected or (Original.Width <> Screen.Size.Width) or (Original.Height <> Screen.Size.Height) then
    Exit;
  Result.Scaling := True;
  Result.Size := PhoneSize;
  Result.Source := 'phone';
  var Target: TJ2MEScreenSize;
  if DisplayAttribute(Suite.GetProperty('Nokia-MIDlet-Target-Display-Size'), Target) then
  begin
    Result.Size := Target;
    Result.Source := Suite.PropertySource('Nokia-MIDlet-Target-Display-Size');
  end;
end;

function TJ2MEDisplayPlan.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('width', TJSONNumber.Create(Size.Width));
  Result.AddPair('height', TJSONNumber.Create(Size.Height));
  Result.AddPair('source', Source);
  if Scaling then
    Result.AddPair('scaling', 'fit')
  else
    Result.AddPair('scaling', 'none');
  Result.AddPair('scope', 'fullscreen-canvas');
end;

function J2MEFitDisplay(const Pixels: TArray<UInt32>; const Canvas, Display: TJ2MEScreenSize): TArray<UInt32>;
begin
  // Keep bounds local even when called with a state restored from another size.
  TJ2MEScreenSize.Create(Canvas.Width, Canvas.Height);
  TJ2MEScreenSize.Create(Display.Width, Display.Height);
  if Length(Pixels) <> Canvas.Width * Canvas.Height then
    raise EArgumentException.Create('Java ME display raster size');
  if (Canvas.Width = Display.Width) and (Canvas.Height = Display.Height) then
    Exit(Copy(Pixels));
  var W := Display.Width;
  var H := Display.Height;
  if Int64(W) * Canvas.Height <= Int64(H) * Canvas.Width then
    H := Max(1, Integer(Int64(Canvas.Height) * W div Canvas.Width))
  else
    W := Max(1, Integer(Int64(Canvas.Width) * H div Canvas.Height));
  var Left := (Display.Width - W) div 2;
  var Top := (Display.Height - H) div 2;
  SetLength(Result, Display.Width * Display.Height);
  for var I := 0 to High(Result) do
    Result[I] := $FF000000;
  var Columns: TArray<Integer>;
  SetLength(Columns, W);
  for var X := 0 to W - 1 do
    Columns[X] := Integer(Int64(X) * Canvas.Width div W);
  for var Y := 0 to H - 1 do
  begin
    var SourceRow := Integer(Int64(Y) * Canvas.Height div H) * Canvas.Width;
    var DestRow := (Top + Y) * Display.Width + Left;
    for var X := 0 to W - 1 do
      Result[DestRow + X] := Pixels[SourceRow + Columns[X]];
  end;
end;

end.

