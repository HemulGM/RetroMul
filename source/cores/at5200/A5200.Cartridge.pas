unit A5200.Cartridge;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TA5200Mapper = (cm4K, cm8K, cm16KTwoChip, cm16KOneChip, cm32K, cm40K);

  TA5200Cartridge = class
  private
    FData: TBytes;
    FMapper: TA5200Mapper;
    FBanks: array[0..1] of Integer;
  public
    constructor Create(const Data: TBytes; MapperHint: Integer = -1);
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Access(Address: Word);
    procedure SerializeState(State: TStateArchive);
    property Mapper: TA5200Mapper read FMapper;
  end;

implementation

uses
  System.Classes;

constructor TA5200Cartridge.Create(const Data: TBytes; MapperHint: Integer);
const
  Sizes: array[TA5200Mapper] of Integer = (4096, 8192, 16384, 16384, 32768, 40960);
begin
  inherited Create;
  FData := Copy(Data);
  if (Length(Data) >= 16) and (TEncoding.ASCII.GetString(Data, 0, 4) = 'CART') then
  begin
    var TypeId := (Cardinal(Data[4]) shl 24) or (Cardinal(Data[5]) shl 16) or (Cardinal(Data[6]) shl 8) or Data[7];
    FData := Copy(Data, 16);
    var Sum: Cardinal := 0;
    for var B in FData do
      Inc(Sum, B);
    var Expected: Cardinal := (Cardinal(Data[8]) shl 24) or (Cardinal(Data[9]) shl 16) or (Cardinal(Data[10]) shl 8) or Data[11];
    if Sum <> Expected then
      raise EReadError.Create('Atari cartridge checksum mismatch');
    case TypeId of
      4:
        MapperHint := 4;
      6:
        MapperHint := 2;
      7:
        MapperHint := 5;
      16:
        MapperHint := 3;
      19:
        MapperHint := 1;
      20:
        MapperHint := 0;
    else
      raise EReadError.Create('CAR header belongs to an unsupported Atari cartridge');
    end;
  end;
  case Length(FData) of
    4096:
      FMapper := cm4K;
    8192:
      FMapper := cm8K;
    16384:
      begin
        // The cartridge entry vector is in the fixed tail at $BFFE.
        // Two-chip software enters the lower mirror ($4000-$7FFF),
        // one-chip software enters its contiguous $8000-$BFFF ROM.
        var Entry := Word(FData[$3FFE]) or (Word(FData[$3FFF]) shl 8);
        if (Entry >= $8000) and (Entry < $C000) and
          not (FData[Entry - $8000] in [$00, $02, $12, $22, $32, $42, $52, $62, $72, $92, $B2, $D2, $F2, $FF]) then
          FMapper := cm16KOneChip
        else
          FMapper := cm16KTwoChip;
        if (Entry >= $8000) and (Entry < $9FFF) then
        begin
          var Mirrored := $2000 + (Entry and $1FFF);
          // Some two-chip diagnostics enter through the upper 8K mirror.
          // Prefer their explicit SEI/CLD reset stub over a data/routine entry.
          if (FData[Mirrored] = $78) and (FData[Mirrored + 1] = $D8) and
            not ((FData[Entry - $8000] = $78) and (FData[Entry - $8000 + 1] = $D8)) then
            FMapper := cm16KTwoChip;
        end;
      end;
    32768:
      FMapper := cm32K;
    40960:
      FMapper := cm40K;
  else
    raise EReadError.Create('Atari 5200 supports 4/8/16/32/40 KiB cartridges');
  end;
  if MapperHint >= 0 then
  begin
    if MapperHint > Ord(High(TA5200Mapper)) then
      raise EReadError.Create('Invalid Atari 5200 mapper');
    FMapper := TA5200Mapper(MapperHint);
  end;
  if Length(FData) <> Sizes[FMapper] then
    raise EReadError.Create('Atari 5200 mapper/size mismatch');
  Reset;
end;

procedure TA5200Cartridge.Reset;
begin
  FBanks[0] := 0;
  FBanks[1] := 0;
end;

procedure TA5200Cartridge.Access(Address: Word);
begin
  if FMapper = cm40K then
    if (Address >= $4FF6) and (Address <= $4FF9) then
      FBanks[0] := Address - $4FF6
    else if (Address >= $5FF6) and (Address <= $5FF9) then
      FBanks[1] := Address - $5FF6;
end;

function TA5200Cartridge.Read(Address: Word): Byte;
begin
  Access(Address);
  case FMapper of
    cm4K:
      Result := FData[Address and $FFF];
    cm8K:
      Result := FData[Address and $1FFF];
    cm16KTwoChip:
      Result := FData[((Address - $4000) div $4000) * $2000 + (Address and $1FFF)];
    cm16KOneChip:
      if Address < $8000 then
        Result := $FF
      else
        Result := FData[Address - $8000];
    cm32K:
      Result := FData[Address - $4000];
    cm40K:
      if Address < $5000 then
        Result := FData[FBanks[0] * 4096 + (Address and $FFF)]
      else if Address < $6000 then
        Result := FData[16384 + FBanks[1] * 4096 + (Address and $FFF)]
      else if Address >= $8000 then
        Result := FData[32768 + (Address and $1FFF)]
      else
        Result := $FF;
  else
    Result := $FF;
  end;
end;

procedure TA5200Cartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FBanks, SizeOf(FBanks));
  for var B in FBanks do
    if (B < 0) or (B > 3) then
      raise EReadError.Create('Invalid cartridge state');
end;

end.

