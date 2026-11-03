unit RM.Platforms.NDS.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder;

type
  TNDSSettings = class(TSettingsPlatform)
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

implementation

procedure TNDSSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupNDSDisplay', 'Nintendo DS screens');
  Context.AddChoice('RowNDSScreenLayout', 'Screen arrangement', 'Place the upper screen above or to the left of the touch screen.',
    'Video', 'ScreenLayout', SettingChoices(['Stacked', 'Side by side'], ['stacked', 'side-by-side']), 'stacked', True);
  var Gap := Context.AddSlider('RowNDSScreenGap', 'Screen gap', 'Space between the screens, scaled with the picture.',
    'Video', 'ScreenGap', 0, 0, 128, 1, True);
  Gap.UnitCaption := 'px';
  Context.Heading('GroupNDSCartridge', 'Nintendo DS cartridge');
  Context.AddChoice('RowNDSSaveSize', 'Save memory', 'Auto uses known cartridge hardware and defaults to 64 KiB for unlisted games. Existing save files retain their size. Restart emulation after changing this setting.',
    'Cartridge', 'SaveSize', SettingChoices(['Auto', '512 bytes', '8 KiB', '64 KiB', '128 KiB', '256 KiB', '512 KiB', '1 MiB', '8 MiB'],
      ['0', '512', '8192', '65536', '131072', '262144', '524288', '1048576', '8388608']), '0', True);
end;

end.

