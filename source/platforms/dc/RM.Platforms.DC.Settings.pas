unit RM.Platforms.DC.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TDCSettings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils;

procedure TDCSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupDCSystem', 'System');
  Context.AddChoice('RowDCBoot', 'Boot', 'Built-in high-level boot. Automatic also takes the font of a boot ROM (dc_boot.bin) when found; ' +
    'Boot ROM file starts the console from it.', 'Hardware', 'BIOSMode', SettingChoices(['Built-in (high-level)', 'Automatic', 'Boot ROM file'], ['hle', 'auto', 'external']), 'hle', True);
  Context.AddPath('RowDCBIOS', 'Boot ROM file', 'Optional 2 MiB boot ROM. Without it, dc_boot.bin beside the game or in the dc ROM folder is used.', 'Hardware', 'BIOS', '', False, True);
  Context.AddPath('RowDCFlash', 'Flash file', 'Optional 128 KiB system flash for the boot ROM. Settings are kept in the save folder.', 'Hardware', 'Flash', '', False, True);
  Context.AddChoice('RowDCRegion', 'Region', 'Automatic follows the area symbols of the disc.', 'System', 'Region', SettingChoices(['Automatic', 'Japan', 'North America',
        'Europe'], ['auto', 'japan', 'usa', 'europe']), 'auto', True);
  Context.AddChoice('RowDCLanguage', 'Language', 'System language stored in the console settings.', 'System', 'Language', SettingChoices(['English', 'Japanese', 'German',
        'French', 'Spanish', 'Italian'], ['english', 'japanese', 'german', 'french', 'spanish', 'italian']), 'english', True);
  Context.AddChoice('RowDCCable', 'Video cable', 'Some games offer extra modes for VGA or RGB.', 'System', 'Cable', SettingChoices(['Composite', 'RGB', 'VGA'], ['composite',
        'rgb', 'vga']), 'composite', True);
  Context.AddChoice('RowDCVideo', 'Video standard', 'Automatic uses 50 Hz PAL for European consoles.', 'System', 'Video', SettingChoices(['Automatic', 'NTSC (60 Hz)',

        'PAL (50 Hz)'], ['auto', 'ntsc', 'pal']), 'auto', True);
end;

procedure TDCSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupDCPeripherals', 'Visual Memory and rumble');
  Context.AddBoolean('RowDCShowVMU', 'VMU screen', 'Show the Visual Memory display of the first controller over the picture.', 'Peripherals', 'ShowVMU', False, True);
  Context.AddChoice('RowDCVMUScreen', 'VMU screen position', 'The corner of the picture it is shown in.', 'Peripherals', 'VMUScreen', SettingChoices(['Top left', 'Top right',
        'Bottom left', 'Bottom right'], ['top-left', 'top-right', 'bottom-left', 'bottom-right']), 'top-right', True);
  Context.AddBoolean('RowDCRumble', 'Jump pack rumble', 'Vibrate the gamepad when the game runs the jump pack of the first controller.', 'Peripherals', 'Rumble', True, True);
end;

function TDCSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.SingleLineDescription := True;
  Result.Caption := 'Controller';
  Result.Description := 'Dreamcast controller (with a Visual Memory unit), keyboard, mouse, light gun or nothing. The keyboard takes the host keys; the light gun aims with the mouse pointer and fires with its left button.';
  Result.RowName := 'RowDCControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['Controller + VMU', 'Controller', 'Keyboard', 'Mouse', 'Light gun', 'None'];
  Result.Values := ['pad-vmu', 'pad', 'keyboard', 'mouse', 'lightgun', 'none'];
  // As 'auto' in the core: a VMU in the first controller only.
  Result.Default := 'pad';
  if Port = 0 then
    Result.Default := 'pad-vmu';
end;

procedure TDCSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.
