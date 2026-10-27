unit RM.Settings.N64;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TN64Settings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types, System.SysUtils, System.Math, RM.Icons;

procedure TN64Settings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupN64Video', 'N64 rendering');
  Context.AddBoolean('RowN64BilinearFiltering', 'Bilinear texture filtering', 'Use the texture filtering requested by the game. Turn off for sharper textures and faster rendering. Applies during play, before output scaling and shaders.', 'Video', 'BilinearFiltering', True, True);
  Context.Heading('GroupN64Cartridge', 'N64 cartridge');
  Context.AddChoice('RowN64SaveType', 'Save memory', 'Auto uses known cartridge IDs and probes FlashRAM commands. Override unknown save formats; reopen the ROM after changing this setting.', 'Cartridge', 'SaveType', SettingChoices([Translate('Auto'), Translate('EEPROM 4 Kbit'), Translate('EEPROM 16 Kbit'),
        Translate('SRAM 32 KiB'), Translate('FlashRAM 128 KiB'), Translate('None')], ['0', '1', '2', '3', '4', '5']), '0', True);
end;

initialization
  RegisterSettingsProfile('N64', TN64Settings);

end.

