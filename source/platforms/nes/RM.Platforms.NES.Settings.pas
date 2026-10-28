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
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    procedure Expansion(Context: TSettingsPageBuilder); override;
    procedure Validate(Draft: TMemIniFile); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  FMX.Types, System.SysUtils, System.Math, RM.Icons;

procedure TNESSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.AddChoice('RowNESregion', 'NES region', 'Frame rate and timing based on the ROM.', 'Video', 'Region',
    SettingChoices([Translate('Automatic'), 'NTSC', 'PAL'], ['Auto', 'NTSC', 'PAL']), 'Auto');
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

