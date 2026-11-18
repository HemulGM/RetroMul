unit RM.Platforms.Flash;

interface

type
  TFlashPlatform = class
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Emulation,
  Core.Platforms, Core.EmulatorRegistry, Core.Platforms.Flash.Adapter,
  Core.PlatformServices, RM.Input, RM.Input.Runtime, RM.Settings.Platform,
  RM.Window.Layout, RM.Session.Runtime, RM.Settings.Runtime,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Gamepad,
  RM.Platforms.CPS.Icons, RM.Settings.Catalog, FMXInput, RM.Input.Gamepads,
  RM.Platforms.NES.Gamepads;

type
  TFlashInputHandler = class(TPlatformInputHandler)
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
  end;

var
  Registered: Boolean;

procedure LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var B := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, B), Ord(B), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
end;

class function TFlashInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := inherited;
  Result.KeyboardActive := True;
  Result.ForwardWithManager := True;
  Result.ReserveCaptureShortcuts := True;
  Result.ControlKeys := [vkF7, vkF8, vkF9, vkF10];
end;

function Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.Signature(0, 'FWS') or Context.Signature(0, 'CWS') or Context.Signature(0, 'ZWS') then
    Result := ImageMatch(Context, 'FLASH',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TFlashCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end,
          False, 'flash');
end;

class procedure TFlashPlatform.RegisterPlatform;
begin
  if Registered then
    Exit;
  TPlatformRegistry.RegisterPlatform('flash', 'Adobe Flash (AS1/AS2)', 'Flash',
    'Adobe / Macromedia', 'Flash SWF ActionScript AVM1', 'flash', ['flash', 'swf'], ['.swf'], 'Flash', 'flash', 1);
  var Registration := TEmulationCoreRegistration.Create('FLASH', ['.swf']);
  Registration.Add(TCoreLoadStage.Image, 60, Recognize);
  RegisterEmulationCore(Registration);
  RegisterPlatformInputHandler('flash', TFlashInputHandler);
  RegisterSettingsPlatform('flash', TSettingsPlatform);
  RegisterPlatformWindowLayout('flash', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('flash', TPlatformSessionHandler);
  RegisterPlatformSettingsHandler('flash', TPlatformSettingsHandler);
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.ButtonNames[TEmulatorButton.A] := 'Space';
  Definition.ButtonNames[TEmulatorButton.B] := 'X';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Shift';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Enter';
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('flash', Definition);
  RegisterPlatformGamepads('flash', TGamepadNESStandart, []);
  RegisterPlatformPresentation('flash', 'flash', PlatformIconCPS);
  var Services := Default(TPlatformServices);
  Services.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    begin
      Result := Default(TTerminalInputPolicy);
      Result.AllKeys := True;
      Result.ExitKey := vkEscape;
    end;
  RegisterPlatformServices('flash', Services);
  Registered := True;
end;

end.

