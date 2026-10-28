unit RM.Controls.Lifetime;
interface
uses FMX.Controls;
procedure DisconnectControl(Control: TControl);
procedure RetireControl(Control: TControl);
implementation
uses FMX.Types, FMX.StdCtrls, FMX.Edit, FMX.ListBox, FMX.SpinBox;
type TControlAccess = class(TControl);
procedure DisconnectControl(Control: TControl);
begin
  // Clear FMX's reference as well as its native capture before detaching.
  var Root := Control.Root;
  if (Root <> nil) and (Root.Captured <> nil) then
  begin
    var Captured := Root.Captured.GetObject;
    if (Captured = Control) or Control.IsChild(Captured) then
      Root.SetCaptured(nil);
  end;
  var ControlAccess := TControlAccess(Control);
  ControlAccess.OnClick := nil;
  ControlAccess.OnDblClick := nil;
  ControlAccess.OnMouseDown := nil;
  ControlAccess.OnMouseUp := nil;
  ControlAccess.OnMouseMove := nil;
  ControlAccess.OnMouseWheel := nil;
  ControlAccess.OnResize := nil;
  ControlAccess.OnKeyDown := nil;
  ControlAccess.OnKeyUp := nil;
  ControlAccess.OnEnter := nil;
  ControlAccess.OnExit := nil;
  ControlAccess.TagObject := nil;
  if Control is TComboBox then
    TComboBox(ControlAccess).OnChange := nil;
  if Control is TSwitch then
    TSwitch(ControlAccess).OnSwitch := nil;
  if Control is TSpinBox then
    TSpinBox(ControlAccess).OnChange := nil;
  if Control is TEdit then
    TEdit(ControlAccess).OnChangeTracking := nil;
  if Control is TTrackBar then
    TTrackBar(ControlAccess).OnChange := nil;
  if ControlAccess.ChildrenCount > 0 then
    for var Child in ControlAccess.Children.ToArray do
      if Child is TControl then
        DisconnectControl(TControl(Child));
  Control.Name := '';
end;

procedure RetireControl(Control: TControl);
begin
  DisconnectControl(Control);
  Control.Visible := False;
  Control.Parent := nil;
  Control.Release;
end;

end.
