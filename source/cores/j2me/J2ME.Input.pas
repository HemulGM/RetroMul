unit J2ME.Input;

interface

const
  // Bits 0..9 are digits; bits 10/11 are star/hash. Independent of host keys.
  J2MEKeypadMask = $0FFF;
  J2MEKeypadCodes: array[0..11] of Integer = (48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 42, 35);

{$SCOPEDENUMS ON}

type
  TJ2MEKeyLayout = (Standard, Motorola, Siemens, StandardWithRawSoftkeys);

  IJ2MEPhoneInput = interface
    ['{6FA3640B-4D39-4240-A054-D0680BDE5C1A}']
    procedure SetVirtualKeypad(Keys: Word);
  end;

// Frontend/UI keys remain canonical; device codes cross only the Canvas API.
function J2MEDeviceKeyCode(Layout: TJ2MEKeyLayout; Code: Integer): Integer;

function J2MECanonicalKeyCode(Layout: TJ2MEKeyLayout; Code: Integer): Integer;

implementation

function J2MEDeviceKeyCode(Layout: TJ2MEKeyLayout; Code: Integer): Integer;
begin
  Result := Code;
  if Layout = TJ2MEKeyLayout.Siemens then
  begin
    case Code of
      -1:
        Result := -59;
      -2:
        Result := -60;
      -3:
        Result := -61;
      -4:
        Result := -62;
      -5:
        Result := 53;
      -6:
        Result := -1;
      -7:
        Result := -4;
    end;
    Exit;
  end;
  if Layout <> TJ2MEKeyLayout.Motorola then
    Exit;
  case Code of
    -1:
      Result := 1;
    -2:
      Result := 6;
    -3:
      Result := 2;
    -4:
      Result := 5;
    -5:
      Result := 20;
    -6:
      Result := 21;
    -7:
      Result := 22;
  end;
end;

function J2MECanonicalKeyCode(Layout: TJ2MEKeyLayout; Code: Integer): Integer;
begin
  Result := Code;
  if Layout = TJ2MEKeyLayout.Siemens then
  begin
    case Code of
      -59:
        Result := -1;
      -60:
        Result := -2;
      -61:
        Result := -3;
      -62:
        Result := -4;
      -1:
        Result := -6;
      -4:
        Result := -7;
    end;
    Exit;
  end;
  if Layout <> TJ2MEKeyLayout.Motorola then
    Exit;
  case Code of
    1:
      Result := -1;
    6:
      Result := -2;
    2:
      Result := -3;
    5:
      Result := -4;
    20:
      Result := -5;
    21:
      Result := -6;
    22:
      Result := -7;
  end;
end;

end.

