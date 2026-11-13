unit RM.LibraryNavigation;

interface

uses
  System.SysUtils, System.Generics.Collections, FMXInput;

type
  // UI actions are deliberately independent of emulated controller bindings.
  TGamepadMenuShortcut = record
  private
    FReady, FHomeDown, FStartConsumed: Boolean;
    FStartDevice: string;
    FStartSince: UInt64;
  public
    function Poll(const Devices: TArray<TInputDevice>; const Values: TArray<TInputValue>; Tick: UInt64; Active: Boolean): Boolean;
    procedure Reset;
  end;

  TLibraryNavigation = class
  private
    FPrevious: TDictionary<string, Cardinal>;
    FDevice: TInputDevice;
    FReady: Boolean;
    FHeld: Cardinal;
    FRepeatAt: UInt64;
    FGamepadHintsByDefault: Boolean;
  public
    constructor Create(GamepadHintsByDefault: Boolean = False);
    destructor Destroy; override;
    procedure Reset;
    procedure KeyboardUsed;
    procedure PointerUsed;
    function Poll(const Devices: TArray<TInputDevice>; const Values: TArray<TInputValue>; Tick: UInt64): Integer;
    function Hint(Command: Integer): string;
    class function Decode(const Device: TInputDevice; const Value: TInputValue): Integer; static;
    property Device: TInputDevice read FDevice;
  end;

implementation

uses
  RM.Input.Gamepads;

procedure TGamepadMenuShortcut.Reset;
begin
  FReady := False;
  FHomeDown := False;
  FStartConsumed := False;
  FStartDevice := '';
  FStartSince := 0;
end;

function TGamepadMenuShortcut.Poll(const Devices: TArray<TInputDevice>; const Values: TArray<TInputValue>; Tick: UInt64; Active: Boolean): Boolean;
begin
  Result := False;
  var Home := False;
  var StartDevice := '';
  for var Device in Devices do
    if (Device.Kind = TInputDeviceKind.Controller) and Device.Available then
      for var Raw in Values do
      begin
        var Value: TInputValue;
        if NormalizeGamepadValue(Device, Raw, Value) and
          (Value.Kind = TInputElementKind.Button) and (Value.Value > 0.5) then
          case TGamepadButton(Value.Code) of
            TGamepadButton.Home:
              Home := True;
            TGamepadButton.Start:
              if (StartDevice = '') or (Device.Id = FStartDevice) then
                StartDevice := Device.Id;
          end;
      end;
  if not FReady then
  begin
    FReady := not Home and (StartDevice = '');
    Exit;
  end;
  Result := Active and Home and not FHomeDown;
  FHomeDown := Home;
  if StartDevice <> FStartDevice then
  begin
    FStartDevice := StartDevice;
    FStartSince := Tick;
    FStartConsumed := not Active;
  end;
  if not Active then
    FStartConsumed := True;
  if (StartDevice <> '') and not FStartConsumed and (Tick - FStartSince >= 1000) then
  begin
    Result := Active;
    FStartConsumed := True;
  end;
end;

constructor TLibraryNavigation.Create(GamepadHintsByDefault: Boolean);
begin
  inherited Create;
  FPrevious := TDictionary<string, Cardinal>.Create;
  FGamepadHintsByDefault := GamepadHintsByDefault;
  PointerUsed;
end;

destructor TLibraryNavigation.Destroy;
begin
  FPrevious.Free;
  inherited;
end;

procedure TLibraryNavigation.Reset;
begin
  FReady := False;
  FHeld := 0;
  FPrevious.Clear;
end;

procedure TLibraryNavigation.KeyboardUsed;
begin
  Reset;
  FDevice := Default(TInputDevice);
  FDevice.Kind := TInputDeviceKind.Keyboard;
end;

procedure TLibraryNavigation.PointerUsed;
begin
  if not FGamepadHintsByDefault then
  begin
    KeyboardUsed;
    Exit;
  end;
  Reset;
  if FDevice.Kind <> TInputDeviceKind.Controller then
  begin
    FDevice := Default(TInputDevice);
    FDevice.Kind := TInputDeviceKind.Controller;
    FDevice.Id := 'mobile:default';
  end;
end;

class function TLibraryNavigation.Decode(const Device: TInputDevice; const Value: TInputValue): Integer;
begin
  Result := -1;
  if (Device.Kind <> TInputDeviceKind.Controller) or not Device.Available or
    (Value.DeviceId <> Device.Id) then
    Exit;
  var N: TInputValue;
  if NormalizeGamepadValue(Device, Value, N) then
  begin
    if N.Kind = TInputElementKind.Hat then
    begin
      if N.Value >= 0 then
        case Round(N.Value) of
          0:
            Result := 10;
          4:
            Result := 11;
          1..3:
            Result := 1;
          5..7:
            Result := 0;
        end;
    end
    else if (N.Kind = TInputElementKind.Axis) and (N.Code in [Ord(TGamepadAxis.LeftX), Ord(TGamepadAxis.DpadX)]) then
    begin
      if N.Value < -0.55 then
        Result := 0;
      if N.Value > 0.55 then
        Result := 1;
    end
    else if (N.Kind = TInputElementKind.Axis) and (N.Code in [Ord(TGamepadAxis.LeftY), Ord(TGamepadAxis.DpadY)]) then
    begin
      if N.Value < -0.55 then
        Result := 10;
      if N.Value > 0.55 then
        Result := 11;
    end
    else if (N.Kind = TInputElementKind.Button) and (N.Value > 0.5) then
      case TGamepadButton(N.Code) of
        TGamepadButton.Up:
          Result := 10;
        TGamepadButton.Down:
          Result := 11;
        TGamepadButton.Left:
          Result := 0;
        TGamepadButton.Right:
          Result := 1;
        TGamepadButton.South:
          Result := 2;
        TGamepadButton.East:
          Result := 3;
        TGamepadButton.West:
          Result := 4;
        TGamepadButton.North:
          Result := 5;
        TGamepadButton.LeftShoulder:
          Result := 6;
        TGamepadButton.RightShoulder:
          Result := 7;
        TGamepadButton.Start:
          Result := 8;
        TGamepadButton.Select:
          Result := 9;
      end;
    Exit;
  end;
  var XInput := Device.Id.Contains(':xinput:');
  var Android := Device.Id.StartsWith('android:');
  var Linux := Device.Id.StartsWith('linux:');
  if Value.Kind = TInputElementKind.Hat then
  begin
    // FMXInput normalizes hats to -1 (neutral), 0..7 clockwise from north.
    if Value.Value >= 0 then
      case Round(Value.Value) of
        0:
          Result := 10;
        4:
          Result := 11;
        1..3:
          Result := 1;
        5..7:
          Result := 0;
      end;
    Exit;
  end;
  if Value.Kind = TInputElementKind.Axis then
  begin
    if (XInput and (Value.Code = 0)) or
      (Android and (Value.Code in [0, 15])) or
      (Linux and (Value.Code in [0, $10])) or
      (not XInput and not Android and not Linux and (Value.Code = $30)) then
    begin
      if Value.Value < -0.55 then
        Result := 0;
      if Value.Value > 0.55 then
        Result := 1;
    end;
    Exit;
  end;
  if (Value.Kind <> TInputElementKind.Button) or (Value.Value <= 0.5) then
    Exit;
  // Backend namespaces take precedence over vendor/product: the OS may already
  // normalize a Sony/Nintendo controller to XInput, evdev or Android keycodes.
  if XInput then
    case Value.Code of
      2:
        Result := 0;
      3:
        Result := 1;
      12:
        Result := 2;
      13:
        Result := 3;
      14:
        Result := 4;
      15:
        Result := 5;
      8:
        Result := 6;
      9:
        Result := 7;
      4:
        Result := 8;
      5:
        Result := 9;
    end
  else if Android then
    case Value.Code of
      21:
        Result := 0;
      22:
        Result := 1;
      96:
        Result := 2;
      97:
        Result := 3;
      99:
        Result := 4;
      100:
        Result := 5;
      102:
        Result := 6;
      103:
        Result := 7;
      108:
        Result := 8;
      109:
        Result := 9;
    end
  else if Linux then
    case Value.Code of
      $222:
        Result := 0;
      $223:
        Result := 1;
      $130:
        Result := 2;
      $131:
        Result := 3;
      $134:
        Result := 4;
      $133:
        Result := 5;
      $136:
        Result := 6;
      $137:
        Result := 7;
      $13B:
        Result := 8;
      $13A:
        Result := 9;
    end
  else
  begin
    // Raw Windows HID uses USB usages, not SDL's zero-based button indices.
    // Restrict corrections to known products; never assume a whole vendor has
    // one layout. Published schemes and limitations: codex-work/design/library-navigation.md.
    var PlayStation := (Device.VendorId = $054C) and
      ((Device.ProductId = $05C4) or (Device.ProductId = $09CC) or
      (Device.ProductId = $0CE6) or (Device.ProductId = $0DF2));
    var Logitech := (Device.VendorId = $046D) and
      ((Device.ProductId = $C216) or (Device.ProductId = $C218) or (Device.ProductId = $C219));
    var BitDo := (Device.VendorId = $2DC8) and
      ((Device.ProductId = $6001) or (Device.ProductId = $6101) or
      (Device.ProductId = $6002) or (Device.ProductId = $6102) or
      (Device.ProductId = $9000) or (Device.ProductId = $9015));
    if PlayStation or Logitech then
      case Value.Code of
        2:
          Result := 2;
        3:
          Result := 3;
        1:
          Result := 4;
        4:
          Result := 5;
        5:
          Result := 6;
        6:
          Result := 7;
        10:
          Result := 8;
        9:
          Result := 9;
      end
    else if BitDo then
      case Value.Code of
        2:
          Result := 2;
        1:
          Result := 3;
        5:
          Result := 4;
        4:
          Result := 5;
        7:
          Result := 6;
        8:
          Result := 7;
        12:
          Result := 8;
        11:
          Result := 9;
      end
    else
      // Switch Pro in raw HID compatibility mode and common USB pads.
      // Unknown HID devices retain this documented fallback, not a claim that
      // USB defines physical meanings for numbered Button-page usages.
      case Value.Code of
        1:
          Result := 2;
        2:
          Result := 3;
        3:
          Result := 4;
        4:
          Result := 5;
        5:
          Result := 6;
        6:
          Result := 7;
        10:
          Result := 8;
        9:
          Result := 9;
      end;
  end;
end;

function TLibraryNavigation.Poll(const Devices: TArray<TInputDevice>; const Values: TArray<TInputValue>; Tick: UInt64): Integer;
begin
  Result := -1;
  var ActiveMask: Cardinal := 0;
  var AllMasks: Cardinal := 0;
  var Candidate := Default(TInputDevice);
  var CandidateMask: Cardinal := 0;
  var Seen := TList<string>.Create;
  try
    for var D in Devices do
      if (D.Kind = TInputDeviceKind.Controller) and D.Available then
      begin
        Seen.Add(D.Id);
        var Mask: Cardinal := 0;
        for var V in Values do
        begin
          var Action := Decode(D, V);
          if Action >= 0 then
            Mask := Mask or (Cardinal(1) shl Action);
        end;
        if Mask and $C00 = $C00 then
          Mask := Mask and not Cardinal($C00);
        // Opposing directions cancel; never select a direction by enum order.
        if Mask and 3 = 3 then
          Mask := Mask and not Cardinal(3);
        AllMasks := AllMasks or Mask;
        var Previous: Cardinal := 0;
        FPrevious.TryGetValue(D.Id, Previous);
        FPrevious.AddOrSetValue(D.Id, Mask);
        if D.Id = FDevice.Id then
          ActiveMask := Mask;
        // A fresh press wins over another controller's held stick. If two
        // devices actuate in one snapshot, keep the current device if possible.
        if (Mask and not Previous <> 0) and
          ((Candidate.Id = '') or (D.Id = FDevice.Id)) then
        begin
          Candidate := D;
          CandidateMask := Mask;
        end;
      end;
    for var Id in FPrevious.Keys.ToArray do
      if not Seen.Contains(Id) then
        FPrevious.Remove(Id);
    if not FReady then
    begin
      FReady := AllMasks = 0;
      FHeld := ActiveMask;
      Exit;
    end;
    if (Candidate.Id <> '') and (Candidate.Id <> FDevice.Id) then
    begin
      FDevice := Candidate;
      ActiveMask := CandidateMask;
      FHeld := 0;
    end;
    var Pressed := ActiveMask and not FHeld;
    if (ActiveMask and $C03 <> 0) and (ActiveMask = FHeld) and (Tick >= FRepeatAt) then
    begin
      Pressed := ActiveMask and $C03;
      FRepeatAt := Tick + 130;
    end
    else if ActiveMask <> FHeld then
      FRepeatAt := Tick + 400;
    FHeld := ActiveMask;
    for var I := 0 to 11 do
      if Pressed and (Cardinal(1) shl I) <> 0 then
        Exit(I);
  finally
    Seen.Free;
  end;
end;

function TLibraryNavigation.Hint(Command: Integer): string;
const
  Keyboard: array[0..9] of string = ('Left', 'Right', 'Enter', 'Esc', 'X', 'Y', 'PgUp', 'PgDn', 'Space', '');
  Xbox: array[0..9] of string = ('D-pad', 'D-pad', 'A', 'B', 'X', 'Y', 'LB', 'RB', 'Start', 'Back');
  Sony: array[0..9] of string = ('D-pad', 'D-pad', 'Cross', 'Circle', 'Square', 'Triangle', 'L1', 'R1', 'Options', 'Share');
  Generic: array[0..9] of string = ('D-pad', 'D-pad', '1', '2', '3', '4', '5', '6', '10', '9');
begin
  if (Command < 0) or (Command > 9) then
    Exit('');
  if FDevice.Kind <> TInputDeviceKind.Controller then
    Exit(Keyboard[Command]);
  if FDevice.Id.Contains(':xinput:') or (FDevice.Id = 'mobile:default') then
    Exit(Xbox[Command]);
  if FDevice.VendorId = $054C then
    Exit(Sony[Command]);
  if (FDevice.VendorId = $046D) and not FDevice.Id.StartsWith('linux:') and
    not FDevice.Id.StartsWith('android:') and
    ((FDevice.ProductId = $C216) or (FDevice.ProductId = $C218) or (FDevice.ProductId = $C219)) then
    case Command of
      2:
        Exit('2');
      3:
        Exit('3');
      4:
        Exit('1');
      5:
        Exit('4');
    end;
  if FDevice.VendorId = $2DC8 then
    case Command of
      2:
        Exit('B');
      3:
        Exit('A');
      4:
        Exit('Y');
      5:
        Exit('X');
      6:
        Exit('L');
      7:
        Exit('R');
      8:
        Exit('Start');
      9:
        Exit('Select');
    end;
  if FDevice.Id.StartsWith('android:') or FDevice.Id.StartsWith('linux:') or
    ((FDevice.VendorId = $057E) and (FDevice.ProductId = $2009)) then
    Exit(Xbox[Command]);
  Result := Generic[Command];
end;

end.

