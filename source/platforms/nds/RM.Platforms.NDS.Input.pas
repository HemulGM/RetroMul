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
  System.SysUtils, System.Types, Core.Emulation;

class procedure TNDSInputHandler.PointerButton(const Context: TInputRuntimeContext; X, Y: Single; Pressed: Boolean);
var
  Pointer: IEmulationPointerInput;
  Mouse: IEmulationMouseInput;
begin
  if Supports(Context.Host.Core, IEmulationPointerInput, Pointer) then
  begin
    var Pixel: TPoint;
    var Valid := Context.Host.Video.TryLocalToFrame(PointF(X, Y), Pixel);
    Pointer.SetPointer(Pixel.X, Pixel.Y, Valid);
  end;
  if Supports(Context.Host.Core, IEmulationMouseInput, Mouse) then
    Mouse.SendMouseDelta(0, 0, Ord(Pressed));
end;

class procedure TNDSInputHandler.PollInput(const Context: TInputRuntimeContext);
var
  Pointer: IEmulationPointerInput;
begin
  if Supports(Context.Host.Core, IEmulationPointerInput, Pointer) then
  begin
    var Pixel: TPoint;
    var Valid := Context.Host.Video.TryPointerToFrame(Pixel);
    Pointer.SetPointer(Pixel.X, Pixel.Y, Valid);
  end;
end;

end.

