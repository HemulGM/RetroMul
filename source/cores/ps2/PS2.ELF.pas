unit PS2.ELF;

// MIPS ELF32 little-endian images: EE executables (ET_EXEC) and IOP modules
// (IRX, type FF80h, relocatable). Parsing only; loaders copy the segments.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes;

type
  TPS2ELFSegment = record
    Offset, VirtualAddress, PhysicalAddress, FileSize, MemorySize, Flags: Cardinal;
  end;

  TPS2ELFSection = record
    Name: string;
    Kind, Flags, Address, Offset, Size, Link, Info, EntrySize: Cardinal;
  end;

  TPS2ELF = class
  private
    FData: TBytes;
    FKind, FEntry: Cardinal;
    FSegments: TArray<TPS2ELFSegment>;
    FSections: TArray<TPS2ELFSection>;
  public
    constructor Create(const Data: TBytes);
    class function IsELF(const Data: TBytes): Boolean; static;
    function U16(Offset: Integer): Cardinal; inline;
    function U32(Offset: Integer): Cardinal; inline;
    function FindSection(const Name: string): Integer;
    property Data: TBytes read FData;
    property Kind: Cardinal read FKind;
    property Entry: Cardinal read FEntry;
    property Segments: TArray<TPS2ELFSegment> read FSegments;
    property Sections: TArray<TPS2ELFSection> read FSections;
  end;

implementation

class function TPS2ELF.IsELF(const Data: TBytes): Boolean;
begin
  // 32-bit little-endian MIPS (machine 8).
  Result := (Length(Data) >= 52) and (Data[0] = $7F) and (Data[1] = Ord('E')) and (Data[2] = Ord('L')) and
    (Data[3] = Ord('F')) and (Data[4] = 1) and (Data[5] = 1) and (Data[18] = 8) and (Data[19] = 0);
end;

constructor TPS2ELF.Create(const Data: TBytes);
begin
  inherited Create;
  if not IsELF(Data) then
    raise EReadError.Create('Not a MIPS ELF image');
  FData := Data;
  FKind := U16(16);
  FEntry := U32(24);
  var PHOffset := Int64(U32(28));
  var PHSize := Integer(U16(42));
  var PHCount := Integer(U16(44));
  if PHCount > 0 then
  begin
    if (PHSize < 32) or (PHOffset + Int64(PHSize) * PHCount > Length(Data)) then
      raise EReadError.Create('Invalid ELF program headers');
    SetLength(FSegments, 0);
    for var I := 0 to PHCount - 1 do
    begin
      var H := Integer(PHOffset) + I * PHSize;
      var S: TPS2ELFSegment;
      // Keep every header kind in Flags' high byte: loaders want PT_LOAD (1)
      // and the IRX module header (70000080h).
      S.Offset := U32(H + 4);
      S.VirtualAddress := U32(H + 8);
      S.PhysicalAddress := U32(H + 12);
      S.FileSize := U32(H + 16);
      S.MemorySize := U32(H + 20);
      S.Flags := U32(H);
      if Int64(S.Offset) + S.FileSize > Length(Data) then
        raise EReadError.Create('Invalid ELF segment');
      FSegments := FSegments + [S];
    end;
  end;
  var SHOffset := Int64(U32(32));
  var SHSize := Integer(U16(46));
  var SHCount := Integer(U16(48));
  var SHNames := Integer(U16(50));
  if (SHCount > 0) and (SHSize >= 40) and (SHOffset + Int64(SHSize) * SHCount <= Length(Data)) then
  begin
    SetLength(FSections, SHCount);
    for var I := 0 to SHCount - 1 do
    begin
      var H := Integer(SHOffset) + I * SHSize;
      FSections[I].Kind := U32(H + 4);
      FSections[I].Flags := U32(H + 8);
      FSections[I].Address := U32(H + 12);
      FSections[I].Offset := U32(H + 16);
      FSections[I].Size := U32(H + 20);
      FSections[I].Link := U32(H + 24);
      FSections[I].Info := U32(H + 28);
      FSections[I].EntrySize := U32(H + 36);
      FSections[I].Name := Format('%d', [U32(H)]);
    end;
    if (SHNames < SHCount) then
    begin
      var StrOff := FSections[SHNames].Offset;
      for var I := 0 to SHCount - 1 do
      begin
        var P := Int64(StrOff) + StrToInt(FSections[I].Name);
        var Name := '';
        while (P < Length(Data)) and (Data[P] <> 0) and (Length(Name) < 64) do
        begin
          Name := Name + Char(Data[P]);
          Inc(P);
        end;
        FSections[I].Name := Name;
      end;
    end;
  end;
end;

function TPS2ELF.U16(Offset: Integer): Cardinal;
begin
  Result := Cardinal(FData[Offset]) or (Cardinal(FData[Offset + 1]) shl 8);
end;

function TPS2ELF.U32(Offset: Integer): Cardinal;
begin
  Result := U16(Offset) or (U16(Offset + 2) shl 16);
end;

function TPS2ELF.FindSection(const Name: string): Integer;
begin
  for var I := 0 to High(FSections) do
    if FSections[I].Name = Name then
      Exit(I);
  Result := -1;
end;

end.
