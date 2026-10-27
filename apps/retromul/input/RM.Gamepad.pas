unit RM.Gamepad;

interface

uses
  System.Classes, System.Types, FMX.Types, FMX.Controls, FMX.Forms,
  NES.Controller, Core.Emulation, Core.Emulation.Types, Core.Platforms, RM.Platforms.Presentation,
  RM.Gamepad.Base;

type
  TScreenGamepadLayout = TPlatformPadLayout;

  // Stable host API. The platform-specific child is the actual virtual control.
  TScreenGamepad = class(TControl)
  private
    FPad: TPlatformGamepad;
    FLayout: TScreenGamepadLayout;
    FLayoutScale: Single;
    FSystem: TRomSystem;
    FDevice: string;
    FExplicitPlatform: Boolean;
    FButtonMask: TEmulatorButtons;
    FForm: TCommonCustomForm;
    FOnChange: TNotifyEvent;
    procedure SetLayoutScale(Value: Single);
    procedure UpdateLayoutScale;
    procedure PadChanged(Sender: TObject);
    procedure ReplacePad(System: TRomSystem; const Device: string);
    procedure SetLayout(Value: TScreenGamepadLayout);
    procedure SetButtonMask(const Value: TEmulatorButtons);
    procedure SetCoreButtons(const Value: TEmulatorButtons);
    function GetAnalogInput: TEmulatorAnalogPad;
    function GetRightAnalogInput: TEmulatorAnalogPad;
    function GetAuxiliaryButtons: Cardinal;
    function GetButtons: TEmulatorButtons;
    function GetCoreButtons: TEmulatorButtons;
    function GetHighlightedButtons: TEmulatorButtons;
    function GetAspectRatio: Single;
    procedure ConfigureLegacy;
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
    procedure Configure(System: TRomSystem; const Device: string; const Buttons: TEmulatorButtons);
    procedure AttachToForm(Form: TCommonCustomForm);
    procedure PointerDown(Id: NativeInt; const Point: TPointF);
    procedure PointerMove(Id: NativeInt; const Point: TPointF);
    procedure PointerUp(Id: NativeInt);
    procedure ReleaseAll;
    function ButtonBounds(Button: TEmulatorButton): TRectF;
    function AuxiliaryButtonBounds(Index: Integer): TRectF;
    property AuxiliaryButtons: Cardinal read GetAuxiliaryButtons;
    function PointInObjectLocal(X, Y: Single): Boolean; override;
    property System: TRomSystem read FSystem;
    property DeviceId: string read FDevice;
    property PlatformPad: TPlatformGamepad read FPad;
    property LayoutScale: Single read FLayoutScale write SetLayoutScale;
    property AnalogInput: TEmulatorAnalogPad read GetAnalogInput;
    property RightAnalogInput: TEmulatorAnalogPad read GetRightAnalogInput;
    property Buttons: TEmulatorButtons read GetButtons;
    property CoreButtons: TEmulatorButtons read GetCoreButtons write SetCoreButtons;
    property HighlightedButtons: TEmulatorButtons read GetHighlightedButtons;
    // Compatibility for existing clients; application code uses Configure.
    property Layout: TScreenGamepadLayout read FLayout write SetLayout;
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

  TNesGamepad = class(TScreenGamepad)
  private
    function GetNesButtons: TNesButtons;
  public
    function ButtonBounds(Button: TNesButton): TRectF; reintroduce;
    property Buttons: TNesButtons read GetNesButtons;
  end;

implementation

uses System.SysUtils, System.Math, RM.Gamepad.Factory;

const
  NesButtonMap: array[TNesButton] of TEmulatorButton =
    (TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select,
     TEmulatorButton.Start, TEmulatorButton.Up, TEmulatorButton.Down,
     TEmulatorButton.Left, TEmulatorButton.Right);

constructor TScreenGamepad.Create(AOwner: TComponent);
begin
  inherited;
  FLayoutScale := 1;
  FButtonMask := [Low(TEmulatorButton)..High(TEmulatorButton)];
  SetBounds(0, 0, 480, 320);
  ConfigureLegacy;
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
  if not Enabled then ReleaseAll;
end;

procedure TScreenGamepad.VisibleChanged;
begin
  inherited;
  if not Visible then ReleaseAll;
end;

procedure TScreenGamepad.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then ReleaseAll;
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
  if (Operation = opRemove) and (AComponent = FForm) then FForm := nil;
end;

procedure TScreenGamepad.PadChanged(Sender: TObject);
begin
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TScreenGamepad.ReplacePad(System: TRomSystem; const Device: string);
begin
  var NewClass := GamepadClass(System, Device);
  if (FPad <> nil) and (FPad.ClassType = NewClass) then
  begin
    FSystem := System;
    FDevice := Device;
    FPad.ButtonMask := FButtonMask;
    Exit;
  end;
  // Construct before releasing the old layout, so exceptions leave a valid pad.
  var NewPad := CreatePlatformGamepad(Self, System, Device);
  try
    NewPad.ButtonMask := FButtonMask;
    if FPad <> nil then
    begin
      FPad.ReleaseAll;
      FPad.OnChange := nil;
      FPad.AttachToForm(nil);
    end;
    FreeAndNil(FPad);
    FPad := NewPad;
    NewPad := nil;
    FSystem := System;
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

procedure TScreenGamepad.Configure(System: TRomSystem; const Device: string; const Buttons: TEmulatorButtons);
begin
  FExplicitPlatform := True;
  FLayout := PlatformPresentation(System).PadLayout;
  if (System = TRomSystem.NES) and (Device = 'paddendy') then FLayout := TScreenGamepadLayout.Dendy;
  FButtonMask := Buttons;
  ReplacePad(System, Device);
end;

procedure TScreenGamepad.ConfigureLegacy;
var System: TRomSystem; Device: string;
begin
  System := TRomSystem.NES; Device := 'pad';
  case FLayout of
    TScreenGamepadLayout.CPS: System := TRomSystem.CPS1;
    TScreenGamepadLayout.Dendy: Device := 'paddendy';
    TScreenGamepadLayout.Sega:
      begin
        System := TRomSystem.MD;
        Device := 'pad3';
        if FButtonMask * [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z] <> [] then Device := 'pad6';
      end;
    TScreenGamepadLayout.Snes: System := TRomSystem.SNES;
    TScreenGamepadLayout.GameBoy: System := TRomSystem.GB;
    TScreenGamepadLayout.GameBoyColor: System := TRomSystem.GBC;
    TScreenGamepadLayout.GameBoyAdvance: System := TRomSystem.GBA;
    TScreenGamepadLayout.Nintendo64: System := TRomSystem.N64;
    TScreenGamepadLayout.PlayStation: System := TRomSystem.PS1;
    TScreenGamepadLayout.PSP: System := TRomSystem.PSP;
    TScreenGamepadLayout.Dreamcast: System := TRomSystem.DC;
    TScreenGamepadLayout.NeoGeo: System := TRomSystem.NeoGeo;
    TScreenGamepadLayout.PCE:
      begin
        System := TRomSystem.PCE;
        if FButtonMask * [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.C, TEmulatorButton.Z] <> [] then Device := 'pad6';
      end;
  end;
  ReplacePad(System, Device);
end;

procedure TScreenGamepad.SetLayout(Value: TScreenGamepadLayout);
begin
  if (FLayout = Value) and not FExplicitPlatform then Exit;
  FLayout := Value;
  FExplicitPlatform := False;
  ConfigureLegacy;
end;

procedure TScreenGamepad.SetButtonMask(const Value: TEmulatorButtons);
begin
  if FButtonMask = Value then Exit;
  FButtonMask := Value;
  if FExplicitPlatform then FPad.ButtonMask := Value else ConfigureLegacy;
end;

class function TScreenGamepad.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := TVirtualGamepadControl.PreferredHeight(AvailableWidth, AvailableHeight);
end;

procedure TScreenGamepad.AttachToForm(Form: TCommonCustomForm);
begin
  if FForm <> nil then FForm.RemoveFreeNotification(Self);
  FForm := Form;
  if FForm <> nil then FForm.FreeNotification(Self);
  if FPad <> nil then FPad.AttachToForm(Form);
end;

function TScreenGamepad.GetAnalogInput: TEmulatorAnalogPad;
begin
  Result := Default(TEmulatorAnalogPad);
  if FPad <> nil then Result := FPad.AnalogInput;
end;

function TScreenGamepad.GetRightAnalogInput: TEmulatorAnalogPad;
begin
  Result := Default(TEmulatorAnalogPad);
  if FPad <> nil then Result := FPad.RightAnalogInput;
end;

function TScreenGamepad.GetAuxiliaryButtons: Cardinal;
begin
  Result := 0;
  if FPad <> nil then Result := FPad.AuxiliaryButtons;
end;

function TScreenGamepad.AuxiliaryButtonBounds(Index: Integer): TRectF;
begin
  Result := TRectF.Empty;
  if FPad = nil then Exit;
  Result := FPad.AuxiliaryButtonBounds(Index);
  if Result.IsEmpty then Exit;
  Result := TRectF.Create(AbsoluteToLocal(FPad.LocalToAbsolute(Result.TopLeft)),
    AbsoluteToLocal(FPad.LocalToAbsolute(Result.BottomRight)));
end;

function TScreenGamepad.GetButtons: TEmulatorButtons;
begin
  Result := [];
  if FPad <> nil then Result := FPad.Buttons;
end;

function TScreenGamepad.GetCoreButtons: TEmulatorButtons;
begin
  Result := [];
  if FPad <> nil then Result := FPad.CoreButtons;
end;

function TScreenGamepad.GetHighlightedButtons: TEmulatorButtons;
begin
  Result := [];
  if FPad <> nil then Result := FPad.HighlightedButtons;
end;

procedure TScreenGamepad.SetCoreButtons(const Value: TEmulatorButtons);
begin
  if FPad <> nil then FPad.CoreButtons := Value;
end;

procedure TScreenGamepad.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if FPad <> nil then FPad.PointerDown(Id, FPad.AbsoluteToLocal(LocalToAbsolute(Point)));
end;

procedure TScreenGamepad.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if FPad <> nil then FPad.PointerMove(Id, FPad.AbsoluteToLocal(LocalToAbsolute(Point)));
end;

procedure TScreenGamepad.PointerUp(Id: NativeInt);
begin
  if FPad <> nil then FPad.PointerUp(Id);
end;

procedure TScreenGamepad.ReleaseAll;
begin
  if FPad <> nil then FPad.ReleaseAll;
end;

function TScreenGamepad.ButtonBounds(Button: TEmulatorButton): TRectF;
begin
  Result := TRectF.Empty;
  if FPad = nil then Exit;
  Result := FPad.ButtonBounds(Button);
  if Result.IsEmpty then Exit;
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
  if FPad <> nil then Result := FPad.AspectRatio;
end;

function TNesGamepad.GetNesButtons: TNesButtons;
begin
  Result := [];
  for var Button := Low(TNesButton) to High(TNesButton) do
    if NesButtonMap[Button] in inherited Buttons then Include(Result, Button);
end;

function TNesGamepad.ButtonBounds(Button: TNesButton): TRectF;
begin
  Result := inherited ButtonBounds(NesButtonMap[Button]);
end;

end.
