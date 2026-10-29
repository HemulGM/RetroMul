unit RM.Platforms.NES.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TNESSettings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Audio(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    procedure Expansion(Context: TSettingsPageBuilder); override;
    procedure Validate(Draft: TMemIniFile); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  FMX.Types, System.SysUtils, System.Math, RM.Icons, NES.Options, Core.Storage,
  RM.Dialogs;

procedure TNESSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.AddChoice('RowNESregion', 'NES region', 'Frame rate and timing based on the ROM. Famicom Disk System always uses NTSC.', 'Video', 'Region',
    SettingChoices([Translate('Automatic'), 'NTSC', 'PAL', 'Dendy'], ['Auto', 'NTSC', 'PAL', 'Dendy']), 'Auto').ApplyMode := TSettingsApplyMode.OnNextLoad;

  Context.AddBoolean('RowNesRemoveSpriteLimit', 'Remove sprite limit',
    'Display more than eight sprites per scanline to reduce flicker. Some games rely on the original limit.',
    'Video', 'RemoveSpriteLimit', False);
  with Context.AddPath('RowNesPaletteFile', 'Custom NES palette', 'Optional RGB .pal file: 192 bytes for 64 colors or 1536 bytes including emphasis colors. Leave blank for the standard palette. Applies when reopening a game; VS palettes stay automatic.', 'Video', 'PaletteFile', '', False) do
  begin
    ApplyMode := TSettingsApplyMode.OnNextLoad;
    FileFilter := 'NES palettes (*.pal)|*.pal|All files|*.*';
    PickerTitle := 'Choose NES palette';
  end;
  Context.Heading('GroupNesOverscan', 'Overscan cropping', True);
  Context.AddInteger('RowNesCropTop', 'Crop top', 'Pixels to hide at the top edge. The full image is still emulated.', 'Video', 'CropTop', 0, 16);
  Context.AddInteger('RowNesCropBottom', 'Crop bottom', 'Pixels to hide at the bottom edge. The full image is still emulated.', 'Video', 'CropBottom', 0, 16);
  Context.AddInteger('RowNesCropLeft', 'Crop left', 'Pixels to hide at the left edge. Zapper aiming follows the cropped image.', 'Video', 'CropLeft', 0, 16);
  Context.AddInteger('RowNesCropRight', 'Crop right', 'Pixels to hide at the right edge. Zapper aiming follows the cropped image.', 'Video', 'CropRight', 0, 16);
end;

procedure TNESSettings.Audio(Context: TSettingsPageBuilder);
const
  Captions: array[0..5] of string = ('Pulse 1', 'Pulse 2', 'Triangle channel', 'Noise', 'DMC', 'Cartridge expansion audio');
begin
  Context.Heading('GroupNesChannelMixer', 'NES channel mixer', True);
  for var I := 0 to High(NES_CHANNEL_KEYS) do
    with Context.AddSlider('RowNes' + NES_CHANNEL_KEYS[I], Captions[I], '100% keeps the original level; 0% mutes this channel. Boosting above 100% may clip.', 'Audio', NES_CHANNEL_KEYS[I], 100, 0, 200, 1, True) do
      UnitCaption := '%';
  Context.Heading('GroupNesSoundCompatibility', 'Sound compatibility', True);
  Context.AddBoolean('RowNesSwapDutyCycles', 'Swap pulse duty cycles',
    'Reproduce the swapped 25% and 50% pulse widths of some Famicom clones.', 'Audio', 'SwapDutyCycles', False);
  Context.AddBoolean('RowNesSilenceUltrasonicTriangle', 'Silence ultrasonic triangle',
    'Reduce triangle-channel clicks at the two highest frequencies. This changes the original sound.',
    'Audio', 'SilenceUltrasonicTriangle', False);
  Context.AddBoolean('RowNesDisableNoiseMode', 'Early Famicom noise',
    'Disable the short noise mode, as on early Famicom audio chips.', 'Audio', 'DisableNoiseMode', False);
end;

procedure TNESSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupAdditionalplayers', 'Additional players', True);
  var FourScore := Context.AddBoolean('RowFourScore', 'Four Score',
    'Extra controllers for players 3 and 4; incompatible with Zapper,' + ' Power Pad and Miracle Piano.', 'Input',
    'FourScore', False);
  FourScore.OnChange := Context.OnRebuild;
end;

procedure TNESSettings.Expansion(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupFamicomDiskSystem', 'Famicom Disk System', True);
  with Context.AddPath('RowFdsBIOS', 'FDS BIOS', 'Optional 8 KiB BIOS override. Leave blank for automatic selection. BIOS changes apply when a game is reopened.', 'FDS', 'BIOSFile', '', False) do
  begin
    ApplyMode := TSettingsApplyMode.OnNextLoad;
    FileFilter := 'BIOS files (*.rom;*.bin)|*.rom;*.bin|All files|*.*';
    PickerTitle := 'Choose FDS BIOS';
  end;
  Context.AddBoolean('RowFdsWriteProtected', 'Write protect disks',
    'Prevent the emulated drive from changing disk contents. Applies immediately.', 'FDS', 'WriteProtected', False);
  Context.AddBoolean('RowFdsAutoLoadDisk', 'Insert side A at startup',
    'Start with disk 1, side A inserted. Disable to show the BIOS insert-disk screen. Applies when reopening a game.',
    'FDS', 'AutoLoadDisk', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddBoolean('RowFdsAutoSwitchSides', 'Automatically switch disk sides',
    'Select the side requested by the standard FDS BIOS. Manual changes pause automation until reset or until this option is turned off and on.',
    'FDS', 'AutoSwitchSides', True);
  var FastLoad := Context.AddBoolean('RowFdsFastForwardOnLoad', 'Fast-forward disk loading',
    'Run faster while the drive reads. Hardware timing is preserved; sound is muted during fast loading.',
    'FDS', 'FastForwardOnLoad', False);
  FastLoad.OnChange := Context.OnRebuild;
  Context.AddChoice('RowFdsLoadSpeed', 'Disk loading speed',
    'Target speed during disk reads. Actual speed depends on your computer.', 'FDS', 'LoadSpeed',
    SettingChoices(['2×', '4×', '8×'], ['2', '4', '8']), '4').EnabledWhen := FastLoad.IsTrue();
  Context.AddChoice('RowFdsChangeDelay', 'Disk change delay',
    'How long the disk remains absent when changing sides. Applies to the next insertion.',
    'FDS', 'ChangeDelayMs', SettingChoices(['0.5 s', '1 s', '2 s'], ['500', '1000', '2000']), '1000');
  with Context.AddSlider('RowFdsAudioVolume', 'FDS audio volume', 'Adjust the FDS wavetable channel independently of NES audio. 100% keeps the original level.', 'FDS', 'Volume', 100, 0, 200, 1, True) do
    UnitCaption := '%';
  Context.Heading('GroupFamicomexpansionport', 'Famicom expansion port', True);
  var Expansion := Context.AddChoice('RowConnecteddevice', 'Connected device', 'Automatic uses the ROM metadata.',
    'Ports', 'Expansion',
    SettingChoices(['Automatic', 'None', 'Subor keyboard', 'Famicom keyboard', 'Data Recorder'], ['auto', 'none', 'subor', 'famicom', 'recorder']), 'auto');
  Expansion.OnChange := Context.OnRebuild;
  var Device := Context.Draft.ReadString('Ports', 'Expansion', 'auto');
  if (Device = 'subor') or (Device = 'famicom') then
  begin
    Context.AddBoolean('RowPhysicalkeyboard', 'Physical keyboard', 'An on-screen keyboard is available during gameplay.',
      'Ports', 'KeyboardEnabled', True);
    Context.BuildBindings(4, Device);
  end;
  if (Device = 'recorder') or (Device = 'famicom') then
    with Context.AddPath('RowInitialcassette', 'Initial cassette', 'Leave blank to use the current game'#39's cassette.', 'Ports', 'TapeFile', '', False) do
    begin
      FileFilter := 'Cassettes (*.tape)|*.tape|All files|*.*';
      PickerTitle := 'Choose cassette';
    end;
end;

function TNESSettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
  if Draft.ReadBool('Input', 'FourScore', False) then
    Result := 4;
end;

function TNESSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result := inherited PortOptions(Port);
  Result.Labels := nil;
  Result.Default := 'auto';
  case Port of
    0:
      begin
        Result.Caption := 'Connected device';
        Result.Description := 'Automatic keeps the device selected by the ROM.';
        Result.RowName := 'RowConnecteddevice10Port1';
        Result.Labels := ['Automatic', 'Gamepad', 'Dendy · Turbo', 'Miracle Piano', 'None'];
        Result.Values := ['auto', 'pad', 'paddendy', 'piano', 'none'];
      end;
    1:
      begin
        Result.Caption := 'Connected device';
        Result.Description := 'Zapper and Power Pad use the second port.';
        Result.RowName := 'RowConnecteddevice18Port2';
        Result.Labels := ['Automatic', 'Gamepad', 'Dendy · Turbo', 'Zapper', 'Power Pad', 'None'];
        Result.Values := ['auto', 'pad', 'paddendy', 'zapper', 'powerpad', 'none'];
      end;
  else
    Result.Labels := ['Gamepad', 'Dendy · Turbo', 'None'];
    Result.Values := ['pad', 'paddendy', 'none'];
    Result.Default := 'pad';
  end;
end;

procedure TNESSettings.Validate(Draft: TMemIniFile);
begin
  // Validate before the settings dialog persists a broken palette path.
  try
    LoadNesPalette(TStorage.Default, Draft.ReadString('Video', 'PaletteFile', ''));
  except
    on E: Exception do
      raise Exception.Create(TranslateCoreMessage(E.Message));
  end;
  if Draft.ReadBool('Input', 'FourScore', False) and
    ((Draft.ReadString('Ports', 'Port1', 'auto') = 'piano') or
    (Draft.ReadString('Ports', 'Port2', 'auto') = 'zapper') or
    (Draft.ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
    raise Exception.Create(Translate('Disable Four Score to use Zapper, Power Pad or Miracle Piano.'));

  if (Draft.ReadString('Ports', 'Port1', 'auto') = 'piano') and
    ((Draft.ReadString('Ports', 'Port2', 'auto') = 'zapper') or
    (Draft.ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
    raise Exception.Create(Translate('Miracle Piano uses both ports. Disconnect Zapper or Power Pad.'));
end;

procedure TNESSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.

