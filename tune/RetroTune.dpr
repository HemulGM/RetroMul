program RetroTune;

uses

  System.StartUpCopy,
  FMX.Forms,
  C64.CPU in '..\source\cores\c64\C64.CPU.pas',
  C64.Sound.SID in '..\source\cores\c64\C64.Sound.SID.pas',
  C64.AudioMachine in '..\source\cores\c64\C64.AudioMachine.pas',
  ZX.AudioMachine in '..\source\cores\zx\ZX.AudioMachine.pas',
  ZX.Sound.YM2149 in '..\source\cores\zx\ZX.Sound.YM2149.pas',
  PC.OPL.Nuked in '..\source\cores\pc\PC.OPL.Nuked.pas',
  PC.Sound.OPL in '..\source\cores\pc\PC.Sound.OPL.pas',
  PC.Sound.OPL2 in '..\source\cores\pc\PC.Sound.OPL2.pas',
  PC.Sound.OPL3 in '..\source\cores\pc\PC.Sound.OPL3.pas',
  RetroTune.Main in 'RetroTune.Main.pas' {FormMain},
  RetroTune.Decoder in 'RetroTune.Decoder.pas',
  RetroTune.Decoder.NSF in 'RetroTune.Decoder.NSF.pas',
  RetroTune.Decoder.NSFe in 'RetroTune.Decoder.NSFe.pas',
  RetroTune.Decoder.SPC in 'RetroTune.Decoder.SPC.pas',
  RetroTune.Decoder.GBS in 'RetroTune.Decoder.GBS.pas',
  RetroTune.Decoder.VGM in 'RetroTune.Decoder.VGM.pas',
  RetroTune.PT3.Engine in 'RetroTune.PT3.Engine.pas',
  RetroTune.ZXTracker.Engine in 'RetroTune.ZXTracker.Engine.pas',
  RetroTune.Decoder.ZXTrackers in 'RetroTune.Decoder.ZXTrackers.pas',
  RetroTune.Compression.LH5 in 'RetroTune.Compression.LH5.pas',
  RetroTune.Decoder.AYDumps in 'RetroTune.Decoder.AYDumps.pas',
  RetroTune.Decoder.Atari in 'RetroTune.Decoder.Atari.pas',
  Atari.Audio.ASAP in '..\source\cores\atari\Atari.Audio.ASAP.pas',
  Atari.AudioMachine in '..\source\cores\atari\Atari.AudioMachine.pas',

  RetroTune.Decoder.AY in 'RetroTune.Decoder.AY.pas',
  RetroTune.Decoder.SID in 'RetroTune.Decoder.SID.pas',
  RetroTune.Decoder.PT3 in 'RetroTune.Decoder.PT3.pas',
  RetroTune.Decoder.GYM in 'RetroTune.Decoder.GYM.pas',
  RetroTune.Binary in 'RetroTune.Binary.pas',
  RetroTune.Player in 'RetroTune.Player.pas',
  RetroTune.Chip.FDS in 'RetroTune.Chip.FDS.pas',
  RetroTune.Spectrum in 'RetroTune.Spectrum.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
