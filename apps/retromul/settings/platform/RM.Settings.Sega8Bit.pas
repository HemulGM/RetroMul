unit RM.Settings.Sega8Bit;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder;

type
  // Common TMS9918/PSG controls; each platform supplies its own hardware page.
  TSega8BitSettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Audio(Context: TSettingsPageBuilder); override;
    procedure Hardware(Context: TSettingsPageBuilder); virtual;
    procedure Keyboard(Context: TSettingsPageBuilder; Cassette: Boolean);
  end;

implementation

uses
  FMX.Types, System.SysUtils, RM.Icons;

procedure TSega8BitSettings.Video(Context: TSettingsPageBuilder);
begin
  var RegionDetail := 'Select the video standard and frame timing.';
  if Context.PageId = SETTINGS_PAGE_SMS then
    RegionDetail := 'Auto detects the ROM region; unknown ROMs use NTSC. Restart with Shift+R to apply.';
  if Context.PageId = SETTINGS_PAGE_SMS then
    Context.AddChoice('RowNESregion', 'NTSC / PAL', RegionDetail, 'Video', 'Region', SettingChoices([Translate('Auto'), 'NTSC', 'PAL'], ['Auto', 'NTSC', 'PAL']), 'Auto')
  else
    Context.AddChoice('RowNESregion', 'NTSC / PAL', RegionDetail, 'Video', 'Region', SettingChoices(['NTSC', 'PAL'], ['NTSC', 'PAL']), 'NTSC');
  Hardware(Context);
  Context.Heading('GroupSegaVideo', 'Video layers');
  Context.AddBoolean('RowSegaShowBackground', 'Show background', 'Display the background layer.', 'Video', 'ShowBackground', True, True);
  Context.AddBoolean('RowSegaShowSprites', 'Show sprites', 'Display the sprite layer.', 'Video', 'ShowSprites', True, True);
  Context.AddBoolean('RowSegaRemoveSpriteLimit', 'Remove sprite limit', 'Reduce sprite flicker. Extra sprites may reveal unexpected graphics.', 'Video', 'RemoveSpriteLimit', False, True);
end;

procedure TSega8BitSettings.Audio(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaSound', 'Sound chips');
  for var i := 1 to 4 do
    Context.AddInteger('RowSegaChannel' + IntToStr(i) + 'Volume', 'PSG channel ' + IntToStr(i) + ' volume (%)', 'Channels 1–3 are tones; channel 4 is noise. Zero mutes the channel.', 'Audio', 'Channel' + IntToStr(i) + 'Volume', 100, 100, True);
end;

procedure TSega8BitSettings.Hardware(Context: TSettingsPageBuilder);
begin

end;

procedure TSega8BitSettings.Keyboard(Context: TSettingsPageBuilder; Cassette: Boolean);
begin
  Context.Heading('GroupSegaKeyboard', 'Keyboard and cassette');
  Context.AddBoolean('RowSegaKeyboardEnabled', 'Physical keyboard', 'Send computer key presses to the emulated keyboard. The screen keyboard remains available.', 'Ports', 'KeyboardEnabled', True, True);
  if Cassette then
  begin
    Context.AddPath('RowSegaTapeFile', 'Initial cassette', 'Optional PCM WAV cassette loaded when opening a ROM.', 'Ports', 'TapeFile', '', False, True);
    Context.AddBoolean('RowSegaTapeAutoPlay', 'Play cassette on startup', 'Start playback of the initial cassette automatically.', 'Ports', 'TapeAutoPlay', False, True);
  end;
end;

end.

