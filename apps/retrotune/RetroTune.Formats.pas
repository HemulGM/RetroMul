unit RetroTune.Formats;

interface

// Called by the application before creating forms or starting playback.
procedure RegisterRetroTuneFormats;

implementation

uses
  Music.Decoder, Music.Decoder.AHX, Music.Decoder.Atari, Music.Decoder.AY,
  Music.Decoder.AYDumps, Music.Decoder.Containers, Music.Decoder.Digital,
  Music.Decoder.DSF, Music.Decoder.GBS, Music.Decoder.GYM, Music.Decoder.HES,
  Music.Decoder.KSS, Music.Decoder.MIDI, Music.Decoder.NSF, Music.Decoder.NSFe,
  Music.Decoder.OPLDumps, Music.Decoder.ProTracker, Music.Decoder.PT3,
  Music.Decoder.SAA, Music.Decoder.SID, Music.Decoder.SPC, Music.Decoder.TIA,
  Music.Decoder.TRDOS, Music.Decoder.TurboFM, Music.Decoder.VGM,
  Music.Decoder.WAV, Music.Decoder.XGM, Music.Decoder.ZXTrackers;

var
  FormatsRegistered: Boolean;

procedure RegisterRetroTuneFormats;
begin
  if FormatsRegistered then
    Exit;
  TTuneDecoders.RegisterFormat('.ahx', 'Amiga AHX', Music.Decoder.AHX.OpenAHX);
  TTuneDecoders.RegisterFormat('.hvl', 'HivelyTracker', Music.Decoder.AHX.OpenAHX);
  TTuneDecoders.RegisterFormat('.d15', 'Atari MPT 15 kHz sample bank', Music.Decoder.Atari.D15);
  TTuneDecoders.RegisterFormat('.md1', 'Atari Music ProTracker with samples', Music.Decoder.Atari.MD1);
  TTuneDecoders.RegisterDataLoader('.md1', Music.Decoder.Atari.ResolveMD1);
  TTuneDecoders.RegisterFormat('.sap', 'Atari SAP', Music.Decoder.Atari.SAP);
  TTuneDecoders.RegisterFormat('.rmt', 'Raster Music Tracker', Music.Decoder.Atari.RMT);
  TTuneDecoders.RegisterFormat('.ay', 'AY / ZX Spectrum / CPC', Music.Decoder.AY.OpenAY);
  TTuneDecoders.RegisterFormat('.debugay', 'AY text register dump', Music.Decoder.AYDumps.DebugAY);
  TTuneDecoders.RegisterFormat('.psg', 'AY register log', Music.Decoder.AYDumps.PSG);
  TTuneDecoders.RegisterFormat('.ym', 'ST Sound YM', Music.Decoder.AYDumps.YM);
  TTuneDecoders.RegisterFormat('.vtx', 'VTX AY/YM', Music.Decoder.AYDumps.VTX);
  TTuneDecoders.RegisterFormat('.ayc', 'CPC AYC', Music.Decoder.AYDumps.AYC);
  TTuneDecoders.RegisterFormat('.txt', 'Vortex Tracker text module', Music.Decoder.Containers.OpenTXT);
  TTuneDecoders.RegisterFormat('.ts', 'TurboSound container', Music.Decoder.Containers.OpenTS);
  TTuneDecoders.RegisterFormat('.mtc', 'Multitrack audio container', Music.Decoder.Containers.OpenMTC);
  TTuneDecoders.RegisterFormat('.chi', 'Chip Tracker', Music.Decoder.Digital.OpenCHI);
  TTuneDecoders.RegisterFormat('.dmm', 'Digital Music Maker', Music.Decoder.Digital.OpenDMM);
  TTuneDecoders.RegisterFormat('.dst', 'Digital Studio', Music.Decoder.Digital.OpenDST);
  TTuneDecoders.RegisterFormat('.sqd', 'SQ Digital Tracker', Music.Decoder.Digital.OpenSQD);
  TTuneDecoders.RegisterFormat('.str', 'Sample Tracker', Music.Decoder.Digital.OpenSTR);
  TTuneDecoders.RegisterFormat('.et1', 'Extreme Tracker', Music.Decoder.Digital.OpenET1);
  TTuneDecoders.RegisterFormat('.pdt', 'ProDigiTracker', Music.Decoder.Digital.OpenPDT);
  TTuneDecoders.RegisterFormat('.d', 'Extreme Tracker', Music.Decoder.Digital.OpenET1);
  TTuneDecoders.RegisterFormat('.m', 'Extreme / ProDigiTracker', Music.Decoder.Digital.OpenM);
  TTuneDecoders.RegisterFormat('.dsf', 'Dreamcast Sound Format', Music.Decoder.DSF.OpenDSF);
  TTuneDecoders.RegisterFormat('.minidsf', 'Dreamcast Sound Format (shared libraries)', Music.Decoder.DSF.OpenDSF);
  TTuneDecoders.RegisterDataLoader('.dsf', Music.Decoder.DSF.ResolveDSF);
  TTuneDecoders.RegisterDataLoader('.minidsf', Music.Decoder.DSF.ResolveDSF);
  TTuneDecoders.RegisterFormat('.gbs', 'Game Boy Sound', Music.Decoder.GBS.CreateGBS);
  TTuneDecoders.RegisterFormat('.gym', 'Mega Drive GYM', Music.Decoder.GYM.CreateGYM);
  TTuneDecoders.RegisterFormat('.hes', 'PC Engine HES', Music.Decoder.HES.OpenHES);
  TTuneDecoders.RegisterFormat('.kss', 'MSX / Sega Master System KSS', Music.Decoder.KSS.OpenKSS);
  TTuneDecoders.RegisterFormat('.mid', 'Standard MIDI File / General MIDI', Music.Decoder.MIDI.OpenMidi);
  TTuneDecoders.RegisterFormat('.midi', 'Standard MIDI File / General MIDI', Music.Decoder.MIDI.OpenMidi);
  TTuneDecoders.RegisterFormat('.rmi', 'RIFF MIDI / General MIDI', Music.Decoder.MIDI.OpenMidi);
  TTuneDecoders.RegisterFormat('.kar', 'MIDI karaoke (audio)', Music.Decoder.MIDI.OpenMidi);
  TTuneDecoders.RegisterFormat('.nsf', 'Nintendo Sound Format', Music.Decoder.NSF.CreateNSF);
  TTuneDecoders.RegisterFormat('.nsf2', 'Nintendo Sound Format 2', Music.Decoder.NSF.CreateNSF);
  TTuneDecoders.RegisterFormat('.nsfe', 'Extended Nintendo Sound Format', Music.Decoder.NSFe.CreateNSFe);
  TTuneDecoders.RegisterFormat('.imf', 'id Software AdLib IMF (700 Hz)', Music.Decoder.OPLDumps.OpenIMF);
  TTuneDecoders.RegisterFormat('.dro', 'DOSBox RAW OPL', Music.Decoder.OPLDumps.OpenDRO);
  TTuneDecoders.RegisterFormat('.mod', 'Amiga SoundTracker / ProTracker MOD', Music.Decoder.ProTracker.OpenMOD);
  TTuneDecoders.RegisterFormat('.pt3', 'Pro Tracker 3 / TurboSound', Music.Decoder.PT3.CreatePT3);
  TTuneDecoders.RegisterFormat('.sng', 'SAM Coupe E-Tracker / SAA1099', Music.Decoder.SAA.OpenSNG);
  TTuneDecoders.RegisterFormat('.cop', 'E-Tracker / SAA1099', Music.Decoder.SAA.OpenCOP);
  TTuneDecoders.RegisterFormat('.etc', 'E-Tracker / SAA1099', Music.Decoder.SAA.OpenCOP);
  TTuneDecoders.RegisterFormat('.tap', 'Spectrum tape with E-Tracker music', Music.Decoder.SAA.OpenTAP);
  TTuneDecoders.RegisterFormat('.sid', 'SID / Commodore 64 (PSID)', Music.Decoder.SID.OpenSID);
  TTuneDecoders.RegisterFormat('.spc', 'Super Nintendo SPC', Music.Decoder.SPC.CreateSPC);
  TTuneDecoders.RegisterFormat('.ttt', 'TIATracker / Atari 2600', Music.Decoder.TIA.OpenTTT);
  TTuneDecoders.RegisterFormat('.a26', 'Atari 2600 cartridge music', Music.Decoder.TIA.OpenA26);
  TTuneDecoders.RegisterFormat('.trd', 'TR-DOS disk image', Music.Decoder.TRDOS.OpenTRD);
  TTuneDecoders.RegisterFormat('.scl', 'SINCLAIR disk archive', Music.Decoder.TRDOS.OpenSCL);
  TTuneDecoders.RegisterFormat('.tf0', 'TFM Music Maker 0.1–1.2', Music.Decoder.TurboFM.OpenTF0);
  TTuneDecoders.RegisterFormat('.tfe', 'TFM Music Maker 1.3+', Music.Decoder.TurboFM.OpenTFE);
  TTuneDecoders.RegisterFormat('.tfc', 'TurboFM Compiled', Music.Decoder.TurboFM.OpenTFC);
  TTuneDecoders.RegisterFormat('.tfd', 'TurboFM Dump', Music.Decoder.TurboFM.OpenTFD);
  TTuneDecoders.RegisterFormat('.vgm', 'Video Game Music', Music.Decoder.VGM.CreateVGM);
  TTuneDecoders.RegisterFormat('.vgz', 'Compressed Video Game Music', Music.Decoder.VGM.CreateVGM);
  TTuneDecoders.RegisterFormat('.wav', 'Wave audio (PCM / IEEE Float)', Music.Decoder.WAV.OpenWav);
  TTuneDecoders.RegisterFormat('.xgm', 'Mega Drive XGM / XGM2', Music.Decoder.XGM.OpenXGM);
  TTuneDecoders.RegisterFormat('.xgm2', 'Mega Drive XGM2', Music.Decoder.XGM.OpenXGM);
  TTuneDecoders.RegisterFormat('.xgc', 'Compiled Mega Drive XGM2', Music.Decoder.XGM.OpenXGM);
  TTuneDecoders.RegisterFormat('.as0', 'ASC Sound Master 0', Music.Decoder.ZXTrackers.OpenAS0);
  TTuneDecoders.RegisterFormat('.asc', 'ASC Sound Master', Music.Decoder.ZXTrackers.OpenASC);
  TTuneDecoders.RegisterFormat('.ftc', 'Fast Tracker', Music.Decoder.ZXTrackers.OpenFTC);
  TTuneDecoders.RegisterFormat('.gtr', 'Global Tracker', Music.Decoder.ZXTrackers.OpenGTR);
  TTuneDecoders.RegisterFormat('.psc', 'Pro Sound Creator', Music.Decoder.ZXTrackers.OpenPSC);
  TTuneDecoders.RegisterFormat('.psm', 'Pro Sound Maker', Music.Decoder.ZXTrackers.OpenPSM);
  TTuneDecoders.RegisterFormat('.pt1', 'Pro Tracker 1', Music.Decoder.ZXTrackers.OpenPT1);
  TTuneDecoders.RegisterFormat('.pt2', 'Pro Tracker 2', Music.Decoder.ZXTrackers.OpenPT2);
  TTuneDecoders.RegisterFormat('.sqt', 'SQ-Tracker', Music.Decoder.ZXTrackers.OpenSQT);
  TTuneDecoders.RegisterFormat('.st1', 'Sound Tracker editor', Music.Decoder.ZXTrackers.OpenST1);
  TTuneDecoders.RegisterFormat('.st3', 'Sound Tracker 3 compilation', Music.Decoder.ZXTrackers.OpenST3);
  TTuneDecoders.RegisterFormat('.stc', 'Sound Tracker', Music.Decoder.ZXTrackers.OpenSTC);
  TTuneDecoders.RegisterFormat('.stp', 'Sound Tracker Pro', Music.Decoder.ZXTrackers.OpenSTP);
  TTuneDecoders.RegisterFormat('.s', 'Sound Tracker editor', Music.Decoder.ZXTrackers.OpenS);
  FormatsRegistered := True;
end;

end.

