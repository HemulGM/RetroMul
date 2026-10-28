unit RM.Platforms.ColecoVision.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder;

type
  TColecoSettings = class(TSettingsPlatform)
  public
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Audio(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  System.SysUtils;

function TColecoSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result := inherited PortOptions(Port);
  Result.Labels := ['Controller', 'Super Action Controller', 'Driving Controller', 'Roller Controller', 'Disconnected'];
  Result.Values := ['pad', 'superaction', 'driving', 'roller', 'none'];
  Result.Default := 'pad';
end;

procedure TColecoSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.AddChoice('RowColecoVideoChip', 'Video chip', 'Automatic selects F18A for recognised enhanced cartridges. Changing the video chip requires reopening the game.', 'Video', 'Chip',
    SettingChoices(['Automatic', 'TI TMS9928A / TMS9929A', 'F18A'], ['-1', '0', '1']), '-1');
  Context.AddChoice('RowColecoRegion', 'NTSC / PAL', 'Select the video standard and frame timing.', 'Video', 'Region',
    SettingChoices(['NTSC', 'PAL'], ['NTSC', 'PAL']), 'NTSC');
  Context.AddBoolean('RowColecoBackground', 'Show background', 'Display the background layer.', 'Video', 'ShowBackground', True, True);
  Context.AddBoolean('RowColecoSprites', 'Show sprites', 'Display the sprite layer.', 'Video', 'ShowSprites', True, True);
  Context.AddBoolean('RowColecoSpriteLimit', 'Remove sprite limit', 'Reduce sprite flicker. Extra sprites may reveal unexpected graphics.', 'Video', 'RemoveSpriteLimit', False, True);
end;

procedure TColecoSettings.Audio(Context: TSettingsPageBuilder);
begin
  for var I := 1 to 4 do
    Context.AddInteger('RowColecoChannel' + IntToStr(I), 'PSG channel ' + IntToStr(I) + ' volume (%)',
      'Channels 1–3 are tones; channel 4 is noise. Zero mutes the channel.', 'Audio', 'Channel' + IntToStr(I) + 'Volume', 100, 100, True);
  Context.AddInteger('RowColecoAYVolume', 'AY-3-8910 volume (%)', 'Super Game Module sound volume.', 'Audio', 'AYVolume', 100, 100, True);
end;

procedure TColecoSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.AddBoolean('RowColecoLegacyRAM', 'Legacy expansion RAM', 'Provide 24 KiB RAM for older expanded-memory cartridges. Recognised Donkey Kong Arcade 2005 and GamePack Demo 2 images enable this automatically.', 'Hardware', 'LegacyRAM', False, True);
  Context.AddBoolean('RowColecoSGM', 'Super Game Module', 'Enable 32 KiB expansion RAM and AY-3-8910 sound.', 'Hardware', 'SGM', True, True);
  Context.AddBoolean('RowColecoKeyboard', 'Physical keyboard', 'Keypad 1: 0–9, Q (*), W (#). Keypad 2: numpad 0–9, E (*), R (#).', 'Ports', 'KeyboardEnabled', True, True);
  Context.AddChoice('RowColecoMousePort', 'Mouse controller', 'Route mouse motion to one wheel or spinner. Roller uses both console ports for its two axes. Gamepad analog sticks control each device independently.', 'Ports', 'MousePort',
    SettingChoices(['Controller 1', 'Controller 2'], ['0', '1']), '0', True);
  Context.AddChoice('RowColecoMapper', 'Cartridge mapper', 'Known cartridges select their board and save memory automatically. Override for unrecognised or modified ROMs.', 'Cartridge', 'Mapper',
    SettingChoices(['Automatic', 'Standard', 'MegaCart', 'Activision', 'Activision + 24C02', 'Activision + 24C256',
        'Activision + 24C08', 'Standard + 2 KiB SRAM', 'Opcode OCM', 'Opcode SGC + SST flash'],
      ['-1', '0', '1', '2', '3', '4', '5', '6', '7', '8']), '-1');
end;

end.

