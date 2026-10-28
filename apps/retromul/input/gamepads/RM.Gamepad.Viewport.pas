unit RM.Gamepad.Viewport;

interface

uses
  FMX.Controls;

type
  TControlPreferredHeight = function(AvailableWidth, AvailableHeight: Single): Single;

  TViewportControl = record
    Control: TControl;
    PreferredHeight: TControlPreferredHeight;
    class function Create(Control: TControl; PreferredHeight: TControlPreferredHeight): TViewportControl; static;
  end;

// Controls are ordered from back to front. Safe-area padding belongs to the form.
procedure ArrangeVirtualControls(Host, Screen: TControl; const Controls: TArray<TViewportControl>);

implementation

uses
  FMX.Types, FMX.Objects;

class function TViewportControl.Create(Control: TControl; PreferredHeight: TControlPreferredHeight): TViewportControl;
begin
  Result.Control := Control;
  Result.PreferredHeight := PreferredHeight;
end;

procedure ArrangeVirtualControls(Host, Screen: TControl; const Controls: TArray<TViewportControl>);
begin
  if (Host = nil) or (Screen = nil) then
    Exit;
  var W := Host.Width;
  var H := Host.Height;
  var Landscape := W > H;
  for var Item in Controls do
    if Item.Control <> nil then
      if Landscape then
        Item.Control.Align := TAlignLayout.Contents
      else
      begin
        Item.Control.Align := TAlignLayout.Bottom;
        if Assigned(Item.PreferredHeight) then
          Item.Control.Height := Item.PreferredHeight(W, H);
      end;
  Screen.Margins.Left := 0;
  Screen.Margins.Right := 0;
  if Screen is TImage then
    TImage(Screen).WrapMode := TImageWrapMode.Fit;
  // Bring forward only the highest-priority visible controller, as before.
  if Landscape then
    for var I := High(Controls) downto 0 do
      if (Controls[I].Control <> nil) and Controls[I].Control.Visible then
      begin
        Controls[I].Control.BringToFront;
        Break;
      end;
end;

end.

