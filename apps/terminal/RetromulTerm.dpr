program RetromulTerm;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  RetroMul.Platforms in '..\..\source\platforms\RetroMul.Platforms.pas',
  Yamaha.Sound.Y8950 in '..\..\source\hardware\audio\opl\Yamaha.Sound.Y8950.pas',

  HW.ARM.Shifter in '..\..\source\hardware\cpu\HW.ARM.Shifter.pas',
  Audio.ATRAC3.Decoder in '..\..\source\hardware\audio\atrac3\Audio.ATRAC3.Decoder.pas',
  Audio.ATRAC3 in '..\..\source\hardware\audio\atrac3\Audio.ATRAC3.pas',
  Core.Bitstream in '..\..\source\media\Core.Bitstream.pas',
  Video.AVC.Bitstream in '..\..\source\hardware\video\avc\Video.AVC.Bitstream.pas',
  Video.AVC.H264.CABAC in '..\..\source\hardware\video\avc\Video.AVC.H264.CABAC.pas',
  Video.AVC.H264.DSP in '..\..\source\hardware\video\avc\Video.AVC.H264.DSP.pas',
  Video.AVC.H264 in '..\..\source\hardware\video\avc\Video.AVC.H264.pas',
  Video.AVC.H264.Syntax in '..\..\source\hardware\video\avc\Video.AVC.H264.Syntax.pas',
  Video.AVC.H264.Tables in '..\..\source\hardware\video\avc\Video.AVC.H264.Tables.pas',
  Video.AVC.Types in '..\..\source\hardware\video\avc\Video.AVC.Types.pas',
  FMXAudio.AAC.ER in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.ER.pas',
  FMXAudio.AAC.LD in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.LD.pas',
  FMXAudio.AAC in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.pas',
  FMXAudio.AAC.PS in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.PS.pas',
  FMXAudio.AAC.SBR in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.SBR.pas',
  FMXAudio.AAC.SSR in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.SSR.pas',
  FMXAudio.AAC.Tables in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.Tables.pas',
  FMXAudio.AAC.USAC.LPC in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.USAC.LPC.pas',
  FMXAudio.AAC.USAC.LPD in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.USAC.LPD.pas',
  FMXAudio.AAC.USAC in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.USAC.pas',
  FMXAudio.Bitstream in '..\..\source\hardware\audio\codecs\FMXAudio.Bitstream.pas',
  FMXAudio.Transform in '..\..\source\hardware\audio\codecs\FMXAudio.Transform.pas',
  FMXAudio.Types in '..\..\source\hardware\audio\codecs\FMXAudio.Types.pas',
  Audio.ATRAC3Plus in '..\..\source\hardware\audio\atrac3plus\Audio.ATRAC3Plus.pas',
  Audio.ATRAC3Plus.Decoder in '..\..\source\hardware\audio\atrac3plus\Audio.ATRAC3Plus.Decoder.pas',
  Audio.ATRAC3Plus.Primitives in '..\..\source\hardware\audio\atrac3plus\Audio.ATRAC3Plus.Primitives.pas',
  Audio.ATRAC3Plus.Tables in '..\..\source\hardware\audio\atrac3plus\Audio.ATRAC3Plus.Tables.pas',
  System.SysUtils,
  System.Classes, System.UITypes,
  Winapi.Windows,
  FMX.Graphics,
  Core.Emulation,
  Core.EmulatorFactory, Core.PlatformServices,
  Core.Storage,
  Core.Platforms in '..\..\source\runtime\Core.Platforms.pas',
  Core.RomFormat,
  Core.RomHashes in '..\..\source\media\rom\Core.RomHashes.pas',
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
