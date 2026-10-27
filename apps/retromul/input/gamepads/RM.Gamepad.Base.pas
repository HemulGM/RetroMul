unit RM.Gamepad.Base;

interface

uses
  System.Classes, System.Types, System.Generics.Collections, FMX.Types,
  FMX.Controls, FMX.Forms, Core.Emulation, Core.Emulation.Types,
  RM.VirtualController;

type
  // Common platform input lifetime; layout classes contain no native input code.
  TVirtualGamepadControl = class(TVirtualController)
  private
    FNativeInput: TObject;
    FTouchForm: TCommonCustomForm;
    FPreviousTouch: TTouchEvent;
    {$IFDEF IOS}
    procedure FormTouch(Sender: TObject; const Touches: TTouches; const Action: TTouchAction);
    {$ENDIF}
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    procedure ButtonActivated; override;
  public
    class var TouchHapticsEnabled: Boolean;
    destructor Destroy; override;
    procedure AttachToForm(Form: TCommonCustomForm);
    class function PreferredHeight(AvailableWidth, AvailableHeight: Single): Single; static;
    function PointInObjectLocal(X, Y: Single): Boolean; override;
    function AspectRatio: Single;
  end;

  TPlatformGamepad = class(TVirtualGamepadControl)
  private
    type
      TBinding = record
        Element: TVirtualElement;
        Part: Integer;
        Button: TEmulatorButton;
      end;
  private
    FBindings: TList<TBinding>;
    FButtons, FCoreButtons, FButtonMask: TEmulatorButtons;
    FOnChange: TNotifyEvent;
    FStick, FRightStick: TVirtualStick;
    FLeftTrigger, FRightTrigger: TVirtualElement;
    FAnalog, FRightAnalog: TEmulatorAnalogPad;
    FAuxiliary: array[0..31] of TVirtualElement;
    FAuxiliaryButtons: Cardinal;
    procedure Bind(Element: TVirtualElement; Part: Integer; Button: TEmulatorButton);
    procedure SetButtonMask(const Value: TEmulatorButtons);
    procedure SetCoreButtons(const Value: TEmulatorButtons);
    function GetHighlightedButtons: TEmulatorButtons;
  protected
    procedure BuildLayout; virtual; abstract;
    procedure InputChanged; override;
    procedure AddPad;
    procedure AddStick; overload;
    procedure AddStick(const Bounds: TRectF); overload;
    // A second stick on the right side (X/Y in RightAnalogInput).
    procedure AddRightStick(const Bounds: TRectF);
    procedure AddAnalogTriggers;
    function AddButton(Button: TEmulatorButton; const Caption: string; Side: TVirtualSide; X, Y, Width, Height: Single; Rectangular: Boolean = False; const IconData: string = ''): TVirtualElement;
    procedure AddAuxiliaryButton(Index: Integer; const Caption: string; Side: TVirtualSide; const Bounds: TRectF; const IconData: string = '');
    procedure AddMenus(const SelectCaption: string = 'SELECT'; const StartCaption: string = 'START');
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ReleaseAll; override;
    function ButtonBounds(Button: TEmulatorButton): TRectF;
    function AuxiliaryButtonBounds(Index: Integer): TRectF;
    property AuxiliaryButtons: Cardinal read FAuxiliaryButtons;
    property AnalogInput: TEmulatorAnalogPad read FAnalog;
    property RightAnalogInput: TEmulatorAnalogPad read FRightAnalog;
    property Buttons: TEmulatorButtons read FButtons;
    property ButtonMask: TEmulatorButtons read FButtonMask write SetButtonMask;
    property CoreButtons: TEmulatorButtons read FCoreButtons write SetCoreButtons;
    property HighlightedButtons: TEmulatorButtons read GetHighlightedButtons;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  TPlatformGamepadClass = class of TPlatformGamepad;

implementation

uses
  System.SysUtils, System.Math, FMX.Vibrate
  {$IFDEF ANDROID}, RM.TouchInput.Android{$ENDIF};

procedure TVirtualGamepadControl.ButtonActivated;
begin
  inherited;
  if TouchHapticsEnabled then
    TouchImpact;
end;

destructor TVirtualGamepadControl.Destroy;
begin
  AttachToForm(nil);
  inherited;
end;

procedure TVirtualGamepadControl.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FTouchForm) then
  begin
    FTouchForm := nil;
    FPreviousTouch := nil;
    FreeAndNil(FNativeInput);
    ReleaseAll;
  end;
end;

procedure TVirtualGamepadControl.AttachToForm(Form: TCommonCustomForm);
begin
  if FTouchForm = Form then
    Exit;
  ReleaseAll;
  if FTouchForm <> nil then
  begin
    {$IFDEF IOS}
    var CurrentTouch: TTouchEvent := FTouchForm.OnTouch;
    var OwnTouch: TTouchEvent := FormTouch;
    if (TMethod(CurrentTouch).Code = TMethod(OwnTouch).Code) and (TMethod(CurrentTouch).Data = TMethod(OwnTouch).Data) then
      FTouchForm.OnTouch := FPreviousTouch;
    {$ENDIF}

    FTouchForm.RemoveFreeNotification(Self);
  end;
  FreeAndNil(FNativeInput);
  FPreviousTouch := nil;
  FTouchForm := Form;
  if Form = nil then
    Exit;
  Form.FreeNotification(Self);

  {$IFDEF ANDROID}
  FNativeInput := TAndroidTouchInput.Create(Self, Form, PointerDown, PointerMove, PointerUp, ReleaseAll, True);
  {$ENDIF}
  {$IFDEF IOS}
  FPreviousTouch := Form.OnTouch;
  Form.OnTouch := FormTouch;
  {$ENDIF}
end;

{$IFDEF IOS}
procedure TVirtualGamepadControl.FormTouch(Sender: TObject; const Touches: TTouches; const Action: TTouchAction);
begin
  if Assigned(FPreviousTouch) then
    FPreviousTouch(Sender, Touches, Action);
  if Action = TTouchAction.Cancel then
  begin
    ReleaseAll;
    Exit;
  end;
  for var Touch in Touches do
    case Touch.Action of
      TTouchAction.Down:
        PointerDown(Touch.Id, AbsoluteToLocal(Touch.Location));
      TTouchAction.Move:
        PointerMove(Touch.Id, AbsoluteToLocal(Touch.Location));
      TTouchAction.Up:
        PointerUp(Touch.Id);
      TTouchAction.Cancel:
        ReleaseAll;
    end;
end;

{$ENDIF}

class function TVirtualGamepadControl.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Max(0, Min(320.0, Min(AvailableWidth * 2 / 3, AvailableHeight * 0.44)));
end;

function TVirtualGamepadControl.AspectRatio: Single;
begin
  Result := DesignSideSize.Height / (DesignSideSize.Width * 2);
end;

function TVirtualGamepadControl.PointInObjectLocal(X, Y: Single): Boolean;
var
  P: TPointF;
  S: Single;
begin
  Result := False;
  if not inherited PointInObjectLocal(X, Y) then
    Exit;

  S := EffectiveScale;
  for var i := Count - 1 downto 0 do
  begin
    var E := Elements[i];
    if not E.HasEnabledParts then
      Continue;

    var Side := SideBounds(E.Side);
    P := PointF((X - Side.Left) / S, (Y - Side.Top) / S);

    // Bounds include the pad's neutral centre, so a gesture can start there.
    if (E is TVirtualDPad) and E.Bounds.Contains(P) then
      Exit(True);

    for var Part := 0 to E.PartCount - 1 do
      if E.PartEnabled[Part] and PartBounds(E, Part).Contains(PointF(X, Y)) then
        Exit(True);
  end;
end;

constructor TPlatformGamepad.Create(AOwner: TComponent);
begin
  inherited;
  FBindings := TList<TBinding>.Create;
  FButtonMask := [Low(TEmulatorButton)..High(TEmulatorButton)];
  BuildLayout;
end;

destructor TPlatformGamepad.Destroy;
begin
  FOnChange := nil;
  AttachToForm(nil);
  FreeAndNil(FBindings);
  inherited;
end;

procedure TPlatformGamepad.Bind(Element: TVirtualElement; Part: Integer; Button: TEmulatorButton);
var
  B: TBinding;
begin
  B.Element := Element;
  B.Part := Part;
  B.Button := Button;
  FBindings.Add(B);
end;

procedure TPlatformGamepad.AddPad;
begin
  var E := Add(TVirtualDPad.Create('dpad', 'PAD', TVirtualSide.Left, RectF(28, 140, 172, 284)));
  Bind(E, TVirtualDPad.Up, TEmulatorButton.Up);
  Bind(E, TVirtualDPad.Down, TEmulatorButton.Down);
  Bind(E, TVirtualDPad.Left, TEmulatorButton.Left);
  Bind(E, TVirtualDPad.Right, TEmulatorButton.Right);
end;

procedure TPlatformGamepad.AddStick;
begin
  AddStick(RectF(24, 20, 128, 124));
end;

procedure TPlatformGamepad.AddStick(const Bounds: TRectF);
begin
  FStick := TVirtualStick.Create('stick', 'STICK', TVirtualSide.Left, Bounds);
  Add(FStick);
end;

procedure TPlatformGamepad.AddRightStick(const Bounds: TRectF);
begin
  FRightStick := TVirtualStick.Create('rightstick', 'STICK', TVirtualSide.Right, Bounds);
  Add(FRightStick);
end;

procedure TPlatformGamepad.AddAnalogTriggers;
begin
  FLeftTrigger := Add(TVirtualTrigger.Create('lt', 'L', TVirtualSide.Left, RectF(172, 8, 228, 108)));
  FRightTrigger := Add(TVirtualTrigger.Create('rt', 'R', TVirtualSide.Right, RectF(172, 8, 228, 108)));
  Bind(FLeftTrigger, 0, TEmulatorButton.Select);
  Bind(FRightTrigger, 0, TEmulatorButton.Mode);
end;

function TPlatformGamepad.AddButton(Button: TEmulatorButton; const Caption: string; Side: TVirtualSide; X, Y, Width, Height: Single; Rectangular: Boolean; const IconData: string): TVirtualElement;
begin
  if Rectangular then
    Result := TVirtualKey.Create('button' + IntToStr(Ord(Button)), Caption, Side, RectF(X, Y, X + Width, Y + Height))
  else
    Result := TVirtualButton.Create('button' + IntToStr(Ord(Button)), Caption, Side, RectF(X, Y, X + Width, Y + Height));
  if (Button in [TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C,
      TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]) then
    Result.CaptureGroup := 'actions';
  Add(Result);
  Result.IconData := IconData;
  Bind(Result, 0, Button);
end;

procedure TPlatformGamepad.AddMenus(const SelectCaption, StartCaption: string);
begin
  if SelectCaption <> '' then
    AddButton(TEmulatorButton.Select, SelectCaption, TVirtualSide.Left, 16, 74, 88, 36, True);
  if StartCaption <> '' then
  begin
    var Button := AddButton(TEmulatorButton.Start, StartCaption, TVirtualSide.Right, 136, 74, 88, 36, True);
    if SameText(StartCaption, 'PAUSE') then
      Button.IconData := VirtualIconPause;
  end;
end;

procedure TPlatformGamepad.AddAuxiliaryButton(Index: Integer; const Caption: string; Side: TVirtualSide; const Bounds: TRectF; const IconData: string);
begin
  if (Index < Low(FAuxiliary)) or (Index > High(FAuxiliary)) or (FAuxiliary[Index] <> nil) then
    raise EArgumentOutOfRangeException.Create('Auxiliary button');
  FAuxiliary[Index] := Add(TVirtualKey.Create('auxiliary' + IntToStr(Index), Caption, Side, Bounds));
  FAuxiliary[Index].IconData := IconData;
end;

function TPlatformGamepad.AuxiliaryButtonBounds(Index: Integer): TRectF;
begin
  Result := TRectF.Empty;
  if (Index >= Low(FAuxiliary)) and (Index <= High(FAuxiliary)) and
    (FAuxiliary[Index] <> nil) and FAuxiliary[Index].PartEnabled[0] then
    Result := PartBounds(FAuxiliary[Index], 0);
end;

procedure TPlatformGamepad.InputChanged;
begin
  inherited;
  if FBindings = nil then
    Exit;

  var NewButtons: TEmulatorButtons := [];
  for var B in FBindings do
    if (B.Button in FButtonMask) and (B.Element.Value(B.Part) > 0) then
      if not (B.Element is TVirtualTrigger) or (B.Element.Value(B.Part) >= 0.49999) then
        Include(NewButtons, B.Button);

  if [TEmulatorButton.Left, TEmulatorButton.Right] <= NewButtons then
    NewButtons := NewButtons - [TEmulatorButton.Left, TEmulatorButton.Right];
  if [TEmulatorButton.Up, TEmulatorButton.Down] <= NewButtons then
    NewButtons := NewButtons - [TEmulatorButton.Up, TEmulatorButton.Down];
  var NewAnalog := Default(TEmulatorAnalogPad);
  if FButtonMask <> [] then
  begin
    if FStick <> nil then
    begin
      NewAnalog.X := Round(FStick.AxisX * 32767);
      NewAnalog.Y := Round(FStick.AxisY * 32767);
    end;
    if FLeftTrigger <> nil then
      NewAnalog.LeftTrigger := Round(FLeftTrigger.Value * 255);
    if FRightTrigger <> nil then
      NewAnalog.RightTrigger := Round(FRightTrigger.Value * 255);
    NewAnalog.Valid := (NewAnalog.X <> 0) or (NewAnalog.Y <> 0) or
      (NewAnalog.LeftTrigger <> 0) or (NewAnalog.RightTrigger <> 0);
  end;
  var NewRight := Default(TEmulatorAnalogPad);
  if (FButtonMask <> []) and (FRightStick <> nil) then
  begin
    NewRight.X := Round(FRightStick.AxisX * 32767);
    NewRight.Y := Round(FRightStick.AxisY * 32767);
    NewRight.Valid := (NewRight.X <> 0) or (NewRight.Y <> 0);
  end;
  var NewAuxiliary: Cardinal := 0;
  for var I := Low(FAuxiliary) to High(FAuxiliary) do
    if (FAuxiliary[I] <> nil) and (FAuxiliary[I].Value > 0) then
      NewAuxiliary := NewAuxiliary or (Cardinal(1) shl I);
  if (NewButtons = FButtons) and (NewAuxiliary = FAuxiliaryButtons) and (NewAnalog.X = FAnalog.X) and (NewAnalog.Y = FAnalog.Y) and
    (NewAnalog.LeftTrigger = FAnalog.LeftTrigger) and (NewAnalog.RightTrigger = FAnalog.RightTrigger) and
    (NewAnalog.Valid = FAnalog.Valid) and (NewRight.X = FRightAnalog.X) and (NewRight.Y = FRightAnalog.Y) then
    Exit;

  FAnalog := NewAnalog;
  FRightAnalog := NewRight;
  FAuxiliaryButtons := NewAuxiliary;
  FButtons := NewButtons;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TPlatformGamepad.SetButtonMask(const Value: TEmulatorButtons);
begin
  if FButtonMask = Value then
    Exit;

  ReleaseAll;
  FButtonMask := Value;
  for var B in FBindings do
    B.Element.PartEnabled[B.Part] := B.Button in Value;
  for var E in FAuxiliary do
    if E <> nil then E.PartEnabled[0] := Value <> [];
  for var Stick in [FStick, FRightStick] do
    if Stick <> nil then
      for var Part := 0 to Stick.PartCount - 1 do
        Stick.PartEnabled[Part] := Value <> [];
end;

function TPlatformGamepad.ButtonBounds(Button: TEmulatorButton): TRectF;
begin
  Result := TRectF.Empty;
  if not (Button in FButtonMask) then
    Exit;

  for var B in FBindings do
    if B.Button = Button then
      Exit(PartBounds(B.Element, B.Part));
end;

procedure TPlatformGamepad.SetCoreButtons(const Value: TEmulatorButtons);
begin
  FCoreButtons := Value * FButtonMask;
  for var B in FBindings do
    B.Element.Feedback[B.Part] := Ord(B.Button in FCoreButtons);
end;

function TPlatformGamepad.GetHighlightedButtons: TEmulatorButtons;
begin
  Result := [];
  for var B in FBindings do
    if (B.Button in FButtonMask) and ((B.Button in FButtons) or (B.Button in FCoreButtons)) then
      Include(Result, B.Button);
end;

procedure TPlatformGamepad.ReleaseAll;
begin
  FCoreButtons := [];
  inherited;
end;

initialization
  TVirtualGamepadControl.TouchHapticsEnabled := True;

end.
