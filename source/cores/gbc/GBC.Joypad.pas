unit GBC.Joypad;

interface

uses
  GB.Joypad;

type
  TGBCKey = GB.Joypad.TGBKey;

  TGBCJoypad = class(TGBJoypad)
  private
    class var
      FColorInstance: TGBCJoypad;
    class function GetColorInstance: TGBCJoypad; static;
  public
    constructor Create; reintroduce; overload;
    class procedure ReleaseInstance; reintroduce;
    class property Instance: TGBCJoypad read GetColorInstance;
  end;

implementation

uses
  System.SysUtils, GBC.InterruptManager;

constructor TGBCJoypad.Create;
begin
  inherited Create(TGBCInterruptManager.Instance);
end;

class function TGBCJoypad.GetColorInstance: TGBCJoypad;
begin
  if FColorInstance = nil then
    FColorInstance := TGBCJoypad.Create;
  Result := FColorInstance;
end;

class procedure TGBCJoypad.ReleaseInstance;
begin
  FreeAndNil(FColorInstance);
end;

end.

