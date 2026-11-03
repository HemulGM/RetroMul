unit PSP.GE.Texture;

// Texture fetch and filtering as the GE samples: all pixel formats, CLUT
// lookups through the CLUT cache (shift, mask, offset), DXT1/3/5, swizzled
// layout, wrap and clamp, nearest and bilinear.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory;

type
  TGETexLevel = record
    Addr: Cardinal;
    Width, Height: Integer;  // 1 shl size bits
    BufWidth: Integer;       // in texels
    // The level's bytes in host memory when they are contiguous there (nil
    // otherwise), for reads without the guest page table.
    Ptr: PByte;
    Size: Cardinal;
    // Every texel the sampler can address lies in Ptr's Size bytes (set by
    // GEFitLevel; False only costs speed).
    Fits: Boolean;
    // Added to a CLUT index read from this level (a CLUT per level).
    ClutAdd: Integer;
  end;

  PGETexLevel = ^TGETexLevel;

  PGETexture = ^TGETexture;

  // The texture cache while a primitive textures from the pixels it draws
  // (TGETexture.Cache; recorded on a PSP-E1000, probe ge_tcache):
  // texels come from blocks of 8 rows of 16 bytes (a swizzled texture's
  // blocks), each loaded when first read after a TEXFLUSH, as memory held it
  // then. A load holds the pixels up GETexCacheMiss cycles, a pixel takes
  // one, and what the pixels write reaches memory GETexCacheDelay cycles
  // after the last of each 4 pixels of a row.
  TGETexCacheWrite = record
    Addr: Cardinal;   // VRAM offset
    Old: Cardinal;    // the bytes the pixel replaced
    Bytes: Integer;
    Visible: Int64;   // the cycle from which memory holds the pixel
  end;

  TGETexCacheBlock = array[0..127] of Byte;

  TGETexCache = record
    Epoch: Cardinal;
    // Open addressing by block address: the address plus 1, 0 free.
    Keys: array of Cardinal;
    Blocks: array of TGETexCacheBlock;
    Used: Integer;
    Clock: Int64;
    // The pixels memory may not hold yet, oldest first (a ring), the last
    // Open of them those of the 4 pixels being drawn (GroupX, GroupY).
    Log: array[0..127] of TGETexCacheWrite;
    LogHead, LogCount, Open: Integer;
    GroupX, GroupY: Integer;
    VRAM: PByte;
    // The pixel pipeline the cache's runs around (PSP.GE.Raster's).
    Plot: Pointer;
  end;

  PGETexCache = ^TGETexCache;

  // A texture's level 0 sampled at (S, TT) in texels (GEPrepareSampler).
  TGESampler = function(T: PGETexture; S, TT: Single): Cardinal;

  TGETexture = record
    Memory: TPSPMemory;
    Format: Integer;
    Swizzle: Boolean;
    Levels: array[0..7] of TGETexLevel;
    LevelCount: Integer;
    Level: Integer;
    ClampU, ClampV: Boolean;
    // The magnification filter (and the only one when NeedLod is off).
    Linear: Boolean;
    // Level of detail: the minification filter (TEXFILTER's 0-7), the
    // highest level, TEXLEVEL's mode and bias (1/16 levels), TEXLODSLOPE.
    // NeedLod: the level or the filter depends on it.
    MinFilter, MaxLevel, LevelMode, LodBias: Integer;
    Slope: Single;
    NeedLod: Boolean;
    // CLUT cache as loaded, and the index transform.
    Clut: PByte;
    ClutFormat, ClutShift, ClutMask, ClutOffset: Integer;
    // Formats 4 and 5 (GEPreparePalette): the colour of every index such a
    // texel can hold, through the index transform and the CLUT as it was
    // then. While PalValid is False the sampler reads the CLUT itself.
    PalValid: Boolean;
    Pal: array[0..255] of Cardinal;
    // GEPrepareSampler: the sampler for this texture's format and filter
    // when its level 0 holds all its texels and no level of detail applies
    // (nil: GESampleTexture).
    Sampler: TGESampler;
    // Set when the texture lies in the pixels drawn: formats 0-7 read
    // through it (blocks loaded before the TEXFLUSH count CacheEpoch are
    // gone).
    Cache: PGETexCache;
    CacheEpoch: Cardinal;
  end;

function GESampleTexture(const T: TGETexture; S, TT: Single): Cardinal;
// With the level of detail Lod (1/16 levels, bias included).

function GESampleTextureLod(const T: TGETexture; S, TT: Single; Lod: Integer): Cardinal;
// log2 as the GE takes it: the exponent and 4 bits of mantissa, in 1/16.

function GELog16(V: Single): Integer;

function GEFetchTexel(const T: TGETexture; Level, X, Y: Integer): Cardinal;

type
  TGEDXTBlock = array[0..15] of Cardinal;

  PGEDXTBlock = ^TGEDXTBlock;

// False for noncontiguous or partial source blocks: retain scalar fault semantics.
function GEReadDXTBlock(const T: TGETexture; Level, BX, BY: Integer; out Colors: TGEDXTBlock): Boolean;

function GEDecode16(Format: Integer; P: Cardinal): Cardinal;

// One past the furthest byte from a level's start the sampler may read
// (texel coordinates are wrapped or clamped into the level).
function GELevelReach(const T: TGETexture; const L: TGETexLevel): UInt64;

// Sets L.Fits.
procedure GEFitLevel(const T: TGETexture; var L: TGETexLevel);

// Fills Pal from the CLUT and the index transform for formats 4 and 5 (sets
// PalValid; other formats leave it False).
procedure GEPreparePalette(var T: TGETexture);

// Sets Sampler from the format, the filter, level 0's Fits and PalValid.
procedure GEPrepareSampler(var T: TGETexture);

// A primitive starts: blocks loaded before the TEXFLUSH count Epoch go, what
// earlier ones wrote is in memory.
procedure GETexCacheStart(var C: TGETexCache; Epoch: Cardinal; VRAM: PByte);

// The pixel in row Y, column X, at VRAM offset Addr (Bytes long), is about
// to be drawn; then the clock passes it (C.Clock goes up by one).
procedure GETexCachePixel(var C: TGETexCache; Addr: Cardinal; Bytes, X, Y: Integer);

const
  GETexCacheMiss = 24;
  GETexCacheDelay = 38;

var
  // Tests: every texel through the general fetch, the reference for the
  // sampler's fast path.
  GEGenericTexels: Boolean;

implementation

const
  // Bits a texel by texture format (DXT by their blocks).
  TexBits: array[0..15] of Integer = (16, 16, 16, 32, 4, 8, 16, 32, 4, 8, 8, 0, 0, 0, 0, 0);

function GELevelReach(const T: TGETexture; const L: TGETexLevel): UInt64;
begin
  var Bits := TexBits[T.Format and 15];
  var W := UInt64(Max(L.Width, 1));
  var H := UInt64(Max(L.Height, 1));
  var BW := UInt64(Max(L.BufWidth, 0));
  if T.Format >= 8 then
  begin
    var BlockBytes: UInt64 := 16;
    if T.Format = 8 then
      BlockBytes := 8;
    Result := (((H - 1) shr 2) * (BW div 4) + ((W - 1) shr 2)) * BlockBytes + BlockBytes;
  end
  else
  begin
    var RowBytes := (BW * UInt64(Bits)) div 8;
    var LastByte := ((W - 1) * UInt64(Bits)) div 8;
    if T.Swizzle then
      Result := ((((H - 1) shr 3) * (RowBytes shr 4) + (LastByte shr 4)) shl 7) + 128
    else
      Result := (H - 1) * RowBytes + LastByte + UInt64(Max(1, Bits div 8));
  end;
end;

procedure GEFitLevel(const T: TGETexture; var L: TGETexLevel);
begin
  L.Fits := (L.Ptr <> nil) and (T.Format <= 7) and (L.Width > 0) and (L.Height > 0) and (L.BufWidth >= 0) and
    (GELevelReach(T, L) <= L.Size);
end;

function Decode16(Format: Integer; Texel: Cardinal): Cardinal; inline;
begin
  // Read once: the inliner would evaluate an argument expression at every use.
  var P := Texel;
  case Format of
    0:
      begin
        var R := P and $1F;
        var G := (P shr 5) and $3F;
        var B := (P shr 11) and $1F;
        Result := $FF000000 or ((R shl 3) or (R shr 2)) or (((G shl 2) or (G shr 4)) shl 8) or
          (((B shl 3) or (B shr 2)) shl 16);
      end;
    1:
      begin
        var R := P and $1F;
        var G := (P shr 5) and $1F;
        var B := (P shr 10) and $1F;
        Result := ((R shl 3) or (R shr 2)) or (((G shl 3) or (G shr 2)) shl 8) or (((B shl 3) or (B shr 2)) shl 16);
        if (P and $8000) <> 0 then
          Result := Result or $FF000000;
      end;
  else
    begin
      var R := P and $F;
      var G := (P shr 4) and $F;
      var B := (P shr 8) and $F;
      var A := (P shr 12) and $F;
      Result := (R * 17) or ((G * 17) shl 8) or ((B * 17) shl 16) or ((A * 17) shl 24);
    end;
  end;
end;

function GEDecode16(Format: Integer; P: Cardinal): Cardinal;
begin
  Result := Decode16(Format, P);
end;

function ClutLookup(const T: TGETexture; Index: Cardinal; Add: Integer = 0): Cardinal; inline;
begin
  var I := (((Index shr T.ClutShift) and Cardinal(T.ClutMask)) or (Cardinal(T.ClutOffset) and $1FF)) + Cardinal(Add);
  if T.ClutFormat = 3 then
    Result := PCardinal(T.Clut + (I and $FF) * 4)^
  else
    Result := Decode16(T.ClutFormat, PWord(T.Clut + (I and $1FF) * 2)^);
end;

procedure GEPreparePalette(var T: TGETexture);
begin
  T.PalValid := False;
  var N := 0;
  case T.Format of
    4:
      N := 16;
    5:
      N := 256;
  end;
  if (N = 0) or (T.Clut = nil) then
    Exit;
  for var I := 0 to N - 1 do
    T.Pal[I] := ClutLookup(T, Cardinal(I));
  T.PalValid := True;
end;

// A CLUT4/CLUT8 texel's colour: Pal holds ClutLookup of every such index
// (level 0's).
function PalLookup(const T: TGETexture; Index: Cardinal; Add: Integer): Cardinal; inline;
begin
  if T.PalValid and (Add = 0) then
    Result := T.Pal[Index]
  else
    Result := ClutLookup(T, Index, Add);
end;

// Byte offset of texel (X, Y) for a format of Bits per texel, swizzled or linear.
function TexelOffset(const T: TGETexture; const L: TGETexLevel; X, Y, Bits: Integer): Cardinal; inline;
begin
  var RowBytes := (L.BufWidth * Bits) div 8;
  var ByteX := (X * Bits) div 8;
  if T.Swizzle then
  begin
    // 16-byte by 8-row blocks laid out left to right, then down.
    var BlockX := ByteX shr 4;
    var BlockY := Y shr 3;
    var BlocksPerRow := RowBytes shr 4;
    Result := Cardinal(((BlockY * BlocksPerRow + BlockX) shl 7) + ((Y and 7) shl 4) + (ByteX and 15));
  end
  else
    Result := Cardinal(Y * RowBytes + ByteX);
end;

// A DXT colour block's texel. The end colours widen to 8 bits without
// repeating their top bits; when the first is not greater, the block has
// three colours and index 3 is transparent black (DXT3/5 take the alpha from
// their own data).
function DXTColor(C0, C1: Cardinal; Index: Integer): Cardinal;

  procedure Split(C: Cardinal; out R, G, B: Integer);
  begin
    R := ((C shr 11) and $1F) shl 3;
    G := ((C shr 5) and $3F) shl 2;
    B := (C and $1F) shl 3;
  end;

var
  R0, G0, B0, R1, G1, B1: Integer;
begin
  Split(C0, R0, G0, B0);
  Split(C1, R1, G1, B1);
  case Index of
    0:
      Result := Cardinal(R0) or (Cardinal(G0) shl 8) or (Cardinal(B0) shl 16) or $FF000000;
    1:
      Result := Cardinal(R1) or (Cardinal(G1) shl 8) or (Cardinal(B1) shl 16) or $FF000000;
    2:
      if C0 > C1 then
        Result := Cardinal((2 * R0 + R1) div 3) or (Cardinal((2 * G0 + G1) div 3) shl 8) or (Cardinal((2 * B0 + B1) div
            3) shl 16) or $FF000000
      else
        Result := Cardinal((R0 + R1) div 2) or (Cardinal((G0 + G1) div 2) shl 8) or (Cardinal((B0 + B1) div
            2) shl 16) or $FF000000;
  else
    if C0 > C1 then
      Result := Cardinal((R0 + 2 * R1) div 3) or (Cardinal((G0 + 2 * G1) div 3) shl 8) or (Cardinal((B0 + 2 * B1) div
          3) shl 16) or $FF000000
    else
      Result := 0;
  end;
end;

function TexR8(const L: TGETexLevel; M: TPSPMemory; Off: Cardinal): Cardinal; inline;
begin
  if (L.Ptr <> nil) and (Off < L.Size) then
    Result := L.Ptr[Off]
  else
    Result := M.Read8(L.Addr + Off);
end;

function TexR16(const L: TGETexLevel; M: TPSPMemory; Off: Cardinal): Cardinal; inline;
begin
  if (L.Ptr <> nil) and (Off + 2 <= L.Size) then
    Result := PWord(L.Ptr + Off)^
  else
    Result := M.Read16(L.Addr + Off);
end;

function TexR32(const L: TGETexLevel; M: TPSPMemory; Off: Cardinal): Cardinal; inline;
begin
  if (L.Ptr <> nil) and (Off + 4 <= L.Size) then
    Result := PCardinal(L.Ptr + Off)^
  else
    Result := M.Read32(L.Addr + Off);
end;

function FetchTexel(const T: TGETexture; L: PGETexLevel; X, Y: Integer): Cardinal; forward;

procedure GETexCacheStart(var C: TGETexCache; Epoch: Cardinal; VRAM: PByte);
begin
  if (C.Epoch <> Epoch) and (C.Used > 0) then
  begin
    FillChar(C.Keys[0], Length(C.Keys) * SizeOf(Cardinal), 0);
    C.Used := 0;
  end;
  C.Epoch := Epoch;
  C.LogHead := 0;
  C.LogCount := 0;
  C.Open := 0;
  C.VRAM := VRAM;
end;

procedure GETexCachePixel(var C: TGETexCache; Addr: Cardinal; Bytes, X, Y: Integer);
begin
  if (C.Open > 0) and ((Y <> C.GroupY) or ((X shr 2) <> C.GroupX)) then
  begin
    // The last pixel was a cycle ago.
    for var K := 1 to C.Open do
      C.Log[(C.LogHead + C.LogCount - K) and High(C.Log)].Visible := C.Clock - 1 + GETexCacheDelay;
    C.Open := 0;
  end;
  while (C.LogCount > C.Open) and (C.Log[C.LogHead].Visible <= C.Clock) do
  begin
    C.LogHead := (C.LogHead + 1) and High(C.Log);
    Dec(C.LogCount);
  end;
  if C.LogCount = Length(C.Log) then
  begin
    C.LogHead := (C.LogHead + 1) and High(C.Log);
    Dec(C.LogCount);
    if C.Open > C.LogCount then
      C.Open := C.LogCount;
  end;
  var E: ^TGETexCacheWrite := @C.Log[(C.LogHead + C.LogCount) and High(C.Log)];
  Inc(C.LogCount);
  Inc(C.Open);
  C.GroupX := X shr 2;
  C.GroupY := Y;
  E.Addr := Addr;
  E.Bytes := Bytes;
  if Bytes = 4 then
    E.Old := PCardinal(C.VRAM + Addr)^
  else
    E.Old := PWord(C.VRAM + Addr)^;
  E.Visible := High(Int64);
end;

// The block at BlockOff in level L (RowBytes a row), loaded if it is not:
// from memory as it is, but for the pixels it does not hold yet.
function CacheBlock(const T: TGETexture; L: PGETexLevel; BlockOff: Cardinal; RowBytes: Integer): PByte;
begin
  var C := T.Cache;
  if C.Keys = nil then
  begin
    SetLength(C.Keys, 1024);
    SetLength(C.Blocks, 1024);
  end;
  var Key := L.Addr + BlockOff;
  var Mask := Length(C.Keys) - 1;
  var H := Integer(((UInt64(Key shr 4) * 2654435761) and $FFFFFFFF) shr 22) and Mask;
  while C.Keys[H] <> 0 do
  begin
    if C.Keys[H] = Key + 1 then
      Exit(@C.Blocks[H][0]);
    H := (H + 1) and Mask;
  end;
  if C.Used >= Length(C.Keys) * 3 div 4 then
  begin
    FillChar(C.Keys[0], Length(C.Keys) * SizeOf(Cardinal), 0);
    C.Used := 0;
    H := Integer(((UInt64(Key shr 4) * 2654435761) and $FFFFFFFF) shr 22) and Mask;
  end;
  C.Keys[H] := Key + 1;
  Inc(C.Used);
  Result := @C.Blocks[H][0];
  for var R := 0 to 7 do
  begin
    var RowOff: Cardinal;
    if T.Swizzle then
      RowOff := BlockOff + Cardinal(R * 16)
    else
      RowOff := BlockOff + Cardinal(R * RowBytes);
    for var B := 0 to 15 do
    begin
      var Off := RowOff + Cardinal(B);
      if (L.Ptr <> nil) and (Off < L.Size) then
        Result[R * 16 + B] := L.Ptr[Off]
      else
        Result[R * 16 + B] := T.Memory.Read8(L.Addr + Off);
    end;
  end;
  // Pixels memory does not hold yet keep their old bytes, the oldest's.
  if (Key and $0F800000) = PSPVRAMBase then
  begin
    var VBlock := Int64(Key and (PSPVRAMSize - 1));
    for var I := C.LogCount - 1 downto 0 do
    begin
      var E: ^TGETexCacheWrite := @C.Log[(C.LogHead + I) and High(C.Log)];
      if E.Visible <= C.Clock then
        Continue;
      for var K := 0 to E.Bytes - 1 do
      begin
        var D := Int64(E.Addr) + K - VBlock;
        if D < 0 then
          Continue;
        var At := -1;
        if T.Swizzle then
        begin
          if D < 128 then
            At := Integer(D);
        end
        else if (D div RowBytes < 8) and (D mod RowBytes < 16) then
          At := Integer(D div RowBytes) * 16 + Integer(D mod RowBytes);
        if At >= 0 then
          Result[At] := Byte(E.Old shr (8 * K));
      end;
    end;
  end;
  Inc(C.Clock, GETexCacheMiss);
end;

// FetchTexel through the texture cache (formats 0-7).
function CacheTexel(const T: TGETexture; L: PGETexLevel; X, Y: Integer): Cardinal;
begin
  var Bits := TexBits[T.Format];
  var RowBytes := (L.BufWidth * Bits) div 8;
  var ByteX := (X * Bits) div 8;
  var BlockOff: Cardinal;
  if T.Swizzle then
    BlockOff := Cardinal(((Y shr 3) * (RowBytes shr 4) + (ByteX shr 4)) shl 7)
  else
    BlockOff := Cardinal((Y and not 7) * RowBytes + (ByteX and not 15));
  var P := CacheBlock(T, L, BlockOff, Max(RowBytes, 1)) + (Y and 7) * 16 + (ByteX and 15);
  case T.Format of
    0, 1, 2:
      Result := Decode16(T.Format, PWord(P)^);
    3:
      Result := PCardinal(P)^;
    4:
      begin
        var B := Cardinal(P^);
        if (X and 1) <> 0 then
          B := B shr 4
        else
          B := B and $F;
        Result := ClutLookup(T, B, L.ClutAdd);
      end;
    5:
      Result := ClutLookup(T, P^, L.ClutAdd);
    6:
      Result := ClutLookup(T, PWord(P)^, L.ClutAdd);
  else
    Result := ClutLookup(T, PCardinal(P)^, L.ClutAdd);
  end;
end;

function GEFetchTexel(const T: TGETexture; Level, X, Y: Integer): Cardinal;
begin
  Result := FetchTexel(T, @T.Levels[Level], X, Y);
end;

// The common formats from a level's contiguous bytes, inline in the sampler.
function FastTexel(const T: TGETexture; L: PGETexLevel; X, Y: Integer): Cardinal; inline;
begin
  if (L.Ptr <> nil) and (T.Format <= 7) then
  begin
    var Bits := 16;
    case T.Format of
      3, 7:
        Bits := 32;
      4:
        Bits := 4;
      5:
        Bits := 8;
    end;
    var Off := TexelOffset(T, L^, X, Y, Bits);
    if Off + Cardinal(Max(1, Bits shr 3)) <= L.Size then
      case T.Format of
        0, 1, 2:
          Exit(Decode16(T.Format, PWord(L.Ptr + Off)^));
        3:
          Exit(PCardinal(L.Ptr + Off)^);
        4:
          begin
            var B := Cardinal(L.Ptr[Off]);
            if (X and 1) <> 0 then
              B := B shr 4
            else
              B := B and $F;
            Exit(PalLookup(T, B, L.ClutAdd));
          end;
        5:
          Exit(PalLookup(T, L.Ptr[Off], L.ClutAdd));
        6:
          Exit(ClutLookup(T, PWord(L.Ptr + Off)^, L.ClutAdd));
      else
        Exit(ClutLookup(T, PCardinal(L.Ptr + Off)^, L.ClutAdd));
      end;
  end;
  Result := FetchTexel(T, L, X, Y);
end;

type
  TGEDXTLast = record
    Valid: Boolean;
    Format: Integer;
    Low, High: UInt64;
    Colors: TGEDXTBlock;
  end;

threadvar
  DXTEntries: array[0..255] of TGEDXTLast;

function ReadDXT(const T: TGETexture; L: PGETexLevel; BX, BY: Integer): PGEDXTBlock;
var
  Words: array[0..3] of Cardinal;
  Palette: array[0..3] of Cardinal;
  Alpha: array[0..7] of Cardinal;
begin
  Result := nil;
  if not (T.Format in [8, 9, 10]) or (L.Ptr = nil) or (BX < 0) or (BY < 0) then
    Exit;
  var Bytes := 16;
  if T.Format = 8 then
    Bytes := 8;
  var Offset := UInt64(Cardinal(BY)) * Cardinal(L.BufWidth div 4) + Cardinal(BX);
  Offset := Offset * Cardinal(Bytes);
  if Offset + Cardinal(Bytes) > L.Size then
    Exit;
  var Source := L.Ptr + NativeInt(Offset);
  var Shift := 4;
  if Bytes = 8 then
    Shift := 3;
  var Index := ((NativeUInt(Source) shr Shift) xor (NativeUInt(Source) shr 12)) and 255;
  var Cached: ^TGEDXTLast := @DXTEntries[Index];
  var Low := PUInt64(Source)^;
  var High: UInt64 := 0;
  if Bytes = 16 then
    High := PUInt64(Source + 8)^;
  // Validate compressed bytes on every access, including texture feedback;
  // no invalidation hook or persistent decoded copy of mutable VRAM is needed.
  if not Cached.Valid or (Cached.Format <> T.Format) or (Cached.Low <> Low) or (Cached.High <> High) then
  begin
    Words[0] := Cardinal(Low);
    Words[1] := Cardinal(Low shr 32);
    Words[2] := Cardinal(High);
    Words[3] := Cardinal(High shr 32);
    var C0 := Words[1] and $FFFF;
    var C1 := Words[1] shr 16;
    for var I := 0 to 3 do
      Palette[I] := DXTColor(C0, C1, I);
    var A0 := Words[3] shr 16 and $FF;
    var A1 := Words[3] shr 24;
    if T.Format = 10 then
    begin
      Alpha[0] := A0;
      Alpha[1] := A1;
      if A0 > A1 then
        for var I := 2 to 7 do
          Alpha[I] := ((8 - Cardinal(I)) * A0 + (Cardinal(I) - 1) * A1) div 7
      else
      begin
        for var I := 2 to 5 do
          Alpha[I] := ((6 - Cardinal(I)) * A0 + (Cardinal(I) - 1) * A1) div 5;
        Alpha[6] := 0;
        Alpha[7] := 255;
      end;
    end;
    var AlphaBits := UInt64(Words[2]) or (UInt64(Words[3] and $FFFF) shl 32);
    for var I := 0 to 15 do
    begin
      var Color := Palette[(Words[0] shr (I * 2)) and 3];
      if T.Format = 9 then
      begin
        var A := (Words[2 + I div 8] shr ((I and 7) * 4)) and $F;
        Color := (Color and $FFFFFF) or (A shl 28);
      end
      else if T.Format = 10 then
        Color := (Color and $FFFFFF) or (Alpha[(AlphaBits shr (I * 3)) and 7] shl 24);
      Cached.Colors[I] := Color;
    end;
    Cached.Low := Low;
    Cached.High := High;
    Cached.Format := T.Format;
    Cached.Valid := True;
  end;
  Result := @Cached.Colors;
end;

function GEReadDXTBlock(const T: TGETexture; Level, BX, BY: Integer; out Colors: TGEDXTBlock): Boolean;
begin
  var P := ReadDXT(T, @T.Levels[Level], BX, BY);
  Result := P <> nil;
  if Result then
    Colors := P^;
end;

function FetchTexel(const T: TGETexture; L: PGETexLevel; X, Y: Integer): Cardinal;
begin
  if (T.Cache <> nil) and (T.Format <= 7) then
    Exit(CacheTexel(T, L, X, Y));
  var M := T.Memory;
  case T.Format of
    0, 1, 2:
      Result := Decode16(T.Format, TexR16(L^, M, TexelOffset(T, L^, X, Y, 16)));
    3:
      Result := TexR32(L^, M, TexelOffset(T, L^, X, Y, 32));
    4:
      begin
        var B := TexR8(L^, M, TexelOffset(T, L^, X, Y, 4));
        if (X and 1) <> 0 then
          B := B shr 4
        else
          B := B and $F;
        Result := ClutLookup(T, B, L.ClutAdd);
      end;
    5:
      Result := ClutLookup(T, TexR8(L^, M, TexelOffset(T, L^, X, Y, 8)), L.ClutAdd);
    6:
      Result := ClutLookup(T, TexR16(L^, M, TexelOffset(T, L^, X, Y, 16)), L.ClutAdd);
    7:
      Result := ClutLookup(T, TexR32(L^, M, TexelOffset(T, L^, X, Y, 32)), L.ClutAdd);
    8, 9, 10:
      begin
        var Colors := ReadDXT(T, L, X shr 2, Y shr 2);
        if Colors <> nil then
          Exit(Colors[(Y and 3) * 4 + (X and 3)]);
        // 4x4 blocks in rows of BufWidth/4 blocks: the colour block (indices,
        // then the two colours), and for DXT3/5 the alpha data after it.
        var BlockBytes := 16;
        if T.Format = 8 then
          BlockBytes := 8;
        var BlocksPerRow := L.BufWidth div 4;
        var Block := Cardinal(((Y shr 2) * BlocksPerRow + (X shr 2)) * BlockBytes);
        var Bits := TexR32(L^, M, Block);
        var C0 := TexR16(L^, M, Block + 4);
        var C1 := TexR16(L^, M, Block + 6);
        var Pixel := (Y and 3) * 4 + (X and 3);
        Result := DXTColor(C0, C1, (Bits shr (Pixel * 2)) and 3);
        if T.Format = 9 then
        begin
          // 4 bits a texel, a row in 16 bits; widened without repeating.
          var AW := TexR16(L^, M, Block + 8 + Cardinal((Y and 3) * 2));
          var A := (AW shr ((X and 3) * 4)) and $F;
          Result := (Result and $FFFFFF) or ((A shl 4) shl 24);
        end
        else if T.Format = 10 then
        begin
          // 48 bits of 3-bit indices, then the two end alphas.
          var ABits := UInt64(TexR32(L^, M, Block + 8)) or (UInt64(TexR16(L^, M, Block + 12)) shl 32);
          var A0 := TexR8(L^, M, Block + 14);
          var A1 := TexR8(L^, M, Block + 15);
          var AI := (ABits shr (Pixel * 3)) and 7;
          var A: Cardinal;
          if A0 > A1 then
            case AI of
              0:
                A := A0;
              1:
                A := A1;
            else
              A := ((8 - AI) * A0 + (AI - 1) * A1) div 7;
            end
          else
            case AI of
              0:
                A := A0;
              1:
                A := A1;
              6:
                A := 0;
              7:
                A := 255;
            else
              A := ((6 - AI) * A0 + (AI - 1) * A1) div 5;
            end;
          Result := (Result and $FFFFFF) or (A shl 24);
        end;
      end;
  else
    Result := 0;
  end;
end;

// Floor() also calls Frac(). For ordinary texture coordinates a truncation
// and signed comparison are equivalent; retain its exceptional/range rules.
function TexFloor(X: Single): Integer; inline;
begin
  if (PCardinal(@X)^ and $7F800000) >= $4F000000 then
    Exit(Floor(X));
  Result := Trunc(X);
  if X < Result then
    Dec(Result);
end;

function WrapCoord(V, Size: Integer; Clamp: Boolean): Integer; inline;
begin
  // V is read once (the inliner would evaluate an expression at every use).
  Result := V;
  if Clamp then
  begin
    if Result < 0 then
      Result := 0
    else if Result >= Size then
      Result := Size - 1;
  end
  else
    Result := Result and (Size - 1);
end;

// TexFloor(S) from the bits of S where that is simple: for S in [0, 2^23)
// floor(S) is the significand shifted by the exponent.
function NearestCoord(S: Single): Integer; inline;
begin
  var B := PCardinal(@S)^;
  if B < $3F800000 then
    Result := 0
  else if B < $4B000000 then
    Result := Integer(((B and $7FFFFF) or $800000) shr (150 - (B shr 23)))
  else
    Result := TexFloor(S);
end;

// The bilinear filter's first texel X0 = TexFloor(S - 0.5) and its 4-bit
// weight Frac = Trunc((S - 0.5 - X0) * 16) (an Int64, as Trunc gives it). For S in [0.5, 2^22) S - 0.5 is
// exact in single precision and the two are floor(16 * S) - 8 split into
// whole texels and sixteenths, from the bits of S; elsewhere as stated.
procedure LinearCoord(S: Single; out X0: Integer; out Frac: Int64); inline;
begin
  var B := PCardinal(@S)^;
  if (B >= $3F000000) and (B < $4A800000) then
  begin
    var R := Integer((((B and $7FFFFF) or $800000) shl 2) shr (148 - (B shr 23))) - 8;
    X0 := R shr 4;
    Frac := R and 15;
  end
  else
  begin
    var FS := S - 0.5;
    X0 := TexFloor(FS);
    Frac := Trunc((FS - X0) * 16);
  end;
end;

// A texel of a level holding all its texels: its byte offset (as TexelOffset,
// for non-negative coordinates) and its colour (as FetchTexel, formats 0-7).
function FitOffset(Swizzle: Boolean; RowBytes, Bits, X, Y: Integer): Cardinal; inline;
begin
  var ByteX := (X * Bits) shr 3;
  if Swizzle then
    Result := Cardinal((((Y shr 3) * (RowBytes shr 4) + (ByteX shr 4)) shl 7) + ((Y and 7) shl 4) + (ByteX and 15))
  else
    Result := Cardinal(Y * RowBytes + ByteX);
end;

// FitOffset split into the part of the row and the part of the byte column:
// the offset is their sum.
function FitRow(Swizzle: Boolean; RowBytes, Row: Integer): Integer; inline;
begin
  var Y := Row;
  if Swizzle then
    Result := (((Y shr 3) * (RowBytes shr 4)) shl 7) + ((Y and 7) shl 4)
  else
    Result := Y * RowBytes;
end;

function FitColumn(Swizzle: Boolean; Column: Integer): Integer; inline;
begin
  var ByteX := Column;
  if Swizzle then
    Result := ((ByteX shr 4) shl 7) + (ByteX and 15)
  else
    Result := ByteX;
end;

function FitTexel(const T: TGETexture; P: PByte; Off: Cardinal; X, Add: Integer): Cardinal; inline;
begin
  case T.Format of
    0, 1, 2:
      Result := Decode16(T.Format, PWord(P + Off)^);
    3:
      Result := PCardinal(P + Off)^;
    4:
      begin
        var B := Cardinal(P[Off]);
        if (X and 1) <> 0 then
          B := B shr 4
        else
          B := B and $F;
        Result := PalLookup(T, B, Add);
      end;
    5:
      Result := PalLookup(T, P[Off], Add);
    6:
      Result := ClutLookup(T, PWord(P + Off)^, Add);
  else
    Result := ClutLookup(T, PCardinal(P + Off)^, Add);
  end;
end;

// A CLUT4 texel: the low nibble for even X, the high one for odd.
function Nibble(B: Cardinal; X: Integer): Cardinal; inline;
begin
  if (X and 1) <> 0 then
    Result := B shr 4
  else
    Result := B and $F;
end;

// The bilinear mix of four texels with 4-bit weights, every channel
// (Top * (16 - FracY) + Bottom * FracY) shr 4 with Top and Bottom mixed by
// FracX and shifted right by 4 first (recorded on a PSP-E1000: the rows are
// truncated before the column mix). With weights in 0..16 two channels at a
// time fit 16-bit lanes of a 32-bit word (at most 255 * 16), so the lanes
// give the per channel result exactly.
function BilerpPacked(T00, T10, T01, T11, FracX, FracY: Cardinal): Cardinal; inline;
begin
  var C00 := T00;
  var C10 := T10;
  var C01 := T01;
  var C11 := T11;
  var FX := FracX;
  var IX := 16 - FX;
  var FY := FracY;
  var IY := 16 - FY;
  var TopRB := (((C00 and $00FF00FF) * IX + (C10 and $00FF00FF) * FX) shr 4) and $00FF00FF;
  var BotRB := (((C01 and $00FF00FF) * IX + (C11 and $00FF00FF) * FX) shr 4) and $00FF00FF;
  var TopGA := ((((C00 shr 8) and $00FF00FF) * IX + ((C10 shr 8) and $00FF00FF) * FX) shr 4) and $00FF00FF;
  var BotGA := ((((C01 shr 8) and $00FF00FF) * IX + ((C11 shr 8) and $00FF00FF) * FX) shr 4) and $00FF00FF;
  Result := (((TopRB * IY + BotRB * FY) shr 4) and $00FF00FF) or (((TopGA * IY + BotGA * FY) shl 4) and $FF00FF00);
end;

function Bilerp(T00, T10, T01, T11: Cardinal; FracX, FracY: Int64): Cardinal; inline;
begin
  var C00 := T00;
  var C10 := T10;
  var C01 := T01;
  var C11 := T11;
  if (UInt64(FracX) <= 16) and (UInt64(FracY) <= 16) then
    Exit(BilerpPacked(C00, C10, C01, C11, Cardinal(FracX), Cardinal(FracY)));
  Result := 0;
  for var Sh := 0 to 3 do
  begin
    var Shift := Sh * 8;
    var A := Integer((C00 shr Shift) and $FF);
    var B := Integer((C10 shr Shift) and $FF);
    var C := Integer((C01 shr Shift) and $FF);
    var D := Integer((C11 shr Shift) and $FF);
    var Top := (A * (16 - FracX) + B * FracX) shr 4;
    var Bottom := (C * (16 - FracX) + D * FracX) shr 4;
    var V := (Top * (16 - FracY) + Bottom * FracY) shr 4;
    Result := Result or (Cardinal(V) shl Shift);
  end;
end;

// The reference sampler (GEGenericTexels): every texel through FetchTexel,
// the CLUT itself, channel by channel.
function SampleGeneric(const T: TGETexture; L: PGETexLevel; S, TT: Single; Linear: Boolean): Cardinal;
begin
  if not Linear then
  begin
    var X := WrapCoord(TexFloor(S), L.Width, T.ClampU);
    var Y := WrapCoord(TexFloor(TT), L.Height, T.ClampV);
    Exit(FetchTexel(T, L, X, Y));
  end;
  var FS := S - 0.5;
  var FT := TT - 0.5;
  var X0 := TexFloor(FS);
  var Y0 := TexFloor(FT);
  var FracX := Trunc((FS - X0) * 16);
  var FracY := Trunc((FT - Y0) * 16);
  var XA := WrapCoord(X0, L.Width, T.ClampU);
  var XB := WrapCoord(X0 + 1, L.Width, T.ClampU);
  var YA := WrapCoord(Y0, L.Height, T.ClampV);
  var YB := WrapCoord(Y0 + 1, L.Height, T.ClampV);
  var C00 := FetchTexel(T, L, XA, YA);
  var C10 := FetchTexel(T, L, XB, YA);
  var C01 := FetchTexel(T, L, XA, YB);
  var C11 := FetchTexel(T, L, XB, YB);
  Result := 0;
  for var Sh := 0 to 3 do
  begin
    var Shift := Sh * 8;
    var A := Integer((C00 shr Shift) and $FF);
    var B := Integer((C10 shr Shift) and $FF);
    var C := Integer((C01 shr Shift) and $FF);
    var D := Integer((C11 shr Shift) and $FF);
    var Top := (A * (16 - FracX) + B * FracX) shr 4;
    var Bottom := (C * (16 - FracX) + D * FracX) shr 4;
    var V := (Top * (16 - FracY) + Bottom * FracY) shr 4;
    Result := Result or (Cardinal(V) shl Shift);
  end;
end;

// A texel of one level, nearest or bilinear (4-bit weights); S and TT are
// in texels of that level. Levels that hold all their texels read them
// straight from their bytes, by format; CLUT4/8 through the palette.
function SampleLevel(const T: TGETexture; Level: Integer; S, TT: Single; Linear: Boolean): Cardinal;
begin
  var L: PGETexLevel := @T.Levels[Level];
  if GEGenericTexels or (T.Cache <> nil) then
    Exit(SampleGeneric(T, L, S, TT, Linear));
  if L.Fits then
  begin
    var Bits := TexBits[T.Format];
    var RowBytes := (L.BufWidth * Bits) shr 3;
    var P := L.Ptr;
    var Sw := T.Swizzle;
    // The palette is level 0's CLUT.
    var Pal := T.PalValid and (L.ClutAdd = 0);
    if not Linear then
    begin
      var X := WrapCoord(NearestCoord(S), L.Width, T.ClampU);
      var Y := WrapCoord(NearestCoord(TT), L.Height, T.ClampV);
      var Off := FitOffset(Sw, RowBytes, Bits, X, Y);
      case T.Format of
        3:
          Exit(PCardinal(P + Off)^);
        4:
          if Pal then
            Exit(T.Pal[Nibble(P[Off], X)]);
        5:
          if Pal then
            Exit(T.Pal[P[Off]]);
      end;
      Exit(FitTexel(T, P, Off, X, L.ClutAdd));
    end;
    var X0, Y0: Integer;
    var FracX, FracY: Int64;
    LinearCoord(S, X0, FracX);
    LinearCoord(TT, Y0, FracY);
    var XA := WrapCoord(X0, L.Width, T.ClampU);
    var XB := WrapCoord(X0 + 1, L.Width, T.ClampU);
    var YA := WrapCoord(Y0, L.Height, T.ClampV);
    var YB := WrapCoord(Y0 + 1, L.Height, T.ClampV);
    var RA := FitRow(Sw, RowBytes, YA);
    var RB := FitRow(Sw, RowBytes, YB);
    var C00, C10, C01, C11: Cardinal;
    case T.Format of
      4:
        if Pal then
        begin
          var CA := FitColumn(Sw, XA shr 1);
          var CB := FitColumn(Sw, XB shr 1);
          C00 := T.Pal[Nibble(P[RA + CA], XA)];
          C10 := T.Pal[Nibble(P[RA + CB], XB)];
          C01 := T.Pal[Nibble(P[RB + CA], XA)];
          C11 := T.Pal[Nibble(P[RB + CB], XB)];
          Exit(Bilerp(C00, C10, C01, C11, FracX, FracY));
        end;
      5:
        if Pal then
        begin
          var CA := FitColumn(Sw, XA);
          var CB := FitColumn(Sw, XB);
          C00 := T.Pal[P[RA + CA]];
          C10 := T.Pal[P[RA + CB]];
          C01 := T.Pal[P[RB + CA]];
          C11 := T.Pal[P[RB + CB]];
          Exit(Bilerp(C00, C10, C01, C11, FracX, FracY));
        end;
      3:
        begin
          var CA := FitColumn(Sw, XA * 4);
          var CB := FitColumn(Sw, XB * 4);
          C00 := PCardinal(P + RA + CA)^;
          C10 := PCardinal(P + RA + CB)^;
          C01 := PCardinal(P + RB + CA)^;
          C11 := PCardinal(P + RB + CB)^;
          Exit(Bilerp(C00, C10, C01, C11, FracX, FracY));
        end;
      0, 1, 2:
        begin
          var F := T.Format;
          var CA := FitColumn(Sw, XA * 2);
          var CB := FitColumn(Sw, XB * 2);
          C00 := Decode16(F, PWord(P + RA + CA)^);
          C10 := Decode16(F, PWord(P + RA + CB)^);
          C01 := Decode16(F, PWord(P + RB + CA)^);
          C11 := Decode16(F, PWord(P + RB + CB)^);
          Exit(Bilerp(C00, C10, C01, C11, FracX, FracY));
        end;
    end;
    C00 := FitTexel(T, P, FitOffset(Sw, RowBytes, Bits, XA, YA), XA, L.ClutAdd);
    C10 := FitTexel(T, P, FitOffset(Sw, RowBytes, Bits, XB, YA), XB, L.ClutAdd);
    C01 := FitTexel(T, P, FitOffset(Sw, RowBytes, Bits, XA, YB), XA, L.ClutAdd);
    C11 := FitTexel(T, P, FitOffset(Sw, RowBytes, Bits, XB, YB), XB, L.ClutAdd);
    Exit(Bilerp(C00, C10, C01, C11, FracX, FracY));
  end;
  if not Linear then
  begin
    var X := WrapCoord(TexFloor(S), L.Width, T.ClampU);
    var Y := WrapCoord(TexFloor(TT), L.Height, T.ClampV);
    Exit(FastTexel(T, L, X, Y));
  end;
  var FS := S - 0.5;
  var FT := TT - 0.5;
  var X0 := TexFloor(FS);
  var Y0 := TexFloor(FT);
  var FracX := Trunc((FS - X0) * 16);
  var FracY := Trunc((FT - Y0) * 16);
  var XA := WrapCoord(X0, L.Width, T.ClampU);
  var XB := WrapCoord(X0 + 1, L.Width, T.ClampU);
  var YA := WrapCoord(Y0, L.Height, T.ClampV);
  var YB := WrapCoord(Y0 + 1, L.Height, T.ClampV);
  var C00 := FastTexel(T, L, XA, YA);
  var C10 := FastTexel(T, L, XB, YA);
  var C01 := FastTexel(T, L, XA, YB);
  var C11 := FastTexel(T, L, XB, YB);
  Result := Bilerp(C00, C10, C01, C11, FracX, FracY);
end;

// Samplers for level 0 of a level that holds all its texels, by format and
// filter (TGETexture.Sampler, chosen by GEPrepareSampler): SampleLevel's
// fast path without its dispatch, for ordinary coordinates.

// The samplers' coordinates where they come straight from the bits of S
// (NearestCoord and LinearCoord without their other cases): nearest for
// B < $4B000000; bilinear (floor(16 * S) - 8: the texel times 16 plus the
// weight) for B in [$3F000000, $4A800000).
function NearestBits(Bits: Cardinal): Integer; inline;
begin
  var B := Bits;
  if B < $3F800000 then
    Result := 0
  else
    Result := Integer(((B and $7FFFFF) or $800000) shr (150 - (B shr 23)));
end;

function LinearBits(Bits: Cardinal): Integer; inline;
begin
  var B := Bits;
  Result := Integer((((B and $7FFFFF) or $800000) shl 2) shr (148 - (B shr 23))) - 8;
end;

function LinearInRange(B: Cardinal): Boolean; inline;
begin
  Result := (B >= $3F000000) and (B < $4A800000);
end;

function SampleFit3N(T: PGETexture; S, TT: Single): Cardinal;
begin
  var BS := PCardinal(@S)^;
  var BT := PCardinal(@TT)^;
  if (BS >= $4B000000) or (BT >= $4B000000) then
    Exit(SampleLevel(T^, 0, S, TT, False));
  var L: PGETexLevel := @T.Levels[0];
  var X := WrapCoord(NearestBits(BS), L.Width, T.ClampU);
  var Y := WrapCoord(NearestBits(BT), L.Height, T.ClampV);
  var Sw := T.Swizzle;
  Result := PCardinal(L.Ptr + FitRow(Sw, L.BufWidth * 4, Y) + FitColumn(Sw, X * 4))^;
end;

function SampleFit4N(T: PGETexture; S, TT: Single): Cardinal;
begin
  var BS := PCardinal(@S)^;
  var BT := PCardinal(@TT)^;
  if (BS >= $4B000000) or (BT >= $4B000000) then
    Exit(SampleLevel(T^, 0, S, TT, False));
  var L: PGETexLevel := @T.Levels[0];
  var X := WrapCoord(NearestBits(BS), L.Width, T.ClampU);
  var Y := WrapCoord(NearestBits(BT), L.Height, T.ClampV);
  var Sw := T.Swizzle;
  Result := T.Pal[Nibble(L.Ptr[FitRow(Sw, L.BufWidth shr 1, Y) + FitColumn(Sw, X shr 1)], X)];
end;

function SampleFit5N(T: PGETexture; S, TT: Single): Cardinal;
begin
  var BS := PCardinal(@S)^;
  var BT := PCardinal(@TT)^;
  if (BS >= $4B000000) or (BT >= $4B000000) then
    Exit(SampleLevel(T^, 0, S, TT, False));
  var L: PGETexLevel := @T.Levels[0];
  var X := WrapCoord(NearestBits(BS), L.Width, T.ClampU);
  var Y := WrapCoord(NearestBits(BT), L.Height, T.ClampV);
  var Sw := T.Swizzle;
  Result := T.Pal[L.Ptr[FitRow(Sw, L.BufWidth, Y) + FitColumn(Sw, X)]];
end;

function SampleFit16N(T: PGETexture; S, TT: Single): Cardinal;
begin
  var BS := PCardinal(@S)^;
  var BT := PCardinal(@TT)^;
  if (BS >= $4B000000) or (BT >= $4B000000) then
    Exit(SampleLevel(T^, 0, S, TT, False));
  var L: PGETexLevel := @T.Levels[0];
  var X := WrapCoord(NearestBits(BS), L.Width, T.ClampU);
  var Y := WrapCoord(NearestBits(BT), L.Height, T.ClampV);
  var Sw := T.Swizzle;
  Result := Decode16(T.Format, PWord(L.Ptr + FitRow(Sw, L.BufWidth * 2, Y) + FitColumn(Sw, X * 2))^);
end;

function SampleFit3L(T: PGETexture; S, TT: Single): Cardinal;
begin
  var BS := PCardinal(@S)^;
  var BT := PCardinal(@TT)^;
  if not (LinearInRange(BS) and LinearInRange(BT)) then
    Exit(SampleLevel(T^, 0, S, TT, True));
  var RS := LinearBits(BS);
  var RT := LinearBits(BT);
  var X0 := RS shr 4;
  var Y0 := RT shr 4;
  var L: PGETexLevel := @T.Levels[0];
  var Sw := T.Swizzle;
  var RowBytes := L.BufWidth * 4;
  var RA := FitRow(Sw, RowBytes, WrapCoord(Y0, L.Height, T.ClampV));
  var RB := FitRow(Sw, RowBytes, WrapCoord(Y0 + 1, L.Height, T.ClampV));
  var CA := FitColumn(Sw, WrapCoord(X0, L.Width, T.ClampU) * 4);
  var CB := FitColumn(Sw, WrapCoord(X0 + 1, L.Width, T.ClampU) * 4);
  var P := L.Ptr;
  Result := BilerpPacked(PCardinal(P + RA + CA)^, PCardinal(P + RA + CB)^, PCardinal(P + RB + CA)^,
    PCardinal(P + RB + CB)^, Cardinal(RS) and 15, Cardinal(RT) and 15);
end;

function SampleFit4L(T: PGETexture; S, TT: Single): Cardinal;
begin
  var BS := PCardinal(@S)^;
  var BT := PCardinal(@TT)^;
  if not (LinearInRange(BS) and LinearInRange(BT)) then
    Exit(SampleLevel(T^, 0, S, TT, True));
  var RS := LinearBits(BS);
  var RT := LinearBits(BT);
  var X0 := RS shr 4;
  var Y0 := RT shr 4;
  var L: PGETexLevel := @T.Levels[0];
  var Sw := T.Swizzle;
  var RowBytes := L.BufWidth shr 1;
  var RA := FitRow(Sw, RowBytes, WrapCoord(Y0, L.Height, T.ClampV));
  var RB := FitRow(Sw, RowBytes, WrapCoord(Y0 + 1, L.Height, T.ClampV));
  var XA := WrapCoord(X0, L.Width, T.ClampU);
  var XB := WrapCoord(X0 + 1, L.Width, T.ClampU);
  var CA := FitColumn(Sw, XA shr 1);
  var CB := FitColumn(Sw, XB shr 1);
  var P := L.Ptr;
  Result := BilerpPacked(T.Pal[Nibble(P[RA + CA], XA)], T.Pal[Nibble(P[RA + CB], XB)], T.Pal[Nibble(P[RB + CA], XA)],
    T.Pal[Nibble(P[RB + CB], XB)], Cardinal(RS) and 15, Cardinal(RT) and 15);
end;

function SampleFit5L(T: PGETexture; S, TT: Single): Cardinal;
begin
  var BS := PCardinal(@S)^;
  var BT := PCardinal(@TT)^;
  if not (LinearInRange(BS) and LinearInRange(BT)) then
    Exit(SampleLevel(T^, 0, S, TT, True));
  var RS := LinearBits(BS);
  var RT := LinearBits(BT);
  var X0 := RS shr 4;
  var Y0 := RT shr 4;
  var L: PGETexLevel := @T.Levels[0];
  var Sw := T.Swizzle;
  var RowBytes := L.BufWidth;
  var RA := FitRow(Sw, RowBytes, WrapCoord(Y0, L.Height, T.ClampV));
  var RB := FitRow(Sw, RowBytes, WrapCoord(Y0 + 1, L.Height, T.ClampV));
  var CA := FitColumn(Sw, WrapCoord(X0, L.Width, T.ClampU));
  var CB := FitColumn(Sw, WrapCoord(X0 + 1, L.Width, T.ClampU));
  var P := L.Ptr;
  Result := BilerpPacked(T.Pal[P[RA + CA]], T.Pal[P[RA + CB]], T.Pal[P[RB + CA]], T.Pal[P[RB + CB]],
    Cardinal(RS) and 15, Cardinal(RT) and 15);
end;

function SampleFit16L(T: PGETexture; S, TT: Single): Cardinal;
begin
  var BS := PCardinal(@S)^;
  var BT := PCardinal(@TT)^;
  if not (LinearInRange(BS) and LinearInRange(BT)) then
    Exit(SampleLevel(T^, 0, S, TT, True));
  var RS := LinearBits(BS);
  var RT := LinearBits(BT);
  var X0 := RS shr 4;
  var Y0 := RT shr 4;
  var L: PGETexLevel := @T.Levels[0];
  var Sw := T.Swizzle;
  var RowBytes := L.BufWidth * 2;
  var RA := FitRow(Sw, RowBytes, WrapCoord(Y0, L.Height, T.ClampV));
  var RB := FitRow(Sw, RowBytes, WrapCoord(Y0 + 1, L.Height, T.ClampV));
  var CA := FitColumn(Sw, WrapCoord(X0, L.Width, T.ClampU) * 2);
  var CB := FitColumn(Sw, WrapCoord(X0 + 1, L.Width, T.ClampU) * 2);
  var P := L.Ptr;
  var F := T.Format;
  Result := BilerpPacked(Decode16(F, PWord(P + RA + CA)^), Decode16(F, PWord(P + RA + CB)^),
    Decode16(F, PWord(P + RB + CA)^), Decode16(F, PWord(P + RB + CB)^), Cardinal(RS) and 15, Cardinal(RT) and 15);
end;

procedure GEPrepareSampler(var T: TGETexture);
begin
  T.Sampler := nil;
  if (T.Level <> 0) or T.NeedLod or not T.Levels[0].Fits or (T.Cache <> nil) then
    Exit;
  case T.Format of
    0, 1, 2:
      if T.Linear then
        T.Sampler := SampleFit16L
      else
        T.Sampler := SampleFit16N;
    3:
      if T.Linear then
        T.Sampler := SampleFit3L
      else
        T.Sampler := SampleFit3N;
    4:
      if T.PalValid then
        if T.Linear then
          T.Sampler := SampleFit4L
        else
          T.Sampler := SampleFit4N;
    5:
      if T.PalValid then
        if T.Linear then
          T.Sampler := SampleFit5L
        else
          T.Sampler := SampleFit5N;
  end;
end;

function GESampleTexture(const T: TGETexture; S, TT: Single): Cardinal;
begin
  Result := SampleLevel(T, T.Level, S, TT, T.Linear);
end;

function GELog16(V: Single): Integer;
begin
  if not (V > 0) then
    Exit(-$10000);
  var Bits := PCardinal(@V)^;
  Result := (Integer((Bits shr 23) and $FF) - 127) * 16 + Integer((Bits shr 19) and $F);
end;

// Texture coordinates in level 0 texels to those of a level.
function LevelSample(const T: TGETexture; Level: Integer; S, TT: Single; Linear: Boolean): Cardinal;
begin
  if Level > 0 then
  begin
    S := S * T.Levels[Level].Width / T.Levels[0].Width;
    TT := TT * T.Levels[Level].Height / T.Levels[0].Height;
  end;
  Result := SampleLevel(T, Level, S, TT, Linear);
end;

// Up to level 0 the magnification filter; past it the minification one,
// from the nearest level or, for the mipmap-linear filters, two levels
// mixed by the level's 4-bit fraction.
function GESampleTextureLod(const T: TGETexture; S, TT: Single; Lod: Integer): Cardinal;
begin
  if Lod <= 0 then
    Exit(SampleLevel(T, 0, S, TT, T.Linear));
  var Linear := (T.MinFilter and 1) <> 0;
  if (T.MinFilter < 4) or (T.MaxLevel = 0) then
    Exit(SampleLevel(T, 0, S, TT, Linear));
  if Lod > T.MaxLevel * 16 then
    Lod := T.MaxLevel * 16;
  var Level := Lod shr 4;
  var Frac := Lod and 15;
  if T.MinFilter < 6 then
  begin
    if Frac >= 8 then
      Inc(Level);
    if Level > T.MaxLevel then
      Level := T.MaxLevel;
    Exit(LevelSample(T, Level, S, TT, Linear));
  end;
  var C0 := LevelSample(T, Level, S, TT, Linear);
  if (Frac = 0) or (Level >= T.MaxLevel) then
    Exit(C0);
  var C1 := LevelSample(T, Level + 1, S, TT, Linear);
  Result := 0;
  for var Sh := 0 to 3 do
  begin
    var Shift := Sh * 8;
    var V := (Integer((C0 shr Shift) and $FF) * (16 - Frac) + Integer((C1 shr Shift) and $FF) * Frac) shr 4;
    Result := Result or (Cardinal(V) shl Shift);
  end;
end;

end.

