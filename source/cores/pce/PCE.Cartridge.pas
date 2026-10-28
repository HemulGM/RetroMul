unit PCE.Cartridge;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TPCEModel = (PCengine, TurboGrafx16, CoreGrafx, CoreGrafxII, Shuttle, GT, LT,
    SuperGrafx, CDROM2, SuperCDROM2, Duo, DuoR, DuoRX, TurboDuo, ArcadeDuo, ArcadePro,
    SuperGrafxCD, TurboGrafxCD, SuperGrafxArcade);

  TPCEOptions = record
    ShowBackground, ShowSprites, RemoveSpriteLimit, Multitap, SixButton: Boolean;
    class function Defaults: TPCEOptions; static;
  end;

  TPCECartridge = class
  private
    FData, FRAM: TBytes;
    FBank: Byte;
    FSuperGrafx: Boolean;
  public
    constructor Create(const Data: TBytes; const Name: string = '');
    function Read(Bank: Byte; Offset: Word): Byte;
    procedure Write(Bank: Byte; Offset: Word; Value: Byte);
    procedure Reset;
    procedure SerializeState(State: TStateArchive);
    function SavePersistent: TBytes;
    procedure LoadPersistent(const Data: TBytes);
    property IdentityData: TBytes read FData;
    property SuperGrafx: Boolean read FSuperGrafx;
  end;

function PCECRC32(const Data: TBytes): Cardinal;

function PCEHasCD(Model: TPCEModel): Boolean;

function PCEIsSuperCD(Model: TPCEModel): Boolean;

function PCESuperGrafx(Model: TPCEModel): Boolean;

function PCEModelName(Model: TPCEModel): string;

implementation

class function TPCEOptions.Defaults: TPCEOptions;
begin
  Result := Default(TPCEOptions);
  Result.ShowBackground := True;
  Result.ShowSprites := True;
end;

function ReverseByte(Value: Byte): Byte;
begin
  Result := 0;
  for var I := 0 to 7 do
    Result := Result or (((Value shr I) and 1) shl (7 - I));
end;

function PCEHasCD(Model: TPCEModel): Boolean;
begin
  Result := Model >= TPCEModel.CDROM2;
end;

function PCEIsSuperCD(Model: TPCEModel): Boolean;
begin
  Result := PCEHasCD(Model) and not (Model in [TPCEModel.CDROM2, TPCEModel.TurboGrafxCD]);
end;

function PCESuperGrafx(Model: TPCEModel): Boolean;
begin
  Result := Model in [TPCEModel.SuperGrafx, TPCEModel.SuperGrafxCD, TPCEModel.SuperGrafxArcade];
end;

function PCEModelName(Model: TPCEModel): string;
const
  Names: array[TPCEModel] of string = ('PC Engine', 'TurboGrafx-16', 'CoreGrafx',
    'CoreGrafx II', 'PC Engine Shuttle', 'PC Engine GT / TurboExpress', 'PC Engine LT',
    'SuperGrafx', 'CD-ROM2 / TurboGrafx-CD', 'Super CD-ROM2', 'PC Engine Duo', 'Duo-R',
    'Duo-RX', 'TurboDuo', 'Arcade Card Duo', 'Arcade Card Pro', 'SuperGrafx + Super CD-ROM2',
    'TurboGrafx-CD', 'SuperGrafx + Arcade Card');
begin
  Result := Names[Model];
end;

function PCECRC32(const Data: TBytes): Cardinal;
begin
  Result := $FFFFFFFF;
  for var B in Data do
  begin
    Result := Result xor B;
    for var I := 0 to 7 do
      if Result and 1 <> 0 then
        Result := (Result shr 1) xor $EDB88320
      else
        Result := Result shr 1;
  end;
  Result := not Result;
end;

constructor TPCECartridge.Create(const Data: TBytes; const Name: string);
begin
  inherited Create;
  var Header := 0;
  if Length(Data) mod $2000 = 512 then
    Header := 512;
  var Size := Length(Data) - Header;
  if (Size < $2000) or (Size > $280000) or (Size mod $2000 <> 0) or
    ((Size > $100000) and (Size <> $280000)) then
    raise EReadError.Create('Invalid HuCard size (8 KiB banks, at most 1 MiB or 2.5 MiB SF2)');
  FData := Copy(Data, Header, Size);
  // Older US HuCard dumps can store every byte with the data lines reversed.
  // Prefer a native reset vector; normalize only when the reversed vector maps
  // to the ROM reset page and the native one does not.
  var VectorHigh := FData[$1FFF];
  var ReversedHigh := ReverseByte(VectorHigh);
  var NativePC := Integer(FData[$1FFE]) or (Integer(VectorHigh) shl 8);
  var ReversedPC := Integer(ReverseByte(FData[$1FFE])) or (Integer(ReversedHigh) shl 8);
  var NativeOp := FData[NativePC and $1FFF];
  var ReversedOp := ReverseByte(FData[ReversedPC and $1FFF]);
  var NativeBoot := NativeOp in [$78, $54, $D4, $D8, $A9, $A2, $A0, $4C, $EA, $62, $82, $C2, $02, $22, $42, $9C, $64];
  // Some vectors (e.g. $FF00) are unchanged by reversal. Confirm the reset
  // prologue in that case instead of relying only on the vector's high byte.
  if (ReversedHigh >= $E0) and ((VectorHigh < $E0) or
    (not NativeBoot and (ReversedOp in [$78, $D4, $D8, $4C]))) then
    for var P := 0 to High(FData) do
      FData[P] := ReverseByte(FData[P]);
  var CRC := PCECRC32(FData);
  FSuperGrafx := SameText(ExtractFileExt(Name), '.sgx') or Name.ToLower.Contains('(sgx)') or
    Name.ToLower.Contains('supergrafx') or
    (CRC = $B486A8ED) or (CRC = $1F041166) or (CRC = $3B13AF61) or
    (CRC = $4C2126B0) or (CRC = $8C4588E2);
  if CRC = $083C956A then
    SetLength(FRAM, $8000); // Populous HuCard RAM.
end;

procedure TPCECartridge.Reset;
begin
  FBank := 0;
end;

function TPCECartridge.Read(Bank: Byte; Offset: Word): Byte;
const
  Mirror384: array[0..7] of Integer = (0, $10, 0, $10, $20, $20, $20, $20);
  Mirror512: array[0..7] of Integer = (0, $10, $20, $30, $20, $30, $20, $30);
  Mirror768: array[0..7] of Integer = (0, $10, $20, $30, $40, $50, $40, $50);
begin
  Offset := Offset and $1FFF;
  if (Length(FRAM) > 0) and (Bank in [$40..$5F]) then
    Exit(FRAM[((Integer(Bank) - $40) * $2000 + Offset) and $7FFF]);
  if Bank > $7F then
    Exit($FF);
  var B := Integer(Bank);
  case Length(FData) of
    $60000:
      B := Mirror384[B shr 4] + (B and 15);
    $80000:
      B := Mirror512[B shr 4] + (B and 15);
    $C0000:
      B := Mirror768[B shr 4] + (B and 15);
    $280000:
      if B >= $40 then
        B := $40 + Integer(FBank) * $40 + (B and $3F);
  end;
  Result := FData[(B * $2000 + Offset) mod Length(FData)];
end;

procedure TPCECartridge.Write(Bank: Byte; Offset: Word; Value: Byte);
begin
  if (Length(FData) = $280000) and (Bank = 0) and ((Offset and $1FFC) = $1FF0) then
    FBank := Offset and 3;
  if (Length(FRAM) > 0) and (Bank in [$40..$5F]) then
    FRAM[((Integer(Bank) - $40) * $2000 + (Offset and $1FFF)) and $7FFF] := Value;
end;

procedure TPCECartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FBank, SizeOf(FBank));
  if Length(FRAM) > 0 then
    State.Field(FRAM[0], Length(FRAM));
  if State.Loading and (FBank > 3) then
    raise EReadError.Create('Invalid HuCard bank state');
end;

function TPCECartridge.SavePersistent: TBytes;
begin
  Result := Copy(FRAM);
end;

procedure TPCECartridge.LoadPersistent(const Data: TBytes);
begin
  if (Length(Data) > 0) and (Length(Data) <> Length(FRAM)) then
    raise EReadError.Create('Invalid HuCard RAM save size');
  if Length(Data) > 0 then
    FRAM := Copy(Data);
end;

end.

