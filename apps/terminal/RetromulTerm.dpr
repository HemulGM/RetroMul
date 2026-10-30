program RetromulTerm;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  NDS.BIOS in '..\..\source\cores\nds\NDS.BIOS.pas',
  NDS.RTC in '..\..\source\cores\nds\NDS.RTC.pas',
  NDS.Geometry in '..\..\source\cores\nds\NDS.Geometry.pas',
  RM.Platforms.NDS.Settings in '..\..\source\platforms\nds\RM.Platforms.NDS.Settings.pas',
  RM.Platforms.NDS in '..\..\source\platforms\nds\RM.Platforms.NDS.pas',
  RM.Platforms.NDS.Input in '..\..\source\platforms\nds\RM.Platforms.NDS.Input.pas',
  Core.Platforms.NDS.Adapter in '..\..\source\platforms\nds\Core.Platforms.NDS.Adapter.pas',
  Core.Platforms.NDS.Display in '..\..\source\platforms\nds\Core.Platforms.NDS.Display.pas',
  NDS.Video in '..\..\source\cores\nds\NDS.Video.pas',
  NDS.Sound in '..\..\source\cores\nds\NDS.Sound.pas',
  NDS.Console in '..\..\source\cores\nds\NDS.Console.pas',
  NDS.Cartridge in '..\..\source\cores\nds\NDS.Cartridge.pas',
  A5200.ANTIC in '..\..\source\cores\at5200\A5200.ANTIC.pas',
  A5200.Arithmetic in '..\..\source\cores\at5200\A5200.Arithmetic.pas',
  A5200.ASAP.CPU in '..\..\source\cores\at5200\A5200.ASAP.CPU.pas',
  A5200.ASAP.Info in '..\..\source\cores\at5200\A5200.ASAP.Info.pas',
  A5200.ASAP in '..\..\source\cores\at5200\A5200.ASAP.pas',
  A5200.ASAP.Types in '..\..\source\cores\at5200\A5200.ASAP.Types.pas',
  A5200.Audio.MPT in '..\..\source\cores\at5200\A5200.Audio.MPT.pas',
  A5200.AudioMachine in '..\..\source\cores\at5200\A5200.AudioMachine.pas',
  A5200.Cartridge in '..\..\source\cores\at5200\A5200.Cartridge.pas',
  A5200.Console in '..\..\source\cores\at5200\A5200.Console.pas',
  A5200.Controller in '..\..\source\cores\at5200\A5200.Controller.pas',
  A5200.CPU in '..\..\source\cores\at5200\A5200.CPU.pas',
  A5200.Emulation in '..\..\source\cores\at5200\A5200.Emulation.pas',
  A5200.Firmware in '..\..\source\cores\at5200\A5200.Firmware.pas',
  A5200.GTIA in '..\..\source\cores\at5200\A5200.GTIA.pas',
  A5200.POKEY.Engine in '..\..\source\cores\at5200\A5200.POKEY.Engine.pas',
  A5200.POKEY in '..\..\source\cores\at5200\A5200.POKEY.pas',
  A5200.POKEY.Types in '..\..\source\cores\at5200\A5200.POKEY.Types.pas',
  A5200.Types in '..\..\source\cores\at5200\A5200.Types.pas',
  Core.Platforms.Atari5200.Adapter in '..\..\source\platforms\at5200\Core.Platforms.Atari5200.Adapter.pas',
  RM.Platforms.Atari5200.Gamepads in '..\..\source\platforms\at5200\RM.Platforms.Atari5200.Gamepads.pas',
  RM.Platforms.Atari5200.Input in '..\..\source\platforms\at5200\RM.Platforms.Atari5200.Input.pas',
  RM.Platforms.Atari5200 in '..\..\source\platforms\at5200\RM.Platforms.Atari5200.pas',
  RM.Platforms.Atari5200.Settings in '..\..\source\platforms\at5200\RM.Platforms.Atari5200.Settings.pas',
  A2600.Types in '..\..\source\cores\at2600\A2600.Types.pas',
  A2600.CPU in '..\..\source\cores\at2600\A2600.CPU.pas',
  A2600.Cartridge in '..\..\source\cores\at2600\A2600.Cartridge.pas',
  A2600.DPC in '..\..\source\cores\at2600\A2600.DPC.pas',
  A2600.Supercharger in '..\..\source\cores\at2600\A2600.Supercharger.pas',
  A2600.Controller in '..\..\source\cores\at2600\A2600.Controller.pas',
  A2600.Paddle in '..\..\source\cores\at2600\A2600.Paddle.pas',
  A2600.RIOT in '..\..\source\cores\at2600\A2600.RIOT.pas',
  A2600.Palette in '..\..\source\cores\at2600\A2600.Palette.pas',
  A2600.TIA in '..\..\source\cores\at2600\A2600.TIA.pas',
  A2600.State in '..\..\source\cores\at2600\A2600.State.pas',
  RM.Platforms.Atari2600.Settings in '..\..\source\platforms\at2600\RM.Platforms.Atari2600.Settings.pas',
  A2600.Console in '..\..\source\cores\at2600\A2600.Console.pas',
  A2600.Emulation in '..\..\source\cores\at2600\A2600.Emulation.pas',
  Core.Platforms.Atari2600.Adapter in '..\..\source\platforms\at2600\Core.Platforms.Atari2600.Adapter.pas',
  RM.Platforms.Atari2600 in '..\..\source\platforms\at2600\RM.Platforms.Atari2600.pas',
  RM.Platforms.Atari2600.Gamepads in '..\..\source\platforms\at2600\RM.Platforms.Atari2600.Gamepads.pas',
  CV.Audio in '..\..\source\cores\colecovision\CV.Audio.pas',
  CV.Controller in '..\..\source\cores\colecovision\CV.Controller.pas',
  CV.F18A.GPU in '..\..\source\cores\colecovision\CV.F18A.GPU.pas',
  CV.F18A in '..\..\source\cores\colecovision\CV.F18A.pas',
  CV.SSTFlash in '..\..\source\cores\colecovision\CV.SSTFlash.pas',
  CV.Cartridge in '..\..\source\cores\colecovision\CV.Cartridge.pas',
  CV.Console in '..\..\source\cores\colecovision\CV.Console.pas',
  CV.Emulation in '..\..\source\cores\colecovision\CV.Emulation.pas',
  CV.Firmware in '..\..\source\cores\colecovision\CV.Firmware.pas',
  Core.Platforms.ColecoVision.Adapter in '..\..\source\platforms\colecovision\Core.Platforms.ColecoVision.Adapter.pas',
  RM.Platforms.ColecoVision.Gamepads in '..\..\source\platforms\colecovision\RM.Platforms.ColecoVision.Gamepads.pas',
  RM.Platforms.ColecoVision.Input in '..\..\source\platforms\colecovision\RM.Platforms.ColecoVision.Input.pas',
  RM.Platforms.ColecoVision in '..\..\source\platforms\colecovision\RM.Platforms.ColecoVision.pas',
  RM.Platforms.ColecoVision.Settings in '..\..\source\platforms\colecovision\RM.Platforms.ColecoVision.Settings.pas',
  RetroMul.Platforms in '..\retromul\RetroMul.Platforms.pas',
  HW.Sound.Y8950 in '..\..\source\hardware\audio\HW.Sound.Y8950.pas',

  HW.ARM in '..\..\source\hardware\cpu\HW.ARM.pas',
  Audio.ATRAC3.Decoder in '..\..\source\media\audio\atrac3\Audio.ATRAC3.Decoder.pas',
  Audio.ATRAC3 in '..\..\source\media\audio\atrac3\Audio.ATRAC3.pas',
  Core.Bitstream in '..\..\source\media\Core.Bitstream.pas',
  Video.AVC.Bitstream in '..\..\source\media\video\avc\Video.AVC.Bitstream.pas',
  Video.AVC.H264.CABAC in '..\..\source\media\video\avc\Video.AVC.H264.CABAC.pas',
  Video.AVC.H264.DSP in '..\..\source\media\video\avc\Video.AVC.H264.DSP.pas',
  Video.AVC.H264 in '..\..\source\media\video\avc\Video.AVC.H264.pas',
  Video.AVC.H264.Syntax in '..\..\source\media\video\avc\Video.AVC.H264.Syntax.pas',
  Video.AVC.H264.Tables in '..\..\source\media\video\avc\Video.AVC.H264.Tables.pas',
  Video.AVC.Types in '..\..\source\media\video\avc\Video.AVC.Types.pas',
  FMXAudio.AAC.ER in '..\..\source\media\audio\aac\FMXAudio.AAC.ER.pas',
  FMXAudio.AAC.LD in '..\..\source\media\audio\aac\FMXAudio.AAC.LD.pas',
  FMXAudio.AAC in '..\..\source\media\audio\aac\FMXAudio.AAC.pas',
  FMXAudio.AAC.PS in '..\..\source\media\audio\aac\FMXAudio.AAC.PS.pas',
  FMXAudio.AAC.SBR in '..\..\source\media\audio\aac\FMXAudio.AAC.SBR.pas',
  FMXAudio.AAC.SSR in '..\..\source\media\audio\aac\FMXAudio.AAC.SSR.pas',
  FMXAudio.AAC.Tables in '..\..\source\media\audio\aac\FMXAudio.AAC.Tables.pas',
  FMXAudio.AAC.USAC.LPC in '..\..\source\media\audio\aac\FMXAudio.AAC.USAC.LPC.pas',
  FMXAudio.AAC.USAC.LPD in '..\..\source\media\audio\aac\FMXAudio.AAC.USAC.LPD.pas',
  FMXAudio.AAC.USAC in '..\..\source\media\audio\aac\FMXAudio.AAC.USAC.pas',
  FMXAudio.Bitstream in '..\..\source\media\audio\common\FMXAudio.Bitstream.pas',
  FMXAudio.Transform in '..\..\source\media\audio\common\FMXAudio.Transform.pas',
  FMXAudio.Types in '..\..\source\media\common\FMXAudio.Types.pas',
  Audio.ATRAC3Plus in '..\..\source\media\audio\atrac3plus\Audio.ATRAC3Plus.pas',
  Audio.ATRAC3Plus.Decoder in '..\..\source\media\audio\atrac3plus\Audio.ATRAC3Plus.Decoder.pas',
  Audio.ATRAC3Plus.Primitives in '..\..\source\media\audio\atrac3plus\Audio.ATRAC3Plus.Primitives.pas',
  Audio.ATRAC3Plus.Tables in '..\..\source\media\audio\atrac3plus\Audio.ATRAC3Plus.Tables.pas',
  System.SysUtils,
  System.Classes, System.UITypes,
  Winapi.Windows,
  FMX.Graphics,
  Core.Emulation,
  Core.EmulatorFactory, Core.PlatformServices,
  Core.Storage,
  Core.Platforms in '..\..\source\runtime\Core.Platforms.pas',
  Retromul.Terminal in 'Retromul.Terminal.pas';

var
  Running: Boolean;
  FEmulation: IEmulationCore;
  FUserPaused: Boolean;
  FKeysDown: array[0..255] of Boolean;
  FEmulationFaulted: Boolean;
  FRomDisplayName: string;

procedure SetStatus(const Text: string);
begin
  TRetromulTerminal.SetTitle('RetromulTerm - ' + Text);
end;

procedure StopOnError;
begin
  FEmulationFaulted := True;
  if FEmulation <> nil then
    FEmulation.Pause;
  SetStatus('Stopped after error - ' + FRomDisplayName);
end;

procedure LoadRom(const FileName: string; const DisplayName: string);
begin
  // Construct first: an invalid ROM leaves the current worker running.
  var NewEmulation: IEmulationCore;
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try NewEmulation := CreateEmulationCore(Stream, Storage, FileName);
  finally Stream.Free; end;
  try
    if FEmulation <> nil then
      FEmulation.Stop;
  except
    NewEmulation := nil;
    raise;
  end;
  FEmulation := nil;
  FEmulation := NewEmulation;
  FUserPaused := False;
  FillChar(FKeysDown, SizeOf(FKeysDown), 0);
  FRomDisplayName := DisplayName;
  if FRomDisplayName = '' then
    FRomDisplayName := ExtractFileName(FileName);
  try
    TRetromulTerminal.Clear;
    FEmulationFaulted := False;
    FEmulation.Start;
    SetStatus(FEmulation.Name + ' - ' + FRomDisplayName);
  except
    StopOnError;
    raise;
  end;
end;

procedure UpdateFrame;
begin
  if FEmulation = nil then
    Exit;
  var Frame: TEmulatorFrame;
  var NewFrame := FEmulation.TryGetFrame(Frame);
  var ErrorText := FEmulation.TakeError;
  if (ErrorText <> '') and not FEmulationFaulted then
  begin
    StopOnError;
    raise Exception.Create(ErrorText);
  end;
  if not FEmulationFaulted and NewFrame then
  begin
    SetStatus(Format('%s - %.1f FPS', [FEmulation.Name, Frame.FramesPerSecond]));
  end;
  if not NewFrame then
    Exit;

  TRetromulTerminal.DrawFrame(Frame, TTerminalRenderMode.trmAscii, TRetromulTerminal.Width, TRetromulTerminal.Height - 2);
end;

begin
  TRetromulTerminal.Initialize;
  try
    TRetromulTerminal.SetTitle('RetroMul');
    TRetromulTerminal.Clear;
    var RomName := ParamStr(1);

    if RomName.IsEmpty then
    begin
      Writeln('Set file name as param 1');
      Exit;
    end;
    LoadRom(RomName, '');

    Running := True;
    while Running do
    begin
      try
        UpdateFrame;
      except
        StopOnError;
        raise;
      end;

      var InputPolicy := TerminalInputPolicy(FEmulation);
      if InputPolicy.AllKeys then
      begin
        for var Code := 1 to 255 do
        begin
          var Down := TRetromulTerminal.IsKeyDown(Code);
          if Down <> FKeysDown[Code] then FEmulation.SetKeyState(Code, Down);
          FKeysDown[Code] := Down;
        end;
      end
      else
      begin
        FEmulation.SetKeyState(VK_LEFT, TRetromulTerminal.IsKeyDown(VK_LEFT));
        FEmulation.SetKeyState(VK_RIGHT, TRetromulTerminal.IsKeyDown(VK_RIGHT));
        FEmulation.SetKeyState(VK_UP, TRetromulTerminal.IsKeyDown(VK_UP));
        FEmulation.SetKeyState(VK_DOWN, TRetromulTerminal.IsKeyDown(VK_DOWN));
        FEmulation.SetKeyState(vkZ, TRetromulTerminal.IsKeyDown(vkZ));
        FEmulation.SetKeyState(vkX, TRetromulTerminal.IsKeyDown(vkX));
        FEmulation.SetKeyState(VK_RETURN, TRetromulTerminal.IsKeyDown(VK_RETURN));
        FEmulation.SetKeyState(VK_SPACE, TRetromulTerminal.IsKeyDown(VK_SPACE));
      end;

      if TRetromulTerminal.IsKeyDown(InputPolicy.ExitKey) then
        Running := False;

      Sleep(16);
    end;
  finally
    TRetromulTerminal.Finalize;
  end;
end.
