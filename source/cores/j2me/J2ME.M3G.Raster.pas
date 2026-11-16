unit J2ME.M3G.Raster;

interface

uses
  JVM.Types, JVM.Runtime;

type
  // Clip XYZW, camera ZW, two texture STQ triples and front/back ARGB colors.
  TM3GClipVertex = array[0..19] of Double;

  TM3GRasterTexture = record
    Pixels: TJVMObject;
    Width, Height, Format, WrapS, WrapT, Blending, Filter: Integer;
    BlendColor: UInt32;
    BorderDiscard: Boolean;
  end;

  TM3GRasterTarget = record
    Pixels, Depth: TJVMObject;
    Width, Height, Left, Top, Right, Bottom: Integer;
    ViewX, ViewY, ViewWidth, ViewHeight, NearDepth, FarDepth: Double;
    DepthEnabled, PreserveAlpha: Boolean;
    DepthTest, DepthWrite, ColorWrite, AlphaWrite: Boolean;
    Culling, Winding, Blending: Integer;
    AlphaThreshold, DepthOffsetFactor, DepthOffsetUnits: Double;
    FogMode: Integer;
    FogColor: UInt32;
    FogDensity, FogNear, FogFar: Double;
    Textures: array[0..1] of TM3GRasterTexture;
    InterpolateColors: Boolean;
    TwoSidedColors: Boolean;
    SpriteAlpha: Double;
  end;

procedure M3GRasterTriangle(VM: TJVM; const Target: TM3GRasterTarget; var HostPixels: TArray<UInt32>; const A, B, C: TM3GClipVertex; Color: UInt32);

implementation

uses
  System.Math;

type
  TPolygon = array[0..11] of TM3GClipVertex;

function RoundedChannel(Value: Double): UInt32;
begin
  // Clip reconstruction and projective interpolation can approach an exact
  // half-channel tie from below. Bound their Double roundoff before rounding.
  Result := UInt32(Trunc(EnsureRange(Value, 0.0, 255.0) + 0.5 + 128 * 2.2204460492503131E-16 * 255));
end;

function Sample(const Texture: TM3GRasterTexture; S, T: Double): UInt32;

  function Normalize(Value: Double; Wrap: Integer): Double;
  begin
    if IsNan(Value) or IsInfinite(Value) then
      Exit(0);
    if Wrap = 241 then
    begin
      Result := Frac(Value);
      if Result < 0 then
        Result := Result + 1;
    end
    else
      Result := EnsureRange(Value, 0.0, 1.0);
  end;

  function Texel(X, Y: Integer): UInt32;
  begin
    if Texture.WrapS = 241 then
      X := ((X mod Texture.Width) + Texture.Width) mod Texture.Width
    else
      X := EnsureRange(X, 0, Texture.Width - 1);
    if Texture.WrapT = 241 then
      Y := ((Y mod Texture.Height) + Texture.Height) mod Texture.Height
    else
      Y := EnsureRange(Y, 0, Texture.Height - 1);
    Result := UInt32(Texture.Pixels.ElementValues[Y * Texture.Width + X].AsInt);
  end;

begin
  S := Normalize(S, Texture.WrapS) * Texture.Width;
  T := Normalize(T, Texture.WrapT) * Texture.Height;
  if Texture.Filter <> 209 then
    Exit(Texel(Floor(S), Floor(T)));
  S := S - 0.5;
  T := T - 0.5;
  var X := Integer(Floor(S));
  var Y := Integer(Floor(T));
  var U := S - X;
  var V := T - Y;
  var A := Texel(X, Y);
  var B := Texel(X + 1, Y);
  var C := Texel(X, Y + 1);
  var D := Texel(X + 1, Y + 1);
  Result := 0;
  for var Channel := 0 to 3 do
  begin
    var Shift := Channel * 8;
    var Value := ((A shr Shift) and 255) * (1 - U) * (1 - V) + ((B shr Shift) and 255) * U * (1 - V) +
      ((C shr Shift) and 255) * (1 - U) * V + ((D shr Shift) and 255) * U * V;
    Result := Result or (RoundedChannel(Value) shl Shift);
  end;
end;

function TextureBlend(Source, Texel: UInt32; const Texture: TM3GRasterTexture): UInt32;
begin
  Result := 0;
  for var Channel := 0 to 3 do
  begin
    var Shift := Channel * 8;
    var S := Integer((Source shr Shift) and 255);
    var T := Integer((Texel shr Shift) and 255);
    var Value := S;
    var HasAlpha := Texture.Format in [96, 98, 100];
    if Channel = 3 then
    begin
      if HasAlpha then
        if Texture.Blending = 228 then
          Value := T
        else if Texture.Blending <> 226 then
          Value := (S * T + 127) div 255;
    end
    else if Texture.Format <> 96 then
      case Texture.Blending of
        224:
          Value := Min(255, S + T);
        225:
          Value := (S * (255 - T) + Integer((Texture.BlendColor shr Shift) and 255) * T + 127) div 255;
        226:
          if Texture.Format = 100 then
            Value := (S * (255 - Integer(Texel shr 24)) + T * Integer(Texel shr 24) + 127) div 255
          else
            Value := T;
        227:
          Value := (S * T + 127) div 255;
        228:
          Value := T;
      end;
    Result := Result or (UInt32(Value) shl Shift);
  end;
end;

function Plane(const V: TM3GClipVertex; Index: Integer): Double;
begin
  if (Index and 1) = 0 then
    Result := V[3] + V[Index div 2]
  else
    Result := V[3] - V[Index div 2];
end;

procedure M3GRasterTriangle(VM: TJVM; const Target: TM3GRasterTarget; var HostPixels: TArray<UInt32>; const A, B, C: TM3GClipVertex; Color: UInt32);
var
  Polygon, Output: TPolygon;

  procedure Raster(V0, V1, V2: TM3GClipVertex);

    function Edge(const U, V: TM3GClipVertex; X, Y: Double): Double;
    begin
      var DX := V[0] - U[0];
      var DY := V[1] - U[1];
      Result := DX * (Y - U[1]) - DY * (X - U[0]);
      // Clipping reconstructs points on an existing edge. Account for rounding
      // in that reconstruction, projection and the cross product, so a sample
      // on the edge still follows the same half-open coverage convention.
      var Magnitude := Max(Abs(X), Max(Abs(U[0]), Abs(V[0]))) + Max(Abs(Y), Max(Abs(U[1]), Abs(V[1]))) + 1;
      var ErrorBound := 64 * 2.2204460492503131E-16 * Magnitude * (Abs(DX) + Abs(DY) + 1);
      if Abs(Result) <= ErrorBound then
        Result := 0;
    end;

    function Inclusive(const U, V: TM3GClipVertex): Boolean;
    begin
      Result := (V[1] < U[1]) or ((V[1] = U[1]) and (V[0] > U[0]));
    end;

    procedure Project(var V: TM3GClipVertex);
    begin
      V[0] := Target.ViewX + (V[0] / V[3] + 1) * Target.ViewWidth / 2;
      V[1] := Target.ViewY + (1 - V[1] / V[3]) * Target.ViewHeight / 2;
      V[2] := Target.NearDepth + (V[2] / V[3] + 1) * (Target.FarDepth - Target.NearDepth) / 2;
    end;

  begin
    if (V0[3] <= 0) or (V1[3] <= 0) or (V2[3] <= 0) then
      Exit;
    Project(V0);
    Project(V1);
    Project(V2);
    var Area := Edge(V0, V1, V2[0], V2[1]);
    if IsNan(Area) or IsInfinite(Area) or (Area = 0) then
      Exit;
    // Window Y is down, so CCW front faces have a negative screen-space area.
    var Front := Area < 0;
    if Target.Winding = 169 then
      Front := not Front;
    if ((Target.Culling = 160) and not Front) or ((Target.Culling = 161) and Front) then
      Exit;
    var ColorOffset := 12;
    var FlatColor := Color;
    if Target.TwoSidedColors and not Front then
    begin
      ColorOffset := 16;
      FlatColor := 0;
      // C is the original provoking vertex, even if clipping removed it.
      for var K := 0 to 3 do
        FlatColor := FlatColor or (RoundedChannel(C[16 + K]) shl ((3 - K) * 8));
    end;
    if Area < 0 then
    begin
      var Swap := V1;
      V1 := V2;
      V2 := Swap;
      Area := -Area;
    end;
    var Slope := Max(Abs(((V1[2] - V0[2]) * (V2[1] - V0[1]) - (V2[2] - V0[2]) * (V1[1] - V0[1])) / Area),
      Abs(((V1[0] - V0[0]) * (V2[2] - V0[2]) - (V2[0] - V0[0]) * (V1[2] - V0[2])) / Area));
    var DepthOffset := Slope * Target.DepthOffsetFactor + Target.DepthOffsetUnits / 16777216;
    var L := Max(Double(Target.Left), Ceil(Min(V0[0], Min(V1[0], V2[0])) - 0.5));
    var R := Min(Double(Target.Right - 1), Floor(Max(V0[0], Max(V1[0], V2[0])) - 0.5));
    var T := Max(Double(Target.Top), Ceil(Min(V0[1], Min(V1[1], V2[1])) - 0.5));
    var B := Min(Double(Target.Bottom - 1), Floor(Max(V0[1], Max(V1[1], V2[1])) - 0.5));
    if (L > R) or (T > B) then
      Exit;
    var I0 := Inclusive(V1, V2);
    var I1 := Inclusive(V2, V0);
    var I2 := Inclusive(V0, V1);
    for var Y := Integer(Trunc(T)) to Integer(Trunc(B)) do
    begin
      if VM.StopRequested then
        Exit;
      for var X := Integer(Trunc(L)) to Integer(Trunc(R)) do
      begin
        var E0 := Edge(V1, V2, X + 0.5, Y + 0.5);
        var E1 := Edge(V2, V0, X + 0.5, Y + 0.5);
        var E2 := Edge(V0, V1, X + 0.5, Y + 0.5);
        if (E0 < 0) or ((E0 = 0) and not I0) or (E1 < 0) or ((E1 = 0) and not I1) or
          (E2 < 0) or ((E2 = 0) and not I2) then
          Continue;
        var Fragment := FlatColor;
        var W0 := E0 / V0[3];
        var W1 := E1 / V1[3];
        var W2 := E2 / V2[3];
        if Target.InterpolateColors then
        begin
          var Sum := W0 + W1 + W2;
          Fragment := 0;
          for var K := 0 to 3 do
          begin
            var Value := EnsureRange((W0 * V0[ColorOffset + K] + W1 * V1[ColorOffset + K] + W2 * V2[ColorOffset + K]) / Sum, 0.0, 255.0);
            Fragment := Fragment or (RoundedChannel(Value) shl ((3 - K) * 8));
          end;
        end;
        var Discard := False;
        for var UnitIndex := 0 to 1 do
          if Target.Textures[UnitIndex].Pixels <> nil then
          begin
            var K := 6 + 3 * UnitIndex;
            var Q := W0 * V0[K + 2] + W1 * V1[K + 2] + W2 * V2[K + 2];
            var TexS: Double := 0;
            var TexT: Double := 0;
            if Q <> 0 then
            begin
              TexS := (W0 * V0[K] + W1 * V1[K] + W2 * V2[K]) / Q;
              TexT := (W0 * V0[K + 1] + W1 * V1[K + 1] + W2 * V2[K + 1]) / Q;
            end;
            if Target.Textures[UnitIndex].BorderDiscard and
              ((TexS < 0) or (TexS >= 1) or (TexT < 0) or (TexT >= 1)) then
            begin
              Discard := True;
              Break;
            end;
            var Texel := Sample(Target.Textures[UnitIndex], TexS, TexT);
            if Target.Textures[UnitIndex].BorderDiscard then
              Fragment := (Texel and $FFFFFF) or (RoundedChannel((Texel shr 24) * Target.SpriteAlpha) shl 24)
            else
              Fragment := TextureBlend(Fragment, Texel, Target.Textures[UnitIndex]);
          end;
        if Discard then
          Continue;
        if Target.FogMode <> 0 then
        begin
          var EyeW := E0 * V0[5] / V0[3] + E1 * V1[5] / V1[3] + E2 * V2[5] / V2[3];
          var Factor: Double := 1;
          if EyeW <> 0 then
          begin
            var Distance := Abs((E0 * V0[4] / V0[3] + E1 * V1[4] / V1[3] + E2 * V2[4] / V2[3]) / EyeW);
            if Target.FogMode = 80 then
            begin
              if (Target.FogDensity <> 0) and (Distance <> 0) then
              begin
                var Exponent := Target.FogDensity * Distance;
                if Exponent > 700 then
                  Factor := 0
                else
                  Factor := Exp(-Exponent);
              end;
            end
            else if Target.FogNear <> Target.FogFar then
              Factor := (Target.FogFar - Distance) / (Target.FogFar - Target.FogNear);
          end;
          if IsNan(Factor) then
            Factor := 1;
          Factor := EnsureRange(Factor, 0.0, 1.0);
          var FogSource := Fragment;
          Fragment := Fragment and $FF000000;
          for var Channel := 0 to 2 do
          begin
            var Shift := Channel * 8;
            var Value := Trunc(((FogSource shr Shift) and 255) * Factor + ((Target.FogColor shr Shift) and 255) * (1 - Factor) + 0.5);
            Fragment := Fragment or (UInt32(Value) shl Shift);
          end;
        end;
        if (Fragment shr 24) / 255 < Target.AlphaThreshold then
          Continue;
        var Z: Single := EnsureRange((E0 * V0[2] + E1 * V1[2] + E2 * V2[2]) / Area + DepthOffset, 0.0, 1.0);
        var Index := Y * Target.Width + X;
        if Target.DepthEnabled then
        begin
          if Target.DepthTest and (Z > Target.Depth.ElementValues[Index].AsFloat) then
            Continue;
          if Target.DepthWrite then
            Target.Depth.ElementValues[Index] := TJVMValue.Float(Z);
        end;
        var Destination: UInt32;
        if Target.Pixels <> nil then
          Destination := UInt32(Target.Pixels.ElementValues[Index].AsInt)
        else
          Destination := HostPixels[Index];
        var Blended: UInt32 := 0;
        var Alpha := Integer(Fragment shr 24);
        for var Channel := 0 to 3 do
        begin
          var Shift := Channel * 8;
          var Source := Integer((Fragment shr Shift) and 255);
          var Dest := Integer((Destination shr Shift) and 255);
          var Value := Source;
          case Target.Blending of
            64:
              Value := (Source * Alpha + Dest * (255 - Alpha) + 127) div 255;
            65:
              Value := Min(255, (Source * Alpha + 127) div 255 + Dest);
            66:
              Value := (Source * Dest + 127) div 255;
            67:
              Value := Min(255, (2 * Source * Dest + 127) div 255);
          end;
          if ((Channel = 3) and not Target.AlphaWrite) or ((Channel <> 3) and not Target.ColorWrite) then
            Value := Dest;
          Blended := Blended or (UInt32(Value) shl Shift);
        end;
        if not Target.PreserveAlpha then
          Blended := Blended or $FF000000;
        if Target.Pixels <> nil then
          Target.Pixels.ElementValues[Index] := TJVMValue.Int(Integer(Blended))
        else
          HostPixels[Index] := Blended;
      end;
    end;
  end;

begin
  for var I := 0 to High(TM3GClipVertex) do
    if IsNan(A[I]) or IsInfinite(A[I]) or IsNan(B[I]) or IsInfinite(B[I]) or IsNan(C[I]) or IsInfinite(C[I]) then
      Exit;
  Polygon[0] := A;
  Polygon[1] := B;
  Polygon[2] := C;
  var Count := 3;
  for var P := 0 to 5 do
  begin
    var Written := 0;
    for var I := 0 to Count - 1 do
    begin
      var U := Polygon[I];
      var V := Polygon[(I + 1) mod Count];
      var DU := Plane(U, P);
      var DV := Plane(V, P);
      if DU >= 0 then
      begin
        Output[Written] := U;
        Inc(Written);
      end;
      // A vertex exactly on the plane is already emitted as an inside vertex.
      // Only strict sign changes add intersections, keeping the polygon bound
      // at three original vertices plus at most one per clipping plane.
      if ((DU > 0) and (DV < 0)) or ((DU < 0) and (DV > 0)) then
      begin
        var Fraction := DU / (DU - DV);
        for var K := 0 to High(TM3GClipVertex) do
          Output[Written][K] := U[K] + Fraction * (V[K] - U[K]);
        Inc(Written);
      end;
    end;
    if Written < 3 then
      Exit;
    Polygon := Output;
    Count := Written;
  end;
  for var I := 1 to Count - 2 do
    Raster(Polygon[0], Polygon[I], Polygon[I + 1]);
end;

end.

