unit RM.Settings.MasterSystem;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TMasterSystemSettings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageBuilder); override;
    procedure Audio(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types, System.SysUtils, RM.Icons;

procedure TMasterSystemSettings.Hardware(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaHardware', 'Sega hardware');
  Context.AddChoice('RowSegaModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model', SettingChoices([Translate('Automatic'), 'Master System',
        'Mark III'], ['auto', 'sms', 'markiii']), 'auto', True);
  Context.AddBoolean('RowSegaBIOSEnabled', 'Use BIOS', 'Run the selected BIOS before the cartridge.', 'Hardware', 'BIOSEnabled', True, True);
  Context.AddPath('RowSegaBIOS', 'BIOS file', 'Optional 8, 16 or 32 KiB Master System BIOS.', 'Hardware', 'BIOS', '', False, True);
  Context.AddChoice('RowSegaMapper', 'Cartridge mapper', 'Auto detects known cartridges. Override for unrecognized ROMs.', 'Cartridge', 'Mapper', SettingChoices([Translate('Automatic'), 'Sega', 'Codemasters', 'Korean', 'Zemina', 'Nemesis',
        'Janggun', 'HiCom', '4 Pak', 'Korean 188', 'Fixed 48 KiB', 'Seojin', '93C46 EEPROM'], ['-1', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11']), '-1', True);
end;

procedure TMasterSystemSettings.Audio(Context: TSettingsPageBuilder);
begin
  inherited;
  Context.AddInteger('RowSegaFMVolume', 'FM volume (%)', 'Adjust FM sound independently of the PSG channels.', 'Audio', 'FMVolume', 100, 100, True);
end;

initialization
  RegisterSettingsProfile('MasterSystem', TMasterSystemSettings);

end.

