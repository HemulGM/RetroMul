unit J2ME.M3G.Lighting;

interface

uses
  JVM.Runtime, J2ME.M3G.Math;

const
  M3GMaxLights = 64;

type
  TM3GLightVector = array[0..2] of Double;

  TM3GLightColor = array[0..3] of Double; // A, R, G, B in [0,255].

  TM3GLight = record
    Mode: Integer;
    Position, Direction, Color: TM3GLightVector;
    Constant, Linear, Quadratic, SpotCos, SpotExponent: Double;
  end;

  TM3GLighting = record
    Controller: TJVM; // Borrowed for cancellation during native lighting loops.
    Enabled, Tracking, LocalViewer, TwoSided: Boolean;
    Ambient, Diffuse, Emissive, Specular: TM3GLightVector;
    Alpha, Shininess: Double;
    NormalMatrix: array[0..8] of Double;
    Lights: TArray<TM3GLight>;
  end;

function M3GPrepareLighting(VM: TJVM; Renderer: TJVMObject; MaterialRef, PolygonRef, Scope: Integer; const ModelView, WorldToCamera: TM3GMatrix; Alpha: Double): TM3GLighting;

procedure M3GLightVertex(const State: TM3GLighting; const Position: TM3GVector; const Normal: TM3GLightVector; const Color: TM3GLightColor; out FrontColor, BackColor: TM3GLightColor);

implementation

uses
  System.SysUtils, System.Math, JVM.Types;

const
  P = '$m3g.';

function I(O: TJVMObject; const Key: string; Fallback: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if (O <> nil) and O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsInt;
end;

function F(O: TJVMObject; const Key: string; Fallback: Double = 0): Double;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if (O <> nil) and O.Fields.TryGetValue(P + Key, V) then
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

function RGB(Color: UInt32): TM3GLightVector;
begin
  for var K := 0 to 2 do
    Result[K] := ((Color shr ((2 - K) * 8)) and 255) / 255;
end;

function Dot(const A, B: TM3GLightVector): Double;
begin
  Result := A[0] * B[0] + A[1] * B[1] + A[2] * B[2];
end;

function UnitVector(const V: TM3GLightVector): TM3GLightVector;
begin
  // Scaling first avoids overflowing squared lengths with valid large inputs.
  var Scale := Max(Abs(V[0]), Max(Abs(V[1]), Abs(V[2])));
  Result := Default(TM3GLightVector);
  if (Scale = 0) or IsNan(Scale) or IsInfinite(Scale) then
    Exit;
  for var K := 0 to 2 do
    Result[K] := V[K] / Scale;
  var Length := Sqrt(Dot(Result, Result));
  for var K := 0 to 2 do
    Result[K] := Result[K] / Length;
end;

function M3GPrepareLighting(VM: TJVM; Renderer: TJVMObject; MaterialRef, PolygonRef, Scope: Integer; const ModelView, WorldToCamera: TM3GMatrix; Alpha: Double): TM3GLighting;
begin
  Result := Default(TM3GLighting);
  Result.Controller := VM;
  Result.Enabled := MaterialRef <> 0;
  if not Result.Enabled then
    Exit;
  var Material := VM.GetObject(MaterialRef);
  var Diffuse := UInt32(I(Material, 'color2048', Integer($FFCCCCCC)));
  Result.Ambient := RGB(UInt32(I(Material, 'color1024', $333333)));
  Result.Diffuse := RGB(Diffuse);
  Result.Emissive := RGB(UInt32(I(Material, 'color4096')));
  Result.Specular := RGB(UInt32(I(Material, 'color8192')));
  Result.Alpha := (Diffuse shr 24) * Alpha;
  Result.Shininess := F(Material, 'shininess');
  Result.Tracking := I(Material, 'tracking') <> 0;
  var Polygon: TJVMObject := nil;
  if PolygonRef <> 0 then
    Polygon := VM.GetObject(PolygonRef);
  Result.LocalViewer := I(Polygon, 'LocalCameraLighting') <> 0;
  Result.TwoSided := I(Polygon, 'TwoSidedLighting') <> 0;
  var Inverse: TM3GMatrix;
  // Lighting under a singular model-view transform is undefined. Keep its
  // behavior bounded without rejecting geometry that can still be rasterized.
  if not M3GInverse(ModelView, Inverse) then
    Inverse := M3GIdentity;
  for var Row := 0 to 2 do
    for var Column := 0 to 2 do
      Result.NormalMatrix[Row * 3 + Column] := Inverse[Column * 4 + Row];
  var Count := I(Renderer, 'lightCount');
  SetLength(Result.Lights, Min(Count, M3GMaxLights));
  var Used := 0;
  for var Index := 0 to Count - 1 do
  begin
    if VM.StopRequested then
      Break;
    var Ref := R(Renderer, 'light' + IntToStr(Index));
    if Ref = 0 then
      Continue;
    var Source := VM.GetObject(Ref);
    if (I(Source, 'render', 1) = 0) or ((Scope and I(Source, 'scope', -1)) = 0) then
      Continue;
    var Light: TM3GLight;
    Light.Mode := I(Source, 'lightMode', 129);
    Light.Color := RGB(UInt32(I(Source, 'lightColor', $FFFFFF)));
    var Intensity := F(Source, 'Intensity', 1);
    for var K := 0 to 2 do
      Light.Color[K] := Light.Color[K] * Intensity;
    var WorldMatrix := M3GIdentity;
    for var K := 0 to 15 do
      WorldMatrix[K] := F(Renderer, 'lightMatrix' + IntToStr(Index) + '.' + IntToStr(K), WorldMatrix[K]);
    var CameraMatrix := M3GMultiply(WorldToCamera, WorldMatrix);
    var Position := Default(TM3GVector);
    Position[3] := 1;
    Position := M3GTransformVector(CameraMatrix, Position);
    var W: Double := Position[3];
    if W = 0 then
      W := 1;
    for var K := 0 to 2 do
    begin
      Light.Position[K] := Position[K] / W;
      Light.Direction[K] := -Double(CameraMatrix[K * 4 + 2]);
    end;
    Light.Direction := UnitVector(Light.Direction);
    Light.Constant := F(Source, 'ConstantAttenuation', 1);
    Light.Linear := F(Source, 'LinearAttenuation');
    Light.Quadratic := F(Source, 'QuadraticAttenuation');
    var Angle := F(Source, 'SpotAngle', 45);
    Light.SpotCos := Cos(Angle * Pi / 180);
    if Angle = 90 then
      Light.SpotCos := 0;
    Light.SpotExponent := F(Source, 'SpotExponent');
    Result.Lights[Used] := Light;
    Inc(Used);
    // Select the first matching lights deterministically; array slots remain
    // unlimited and disabled/out-of-scope entries do not consume the budget.
    if Used = M3GMaxLights then
      Break;
  end;
  SetLength(Result.Lights, Used);
end;

procedure M3GLightVertex(const State: TM3GLighting; const Position: TM3GVector; const Normal: TM3GLightVector; const Color: TM3GLightColor; out FrontColor, BackColor: TM3GLightColor);
var
  EyePosition, EyeNormal, Viewer, Ambient, Diffuse: TM3GLightVector;

  procedure Shade(const N: TM3GLightVector; out Lit: TM3GLightColor);
  begin
    Lit[0] := State.Alpha;
    if State.Tracking then
      Lit[0] := Color[0];
    var Sum := State.Emissive;
    for var Light in State.Lights do
    begin
      if State.Controller.StopRequested then
      begin
        Lit := Default(TM3GLightColor);
        Exit;
      end;
      if Light.Mode = 128 then
      begin
        for var K := 0 to 2 do
          Sum[K] := Sum[K] + Ambient[K] * Light.Color[K];
        Continue;
      end;
      var L: TM3GLightVector;
      var Attenuation: Double := 1;
      if Light.Mode = 129 then
        for var K := 0 to 2 do
          L[K] := -Light.Direction[K]
      else
      begin
        for var K := 0 to 2 do
          L[K] := Light.Position[K] - EyePosition[K];
        var Distance := Sqrt(Dot(L, L));
        L := UnitVector(L);
        var Denominator := Light.Constant + Light.Linear * Distance + Light.Quadratic * Distance * Distance;
        if Denominator <= 0 then
          Attenuation := 0
        else
          Attenuation := 1 / Denominator;
        if Light.Mode = 131 then
        begin
          var Cone := EnsureRange(-Dot(L, Light.Direction), 0.0, 1.0);
          if (-Dot(L, Light.Direction) < Light.SpotCos - 32 * 2.2204460492503131E-16) then
            Attenuation := 0
          else if Light.SpotExponent <> 0 then
            Attenuation := Attenuation * Power(Cone, Light.SpotExponent);
        end;
      end;
      var Lambert := Max(0.0, Dot(N, L));
      var Specular: Double := 0;
      if Lambert > 0 then
      begin
        var H: TM3GLightVector;
        for var K := 0 to 2 do
          H[K] := L[K] + Viewer[K];
        H := UnitVector(H);
        if State.Shininess = 0 then
          Specular := 1
        else
          Specular := Power(Max(0.0, Dot(N, H)), State.Shininess);
      end;
      for var K := 0 to 2 do
        Sum[K] := Sum[K] + Attenuation * Light.Color[K] * (Diffuse[K] * Lambert + State.Specular[K] * Specular);
    end;
    // Negative lights are accumulated before the final color clamp.
    for var K := 0 to 2 do
      Lit[K + 1] := 255 * EnsureRange(Sum[K], 0.0, 1.0);
  end;

begin
  var W: Double := Position[3];
  if W = 0 then
    W := 1;
  for var K := 0 to 2 do
  begin
    EyePosition[K] := Position[K] / W;
    EyeNormal[K] := 0;
    for var J := 0 to 2 do
      EyeNormal[K] := EyeNormal[K] + State.NormalMatrix[K * 3 + J] * Normal[J];
  end;
  EyeNormal := UnitVector(EyeNormal);
  Viewer := Default(TM3GLightVector);
  Viewer[2] := 1;
  if State.LocalViewer then
  begin
    for var K := 0 to 2 do
      Viewer[K] := -EyePosition[K];
    Viewer := UnitVector(Viewer);
  end;
  Ambient := State.Ambient;
  Diffuse := State.Diffuse;
  if State.Tracking then
    for var K := 0 to 2 do
    begin
      Ambient[K] := Color[K + 1] / 255;
      Diffuse[K] := Color[K + 1] / 255;
    end;
  Shade(EyeNormal, FrontColor);
  BackColor := FrontColor;
  if State.TwoSided then
  begin
    for var K := 0 to 2 do
      EyeNormal[K] := -EyeNormal[K];
    Shade(EyeNormal, BackColor);
  end;
end;

end.

