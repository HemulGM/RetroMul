unit RM.Platforms.Lynx.Settings;

interface

uses
  System.IniFiles, RM.Settings.Platform, RM.Settings.Builder;

type
  TLynxSettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

implementation

procedure TLynxSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupLynxSystem', 'Atari Lynx');
  Context.AddPath('RowLynxBIOS', 'BIOS file',
    'Optional 512-byte boot ROM override. The Lynx BIOS is built in.',
    'Hardware', 'BIOS', '', False, True);
  Context.AddChoice('RowLynxRotation', 'Screen orientation',
    'Rotate the display and directional controls for games played vertically.',
    'Video', 'Rotation', [TSettingsChoiceItem.Make('Automatic', '-1'),
      TSettingsChoiceItem.Make('Landscape', '0'), TSettingsChoiceItem.Make('Rotate left', '1'),
      TSettingsChoiceItem.Make('Rotate right', '2')], '-1');
end;

end.

