unit PSP.Font;

// sceLibFont: PGF fonts. A library lives in memory the program hands out
// through its own allocator callbacks, and so does what it keeps of each
// font: the program sees the allocations, frees and file callbacks the
// firmware library makes. Fonts come from flash0:/font (when the user
// supplied it), the program's files and memory images; a flash0 font that is
// missing is replaced by a built-in one of the same size and weight drawn
// from the Hershey strokes, with Latin-1 and fullwidth Latin characters.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, PSP.Types,
  PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service,
  PSP.State.Action;

const
  // Lookups that find no glyph: below the font's first character (drawn and
  // measured as nothing), and not in the font (the alternative character
  // stands in).
  PGFBelow = -1;
  PGFMissing = -2;

type
  TPGFMetric = record
    X, Y: Integer;
  end;

  // A decoded glyph: one 0..15 level per pixel, rows from the top, and its
  // metrics in 26.6 fixed point.
  TPGFGlyph = class
  public
    W, H, Left, Top: Integer;
    // Dimension (width, height); BearingX (horizontal, vertical layout X);
    // BearingY (horizontal, vertical layout Y); advance (horizontal, vertical).
    Dim, BearingX, BearingY, Advance: TPGFMetric;
    ShadowFlags, ShadowId: Integer;
    // Bytes of the glyph in the file.
    DataSize: Integer;
    // The streamed cache excludes the record's fixed header, not its metrics.
    CacheDataSize: Integer;
    Pixels: TBytes;
    function Pixel(X, Y: Integer): Integer; inline;
  end;

  TPGFLayout = record
    HeaderSize, Revision: Integer;
    CharMapLength, CharPtrLength, CharMapBpe, CharPtrBpe: Integer;
    ShadowMapLength, ShadowMapBpe: Integer;
    TableLength: array[0..3] of Integer;
    ShadowMapPos, CharMapPos, CharPtrPos, GlyphPos: Int64;
    // What a font opened in mode 0 keeps, in the order the library allocates
    // it: the four metric tables, the shadow map, two charmap compression
    // tables, the charmap and the glyph pointers.
    Parts: array[0..8] of Cardinal;
    function Read(const Header: TBytes): Boolean;
  end;

  TPGFFont = class
  protected
    FGlyphs, FShadows: TObjectDictionary<Integer, TPGFGlyph>;
    function DecodeGlyph(Index: Integer): TPGFGlyph; virtual; abstract;
    function DecodeShadow(Index: Integer): TPGFGlyph; virtual; abstract;
  public
    // Header; sizes and resolutions in 26.6.
    HSize, VSize, HRes, VRes: Integer;
    Bpp: Integer;
    FirstCode, LastCode: Integer;
    GlyphCount: Integer;
    MaxAscender, MaxDescender, MaxLeftX, MaxBaseY, MinCenterX, MaxTopY: Integer;
    MaxAdvanceH, MaxAdvanceV, MaxSizeH, MaxSizeV: Integer;
    MaxGlyphWidth, MaxGlyphHeight: Integer;
    // The file's size, 0 when there is no file.
    FileSize: Cardinal;
    // The blocks a mode 0 open allocates (see TPGFLayout.Parts).
    Parts: TArray<Cardinal>;
    constructor Create;
    destructor Destroy; override;
    // A glyph index, PGFBelow or PGFMissing.
    function Lookup(Code: Integer): Integer; virtual; abstract;
    function Glyph(Index: Integer): TPGFGlyph;
    function Shadow(Index: Integer): TPGFGlyph;
  end;

  TPGFFile = class(TPGFFont)
  private
    FData: TBytes;
    FLayout: TPGFLayout;
    FCharMap, FCharPtr, FShadowMap: TArray<Integer>;
    FTables: array[0..3] of TArray<TPGFMetric>;
    function Bits(BitPos: Int64; N: Integer): Cardinal;
    function SBits(BitPos: Int64; N: Integer): Integer;
    function ReadMap(Pos: Int64; Count, Bpe: Integer): TArray<Integer>;
    function GlyphBitPos(Index: Integer): Int64;
    procedure DecodeBitmap(G: TPGFGlyph; BitPos: Int64; Layout: Integer);
  protected
    function DecodeGlyph(Index: Integer): TPGFGlyph; override;
    function DecodeShadow(Index: Integer): TPGFGlyph; override;
  public
    // nil when Data is no PGF font. Data may stop after the glyph pointers.
    class function Parse(const Data: TBytes): TPGFFile;
    function Lookup(Code: Integer): Integer; override;
  end;

  TPGFBuiltin = class(TPGFFont)
  protected
    function DecodeGlyph(Index: Integer): TPGFGlyph; override;
    function DecodeShadow(Index: Integer): TPGFGlyph; override;
  public
    constructor Create(Points: Single; Bold, Italic: Boolean);
    function Lookup(Code: Integer): Integer; override;
  end;

  // A font a library has loaded, shared by the handles opening the same one.
  TPSPFontData = class
  public
    Key: string;
    Font: TPGFFont;
    OwnsFont: Boolean;
    Refs: Integer;
    // The library's blocks for the font, in the order it frees them.
    Blocks: TArray<Cardinal>;
    // Opened in mode 0: glyphs are read from the file when first asked
    // about, and the one drawn last is loaded into two blocks.
    Streamed: Boolean;
    Seen: TDictionary<Integer, Boolean>;
    CacheKey: Integer;
    Cache: TArray<Cardinal>;
    destructor Destroy; override;
    // Whether the glyph has to come from the file first.
    function FirstLook(Index: Integer): Boolean;
  end;

  TPSPFontLib = class;

  TPSPFontSlot = class
  public
    Lib: TPSPFontLib;
    Handle: Cardinal;
    // The slot's record in the library's memory.
    Memory: Cardinal;
    Busy: Boolean;
    // What the slot opened last; a closed handle still reaches it.
    Data: TPSPFontData;
  end;

  TPSPFontLib = class
  public
    Addr: Cardinal;
    // The library, its font handles, its font records, the font list.
    Blocks: TArray<Cardinal>;
    Slots: TObjectList<TPSPFontSlot>;
    Datas: TObjectList<TPSPFontData>;
    Done: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TFontIOKind = (fiSeek, fiRead, fiClose);

  TFontIOOp = record
    Kind: TFontIOKind;
    A, B, C: Cardinal;
  end;

  TFontIO = record
    UserData, OpenF, CloseF, ReadF, SeekF, FH, ErrAddr: Cardinal;
  end;

  TPSPFont = class(TPSPService)
  private
    FLibs: TObjectDictionary<Cardinal, TPSPFontLib>;
    FSlots: TDictionary<Cardinal, TPSPFontSlot>;
    // flash0 and built-in fonts, shared by every library.
    FFonts: TObjectDictionary<Integer, TPGFFont>;
    function LibOf(Addr: Cardinal): TPSPFontLib;
    function SlotOf(Handle: Cardinal): TPSPFontSlot;
    procedure SetError(Ptr, Code: Cardinal);
    procedure Finish(Value: Cardinal; YieldUs: Integer);
    procedure AllocStep(AllocF, FreeF, UserData: Cardinal; const Sizes, Addrs: TArray<Cardinal>; I: Integer; const Done: IPSPStateAction);
    procedure AllocBlocks(Lib: TPSPFontLib; const Sizes: TArray<Cardinal>; const Done: IPSPStateAction);
    procedure FreeStep(FreeF, UserData: Cardinal; const Addrs: TArray<Cardinal>; I: Integer; const Done: IPSPStateAction);
    procedure FreeBlocks(Lib: TPSPFontLib; const Addrs: TArray<Cardinal>; const Done: IPSPStateAction);
    procedure RunIO(const IO: TFontIO; const Ops: TArray<TFontIOOp>; I: Integer; const Done, Fail: IPSPStateAction);
    procedure AllocNext(Action: TPSPStateAction);
    procedure StateAlloc(Action: TPSPStateAction; Value: Cardinal);
    procedure StateAllocFailed(Action: TPSPStateAction; Value: Cardinal);
    procedure AllocDone(const Done: IPSPStateAction; const Addrs: TArray<Cardinal>; Ok: Boolean);
    procedure FreeNext(Action: TPSPStateAction);
    procedure StateFree(Action: TPSPStateAction; Value: Cardinal);
    procedure IONext(Action: TPSPStateAction);
    procedure StateIO(Action: TPSPStateAction; Value: Cardinal);
    procedure StateResult(Action: TPSPStateAction; Value: Cardinal);
    procedure StateLibAllocated(Action: TPSPStateAction; Value: Cardinal);
    procedure StateOpened(Action: TPSPStateAction; Value: Cardinal);
    function StreamIO(Action: TPSPStateAction): TFontIO;
    procedure StreamFail(Action: TPSPStateAction; Error: Cardinal; Close: Boolean);
    procedure StateStreamOpened(Action: TPSPStateAction; Value: Cardinal);
    procedure StateStreamShortRead(Action: TPSPStateAction; Value: Cardinal);
    procedure StateStreamHeaderRead(Action: TPSPStateAction; Value: Cardinal);
    procedure StateStreamAllocated(Action: TPSPStateAction; Value: Cardinal);
    procedure StateStreamTablesRead(Action: TPSPStateAction; Value: Cardinal);
    procedure StateStreamIOFailed(Action: TPSPStateAction; Value: Cardinal);
    procedure StateStreamFailClose(Action: TPSPStateAction; Value: Cardinal);
    procedure StateStreamError(Action: TPSPStateAction; Value: Cardinal);
    procedure StateDrawFreed(Action: TPSPStateAction; Value: Cardinal);
    procedure StateDrawAllocated(Action: TPSPStateAction; Value: Cardinal);
    procedure RemoveLib(Addr: Cardinal);
    function CreateLib(const Addrs: TArray<Cardinal>; Count: Integer; const Params: TBytes): TPSPFontLib;
    function FreeSlot(Lib: TPSPFontLib): TPSPFontSlot;
    function SharedData(Lib: TPSPFontLib; const Key: string): TPSPFontData;
    function AddData(Lib: TPSPFontLib; const Key: string; Font: TPGFFont; Owns: Boolean; const Blocks: TArray<Cardinal>): TPSPFontData;
    procedure Attach(Slot: TPSPFontSlot; Data: TPSPFontData);
    function InternalFont(Index: Integer): TPGFFont;
    function GuestBytes(Addr, Size: Cardinal): TBytes;
    procedure OpenStreamed(Lib: TPSPFontLib; NamePtr: Cardinal; const Name: string; ErrPtr: Cardinal);
    procedure OpenWhole(Lib: TPSPFontLib; const Name: string; ErrPtr: Cardinal);
    function Resolve(Slot: TPSPFontSlot; Code: Integer): Integer;
    procedure WriteStyle(Addr: Cardinal; Index: Integer);
    procedure WriteCharInfo(Addr: Cardinal; G, Bitmap: TPGFGlyph);
    procedure Draw(G: TPGFGlyph; Image: Cardinal; ClipX, ClipY, ClipW, ClipH: Integer);
    procedure DrawCall(Shadow, Clip: Boolean);
    procedure InfoCall(Shadow: Boolean);
    procedure RectCall(Shadow: Boolean);
    procedure Convert(Vertical, ToPoints: Boolean);
    function Match(Lib: TPSPFontLib; Style: Cardinal; Optimum: Boolean): Integer;
    procedure hNewLib;
    procedure hDoneLib;
    procedure hOpen;
    procedure hOpenUserMemory;
    procedure hOpenUserFile;
    procedure hClose;
    procedure hGetNumFontList;
    procedure hGetFontList;
    procedure hFindOptimumFont;
    procedure hFindFont;
    procedure hGetFontInfo;
    procedure hGetFontInfoByIndexNumber;
    procedure hGetCharInfo;
    procedure hGetShadowInfo;
    procedure hGetCharImageRect;
    procedure hGetShadowImageRect;
    procedure hGetCharGlyphImage;
    procedure hGetCharGlyphImageClip;
    procedure hGetShadowGlyphImage;
    procedure hGetShadowGlyphImageClip;
    procedure hSetAltCharacterCode;
    procedure hSetResolution;
    procedure hPixelToPointH;
    procedure hPixelToPointV;
    procedure hPointToPixelH;
    procedure hPointToPixelV;
    procedure hFlush;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
    // The font behind a handle the program opened, for a renderer (nil if none).
    function FontOf(Handle: Cardinal): TPGFFont;
  end;

implementation

uses
  PSP.IO, System.IOUtils;

const
  SCE_FONT_ERROR_NOMEMORY = Cardinal($80460001);
  SCE_FONT_ERROR_LIBID = Cardinal($80460002);
  SCE_FONT_ERROR_ARG = Cardinal($80460003);
  SCE_FONT_ERROR_FILEOPEN = Cardinal($80460005);
  SCE_FONT_ERROR_FILEREAD = Cardinal($80460007);
  SCE_FONT_ERROR_FILESEEK = Cardinal($80460008);
  SCE_FONT_ERROR_TOOMANYOPENED = Cardinal($80460009);
  SCE_FONT_ERROR_DATAINCONSISTENT = Cardinal($8046000B);

// PGF files. All fields little-endian, bit fields LSB first. The header
// (0x188 bytes, more in later revisions) is followed by four tables of 32-bit
// (x, y) pairs the glyphs index their metrics into, then the shadow map (shadow
// id -> character), the charmap (character - first -> glyph index) and the
// glyph pointers (glyph index -> 32-bit words from the glyph data), each
// padded to 32 bits. A glyph is 14 bits of size in bytes, 7 bits each of
// width, height, left and top (signed), 6 bits of flags (bits 0-1: 1 rows,
// 2 columns; bits 2-5: dimension, x and y bearing, advance given as 8-bit
// table indices rather than inline pairs), 7 bits nobody reads, 9 bits of
// shadow id, the metrics and then the bitmap: run-length coded nibbles, a
// count c < 8 repeating the next nibble c + 1 times and c >= 8 introducing
// 16 - c literal ones. Its shadow follows it: the same first 48 bits, then
// its bitmap.

function Align32(Count, Bpe: Int64): Cardinal;
begin
  Result := Cardinal(((Count * Bpe + 31) div 32) * 4);
end;

function TPGFLayout.Read(const Header: TBytes): Boolean;
begin
  Result := False;
  if Length(Header) < $188 then
    Exit;
  if (Header[4] <> Ord('P')) or (Header[5] <> Ord('G')) or (Header[6] <> Ord('F')) or (Header[7] <> Ord('0')) then
    Exit;
  HeaderSize := PWord(@Header[2])^;
  if HeaderSize < $188 then
    HeaderSize := $188;
  Revision := PInteger(@Header[8])^;
  CharMapLength := PInteger(@Header[$10])^;
  CharPtrLength := PInteger(@Header[$14])^;
  CharMapBpe := PInteger(@Header[$18])^;
  CharPtrBpe := PInteger(@Header[$1C])^;
  ShadowMapLength := PInteger(@Header[$16C])^;
  ShadowMapBpe := PInteger(@Header[$170])^;
  if (CharMapLength < 0) or (CharMapLength > $110000) or (CharPtrLength < 0) or (CharPtrLength > $110000) or
    (ShadowMapLength < 0) or (ShadowMapLength > $110000) then
    Exit;
  if (CharMapBpe < 1) or (CharMapBpe > 32) or (CharPtrBpe < 1) or (CharPtrBpe > 32) then
    Exit;
  if (ShadowMapLength > 0) and ((ShadowMapBpe < 1) or (ShadowMapBpe > 32)) then
    Exit;
  var Pos: Int64 := HeaderSize;
  for var K := 0 to 3 do
  begin
    TableLength[K] := Header[$102 + K];
    Parts[K] := TableLength[K] * 8;
    Inc(Pos, Parts[K]);
  end;
  ShadowMapPos := Pos;
  Parts[4] := Align32(ShadowMapLength, ShadowMapBpe);
  Inc(Pos, Parts[4]);
  Parts[5] := 0;
  Parts[6] := 0;
  CharMapPos := Pos;
  Parts[7] := Align32(CharMapLength, CharMapBpe);
  Inc(Pos, Parts[7]);
  CharPtrPos := Pos;
  Parts[8] := Align32(CharPtrLength, CharPtrBpe);
  Inc(Pos, Parts[8]);
  GlyphPos := Pos;
  Result := True;
end;

{ TPGFGlyph }

function TPGFGlyph.Pixel(X, Y: Integer): Integer;
begin
  if (X < 0) or (Y < 0) or (X >= W) or (Y >= H) then
    Result := 0
  else
    Result := Pixels[Y * W + X];
end;

{ TPGFFont }

constructor TPGFFont.Create;
begin
  inherited Create;
  FGlyphs := TObjectDictionary<Integer, TPGFGlyph>.Create([doOwnsValues]);
  FShadows := TObjectDictionary<Integer, TPGFGlyph>.Create([doOwnsValues]);
  Bpp := 4;
end;

destructor TPGFFont.Destroy;
begin
  FGlyphs.Free;
  FShadows.Free;
  inherited;
end;

function TPGFFont.Glyph(Index: Integer): TPGFGlyph;
begin
  if Index < 0 then
    Exit(nil);
  if not FGlyphs.TryGetValue(Index, Result) then
  begin
    Result := DecodeGlyph(Index);
    if Result <> nil then
      FGlyphs.Add(Index, Result);
  end;
end;

function TPGFFont.Shadow(Index: Integer): TPGFGlyph;
begin
  if Index < 0 then
    Exit(nil);
  if not FShadows.TryGetValue(Index, Result) then
  begin
    Result := DecodeShadow(Index);
    if Result <> nil then
      FShadows.Add(Index, Result);
  end;
end;

{ TPGFFile }

class function TPGFFile.Parse(const Data: TBytes): TPGFFile;
begin
  var L: TPGFLayout;
  if not L.Read(Data) then
    Exit(nil);
  if Length(Data) < L.CharPtrPos + L.Parts[8] then
    Exit(nil);
  Result := TPGFFile.Create;
  var F := Result;
  F.FData := Data;
  F.FLayout := L;
  F.FileSize := Length(Data);
  SetLength(F.Parts, 9);
  for var K := 0 to 8 do
    F.Parts[K] := L.Parts[K];
  F.HSize := PInteger(@Data[$24])^;
  F.VSize := PInteger(@Data[$28])^;
  F.HRes := PInteger(@Data[$2C])^;
  F.VRes := PInteger(@Data[$30])^;
  if Data[$22] <> 0 then
    F.Bpp := Data[$22];
  F.FirstCode := PWord(@Data[$B6])^;
  F.LastCode := PWord(@Data[$B8])^;
  F.MaxAscender := PInteger(@Data[$D4])^;
  F.MaxDescender := PInteger(@Data[$D8])^;
  F.MaxLeftX := PInteger(@Data[$DC])^;
  F.MaxBaseY := PInteger(@Data[$E0])^;
  F.MinCenterX := PInteger(@Data[$E4])^;
  F.MaxTopY := PInteger(@Data[$E8])^;
  F.MaxAdvanceH := PInteger(@Data[$EC])^;
  F.MaxAdvanceV := PInteger(@Data[$F0])^;
  F.MaxSizeH := PInteger(@Data[$F4])^;
  F.MaxSizeV := PInteger(@Data[$F8])^;
  F.MaxGlyphWidth := PWord(@Data[$FC])^;
  F.MaxGlyphHeight := PWord(@Data[$FE])^;
  F.GlyphCount := L.CharPtrLength;
  var Pos: Int64 := L.HeaderSize;
  for var K := 0 to 3 do
  begin
    SetLength(F.FTables[K], L.TableLength[K]);
    for var I := 0 to L.TableLength[K] - 1 do
    begin
      F.FTables[K][I].X := PInteger(@Data[Pos])^;
      F.FTables[K][I].Y := PInteger(@Data[Pos + 4])^;
      Inc(Pos, 8);
    end;
  end;
  F.FShadowMap := F.ReadMap(L.ShadowMapPos, L.ShadowMapLength, L.ShadowMapBpe);
  F.FCharMap := F.ReadMap(L.CharMapPos, L.CharMapLength, L.CharMapBpe);
  F.FCharPtr := F.ReadMap(L.CharPtrPos, L.CharPtrLength, L.CharPtrBpe);
end;

function TPGFFile.Bits(BitPos: Int64; N: Integer): Cardinal;
begin
  // Up to 32 bits from any bit position; past the end reads zeros.
  var ByteIdx := BitPos shr 3;
  var Acc: UInt64 := 0;
  for var I := 0 to 4 do
    if ByteIdx + I < Length(FData) then
      Acc := Acc or (UInt64(FData[ByteIdx + I]) shl (8 * I));
  Acc := Acc shr (BitPos and 7);
  if N >= 32 then
    Result := Cardinal(Acc)
  else
    Result := Cardinal(Acc) and ((Cardinal(1) shl N) - 1);
end;

function TPGFFile.SBits(BitPos: Int64; N: Integer): Integer;
begin
  var V := Bits(BitPos, N);
  if (N < 32) and ((V and (Cardinal(1) shl (N - 1))) <> 0) then
    Result := Integer(V) - (1 shl N)
  else
    Result := Integer(V);
end;

function TPGFFile.ReadMap(Pos: Int64; Count, Bpe: Integer): TArray<Integer>;
begin
  SetLength(Result, Count);
  for var I := 0 to Count - 1 do
    Result[I] := Integer(Bits(Pos * 8 + Int64(I) * Bpe, Bpe));
end;

function TPGFFile.Lookup(Code: Integer): Integer;
begin
  if Code < FirstCode then
    Exit(PGFBelow);
  var I := Code - FirstCode;
  if (Code > LastCode) or (I >= Length(FCharMap)) then
    Exit(PGFMissing);
  Result := FCharMap[I];
  if (Result < 0) or (Result >= GlyphCount) then
    Result := PGFMissing;
end;

function TPGFFile.GlyphBitPos(Index: Integer): Int64;
begin
  Result := (FLayout.GlyphPos + Int64(Cardinal(FCharPtr[Index])) * 4) * 8;
end;

procedure TPGFFile.DecodeBitmap(G: TPGFGlyph; BitPos: Int64; Layout: Integer);
begin
  var N := G.W * G.H;
  SetLength(G.Pixels, N);
  if N = 0 then
    Exit;
  var Limit := Int64(Length(FData)) * 8;
  var I := 0;
  var P := BitPos;
  while (I < N) and (P < Limit) do
  begin
    var C := Integer(Bits(P, 4));
    Inc(P, 4);
    var Count, Literal: Integer;
    if C < 8 then
    begin
      Count := C + 1;
      Literal := 0;
    end
    else
    begin
      Count := 16 - C;
      Literal := 1;
    end;
    var V := 0;
    if Literal = 0 then
    begin
      V := Integer(Bits(P, 4));
      Inc(P, 4);
    end;
    for var K := 1 to Count do
    begin
      if I >= N then
        Break;
      if Literal <> 0 then
      begin
        V := Integer(Bits(P, 4));
        Inc(P, 4);
      end;
      if Layout = 2 then
        G.Pixels[(I mod G.H) * G.W + I div G.H] := V
      else
        G.Pixels[I] := V;
      Inc(I);
    end;
  end;
end;

function TPGFFile.DecodeGlyph(Index: Integer): TPGFGlyph;
begin
  if (Index < 0) or (Index >= GlyphCount) then
    Exit(nil);
  Result := TPGFGlyph.Create;
  var P := GlyphBitPos(Index);
  if P >= Int64(Length(FData)) * 8 then
    Exit;
  var G := Result;
  G.DataSize := Integer(Bits(P, 14));
  G.CacheDataSize := Max(0, G.DataSize - 8);
  G.W := Integer(Bits(P + 14, 7));
  G.H := Integer(Bits(P + 21, 7));
  G.Left := SBits(P + 28, 7);
  G.Top := SBits(P + 35, 7);
  var Flags := Integer(Bits(P + 42, 6));
  var Q := P + 48 + 7;
  G.ShadowId := Integer(Bits(Q, 9));
  Inc(Q, 9);
  for var K := 0 to 3 do
  begin
    var M: TPGFMetric;
    if (Flags and (4 shl K)) <> 0 then
    begin
      var Idx := Integer(Bits(Q, 8));
      Inc(Q, 8);
      if Idx < Length(FTables[K]) then
        M := FTables[K][Idx]
      else
        M := Default(TPGFMetric);
    end
    else
    begin
      M.X := SBits(Q, 32);
      M.Y := SBits(Q + 32, 32);
      Inc(Q, 64);
    end;
    case K of
      0:
        G.Dim := M;
      1:
        G.BearingX := M;
      2:
        G.BearingY := M;
      3:
        G.Advance := M;
    end;
  end;
  G.ShadowFlags := $40 or Max(G.W, G.H);
  DecodeBitmap(G, Q, Flags and 3);
end;

function TPGFFile.DecodeShadow(Index: Integer): TPGFGlyph;
begin
  var G := Glyph(Index);
  if G = nil then
    Exit(nil);
  Result := TPGFGlyph.Create;
  if G.ShadowId >= Length(FShadowMap) then
    Exit;
  var Owner := Lookup(FShadowMap[G.ShadowId]);
  if Owner < 0 then
    Exit;
  var O := Glyph(Owner);
  if O = nil then
    Exit;
  var P := GlyphBitPos(Owner) + Int64(O.DataSize) * 8;
  if P >= Int64(Length(FData)) * 8 then
    Exit;
  var S := Result;
  S.DataSize := Integer(Bits(P, 14));
  S.CacheDataSize := Max(0, S.DataSize - 6);
  S.W := Integer(Bits(P + 14, 7));
  S.H := Integer(Bits(P + 21, 7));
  S.Left := SBits(P + 28, 7);
  S.Top := SBits(P + 35, 7);
  DecodeBitmap(S, P + 48, Integer(Bits(P + 42, 6)) and 3);
end;

// The built-in stand-ins for flash0's fonts: ASCII, Latin-1, Cyrillic, the trade mark sign and
// fullwidth Latin drawn from
// the Hershey strokes at the size and weight of the font they replace,
// antialiased to the 4-bit levels PGF glyphs have.

// The Hershey Simplex strokes (public domain, A. V. Hershey, U.S. National
// Bureau of Standards) the built-in fonts are drawn from.

const
  // Per character 21h..7Eh: the advance width, then x/y pairs (each value
  // offset by Ord('R'), y up from the baseline), a space lifting the pen.
  HersheyStrokes: array[33..126] of string = (
    '\WgWY WTVSWRXSWT',
    'bVgV` ^g^`',
    'g]kVK ck\K V^d^ UXcX',
    'fZkZN ^k^N cdaf^gZgWfUdUbV`W_Y^_\a[bZcXcUaS^RZRWSUU',
    'jggUR Zg\e\c[aY`W`UbUdVfXgZg\f_ebeefgg cYaX`V`TbRdRfSgUgWeYcY',
    'li^i_h`g`f_e]cXaU_S]RYRWSVTUVUXVZW[^__``b`d_f]g[fZdZb[_]\bUdSfRhRiSiT',
    '\WeVfWgXfXdWbVa',
    '`]k[iYfWbV]VYWTYP[M]K',
    '`UkWiYf[b\]\Y[TYPWMUK',
    'bZgZ[ Ud_^ _dU^',
    'l_d_R V[h[',
    '\XSWRVSWTXSXQWOVN',
    'lV[h[',
    '\WTVSWRXSWT',
    'hfkTK',
    'f[gXfVcU^U[VVXS[R]R`SbVc[c^bc`f]g[g',
    'fXcZd]g]R',
    'fVbVcWeXfZg^g`faebcbaa__\URcR',
    'fWgbg\___a^b]cZcXbU`S]RZRWSVTUV',
    'f_gUYdY _g_R',
    'fagWgV^W_Z`]``_b]cZcXbU`S]RZRWSVTUV',
    'fbdaf^g\gYfWcV^VYWUYS\R]R`SbUcXcYb\`^]_\_Y^W\VY',
    'fcgYR Ugcg',
    'fZgWfVdVbW`Y_]^`]b[cYcVbTaS^RZRWSVTUVUYV[X][^__a`bbbdaf^gZg',
    'fb`a]_[\Z[ZX[V]U`UaVdXf[g\g_fadb`b[aV_S\RZRWSVU',
    '\W`V_W^X_W` WTVSWRXSWT',
    '\W`V_W^X_W` XSWRVSWTXSXQWOVN',
    'jfdV[fR',
    'lV^h^ VXhX',
    'jVdf[VR',
    'dUbUcVeWfYg]g_f`eacaa`__^[\[Y [TZS[R\S[T',
    'md_caab^b\a[`Z]ZZ[X]W`WbXcZ ^b\`[][Z\X]W dbcZcXeWgWiYj\j^iahcfedfag^g[fYeWcVaU^U[VXWVYT[S^RaRdSfTgU ebdZdXeW',
    'd[gSR [gcR VY`Y',
    'gVgVR Vg_gbfcedcdac_b^_] V]_]b\c[dYdVcTbS_RVR',
    'gdbcdaf_g[gYfWdVbU_UZVWWUYS[R_RaScUdW',
    'gVgVR Vg]g`fbdcbd_dZcWbU`S]RVR',
    'eVgVR Vgcg V]^] VRcR',
    'dVgVR Vgcg V]^]',
    'gdbcdaf_g[gYfWdVbU_UZVWWUYS[R_RaScUdWdZ _ZdZ',
    'hVgVR dgdR V]d]',
    'ZVgVR',
    'b^g^W]T\SZRXRVSUTTWTY',
    'gVgVR dgVY [^dR',
    'cVgVR VRbR',
    'jVgVR Vg^R fg^R fgfR',
    'hVgVR VgdR dgdR',
    'h[gYfWdVbU_UZVWWUYS[R_RaScUdWeZe_dbcdaf_g[g',
    'gVgVR Vg_gbfcedcd`c^b]_\V\',
    'h[gYfWdVbU_UZVWWUYS[R_RaScUdWeZe_dbcdaf_g[g ^VdP',
    'gVgVR Vg_gbfcedcdac_b^_]V] ]]dR',
    'fcdaf^gZgWfUdUbV`W_Y^_\a[bZcXcUaS^RZRWSUU',
    'bZgZR Sgag',
    'hVgVXWUYS\R^RaScUdXdg',
    'dSg[R cg[R',
    'jTgYR ^gYR ^gcR hgcR',
    'fUgcR cgUR',
    'dSg[][R cg[]',
    'fcgUR Ugcg URcR',
    '`VkVK WkWK Vk]k VK]K',
    '`Rg`O',
    '`[k[K \k\K Uk\k UK\K',
    'bXaZd\a U^Zc_^ ZcZR',
    'bRPbP',
    '\XgWfVdVbWaXbWc',
    'ea`aR a]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    'eVgVR V]X_Z`]`__a]bZbXaU_S]RZRXSVU',
    'da]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    'eagaR a]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    'dUZaZa\`^__]`Z`X_V]UZUXVUXSZR]R_SaU',
    '^\gZgXfWcWR T`[`',
    'ea`aP`M_L]KZKXL a]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    'eVgVR V\Y_[`^``_a\aR',
    'ZUgVfWgVhUg V`VR',
    '\WgXfYgXhWg X`XOWLUKSK',
    'cVgVR ``VV ZZaR',
    'ZVgVR',
    'pV`VR V\Y_[`^``_a\aR a\d_f`i`k_l\lR',
    'eV`VR V\Y_[`^``_a\aR',
    'eZ`X_V]UZUXVUXSZR]R_SaUbXbZa]__]`Z`',
    'eV`VK V]X_Z`]`__a]bZbXaU_S]RZRXSVU',
    'ea`aK a]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    '_V`VR VZW]Y_[`^`',
    'c`]__\`Y`V_U]V[XZ]Y_X`V`U_S\RYRVSUU',
    '^WgWVXSZR\R T`[`',
    'eV`VVWSYR\R^SaV a`aR',
    'bT`ZR ``ZR',
    'hU`YR ]`YR ]`aR e`aR',
    'cU``R ``UR',
    'bT`ZR ``ZRXNVLTKSK',
    'c``UR U``` UR`R',
    '`[kYjXiWgWeXcYbZ`Z^X\ YjXhXfYdZc[a[_Z]V[ZY[W[UZSYRXPXNYL XZZXZVYTXSWQWOXMYL[K',
    'ZVkVK',
    '`WkYjZi[g[eZcYbX`X^Z\ YjZhZfYdXcWaW_X]\[XYWWWUXSYRZPZNYL ZZXXXVYTZS[Q[OZMYLWK',
    'jUXUZV]X^Z^\]`ZbYdYfZg\ UZV\X]Z]\\`YbXdXfYg\g^');
  // A0h..FFh: base character and mark (` grave, / acute, ^ circumflex,
  // ~ tilde, : diaeresis, o ring, , cedilla, | slash, ! inverted, . dot,
  // v vertical bar, - none); a space base with no mark is blank.
  HersheyLatinBases = ' !c        < -       u     >   ?AAAAAA CEEEEIIII' +
    'DNOOOOOxOUUUUY  aaaaaa ceeeeiiiionooooo ouuuuypy';
  HersheyLatinMarks = '-!v-----:-------o---/--.,------!`/^~:o-,`/^:`/^:' +
    '-~`/^~:-|`/^:/--`/^~:o-,`/^:`/^:-~`/^~:-|`/^:/-:';
  // U+0410..U+042F: a Latin capital to reuse, or the width and strokes as
  // in HersheyStrokes.
  HersheyCyrillicUpper: array[$410..$42F] of string = (
    'A',
    'gcgVgVR V]_]b\c[dYdVcTbS_RVR',
    'B',
    'cVRVgbg',
    'gYgcgcR YgY]XWWTUR SNSReReN',
    'E',
    'h]g]R Tg]]fg SR[] gR_]',
    'fVdXf[g_gbfcdcaa^]] Z]]]a\cZcVbT_R[RXSVU',
    'gVgVRcgcR',
    'gVgVRcgcR Yl[j^j`l',
    'K',
    'gSRUSWVX[YgcgcR',
    'M',
    'H',
    'O',
    'gVRVgcgcR',
    'P',
    'C',
    'T',
    'fTg\Y dg\YZUXSVRTR',
    'h]g]R e^d`cb`d]dZdWbV`U^V\WZZX]X`XcZd\e^',
    'X',
    'fVgVRdRdN bgbR',
    'fVgV`W^Y]b] bgbR',
    'jUgURgRgg ^g^R',
    'lUgURiRiN ^g^R gggR',
    'gSgWgWR`RcSdTeVeYd[c\`]W]',
    'jVgVR_RbScTdVdYc[b\_]V] gggR',
    'gVgVR_RbScTdVdYc[b\_]V]',
    'gUbVdXfZg^g`fbdcbd_dZcWbU`S^RZRXSVUUW []d]',
    'kUgUR U]Z] h\h_gbeecfag_f]e[bZ_Z\ZY[V]S_RaQcReSgVhYh\',
    'gcRcgZgWfVeUcUaV_W^Z]c] \]UR');
  // U+0430..U+044F: a Latin small letter, the strokes, or empty for the
  // capital at the x-height.
  HersheyCyrillicLower: array[$430..$44F] of string = (
    'a',
    'eag^fZeXcW`V\ bYb[a]`_^`\`Z`X_W]V[VYVWWUXSZR\R^R`SaUbWbY',
    '',
    '',
    '',
    'e',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    'o',
    '',
    'p',
    'c',
    '',
    'y',
    'h]g]K eYe[c]b__`]`[`X_W]U[UYUWWUXS[R]R_RbScUeWeY',
    'x',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '');

type
  THSegment = record
    X0, Y0, X1, Y1: Single;
  end;

procedure HAdd(var Segments: TArray<THSegment>; const Points: array of Single);
begin
  for var I := 0 to Length(Points) div 2 - 2 do
  begin
    var S: THSegment;
    S.X0 := Points[I * 2];
    S.Y0 := Points[I * 2 + 1];
    S.X1 := Points[I * 2 + 2];
    S.Y1 := Points[I * 2 + 3];
    Segments := Segments + [S];
  end;
end;

// Strokes as HersheyStrokes holds them, in Hershey units (y up from the
// baseline); DotlessI drops the dot of i and j.
function HStrokes(const Data: string; DotlessI: Boolean; out Width: Integer): TArray<THSegment>;
begin
  Result := nil;
  Width := Ord(Data[1]) - Ord('R');
  var HaveLast := False;
  var LX := 0;
  var LY := 0;
  var I := 2;
  while I <= Length(Data) do
  begin
    if Data[I] = ' ' then
    begin
      HaveLast := False;
      Inc(I);
      Continue;
    end;
    var X := Ord(Data[I]) - Ord('R');
    var Y := Ord(Data[I + 1]) - Ord('R');
    Inc(I, 2);
    if HaveLast and not (DotlessI and (LY > 15) and (Y > 15)) then
      HAdd(Result, [LX, LY, X, Y]);
    LX := X;
    LY := Y;
    HaveLast := True;
  end;
end;

// The strokes of an ASCII character.
function HGlyph(C: Char; DotlessI: Boolean; out Width: Integer): TArray<THSegment>;
begin
  Result := nil;
  Width := 16;
  if (Ord(C) < 33) or (Ord(C) > 126) then
    Exit;
  Result := HStrokes(HersheyStrokes[Ord(C)], DotlessI, Width);
end;

// A capital Cyrillic letter: a Latin capital or its own strokes.
function HCyrillicCapital(Code: Integer; out Width: Integer): TArray<THSegment>;
begin
  var Data := HersheyCyrillicUpper[Code];
  if Length(Data) = 1 then
    Result := HGlyph(Data[1], False, Width)
  else
    Result := HStrokes(Data, False, Width);
end;

function HMarks(Mark: Char; CX, Top: Single): TArray<THSegment>;
begin
  Result := nil;
  case Mark of
    '`':
      HAdd(Result, [CX - 2, Top + 4, CX + 1, Top + 1]);
    '/':
      HAdd(Result, [CX + 2, Top + 4, CX - 1, Top + 1]);
    '^':
      HAdd(Result, [CX - 3, Top + 1, CX, Top + 4, CX + 3, Top + 1]);
    '~':
      HAdd(Result, [CX - 4, Top + 2, CX - 2, Top + 4, CX + 2, Top + 2, CX + 4, Top + 4]);
    ':':
      begin
        HAdd(Result, [CX - 3, Top + 2, CX - 3, Top + 3]);
        HAdd(Result, [CX + 3, Top + 2, CX + 3, Top + 3]);
      end;
    'o':
      HAdd(Result,
        [CX, Top + 1.5, CX + 1.5, Top + 2.5, CX + 1.5, Top + 3.5, CX, Top + 4.5, CX - 1.5, Top + 3.5, CX - 1.5,
          Top + 2.5, CX, Top + 1.5]);
    ',':
      HAdd(Result, [CX, 0, CX, -2, CX + 2, -3, CX - 1, -5]);
    '|':
      HAdd(Result, [CX - 6, -1, CX + 6, Top + 1]);
    'v':
      HAdd(Result, [CX, Top + 3, CX, -3]);
    '.':
      HAdd(Result, [CX, 9, CX, 10]);
  end;
end;

// Segments scaled by SX, SY, then moved by DX, DY.
function HMoved(const Segments: TArray<THSegment>; SX, SY, DX, DY: Single): TArray<THSegment>;
begin
  Result := Copy(Segments);
  for var K := 0 to High(Result) do
  begin
    Result[K].X0 := Result[K].X0 * SX + DX;
    Result[K].X1 := Result[K].X1 * SX + DX;
    Result[K].Y0 := Result[K].Y0 * SY + DY;
    Result[K].Y1 := Result[K].Y1 * SY + DY;
  end;
end;

// The copyright and registered signs (a letter in a circle) and the trade
// mark sign (raised small capitals).
function HSign(Code: Integer; out Width: Integer): TArray<THSegment>;
var
  W1, W2: Integer;
begin
  Result := nil;
  if Code = $2122 then
  begin
    var T := HGlyph('T', False, W1);
    var M := HGlyph('M', False, W2);
    Result := HMoved(T, 0.45, 0.45, 0, 12) + HMoved(M, 0.45, 0.45, W1 * 0.45 - 1, 12);
    Width := Round((W1 + W2) * 0.45);
    Exit;
  end;
  var L: Char := 'C';
  if Code = $AE then
    L := 'R';
  Width := 24;
  var Circle: array[0..33] of Single;
  for var K := 0 to 16 do
  begin
    Circle[K * 2] := 12 + 10 * Cos(K * Pi / 8);
    Circle[K * 2 + 1] := 10.5 + 10.5 * Sin(K * Pi / 8);
  end;
  HAdd(Result, Circle);
  var G := HGlyph(L, False, W1);
  Result := Result + HMoved(G, 0.45, 0.45, 12 - W1 * 0.45 / 2, 5.5);
end;

// Characters 20h..7Eh, A0h..FFh, 401h, 410h..44Fh, 451h and 2122h.
function HCharacter(Code: Integer; out Width: Integer): TArray<THSegment>;
const
  // Small letters drawn as capitals: the x-height of the capitals' 21 units,
  // and a little narrower.
  SmallY = 14 / 21;
  SmallX = 0.85;
begin
  Result := nil;
  Width := 16;
  case Code of
    $A9, $AE, $2122:
      Exit(HSign(Code, Width));
    $401, $451:
      begin
        // Yo: E with a diaeresis.
        var Small := Code = $451;
        if Small then
          Result := HGlyph('e', False, Width)
        else
          Result := HGlyph('E', False, Width);
        var Top: Single := 21;
        if Small then
          Top := 14;
        Result := Result + HMarks(':', Width / 2, Top);
        Exit;
      end;
    $410..$42F:
      Exit(HCyrillicCapital(Code, Width));
    $430..$44F:
      begin
        var Data := HersheyCyrillicLower[Code];
        if Length(Data) = 1 then
          Exit(HGlyph(Data[1], False, Width));
        if Data <> '' then
          Exit(HStrokes(Data, False, Width));
        Result := HCyrillicCapital(Code - $20, Width);
        for var K := 0 to High(Result) do
        begin
          Result[K].X0 := Result[K].X0 * SmallX;
          Result[K].X1 := Result[K].X1 * SmallX;
          Result[K].Y0 := Result[K].Y0 * SmallY;
          Result[K].Y1 := Result[K].Y1 * SmallY;
        end;
        Width := Round(Width * SmallX);
        Exit;
      end;
  end;
  if Code < $A0 then
  begin
    if Code > $20 then
      Result := HGlyph(Char(Code), False, Width);
    Exit;
  end;
  var Base := HersheyLatinBases[Code - $A0 + 1];
  var Mark := HersheyLatinMarks[Code - $A0 + 1];
  if Base <> ' ' then
    Result := HGlyph(Base, CharInSet(Base, ['i', 'j']) and (Mark <> '-'), Width);
  if Mark = '!' then
    // Inverted punctuation hangs below the baseline.
    for var K := 0 to High(Result) do
    begin
      Result[K].X0 := Width - Result[K].X0;
      Result[K].X1 := Width - Result[K].X1;
      Result[K].Y0 := 14 - Result[K].Y0;
      Result[K].Y1 := 14 - Result[K].Y1;
    end
  else if Mark <> '-' then
  begin
    var Top: Single := 14;
    if CharInSet(Base, ['A'..'Z']) then
      Top := 21
    else if Base = ' ' then
      Top := 16;
    Result := Result + HMarks(Mark, Width / 2, Top);
  end;
end;

{ TPGFBuiltin }

const
  BuiltinSamples = 4;

function BuiltinIndex(Code: Integer): Integer;
begin
  case Code of
    $20..$7E:
      Result := Code - $20;
    $A0..$FF:
      Result := 95 + Code - $A0;
    $FF01..$FF5E:
      Result := 191 + Code - $FF01;
    $3000:
      Result := 285;
    $410..$44F:
      Result := 286 + Code - $410;
    $401:
      Result := 350;
    $451:
      Result := 351;
    $2122:
      Result := 352;
  else
    Result := PGFMissing;
  end;
end;

// The character a glyph is drawn from (fullwidth forms from their ASCII
// ones, the ideographic space as a space).
function BuiltinCode(Index: Integer): Integer;
begin
  case Index of
    0..94:
      Result := Index + $20;
    95..190:
      Result := Index - 95 + $A0;
    191..284:
      Result := Index - 191 + $21;
    286..349:
      Result := Index - 286 + $410;
    350:
      Result := $401;
    351:
      Result := $451;
    352:
      Result := $2122;
  else
    Result := $20;
  end;
end;

function BuiltinRasterize(const Segments: TArray<THSegment>; Scale, XScale, Radius, Shear: Single): TPGFGlyph; forward;

function BuiltinShadow(G: TPGFGlyph): TPGFGlyph; forward;

constructor TPGFBuiltin.Create(Points: Single; Bold, Italic: Boolean);
begin
  inherited Create;
  var EmPx: Single := Points * 128 / 72;
  // Hershey capitals stand 21 units tall.
  var Scale := EmPx / 28;
  var XScale: Single := 0.9;
  var Radius: Single := 0.72 * EmPx / 18;
  if Bold then
    Radius := Radius * 1.6;
  if Radius < 0.55 then
    Radius := 0.55;
  var Shear: Single := 0;
  if Italic then
    Shear := 0.2;
  HSize := Round(Points * 64);
  VSize := HSize;
  HRes := 128 * 64;
  VRes := HRes;
  FirstCode := $20;
  LastCode := $FF5E;
  GlyphCount := 353;
  MaxAdvanceV := Round(EmPx * 64);
  MinCenterX := 0;
  MaxDescender := 0;
  for var Index := 0 to GlyphCount - 1 do
  begin
    var Width: Integer;
    var Segments := HCharacter(BuiltinCode(Index), Width);
    var G := BuiltinRasterize(Segments, Scale, XScale, Radius, Shear);
    G.Advance.X := Round(Width * Scale * XScale * 64);
    // Fullwidth forms and the ideographic space.
    if (Index >= 191) and (Index <= 285) then
    begin
      G.Left := G.Left + Round((EmPx - Width * Scale * XScale) / 2);
      G.Advance.X := MaxAdvanceV;
    end;
    G.Advance.Y := MaxAdvanceV;
    G.Dim.X := G.W * 64;
    G.Dim.Y := G.H * 64;
    G.BearingX.X := G.Left * 64;
    G.BearingX.Y := -(G.W * 32);
    G.BearingY.X := G.Top * 64;
    G.BearingY.Y := 0;
    G.ShadowFlags := $40 or Max(G.W, G.H);
    G.ShadowId := Index;
    G.DataSize := (G.W * G.H + 1) div 2 + 12;
    FGlyphs.Add(Index, G);
    FShadows.Add(Index, BuiltinShadow(G));
    MaxSizeH := Max(MaxSizeH, G.Dim.X);
    MaxSizeV := Max(MaxSizeV, G.Dim.Y);
    MaxAscender := Max(MaxAscender, G.Top * 64);
    MaxDescender := Min(MaxDescender, (G.Top - G.H) * 64);
    MaxLeftX := Max(MaxLeftX, G.Left * 64);
    MinCenterX := Min(MinCenterX, -(G.W * 32));
    MaxAdvanceH := Max(MaxAdvanceH, G.Advance.X);
    MaxGlyphWidth := Max(MaxGlyphWidth, G.W);
    MaxGlyphHeight := Max(MaxGlyphHeight, G.H);
  end;
  MaxBaseY := MaxAscender;
  MaxTopY := 0;
end;

function BuiltinRasterize(const Segments: TArray<THSegment>; Scale, XScale, Radius, Shear: Single): TPGFGlyph;
begin
  Result := TPGFGlyph.Create;
  if Length(Segments) = 0 then
    Exit;
  // Pixel space: x right from the pen, y down from the baseline.
  var S := Copy(Segments);
  var MinX: Single := 1E9;
  var MaxX: Single := -1E9;
  var MinY: Single := 1E9;
  var MaxY: Single := -1E9;
  for var K := 0 to High(S) do
  begin
    var A := S[K];
    S[K].X0 := (A.X0 * XScale + A.Y0 * Shear) * Scale;
    S[K].Y0 := -A.Y0 * Scale;
    S[K].X1 := (A.X1 * XScale + A.Y1 * Shear) * Scale;
    S[K].Y1 := -A.Y1 * Scale;
    MinX := Min(MinX, Min(S[K].X0, S[K].X1));
    MaxX := Max(MaxX, Max(S[K].X0, S[K].X1));
    MinY := Min(MinY, Min(S[K].Y0, S[K].Y1));
    MaxY := Max(MaxY, Max(S[K].Y0, S[K].Y1));
  end;
  var X0 := Floor(MinX - Radius);
  var Y0 := Floor(MinY - Radius);
  var BW := Ceil(MaxX + Radius) - X0;
  var BH := Ceil(MaxY + Radius) - Y0;
  var Cover: TArray<Integer>;
  SetLength(Cover, BW * BH);
  var R2 := Radius * Radius;
  for var J := 0 to BH - 1 do
    for var I := 0 to BW - 1 do
    begin
      var Hits := 0;
      for var SY := 0 to BuiltinSamples - 1 do
        for var SX := 0 to BuiltinSamples - 1 do
        begin
          var PX: Single := X0 + I + (SX + 0.5) / BuiltinSamples;
          var PY: Single := Y0 + J + (SY + 0.5) / BuiltinSamples;
          for var K := 0 to High(S) do
          begin
            var DX := S[K].X1 - S[K].X0;
            var DY := S[K].Y1 - S[K].Y0;
            var Len := DX * DX + DY * DY;
            var T: Single := 0;
            if Len > 0 then
              T := EnsureRange(((PX - S[K].X0) * DX + (PY - S[K].Y0) * DY) / Len, 0, 1);
            var QX := S[K].X0 + T * DX - PX;
            var QY := S[K].Y0 + T * DY - PY;
            if QX * QX + QY * QY <= R2 then
            begin
              Inc(Hits);
              Break;
            end;
          end;
        end;
      Cover[J * BW + I] := (Hits * 15 + (BuiltinSamples * BuiltinSamples) div 2) div (BuiltinSamples * BuiltinSamples);
    end;
  // Crop to the inked pixels.
  var CropL := BW;
  var CropT := BH;
  var CropR := -1;
  var CropB := -1;
  for var J := 0 to BH - 1 do
    for var I := 0 to BW - 1 do
      if Cover[J * BW + I] <> 0 then
      begin
        CropL := Min(CropL, I);
        CropR := Max(CropR, I);
        CropT := Min(CropT, J);
        CropB := Max(CropB, J);
      end;
  if CropR < 0 then
    Exit;
  Result.W := CropR - CropL + 1;
  Result.H := CropB - CropT + 1;
  Result.Left := X0 + CropL;
  Result.Top := -(Y0 + CropT);
  SetLength(Result.Pixels, Result.W * Result.H);
  for var J := 0 to Result.H - 1 do
    for var I := 0 to Result.W - 1 do
      Result.Pixels[J * Result.W + I] := Cover[(CropT + J) * BW + CropL + I];
end;

function BuiltinShadow(G: TPGFGlyph): TPGFGlyph;
begin
  // A soft halo one pixel wider all round.
  Result := TPGFGlyph.Create;
  if G.W * G.H = 0 then
    Exit;
  Result.W := G.W + 2;
  Result.H := G.H + 2;
  Result.Left := G.Left - 1;
  Result.Top := G.Top + 1;
  SetLength(Result.Pixels, Result.W * Result.H);
  for var Y := 0 to Result.H - 1 do
    for var X := 0 to Result.W - 1 do
    begin
      var Sum := 0;
      for var DY := -1 to 1 do
        for var DX := -1 to 1 do
          Inc(Sum, G.Pixel(X - 1 + DX, Y - 1 + DY));
      Result.Pixels[Y * Result.W + X] := Min(15, (Sum + 2) div 3);
    end;
  Result.DataSize := (Result.W * Result.H + 1) div 2 + 6;
end;

function TPGFBuiltin.Lookup(Code: Integer): Integer;
begin
  if Code < FirstCode then
    Result := PGFBelow
  else
    Result := BuiltinIndex(Code);
end;

function TPGFBuiltin.DecodeGlyph(Index: Integer): TPGFGlyph;
begin
  Result := nil;
end;

function TPGFBuiltin.DecodeShadow(Index: Integer): TPGFGlyph;
begin
  Result := nil;
end;

// Libraries, opening and closing fonts.

type
  TPSPInternalFont = record
    Name, FileName: string;
    Family, Style, Language, Country: Word;
    Points: Single;
    // What opening it takes on hardware: mode 0, and the file for mode 1.
    Mode0Size, FileSize: Cardinal;
  end;

const
  // The firmware's font list, in its order.
  InternalFonts: array[0..17] of TPSPInternalFont = (
    (Name: 'FTT-NewRodin Pro DB'; FileName: 'jpn0.pgf'; Family: 1; Style: 103; Language: 1; Country: 1;
      Points: 10.125; Mode0Size: 145844; FileSize: 1581700),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn0.pgf'; Family: 1; Style: 1; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16680; FileSize: 67660),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn1.pgf'; Family: 2; Style: 1; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16920; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn2.pgf'; Family: 1; Style: 2; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16872; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn3.pgf'; Family: 2; Style: 2; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 17112; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn4.pgf'; Family: 1; Style: 5; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16648; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn5.pgf'; Family: 2; Style: 5; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16928; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn6.pgf'; Family: 1; Style: 6; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16792; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn7.pgf'; Family: 2; Style: 6; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 17160; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn8.pgf'; Family: 1; Style: 1; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16192; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn9.pgf'; Family: 2; Style: 1; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16476; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn10.pgf'; Family: 1; Style: 2; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16300; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn11.pgf'; Family: 2; Style: 2; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16656; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn12.pgf'; Family: 1; Style: 5; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16176; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn13.pgf'; Family: 2; Style: 5; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16436; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn14.pgf'; Family: 1; Style: 6; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16272; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn15.pgf'; Family: 2; Style: 6; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16704; FileSize: 0),
    (Name: 'AsiaNHH(512Johab)'; FileName: 'kr0.pgf'; Family: 1; Style: 1; Language: 3; Country: 3;
      Points: 10.125; Mode0Size: 51856; FileSize: 0));

  // How the two fonts the tests open break their mode 0 size down.
  Jpn0Parts: array[0..8] of Cardinal = (2040, 2040, 2040, 848, 1020, 0, 0, 114632, 23224);
  Ltn0Parts: array[0..8] of Cardinal = (2040, 1760, 648, 1144, 648, 0, 0, 9872, 568);
  MaxFontsPerLib = 9;
  LibStructSize = 76;
  FontHandleSize = 76;
  FontRecordSize = 560;
  FontStyleSize = 168;
  FontListSize = Length(InternalFonts) * FontStyleSize;
  MemoryFontSize = 12;
  // Inside a font record: where a mode 0 open reads the header and the
  // error word it hands the file callbacks.
  RecordErrorWord = $220;
  // The free order of the nine mode 0 blocks.
  PartFreeOrder: array[0..8] of Integer = (8, 7, 5, 6, 4, 0, 1, 2, 3);
  // Time the library's own file and kernel calls give other threads.
  NewLibYieldUs = 60;
  FileYieldUs = 120;
  ListYieldUs = 20;

{ TPSPFontData }

destructor TPSPFontData.Destroy;
begin
  if OwnsFont then
    Font.Free;
  Seen.Free;
  inherited;
end;

function TPSPFontData.FirstLook(Index: Integer): Boolean;
begin
  if not Streamed or (Index < 0) then
    Exit(False);
  if Seen = nil then
    Seen := TDictionary<Integer, Boolean>.Create;
  Result := not Seen.ContainsKey(Index);
  if Result then
    Seen.Add(Index, True);
end;

{ TPSPFontLib }

constructor TPSPFontLib.Create;
begin
  inherited Create;
  Slots := TObjectList<TPSPFontSlot>.Create;
  Datas := TObjectList<TPSPFontData>.Create;
end;

destructor TPSPFontLib.Destroy;
begin
  Slots.Free;
  Datas.Free;
  inherited;
end;

{ TPSPFont }

constructor TPSPFont.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FLibs := TObjectDictionary<Cardinal, TPSPFontLib>.Create([doOwnsValues]);
  FSlots := TDictionary<Cardinal, TPSPFontSlot>.Create;
  FFonts := TObjectDictionary<Integer, TPGFFont>.Create([doOwnsValues]);
end;

destructor TPSPFont.Destroy;
begin
  FSlots.Free;
  FLibs.Free;
  FFonts.Free;
  inherited;
end;

procedure TPSPFont.Reset;
begin
  FSlots.Clear;
  FLibs.Clear;
end;

function TPSPFont.FontOf(Handle: Cardinal): TPGFFont;
begin
  var S := SlotOf(Handle);
  if (S = nil) or (S.Data = nil) then
    Result := nil
  else
    Result := S.Data.Font;
end;

function TPSPFont.LibOf(Addr: Cardinal): TPSPFontLib;
begin
  if (Addr = 0) or not FLibs.TryGetValue(Addr, Result) then
    Result := nil;
end;

function TPSPFont.SlotOf(Handle: Cardinal): TPSPFontSlot;
begin
  if (Handle = 0) or not FSlots.TryGetValue(Handle, Result) then
    Result := nil;
end;

procedure TPSPFont.SetError(Ptr, Code: Cardinal);
begin
  if (Ptr <> 0) and FMemory.Valid(Ptr, 4) then
    FMemory.Write32(Ptr, Code);
end;

procedure TPSPFont.Finish(Value: Cardinal; YieldUs: Integer);
begin
  FHLE.Result(Value);
  if (YieldUs <= 0) or not FKernel.CanWait then
    Exit;
  // The library's own kernel calls let other threads run meanwhile.
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, nil, 'font');
  if T.Wait.HLETag <> 'font' then
    Exit;
  // The operation is already done; releasing its internal driver wait does not
  // turn a successfully measured or drawn glyph into an error.
  T.Wait.FailAsZero := Value = 0;
  FKernel.AddWakeTimer(FKernel.Scheduler.Now + Int64(YieldUs) * 1000, T, 'font', Value);
end;

{ Guest calls }

procedure TPSPFont.AllocStep(AllocF, FreeF, UserData: Cardinal; const Sizes, Addrs: TArray<Cardinal>; I: Integer; const Done: IPSPStateAction);
begin
  var A := TPSPStateAction.Create(StateAlloc, [], [AllocF, FreeF, UserData, I], '', Done);
  A.Arrays := [Sizes, Addrs];
  var Keep: IPSPStateAction := A;
  AllocNext(TPSPStateAction(Keep as TObject));
end;

procedure TPSPFont.AllocDone(const Done: IPSPStateAction; const Addrs: TArray<Cardinal>; Ok: Boolean);
begin
  TPSPStateAction(Done as TObject).Results := Copy(Addrs);
  Done.Run(Ord(Ok));
end;

procedure TPSPFont.AllocNext(Action: TPSPStateAction);
begin
  var I := Integer(Action.Arg(3));
  if I > High(Action.Arrays[0]) then
  begin
    AllocDone(Action.Next, Action.Arrays[1], True);
    Exit;
  end;
  FKernel.CallGuest(Cardinal(Action.Arg(0)), [Cardinal(Action.Arg(2)), Action.Arrays[0][I]], nil, 0, Action);
end;

procedure TPSPFont.StateAlloc(Action: TPSPStateAction; Value: Cardinal);
begin
  var I := Integer(Action.Arg(3));
  if (Value = 0) and (Action.Arrays[0][I] <> 0) then
  begin
    var Back: TArray<Cardinal>;
    SetLength(Back, I);
    for var K := 0 to I - 1 do
      Back[K] := Action.Arrays[1][I - 1 - K];
    FreeStep(Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2)), Back, 0, TPSPStateAction.Create(StateAllocFailed, [], [],
        '', Action.Next));
    Exit;
  end;
  Action.Arrays[1][I] := Value;
  Inc(Action.Values[3]);
  AllocNext(Action);
end;

procedure TPSPFont.StateAllocFailed(Action: TPSPStateAction; Value: Cardinal);
begin
  AllocDone(Action.Next, nil, False);
end;

procedure TPSPFont.AllocBlocks(Lib: TPSPFontLib; const Sizes: TArray<Cardinal>; const Done: IPSPStateAction);
begin
  var Addrs: TArray<Cardinal>;
  SetLength(Addrs, Length(Sizes));
  var AllocF := FMemory.Read32(Lib.Addr + $0C);
  var FreeF := FMemory.Read32(Lib.Addr + $10);
  if AllocF = 0 then
  begin
    AllocDone(Done, nil, False);
    Exit;
  end;
  AllocStep(AllocF, FreeF, FMemory.Read32(Lib.Addr), Sizes, Addrs, 0, Done);
end;

procedure TPSPFont.FreeStep(FreeF, UserData: Cardinal; const Addrs: TArray<Cardinal>; I: Integer; const Done: IPSPStateAction);
begin
  var A := TPSPStateAction.Create(StateFree, [], [FreeF, UserData, I], '', Done);
  A.Arrays := [Addrs];
  var Keep: IPSPStateAction := A;
  FreeNext(TPSPStateAction(Keep as TObject));
end;

procedure TPSPFont.FreeNext(Action: TPSPStateAction);
begin
  var I := Integer(Action.Arg(2));
  var Addrs := Action.Arrays[0];
  while (I <= High(Addrs)) and (Addrs[I] = 0) do
    Inc(I);
  if (I > High(Addrs)) or (Action.Arg(0) = 0) then
  begin
    Action.Next.Run;
    Exit;
  end;
  Action.Values[2] := I;
  FKernel.CallGuest(Cardinal(Action.Arg(0)), [Cardinal(Action.Arg(1)), Addrs[I]], nil, 0, Action);
end;

procedure TPSPFont.StateFree(Action: TPSPStateAction; Value: Cardinal);
begin
  Inc(Action.Values[2]);
  FreeNext(Action);
end;

procedure TPSPFont.StateResult(Action: TPSPStateAction; Value: Cardinal);
begin
  FHLE.Result(Cardinal(Action.Arg(0)));
end;

procedure TPSPFont.StateLibAllocated(Action: TPSPStateAction; Value: Cardinal);
begin
  var ErrPtr := Cardinal(Action.Arg(1));
  if Value = 0 then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_NOMEMORY);
    FHLE.Result(0);
    Exit;
  end;
  var Lib := CreateLib(Action.Results, Integer(Action.Arg(0)), Action.Data);
  SetError(ErrPtr, 0);
  Finish(Lib.Addr, NewLibYieldUs);
end;

procedure TPSPFont.FreeBlocks(Lib: TPSPFontLib; const Addrs: TArray<Cardinal>; const Done: IPSPStateAction);
begin
  FreeStep(FMemory.Read32(Lib.Addr + $10), FMemory.Read32(Lib.Addr), Addrs, 0, Done);
end;

procedure TPSPFont.RunIO(const IO: TFontIO; const Ops: TArray<TFontIOOp>; I: Integer; const Done, Fail: IPSPStateAction);
begin
  var A := TPSPStateAction.Create(StateIO, [],
    [IO.UserData, IO.OpenF, IO.CloseF, IO.ReadF, IO.SeekF, IO.FH, IO.ErrAddr, I], '', Done);
  A.Failure := Fail;
  SetLength(A.Arrays, 1);
  SetLength(A.Arrays[0], Length(Ops) * 4);
  for var K := 0 to High(Ops) do
  begin
    A.Arrays[0][K * 4] := Ord(Ops[K].Kind);
    A.Arrays[0][K * 4 + 1] := Ops[K].A;
    A.Arrays[0][K * 4 + 2] := Ops[K].B;
    A.Arrays[0][K * 4 + 3] := Ops[K].C;
  end;
  var Keep: IPSPStateAction := A;
  IONext(TPSPStateAction(Keep as TObject));
end;

procedure TPSPFont.IONext(Action: TPSPStateAction);
begin
  var I := Integer(Action.Arg(7));
  if I >= Length(Action.Arrays[0]) div 4 then
  begin
    Action.Next.Run;
    Exit;
  end;
  var Op := Action.Arrays[0];
  var U := Cardinal(Action.Arg(0));
  var FH := Cardinal(Action.Arg(5));
  case TFontIOKind(Op[I * 4]) of
    fiSeek:
      FKernel.CallGuest(Cardinal(Action.Arg(4)), [U, FH, Op[I * 4 + 1]], nil, 0, Action);
    fiRead:
      begin
        var Err := Cardinal(Action.Arg(6));
        FMemory.Write32(Err, 0);
        FKernel.CallGuest(Cardinal(Action.Arg(3)), [U, FH, Op[I * 4 + 1], Op[I * 4 + 2], Op[I * 4 + 3], Err], nil,
          0, Action);
      end;
    fiClose:
      FKernel.CallGuest(Cardinal(Action.Arg(2)), [U, FH], nil, 0, Action);
  end;
end;

procedure TPSPFont.StateIO(Action: TPSPStateAction; Value: Cardinal);
begin
  var I := Integer(Action.Arg(7));
  var Kind := TFontIOKind(Action.Arrays[0][I * 4]);
  if (Kind = fiSeek) and (Value <> 0) then
  begin
    Action.Failure.Run(SCE_FONT_ERROR_FILESEEK);
    Exit;
  end;
  if (Kind = fiRead) and ((Value <> Action.Arrays[0][I * 4 + 3]) or (FMemory.Read32(Cardinal(Action.Arg(6))) <> 0)) then
  begin
    Action.Failure.Run(SCE_FONT_ERROR_FILEREAD);
    Exit;
  end;
  Inc(Action.Values[7]);
  IONext(Action);
end;

function IOOp(Kind: TFontIOKind; A: Cardinal = 0; B: Cardinal = 0; C: Cardinal = 0): TFontIOOp;
begin
  Result.Kind := Kind;
  Result.A := A;
  Result.B := B;
  Result.C := C;
end;

{ Libraries }

procedure TPSPFont.RemoveLib(Addr: Cardinal);
begin
  var Lib := LibOf(Addr);
  if Lib = nil then
    Exit;
  for var S in Lib.Slots do
  begin
    var Cur: TPSPFontSlot;
    if FSlots.TryGetValue(S.Handle, Cur) and (Cur = S) then
      FSlots.Remove(S.Handle);
  end;
  FLibs.Remove(Addr);
end;

procedure TPSPFont.WriteStyle(Addr: Cardinal; Index: Integer);
begin
  var E := InternalFonts[Index];
  FMemory.Fill(Addr, 0, FontStyleSize);
  FMemory.WriteFloat(Addr, E.Points);
  FMemory.WriteFloat(Addr + 4, E.Points);
  FMemory.WriteFloat(Addr + 8, 128);
  FMemory.WriteFloat(Addr + 12, 128);
  FMemory.Write16(Addr + 20, E.Family);
  FMemory.Write16(Addr + 22, E.Style);
  FMemory.Write16(Addr + 26, E.Language);
  FMemory.Write16(Addr + 30, E.Country);
  FMemory.WriteString(Addr + 32, RawByteString(E.Name), 64);
  FMemory.WriteString(Addr + 96, RawByteString(E.FileName), 64);
end;

function TPSPFont.CreateLib(const Addrs: TArray<Cardinal>; Count: Integer; const Params: TBytes): TPSPFontLib;
begin
  var A := Addrs[0];
  // Memory freed by a library that is done can come back for a new one.
  RemoveLib(A);
  FMemory.Fill(A, 0, LibStructSize);
  FMemory.WriteBytes(A, Params[0], Length(Params));
  FMemory.Write32(A + $2C, Addrs[1]);
  FMemory.Write32(A + $30, Addrs[2]);
  FMemory.WriteFloat(A + $38, 128);
  FMemory.WriteFloat(A + $3C, 128);
  FMemory.Write32(A + $40, Length(InternalFonts));
  FMemory.Write32(A + $44, Addrs[3]);
  FMemory.Write16(A + $48, Ord('_'));
  FMemory.Fill(Addrs[1], 0, FontHandleSize * Count);
  FMemory.Fill(Addrs[2], 0, FontRecordSize * Count);
  for var I := 0 to High(InternalFonts) do
    WriteStyle(Addrs[3] + Cardinal(I * FontStyleSize), I);
  Result := TPSPFontLib.Create;
  Result.Addr := A;
  Result.Blocks := Copy(Addrs);
  for var I := 0 to Count - 1 do
  begin
    var S := TPSPFontSlot.Create;
    S.Lib := Result;
    S.Handle := Addrs[1] + Cardinal(I * FontHandleSize);
    S.Memory := Addrs[2] + Cardinal(I * FontRecordSize);
    FMemory.Write32(S.Handle, A);
    FMemory.Write32(S.Handle + 4, S.Memory);
    Result.Slots.Add(S);
    FSlots.AddOrSetValue(S.Handle, S);
  end;
  FLibs.Add(A, Result);
end;

procedure TPSPFont.hNewLib;
begin
  var Params := FHLE.Arg(0);
  var ErrPtr := FHLE.Arg(1);
  if (Params = 0) or not FMemory.Valid(Params, $2C) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var UserData := FMemory.Read32(Params);
  var AllocF := FMemory.Read32(Params + $0C);
  var FreeF := FMemory.Read32(Params + $10);
  if (AllocF = 0) or (FreeF = 0) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Count := Integer(Min(FMemory.Read32(Params + 4), Cardinal(MaxFontsPerLib)));
  var Copied: TBytes;
  SetLength(Copied, $2C);
  FMemory.ReadBytes(Params, Copied[0], $2C);
  var Sizes: TArray<Cardinal> := [LibStructSize, FontHandleSize * Count, FontRecordSize * Count, FontListSize];
  var Addrs: TArray<Cardinal>;
  SetLength(Addrs, Length(Sizes));
  var A := TPSPStateAction.Create(StateLibAllocated, [], [Count, ErrPtr]);
  A.Data := Copied;
  AllocStep(AllocF, FreeF, UserData, Sizes, Addrs, 0, A);
end;

procedure TPSPFont.hDoneLib;
begin
  var Lib := LibOf(FHLE.Arg(0));
  if (Lib = nil) or Lib.Done then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  Lib.Done := True;
  // Fonts still open go first, then the library's own blocks.
  var Addrs: TArray<Cardinal> := nil;
  for var D in Lib.Datas do
    if D.Refs > 0 then
    begin
      D.Refs := 0;
      Addrs := Addrs + D.Blocks + D.Cache;
      D.Cache := nil;
    end;
  for var S in Lib.Slots do
    S.Busy := False;
  Addrs := Addrs + [Lib.Blocks[3], Lib.Blocks[1], Lib.Blocks[2], Lib.Blocks[0]];
  FHLE.Result(0);
  FreeBlocks(Lib, Addrs, TPSPStateAction.Create(StateResult, [], [0]));
end;

{ Opening }

function TPSPFont.FreeSlot(Lib: TPSPFontLib): TPSPFontSlot;
begin
  for var S in Lib.Slots do
    if not S.Busy then
      Exit(S);
  Result := nil;
end;

function TPSPFont.SharedData(Lib: TPSPFontLib; const Key: string): TPSPFontData;
begin
  for var D in Lib.Datas do
    if (D.Refs > 0) and (D.Key = Key) then
      Exit(D);
  Result := nil;
end;

function TPSPFont.AddData(Lib: TPSPFontLib; const Key: string; Font: TPGFFont; Owns: Boolean; const Blocks: TArray<Cardinal>): TPSPFontData;
begin
  Result := TPSPFontData.Create;
  Result.Key := Key;
  Result.Font := Font;
  Result.OwnsFont := Owns;
  Result.Blocks := Blocks;
  Result.CacheKey := -1;
  Lib.Datas.Add(Result);
end;

procedure TPSPFont.Attach(Slot: TPSPFontSlot; Data: TPSPFontData);
begin
  Slot.Busy := True;
  Slot.Data := Data;
  Inc(Data.Refs);
end;

function PartsFreeOrder(const Parts: TArray<Cardinal>): TArray<Cardinal>;
begin
  SetLength(Result, Length(Parts));
  if Length(Parts) = 9 then
    for var K := 0 to 8 do
      Result[K] := Parts[PartFreeOrder[K]]
  else
    for var K := 0 to High(Parts) do
      Result[K] := Parts[High(Parts) - K];
end;

function TPSPFont.InternalFont(Index: Integer): TPGFFont;
begin
  if FFonts.TryGetValue(Index, Result) then
    Exit;
  var E := InternalFonts[Index];
  Result := nil;
  var Data: TBytes;
  if FSystem.FontDirectory <> '' then
  begin
    var Path := TPath.Combine(FSystem.FontDirectory, E.FileName);
    if TFile.Exists(Path) and (TFile.GetSize(Path) <= 16 * 1024 * 1024) then
    try
      Data := TFile.ReadAllBytes(Path);
      Result := TPGFFile.Parse(Data);
    except
      on X: Exception do
        FHLE.Log('font: cannot read %s (%s)', [E.FileName, X.Message]);
    end;
  end;
  if (Result = nil) and (FSystem.FlashRoot <> '') and (FSystem.IO.ReadAll('flash0:/font/' + E.FileName, Data) = 0) then
    Result := TPGFFile.Parse(Data);
  if Result = nil then
  begin
    var Bold := E.Style in [5, 6, 103];
    var Italic := E.Style in [2, 6];
    Result := TPGFBuiltin.Create(E.Points, Bold, Italic);
    Result.FileSize := E.FileSize;
    case Index of
      0:
        Result.Parts := TArray<Cardinal>.Create(Jpn0Parts[0], Jpn0Parts[1], Jpn0Parts[2], Jpn0Parts[3], Jpn0Parts[4],
          Jpn0Parts[5], Jpn0Parts[6], Jpn0Parts[7], Jpn0Parts[8]);
      1:
        Result.Parts := TArray<Cardinal>.Create(Ltn0Parts[0], Ltn0Parts[1], Ltn0Parts[2], Ltn0Parts[3], Ltn0Parts[4],
          Ltn0Parts[5], Ltn0Parts[6], Ltn0Parts[7], Ltn0Parts[8]);
    else
      Result.Parts := [E.Mode0Size];
    end;
  end;
  FFonts.Add(Index, Result);
end;

procedure TPSPFont.hOpen;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Index := FHLE.ArgInt(1);
  var Mode := FHLE.ArgInt(2);
  var ErrPtr := FHLE.Arg(3);
  if (Lib = nil) or Lib.Done then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  if (Index < 0) or (Index > High(InternalFonts)) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Slot := FreeSlot(Lib);
  if Slot = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_TOOMANYOPENED);
    FHLE.Result(0);
    Exit;
  end;
  var Whole := Mode = 1;
  var Key := Format('font%d:%d', [Ord(Whole), Index]);
  var Shared := SharedData(Lib, Key);
  if Shared <> nil then
  begin
    Attach(Slot, Shared);
    SetError(ErrPtr, 0);
    FHLE.Result(Slot.Handle);
    Exit;
  end;
  var Font := InternalFont(Index);
  var Sizes: TArray<Cardinal>;
  if Whole and (Font.FileSize <> 0) then
    Sizes := [Font.FileSize, MemoryFontSize]
  else
  begin
    Sizes := Copy(Font.Parts);
    Whole := False;
  end;
  Slot.Busy := True;
  AllocBlocks(Lib, Sizes, TPSPStateAction.Create(StateOpened, [Lib, Slot, Font], [ErrPtr, Ord(Whole)], Key));
end;

function TPSPFont.GuestBytes(Addr, Size: Cardinal): TBytes;
const
  Cap = 64 * 1024 * 1024;
begin
  // As much of the image as is mapped: a size past the font's end is fine.
  var N := Min(Size, Cardinal(Cap));
  if not FMemory.Valid(Addr, N) then
  begin
    var Lo: Cardinal := 0;
    var Hi := N;
    while Lo + 1 < Hi do
    begin
      var Mid := Lo + (Hi - Lo) div 2;
      if FMemory.Valid(Addr, Mid) then
        Lo := Mid
      else
        Hi := Mid;
    end;
    N := Lo;
  end;
  SetLength(Result, N);
  if N > 0 then
    FMemory.ReadBytes(Addr, Result[0], N);
end;

procedure TPSPFont.hOpenUserMemory;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Addr := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  var ErrPtr := FHLE.Arg(3);
  if (Lib = nil) or Lib.Done then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  if (Addr = 0) or (Size = 0) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Slot := FreeSlot(Lib);
  if Slot = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_TOOMANYOPENED);
    FHLE.Result(0);
    Exit;
  end;
  var Key := 'memory:' + IntToHex(Addr, 8);
  var Shared := SharedData(Lib, Key);
  if Shared <> nil then
  begin
    Attach(Slot, Shared);
    SetError(ErrPtr, 0);
    FHLE.Result(Slot.Handle);
    Exit;
  end;
  var Font := TPGFFile.Parse(GuestBytes(Addr, Size));
  if Font = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_DATAINCONSISTENT);
    FHLE.Result(0);
    Exit;
  end;
  Slot.Busy := True;
  var A := TPSPStateAction.Create(StateOpened, [Lib, Slot, Font], [ErrPtr, 2], Key);
  A.Own(Font);
  AllocBlocks(Lib, [MemoryFontSize], A);
end;

procedure TPSPFont.hOpenUserFile;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var NamePtr := FHLE.Arg(1);
  var Mode := FHLE.ArgInt(2);
  var ErrPtr := FHLE.Arg(3);
  if (Lib = nil) or Lib.Done then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  if NamePtr = 0 then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Name := FMemory.ReadString(NamePtr, 256);
  if Mode = 1 then
    OpenWhole(Lib, Name, ErrPtr)
  else
    OpenStreamed(Lib, NamePtr, Name, ErrPtr);
end;

procedure TPSPFont.OpenWhole(Lib: TPSPFontLib; const Name: string; ErrPtr: Cardinal);
begin
  // Mode 1: the library reads the whole file itself.
  var Slot := FreeSlot(Lib);
  if Slot = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_TOOMANYOPENED);
    FHLE.Result(0);
    Exit;
  end;
  var Key := 'file1:' + Name;
  var Shared := SharedData(Lib, Key);
  if Shared <> nil then
  begin
    Attach(Slot, Shared);
    SetError(ErrPtr, 0);
    FHLE.Result(Slot.Handle);
    Exit;
  end;
  var Data: TBytes;
  if FSystem.IO.ReadAll(Name, Data) <> 0 then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_FILEOPEN);
    Finish(0, FileYieldUs);
    Exit;
  end;
  var Font := TPGFFile.Parse(Data);
  if Font = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_DATAINCONSISTENT);
    Finish(0, FileYieldUs);
    Exit;
  end;
  Slot.Busy := True;
  var A := TPSPStateAction.Create(StateOpened, [Lib, Slot, Font], [ErrPtr, 3], Key);
  A.Own(Font);
  AllocBlocks(Lib, [Font.FileSize, MemoryFontSize], A);
end;

procedure TPSPFont.StateOpened(Action: TPSPStateAction; Value: Cardinal);
begin
  var Lib := TPSPFontLib(Action.Obj(0));
  var Slot := TPSPFontSlot(Action.Obj(1));
  var Font := TPGFFont(Action.Obj(2));
  var ErrPtr := Cardinal(Action.Arg(0));
  var Mode := Integer(Action.Arg(1));
  if Value = 0 then
  begin
    Slot.Busy := False;
    SetError(ErrPtr, SCE_FONT_ERROR_NOMEMORY);
    FHLE.Result(0);
    Exit;
  end;
  var Blocks := Action.Results;
  if Mode < 2 then
    Blocks := PartsFreeOrder(Blocks)
  else if Mode = 3 then
    Blocks := [Blocks[1], Blocks[0]];
  var D := AddData(Lib, Action.Text, Font, Mode >= 2, Blocks);
  if Mode >= 2 then
    Action.Disown(Font);
  D.Streamed := Mode = 0;
  Attach(Slot, D);
  SetError(ErrPtr, 0);
  if Mode = 2 then
    FHLE.Result(Slot.Handle)
  else
    Finish(Slot.Handle, FileYieldUs);
end;

procedure TPSPFont.OpenStreamed(Lib: TPSPFontLib; NamePtr: Cardinal; const Name: string; ErrPtr: Cardinal);
begin
  // Mode 0: header and tables come through the program's file callbacks,
  // the glyphs as they are drawn.
  var IO: TFontIO;
  IO.UserData := FMemory.Read32(Lib.Addr);
  IO.OpenF := FMemory.Read32(Lib.Addr + $14);
  IO.CloseF := FMemory.Read32(Lib.Addr + $18);
  IO.ReadF := FMemory.Read32(Lib.Addr + $1C);
  IO.SeekF := FMemory.Read32(Lib.Addr + $20);
  if (IO.OpenF = 0) or (IO.CloseF = 0) or (IO.ReadF = 0) or (IO.SeekF = 0) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Slot := FreeSlot(Lib);
  if Slot = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_TOOMANYOPENED);
    FHLE.Result(0);
    Exit;
  end;
  var Key := 'file0:' + Name;
  var Shared := SharedData(Lib, Key);
  if Shared <> nil then
  begin
    Attach(Slot, Shared);
    SetError(ErrPtr, 0);
    FHLE.Result(Slot.Handle);
    Exit;
  end;
  Slot.Busy := True;
  var Mem := Slot.Memory;
  IO.ErrAddr := Mem + RecordErrorWord;
  var A := TPSPStateAction.Create(StateStreamOpened, [Lib, Slot],
    [IO.UserData, IO.OpenF, IO.CloseF, IO.ReadF, IO.SeekF, 0, IO.ErrAddr, NamePtr, ErrPtr, Mem, 0, 0, 0, 0]);
  A.Texts := [Name, Key];
  FMemory.Write32(IO.ErrAddr, 0);
  FKernel.CallGuest(IO.OpenF, [IO.UserData, NamePtr, IO.ErrAddr], nil, 0, A);
end;

function TPSPFont.StreamIO(Action: TPSPStateAction): TFontIO;
begin
  Result.UserData := Cardinal(Action.Arg(0));
  Result.OpenF := Cardinal(Action.Arg(1));
  Result.CloseF := Cardinal(Action.Arg(2));
  Result.ReadF := Cardinal(Action.Arg(3));
  Result.SeekF := Cardinal(Action.Arg(4));
  Result.FH := Cardinal(Action.Arg(5));
  Result.ErrAddr := Cardinal(Action.Arg(6));
end;

procedure TPSPFont.StreamFail(Action: TPSPStateAction; Error: Cardinal; Close: Boolean);
begin
  Action.Values[11] := Error;
  Action.Values[12] := Ord(Close);
  Action.Handler := StateStreamFailClose;
  if Action.Arg(13) <> 0 then
  begin
    Action.Values[13] := 0;
    FreeBlocks(TPSPFontLib(Action.Obj(0)), PartsFreeOrder(Action.Results), Action);
  end
  else
    StateStreamFailClose(Action, 0);
end;

procedure TPSPFont.StateStreamFailClose(Action: TPSPStateAction; Value: Cardinal);
begin
  Action.Handler := StateStreamError;
  if Action.Arg(12) <> 0 then
    RunIO(StreamIO(Action), [IOOp(fiClose)], 0, Action, Action)
  else
    StateStreamError(Action, 0);
end;

procedure TPSPFont.StateStreamError(Action: TPSPStateAction; Value: Cardinal);
begin
  TPSPFontSlot(Action.Obj(1)).Busy := False;
  if Value = 0 then
    Value := Cardinal(Action.Arg(11));
  SetError(Cardinal(Action.Arg(8)), Value);
  FHLE.Result(0);
end;

procedure TPSPFont.StateStreamIOFailed(Action: TPSPStateAction; Value: Cardinal);
begin
  StreamFail(TPSPStateAction(Action.Next as TObject), Value, True);
end;

procedure TPSPFont.StateStreamOpened(Action: TPSPStateAction; Value: Cardinal);
begin
  var IO := StreamIO(Action);
  if FMemory.Read32(IO.ErrAddr) <> 0 then
  begin
    StreamFail(Action, SCE_FONT_ERROR_FILEOPEN, False);
    Exit;
  end;
  Action.Values[5] := Value;
  IO.FH := Value;
  Action.Handler := StateStreamShortRead;
  RunIO(IO, [IOOp(fiSeek, 0), IOOp(fiRead, Cardinal(Action.Arg(9)), $C, 1)], 0, Action,
    TPSPStateAction.Create(StateStreamIOFailed, [], [], '', Action));
end;

procedure TPSPFont.StateStreamShortRead(Action: TPSPStateAction; Value: Cardinal);
begin
  var Mem := Cardinal(Action.Arg(9));
  var HeaderSize := FMemory.Read16(Mem + 2);
  if (HeaderSize < $188) or (HeaderSize > RecordErrorWord) then
  begin
    StreamFail(Action, SCE_FONT_ERROR_DATAINCONSISTENT, True);
    Exit;
  end;
  Action.Values[10] := HeaderSize;
  Action.Handler := StateStreamHeaderRead;
  RunIO(StreamIO(Action), [IOOp(fiRead, Mem + $C, HeaderSize - $C, 1)], 0, Action,
    TPSPStateAction.Create(StateStreamIOFailed, [], [], '', Action));
end;

procedure TPSPFont.StateStreamHeaderRead(Action: TPSPStateAction; Value: Cardinal);
begin
  SetLength(Action.Data, Action.Arg(10));
  FMemory.ReadBytes(Cardinal(Action.Arg(9)), Action.Data[0], Length(Action.Data));
  var L: TPGFLayout;
  if not L.Read(Action.Data) then
  begin
    StreamFail(Action, SCE_FONT_ERROR_DATAINCONSISTENT, True);
    Exit;
  end;
  var Sizes: TArray<Cardinal>;
  SetLength(Sizes, 9);
  for var K := 0 to 8 do
    Sizes[K] := L.Parts[K];
  Action.Handler := StateStreamAllocated;
  AllocBlocks(TPSPFontLib(Action.Obj(0)), Sizes, Action);
end;

procedure TPSPFont.StateStreamAllocated(Action: TPSPStateAction; Value: Cardinal);
begin
  if Value = 0 then
  begin
    StreamFail(Action, SCE_FONT_ERROR_NOMEMORY, True);
    Exit;
  end;
  Action.Values[13] := 1;
  var L: TPGFLayout;
  if not L.Read(Action.Data) then
  begin
    StreamFail(Action, SCE_FONT_ERROR_DATAINCONSISTENT, True);
    Exit;
  end;
  var Addrs := Action.Results;
  var Ops: TArray<TFontIOOp> := [IOOp(fiSeek, L.HeaderSize), IOOp(fiSeek, L.HeaderSize)];
  for var K := 0 to 3 do
    if L.TableLength[K] > 0 then
      Ops := Ops + [IOOp(fiRead, Addrs[K], 8, L.TableLength[K])];
  Ops := Ops + [IOOp(fiSeek, Cardinal(L.ShadowMapPos))];
  for var K := 4 to 8 do
    if L.Parts[K] > 0 then
      Ops := Ops + [IOOp(fiRead, Addrs[K], L.Parts[K], 1)];
  Ops := Ops + [IOOp(fiClose)];
  Action.Handler := StateStreamTablesRead;
  RunIO(StreamIO(Action), Ops, 0, Action, TPSPStateAction.Create(StateStreamIOFailed, [], [], '', Action));
end;

procedure TPSPFont.StateStreamTablesRead(Action: TPSPStateAction; Value: Cardinal);
begin
  var L: TPGFLayout;
  if not L.Read(Action.Data) then
  begin
    StreamFail(Action, SCE_FONT_ERROR_DATAINCONSISTENT, False);
    Exit;
  end;
  var Addrs := Action.Results;
  var Font: TPGFFile := nil;
  var Data: TBytes;
  if FSystem.IO.ReadAll(Action.Texts[0], Data) = 0 then
    Font := TPGFFile.Parse(Data);
  if Font = nil then
  begin
    SetLength(Data, L.GlyphPos);
    FillChar(Data[0], Length(Data), 0);
    Move(Action.Data[0], Data[0], Length(Action.Data));
    var Pos := L.HeaderSize;
    for var K := 0 to 3 do
    begin
      FMemory.ReadBytes(Addrs[K], Data[Pos], L.Parts[K]);
      Inc(Pos, L.Parts[K]);
    end;
    FMemory.ReadBytes(Addrs[4], Data[L.ShadowMapPos], L.Parts[4]);
    FMemory.ReadBytes(Addrs[7], Data[L.CharMapPos], L.Parts[7]);
    FMemory.ReadBytes(Addrs[8], Data[L.CharPtrPos], L.Parts[8]);
    Font := TPGFFile.Parse(Data);
  end;
  if Font = nil then
  begin
    StreamFail(Action, SCE_FONT_ERROR_DATAINCONSISTENT, False);
    Exit;
  end;
  var Lib := TPSPFontLib(Action.Obj(0));
  var Slot := TPSPFontSlot(Action.Obj(1));
  var D := AddData(Lib, Action.Texts[1], Font, True, PartsFreeOrder(Addrs));
  Action.Values[13] := 0;
  D.Streamed := True;
  Attach(Slot, D);
  SetError(Cardinal(Action.Arg(8)), 0);
  FHLE.Result(Slot.Handle);
end;

procedure TPSPFont.hClose;
begin
  var Slot := SlotOf(FHLE.Arg(0));
  if Slot = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  FHLE.Result(0);
  if not Slot.Busy or (Slot.Data = nil) then
    Exit;
  Slot.Busy := False;
  var D := Slot.Data;
  Dec(D.Refs);
  if D.Refs > 0 then
    Exit;
  var Addrs := D.Blocks + D.Cache;
  D.Cache := nil;
  D.CacheKey := -1;
  FreeBlocks(Slot.Lib, Addrs, TPSPStateAction.Create(StateResult, [], [0]));
end;

// Font information, drawing glyphs, the font list and its searches.

function TPSPFont.Resolve(Slot: TPSPFontSlot; Code: Integer): Integer;
begin
  var Font := Slot.Data.Font;
  Result := Font.Lookup(Code);
  if Result = PGFMissing then
  begin
    Result := Font.Lookup(FMemory.Read16(Slot.Lib.Addr + $48));
    if Result < 0 then
      Result := PGFBelow;
  end;
end;

procedure TPSPFont.hGetFontInfo;
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Info := FHLE.Arg(1);
  if (Slot = nil) or (Slot.Data = nil) or (Info = 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  var F := Slot.Data.Font;
  var Ints: TArray<Integer> := [F.MaxSizeH, F.MaxSizeV, F.MaxAscender, F.MaxDescender, F.MaxLeftX, F.MaxBaseY,
      F.MinCenterX, F.MaxTopY, F.MaxAdvanceH, F.MaxAdvanceV];
  for var I := 0 to 9 do
  begin
    FMemory.Write32(Info + Cardinal(I * 4), Cardinal(Ints[I]));
    FMemory.WriteFloat(Info + 40 + Cardinal(I * 4), Ints[I] / 64);
  end;
  FMemory.Write16(Info + 80, Word(F.MaxGlyphWidth));
  FMemory.Write16(Info + 82, Word(F.MaxGlyphHeight));
  FMemory.Write32(Info + 84, Cardinal(F.GlyphCount));
  FMemory.Write32(Info + 88, 0);
  // Of the style only the size and resolution are the font's.
  FMemory.Fill(Info + 92, 0, FontStyleSize);
  FMemory.WriteFloat(Info + 92, F.HSize / 64);
  FMemory.WriteFloat(Info + 96, F.VSize / 64);
  FMemory.WriteFloat(Info + 100, F.HRes / 64);
  FMemory.WriteFloat(Info + 104, F.VRes / 64);
  FMemory.Write8(Info + 260, Byte(F.Bpp));
  FHLE.Result(0);
end;

procedure TPSPFont.WriteCharInfo(Addr: Cardinal; G, Bitmap: TPGFGlyph);
begin
  FMemory.Fill(Addr, 0, 60);
  if G = nil then
    Exit;
  if Bitmap <> nil then
  begin
    FMemory.Write32(Addr, Cardinal(Bitmap.W));
    FMemory.Write32(Addr + 4, Cardinal(Bitmap.H));
    FMemory.Write32(Addr + 8, Cardinal(Bitmap.Left));
    FMemory.Write32(Addr + 12, Cardinal(Bitmap.Top));
  end;
  FMemory.Write32(Addr + 16, Cardinal(G.Dim.X));
  FMemory.Write32(Addr + 20, Cardinal(G.Dim.Y));
  FMemory.Write32(Addr + 24, Cardinal(G.BearingY.X));
  FMemory.Write32(Addr + 28, Cardinal(G.BearingY.X - G.Dim.Y));
  FMemory.Write32(Addr + 32, Cardinal(G.BearingX.X));
  FMemory.Write32(Addr + 36, Cardinal(G.BearingY.X));
  FMemory.Write32(Addr + 40, Cardinal(G.BearingX.Y));
  FMemory.Write32(Addr + 44, Cardinal(G.BearingY.Y));
  FMemory.Write32(Addr + 48, Cardinal(G.Advance.X));
  FMemory.Write32(Addr + 52, Cardinal(G.Advance.Y));
  FMemory.Write16(Addr + 56, Word(G.ShadowFlags));
  FMemory.Write16(Addr + 58, Word(G.ShadowId));
end;

procedure TPSPFont.InfoCall(Shadow: Boolean);
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Code := Integer(FHLE.Arg(1) and $FFFF);
  var Info := FHLE.Arg(2);
  if (Slot = nil) or (Slot.Data = nil) or (Info = 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  var Index := Resolve(Slot, Code);
  var G := Slot.Data.Font.Glyph(Index);
  var Bitmap := G;
  if Shadow then
    Bitmap := Slot.Data.Font.Shadow(Index);
  WriteCharInfo(Info, G, Bitmap);
  if Slot.Data.FirstLook(Index) then
    Finish(0, FileYieldUs)
  else
    FHLE.Result(0);
end;

procedure TPSPFont.hGetCharInfo;
begin
  InfoCall(False);
end;

procedure TPSPFont.hGetShadowInfo;
begin
  InfoCall(True);
end;

procedure TPSPFont.RectCall(Shadow: Boolean);
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Code := Integer(FHLE.Arg(1) and $FFFF);
  var Rect := FHLE.Arg(2);
  if (Slot = nil) or (Slot.Data = nil) or (Rect = 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  var Index := Resolve(Slot, Code);
  var G: TPGFGlyph;
  if Shadow then
    G := Slot.Data.Font.Shadow(Index)
  else
    G := Slot.Data.Font.Glyph(Index);
  if G = nil then
    FMemory.Write32(Rect, 0)
  else
  begin
    FMemory.Write16(Rect, Word(G.W));
    FMemory.Write16(Rect + 2, Word(G.H));
  end;
  if Slot.Data.FirstLook(Index) then
    Finish(0, FileYieldUs)
  else
    FHLE.Result(0);
end;

procedure TPSPFont.hGetCharImageRect;
begin
  RectCall(False);
end;

procedure TPSPFont.hGetShadowImageRect;
begin
  RectCall(True);
end;

{ Drawing }

procedure TPSPFont.Draw(G: TPGFGlyph; Image: Cardinal; ClipX, ClipY, ClipW, ClipH: Integer);
begin
  // The glyph's top left goes at the pen; a fraction of a pixel in x splits
  // each column over two, the near part rounded up and the far one down, and
  // the result adds to what the buffer holds, saturating. Only the 4 and
  // 8 bit formats draw.
  var Format := FMemory.Read32(Image);
  if (Format <> 0) and (Format <> 2) then
    Exit;
  var XPos := Integer(FMemory.Read32(Image + 4));
  var YPos := Integer(FMemory.Read32(Image + 8));
  var BufW := Integer(FMemory.Read16(Image + 12));
  var BufH := Integer(FMemory.Read16(Image + 14));
  var Pitch := Integer(SmallInt(FMemory.Read16(Image + 16)));
  var Buf := FMemory.Read32(Image + 20);
  var X0 := XPos div 64;
  if (XPos < 0) and (XPos mod 64 <> 0) then
    Dec(X0);
  var Frac := XPos - X0 * 64;
  var Y0 := YPos div 64;
  if (YPos < 0) and (YPos mod 64 <> 0) then
    Dec(Y0);
  var Cols := G.W;
  if Frac <> 0 then
    Inc(Cols);
  var Scale := 1;
  if Format = 2 then
    Scale := 17;
  for var R := 0 to G.H - 1 do
  begin
    var DY := Y0 + R;
    if (DY < 0) or (DY >= BufH) or (Cardinal(DY - ClipY) >= Cardinal(ClipH)) then
      Continue;
    for var C := 0 to Cols - 1 do
    begin
      var DX := X0 + C;
      if (DX < 0) or (DX >= BufW) or (Cardinal(DX - ClipX) >= Cardinal(ClipW)) then
        Continue;
      var Cur := G.Pixel(C, R) * Scale;
      var Prev := G.Pixel(C - 1, R) * Scale;
      var V := Cur - (Cur * Frac) shr 6 + (Prev * Frac) shr 6;
      if V = 0 then
        Continue;
      if Format = 2 then
      begin
        var A := Cardinal(Int64(Buf) + Int64(DY) * Pitch + DX);
        FMemory.Write8(A, Min(255, Integer(FMemory.Read8(A)) + V));
      end
      else
      begin
        var A := Cardinal(Int64(Buf) + Int64(DY) * Pitch + DX div 2);
        var B := FMemory.Read8(A);
        var Shift := (DX and 1) * 4;
        var N := Min(15, Integer((B shr Shift) and $F) + V);
        FMemory.Write8(A, (B and not Cardinal($F shl Shift)) or Cardinal(N shl Shift));
      end;
    end;
  end;
end;

procedure TPSPFont.DrawCall(Shadow, Clip: Boolean);
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Code := Integer(FHLE.Arg(1) and $FFFF);
  var Image := FHLE.Arg(2);
  var ClipX := 0;
  var ClipY := 0;
  var ClipW := -1;
  var ClipH := -1;
  if Clip then
  begin
    ClipX := FHLE.ArgInt(3);
    ClipY := FHLE.ArgInt(4);
    ClipW := FHLE.ArgInt(5);
    ClipH := FHLE.ArgInt(6);
  end;
  if (Slot = nil) or (Slot.Data = nil) or (Image = 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  FHLE.Result(0);
  var D := Slot.Data;
  var Index := Resolve(Slot, Code);
  var G: TPGFGlyph;
  if Shadow then
    G := D.Font.Shadow(Index)
  else
    G := D.Font.Glyph(Index);
  var Fresh := D.FirstLook(Index);
  if (G = nil) or (G.W * G.H = 0) then
  begin
    if Fresh then
      Finish(0, FileYieldUs);
    Exit;
  end;
  var Key := Index * 2 + Ord(Shadow);
  if not D.Streamed or (D.CacheKey = Key) or (D.Refs = 0) then
  begin
    Draw(G, Image, ClipX, ClipY, ClipW, ClipH);
    if Fresh then
      Finish(0, FileYieldUs);
    Exit;
  end;
  // A mode 0 font loads the glyph it draws: its bytes and its bitmap.
  var Old := D.Cache;
  D.Cache := nil;
  D.CacheKey := -1;
  var Lib := Slot.Lib;
  var CacheSize := G.DataSize;
  if G.CacheDataSize > 0 then
    CacheSize := G.CacheDataSize;
  FreeBlocks(Lib, Old, TPSPStateAction.Create(StateDrawFreed, [D, G, Lib],
      [Key, Image, ClipX, ClipY, ClipW, ClipH, CacheSize]));
end;

procedure TPSPFont.StateDrawFreed(Action: TPSPStateAction; Value: Cardinal);
begin
  var G := TPGFGlyph(Action.Obj(1));
  Action.Handler := StateDrawAllocated;
  AllocBlocks(TPSPFontLib(Action.Obj(2)), [Cardinal(Action.Arg(6)), Cardinal(G.W * G.H)], Action);
end;

procedure TPSPFont.StateDrawAllocated(Action: TPSPStateAction; Value: Cardinal);
begin
  if Value = 0 then
  begin
    FHLE.Result(SCE_FONT_ERROR_NOMEMORY);
    Exit;
  end;
  var D := TPSPFontData(Action.Obj(0));
  D.Cache := Copy(Action.Results);
  D.CacheKey := Integer(Action.Arg(0));
  Draw(TPGFGlyph(Action.Obj(1)), Cardinal(Action.Arg(1)), Integer(Action.Arg(2)), Integer(Action.Arg(3)),
    Integer(Action.Arg(4)), Integer(Action.Arg(5)));
  Finish(0, FileYieldUs);
end;

procedure TPSPFont.hGetCharGlyphImage;
begin
  DrawCall(False, False);
end;

procedure TPSPFont.hGetCharGlyphImageClip;
begin
  DrawCall(False, True);
end;

procedure TPSPFont.hGetShadowGlyphImage;
begin
  DrawCall(True, False);
end;

procedure TPSPFont.hGetShadowGlyphImageClip;
begin
  DrawCall(True, True);
end;

{ The font list }

procedure TPSPFont.hGetNumFontList;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var ErrPtr := FHLE.Arg(1);
  if Lib = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  SetError(ErrPtr, 0);
  if Lib.Done then
    FHLE.Result(0)
  else
    FHLE.Result(Length(InternalFonts));
end;

procedure TPSPFont.hGetFontList;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var List := FHLE.Arg(1);
  var Num := FHLE.ArgInt(2);
  if Lib = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  if List = 0 then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  if not Lib.Done then
    for var I := 0 to Min(Num, Length(InternalFonts)) - 1 do
      WriteStyle(List + Cardinal(I * FontStyleSize), I);
  Finish(0, ListYieldUs);
end;

procedure TPSPFont.hGetFontInfoByIndexNumber;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Style := FHLE.Arg(1);
  var Index := FHLE.ArgInt(2);
  if Lib = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  if Lib.Done or (Style = 0) or (Index < 0) or (Index > High(InternalFonts)) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  WriteStyle(Style, Index);
  FHLE.Result(0);
end;

function TPSPFont.Match(Lib: TPSPFontLib; Style: Cardinal; Optimum: Boolean): Integer;
begin
  // Sizes are asked for at a resolution (the style's, or the library's) and
  // measured against the fonts' at 128 dpi; the firmware compares the fonts'
  // vertical size with the requested horizontal one. FindFont wants the
  // first exact match. FindOptimumFont takes the nearest size, the first of
  // equals, except that among fonts matching a requested attribute the last
  // of equals wins; nothing matching leaves font 0.
  var H := FMemory.ReadFloat(Style);
  var V := FMemory.ReadFloat(Style + 4);
  var StyleHRes := FMemory.ReadFloat(Style + 8);
  var StyleVRes := FMemory.ReadFloat(Style + 12);
  var Family := FMemory.Read16(Style + 20);
  var Kind := FMemory.Read16(Style + 22);
  var Language := FMemory.Read16(Style + 26);
  var Country := FMemory.Read16(Style + 30);
  var Name := FMemory.ReadString(Style + 32, 64);
  var FileName := FMemory.ReadString(Style + 96, 64);
  var ResH := FMemory.ReadFloat(Lib.Addr + $38);
  var ResV := FMemory.ReadFloat(Lib.Addr + $3C);
  if StyleHRes > 0 then
    ResH := StyleHRes;
  if StyleVRes > 0 then
    ResV := StyleVRes;
  var UseH := H > 0;
  var UseV := V > 0;
  var TargetH: Single := H * ResH / 128;
  var TargetV: Single := H * ResV / 128;
  var AnyAttr := (Family <> 0) or (Kind <> 0) or (Language <> 0) or (Country <> 0) or (Name <> '') or (FileName <> '');
  if Optimum then
    Result := 0
  else
    Result := -1;
  var BestDiff: Single := Infinity;
  for var I := 0 to High(InternalFonts) do
  begin
    var E := InternalFonts[I];
    if ((Family <> 0) and (E.Family <> Family)) or ((Kind <> 0) and (E.Style <> Kind)) or ((Language <> 0) and
      (E.Language <> Language)) or ((Country <> 0) and (E.Country <> Country)) or ((Name <> '') and (E.Name <> Name)) or
      ((FileName <> '') and (E.FileName <> FileName)) then
      Continue;
    var Size: Single := E.Points;
    if not Optimum then
    begin
      if (UseH and (Size <> TargetH)) or (UseV and (Size <> TargetV)) then
        Continue;
      Exit(I);
    end;
    var Diff: Single := 0;
    if UseH or UseV then
    begin
      Diff := Infinity;
      if UseH then
        Diff := Min(Diff, Abs(Size - TargetH));
      if UseV then
        Diff := Min(Diff, Abs(Size - TargetV));
    end;
    if (AnyAttr and (Diff <= BestDiff)) or (not AnyAttr and (Diff < BestDiff)) then
    begin
      Result := I;
      BestDiff := Diff;
    end;
  end;
end;

procedure TPSPFont.hFindOptimumFont;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Style := FHLE.Arg(1);
  var ErrPtr := FHLE.Arg(2);
  if (Lib = nil) or (Style = 0) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  SetError(ErrPtr, 0);
  FHLE.Result(Cardinal(Match(Lib, Style, True)));
end;

procedure TPSPFont.hFindFont;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Style := FHLE.Arg(1);
  var ErrPtr := FHLE.Arg(2);
  if Lib = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  if Style = 0 then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  SetError(ErrPtr, 0);
  FHLE.Result(Cardinal(Match(Lib, Style, False)));
end;

{ Library settings }

procedure TPSPFont.hSetAltCharacterCode;
begin
  var Lib := LibOf(FHLE.Arg(0));
  if Lib = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  FMemory.Write16(Lib.Addr + $48, FHLE.Arg(1) and $FFFF);
  FHLE.Result(0);
end;

procedure TPSPFont.hSetResolution;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var H := FHLE.ArgFloat(0);
  var V := FHLE.ArgFloat(1);
  if Lib = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  if not (H > 0) or not (V > 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  FMemory.WriteFloat(Lib.Addr + $38, H);
  FMemory.WriteFloat(Lib.Addr + $3C, V);
  FHLE.Result(0);
end;

procedure TPSPFont.Convert(Vertical, ToPoints: Boolean);
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Value := FHLE.ArgFloat(0);
  var ErrPtr := FHLE.Arg(1);
  if Lib = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.ResultFloat(0);
    Exit;
  end;
  var Res := FMemory.ReadFloat(Lib.Addr + $38);
  if Vertical then
    Res := FMemory.ReadFloat(Lib.Addr + $3C);
  var R: Single;
  if ToPoints then
    R := Value * 72 / Res
  else
    R := Value * Res / 72;
  SetError(ErrPtr, 0);
  FHLE.ResultFloat(R);
end;

procedure TPSPFont.hPixelToPointH;
begin
  Convert(False, True);
end;

procedure TPSPFont.hPixelToPointV;
begin
  Convert(True, True);
end;

procedure TPSPFont.hPointToPixelH;
begin
  Convert(False, False);
end;

procedure TPSPFont.hPointToPixelV;
begin
  Convert(True, False);
end;

procedure TPSPFont.hFlush;
begin
  if SlotOf(FHLE.Arg(0)) = nil then
    FHLE.Result(SCE_FONT_ERROR_ARG)
  else
    FHLE.Result(0);
end;

procedure TPSPFont.Register;
const
  L = 'sceLibFont';
begin
  var H := FHLE;
  H.Register(L, $67F17ED7, 'sceFontNewLib', hNewLib);
  H.Register(L, $574B6FBC, 'sceFontDoneLib', hDoneLib);
  H.Register(L, $A834319D, 'sceFontOpen', hOpen);
  H.Register(L, $BB8E7FE6, 'sceFontOpenUserMemory', hOpenUserMemory);
  H.Register(L, $57FCB733, 'sceFontOpenUserFile', hOpenUserFile);
  H.Register(L, $3AEA8CB6, 'sceFontClose', hClose);
  H.Register(L, $27F6E642, 'sceFontGetNumFontList', hGetNumFontList);
  H.Register(L, $BC75D85B, 'sceFontGetFontList', hGetFontList);
  H.Register(L, $099EF33C, 'sceFontFindOptimumFont', hFindOptimumFont);
  H.Register(L, $681E61A7, 'sceFontFindFont', hFindFont);
  H.Register(L, $0DA7535E, 'sceFontGetFontInfo', hGetFontInfo);
  H.Register(L, $5333322D, 'sceFontGetFontInfoByIndexNumber', hGetFontInfoByIndexNumber);
  H.Register(L, $DCC80C2F, 'sceFontGetCharInfo', hGetCharInfo);
  H.Register(L, $AA3DE7B5, 'sceFontGetShadowInfo', hGetShadowInfo);
  H.Register(L, $5C3E4A9E, 'sceFontGetCharImageRect', hGetCharImageRect);
  H.Register(L, $48B06520, 'sceFontGetShadowImageRect', hGetShadowImageRect);
  H.Register(L, $980F4895, 'sceFontGetCharGlyphImage', hGetCharGlyphImage);
  H.Register(L, $CA1E6945, 'sceFontGetCharGlyphImage_Clip', hGetCharGlyphImageClip);
  H.Register(L, $568BE516, 'sceFontGetShadowGlyphImage', hGetShadowGlyphImage);
  H.Register(L, $5DCF6858, 'sceFontGetShadowGlyphImage_Clip', hGetShadowGlyphImageClip);
  H.Register(L, $EE232411, 'sceFontSetAltCharacterCode', hSetAltCharacterCode);
  H.Register(L, $48293280, 'sceFontSetResolution', hSetResolution);
  H.Register(L, $74B21701, 'sceFontPixelToPointH', hPixelToPointH);
  H.Register(L, $F8F0752E, 'sceFontPixelToPointV', hPixelToPointV);
  H.Register(L, $472694CD, 'sceFontPointToPixelH', hPointToPixelH);
  H.Register(L, $3C4B7E82, 'sceFontPointToPixelV', hPointToPixelV);
  H.Register(L, $02D7F94B, 'sceFontFlush', hFlush);
end;

initialization
  RegisterPSPService(TPSPFont);

end.

