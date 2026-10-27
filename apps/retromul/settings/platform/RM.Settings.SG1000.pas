unit RM.Settings.SG1000;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TSG1000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types, System.SysUtils, RM.Icons;

procedure TSG1000Settings.Hardware(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaHardware', 'Sega hardware');
  Context.AddChoice('RowSegaModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model', SettingChoices([Translate('Automatic'), 'SG-1000',
        'SG-1000 II / SK-1100'], ['auto', 'sg1000', 'sg1000ii']), 'auto', True);
end;

procedure TSG1000Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  if SameText(Context.Draft.ReadString('Hardware', 'Model', 'auto'), 'sg1000ii') then
    Keyboard(Context, True);
end;

initialization
  RegisterSettingsProfile('SG1000', TSG1000Settings);

end.

