unit NDS.Video;

interface

uses
  System.SysUtils, System.Classes, System.Math, NDS.Geometry, Core.Snapshots;

const
  NDS_SCREEN_WIDTH = 256;
  NDS_SCREEN_HEIGHT = 192;
  NDS_BG_PALETTE = $10000000;
  NDS_OBJ_PALETTE = $11000000;
  NDS_TEXTURE = $12000000;
  NDS_TEXTURE_PALETTE = $13000000;

type
  TNDSPixelLine = array[0..255] of Integer;

  TNDSVideo = class
  private
    FBankControl: array[0..8] of Byte;
    FCaptureActive: Boolean;
    FAffine: array[0..1, 0..1, 0..1] of Int64;
    FLastLine: Integer;
    FDisplayFIFO: array[0..7] of Word;
    FFIFOHead, FFIFOCount: Integer;
    FFIFOLast: Word;
    FGraphicsLine, FFIFOLine: array[0..255] of Word;
    FSingleMap: array[0..1, 0..4671] of Integer;
    function FIFOPixel: Word;
    procedure CaptureLine(Y: Integer);
    function GetBankControl(Index: Integer): Byte;
    procedure SetBankControl(Index: Integer; Value: Byte);
    procedure RebuildMap;
    function MapIndex(var Address: Cardinal; CPU: Integer): Integer;
    function BankAddress(Bank, CPU: Integer): Int64;
    function BGPixel(Engine, BG, X, Y: Integer): Integer;
    procedure BGLine(Engine, BG, Y: Integer; out Line: TNDSPixelLine);
    function Register16(Engine, Offset: Integer): Word; inline;
    function Register32(Engine, Offset: Integer): Cardinal; inline;
    function Read16(Address: Cardinal): Word;
    function Palette16(Offset: Integer): Word; inline;
    function OAM16(Offset: Integer): Word; inline;
    function GeometryMemory(Address: Cardinal): Byte;
    function GeometryPage(Address: Cardinal): PByte;
  public
    VRAM: array[0..$A3FFF] of Byte;
    Palette, OAM: array[0..$7FF] of Byte;
    Registers: array[0..1, 0..$6F] of Byte;
    Pixels: array[0..256 * 384 - 1] of Cardinal;
    Power: Word;
    OnDisplayFIFO: TNotifyEvent;
    Geometry: TNDSGeometry;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure SerializeState(State: TStateArchive; Version: Cardinal = 2);
    function ReadMemory(Address: Cardinal; CPU: Integer = 0): Byte;
    // Borrowed for one aligned bus transaction; nil for OR/unmapped banks.
    function DirectMemory(Address: Cardinal; CPU: Integer): PByte;
    procedure WriteMemory(Address: Cardinal; Value: Byte; CPU: Integer = 0);
    procedure RenderLine(Y: Integer);
    procedure WriteDisplayFIFO(Value: Cardinal; Size: Integer);
    procedure WriteRegister(Engine, Offset: Integer; Value: Byte);
    procedure VBlank;
    property BankControl[Index: Integer]: Byte read GetBankControl write SetBankControl;
  end;

implementation

const
  BankStart: array[0..8] of Integer = (0, $20000, $40000, $60000, $80000, $90000, $94000, $98000, $A0000);
  BankSize: array[0..8] of Integer = ($20000, $20000, $20000, $20000, $10000, $4000, $4000, $8000, $4000);

function Color32(V: Word): Cardinal; inline;
begin
  var R := Integer(V and 31);
  var G := Integer((V shr 5) and 31);
  var B := Integer((V shr 10) and 31);
  Result := $FF000000 or (Cardinal((R shl 3) or (R shr 2)) shl 16) or
    (Cardinal((G shl 3) or (G shr 2)) shl 8) or Cardinal((B shl 3) or (B shr 2));
end;

function Mix(A, B: Word; EVA, EVB: Integer): Word;
begin
  Result := Min(31, ((A and 31) * EVA + (B and 31) * EVB) shr 4) or
    (Min(31, (((A shr 5) and 31) * EVA + ((B shr 5) and 31) * EVB) shr 4) shl 5) or
    (Min(31, (((A shr 10) and 31) * EVA + ((B shr 10) and 31) * EVB) shr 4) shl 10);
end;

function Brighten(A: Word; Factor: Integer; Up: Boolean): Word;
begin
  if Up then
    Result := Mix(A, $7FFF, 16 - Factor, Factor)
  else
    Result := Mix(A, 0, 16 - Factor, 0);
end;

constructor TNDSVideo.Create;
begin
  inherited Create;
  Geometry := TNDSGeometry.Create(GeometryMemory, GeometryPage);
  Reset;
end;

destructor TNDSVideo.Destroy;
begin
  Geometry.Free;
  inherited;
end;

function TNDSVideo.GeometryMemory(Address: Cardinal): Byte;
begin
  Result := ReadMemory(Address);
end;

function TNDSVideo.GeometryPage(Address: Cardinal): PByte;
begin
  Result := nil;
  var Index := MapIndex(Address, 0);
  if Index < 0 then
    Exit;

  var Single := FSingleMap[0, Index];
  if Single >= 0 then
    Result := @VRAM[Single];
  // Overlapping and unmapped banks retain the ordinary OR/open-bus path.
end;

procedure TNDSVideo.Reset;
begin
  FillChar(VRAM, SizeOf(VRAM), 0);
  FillChar(Palette, SizeOf(Palette), 0);
  FillChar(OAM, SizeOf(OAM), 0);
  FillChar(Registers, SizeOf(Registers), 0);
  FillChar(FBankControl, SizeOf(FBankControl), 0);
  RebuildMap;
  FillChar(Pixels, SizeOf(Pixels), 0);
  Power := $820F;
  Geometry.Reset;
  FLastLine := -1;
  FillChar(FAffine, SizeOf(FAffine), 0);
  FCaptureActive := False;
  FFIFOHead := 0;
  FFIFOCount := 0;
  FFIFOLast := 0;
  FillChar(FDisplayFIFO, SizeOf(FDisplayFIFO), 0);
  FillChar(FGraphicsLine, SizeOf(FGraphicsLine), 0);
  FillChar(FFIFOLine, SizeOf(FFIFOLine), 0);
end;

function TNDSVideo.BankAddress(Bank, CPU: Integer): Int64;
begin
  Result := -1;
  var C := BankControl[Bank];
  if C and $80 = 0 then
    Exit;
  var Mode := C and 7;
  var Offset := (C shr 3) and 3;
  if CPU = 1 then
  begin
    if (Bank in [2, 3]) and (Mode = 2) then
      Result := $06000000 + (Offset and 1) * $20000;
    Exit;
  end;

  if Mode = 0 then
    Exit($06800000 + BankStart[Bank]);

  case Bank of
    0..3:
      case Mode of
        1:
          Result := $06000000 + Offset * $20000;
        2:
          if Bank < 2 then
            Result := $06400000 + (Offset and 1) * $20000;
        3:
          Result := NDS_TEXTURE + Offset * $20000;
        4:
          if Bank = 2 then
            Result := $06200000
          else if Bank = 3 then
            Result := $06600000;
      end;
    4:
      case Mode of
        1:
          Result := $06000000;
        2:
          Result := $06400000;
        3:
          Result := NDS_TEXTURE_PALETTE;
        4:
          Result := NDS_BG_PALETTE;
      end;
    5, 6:
      case Mode of
        1:
          Result := $06000000 + (Offset and 1) * $4000 + (Offset shr 1) * $10000;
        2:
          Result := $06400000 + (Offset and 1) * $4000 + (Offset shr 1) * $10000;
        3:
          Result := NDS_TEXTURE_PALETTE + (Offset and 1) * $4000 + (Offset shr 1) * $10000;
        4:
          Result := NDS_BG_PALETTE + (Offset and 1) * $4000;
        5:
          Result := NDS_OBJ_PALETTE;
      end;
    7:
      case Mode of
        1:
          Result := $06200000;
        2:
          Result := NDS_BG_PALETTE + $100000;
      end;
    8:
      case Mode of
        1:
          Result := $06208000;
        2:
          Result := $06600000;
        3:
          Result := NDS_OBJ_PALETTE + $100000;
      end;
  end;
end;

function TNDSVideo.GetBankControl(Index: Integer): Byte;
begin
  Result := FBankControl[Index];
end;

procedure TNDSVideo.SetBankControl(Index: Integer; Value: Byte);
begin
  if FBankControl[Index] = Value then
    Exit;

  FBankControl[Index] := Value;
  RebuildMap;
end;

function TNDSVideo.MapIndex(var Address: Cardinal; CPU: Integer): Integer;
begin
  Result := -1;
  if (Address >= $06000000) and (Address < $06900000) then
  begin
    if CPU = 1 then
      Address := $06000000 + (Address and $3FFFF)
    else
      case (Address shr 21) and 7 of
        0:
          Address := $06000000 + (Address and $7FFFF);
        1:
          Address := $06200000 + (Address and $1FFFF);
        2:
          Address := $06400000 + (Address and $3FFFF);
        3:
          Address := $06600000 + (Address and $1FFFF);
      end;
    Result := (Address - $06000000) shr 14;
  end
  else if (Address >= $10000000) and (Address < $14000000) then
    Result := 576 + Integer((Address - $10000000) shr 14);
end;

procedure TNDSVideo.RebuildMap;
begin
  FillChar(FSingleMap, SizeOf(FSingleMap), $FF);
  for var CPU := 0 to 1 do
    for var B := 0 to 8 do
    begin
      var Base := BankAddress(B, CPU);
      if Base < 0 then
        Continue;
      for var P := 0 to BankSize[B] div $4000 - 1 do
      begin
        var Address := Cardinal(Base) + Cardinal(P * $4000);
        var Index := MapIndex(Address, CPU);
        if Index < 0 then
          Continue;
        if FSingleMap[CPU, Index] = -1 then
          FSingleMap[CPU, Index] := BankStart[B] + P * $4000
        else
          FSingleMap[CPU, Index] := -2;
      end;
    end;
end;

function TNDSVideo.DirectMemory(Address: Cardinal; CPU: Integer): PByte;
begin
  Result := nil;
  var Index := MapIndex(Address, CPU);
  if Index < 0 then
    Exit;

  var Single := FSingleMap[CPU, Index];
  if Single >= 0 then
    Result := @VRAM[Single + Integer(Address and $3FFF)];
end;

function TNDSVideo.ReadMemory(Address: Cardinal; CPU: Integer): Byte;
begin
  Result := 0;
  var Index := MapIndex(Address, CPU);
  if Index < 0 then
    Exit;
  var Single := FSingleMap[CPU, Index];
  if Single >= 0 then
    Exit(VRAM[Single + Integer(Address and $3FFF)]);
  if Single = -1 then
    Exit;

  // Multiple banks can overlap; on hardware their read data are ORed.
  for var B := 0 to 8 do
  begin
    var Base := BankAddress(B, CPU);
    if (Base >= 0) and (Int64(Address) >= Base) and (Int64(Address) < Base + BankSize[B]) then
      Result := Result or VRAM[BankStart[B] + Integer(Int64(Address) - Base)];
  end;
end;

procedure TNDSVideo.WriteMemory(Address: Cardinal; Value: Byte; CPU: Integer);
begin
  var Index := MapIndex(Address, CPU);
  if Index < 0 then
    Exit;
  var Single := FSingleMap[CPU, Index];
  if Single >= 0 then
  begin
    VRAM[Single + Integer(Address and $3FFF)] := Value;
    Exit;
  end;
  if Single = -1 then
    Exit;

  for var B := 0 to 8 do
  begin
    var Base := BankAddress(B, CPU);
    if (Base >= 0) and (Int64(Address) >= Base) and (Int64(Address) < Base + BankSize[B]) then
      VRAM[BankStart[B] + Integer(Int64(Address) - Base)] := Value;
  end;
end;

function TNDSVideo.Read16(Address: Cardinal): Word;
begin
  Result := ReadMemory(Address) or (Word(ReadMemory(Address + 1)) shl 8);
end;

function TNDSVideo.Palette16(Offset: Integer): Word;
begin
  Result := Palette[Offset and $7FF] or (Word(Palette[(Offset + 1) and $7FF]) shl 8);
end;

function TNDSVideo.OAM16(Offset: Integer): Word;
begin
  Result := OAM[Offset and $7FF] or (Word(OAM[(Offset + 1) and $7FF]) shl 8);
end;

function TNDSVideo.Register16(Engine, Offset: Integer): Word;
begin
  Result := Registers[Engine, Offset] or (Word(Registers[Engine, Offset + 1]) shl 8);
end;

function TNDSVideo.Register32(Engine, Offset: Integer): Cardinal;
begin
  Result := Register16(Engine, Offset) or (Cardinal(Register16(Engine, Offset + 2)) shl 16);
end;

function Signed16(V: Word): Integer;
begin
  Result := V;
  if Result >= $8000 then
    Dec(Result, $10000);
end;

function Signed28(V: Cardinal): Integer;
begin
  Result := Integer(V and $0FFFFFFF);
  if V and $08000000 <> 0 then
    Dec(Result, $10000000);
end;

function TNDSVideo.BGPixel(Engine, BG, X, Y: Integer): Integer;
begin
  Result := -1;
  var D := Register32(Engine, 0);
  var C := Register16(Engine, 8 + BG * 2);
  if (Engine = 0) and (BG = 0) and (D and 8 <> 0) then
  begin
    X := (X + (Register16(0, $10) and $1FF)) and $1FF;
    if (X < 256) and (Geometry.Alpha[Y * 256 + X] <> 0) then
      Result := Geometry.Pixels[Y * 256 + X];
    Exit;
  end;

  var Mode := D and 7;
  var Kind := 0; // text, affine, extended, large bitmap
  case Mode of
    1:
      if BG = 3 then
        Kind := 1;
    2:
      if BG >= 2 then
        Kind := 1;
    3:
      if BG = 3 then
        Kind := 2;
    4:
      if BG = 2 then
        Kind := 1
      else if BG = 3 then
        Kind := 2;
    5:
      if BG >= 2 then
        Kind := 2;
    6:
      if (BG = 2) and (Engine = 0) then
        Kind := 3
      else
        Exit;
    7:
      Exit;
  end;

  var Base: Cardinal := $06000000 + Cardinal(Engine) * $200000;
  var CharBase: Cardinal := ((C shr 2) and 15) * $4000;
  var MapBase: Cardinal := ((C shr 8) and 31) * $800;
  if Engine = 0 then
  begin
    Inc(CharBase, ((D shr 24) and 7) * $10000);
    Inc(MapBase, ((D shr 27) and 7) * $10000);
  end;
  var Size := C shr 14;
  var W := 256;
  var H := 256;
  var Tile, Index, PaletteNo: Integer;
  PaletteNo := 0;
  var LineY := Y;
  if C and $40 <> 0 then
  begin
    var Mosaic := Register16(Engine, $4C);
    X := X - X mod ((Mosaic and 15) + 1);
    Y := Y - Y mod (((Mosaic shr 4) and 15) + 1);
  end;
  if Kind = 0 then
  begin
    if Size and 1 <> 0 then
      W := 512;
    if Size and 2 <> 0 then
      H := 512;
    X := (X + Register16(Engine, $10 + BG * 4)) and (W - 1);
    Y := (Y + Register16(Engine, $12 + BG * 4)) and (H - 1);
    var MapOffset := ((Y shr 3) and 31) * 32 + ((X shr 3) and 31);
    Inc(MapOffset, ((X shr 8) + (Y shr 8) * (W shr 8)) * 1024);
    Tile := Read16(Base + MapBase + Cardinal(MapOffset) * 2);
    X := X and 7;
    Y := Y and 7;
    if Tile and $400 <> 0 then
      X := 7 - X;
    if Tile and $800 <> 0 then
      Y := 7 - Y;
    PaletteNo := Tile shr 12;
    if C and $80 <> 0 then
      Index := ReadMemory(Base + CharBase + Cardinal(Tile and $3FF) * 64 + Cardinal(Y * 8 + X))
    else
    begin
      Index := ReadMemory(Base + CharBase + Cardinal(Tile and $3FF) * 32 + Cardinal(Y * 4 + (X shr 1)));
      Index := (Index shr ((X and 1) * 4)) and 15;
    end;
  end
  else
  begin
    var O := $20 + (BG - 2) * $10;
    var MosaicY := LineY - Y;
    var XX := FAffine[Engine, BG - 2, 0] + Int64(Signed16(Register16(Engine, O))) * X - Int64(Signed16(Register16(Engine, O + 2))) * MosaicY;
    var YY := FAffine[Engine, BG - 2, 1] + Int64(Signed16(Register16(Engine, O + 4))) * X - Int64(Signed16(Register16(Engine, O + 6))) * MosaicY;
    X := Integer(XX shr 8);
    Y := Integer(YY shr 8);
    W := 128 shl Size;
    H := W;
    if ((Kind = 2) and (C and $80 <> 0)) then
      case Size of
        0:
          begin
            W := 128;
            H := 128;
          end;
        1:
          begin
            W := 256;
            H := 256;
          end;
        2:
          begin
            W := 512;
            H := 256;
          end;
        3:
          begin
            W := 512;
            H := 512;
          end;
      end;
    if Kind = 3 then
      if Size and 1 = 0 then
      begin
        W := 512;
        H := 1024;
      end
      else
      begin
        W := 1024;
        H := 512;
      end;
    if C and $2000 <> 0 then
    begin
      X := X and (W - 1);
      Y := Y and (H - 1);
    end
    else if (X < 0) or (Y < 0) or (X >= W) or (Y >= H) then
      Exit;
    if (Kind = 3) or ((Kind = 2) and (C and $80 <> 0)) then
    begin
      MapBase := ((C shr 8) and 31) * $4000;
      if Kind = 3 then
        MapBase := 0;
      if (Kind = 2) and (C and 4 <> 0) then
      begin
        var Color := Read16(Base + MapBase + Cardinal(Y * W + X) * 2);
        if Color and $8000 <> 0 then
          Result := Color and $7FFF;
        Exit;
      end;
      Index := ReadMemory(Base + MapBase + Cardinal(Y * W + X));
    end
    else if Kind = 1 then
    begin
      Tile := ReadMemory(Base + MapBase + Cardinal((Y shr 3) * (W shr 3) + (X shr 3)));
      Index := ReadMemory(Base + CharBase + Cardinal(Tile * 64 + (Y and 7) * 8 + (X and 7)));
    end
    else
    begin
      Tile := Read16(Base + MapBase + Cardinal((Y shr 3) * (W shr 3) + (X shr 3)) * 2);
      X := X and 7;
      Y := Y and 7;
      if Tile and $400 <> 0 then
        X := 7 - X;
      if Tile and $800 <> 0 then
        Y := 7 - Y;
      PaletteNo := Tile shr 12;
      Index := ReadMemory(Base + CharBase + Cardinal((Tile and $3FF) * 64 + Y * 8 + X));
    end;
  end;
  if Index = 0 then
    Exit;

  if ((Kind = 0) and (C and $80 <> 0)) or ((Kind = 2) and (C and $80 = 0)) then
  begin
    if D and $40000000 <> 0 then
    begin
      var Slot := BG;
      if (BG < 2) and (C and $2000 <> 0) then
        Inc(Slot, 2);
      Exit(Read16(NDS_BG_PALETTE + Cardinal(Engine) * $100000 + Cardinal(Slot * $2000 + PaletteNo * $200 + Index * 2)));
    end;
    PaletteNo := 0;
  end
  else if (Kind <> 0) or (C and $80 <> 0) then
    PaletteNo := 0;
  Result := Palette16(Engine * $400 + (PaletteNo * 16 + Index) * 2);
end;

procedure TNDSVideo.BGLine(Engine, BG, Y: Integer; out Line: TNDSPixelLine);
begin
  var D := Register32(Engine, 0);
  if (Engine = 0) and (BG = 0) and (D and 8 <> 0) then
  begin
    var Scroll := Register16(0, $10) and $1FF;
    for var X := 0 to 255 do
    begin
      var GX := (X + Scroll) and $1FF;
      Line[X] := -1;
      if (GX < 256) and (Geometry.Alpha[Y * 256 + GX] <> 0) then
        Line[X] := Geometry.Pixels[Y * 256 + GX];
    end;
    Exit;
  end;

  var Mode := D and 7;
  var Text := (Mode = 0) or ((Mode in [1, 3]) and (BG < 3)) or
    ((Mode in [2, 4, 5]) and (BG < 2));
  if not Text or ((Engine = 0) and (BG = 0) and (D and 8 <> 0)) then
  begin
    for var X := 0 to 255 do
      Line[X] := BGPixel(Engine, BG, X, Y);
    Exit;
  end;

  // Decode a text tile row once for all of its output pixels. Everything is
  // local to this scanline, so DMA/VRAM/palette writes need no cache invalidation.
  var C := Register16(Engine, 8 + BG * 2);
  var Base: Cardinal := $06000000 + Cardinal(Engine) * $200000;
  var CharBase: Cardinal := ((C shr 2) and 15) * $4000;
  var MapBase: Cardinal := ((C shr 8) and 31) * $800;
  if Engine = 0 then
  begin
    Inc(CharBase, ((D shr 24) and 7) * $10000);
    Inc(MapBase, ((D shr 27) and 7) * $10000);
  end;
  var W := 256;
  var H := 256;
  if C and $4000 <> 0 then
    W := 512;
  if C and $8000 <> 0 then
    H := 512;
  var MosaicX := 1;
  if C and $40 <> 0 then
  begin
    var Mosaic := Register16(Engine, $4C);
    MosaicX := (Mosaic and 15) + 1;
    Dec(Y, Y mod (((Mosaic shr 4) and 15) + 1));
  end;
  Y := (Y + Register16(Engine, $12 + BG * 4)) and (H - 1);
  var ScrollX := Register16(Engine, $10 + BG * 4);
  var MapRow := ((Y shr 3) and 31) * 64 + (Y shr 8) * (W shr 8) * $800;
  var LastTileX := -1;
  var Row: array[0..7] of Integer;
  for var X := 0 to 255 do
  begin
    var SX := (X - X mod MosaicX + ScrollX) and (W - 1);
    var TileX := SX shr 3;
    if TileX <> LastTileX then
    begin
      LastTileX := TileX;
      var Tile := Read16(Base + MapBase + Cardinal(MapRow + (TileX and 31) * 2 + (TileX shr 5) * $800));
      var TY := Y and 7;
      if Tile and $800 <> 0 then
        TY := 7 - TY;
      var PaletteBase := Engine * $400 + (Tile shr 12) * 32;
      var Extended: Cardinal := 0;
      if C and $80 <> 0 then
      begin
        PaletteBase := Engine * $400;
        if D and $40000000 <> 0 then
        begin
          var Slot := BG;
          if (BG < 2) and (C and $2000 <> 0) then
            Inc(Slot, 2);
          Extended := NDS_BG_PALETTE + Cardinal(Engine) * $100000 + Cardinal(Slot * $2000 + (Tile shr 12) * $200);
        end;
      end;
      var TileRow := Base + CharBase + Cardinal((Tile and $3FF) * 32 + TY * 4);
      if C and $80 <> 0 then
        TileRow := Base + CharBase + Cardinal((Tile and $3FF) * 64 + TY * 8);
      for var TX := 0 to 7 do
      begin
        var Index: Integer;
        if C and $80 <> 0 then
          Index := ReadMemory(TileRow + Cardinal(TX))
        else
          Index := (ReadMemory(TileRow + Cardinal(TX shr 1)) shr ((TX and 1) * 4)) and 15;
        var Color := -1;
        if Index <> 0 then
          if Extended <> 0 then
            Color := Read16(Extended + Cardinal(Index * 2))
          else
            Color := Palette16(PaletteBase + Index * 2);
        var TargetX := TX;
        if Tile and $400 <> 0 then
          TargetX := 7 - TX;
        Row[TargetX] := Color;
      end;
    end;
    Line[X] := Row[SX and 7];
  end;
end;

procedure TNDSVideo.WriteRegister(Engine, Offset: Integer; Value: Byte);
begin
  Registers[Engine, Offset] := Value;
  if (Offset in [$28..$2F, $38..$3F]) then
  begin
    var BG := (Offset - $20) div 16;
    var Axis := (Offset and 7) div 4;
    FAffine[Engine, BG, Axis] := Signed28(Register32(Engine, $28 + BG * 16 + Axis * 4));
  end;
end;

procedure TNDSVideo.WriteDisplayFIFO(Value: Cardinal; Size: Integer);
begin
  for var i := 0 to Size div 2 - 1 do
    if FFIFOCount < 8 then
    begin
      FDisplayFIFO[(FFIFOHead + FFIFOCount) and 7] := Word(Value shr (i * 16));
      Inc(FFIFOCount);
    end;
end;

function TNDSVideo.FIFOPixel: Word;
begin
  if (FFIFOCount = 0) and Assigned(OnDisplayFIFO) then
    OnDisplayFIFO(Self);
  if FFIFOCount <> 0 then
  begin
    FFIFOLast := FDisplayFIFO[FFIFOHead];
    FFIFOHead := (FFIFOHead + 1) and 7;
    Dec(FFIFOCount);
  end;
  Result := FFIFOLast;
end;

procedure TNDSVideo.VBlank;
begin
  if FCaptureActive then
    Registers[0, $67] := Registers[0, $67] and $7F;
  FCaptureActive := False;
end;

procedure TNDSVideo.CaptureLine(Y: Integer);
const
  Widths: array[0..3] of Integer = (128, 256, 256, 256);
  Heights: array[0..3] of Integer = (128, 64, 128, 192);
begin
  if not FCaptureActive then
    Exit;
  var C := Register32(0, $64);
  var Size: Integer := (C shr 20) and 3;
  if Y >= Heights[Size] then
    Exit;
  var Bank: Integer := (C shr 16) and 3;
  if FBankControl[Bank] and $87 <> $80 then
    Exit;

  var D := Register32(0, 0);
  var ReadBank: Integer := (D shr 18) and 3;
  var SourceMode: Integer := (C shr 29) and 3;
  var ReadOffset: Integer := ((C shr 26) and 3) * $8000;
  if D and $30000 = $20000 then
    ReadOffset := 0;
  var WriteOffset: Integer := ((C shr 18) and 3) * $8000;
  for var X := 0 to Widths[Size] - 1 do
  begin
    var A := FGraphicsLine[X];
    var B: Word := 0;
    if C and $01000000 <> 0 then
    begin
      A := Geometry.Pixels[Y * 256 + X] and $7FFF;
      if Geometry.Alpha[Y * 256 + X] <> 0 then
        A := A or $8000;
    end;
    if C and $02000000 <> 0 then
      B := FFIFOLine[X] or $8000
    else if FBankControl[ReadBank] and $87 = $80 then
    begin
      var P := ReadBank * $20000 + ((ReadOffset + (Y * 256 + X) * 2) and $1FFFF);
      B := VRAM[P] or (Word(VRAM[P + 1]) shl 8);
    end;
    var Color := A;
    if SourceMode = 1 then
      Color := B
    else if SourceMode >= 2 then
    begin
      var EVA := 0;
      var EVB := 0;
      if A and $8000 <> 0 then
        EVA := Min(16, Integer(C and 31));
      if B and $8000 <> 0 then
        EVB := Min(16, Integer((C shr 8) and 31));
      Color := Mix(A, B, EVA, EVB);
      if (EVA <> 0) or (EVB <> 0) then
        Color := Color or $8000;
    end;
    var P := Bank * $20000 + ((WriteOffset + (Y * Widths[Size] + X) * 2) and $1FFFF);
    VRAM[P] := Byte(Color);
    VRAM[P + 1] := Byte(Color shr 8);
  end;
end;

procedure TNDSVideo.RenderLine(Y: Integer);
const
  ObjWidth: array[0..2, 0..3] of Integer = ((8, 16, 32, 64), (16, 32, 32, 64), (8, 8, 16, 32));
  ObjHeight: array[0..2, 0..3] of Integer = ((8, 16, 32, 64), (8, 8, 16, 32), (16, 32, 32, 64));
var
  Colors, Below: array[0..255] of Word;
  Priorities, Layers, BelowLayers: array[0..255] of Integer;
  Semi, ObjWindow: array[0..255] of Boolean;
  ObjColors: array[0..255] of Integer;
  ObjPriorities: array[0..255] of Integer;
  ObjAlpha: array[0..255] of Integer;
  ObjSemi: array[0..255] of Boolean;
  Background: TNDSPixelLine;
  Masks: array[0..255] of Byte;

  function InRange(V, First, Last: Integer): Boolean;
  begin
    if First <= Last then
      Result := (V >= First) and (V < Last)
    else
      Result := (V >= First) or (V < Last);
  end;

  function WindowMask(E, X: Integer; D: Cardinal): Integer;
  begin
    Result := 63;
    if D and $E000 = 0 then
      Exit;

    Result := Register16(E, $4A) and 63;
    if ObjWindow[X] and (D and $8000 <> 0) then
      Result := (Register16(E, $4A) shr 8) and 63;
    for var N := 1 downto 0 do
      if D and (Cardinal($2000) shl N) <> 0 then
      begin
        var WH := Register16(E, $40 + N * 2);
        var WV := Register16(E, $44 + N * 2);
        if InRange(X, WH shr 8, WH and 255) and InRange(Y and 255, WV shr 8, WV and 255) then
          Result := (Register16(E, $48) shr (N * 8)) and 63;
      end;
  end;

begin
  if (Y < 0) or (Y >= 192) then
    Exit;

  if Y = 0 then
    FCaptureActive := Registers[0, $67] and $80 <> 0;
  for var E := 0 to 1 do
    for var B := 0 to 1 do
      for var Axis := 0 to 1 do
      begin
        var O := $20 + B * 16 + Axis * 4;
        if (Y = 0) or (FLastLine < 0) or (Y <= FLastLine) then
          FAffine[E, B, Axis] := Int64(Signed28(Register32(E, O + 8))) + Int64(Signed16(Register16(E, O + 2))) * Y
        else
          Inc(FAffine[E, B, Axis], Int64(Signed16(Register16(E, O + 2))) * (Y - FLastLine - 1));
      end;
  for var E := 0 to 1 do
  begin
    var D := Register32(E, 0);
    var OutputY := Y + E * 192;
    if Power and $8000 = 0 then
      OutputY := Y + (1 - E) * 192;
    if E = 0 then
    begin
      var Capture := Register32(0, $64);
      var NeedFIFO := (D and $30000 = $30000) or
        (FCaptureActive and (Capture and $02000000 <> 0) and (Capture and $60000000 <> 0));
      var Count := 256;
      if (D and $30000 <> $30000) and (Capture and $00300000 = 0) then
        Count := 128;
      if NeedFIFO then
        for var X := 0 to Count - 1 do
          FFIFOLine[X] := FIFOPixel;
    end;
    FillChar(ObjWindow, SizeOf(ObjWindow), 0);
    FillChar(ObjSemi, SizeOf(ObjSemi), 0);
    for var X := 0 to 255 do
    begin
      ObjColors[X] := -1;
      ObjPriorities[X] := 4;
      ObjAlpha[X] := 0;
    end;
    if D and $1000 <> 0 then
      for var N := 127 downto 0 do
      begin
        var A := OAM16(E * $400 + N * 8);
        var B := OAM16(E * $400 + N * 8 + 2);
        var C := OAM16(E * $400 + N * 8 + 4);
        if ((A and $100 = 0) and (A and $200 <> 0)) or (A shr 14 = 3) then
          Continue;
        var W := ObjWidth[A shr 14, B shr 14];
        var H := ObjHeight[A shr 14, B shr 14];
        var DW := W;
        var DH := H;
        if A and $300 = $300 then
        begin
          DW := W * 2;
          DH := H * 2;
        end;
        var OY := (Y - (A and 255)) and 255;
        if OY >= DH then
          Continue;
        var OX := Integer(B and 511);
        if OX >= 256 then
          Dec(OX, 512);
        for var PX := Max(0, OX) to Min(255, OX + DW - 1) do
        begin
          var TX := PX - OX;
          var TY := OY;
          if A and $1000 <> 0 then
          begin
            var Mosaic := Register16(E, $4C);
            Dec(TX, TX mod (((Mosaic shr 8) and 15) + 1));
            Dec(TY, TY mod (((Mosaic shr 12) and 15) + 1));
          end;
          if A and $100 <> 0 then
          begin
            var M := E * $400 + ((B shr 9) and 31) * 32;
            var PA := SmallInt(OAM16(M + 6));
            var PB := SmallInt(OAM16(M + 14));
            var PC := SmallInt(OAM16(M + 22));
            var PD := SmallInt(OAM16(M + 30));
            var SX := TX;
            var SY := TY;
            TX := ((PA * (TX - DW div 2) + PB * (TY - DH div 2)) div 256) + W div 2;
            TY := ((PC * (SX - DW div 2) + PD * (SY - DH div 2)) div 256) + H div 2;
            if (TX < 0) or (TY < 0) or (TX >= W) or (TY >= H) then
              Continue;
          end
          else
          begin
            if B and $1000 <> 0 then
              TX := W - 1 - TX;
            if B and $2000 <> 0 then
              TY := H - 1 - TY;
          end;
          var Mode := (A shr 10) and 3;
          var Address: Cardinal := $06400000 + Cardinal(E) * $200000;
          var Index, Color: Integer;
          if Mode = 3 then
          begin
            if C shr 12 = 0 then
              Continue;
            if D and $40 <> 0 then
              Inc(Address, Cardinal(C and $3FF) * (128 shl ((D shr 22) and 1)) + Cardinal(TY * W + TX) * 2)
            else
            begin
              var Mask := 15;
              if D and $20 <> 0 then
                Mask := 31;
              Inc(Address, Cardinal((C and Mask) * $10 + ((C and $3FF) and not Mask) * $80 + (TY * (Mask + 1) * 8 + TX) * 2));
            end;
            Color := Read16(Address);
            if Color and $8000 = 0 then
              Continue;
          end
          else
          begin
            var Depth := 32;
            if A and $2000 <> 0 then
              Depth := 64;
            var Tile := Integer(C and $3FF);
            if Depth = 64 then
              Tile := Tile and not 1;
            if D and $10 <> 0 then
              Inc(Address, Cardinal(Tile) * (32 shl ((D shr 20) and 3)) + Cardinal((TY shr 3) * (W shr 3) + (TX shr 3)) * Cardinal(Depth))
            else
              Inc(Address, Cardinal(Tile * 32 + (TY shr 3) * 1024 + (TX shr 3) * Depth));
            Index := ReadMemory(Address + Cardinal((TY and 7) * Depth div 8 + (TX and 7) * Depth div 64));
            if Depth = 32 then
              Index := (Index shr ((TX and 1) * 4)) and 15;
            if Index = 0 then
              Continue;
            if Mode = 2 then
            begin
              ObjWindow[PX] := True;
              Continue;
            end;
            if (Depth = 64) and (D and $80000000 <> 0) then
              Color := Read16(NDS_OBJ_PALETTE + Cardinal(E) * $100000 + Cardinal((C shr 12) * 512 + Index * 2))
            else
            begin
              if Depth = 32 then
                Inc(Index, (C shr 12) * 16);
              Color := Palette16(E * $400 + $200 + Index * 2);
            end;
          end;
          var Priority := (C shr 10) and 3;
          if Priority > ObjPriorities[PX] then
            Continue;
          ObjColors[PX] := Color;
          ObjPriorities[PX] := Priority;
          ObjSemi[PX] := Mode in [1, 3];
          ObjAlpha[PX] := 0;
          if Mode = 3 then
            ObjAlpha[PX] := (C shr 12) + 1;
        end;
      end;

    for var X := 0 to 255 do
    begin
      Colors[X] := Palette16(E * $400);
      Below[X] := Colors[X];
      Priorities[X] := 4;
      Layers[X] := 5;
      BelowLayers[X] := 5;
      Semi[X] := False;
    end;
    if D and $E000 = 0 then
      FillChar(Masks, SizeOf(Masks), 63)
    else
      for var X := 0 to 255 do
        Masks[X] := WindowMask(E, X, D);
    for var BG := 3 downto 0 do
      if (D and (Cardinal($100) shl BG) <> 0) then
      begin
        BGLine(E, BG, Y, Background);
        var Priority := Register16(E, 8 + BG * 2) and 3;
        for var X := 0 to 255 do
        begin
          if Masks[X] and (1 shl BG) = 0 then
            Continue;
          var Color := Background[X];
          if Color < 0 then
            Continue;
          if Priority <= Priorities[X] then
          begin
            Below[X] := Colors[X];
            BelowLayers[X] := Layers[X];
            Colors[X] := Color;
            Layers[X] := BG;
            Priorities[X] := Priority;
          end
          else if (BelowLayers[X] = 5) or (Priority <= (Register16(E, 8 + BelowLayers[X] * 2) and 3)) then
          begin
            Below[X] := Color;
            BelowLayers[X] := BG;
          end;
        end;
      end;
    var Blend := Register16(E, $50);
    var BlendMode := (Blend shr 6) and 3;
    var EVA := Min(16, Register16(E, $52) and 31);
    var EVB := Min(16, (Register16(E, $52) shr 8) and 31);
    var EVY := Min(16, Register16(E, $54) and 31);
    var Scroll3D := Register16(0, $10) and $1FF;
    var Master := Register16(E, $6C);
    for var X := 0 to 255 do
    begin
      var Mask := Masks[X];
      if (ObjColors[X] >= 0) and (Mask and $10 <> 0) then
        if ObjPriorities[X] <= Priorities[X] then
        begin
          Below[X] := Colors[X];
          BelowLayers[X] := Layers[X];
          Colors[X] := ObjColors[X];
          Layers[X] := 4;
          Semi[X] := ObjSemi[X];
        end
        else if (BelowLayers[X] = 5) or (ObjPriorities[X] <= (Register16(E, 8 + BelowLayers[X] * 2) and 3)) then
        begin
          Below[X] := ObjColors[X];
          BelowLayers[X] := 4;
        end;
      var Color := Colors[X];
      if Mask and $20 <> 0 then
      begin
        var GX := (X + Scroll3D) and $1FF;
        if (Layers[X] = 4) and (ObjAlpha[X] <> 0) and (Blend and (1 shl (8 + BelowLayers[X])) <> 0) then
          Color := Mix(Color, Below[X], ObjAlpha[X], 16 - ObjAlpha[X])
        else if (E = 0) and (D and 8 <> 0) and (Layers[X] = 0) and (GX < 256) and
          (Blend and (1 shl (8 + BelowLayers[X])) <> 0) then
        begin
          var A := Geometry.Alpha[Y * 256 + GX] + 1;
          var ResultColor := 0;
          for var Channel := 0 to 2 do
            ResultColor := ResultColor or (((((Color shr (Channel * 5)) and 31) * A +
              ((Below[X] shr (Channel * 5)) and 31) * (32 - A)) shr 5) shl (Channel * 5));
          Color := ResultColor;
        end
        else if ((Semi[X] or ((BlendMode = 1) and (Blend and (1 shl Layers[X]) <> 0))) and
          (Blend and (1 shl (8 + BelowLayers[X])) <> 0)) then
          Color := Mix(Color, Below[X], EVA, EVB)
        else if (BlendMode in [2, 3]) and (Blend and (1 shl Layers[X]) <> 0) then
          Color := Brighten(Color, EVY, BlendMode = 2);
      end;
      if E = 0 then
        FGraphicsLine[X] := Color or $8000;
      if (E = 0) and (D and $30000 = $30000) then
        Color := FFIFOLine[X];
      if (E = 0) and (D and $30000 = $20000) then
      begin
        var Address := ((D shr 18) and 3) * $20000 + Cardinal(Y * 256 + X) * 2;
        Color := 0;
        if FBankControl[(D shr 18) and 3] and $87 = $80 then
          Color := VRAM[Address] or (Word(VRAM[Address + 1]) shl 8);
      end;
      if (Power and 1 = 0) or (D and $80 <> 0) or (D and $30000 = 0) then
        Color := $7FFF;
      if Master shr 14 in [1, 2] then
        Color := Brighten(Color, Min(16, Master and 31), Master shr 14 = 1);
      Pixels[OutputY * 256 + X] := Color32(Color);
    end;
    if E = 0 then
      CaptureLine(Y);
    for var B := 0 to 1 do
      for var Axis := 0 to 1 do
        Inc(FAffine[E, B, Axis], Signed16(Register16(E, $22 + B * 16 + Axis * 4)));
  end;
  FLastLine := Y;
end;

procedure TNDSVideo.SerializeState(State: TStateArchive; Version: Cardinal);
begin
  State.Field(FBankControl, SizeOf(FBankControl));
  State.Field(VRAM, SizeOf(VRAM));
  State.Field(Palette, SizeOf(Palette));
  State.Field(OAM, SizeOf(OAM));
  State.Field(Registers, SizeOf(Registers));
  State.Field(Pixels, SizeOf(Pixels));
  State.Field(Power, SizeOf(Power));
  State.Field(FAffine, SizeOf(FAffine));
  State.Field(FLastLine, SizeOf(FLastLine));
  State.Field(FCaptureActive, SizeOf(FCaptureActive));
  State.Field(FDisplayFIFO, SizeOf(FDisplayFIFO));
  State.Field(FFIFOHead, SizeOf(FFIFOHead));
  State.Field(FFIFOCount, SizeOf(FFIFOCount));
  State.Field(FFIFOLast, SizeOf(FFIFOLast));
  State.Field(FGraphicsLine, SizeOf(FGraphicsLine));
  State.Field(FFIFOLine, SizeOf(FFIFOLine));
  if State.Loading and ((FFIFOHead < 0) or (FFIFOHead > 7) or (FFIFOCount < 0) or (FFIFOCount > 8) or (FLastLine < -1) or (FLastLine > 191)) then
    raise EReadError.Create('Invalid NDS snapshot display FIFO');

  Geometry.SerializeState(State, Version);
  if State.Loading then
    RebuildMap;
end;

end.

