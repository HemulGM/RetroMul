program JitModelTest;

// HW.JIT's backend on this host against the model (HW.JIT.ModelTest):
// JitModelTest [seeds]. Exit code 1 when they differ.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, HW.JIT.ModelTest;

begin
  var Report := TStringList.Create;
  try
    try
      var Seeds := 3000;
      if ParamCount >= 1 then
        Seeds := StrToInt(ParamStr(1));
      if not RunJitModelTest(Seeds, Report) then
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
