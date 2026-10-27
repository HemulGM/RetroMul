unit DC.ELF;

// Homebrew programs: SH-4 ELF executables and raw binaries loaded into
// system RAM (raw binaries at 8C010000).
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, DC.Types, DC.Memory;

const
  DCProgramAddress = $8C010000;

function IsDCELF(const Data: TBytes): Boolean;
// Copies the loadable segments into RAM and returns the entry point.
function LoadDCELF(const Data: TBytes; Memory: TDCMemory): Cardinal;
function LoadDCBinary(const Data: TBytes; Memory: TDCMemory; Address: Cardinal = DCProgramAddress): Cardinal;

implementation

function U16(const Data: TBytes; Offset: Integer): Cardinal;
begin
  Result := Cardinal(Data[Offset]) or (Cardinal(Data[Offset + 1]) shl 8);
end;

function U32(const Data: TBytes; Offset: Integer): Cardinal;
begin
  Result := U16(Data, Offset) or (U16(Data, Offset + 2) shl 16);
end;

function IsDCELF(const Data: TBytes): Boolean;
begin
  // 32-bit little-endian executable for machine 42 (SuperH).
  Result := (Length(Data) >= 52) and (Data[0] = $7F) and (Data[1] = Ord('E')) and (Data[2] = Ord('L')) and
    (Data[3] = Ord('F')) and (Data[4] = 1) and (Data[5] = 1) and (U16(Data, 16) = 2) and (U16(Data, 18) = 42);
end;

procedure CopyToRAM(Memory: TDCMemory; Address: Cardinal; const Data: TBytes; Offset, Size, MemorySize: Int64);
begin
  var Physical := Address and $1FFFFFFF;
  if (Physical < $0C000000) or (Physical >= $10000000) or (MemorySize > DCRAMSize) or
    (Int64(Physical and (DCRAMSize - 1)) + MemorySize > DCRAMSize) then
    raise EReadError.CreateFmt('Program segment outside system RAM: %.8x', [Address]);
  var Target := Memory.RAM + (Physical and (DCRAMSize - 1));
  FillChar(Target^, MemorySize, 0);
  if Size > 0 then
    Move(Data[Offset], Target^, Size);
  Memory.TouchRAM(Physical, MemorySize);
end;

function LoadDCELF(const Data: TBytes; Memory: TDCMemory): Cardinal;
begin
  if not IsDCELF(Data) then
    raise EReadError.Create('Not an SH-4 ELF executable');
  var PHOffset := Int64(U32(Data, 28));
  var PHSize := Integer(U16(Data, 42));
  var PHCount := Integer(U16(Data, 44));
  if (PHSize < 32) or (PHCount = 0) or (PHOffset + Int64(PHSize) * PHCount > Length(Data)) then
    raise EReadError.Create('Invalid ELF program headers');
  var Loaded := 0;
  for var I := 0 to PHCount - 1 do
  begin
    var H := Integer(PHOffset) + I * PHSize;
    if U32(Data, H) <> 1 then
      Continue;
    var Offset := Int64(U32(Data, H + 4));
    var Address := U32(Data, H + 12); // physical address
    if Address = 0 then
      Address := U32(Data, H + 8);
    var FileSize := Int64(U32(Data, H + 16));
    var MemorySize := Int64(U32(Data, H + 20));
    if (Offset + FileSize > Length(Data)) or (FileSize > MemorySize) then
      raise EReadError.Create('Invalid ELF segment');
    if MemorySize = 0 then
      Continue;
    CopyToRAM(Memory, Address, Data, Offset, FileSize, MemorySize);
    Inc(Loaded);
  end;
  if Loaded = 0 then
    raise EReadError.Create('ELF has no loadable segments');
  Result := U32(Data, 24);
end;

function LoadDCBinary(const Data: TBytes; Memory: TDCMemory; Address: Cardinal): Cardinal;
begin
  if (Length(Data) = 0) or (Length(Data) > DCRAMSize - $10000) then
    raise EReadError.Create('Program must fit in system RAM');
  CopyToRAM(Memory, Address, Data, 0, Length(Data), Length(Data));
  Result := Address;
end;

end.
