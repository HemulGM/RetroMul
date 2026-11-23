unit RM.Platforms.J2ME.Gamepads;

interface

uses
  RM.Gamepad.Base, RM.VirtualController;

type
  TJ2MEKeypadLayout = (NumbersArrows, ArrowsNumbers, Phone, PhoneArrows,
    Numbers, Arrows);

  TGamepadJ2ME = class(TPlatformGamepad)
  protected
    function KeypadLayout: TJ2MEKeypadLayout; virtual;
    procedure BuildLayout; override;
    procedure AddNavigation(Side: TVirtualSide);
    procedure AddKeypad(Side: TVirtualSide; Arrows: Boolean = False);
    procedure AddSoftKeys(Side: TVirtualSide; WithFire: Boolean);
  end;

  TGamepadJ2MEArrowsNumbers = class(TGamepadJ2ME)
  protected
    function KeypadLayout: TJ2MEKeypadLayout; override;
  end;

  TGamepadJ2MEPhone = class(TGamepadJ2ME)
  protected
    function KeypadLayout: TJ2MEKeypadLayout; override;
  end;

  TGamepadJ2MEPhoneArrows = class(TGamepadJ2ME)
  protected
    function KeypadLayout: TJ2MEKeypadLayout; override;
  end;

  TGamepadJ2MENumbers = class(TGamepadJ2ME)
  protected
    function KeypadLayout: TJ2MEKeypadLayout; override;
  end;

  TGamepadJ2MEArrows = class(TGamepadJ2ME)
  protected
    function KeypadLayout: TJ2MEKeypadLayout; override;
  end;

function NormalizeJ2MEKeypadLayout(const Value: string): string;

implementation

uses
  System.SysUtils, System.Types, Core.Emulation;

function NormalizeJ2MEKeypadLayout(const Value: string): string;
begin
  Result := Value.Trim.ToLower;
  if (Result <> 'numbers-arrows') and (Result <> 'arrows-numbers') and
    (Result <> 'phone') and (Result <> 'phone-arrows') and
    (Result <> 'numbers') and (Result <> 'arrows') then
    Result := 'arrows-numbers';
end;

function TGamepadJ2ME.KeypadLayout: TJ2MEKeypadLayout;
begin
  Result := TJ2MEKeypadLayout.NumbersArrows;
end;

function TGamepadJ2MEArrowsNumbers.KeypadLayout: TJ2MEKeypadLayout;
begin
  Result := TJ2MEKeypadLayout.ArrowsNumbers;
end;

function TGamepadJ2MEPhone.KeypadLayout: TJ2MEKeypadLayout;
begin
  Result := TJ2MEKeypadLayout.Phone;
end;

function TGamepadJ2MEPhoneArrows.KeypadLayout: TJ2MEKeypadLayout;
begin
  Result := TJ2MEKeypadLayout.PhoneArrows;
end;

function TGamepadJ2MENumbers.KeypadLayout: TJ2MEKeypadLayout;
begin
  Result := TJ2MEKeypadLayout.Numbers;
end;

function TGamepadJ2MEArrows.KeypadLayout: TJ2MEKeypadLayout;
begin
  Result := TJ2MEKeypadLayout.Arrows;
end;

procedure TGamepadJ2ME.AddSoftKeys(Side: TVirtualSide; WithFire: Boolean);
begin
  AddButton(TEmulatorButton.Select, 'L', Side, 12, 4, 68, 48, True);
  if WithFire then
    AddButton(TEmulatorButton.A, 'OK', Side, 86, 4, 68, 48, True);
  AddButton(TEmulatorButton.Start, 'R', Side, 160, 4, 68, 48, True);
end;

procedure TGamepadJ2ME.AddNavigation(Side: TVirtualSide);
begin
  AddPad;
  var Pad := Find('dpad');
  Pad.Side := Side;
  Pad.Bounds := RectF(12, 64, 228, 268);
  AddButton(TEmulatorButton.A, 'OK', Side, 90, 136, 60, 60, True);
end;

procedure TGamepadJ2ME.AddKeypad(Side: TVirtualSide; Arrows: Boolean);
const
  Keys: array[0..11] of Integer = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 11);
  Captions: array[0..11] of string = ('1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#');
begin
  for var I := Low(Keys) to High(Keys) do
  begin
    var X := 12 + (I mod 3) * 74;
    var Y := 58 + (I div 3) * 54;
    var B := TEmulatorButton.A;
    var Icon := '';
    var Direction := Arrows and (Keys[I] in [2, 4, 5, 6, 8]);
    if Direction then
    begin
      case Keys[I] of
        2:
          begin
            B := TEmulatorButton.Up;
            Icon := VirtualIconUp;
          end;
        4:
          begin
            B := TEmulatorButton.Left;
            Icon := VirtualIconLeft;
          end;
        6:
          begin
            B := TEmulatorButton.Right;
            Icon := VirtualIconRight;
          end;
        8:
          begin
            B := TEmulatorButton.Down;
            Icon := VirtualIconDown;
          end;
      end;
      AddButton(B, 'OK', Side, X, Y, 68, 48, True, Icon);
    end
    else
    begin
      AddAuxiliaryButton(Keys[I], Captions[I], Side, RectF(X, Y, X + 68, Y + 48));
      var Key := Find('auxiliary' + IntToStr(Keys[I]));
      Key.CaptureGroup := 'phone-keys';
      // Sliding across numbers releases the old key before pressing the next.
      Key.RetainOnSlide := False;
    end;
  end;
end;

procedure TGamepadJ2ME.BuildLayout;
begin
  case KeypadLayout of
    TJ2MEKeypadLayout.NumbersArrows:
      begin
        AddKeypad(TVirtualSide.Left);
        AddSoftKeys(TVirtualSide.Right, False);
        AddNavigation(TVirtualSide.Right);
      end;
    TJ2MEKeypadLayout.ArrowsNumbers:
      begin
        AddKeypad(TVirtualSide.Right);
        AddSoftKeys(TVirtualSide.Left, False);
        AddNavigation(TVirtualSide.Left);
      end;
    TJ2MEKeypadLayout.Phone:
      begin
        AddSoftKeys(TVirtualSide.Center, True);
        AddKeypad(TVirtualSide.Center);
      end;
    TJ2MEKeypadLayout.PhoneArrows:
      begin
        AddSoftKeys(TVirtualSide.Center, False);
        AddKeypad(TVirtualSide.Center, True);
      end;
    TJ2MEKeypadLayout.Numbers:
      begin
        AddSoftKeys(TVirtualSide.Center, False);
        AddKeypad(TVirtualSide.Center);
      end;
    TJ2MEKeypadLayout.Arrows:
      begin
        AddSoftKeys(TVirtualSide.Center, False);
        AddNavigation(TVirtualSide.Center);
      end;
  end;
  DesignSideSize := TSizeF.Create(240, 280);
  for var I := 0 to Count - 1 do
    if not (Elements[I] is TVirtualDPad) then
    begin
      Elements[I].CaptureGroup := 'phone-keys';
      Elements[I].RetainOnSlide := False;
    end;
end;

end.

