unit RM.Platforms.Atari5200.Input;

interface

uses
  RM.Input.Runtime, Core.Emulation.Types, RM.Input, FMXInput, System.IniFiles;

function Atari5200KeypadAction(Port, Key: Integer): Integer;

function Atari5200KeypadCaption(Key: Integer): string;

procedure LoadAtari5200LegacyBindings(Input: TInputManager; Ini: TCustomIniFile);

procedure MigrateAtari5200Bindings(Input: TInputManager; Ini: TCustomIniFile);

procedure FilterAtari5200Binding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);

type
  TAtari5200InputHandler = class(TPlatformInputHandler)
  public
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

implementation

uses
  System.SysUtils, System.UITypes, Core.Platforms.Atari5200.Adapter;

const
  KeypadActionBase = 2048;

function Atari5200KeypadAction(Port, Key: Integer): Integer;
begin
  Result := KeypadActionBase + Port * 12 + Key;
end;

function Atari5200KeypadCaption(Key: Integer): string;
begin
  case Key of
    10:
      Result := '*';
    11:
      Result := '#';
  else
    Result := IntToStr(Key);
  end;
end;

procedure LoadDefaultKeypadBindings(Input: TInputManager);
begin
  for var Key := 0 to 9 do
  begin
    AddLegacyInputKey(Input, Atari5200KeypadAction(0, Key), vk0 + Key);
    AddLegacyInputKey(Input, Atari5200KeypadAction(1, Key), vkNumpad0 + Key);
  end;
  AddLegacyInputKey(Input, Atari5200KeypadAction(0, 10), vkQ);
  AddLegacyInputKey(Input, Atari5200KeypadAction(0, 11), vkW);
  AddLegacyInputKey(Input, Atari5200KeypadAction(1, 10), vkSubtract);
  AddLegacyInputKey(Input, Atari5200KeypadAction(1, 11), vkAdd);
end;

procedure LoadAtari5200LegacyBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  LoadSharedLegacyBindings(Input, Ini);
  LoadDefaultKeypadBindings(Input);
end;

procedure MigrateAtari5200Bindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  if (Ini.ReadString('FMXInput', 'Bindings', '') = '') or
    (Ini.ReadInteger('FMXInput', 'Atari5200KeypadVersion', 0) >= 1) then
    Exit;
  for var Binding in Input.Bindings do
    if (Binding.Action >= KeypadActionBase) and (Binding.Action < KeypadActionBase + 48) then
      Exit;
  // Older saved profiles used hard-coded keypad keys outside the input manager.
  LoadDefaultKeypadBindings(Input);
end;

procedure FilterAtari5200Binding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);
begin
  if (Binding.Action >= KeypadActionBase) and (Binding.Action < KeypadActionBase + 48) then
  begin
    var Port := (Binding.Action - KeypadActionBase) div 12;
    Policy.SourceKey := 'Source' + IntToStr(Port + 1);
    Policy.Enabled := not SameText(Ini.ReadString('Ports', 'Port' + IntToStr(Port + 1), 'auto'), 'none');
  end;
end;

class procedure TAtari5200InputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var Keypad: IAtari5200KeypadInput;
  if not Supports(Context.State.Session.Emulation, IAtari5200KeypadInput, Keypad) then
    Exit;
  for var Port := 0 to 3 do
  begin
    var Mask: Word := 0;
    if Context.State.Input.Manager <> nil then
      for var Key := 0 to 11 do
        if Context.State.Input.Manager.IsPressed(Atari5200KeypadAction(Port, Key)) then
          Mask := Mask or (Word(1) shl Key);
    if (Port = 0) and (Context.State.Input.Gamepad <> nil) then
      Mask := Mask or (Context.State.Input.Gamepad.AuxiliaryButtons and $FFF);
    Keypad.SetVirtualKeypad(Port, Mask);
  end;
end;

end.

