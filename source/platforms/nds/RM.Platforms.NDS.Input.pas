unit RM.Platforms.NDS.Input;

interface

uses
  RM.Input.Runtime;

type
  TNDSInputHandler = class(TPlatformInputHandler)
    class procedure PointerButton(const Context: TInputRuntimeContext; X, Y: Single; Pressed: Boolean); override;
    class procedure PollInput(const Context: TInputRuntimeContext); override;
  end;

implementation

uses
  System.SysUtils, Core.Emulation, FMX.Platform, FMX.Types, FMX.Forms;

class procedure TNDSInputHandler.PointerButton(const Context: TInputRuntimeContext; X, Y: Single; Pressed: Boolean);
var
  Pointer: IEmulationPointerInput;
  Mouse: IEmulationMouseInput;
begin
  if Supports(Context.State.Session.Emulation, IEmulationPointerInput, Pointer) then
  begin
    var PX, PY: Integer;
    var Valid := TryGetImagePixel(Context.View.ImageCanvas, X, Y, PX, PY);
    Pointer.SetPointer(PX, PY, Valid);
  end;
  if Supports(Context.State.Session.Emulation, IEmulationMouseInput, Mouse) then
    Mouse.SendMouseDelta(0, 0, Ord(Pressed));
end;

class procedure TNDSInputHandler.PollInput(const Context: TInputRuntimeContext);
var
  Pointer: IEmulationPointerInput;
  Mouse: IFMXMouseService;
begin
  if Supports(Context.State.Session.Emulation, IEmulationPointerInput, Pointer) and
    TPlatformServices.Current.SupportsPlatformService(IFMXMouseService, Mouse) then
  begin
    var Point := Context.View.ImageCanvas.AbsoluteToLocal(Context.View.ScreenToClient(Mouse.GetMousePos));
    var PX, PY: Integer;
    var Valid := TryGetImagePixel(Context.View.ImageCanvas, Point.X, Point.Y, PX, PY);
    Pointer.SetPointer(PX, PY, Valid);
  end;
end;

end.

