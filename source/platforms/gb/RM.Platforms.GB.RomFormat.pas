unit RM.Platforms.GB.RomFormat;

interface

procedure RegisterGBXReader;

implementation

uses
  GB.RomFormat;

var
  GBXReaderRegistered: Boolean;

procedure RegisterGBXReader;
begin
  if GBXReaderRegistered then
    Exit;

  RegisterLegacyFooterReader(ReadFooter);
  GBXReaderRegistered := True;
end;

end.
