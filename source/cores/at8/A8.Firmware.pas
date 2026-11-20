unit A8.Firmware;

interface

uses
  System.SysUtils;

function AtariOS(Legacy: Boolean): TBytes;

function AtariBasic: TBytes;

implementation

uses
  System.Classes;

{$R 'A8.Firmware.res' 'A8.Firmware.rc'}

function LoadROM(const Name: string; Count: Integer): TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, Name, PChar(10));
  try
    if Stream.Size <> Count then
      raise EReadError.CreateFmt('Invalid Atari firmware size (%s)', [Name]);
    SetLength(Result, Count);
    Stream.ReadBuffer(Result[0], Count);
  finally
    Stream.Free;
  end;
end;

function AtariOS(Legacy: Boolean): TBytes;
begin
  if Legacy then
    Result := LoadROM('A8_OS800', $2800)
  else
    Result := LoadROM('A8_OSXL', $4000);
end;

function AtariBasic: TBytes;
begin
  Result := LoadROM('A8_BASIC', $2000);
end;

end.

