program DCJitTest;

// The SH-4's generated code against its interpreter (DC.JitTest):
// DCJitTest [programs]. Exit code 1 when they differ.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, DC.JitTest;

begin
  var Report := TStringList.Create;
  try
    try
      var Programs := 100;
      if ParamCount >= 1 then
        Programs := StrToInt(ParamStr(1));
      if not RunDCJitTest(Programs, Report) then
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
