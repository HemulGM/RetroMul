unit RM.Settings.GameBoyColor;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Settings.GameBoy.Base;

type
  TGameBoyColorSettings = class(TGameBoySettingsBase)
  public
    procedure Display(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog;

procedure TGameBoyColorSettings.Display(Context: TSettingsPageBuilder);
begin
  Context.AddBoolean('RowLCDcolors', 'LCD colors', 'Approximate Game Boy Color color reproduction.', 'Video', 'ColorCorrection', False);
end;

initialization
  RegisterSettingsProfile('GameBoyColor', TGameBoyColorSettings);

end.

