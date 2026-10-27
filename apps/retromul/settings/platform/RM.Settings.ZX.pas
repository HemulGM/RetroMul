unit RM.Settings.ZX;

interface

uses
  System.IniFiles, RM.Settings.Platform, RM.Settings.Builder;

type
  TZXSettings = class(TSettingsPlatform)
  public
    procedure Validate(Draft: TMemIniFile); override;
    function HasConfiguration: Boolean; override;
    function ChangeConfiguration(Draft: TMemIniFile; const Section, Key: string): Boolean; override;
    function ConfigurationNotice(Draft: TMemIniFile): string; override;
    procedure Audio(Context: TSettingsPageBuilder); override;
    procedure Configuration(Context: TSettingsPageBuilder); override;
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types, System.SysUtils, ZX.Configuration;

function LocalizeConfigurationText(const Text: string): string;
const
  ConflictPrefix = 'Conflict: ';
begin
  Result := '';
  for var Line in Text.Split([sLineBreak]) do
  begin
    if Result <> '' then
      Result := Result + sLineBreak;
    if Line.StartsWith(ConflictPrefix) then
      Result := Result + Translate(ConflictPrefix) + Translate(Line.Substring(Length(ConflictPrefix)))
    else
      Result := Result + Translate(Line);
  end;
end;

procedure TZXSettings.Validate(Draft: TMemIniFile);
begin
  inherited;
  var Errors := TZXConfiguration.ReadMachine(Draft).ConfigurationErrors;
  if Length(Errors) > 0 then
    raise EArgumentException.Create(LocalizeConfigurationText(string.Join(sLineBreak, Errors)));
end;

function TZXSettings.HasConfiguration: Boolean;
begin
  Result := True;
end;

function TZXSettings.ChangeConfiguration(Draft: TMemIniFile; const Section, Key: string): Boolean;
begin
  Result := False;
  if SameText(Section, 'Hardware') and SameText(Key, 'Preset') then
  begin
    TZXConfiguration.ApplyPreset(Draft, Draft.ReadString('Hardware', 'Preset', 'custom'));
    Exit(True);
  end;
  if TZXConfiguration.ManagedSetting(Section, Key) then
    Draft.WriteString('Hardware', 'Preset', 'custom');
end;

function TZXSettings.ConfigurationNotice(Draft: TMemIniFile): string;
begin
  Result := LocalizeConfigurationText(TZXConfiguration.Notice(Draft));
end;

procedure TZXSettings.Configuration(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupZXConfiguration', 'Ready configurations');
  var Presets := TZXConfiguration.Presets;
  var Labels, Values: TArray<string>;
  SetLength(Labels, Length(Presets) + 1);
  SetLength(Values, Length(Labels));
  Labels[0] := 'Custom configuration';
  Values[0] := 'custom';
  for var I := 0 to High(Presets) do
  begin
    Labels[I + 1] := Presets[I].Name;
    Values[I + 1] := Presets[I].Id;
  end;
  Context.Draft.WriteString('Hardware', 'Preset', TZXConfiguration.SelectedPreset(Context.Draft));
  Context.AddChoice('ZXConfigurationPreset', 'Configuration preset', 'Replaces machine, interface, sound, input and media options in this draft. Apply saves; Cancel discards. Manual changes select Custom. Shaders, master volume and button bindings are preserved.', 'Hardware', 'Preset', SettingChoices(Labels, Values), 'custom', True);
end;

procedure TZXSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupZXHardware', 'ZX Spectrum');
  Context.AddChoice('ZXTapeModel', 'Machine model', 'KDI opens on Byte-01. PRO opens on Profi 1024K unless Profi 512K is selected. TRD/SCL retain selected Pentagon, Scorpion or Profi; other models use Pentagon 128K. DSK opens on +3. Tapes use the selected machine. Select Gama 1989 for esxDOS autoboot; older Gama ROMs switch memory after its boot hook. Changes apply when opening media.', 'Hardware', 'TapeModel', SettingChoices(['48K', '128K / 48 BASIC', 'Pentagon 128K / TR-DOS', 'Pentagon 512K / TR-DOS', 'Pentagon 1024K / TR-DOS', '16K',
        '+2 (grey) / 48 BASIC', '+2b (black) / 48 BASIC', '+3 / disk', 'Timex TC2048', 'Timex TC2068 / BASIC 64', 'Scorpion ZS-256', 'Profi+ 512K', 'Profi+ 1024K', 'Byte 48K',
        'Byte-01 / KVU', 'Didaktik Gama 1987 / 80K', 'Didaktik Gama 1988 / 80K', 'Didaktik Gama 1989 / 80K', 'Microdigital TK90X', 'Microdigital TK95'], ['48k', '128k', 'pentagon',
        'pentagon512', 'pentagon1024', '16k', 'plus2', 'plus2b', 'plus3', 'tc2048', 'tc2068', 'scorpion', 'profi512', 'profi', 'byte', 'byte01', 'gama87', 'gama88', 'gama', 'tk90x',
        'tk95']), '48k', True);
  Context.AddChoice('ZXTKTiming', 'TK90X / TK95 video timing', 'Select the original Microdigital MC16845 60 Hz timing or its 50 Hz pin setting. Applies on opening media; other machine families ignore this option.', 'Hardware', 'TKTiming', SettingChoices(['Microdigital 60 Hz', 'Microdigital 50 Hz'], ['60hz', '50hz']), '60hz', True);
  Context.AddBoolean('ZXTKSpanish', 'TK90X / TK95 Spanish ROM', 'Select the original Spanish EPROM and export-board keyboard input. Disabled selects the Brazilian Portuguese EPROM. Applies only to TK90X/TK95.', 'Hardware', 'TKSpanish', False, True);
  Context.AddPath('ZXTimexCartridge', 'Timex TC2068 cartridge', 'Optional DCK HOME/DOCK/EXROM cartridge attached to tapes and snapshots. Use a Spectrum emulator cartridge for Spectrum software on TC2068. Open DCK directly to boot a cartridge.', 'Hardware', 'TimexCartridge', '', False, True);
  Context.AddPath('ZXServiceROM', 'Pentagon service ROM', 'Optional 16 KiB Gluk ROM or 64 KiB GLUK/DOS/128/48 ROM set for Pentagon 1024K disk boot. Leave empty for the classic TR-DOS boot.', 'Hardware', 'ServiceROM', '', False, True);
  Context.AddBoolean('ZXByteCompatibility', 'Byte Spectrum compatibility', 'Position of the original Byte compatibility switch. The ROM overlay becomes active after reading Kempston port 1F. Applies on open; Byte-01 has no overlay PROMs.', 'Hardware', 'ByteCompatibility', True, True);
  Context.AddBoolean('ZXULAPlus', 'ULAplus palette', 'Attach the programmable 64-entry palette. Programs select colors through its ports. Applies when opening media.', 'Hardware', 'ULAPlus', False, True);
  Context.AddBoolean('ZXTimexVideo', 'Timex video modes', 'Attach dual-screen, HiColor and 512-pixel HiRes video modes. Applies when opening media.', 'Hardware', 'TimexVideo', False, True);
  Context.Heading('GroupZXStorage', 'CF / SD interface');
  Context.AddChoice('ZXDivType', 'CF / SD interface', 'Attach divIDE (32 KiB RAM) or divMMC with esxDOS 0.8.9. Changes apply on open. F9 is the NMI button (also Scorpion Magic without a CF/SD interface).', 'Hardware', 'DivType', SettingChoices(['None', 'divIDE / esxDOS', 'divMMC / esxDOS'], ['none', 'divide', 'divmmc']), 'none', True);
  Context.AddChoice('ZXDivRAM', 'DivMMC RAM', 'Select the installed divMMC RAM. divIDE always has 32 KiB.', 'Hardware', 'DivRAMKB', SettingChoices(['128 KiB', '512 KiB'], ['128',
        '512']), '128', True);
  Context.AddPath('ZXDivImage', 'CF / SD image', 'Optional raw 512-byte-sector FAT image attached to tapes/snapshots. Open .ide or .mmc directly to boot the card.', 'Hardware', 'DivImage', '', False, True);
  Context.AddPath('ZXDivFirmware', 'Interface firmware', 'Optional 8 KiB ROM override; empty uses built-in esxDOS 0.8.9. The card needs matching SYS/BIN files.', 'Hardware', 'DivFirmware', '', False, True);
end;

procedure TZXSettings.Audio(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupZXSound', 'Spectrum sound');
  Context.AddBoolean('ZXTurboSound', 'Turbo Sound', 'Attach a second AY/YM chip using the NedoPC FF/FE selector. Applies when opening media.', 'Hardware', 'TurboSound', False, True);
  Context.AddBoolean('ZXTurboSoundFM', 'Turbo Sound FM', 'Replace the PSG with two YM2203 chips (NedoPC revision C). FM uses the expansion volume; SSG uses AY / YM volume. Applies when opening media.', 'Hardware', 'TurboSoundFM', False, True);
  Context.AddBoolean('ZXSAA1099', 'SAA1099 sound board', 'Attach the 8 MHz board at ports 00FF/01FF. Shares ports with Timex video; applies when opening media.', 'Hardware', 'SAA1099', False, True);
  Context.AddChoice('ZXDAC', 'DAC sound board', 'Choose the external 8-bit DAC interface. GS-port Covox is the B3 DAC interface. Applies when opening media.', 'Hardware', 'DAC', SettingChoices(['None', 'Covox #FB', 'Covox #DD', 'GS-port Covox #B3', 'SounDrive 1.00', 'SpecDrum #DF', 'Next-DAC (audio only)'], ['none', 'covoxfb', 'covoxdd', 'covoxgs',
        'soundrive', 'specdrum', 'nextdac']), 'none', True);
  Context.AddBoolean('ZXGeneralSound', 'General Sound', 'Attach the classic 12 MHz Z80 sound card with built-in GS ROM 1.05b and four DAC channels. Applies when opening media.', 'Hardware', 'GeneralSound', False, True);
  Context.AddChoice('ZXGeneralSoundRAM', 'General Sound RAM', 'Select the classic 128 KiB board or GS512 expansion. GS512 retains the original missing 32 KiB region. Applies when opening media.', 'Hardware', 'GeneralSoundRAMKB', SettingChoices(['128 KiB', '512 KiB'], ['128', '512']), '128', True);
  Context.AddBoolean('ZXSID', 'SID sound board', 'Attach one MOS SID using the selected interface. No BIOS is required. Applies when opening media.', 'Hardware', 'SID', False, True);
  Context.AddChoice('ZXSIDInterface', 'SID interface', 'eZX/MB uses 6C3B/6D3B. HardSID uses xxCF with the register in the high byte. For NSID Pentagon use the Pentagon 1024 HardSID preset.', 'Hardware', 'SIDInterface', SettingChoices(['eZX/MB (6C3B/6D3B)', 'HardSID / ZX-TSid (xxCF)'], ['ezxmb', 'xxcf']), 'ezxmb', True);
  Context.AddChoice('ZXSIDModel', 'SID model', 'Initial SID model. eZX/MB software can switch 6581/8580 without resetting the voices. HardSID keeps the configured model.', 'Hardware', 'SIDModel', SettingChoices(['MOS 6581', 'MOS 8580'], ['0', '1']), '0', True);
  Context.AddChoice('ZXSIDClock', 'SID clock', 'Choose PAL, NTSC or a 1 MHz HardSID clock. Only eZX/MB software can change the SID clock. Spectrum video timing is unchanged.', 'Hardware', 'SIDClock', SettingChoices(['PAL (985248 Hz)', 'NTSC (1022730 Hz)', '1 MHz (ZX-TSid)'], ['pal', 'ntsc', '1mhz']), 'pal', True);
  Context.AddBoolean('ZXMoonSound', 'ZXM-MoonSound', 'Attach OPL4 with 18 FM and 24 wave channels, 1 MiB RAM and built-in Yamaha sample ROM. Flash updates are saved automatically. Applies when opening media.', 'Hardware', 'MoonSound', False, True);
  Context.AddBoolean('ZXMoonSoundIRQ', 'MoonSound IRQ jumper', 'Connect OPL4 timer interrupts to the Spectrum CPU. The standard music players use frame interrupts and do not require this jumper.', 'Hardware', 'MoonSoundIRQ', False, True);
  Context.AddBoolean('ZXMoonSoundInDOS', 'MoonSound in TR-DOS', 'Emulate the PentEvo jumper and keep MoonSound accessible in DOS ROM. Disk-controller accesses still take priority.', 'Hardware', 'MoonSoundInDOS', False, True);
  Context.AddBoolean('ZXDMAUSC', 'DMA Ultrasound Card', 'Attach the four-channel DMA Ultrasound Card. Samples use motherboard RAM; no BIOS is required. Applies when opening media.', 'Hardware', 'DMAUSC', False, True);
  Context.AddChoice('ZXDMAUSCStereo', 'DMA Ultrasound stereo', 'Route the four physical audio outputs to stereo or mono.', 'Hardware', 'DMAUSCStereo', SettingChoices(['AD left / BC right', 'AB left / CD right', 'Mono'], ['0', '1', '2']), '0', True);
  Context.AddBoolean('ZXDMAUSCULABypass', 'Keep ULA interrupts enabled', 'Compatibility option for early DMA USC players. Keep frame interrupts enabled regardless of IRQ-control bit 3. Turn off to emulate the complete interrupt controller.', 'Hardware', 'DMAUSCULABypass', True, True);
  Context.AddBoolean('ZXNeoGS', 'NeoGS', 'Attach NeoGS with built-in firmware 1.11, 4/8-channel PCM, VS1011e MP3, SD and DMA. Flash updates are saved automatically. Applies when opening media.', 'Hardware', 'NeoGS', False, True);
  Context.AddChoice('ZXNeoGSRAM', 'NeoGS RAM', 'Select 512 KiB, 2 MiB or 4 MiB of sound card RAM. Programs control paging, channel mode and the 10/12/20/24 MHz CPU clock.', 'Hardware', 'NeoGSRAMKB', SettingChoices(['512 KiB', '2 MiB', '4 MiB'], ['512', '2048', '4096']), '2048', True);
  Context.AddPath('ZXNeoGSImage', 'NeoGS SD image', 'Optional raw SD image for the NeoGS slot, independent of divMMC. Sector changes are saved separately; the original image is preserved.', 'Hardware', 'NeoGSImage', '', False, True);
  Context.AddChoice('ZXNextDACMode', 'Next-DAC port profile', 'Choose enabled DAC aliases on startup. Programs can change these gates through NextReg 84. Applies only to Next-DAC.', 'Hardware', 'NextDACMode', SettingChoices(['All DAC aliases', 'SounDrive mode 1', 'SounDrive mode 2', 'Profi stereo Covox', 'Stereo Covox', 'Pentagon / ATM mono', 'GS Covox mono', 'SpecDrum mono',
        'NextReg mirrors only'], ['0', '1', '2', '3', '4', '5', '6', '7', '8']), '0', True);
  Context.AddBoolean('ZXNextDACStartup', 'Enable Next-DAC on startup', 'Enable the DAC for classic software. Turn off to start with the hardware power-on gate closed; programs can enable NextReg 08 bit 3.', 'Hardware', 'NextDACStartup', True, True);
  Context.AddInteger('ZXExpansionVolume', 'Expansion sound volume (%)', 'Adjust DAC, GS/NeoGS, SAA1099, FM, MoonSound and SID independently of the PSG and beeper.', 'Audio', 'ExpansionVolume', 100, 100, True);
  Context.AddChoice('ZXPSGModel', 'PSG chip', 'Select AY-3-8912 or YM2149 sound characteristics. Turbo Sound FM always uses YM2203 SSG.', 'Audio', 'PSGModel', SettingChoices(['AY-3-8912', 'YM2149'], ['ay', 'ym']), 'ay', True);
  Context.AddChoice('ZXStereo', 'PSG stereo layout', 'Mono or channel order from left to right. ABC preserves the previous sound.', 'Audio', 'Stereo', SettingChoices(['ABC',
        'Mono', 'ACB', 'BAC', 'BCA', 'CAB', 'CBA'], ['abc', 'mono', 'acb', 'bac', 'bca', 'cab', 'cba']), 'abc', True);
  Context.AddInteger('ZXVI53Volume', 'Byte VI53 volume (%)', 'Adjust the three-channel Byte/Byte-01 timer synthesizer independently of the beeper and AY.', 'Audio', 'PITVolume', 100, 100, True);
  Context.AddInteger('ZXAYVolume', 'AY / YM volume (%)', 'Adjust PSG sound independently. Zero mutes the chip.', 'Audio', 'AYVolume', 100, 100, True);
  Context.AddInteger('ZXBeeperVolume', 'Beeper volume (%)', 'Adjust the Spectrum speaker and MIC output. Zero mutes them.', 'Audio', 'BeeperVolume', 100, 100, True);
end;

procedure TZXSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupZXKeyboard', 'Spectrum input');
  Context.AddBoolean('ZXKeyboard', 'Keyboard', 'Send keyboard input to Spectrum. Shift is CAPS SHIFT; Ctrl is SYMBOL SHIFT. Tape shortcuts remain available.', 'Ports', 'KeyboardEnabled', True, True);
  Context.AddChoice('ZXJoystick', 'Joystick emulation', 'Choose Kempston, QAOP/Space, both, or no joystick. Button bindings are in Controls.', 'Ports', 'JoystickMode', SettingChoices(['Kempston + QAOP/Space', 'Kempston', 'QAOP/Space', 'Disconnected', 'Interface 2 (6–0)', 'Interface 2 (1–5)'], ['both', 'kempston', 'qaop', 'none', 'sinclair1',
        'sinclair2']), 'both', True);
  Context.AddBoolean('ZXSecondJoystick', 'Second joystick', 'Map controller 2 to Gama PPI port B (63), or Interface 2 keys 1–5 on other machines. Configure both controllers in Controls.', 'Ports', 'SecondJoystick', False, True);
  Context.AddBoolean('ZXKempstonMouse', 'Kempston mouse', 'Use host relative mouse movement and three buttons. Applies when opening media.', 'Hardware', 'KempstonMouse', False, True);
  Context.Heading('GroupZXMedia', 'Tape and disk');
  Context.AddBoolean('ZXAutoLoad', 'Auto-load media', 'Automatically enter the tape loading command or start the +3 Loader / boot TR-DOS after opening media. Applies on open or reset.', 'Media', 'AutoLoad', True, True);
  Context.AddBoolean('ZXTapeAutoPlay', 'Play tape on startup', 'Start the tape automatically after opening or resetting. F7 toggles playback; F8 rewinds.', 'Media', 'TapeAutoPlay', True, True);
  Context.AddChoice('ZXTapeSpeed', 'Tape playback speed', 'Accelerate the whole machine while the tape is playing; accelerated playback is muted. F7 returns to normal speed.', 'Media', 'TapeSpeed', SettingChoices(['1x (normal)', '2x', '4x', '8x'], ['1', '2', '4', '8']), '1', True);
  Context.AddChoice('ZXFastForwardSpeed', 'Fast-forward speed (hold F10)', 'Accelerate any media while F10 is held. All hardware clocks are emulated; host audio is muted.', 'Media', 'FastForwardSpeed', SettingChoices(['1x (normal)', '2x', '4x', '8x'], ['1', '2', '4', '8']), '8', True);
  Context.AddBoolean('ZXDiskWriteProtected', 'Write protect disk', 'Prevent writes and formatting. Existing saved disk changes remain readable.', 'Media', 'DiskWriteProtected', False, True);
end;

initialization
  RegisterSettingsProfile('ZXSpectrum', TZXSettings);

end.

