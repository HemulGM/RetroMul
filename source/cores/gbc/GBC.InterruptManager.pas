unit GBC.InterruptManager;

interface

uses
  GB.InterruptManager;

type
  TGBCInterrupt = GB.InterruptManager.TGBInterrupt;

  TGBCInterruptArray = GB.InterruptManager.TGBInterruptArray;

  TGBCInterruptManager = class(TGBInterruptManager)
  private
    class var
      FColorInstance: TGBCInterruptManager;
    class function GetColorInstance: TGBCInterruptManager; static;
  public
    class procedure ReleaseInstance; reintroduce;
    class property Instance: TGBCInterruptManager read GetColorInstance;
  end;

implementation

uses
  System.SysUtils;

class function TGBCInterruptManager.GetColorInstance: TGBCInterruptManager;
begin
  if FColorInstance = nil then
    FColorInstance := TGBCInterruptManager.Create;
  Result := FColorInstance;
end;

class procedure TGBCInterruptManager.ReleaseInstance;
begin
  FreeAndNil(FColorInstance);
end;

end.

