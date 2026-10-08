program RetromulTerm;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.Classes, System.UITypes,
  Winapi.Windows,
  FMX.Graphics,
  Core.Emulation,
  Core.EmulatorFactory,
  Core.Storage,
  Core.RomFormat,
  Core.RomHashes in '..\source\cores\Core.RomHashes.pas',
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
    {$IFDEF DEBUG}
    RomName := 'H:\ROMS\' + ROM_SYSTEM_NES + '\Super Mario Brothers' + ROM_EXTENSION_NES;
    //RomName := 'H:\ROMS\megadrive\Sonic The Hedgehog (USA, Europe).gen';
    //RomName := 'H:\ROMS\gb\DuckTales (USA).gb';
    {$ENDIF}
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

      FEmulation.SetKeyState(VK_LEFT, TRetromulTerminal.IsKeyDown(VK_LEFT));
      FEmulation.SetKeyState(VK_RIGHT, TRetromulTerminal.IsKeyDown(VK_RIGHT));
      FEmulation.SetKeyState(VK_UP, TRetromulTerminal.IsKeyDown(VK_UP));
      FEmulation.SetKeyState(VK_DOWN, TRetromulTerminal.IsKeyDown(VK_DOWN));
      FEmulation.SetKeyState(vkZ, TRetromulTerminal.IsKeyDown(vkZ));
      FEmulation.SetKeyState(vkX, TRetromulTerminal.IsKeyDown(vkX));
      FEmulation.SetKeyState(VK_RETURN, TRetromulTerminal.IsKeyDown(VK_RETURN));
      FEmulation.SetKeyState(VK_SPACE, TRetromulTerminal.IsKeyDown(VK_SPACE));

      if TRetromulTerminal.IsKeyDown(VK_ESCAPE) then
        Running := False;

      Sleep(16);
    end;
  finally
    TRetromulTerminal.Finalize;
  end;
end.

