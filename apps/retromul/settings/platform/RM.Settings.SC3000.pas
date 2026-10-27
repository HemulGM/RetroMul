unit RM.Settings.SC3000;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TSC3000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types, System.SysUtils, RM.Icons;

procedure TSC3000Settings.Hardware(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaHardware', 'Sega hardware');
  Context.AddChoice('RowSegaModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model', SettingChoices([Translate('Automatic'), 'SC-3000',
        'SC-3000H'], ['auto', 'sc3000', 'sc3000h']), 'auto', True);
end;

procedure TSC3000Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  Keyboard(Context, True);
end;

initialization
  RegisterSettingsProfile('SC3000', TSC3000Settings);

end.

