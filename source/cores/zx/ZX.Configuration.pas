unit ZX.Configuration;

interface

uses
  System.SysUtils, System.IniFiles, ZX.Machine;

type
  TZXPreset = record
    Id, Name: string;
    Machine: TZXMachineConfig;
  end;

  TZXConfiguration = record
    class function ReadMachine(Ini: TCustomIniFile): TZXMachineConfig; static;
    class function Presets: TArray<TZXPreset>; static;
    class procedure ApplyPreset(Ini: TCustomIniFile; const Id: string); static;
    class function SelectedPreset(Ini: TCustomIniFile): string; static;
    class function ManagedSetting(const Section, Key: string): Boolean; static;
    class function Notice(Ini: TCustomIniFile): string; static;
  end;

implementation

uses
  System.StrUtils, System.Classes;

class function TZXConfiguration.ReadMachine(Ini: TCustomIniFile): TZXMachineConfig;
begin
  Result := TZXMachineConfig.FromId(Ini.ReadString('Hardware', 'TapeModel', '48k'));
  Result.ULAPlus := Ini.ReadBool('Hardware', 'ULAPlus', False);
  Result.ByteCompatibility := Ini.ReadBool('Hardware', 'ByteCompatibility', True);
  Result.TimexVideo := Ini.ReadBool('Hardware', 'TimexVideo', False);
  Result.KempstonMouse := Ini.ReadBool('Hardware', 'KempstonMouse', False);
  Result.TurboSound := Ini.ReadBool('Hardware', 'TurboSound', False);
  Result.TurboSoundFM := Ini.ReadBool('Hardware', 'TurboSoundFM', False);
  Result.SAA1099 := Ini.ReadBool('Hardware', 'SAA1099', False);
  Result.DAC := IndexStr(Ini.ReadString('Hardware', 'DAC', 'none').ToLower,
    ['none', 'covoxfb', 'covoxdd', 'covoxgs', 'soundrive', 'specdrum', 'nextdac']);
  if Result.DAC < 0 then
    Result.DAC := 0;
  Result.NextDACMode := Ini.ReadInteger('Hardware', 'NextDACMode', 0);
  Result.NextDACStartup := Ini.ReadBool('Hardware', 'NextDACStartup', True);
  Result.GeneralSound := Ini.ReadBool('Hardware', 'GeneralSound', False);
  Result.GeneralSoundRAMKB := Ini.ReadInteger('Hardware', 'GeneralSoundRAMKB', 128);
  Result.NeoGS := Ini.ReadBool('Hardware', 'NeoGS', False);
  Result.SID := Ini.ReadBool('Hardware', 'SID', False);
  Result.SIDModel := Ini.ReadInteger('Hardware', 'SIDModel', 0);
  Result.SIDNTSC := SameText(Ini.ReadString('Hardware', 'SIDClock', 'pal'), 'ntsc');
  Result.SIDClock1MHz := SameText(Ini.ReadString('Hardware', 'SIDClock', 'pal'), '1mhz');
  Result.SIDInterface := IndexStr(LowerCase(Ini.ReadString('Hardware', 'SIDInterface', 'ezxmb')), ['ezxmb', 'xxcf']);
  Result.MoonSound := Ini.ReadBool('Hardware', 'MoonSound', False);
  Result.MoonSoundIRQ := Ini.ReadBool('Hardware', 'MoonSoundIRQ', False);
  Result.MoonSoundInDOS := Ini.ReadBool('Hardware', 'MoonSoundInDOS', False);
  Result.DMAUSC := Ini.ReadBool('Hardware', 'DMAUSC', False);
  Result.DMAUSCULABypass := Ini.ReadBool('Hardware', 'DMAUSCULABypass', True);
  Result.DMAUSCStereo := Ini.ReadInteger('Hardware', 'DMAUSCStereo', 0);
  Result.NeoGSRAMKB := Ini.ReadInteger('Hardware', 'NeoGSRAMKB', 2048);
  if SameText(Ini.ReadString('Hardware', 'DivType', 'none'), 'divide') then
    Result.DivType := zdIDE;
  if SameText(Ini.ReadString('Hardware', 'DivType', 'none'), 'divmmc') then
    Result.DivType := zdMMC;
  Result.DivRAMKB := Ini.ReadInteger('Hardware', 'DivRAMKB', 128);
  if SameText(Ini.ReadString('Hardware', 'TKTiming', '60hz'), '50hz') then
    Result.TKTiming := ztk50Hz;
  Result.TKSpanish := Ini.ReadBool('Hardware', 'TKSpanish', False);
end;

class function TZXConfiguration.Presets: TArray<TZXPreset>;

  procedure Add(const Id, Name: string; Model: TZXMachineModel);
  begin
    var N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].Id := Id;
    Result[N].Name := Name;
    Result[N].Machine := TZXMachineConfig.ForModel(Model);
    Result[N].Machine.DivRAMKB := 128;
  end;

begin
  Result := nil;
  for var Model := Low(TZXMachineModel) to High(TZXMachineModel) do
  begin
    var Config := TZXMachineConfig.ForModel(Model);
    Add('model-' + Config.Id, Config.Profile.Name, Model);
  end;
  Add('tk90x-50', 'TK90X / Microdigital 50 Hz', zmTK90X);
  Result[High(Result)].Machine.TKTiming := ztk50Hz;
  Add('tk95-50', 'TK95 / Microdigital 50 Hz', zmTK95);
  Result[High(Result)].Machine.TKTiming := ztk50Hz;
  Add('tk90x-es', 'TK90X / Spanish ROM / 60 Hz', zmTK90X);
  Result[High(Result)].Machine.TKSpanish := True;
  Add('tk95-es', 'TK95 / Spanish ROM / 60 Hz', zmTK95);
  Result[High(Result)].Machine.TKSpanish := True;
  Add('atarin', 'Atarin / Pentagon 128K / AY', zmPentagon128);
  Add('divmmc', 'Spectrum 128K + divMMC / esxDOS', zmSpectrum128);
  Result[High(Result)].Machine.DivType := zdMMC;
  Add('turbosound', 'Pentagon 128K + Turbo Sound', zmPentagon128);
  Result[High(Result)].Machine.TurboSound := True;
  Add('turbosound-fm', 'Pentagon 128K + Turbo Sound FM', zmPentagon128);
  Result[High(Result)].Machine.TurboSoundFM := True;
  Add('nextdac', 'Pentagon 128K + Next-DAC (audio only)', zmPentagon128);
  Result[High(Result)].Machine.DAC := 6;
  Add('gs128', 'Pentagon 128K + General Sound 128K', zmPentagon128);
  Result[High(Result)].Machine.GeneralSound := True;
  Add('gs512', 'Pentagon 128K + General Sound 512K', zmPentagon128);
  Result[High(Result)].Machine.GeneralSound := True;
  Result[High(Result)].Machine.GeneralSoundRAMKB := 512;
  Add('neogs512', 'Pentagon 128K + NeoGS 512K', zmPentagon128);
  Result[High(Result)].Machine.NeoGS := True;
  Result[High(Result)].Machine.NeoGSRAMKB := 512;
  Add('neogs2048', 'Pentagon 128K + NeoGS 2M', zmPentagon128);
  Result[High(Result)].Machine.NeoGS := True;
  Add('neogs4096', 'Pentagon 128K + NeoGS 4M', zmPentagon128);
  Result[High(Result)].Machine.NeoGS := True;
  Result[High(Result)].Machine.NeoGSRAMKB := 4096;
  Add('dmausc', 'Pentagon 128K + DMA Ultrasound Card', zmPentagon128);
  Result[High(Result)].Machine.DMAUSC := True;
  Add('sid6581', 'Pentagon 128K + SID 6581 (eZX/MB)', zmPentagon128);
  Result[High(Result)].Machine.SID := True;
  Add('sid8580', 'Pentagon 128K + SID 8580 (eZX/MB)', zmPentagon128);
  Result[High(Result)].Machine.SID := True;
  Result[High(Result)].Machine.SIDModel := 1;
  Add('hardsid6581', 'Pentagon 1024K + HardSID 6581 (xxCF)', zmPentagon1024);
  Result[High(Result)].Machine.SID := True;
  Result[High(Result)].Machine.SIDInterface := 1;
  Add('hardsid8580', 'Pentagon 1024K + HardSID 8580 (xxCF)', zmPentagon1024);
  Result[High(Result)].Machine.SID := True;
  Result[High(Result)].Machine.SIDInterface := 1;
  Result[High(Result)].Machine.SIDModel := 1;
  Add('moonsound', 'Pentagon 128K + ZXM-MoonSound', zmPentagon128);
  Result[High(Result)].Machine.MoonSound := True;
  Add('ulaplus', 'Spectrum 48K + ULAplus', zmSpectrum48);
  Result[High(Result)].Machine.ULAPlus := True;
  Add('gama-divmmc', 'Gama 1989 + divMMC / esxDOS', zmGama89);
  Result[High(Result)].Machine.DivType := zdMMC;
end;

class procedure TZXConfiguration.ApplyPreset(Ini: TCustomIniFile; const Id: string);
const
  DACNames: array[0..6] of string = ('none', 'covoxfb', 'covoxdd', 'covoxgs', 'soundrive', 'specdrum', 'nextdac');
begin
  if SameText(Id, 'custom') then
  begin
    Ini.WriteString('Hardware', 'Preset', 'custom');
    Exit;
  end;
  var Found := False;
  var Machine: TZXMachineConfig;
  for var Preset in Presets do
    if SameText(Preset.Id, Id) then
    begin
      Machine := Preset.Machine;
      Found := True;
      Break;
    end;
  if not Found then
    raise EArgumentException.Create('Unknown ZX configuration preset');
  Machine.Validate;
  Ini.WriteString('Hardware', 'Preset', Id);
  Ini.WriteString('Hardware', 'TapeModel', Machine.Id);
  Ini.WriteString('Hardware', 'TKTiming', '60hz');
  if Machine.TKTiming = ztk50Hz then
    Ini.WriteString('Hardware', 'TKTiming', '50hz');
  Ini.WriteBool('Hardware', 'TKSpanish', Machine.TKSpanish);
  Ini.WriteBool('Hardware', 'ULAPlus', Machine.ULAPlus);
  Ini.WriteBool('Hardware', 'ByteCompatibility', Machine.ByteCompatibility);
  Ini.WriteBool('Hardware', 'TimexVideo', Machine.TimexVideo);
  Ini.WriteBool('Hardware', 'KempstonMouse', Machine.KempstonMouse);
  Ini.WriteBool('Hardware', 'TurboSound', Machine.TurboSound);
  Ini.WriteBool('Hardware', 'TurboSoundFM', Machine.TurboSoundFM);
  Ini.WriteBool('Hardware', 'SAA1099', Machine.SAA1099);
  Ini.WriteString('Hardware', 'DAC', DACNames[Machine.DAC]);
  Ini.WriteInteger('Hardware', 'NextDACMode', Machine.NextDACMode);
  Ini.WriteBool('Hardware', 'NextDACStartup', Machine.NextDACStartup);
  Ini.WriteBool('Hardware', 'GeneralSound', Machine.GeneralSound);
  Ini.WriteInteger('Hardware', 'GeneralSoundRAMKB', Machine.GeneralSoundRAMKB);
  Ini.WriteBool('Hardware', 'NeoGS', Machine.NeoGS);
  Ini.WriteBool('Hardware', 'SID', Machine.SID);
  Ini.WriteInteger('Hardware', 'SIDModel', Machine.SIDModel);
  Ini.WriteString('Hardware', 'SIDInterface', 'ezxmb');
  if Machine.SIDInterface = 1 then
    Ini.WriteString('Hardware', 'SIDInterface', 'xxcf');
  Ini.WriteString('Hardware', 'SIDClock', 'pal');
  if Machine.SIDNTSC then
    Ini.WriteString('Hardware', 'SIDClock', 'ntsc');
  if Machine.SIDClock1MHz then
    Ini.WriteString('Hardware', 'SIDClock', '1mhz');
  Ini.WriteBool('Hardware', 'MoonSound', Machine.MoonSound);
  Ini.WriteBool('Hardware', 'MoonSoundIRQ', Machine.MoonSoundIRQ);
  Ini.WriteBool('Hardware', 'MoonSoundInDOS', Machine.MoonSoundInDOS);
  Ini.WriteBool('Hardware', 'DMAUSC', Machine.DMAUSC);
  Ini.WriteBool('Hardware', 'DMAUSCULABypass', Machine.DMAUSCULABypass);
  Ini.WriteInteger('Hardware', 'DMAUSCStereo', Machine.DMAUSCStereo);
  Ini.WriteInteger('Hardware', 'NeoGSRAMKB', Machine.NeoGSRAMKB);
  Ini.WriteString('Hardware', 'NeoGSImage', '');
  Ini.WriteString('Hardware', 'DivType', 'none');
  if Machine.DivType = zdMMC then
    Ini.WriteString('Hardware', 'DivType', 'divmmc');
  Ini.WriteInteger('Hardware', 'DivRAMKB', Machine.DivRAMKB);
  Ini.WriteString('Hardware', 'ServiceROM', '');
  Ini.WriteString('Hardware', 'TimexCartridge', '');
  Ini.WriteString('Hardware', 'DivFirmware', '');
  if Machine.DivType = zdNone then
    Ini.WriteString('Hardware', 'DivImage', '');
  Ini.WriteString('Audio', 'PSGModel', 'ay');
  Ini.WriteString('Audio', 'Stereo', 'abc');
  if Machine.TurboSoundFM then
    Ini.WriteString('Audio', 'Stereo', 'acb');
  for var Key in ['AYVolume', 'BeeperVolume', 'ExpansionVolume', 'PITVolume'] do
    Ini.WriteInteger('Audio', Key, 100);
  Ini.WriteString('Ports', 'JoystickMode', 'both');
  // TK sockets are wired to the Interface 2 keyboard contacts.
  if Machine.Id.StartsWith('tk') then
    Ini.WriteString('Ports', 'JoystickMode', 'sinclair1');
  Ini.WriteBool('Ports', 'SecondJoystick', False);
  Ini.WriteBool('Ports', 'KeyboardEnabled', True);
  Ini.WriteBool('Media', 'AutoLoad', True);
  Ini.WriteBool('Media', 'TapeAutoPlay', True);
  Ini.WriteInteger('Media', 'TapeSpeed', 1);
  Ini.WriteBool('Media', 'DiskWriteProtected', False);
end;

class function TZXConfiguration.ManagedSetting(const Section, Key: string): Boolean;
begin
  Result := SameText(Section, 'Hardware') or SameText(Section, 'Media') or
    (SameText(Section, 'Audio') and not SameText(Key, 'Volume')) or
    (SameText(Section, 'Ports') and MatchText(Key, ['JoystickMode', 'SecondJoystick', 'KeyboardEnabled']));
end;

class function TZXConfiguration.SelectedPreset(Ini: TCustomIniFile): string;
begin
  Result := 'custom';
  var Id := Ini.ReadString('Hardware', 'Preset', 'custom');
  for var P in Presets do
    if SameText(P.Id, Id) then
    begin
      var Expected := TMemIniFile.Create('');
      var Sections := TStringList.Create;
      var Keys := TStringList.Create;
      try
        ApplyPreset(Expected, Id);
        Expected.ReadSections(Sections);
        for var Section in Sections do
        begin
          Expected.ReadSection(Section, Keys);
          for var Key in Keys do
          begin
            if SameText(Key, 'Preset') then
              Continue;
            if not Ini.ValueExists(Section, Key) then
            begin
              // Configurations saved before HardSID implicitly use eZX/MB.
              if SameText(Section, 'Hardware') and SameText(Key, 'SIDInterface') and
                (P.Machine.SIDInterface = 0) then
                Continue;
              Exit;
            end;
            var Value := Expected.ReadString(Section, Key, '');
            if not SameText(Ini.ReadString(Section, Key, Value), Value) then
              Exit;
          end;
        end;
        Result := P.Id;
      finally
        Keys.Free;
        Sections.Free;
        Expected.Free;
      end;
      Exit;
    end;
end;

class function TZXConfiguration.Notice(Ini: TCustomIniFile): string;

  procedure Add(const Text: string);
  begin
    if Result <> '' then
      Result := Result + sLineBreak;
    Result := Result + Text;
  end;

begin
  Result := '';
  var Machine := ReadMachine(Ini);
  for var Error in Machine.ConfigurationErrors do
    Add('Conflict: ' + Error);
  if Machine.MoonSound and Machine.MoonSoundInDOS then
    Add('Notice: MoonSound stays available in TR-DOS except during disk-controller I/O. This emulates the PentEvo jumper.');
  if Machine.DMAUSC and not Machine.DMAUSCULABypass then
    Add('Notice: DMA Ultrasound uses the complete interrupt controller. Programs must enable IRQ-control bit 3 for normal Spectrum interrupts; early players may require the ULA compatibility option.');
  if Machine.DMAUSC and (Machine.Model = zmPentagon1024) then
    Add('Notice: DMA Ultrasound register aliases can also reach Pentagon EFF7. Programs should use the documented 77 ports.');
  if Machine.NeoGS then
    Add('Notice: NeoGS supports standard NedoPC FPGA configurations and VS1011e MP3. Custom FPGA designs and DSP plugins are unsupported.');
  if Machine.NeoGS and (Machine.Model = zmPentagon1024) then
    Add('Notice: NeoGS data writes at E0B3..EFB3 also reach Pentagon 1024SL EFF7. Software must use explicit port addresses such as 00B3.');
  if not Machine.NeoGS and (Ini.ReadString('Hardware', 'NeoGSImage', '').Trim <> '') then
    Add('Notice: The NeoGS SD image is ignored while NeoGS is disabled.');
  if Machine.GeneralSound and (Machine.Model = zmPentagon1024) then
    Add('Notice: General Sound data writes at E0B3..EFB3 also reach Pentagon 1024SL EFF7. Software must use explicit port addresses such as 00B3.');
  if Machine.GeneralSound and (Machine.GeneralSoundRAMKB = 512) then
    Add('Notice: Classic GS512 exposes 480 KiB of RAM. Its original decoder leaves one 32 KiB region unavailable.');
  if Machine.DAC = 6 then
  begin
    Add('Notice: Next-DAC provides audio ports only. Spectrum Next CPU, video, DMA and copper are not enabled.');
    if not Machine.NextDACStartup then
      Add('Notice: Next-DAC starts disabled. The program must enable NextReg 08 bit 3 to produce sound.');
    if Machine.Profile.Has128Paging and (Machine.NextDACMode in [0, 2]) then
      Add('Notice: Soundrive 2 ports F1/F9 also reach the selected motherboard paging and AY decoders. Use explicit port addresses or choose another DAC port profile.');
    if Machine.Gama then
      Add('Notice: Gama PPI also decodes the NextReg ports. Its input/output settings can affect register readback.');
  end;
  if (Machine.DivType <> zdNone) and (Machine.Model in [zmGama87, zmGama88]) then
    Add('Notice: Gama 1987/1988 ROMs switch banks after the esxDOS autoboot hook. Select Gama 1989 for autoboot; NMI browser entry is available.');
  if (Machine.DivType <> zdNone) and (Machine.Model = zmTimex2068) then
    Add('Notice: Native TC2068 HOME firmware is not compatible with the built-in esxDOS boot. A Spectrum-compatible HOME cartridge is required.');
  if (Machine.DivType = zdNone) and (Ini.ReadString('Hardware', 'DivImage', '').Trim <> '') then
    Add('Notice: The CF/SD image is ignored while its interface is disabled.');
  if (Machine.DivType <> zdNone) and (Ini.ReadString('Hardware', 'DivImage', '').Trim = '') then
    Add('Notice: Choose a CF/SD image with matching esxDOS SYS/BIN files, or open an IDE/MMC image directly.');
  if (Machine.Model <> zmPentagon1024) and (Ini.ReadString('Hardware', 'ServiceROM', '').Trim <> '') then
    Add('Notice: The selected service ROM is only used by Pentagon 1024SL.');
  if (Machine.Model <> zmTimex2068) and (Ini.ReadString('Hardware', 'TimexCartridge', '').Trim <> '') then
    Add('Notice: The DCK cartridge is only attached on Timex TC2068.');
end;

end.

