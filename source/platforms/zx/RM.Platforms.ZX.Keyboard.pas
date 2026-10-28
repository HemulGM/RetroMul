unit RM.Platforms.ZX.Keyboard;

interface

uses
  RM.Keyboard;

type
  TZXKeyboard = class(TScreenKeyboard)
  protected
    function RowCount: Integer; override;
    procedure BuildLayout; override;
  end;

implementation

uses
  System.SysUtils, System.UITypes;

function TZXKeyboard.RowCount: Integer;
begin
  Result := 4;
end;

procedure TZXKeyboard.BuildLayout;
const
  Letters: array[0..2] of string = ('QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM');
begin
  for var i := 1 to 10 do
    AddKey(Ord('0') + (i mod 10), IntToStr(i mod 10), 0, (i - 1) * 1.6, 1.6);
  for var i := 1 to Length(Letters[0]) do
    AddKey(Ord(Letters[0][i]), Letters[0][i], 1, (i - 1) * 1.6, 1.6);
  for var i := 1 to Length(Letters[1]) do
    AddKey(Ord(Letters[1][i]), Letters[1][i], 2, (i - 1) * 1.5, 1.5);
  AddKey(vkReturn, 'ENTER', 2, 13.5, 2.5);
  AddKey(vkShift, 'CAPS SHIFT', 3, 0, 2, True);
  for var i := 1 to Length(Letters[2]) do
    AddKey(Ord(Letters[2][i]), Letters[2][i], 3, 2 + (i - 1) * 1.4, 1.4);
  AddKey(vkControl, 'SYMBOL SHIFT', 3, 11.8, 2.1, True);
  AddKey(vkSpace, 'SPACE', 3, 13.9, 2.1);
end;

end.
