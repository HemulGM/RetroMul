unit RM.Window.Layout;

interface

uses
  FMX.Controls, RM.Input.Runtime, RM.Gamepad.Viewport;

type
  TWindowLayoutContext = TInputRuntimeContext;

  TWindowControlWidth = (FormContent, ClientLayout);

  // Borrowed controls and stateless size functions; the view owns the controls.
  TWindowControlLayout = record
    Control: TControl;
    PreferredHeight: TControlPreferredHeight;
    WidthSource: TWindowControlWidth;
    ResizeOrder: Integer;
    InsetOrder: Integer; // Negative means this control has no bottom-inset setting.
    ViewportOrder: Integer; // Negative means ordinary aligned content, not an overlay.
    class function Create(Control: TControl; PreferredHeight: TControlPreferredHeight; WidthSource: TWindowControlWidth; ResizeOrder, InsetOrder: Integer; ViewportOrder: Integer = -1): TWindowControlLayout; static;
  end;

  TPlatformWindowLayout = class
  public
    class function Controls(const Context: TWindowLayoutContext): TArray<TWindowControlLayout>; virtual;
  end;

  TPlatformWindowLayoutClass = class of TPlatformWindowLayout;

procedure RegisterPlatformWindowLayout(const PlatformId: string; Layout: TPlatformWindowLayoutClass);

function TryPlatformWindowLayout(const PlatformId: string; out Layout: TPlatformWindowLayoutClass): Boolean;

function PlatformWindowLayout(const PlatformId: string): TPlatformWindowLayoutClass;

procedure ResizePlatformControls(const Context: TWindowLayoutContext);

procedure ApplyPlatformControlInset(const Context: TWindowLayoutContext);

procedure ArrangePlatformWindowControls(const Context: TWindowLayoutContext);

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, Core.Platforms, RM.Gamepad;

var
  Layouts: TDictionary<string, TPlatformWindowLayoutClass>;

class function TWindowControlLayout.Create(Control: TControl; PreferredHeight: TControlPreferredHeight; WidthSource: TWindowControlWidth; ResizeOrder, InsetOrder, ViewportOrder: Integer): TWindowControlLayout;
begin
  Result.Control := Control;
  Result.PreferredHeight := PreferredHeight;
  Result.WidthSource := WidthSource;
  Result.ResizeOrder := ResizeOrder;
  Result.InsetOrder := InsetOrder;
  Result.ViewportOrder := ViewportOrder;
end;

class function TPlatformWindowLayout.Controls(const Context: TWindowLayoutContext): TArray<TWindowControlLayout>;
begin
  Result := nil;
end;

procedure RegisterPlatformWindowLayout(const PlatformId: string; Layout: TPlatformWindowLayoutClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Layout = nil) then
    raise EArgumentException.Create('Invalid platform window layout: ' + PlatformId);
  if Layouts.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate platform window layout: ' + Id);
  Layouts.Add(Id, Layout);
end;

function TryPlatformWindowLayout(const PlatformId: string; out Layout: TPlatformWindowLayoutClass): Boolean;
begin
  Layout := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Layouts.TryGetValue(Id, Layout);
  if not Result then
    Result := Layouts.TryGetValue(TPlatformRegistry.CanonicalId(Id), Layout);
end;

function PlatformWindowLayout(const PlatformId: string): TPlatformWindowLayoutClass;
begin
  if not TryPlatformWindowLayout(PlatformId, Result) then
    Result := TPlatformWindowLayout;
end;

function WindowControls(const Context: TWindowLayoutContext): TArray<TWindowControlLayout>;
begin
  var Items := TList<TWindowControlLayout>.Create;
  var Classes := TList<TPlatformWindowLayoutClass>.Create;
  var Seen := TList<TControl>.Create;
  try
    // The common gamepad facade exists even when no platform module is linked.
    if Context.State.Input.Gamepad <> nil then
    begin
      Items.Add(TWindowControlLayout.Create(Context.State.Input.Gamepad,
          TScreenGamepad.PreferredHeight, TWindowControlWidth.FormContent, 40, 0, 10));
      Seen.Add(Context.State.Input.Gamepad);
    end;
    for var Layout in Layouts.Values do
      if not Classes.Contains(Layout) then
        Classes.Add(Layout);
    Classes.Sort(TComparer<TPlatformWindowLayoutClass>.Construct(
      function(const A, B: TPlatformWindowLayoutClass): Integer
      begin
        Result := CompareStr(A.ClassName, B.ClassName);
      end));
    for var Layout in Classes do
      for var Item in Layout.Controls(Context) do
        if (Item.Control <> nil) and not Seen.Contains(Item.Control) then
        begin
          Seen.Add(Item.Control);
          Items.Add(Item);
        end;
    Result := Items.ToArray;
  finally
    Seen.Free;
    Classes.Free;
    Items.Free;
  end;
end;

procedure ResizePlatformControls(const Context: TWindowLayoutContext);
begin
  var Items := WindowControls(Context);
  TArray.Sort<TWindowControlLayout>(Items, TComparer<TWindowControlLayout>.Construct(
    function(const A, B: TWindowControlLayout): Integer
    begin
      Result := CompareValue(A.ResizeOrder, B.ResizeOrder);
    end));
  for var Item in Items do
    if Assigned(Item.PreferredHeight) then
    begin
      var Width := Context.View.ClientWidth - Context.View.Padding.Left - Context.View.Padding.Right;
      if Item.WidthSource = TWindowControlWidth.ClientLayout then
        Width := Context.View.LayoutClient.Width;
      Item.Control.Height := Item.PreferredHeight(Width,
        Context.View.ClientHeight - Context.View.Padding.Top - Context.View.Padding.Bottom - Context.View.LayoutHead.Height);
    end;
end;

procedure ApplyPlatformControlInset(const Context: TWindowLayoutContext);
begin
  var Items := WindowControls(Context);
  TArray.Sort<TWindowControlLayout>(Items, TComparer<TWindowControlLayout>.Construct(
    function(const A, B: TWindowControlLayout): Integer
    begin
      Result := CompareValue(A.InsetOrder, B.InsetOrder);
    end));
  for var Item in Items do
    if Item.InsetOrder >= 0 then
      Item.Control.Margins.Bottom := Context.State.Input.BottomInset;
end;

procedure ArrangePlatformWindowControls(const Context: TWindowLayoutContext);
begin
  if (Context.State.Input.Gamepad = nil) or not (Context.State.Input.Gamepad.Parent is TControl) then
    Exit;
  var Items := WindowControls(Context);
  TArray.Sort<TWindowControlLayout>(Items, TComparer<TWindowControlLayout>.Construct(
    function(const A, B: TWindowControlLayout): Integer
    begin
      Result := CompareValue(A.ViewportOrder, B.ViewportOrder);
    end));
  var Overlays := TList<TViewportControl>.Create;
  try
    for var Item in Items do
      if Item.ViewportOrder >= 0 then
        Overlays.Add(TViewportControl.Create(Item.Control, Item.PreferredHeight));
    ArrangeVirtualControls(TControl(Context.State.Input.Gamepad.Parent), Context.View.ImageCanvas, Overlays.ToArray);
  finally
    Overlays.Free;
  end;
end;

initialization
  Layouts := TDictionary<string, TPlatformWindowLayoutClass>.Create(TIStringComparer.Ordinal);

finalization
  Layouts.Free;

end.

