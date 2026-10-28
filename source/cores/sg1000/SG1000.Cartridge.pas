unit SG1000.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots;

{$SCOPEDENUMS ON}

const
  ROM_CORE_ID_SG1000 = 'SG1000';
  ROM_CORE_ID_SC3000 = 'SC3000';
  ROM_CORE_ID_SF7000 = 'SF7000';
  ROM_CORE_ID_OMV = 'OMV';
  ROM_CORE_ID_SMS = 'SMS';
  ROM_CORE_ID_GG = 'GG';

type
  TSGMapper = (Standard, Ram2K, Ram8K, Basic32K, Music10K, DahjeeA, DahjeeB, SegaBanked, System2K,
    Terebi, Survivors, Megacart);

  TSGCartridge = class
  private
    FData: TBytes;
    FROMMask: Integer;
    FRAM: array[0..$7FFF] of Byte;
    FMapper: TSGMapper;
    FBanks: array[0..2] of Byte;
    FBankControl: Byte;
    FTabletX, FTabletY, FTabletData, FBlock, FBlockLatch: Byte;
    FTabletPressed: Boolean;
    function ROM(Address: Integer): Byte; inline;
    function RAMIndex(Address: Integer): Integer;
  public
    constructor Create(const Data: TBytes; MapperHint: Integer = -1);
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure WritePort(Port, Value: Byte);
    procedure SetTablet(X, Y: Integer; Pressed: Boolean);
    function OverridesSystemRAM: Boolean;
    procedure SerializeState(State: TStateArchive);
    property Mapper: TSGMapper read FMapper;
  end;

function SGCRC32(const Data: TBytes): Cardinal;

implementation

function SGCRC32(const Data: TBytes): Cardinal;
const
  Table: array[0..255] of Cardinal = (
    $00000000, $77073096, $EE0E612C, $990951BA, $076DC419, $706AF48F, $E963A535, $9E6495A3,
    $0EDB8832, $79DCB8A4, $E0D5E91E, $97D2D988, $09B64C2B, $7EB17CBD, $E7B82D07, $90BF1D91,
    $1DB71064, $6AB020F2, $F3B97148, $84BE41DE, $1ADAD47D, $6DDDE4EB, $F4D4B551, $83D385C7,
    $136C9856, $646BA8C0, $FD62F97A, $8A65C9EC, $14015C4F, $63066CD9, $FA0F3D63, $8D080DF5,
    $3B6E20C8, $4C69105E, $D56041E4, $A2677172, $3C03E4D1, $4B04D447, $D20D85FD, $A50AB56B,
    $35B5A8FA, $42B2986C, $DBBBC9D6, $ACBCF940, $32D86CE3, $45DF5C75, $DCD60DCF, $ABD13D59,
    $26D930AC, $51DE003A, $C8D75180, $BFD06116, $21B4F4B5, $56B3C423, $CFBA9599, $B8BDA50F,
    $2802B89E, $5F058808, $C60CD9B2, $B10BE924, $2F6F7C87, $58684C11, $C1611DAB, $B6662D3D,
    $76DC4190, $01DB7106, $98D220BC, $EFD5102A, $71B18589, $06B6B51F, $9FBFE4A5, $E8B8D433,
    $7807C9A2, $0F00F934, $9609A88E, $E10E9818, $7F6A0DBB, $086D3D2D, $91646C97, $E6635C01,
    $6B6B51F4, $1C6C6162, $856530D8, $F262004E, $6C0695ED, $1B01A57B, $8208F4C1, $F50FC457,
    $65B0D9C6, $12B7E950, $8BBEB8EA, $FCB9887C, $62DD1DDF, $15DA2D49, $8CD37CF3, $FBD44C65,
    $4DB26158, $3AB551CE, $A3BC0074, $D4BB30E2, $4ADFA541, $3DD895D7, $A4D1C46D, $D3D6F4FB,
    $4369E96A, $346ED9FC, $AD678846, $DA60B8D0, $44042D73, $33031DE5, $AA0A4C5F, $DD0D7CC9,
    $5005713C, $270241AA, $BE0B1010, $C90C2086, $5768B525, $206F85B3, $B966D409, $CE61E49F,
    $5EDEF90E, $29D9C998, $B0D09822, $C7D7A8B4, $59B33D17, $2EB40D81, $B7BD5C3B, $C0BA6CAD,
    $EDB88320, $9ABFB3B6, $03B6E20C, $74B1D29A, $EAD54739, $9DD277AF, $04DB2615, $73DC1683,
    $E3630B12, $94643B84, $0D6D6A3E, $7A6A5AA8, $E40ECF0B, $9309FF9D, $0A00AE27, $7D079EB1,
    $F00F9344, $8708A3D2, $1E01F268, $6906C2FE, $F762575D, $806567CB, $196C3671, $6E6B06E7,
    $FED41B76, $89D32BE0, $10DA7A5A, $67DD4ACC, $F9B9DF6F, $8EBEEFF9, $17B7BE43, $60B08ED5,
    $D6D6A3E8, $A1D1937E, $38D8C2C4, $4FDFF252, $D1BB67F1, $A6BC5767, $3FB506DD, $48B2364B,
    $D80D2BDA, $AF0A1B4C, $36034AF6, $41047A60, $DF60EFC3, $A867DF55, $316E8EEF, $4669BE79,
    $CB61B38C, $BC66831A, $256FD2A0, $5268E236, $CC0C7795, $BB0B4703, $220216B9, $5505262F,
    $C5BA3BBE, $B2BD0B28, $2BB45A92, $5CB36A04, $C2D7FFA7, $B5D0CF31, $2CD99E8B, $5BDEAE1D,
    $9B64C2B0, $EC63F226, $756AA39C, $026D930A, $9C0906A9, $EB0E363F, $72076785, $05005713,
    $95BF4A82, $E2B87A14, $7BB12BAE, $0CB61B38, $92D28E9B, $E5D5BE0D, $7CDCEFB7, $0BDBDF21,
    $86D3D2D4, $F1D4E242, $68DDB3F8, $1FDA836E, $81BE16CD, $F6B9265B, $6FB077E1, $18B74777,
    $88085AE6, $FF0F6A70, $66063BCA, $11010B5C, $8F659EFF, $F862AE69, $616BFFD3, $166CCF45,
    $A00AE278, $D70DD2EE, $4E048354, $3903B3C2, $A7672661, $D06016F7, $4969474D, $3E6E77DB,
    $AED16A4A, $D9D65ADC, $40DF0B66, $37D83BF0, $A9BCAE53, $DEBB9EC5, $47B2CF7F, $30B5FFE9,
    $BDBDF21C, $CABAC28A, $53B39330, $24B4A3A6, $BAD03605, $CDD70693, $54DE5729, $23D967BF,
    $B3667A2E, $C4614AB8, $5D681B02, $2A6F2B94, $B40BBE37, $C30C8EA1, $5A05DF1B, $2D02EF8D);
begin
  Result := $FFFFFFFF;
  for var Value in Data do
    Result := (Result shr 8) xor Table[(Result xor Value) and $FF];
  Result := Result xor $FFFFFFFF;
end;

constructor TSGCartridge.Create(const Data: TBytes; MapperHint: Integer);
begin
  inherited Create;
  if (Length(Data) = 0) or (Length(Data) > $400000) then
    raise EReadError.Create('SG-1000/SC-3000 cartridge must contain 1..4194304 bytes');

  FData := Copy(Data);
  FMapper := TSGMapper.Standard;
  if Length(Data) > $C000 then
    FMapper := TSGMapper.SegaBanked;
  case SGCRC32(FData) of
    // Cartridge wiring identified by CRC32; metadata from MAME CC0 software lists.
    $1D1A0CA3, $AF4F14BC, $B7EC1307, $CDF7BDF3, $F691F9C7:
      FMapper := TSGMapper.Ram2K;
    $092F29D6:
      FMapper := TSGMapper.Ram8K;
    $55F47493, $5D9F11CA, $78A37CBC, $A46E3C73, $D5E919C1:
      FMapper := TSGMapper.Basic32K;
    $2EC28526, $622010E1:
      FMapper := TSGMapper.Music10K;
    $223397A1, $281D2888, $29E047CC, $2E7166D5, $306D5F78, $5CBD1163, $C550B4F0, $CE5648C3, $DF7CBFA5, $E0816BB7, $FC87463C:
      FMapper := TSGMapper.DahjeeA;
    $2E366CCF, $69FC1494, $AAAC12CF, $D2EDD329, $FFC4EE3F:
      FMapper := TSGMapper.DahjeeB;
    $7F7F009D:  // Korean Circus Charlie requires 2 KiB at $C000, mirrored through $FFFF. The ordinary 1 KiB SG RAM aliases its stack and game work area.
      FMapper := TSGMapper.System2K;
    $DD4A661B:
      FMapper := TSGMapper.Terebi;
    $3003D9BD, $626E30CC:  // These unbanked translations are padded to 65535 bytes, not banked carts.
      FMapper := TSGMapper.Standard;
  end;
  if Length(Data) >= $200000 then
    FMapper := TSGMapper.Survivors;
  if Length(Data) >= $400000 then
    FMapper := TSGMapper.Megacart;
  if (MapperHint >= 0) and (MapperHint <= Ord(High(TSGMapper))) then
    FMapper := TSGMapper(MapperHint);
  if FMapper = TSGMapper.SegaBanked then
  begin
    var OriginalSize := Length(FData);
    SetLength(FData, ((OriginalSize + $3FFF) div $4000) * $4000);
    for var I := OriginalSize to High(FData) do
      FData[I] := $FF;
  end;
  FROMMask := -1;
  if Length(FData) and (Length(FData) - 1) = 0 then
    FROMMask := Length(FData) - 1;
  Reset;
end;

procedure TSGCartridge.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FBanks[0] := 0;
  FBanks[1] := 1;
  FBanks[2] := 2;
  FBankControl := 0;
  FBlock := $3F;
  FBlockLatch := 0;
  FTabletData := 0;
  FTabletX := 128;
  FTabletY := 96;
  FTabletPressed := False;
end;

function TSGCartridge.RAMIndex(Address: Integer): Integer;
begin
  Result := -1;
  case FMapper of
    TSGMapper.Ram2K:
      if (Address >= $8000) and (Address < $A000) then
        Result := Address and $7FF;
    TSGMapper.Ram8K, TSGMapper.Music10K:
      if (Address >= $8000) and (Address < $A000) then
        Result := Address and $1FFF;
    TSGMapper.Basic32K:
      if Address >= $8000 then
        Result := Address - $8000;
    TSGMapper.Survivors, TSGMapper.Megacart:
      if Address >= $8000 then
        Result := Address - $8000;
    TSGMapper.SegaBanked:
      if (Address >= $8000) and (Address < $C000) and (FBankControl and 8 <> 0) then
        Result := (Address and $3FFF) + ((FBankControl and 4) * $1000);
    TSGMapper.DahjeeA:
      if (Address >= $2000) and (Address < $4000) then
        Result := Address and $1FFF;
  end;
  if Address >= $C000 then
    case FMapper of
      TSGMapper.Music10K:
        Result := $2000 + (Address and $7FF);
      TSGMapper.DahjeeA:
        Result := $2000 + (Address and $3FF);
      TSGMapper.DahjeeB:
        Result := Address and $1FFF;
      TSGMapper.System2K:
        Result := Address and $7FF;
    end;
end;

function TSGCartridge.OverridesSystemRAM: Boolean;
begin
  Result := FMapper in [TSGMapper.Basic32K, TSGMapper.Music10K,
      TSGMapper.DahjeeA, TSGMapper.DahjeeB, TSGMapper.System2K, TSGMapper.Survivors, TSGMapper.Megacart];
end;

function TSGCartridge.ROM(Address: Integer): Byte;
begin
  if FROMMask >= 0 then
    Address := Address and FROMMask
  else
    Address := Address mod Length(FData);
  Result := FData[Address];
end;

function TSGCartridge.Read(Address: Word): Byte;
begin
  if FMapper = TSGMapper.Standard then
    Exit(ROM(Address));

  if FMapper = TSGMapper.Terebi then
  begin
    if Address = $8000 then
      Exit(Ord(not FTabletPressed));
    if Address = $A000 then
      Exit(FTabletData);
  end;

  var Index := RAMIndex(Address);
  if Index >= 0 then
    Result := FRAM[Index]
  else if FMapper in [TSGMapper.Survivors, TSGMapper.Megacart] then
    Result := ROM((Integer(FBlock) * $8000) + (Address and $7FFF))
  else if (FMapper = TSGMapper.SegaBanked) and (Address >= $400) and (Address < $C000) then
    Result := ROM(Integer(FBanks[Address div $4000]) * $4000 + (Address and $3FFF))
  else
    Result := ROM(Address);
end;

procedure TSGCartridge.Write(Address: Word; Value: Byte);
begin
  if (FMapper = TSGMapper.Terebi) and (Address = $6000) then
  begin
    if Value and 1 <> 0 then
      FTabletData := FTabletX
    else
      FTabletData := FTabletY + $20;
    Exit;
  end;

  if (FMapper = TSGMapper.SegaBanked) and (Address >= $FFFC) then
  begin
    if Address = $FFFC then
      FBankControl := Value
    else
      FBanks[Address - $FFFD] := Value;
  end;
  var Index := RAMIndex(Address);
  if Index >= 0 then
    FRAM[Index] := Value;
end;

procedure TSGCartridge.SetTablet(X, Y: Integer; Pressed: Boolean);
begin
  FTabletX := System.Math.EnsureRange(X, 4, 251);
  FTabletY := System.Math.EnsureRange(Y, 0, 191);
  FTabletPressed := Pressed;
end;

procedure TSGCartridge.WritePort(Port, Value: Byte);
begin
  if Port and $E0 <> $E0 then
    Exit;

  if FMapper = TSGMapper.Survivors then
  begin
    FBlock := $3F;
    if Value and $80 <> 0 then
      FBlock := (Value and $1F) or ((Value and $40) shr 1);
  end
  else if FMapper = TSGMapper.Megacart then
  begin
    FBlock := (Value and $1F) or ((Value and $C0) shr 1);
  end;
end;

procedure TSGCartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FBanks, SizeOf(FBanks));
  State.Field(FBankControl, SizeOf(FBankControl));
  State.Field(FTabletX, SizeOf(FTabletX));
  State.Field(FTabletY, SizeOf(FTabletY));
  State.Field(FTabletData, SizeOf(FTabletData));
  State.Field(FTabletPressed, SizeOf(FTabletPressed));
  State.Field(FBlock, SizeOf(FBlock));
  State.Field(FBlockLatch, SizeOf(FBlockLatch));
end;

end.

