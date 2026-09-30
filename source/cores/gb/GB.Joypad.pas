unit GB.Joypad;

interface

uses
  Core.Snapshots, System.Classes, System.SysUtils, GB.InterruptManager;

{$SCOPEDENUMS ON}

type
  TGBKey = (Up = 0, Down = 1, Left = 2, Right = 3, A = 4, B = 5, Select = 6, Start = 7);

type
  TGBJoypad = class
  private
    class var
      FInstance: TGBJoypad;
    class function GetInstance: TGBJoypad; static;
  private
    FPressed: set of TGBKey;
    FSelection: Integer;
    procedure CheckInterrupt(Previous: Integer);
  public
    KeyBindings: array[TGBKey] of Integer;
    constructor Create; overload;
    function GetPressedKeys: Integer;
    procedure SetSelection(Value: Integer);
    procedure KeyDown(Key: Integer);
    procedure KeyUp(Key: Integer);
    class procedure ReleaseInstance;
    class property Instance: TGBJoypad read GetInstance;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

{ TGBJoypad }

constructor TGBJoypad.Create;
begin
  inherited;
  FSelection := $30;

  KeyBindings[TGBKey.Up] := 87;
  KeyBindings[TGBKey.Down] := 83;
  KeyBindings[TGBKey.Left] := 65;
  KeyBindings[TGBKey.Right] := 68;

  KeyBindings[TGBKey.A] := 74;
  KeyBindings[TGBKey.B] := 75;
  KeyBindings[TGBKey.Select] := 90;
  KeyBindings[TGBKey.Start] := 88;
end;

procedure TGBJoypad.CheckInterrupt(Previous: Integer);
begin
  if (Previous and not GetPressedKeys and $0F) <> 0 then
    TGBInterruptManager.Instance.RaiseInterruptByIndex(0);
end;

procedure TGBJoypad.KeyDown(Key: Integer);
begin
  var Previous := GetPressedKeys;
  for var Button := Low(TGBKey) to High(TGBKey) do
    if Key = KeyBindings[Button] then
      Include(FPressed, Button);
  CheckInterrupt(Previous);
end;

procedure TGBJoypad.KeyUp(Key: Integer);
begin
  for var Button := Low(TGBKey) to High(TGBKey) do
    if Key = KeyBindings[Button] then
      Exclude(FPressed, Button);
end;

function TGBJoypad.GetPressedKeys: Integer;
begin
  Result := $CF or FSelection;
  if (FSelection and $10) = 0 then
  begin
    if TGBKey.Right in FPressed then
      Result := Result and $FE;
    if TGBKey.Left in FPressed then
      Result := Result and $FD;
    if TGBKey.Up in FPressed then
      Result := Result and $FB;
    if TGBKey.Down in FPressed then
      Result := Result and $F7;
  end;
  if (FSelection and $20) = 0 then
  begin
    if TGBKey.A in FPressed then
      Result := Result and $FE;
    if TGBKey.B in FPressed then
      Result := Result and $FD;
    if TGBKey.Select in FPressed then
      Result := Result and $FB;
    if TGBKey.Start in FPressed then
      Result := Result and $F7;
  end;
end;

class function TGBJoypad.GetInstance: TGBJoypad;
begin
  if FInstance = nil then
    FInstance := TGBJoypad.Create;
  Result := FInstance;
end;

class procedure TGBJoypad.ReleaseInstance;
begin
  FreeAndNil(FInstance);
end;

procedure TGBJoypad.SetSelection(Value: Integer);
begin
  var Previous := GetPressedKeys;
  FSelection := Value and $30;
  CheckInterrupt(Previous);
end;


procedure TGBJoypad.SerializeState(State: TStateArchive);
begin
  State.Field(FPressed, SizeOf(FPressed));
  State.Field(FSelection, SizeOf(FSelection));
end;

end.
