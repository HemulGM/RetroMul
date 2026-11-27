unit RA.Hash;

interface

{$SCOPEDENUMS ON}

uses
  System.Classes, System.SysUtils;

type
  TRARomConsole = (
    MegaDrive = 1,
    Nintendo64 = 2,
    SuperNintendo = 3,
    GameBoy = 4,
    GameBoyAdvance = 5,
    GameBoyColor = 6,
    Nintendo = 7,
    PCEngine = 8,
    Sega32X = 10,
    MasterSystem = 11,
    AtariLynx = 13,
    NeoGeoPocket = 14,
    GameGear = 15,
    GameCube = 16,
    AtariJaguar = 17,
    NintendoDS = 18,
    Wii = 19,
    MagnavoxOdyssey2 = 23,
    PokemonMini = 24,
    Atari2600 = 25,
    NeoGeoCartridge = 27,
    VirtualBoy = 28,
    MSX = 29,
    Commodore64 = 30,
    Oric = 32,
    SG1000 = 33,
    AmstradPC = 37,
    AppleII = 38,
    PSPPackage = 41,
    ColecoVision = 44,
    Intellivision = 45,
    Vectrex = 46,
    PC8800 = 47,
    Atari7800 = 51,
    WonderSwan = 53,
    SuperCassettevision = 55,
    FairchildChannelF = 57,
    ZXSpectrum = 59,
    Nintendo3DS = 62,
    Supervision = 63,
    TIC80 = 65,
    MegaDuck = 69,
    Arduboy = 71,
    WASM4 = 72,
    Arcadia2001 = 73,
    IntertonVC4000 = 74,
    ElektorTvGamesComputer = 75,
    NintendoDSi = 78,
    TI83 = 79,
    Uzebox = 80,
    FamicomDiskSystem = 81
    );

function TryHashRARom(Console: TRARomConsole; const Data: TBytes; out Digest: string): Boolean; overload;

// The current stream position marks the start of the ROM and is preserved.
function TryHashRARom(Console: TRARomConsole; Stream: TStream; out Digest: string): Boolean; overload;

// Streams the same bytes as the buffer overload. The limit applies after the ROM header.
function TryHashRAEmulatedROM(Console: TRARomConsole; Stream: TStream; out Digest: string): Boolean;

implementation

uses
  System.Hash, System.Math, RA.DiscHash, RA.Hash3DS, RA.Streams;

const
  MaxHashSize = 64 * 1024 * 1024;
  HashChunkSize = 64 * 1024;

type
  TRARomHeader = array[0..9] of Byte;

  TN64ByteOrder = (Native, SwapPairs, ReverseWords);

function GetRomHeaderSize(Console: TRARomConsole; const Header: TRARomHeader; Size: Int64): Integer;
begin
  Result := 0;
  case Console of
    TRARomConsole.Atari7800:
      if (Size > 128) and CompareMem(@Header[1], PAnsiChar(AnsiString('ATARI7800')), 9) then
        Result := 128;
    TRARomConsole.AtariLynx:
      if (Size > 64) and CompareMem(@Header[0], PAnsiChar(AnsiString('LYNX'#0)), 5) then
        Result := 64;
    TRARomConsole.Nintendo, TRARomConsole.FamicomDiskSystem:
      if (Size > 16) and (Header[3] = $1A) and
        (CompareMem(@Header[0], PAnsiChar(AnsiString('NES')), 3) or
        CompareMem(@Header[0], PAnsiChar(AnsiString('FDS')), 3)) then
        Result := 16;
    TRARomConsole.SuperCassettevision:
      if (Size > 32) and CompareMem(@Header[0], PAnsiChar(AnsiString('EmuSCV')), 6) then
        Result := 32;
    TRARomConsole.PCEngine:
      if (Size and 512) <> 0 then
        Result := 512;
    TRARomConsole.SuperNintendo:
      if (Size mod $2000) = 512 then
        Result := 512;
  end;
end;

function TryGetRomLayout(Console: TRARomConsole; const Header: TRARomHeader; Size: Int64; out Offset: Integer; out ByteOrder: TN64ByteOrder): Boolean;
begin
  Offset := 0;
  ByteOrder := TN64ByteOrder.Native;
  case Console of
    TRARomConsole.Nintendo64:
      case Header[0] of
        $80, $E8, $22:
          ;
        $37:
          ByteOrder := TN64ByteOrder.SwapPairs;
        $40:
          ByteOrder := TN64ByteOrder.ReverseWords;
      else
        Exit(False);
      end;
    TRARomConsole.NeoGeoCartridge:
      begin
        Offset := 4096;
        if (Size < Offset) or not CompareMem(@Header[0], PAnsiChar(AnsiString('NEO'#1)), 4) then
          Exit(False);
      end;
    TRARomConsole.Atari7800, TRARomConsole.AtariLynx, TRARomConsole.Nintendo, TRARomConsole.FamicomDiskSystem, TRARomConsole.PCEngine, TRARomConsole.SuperNintendo, TRARomConsole.SuperCassettevision:
      Offset := GetRomHeaderSize(Console, Header, Size);
    TRARomConsole.MegaDrive, TRARomConsole.GameBoy, TRARomConsole.GameBoyAdvance, TRARomConsole.GameBoyColor, TRARomConsole.Sega32X, TRARomConsole.MasterSystem, TRARomConsole.NeoGeoPocket, TRARomConsole.GameGear, TRARomConsole.AtariJaguar, TRARomConsole.Atari2600, TRARomConsole.VirtualBoy, TRARomConsole.SG1000, TRARomConsole.ColecoVision, TRARomConsole.WonderSwan, TRARomConsole.PSPPackage, TRARomConsole.MagnavoxOdyssey2, TRARomConsole.PokemonMini, TRARomConsole.MSX, TRARomConsole.Commodore64, TRARomConsole.Oric,
      TRARomConsole.AmstradPC, TRARomConsole.AppleII, TRARomConsole.Intellivision, TRARomConsole.Vectrex, TRARomConsole.PC8800, TRARomConsole.FairchildChannelF, TRARomConsole.ZXSpectrum, TRARomConsole.Supervision, TRARomConsole.TIC80, TRARomConsole.MegaDuck, TRARomConsole.WASM4, TRARomConsole.Arcadia2001, TRARomConsole.IntertonVC4000, TRARomConsole.ElektorTvGamesComputer, TRARomConsole.TI83, TRARomConsole.Uzebox:
      ;
  else
    Exit(False);
  end;
  Result := True;
end;

procedure NormalizeN64ByteOrder(var Data: TBytes; Count: Integer; ByteOrder: TN64ByteOrder);
var
  Offset: Integer;
  First, Second: Byte;
begin
  if ByteOrder = TN64ByteOrder.Native then
    Exit;

  Offset := 0;
  while Offset + 4 <= Count do
  begin
    First := Data[Offset];
    Second := Data[Offset + 1];
    if ByteOrder = TN64ByteOrder.SwapPairs then
    begin
      Data[Offset] := Second;
      Data[Offset + 1] := First;
      First := Data[Offset + 2];
      Data[Offset + 2] := Data[Offset + 3];
      Data[Offset + 3] := First;
    end
    else
    begin
      Data[Offset] := Data[Offset + 3];
      Data[Offset + 1] := Data[Offset + 2];
      Data[Offset + 2] := Second;
      Data[Offset + 3] := First;
    end;
    Inc(Offset, 4);
  end;

  // A v64 image can end with one more complete 16-bit pair.
  if (ByteOrder = TN64ByteOrder.SwapPairs) and (Count - Offset >= 2) then
  begin
    First := Data[Offset];
    Data[Offset] := Data[Offset + 1];
    Data[Offset + 1] := First;
  end;
end;

function HashNintendoDS(Stream: TStream; Start: Int64; out Digest: string): Boolean;
const
  MaxCodeSize = 16 * 1024 * 1024;
  BannerSize = $A00;
  HeaderHashSize = $160;
var
  Header: array[0..511] of Byte;
  Banner: array[0..BannerSize - 1] of Byte;
  Arm9Size, Arm7Size, BannerOffset: Cardinal;
  Hash: THashMD5;
  Buffer: TBytes;
  Available: Int64;
  Received: Integer;

  function ReadOffset(Index: Integer): Cardinal;
  begin
    Result := Cardinal(Header[Index]) or (Cardinal(Header[Index + 1]) shl 8) or
      (Cardinal(Header[Index + 2]) shl 16) or (Cardinal(Header[Index + 3]) shl 24);
  end;

  function HashCode(Offset, Size: Cardinal): Boolean;
  var
    Count: Integer;
  begin
    if UInt64(Offset) + Size > UInt64(Available) then
      Exit(Size = 0);
    Stream.Position := Start + Offset;
    while Size <> 0 do
    begin
      Count := Integer(Min(Size, Cardinal(Length(Buffer))));
      if ReadRAStream(Stream, Buffer[0], Count) <> Count then
        Exit(False);
      Hash.Update(Buffer, Count);
      Dec(Size, Count);
    end;
    Result := True;
  end;

begin
  Available := Stream.Size - Start;
  if Available < SizeOf(Header) then
    Exit(False);
  if ReadRAStream(Stream, Header, SizeOf(Header)) <> SizeOf(Header) then
    Exit(False);
  if (ReadOffset(0) = $EA00002E) and (ReadOffset($B0) = $00964644) then
  begin
    Inc(Start, SizeOf(Header));
    Dec(Available, SizeOf(Header));
    if Available < HeaderHashSize then
      Exit(False);
    Received := Stream.Read(Header[0], Integer(SizeOf(Header)));
    if (Received < HeaderHashSize) or (Received > SizeOf(Header)) then
      Exit(False);
  end;

  Arm9Size := ReadOffset($2C);
  Arm7Size := ReadOffset($3C);
  if UInt64(Arm9Size) + Arm7Size > MaxCodeSize then
    Exit(False);
  Hash := THashMD5.Create;
  Hash.Update(Header[0], HeaderHashSize);
  SetLength(Buffer, HashChunkSize);
  if not HashCode(ReadOffset($20), Arm9Size) or not HashCode(ReadOffset($30), Arm7Size) then
    Exit(False);

  BannerOffset := ReadOffset($68);
  Received := 0;
  if BannerOffset < Available then
  begin
    Stream.Position := Start + BannerOffset;
    // The original hashes one read of the banner, then pads the unread suffix.
    Received := Stream.Read(Banner[0], Integer(SizeOf(Banner)));
  end;
  if (Received < 0) or (Received > SizeOf(Banner)) then
    Exit(False);
  if Received < SizeOf(Banner) then
    FillChar(Banner[Received], SizeOf(Banner) - Received, 0);
  Hash.Update(Banner[0], SizeOf(Banner));
  Digest := LowerCase(Hash.HashAsString);
  Result := True;
end;

function HashArduboyText(Stream: TStream; Remaining: Int64; out Digest: string): Boolean;
const
  LineFeed: Byte = 10;
var
  Hash: THashMD5;
  Buffer: TBytes;
  Count, Written: Integer;
  Ch: Byte;
  AfterCR, AtLineEnd: Boolean;
begin
  Hash := THashMD5.Create;
  SetLength(Buffer, Integer(Min(Remaining, Int64(HashChunkSize))));
  AfterCR := False;
  AtLineEnd := False;
  while Remaining > 0 do
  begin
    Count := Integer(Min(Remaining, Int64(Length(Buffer))));
    if ReadRAStream(Stream, Buffer[0], Count) <> Count then
      Exit(False);
    Written := 0;
    for var I := 0 to Count - 1 do
    begin
      Ch := Buffer[I];
      AtLineEnd := Ch in [10, 13];
      if AtLineEnd then
      begin
        if (Ch = 13) or not AfterCR then
        begin
          Buffer[Written] := LineFeed;
          Inc(Written);
        end;
      end
      else
      begin
        Buffer[Written] := Ch;
        Inc(Written);
      end;
      AfterCR := Ch = 13;
    end;
    if Written <> 0 then
      Hash.Update(Buffer[0], Written);
    Dec(Remaining, Count);
  end;
  if not AtLineEnd then
    Hash.Update(LineFeed, SizeOf(LineFeed));
  Digest := LowerCase(Hash.HashAsString);
  Result := True;
end;

function HashRom(Console: TRARomConsole; Stream: TStream; LimitBeforeHeader: Boolean; out Digest: string): Boolean;
var
  Start, Size, Remaining: Int64;
  Header: TRARomHeader;
  Offset, Count: Integer;
  ByteOrder: TN64ByteOrder;
  Hash: THashMD5;
  Buffer: TBytes;
begin
  Digest := '';
  if Console = TRARomConsole.GameCube then
    Exit(TryHashRAGameCube(Stream, Digest));
  if Console = TRARomConsole.Wii then
    Exit(TryHashRAWii(Stream, Digest));
  if Console = TRARomConsole.Nintendo3DS then
    Exit(TryHashRA3DS(Stream, Digest));
  Start := Stream.Position;
  Size := Stream.Size - Start;
  if Size < 0 then
    Exit(False);
  // File-based hashing buffers at most 64 MiB before examining the header.
  if LimitBeforeHeader and (Console <> TRARomConsole.NeoGeoCartridge) then
    Size := Min(Size, Int64(MaxHashSize));

  try
    if Console = TRARomConsole.Arduboy then
      Exit(HashArduboyText(Stream, Size, Digest));
    if Console in [TRARomConsole.NintendoDS, TRARomConsole.NintendoDSi] then
      Exit(HashNintendoDS(Stream, Start, Digest));
    if LimitBeforeHeader and (Console = TRARomConsole.NeoGeoCartridge) and (Size <= 4096) then
      Exit(False);
    Header := Default(TRARomHeader);
    Count := Integer(Min(Size, Int64(SizeOf(Header))));
    if ReadRAStream(Stream, Header, Count) <> Count then
      Exit(False);
    if not TryGetRomLayout(Console, Header, Size, Offset, ByteOrder) then
      Exit(False);

    Hash := THashMD5.Create;
    Stream.Position := Start + Offset;
    Remaining := Min(Size - Offset, Int64(MaxHashSize));
    SetLength(Buffer, Integer(Min(Remaining, Int64(HashChunkSize))));
    while Remaining > 0 do
    begin
      Count := Integer(Min(Remaining, Int64(Length(Buffer))));
      if ReadRAStream(Stream, Buffer[0], Count) <> Count then
        Exit(False);
      NormalizeN64ByteOrder(Buffer, Count, ByteOrder);
      Hash.Update(Buffer, Count);
      Dec(Remaining, Count);
    end;
    Digest := LowerCase(Hash.HashAsString);
    Result := True;
  finally
    Stream.Position := Start;
  end;
end;

function TryHashRARom(Console: TRARomConsole; const Data: TBytes; out Digest: string): Boolean;
var
  Stream: TBytesStream;
begin
  Stream := TBytesStream.Create(Data);
  try
    Result := HashRom(Console, Stream, False, Digest);
  finally
    Stream.Free;
  end;
end;

function TryHashRARom(Console: TRARomConsole; Stream: TStream; out Digest: string): Boolean;
begin
  Digest := '';
  Result := Assigned(Stream) and HashRom(Console, Stream, True, Digest);
end;

function TryHashRAEmulatedROM(Console: TRARomConsole; Stream: TStream; out Digest: string): Boolean;
begin
  Digest := '';
  Result := Assigned(Stream) and HashRom(Console, Stream, False, Digest);
end;

end.

