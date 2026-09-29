program RetroMul;

{$R *.dres}

uses
  System.StartUpCopy,
  FMX.Forms,
  NES.Gamepad in 'NES.Gamepad.pas',
  NES.SuborKeyboard in 'NES.SuborKeyboard.pas',
  RM.Main in 'RM.Main.pas' {FormMain},
  {$IFDEF ANDROID}
  RM.RomPicker.Android in 'RM.RomPicker.Android.pas',
  {$ENDIF }
  {$IF Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Android.AudioTrack in '..\source\PCM\PCM.Audio.Android.AudioTrack.pas',
  {$ENDIF }
  {$IF Defined(MSWINDOWS) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Windows.MMSystem in '..\source\PCM\PCM.Audio.Windows.MMSystem.pas',
  {$ENDIF }
  {$IF Defined(LINUX) and not Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Linux.Alsa in '..\source\PCM\PCM.Audio.Linux.Alsa.pas',
  {$ENDIF }
  {$IF (Defined(MACOS) or Defined(IOS)) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Apple.AudioQueue in '..\source\PCM\PCM.Audio.Apple.AudioQueue.pas',
  {$ENDIF }
  PCM.Audio.Null in '..\source\PCM\PCM.Audio.Null.pas',
  PCM.Audio.Factory in '..\source\PCM\PCM.Audio.Factory.pas',
  PCM.Audio in '..\source\PCM\PCM.Audio.pas',
  PCM.Audio.Backend in '..\source\PCM\PCM.Audio.Backend.pas',
  Core.Emulation in '..\source\cores\Core.Emulation.pas',
  Core.EmulatorFactory in '..\source\cores\Core.EmulatorFactory.pas',
  Core.Adapter.NES in '..\source\cores\Core.Adapter.NES.pas',
  Core.Adapter.GB in '..\source\cores\Core.Adapter.GB.pas',
  Core.Adapter.GBC in '..\source\cores\Core.Adapter.GBC.pas',
  Core.Adapter.MD in '..\source\cores\Core.Adapter.MD.pas',
  MD.Arithmetic in '..\source\cores\md\MD.Arithmetic.pas',
  MD.Cartridge in '..\source\cores\md\MD.Cartridge.pas',
  MD.Console in '..\source\cores\md\MD.Console.pas',
  MD.M68k in '..\source\cores\md\MD.M68k.pas',
  MD.Z80 in '..\source\cores\md\MD.Z80.pas',
  MD.VDP in '..\source\cores\md\MD.VDP.pas',
  MD.Sound in '..\source\cores\md\MD.Sound.pas',
  NES.Mapper in '..\source\cores\nes\NES.Mapper.pas',
  NES.Mapper.Factory in '..\source\cores\nes\NES.Mapper.Factory.pas',
  NES.Mapper.ColorDreams in '..\source\cores\nes\mappers\NES.Mapper.ColorDreams.pas',
  NES.Mapper.Banked in '..\source\cores\nes\mappers\NES.Mapper.Banked.pas',
  NES.Mapper.Discrete in '..\source\cores\nes\mappers\NES.Mapper.Discrete.pas',
  NES.Mapper.MmcLatch in '..\source\cores\nes\mappers\NES.Mapper.MmcLatch.pas',
  NES.Mapper.Mmc3Variants in '..\source\cores\nes\mappers\NES.Mapper.Mmc3Variants.pas',
  NES.Mapper.Vrc in '..\source\cores\nes\mappers\NES.Mapper.Vrc.pas',
  NES.Mapper.Sunsoft in '..\source\cores\nes\mappers\NES.Mapper.Sunsoft.pas',
  NES.Mapper.Rambo in '..\source\cores\nes\mappers\NES.Mapper.Rambo.pas',
  NES.Mapper.Cony in '..\source\cores\nes\mappers\NES.Mapper.Cony.pas',
  NES.Mapper.Bandai in '..\source\cores\nes\mappers\NES.Mapper.Bandai.pas',
  NES.Mapper.Jy in '..\source\cores\nes\mappers\NES.Mapper.Jy.pas',
  NES.Mapper.Mmc5 in '..\source\cores\nes\mappers\NES.Mapper.Mmc5.pas',
  NES.Mapper.Subor in '..\source\cores\nes\mappers\NES.Mapper.Subor.pas',
  NES.Mapper.Mmc1 in '..\source\cores\nes\mappers\NES.Mapper.Mmc1.pas',
  NES.Mapper.Mmc3 in '..\source\cores\nes\mappers\NES.Mapper.Mmc3.pas',
  NES.Mapper.Nrom in '..\source\cores\nes\mappers\NES.Mapper.Nrom.pas',
  NES.Mapper.Uxrom in '..\source\cores\nes\mappers\NES.Mapper.Uxrom.pas',
  NES.Mapper.Axrom in '..\source\cores\nes\mappers\NES.Mapper.Axrom.pas',
  NES.Mapper.Cnrom in '..\source\cores\nes\mappers\NES.Mapper.Cnrom.pas',
  NES.Mapper.Gxrom in '..\source\cores\nes\mappers\NES.Mapper.Gxrom.pas',
  NES.PPU in '..\source\cores\nes\NES.PPU.pas',
  NES.State in '..\source\cores\nes\NES.State.pas',
  NES.Types in '..\source\cores\nes\NES.Types.pas',
  NES.APU in '..\source\cores\nes\NES.APU.pas',
  NES.AudioDiagnostics in '..\source\cores\nes\NES.AudioDiagnostics.pas',
  NES.Emulation in '..\source\cores\nes\NES.Emulation.pas',
  NES.Bus in '..\source\cores\nes\NES.Bus.pas',
  NES.Cartridge in '..\source\cores\nes\NES.Cartridge.pas',
  NES.RomMetadata in '..\source\cores\nes\NES.RomMetadata.pas',
  NES.Console in '..\source\cores\nes\NES.Console.pas',
  NES.Consts in '..\source\cores\nes\NES.Consts.pas',
  NES.Controller in '..\source\cores\nes\NES.Controller.pas',
  NES.Input in '..\source\cores\nes\NES.Input.pas',
  NES.CPU in '..\source\cores\nes\NES.CPU.pas',
  GB.Cartridge in '..\source\cores\gb\GB.Cartridge.pas',
  GB.CPU in '..\source\cores\gb\GB.CPU.pas',
  GB.EmulationThread in '..\source\cores\gb\GB.EmulationThread.pas',
  GB.GPU in '..\source\cores\gb\GB.GPU.pas',
  GB.InterruptManager in '..\source\cores\gb\GB.InterruptManager.pas',
  GB.Joypad in '..\source\cores\gb\GB.Joypad.pas',
  GB.MBC in '..\source\cores\gb\GB.MBC.pas',
  GB.Memory in '..\source\cores\gb\GB.Memory.pas',
  GB.Palettes in '..\source\cores\gb\GB.Palettes.pas',
  GB.ROM in '..\source\cores\gb\GB.ROM.pas',
  GB.Sound.Channel in '..\source\cores\gb\GB.Sound.Channel.pas',
  GB.Sound in '..\source\cores\gb\GB.Sound.pas',
  GB.Timer in '..\source\cores\gb\GB.Timer.pas',
  GBC.Cartridge in '..\source\cores\gbc\GBC.Cartridge.pas',
  GBC.CPU in '..\source\cores\gbc\GBC.CPU.pas',
  GBC.EmulationThread in '..\source\cores\gbc\GBC.EmulationThread.pas',
  GBC.GPU in '..\source\cores\gbc\GBC.GPU.pas',
  GBC.InterruptManager in '..\source\cores\gbc\GBC.InterruptManager.pas',
  GBC.Joypad in '..\source\cores\gbc\GBC.Joypad.pas',
  GBC.MBC in '..\source\cores\gbc\GBC.MBC.pas',
  GBC.Memory in '..\source\cores\gbc\GBC.Memory.pas',
  GBC.ROM in '..\source\cores\gbc\GBC.ROM.pas',
  GBC.Sound.Channel in '..\source\cores\gbc\GBC.Sound.Channel.pas',
  GBC.Sound in '..\source\cores\gbc\GBC.Sound.pas',
  GBC.Timer in '..\source\cores\gbc\GBC.Timer.pas',
  SCRP.GameList in '..\source\gamelist\SCRP.GameList.pas',
  RM.Styles in 'RM.Styles.pas' {FormStyles},
  FMX.Menus in 'DelphiWinUI3\Fixes\D13\FMX.Menus.pas',
  FMX.StyledContextMenu in 'DelphiWinUI3\Fixes\D13\FMX.StyledContextMenu.pas',
  FMX.Windows.Hints in 'DelphiWinUI3\FMXWindowsHint\FMX.Windows.Hints.pas',
  HGM.FMX.Image in 'HGM.FMX.Image.pas',
  Core.SavePaths in '..\source\cores\Core.SavePaths.pas';

{$R *.res}

begin
  Application.Initialize;
  FormStyles := TFormStyles.Create(Application);
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.

