unit RA.Memory;

interface

uses
  System.SysUtils;

type
  TRAMemoryRead = reference to function(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;

  TRAAddressValidator = reference to function(Address: Cardinal): Boolean;

  TRAGBAMemory = record
  public
    const
      InternalWorkRAMSize = $8000;
      ExternalWorkRAMSize = $40000;
      MaximumSaveRAMSize = $10000;
      ExternalWorkRAMBase = InternalWorkRAMSize;
      SaveRAMBase = InternalWorkRAMSize + ExternalWorkRAMSize;
  private
    FInternalWorkRAM: PByte;
    FExternalWorkRAM: PByte;
    FSaveRAM: PByte;
    FSaveRAMSize: Cardinal;
  public
    // The GBA core owns these buffers and should only read them on its emulation thread.
    constructor Create(InternalWorkRAM, ExternalWorkRAM, SaveRAM: PByte; SaveRAMSize: Cardinal);
    function Read(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
  end;

implementation

uses
  System.Math;

constructor TRAGBAMemory.Create(InternalWorkRAM, ExternalWorkRAM, SaveRAM: PByte; SaveRAMSize: Cardinal);
begin
  FInternalWorkRAM := InternalWorkRAM;
  FExternalWorkRAM := ExternalWorkRAM;
  FSaveRAM := SaveRAM;
  FSaveRAMSize := Min(SaveRAMSize, Cardinal(MaximumSaveRAMSize));
end;

function TRAGBAMemory.Read(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
var
  Region: PByte;
  Offset, RegionSize, ReadCount: Cardinal;
begin
  Result := 0;
  if Buffer = nil then
    Exit;

  while Count > 0 do
  begin
    if Address < ExternalWorkRAMBase then
    begin
      Region := FInternalWorkRAM;
      Offset := Address;
      RegionSize := InternalWorkRAMSize;
    end
    else if Address < SaveRAMBase then
    begin
      Region := FExternalWorkRAM;
      Offset := Address - ExternalWorkRAMBase;
      RegionSize := ExternalWorkRAMSize;
    end
    else
    begin
      Region := FSaveRAM;
      Offset := Address - SaveRAMBase;
      RegionSize := FSaveRAMSize;
    end;

    if (Region = nil) or (Offset >= RegionSize) then
      Exit;
    ReadCount := Min(Count, RegionSize - Offset);
    Move((Region + Offset)^, Buffer^, ReadCount);
    Inc(Address, ReadCount);
    Inc(Buffer, ReadCount);
    Inc(Result, ReadCount);
    Dec(Count, ReadCount);
  end;
end;

end.

