unit Core.Platforms.DC.Keyboard;

interface

function DCHostKeyToHID(Code: UInt32): Byte;

function DCHostKeyModifier(Code: UInt32): Byte;

implementation

uses
  System.UITypes;

// USB HID usage code of a host key; modifiers and unknown keys give 0.
function DCHostKeyToHID(Code: UInt32): Byte;
begin
  Result := 0;
  case Code of
    vkA..vkZ:
      Result := 4 + (Code - vkA);
    vk1..vk9:
      Result := 30 + (Code - vk1);
    vk0:
      Result := 39;
    vkReturn:
      Result := 40;
    vkEscape:
      Result := 41;
    vkBack:
      Result := 42;
    vkTab:
      Result := 43;
    vkSpace:
      Result := 44;
    vkMinus:
      Result := 45;
    vkEqual:
      Result := 46;
    vkLeftBracket:
      Result := 47;
    vkRightBracket:
      Result := 48;
    vkBackslash:
      Result := 49;
    vkSemicolon:
      Result := 51;
    vkQuote:
      Result := 52;
    vkTilde:
      Result := 53;
    vkComma:
      Result := 54;
    vkPeriod:
      Result := 55;
    vkSlash:
      Result := 56;
    vkCapital:
      Result := 57;
    vkF1..vkF12:
      Result := 58 + (Code - vkF1);
    vkSnapshot:
      Result := 70;
    vkScroll:
      Result := 71;
    vkPause:
      Result := 72;
    vkInsert:
      Result := 73;
    vkHome:
      Result := 74;
    vkPrior:
      Result := 75;
    vkDelete:
      Result := 76;
    vkEnd:
      Result := 77;
    vkNext:
      Result := 78;
    vkRight:
      Result := 79;
    vkLeft:
      Result := 80;
    vkDown:
      Result := 81;
    vkUp:
      Result := 82;
    vkNumLock:
      Result := 83;
    vkDivide:
      Result := 84;
    vkMultiply:
      Result := 85;
    vkSubtract:
      Result := 86;
    vkAdd:
      Result := 87;
    vkNumpad1..vkNumpad9:
      Result := 89 + (Code - vkNumpad1);
    vkNumpad0:
      Result := 98;
    vkDecimal:
      Result := 99;
    vkOem102:
      Result := 100;
    vkApps:
      Result := 101;
  end;
end;

// Keyboard modifier bit of a host key (left/right Ctrl, Shift, Alt and the
// S1/S2 keys for the system keys), 0 for others.
function DCHostKeyModifier(Code: UInt32): Byte;
begin
  case Code of
    vkControl, vkLControl:
      Result := $01;
    vkShift, vkLShift:
      Result := $02;
    vkMenu, vkLMenu:
      Result := $04;
    vkLWin:
      Result := $08;
    vkRControl:
      Result := $10;
    vkRShift:
      Result := $20;
    vkRMenu:
      Result := $40;
    vkRWin:
      Result := $80;
  else
    Result := 0;
  end;
end;

end.

