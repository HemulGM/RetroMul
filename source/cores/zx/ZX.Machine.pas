unit ZX.Machine;

interface

type
  TZXDivType = (zdNone, zdIDE, zdMMC);

  TZXTKTiming = (ztk60Hz, ztk50Hz);

  // Values are persisted in native states. Append new models; never reorder.
  TZXMachineModel = (zmSpectrum48, zmSpectrum16, zmSpectrum128, zmSpectrumPlus2,
    zmPentagon128, zmPentagon512, zmPentagon1024, zmSpectrumPlus2b, zmSpectrumPlus3,
    zmTimex2048, zmTimex2068, zmScorpion256, zmProfi512, zmProfi1024, zmByte, zmByte01,
    zmGama87, zmGama88, zmGama89, zmTK90X, zmTK95);

  TZXMachineProfile = record
    Id, Name: string;
    RAMSizeKB, ClockHz, FrameCycles, LineCycles, DisplayStart, ContentionStart: Integer;
    Has128Paging, HasAY, IsPentagon: Boolean;
  end;

  TZXMachineConfig = record
    Model: TZXMachineModel;
    ULAPlus, TimexVideo, KempstonMouse: Boolean;
    ByteCompatibility: Boolean;
    TKTiming: TZXTKTiming;
    TKSpanish: Boolean;
    TurboSound, TurboSoundFM, SAA1099: Boolean;
    DivType: TZXDivType;
    DivRAMKB: Integer; // 0/128 = 128 KiB DivMMC, 512 = expanded. DivIDE always 32 KiB.
    DAC: Integer; // 0 none, 1 Covox FB, 2 Covox DD, 3 GS B3, 4 SounDrive 1, 5 SpecDrum, 6 Next-DAC
    NextDACMode: Integer; // 0 all, 1 SD1, 2 SD2, 3 Profi, 4 Covox, 5 Pentagon, 6 GS, 7 SpecDrum, 8 NextReg only
    NextDACStartup: Boolean;
    GeneralSound: Boolean;
    GeneralSoundRAMKB: Integer;
    NeoGS: Boolean;
    NeoGSRAMKB: Integer;
    MoonSound, MoonSoundIRQ, MoonSoundInDOS: Boolean;
    SID, SIDNTSC: Boolean;
    SIDModel: Integer; // 0 MOS6581, 1 MOS8580
    SIDInterface: Integer; // 0 eZX/MB 6C3B/6D3B, 1 HardSID/ZX-TSid xxCF
    SIDClock1MHz: Boolean; // Fixed ZX-TSid clock; otherwise SIDNTSC selects PAL/NTSC.
    DMAUSC, DMAUSCULABypass: Boolean;
    DMAUSCStereo: Integer; // 0 AD/BC, 1 AB/CD, 2 mono; four physical card outputs
    class function ForModel(Value: TZXMachineModel): TZXMachineConfig; static;
    class function FromId(const Id: string): TZXMachineConfig; static;
    class function FromLegacy(Is128, Pentagon: Boolean; RAMSizeKB: Integer): TZXMachineConfig; static;
    function NextDACDecodeMask: Byte;
    function ConfigurationErrors: TArray<string>;
    procedure Validate;
    function WithModel(Value: TZXMachineModel): TZXMachineConfig;
    function TK: Boolean; inline;
    function Gama: Boolean; inline;
    function ByteFamily: Boolean; inline;
    function Profi: Boolean; inline;
    function Scorpion: Boolean; inline;
    function Timex: Boolean; inline;
    function VideoTimex: Boolean; inline;
    function Profile: TZXMachineProfile;
    function Id: string;
  end;

  // Host preferences; hardware state and tape transport remain in native snapshots.
  TZXRuntimeOptions = record
    YMChip: Boolean;
    Stereo: Integer; // 0 ABC (legacy), 1 mono, 2 ACB, 3 BAC, 4 BCA, 5 CAB, 6 CBA
    AYVolume, BeeperVolume, ExpansionVolume, PITVolume: Integer;
    Joystick: Integer; // 0 combined, 1 Kempston, 2 QAOP, 3 none, 4 Interface 2 (67890), 5 Interface 2 (12345)
    SecondJoystick: Boolean; // Controller 2: Gama PPI B, otherwise Interface 2 keys 12345.
    AutoLoad, TapeAutoPlay, DiskWriteProtected: Boolean;
    TapeSpeed: Integer;
    FastForwardSpeed: Integer; // Host pacing only, while F10 is held.
    class function Defaults: TZXRuntimeOptions; static;
    function Normalized: TZXRuntimeOptions;
    function PlaybackSpeed(HasTape, Stopped: Boolean; FastForward: Boolean = False): Integer;
  end;

implementation

uses
  System.SysUtils, System.Math;

class function TZXRuntimeOptions.Defaults: TZXRuntimeOptions;
begin
  Result := Default(TZXRuntimeOptions);
  Result.PITVolume := 100;
  Result.AYVolume := 100;
  Result.BeeperVolume := 100;
  Result.ExpansionVolume := 100;
  Result.AutoLoad := True;
  Result.TapeAutoPlay := True;
  Result.TapeSpeed := 1;
  Result.FastForwardSpeed := 8;
end;

function TZXRuntimeOptions.Normalized: TZXRuntimeOptions;
begin
  Result := Self;
  Result.PITVolume := EnsureRange(PITVolume, 0, 100);
  Result.AYVolume := EnsureRange(AYVolume, 0, 100);
  Result.BeeperVolume := EnsureRange(BeeperVolume, 0, 100);
  Result.ExpansionVolume := EnsureRange(ExpansionVolume, 0, 100);
  if (Stereo < 0) or (Stereo > 6) then
    Result.Stereo := 0;
  if (Joystick < 0) or (Joystick > 5) then
    Result.Joystick := 0;
  if not (TapeSpeed in [1, 2, 4, 8]) then
    Result.TapeSpeed := 1;
  if not (FastForwardSpeed in [1, 2, 4, 8]) then
    Result.FastForwardSpeed := 8;
end;

function TZXRuntimeOptions.PlaybackSpeed(HasTape, Stopped: Boolean; FastForward: Boolean): Integer;
begin
  Result := 1;
  if HasTape and not Stopped then
    Result := Normalized.TapeSpeed;
  if FastForward then
    Result := Max(Result, Normalized.FastForwardSpeed);
end;

class function TZXMachineConfig.ForModel(Value: TZXMachineModel): TZXMachineConfig;
begin
  if (Ord(Value) < Ord(Low(TZXMachineModel))) or (Ord(Value) > Ord(High(TZXMachineModel))) then
    raise EArgumentException.Create('Unsupported Spectrum machine model');
  Result := Default(TZXMachineConfig);
  Result.Model := Value;
  Result.ByteCompatibility := True;
  Result.NextDACStartup := True;
  Result.GeneralSoundRAMKB := 128;
  Result.NeoGSRAMKB := 2048;
  Result.DMAUSCULABypass := True;
end;

class function TZXMachineConfig.FromId(const Id: string): TZXMachineConfig;
begin
  // Unknown legacy settings retain the historical 48K fallback.
  Result := ForModel(zmSpectrum48);
  for var Model := Low(TZXMachineModel) to High(TZXMachineModel) do
  begin
    var Candidate := ForModel(Model);
    if SameText(Id, Candidate.Id) then
      Exit(Candidate);
  end;
  if SameText(Id, '+2') then
    Result := ForModel(zmSpectrumPlus2);
end;

class function TZXMachineConfig.FromLegacy(Is128, Pentagon: Boolean; RAMSizeKB: Integer): TZXMachineConfig;
begin
  Result := ForModel(zmSpectrum48);
  if Pentagon then
    case RAMSizeKB of
      128:
        Result.Model := zmPentagon128;
      512:
        Result.Model := zmPentagon512;
      1024:
        Result.Model := zmPentagon1024;
    else
      raise EArgumentException.Create('Unsupported Pentagon RAM size');
    end
  else if Is128 then
    Result.Model := zmSpectrum128;
end;

function TZXMachineConfig.NextDACDecodeMask: Byte;
const
  Masks: array[0..8] of Byte = ($FE, $02, $04, $08, $10, $20, $40, $80, $00);
begin
  if (NextDACMode < 0) or (NextDACMode > 8) then
    raise EArgumentException.Create('Unsupported Next-DAC port profile');
  Result := Masks[NextDACMode];
end;

function TZXMachineConfig.ConfigurationErrors: TArray<string>;

  procedure Add(const Message: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Message;
  end;

begin
  Result := nil;
  Profile;
  if (Ord(DivType) > Ord(High(TZXDivType))) or not ((DivRAMKB = 0) or (DivRAMKB = 128) or (DivRAMKB = 512)) then
    Add('Unsupported DivIDE/DivMMC configuration');
  if (DivType <> zdNone) and (Model = zmPentagon1024) then
    Add('DivIDE/divMMC ports conflict with Pentagon 1024SL EFF7 decoding; choose Pentagon 128/512 or disable the interface');
  if (DivType <> zdNone) and Scorpion then
    Add('Scorpion shadow ROM is not supported by the built-in esxDOS firmware; disable divIDE/divMMC for Scorpion');
  if (DivType = zdIDE) and (DAC = 3) then
    Add('DivIDE ATA and GS-port Covox both use port B3');
  if Ord(TKTiming) > Ord(High(TZXTKTiming)) then
    Add('Unsupported TK90X/TK95 video timing');
  if (NextDACMode < 0) or (NextDACMode > 8) then
    Add('Unsupported Next-DAC port profile');
  if (SIDModel < 0) or (SIDModel > 1) then
    Add('Unsupported SID model');
  if (SIDInterface < 0) or (SIDInterface > 1) then
    Add('Unsupported SID interface');
  if SID and SIDClock1MHz and ((SIDInterface <> 1) or SIDNTSC) then
    Add('The 1 MHz SID clock requires HardSID xxCF and cannot be combined with NTSC');
  if (DAC < 0) or (DAC > 6) then
    Add('Unsupported Spectrum DAC board');
  if (DivType = zdIDE) and (DAC = 6) and (NextDACMode in [0, 6]) then
    Add('DivIDE ATA and the selected Next-DAC GS alias both use port B3; choose another DAC port profile or interface');
  if (GeneralSoundRAMKB <> 0) and (GeneralSoundRAMKB <> 128) and (GeneralSoundRAMKB <> 512) then
    Add('Unsupported General Sound RAM size');
  if (NeoGSRAMKB <> 0) and (NeoGSRAMKB <> 512) and (NeoGSRAMKB <> 2048) and (NeoGSRAMKB <> 4096) then
    Add('Unsupported NeoGS RAM size');
  if (DMAUSCStereo < 0) or (DMAUSCStereo > 2) then
    Add('Unsupported DMA Ultrasound stereo layout');
  if MoonSound and MoonSoundIRQ and DMAUSC then
    Add('DMA Ultrasound and MoonSound IRQ share the interrupt bus; disable the MoonSound IRQ jumper');
  if DMAUSC and not (Model in [zmSpectrum128, zmSpectrumPlus2, zmSpectrumPlus2b, zmSpectrumPlus3,
      zmPentagon128, zmPentagon512, zmPentagon1024, zmScorpion256, zmProfi512, zmProfi1024]) then
    Add('DMA Ultrasound requires a supported 128K or expanded motherboard with physical RAM banking');
  if NeoGS then
  begin
    if GeneralSound then
      Add('NeoGS and General Sound share the same host ports; choose one board');
    if DivType = zdIDE then
      Add('NeoGS and divIDE ATA share ports B3/BB; choose divMMC or disable one interface');
    if (DAC = 3) or ((DAC = 6) and (NextDACMode in [0, 6])) then
      Add('NeoGS and the selected DAC share port B3; choose another DAC port profile or disable one board');
  end;
  if GeneralSound then
  begin
    if DivType = zdIDE then
      Add('General Sound and divIDE ATA share ports B3/BB; choose divMMC or disable one interface');
    if (DAC = 3) or ((DAC = 6) and (NextDACMode in [0, 6])) then
      Add('General Sound and the selected DAC share port B3; choose another DAC port profile or disable one board');
  end;
  if TurboSound and TurboSoundFM then
    Add('Turbo Sound and Turbo Sound FM replace the same PSG interface; choose one board');
  if TurboSoundFM and (Model = zmTimex2068) then
    Add('Turbo Sound FM requires the Spectrum PSG interface; TC2068 uses different AY ports');
  if SAA1099 and VideoTimex then
    Add('SAA1099 and Timex video both use port FF; choose one interface');
end;

procedure TZXMachineConfig.Validate;
begin
  var Errors := ConfigurationErrors;
  if Length(Errors) > 0 then
    raise EArgumentException.Create(string.Join(sLineBreak, Errors));
end;

function TZXMachineConfig.WithModel(Value: TZXMachineModel): TZXMachineConfig;
begin
  ForModel(Value);
  Result := Self;
  Result.Model := Value;
end;

function TZXMachineConfig.Id: string;
begin
  Result := Profile.Id;
end;

function TZXMachineConfig.TK: Boolean;
begin
  Result := Model in [zmTK90X, zmTK95];
end;

function TZXMachineConfig.Gama: Boolean;
begin
  Result := Model in [zmGama87, zmGama88, zmGama89];
end;

function TZXMachineConfig.ByteFamily: Boolean;
begin
  Result := Model in [zmByte, zmByte01];
end;

function TZXMachineConfig.Profi: Boolean;
begin
  Result := Model in [zmProfi512, zmProfi1024];
end;

function TZXMachineConfig.Scorpion: Boolean;
begin
  Result := Model = zmScorpion256;
end;

function TZXMachineConfig.Timex: Boolean;
begin
  Result := Model in [zmTimex2048, zmTimex2068];
end;

function TZXMachineConfig.VideoTimex: Boolean;
begin
  Result := TimexVideo or Timex;
end;

function TZXMachineConfig.Profile: TZXMachineProfile;
const
  Ids: array[TZXMachineModel] of string =
    ('48k', '16k', '128k', 'plus2', 'pentagon', 'pentagon512', 'pentagon1024', 'plus2b', 'plus3', 'tc2048', 'tc2068', 'scorpion', 'profi512', 'profi', 'byte', 'byte01', 'gama87', 'gama88', 'gama', 'tk90x', 'tk95');
  Names: array[TZXMachineModel] of string =
    ('ZX Spectrum 48K', 'ZX Spectrum 16K', 'ZX Spectrum 128K', 'ZX Spectrum +2',
    'Pentagon 128', 'Pentagon 512', 'Pentagon 1024', 'ZX Spectrum +2b', 'ZX Spectrum +3', 'Timex TC2048', 'Timex TC2068', 'Scorpion ZS-256', 'Profi+ 512K', 'Profi+ 1024K', 'Byte 48K', 'Byte-01 / KVU', 'Didaktik Gama 1987', 'Didaktik Gama 1988', 'Didaktik Gama 1989', 'Microdigital TK90X', 'Microdigital TK95');
  RAM: array[TZXMachineModel] of Integer = (48, 16, 128, 128, 128, 512, 1024, 128, 128, 48, 48, 256, 512, 1024, 48, 128, 80, 80, 80, 48, 48);
begin
  ForModel(Model); // Validate before indexing, including builds without range checks.
  Result := Default(TZXMachineProfile);
  Result.Id := Ids[Model];
  Result.Name := Names[Model];
  Result.RAMSizeKB := RAM[Model];
  Result.Has128Paging := Model in [zmSpectrum128, zmSpectrumPlus2, zmPentagon128, zmPentagon512, zmPentagon1024, zmSpectrumPlus2b, zmSpectrumPlus3, zmScorpion256, zmProfi512, zmProfi1024];
  Result.HasAY := Result.Has128Paging or (Model = zmTimex2068);
  Result.IsPentagon := Model in [zmPentagon128, zmPentagon512, zmPentagon1024];
  Result.ClockHz := 3500000;
  Result.LineCycles := 224;
  Result.FrameCycles := 69888;
  Result.DisplayStart := 14340;
  Result.ContentionStart := 14335;
  if Result.IsPentagon then
  begin
    Result.FrameCycles := 71680;
    Result.DisplayStart := 17984;
    Result.ContentionStart := 0;
  end
  else if Result.Has128Paging then
  begin
    Result.ClockHz := 3546900;
    Result.LineCycles := 228;
    Result.FrameCycles := 70908;
    Result.DisplayStart := 14366;
    Result.ContentionStart := 14361;
  end;
  if Scorpion then
  begin
    Result.ClockHz := 3500000;
    Result.LineCycles := 224;
    Result.FrameCycles := 69888;
    Result.DisplayStart := 14340;
    Result.ContentionStart := 0;
  end;
  if Profi then
  begin
    Result.ClockHz := 3500000;
    Result.LineCycles := 224;
    Result.FrameCycles := 69888;
    Result.DisplayStart := 12580;
    Result.ContentionStart := 0;
  end;
  if ByteFamily then
  begin
    Result.DisplayStart := 64 * 224 + 56;
    Result.ContentionStart := 0;
  end;
  if TK then
  begin
    // 14.302444 MHz master / 4; 456 pixel clocks per line, 262/312 lines.
    Result.ClockHz := 3575611;
    Result.LineCycles := 228;
    Result.FrameCycles := 262 * 228;
    Result.ContentionStart := 8759;
    Result.DisplayStart := 8764;
    if TKTiming = ztk50Hz then
    begin
      Result.FrameCycles := 312 * 228;
      Inc(Result.ContentionStart, 26 * 228);
      Inc(Result.DisplayStart, 26 * 228);
    end;
  end;
  if Timex then
  begin
    Result.DisplayStart := 14325;
    Result.ContentionStart := 14320;
  end;
  if Model in [zmSpectrumPlus2b, zmSpectrumPlus3] then
  begin
    Result.DisplayStart := 14364;
    Result.ContentionStart := 14365;
  end;
end;

end.

