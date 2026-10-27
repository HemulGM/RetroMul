unit GW.Artwork.FMX;

interface

uses
  System.SysUtils, System.UITypes, GW.Artwork;

function RenderGWArtwork(const Screens: TArray<string>; Layout: Integer; ShiftLCD: Boolean): TGWArtwork;

function DecodeGWBitmap(const Data: TBytes; Width, Height: Integer): TArray<TAlphaColor>;

implementation

uses
  System.Classes, System.Types, System.Math, FMX.Types, FMX.Graphics, FMX.SVG,
  FMX.SVG.Cache;

function OutputIndex(const Name: string; ShiftLCD: Boolean): Integer;
begin
  Result := -1;
  var Parts := Name.Trim.Split(['.']);
  if Length(Parts) <> 3 then
    Exit;

  var Group, Bit, Common: Integer;
  if not TryStrToInt(Parts[0], Group) or not TryStrToInt(Parts[1], Bit) or not TryStrToInt(Parts[2], Common) then
    Exit;

  if ShiftLCD then
  begin
    if (Group < 0) or (Group > 8) or (Bit < 0) or (Bit > 3) or (Common < 0) or (Common > 1) then
      Exit;

    Result := Group * 8 + Bit * 2 + Common;
  end
  else
  begin
    if (Group < 0) or (Group > 3) or (Bit < 0) or (Bit > 15) or (Common < 0) or (Common > 3) then
      Exit;

    Result := Group * 64 + Bit * 4 + Common;
  end;
end;

function Pixels(Bitmap: TBitmap): TArray<TAlphaColor>;
begin
  var Map: TBitmapData;
  if not Bitmap.Map(TMapAccess.Read, Map) then
    raise EReadError.Create('Cannot read FMX SVG bitmap');

  try
    SetLength(Result, Bitmap.Width * Bitmap.Height);
    for var Y := 0 to Bitmap.Height - 1 do
      for var X := 0 to Bitmap.Width - 1 do
        Result[Y * Bitmap.Width + X] := Map.GetPixel(X, Y);
  finally
    Bitmap.Unmap(Map);
  end;
end;

function DecodeGWBitmap(const Data: TBytes; Width, Height: Integer): TArray<TAlphaColor>;
begin
  var Stream := TBytesStream.Create(Data);
  var Bitmap := TBitmap.Create;
  try
    Bitmap.LoadFromStream(Stream);
    if (Bitmap.Width <= 0) or (Bitmap.Height <= 0) or (Bitmap.Width > Width) or (Bitmap.Height > Height) then
      raise EReadError.Create('Invalid Game & Watch JPEG dimensions');

    var Source := Pixels(Bitmap);
    SetLength(Result, Width * Height);
    for var i := 0 to High(Result) do
      Result[i] := $FF000000;
    var X := (Width - Bitmap.Width) div 2;
    var Y := (Height - Bitmap.Height) div 2;
    for var Row := 0 to Bitmap.Height - 1 do
      Move(Source[Row * Bitmap.Width], Result[(Row + Y) * Width + X], Bitmap.Width * 4);
  finally
    Bitmap.Free;
    Stream.Free;
  end;
end;

function RenderGWArtwork(const Screens: TArray<string>; Layout: Integer; ShiftLCD: Boolean): TGWArtwork;
begin
  Result := Default(TGWArtwork);
  if (Length(Screens) < 1) or (Length(Screens) > 3) then
    raise EReadError.Create('Invalid Game & Watch screen count');

  var Images: TArray<TGWArtwork>;
  SetLength(Images, Length(Screens));
  for var i := 0 to High(Screens) do
  begin
    var Doc := TSvgDocument.Create;
    var Control := TSvgControl.Create(nil);
    var Cache := TSvgBitmapCache.Create;
    try
      Doc.LoadFromString(Screens[i]);
      var W := Doc.Width;
      var H := Doc.Height;
      if Doc.HasViewBox then
      begin
        W := Doc.ViewBox.Width;
        H := Doc.ViewBox.Height;
      end;
      if (W <= 0) or (H <= 0) then
        raise EReadError.Create('SVG has no screen dimensions');

      var Scale := Min(640.0 / W, 480.0 / H);
      Images[i].Width := Max(1, Round(W * Scale));
      Images[i].Height := Max(1, Round(H * Scale));
      Control.SetBounds(0, 0, Images[i].Width, Images[i].Height);
      Control.SVG := Screens[i];
      Cache.EnsureSize(Images[i].Width, Images[i].Height, 1);
      Control.RenderToBitmap(Cache.Bitmap,
        function(Element: TSvgElement): Boolean
        begin
          Result := OutputIndex(Element.OutputName, ShiftLCD) < 0;
        end);
      Images[i].Background := Pixels(Cache.Bitmap);
      for var P := 0 to High(Images[i].Background) do
      begin
        var Color := Images[i].Background[P];
        var Alpha := Color shr 24;

        // Put transparent vector backgrounds on a light LCD substrate.
        Images[i].Background[P] := $FF000000 or
          (TAlphaColor(Min(255, Integer(Color shr 16 and 255) + (255 - Integer(Alpha)) * 224 div 255)) shl 16) or
          (TAlphaColor(Min(255, Integer(Color shr 8 and 255) + (255 - Integer(Alpha)) * 227 div 255)) shl 8) or
          TAlphaColor(Min(255, Integer(Color and 255) + (255 - Integer(Alpha)) * 206 div 255));
      end;
      var Labels: TArray<string> := nil;
      for var Element in Doc.Elements do
        if OutputIndex(Element.OutputName, ShiftLCD) >= 0 then
        begin
          var Seen := False;
          for var LabelName in Labels do
            if LabelName = Element.OutputName then
              Seen := True;
          if not Seen then
            Labels := Labels + [Element.OutputName];
        end;
      for var LabelName in Labels do
      begin
        Control.RenderToBitmap(Cache.Bitmap,
          function(Element: TSvgElement): Boolean
          begin
            Result := Element.OutputName = LabelName;
          end);
        var Source := Pixels(Cache.Bitmap);
        var Left := Images[i].Width;
        var Top := Images[i].Height;
        var Right := -1;
        var Bottom := -1;
        for var Y := 0 to Images[i].Height - 1 do
          for var X := 0 to Images[i].Width - 1 do
            if (Source[Y * Images[i].Width + X] shr 24) > 0 then
            begin
              Left := Min(Left, X);
              Right := Max(Right, X);
              Top := Min(Top, Y);
              Bottom := Max(Bottom, Y);
            end;

        if Right < Left then
          Continue;

        var Layer: TGWLayer;
        Layer.Index := OutputIndex(LabelName, ShiftLCD);
        Layer.X := Left;
        Layer.Y := Top;
        Layer.Width := Right - Left + 1;
        Layer.Height := Bottom - Top + 1;
        SetLength(Layer.Pixels, Layer.Width * Layer.Height);
        for var Y := 0 to Layer.Height - 1 do
          Move(Source[(Top + Y) * Images[i].Width + Left], Layer.Pixels[Y * Layer.Width], Layer.Width * 4);
        Images[i].Layers := Images[i].Layers + [Layer];
      end;
    finally
      Cache.Free;
      Control.Free;
      Doc.Free;
    end;
  end;
  for var Image in Images do
  begin
    if Layout = 1 then
    begin
      Result.Width := Max(Result.Width, Image.Width);
      Inc(Result.Height, Image.Height);
    end
    else
    begin
      Inc(Result.Width, Image.Width);
      Result.Height := Max(Result.Height, Image.Height);
    end;
  end;
  SetLength(Result.Background, Result.Width * Result.Height);
  for var P := 0 to High(Result.Background) do
    Result.Background[P] := $FF202020;
  var X := 0;
  var Y := 0;
  for var Image in Images do
  begin
    var SX := X;
    var SY := Y;
    if Layout = 1 then
      SX := (Result.Width - Image.Width) div 2
    else
      SY := (Result.Height - Image.Height) div 2;
    for var Row := 0 to Image.Height - 1 do
      Move(Image.Background[Row * Image.Width], Result.Background[(SY + Row) * Result.Width + SX], Image.Width * 4);
    for var SourceLayer in Image.Layers do
    begin
      var Layer := SourceLayer;
      Inc(Layer.X, SX);
      Inc(Layer.Y, SY);
      Result.Layers := Result.Layers + [Layer];
    end;
    if Layout = 1 then
      Inc(Y, Image.Height)
    else
      Inc(X, Image.Width);
  end;

  if Length(Result.Layers) = 0 then
    raise EReadError.Create('SVG contains no LCD output labels (x.y.z titles)');
end;

type
  TFMXGWArtworkRenderer = class(TInterfacedObject, IGWArtworkRenderer)
  public
    function Render(const Screens: TArray<string>; Layout: Integer; ShiftLCD: Boolean): TGWArtwork;
    function DecodeBitmap(const Data: TBytes; Width, Height: Integer): TArray<TAlphaColor>;
  end;

function TFMXGWArtworkRenderer.Render(const Screens: TArray<string>; Layout: Integer; ShiftLCD: Boolean): TGWArtwork;
begin
  Result := RenderGWArtwork(Screens, Layout, ShiftLCD);
end;

function TFMXGWArtworkRenderer.DecodeBitmap(const Data: TBytes; Width, Height: Integer): TArray<TAlphaColor>;
begin
  Result := DecodeGWBitmap(Data, Width, Height);
end;

initialization
  SetDefaultGWArtworkRenderer(TFMXGWArtworkRenderer.Create);

finalization
  SetDefaultGWArtworkRenderer(nil);

end.
