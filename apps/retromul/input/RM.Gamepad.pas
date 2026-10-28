unit RM.Gamepad;

interface

uses
  System.Classes, System.Types, FMX.Types, FMX.Controls, FMX.Forms,
  Core.Emulation, Core.Emulation.Types, Core.Platforms,
  RM.Platforms.Presentation, RM.Gamepad.Base;

type
  // Stable host API. The platform-specific child is the actual virtual control.
  TScreenGamepad = class(TControl)
  private
    FPad: TPlatformGamepad;
    FLayoutScale: Single;
    FSystemId: string;
    FDevice: string;
    FButtonMask: TEmulatorButtons;
    FForm: TCommonCustomForm;
    FOnChange: TNotifyEvent;
    procedure SetLayoutScale(Value: Single);
    procedure UpdateLayoutScale;
    procedure PadChanged(Sender: TObject);
    procedure ReplacePad(const SystemId: string; const Device: string);
    procedure SetButtonMask(const Value: TEmulatorButtons);
    procedure SetCoreButtons(const Value: TEmulatorButtons);
    function GetAnalogInput: TEmulatorAnalogPad;
    function GetRightAnalogInput: TEmulatorAnalogPad;
    function GetAuxiliaryButtons: Cardinal;
    function GetButtons: TEmulatorButtons;
    function GetCoreButtons: TEmulatorButtons;
    function GetHighlightedButtons: TEmulatorButtons;
    function GetAspectRatio: Single;
  protected
    procedure EnabledChanged; override;
    procedure VisibleChanged; override;
    procedure AncestorVisibleChanged(const Visible: Boolean); override;
    procedure Resize; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    class function PreferredHeight(AvailableWidth, AvailableHeight: Single): Single; static;
    procedure Configure(const SystemId: string; const Device: string; const Buttons: TEmulatorButtons);
    procedure AttachToForm(Form: TCommonCustomForm);
    procedure PointerDown(Id: NativeInt; const Point: TPointF);
    procedure PointerMove(Id: NativeInt; const Point: TPointF);
    procedure PointerUp(Id: NativeInt);
    procedure ReleaseAll;
    function ButtonBounds(Button: TEmulatorButton): TRectF;
    function AuxiliaryButtonBounds(Index: Integer): TRectF;
    property AuxiliaryButtons: Cardinal read GetAuxiliaryButtons;
    function PointInObjectLocal(X, Y: Single): Boolean; override;
    property SystemId: string read FSystemId;
    property DeviceId: string read FDevice;
    property PlatformPad: TPlatformGamepad read FPad;
    property LayoutScale: Single read FLayoutScale write SetLayoutScale;
    property AnalogInput: TEmulatorAnalogPad read GetAnalogInput;
    property RightAnalogInput: TEmulatorAnalogPad read GetRightAnalogInput;
    property Buttons: TEmulatorButtons read GetButtons;
    property CoreButtons: TEmulatorButtons read GetCoreButtons write SetCoreButtons;
    property HighlightedButtons: TEmulatorButtons read GetHighlightedButtons;
    // Compatibility for existing clients; application code uses Configure.
    property ButtonMask: TEmulatorButtons read FButtonMask write SetButtonMask;
    property AspectRatio: Single read GetAspectRatio;
  published
    property Align;
    property Enabled;
    property Margins;
    property Position;
    property Size;
    property Visible;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

uses
  System.SysUtils, System.Math, RM.Gamepad.Factory, RM.Controls.Lifetime;

constructor TScreenGamepad.Create(AOwner: TComponent);
begin
  inherited;
  FLayoutScale := 1;
  FButtonMask := [Low(TEmulatorButton)..High(TEmulatorButton)];
  SetBounds(0, 0, 480, 320);
end;

destructor TScreenGamepad.Destroy;
begin
  FOnChange := nil;
  AttachToForm(nil);
  FreeAndNil(FPad);
  inherited;
end;

procedure TScreenGamepad.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
end;

procedure TScreenGamepad.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TScreenGamepad.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TScreenGamepad.Resize;
begin
  inherited;
  ReleaseAll;
  UpdateLayoutScale;
end;

procedure TScreenGamepad.SetLayoutScale(Value: Single);
begin
  if IsNan(Value) or IsInfinite(Value) then
    Exit;
  Value := EnsureRange(Value, 0.5, 2.0);
  if FLayoutScale = Value then
    Exit;
  FLayoutScale := Value;
  UpdateLayoutScale;
end;

procedure TScreenGamepad.UpdateLayoutScale;
begin
  if FPad = nil then
    Exit;
  // Scale relative to the fitted default size, including on small screens.
  // The child caps the result to the available space for drawing and input.
  var Fit := Min(1.0, Min(Width / (2 * FPad.DesignSideSize.Width),
      Height / FPad.DesignSideSize.Height));
  FPad.LayoutScale := Max(0.001, Fit * FLayoutScale);
end;

procedure TScreenGamepad.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FForm) then
    FForm := nil;
end;

procedure TScreenGamepad.PadChanged(Sender: TObject);
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TScreenGamepad.ReplacePad(const SystemId: string; const Device: string);
begin
  var NewClass := GamepadClass(SystemId, Device);
  if (FPad <> nil) and (FPad.ClassType = NewClass) then
  begin
    FSystemId := SystemId.Trim.ToLower;
    FDevice := Device;
    FPad.ButtonMask := FButtonMask;
    Exit;
  end;
  // Construct before releasing the old layout, so exceptions leave a valid pad.
  var NewPad := CreatePlatformGamepad(Self, SystemId, Device);
  try
    NewPad.ButtonMask := FButtonMask;
    if FPad <> nil then
    begin
      FPad.ReleaseAll;
      FPad.OnChange := nil;
      FPad.AttachToForm(nil);
    end;
    if FPad <> nil then
      RetireControl(FPad);
    FPad := NewPad;
    NewPad := nil;
    FSystemId := SystemId.Trim.ToLower;
    FDevice := Device;
    FPad.Parent := Self;
    FPad.Align := TAlignLayout.Client;
    UpdateLayoutScale;
    FPad.OnChange := PadChanged;
    FPad.AttachToForm(FForm);
  finally
    NewPad.Free;
  end;
end;

procedure TScreenGamepad.Configure(const SystemId: string; const Device: string; const Buttons: TEmulatorButtons);
begin
  FButtonMask := Buttons;
  ReplacePad(SystemId, Device);
end;

procedure TScreenGamepad.SetButtonMask(const Value: TEmulatorButtons);
begin
  if FButtonMask = Value then
    Exit;
  FButtonMask := Value;
  if FPad <> nil then
    FPad.ButtonMask := Value;
end;

class function TScreenGamepad.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := TVirtualGamepadControl.PreferredHeight(AvailableWidth, AvailableHeight);
end;

procedure TScreenGamepad.AttachToForm(Form: TCommonCustomForm);
begin
  if FForm <> nil then
    FForm.RemoveFreeNotification(Self);
  FForm := Form;
  if FForm <> nil then
    FForm.FreeNotification(Self);
  if FPad <> nil then
    FPad.AttachToForm(Form);
end;

function TScreenGamepad.GetAnalogInput: TEmulatorAnalogPad;
begin
  Result := Default(TEmulatorAnalogPad);
  if FPad <> nil then
    Result := FPad.AnalogInput;
end;

function TScreenGamepad.GetRightAnalogInput: TEmulatorAnalogPad;
begin
  Result := Default(TEmulatorAnalogPad);
  if FPad <> nil then
    Result := FPad.RightAnalogInput;
end;

function TScreenGamepad.GetAuxiliaryButtons: Cardinal;
begin
  Result := 0;
  if FPad <> nil then
    Result := FPad.AuxiliaryButtons;
end;

function TScreenGamepad.AuxiliaryButtonBounds(Index: Integer): TRectF;
begin
  Result := TRectF.Empty;
  if FPad = nil then
    Exit;
  Result := FPad.AuxiliaryButtonBounds(Index);
  if Result.IsEmpty then
    Exit;
  Result := TRectF.Create(AbsoluteToLocal(FPad.LocalToAbsolute(Result.TopLeft)),
    AbsoluteToLocal(FPad.LocalToAbsolute(Result.BottomRight)));
end;

function TScreenGamepad.GetButtons: TEmulatorButtons;
begin
  Result := [];
  if FPad <> nil then
    Result := FPad.Buttons;
end;

function TScreenGamepad.GetCoreButtons: TEmulatorButtons;
begin
  Result := [];
  if FPad <> nil then
    Result := FPad.CoreButtons;
end;

function TScreenGamepad.GetHighlightedButtons: TEmulatorButtons;
begin
  Result := [];
  if FPad <> nil then
    Result := FPad.HighlightedButtons;
end;

procedure TScreenGamepad.SetCoreButtons(const Value: TEmulatorButtons);
begin
  if FPad <> nil then
    FPad.CoreButtons := Value;
end;

procedure TScreenGamepad.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if FPad <> nil then
    FPad.PointerDown(Id, FPad.AbsoluteToLocal(LocalToAbsolute(Point)));
end;

procedure TScreenGamepad.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if FPad <> nil then
    FPad.PointerMove(Id, FPad.AbsoluteToLocal(LocalToAbsolute(Point)));
end;

procedure TScreenGamepad.PointerUp(Id: NativeInt);
begin
  if FPad <> nil then
    FPad.PointerUp(Id);
end;

procedure TScreenGamepad.ReleaseAll;
begin
  if FPad <> nil then
    FPad.ReleaseAll;
end;

function TScreenGamepad.ButtonBounds(Button: TEmulatorButton): TRectF;
begin
  Result := TRectF.Empty;
  if FPad = nil then
    Exit;
  Result := FPad.ButtonBounds(Button);
  if Result.IsEmpty then
    Exit;
  Result := TRectF.Create(AbsoluteToLocal(FPad.LocalToAbsolute(Result.TopLeft)),
    AbsoluteToLocal(FPad.LocalToAbsolute(Result.BottomRight)));
end;

function TScreenGamepad.PointInObjectLocal(X, Y: Single): Boolean;
begin
  Result := (FPad <> nil) and FPad.PointInObjectLocal(X, Y);
end;

function TScreenGamepad.GetAspectRatio: Single;
begin
  Result := 2 / 3;
  if FPad <> nil then
    Result := FPad.AspectRatio;
end;

end.

