unit GBC.Joypad;

interface

uses
  System.SysUtils, GBC.InterruptManager;

{$SCOPEDENUMS ON}

type
  TGBCKey = (Up = 0, Down = 1, Left = 2, Right = 3, A = 4, B = 5, Select = 6, Start = 7);

type
  TGBCJoypad = class
  private
    class var
      FInstance: TGBCJoypad;
    class function GetInstance: TGBCJoypad; static;
  private
    FPressed: set of TGBCKey;
    FSelection: Integer;
    procedure CheckInterrupt(Previous: Integer);
  public
    KeyBindings: array[TGBCKey] of Integer;
    constructor Create; overload;
    function GetPressedKeys: Integer;
    procedure SetSelection(Value: Integer);
    procedure KeyDown(Key: Integer);
    procedure KeyUp(Key: Integer);
    class procedure ReleaseInstance;
    class property Instance: TGBCJoypad read GetInstance;
  end;

implementation

{ TGBCJoypad }

constructor TGBCJoypad.Create;
begin
  inherited;
  FSelection := $30;

  KeyBindings[TGBCKey.Up] := 87;
  KeyBindings[TGBCKey.Down] := 83;
  KeyBindings[TGBCKey.Left] := 65;
  KeyBindings[TGBCKey.Right] := 68;

  KeyBindings[TGBCKey.A] := 74;
  KeyBindings[TGBCKey.B] := 75;
  KeyBindings[TGBCKey.Select] := 90;
  KeyBindings[TGBCKey.Start] := 88;
end;

procedure TGBCJoypad.CheckInterrupt(Previous: Integer);
begin
  if (Previous and not GetPressedKeys and $0F) <> 0 then
    TGBCInterruptManager.Instance.RaiseInterruptByIndex(0);
end;

procedure TGBCJoypad.KeyDown(Key: Integer);
begin
  var Previous := GetPressedKeys;
  for var Button := Low(TGBCKey) to High(TGBCKey) do
    if Key = KeyBindings[Button] then
      Include(FPressed, Button);
  CheckInterrupt(Previous);
end;

procedure TGBCJoypad.KeyUp(Key: Integer);
begin
  for var Button := Low(TGBCKey) to High(TGBCKey) do
    if Key = KeyBindings[Button] then
      Exclude(FPressed, Button);
end;

function TGBCJoypad.GetPressedKeys: Integer;
begin
  Result := $CF or FSelection;
  if (FSelection and $10) = 0 then
  begin
    if TGBCKey.Right in FPressed then Result := Result and $FE;
    if TGBCKey.Left in FPressed then Result := Result and $FD;
    if TGBCKey.Up in FPressed then Result := Result and $FB;
    if TGBCKey.Down in FPressed then Result := Result and $F7;
  end;
  if (FSelection and $20) = 0 then
  begin
    if TGBCKey.A in FPressed then Result := Result and $FE;
    if TGBCKey.B in FPressed then Result := Result and $FD;
    if TGBCKey.Select in FPressed then Result := Result and $FB;
    if TGBCKey.Start in FPressed then Result := Result and $F7;
  end;
end;

class function TGBCJoypad.GetInstance: TGBCJoypad;
begin
  if FInstance = nil then
    FInstance := TGBCJoypad.Create;
  Result := FInstance;
end;

class procedure TGBCJoypad.ReleaseInstance;
begin
  FreeAndNil(FInstance);
end;

procedure TGBCJoypad.SetSelection(Value: Integer);
begin
  var Previous := GetPressedKeys;
  FSelection := Value and $30;
  CheckInterrupt(Previous);
end;

end.