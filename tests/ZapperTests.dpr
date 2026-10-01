program ZapperTests;

{$APPTYPE CONSOLE}
{$Q+}{$R+}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Hash,
  NES.Types, NES.Controller, NES.Bus, NES.Console, NES.PPU, NES.State;

procedure Check(Value: Boolean; const Text: string);
begin
  if not Value then
    raise Exception.Create(Text);
end;

procedure TestConsole;
type
  THeader = packed record
    Magic: array[0..7] of AnsiChar;
    Version, PayloadSize: UInt32;
    MapperId: Integer;
    RomHash: array[0..63] of AnsiChar;
    Digest: array[0..31] of Byte;
    Region: Byte;
  end;
begin
  var Dir := TPath.Combine(ExtractFilePath(ParamStr(0)), 'zapper-snapshots');
  ForceDirectories(Dir);
  var Rom: TBytes;
  SetLength(Rom, 16 + $4000);
  Rom[0] := $4E; Rom[1] := $45; Rom[2] := $53; Rom[3] := $1A;
  Rom[4] := 1;
  Rom[16] := $4C; Rom[17] := 0; Rom[18] := $80;
  Rom[16 + $3FFC] := 0; Rom[16 + $3FFD] := $80;
  var RomPath := TPath.Combine(Dir, 'zapper.nes');
  var StatePath := TPath.Combine(Dir, 'zapper.snapshot');
  TFile.WriteAllBytes(RomPath, Rom);
  var Core := TNesConsole.Create;
  try
    Core.LoadRom(RomPath);
    Core.Zapper.Enabled := True;
    Core.Zapper.TriggerPressed := True;
    Core.Zapper.OnReadLight := function(const Mask: TNesZapperMask): Boolean
      begin
        Result := True;
      end;
    Core.SaveSnapshot(StatePath);
    Core.Reset;
    Check(not Core.Zapper.TriggerPressed, 'Console reset releases trigger');
    Check(Core.Zapper.Enabled and Assigned(Core.Zapper.OnReadLight),
      'Console reset preserves host configuration');
    Core.Zapper.Enabled := False;
    Core.LoadSnapshot(StatePath);
    Check(Core.Zapper.Enabled and Core.Zapper.TriggerPressed, 'Console device restore');
    Check(Core.DebugCpuRead($4017) = $10, 'Console callback retained');
    var Other := TNesConsole.Create;
    try
      Other.LoadRom(RomPath);
      Other.LoadSnapshot(StatePath);
      Check(Other.DebugCpuRead($4017) = $18, 'Callback not serialized');
    finally
      Other.Free;
    end;

    // Version 4 appends two Boolean fields to the unchanged v3 payload.
    // Recreate v3 and verify that old snapshots still load with a host gun.
    var Bytes := TFile.ReadAllBytes(StatePath);
    var Header: THeader;
    Move(Bytes[0], Header, SizeOf(Header));
    Check(Header.Version = 4, 'New snapshot version');
    SetLength(Bytes, Length(Bytes) - 2 * (SizeOf(Integer) + SizeOf(Boolean)));
    Header.Version := 3;
    Header.PayloadSize := Length(Bytes) - SizeOf(Header);
    var Hash := THashSHA2.Create;
    Hash.Update(Bytes[SizeOf(Header)], Header.PayloadSize);
    var Digest := Hash.HashAsBytes;
    Move(Digest[0], Header.Digest[0], SizeOf(Header.Digest));
    Move(Header, Bytes[0], SizeOf(Header));
    TFile.WriteAllBytes(StatePath, Bytes);
    Core.LoadSnapshot(StatePath);
    Check(Core.Zapper.Enabled and not Core.Zapper.TriggerPressed,
      'Legacy snapshot retains connection and releases trigger');
    Check(Core.DebugCpuRead($4017) = 0, 'Legacy snapshot retains callback');
  finally
    Core.Free;
  end;
end;

procedure Run;
begin
  var Ppu := TPpu.Create;
  var Bus := TNesBus.Create;
  var Pad1 := TController.Create;
  var Pad2 := TController.Create;
  var Gun := TZapper.Create;
  var Saved := TMemoryStream.Create;
  try
    Bus.Connect(nil, Ppu, nil, Pad1, Pad2);
    Bus.Zapper := Gun;
    var Calls := 0;
    var Light := False;
    Gun.OnReadLight := function(const Mask: TNesZapperMask): Boolean
      begin
        Inc(Calls);
        Result := Light;
      end;
    Check(not Gun.Enabled, 'Zapper must default to disconnected');
    Bus.CpuRead($4017);
    Check(Calls = 0, 'Disconnected gun must not call the host');
    Gun.Enabled := True;
    Check(Bus.CpuRead($4017) = $08, 'Dark, released');
    Gun.TriggerPressed := True;
    Check(Bus.CpuRead($4017) = $18, 'Dark, pressed');
    Light := True;
    Check(Bus.CpuRead($4017) = $10, 'Light, pressed');
    Gun.TriggerPressed := False;
    Check(Bus.CpuRead($4017) = 0, 'Light, released');
    Pad2.PowerPadEnabled := True;
    Pad2.SetPowerPadButton(2, True);
    Bus.CpuWrite($4016, 1);
    for var I := 1 to 30 do
      Check(Bus.CpuRead($4017) = 0, 'Strobe/Power Pad must not affect Zapper');
    Bus.FourScoreEnabled := True;
    Bus.CpuWrite($4016, 0);
    for var I := 1 to 30 do
      Check(Bus.CpuRead($4017) = 0, 'Four Score must not affect Zapper');
    Pad1.SetButton(TNesButton.A, True);
    Bus.CpuWrite($4016, 1);
    Check(Bus.CpuRead($4016) = 1, 'Port 1 remains usable');
    Gun.OnReadLight := nil;
    Check(Bus.CpuRead($4017) = $08, 'Missing callback means no light');

    // White backdrop, rendering disabled: light sensing is independent of
    // sprite/background enable bits, just like the video output.
    Ppu.CpuWrite($2006, $3F);
    Ppu.CpuWrite($2006, 0);
    Ppu.CpuWrite($2007, $30);
    Gun.OnReadLight := function(const Mask: TNesZapperMask): Boolean
      begin
        Inc(Calls);
        Result := Mask[100, 10] <> 0;
      end;
    Check(Bus.CpuRead($4017) = $08, 'Undrawn frame is dark');
    while not ((Ppu.Scanline = 10) and (Ppu.Cycle = 1)) do Ppu.Clock;
    Check(Bus.CpuRead($4017) = $08, 'Target line has not been emitted yet');
    Ppu.Clock;
    Check(Bus.CpuRead($4017) = 0, 'Callback receives current bright target');
    Check(Ppu.GetZapperMask^[255, 10] = 1, 'Native X/Y coordinates');
    Check(Ppu.GetZapperMask^[100, 11] = 0, 'Future scanline must remain dark');
    while not ((Ppu.Scanline = 35) and (Ppu.Cycle = 2)) do Ppu.Clock;
    Check(Bus.CpuRead($4017) = 0, 'Light persists for 26 scanlines');
    while not ((Ppu.Scanline = 36) and (Ppu.Cycle = 2)) do Ppu.Clock;
    Check(Bus.CpuRead($4017) = $08, 'Old target must expire');

    // Snapshot restore must discard the derived mask and preserve the host.
    var Archive := TNesStateArchive.Create(Saved, False, 4);
    try
      Ppu.SerializeState(Archive);
      Gun.TriggerPressed := True;
      Gun.SerializeState(Archive);
    finally
      Archive.Free;
    end;
    Ppu.Reset;
    Check(Ppu.GetZapperMask^[100, 36] = 0, 'Reset clears light');
    Gun.Enabled := False;
    Gun.TriggerPressed := False;
    Saved.Position := 0;
    Archive := TNesStateArchive.Create(Saved, True, 4);
    try
      Ppu.SerializeState(Archive);
      Gun.SerializeState(Archive);
    finally
      Archive.Free;
    end;
    Check(Gun.Enabled and Gun.TriggerPressed, 'Device state restored');
    Check(Ppu.GetZapperMask^[100, 36] = 1, 'Mask rebuilt after load');
    var Before := Calls;
    Check(Bus.CpuRead($4017) = $18, 'Restored port state');
    Check(Calls = Before + 1, 'Host callback survives state load');

    for var Region := Low(TNesRegion) to High(TNesRegion) do
    begin
      Ppu.SetRegion(Region);
      Ppu.CpuWrite($2006, $3F);
      Ppu.CpuWrite($2006, 0);
      Ppu.CpuWrite($2007, $0F);
      while not ((Ppu.Scanline = 20) and (Ppu.Cycle = 2)) do Ppu.Clock;
      Check(Ppu.GetZapperMask^[100, 20] = 0, 'Black backdrop must stay dark');
      Ppu.CpuWrite($2006, $3F);
      Ppu.CpuWrite($2006, 0);
      Ppu.CpuWrite($2007, $30);
      while not ((Ppu.Scanline = 239) and (Ppu.Cycle = 2)) do Ppu.Clock;
      Check(Ppu.GetZapperMask^[100, 239] = 1, 'Last visible line detects light');
      while not ((Ppu.Scanline = 0) and (Ppu.Cycle = 2)) do Ppu.Clock;
      Check((Ppu.GetZapperMask^[100, 239] <> 0) = (Region = TNesRegion.NTSC),
        'Persistence across frame boundary respects region timing');
    end;
  finally
    Saved.Free;
    Gun.Free;
    Pad2.Free;
    Pad1.Free;
    Bus.Free;
    Ppu.Free;
  end;
end;

begin
  try
    Run;
    TestConsole;
    Writeln('Zapper tests passed');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
