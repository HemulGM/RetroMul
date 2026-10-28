unit RM.Platforms.GB.PalettePreview;

interface

uses
  System.Classes, RM.Settings.PalettePreview, RM.ShaderBitmap;

type
  TGameBoyPalettePreview = class(TPlatformPalettePreview)
  public
    class function CreatePreview(Owner: TComponent; const Context: TSettingsPalettePreviewContext): TShaderBitmap; override;
    class procedure UpdatePreview(Preview: TShaderBitmap; const Context: TSettingsPalettePreviewContext); override;
  end;

implementation

uses
  System.Math, FMX.Graphics, FMX.Objects, GB.Palettes;

type
  TGameBoyPaletteBitmap = class(TShaderBitmap)
  private
    FPaletteIndex: Integer;
    procedure SetPaletteIndex(Value: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    property PaletteIndex: Integer read FPaletteIndex write SetPaletteIndex;
  end;

constructor TGameBoyPaletteBitmap.Create(AOwner: TComponent);
begin
  inherited;
  WrapMode := TImageWrapMode.Fit;
  DisableInterpolation := True;
  FPaletteIndex := -1;
  SetPaletteIndex(0);
end;

procedure TGameBoyPaletteBitmap.SetPaletteIndex(Value: Integer);
begin
  Value := EnsureRange(Value, 0, SCREEN_PALETTE_COUNT - 1);
  if Value = FPaletteIndex then
    Exit;
  Bitmap.SetSize(160, 144);
  var Data: TBitmapData;
  if not Bitmap.Map(TMapAccess.Write, Data) then
    Exit;
  try
    var Palette := ScreenPalettes[Value];
    for var PixelY := 0 to Bitmap.Height - 1 do
      for var PixelX := 0 to Bitmap.Width - 1 do
      begin
        var X := PixelX * 32 div Bitmap.Width;
        var Y := PixelY * 29 div Bitmap.Height;
        var Shade := 0;
        if Y > 12 + Abs(16 - X) div 2 then
          Shade := 1;
        if Y > 19 then
          Shade := 2;
        if (Y = 20) or ((Y > 20) and ((X + Y) mod 4 = 0)) then
          Shade := 3;
        if (X in [4..7]) and (Y in [9..16]) then
          Shade := 2;
        if (X = 6) and (Y in [16..19]) then
          Shade := 3;
        if (X in [14..15]) and (Y in [16..19]) then
          Shade := 3;
        if (Y in [4..5]) and (X in [18..22]) then
          Shade := 0;
        Data.SetPixel(PixelX, PixelY, Palette.Colors[Shade]);
      end;
    FPaletteIndex := Value;
  finally
    Bitmap.Unmap(Data);
  end;
  ResetHistory;
end;

class function TGameBoyPalettePreview.CreatePreview(Owner: TComponent; const Context: TSettingsPalettePreviewContext): TShaderBitmap;
begin
  Result := TGameBoyPaletteBitmap.Create(Owner);
  Result.Name := 'GameBoyPaletteBitmapPalettePreview';
end;

class procedure TGameBoyPalettePreview.UpdatePreview(Preview: TShaderBitmap; const Context: TSettingsPalettePreviewContext);
begin
  TGameBoyPaletteBitmap(Preview).PaletteIndex := Context.SelectedIndex;
end;

end.

