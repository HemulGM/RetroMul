unit RM.Platforms.GBC.Settings;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Platforms.GB.Settings;

type
  TGameBoyColorSettings = class(TGameBoySettingsBase)
  public
    procedure Display(Context: TSettingsPageBuilder); override;
  end;

implementation

procedure TGameBoyColorSettings.Display(Context: TSettingsPageBuilder);
begin
  Context.AddBoolean('RowLCDcolors', 'LCD colors', 'Approximate Game Boy Color color reproduction.', 'Video', 'ColorCorrection', False);
end;

end.

