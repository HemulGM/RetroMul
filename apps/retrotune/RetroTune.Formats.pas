unit RetroTune.Formats;

interface

uses
  Audio.Registry;

var
  RetroTuneDecoders: IAudioRegistry;

function CreateRetroTuneFormats: IAudioRegistry;

// Called by the application before creating forms or starting playback.
procedure RegisterRetroTuneFormats;

implementation

uses
  System.SysUtils, Audio.Types, Audio.Decoder, Audio.Music.AHX,
  Audio.Music.Atari, Audio.Music.AY, Audio.Music.AYDumps, Audio.Music.Containers,
  Audio.Music.Digital, Audio.Music.DSF, Audio.Music.Furnace, Audio.Music.GBS,
  Audio.Music.GYM, Audio.Music.HES, Audio.Music.KSS, Audio.Format.MIDI,
  Audio.Music.NSF, Audio.Music.NSFe, Audio.Music.OPLDumps,
  Audio.Music.ProTracker, Audio.Music.PT3, Audio.Music.SAA, Audio.Music.SID,
  Audio.Music.SPC, Audio.Music.TIA, Audio.Music.TRDOS, Audio.Music.TurboFM,
  Audio.Music.VGM, Audio.Music.XGM, Audio.Music.XM, Audio.Music.ZXTrackers,
  Audio.MP3.Source, Audio.Format.AMR, Audio.Format.ADTS, Audio.Format.ATRAC,
  Audio.Format.FLAC, J2ME.IMelody, J2ME.SMAF;

function OpenIMelodyFile(const Data: TBytes): IAudioSource;
var
  Frames: Int64;
begin
  Result := OpenIMelody(Data, Frames);
end;

function CreateRetroTuneFormats: IAudioRegistry;
begin
  Result := TAudioRegistry.Create;
  Result.RegisterFormat('.aac', 'AAC (ADTS)', OpenADTS);
  Result.RegisterFormat('.adts', 'AAC (ADTS)', OpenADTS);
  Result.RegisterFormat('.at3', 'Sony ATRAC3 / ATRAC3plus', OpenATRAC);
  Result.RegisterFormat('.oma', 'Sony OpenMG ATRAC', OpenATRAC);
  Result.RegisterFormat('.aa3', 'Sony OpenMG ATRAC', OpenATRAC);
  Result.RegisterFormat('.flac', 'FLAC mono / stereo', OpenFLAC);
  Result.RegisterFormat('.mp3', 'MPEG Layer III', OpenMP3);
  Result.RegisterFormat('.mmf', 'Yamaha SMAF', OpenSMAF);
  Result.RegisterFormat('.imy', 'iMelody', OpenIMelodyFile);
  Result.RegisterFormat('.amr', 'AMR (Narrowband / Wideband)', OpenAMRForPlayback);
  Result.RegisterFormat('.awb', 'AMR-WB (Wideband)', OpenAMRForPlayback);
  Result.RegisterFormat('.ahx', 'Amiga AHX', Audio.Music.AHX.OpenAHX);
  Result.RegisterFormat('.hvl', 'HivelyTracker', Audio.Music.AHX.OpenAHX);
  Result.RegisterFormat('.d15', 'Atari MPT 15 kHz sample bank', Audio.Music.Atari.D15);
  Result.RegisterFormat('.md1', 'Atari Music ProTracker with samples', Audio.Music.Atari.MD1);
  Result.RegisterDataLoader('.md1', Audio.Music.Atari.ResolveMD1);
  Result.RegisterFormat('.sap', 'Atari SAP', Audio.Music.Atari.SAP);
  Result.RegisterFormat('.rmt', 'Raster Music Tracker', Audio.Music.Atari.RMT);
  Result.RegisterFormat('.ay', 'AY / ZX Spectrum / CPC', Audio.Music.AY.OpenAY);
  Result.RegisterFormat('.debugay', 'AY text register dump', Audio.Music.AYDumps.DebugAY);
  Result.RegisterFormat('.psg', 'AY register log', Audio.Music.AYDumps.PSG);
  Result.RegisterFormat('.ym', 'ST Sound YM', Audio.Music.AYDumps.YM);
  Result.RegisterFormat('.vtx', 'VTX AY/YM', Audio.Music.AYDumps.VTX);
  Result.RegisterFormat('.ayc', 'CPC AYC', Audio.Music.AYDumps.AYC);
  Result.RegisterFormat('.txt', 'Vortex Tracker text module', Audio.Music.Containers.OpenTXT);
  Result.RegisterFormat('.ts', 'TurboSound container', Audio.Music.Containers.OpenTS);
  Result.RegisterFormat('.mtc', 'Multitrack audio container', Audio.Music.Containers.OpenMTC);
  Result.RegisterFormat('.chi', 'Chip Tracker', Audio.Music.Digital.OpenCHI);
  Result.RegisterFormat('.dmm', 'Digital Music Maker', Audio.Music.Digital.OpenDMM);
  Result.RegisterFormat('.dst', 'Digital Studio', Audio.Music.Digital.OpenDST);
  Result.RegisterFormat('.sqd', 'SQ Digital Tracker', Audio.Music.Digital.OpenSQD);
  Result.RegisterFormat('.str', 'Sample Tracker', Audio.Music.Digital.OpenSTR);
  Result.RegisterFormat('.et1', 'Extreme Tracker', Audio.Music.Digital.OpenET1);
  Result.RegisterFormat('.pdt', 'ProDigiTracker', Audio.Music.Digital.OpenPDT);
  Result.RegisterFormat('.d', 'Extreme Tracker', Audio.Music.Digital.OpenET1);
  Result.RegisterFormat('.m', 'Extreme / ProDigiTracker', Audio.Music.Digital.OpenM);
  Result.RegisterFormat('.dsf', 'Dreamcast Sound Format', Audio.Music.DSF.OpenDSF);
  Result.RegisterFormat('.minidsf', 'Dreamcast Sound Format (shared libraries)', Audio.Music.DSF.OpenDSF);
  Result.RegisterDataLoader('.dsf', Audio.Music.DSF.ResolveDSF);
  Result.RegisterDataLoader('.minidsf', Audio.Music.DSF.ResolveDSF);
  Result.RegisterFormat('.fur', 'Furnace', Audio.Music.Furnace.OpenFurnace);
  Result.RegisterFormat('.gbs', 'Game Boy Sound', Audio.Music.GBS.CreateGBS);
  Result.RegisterFormat('.gym', 'Mega Drive GYM', Audio.Music.GYM.CreateGYM);
  Result.RegisterFormat('.hes', 'PC Engine HES', Audio.Music.HES.OpenHES);
  Result.RegisterFormat('.kss', 'MSX / Sega Master System KSS', Audio.Music.KSS.OpenKSS);
  Result.RegisterFormat('.mid', 'Standard MIDI File / General MIDI', Audio.Format.MIDI.OpenMidi);
  Result.RegisterFormat('.midi', 'Standard MIDI File / General MIDI', Audio.Format.MIDI.OpenMidi);
  Result.RegisterFormat('.rmi', 'RIFF MIDI / General MIDI', Audio.Format.MIDI.OpenMidi);
  Result.RegisterFormat('.kar', 'MIDI karaoke (audio)', Audio.Format.MIDI.OpenMidi);
  Result.RegisterFormat('.nsf', 'Nintendo Sound Format', Audio.Music.NSF.CreateNSF);
  Result.RegisterFormat('.nsf2', 'Nintendo Sound Format 2', Audio.Music.NSF.CreateNSF);
  Result.RegisterFormat('.nsfe', 'Extended Nintendo Sound Format', Audio.Music.NSFe.CreateNSFe);
  Result.RegisterFormat('.imf', 'id Software AdLib IMF (700 Hz)', Audio.Music.OPLDumps.OpenIMF);
  Result.RegisterFormat('.dro', 'DOSBox RAW OPL', Audio.Music.OPLDumps.OpenDRO);
  Result.RegisterFormat('.mod', 'Amiga SoundTracker / ProTracker MOD', Audio.Music.ProTracker.OpenMOD);
  Result.RegisterFormat('.pt3', 'Pro Tracker 3 / TurboSound', Audio.Music.PT3.CreatePT3);
  Result.RegisterFormat('.sng', 'SAM Coupe E-Tracker / SAA1099', Audio.Music.SAA.OpenSNG);
  Result.RegisterFormat('.cop', 'E-Tracker / SAA1099', Audio.Music.SAA.OpenCOP);
  Result.RegisterFormat('.etc', 'E-Tracker / SAA1099', Audio.Music.SAA.OpenCOP);
  Result.RegisterFormat('.tap', 'Spectrum tape with E-Tracker music', Audio.Music.SAA.OpenTAP);
  Result.RegisterFormat('.sid', 'SID / Commodore 64 (PSID)', Audio.Music.SID.OpenSID);
  Result.RegisterFormat('.spc', 'Super Nintendo SPC', Audio.Music.SPC.CreateSPC);
  Result.RegisterFormat('.ttt', 'TIATracker / Atari 2600', Audio.Music.TIA.OpenTTT);
  Result.RegisterFormat('.a26', 'Atari 2600 cartridge music', Audio.Music.TIA.OpenA26);
  Result.RegisterFormat('.trd', 'TR-DOS disk image', Audio.Music.TRDOS.OpenTRD);
  Result.RegisterFormat('.scl', 'SINCLAIR disk archive', Audio.Music.TRDOS.OpenSCL);
  Result.RegisterFormat('.tf0', 'TFM Music Maker 0.1–1.2', Audio.Music.TurboFM.OpenTF0);
  Result.RegisterFormat('.tfe', 'TFM Music Maker 1.3+', Audio.Music.TurboFM.OpenTFE);
  Result.RegisterFormat('.tfc', 'TurboFM Compiled', Audio.Music.TurboFM.OpenTFC);
  Result.RegisterFormat('.tfd', 'TurboFM Dump', Audio.Music.TurboFM.OpenTFD);
  Result.RegisterFormat('.vgm', 'Video Game Music', Audio.Music.VGM.CreateVGM);
  Result.RegisterFormat('.vgz', 'Compressed Video Game Music', Audio.Music.VGM.CreateVGM);
  Result.RegisterFormat('.wav', 'Wave audio (PCM / Float / ADPCM / ATRAC)', OpenWaveAudio);
  Result.RegisterFormat('.xm', 'FastTracker II XM', Audio.Music.XM.OpenXM);
  Result.RegisterFormat('.xgm', 'Mega Drive XGM / XGM2', Audio.Music.XGM.OpenXGM);
  Result.RegisterFormat('.xgm2', 'Mega Drive XGM2', Audio.Music.XGM.OpenXGM);
  Result.RegisterFormat('.xgc', 'Compiled Mega Drive XGM2', Audio.Music.XGM.OpenXGM);
  Result.RegisterFormat('.as0', 'ASC Sound Master 0', Audio.Music.ZXTrackers.OpenAS0);
  Result.RegisterFormat('.asc', 'ASC Sound Master', Audio.Music.ZXTrackers.OpenASC);
  Result.RegisterFormat('.ftc', 'Fast Tracker', Audio.Music.ZXTrackers.OpenFTC);
  Result.RegisterFormat('.gtr', 'Global Tracker', Audio.Music.ZXTrackers.OpenGTR);
  Result.RegisterFormat('.psc', 'Pro Sound Creator', Audio.Music.ZXTrackers.OpenPSC);
  Result.RegisterFormat('.psm', 'Pro Sound Maker', Audio.Music.ZXTrackers.OpenPSM);
  Result.RegisterFormat('.pt1', 'Pro Tracker 1', Audio.Music.ZXTrackers.OpenPT1);
  Result.RegisterFormat('.pt2', 'Pro Tracker 2', Audio.Music.ZXTrackers.OpenPT2);
  Result.RegisterFormat('.sqt', 'SQ-Tracker', Audio.Music.ZXTrackers.OpenSQT);
  Result.RegisterFormat('.st1', 'Sound Tracker editor', Audio.Music.ZXTrackers.OpenST1);
  Result.RegisterFormat('.st3', 'Sound Tracker 3 compilation', Audio.Music.ZXTrackers.OpenST3);
  Result.RegisterFormat('.stc', 'Sound Tracker', Audio.Music.ZXTrackers.OpenSTC);
  Result.RegisterFormat('.stp', 'Sound Tracker Pro', Audio.Music.ZXTrackers.OpenSTP);
  Result.RegisterFormat('.s', 'Sound Tracker editor', Audio.Music.ZXTrackers.OpenS);
end;

procedure RegisterRetroTuneFormats;
begin
  if RetroTuneDecoders = nil then
    RetroTuneDecoders := CreateRetroTuneFormats;
end;

end.

