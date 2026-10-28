unit RM.Platforms.NGP.Settings;

interface

uses
  System.IniFiles, RM.Settings.Platform, RM.Settings.Builder;

type
  TNGPSettings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
  public
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

implementation

procedure TNGPSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupNGPSystem', 'Neo Geo Pocket');
  Context.AddPath('RowNGPBIOS', 'BIOS file', 'Optional 64 KiB system ROM override. The monochrome and Color BIOS images are built in.', 'Hardware', 'BIOS', '', False, True);
end;

procedure TNGPSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.

