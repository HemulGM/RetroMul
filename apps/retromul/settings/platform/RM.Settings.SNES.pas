unit RM.Settings.SNES;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TSNESSettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
  end;

implementation

uses
  RM.Settings.Catalog, System.SysUtils, System.Math, RM.Icons;

procedure TSNESSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.AddBoolean('RowCropoverscan', 'Crop overscan', 'Show the central 224 lines instead of 239.', 'Video', 'CropOverscan', False);
end;

procedure TSNESSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupAdditionalplayers', 'Additional players');
  var Multi := Context.AddBoolean('RowMultitapport2', 'Multitap '#183' port 2', 'Controllers for players 2'#8211'5.', 'Input', 'Multitap2', False);
  Multi.OnChange := Context.OnRebuild;
  Multi := Context.AddBoolean('RowMultitapport1', 'Multitap '#183' port 1', 'Players 1, 6, 7 and 8.', 'Input', 'Multitap1', False);
  Multi.OnChange := Context.OnRebuild;
end;

function TSNESSettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
  if Draft.ReadBool('Input', 'Multitap2', False) then
    Result := 5;
  if Draft.ReadBool('Input', 'Multitap1', False) then
    Result := 8;
end;

initialization
  RegisterSettingsProfile('SNES', TSNESSettings);

end.

