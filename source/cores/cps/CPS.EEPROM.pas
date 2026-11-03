unit CPS.EEPROM;

interface

uses
  HW.EEPROM93Cxx;

type
  // Preserve the CPS API and 128-byte snapshot payload layout.
  TCPS93C46 = class(TSerialEEPROM93Cxx)
  public
    constructor Create(DataBits: Integer = 8);
  end;

implementation

constructor TCPS93C46.Create(DataBits: Integer);
begin
  inherited Create(128, DataBits);
end;

end.

