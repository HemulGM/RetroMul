unit INTV.Locutus;

interface

uses
  System.SysUtils, Core.Snapshots, INTV.LuigiImage;

type
  TIntvLocutus = class
  private
    const
      Readable = 1;
      Writable = 2;
      Narrow = 4;
      Banking = 8;
  private
    FMemory: TArray<Word>;
    FMap, FResetMap: TLuigiParagraphs;
    FAccess, FResetAccess: TLuigiPermissions;
    FPages: TLuigiPages;
    FMapperEnabled: Boolean;
    procedure SwitchHalfPage(Address, Value: Word);
    procedure SwitchPage(Chapter, Page: Integer);
    procedure WriteMapper(Address, Value: Word);
  public
    constructor Create(const Image: TLuigiImage);
    procedure Reset;
    function ReadWord(Address: Word): Word;
    function TryPreviousValue(Address: Word; out Value: Word): Boolean;
    procedure WriteWord(Address, Value: Word);
    procedure SerializeState(State: TStateArchive);
    property MapperEnabled: Boolean read FMapperEnabled;
    property Memory: TArray<Word> read FMemory;
  end;

implementation

uses
  System.Classes;

constructor TIntvLocutus.Create(const Image: TLuigiImage);
begin
  inherited Create;
  FMemory := Image.Words;
  FResetMap := Image.Paragraphs;
  FResetAccess := Image.Permissions;
  FPages := Image.Pages;
  FMapperEnabled := Image.MapperEnabled;
  Reset;
end;

procedure TIntvLocutus.Reset;
begin
  FMap := FResetMap;
  FAccess := FResetAccess;
end;

function TIntvLocutus.ReadWord(Address: Word): Word;
begin
  var Paragraph := Address shr 8;
  if (FAccess[Paragraph] and Readable = 0) or (Address < $0500) or
    ((Address >= $1000) and (Address < $2000)) or ((Address >= $3000) and (Address < $4000)) then
    Exit($FFFF);
  Result := FMemory[(FMap[Paragraph] shl 8) or (Address and $FF)];
end;

function TIntvLocutus.TryPreviousValue(Address: Word; out Value: Word): Boolean;
begin
  var Paragraph := Address shr 8;
  Result := (Address >= $0500) and (FAccess[Paragraph] and (Readable or Writable) <> 0) and
    ((Address < $1000) or (Address >= $2000)) and ((Address < $3000) or (Address >= $4000));
  if Result then
    Value := FMemory[(FMap[Paragraph] shl 8) or (Address and $FF)];
end;

procedure TIntvLocutus.SwitchHalfPage(Address, Value: Word);
begin
  var First := ((Address and $F) shl 4) or ((Address and $10) shr 1);
  if FAccess[First] and Banking <> 0 then
    for var Offset := 0 to 7 do
      FMap[First + Offset] := (Value + Offset) and $FF;
end;

procedure TIntvLocutus.SwitchPage(Chapter, Page: Integer);
begin
  var Entry := FPages[Chapter, Page];
  if (Entry and Banking = 0) or (Chapter = 0) or
    ((Chapter = 1) and FMapperEnabled and (FAccess[$1F] and Writable = 0)) then
    Exit;
  var FirstOffset := 0;
  if Chapter = 4 then
    FirstOffset := 8;
  for var Offset := FirstOffset to 15 do
  begin
    var Paragraph := Chapter * 16 + Offset;
    FMap[Paragraph] := (Entry and $7F0) or Offset;
    FAccess[Paragraph] := Entry and 7;
  end;
end;

procedure TIntvLocutus.WriteMapper(Address, Value: Word);
begin
  var Index := Address and $FF;
  case Address shr 8 of
    $10:
      FMap[Index] := Value and $7FF;
    $11:
      FResetMap[Index] := Value and $7FF;
    $12:
      FAccess[Index] := Value and $F;
    $13:
      FResetAccess[Index] := Value and $F;
    $14:
      FPages[Index shr 4, Index and $F] := Value and $7FF;
  end;
end;

procedure TIntvLocutus.WriteWord(Address, Value: Word);
begin
  case Address of
    $40..$5F:
      begin
        SwitchHalfPage(Address, Value);
        Exit;
      end;
  end;
  var Paragraph := Address shr 8;
  var Access := FAccess[Paragraph];
  if (Address and $FFF = $FFF) and (Value and $FFF0 = ((Address and $F000) or $A50)) then
  begin
    SwitchPage(Address shr 12, Value and $F);
    Exit;
  end;
  if Access and Writable <> 0 then
  begin
    var Index := (FMap[Paragraph] shl 8) or (Address and $FF);
    if Access and Narrow <> 0 then
      Value := (FMemory[Index] and $FF00) or (Value and $FF);
    FMemory[Index] := Value;
  end
  else if FMapperEnabled and (Address >= $1000) and (Address <= $14FF) then
    WriteMapper(Address, Value);
end;

procedure TIntvLocutus.SerializeState(State: TStateArchive);
begin
  State.Field(FMemory[0], Length(FMemory) * SizeOf(Word));
  State.Field(FMap, SizeOf(FMap));
  State.Field(FResetMap, SizeOf(FResetMap));
  State.Field(FAccess, SizeOf(FAccess));
  State.Field(FResetAccess, SizeOf(FResetAccess));
  State.Field(FPages, SizeOf(FPages));
  if State.Loading then
  begin
    for var Index := 0 to 255 do
      if (FMap[Index] > $7FF) or (FResetMap[Index] > $7FF) or
        (FAccess[Index] > $F) or (FResetAccess[Index] > $F) then
        raise EReadError.Create('Invalid Locutus snapshot mapping');
    for var Chapter := 0 to 15 do
      for var Page := 0 to 15 do
        if FPages[Chapter, Page] > $7FF then
          raise EReadError.Create('Invalid Locutus snapshot page');
  end;
end;

end.

