unit AVM1.BitmapOps;

interface

uses
  AVM1.Runtime;

function TryGetBitmapRect(VM: TAVM1; const Arg: TAVMValue; out X, Y, Width, Height: Integer): Boolean;

function AVMBitmapDataOpsCall(VM: TAVM1; const Name: string; Instance: TAVMObject; const Args: TArray<TAVMValue>; out Value: TAVMValue): Boolean;

implementation

uses
  System.Math, AVM1.Coercion, Media.Image.PixelBuffer;

type
  TBitmapOperation = (boCopyPixels, boCopyChannel, boScroll, boColorTransform);

  TBitmapTransfer = record
    SourceX, SourceY: Integer;
    DestX, DestY: Integer;
    AlphaX, AlphaY: Integer;
    Width, Height: Integer;
  end;

function TryGetBitmapRect(VM: TAVM1; const Arg: TAVMValue; out X, Y, Width, Height: Integer): Boolean;
var
  RectObject: TAVMObject;
begin
  RectObject := VM.Box(Arg);
  Result := VM.HasProperty(RectObject, 'x') and VM.HasProperty(RectObject, 'y') and
    VM.HasProperty(RectObject, 'width') and VM.HasProperty(RectObject, 'height');
  if not Result then
    Exit;
  X := AVMToInt32(VM.CoerceNumber(VM.Get(RectObject, 'x')));
  Y := AVMToInt32(VM.CoerceNumber(VM.Get(RectObject, 'y')));
  Width := AVMToInt32(VM.CoerceNumber(VM.Get(RectObject, 'width')));
  Height := AVMToInt32(VM.CoerceNumber(VM.Get(RectObject, 'height')));
end;

function BitmapOf(Instance: TAVMObject): IImagePixelBuffer;
begin
  Result := nil;
  if Instance <> nil then
    Result := Instance.BitmapData;
end;

function SaturatingInt(Value: Double; Lower, Upper: Integer): Integer;
begin
  if IsNan(Value) then
    Exit(0);
  if Value <= Lower then
    Exit(Lower);
  if Value >= Upper then
    Exit(Upper);
  Result := Trunc(Value);
end;

procedure ReadPoint(VM: TAVM1; PointObject: TAVMObject; Wrap: Boolean; out X, Y: Integer);
var
  Coord: Double;
begin
  Coord := VM.CoerceNumber(VM.Get(PointObject, 'x'));
  if Wrap then
    X := AVMToInt32(Coord)
  else
    X := SaturatingInt(Coord, Low(Integer), High(Integer));
  Coord := VM.CoerceNumber(VM.Get(PointObject, 'y'));
  if Wrap then
    Y := AVMToInt32(Coord)
  else
    Y := SaturatingInt(Coord, Low(Integer), High(Integer));
end;

procedure ClipAxis(Origin, Limit: Integer; var First, Last: Int64);
var
  StartOffset, EndOffset: Int64;
begin
  StartOffset := Int64(0) - Int64(Origin);
  EndOffset := Int64(Limit) - Origin;
  if StartOffset > First then
    First := StartOffset;
  if EndOffset < Last then
    Last := EndOffset;
end;

function ClipTransfer(var Area: TBitmapTransfer; const Source, Dest, Alpha: IImagePixelBuffer): Boolean;
var
  Left, Top, Right, Bottom: Int64;
begin
  Left := 0;
  Top := 0;
  Right := Area.Width;
  Bottom := Area.Height;
  ClipAxis(Area.SourceX, Source.Width, Left, Right);
  ClipAxis(Area.SourceY, Source.Height, Top, Bottom);
  ClipAxis(Area.DestX, Dest.Width, Left, Right);
  ClipAxis(Area.DestY, Dest.Height, Top, Bottom);
  if (Alpha <> nil) and Alpha.Transparent then
  begin
    ClipAxis(Area.AlphaX, Alpha.Width, Left, Right);
    ClipAxis(Area.AlphaY, Alpha.Height, Top, Bottom);
  end;
  Result := (Left < Right) and (Top < Bottom);
  if not Result then
    Exit;
  Area.SourceX := Int64(Area.SourceX) + Left;
  Area.SourceY := Int64(Area.SourceY) + Top;
  Area.DestX := Int64(Area.DestX) + Left;
  Area.DestY := Int64(Area.DestY) + Top;
  if (Alpha <> nil) and Alpha.Transparent then
  begin
    Area.AlphaX := Int64(Area.AlphaX) + Left;
    Area.AlphaY := Int64(Area.AlphaY) + Top;
  end;
  Area.Width := Right - Left;
  Area.Height := Bottom - Top;
end;

function ApplyAlphaMask(Source, MaskAlpha: Cardinal): Cardinal;
var
  Alpha, Shift, Channel, StraightColor: Cardinal;
begin
  Alpha := Source shr 24;
  if (Alpha = 0) or (MaskAlpha = 255) then
    Exit(Source);
  if Alpha <> 255 then
    MaskAlpha := (Alpha * MaskAlpha) shr 8;
  StraightColor := MaskAlpha shl 24;
  for Shift in [0, 8, 16] do
  begin
    Channel := ((((Source shr Shift) and $FF) * 255) + Alpha div 2) div Alpha;
    StraightColor := StraightColor or (Channel shl Shift);
  end;
  Result := PremultiplyBitmapColor(StraightColor, True);
end;

procedure CopyPixels(VM: TAVM1; const Source, Dest, Alpha: IImagePixelBuffer; Area: TBitmapTransfer; MergeAlpha: Boolean);
var
  Merge, Masked, TransparentMask, ReverseRows, ReverseColumns: Boolean;
  Row, Column, OffsetX, OffsetY, SourceX, SourceY, DestX, DestY: Integer;
  Color, MaskAlpha: Cardinal;
begin
  Masked := (Alpha <> nil) and not ((Alpha = Source) and
    (Area.AlphaX = Area.SourceX) and (Area.AlphaY = Area.SourceY));
  if Masked then
  begin
    if not ClipTransfer(Area, Source, Dest, Alpha) then
      Exit;
    Merge := MergeAlpha or not Dest.Transparent;
  end
  else
  begin
    if not ClipTransfer(Area, Source, Dest, nil) then
      Exit;
    Merge := Source.Transparent and (MergeAlpha or not Dest.Transparent);
    if (Source = Dest) and not Merge and (Area.SourceX = Area.DestX) and
      (Area.SourceY = Area.DestY) then
      Exit;
  end;

  // Flash reverses both axes of a blended self-copy only when both offsets
  // are nonnegative. A plain copy moves each row without overwriting its input.
  ReverseRows := not Masked and (Source = Dest) and
    (Area.DestY >= Area.SourceY) and (Area.DestX >= Area.SourceX);
  ReverseColumns := ReverseRows or
    (not Masked and not Merge and (Source = Dest) and (Area.DestX > Area.SourceX));
  TransparentMask := Masked and Alpha.Transparent;
  if Masked or Merge then
    VM.ChargeWork((Area.Width * Area.Height + 31) div 32)
  else
    VM.ChargeWork((Area.Width * Area.Height + 63) div 64);

  for Row := 0 to Area.Height - 1 do
  begin
    OffsetY := Row;
    if ReverseRows then
      OffsetY := Area.Height - 1 - Row;
    SourceY := Area.SourceY + OffsetY;
    DestY := Area.DestY + OffsetY;
    for Column := 0 to Area.Width - 1 do
    begin
      OffsetX := Column;
      if ReverseColumns then
        OffsetX := Area.Width - 1 - Column;
      SourceX := Area.SourceX + OffsetX;
      DestX := Area.DestX + OffsetX;
      Color := Source.PixelPremultiplied(SourceX, SourceY);
      if TransparentMask then
      begin
        MaskAlpha := Alpha.PixelPremultiplied(Area.AlphaX + OffsetX, Area.AlphaY + OffsetY) shr 24;
        Color := ApplyAlphaMask(Color, MaskAlpha);
      end;
      if Merge then
        Color := BlendPremultiplied(Dest.PixelPremultiplied(DestX, DestY), Color);
      Dest.SetPixelPremultiplied(DestX, DestY, Color);
    end;
  end;
end;

function ChannelShift(Channel: Integer): Integer;
begin
  case Channel of
    1:
      Result := 16;
    2:
      Result := 8;
    4:
      Result := 0;
    8:
      Result := 24;
  else
    Result := -1;
  end;
end;

procedure CopyChannel(VM: TAVM1; const Source, Dest: IImagePixelBuffer; Area: TBitmapTransfer; SourceChannel, DestChannel: Integer);
var
  SourceShift, DestShift, X, Y: Integer;
  Channel, Color, KeepMask: Cardinal;
begin
  SourceShift := ChannelShift(SourceChannel);
  DestShift := ChannelShift(DestChannel);
  if (DestShift < 0) or ((DestShift = 24) and not Dest.Transparent) then
    Exit;
  if not ClipTransfer(Area, Source, Dest, nil) then
    Exit;
  VM.ChargeWork((Area.Width * Area.Height + 63) div 64);
  KeepMask := not (Cardinal($FF) shl DestShift);
  for Y := 0 to Area.Height - 1 do
    for X := 0 to Area.Width - 1 do
    begin
      Channel := 0;
      if SourceShift >= 0 then
        Channel := (Source.Pixel(Area.SourceX + X, Area.SourceY + Y) shr SourceShift) and $FF;
      Color := Dest.Pixel(Area.DestX + X, Area.DestY + Y);
      Dest.SetPixel(Area.DestX + X, Area.DestY + Y,
        (Color and KeepMask) or (Channel shl DestShift));
    end;
end;

procedure Scroll(VM: TAVM1; const Bitmap: IImagePixelBuffer; DeltaX, DeltaY: Integer);
var
  Left, Top, Width, Height, Row, Column, X, Y: Integer;
begin
  if (DeltaX = 0) and (DeltaY = 0) then
    Exit;
  if (DeltaX <= -Bitmap.Width) or (DeltaX >= Bitmap.Width) or
    (DeltaY <= -Bitmap.Height) or (DeltaY >= Bitmap.Height) then
    Exit;

  Left := Max(0, -DeltaX);
  Top := Max(0, -DeltaY);
  Width := Bitmap.Width - Abs(DeltaX);
  Height := Bitmap.Height - Abs(DeltaY);
  VM.ChargeWork((Width * Height + 63) div 64);
  for Row := 0 to Height - 1 do
  begin
    Y := Top + Row;
    if DeltaY > 0 then
      Y := Top + Height - 1 - Row;
    for Column := 0 to Width - 1 do
    begin
      X := Left + Column;
      if (DeltaY = 0) and (DeltaX > 0) then
        X := Left + Width - 1 - Column;
      Bitmap.SetPixelPremultiplied(X + DeltaX, Y + DeltaY, Bitmap.PixelPremultiplied(X, Y));
    end;
  end;
end;

procedure ColorTransform(VM: TAVM1; const Bitmap: IImagePixelBuffer; const Area: TBitmapTransfer; const Transform: IAVMColorData);
const
  Shifts: array[0..3] of Integer = (16, 8, 0, 24);
var
  Left, Top, Right, Bottom, X, Y, I, Component: Integer;
  Mult, Offset: array[0..3] of Integer;
  Neutral: Boolean;
  Color, Transformed: Cardinal;
begin
  Left := Max(0, Area.SourceX);
  Top := Max(0, Area.SourceY);
  Right := Min(Int64(Bitmap.Width), (Int64(Area.SourceX) + Area.Width) and $FFFFFFFF);
  Bottom := Min(Int64(Bitmap.Height), (Int64(Area.SourceY) + Area.Height) and $FFFFFFFF);
  if (Left >= Right) or (Top >= Bottom) then
    Exit;

  Neutral := True;
  for I := 0 to 3 do
  begin
    Mult[I] := SaturatingInt(Transform[I] * 256, Low(SmallInt), High(SmallInt));
    Offset[I] := SaturatingInt(Transform[I + 4], Low(SmallInt), High(SmallInt));
    if (Offset[I] <> 0) or (Mult[I] < 256) or ((I <> 3) and (Mult[I] <> 256)) then
      Neutral := False;
  end;
  // Flash ignores an alpha-only multiplier greater than one.
  if Neutral then
    Exit;
  VM.ChargeWork(((Right - Left) * (Bottom - Top) + 31) div 32);

  for Y := Top to Bottom - 1 do
    for X := Left to Right - 1 do
    begin
      Color := Bitmap.Pixel(X, Y);
      if Color shr 24 = 0 then
        Continue;
      Transformed := 0;
      for I := 0 to 3 do
      begin
        Component := Integer((Color shr Shifts[I]) and $FF) * Mult[I];
        if Component < 0 then
          Dec(Component, 255);
        Component := EnsureRange(Component div 256 + Offset[I], 0, 255);
        Transformed := Transformed or (Cardinal(Component) shl Shifts[I]);
      end;
      Bitmap.SetPixel(X, Y, Transformed);
    end;
end;

function AVMBitmapDataOpsCall(VM: TAVM1; const Name: string; Instance: TAVMObject; const Args: TArray<TAVMValue>; out Value: TAVMValue): Boolean;
var
  Operation: TBitmapOperation;
  Dest, Source, Alpha: IImagePixelBuffer;
  PointObject: TAVMObject;
  Area: TBitmapTransfer;
  RequiredArgs, SourceChannel, DestChannel: Integer;
  MergeAlpha: Boolean;
begin
  Result := True;
  Value := TAVMValue.Num(-1);
  if Name = 'BitmapData.copyPixels' then
  begin
    Operation := boCopyPixels;
    RequiredArgs := 3;
  end
  else if Name = 'BitmapData.copyChannel' then
  begin
    Operation := boCopyChannel;
    RequiredArgs := 5;
  end
  else if Name = 'BitmapData.scroll' then
  begin
    Operation := boScroll;
    RequiredArgs := 2;
  end
  else if Name = 'BitmapData.colorTransform' then
  begin
    Operation := boColorTransform;
    RequiredArgs := 2;
  end
  else
    Exit(False);

  if Length(Args) < RequiredArgs then
    Exit;
  Dest := BitmapOf(Instance);
  if (Dest = nil) or Dest.Disposed then
    Exit;
  Area := Default(TBitmapTransfer);

  if Operation = boScroll then
  begin
    Area.DestX := AVMToInt32(VM.CoerceNumber(Args[0]));
    Area.DestY := AVMToInt32(VM.CoerceNumber(Args[1]));
    Scroll(VM, Dest, Area.DestX, Area.DestY);
    Value := TAVMValue.Num(0);
    Exit;
  end;

  if Operation = boColorTransform then
  begin
    if not TryGetBitmapRect(VM, Args[0], Area.SourceX, Area.SourceY, Area.Width, Area.Height) then
      Value := TAVMValue.Num(-2)
    else if (Args[1].Obj = nil) or (Args[1].Obj.ColorData = nil) then
      Value := TAVMValue.Num(-3)
    else
      ColorTransform(VM, Dest, Area, Args[1].Obj.ColorData);
    Exit;
  end;

  Source := BitmapOf(VM.Box(Args[0]));
  if Source = nil then
  begin
    Value := TAVMValue.Num(-2);
    Exit;
  end;
  if Source.Disposed then
  begin
    Value := TAVMValue.Num(-3);
    Exit;
  end;
  if not TryGetBitmapRect(VM, Args[1], Area.SourceX, Area.SourceY, Area.Width, Area.Height) then
  begin
    Value := TAVMValue.Num(-4);
    Exit;
  end;

  PointObject := VM.Box(Args[2]);
  if Operation = boCopyChannel then
  begin
    SourceChannel := AVMToInt32(VM.CoerceNumber(Args[3]));
    DestChannel := AVMToInt32(VM.CoerceNumber(Args[4]));
    ReadPoint(VM, PointObject, True, Area.DestX, Area.DestY);
    CopyChannel(VM, Source, Dest, Area, SourceChannel, DestChannel);
    Exit;
  end;

  ReadPoint(VM, PointObject, False, Area.DestX, Area.DestY);
  if Length(Args) >= 4 then
  begin
    Alpha := BitmapOf(VM.Box(Args[3]));
    if (Alpha <> nil) and Alpha.Disposed then
      Alpha := nil;
  end;
  if Length(Args) >= 6 then
    MergeAlpha := Args[5].AsBoolean(VM.SWFVersion)
  else
    MergeAlpha := Alpha <> nil;
  if (Alpha <> nil) and (Length(Args) >= 5) then
    ReadPoint(VM, VM.Box(Args[4]), False, Area.AlphaX, Area.AlphaY);
  CopyPixels(VM, Source, Dest, Alpha, Area, MergeAlpha);
  Value := TAVMValue.Num(0);
end;

end.

