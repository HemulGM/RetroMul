unit NES.Input;

interface

uses
  System.SysUtils, System.Generics.Collections, NES.Controller;

const
  INPUT_KEYBOARD = 0;
  INPUT_SCREEN_GAMEPAD = 1;
  INPUT_PLAYER_COUNT = 4;

type
  // Each physical device/backend owns a distinct source ID; 0 is the keyboard.
  // Releasing one source never releases a button held by another source.
  TNesInput = class
  private
    type
      TPlayerStates = array[1..INPUT_PLAYER_COUNT] of Byte;
  private
    FSources: TDictionary<UInt32, TPlayerStates>;
    procedure CheckPlayer(Player: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetButton(Source: UInt32; Player: Integer; Button: TNesButton; Pressed: Boolean);
    procedure SetKey(Player: Integer; Code: UInt32; Pressed: Boolean; const Keys: TKeyMap);
    procedure ReleaseSource(Source: UInt32);
    procedure Clear;
    function IsPressed(Player: Integer; Button: TNesButton): Boolean;
    procedure Apply(Player: Integer; Controller: TController);
  end;

implementation

constructor TNesInput.Create;
begin
  inherited;
  FSources := TDictionary<UInt32, TPlayerStates>.Create;
end;

destructor TNesInput.Destroy;
begin
  FSources.Free;
  inherited;
end;

procedure TNesInput.CheckPlayer(Player: Integer);
begin
  if (Player < 1) or (Player > INPUT_PLAYER_COUNT) then
    raise EArgumentOutOfRangeException.Create('Invalid input player');
end;

procedure TNesInput.SetButton(Source: UInt32; Player: Integer; Button: TNesButton; Pressed: Boolean);
begin
  CheckPlayer(Player);
  var States: TPlayerStates;
  if not FSources.TryGetValue(Source, States) then
    FillChar(States, SizeOf(States), 0);
  var Mask: Byte := 1 shl Ord(Button);
  if Pressed then
    States[Player] := States[Player] or Mask
  else
    States[Player] := States[Player] and not Mask;
  FSources.AddOrSetValue(Source, States);
end;

procedure TNesInput.SetKey(Player: Integer; Code: UInt32; Pressed: Boolean; const Keys: TKeyMap);
begin
  CheckPlayer(Player);
  if Code = Keys.A then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.A, Pressed);
  if Code = Keys.B then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.B, Pressed);
  if Code = Keys.Select then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Select, Pressed);
  if Code = Keys.Start then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Start, Pressed);
  if Code = Keys.Up then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Up, Pressed);
  if Code = Keys.Down then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Down, Pressed);
  if Code = Keys.Left then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Left, Pressed);
  if Code = Keys.Right then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Right, Pressed);
end;

procedure TNesInput.ReleaseSource(Source: UInt32);
begin
  FSources.Remove(Source);
end;

procedure TNesInput.Clear;
begin
  FSources.Clear;
end;

function TNesInput.IsPressed(Player: Integer; Button: TNesButton): Boolean;
begin
  CheckPlayer(Player);
  for var Pair in FSources do
    if (Pair.Value[Player] and (1 shl Ord(Button))) <> 0 then
      Exit(True);

  Result := False;
end;

procedure TNesInput.Apply(Player: Integer; Controller: TController);
begin
  CheckPlayer(Player);
  for var Button := Low(TNesButton) to High(TNesButton) do
    Controller.SetButton(Button, IsPressed(Player, Button));
end;

end.

