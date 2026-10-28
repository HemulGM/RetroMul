unit RM.Platforms.NES.Controls.PowerPad;

interface

uses
  System.Classes, System.Types, NES.Controller, RM.Gamepad.Base,
  RM.VirtualController;

type
  TGamepadNESPowerPad = class(TVirtualGamepadControl)
  private
    FPads: array[TPowerPadButton] of TVirtualElement;
    FButtons, FCoreButtons: TPowerPadButtons;
    FOnChange: TNotifyEvent;
    procedure SetCoreButtons(const Value: TPowerPadButtons);
    function GetHighlightedButtons: TPowerPadButtons;
  protected
    procedure InputChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ReleaseAll; override;
    function ButtonBounds(Button: TPowerPadButton): TRectF;
    property Buttons: TPowerPadButtons read FButtons;
    property CoreButtons: TPowerPadButtons read FCoreButtons write SetCoreButtons;
    property HighlightedButtons: TPowerPadButtons read GetHighlightedButtons;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

uses
  System.SysUtils;

constructor TGamepadNESPowerPad.Create(AOwner: TComponent);
begin
  inherited;

  // Preserve the original 4-column numbering: columns 1/2 left, 3/4 right.
  for var Button := Low(TPowerPadButton) to High(TPowerPadButton) do
  begin
    var Column := (Button - 1) mod 4;
    var Row := (Button - 1) div 4;
    var Side := TVirtualSide.Left;
    if Column >= 2 then
      Side := TVirtualSide.Right;
    var X := 24 + (Column mod 2) * 104;
    var Y := 48 + Row * 88;
    FPads[Button] := TVirtualButton.Create('pad' + IntToStr(Button), IntToStr(Button), Side, RectF(X, Y, X + 80, Y + 80));
    FPads[Button].CaptureGroup := 'pads';
    FPads[Button].RetainOnSlide := False;
    Add(FPads[Button]);
  end;
end;

destructor TGamepadNESPowerPad.Destroy;
begin
  FOnChange := nil;
  inherited;
end;

procedure TGamepadNESPowerPad.InputChanged;
begin
  inherited;
  var NewButtons: TPowerPadButtons := [];
  for var Button := Low(TPowerPadButton) to High(TPowerPadButton) do
    if (FPads[Button] <> nil) and (FPads[Button].Value > 0) then
      Include(NewButtons, Button);

  if NewButtons = FButtons then
    Exit;

  FButtons := NewButtons;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TGamepadNESPowerPad.ButtonBounds(Button: TPowerPadButton): TRectF;
begin
  Result := ElementBounds(FPads[Button]);
end;

procedure TGamepadNESPowerPad.SetCoreButtons(const Value: TPowerPadButtons);
begin
  FCoreButtons := Value;
  for var Button := Low(TPowerPadButton) to High(TPowerPadButton) do
    FPads[Button].Feedback[0] := Ord(Button in Value);
end;

function TGamepadNESPowerPad.GetHighlightedButtons: TPowerPadButtons;
begin
  Result := FButtons + FCoreButtons;
end;

procedure TGamepadNESPowerPad.ReleaseAll;
begin
  FCoreButtons := [];
  inherited;
end;

end.

