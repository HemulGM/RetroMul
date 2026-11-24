program PS2GSPascalShaderTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, PS2.GS.PascalShaders;

procedure CheckShader(Kernel: TPS2GSKernel; Scale: Integer);
begin
  var Code := PS2GSKernelCode(Kernel, Scale);
  if (Length(Code) < 5) or (Code[0] <> $07230203) then
    raise Exception.CreateFmt('Invalid PS2 SPIR-V, kernel %d scale %d', [Ord(Kernel), Scale]);
  if ParamCount > 0 then
  begin
    var Name := Format('ps2-%d-%d.spv', [Ord(Kernel), Scale]);
    var Stream := TFileStream.Create(TPath.Combine(ParamStr(1), Name), fmCreate);
    try
      Stream.WriteBuffer(Code[0], Length(Code) * SizeOf(Cardinal));
    finally
      Stream.Free;
    end;
  end;
end;

begin
  try
    for var Kernel := Low(TPS2GSKernel) to High(TPS2GSKernel) do
      if Kernel = TPS2GSKernel.HLEUpload then
      begin
        for var Scale := 1 to 8 do
          CheckShader(Kernel, Scale);
      end
      else
        CheckShader(Kernel, 1);
    Writeln('PS2 Pascal shader modules compiled, including all eight upload scales.');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
