unit RM.Controllers.Base;

interface

uses
  RM.Main, RM.Main.State, RM.Platform.Host;

type
  TMainController = class
  protected
    // Non-owning references; the form outlives its controllers.
    FView: TFormMain;
    FState: TMainState;
    FPlatformHost: IPlatformHost;
  public
    constructor Create(AView: TFormMain);
  end;

implementation

uses
  RM.Platform.Host.RetroMul;

constructor TMainController.Create(AView: TFormMain);
begin
  inherited Create;
  FView := AView;
  FState := AView.State;
  FPlatformHost := CreateRetroMulPlatformHost(AView);
end;

end.
