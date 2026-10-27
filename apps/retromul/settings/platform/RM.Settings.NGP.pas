unit RM.Settings.NGP;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder;

type
  TNGPSettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog;

procedure TNGPSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupNGPSystem', 'Neo Geo Pocket');
  Context.AddPath('RowNGPBIOS', 'BIOS file', 'Optional 64 KiB system ROM override. The monochrome and Color BIOS images are built in.', 'Hardware', 'BIOS', '', False, True);
end;

initialization
  RegisterSettingsProfile('NeoGeoPocket', TNGPSettings);

end.

