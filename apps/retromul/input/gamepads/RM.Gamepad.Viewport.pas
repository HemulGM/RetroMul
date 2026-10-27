unit RM.Gamepad.Viewport;

interface

uses
  FMX.Controls, RM.Gamepad, NES.PowerPad;

// Shared by resize and session visibility changes. Safe-area padding belongs to
// the host form. Landscape controllers overlay the full fitted game image.
procedure ArrangeVirtualGamepads(Gamepad: TScreenGamepad; PowerPad: TNesPowerPad; Screen: TControl);

implementation

uses
  FMX.Types, FMX.Objects;

procedure ArrangeVirtualGamepads(Gamepad: TScreenGamepad; PowerPad: TNesPowerPad; Screen: TControl);
var
  W, H: Single;
  Landscape: Boolean;
begin
  if (Gamepad = nil) or (Screen = nil) or not (Gamepad.Parent is TControl) then
    Exit;

  W := TControl(Gamepad.Parent).Width;
  H := TControl(Gamepad.Parent).Height;
  Landscape := W > H;
  if Landscape then
  begin
    Gamepad.Align := TAlignLayout.Contents;
    if PowerPad <> nil then
      PowerPad.Align := TAlignLayout.Contents;
  end
  else
  begin
    Gamepad.Align := TAlignLayout.Bottom;
    Gamepad.Height := TScreenGamepad.PreferredHeight(W, H);
    if PowerPad <> nil then
    begin
      PowerPad.Align := TAlignLayout.Bottom;
      PowerPad.Height := TNesPowerPad.PreferredHeight(W, H);
    end;
  end;
  Screen.Margins.Left := 0;
  Screen.Margins.Right := 0;
  if Screen is TImage then
    TImage(Screen).WrapMode := TImageWrapMode.Fit;

  // The controller is an overlay; its hit test passes the central screen through.
  if Landscape then
    if (PowerPad <> nil) and PowerPad.Visible then
      PowerPad.BringToFront
    else if Gamepad.Visible then
      Gamepad.BringToFront;
end;

end.

