unit RM.Input.Gamepads;

interface

uses
  System.SysUtils, System.Generics.Collections, FMXInput;

{$SCOPEDENUMS ON}
// Enum ordinals are persisted by the existing binding JSON. Append new controls;
// never reorder these values. Face buttons describe physical positions.
type
  TGamepadButton = (South, East, West, North, LeftShoulder, RightShoulder,
    LeftTrigger, RightTrigger, Select, Start, LeftStick, RightStick, Home,
    Up, Down, Left, Right);

  TGamepadAxis = (LeftX, LeftY, RightX, RightY, LeftTrigger, RightTrigger, DpadX, DpadY);

  TGamepadProfile = (Unknown, XInput, Android, Evdev, SonyHid, LogitechHid);

  TGamepadBackend = class(TInputBackend)
  private
    FNative: TInputBackend;
    FOwnsNative: Boolean;
    FSlots: array[0..11] of string;
    procedure SyncDevices;
  public
    constructor Create(Native: TInputBackend; OwnsNative: Boolean = True);
    destructor Destroy; override;
    procedure Refresh; override;
    procedure RefreshIfNeeded; override;
    function Poll: TArray<TInputValue>; override;
    procedure Reset; override;
    function ResolveSource(const Id: string): string;
    function SetRumble(const DeviceId: string; LowFrequency, HighFrequency: Word; DurationMs: UInt16): Boolean; override;
    procedure StopRumble(const DeviceId: string = ''); override;
  end;

  TGamepadInputManager = class(TInputManager)
  private
    FGamepads: TGamepadBackend;
  public
    constructor Create(Native: TInputBackend);
    function ResolveSource(const Id: string): string;
  end;

function GamepadProfile(const Device: TInputDevice): TGamepadProfile;

function NormalizeGamepadValue(const Device: TInputDevice; const Raw: TInputValue; out Value: TInputValue): Boolean;

function StandardGamepadId(Port: Integer): string;

function StandardGamepadPort(const Id: string): Integer;

function IsStandardGamepadId(const Id: string): Boolean;

function StandardGamepadSource(const PhysicalId: string): string;

function ResolveGamepadSource(Input: TInputManager; const Id: string): string;

function StandardGamepadCaption(const Binding: TInputBinding): string;

// Constructors operate on opaque action IDs; console layouts belong to the
// platform registration modules.
procedure AddStandardButton(Input: TInputManager; Port, Action: Integer; Button: TGamepadButton);

procedure AddStandardAxis(Input: TInputManager; Port, Action: Integer; Axis: TGamepadAxis; Direction: Integer);

procedure AddStandardTrigger(Input: TInputManager; Port, Action: Integer; Left: Boolean);

procedure AddStandardStick(Input: TInputManager; Port: Integer; Right: Boolean; const Actions: array of Integer);

procedure AddStandardDirection(Input: TInputManager; Port, Action: Integer; Direction: Integer; Stick: Boolean);

implementation

uses
  System.Math;

procedure AddStandardButton(Input: TInputManager; Port, Action: Integer; Button: TGamepadButton);
begin
  Input.AddBinding(TInputBinding.Create(Action, TInputValue.Create(StandardGamepadId(Port), TInputElementKind.Button, Ord(Button), 1)));
end;

procedure AddStandardAxis(Input: TInputManager; Port, Action: Integer; Axis: TGamepadAxis; Direction: Integer);
begin
  var B := Default(TInputBinding);
  B.Action := Action;
  B.DeviceId := StandardGamepadId(Port);
  B.Kind := TInputElementKind.Axis;
  B.Code := Ord(Axis);
  B.Direction := Direction;
  B.PressThreshold := 0.55;
  B.ReleaseThreshold := 0.40;
  if Axis in [TGamepadAxis.LeftTrigger, TGamepadAxis.RightTrigger] then
    B.AxisOrigin := -1;
  Input.AddBinding(B);
end;

procedure AddStandardTrigger(Input: TInputManager; Port, Action: Integer; Left: Boolean);
begin
  if Left then
  begin
    AddStandardAxis(Input, Port, Action, TGamepadAxis.LeftTrigger, 1);
    AddStandardButton(Input, Port, Action, TGamepadButton.LeftTrigger);
  end
  else
  begin
    AddStandardAxis(Input, Port, Action, TGamepadAxis.RightTrigger, 1);
    AddStandardButton(Input, Port, Action, TGamepadButton.RightTrigger);
  end;
end;

procedure AddStandardStick(Input: TInputManager; Port: Integer; Right: Boolean; const Actions: array of Integer);
begin
  if Length(Actions) <> 4 then
    raise EArgumentException.Create('Stick needs up/down/left/right actions');
  var X := TGamepadAxis.LeftX;
  var Y := TGamepadAxis.LeftY;
  if Right then
  begin
    X := TGamepadAxis.RightX;
    Y := TGamepadAxis.RightY;
  end;
  AddStandardAxis(Input, Port, Actions[0], Y, -1);
  AddStandardAxis(Input, Port, Actions[1], Y, 1);
  AddStandardAxis(Input, Port, Actions[2], X, -1);
  AddStandardAxis(Input, Port, Actions[3], X, 1);
end;

procedure AddStandardDirection(Input: TInputManager; Port, Action: Integer; Direction: Integer; Stick: Boolean);
const
  Buttons: array[0..3] of TGamepadButton = (TGamepadButton.Up, TGamepadButton.Down, TGamepadButton.Left, TGamepadButton.Right);
  Hats: array[0..3] of Integer = (0, 4, 6, 2);
begin
  AddStandardButton(Input, Port, Action, Buttons[Direction]);
  var Axis := TGamepadAxis.DpadX;
  var Sign := 1;
  if Direction < 2 then
    Axis := TGamepadAxis.DpadY;
  if Direction in [0, 2] then
    Sign := -1;
  AddStandardAxis(Input, Port, Action, Axis, Sign);
  var B := TInputBinding.Create(Action, TInputValue.Create(StandardGamepadId(Port), TInputElementKind.Hat, 0, Hats[Direction]));
  Input.AddBinding(B);
  if Stick then
  begin
    Axis := TGamepadAxis.LeftX;
    if Direction < 2 then
      Axis := TGamepadAxis.LeftY;
    AddStandardAxis(Input, Port, Action, Axis, Sign);
  end;
end;

const
  SlotPrefix = 'retromul:gamepad:slot:';
  SourcePrefix = 'retromul:gamepad:source:';

function StandardGamepadId(Port: Integer): string;
begin
  Result := SlotPrefix + IntToStr(Port + 1);
end;

function StandardGamepadPort(const Id: string): Integer;
begin
  Result := -1;
  if Id.StartsWith(SlotPrefix) then
    Result := StrToIntDef(Id.Substring(Length(SlotPrefix)), 0) - 1;
  if (Result < 0) or (Result > 11) then
    Result := -1;
end;

function StandardGamepadSource(const PhysicalId: string): string;
begin
  Result := SourcePrefix + PhysicalId;
end;

function IsStandardGamepadId(const Id: string): Boolean;
begin
  Result := (StandardGamepadPort(Id) >= 0) or Id.StartsWith(SourcePrefix);
end;

function HasElement(const D: TInputDevice; Kind: TInputElementKind; Code: Integer): Boolean;
begin
  for var E in D.Elements do
    if (E.Kind = Kind) and (E.Code = Code) then
      Exit(True);
  Result := False;
end;

function GamepadProfile(const Device: TInputDevice): TGamepadProfile;
begin
  Result := TGamepadProfile.Unknown;
  if Device.Kind <> TInputDeviceKind.Controller then
    Exit;
  // Backend namespaces take precedence: Sony in XInput/evdev is already translated.
  if Device.Id.Contains(':xinput:') then
    Exit(TGamepadProfile.XInput);
  if Device.Id.StartsWith('android:') then
    Exit(TGamepadProfile.Android);
  if Device.Id.StartsWith('linux:') then
    Exit(TGamepadProfile.Evdev);
  if Device.VendorId = $054C then
    case Device.ProductId of
      $05C4, $09CC, $0CE6, $0DF2:
        Exit(TGamepadProfile.SonyHid);
    end;
  if Device.VendorId = $046D then
    case Device.ProductId of
      $C216, $C218, $C219:
        Exit(TGamepadProfile.LogitechHid);
    end;
end;

function NormalizeGamepadValue(const Device: TInputDevice; const Raw: TInputValue; out Value: TInputValue): Boolean;
var
  Code: Integer;
  Profile: TGamepadProfile;

  procedure Button(B: TGamepadButton);
  begin
    Code := Ord(B);
  end;

  procedure Axis(A: TGamepadAxis);
  begin
    Code := Ord(A);
  end;

begin
  Value := Raw;
  Code := -1;
  if (Raw.DeviceId <> Device.Id) or not Device.Available then
    Exit(False);
  Profile := GamepadProfile(Device);
  if Profile = TGamepadProfile.Unknown then
    Exit(False);
  if Raw.Kind = TInputElementKind.Hat then
  begin
    Value.Code := 0;
    Exit(True);
  end;
  if Raw.Kind = TInputElementKind.Button then
  begin
    case Profile of
      TGamepadProfile.XInput:
        case Raw.Code of
          0:
            Button(TGamepadButton.Up);
          1:
            Button(TGamepadButton.Down);
          2:
            Button(TGamepadButton.Left);
          3:
            Button(TGamepadButton.Right);
          4:
            Button(TGamepadButton.Start);
          5:
            Button(TGamepadButton.Select);
          6:
            Button(TGamepadButton.LeftStick);
          7:
            Button(TGamepadButton.RightStick);
          8:
            Button(TGamepadButton.LeftShoulder);
          9:
            Button(TGamepadButton.RightShoulder);
          10:
            Button(TGamepadButton.Home);
          12:
            Button(TGamepadButton.South);
          13:
            Button(TGamepadButton.East);
          14:
            Button(TGamepadButton.West);
          15:
            Button(TGamepadButton.North);
        end;
      TGamepadProfile.Android:
        case Raw.Code of
          19:
            Button(TGamepadButton.Up);
          20:
            Button(TGamepadButton.Down);
          21:
            Button(TGamepadButton.Left);
          22:
            Button(TGamepadButton.Right);
          96:
            Button(TGamepadButton.South);
          97:
            Button(TGamepadButton.East);
          99:
            Button(TGamepadButton.West);
          100:
            Button(TGamepadButton.North);
          102:
            Button(TGamepadButton.LeftShoulder);
          103:
            Button(TGamepadButton.RightShoulder);
          104:
            if not HasElement(Device, TInputElementKind.Axis, 17) and not HasElement(Device, TInputElementKind.Axis, 23) then
              Button(TGamepadButton.LeftTrigger);
          105:
            if not HasElement(Device, TInputElementKind.Axis, 18) and not HasElement(Device, TInputElementKind.Axis, 22) then
              Button(TGamepadButton.RightTrigger);
          106:
            Button(TGamepadButton.LeftStick);
          107:
            Button(TGamepadButton.RightStick);
          108:
            Button(TGamepadButton.Start);
          109:
            Button(TGamepadButton.Select);
          3, 82, 110:
            Button(TGamepadButton.Home);
        end;
      TGamepadProfile.Evdev:
        case Raw.Code of
          $130:
            Button(TGamepadButton.South);
          $131:
            Button(TGamepadButton.East);
          $134:
            Button(TGamepadButton.West);
          $133:
            Button(TGamepadButton.North);
          $136:
            Button(TGamepadButton.LeftShoulder);
          $137:
            Button(TGamepadButton.RightShoulder);
          $138:
            if not HasElement(Device, TInputElementKind.Axis, 2) then
              Button(TGamepadButton.LeftTrigger);
          $139:
            if not HasElement(Device, TInputElementKind.Axis, 5) then
              Button(TGamepadButton.RightTrigger);
          $13A:
            Button(TGamepadButton.Select);
          $13B:
            Button(TGamepadButton.Start);
          $13C:
            Button(TGamepadButton.Home);
          $13D:
            Button(TGamepadButton.LeftStick);
          $13E:
            Button(TGamepadButton.RightStick);
          $220:
            Button(TGamepadButton.Up);
          $221:
            Button(TGamepadButton.Down);
          $222:
            Button(TGamepadButton.Left);
          $223:
            Button(TGamepadButton.Right);
        end;
      TGamepadProfile.SonyHid, TGamepadProfile.LogitechHid:
        case Raw.Code of
          1:
            Button(TGamepadButton.West);
          2:
            Button(TGamepadButton.South);
          3:
            Button(TGamepadButton.East);
          4:
            Button(TGamepadButton.North);
          5:
            Button(TGamepadButton.LeftShoulder);
          6:
            Button(TGamepadButton.RightShoulder);
          7:
            if (Profile <> TGamepadProfile.SonyHid) or not HasElement(Device, TInputElementKind.Axis, $33) then
              Button(TGamepadButton.LeftTrigger);
          8:
            if (Profile <> TGamepadProfile.SonyHid) or not HasElement(Device, TInputElementKind.Axis, $34) then
              Button(TGamepadButton.RightTrigger);
          9:
            Button(TGamepadButton.Select);
          10:
            Button(TGamepadButton.Start);
          11:
            Button(TGamepadButton.LeftStick);
          12:
            Button(TGamepadButton.RightStick);
          13:
            Button(TGamepadButton.Home);
        end;
    end;
  end
  else if Raw.Kind = TInputElementKind.Axis then
  begin
    case Profile of
      TGamepadProfile.XInput:
        case Raw.Code of
          0:
            Axis(TGamepadAxis.LeftX);
          1:
            begin
              Axis(TGamepadAxis.LeftY);
              Value.Value := -Raw.Value;
            end;
          2:
            Axis(TGamepadAxis.RightX);
          3:
            begin
              Axis(TGamepadAxis.RightY);
              Value.Value := -Raw.Value;
            end;
          4:
            begin
              Axis(TGamepadAxis.LeftTrigger);
              Value.Value := Raw.Value * 2 - 1;
            end;
          5:
            begin
              Axis(TGamepadAxis.RightTrigger);
              Value.Value := Raw.Value * 2 - 1;
            end;
        end;
      TGamepadProfile.Android:
        case Raw.Code of
          0:
            Axis(TGamepadAxis.LeftX);
          1:
            Axis(TGamepadAxis.LeftY);
          11:
            Axis(TGamepadAxis.RightX);
          14:
            Axis(TGamepadAxis.RightY);
          12:
            if not HasElement(Device, TInputElementKind.Axis, 11) then
              Axis(TGamepadAxis.RightX);
          13:
            if not HasElement(Device, TInputElementKind.Axis, 14) then
              Axis(TGamepadAxis.RightY);
          17:
            Axis(TGamepadAxis.LeftTrigger);
          18:
            Axis(TGamepadAxis.RightTrigger);
          23:
            if not HasElement(Device, TInputElementKind.Axis, 17) then
              Axis(TGamepadAxis.LeftTrigger);
          22:
            if not HasElement(Device, TInputElementKind.Axis, 18) then
              Axis(TGamepadAxis.RightTrigger);
          15:
            Axis(TGamepadAxis.DpadX);
          16:
            Axis(TGamepadAxis.DpadY);
        end;
      TGamepadProfile.Evdev:
        case Raw.Code of
          0:
            Axis(TGamepadAxis.LeftX);
          1:
            Axis(TGamepadAxis.LeftY);
          3:
            Axis(TGamepadAxis.RightX);
          4:
            Axis(TGamepadAxis.RightY);
          2:
            Axis(TGamepadAxis.LeftTrigger);
          5:
            Axis(TGamepadAxis.RightTrigger);
          $10:
            Axis(TGamepadAxis.DpadX);
          $11:
            Axis(TGamepadAxis.DpadY);
        end;
      TGamepadProfile.SonyHid:
        case Raw.Code of
          $30:
            Axis(TGamepadAxis.LeftX);
          $31:
            Axis(TGamepadAxis.LeftY);
          $32:
            Axis(TGamepadAxis.RightX);
          $35:
            Axis(TGamepadAxis.RightY);
          $33:
            Axis(TGamepadAxis.LeftTrigger);
          $34:
            Axis(TGamepadAxis.RightTrigger);
        end;
      TGamepadProfile.LogitechHid:
        case Raw.Code of
          $30:
            Axis(TGamepadAxis.LeftX);
          $31:
            Axis(TGamepadAxis.LeftY);
        end;
    end;
    Value.Value := EnsureRange(Value.Value, -1.0, 1.0);
  end;
  Value.Code := Code;
  Result := Code >= 0;
end;

constructor TGamepadBackend.Create(Native: TInputBackend; OwnsNative: Boolean);
begin
  inherited Create;
  if Native = nil then
    raise EArgumentNilException.Create('Native');
  FNative := Native;
  FOwnsNative := OwnsNative;
  DeviceListMode := Native.DeviceListMode;
  SyncDevices;
end;

destructor TGamepadBackend.Destroy;
begin
  if FOwnsNative then
    FNative.Free;
  inherited;
end;

procedure TGamepadBackend.SyncDevices;
begin
  FDevices := FNative.Devices;
  for var I := 0 to High(FSlots) do
  begin
    var Found := False;
    for var D in FDevices do
      if (D.Id = FSlots[I]) and D.Available and (GamepadProfile(D) <> TGamepadProfile.Unknown) then
        Found := True;
    if not Found then
      FSlots[I] := '';
  end;
  for var D in FDevices do
    if D.Available and (GamepadProfile(D) <> TGamepadProfile.Unknown) then
    begin
      var Found := False;
      for var Id in FSlots do
        if Id = D.Id then
          Found := True;
      if not Found then
        for var I := 0 to High(FSlots) do
          if FSlots[I] = '' then
          begin
            FSlots[I] := D.Id;
            Break;
          end;
    end;
end;

procedure TGamepadBackend.Refresh;
begin
  FNative.Refresh;
  SyncDevices;
end;

procedure TGamepadBackend.RefreshIfNeeded;
begin
  FNative.RefreshIfNeeded;
  SyncDevices;
end;

procedure TGamepadBackend.Reset;
begin
  FNative.Reset;
end;

function TGamepadBackend.Poll: TArray<TInputValue>;
begin
  // Keep raw values first so manual capture always records the native source.
  // Alias streams are values only: device pickers still list each real pad once.
  Result := FNative.Poll;
  SyncDevices;
  var Extra := TList<TInputValue>.Create;
  try
    for var V in Result do
      for var D in FDevices do
        if D.Id = V.DeviceId then
        begin
          var N: TInputValue;
          if not NormalizeGamepadValue(D, V, N) then
            Break;
          N.DeviceId := StandardGamepadSource(D.Id);
          Extra.Add(N);
          for var I := 0 to High(FSlots) do
            if FSlots[I] = D.Id then
            begin
              N.DeviceId := StandardGamepadId(I);
              Extra.Add(N);
              Break;
            end;
          Break;
        end;
    Result := Result + Extra.ToArray;
  finally
    Extra.Free;
  end;
end;

function TGamepadBackend.ResolveSource(const Id: string): string;
begin
  Result := Id;
  var Port := StandardGamepadPort(Id);
  if Port >= 0 then
    Exit(FSlots[Port]);
  if Id.StartsWith(SourcePrefix) then
    Result := Id.Substring(Length(SourcePrefix));
end;

function TGamepadBackend.SetRumble(const DeviceId: string; LowFrequency, HighFrequency: Word; DurationMs: UInt16): Boolean;
begin
  var Id := ResolveSource(DeviceId);
  Result := (Id <> '') and FNative.SetRumble(Id, LowFrequency, HighFrequency, DurationMs);
end;

procedure TGamepadBackend.StopRumble(const DeviceId: string);
begin
  var Id := ResolveSource(DeviceId);
  if (DeviceId = '') or (Id <> '') then
    FNative.StopRumble(Id);
end;

constructor TGamepadInputManager.Create(Native: TInputBackend);
begin
  FGamepads := TGamepadBackend.Create(Native);
  inherited Create(FGamepads);
end;

function TGamepadInputManager.ResolveSource(const Id: string): string;
begin
  Result := FGamepads.ResolveSource(Id);
end;

function ResolveGamepadSource(Input: TInputManager; const Id: string): string;
begin
  if Input is TGamepadInputManager then
    Exit(TGamepadInputManager(Input).ResolveSource(Id));
  if Id.StartsWith(SourcePrefix) then
    Exit(Id.Substring(Length(SourcePrefix)));
  if StandardGamepadPort(Id) >= 0 then
    Exit('');
  Result := Id;
end;

function StandardGamepadCaption(const Binding: TInputBinding): string;
const
  Buttons: array[TGamepadButton] of string = ('A / Cross', 'B / Circle', 'X / Square', 'Y / Triangle',
    'L1', 'R1', 'L2', 'R2', 'Select / Back', 'Start', 'L3', 'R3', 'Home', '↑', '↓', '←', '→');
  Axes: array[TGamepadAxis] of string = ('LS X', 'LS Y', 'RS X', 'RS Y', 'L2', 'R2', 'D-pad X', 'D-pad Y');
begin
  Result := '';
  if not IsStandardGamepadId(Binding.DeviceId) then
    Exit;
  if (Binding.Kind = TInputElementKind.Button) and (Binding.Code >= 0) and (Binding.Code <= Ord(High(TGamepadButton))) then
    Result := Buttons[TGamepadButton(Binding.Code)]
  else if (Binding.Kind = TInputElementKind.Axis) and (Binding.Code >= 0) and (Binding.Code <= Ord(High(TGamepadAxis))) then
    Result := Axes[TGamepadAxis(Binding.Code)] + ' ' + IntToStr(Binding.Direction)
  else if Binding.Kind = TInputElementKind.Hat then
    Result := 'D-pad ' + IntToStr(Binding.Direction);
end;

end.

