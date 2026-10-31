unit PS2.GS.Memory;

// GS local memory (4 MiB) with the page/block/column swizzles of every pixel
// storage mode: PSMCT32/24/16/16S, PSMT8/4/8H/4HL/4HH and PSMZ32/24/16/16S.
// Base pointers are in 64-word blocks (256 bytes); widths in 64 pixels.
// References: GS User's Manual (memory arrangement tables), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, PS2.Types;

const
  PSMCT32 = $00;
  PSMCT24 = $01;
  PSMCT16 = $02;
  PSMCT16S = $0A;
  PSMT8 = $13;
  PSMT4 = $14;
  PSMT8H = $1B;
  PSMT4HL = $24;
  PSMT4HH = $2C;
  PSMZ32 = $30;
  PSMZ24 = $31;
  PSMZ16 = $32;
  PSMZ16S = $3A;

  // Swizzle tables (GS User's Manual).
  Block32: array[0..3, 0..7] of Byte = (
    (0, 1, 4, 5, 16, 17, 20, 21),
    (2, 3, 6, 7, 18, 19, 22, 23),
    (8, 9, 12, 13, 24, 25, 28, 29),
    (10, 11, 14, 15, 26, 27, 30, 31));
  Block16: array[0..7, 0..3] of Byte = (
    (0, 2, 8, 10),
    (1, 3, 9, 11),
    (4, 6, 12, 14),
    (5, 7, 13, 15),
    (16, 18, 24, 26),
    (17, 19, 25, 27),
    (20, 22, 28, 30),
    (21, 23, 29, 31));
  Block16S: array[0..7, 0..3] of Byte = (
    (0, 2, 16, 18),
    (1, 3, 17, 19),
    (8, 10, 24, 26),
    (9, 11, 25, 27),
    (4, 6, 20, 22),
    (5, 7, 21, 23),
    (12, 14, 28, 30),
    (13, 15, 29, 31));
  Column16: array[0..7, 0..15] of Byte = (
    (0, 2, 8, 10, 16, 18, 24, 26, 1, 3, 9, 11, 17, 19, 25, 27),
    (4, 6, 12, 14, 20, 22, 28, 30, 5, 7, 13, 15, 21, 23, 29, 31),
    (32, 34, 40, 42, 48, 50, 56, 58, 33, 35, 41, 43, 49, 51, 57, 59),
    (36, 38, 44, 46, 52, 54, 60, 62, 37, 39, 45, 47, 53, 55, 61, 63),
    (64, 66, 72, 74, 80, 82, 88, 90, 65, 67, 73, 75, 81, 83, 89, 91),
    (68, 70, 76, 78, 84, 86, 92, 94, 69, 71, 77, 79, 85, 87, 93, 95),
    (96, 98, 104, 106, 112, 114, 120, 122, 97, 99, 105, 107, 113, 115, 121, 123),
    (100, 102, 108, 110, 116, 118, 124, 126, 101, 103, 109, 111, 117, 119, 125, 127));
  Column8: array[0..15, 0..15] of Byte = (
    (0, 4, 16, 20, 32, 36, 48, 52, 2, 6, 18, 22, 34, 38, 50, 54),
    (8, 12, 24, 28, 40, 44, 56, 60, 10, 14, 26, 30, 42, 46, 58, 62),
    (33, 37, 49, 53, 1, 5, 17, 21, 35, 39, 51, 55, 3, 7, 19, 23),
    (41, 45, 57, 61, 9, 13, 25, 29, 43, 47, 59, 63, 11, 15, 27, 31),
    (96, 100, 112, 116, 64, 68, 80, 84, 98, 102, 114, 118, 66, 70, 82, 86),
    (104, 108, 120, 124, 72, 76, 88, 92, 106, 110, 122, 126, 74, 78, 90, 94),
    (65, 69, 81, 85, 97, 101, 113, 117, 67, 71, 83, 87, 99, 103, 115, 119),
    (73, 77, 89, 93, 105, 109, 121, 125, 75, 79, 91, 95, 107, 111, 123, 127),
    (128, 132, 144, 148, 160, 164, 176, 180, 130, 134, 146, 150, 162, 166, 178, 182),
    (136, 140, 152, 156, 168, 172, 184, 188, 138, 142, 154, 158, 170, 174, 186, 190),
    (161, 165, 177, 181, 129, 133, 145, 149, 163, 167, 179, 183, 131, 135, 147, 151),
    (169, 173, 185, 189, 137, 141, 153, 157, 171, 175, 187, 191, 139, 143, 155, 159),
    (224, 228, 240, 244, 192, 196, 208, 212, 226, 230, 242, 246, 194, 198, 210, 214),
    (232, 236, 248, 252, 200, 204, 216, 220, 234, 238, 250, 254, 202, 206, 218, 222),
    (193, 197, 209, 213, 225, 229, 241, 245, 195, 199, 211, 215, 227, 231, 243, 247),
    (201, 205, 217, 221, 233, 237, 249, 253, 203, 207, 219, 223, 235, 239, 251, 255));
  Column4: array[0..15, 0..31] of Word = (
    (0, 8, 32, 40, 64, 72, 96, 104, 2, 10, 34, 42, 66, 74, 98, 106, 4, 12, 36, 44, 68, 76, 100, 108, 6, 14, 38, 46, 70, 78, 102, 110),
    (16, 24, 48, 56, 80, 88, 112, 120, 18, 26, 50, 58, 82, 90, 114, 122, 20, 28, 52, 60, 84, 92, 116, 124, 22, 30, 54, 62, 86, 94, 118, 126),
    (65, 73, 97, 105, 1, 9, 33, 41, 67, 75, 99, 107, 3, 11, 35, 43, 69, 77, 101, 109, 5, 13, 37, 45, 71, 79, 103, 111, 7, 15, 39, 47),
    (81, 89, 113, 121, 17, 25, 49, 57, 83, 91, 115, 123, 19, 27, 51, 59, 85, 93, 117, 125, 21, 29, 53, 61, 87, 95, 119, 127, 23, 31, 55, 63),
    (192, 200, 224, 232, 128, 136, 160, 168, 194, 202, 226, 234, 130, 138, 162, 170, 196, 204, 228, 236, 132, 140, 164, 172, 198, 206, 230, 238, 134, 142, 166, 174),
    (208, 216, 240, 248, 144, 152, 176, 184, 210, 218, 242, 250, 146, 154, 178, 186, 212, 220, 244, 252, 148, 156, 180, 188, 214, 222, 246, 254, 150, 158, 182, 190),
    (129, 137, 161, 169, 193, 201, 225, 233, 131, 139, 163, 171, 195, 203, 227, 235, 133, 141, 165, 173, 197, 205, 229, 237, 135, 143, 167, 175, 199, 207, 231, 239),
    (145, 153, 177, 185, 209, 217, 241, 249, 147, 155, 179, 187, 211, 219, 243, 251, 149, 157, 181, 189, 213, 221, 245, 253, 151, 159, 183, 191, 215, 223, 247, 255),
    (256, 264, 288, 296, 320, 328, 352, 360, 258, 266, 290, 298, 322, 330, 354, 362, 260, 268, 292, 300, 324, 332, 356, 364, 262, 270, 294, 302, 326, 334, 358, 366),
    (272, 280, 304, 312, 336, 344, 368, 376, 274, 282, 306, 314, 338, 346, 370, 378, 276, 284, 308, 316, 340, 348, 372, 380, 278, 286, 310, 318, 342, 350, 374, 382),
    (321, 329, 353, 361, 257, 265, 289, 297, 323, 331, 355, 363, 259, 267, 291, 299, 325, 333, 357, 365, 261, 269, 293, 301, 327, 335, 359, 367, 263, 271, 295, 303),
    (337, 345, 369, 377, 273, 281, 305, 313, 339, 347, 371, 379, 275, 283, 307, 315, 341, 349, 373, 381, 277, 285, 309, 317, 343, 351, 375, 383, 279, 287, 311, 319),
    (448, 456, 480, 488, 384, 392, 416, 424, 450, 458, 482, 490, 386, 394, 418, 426, 452, 460, 484, 492, 388, 396, 420, 428, 454, 462, 486, 494, 390, 398, 422, 430),
    (464, 472, 496, 504, 400, 408, 432, 440, 466, 474, 498, 506, 402, 410, 434, 442, 468, 476, 500, 508, 404, 412, 436, 444, 470, 478, 502, 510, 406, 414, 438, 446),
    (385, 393, 417, 425, 449, 457, 481, 489, 387, 395, 419, 427, 451, 459, 483, 491, 389, 397, 421, 429, 453, 461, 485, 493, 391, 399, 423, 431, 455, 463, 487, 495),
    (401, 409, 433, 441, 465, 473, 497, 505, 403, 411, 435, 443, 467, 475, 499, 507, 405, 413, 437, 445, 469, 477, 501, 509, 407, 415, 439, 447, 471, 479, 503, 511));

type
  // The pixel addresses of one buffer (base BP, width BW, format PSM) as
  // TPS2GSMemory.Locate gives them, from the offsets inside a page.
  TPS2GSAddressing = record
    Offsets: PWord;
    Base, Width, Mask: Cardinal;
    WShift, HShift, PageShift, WMask, HMask: Cardinal;
    procedure Init(PSM: Integer; BP, BW: Cardinal);
    function Addr(X, Y: Cardinal): Cardinal; inline;
  end;

  TPS2GSMemory = class
  private
    FData: PByte;
    FAllocation: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    // Word / halfword / byte / nibble addresses of a pixel.
    class function Addr32(BP, BW, X, Y: Cardinal): Cardinal; static; inline;
    class function Addr16(BP, BW, X, Y: Cardinal): Cardinal; static; inline;
    class function Addr16S(BP, BW, X, Y: Cardinal): Cardinal; static; inline;
    class function Addr8(BP, BW, X, Y: Cardinal): Cardinal; static; inline;
    class function Addr4(BP, BW, X, Y: Cardinal): Cardinal; static; inline;
    class function AddrZ32(BP, BW, X, Y: Cardinal): Cardinal; static; inline;
    class function AddrZ16(BP, BW, X, Y: Cardinal): Cardinal; static; inline;
    class function AddrZ16S(BP, BW, X, Y: Cardinal): Cardinal; static; inline;
    // Raw stored value of a pixel in format PSM (index for palettized
    // formats, 16-bit value for 16-bit formats, 32/24 bits otherwise).
    function ReadRaw(PSM: Integer; BP, BW, X, Y: Cardinal): Cardinal; inline;
    procedure WriteRaw(PSM: Integer; BP, BW, X, Y, Value: Cardinal);
    // A transfer row of unpacked values. Coordinates and VRAM wrap as in
    // host-to-local transfers; each source value retains scalar write order.
    procedure WriteRow(PSM: Integer; BP, BW, X, Y: Cardinal; Values: PCardinal; Count: Integer);
    // The same in two steps: a pixel's address in format PSM's units (words,
    // halfwords, bytes or nibbles), then its value there.
    function Locate(PSM: Integer; BP, BW, X, Y: Cardinal): Cardinal; inline;
    function ReadAt(PSM: Integer; A: Cardinal): Cardinal; inline;
    procedure WriteAt(PSM: Integer; A, Value: Cardinal); inline;
    // A displayable pixel as 32-bit ABGR (R in bits 0..7) for the CRTC.
    function ReadPixel(PSM: Integer; FBP, FBW: Cardinal; X, Y: Integer): Cardinal;
    // Exactly ReadPixel's display conversion, including coordinates beyond
    // 2047 (only VRAM addresses wrap here, unlike transfer coordinates).
    procedure ReadDisplayRow(PSM: Integer; FBP, FBW: Cardinal; X, Y: Integer;
      Pixels: PCardinal; Count: Integer);
    property Data: PByte read FData;
  end;

function Color16To32(V: Cardinal): Cardinal; inline;
function Color32To16(V: Cardinal): Cardinal; inline;

implementation

{$IFDEF GS_RACECHECK}
uses PS2.GS.RaceCheck;

// The bytes of the word a format's pixel occupies (RaceAccess lanes).
function RaceLanes(PSM: Integer): Integer; inline;
begin
  case PSM of
    PSMCT24, PSMZ24: Result := 1;
    PSMT8H, PSMT4HL, PSMT4HH: Result := 2;
  else
    Result := 3;
  end;
end;

function RaceWord(PSM: Integer; A: Cardinal): Cardinal; inline;
begin
  case PSM of
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: Result := A shr 1;
    PSMT8: Result := A shr 2;
    PSMT4: Result := A shr 3;
  else
    Result := A;
  end;
end;
{$ENDIF}

var
  // Immutable offsets of the pixels inside a page (address of the pixel at
  // the page's X, Y with base and page 0), by row.
  PageOffsets8: array[0..63, 0..127] of Word;
  PageOffsets4: array[0..127, 0..127] of Word;
  PageOffsets32, PageOffsetsZ32: array[0..31, 0..63] of Word;
  PageOffsets16, PageOffsets16S, PageOffsetsZ16, PageOffsetsZ16S: array[0..63, 0..63] of Word;

function Color16To32(V: Cardinal): Cardinal;
begin
  // 1:5:5:5 (A B G R) to 32-bit with the 5-bit channels in the high bits.
  Result := ((V and $1F) shl 3) or (((V shr 5) and $1F) shl 11) or (((V shr 10) and $1F) shl 19);
  if (V and $8000) <> 0 then
    Result := Result or $80000000;
end;

function Color32To16(V: Cardinal): Cardinal;
begin
  Result := ((V shr 3) and $1F) or (((V shr 11) and $1F) shl 5) or (((V shr 19) and $1F) shl 10) or
    (((V shr 31) and 1) shl 15);
end;

{ TPS2GSAddressing }

procedure TPS2GSAddressing.Init(PSM: Integer; BP, BW: Cardinal);
begin
  // The cases of TPS2GSMemory.Locate: page sizes 64x32 (32-bit), 64x64
  // (16-bit), 128x64 (8-bit) and 128x128 (4-bit) pixels of 2048 words.
  WShift := 6;
  HShift := 5;
  PageShift := 11;
  Base := BP shl 6;
  Width := BW;
  Mask := $FFFFF;
  Offsets := @PageOffsets32[0, 0];
  case PSM of
    PSMZ32, PSMZ24: Offsets := @PageOffsetsZ32[0, 0];
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
      begin
        HShift := 6;
        PageShift := 12;
        Base := BP shl 7;
        Mask := $1FFFFF;
        case PSM of
          PSMCT16: Offsets := @PageOffsets16[0, 0];
          PSMCT16S: Offsets := @PageOffsets16S[0, 0];
          PSMZ16: Offsets := @PageOffsetsZ16[0, 0];
        else
          Offsets := @PageOffsetsZ16S[0, 0];
        end;
      end;
    PSMT8:
      begin
        WShift := 7;
        HShift := 6;
        PageShift := 13;
        Base := BP shl 8;
        Width := (BW + 1) shr 1;
        Mask := $3FFFFF;
        Offsets := @PageOffsets8[0, 0];
      end;
    PSMT4:
      begin
        WShift := 7;
        HShift := 7;
        PageShift := 14;
        Base := BP shl 9;
        Width := (BW + 1) shr 1;
        Mask := $7FFFFF;
        Offsets := @PageOffsets4[0, 0];
      end;
  end;
  WMask := (Cardinal(1) shl WShift) - 1;
  HMask := (Cardinal(1) shl HShift) - 1;
end;

function TPS2GSAddressing.Addr(X, Y: Cardinal): Cardinal;
begin
  Result := (Base + ((X shr WShift) + (Y shr HShift) * Width) shl PageShift +
    Offsets[((Y and HMask) shl WShift) + (X and WMask)]) and Mask;
end;

{ TPS2GSMemory }

constructor TPS2GSMemory.Create;
begin
  inherited Create;
  // Page-aligned storage can be imported by VK_EXT_external_memory_host.
  // Keep the original allocation for the software renderer's ownership.
  FAllocation := AllocMem(PS2GSMemorySize + $10000);
  FData := PByte((NativeUInt(FAllocation) + $FFFF) and not NativeUInt($FFFF));
end;

destructor TPS2GSMemory.Destroy;
begin
  FreeMem(FAllocation);
  inherited;
end;

procedure TPS2GSMemory.Clear;
begin
  FillChar(FData^, PS2GSMemorySize, 0);
end;

class function TPS2GSMemory.Addr32(BP, BW, X, Y: Cardinal): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 5) * BW;
  var Block := Block32[(Y shr 3) and 3, (X shr 3) and 7];
  var Word := (X and 1) + ((Y and 1) shl 1) + (((X shr 1) and 3) shl 2) + (((Y shr 1) and 3) shl 4);
  Result := (BP shl 6 + Page shl 11 + Cardinal(Block) shl 6 + Word) and $FFFFF;
end;

class function TPS2GSMemory.AddrZ32(BP, BW, X, Y: Cardinal): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 5) * BW;
  var Block := Block32[(Y shr 3) and 3, (X shr 3) and 7] xor 24;
  var Word := (X and 1) + ((Y and 1) shl 1) + (((X shr 1) and 3) shl 2) + (((Y shr 1) and 3) shl 4);
  Result := (BP shl 6 + Page shl 11 + Cardinal(Block) shl 6 + Word) and $FFFFF;
end;

class function TPS2GSMemory.Addr16(BP, BW, X, Y: Cardinal): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 6) * BW;
  var Block := Block16[(Y shr 3) and 7, (X shr 4) and 3];
  Result := (BP shl 7 + Page shl 12 + Cardinal(Block) shl 7 + Column16[Y and 7, X and 15]) and $1FFFFF;
end;

class function TPS2GSMemory.AddrZ16(BP, BW, X, Y: Cardinal): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 6) * BW;
  var Block := Block16[(Y shr 3) and 7, (X shr 4) and 3] xor 24;
  Result := (BP shl 7 + Page shl 12 + Cardinal(Block) shl 7 + Column16[Y and 7, X and 15]) and $1FFFFF;
end;

class function TPS2GSMemory.Addr16S(BP, BW, X, Y: Cardinal): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 6) * BW;
  var Block := Block16S[(Y shr 3) and 7, (X shr 4) and 3];
  Result := (BP shl 7 + Page shl 12 + Cardinal(Block) shl 7 + Column16[Y and 7, X and 15]) and $1FFFFF;
end;

class function TPS2GSMemory.AddrZ16S(BP, BW, X, Y: Cardinal): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 6) * BW;
  var Block := Block16S[(Y shr 3) and 7, (X shr 4) and 3] xor 24;
  Result := (BP shl 7 + Page shl 12 + Cardinal(Block) shl 7 + Column16[Y and 7, X and 15]) and $1FFFFF;
end;

class function TPS2GSMemory.Addr8(BP, BW, X, Y: Cardinal): Cardinal;
begin
  var Page := (X shr 7) + (Y shr 6) * ((BW + 1) shr 1);
  var Block := Block32[(Y shr 4) and 3, (X shr 4) and 7];
  Result := (BP shl 8 + Page shl 13 + Cardinal(Block) shl 8 + Column8[Y and 15, X and 15]) and $3FFFFF;
end;

class function TPS2GSMemory.Addr4(BP, BW, X, Y: Cardinal): Cardinal;
begin
  var Page := (X shr 7) + (Y shr 7) * ((BW + 1) shr 1);
  var Block := Block16[(Y shr 4) and 7, (X shr 5) and 3];
  Result := (BP shl 9 + Page shl 14 + Cardinal(Block) shl 9 + Column4[Y and 15, X and 31]) and $7FFFFF;
end;

function TPS2GSMemory.Locate(PSM: Integer; BP, BW, X, Y: Cardinal): Cardinal;
begin
  case PSM of
    PSMZ32, PSMZ24: Result := AddrZ32(BP, BW, X, Y);
    PSMCT16: Result := Addr16(BP, BW, X, Y);
    PSMCT16S: Result := Addr16S(BP, BW, X, Y);
    PSMZ16: Result := AddrZ16(BP, BW, X, Y);
    PSMZ16S: Result := AddrZ16S(BP, BW, X, Y);
    PSMT8: Result := Addr8(BP, BW, X, Y);
    PSMT4: Result := Addr4(BP, BW, X, Y);
  else
    Result := Addr32(BP, BW, X, Y);
  end;
end;

function TPS2GSMemory.ReadAt(PSM: Integer; A: Cardinal): Cardinal;
begin
  {$IFDEF GS_RACECHECK}RaceAccess(RaceWord(PSM, A), False, RaceLanes(PSM));{$ENDIF}
  case PSM of
    PSMCT24, PSMZ24: Result := PCardinal(FData)[A] and $FFFFFF;
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: Result := PWord(FData)[A];
    PSMT8: Result := FData[A];
    PSMT4: Result := (FData[A shr 1] shr ((A and 1) * 4)) and $F;
    PSMT8H: Result := PCardinal(FData)[A] shr 24;
    PSMT4HL: Result := (PCardinal(FData)[A] shr 24) and $F;
    PSMT4HH: Result := PCardinal(FData)[A] shr 28;
  else
    Result := PCardinal(FData)[A];
  end;
end;

procedure TPS2GSMemory.WriteAt(PSM: Integer; A, Value: Cardinal);
begin
  {$IFDEF GS_RACECHECK}if RaceBandPlus1 = 0 then RaceMainWrite(RaceWord(PSM, A)) else RaceAccess(RaceWord(PSM, A), True, RaceLanes(PSM));{$ENDIF}
  case PSM of
    PSMCT32, PSMZ32: PCardinal(FData)[A] := Value;
    PSMCT24, PSMZ24: PCardinal(FData)[A] := (PCardinal(FData)[A] and $FF000000) or (Value and $FFFFFF);
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: PWord(FData)[A] := Word(Value);
    PSMT8: FData[A] := Byte(Value);
    PSMT4:
      begin
        var Shift := (A and 1) * 4;
        FData[A shr 1] := (FData[A shr 1] and not ($F shl Shift)) or ((Value and $F) shl Shift);
      end;
    PSMT8H: PCardinal(FData)[A] := (PCardinal(FData)[A] and $00FFFFFF) or (Value shl 24);
    PSMT4HL: PCardinal(FData)[A] := (PCardinal(FData)[A] and $F0FFFFFF) or ((Value and $F) shl 24);
    PSMT4HH: PCardinal(FData)[A] := (PCardinal(FData)[A] and $0FFFFFFF) or ((Value and $F) shl 28);
  end;
end;

function TPS2GSMemory.ReadRaw(PSM: Integer; BP, BW, X, Y: Cardinal): Cardinal;
begin
  Result := ReadAt(PSM, Locate(PSM, BP, BW, X, Y));
end;

procedure TPS2GSMemory.WriteRaw(PSM: Integer; BP, BW, X, Y, Value: Cardinal);
begin
  WriteAt(PSM, Locate(PSM, BP, BW, X, Y), Value);
end;

procedure TPS2GSMemory.WriteRow(PSM: Integer; BP, BW, X, Y: Cardinal; Values: PCardinal; Count: Integer);
begin
  if Count <= 0 then Exit;
  X := X and $7FF;
  Y := Y and $7FF;
  {$IFNDEF GS_RACECHECK}
  if PSM = PSMT8 then
  begin
    var RowBase := (BP shl 8) + (((Y shr 6) * ((BW + 1) shr 1)) shl 13);
    while Count > 0 do
    begin
      var N := Min(Count, 128 - Integer(X and 127));
      var Base := RowBase + ((X shr 7) shl 13);
      var Offsets: PWord := @PageOffsets8[Y and 63, X and 127];
      for var K := 0 to N - 1 do FData[(Base + Offsets[K]) and $3FFFFF] := Byte(Values[K]);
      Inc(Values, N);
      Dec(Count, N);
      X := (X + Cardinal(N)) and $7FF;
    end;
    Exit;
  end;
  if PSM = PSMT4 then
  begin
    var RowBase := (BP shl 9) + (((Y shr 7) * ((BW + 1) shr 1)) shl 14);
    var Shift := (PageOffsets4[Y and 127, 0] and 1) * 4;
    var Keep := $FF xor ($F shl Shift);
    while Count > 0 do
    begin
      var N := Min(Count, 128 - Integer(X and 127));
      var Base := RowBase + ((X shr 7) shl 14);
      var Offsets: PWord := @PageOffsets4[Y and 127, X and 127];
      for var K := 0 to N - 1 do
      begin
        var A := ((Base + Offsets[K]) shr 1) and $3FFFFF;
        FData[A] := Byte((FData[A] and Keep) or ((Values[K] and 15) shl Shift));
      end;
      Inc(Values, N);
      Dec(Count, N);
      X := (X + Cardinal(N)) and $7FF;
    end;
    Exit;
  end;
  {$ENDIF}
  for var K := 0 to Count - 1 do WriteRaw(PSM, BP, BW, (X + Cardinal(K)) and $7FF, Y, Values[K]);
end;

function TPS2GSMemory.ReadPixel(PSM: Integer; FBP, FBW: Cardinal; X, Y: Integer): Cardinal;
begin
  if (X < 0) or (Y < 0) then
    Exit(0);
  // FBP is in 2048-word pages: 32 blocks.
  var BP := FBP div 64;
  case PSM of
    PSMCT32, PSMZ32, PSMCT24, PSMZ24:
      Result := ReadRaw(PSM, BP, FBW div 64, Cardinal(X), Cardinal(Y)) or $FF000000;
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
      Result := Color16To32(ReadRaw(PSM, BP, FBW div 64, Cardinal(X), Cardinal(Y)));
  else
    Result := ReadRaw(PSMCT32, BP, FBW div 64, Cardinal(X), Cardinal(Y));
  end;
end;

procedure TPS2GSMemory.ReadDisplayRow(PSM: Integer; FBP, FBW: Cardinal; X, Y: Integer;
  Pixels: PCardinal; Count: Integer);
begin
  if Count <= 0 then Exit;
  {$IFNDEF GS_RACECHECK}
  if (X >= 0) and (Y >= 0) then
  begin
    var BP := FBP div 64;
    var BW := FBW div 64;
    if PSM in [PSMCT32, PSMCT24, PSMZ32, PSMZ24] then
    begin
      var RowBase := (BP shl 6) + (((Cardinal(Y) shr 5) * BW) shl 11);
      var Depth: Cardinal := 0;
      if PSM in [PSMZ32, PSMZ24] then Depth := 24 shl 6;
      while Count > 0 do
      begin
        var N := Min(Count, 64 - (X and 63));
        var Base := RowBase + ((Cardinal(X) shr 6) shl 11);
        var Offsets: PWord := @PageOffsets32[Y and 31, X and 63];
        for var K := 0 to N - 1 do
          Pixels[K] := PCardinal(FData)[(Base + (Offsets[K] xor Depth)) and $FFFFF] or $FF000000;
        Inc(Pixels, N);
        Dec(Count, N);
        Inc(X, N);
      end;
      Exit;
    end;
    if PSM in [PSMCT16, PSMCT16S, PSMZ16, PSMZ16S] then
    begin
      var RowBase := (BP shl 7) + (((Cardinal(Y) shr 6) * BW) shl 12);
      var Depth: Cardinal := 0;
      if PSM in [PSMZ16, PSMZ16S] then Depth := 24 shl 7;
      while Count > 0 do
      begin
        var N := Min(Count, 64 - (X and 63));
        var Base := RowBase + ((Cardinal(X) shr 6) shl 12);
        var Offsets: PWord := @PageOffsets16[Y and 63, X and 63];
        if PSM in [PSMCT16S, PSMZ16S] then Offsets := @PageOffsets16S[Y and 63, X and 63];
        for var K := 0 to N - 1 do
          Pixels[K] := Color16To32(PWord(FData)[(Base + (Offsets[K] xor Depth)) and $1FFFFF]);
        Inc(Pixels, N);
        Dec(Count, N);
        Inc(X, N);
      end;
      Exit;
    end;
  end;
  {$ENDIF}
  for var K := 0 to Count - 1 do Pixels[K] := ReadPixel(PSM, FBP, FBW, X + K, Y);
end;

procedure InitPageOffsets;
begin
  for var Y := 0 to 63 do
    for var X := 0 to 127 do PageOffsets8[Y, X] := Word(TPS2GSMemory.Addr8(0, 0, Cardinal(X), Cardinal(Y)));
  for var Y := 0 to 127 do
    for var X := 0 to 127 do PageOffsets4[Y, X] := Word(TPS2GSMemory.Addr4(0, 0, Cardinal(X), Cardinal(Y)));
  for var Y := 0 to 31 do
    for var X := 0 to 63 do PageOffsets32[Y, X] := Word(TPS2GSMemory.Addr32(0, 0, Cardinal(X), Cardinal(Y)));
  for var Y := 0 to 63 do
    for var X := 0 to 63 do
    begin
      PageOffsets16[Y, X] := Word(TPS2GSMemory.Addr16(0, 0, Cardinal(X), Cardinal(Y)));
      PageOffsets16S[Y, X] := Word(TPS2GSMemory.Addr16S(0, 0, Cardinal(X), Cardinal(Y)));
      PageOffsetsZ16[Y, X] := Word(TPS2GSMemory.AddrZ16(0, 0, Cardinal(X), Cardinal(Y)));
      PageOffsetsZ16S[Y, X] := Word(TPS2GSMemory.AddrZ16S(0, 0, Cardinal(X), Cardinal(Y)));
    end;
  for var Y := 0 to 31 do
    for var X := 0 to 63 do PageOffsetsZ32[Y, X] := Word(TPS2GSMemory.AddrZ32(0, 0, Cardinal(X), Cardinal(Y)));
end;

initialization
  InitPageOffsets;

end.
