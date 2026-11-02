unit RM.Platforms.WS.Settings;

interface

uses
  System.IniFiles, RM.Settings.Platform, RM.Settings.Builder;

type
  TWSSettings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Audio(Context: TSettingsPageBuilder); override;
  end;

implementation

procedure TWSSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupWSHardware', 'WonderSwan hardware');
  Context.AddChoice('RowWSModel', 'Console model',
    'Automatic uses the cartridge header and the .wsc extension.', 'Hardware', 'Model',
    [TSettingsChoiceItem.Make('Automatic', '0'), TSettingsChoiceItem.Make('WonderSwan', '1'),
      TSettingsChoiceItem.Make('WonderSwan Color', '2')], '0').ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddPath('RowWSBootROM', 'Boot ROM file',
    'Optional 4 KiB WonderSwan or 8 KiB Color boot ROM. Leave empty for direct cartridge startup.',
    'Hardware', 'BIOS', '', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowWSOrientation', 'Screen orientation',
    'Automatic follows the cartridge header. Vertical mode rotates the display and both directional button groups.',
    'Video', 'Orientation', [TSettingsChoiceItem.Make('Automatic', '0'),
      TSettingsChoiceItem.Make('Horizontal', '1'), TSettingsChoiceItem.Make('Vertical', '2')], '0');
  Context.AddChoice('RowWSMonoPalette', 'Monochrome palette',
    'Choose the LCD tint used by monochrome games.', 'Video', 'MonoPalette',
    [TSettingsChoiceItem.Make('Grayscale', '0'), TSettingsChoiceItem.Make('Warm LCD', '1'),
      TSettingsChoiceItem.Make('Cool LCD', '2')], '0');
end;

procedure TWSSettings.Audio(Context: TSettingsPageBuilder);
begin
  inherited;
  Context.Heading('GroupWSAudio', 'WonderSwan sound');
  Context.AddBoolean('RowWSHeadphones', 'Headphones connected',
    'Use stereo headphone output. Disable to emulate the built-in mono speaker.',
    'Audio', 'Headphones', True, True);
end;

procedure TWSSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.

