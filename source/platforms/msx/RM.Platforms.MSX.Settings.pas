unit RM.Platforms.MSX.Settings;

interface

uses
  System.IniFiles, RM.Settings.Platform, RM.Settings.Builder;

type
  TMSXSettings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  System.SysUtils;

procedure TMSXSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupMSXHardware', 'MSX hardware');
  Context.AddBoolean('RowMSXOriginalBIOS', 'Original BIOS with BASIC', 'Use the built-in machine BIOS for cartridges too. Disk and tape images select it automatically.', 'Hardware', 'OriginalBIOS', False, True);
  Context.AddPath('RowMSXBIOS', 'BIOS file', 'Optional 32 KiB BIOS override. Built-in firmware is used when empty. Reopen the game to apply.', 'Hardware', 'BIOS', '', False, True);
  Context.AddPath('RowMSXSubROM', 'Sub-ROM file', 'A matching 16 KiB sub-ROM is required with an external MSX2 or MSX2+ BIOS.', 'Hardware', 'SubROM', '', False, True);
  if SameText(CoreId, 'MSX1') then
    Context.AddChoice('RowMSXVDPChip', 'Video chip', 'Select the VDP fitted to the machine. Automatic follows the system and BIOS timing. Reopen the game to apply.', 'Hardware', 'VDPChip', SettingChoices(['Automatic', 'TI TMS9918A (60 Hz)', 'TI TMS9929A (50 Hz)', 'TI TMS9118 (60 Hz)',
          'TI TMS9129 (50 Hz)', 'Toshiba T7937A (60 Hz)', 'Toshiba T6950 (50 Hz)'], ['0', '1', '2', '3', '4', '5', '6']), '0', True)
  else if SameText(CoreId, 'MSX2') then
    Context.AddChoice('RowMSXVDPChip', 'Video chip', 'Select the VDP fitted to the machine. Automatic follows the system and BIOS timing. Reopen the game to apply.', 'Hardware', 'VDPChip', SettingChoices(['Automatic', 'Yamaha V9938 A', 'Yamaha V9938 B', 'Yamaha V9938 C', 'Yamaha V9958 upgrade'], ['0', '7', '8', '9', '10']), '0', True)
  else
    Context.AddChoice('RowMSXVDPChip', 'Video chip', 'Select the VDP fitted to the machine. Automatic follows the system and BIOS timing. Reopen the game to apply.', 'Hardware', 'VDPChip', SettingChoices(['Automatic', 'Yamaha V9958'], ['0', '10']), '0', True);
  if not SameText(CoreId, 'MSX1') then
    Context.AddBoolean('RowMSXVDPWait', 'Connect VDP WAIT to CPU', 'For V9958 machines with WAIT wired to the CPU. On MSX2, select the V9958 upgrade first. Reopen the game to apply.', 'Hardware', 'VDPWaitConnected', False, True);
  Context.AddChoice('RowMSXMapper', 'Cartridge mapper', 'Automatic uses known ROM hashes and bank-switch instructions. Restart to apply.', 'Cartridge', 'Mapper', SettingChoices(['Automatic', 'Plain ROM', 'ASCII8', 'ASCII16', 'Konami', 'Konami SCC',
        'ASCII8 + SRAM', 'ASCII16 + SRAM', 'R-Type', 'Game Master 2', 'Koei + 32 KiB SRAM', 'FM-PAC', 'PAC',
        'SCC+ 128 KiB', 'Snatcher SCC+', 'SD Snatcher SCC+', 'Philips MSX-AUDIO', 'Panasonic MSX-AUDIO'], ['-1', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12',
        '13', '14', '15', '16']), '-1', True);
end;

procedure TMSXSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupMSXDisks', 'Disk drives');
  Context.AddPath('RowMSXDiskROM', 'Disk ROM', 'Optional 16 KiB Philips WD2793 disk ROM override. Leave empty to use the built-in disk ROM.', 'Disk', 'ROM', '', False, True);
  Context.AddPath('RowMSXDiskA', 'Drive A image', 'Optional raw MSX DSK image. Opening a DSK directly replaces this image for that session.', 'Disk', 'DriveA', '', False, True);
  Context.AddPath('RowMSXDiskB', 'Drive B image', 'Optional second raw MSX DSK image. Reopen the game to apply.', 'Disk', 'DriveB', '', False, True);
  Context.AddBoolean('RowMSXDiskProtect', 'Write protect disks', 'Reject writes and formatting. Original images remain unchanged; writable disks use game saves.', 'Disk', 'WriteProtected', False, True);
  Context.Heading('GroupMSXCassette', 'Cassette recorder');
  Context.AddPath('RowMSXTapeFile', 'Cassette image', 'CAS or integer PCM WAV. Enable the original BIOS to use BASIC cassette commands with cartridges. Reopen the game to apply.', 'Cassette', 'File', '', False, True);
  Context.AddChoice('RowMSXTapeMode', 'Recorder mode', 'The MSX controls the motor. Recordings are saved as WAV alongside game saves when emulation stops.', 'Cassette', 'Mode', SettingChoices(['Stopped', 'Play', 'Record'], ['0', '1', '2']), '1', True);
  Context.AddChoice('RowMSXTapeBaud', 'CAS speed', 'FSK speed for CAS images; WAV recordings keep their original timing.', 'Cassette', 'Baud', SettingChoices(['1200 baud',
        '2400 baud'], ['1200', '2400']), '1200', True);
  Context.Heading('GroupMSXExpansion', 'Expansion hardware');
  Context.AddPath('RowMSXKanji', 'Kanji ROM', 'Optional 128 KiB JIS1 or 256 KiB JIS1+JIS2 font ROM. Reopen the game to apply.', 'Hardware', 'Kanji', '', False, True);
  Context.AddPath('RowMSXMusic', 'MSX-MUSIC ROM', 'Optional 16 KiB FM BASIC ROM for MSX2/2+. Reopen the game to apply.', 'Hardware', 'MusicROM', '', False, True);
  Context.AddPath('RowMSXKanjiBasic', 'Kanji BASIC ROM', 'Matching 32 KiB Kanji BASIC ROM; required by some Japanese MSX2+ BIOS startup screens.', 'Hardware', 'KanjiBasicROM', '', False, True);
  Context.AddChoice('RowMSXExpansion2', 'Slot 2 device', 'Insert a cartridge, FM-PAC/PAC, a Konami sound cartridge or MSX-AUDIO. Firmware is included; reopen the game to apply.', 'Cartridge', 'Expansion2', SettingChoices(['Cartridge file', 'FM-PAC', 'PAC', 'SCC+ 128 KiB', 'Snatcher SCC+', 'SD Snatcher SCC+', 'Philips MSX-AUDIO', 'Panasonic MSX-AUDIO'],
      ['0', '1', '2', '3', '4', '5', '6', '7']), '0', True);
  Context.AddChoice('RowMSXAudioRAM', 'MSX-AUDIO sample memory', '32 KiB matches the original modules; 256 KiB provides expanded ADPCM sample storage. Reopen the game to apply.', 'Hardware', 'AudioSampleRAM', SettingChoices(['32 KiB', '256 KiB'], ['32', '256']), '32', True);
  Context.AddPath('RowMSXCartridge2', 'Second cartridge', 'Optional cartridge for slot 2, including game combinations and SRAM cartridges. Reopen the game to apply.', 'Cartridge', 'Slot2', '', False, True);
  Context.AddChoice('RowMSXMapper2', 'Second cartridge mapper', 'Mapper override for slot 2. Reopen the game to apply.', 'Cartridge', 'Mapper2', SettingChoices(['Automatic',
        'Plain ROM', 'ASCII8', 'ASCII16', 'Konami', 'Konami SCC',
        'ASCII8 + SRAM', 'ASCII16 + SRAM', 'R-Type', 'Game Master 2', 'Koei + 32 KiB SRAM', 'FM-PAC', 'PAC',
        'SCC+ 128 KiB', 'Snatcher SCC+', 'SD Snatcher SCC+', 'Philips MSX-AUDIO', 'Panasonic MSX-AUDIO'], ['-1', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12',
        '13', '14', '15', '16']), '-1', True);
  Context.AddChoice('RowMSXMouse', 'MSX mouse', 'Connect a mouse to either general-purpose port. Reopen the game to apply.', 'Ports', 'MSXMousePort', SettingChoices(['Disconnected', 'Port 1', 'Port 2'], ['0', '1', '2']), '0', True);
  Context.Heading('GroupMSXKeyboard', 'Keyboard');
  Context.AddBoolean('RowMSXKeyboardEnabled', 'Physical keyboard', 'Send host keys to the MSX keyboard. Space is trigger 1; arrows move; Enter starts; F1 is available to games.', 'Ports', 'KeyboardEnabled', True, True);
end;

procedure TMSXSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.
