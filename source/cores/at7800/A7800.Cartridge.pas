unit A7800.Cartridge;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TA7800Mapper = (Linear, SuperGame, Activision, &Absolute);

  TA7800Cartridge = class
  private
    FROM: TBytes;
    FRAM: array[0..32767] of Byte;
    FMapper: TA7800Mapper;
    FFlags: Word;
    FBank, FRAMBank: Integer;
    FPAL: Boolean;
    FPokeyAddress: Word;
    function ROMByte(Index: Integer): Byte;
    function RAMIndex(Address: Word): Integer;
  public
    constructor Create(const Image: TBytes);
    class function HasHeader(const Image: TBytes): Boolean; static;
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property PAL: Boolean read FPAL;
    property Mapper: TA7800Mapper read FMapper;
    property PokeyAddress: Word read FPokeyAddress;
  end;

implementation

uses
  System.Hash;

class function TA7800Cartridge.HasHeader(const Image: TBytes): Boolean;
const
  Magic: AnsiString = 'ATARI7800';
begin
  Result := (Length(Image) >= 128) and CompareMem(@Image[1], PAnsiChar(Magic), 9);
end;

constructor TA7800Cartridge.Create(const Image: TBytes);
begin
  inherited Create;
  FMapper := TA7800Mapper.Linear;
  var Start := 0;
  var Count := Length(Image);
  if HasHeader(Image) then
  begin
    Start := 128;
    Dec(Count, Start);
    var Declared := (Cardinal(Image[49]) shl 24) or (Cardinal(Image[50]) shl 16) or
      (Cardinal(Image[51]) shl 8) or Image[52];
    if (Declared <> 0) and (Declared <> Cardinal(Count)) then
      raise EReadError.Create('Truncated or inconsistent A78 cartridge length');
    FFlags := (Word(Image[53]) shl 8) or Image[54];
    FPAL := Image[57] and 1 <> 0;
    if FFlags and 2 <> 0 then
      FMapper := TA7800Mapper.SuperGame;
    if FFlags and $100 <> 0 then
      FMapper := TA7800Mapper.Activision;
    if FFlags and $200 <> 0 then
      FMapper := TA7800Mapper.absolute;
    if FFlags and $800 <> 0 then
      raise EReadError.Create('A78 YM2151 expansion audio is not implemented');
    if FFlags and $7000 <> 0 then
      raise EReadError.Create('A78 Souper/Banksets cartridge hardware is not implemented');
    if FFlags and 1 <> 0 then
      FPokeyAddress := $4000;
    if FFlags and $40 <> 0 then
      FPokeyAddress := $450;
    if FFlags and $400 <> 0 then
      FPokeyAddress := $440;
    if FFlags and $8000 <> 0 then
      FPokeyAddress := $800;
    if Image[0] >= 4 then
    begin
      case Image[64] of
        0:
          FMapper := TA7800Mapper.Linear;
        1:
          FMapper := TA7800Mapper.SuperGame;
        2:
          FMapper := TA7800Mapper.Activision;
        3:
          FMapper := TA7800Mapper.absolute;
      else
        raise EReadError.Create('Unsupported A78 v4 mapper');
      end;
      if Image[65] and $80 <> 0 then
        raise EReadError.Create('A78 Banksets hardware is not implemented');
      FFlags := 0;
      case Image[65] and 7 of
        0:
          ;
        1:
          FFlags := 4;
        4:
          FFlags := 8;
        5:
          FFlags := 16;
      else
        raise EReadError.Create('Unsupported A78 v4 cartridge RAM layout');
      end;
      case Image[67] and 7 of
        0:
          FPokeyAddress := 0;
        1:
          FPokeyAddress := $440;
        2:
          FPokeyAddress := $450;
        4:
          FPokeyAddress := $800;
        5:
          FPokeyAddress := $4000;
      else
        raise EReadError.Create('Unsupported A78 dual POKEY layout');
      end;
      if Image[67] and $38 <> 0 then
        raise EReadError.Create('Unsupported A78 expansion audio');
    end;
  end
  else if Count > $C000 then
  begin
    FMapper := TA7800Mapper.SuperGame;
    if Count = $24000 then
      FFlags := 8;
  end;
  if (Count < $1000) or (Count > $100000) or (Count mod $1000 <> 0) then
    raise EReadError.Create('Invalid Atari 7800 cartridge size');
  FROM := Copy(Image, Start, Count);
  // Older A78 headers identify these 8 KiB boards as generic SuperGame RAM.
  // Hardware topology: Eckhard Stolberg's 7800 bankswitching guide.
  if (Start = 0) or (Image[0] < 4) then
  begin
    var ImageStream := TBytesStream.Create(FROM);
    var Digest: string;
    try
      Digest := THashSHA1.GetHashString(ImageStream).ToLower;
    finally
      ImageStream.Free;
    end;
    if (Digest = '9770b61472510aba1cf3ea35ceca1859c3493676') or
      (Digest = 'eb16de0c3d5c4e769ae2314ba21c4dd3bca33c88') or
      (Digest = '56e1b795e80382edb376e4536d1dee539d4ac548') then
      FFlags := FFlags or $80;
  end;
  Reset;
end;

procedure TA7800Cartridge.Reset;
begin
  FBank := 0;
  if Length(FROM) = $24000 then
    FBank := 1;
  FRAMBank := 0;
end;

function TA7800Cartridge.ROMByte(Index: Integer): Byte;
begin
  Result := $FF;
  if (Index >= 0) and (Index < Length(FROM)) then
    Result := FROM[Index];
end;

function TA7800Cartridge.RAMIndex(Address: Word): Integer;
begin
  Result := Address and $3FFF;
  if FFlags and $80 <> 0 then
    Result := Result and $1FFF;
  Inc(Result, FRAMBank * $4000);
end;

function TA7800Cartridge.Read(Address: Word): Byte;
begin
  Result := $FF;
  if Address < $4000 then
    Exit;
  if (Address < $8000) and (FFlags and $A4 <> 0) then
    Exit(FRAM[RAMIndex(Address)]);
  case FMapper of
    TA7800Mapper.Linear:
      Result := ROMByte(Integer(Address) - ($10000 - Length(FROM)));
    TA7800Mapper.SuperGame:
      case Address shr 14 of
        1:
          if FFlags and 8 <> 0 then
            Result := ROMByte(Address and $3FFF)
          else if (FFlags and 16 <> 0) or (Length(FROM) >= $10000) then
            Result := ROMByte(Length(FROM) - $8000 + (Address and $3FFF));
        2:
          Result := ROMByte(FBank * $4000 + (Address and $3FFF));
        3:
          Result := ROMByte(Length(FROM) - $4000 + (Address and $3FFF));
      end;
    TA7800Mapper.absolute:
      if Address < $8000 then
        Result := ROMByte(FBank * $4000 + (Address and $3FFF))
      else
        Result := ROMByte($8000 + (Address - $8000));
    TA7800Mapper.Activision:
      case Address shr 13 of
        2:
          Result := ROMByte($1A000 + (Address and $1FFF));
        3:
          Result := ROMByte($18000 + (Address and $1FFF));
        4:
          Result := ROMByte($1E000 + (Address and $1FFF));
        5, 6:
          Result := ROMByte(FBank * $4000 + (Address - $A000));
        7:
          Result := ROMByte($1C000 + (Address and $1FFF));
      end;
  end;
end;

procedure TA7800Cartridge.Write(Address: Word; Value: Byte);
begin
  if (Address >= $4000) and (Address < $8000) and (FFlags and $A4 <> 0) then
    FRAM[RAMIndex(Address)] := Value;
  case FMapper of
    TA7800Mapper.SuperGame:
      if (Address >= $8000) and (Address < $C000) then
      begin
        var Banks := Length(FROM) div $4000;
        var Mask := Banks - 1;
        if Banks = 9 then
          Mask := 7;
        FBank := Value and Mask;
        if Length(FROM) = $24000 then
          Inc(FBank);
        if FFlags and $20 <> 0 then
          FRAMBank := (Value shr 5) and 1;
      end;
    TA7800Mapper.absolute:
      if Address = $8000 then
      begin
        if Value and 1 <> 0 then
          FBank := 0;
        if Value and 2 <> 0 then
          FBank := 1;
      end;
    TA7800Mapper.Activision:
      if Address >= $FF80 then
        FBank := Address and 7;
  end;
end;

procedure TA7800Cartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FBank, SizeOf(FBank));
  State.Field(FRAMBank, SizeOf(FRAMBank));
  State.Field(FRAM, SizeOf(FRAM));
  if State.Loading and ((FBank < 0) or (FBank >= Length(FROM) div $4000) or (FRAMBank < 0) or (FRAMBank > 1)) then
    raise EReadError.Create('Invalid A7800 cartridge state');
end;

end.

