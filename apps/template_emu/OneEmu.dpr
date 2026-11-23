program OneEmu;

uses
  System.StartUpCopy,
  FMX.Forms,
  OneEmu.Platform in 'OneEmu.Platform.pas',
  OneEmu.Main in 'OneEmu.Main.pas' {FormMain};

{$R *.res}

begin
  RegisterOneEmuPlatform;
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
