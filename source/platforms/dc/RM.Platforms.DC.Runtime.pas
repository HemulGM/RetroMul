unit RM.Platforms.DC.Runtime;

{$I RM.Mobile.inc}

interface

uses
  System.IniFiles, FMXInput, RM.Input, Core.Platforms.DC.Adapter,
  RM.Input.Runtime, Core.Emulation, RM.Session.Runtime;

const
  DCExtraAction = 4160;

type
  TDCInputHandler = class(TPlatformInputHandler)
  public
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

function DCAction(Port: Integer; Extra: TDCExtra): Integer;

function DCExtraName(Extra: TDCExtra): string;

function ReadDCPad(Input: TInputManager; Port: Integer): TDCAnalogPad;

type
  TDCSessionHandler = class(TPlatformSessionHandler)
  public
    class procedure Disconnect(const Context: TSessionRuntimeContext); override;
    class procedure FramePresented(const Context: TSessionRuntimeContext); override;
  end;

implementation

uses
  System.SysUtils, System.Math, RM.Gamepad, RM.Platforms.DC.VMUOverlay,
  FMX.Controls;

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

class procedure TDCInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  // Dreamcast stick and trigger axes from host bindings (the on-screen stick
  // and triggers arrive as Analog[0]).
  var DCInput: IDCControllerInput;
  if Supports(Context.State.Session.Emulation, IDCControllerInput, DCInput) then
    for var Port := 0 to 3 do
      DCInput.SetDCController(Port, ReadDCPad(Context.State.Input.Manager, Port));
end;

type
  IDCSessionOverlay = interface
    ['{85894416-6FDC-4C99-BA16-A014E32232F8}']
    function Overlay: TVMUOverlay;
  end;

  TDCSessionOverlay = class(TInterfacedObject, IDCSessionOverlay)
  private
    FOverlay: TVMUOverlay;
  public
    constructor Create(Host: TControl);
    destructor Destroy; override;
    function Overlay: TVMUOverlay;
  end;

const
  OverlayKey = 'retromul.session/dc-vmu';

constructor TDCSessionOverlay.Create(Host: TControl);
begin
  inherited Create;
  FOverlay := TVMUOverlay.Create(Host);
end;

destructor TDCSessionOverlay.Destroy;
begin
  FOverlay.Free;
  inherited;
end;

function TDCSessionOverlay.Overlay: TVMUOverlay;
begin
  Result := FOverlay;
end;

class procedure TDCSessionHandler.FramePresented(const Context: TSessionRuntimeContext);
begin
  var Value := Context.Data(OverlayKey);
  if Value = nil then
  begin
    Value := TDCSessionOverlay.Create(Context.View.ImageCanvas);
    Context.SetData(OverlayKey, Value);
  end;
  (Value as IDCSessionOverlay).Overlay.Update(Context.State.Session.Emulation);
end;

class procedure TDCSessionHandler.Disconnect(const Context: TSessionRuntimeContext);
begin
  var Value := Context.Data(OverlayKey);
  if Value <> nil then
    (Value as IDCSessionOverlay).Overlay.Hide;
  inherited;
end;

end.

