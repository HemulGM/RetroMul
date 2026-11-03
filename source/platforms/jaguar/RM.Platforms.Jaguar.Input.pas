unit RM.Platforms.Jaguar.Input;

interface

uses
  RM.Input.Runtime, Core.Emulation.Types, RM.Input, FMXInput, System.IniFiles;

function JaguarKeypadAction(Port, Key: Integer): Integer;

function JaguarKeypadCaption(Key: Integer): string;

procedure LoadJaguarLegacyBindings(Input: TInputManager; Ini: TCustomIniFile);

procedure MigrateJaguarBindings(Input: TInputManager; Ini: TCustomIniFile);

procedure FilterJaguarBinding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);

type
  TJaguarInputHandler = class(TPlatformInputHandler)
  public
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

implementation

uses
  System.SysUtils, System.UITypes, Core.Platforms.Jaguar.Adapter;

const
  KeypadActionBase = 2304;

function JaguarKeypadAction(Port, Key: Integer): Integer;
begin
  Result := KeypadActionBase + Port * 12 + Key;
end;

function JaguarKeypadCaption(Key: Integer): string;
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
    AddLegacyInputKey(Input, JaguarKeypadAction(0, Key), vk0 + Key);
    AddLegacyInputKey(Input, JaguarKeypadAction(1, Key), vkNumpad0 + Key);
  end;
  AddLegacyInputKey(Input, JaguarKeypadAction(0, 10), vkQ);
  AddLegacyInputKey(Input, JaguarKeypadAction(0, 11), vkW);
  AddLegacyInputKey(Input, JaguarKeypadAction(1, 10), vkSubtract);
  AddLegacyInputKey(Input, JaguarKeypadAction(1, 11), vkAdd);
end;

procedure LoadJaguarLegacyBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  LoadSharedLegacyBindings(Input, Ini);
  LoadDefaultKeypadBindings(Input);
end;

procedure MigrateJaguarBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  if (Ini.ReadString('FMXInput', 'Bindings', '') = '') or
    (Ini.ReadInteger('FMXInput', 'JaguarKeypadVersion', 0) >= 1) then
    Exit;
  for var Binding in Input.Bindings do
    if (Binding.Action >= KeypadActionBase) and (Binding.Action < KeypadActionBase + 96) then
      Exit;
  // Older saved profiles used hard-coded keypad keys outside the input manager.
  LoadDefaultKeypadBindings(Input);
end;

procedure FilterJaguarBinding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);
begin
  if (Binding.Action >= KeypadActionBase) and (Binding.Action < KeypadActionBase + 96) then
  begin
    var Port := (Binding.Action - KeypadActionBase) div 12;
    Policy.SourceKey := 'Source' + IntToStr(Port + 1);
    Policy.Enabled := not SameText(Ini.ReadString('Ports', 'Port' + IntToStr(Port + 1), 'auto'), 'none');
  end;
end;

class procedure TJaguarInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var Keypad: IJaguarKeypadInput;
  if not Supports(Context.State.Session.Emulation, IJaguarKeypadInput, Keypad) then
    Exit;
  for var Port := 0 to 7 do
  begin
    var Mask: Word := 0;
    if Context.State.Input.Manager <> nil then
      for var Key := 0 to 11 do
        if Context.State.Input.Manager.IsPressed(JaguarKeypadAction(Port, Key)) then
          Mask := Mask or (Word(1) shl Key);
    if (Port = 0) and (Context.State.Input.Gamepad <> nil) then
      Mask := Mask or (Context.State.Input.Gamepad.AuxiliaryButtons and $FFF);
    Keypad.SetVirtualKeypad(Port, Mask);
  end;
end;

end.

