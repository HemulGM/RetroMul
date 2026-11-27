unit RA.Hash3DS;

interface

uses
  System.Classes, RA.AES128;

type
  TRA3DSKey = TRAAESBlock;

  TRA3DSProgramID = array[0..7] of Byte;

  PRA3DSProgramID = ^TRA3DSProgramID;

  TRACIAKeyProvider = reference to function(CommonKeyIndex: Byte; out Key: TRA3DSKey): Boolean;

  // ProgramID points to the eight header bytes for seed crypto, or is nil.
  TRANCCHKeyProvider = reference to function(const PrimaryKeyY: TRA3DSKey; SecondaryKeyXSlot: Byte; ProgramID: PRA3DSProgramID; out PrimaryKey, SecondaryKey: TRA3DSKey): Boolean;

  TRA3DSKeyProviders = record
    CIA: TRACIAKeyProvider;
    NCCH: TRANCCHKeyProvider;
  end;

// Hash from the current stream position and preserve it. Key callbacks return normal keys in big endian order.
function TryHashRA3DS(Stream: TStream; out Digest: string): Boolean; overload;

function TryHashRA3DS(Stream: TStream; const Keys: TRA3DSKeyProviders; out Digest: string): Boolean; overload;

implementation

uses
  System.Hash, System.Math, System.SysUtils, RA.Streams;

const
  MediaUnit = $200;
  MaxHashSize = 64 * 1024 * 1024;
  HashChunkSize = 64 * 1024;
  MagicNCCH = $4843434E;
  MagicNCSD = $4453434E;
  MagicCIA = $2020;
  Magic3DSX = $58534433;
  MagicELF = $464C457F;

type
  TRA3DSHeader = array[0..MediaUnit - 1] of Byte;

  PRAAES128 = ^TRAAES128;

  TRA3DSImage = record
    Stream: TStream;
    Start, Size: Int64;
    function ReadAt(Offset: Int64; var Buffer; Count: Integer): Boolean;
  end;

function LE16(P: PByte): Word; inline;
begin
  Result := Word(P[0]) or (Word(P[1]) shl 8);
end;

function BE16(P: PByte): Word; inline;
begin
  Result := (Word(P[0]) shl 8) or Word(P[1]);
end;

function LE32(P: PByte): Cardinal; inline;
begin
  Result := Cardinal(LE16(P)) or (Cardinal(LE16(P + 2)) shl 16);
end;

function BE32(P: PByte): Cardinal; inline;
begin
  Result := (Cardinal(BE16(P)) shl 16) or Cardinal(BE16(P + 2));
end;

function AlignUp(Value, Alignment: Int64): Int64; inline;
begin
  Result := (Value + Alignment - 1) and not (Alignment - 1);
end;

function TRA3DSImage.ReadAt(Offset: Int64; var Buffer; Count: Integer): Boolean;
begin
  if (Offset < 0) or (Offset > Size - Count) then
    Exit(False);
  Stream.Position := Start + Offset;
  Result := ReadRAStream(Stream, Buffer, Count) = Count;
end;

function AppendRange(const Image: TRA3DSImage; Offset, Remaining: Int64; var Hash: THashMD5): Boolean;
var
  Buffer: TBytes;
  Count: Integer;
begin
  if Remaining = 0 then
    Exit(True);
  if (Offset < 0) or (Offset > Image.Size - Remaining) then
    Exit(False);
  SetLength(Buffer, Integer(Min(Remaining, Int64(HashChunkSize))));
  while Remaining > 0 do
  begin
    Count := Integer(Min(Remaining, Int64(Length(Buffer))));
    if not Image.ReadAt(Offset, Buffer[0], Count) then
      Exit(False);
    Hash.Update(Buffer[0], Count);
    Inc(Offset, Count);
    Dec(Remaining, Count);
  end;
  Result := True;
end;

function InitNCCHKeys(const Header: TRA3DSHeader; const GetKeys: TRANCCHKeyProvider; out Primary, Secondary: TRAAES128): Boolean;
var
  PrimaryKey, SecondaryKey, PrimaryKeyY: TRA3DSKey;
  ProgramID: TRA3DSProgramID;
  ProgramIDPtr: PRA3DSProgramID;
  SecondarySlot: Byte;
begin
  if (Header[$18F] and $01) <> 0 then
  begin
    PrimaryKey := Default(TRA3DSKey);
    SecondaryKey := PrimaryKey;
  end
  else
  begin
    if not Assigned(GetKeys) then
      Exit(False);
    case Header[$18B] of
      $00:
        SecondarySlot := $2C;
      $01:
        SecondarySlot := $25;
      $0A:
        SecondarySlot := $18;
      $0B:
        SecondarySlot := $1B;
    else
      Exit(False);
    end;
    Move(Header[0], PrimaryKeyY, SizeOf(PrimaryKeyY));
    ProgramIDPtr := nil;
    if (Header[$18F] and $20) <> 0 then
    begin
      Move(Header[$118], ProgramID, SizeOf(ProgramID));
      ProgramIDPtr := @ProgramID;
    end;
    if not GetKeys(PrimaryKeyY, SecondarySlot, ProgramIDPtr, PrimaryKey, SecondaryKey) then
      Exit(False);
  end;
  Primary.SetKey(PrimaryKey);
  Secondary.SetKey(SecondaryKey);
  Result := True;
end;

function InitNCCHCounter(const Header: TRA3DSHeader; ExeFSOffset: Int64; out Counter: TRAAESBlock): Boolean;
begin
  Counter := Default(TRAAESBlock);
  case LE16(@Header[$112]) of
    0, 2:
      begin
        for var I := 0 to 7 do
          Counter[7 - I] := Header[$108 + I];
        Counter[8] := 2;
      end;
    1:
      begin
        Move(Header[$108], Counter[0], 8);
        for var I := 0 to 3 do
          Counter[15 - I] := Byte((ExeFSOffset shr (8 * I)) and $FF);
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

function DecryptExeFS(var Buffer: TBytes; RealSize: Int64; var Counter: TRAAESBlock; const Primary, Secondary: TRAAES128): Boolean;
var
  Entry, Section: PByte;
  Offset, Size, AlignedSize: Int64;
  Cipher: PRAAES128;
  FullBlocks, Padding, Tail: Integer;
  SavedCounter: TRAAESBlock;
begin
  Primary.ApplyCTR(Counter, @Buffer[0], MediaUnit);
  for var I := 0 to 7 do
  begin
    Entry := @Buffer[I * 16];
    Size := LE32(Entry + 12);
    if Size = 0 then
      Continue;
    Offset := LE32(Entry + 8);
    if (Offset and (MediaUnit - 1)) <> 0 then
      Exit(False);
    Inc(Offset, MediaUnit);
    AlignedSize := AlignUp(Size, MediaUnit);
    if Offset + AlignedSize > RealSize then
      Exit(False);

    // The header order determines counter advancement. icon and banner use the primary key.
    if (LE32(Entry) = $6E6F6369) or ((LE32(Entry) = $6E6E6162) and (LE16(Entry + 4) = $7265)) then
    begin
      Size := AlignedSize;
      Cipher := @Primary;
    end
    else
      Cipher := @Secondary;

    Size := Min(Size, Int64(Length(Buffer)) - Offset);
    if Size <= 0 then
      Continue;
    Section := @Buffer[Integer(Offset)];
    FullBlocks := Integer(Size) and not (SizeOf(TRAAESBlock) - 1);
    Cipher.ApplyCTR(Counter, Section, FullBlocks);

    Padding := Integer(AlignUp(Size, MediaUnit) - Size);
    if Padding <> 0 then
    begin
      Inc(Section, FullBlocks);
      Tail := Integer(Size) - FullBlocks;
      if Tail <> 0 then
      begin
        // Convert the partial data block to the primary key so it can be processed with its padding.
        SavedCounter := Counter;
        Cipher.ApplyCTR(Counter, Section, Tail);
        Counter := SavedCounter;
        Primary.ApplyCTR(Counter, Section, Tail);
        Counter := SavedCounter;
      end;
      Primary.ApplyCTR(Counter, Section, Tail + Padding);
    end;
  end;
  Result := True;
end;

function HashNCCH(const Image: TRA3DSImage; Start: Int64; var Header: TRA3DSHeader; var Hash: THashMD5; const Keys: TRA3DSKeyProviders; CIACipher: PRAAES128): Boolean;
var
  Offset, RealSize: Int64;
  Size: Integer;
  Encrypted: Boolean;
  Buffer: TBytes;
  Primary, Secondary: TRAAES128;
  Counter, IV: TRAAESBlock;
begin
  Offset := Int64(LE32(@Header[$1A0])) * MediaUnit;
  RealSize := Int64(LE32(@Header[$1A4])) * MediaUnit;
  Size := Integer(Min(RealSize, Int64(MaxHashSize)));
  if (Offset = 0) or (Size = 0) then
    Exit(False);

  Encrypted := (Header[$18F] and $04) = 0;
  if Encrypted and (not InitNCCHKeys(Header, Keys.NCCH, Primary, Secondary) or
    not InitNCCHCounter(Header, Offset, Counter)) then
    Exit(False);

  if Start + Offset > Image.Size - Size then
    Exit(False);
  SetLength(Buffer, Size);
  if (CIACipher <> nil) and not Image.ReadAt(Start + Offset - SizeOf(IV), IV, SizeOf(IV)) then
    Exit(False);
  if not Image.ReadAt(Start + Offset, Buffer[0], Size) then
    Exit(False);
  if CIACipher <> nil then
    CIACipher.DecryptCBC(IV, @Buffer[0], Size);
  if Encrypted and not DecryptExeFS(Buffer, RealSize, Counter, Primary, Secondary) then
    Exit(False);

  // Normalize the same fields for encrypted and clear containers.
  FillChar(Header[$114], 4, 0);
  Header[$18B] := 0;
  Header[$18F] := Header[$18F] and not $25;
  Hash.Update(Header[0], SizeOf(Header));
  Hash.Update(Buffer[0], Size);
  Result := True;
end;

function ReadSignedBody(const Image: TRA3DSImage; Offset: Int64; out BodyOffset: Int64): Boolean;
var
  Signature: array[0..3] of Byte;
  Size: Integer;
begin
  if not Image.ReadAt(Offset, Signature, SizeOf(Signature)) then
    Exit(False);
  case BE32(@Signature[0]) of
    $010000, $010003:
      Size := $23C;
    $010001, $010004:
      Size := $13C;
    $010002, $010005:
      Size := $7C;
  else
    Exit(False);
  end;
  BodyOffset := Offset + SizeOf(Signature) + Size;
  Result := True;
end;

function HashCIA(const Image: TRA3DSImage; var Header: TRA3DSHeader; var Hash: THashMD5; const Keys: TRA3DSKeyProviders): Boolean;
const
  CIAHeaderSize = $2020;
  CIAAlignment = 64;
var
  TicketOffset, TMDOffset, Offset, Body, ChunkOffset: Int64;
  Count: Integer;
  Encrypted: Boolean;
  CommonKeyIndex: Byte;
  CommonKey, TitleKey: TRA3DSKey;
  IV: TRAAESBlock;
  Cipher: TRAAES128;
  CIACipher: PRAAES128;
begin
  TicketOffset := AlignUp(AlignUp(CIAHeaderSize, CIAAlignment) + LE32(@Header[8]), CIAAlignment);
  TMDOffset := AlignUp(TicketOffset + LE32(@Header[$0C]), CIAAlignment);
  Offset := AlignUp(TMDOffset + LE32(@Header[$10]), CIAAlignment);
  if not ReadSignedBody(Image, TMDOffset, Body) or not Image.ReadAt(Body + $9E, Header, 2) then
    Exit(False);
  Count := BE16(@Header[0]);

  ChunkOffset := Body + $9C4;
  for var I := 0 to Count - 1 do
  begin
    if not Image.ReadAt(ChunkOffset + Int64(I) * $30, Header, $30) then
      Exit(False);
    if BE16(@Header[4]) = 0 then
    begin
      Encrypted := (Header[7] and 1) <> 0;
      CIACipher := nil;
      if Encrypted then
      begin
        if not Assigned(Keys.CIA) or not ReadSignedBody(Image, TicketOffset, Body) or
          not Image.ReadAt(Body, Header, $B2) then
          Exit(False);
        CommonKeyIndex := Header[$B1];
        if (CommonKeyIndex > 5) or not Keys.CIA(CommonKeyIndex, CommonKey) then
          Exit(False);
        Move(Header[$7F], TitleKey, SizeOf(TitleKey));
        IV := Default(TRAAESBlock);
        Move(Header[$9C], IV[0], SizeOf(TRA3DSProgramID));
        Cipher.SetKey(CommonKey);
        Cipher.DecryptCBC(IV, @TitleKey[0], SizeOf(TitleKey));
        Cipher.SetKey(TitleKey);
        CIACipher := @Cipher;
      end;

      if not Image.ReadAt(Offset, Header, SizeOf(Header)) then
        Exit(False);
      if CIACipher <> nil then
      begin
        IV := Default(TRAAESBlock);
        CIACipher.DecryptCBC(IV, @Header[0], SizeOf(Header));
      end;
      Exit((LE32(@Header[$100]) = MagicNCCH) and HashNCCH(Image, Offset, Header, Hash, Keys, CIACipher));
    end;
    Inc(Offset, BE32(@Header[$0C]));
  end;
  Result := False;
end;

function HashImage(const Image: TRA3DSImage; const Keys: TRA3DSKeyProviders; var Hash: THashMD5): Boolean;
var
  Header: TRA3DSHeader;
  Offset: Int64;
begin
  if not Image.ReadAt(0, Header, SizeOf(Header)) then
    Exit(False);
  Offset := 0;
  if LE32(@Header[$100]) = MagicNCSD then
  begin
    Offset := Int64(LE32(@Header[$120])) * MediaUnit;
    Hash.Update(Header[0], SizeOf(Header));
    if not Image.ReadAt(Offset, Header, SizeOf(Header)) or (LE32(@Header[$100]) <> MagicNCCH) then
      Exit(False);
  end;
  if LE32(@Header[$100]) = MagicNCCH then
    Exit(HashNCCH(Image, Offset, Header, Hash, Keys, nil));

  case LE32(@Header[0]) of
    MagicCIA:
      Result := HashCIA(Image, Header, Hash, Keys);
    Magic3DSX:
      Result := AppendRange(Image, LE16(@Header[4]) + Int64(LE16(@Header[6])) * 3,
        Min(Int64(LE32(@Header[$10])), Int64(MaxHashSize)), Hash);
    MagicELF:
      Result := AppendRange(Image, 0, Min(Image.Size, Int64(MaxHashSize)), Hash);
  else
    Result := False;
  end;
end;

function TryHashRA3DS(Stream: TStream; const Keys: TRA3DSKeyProviders; out Digest: string): Boolean;
var
  Image: TRA3DSImage;
  Hash: THashMD5;
begin
  Digest := '';
  if Stream = nil then
    Exit(False);
  Image.Stream := Stream;
  Image.Start := Stream.Position;
  try
    try
      Image.Size := Stream.Size - Image.Start;
      Hash := THashMD5.Create;
      Result := HashImage(Image, Keys, Hash);
      if Result then
        Digest := LowerCase(Hash.HashAsString);
    except
      on EStreamError do
        Result := False;
    end;
  finally
    Stream.Position := Image.Start;
  end;
end;

function TryHashRA3DS(Stream: TStream; out Digest: string): Boolean;
begin
  Result := TryHashRA3DS(Stream, Default(TRA3DSKeyProviders), Digest);
end;

end.

