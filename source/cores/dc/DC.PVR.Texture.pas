unit DC.PVR.Texture;

// PowerVR2 textures decoded to ARGB8888: twiddled and scan-order layouts,
// stride textures, VQ compression, 4/8-bit palettes, ARGB1555/RGB565/
// ARGB4444/YUV422 and bump maps (kept raw), with mipmap chains. Decoded
// textures are cached and revalidated against VRAM page write generations
// and the palette generation.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Generics.Collections, DC.Memory;

const
  TexARGB1555 = 0;
  TexRGB565 = 1;
  TexARGB4444 = 2;
  TexYUV422 = 3;
  TexBump = 4;
  TexPal4 = 5;
  TexPal8 = 6;

type
  TPVRTexture = class
  public
    TCW, SizeBits, PaletteKey: Cardinal;
    Width, Height: Integer;   // largest level
    Levels: Integer;          // 1 without mipmaps
    LevelOffset: array[0..10] of Integer;
    LevelShift: array[0..10] of Integer; // log2 width of each level
    Texels: TArray<Cardinal>;
    Format: Integer;
    // Validation.
    FirstPage, LastPage: Integer;
    Gens: TArray<Cardinal>;
    PaletteGen: Cardinal;
    LastUse: Int64;
    // The scene it was last validated in.
    Checked: Int64;
  end;

  TPVRTextureCache = class
  private
    FMemory: TDCMemory;
    FTextures: TDictionary<UInt64, TPVRTexture>;
    FClock: Int64;
    // The current scene and the texture Get returned last in it.
    FScene: Int64;
    FLast: TPVRTexture;
    FLastKey: UInt64;
    procedure Decode(T: TPVRTexture; const Palette: array of Cardinal; PalFormat: Cardinal; Stride: Integer);
    function Valid(T: TPVRTexture; PaletteGen: Cardinal): Boolean;
  public
    constructor Create(Memory: TDCMemory);
    destructor Destroy; override;
    procedure Clear;
    // Starts a scene: textures are validated against VRAM and the palette
    // once per scene, which must not change them until the next.
    procedure NewScene;
    // Texture for a TCW and the TSP size bits (U size 5..3, V size 2..0).
    function Get(TCW, TSP: Cardinal; const Palette: array of Cardinal; PalFormat, PaletteGen: Cardinal; Stride: Integer): TPVRTexture;
    // Drops the least recently used half above MaxTextures, never a texture
    // used since Clock was Mark (the current scene's).
    procedure Trim(MaxTextures: Integer; Mark: Int64);
    property Clock: Int64 read FClock;
  end;

function Twiddle(X, Y, Width, Height: Integer): Integer;

function DecodeTexel(Value: Cardinal; Format: Integer): Cardinal;

function YUVToARGB(Y, U, V: Integer): Cardinal;

implementation

function Spread(V: Integer): Integer; inline;
begin
  // Bits of V moved to even positions.
  V := V and $3FF;
  V := (V or (V shl 8)) and $00FF00FF;
  V := (V or (V shl 4)) and $0F0F0F0F;
  V := (V or (V shl 2)) and $33333333;
  V := (V or (V shl 1)) and $55555555;
  Result := V;
end;

function Twiddle(X, Y, Width, Height: Integer): Integer;
begin
  // Morton order with V in the low bit; rectangular textures are a row of
  // squares of the smaller side.
  if Width = Height then
    Exit((Spread(X) shl 1) or Spread(Y));
  if Width > Height then
    Result := (X div Height) * Height * Height + ((Spread(X mod Height) shl 1) or Spread(Y))
  else
    Result := (Y div Width) * Width * Width + ((Spread(X) shl 1) or Spread(Y mod Width));
end;

function Expand5(V: Cardinal): Cardinal; inline;
begin
  Result := (V shl 3) or (V shr 2);
end;

function Expand6(V: Cardinal): Cardinal; inline;
begin
  Result := (V shl 2) or (V shr 4);
end;

function DecodeTexel(Value: Cardinal; Format: Integer): Cardinal;
begin
  case Format of
    TexARGB1555:
      begin
        Result := (Expand5((Value shr 10) and 31) shl 16) or (Expand5((Value shr 5) and 31) shl 8) or
          Expand5(Value and 31);
        if (Value and $8000) <> 0 then
          Result := Result or $FF000000;
      end;
    TexRGB565:
      Result := $FF000000 or (Expand5((Value shr 11) and 31) shl 16) or (Expand6((Value shr 5) and 63) shl 8) or
        Expand5(Value and 31);
    TexARGB4444:
      Result := (((Value shr 12) and 15) * $11 shl 24) or (((Value shr 8) and 15) * $11 shl 16) or
        (((Value shr 4) and 15) * $11 shl 8) or ((Value and 15) * $11);
  else
    // ARGB8888 palette entries and raw bump values.
    Result := Value;
  end;
end;

function Clamp8(V: Integer): Cardinal; inline;
begin
  if V < 0 then
    Result := 0
  else if V > 255 then
    Result := 255
  else
    Result := Cardinal(V);
end;

function YUVToARGB(Y, U, V: Integer): Cardinal;
begin
  // ITU-R BT.601 with the coefficients the PVR uses (fixed point /16384).
  U := U - 128;
  V := V - 128;
  var R := Y + (22970 * V) div 16384;
  var G := Y - (5638 * U + 11700 * V) div 16384;
  var B := Y + (29032 * U) div 16384;
  Result := $FF000000 or (Clamp8(R) shl 16) or (Clamp8(G) shl 8) or Clamp8(B);
end;

{ TPVRTextureCache }

constructor TPVRTextureCache.Create(Memory: TDCMemory);
begin
  inherited Create;
  FMemory := Memory;
  FTextures := TDictionary<UInt64, TPVRTexture>.Create;
end;

destructor TPVRTextureCache.Destroy;
begin
  Clear;
  FTextures.Free;
  inherited;
end;

procedure TPVRTextureCache.Clear;
begin
  for var T in FTextures.Values do
    T.Free;
  FTextures.Clear;
  FLast := nil;
end;

procedure TPVRTextureCache.NewScene;
begin
  Inc(FScene);
  FLast := nil;
end;

procedure TPVRTextureCache.Trim(MaxTextures: Integer; Mark: Int64);
begin
  if FTextures.Count <= MaxTextures then
    Exit;
  // Drop the least recently used half.
  var Stamps: TArray<Int64>;
  SetLength(Stamps, FTextures.Count);
  var N := 0;
  for var T in FTextures.Values do
  begin
    Stamps[N] := T.LastUse;
    Inc(N);
  end;
  TArray.Sort<Int64>(Stamps);
  var Limit := Stamps[N div 2];
  if Limit > Mark then
    Limit := Mark;
  var Keys := FTextures.Keys.ToArray;
  for var K in Keys do
  begin
    var T := FTextures[K];
    if T.LastUse <= Limit then
    begin
      if T = FLast then
        FLast := nil;
      T.Free;
      FTextures.Remove(K);
    end;
  end;
end;

function TPVRTextureCache.Valid(T: TPVRTexture; PaletteGen: Cardinal): Boolean;
begin
  if ((T.Format = TexPal4) or (T.Format = TexPal8)) and (T.PaletteGen <> PaletteGen) then
    Exit(False);
  for var P := T.FirstPage to T.LastPage do
    if (FMemory.VRAMGens[P] <> T.Gens[(P - T.FirstPage) * 2]) or
      (FMemory.VRAMGens[P + 1024] <> T.Gens[(P - T.FirstPage) * 2 + 1]) then
      Exit(False);
  Result := True;
end;

function TPVRTextureCache.Get(TCW, TSP: Cardinal; const Palette: array of Cardinal; PalFormat, PaletteGen: Cardinal; Stride: Integer): TPVRTexture;
begin
  Inc(FClock);
  var Format := Integer((TCW shr 27) and 7);
  var PalKey: Cardinal := 0;
  if (Format = TexPal4) or (Format = TexPal8) then
    PalKey := ((TCW shr 21) and $3F) or (PalFormat shl 8);
  var Key := (UInt64(TCW) shl 32) or (UInt64(TSP and $3F) shl 16) or (UInt64(Stride and $FF) shl 8) or (PalKey and $FF) or
    (UInt64(PalKey shr 8) shl 14);
  // Polygons in a row often share a texture.
  if (FLast <> nil) and (Key = FLastKey) then
  begin
    Result := FLast;
    Result.LastUse := FClock;
    Exit;
  end;
  if FTextures.TryGetValue(Key, Result) then
  begin
    if (Result.Checked <> FScene) and not Valid(Result, PaletteGen) then
      Decode(Result, Palette, PalFormat, Stride);
  end
  else
  begin
    Result := TPVRTexture.Create;
    Result.TCW := TCW;
    Result.SizeBits := TSP and $3F;
    Result.PaletteKey := PalKey;
    Result.PaletteGen := PaletteGen;
    Decode(Result, Palette, PalFormat, Stride);
    FTextures.Add(Key, Result);
  end;
  Result.PaletteGen := PaletteGen;
  Result.LastUse := FClock;
  Result.Checked := FScene;
  FLast := Result;
  FLastKey := Key;
end;

procedure TPVRTextureCache.Decode(T: TPVRTexture; const Palette: array of Cardinal; PalFormat: Cardinal; Stride: Integer);
var
  VRAM: PByte;

  function Read16(Offset: Cardinal): Cardinal;
  begin
    // Texture addresses are in the 64-bit view.
    Result := PWord(VRAM + TDCMemory.VRAM64(Offset and $7FFFFE))^;
  end;

  function Read8(Offset: Cardinal): Cardinal;
  begin
    Result := (VRAM + TDCMemory.VRAM64(Offset and $7FFFFF))^;
  end;

  function PaletteColor(Index: Integer): Cardinal;
  begin
    var Entry := Palette[Index and 1023];
    case PalFormat of
      0:
        Result := DecodeTexel(Entry, TexARGB1555);
      1:
        Result := DecodeTexel(Entry, TexRGB565);
      2:
        Result := DecodeTexel(Entry, TexARGB4444);
    else
      Result := Entry;
    end;
  end;

begin
  VRAM := FMemory.VRAM;
  var TCW := T.TCW;
  var Format := Integer((TCW shr 27) and 7);
  if Format = 7 then
    Format := TexARGB1555;
  T.Format := Format;
  var Mipmapped := (TCW and $80000000) <> 0;
  var VQ := (TCW and $40000000) <> 0;
  var Palettized := (Format = TexPal4) or (Format = TexPal8);
  var ScanOrder := ((TCW and $04000000) <> 0) and not Palettized;
  var StrideSelect := ScanOrder and ((TCW and $02000000) <> 0);
  var Base := (TCW and $1FFFFF) shl 3;
  var USize := 8 shl ((T.SizeBits shr 3) and 7);
  var VSize := 8 shl (T.SizeBits and 7);
  if StrideSelect and (Stride > 0) then
    USize := Stride;
  if ScanOrder then
    Mipmapped := False;
  if Mipmapped then
    VSize := USize;
  T.Width := USize;
  T.Height := VSize;
  var PalBase := 0;
  if Format = TexPal4 then
    PalBase := Integer((TCW shr 21) and $3F) * 16
  else if Format = TexPal8 then
    PalBase := Integer((TCW shr 25) and 3) * 256;

  // Levels from largest (0) to smallest; each level's texels follow.
  var LevelCount := 1;
  if Mipmapped then
  begin
    LevelCount := 0;
    var S := USize;
    while S >= 1 do
    begin
      Inc(LevelCount);
      S := S shr 1;
    end;
  end;
  T.Levels := LevelCount;
  var Total := 0;
  for var L := 0 to LevelCount - 1 do
  begin
    T.LevelOffset[L] := Total;
    var W := USize shr L;
    var H := VSize shr L;
    if W < 1 then
      W := 1;
    if H < 1 then
      H := 1;
    var Shift := 0;
    while (1 shl Shift) < W do
      Inc(Shift);
    T.LevelShift[L] := Shift;
    Inc(Total, W * H);
  end;
  SetLength(T.Texels, Total);

  var Codebook: array[0..1023] of Cardinal;
  var DataBase := Base;
  if VQ then
  begin
    for var I := 0 to 1023 do
      Codebook[I] := Read16(Base + Cardinal(I) * 2);
    DataBase := Base + 2048;
  end;

  var MaxOffset := DataBase;
  for var L := 0 to LevelCount - 1 do
  begin
    var W := USize shr L;
    var H := VSize shr L;
    if W < 1 then
      W := 1;
    if H < 1 then
      H := 1;
    // Level K = log2 of its side; mipmap chains are stored smallest first.
    var LevelBase := DataBase;
    if Mipmapped then
    begin
      var K := T.LevelShift[L];
      if VQ then
      begin
        // Index bytes: 1x1 and 2x2 one index each, then 4^(k-1).
        var Offset := 0;
        for var J := 0 to K - 1 do
          if J <= 1 then
            Inc(Offset)
          else
            Inc(Offset, 1 shl (2 * (J - 1)));
        LevelBase := DataBase + Cardinal(Offset);
      end
      else
      begin
        // Texels: three pad texels, then 4^j for each smaller level.
        var Texel := 3;
        for var J := 0 to K - 1 do
          Inc(Texel, 1 shl (2 * J));
        case Format of
          TexPal4:
            LevelBase := DataBase + Cardinal(Texel div 2);
          TexPal8:
            LevelBase := DataBase + Cardinal(Texel);
        else
          LevelBase := DataBase + Cardinal(Texel) * 2;
        end;
      end;
    end;
    var out := T.LevelOffset[L];
    for var Y := 0 to H - 1 do
      for var X := 0 to W - 1 do
      begin
        var Texel: Cardinal;
        if VQ then
        begin
          var Index: Cardinal;
          if (W >= 2) and (H >= 2) then
          begin
            Index := Read8(LevelBase + Cardinal(Twiddle(X shr 1, Y shr 1, W shr 1, H shr 1)));
            Texel := Codebook[Index * 4 + Cardinal(((X and 1) shl 1) or (Y and 1))];
          end
          else
          begin
            Index := Read8(LevelBase);
            Texel := Codebook[Index * 4];
          end;
          if Format = TexPal8 then
            Texel := PaletteColor(PalBase + Integer(Texel and $FF))
          else if Format = TexPal4 then
            Texel := PaletteColor(PalBase + Integer(Texel and 15))
          else
            Texel := DecodeTexel(Texel, Format);
        end
        else
        begin
          var Index: Integer;
          if ScanOrder then
            Index := Y * W + X
          else
            Index := Twiddle(X, Y, W, H);
          case Format of
            TexPal4:
              begin
                var B := Read8(LevelBase + Cardinal(Index shr 1));
                if Mipmapped and (W = 1) then
                  B := B shr 4
                else if (Index and 1) <> 0 then
                  B := B shr 4;
                Texel := PaletteColor(PalBase + Integer(B and 15));
              end;
            TexPal8:
              Texel := PaletteColor(PalBase + Integer(Read8(LevelBase + Cardinal(Index))));
            TexYUV422:
              begin
                // Texels pair horizontally: U Y0 V Y1.
                var PairX := X and not 1;
                var I0, I1: Integer;
                if ScanOrder then
                begin
                  I0 := Y * W + PairX;
                  I1 := I0 + 1;
                end
                else
                begin
                  I0 := Twiddle(PairX, Y, W, H);
                  I1 := Twiddle(PairX + 1, Y, W, H);
                end;
                var A := Read16(LevelBase + Cardinal(I0) * 2);
                var B := Read16(LevelBase + Cardinal(I1) * 2);
                var YV := Integer(A shr 8);
                if (X and 1) <> 0 then
                  YV := Integer(B shr 8);
                Texel := YUVToARGB(YV, Integer(A and $FF), Integer(B and $FF));
              end;
          else
            Texel := DecodeTexel(Read16(LevelBase + Cardinal(Index) * 2), Format);
          end;
          var Last := LevelBase + Cardinal(Index + 1) * 2;
          if Last > MaxOffset then
            MaxOffset := Last;
        end;
        T.Texels[out + Y * W + X] := Texel;
      end;
    if VQ then
    begin
      var Last := LevelBase + Cardinal((W * H) div 4 + 1);
      if Last > MaxOffset then
        MaxOffset := Last;
    end;
  end;
  // Source pages: a 64-bit range covers the same pages in both 4 MiB banks.
  var Lo := (Base and $7FFFF8) shr 1;
  var Hi := ((MaxOffset + 8) and $FFFFF8) shr 1;
  if (Hi < Lo) or (Hi > $3FFFFF) then
    Hi := $3FFFFF;
  T.FirstPage := Lo shr 12;
  T.LastPage := Hi shr 12;
  SetLength(T.Gens, (T.LastPage - T.FirstPage + 1) * 2);
  for var P := T.FirstPage to T.LastPage do
  begin
    T.Gens[(P - T.FirstPage) * 2] := FMemory.VRAMGens[P];
    T.Gens[(P - T.FirstPage) * 2 + 1] := FMemory.VRAMGens[P + 1024];
  end;
end;

end.

