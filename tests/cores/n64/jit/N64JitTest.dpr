program N64JitTest;

// The N64 core's generated code against its interpreter (N64.JitTest):
// N64JitTest [programs]. Exit code 1 when they differ.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, N64.JitTest;

begin
  var Report := TStringList.Create;
  try
    try
      var Programs := 100;
      if ParamCount >= 1 then
        Programs := StrToInt(ParamStr(1));
      if not RunN64JitTest(Programs, Report) then
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
