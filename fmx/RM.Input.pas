unit RM.Input;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.UITypes, FMXInput,
  Core.Emulation, Core.InputConfig, NES.Controller, NES.FamicomKeyboardDevice,
  NES.MiraclePianoDevice;

const
  PowerPadAction = 128;
  ZapperTriggerAction = 160;
  SuborAction = 256;
  FamicomAction = 384;
  PianoAction = 512;

type
  THostKeys = array[0..255] of Boolean;

function HidToHostKey(Code: Integer): Word;

function HostKeyToHid(Code: Word): Integer;

function PadAction(Port: Integer; Button: TEmulatorButton): Integer;

function CoreButtons(const SystemId, Device: string): TEmulatorButtons;

function CoreButtonName(const SystemId: string; Button: TEmulatorButton): string;

procedure LoadInputBindings(Input: TInputManager; Ini: TCustomIniFile; const SystemId: string);

procedure SaveInputBindings(Input: TInputManager; Ini: TCustomIniFile);

procedure FilterInputBindings(Input: TInputManager; Ini: TCustomIniFile);

function BindingCaption(Input: TInputManager; Action: Integer): string;

function ReadHostKeys(Input: TInputManager): THostKeys;

function ReadPadInput(Input: TInputManager; const Ports: TCoreInputPorts): TEmulatorInput;

function ReadSuborInput(Input: TInputManager): TSuborKeys;

function ReadFamicomInput(Input: TInputManager): TFamicomKeys;

function ReadPianoInput(Input: TInputManager): TMiracleKeys;

implementation

uses
  Core.Adapter.GB, Core.Adapter.NES, Core.Adapter.MD, Core.Adapter.SNES,
  GB.Joypad, NES.Input, NES.Types, MD.Console, SNES.Console, System.Math;

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

function PadAction(Port: Integer; Button: TEmulatorButton): Integer;
begin
  Result := Port * 32 + Ord(Button);
end;

function CoreButtons(const SystemId, Device: string): TEmulatorButtons;
begin
  Result := [];
  if not (Device = 'auto') and not Device.StartsWith('pad') then
    Exit;
  Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start];
  if SystemId = 'md' then
  begin
    Include(Result, TEmulatorButton.C);
    if Device <> 'pad3' then
      Result := Result + [TEmulatorButton.X, TEmulatorButton.Y,
          TEmulatorButton.Z, TEmulatorButton.Mode];
  end
  else
  begin
    Include(Result, TEmulatorButton.Select);
    if SystemId = 'snes' then
      Result := Result + [TEmulatorButton.X, TEmulatorButton.Y,
          TEmulatorButton.C, TEmulatorButton.Z];
  end;
end;

function CoreButtonName(const SystemId: string; Button: TEmulatorButton): string;
const
  Names: array[TEmulatorButton] of string =
    ('↑', '↓', '←', '→', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');
begin
  Result := Names[Button];
  if SystemId = 'snes' then
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
  Keys: array[0..3, TEmulatorButton] of Word;
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
    if SystemId = 'nes' then
      EnsurePeripheralBindings(Input, Ini);
    Exit;
  end;
  FillChar(Keys, SizeOf(Keys), 0);
  // Import the existing core keyboard maps once; all later assignments use FMXInput.
  if SystemId = 'nes' then
  begin
    var C := TNesEmulatorConfig.Create('');
    Config := C;
    CopyNES(0, C.GetKeys);
    CopyNES(1, C.GetKeys2);
    CopyNES(2, C.GetKeys3);
    CopyNES(3, C.GetKeys4);
  end
  else if SystemId = 'md' then
  begin
    var C := TMDConfig.Create('');
    Config := C;
    for var B := Low(TMDButton) to High(TMDButton) do
    begin
      Keys[0, MDMapping[B]] := C.Keys[B];
      Keys[1, MDMapping[B]] := C.Keys2[B];
    end;
  end
  else if SystemId = 'snes' then
  begin
    var C := TSnesConfig.Create('');
    Config := C;
    for var B := Low(TSnesButton) to High(TSnesButton) do
    begin
      Keys[0, SNESMapping[B]] := C.Keys[B];
      Keys[1, SNESMapping[B]] := C.Keys2[B];
    end;
  end
  else
  begin
    var C := TGBEmulatorConfig.Create('');
    Config := C;
    CopyGB(C.GetKeys);
  end;
  var Count := 2;
  if SystemId = 'nes' then
    Count := 4;
  if (SystemId = 'gb') or (SystemId = 'gbc') then
    Count := 1;
  for var Port := 0 to Count - 1 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if B in CoreButtons(SystemId, 'auto') then
      begin
        var Section := 'Controls';
        if (SystemId = 'md') or (SystemId = 'snes') then
          Section := 'Keys';
        if Port > 0 then
          Section := Section + IntToStr(Port + 1);
        AddKey(PadAction(Port, B), ReadEmulatorKey(Ini, Section,
            CoreButtonName(SystemId, B).Replace('↑', 'Up').Replace('↓', 'Down')
            .Replace('←', 'Left').Replace('→', 'Right'), Keys[Port, B]));
      end;
  for var i := 0 to 11 do
    AddKey(PowerPadAction + i, PowerKeys[i]);
  Input.AddBinding(TInputBinding.Create(ZapperTriggerAction,
      TInputValue.Create(SystemMouseId, TInputElementKind.Button, MouseLeft, 1)));
  if SystemId = 'nes' then
    EnsurePeripheralBindings(Input, Ini);
end;

function BindingCaption(Input: TInputManager; Action: Integer): string;
begin
  Result := 'Не назначено';
  if Input = nil then
    Exit;
  for var B in Input.Bindings do
    if B.Action = Action then
    begin
      if B.Kind = TInputElementKind.Key then
        Exit(InputKeyName(B.Code));
      if B.DeviceId = SystemMouseId then
        Exit(MouseElementName(B.Kind, B.Code));
      Result := Format('%s %d', ['Кнопка', B.Code + 1]);
      if B.Kind = TInputElementKind.Axis then
        Result := Format('Ось %d (%d)', [B.Code, B.Direction]);
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
      ((B.Action >= SuborAction) or
      ((Ini.ReadString('Ports', 'Port1', 'auto') = 'piano') and (B.Action < 32))) then
      Continue;
    var Port := B.Action div 32;
    if (B.Action >= PowerPadAction) and (B.Action < SuborAction) then
      Port := 1;
    if (B.Action >= SuborAction) and (B.Action < PianoAction) then
      Port := 4;
    if B.Action >= PianoAction then
      Port := 0;
    var Source := '';
    if (Port >= 0) and (Port < 4) then
      Source := Ini.ReadString('Ports', 'Source' + IntToStr(Port + 1), '');
    if Port = 4 then
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
  Pads: array[0..3] of TEmulatorButtons;
begin
  Result := Default(TEmulatorInput);
  for var P := 0 to 3 do
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
end;

end.

