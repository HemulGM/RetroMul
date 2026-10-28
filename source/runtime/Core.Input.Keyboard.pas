unit Core.Input.Keyboard;

interface

type
  // Host key state. Hardware matrix/HID translation belongs to each adapter.
  THostKeyboardKeys = array[0..255] of Boolean;

  IEmulationKeyboard = interface
    ['{EFD61C7F-7A61-4F3A-A792-A0D5D6C237ED}']
    procedure SetScreenKeys(const Keys: THostKeyboardKeys);
    function GetHasKeyboard: Boolean;
    property HasKeyboard: Boolean read GetHasKeyboard;
  end;

implementation

end.
