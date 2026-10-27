unit RM.Settings.Multivision;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TMultivisionSettings = class(TSega8BitSettings)
  public
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, System.SysUtils, RM.Icons;

procedure TMultivisionSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Keyboard(Context, False);
end;

initialization
  RegisterSettingsProfile('Multivision', TMultivisionSettings);

end.

