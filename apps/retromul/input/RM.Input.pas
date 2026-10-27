unit RM.Input;

interface

uses
  Core.RomFormat, System.SysUtils, System.Classes, System.IniFiles,
  System.UITypes, FMXInput, Core.Emulation, Core.InputConfig, NES.Controller,
  NES.FamicomKeyboardDevice, NES.MiraclePianoDevice, Core.Adapter.PS1, Core.Adapter.DC;

const
  PowerPadAction = 128;
  ZapperTriggerAction = 160;
  SuborAction = 256;
  FamicomAction = 384;
  PianoAction = 512;
  ExtraPadAction = 1024; // Preserve the existing NES peripheral action IDs.
  N64LAction = 4096;
  PS1ExtraAction = 4112; // PlayStation inputs outside the logical pad, see PS1Action.
  DCExtraAction = 4160; // Dreamcast analog stick directions, see DCAction.

type
  THostKeys = array[0..255] of Boolean;

function HidToHostKey(Code: Integer): Word;

function HostKeyToHid(Code: Word): Integer;

function PadAction(Port: Integer; Button: TEmulatorButton): Integer;

function PS1Action(Port: Integer; Extra: TPS1Extra): Integer;

function PS1ExtraName(Extra: TPS1Extra): string;

// The extras of a DualShock-capable port: L2/L3/R3, ANALOG and both sticks.
function ReadPS1Pad(Input: TInputManager; Port: Integer): TPS1Pad;
function DCAction(Port: Integer; Extra: TDCExtra): Integer;

function DCExtraName(Extra: TDCExtra): string;

// The analog stick (DC extras) and the triggers (Select and Mode) of a
// Dreamcast controller; axes give partial deflection.
function ReadDCPad(Input: TInputManager; Port: Integer): TDCAnalogPad;

function CoreButtons(const SystemId, Device: string): TEmulatorButtons;

function CoreButtonName(const SystemId: string; Button: TEmulatorButton): string;

procedure LoadInputBindings(Input: TInputManager; Ini: TCustomIniFile; const SystemId: string);

procedure SaveInputBindings(Input: TInputManager; Ini: TCustomIniFile);

procedure FilterInputBindings(Input: TInputManager; Ini: TCustomIniFile);

function BindingCaption(Input: TInputManager; Action: Integer): string;

// First available rumble controller bound to this player's pad buttons.
function RumbleDeviceId(Input: TInputManager; Port: Integer): string;

function ReadHostKeys(Input: TInputManager): THostKeys;

function ReadPadInput(Input: TInputManager; const Ports: TCoreInputPorts): TEmulatorInput;

function ReadSuborInput(Input: TInputManager): TSuborKeys;

function ReadFamicomInput(Input: TInputManager): TFamicomKeys;

function ReadPianoInput(Input: TInputManager): TMiracleKeys;

// Reads the aggregate mouse once, avoiding duplicate physical-device aliases.
procedure ReadRelativeMouse(Input: TInputManager; out DX, DY: Integer; out Buttons: Byte);

implementation

uses
  Core.Adapter.ZX, Core.Adapter.PCE, Core.Adapter.GW, Core.Adapter.Saturn,
  Core.Adapter.N64, Core.Adapter.GB, Core.Adapter.NES, Core.Adapter.MD,
  Core.Adapter.SNES, Core.Adapter.NeoGeo, Core.Adapter.NGP, Core.Adapter.GBA,
  Core.Adapter.CPS, GB.Joypad, NES.Input, NES.Types, MD.Console, SNES.Console,
  System.Math, FMX.Types, PS1.SIO, Core.Adapter.PSP;

procedure ReadRelativeMouse(Input: TInputManager; out DX, DY: Integer; out Buttons: Byte);
begin
  DX := 0;
  DY := 0;
  Buttons := 0;
  if Input = nil then
    Exit;
  for var V in Input.Values do
    if V.DeviceId = SystemMouseId then
      if V.Kind = TInputElementKind.RelativeAxis then
      begin
        if V.Code = MouseX then
          DX := Round(EnsureRange(V.Value, -32768.0, 32767.0));
        if V.Code = MouseY then
          DY := Round(EnsureRange(V.Value, -32768.0, 32767.0));
      end
      else if (V.Kind = TInputElementKind.Button) and (V.Code in [MouseLeft, MouseRight, MouseMiddle]) and (V.Value > 0.5) then
        Buttons := Buttons or (1 shl V.Code);
end;

function HidToHostKey(Code: Integer): Word;
const
  Keys: array[40..101] of Word = (vkReturn, vkEscape, vkBack, vkTab, vkSpace,
    vkMinus, vkEqual, vkLeftBracket, vkRightBracket, vkBackslash, 0, vkSemicolon,
    vkQuote, vkTilde, vkComma, vkPeriod, vkSlash, vkCapital,
    vkF1, vkF2, vkF3, vkF4, vkF5, vkF6, vkF7, vkF8, vkF9, vkF10, vkF11, vkF12,
    vkSnapshot, vkScroll, vkPause, vkInsert, vkHome, vkPrior, vkDelete, vkEnd,
    vkNext, vkRight, vkLeft, vkDown, vkUp, vkNumLock, vkDivide, vkMultiply,
    vkSubtract, vkAdd, vkReturn, vkNumpad1, vkNumpad2, vkNumpad3, vkNumpad4,
    vkNumpad5, vkNumpad6, vkNumpad7, vkNumpad8, vkNumpad9, vkNumpad0,
    vkDecimal, vkBackslash, vkApps);
begin
  Result := 0;
  if (Code >= 4) and (Code <= 29) then
    Exit(vkA + Code - 4);

  if (Code >= 30) and (Code <= 38) then
    Exit(vk1 + Code - 30);

  if Code = 39 then
    Exit(vk0);

  if (Code >= Low(Keys)) and (Code <= High(Keys)) then
    Exit(Keys[Code]);

  case Code of
    224:
      Result := vkLControl;
    225:
      Result := vkLShift;
    226:
      Result := vkLMenu;
    227:
      Result := vkLWin;
    228:
      Result := vkRControl;
    229:
      Result := vkRShift;
    230:
      Result := vkRMenu;
    231:
      Result := vkRWin;
  end;
end;

function HostKeyToHid(Code: Word): Integer;
begin
  case Code of
    vkShift:
      Exit(225);
    vkControl:
      Exit(224);
    vkMenu:
      Exit(226);
  end;

  for var i := 4 to 231 do
    if (Code <> 0) and (HidToHostKey(i) = Code) then
      Exit(i);

  Result := 0;
end;

function RumbleDeviceId(Input: TInputManager; Port: Integer): string;
begin
  Result := '';
  if Input = nil then
    Exit;

  var Devices := Input.Devices;
  for var Binding in Input.Bindings do
    for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
      if Binding.Action = PadAction(Port, Button) then
        for var Device in Devices do
          if (Device.Id = Binding.DeviceId) and (Device.Kind = TInputDeviceKind.Controller) and Device.Available and
            Device.RumbleSupported then
            Exit(Device.Id);
end;

function PadAction(Port: Integer; Button: TEmulatorButton): Integer;
begin
  if Port < 4 then
    Result := Port * 32 + Ord(Button)
  else
    Result := ExtraPadAction + (Port - 4) * 32 + Ord(Button);
end;

function PS1Action(Port: Integer; Extra: TPS1Extra): Integer;
begin
  Result := PS1ExtraAction + Port * 16 + Ord(Extra);
end;

function PS1ExtraName(Extra: TPS1Extra): string;
const
  Names: array[TPS1Extra] of string = ('L2', 'L3', 'R3', 'Analog', 'LS ↑', 'LS ↓', 'LS ←', 'LS →', 'RS ↑', 'RS ↓',
    'RS ←', 'RS →');
begin
  Result := Names[Extra];
end;

function DCAction(Port: Integer; Extra: TDCExtra): Integer;
begin
  Result := DCExtraAction + Port * 16 + Ord(Extra);
end;

function DCExtraName(Extra: TDCExtra): string;
const
  Names: array[TDCExtra] of string = ('Stick ↑', 'Stick ↓', 'Stick ←', 'Stick →');
begin
  Result := Names[Extra];
end;

// 0..1: the deflection of an axis bound to the action, else 1 while pressed.
function ActionAmount(Input: TInputManager; const Bindings: TArray<TInputBinding>;
  const Values: TArray<TInputValue>; Action: Integer): Single;
begin
  Result := 0;
  for var B in Bindings do
    if (B.Action = Action) and (B.Kind = TInputElementKind.Axis) then
      for var V in Values do
        if (V.DeviceId = B.DeviceId) and (V.Kind = B.Kind) and (V.Code = B.Code) then
        begin
          var Travel := 1.0 - B.AxisOrigin * B.Direction;
          if Travel > 0 then
            Result := Max(Result, EnsureRange((V.Value - B.AxisOrigin) * B.Direction / Travel, 0.0, 1.0));
        end;
  if (Result = 0) and Input.IsPressed(Action) then
    Result := 1;
end;

function ReadPS1Pad(Input: TInputManager; Port: Integer): TPS1Pad;

  function Axis(Negative, Positive: TPS1Extra; const Bindings: TArray<TInputBinding>;
    const Values: TArray<TInputValue>): SmallInt;
  begin
    var Amount := ActionAmount(Input, Bindings, Values, PS1Action(Port, Positive)) -
      ActionAmount(Input, Bindings, Values, PS1Action(Port, Negative));
    Result := EnsureRange(Round(Amount * 32767), -32768, 32767);
  end;

begin
  Result := Default(TPS1Pad);
  if Input = nil then
    Exit;

  if Input.IsPressed(PS1Action(Port, TPS1Extra.L2)) then
    Result.Buttons := Result.Buttons or PS1PadL2;
  if Input.IsPressed(PS1Action(Port, TPS1Extra.L3)) then
    Result.Buttons := Result.Buttons or PS1PadL3;
  if Input.IsPressed(PS1Action(Port, TPS1Extra.R3)) then
    Result.Buttons := Result.Buttons or PS1PadR3;
  Result.AnalogButton := Input.IsPressed(PS1Action(Port, TPS1Extra.Analog));
  var Bindings := Input.Bindings;
  var Values := Input.Values;
  Result.LeftX := Axis(TPS1Extra.LeftLeft, TPS1Extra.LeftRight, Bindings, Values);
  Result.LeftY := Axis(TPS1Extra.LeftUp, TPS1Extra.LeftDown, Bindings, Values);
  Result.RightX := Axis(TPS1Extra.RightLeft, TPS1Extra.RightRight, Bindings, Values);
  Result.RightY := Axis(TPS1Extra.RightUp, TPS1Extra.RightDown, Bindings, Values);
end;

function ReadDCPad(Input: TInputManager; Port: Integer): TDCAnalogPad;
begin
  Result := Default(TDCAnalogPad);
  if Input = nil then
    Exit;

  var Bindings := Input.Bindings;
  var Values := Input.Values;
  var X := ActionAmount(Input, Bindings, Values, DCAction(Port, TDCExtra.StickRight)) -
    ActionAmount(Input, Bindings, Values, DCAction(Port, TDCExtra.StickLeft));
  var Y := ActionAmount(Input, Bindings, Values, DCAction(Port, TDCExtra.StickDown)) -
    ActionAmount(Input, Bindings, Values, DCAction(Port, TDCExtra.StickUp));
  Result.StickX := EnsureRange(Round(X * 32767), -32768, 32767);
  Result.StickY := EnsureRange(Round(Y * 32767), -32768, 32767);
  Result.LeftTrigger := Round(ActionAmount(Input, Bindings, Values, PadAction(Port, TEmulatorButton.Select)) * 255);
  Result.RightTrigger := Round(ActionAmount(Input, Bindings, Values, PadAction(Port, TEmulatorButton.Mode)) * 255);
end;

function CoreButtons(const SystemId, Device: string): TEmulatorButtons;
begin
  if SystemId = ROM_SYSTEM_ZX then
  begin
    if Device = 'none' then
      Exit([]);
    Exit([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
        TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Mode, TEmulatorButton.Select, TEmulatorButton.Start]);
  end;
  // Dreamcast controller: Select and Mode are the L and R triggers.
  if SystemId = ROM_SYSTEM_DC then
  begin
    if Device = 'none' then
      Exit([]);
    Exit([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
      TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Start,
      TEmulatorButton.Select, TEmulatorButton.Mode]);
  end;

  if (SystemId = ROM_SYSTEM_PCE) or (SystemId = ROM_SYSTEM_SGX) or (SystemId = ROM_SYSTEM_PCECD) then
  begin
    if Device = 'none' then
      Exit([]);

    Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
        TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start];
    if Device = 'pad6' then
      Result := Result + [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.C, TEmulatorButton.Z];
    Exit;
  end;

  if SystemId = ROM_SYSTEM_GW then
    Exit([Low(TEmulatorButton)..High(TEmulatorButton)]);

  if (SystemId = ROM_SYSTEM_MSX1) or (SystemId = ROM_SYSTEM_MSX2) or (SystemId = ROM_SYSTEM_MSX2PLUS) then
    Exit([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
      TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start, TEmulatorButton.Select]);

  Result := [];
  if not (Device = 'auto') and not Device.StartsWith('pad') then
    Exit;

  Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start];
  if (SystemId = ROM_SYSTEM_NES) and (Device = 'paddendy') then
    Result := Result + [TEmulatorButton.X, TEmulatorButton.Y];
  if (SystemId = ROM_SYSTEM_SG1000) or (SystemId = ROM_SYSTEM_SC3000) or (SystemId = ROM_SYSTEM_SF7000) or (SystemId = ROM_SYSTEM_OMV) or (SystemId = ROM_SYSTEM_SMS) or (SystemId = ROM_SYSTEM_GG) then
    Exit;

  if (SystemId = ROM_SYSTEM_NGP) or (SystemId = ROM_SYSTEM_NGPC) then
    Exit;

  if SystemId = ROM_SYSTEM_N64 then
    Exit([Low(TEmulatorButton)..High(TEmulatorButton)]);

  if SystemId = ROM_SYSTEM_SATURN then
    Exit([Low(TEmulatorButton)..High(TEmulatorButton)]);

  if SystemId = ROM_SYSTEM_PS1 then
    Exit([Low(TEmulatorButton)..High(TEmulatorButton)]);
  if SystemId = ROM_SYSTEM_PSP then
    Exit([Low(TEmulatorButton)..TEmulatorButton.Z]);

  if (SystemId = ROM_SYSTEM_MD) or (SystemId = ROM_SYSTEM_SEGACD) or (SystemId = ROM_SYSTEM_SEGA32X) then
  begin
    Include(Result, TEmulatorButton.C);
    if Device <> 'pad3' then
      Result := Result + [TEmulatorButton.X, TEmulatorButton.Y,
          TEmulatorButton.Z, TEmulatorButton.Mode];
  end
  else
  begin
    Include(Result, TEmulatorButton.Select);
    if (SystemId = ROM_SYSTEM_CPS1) or (SystemId = ROM_SYSTEM_CPS2) or (SystemId = ROM_SYSTEM_CPS3) then
      Result := Result + [TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode];
    if ((SystemId = ROM_SYSTEM_NEOGEO) or (SystemId = ROM_SYSTEM_NEOGEOCD) or (SystemId = ROM_SYSTEM_NEOGEOAES)) then
      Result := Result + [TEmulatorButton.C, TEmulatorButton.X];
    if SystemId = ROM_SYSTEM_GBA then
      Result := Result + [TEmulatorButton.C, TEmulatorButton.Z];
    if SystemId = ROM_SYSTEM_SNES then
      Result := Result + [TEmulatorButton.X, TEmulatorButton.Y,
          TEmulatorButton.C, TEmulatorButton.Z];
  end;
end;

function CoreButtonName(const SystemId: string; Button: TEmulatorButton): string;
const
  Names: array[TEmulatorButton] of string =
    ('↑', '↓', '←', '→', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');
begin
  if SystemId = ROM_SYSTEM_ZX then
    case Button of
      TEmulatorButton.A:
        Exit('Fire');
      TEmulatorButton.B:
        Exit('Tape play/pause');
      TEmulatorButton.Mode:
        Exit('Tape rewind');
      TEmulatorButton.Select:
        Exit('1');
      TEmulatorButton.Start:
        Exit('Enter');
    end;
  if (SystemId = ROM_SYSTEM_CPS1) or (SystemId = ROM_SYSTEM_CPS2) or (SystemId = ROM_SYSTEM_CPS3) then
    case Button of
      TEmulatorButton.A:
        Exit('LP');
      TEmulatorButton.B:
        Exit('MP');
      TEmulatorButton.C:
        Exit('HP');
      TEmulatorButton.X:
        Exit('LK');
      TEmulatorButton.Y:
        Exit('MK');
      TEmulatorButton.Z:
        Exit('HK');
      TEmulatorButton.Select:
        Exit('Coin');
      TEmulatorButton.Mode:
        Exit('Service');
    end;
  if SystemId = ROM_SYSTEM_GW then
    case Button of
      TEmulatorButton.Select:
        Exit('Time');
      TEmulatorButton.Start:
        Exit('Game A');
      TEmulatorButton.X:
        Exit('Game B');
      TEmulatorButton.Y:
        Exit('Alarm / ACL');
      TEmulatorButton.C:
        Exit('X');
      TEmulatorButton.Z:
        Exit('Y');
      TEmulatorButton.Mode:
        Exit('Start');
    end;

  Result := Names[Button];
  if (SystemId = ROM_SYSTEM_SATURN) or (SystemId = ROM_SYSTEM_DC) then
    case Button of
      TEmulatorButton.Select:
        Exit('L');
      TEmulatorButton.Mode:
        Exit('R');
    end;

  if SystemId = ROM_SYSTEM_PSP then
  begin
    case Button of
      TEmulatorButton.A: Result := 'Cross';
      TEmulatorButton.B: Result := 'Circle';
      TEmulatorButton.X: Result := 'Square';
      TEmulatorButton.Y: Result := 'Triangle';
      TEmulatorButton.C: Result := 'L';
      TEmulatorButton.Z: Result := 'R';
    end;
    Exit;
  end;
  if SystemId = ROM_SYSTEM_PS1 then
  begin
    case Button of
      TEmulatorButton.A:
        Result := 'Cross';
      TEmulatorButton.B:
        Result := 'Circle';
      TEmulatorButton.X:
        Result := 'Square';
      TEmulatorButton.Y:
        Result := 'Triangle';
      TEmulatorButton.C:
        Result := 'L1';
      TEmulatorButton.Z:
        Result := 'R1';
      TEmulatorButton.Mode:
        Result := 'R2';
    end;
    Exit;
  end;

  if (SystemId = ROM_SYSTEM_PCE) or (SystemId = ROM_SYSTEM_SGX) or (SystemId = ROM_SYSTEM_PCECD) then
  begin
    case Button of
      TEmulatorButton.A:
        Result := 'I';
      TEmulatorButton.B:
        Result := 'II';
      TEmulatorButton.X:
        Result := 'III';
      TEmulatorButton.Y:
        Result := 'IV';
      TEmulatorButton.C:
        Result := 'V';
      TEmulatorButton.Z:
        Result := 'VI';
      TEmulatorButton.Start:
        Result := 'Run';
    end;
    Exit;
  end;

  if SystemId = ROM_SYSTEM_N64 then
  begin
    case Button of
      TEmulatorButton.Select:
        Result := 'Z';
      TEmulatorButton.C:
        Result := 'CDown';
      TEmulatorButton.X:
        Result := 'CLeft';
      TEmulatorButton.Y:
        Result := 'CUp';
      TEmulatorButton.Z:
        Result := 'CRight';
      TEmulatorButton.Mode:
        Result := 'R';
    end;
    Exit;
  end;

  if SystemId = ROM_SYSTEM_NES then
    case Button of
      TEmulatorButton.X:
        Result := 'Turbo B';
      TEmulatorButton.Y:
        Result := 'Turbo A';
    end;

  if ((SystemId = ROM_SYSTEM_NEOGEO) or (SystemId = ROM_SYSTEM_NEOGEOCD) or (SystemId = ROM_SYSTEM_NEOGEOAES)) and (Button = TEmulatorButton.X) then
    Result := 'D';
  if ((SystemId = ROM_SYSTEM_NGP) or (SystemId = ROM_SYSTEM_NGPC)) and (Button = TEmulatorButton.Start) then
    Result := 'Option';

  if (SystemId = ROM_SYSTEM_SNES) or (SystemId = ROM_SYSTEM_GBA) then
    case Button of
      TEmulatorButton.C:
        Result := 'L';
      TEmulatorButton.Z:
        Result := 'R';
    end;
end;

procedure SaveInputBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  var Stream := TMemoryStream.Create;
  try
    Input.SaveBindings(Stream);
    var Bytes: TBytes;
    SetLength(Bytes, Stream.Size);
    Stream.Position := 0;
    if Length(Bytes) > 0 then
      Stream.ReadBuffer(Bytes[0], Length(Bytes));
    Ini.WriteString('FMXInput', 'Bindings', TEncoding.UTF8.GetString(Bytes));
    Ini.WriteInteger('FMXInput', 'PeripheralVersion', 1);
  finally
    Stream.Free;
  end;
end;

procedure EnsurePeripheralBindings(Input: TInputManager; Ini: TCustomIniFile);

  procedure AddKey(Action, Hid: Integer);
  begin
    Input.AddBinding(TInputBinding.Create(Action,
        TInputValue.Create(SystemKeyboardId, TInputElementKind.Key, Hid, 1)));
  end;

begin
  if Ini.ReadInteger('FMXInput', 'PeripheralVersion', 0) >= 1 then
    Exit;

  var Subor := TSuborKeyboard.Create;
  var Famicom := TFamicomKeyboard.Create;
  try
    for var Hid := 4 to 231 do
    begin
      var Code := HidToHostKey(Hid);
      if Code = 0 then
        Continue;

      Subor.Clear;
      Subor.SetHostKey(Code, True);
      for var K in Subor.GetPressedKeys do
        AddKey(SuborAction + Ord(K), Hid);
      Famicom.Clear;
      Famicom.SetHostKey(Code, True);
      for var K in Famicom.GetPressedKeys do
        AddKey(FamicomAction + Ord(K), Hid);
      var PianoKey := TMiraclePianoDevice.HostKey(Code);
      if PianoKey >= 0 then
        AddKey(PianoAction + PianoKey, Hid);
    end;
    Ini.WriteInteger('FMXInput', 'PeripheralVersion', 1);
  finally
    Famicom.Free;
    Subor.Free;
  end;
end;

procedure LoadInputBindings(Input: TInputManager; Ini: TCustomIniFile; const SystemId: string);
const
  MDMapping: array[TMDButton] of TEmulatorButton = (TEmulatorButton.Up,
    TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.Start,
    TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode);
  SNESMapping: array[TSnesButton] of TEmulatorButton = (TEmulatorButton.Up,
    TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.C, TEmulatorButton.Z);
  NESMapping: array[TNesButton] of TEmulatorButton = (TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right);
  Second: array[TEmulatorButton] of Word = (vkNumpad8, vkNumpad5, vkNumpad4,
    vkNumpad6, vkNumpad1, vkNumpad2, vkNumpad3, vkNumpad0,
    vkNumpad3, vkNumpad7, vkNumpad9, vkDecimal, vkMultiply);
  PowerKeys: array[0..11] of Word = (vk1, vk2, vk3, vk4, vk5, vk6, vk7, vk8,
    vk9, vk0, vkMinus, vkEqual);
var
  Keys: array[0..11, TEmulatorButton] of Word;
  Config: IEmulatorConfig;

  procedure AddKey(Action: Integer; Code: Word);
  begin
    var Hid := HostKeyToHid(Code);
    if Hid <> 0 then
      Input.AddBinding(TInputBinding.Create(Action,
          TInputValue.Create(SystemKeyboardId, TInputElementKind.Key, Hid, 1)));
  end;

  procedure CopyGB(const Map: TGBKeyMap);
  begin
    Keys[0, TEmulatorButton.A] := Map.A;
    Keys[0, TEmulatorButton.B] := Map.B;
    Keys[0, TEmulatorButton.Select] := Map.Select;
    Keys[0, TEmulatorButton.Start] := Map.Start;
    Keys[0, TEmulatorButton.Up] := Map.Up;
    Keys[0, TEmulatorButton.Down] := Map.Down;
    Keys[0, TEmulatorButton.Left] := Map.Left;
    Keys[0, TEmulatorButton.Right] := Map.Right;
  end;

  procedure CopyNES(Port: Integer; const Map: TKeyMap);
  begin
    Keys[Port, TEmulatorButton.A] := Map.A;
    Keys[Port, TEmulatorButton.B] := Map.B;
    Keys[Port, TEmulatorButton.Select] := Map.Select;
    Keys[Port, TEmulatorButton.Start] := Map.Start;
    Keys[Port, TEmulatorButton.Up] := Map.Up;
    Keys[Port, TEmulatorButton.Down] := Map.Down;
    Keys[Port, TEmulatorButton.Left] := Map.Left;
    Keys[Port, TEmulatorButton.Right] := Map.Right;
  end;

begin
  Input.CancelCapture;
  Input.ClearBindings;
  var JSON := Ini.ReadString('FMXInput', 'Bindings', '');
  if JSON <> '' then
  begin
    var Stream := TStringStream.Create(JSON, TEncoding.UTF8);
    try
      Input.LoadBindings(Stream);
    finally
      Stream.Free;
    end;
    if SystemId = ROM_SYSTEM_NES then
      EnsurePeripheralBindings(Input, Ini);
    Exit;
  end;

  FillChar(Keys, SizeOf(Keys), 0);

  // Import the existing core keyboard maps once; all later assignments use FMXInput.
  if SystemId = ROM_SYSTEM_ZX then
  begin
    var C := TZXConfig.Create('', nil);
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[0, B] := C.Keys[B];
  end
  else if (SystemId = ROM_SYSTEM_CPS1) or (SystemId = ROM_SYSTEM_CPS2) or (SystemId = ROM_SYSTEM_CPS3) then
  begin
    var C := TCPSConfig.Create('', nil);
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    begin
      Keys[0, B] := C.Keys[0, B];
      Keys[1, B] := C.Keys[1, B];
    end;
  end
  else if (SystemId = ROM_SYSTEM_PCE) or (SystemId = ROM_SYSTEM_SGX) or (SystemId = ROM_SYSTEM_PCECD) then
  begin
    var C := TPCEConfig.Create('');
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    begin
      Keys[0, B] := C.Keys[B];
      Keys[1, B] := C.Keys2[B];
    end;
  end
  else if SystemId = ROM_SYSTEM_GW then
  begin
    var C := TGWConfig.Create('');
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    begin
      Keys[0, B] := C.Keys[B];
      Keys[1, B] := C.Keys2[B];
    end;
  end
  else if SystemId = ROM_SYSTEM_SATURN then
  begin
    var C := TSaturnConfig.Create('');
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    begin
      Keys[0, B] := C.Keys[B];
      Keys[1, B] := C.Keys2[B];
    end;
  end
  else if SystemId = ROM_SYSTEM_NES then
  begin
    var C := TNesEmulatorConfig.Create('');
    Config := C;
    CopyNES(0, C.GetKeys);
    CopyNES(1, C.GetKeys2);
    CopyNES(2, C.GetKeys3);
    CopyNES(3, C.GetKeys4);
  end
  else if (SystemId = ROM_SYSTEM_MSX1) or (SystemId = ROM_SYSTEM_MSX2) or (SystemId = ROM_SYSTEM_MSX2PLUS) or (SystemId = ROM_SYSTEM_SG1000) or (SystemId = ROM_SYSTEM_SC3000) or (SystemId = ROM_SYSTEM_SF7000) or (SystemId = ROM_SYSTEM_OMV) or (SystemId = ROM_SYSTEM_SMS) or (SystemId = ROM_SYSTEM_GG) then
  begin
    Keys[0, TEmulatorButton.Up] := vkUp;
    Keys[0, TEmulatorButton.Down] := vkDown;
    Keys[0, TEmulatorButton.Left] := vkLeft;
    Keys[0, TEmulatorButton.Right] := vkRight;
    Keys[0, TEmulatorButton.A] := vkZ;
    Keys[0, TEmulatorButton.B] := vkX;
    Keys[0, TEmulatorButton.Start] := vkReturn;
    Keys[1, TEmulatorButton.Up] := vkNumpad8;
    Keys[1, TEmulatorButton.Down] := vkNumpad5;
    Keys[1, TEmulatorButton.Left] := vkNumpad4;
    Keys[1, TEmulatorButton.Right] := vkNumpad6;
    Keys[1, TEmulatorButton.A] := vkNumpad1;
    Keys[1, TEmulatorButton.B] := vkNumpad2;
    Keys[1, TEmulatorButton.Start] := vkNumpad0;
  end
  else if (SystemId = ROM_SYSTEM_MD) or (SystemId = ROM_SYSTEM_SEGACD) or (SystemId = ROM_SYSTEM_SEGA32X) then
  begin
    var C := TMDConfig.Create('');
    Config := C;
    for var B := Low(TMDButton) to High(TMDButton) do
    begin
      Keys[0, MDMapping[B]] := C.Keys[B];
      Keys[1, MDMapping[B]] := C.Keys2[B];
    end;
  end
  else if ((SystemId = ROM_SYSTEM_NEOGEO) or (SystemId = ROM_SYSTEM_NEOGEOCD) or (SystemId = ROM_SYSTEM_NEOGEOAES)) then
  begin
    var C := TNeoGeoConfig.Create('');
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    begin
      Keys[0, B] := C.Keys[B];
      Keys[1, B] := C.Keys2[B];
    end;
  end
  else if (SystemId = ROM_SYSTEM_NGP) or (SystemId = ROM_SYSTEM_NGPC) then
  begin
    var C := TNGPConfig.Create('');
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[0, B] := C.Keys[B];
  end
  else if SystemId = ROM_SYSTEM_N64 then
  begin
    var C := TN64Config.Create('', nil);
    Config := C;
    var Map := C.Keys;
    for var Port := 0 to 3 do
      for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
        Keys[Port, B] := Map[Port, B];
  end
  else if SystemId = ROM_SYSTEM_PSP then
  begin
    var C := TPSPConfig.Create('', nil);
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[0, B] := C.Keys[B];
  end
  else if SystemId = ROM_SYSTEM_PS1 then
  begin
    var C := TPS1Config.Create('', nil);
    Config := C;
    var Map := C.Keys;
    for var Port := 0 to 1 do
      for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
        Keys[Port, B] := Map[Port, B];
  end
  else if SystemId = ROM_SYSTEM_DC then
  begin
    var C := TDCConfig.Create('', nil);
    Config := C;
    var Map := C.Keys;
    for var Port := 0 to 3 do
      for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
        Keys[Port, B] := Map[Port, B];
  end
  else if SystemId = ROM_SYSTEM_GBA then
  begin
    var C := TGBAConfig.Create('');
    Config := C;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[0, B] := C.Keys[B];
  end
  else if SystemId = ROM_SYSTEM_SNES then
  begin
    var C := TSnesConfig.Create('');
    Config := C;
    for var B := Low(TSnesButton) to High(TSnesButton) do
    begin
      for var Port := 0 to 7 do
      begin
        var Map := C.KeyMap(Port);
        Keys[Port, SNESMapping[B]] := Map[B];
      end;
    end;
  end
  else
  begin
    var C := TGBEmulatorConfig.Create('');
    Config := C;
    CopyGB(C.GetKeys);
  end;
  var Count := 2;
  if SystemId = ROM_SYSTEM_N64 then
  begin
    var C := TN64Config.Create('', nil);
    Config := C;
    for var Port := 0 to 3 do
    begin
      var Section := 'Keys';
      if Port > 0 then
        Section := Section + IntToStr(Port + 1);
      AddKey(N64LAction + Port, ReadEmulatorKey(Ini, Section, 'L', C.LKey(Port)));
    end;
  end;
  if SystemId = ROM_SYSTEM_PS1 then
  begin
    var C := TPS1Config.Create('', nil);
    Config := C;
    for var Port := 0 to 1 do
    begin
      var Section := 'Keys';
      if Port > 0 then
        Section := Section + IntToStr(Port + 1);
      for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
        AddKey(PS1Action(Port, Extra), ReadEmulatorKey(Ini, Section, TPS1Config.ExtraKeyName(Extra),
          C.ExtraKey(Port, Extra)));
    end;
  end;
  if SystemId = ROM_SYSTEM_DC then
  begin
    var C := TDCConfig.Create('', nil);
    Config := C;
    for var Port := 0 to 3 do
    begin
      var Section := 'Keys';
      if Port > 0 then
        Section := Section + IntToStr(Port + 1);
      for var Extra := Low(TDCExtra) to High(TDCExtra) do
        AddKey(DCAction(Port, Extra), ReadEmulatorKey(Ini, Section, TDCConfig.ExtraKeyName(Extra),
          C.ExtraKey(Port, Extra)));
    end;
  end;
  if (SystemId = ROM_SYSTEM_NES) or (SystemId = ROM_SYSTEM_N64) or (SystemId = ROM_SYSTEM_DC) then
    Count := 4;
  if SystemId = ROM_SYSTEM_SNES then
    Count := 8;
  if SystemId = ROM_SYSTEM_SATURN then
    Count := 12;
  if (SystemId = ROM_SYSTEM_PCE) or (SystemId = ROM_SYSTEM_SGX) or (SystemId = ROM_SYSTEM_PCECD) then
    Count := 5;
  if (SystemId = ROM_SYSTEM_PSP) or (SystemId = ROM_SYSTEM_ZX) or (SystemId = ROM_SYSTEM_NGP) or (SystemId = ROM_SYSTEM_NGPC) or (SystemId = ROM_SYSTEM_GB) or (SystemId = ROM_SYSTEM_GBC) or (SystemId = ROM_SYSTEM_GBA) then
    Count := 1;
  if (SystemId = ROM_SYSTEM_MD) or (SystemId = ROM_SYSTEM_SEGACD) or (SystemId = ROM_SYSTEM_SEGA32X) then
    Count := 4;
  var BindingDevice := 'auto';
  if (SystemId = ROM_SYSTEM_PCE) or (SystemId = ROM_SYSTEM_SGX) or (SystemId = ROM_SYSTEM_PCECD) then
    BindingDevice := 'pad6';
  for var Port := 0 to Count - 1 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if (SystemId <> ROM_SYSTEM_SC3000) and (B in CoreButtons(SystemId, BindingDevice)) then
      begin
        var Section := 'Controls';
        if SystemId = ROM_SYSTEM_ZX then
          Section := 'Keys';
        if (SystemId = ROM_SYSTEM_CPS1) or (SystemId = ROM_SYSTEM_CPS2) or (SystemId = ROM_SYSTEM_CPS3) then
          Section := 'Keys';
        if (SystemId = ROM_SYSTEM_SG1000) or (SystemId = ROM_SYSTEM_SC3000) or (SystemId = ROM_SYSTEM_SF7000) or (SystemId = ROM_SYSTEM_OMV) or (SystemId = ROM_SYSTEM_SMS) or (SystemId = ROM_SYSTEM_GG) or (SystemId = ROM_SYSTEM_GW) or (SystemId = ROM_SYSTEM_N64) or ((SystemId = ROM_SYSTEM_MD) or (SystemId = ROM_SYSTEM_SEGACD) or (SystemId = ROM_SYSTEM_SEGA32X)) or (SystemId = ROM_SYSTEM_SNES) or ((SystemId = ROM_SYSTEM_NEOGEO) or (SystemId = ROM_SYSTEM_NEOGEOCD) or (SystemId = ROM_SYSTEM_NEOGEOAES)) or (SystemId = ROM_SYSTEM_GBA) then
          Section := 'Keys';
        if (SystemId = ROM_SYSTEM_PCE) or (SystemId = ROM_SYSTEM_SGX) or (SystemId = ROM_SYSTEM_PCECD) then
          Section := 'Keys';
        if (SystemId = ROM_SYSTEM_SATURN) or (SystemId = ROM_SYSTEM_NGP) or (SystemId = ROM_SYSTEM_NGPC) or
          (SystemId = ROM_SYSTEM_PS1) or (SystemId = ROM_SYSTEM_PSP) or (SystemId = ROM_SYSTEM_DC) then
          Section := 'Keys';
        if Port > 0 then
          Section := Section + IntToStr(Port + 1);
        var KeyName := CoreButtonName(SystemId, B).Replace('↑', 'Up').Replace('↓', 'Down')
          .Replace('←', 'Left').Replace('→', 'Right');
        if ((SystemId = ROM_SYSTEM_NGP) or (SystemId = ROM_SYSTEM_NGPC)) and (B = TEmulatorButton.Start) then
          KeyName := 'Start';
        if (SystemId = ROM_SYSTEM_SATURN) or (SystemId = ROM_SYSTEM_DC) then
          case B of
            TEmulatorButton.Select:
              KeyName := 'Select';
            TEmulatorButton.Mode:
              KeyName := 'Mode';
          end;

        // Config keys are stable identifiers, not the displayed GW button labels.
        if (SystemId = ROM_SYSTEM_PSP) or (SystemId = ROM_SYSTEM_ZX) or (SystemId = ROM_SYSTEM_GW) or (SystemId = ROM_SYSTEM_PCE) or (SystemId = ROM_SYSTEM_SGX) or (SystemId = ROM_SYSTEM_PCECD) then
          case B of
            TEmulatorButton.Mode:
              KeyName := 'Mode';
            TEmulatorButton.A:
              KeyName := 'A';
            TEmulatorButton.B:
              KeyName := 'B';
            TEmulatorButton.Select:
              KeyName := 'Select';
            TEmulatorButton.Start:
              KeyName := 'Start';
            TEmulatorButton.C:
              KeyName := 'C';
            TEmulatorButton.X:
              KeyName := 'X';
            TEmulatorButton.Y:
              KeyName := 'Y';
            TEmulatorButton.Z:
              KeyName := 'Z';
          end;
        AddKey(PadAction(Port, B), ReadEmulatorKey(Ini, Section, KeyName, Keys[Port, B]));
      end;
  for var i := 0 to 11 do
    AddKey(PowerPadAction + i, PowerKeys[i]);
  Input.AddBinding(TInputBinding.Create(ZapperTriggerAction,
      TInputValue.Create(SystemMouseId, TInputElementKind.Button, MouseLeft, 1)));
  if SystemId = ROM_SYSTEM_NES then
    EnsurePeripheralBindings(Input, Ini);
end;

function BindingCaption(Input: TInputManager; Action: Integer): string;
begin
  Result := Translate('Unassigned');
  if Input = nil then
    Exit;

  for var B in Input.Bindings do
    if B.Action = Action then
    begin
      if B.Kind = TInputElementKind.Key then
        Exit(InputKeyName(B.Code));

      if B.DeviceId = SystemMouseId then
        Exit(Translate(MouseElementName(B.Kind, B.Code)));

      Result := Format('%s %d', [Translate('Button'), B.Code + 1]);
      if B.Kind = TInputElementKind.Axis then
        Result := Format(Translate('Axis %d (%d)'), [B.Code, B.Direction]);
      if B.Kind = TInputElementKind.Hat then
        Result := Format('D-pad %d', [B.Direction]);
      for var D in Input.Devices do
        if D.Id = B.DeviceId then
          for var E in D.Elements do
            if (E.Kind = B.Kind) and (E.Code = B.Code) then
              Exit(E.Name);
      Exit;
    end;
end;

function ReadHostKeys(Input: TInputManager): THostKeys;
begin
  FillChar(Result, SizeOf(Result), 0);
  for var V in Input.Values do
    if (V.Kind = TInputElementKind.Key) and (V.Value > 0.5) then
    begin
      var K := HidToHostKey(V.Code);
      if (K > 0) and (K <= High(Result)) then
        Result[K] := True;
    end;
  Result[vkShift] := Result[vkLShift] or Result[vkRShift];
  Result[vkControl] := Result[vkLControl] or Result[vkRControl];
  Result[vkMenu] := Result[vkLMenu] or Result[vkRMenu];
end;

procedure FilterInputBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  var Bindings := Input.Bindings;
  Input.ClearBindings;
  for var B in Bindings do
  begin
    if not Ini.ReadBool('Ports', 'KeyboardEnabled', True) and
      (B.Kind = TInputElementKind.Key) and
      (((B.Action >= SuborAction) and (B.Action < ExtraPadAction)) or
      ((Ini.ReadString('Ports', 'Port1', 'auto') = 'piano') and (B.Action < 32))) then
      Continue;

    var Port := B.Action div 32;
    if (B.Action >= PowerPadAction) and (B.Action < SuborAction) then
      Port := 1;
    if (B.Action >= SuborAction) and (B.Action < PianoAction) then
      Port := 4;
    if (B.Action >= PianoAction) and (B.Action < ExtraPadAction) then
      Port := 0;
    if B.Action >= ExtraPadAction then
      Port := 4 + (B.Action - ExtraPadAction) div 32;
    if (B.Action >= PS1ExtraAction) and (B.Action < PS1ExtraAction + 2 * 16) then
      Port := (B.Action - PS1ExtraAction) div 16;
    var Source := '';
    if (Port >= 0) and (Port < 12) then
      Source := Ini.ReadString('Ports', 'Source' + IntToStr(Port + 1), '');
    if (Port = 4) and (B.Action < ExtraPadAction) then
      Source := Ini.ReadString('Ports', 'SourceExpansion', '');
    if (Source = '') or (Source = B.DeviceId) then
      Input.AddBinding(B);
  end;
end;

function ReadSuborInput(Input: TInputManager): TSuborKeys;
begin
  Result := [];
  if Input = nil then
    Exit;

  for var K := Low(TSuborKey) to High(TSuborKey) do
    if (K <> SkNone) and Input.IsPressed(SuborAction + Ord(K)) then
      Include(Result, K);
end;

function ReadFamicomInput(Input: TInputManager): TFamicomKeys;
begin
  Result := [];
  if Input = nil then
    Exit;

  for var K := Low(TFamicomKey) to High(TFamicomKey) do
    if (K <> FkNone) and Input.IsPressed(FamicomAction + Ord(K)) then
      Include(Result, K);
end;

function ReadPianoInput(Input: TInputManager): TMiracleKeys;
begin
  Result := [];
  if Input = nil then
    Exit;

  for var K := Low(TMiracleKey) to High(TMiracleKey) do
    if Input.IsPressed(PianoAction + K) then
      Include(Result, K);
end;

function ReadPadInput(Input: TInputManager; const Ports: TCoreInputPorts): TEmulatorInput;
var
  Pads: array[0..11] of TEmulatorButtons;
begin
  Result := Default(TEmulatorInput);
  for var P := 0 to 11 do
  begin
    Pads[P] := [];
    if (Ports.Devices[P] = 'auto') or Ports.Devices[P].StartsWith('pad') then
      for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
        if Input.IsPressed(PadAction(P, B)) then
          Include(Pads[P], B);
  end;
  Result.Buttons := Pads[0];
  Result.Buttons2 := Pads[1];
  Result.Buttons3 := Pads[2];
  Result.Buttons4 := Pads[3];
  Result.Buttons5 := Pads[4];
  Result.Buttons6 := Pads[5];
  Result.Buttons7 := Pads[6];
  Result.Buttons8 := Pads[7];
  Result.Buttons9 := Pads[8];
  Result.Buttons10 := Pads[9];
  Result.Buttons11 := Pads[10];
  Result.Buttons12 := Pads[11];
  var Bindings := Input.Bindings;
  var Values := Input.Values;
  for var P := 0 to High(Ports.Devices) do
  begin
    if Ports.Devices[P] <> 'pad-analog' then
      Continue;

    for var B in Bindings do
    begin
      if B.Kind <> TInputElementKind.Axis then
        Continue;

      for var V in Values do
        if (V.DeviceId = B.DeviceId) and (V.Kind = B.Kind) and (V.Code = B.Code) then
        begin
          var Travel := 1.0 - B.AxisOrigin * B.Direction;
          if Travel <= 0 then
            Continue;

          var Amount := EnsureRange((V.Value - B.AxisOrigin) * B.Direction / Travel, 0.0, 1.0);
          var Magnitude := Round(Amount * 32767);
          if B.Action = PadAction(P, TEmulatorButton.Left) then
          begin
            Result.Analog[P].X := EnsureRange(Integer(Result.Analog[P].X) - Magnitude, -32768, 32767);
            Result.Analog[P].Valid := True;
          end;
          if B.Action = PadAction(P, TEmulatorButton.Right) then
          begin
            Result.Analog[P].X := EnsureRange(Integer(Result.Analog[P].X) + Magnitude, -32768, 32767);
            Result.Analog[P].Valid := True;
          end;
          if B.Action = PadAction(P, TEmulatorButton.Up) then
          begin
            Result.Analog[P].Y := EnsureRange(Integer(Result.Analog[P].Y) - Magnitude, -32768, 32767);
            Result.Analog[P].Valid := True;
          end;
          if B.Action = PadAction(P, TEmulatorButton.Down) then
          begin
            Result.Analog[P].Y := EnsureRange(Integer(Result.Analog[P].Y) + Magnitude, -32768, 32767);
            Result.Analog[P].Valid := True;
          end;
          if B.Action = PadAction(P, TEmulatorButton.Select) then
          begin
            Result.Analog[P].LeftTrigger := Round(Amount * 255);
            Result.Analog[P].Valid := True;
          end;
          if B.Action = PadAction(P, TEmulatorButton.Mode) then
          begin
            Result.Analog[P].RightTrigger := Round(Amount * 255);
            Result.Analog[P].Valid := True;
          end;
        end;
    end;
  end;
end;

end.

