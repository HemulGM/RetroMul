unit RM.Settings.PS2;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TPS2Settings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils;

procedure TPS2Settings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('PS2System', 'System');
  Context.CreateOption('RowPS2BIOSMode', 'BIOS',
    'High-level emulation needs no BIOS. Automatic uses the IOP modules of a BIOS found in the settings, beside the game ' +
    'or in the ps2 folder; External boots a PlayStation 2 BIOS.', sekCombo);
  Context.CreateOption('RowPS2BIOS', 'BIOS file', 'Optional PlayStation 2 BIOS image (4 MiB).', sekPath);
  Context.CreateOption('RowPS2Region', 'Region', 'Automatic follows the disc.', sekCombo);
  Context.CreateOption('RowPS2Video', 'Video standard', 'Automatic follows SYSTEM.CNF of the disc.', sekCombo);
  Context.CreateOption('RowPS2Language', 'Language', 'System language reported to games.', sekCombo);
  for var Port := 1 to 2 do
    Context.CreateOption('RowPS2ControllerPort' + IntToStr(Port), 'Controller',
      'DualShock 2 or disconnected.', sekCombo);
end;

procedure TPS2Settings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupPS2System');
  Context.Combo('RowPS2BIOSMode', 'Hardware', 'BIOSMode', ['High-level', 'Automatic', 'External'],
    ['hle', 'auto', 'external'], 'hle');
  Context.PathEdit('RowPS2BIOS', 'Hardware', 'BIOS', '', False);
  Context.Combo('RowPS2Region', 'System', 'Region', ['Automatic', 'Japan', 'USA', 'Europe'],
    ['auto', 'japan', 'usa', 'europe'], 'auto');
  Context.Combo('RowPS2Video', 'System', 'Video', ['Automatic', 'NTSC (60 Hz)', 'PAL (50 Hz)'], ['auto', 'ntsc', 'pal'],
    'auto');
  Context.Combo('RowPS2Language', 'System', 'Language',
    ['Japanese', 'English', 'French', 'Spanish', 'German', 'Italian', 'Dutch', 'Portuguese', 'Russian'],
    ['japanese', 'english', 'french', 'spanish', 'german', 'italian', 'dutch', 'portuguese', 'russian'], 'english');
end;

function TPS2Settings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
end;

function TPS2Settings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.RowName := 'RowPS2ControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['DualShock 2', 'None'];
  Result.Values := ['pad-analog', 'none'];
  Result.Default := 'pad-analog';
end;

end.
