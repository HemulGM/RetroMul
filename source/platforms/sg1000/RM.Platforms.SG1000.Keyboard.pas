unit RM.Platforms.SG1000.Keyboard;

interface

uses
  RM.Keyboard;

type
  TSGKeyboard = class(TScreenKeyboard)
  protected
    function RowCount: Integer; override;
    procedure BuildLayout; override;
  end;

implementation

uses
  System.SysUtils, System.UITypes;

function TSGKeyboard.RowCount: Integer;
begin
  Result := 5;
end;

procedure TSGKeyboard.BuildLayout;
const
  Letters: array[0..2] of string = ('QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM');
begin
  for var i := 1 to 9 do
    AddKey($30 + i, IntToStr(i), 0, i - 1, 1);
  AddKey($30, '0', 0, 9, 1);
  AddKey(vkMinus, '- =', 0, 10, 1);
  AddKey(vkEqual, '^ ~', 0, 11, 1);
  AddKey(vkBackslash, '¥ |', 0, 12, 1);
  AddKey(vkInsert, 'Clr', 0, 13, 1.5);
  AddKey(vkDelete, 'Del', 0, 14.5, 1.5);
  for var Row := 0 to 2 do
    for var i := 1 to Length(Letters[Row]) do
      AddKey(Ord(Letters[Row][i]), Letters[Row][i], Row + 1, i - 1, 1);
  AddKey($C0, '@', 1, 10, 1);
  AddKey($DB, '[', 1, 11, 1);
  AddKey($DD, ']', 1, 12, 1);
  AddKey(vkReturn, 'Return', 1, 13, 3);
  AddKey($BA, '; +', 2, 9, 1);
  AddKey($DE, ': *', 2, 10, 1);
  AddKey($E2, 'π', 2, 11, 1);
  AddKey(vkUp, '↑', 2, 13, 1);
  AddKey(vkEscape, 'Break', 2, 14, 2);
  AddKey($BC, ', <', 3, 7, 1);
  AddKey($BE, '. >', 3, 8, 1);
  AddKey($BF, '/ ?', 3, 9, 1);
  AddKey(vkLeft, '←', 3, 12, 1);
  AddKey(vkDown, '↓', 3, 13, 1);
  AddKey(vkRight, '→', 3, 14, 1);
  AddKey(vkShift, 'Shift', 4, 0, 2, True);
  AddKey(vkControl, 'Ctrl', 4, 2, 1.5, True);
  AddKey(vkMenu, 'Graph', 4, 3.5, 1.5, True);
  AddKey(vkSpace, 'Space', 4, 5, 6);
  AddKey(vkTab, 'Func', 4, 11, 2);
  AddKey(vkRMenu, 'Kana', 4, 13, 3, True);
end;

end.
