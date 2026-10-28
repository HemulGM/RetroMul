unit RM.Platforms.MD.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TMegaDriveSettings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
  public
    procedure Audio(Context: TSettingsPageBuilder); override;
    procedure Expansion(Context: TSettingsPageBuilder); override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils, System.Math, RM.Icons;

procedure TMegaDriveSettings.Audio(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupMDCDAudio', 'Sega CD');
  Context.AddInteger('RowMDCDAudio', 'Sega CD volume (%)', 'CD audio tracks and the Sega CD sound chip.', 'SegaCD', 'Volume', 100, 100);
  Context.Heading('GroupMD32XAudio', 'Sega 32X');
  Context.AddInteger('RowMD32XAudio', '32X PWM volume (%)', 'Sound from the 32X expansion, including Sega CD + 32X games.', 'Sega32X', 'Volume', 100, 100);
end;

procedure TMegaDriveSettings.Expansion(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupMDCDInput', 'Sega CD');
  Context.AddBoolean('RowMDMicrophone', 'Microphone', 'Karaoke audio input. A microphone device source must be connecte' + 'd.', 'SegaCD', 'MicrophoneEnabled', False);
end;

function TMegaDriveSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.SingleLineDescription := False;
  Result.Caption := 'Connected device';
  Result.Description := 'Controller protocol for this port.';
  Result.RowName := 'RowConnecteddevice2Port' + IntToStr(Port + 1);
  Result.Labels := ['Gamepad · 6 buttons', 'Gamepad · 3 buttons', 'None'];
  Result.Values := ['pad6', 'pad3', 'none'];
  Result.Default := 'pad6';
end;

procedure TMegaDriveSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
  Draft.DeleteKey('SegaCD', 'AudioEnabled');
  Draft.DeleteKey('Sega32X', 'AudioEnabled');
end;

end.
