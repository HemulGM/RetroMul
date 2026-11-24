program PS2HLEConfigTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IniFiles, System.IOUtils, System.Math,
  Core.Storage, Core.Emulation, Core.Platforms.PS2.Adapter, RM.Vulkan.TexScale;

begin
  try
    if ParamStr(1) = '' then
      raise Exception.Create('Pass an isolated configuration test directory');
    var Root := TPath.GetFullPath(ParamStr(1));
    ForceDirectories(Root);
    var Storage: IStorage := TStorage.Create(Root);
    var Path := TPath.Combine(Root, 'ps2.ini');
    var Config := TPS2Config.Create(Path, Storage);
    var Common: IEmulatorConfig := Config;
    if (Config.Resolution <> 1) or (Config.TextureScale <> 0) or (Config.TextureFilter <> tfXBRZ) then
      raise Exception.Create('HLE enhancement defaults changed');
    var Checks := 0;
    for var Resolution in TArray<Integer>.Create(-100, 0, 1, 2, 3, 4, 6, 8, 100) do
      for var Scale in TArray<Integer>.Create(-1, 0, 1, 2, 3, 6, 99) do
        for var Filter in TArray<string>.Create('xbrz', 'hybrid', 'bicubic', 'unknown', '  HYBRID ') do
        begin
          var Ini := TMemIniFile.Create(Path);
          try
            Ini.WriteInteger('Video', 'Scale', 5);
            Ini.WriteString('Video', 'Filter', 'linear');
            Ini.WriteInteger('Video', 'Resolution', Resolution);
            Ini.WriteInteger('Video', 'TextureScale', Scale);
            Ini.WriteString('Video', 'TextureFilter', Filter);
            Ini.WriteString('Video', 'Renderer', 'vulkan-hle');
            Ini.UpdateFile;
          finally
            Ini.Free;
          end;
          Config.Load;
          var Expected := EnsureRange(Scale, 0, TexScaleMax);
          if Expected = 1 then
            Expected := 0;
          if (Config.Resolution <> EnsureRange(Resolution, 1, 8)) or (Config.TextureScale <> Expected) or
            (Config.TextureFilter <> TexScaleFilterFromName(Filter)) then
            raise Exception.Create('HLE setting normalization failed');
          if (Common.Scale <> 5) or (Common.Filter <> 'linear') then
            raise Exception.Create('HLE options replaced display scaling/filtering');
          Config.Save;
          Ini := TMemIniFile.Create(Path);
          try
            if (Ini.ReadInteger('Video', 'Resolution', 0) <> Config.Resolution) or
              (Ini.ReadInteger('Video', 'TextureScale', -1) <> Expected) or
              (Ini.ReadString('Video', 'TextureFilter', '') <> TexScaleFilterName(Config.TextureFilter)) or
              (Ini.ReadInteger('Video', 'Scale', 0) <> 5) or (Ini.ReadString('Video', 'Filter', '') <> 'linear') then
              raise Exception.Create('HLE configuration round trip failed');
          finally
            Ini.Free;
          end;
          Inc(Checks);
        end;
    Writeln('PS2 HLE settings: ', Checks, ' defaults/clamps/filters/independent display keys: OK');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
