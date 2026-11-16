unit J2ME.Input;

interface

const
  // Bits 0..9 are digits; bits 10/11 are star/hash. Independent of host keys.
  J2MEKeypadMask = $0FFF;
  J2MEKeypadCodes: array[0..11] of Integer = (48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 42, 35);

type
  IJ2MEPhoneInput = interface
    ['{6FA3640B-4D39-4240-A054-D0680BDE5C1A}']
    procedure SetVirtualKeypad(Keys: Word);
  end;

implementation

end.

