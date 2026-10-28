unit RM.Settings.PalettePreview;

interface

uses System.Classes, RM.Settings.Builder, RM.ShaderBitmap;

type
  TSettingsPalettePreviewContext = record
    SystemId: string;
    Palette: TChoiceSetting;
    SelectedIndex: Integer;
  end;

  TPlatformPalettePreview = class
  public
    class function CreatePreview(Owner: TComponent; const Context: TSettingsPalettePreviewContext): TShaderBitmap; virtual;
    class procedure UpdatePreview(Preview: TShaderBitmap; const Context: TSettingsPalettePreviewContext); virtual;
    class procedure DisconnectPreview(Preview: TShaderBitmap; const Context: TSettingsPalettePreviewContext); virtual;
  end;
  TPlatformPalettePreviewClass = class of TPlatformPalettePreview;

procedure RegisterPlatformPalettePreview(const PlatformId: string; Provider: TPlatformPalettePreviewClass);
function TryPlatformPalettePreview(const PlatformId: string; out Provider: TPlatformPalettePreviewClass): Boolean;

implementation

uses System.SysUtils, System.Generics.Collections, System.Generics.Defaults,
  Core.Platforms, FMX.Objects, RM.BitmapShaders;

var Providers: TDictionary<string, TPlatformPalettePreviewClass>;

procedure RegisterPlatformPalettePreview(const PlatformId: string; Provider: TPlatformPalettePreviewClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Provider = nil) then raise EArgumentException.Create('Invalid palette preview provider: ' + PlatformId);
  if Providers.ContainsKey(Id) then raise EArgumentException.Create('Duplicate palette preview provider: ' + Id);
  Providers.Add(Id, Provider);
end;

function TryPlatformPalettePreview(const PlatformId: string; out Provider: TPlatformPalettePreviewClass): Boolean;
begin
  Provider := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Providers.TryGetValue(Id, Provider);
  if not Result then Result := Providers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Provider);
end;

class function TPlatformPalettePreview.CreatePreview(Owner: TComponent; const Context: TSettingsPalettePreviewContext): TShaderBitmap;
begin
  Result := TShaderBitmap.Create(Owner);
  Result.Name := 'ShaderBitmapPalettePreview';
  Result.WrapMode := TImageWrapMode.Fit;
  Result.DisableInterpolation := True;
end;

class procedure TPlatformPalettePreview.UpdatePreview(Preview: TShaderBitmap; const Context: TSettingsPalettePreviewContext);
begin end;

class procedure TPlatformPalettePreview.DisconnectPreview(Preview: TShaderBitmap; const Context: TSettingsPalettePreviewContext);
begin Preview.Mode := TBitmapShaderMode.Original; end;

initialization
  Providers := TDictionary<string, TPlatformPalettePreviewClass>.Create(TIStringComparer.Ordinal);
finalization
  Providers.Free;
end.
