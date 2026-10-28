unit RM.Platforms.N64.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TN64Settings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
  public
    procedure Configuration(Context: TSettingsPageBuilder); override;
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  FMX.Types, System.SysUtils, System.Math, RM.Icons, HW.JIT;

procedure TN64Settings.Configuration(Context: TSettingsPageBuilder);
begin
  // (First on the page; only where there is a code generator: elsewhere
  // always the interpreter.)
  if JitSupported then
  begin
    Context.Heading('GroupN64Emulation', 'N64 emulation');
    Context.AddChoice('RowN64Execution', 'CPU and RSP', 'The recompiler runs the game''s code as native code; the interpreter runs it instruction by instruction. Both give the same emulation; the recompiler is faster. Applies during play.', 'Emulation', 'Execution', SettingChoices([Translate('Recompiler (JIT)'), Translate('Interpreter')], ['jit', 'interpreter']), 'jit', True);
  end;
end;
procedure TN64Settings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupN64Video', 'N64 rendering');
  Context.AddBoolean('RowN64BilinearFiltering', 'Bilinear texture filtering', 'Use the texture filtering requested by the game. Turn off for sharper textures and faster rendering. Applies during play, before output scaling and shaders.', 'Video', 'BilinearFiltering', True, True);
  Context.Heading('GroupN64Cartridge', 'N64 cartridge');
  Context.AddChoice('RowN64SaveType', 'Save memory', 'Auto uses known cartridge IDs and probes FlashRAM commands. Override unknown save formats; reopen the ROM after changing this setting.', 'Cartridge', 'SaveType', SettingChoices([Translate('Auto'), Translate('EEPROM 4 Kbit'), Translate('EEPROM 16 Kbit'),
        Translate('SRAM 32 KiB'), Translate('FlashRAM 128 KiB'), Translate('None')], ['0', '1', '2', '3', '4', '5']), '0', True);
end;

procedure TN64Settings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.
