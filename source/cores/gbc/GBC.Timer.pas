unit GBC.Timer;

interface

uses
  GB.Timer;

type
  TGBCTimer = class(TGBTimer)
  private
    class var
      FColorInstance: TGBCTimer;
    class function GetColorInstance: TGBCTimer; static;
  public
    constructor Create; reintroduce; overload;
    class procedure ReleaseInstance; reintroduce;
    class property Instance: TGBCTimer read GetColorInstance;
  end;

implementation

uses
  System.SysUtils, GBC.InterruptManager;

constructor TGBCTimer.Create;
begin
  inherited Create(TGBCInterruptManager.Instance, True);
end;

class function TGBCTimer.GetColorInstance: TGBCTimer;
begin
  if FColorInstance = nil then
    FColorInstance := TGBCTimer.Create;
  Result := FColorInstance;
end;

class procedure TGBCTimer.ReleaseInstance;
begin
  FreeAndNil(FColorInstance);
end;

end.

