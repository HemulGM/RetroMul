unit RM.Settings.Catalog;

interface

uses
  RM.Settings.Platform;

var
  SettingsPlatforms: TSettingsPlatformRegistry;
  // Compatibility lookup tables, generated from the registry. Index zero is Main.
  SettingsCoreIds, SettingsPageNames: TArray<string>;
  SettingsCoreOrder: TArray<Integer>;

implementation

uses
  Core.Platforms, System.SysUtils, System.Generics.Collections, RM.Gamepad,
  RM.Settings.GameBoy, RM.Settings.GBA, RM.Settings.NES, RM.Settings.SNES,
  RM.Settings.N64, RM.Settings.MegaDrive, RM.Settings.Sega8Bit,
  RM.Settings.GameBoyColor, RM.Settings.SG1000, RM.Settings.SC3000,
  RM.Settings.SF7000, RM.Settings.Multivision, RM.Settings.Saturn,
  RM.Settings.PCE, RM.Settings.MasterSystem, RM.Settings.GameGear,
  RM.Settings.NeoGeo, RM.Settings.NGP, RM.Settings.ZX, RM.Settings.PS1, RM.Settings.PS2;

type
  TSettingsPlatformClass = class of TSettingsPlatform;

procedure RegisterPlatforms;
begin
  // Bind UI implementations by profile; page IDs and artwork live in RM.Platforms.Presentation.
  var Classes := TDictionary<string, TSettingsPlatformClass>.Create;
  try
    Classes.Add('', TSettingsPlatform);
    Classes.Add('ZXSpectrum', TZXSettings);
    Classes.Add('CPS1', TSettingsPlatform);
    Classes.Add('CPS2', TSettingsPlatform);
    Classes.Add('CPS3', TSettingsPlatform);
    Classes.Add('GameBoy', TGameBoySettings);
    Classes.Add('GameBoyColor', TGameBoyColorSettings);
    Classes.Add('GBA', TGBASettings);
    Classes.Add('NES', TNESSettings);
    Classes.Add('SNES', TSNESSettings);
    Classes.Add('N64', TN64Settings);
    Classes.Add('Saturn', TSaturnSettings);
    Classes.Add('PS1', TPS1Settings);
    Classes.Add('PS2', TPS2Settings);
    Classes.Add('MegaDrive', TMegaDriveSettings);
    Classes.Add('SG1000', TSG1000Settings);
    Classes.Add('SC3000', TSC3000Settings);
    Classes.Add('SF7000', TSF7000Settings);
    Classes.Add('MasterSystem', TMasterSystemSettings);
    Classes.Add('GameGear', TGameGearSettings);
    Classes.Add('Multivision', TMultivisionSettings);
    Classes.Add('NeoGeo', TNeoGeoSettings);
    Classes.Add('NeoGeoPocket', TNGPSettings);
    Classes.Add('PCE', TPCESettings);
    for var Info in TPlatformRegistry.All do
    begin
      // Library variants may share one canonical settings page.
      if not SameText(Info.Id, Info.SettingsCoreId) then
        Continue;

      var PageClass: TSettingsPlatformClass;
      if not Classes.TryGetValue(Info.SettingsProfile, PageClass) then
        raise EInvalidOpException.Create('Unknown settings profile: ' + Info.SettingsProfile);

      SettingsPlatforms.Add(PageClass.Create(Info));
    end;
  finally
    Classes.Free;
  end;
  SetLength(SettingsCoreIds, SettingsPlatforms.MaxPageId + 1);
  SetLength(SettingsPageNames, Length(SettingsCoreIds));
  SettingsPageNames[0] := 'Main';
  var Ordered := SettingsPlatforms.Matching('');
  SetLength(SettingsCoreOrder, Length(Ordered));
  for var i := 0 to High(Ordered) do
  begin
    var platform := Ordered[i];
    SettingsCoreOrder[i] := platform.PageId;
    SettingsCoreIds[platform.PageId] := platform.CoreId;
    SettingsPageNames[platform.PageId] := platform.Name;
  end;
end;

initialization
  SettingsPlatforms := TSettingsPlatformRegistry.Create;
  RegisterPlatforms;

finalization
  SettingsPlatforms.Free;

end.

