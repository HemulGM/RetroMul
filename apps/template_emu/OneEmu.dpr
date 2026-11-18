program OneEmu;

uses
  System.StartUpCopy,
  FMX.Forms,
  OneEmu.Main in 'OneEmu.Main.pas' {FormMain};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
