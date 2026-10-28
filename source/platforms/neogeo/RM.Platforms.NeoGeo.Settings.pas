unit RM.Platforms.NeoGeo.Settings;

interface

uses
  System.IniFiles, RM.Settings.Platform, RM.Settings.Builder;

type
  TNeoGeoSettings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

procedure TNeoGeoSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupNGHardware', 'Neo Geo hardware');
  if CoreId = 'neogeocd' then
    Context.AddChoice('RowNGModel', 'Machine', 'Applies when opening a game.', 'Hardware', 'Model',
      SettingChoices(['Automatic', 'Neo Geo CD front loader', 'Neo Geo CD top loader', 'Neo Geo CDZ'], ['auto', 'front', 'top', 'cdz']), 'auto', True)
  else
  begin
    Context.AddChoice('RowNGModel', 'Machine', 'Applies when opening a game.', 'Hardware', 'Model',
      SettingChoices(['Automatic', 'Neo Geo MVS', 'Neo Geo AES'], ['auto', 'mvs', 'aes']), 'auto', True);
    Context.AddBoolean('RowNGPAL', 'PAL video', '50 Hz AES video. Applies when opening a game.', 'Hardware', 'PAL', False);
  end;
  Context.AddChoice('RowNGRegion', 'Region', 'Stock BIOS region; UniBIOS uses its own menu.', 'Hardware', 'Region',
    SettingChoices(['Automatic', 'Japan', 'USA', 'Europe'], ['auto', 'japan', 'usa', 'europe']), 'auto', True);
  with Context.AddPath('RowNGBIOS', 'BIOS', 'Choose a BIOS file; empty selects automatically.', 'Hardware', 'BIOS', '', False) do
  begin
    FileFilter := 'Boot ROM (*.bin;*.rom;*.gb)|*.bin;*.rom;*.gb|All files|*.*';
    PickerTitle := 'Choose boot ROM';
  end;
end;

procedure TNeoGeoSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  if CoreId = 'neogeocd' then
  begin
    Context.Heading('GroupNGDrive', 'Neo Geo CD drive');
    Context.AddBoolean('RowNGDiscPresent', 'Disc inserted', 'Insert or remove the mounted image.', 'Drive', 'DiscPresent', True);
    Context.AddBoolean('RowNGTrayOpen', 'Open tray', 'Open or close the drive while the game is running.', 'Drive', 'TrayOpen', False);
    Exit;
  end;
  Context.Heading('GroupNGCard', 'Neo Geo memory card');
  Context.AddBoolean('RowNGCardInserted', 'Card inserted', 'Enable the shared memory card for cartridge games.', 'MemoryCard', 'Inserted', False);
  Context.AddBoolean('RowNGCardReadOnly', 'Write protected', 'Games can read the card but cannot change it.', 'MemoryCard', 'ReadOnly', False);
  with Context.AddPath('RowNGCardPath', 'Memory card file', 'Empty uses one shared card in the save folder.', 'MemoryCard', 'Path', '', False) do
  begin
    FileFilter := 'Cassettes (*.tape)|*.tape|All files|*.*';
    PickerTitle := 'Choose cassette';
  end;
  Context.AddChoice('RowNGCardSize', 'New card capacity', 'Existing card files retain their capacity.', 'MemoryCard', 'Size',
    SettingChoices(['2 KiB', '4 KiB', '6 KiB', '8 KiB', '10 KiB', '12 KiB', '14 KiB', '16 KiB'],
      ['2048', '4096', '6144', '8192', '10240', '12288', '14336', '16384']), '2048', True);
  if Context.Draft.ReadString('Hardware', 'Model', 'auto') <> 'aes' then
  begin
    Context.Heading('GroupNGCabinet', 'MVS cabinet');
    Context.AddBoolean('RowNGSettingsMode', 'System settings at startup', 'F3 adds a service credit; F2 opens the service menu.', 'Cabinet', 'Settings', False);
    Context.AddBoolean('RowNGFreePlay', 'Free play', 'Starts games without coins. Applies when opening a game.', 'Cabinet', 'FreePlay', False);
    Context.AddBoolean('RowNGFreeze', 'Freeze switch', 'Freezes gameplay through the BIOS. Applies when opening a game.', 'Cabinet', 'Freeze', False);
    Context.AddBoolean('RowNGSingleCoin', 'Shared coin chute', 'Shares the first coin input. Applies when opening a game.', 'Cabinet', 'SingleCoin', False);
  end;
end;

procedure TNeoGeoSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.

