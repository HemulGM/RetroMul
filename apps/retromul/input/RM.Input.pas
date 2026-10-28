unit RM.Input;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.UITypes, FMXInput,
  Core.Emulation, Core.InputConfig;

const
  // Historical encoding of logical buttons for players 5..12.
  ExtraPadAction = 1024;

type
  THostKeys = array[0..255] of Boolean;

  TPlatformInputKeyMap = array[0..11, TEmulatorButton] of Word;

  TInputButtonNames = array[TEmulatorButton] of string;

  TInputKeyMapLoader = reference to procedure(var Keys: TPlatformInputKeyMap);

  TInputBindingsSetup = reference to procedure(Input: TInputManager; Ini: TCustomIniFile);

  TInputBindingPolicy = record
    Enabled: Boolean;
    SourceKey: string;
  end;

  TInputBindingFilter = reference to procedure(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);

  TInputDeviceVariant = record
    DeviceId: string;
    Buttons: TEmulatorButtons;
    class function Create(const DeviceId: string; const Buttons: TEmulatorButtons): TInputDeviceVariant; static;
  end;

  TPlatformInputDefinition = record
    Buttons: TEmulatorButtons;
    // Preserve the historical auto/pad* fallback without limiting explicit variants.
    PadDevicesOnly: Boolean;
    Devices: TArray<TInputDeviceVariant>;
    ButtonNames, LegacyKeyNames: TInputButtonNames;
    LegacyPorts: Integer;
    LegacySection: string;
    LegacyButtons: TEmulatorButtons;
    // Existing profiles opt into shared historical codecs. New profiles are independent.
    UseSharedBindingRules: Boolean;
    SharedBindingOrder: Integer;
    SharedLegacyBindings: TInputBindingsSetup;
    SharedFilterBinding, FilterBinding: TInputBindingFilter;
    LoadLegacyKeys: TInputKeyMapLoader;
    BeforeLegacyBindings, AfterLegacyBindings, AfterLoadBindings: TInputBindingsSetup;
    class function Create(const Buttons: TEmulatorButtons): TPlatformInputDefinition; static;
  end;

// Static platform registration. Definitions and device arrays are copied.
procedure RegisterPlatformInput(const PlatformId: string; const Definition: TPlatformInputDefinition);

function TryPlatformInput(const PlatformId: string; out Definition: TPlatformInputDefinition): Boolean;

procedure AddLegacyInputKey(Input: TInputManager; Action: Integer; Code: Word);
// Opt-in compatibility contributions registered by the owning platform modules.

procedure LoadSharedLegacyBindings(Input: TInputManager; Ini: TCustomIniFile);

function HidToHostKey(Code: Integer): Word;

function HostKeyToHid(Code: Word): Integer;

function PadAction(Port: Integer; Button: TEmulatorButton): Integer;

// Generic axis travel, including calibrated trigger origins and digital fallback.
function ActionAmount(Input: TInputManager; const Bindings: TArray<TInputBinding>; const Values: TArray<TInputValue>; Action: Integer): Single;

function CoreButtons(const SystemId, Device: string): TEmulatorButtons;

function CoreButtonName(const SystemId: string; Button: TEmulatorButton): string;

procedure LoadInputBindings(Input: TInputManager; Ini: TCustomIniFile; const SystemId: string);

procedure SaveInputBindings(Input: TInputManager; Ini: TCustomIniFile);

procedure FilterInputBindings(Input: TInputManager; Ini: TCustomIniFile; const SystemId: string = '');

function BindingCaption(Input: TInputManager; Action: Integer): string;

// First available rumble controller bound to this player's pad buttons.
function RumbleDeviceId(Input: TInputManager; Port: Integer): string;

function ReadHostKeys(Input: TInputManager): THostKeys;

function ReadPadInput(Input: TInputManager; const Ports: TCoreInputPorts): TEmulatorInput;

// Reads the aggregate mouse once, avoiding duplicate physical-device aliases.
procedure ReadRelativeMouse(Input: TInputManager; out DX, DY: Integer; out Buttons: Byte);

implementation

uses
  System.Generics.Collections, System.Generics.Defaults, Core.Platforms,
  System.Math, FMX.Types;

var
  PlatformInputs: TDictionary<string, TPlatformInputDefinition>;

class function TInputDeviceVariant.Create(const DeviceId: string; const Buttons: TEmulatorButtons): TInputDeviceVariant;
begin
  Result.DeviceId := DeviceId;
  Result.Buttons := Buttons;
end;

class function TPlatformInputDefinition.Create(const Buttons: TEmulatorButtons): TPlatformInputDefinition;
const
  Names: TInputButtonNames = ('↑', '↓', '←', '→', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');
  Keys: TInputButtonNames = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');
begin
  Result := Default(TPlatformInputDefinition);
  Result.Buttons := Buttons;
  Result.PadDevicesOnly := True;
  Result.ButtonNames := Names;
  Result.LegacyKeyNames := Keys;
  Result.LegacyButtons := Buttons;
  Result.LegacyPorts := 1;
  Result.LegacySection := 'Keys';
end;

procedure RegisterPlatformInput(const PlatformId: string; const Definition: TPlatformInputDefinition);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Definition.LegacyPorts < 0) or (Definition.LegacyPorts > 12) or
    ((Definition.LegacyPorts > 0) and (Definition.LegacySection = '')) then
    raise EArgumentException.Create('Invalid platform input: ' + PlatformId);
  if PlatformInputs.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate platform input: ' + Id);
  var Item := Definition;
  Item.Devices := Copy(Definition.Devices);
  for var I := 0 to High(Item.Devices) do
  begin
    if Item.Devices[I].DeviceId = '' then
      raise EArgumentException.Create('Empty input device variant');
    for var J := 0 to I - 1 do
      if Item.Devices[J].DeviceId = Item.Devices[I].DeviceId then
        raise EArgumentException.Create('Duplicate input device variant: ' + Item.Devices[I].DeviceId);
  end;
  PlatformInputs.Add(Id, Item);
end;

function FindPlatformInput(const PlatformId: string; out Definition: TPlatformInputDefinition): Boolean;
begin
  Definition := Default(TPlatformInputDefinition);
  var Id := PlatformId.Trim.ToLower;
  Result := PlatformInputs.TryGetValue(Id, Definition);
  if not Result then
    Result := PlatformInputs.TryGetValue(TPlatformRegistry.CanonicalId(Id), Definition);
end;

function TryPlatformInput(const PlatformId: string; out Definition: TPlatformInputDefinition): Boolean;
begin
  Result := FindPlatformInput(PlatformId, Definition);
  if Result then
    Definition.Devices := Copy(Definition.Devices);
end;

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

// 0..1: the deflection of an axis bound to the action, else 1 while pressed.
function ActionAmount(Input: TInputManager; const Bindings: TArray<TInputBinding>; const Values: TArray<TInputValue>; Action: Integer): Single;
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

function CoreButtons(const SystemId, Device: string): TEmulatorButtons;
begin
  Result := [];
  var Definition: TPlatformInputDefinition;
  if not FindPlatformInput(SystemId, Definition) then
    Exit;
  for var Variant in Definition.Devices do
    if Variant.DeviceId = Device then
      Exit(Variant.Buttons);
  if Definition.PadDevicesOnly and (Device <> 'auto') and not Device.StartsWith('pad') then
    Exit;
  Result := Definition.Buttons;
end;

function CoreButtonName(const SystemId: string; Button: TEmulatorButton): string;
begin
  var Definition: TPlatformInputDefinition;
  if not FindPlatformInput(SystemId, Definition) then
    Definition := TPlatformInputDefinition.Create([]);
  Result := Definition.ButtonNames[Button];
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

procedure AddLegacyInputKey(Input: TInputManager; Action: Integer; Code: Word);
begin
  var Hid := HostKeyToHid(Code);
  if Hid <> 0 then
    Input.AddBinding(TInputBinding.Create(Action,
        TInputValue.Create(SystemKeyboardId, TInputElementKind.Key, Hid, 1)));
end;

procedure LoadInputBindings(Input: TInputManager; Ini: TCustomIniFile; const SystemId: string);
begin
  Input.CancelCapture;
  Input.ClearBindings;
  var Definition: TPlatformInputDefinition;
  var Registered := FindPlatformInput(SystemId, Definition);
  var JSON := Ini.ReadString('FMXInput', 'Bindings', '');
  if JSON <> '' then
  begin
    var Stream := TStringStream.Create(JSON, TEncoding.UTF8);
    try
      Input.LoadBindings(Stream);
    finally
      Stream.Free;
    end;
  end
  else if Registered then
  begin
    var Keys := Default(TPlatformInputKeyMap);
    if Assigned(Definition.LoadLegacyKeys) then
      Definition.LoadLegacyKeys(Keys);
    if Assigned(Definition.BeforeLegacyBindings) then
      Definition.BeforeLegacyBindings(Input, Ini);
    for var Port := 0 to Definition.LegacyPorts - 1 do
      for var B in Definition.LegacyButtons do
      begin
        var Section := Definition.LegacySection;
        if Port > 0 then
          Section := Section + IntToStr(Port + 1);
        AddLegacyInputKey(Input, PadAction(Port, B),
          ReadEmulatorKey(Ini, Section, Definition.LegacyKeyNames[B], Keys[Port, B]));
      end;
    if Assigned(Definition.AfterLegacyBindings) then
      Definition.AfterLegacyBindings(Input, Ini);
  end;
  if Registered and Assigned(Definition.AfterLoadBindings) then
    Definition.AfterLoadBindings(Input, Ini);
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

function OrderedSharedInputs: TArray<string>;
begin
  Result := PlatformInputs.Keys.ToArray;
  TArray.Sort<string>(Result, TComparer<string>.Construct(
    function(const A, B: string): Integer
    begin
      Result := CompareValue(PlatformInputs[A].SharedBindingOrder, PlatformInputs[B].SharedBindingOrder);
      if Result = 0 then
        Result := CompareStr(A, B);
    end));
end;

procedure LoadSharedLegacyBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  for var Id in OrderedSharedInputs do
  begin
    var Definition := PlatformInputs[Id];
    if Assigned(Definition.SharedLegacyBindings) then
      Definition.SharedLegacyBindings(Input, Ini);
  end;
end;

procedure FilterInputBindings(Input: TInputManager; Ini: TCustomIniFile; const SystemId: string);
begin
  var Definition: TPlatformInputDefinition;
  var Registered := FindPlatformInput(SystemId, Definition);
  var Rules := OrderedSharedInputs;
  var Bindings := Input.Bindings;
  Input.ClearBindings;
  for var Binding in Bindings do
  begin
    var Policy := Default(TInputBindingPolicy);
    Policy.Enabled := True;
    var Port := Binding.Action div 32;
    if Binding.Action >= ExtraPadAction then
      Port := 4 + (Binding.Action - ExtraPadAction) div 32;
    if (Port >= 0) and (Port < 12) then
      Policy.SourceKey := 'Source' + IntToStr(Port + 1);
    if not Registered or Definition.UseSharedBindingRules then
      for var Id in Rules do
      begin
        var Shared := PlatformInputs[Id];
        if Assigned(Shared.SharedFilterBinding) then
          Shared.SharedFilterBinding(Binding, Ini, Policy);
      end;
    if Registered and Assigned(Definition.FilterBinding) then
      Definition.FilterBinding(Binding, Ini, Policy);
    if not Policy.Enabled then
      Continue;
    var Source := '';
    if Policy.SourceKey <> '' then
      Source := Ini.ReadString('Ports', Policy.SourceKey, '');
    if (Source = '') or (Source = Binding.DeviceId) then
      Input.AddBinding(Binding);
  end;
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

initialization
  PlatformInputs := TDictionary<string, TPlatformInputDefinition>.Create(TIStringComparer.Ordinal);

finalization
  PlatformInputs.Free;

end.

