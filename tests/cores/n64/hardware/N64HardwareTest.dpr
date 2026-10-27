program N64HardwareTest;

// The N64 core against PeterLemon's test ROMs (N64.HardwareTest):
// N64HardwareTest [roms folder] [manifest] [VIs] [ROMs at once]. Exit code 1
// when any differs.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, N64.HardwareTest;

begin
  var Report := TStringList.Create;
  try
    try
      var Here := ExtractFilePath(ParamStr(0));
      var Root := TPath.Combine(Here, '..\..\roms');
      var Manifest := TPath.Combine(Here, '..\..\manifest.txt');
      if ParamCount >= 1 then
        Root := ParamStr(1);
      if ParamCount >= 2 then
        Manifest := ParamStr(2);
      if ParamCount >= 3 then
        HardwareTestFrames := StrToInt(ParamStr(3));
      if ParamCount >= 4 then
        HardwareTestThreads := StrToInt(ParamStr(4));
      if not RunHardwareTest(Root, Manifest, Report) then
        ExitCode := 1;
    except
      on E: Exception do
      begin
        Report.Add(E.ClassName + ': ' + E.Message);
        ExitCode := 2;
      end;
    end;
    for var L in Report do
      Writeln(L);
  finally
    Report.Free;
  end;
end.
