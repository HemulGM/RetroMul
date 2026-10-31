unit RM.Platforms.PS2.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TPS2Settings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  RM.Settings.Catalog, System.SysUtils, HW.JIT;

procedure TPS2Settings.Video(Context: TSettingsPageBuilder);
begin
  if JitSupported then
  begin
    Context.Heading('GroupPS2Execution', 'PS2 emulation');
    Context.AddChoice('RowPS2Execution', 'CPU/VU execution', 'Experimental block recompilers for the EE and for VU1 and VU0 micro programs with native pipeline bookkeeping, chained blocks and exact SIMD arithmetic. Uncommon operations retain interpreter helpers. Applies during play. Speed depends on the game.',
      'Emulation', 'Execution', SettingChoices(['Interpreter', 'Recompiler (JIT, experimental)'],
      ['interpreter', 'jit']), 'interpreter', True);
  end;
  Context.Heading('GroupPS2Rendering', 'PS2 rendering');
  Context.AddChoice('RowPS2Renderer', 'Graphics Synthesizer', 'Software rendering or experimental Vulkan compute for 32/24-bit targets, direct/palettized textures and mipmapping. Unsupported draws and devices use the CPU. Vulkan may be slower. Applies during play.', 'Video', 'Renderer', SettingChoices(['Software, multithreaded', 'Software, one thread', 'Vulkan (experimental)'], ['threads', 'single', 'vulkan']), 'threads', True);
  Context.Heading('GroupPS2System', 'System');
  Context.AddChoice('RowPS2BIOSMode', 'BIOS', 'High-level emulation needs no BIOS. Automatic boots a PlayStation 2 BIOS found in the settings, beside the game, in the ps2 folder or in the bios folder, otherwise it uses high-level emulation; External always boots a BIOS. A BIOS boot starts discs through the console''s own start-up and logos and keeps the console''s settings in the save folder.', 'Hardware', 'BIOSMode', SettingChoices(['High-level', 'Automatic', 'External'], ['hle', 'auto', 'external']), 'hle');
  Context.AddPath('RowPS2BIOS', 'BIOS file', 'Optional PlayStation 2 BIOS image (4 MiB). An .nvm (console EEPROM) and a .mec (MECHACON version) file beside it are used when present.', 'Hardware', 'BIOS', '', False);
  Context.AddChoice('RowPS2Region', 'Region', 'Automatic follows the disc.', 'System', 'Region', SettingChoices(['Automatic', 'Japan', 'USA', 'Europe'], ['auto', 'japan', 'usa', 'europe']), 'auto');
  Context.AddChoice('RowPS2Video', 'Video standard', 'Automatic follows SYSTEM.CNF of the disc.', 'System', 'Video', SettingChoices(['Automatic', 'NTSC (60 Hz)', 'PAL (50 Hz)'], ['auto', 'ntsc', 'pal']), 'auto');
  Context.AddChoice('RowPS2Language', 'Language', 'System language reported to games. Automatic is Japanese for the Japan region and English elsewhere; Russian is reported the way consoles with extended languages do.', 'System', 'Language', SettingChoices(['Automatic', 'Japanese', 'English', 'French', 'Spanish', 'German', 'Italian', 'Dutch', 'Portuguese', 'Russian'], ['auto', 'japanese', 'english', 'french', 'spanish', 'german', 'italian', 'dutch', 'portuguese', 'russian']), 'auto');
end;

function TPS2Settings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
end;

function TPS2Settings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.SingleLineDescription := False;
  Result.Caption := 'Controller';
  Result.Description := 'DualShock 2 or disconnected.';
  Result.RowName := 'RowPS2ControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['DualShock 2', 'None'];
  Result.Values := ['pad-analog', 'none'];
  Result.Default := 'pad-analog';
end;

end.
